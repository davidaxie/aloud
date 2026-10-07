"""Native desktop entrypoint for Aloud.

Launches the FastAPI backend (which serves both the API and the built React UI)
on a local loopback port in a background thread, waits for it to become healthy,
then opens the reader in a native pywebview window on the main thread.

Before starting anything it probes ``GET /health`` on the target port: if an
Aloud backend is already serving there, the window attaches to it rather than
starting a rival on the same socket. While attached it keeps watching, and if
that backend stops and leaves the port free, it starts its own there, so the
open window gets its speech back without a relaunch.

macOS requires the GUI toolkit to run on the main thread, so uvicorn runs in a
worker thread and ``webview.start()`` owns the main thread. When the window is
closed, the server is asked to shut down and the process exits cleanly.

Environment variables:
    ALOUD_PORT      Force a specific port (otherwise prefer 8000, then 8001-8010,
                    else a free one).
                    Anything that is not a port number is ignored with a warning.
    ALOUD_HEADLESS  If set to "1", start the server, wait for health, print the
                    URL, then exit 0 — everything except opening the window. Used
                    for smoke-testing without popping a GUI.
"""

from __future__ import annotations

import json
import logging
import os
import socket
import sys
import threading
import time
import urllib.error
import urllib.request

# Ensure the backend package directory is importable no matter the working
# directory the launcher was invoked from (Python already puts the script dir on
# sys.path[0], but be explicit so `import app` / `import uvicorn` are reliable).
_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

import uvicorn

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(name)s: %(message)s",
)
logger = logging.getLogger("aloud.native")

HOST = "127.0.0.1"
HEALTH_TIMEOUT_SECS = 30.0
DEFAULT_PORT = 8000
# Tried in order when 8000 is taken, before a random port. The page's origin
# includes the port and its saved preferences belong to the origin, so a fixed
# fallback keeps them from one launch to the next.
FALLBACK_PORTS = range(DEFAULT_PORT + 1, DEFAULT_PORT + 11)
PROBE_TIMEOUT_SECS = 1.0
# How often a window attached to another backend checks that it is still there.
ATTACH_WATCH_SECS = 2.0
# Both addresses "localhost" can mean. The reader and the extension dial
# http://localhost:<port>, which macOS resolves to ::1 first, and a dev server
# that Node or Vite binds to localhost listens on ::1 alone.
LOOPBACK_HOSTS = (HOST, "::1")


def _accepts(host: str, port: int) -> bool:
    try:
        with socket.create_connection((host, port), timeout=PROBE_TIMEOUT_SECS):
            return True
    except OSError:
        return False


def port_in_use(port: int) -> bool:
    """True if anything is accepting connections on ``port`` at either loopback address.

    This is deliberately a CONNECT test rather than a bind test. Binding
    ``127.0.0.1:8000`` with SO_REUSEADDR *succeeds* on macOS while another
    process holds ``0.0.0.0:8000``, so the old check called a busy port free and
    we started a second backend: two 325 MB model loads and requests routed
    non-deterministically to one of them. ``::1`` counts too: a server there
    does not stop us binding 127.0.0.1, but it is the one the clients reach.
    """
    return any(_accepts(host, port) for host in LOOPBACK_HOSTS)


def _health(host: str, port: int) -> dict | None:
    """The ``/health`` payload at ``host:port`` if it names the kokoro engine."""
    if ":" in host:
        # Ask the way a client that dialed localhost does; the backend only
        # accepts its own Host names.
        request = urllib.request.Request(
            f"http://[{host}]:{port}/health", headers={"Host": f"localhost:{port}"}
        )
    else:
        request = urllib.request.Request(f"http://{host}:{port}/health")
    try:
        with urllib.request.urlopen(request, timeout=PROBE_TIMEOUT_SECS) as resp:
            if resp.status != 200:
                return None
            payload = json.loads(resp.read().decode("utf-8"))
    except (urllib.error.URLError, ConnectionError, OSError, ValueError):
        return None
    if isinstance(payload, dict) and payload.get("engine") == "kokoro":
        return payload
    return None


