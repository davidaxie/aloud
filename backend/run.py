"""Convenience launcher for the Aloud backend.

Run with the project venv:

    .venv/bin/python run.py

Starts uvicorn on 127.0.0.1:8000. The Kokoro model loads once when ``app`` is
imported by the worker, so the first startup takes a few seconds; the warm-up
inference then runs in the background and /health reports "warming" until it
finishes.

Before loading anything it checks the port. If an Aloud backend already answers
there, it says so and exits 0, and the reader keeps using that one. If some
other program answers there, it exits 1 with a message: on macOS a second
server can bind the port next to the first without an error, and the reader
would then quietly talk to the wrong one.

Environment variables:
    ALOUD_HOST       Bind address (default 127.0.0.1, this Mac only). Set
                     0.0.0.0 to open the server to the LAN on purpose; it has no
                     login, so also list the names other devices will use in
                     ALOUD_ALLOWED_HOSTS (read by ``app``).
    ALOUD_PORT       Port to serve on (default 8000). Useful for running a
                     second backend alongside the first without a port clash.
                     Anything that is not a port number is ignored with a warning.
    ALOUD_QUEUE_MAX  Prefetch queue bound, read by ``app`` (default 8).

``run.py --print-port`` prints the port it would serve on and exits, so run.sh
waits on the same port and points the reader at it.
"""

from __future__ import annotations

import os
import sys

import uvicorn

from native_app import DEFAULT_PORT, env_port, port_in_use, probe_backend

HOST = os.environ.get("ALOUD_HOST", "127.0.0.1")
PORT = env_port() or DEFAULT_PORT


def preflight(port: int) -> int | None:
    """Check ``port`` before the model loads.

    Returns None when the port is free to serve on, otherwise the exit code:
    0 when an Aloud backend is already serving there, 1 when something else is.
    The check connects to 127.0.0.1 because that is where both clients look.
    """
    if probe_backend(port) is not None:
        print(f"Aloud backend is already running on http://localhost:{port}; using that one.")
        return 0
    if port_in_use(port):
        print(
            f"Port {port} is in use by another program, so the reader could not reach "
            f"Aloud there. Stop that program, or set ALOUD_PORT to a free port.",
            file=sys.stderr,
        )
        return 1
    return None


def main(argv: list[str] | None = None) -> int:
    args = sys.argv[1:] if argv is None else argv
    if args == ["--print-port"]:
        print(PORT)
        return 0
    code = preflight(PORT)
    if code is not None:
        return code
    # Pass the app as an import string but with reload disabled, and stay at one
    # worker: the model is 325 MB and the phonemizer keeps process-global state,
    # so a second worker would double the memory and reintroduce the race that
    # the single synthesis thread exists to prevent.
    uvicorn.run("app:app", host=HOST, port=PORT, reload=False, log_level="info")
    return 0


if __name__ == "__main__":
    sys.exit(main())
