"""Native desktop entrypoint for Aloud.

Launches the FastAPI backend (which serves both the API and the built React UI)
on a local loopback port in a background thread, waits for it to become healthy,
then opens the reader in a native pywebview window on the main thread.

macOS requires the GUI toolkit to run on the main thread, so uvicorn runs in a
worker thread and ``webview.start()`` owns the main thread. When the window is
closed, the server is asked to shut down and the process exits cleanly.

Environment variables:
    ALOUD_PORT      Force a specific port (otherwise prefer 8000, else a free one).
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


def _port_is_free(port: int) -> bool:
    """Return True if ``port`` can be bound on the loopback interface."""
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        try:
            sock.bind((HOST, port))
            return True
        except OSError:
            return False


def _find_free_port() -> int:
    """Ask the OS for an unused loopback port."""
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.bind((HOST, 0))
        return sock.getsockname()[1]


def choose_port() -> int:
    """Pick the port to serve on: ALOUD_PORT, else 8000, else any free port."""
    env_port = os.environ.get("ALOUD_PORT")
    if env_port:
        return int(env_port)
    if _port_is_free(8000):
        return 8000
    port = _find_free_port()
    logger.info("Port 8000 is busy; using free port %d instead", port)
    return port


def _wait_for_health(base_url: str, timeout: float) -> bool:
    """Poll ``<base_url>/health`` until it reports ok or ``timeout`` elapses."""
    deadline = time.monotonic() + timeout
    health_url = f"{base_url}/health"
    while time.monotonic() < deadline:
        try:
            with urllib.request.urlopen(health_url, timeout=2.0) as resp:
                if resp.status == 200:
                    payload = json.loads(resp.read().decode("utf-8"))
                    if payload.get("status") == "ok":
                        return True
        except (urllib.error.URLError, ConnectionError, OSError, ValueError):
            pass  # Server not up yet — keep polling.
        time.sleep(0.25)
    return False


def main() -> int:
    port = choose_port()
    base_url = f"http://{HOST}:{port}"

    # Import the ASGI app here (triggers the one-time Kokoro model load) so any
    # startup failure surfaces before we spawn threads or open a window.
    try:
        from app import app as asgi_app
    except Exception:  # noqa: BLE001
        logger.exception("Failed to import the Aloud backend app")
        return 1

    config = uvicorn.Config(asgi_app, host=HOST, port=port, log_level="info")
    server = uvicorn.Server(config)

    # Run uvicorn in a daemon thread; the window (or headless wait) owns main.
    server_thread = threading.Thread(target=server.run, name="uvicorn", daemon=True)
    server_thread.start()

    logger.info("Waiting for backend health at %s/health ...", base_url)
    if not _wait_for_health(base_url, HEALTH_TIMEOUT_SECS):
        logger.error(
            "Backend did not become healthy within %.0fs — giving up.",
            HEALTH_TIMEOUT_SECS,
        )
        server.should_exit = True
        server_thread.join(timeout=5.0)
        return 1

    logger.info("Backend is healthy at %s/", base_url)

    headless = os.environ.get("ALOUD_HEADLESS") == "1"
    if headless:
        # Smoke-test path: prove the server is up, print the URL, shut down.
        print(f"ALOUD_URL={base_url}/")
        server.should_exit = True
        server_thread.join(timeout=5.0)
        return 0

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
        webview.start()
    finally:
        # Window closed (or start() raised): stop uvicorn and clean up.
        server.should_exit = True
        server_thread.join(timeout=5.0)

    return 0


if __name__ == "__main__":
    sys.exit(main())