def probe_backend(port: int) -> dict | None:
    """Return the ``/health`` payload if an Aloud backend answers on ``port``.

    None means "not ours": nothing listening, not HTTP, or some other service
    that happens to own the port. Only a payload naming the kokoro engine counts,
    so we never attach a window to an unrelated dev server. Every loopback
    address that accepts has to be Aloud: one on 127.0.0.1 is no use to a
    client that dials localhost and lands on another server on ::1.
    """
    listening = [host for host in LOOPBACK_HOSTS if _accepts(host, port)]
    if HOST not in listening:
        return None
    payloads = [_health(host, port) for host in listening]
    if any(payload is None for payload in payloads):
        return None
    return payloads[0]


def _find_free_port() -> int:
    """Ask the OS for an unused loopback port."""
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.bind((HOST, 0))
        return sock.getsockname()[1]


def env_port() -> int | None:
    """ALOUD_PORT as a port number, or None when it is unset or not a port.

    Read in one place so every caller falls back the same way; a typo here
    used to be ignored by one function and crash the next.
    """
    raw = os.environ.get("ALOUD_PORT", "").strip()
    if not raw:
        return None
    try:
        port = int(raw)
    except ValueError:
        port = -1
    if not 0 < port < 65536:
        logger.warning("Ignoring invalid ALOUD_PORT=%r; using %d", raw, DEFAULT_PORT)
        return None
    return port


def find_running_backend() -> int | None:
    """Port of an Aloud backend that is already serving, or None.

    Attaching to it beats starting a rival (F4.6): a second process means a
    second model load and a coin flip over which one answers a given request.
    """
    candidate = env_port() or DEFAULT_PORT
    return candidate if probe_backend(candidate) is not None else None


def choose_port() -> int:
    """Pick the port to SERVE on: ALOUD_PORT, else 8000 if truly unused, else the
    first unused FALLBACK_PORTS entry, else any free port."""
    forced = env_port()
    if forced is not None:
        return forced
    if not port_in_use(DEFAULT_PORT):
        return DEFAULT_PORT
    port = next((p for p in FALLBACK_PORTS if not port_in_use(p)), None) or _find_free_port()
    logger.info("Port %d is already in use; using free port %d instead", DEFAULT_PORT, port)
    return port


def _start_own_server(port: int) -> tuple[uvicorn.Server, threading.Thread] | None:
    """Start the Aloud backend on ``port`` in a daemon thread; None if it cannot load.

    Importing the ASGI app triggers the one-time Kokoro model load, so a startup
    failure surfaces here, before anything depends on the server.
    """
    try:
        from app import app as asgi_app
    except Exception:  # noqa: BLE001
        logger.exception("Failed to import the Aloud backend app")
        return None
    config = uvicorn.Config(asgi_app, host=HOST, port=port, log_level="info")
    server = uvicorn.Server(config)
    # Run uvicorn in a daemon thread; the window (or headless wait) owns main.
    thread = threading.Thread(target=server.run, name="uvicorn", daemon=True)
    thread.start()
    return server, thread


def _take_over_when_gone(
    port: int,
    own: list[tuple[uvicorn.Server, threading.Thread]],
    stop: threading.Event,
    interval: float = ATTACH_WATCH_SECS,
) -> None:
    """While attached to another backend, start our own on ``port`` once it stops.

    The page polls /health on its own origin, so a backend back on the same port
    brings its speech back without a relaunch. A port that something else holds
    is left alone, and so is one the old backend is already serving again.
    """
    while not stop.wait(interval):
        if probe_backend(port) is not None or port_in_use(port):
            continue
        if stop.is_set():
            return
        logger.info("The Aloud backend on port %d stopped; starting our own there.", port)
        started = _start_own_server(port)
        if started is not None:
            own.append(started)
        return


def _wait_for_health(
    base_url: str, timeout: float, server_thread: threading.Thread | None = None
) -> bool:
    """Poll ``<base_url>/health`` until the backend answers or ``timeout`` elapses.

    "warming" counts as up. The engine's first inference costs ~4s, and the UI
    shows that as a transient notice — blocking here would trade a warm-up
    message for four seconds of nothing at all.

    Only an answer naming the kokoro engine counts, as in ``probe_backend``, so
    another service that owns the port never gets the window. If
    ``server_thread`` (our own uvicorn) stops, it could not bind the port, and
    this gives up at once instead of waiting out the timeout.
    """
    deadline = time.monotonic() + timeout
    health_url = f"{base_url}/health"
    while time.monotonic() < deadline:
        try:
            with urllib.request.urlopen(health_url, timeout=2.0) as resp:
                if resp.status == 200:
                    payload = json.loads(resp.read().decode("utf-8"))
                    if (
                        isinstance(payload, dict)
                        and payload.get("engine") == "kokoro"
                        and payload.get("status") in ("ok", "warming")
                    ):
                        return True
        except (urllib.error.URLError, ConnectionError, OSError, ValueError):
            pass  # Server not up yet — keep polling.
        if server_thread is not None and not server_thread.is_alive():
            return False
        time.sleep(0.25)
    return False


def main() -> int:
    # Servers this process started: one at launch, or one the attach watcher
    # starts later when the backend the window attached to goes away.
    own: list[tuple[uvicorn.Server, threading.Thread]] = []
    server_thread: threading.Thread | None = None
    watch_stop = threading.Event()

    attach_port = find_running_backend()
    if attach_port is not None:
        # Someone (run.sh, another Aloud window) already owns this port. Point
        # the window at them instead of racing for the same socket.
        port = attach_port
        base_url = f"http://{HOST}:{port}"
        logger.info("Aloud backend already running at %s — attaching to it.", base_url)
    else:
        port = choose_port()
        base_url = f"http://{HOST}:{port}"
        started = _start_own_server(port)
        if started is None:
            return 1
        own.append(started)
        server_thread = started[1]

    def stop_server() -> None:
        """Shut down the servers we started. A no-op when we only attached to another."""
        watch_stop.set()
        for server, thread in list(own):
            server.should_exit = True
            thread.join(timeout=5.0)

    logger.info("Waiting for backend health at %s/health ...", base_url)
    if not _wait_for_health(base_url, HEALTH_TIMEOUT_SECS, server_thread):
        if server_thread is not None and not server_thread.is_alive():
            logger.error(
                "The backend stopped before it was ready, most likely because port %d "
                "is in use by another program (see the error above). Stop that "
                "program, or set ALOUD_PORT to a free port.",
                port,
            )
            return 1
        logger.error(
            "Backend did not become healthy within %.0fs — giving up.",
            HEALTH_TIMEOUT_SECS,
        )
        stop_server()
        return 1

    logger.info("Backend is healthy at %s/", base_url)

    headless = os.environ.get("ALOUD_HEADLESS") == "1"
    if headless:
        # Smoke-test path: prove the server is up, print the URL, shut down.
        print(f"ALOUD_URL={base_url}/")
        stop_server()
        return 0

    if attach_port is not None:
        threading.Thread(
            target=_take_over_when_gone,
            args=(port, own, watch_stop),
            name="aloud-attach-watch",
            daemon=True,
        ).start()

    # Open the native window on the MAIN thread (required on macOS).
    import webview

    webview.create_window(
        "Aloud",
        f"{base_url}/",
        width=1120,
        height=780,
        min_size=(720, 560),
    )
    try:
        # pywebview defaults to private mode, which on macOS wipes the web
        # view's stored data at every launch, and with it the reader's saved
        # voice, rate and theme.
        webview.start(private_mode=False)
    finally:
        # Window closed (or start() raised): stop uvicorn and clean up.
        stop_server()

    return 0


if __name__ == "__main__":
    sys.exit(main())
