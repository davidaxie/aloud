"""Convenience launcher for the Aloud backend.

Run with the project venv:

    .venv/bin/python run.py

Starts uvicorn on port 8000. The Kokoro model loads once when ``app`` is
imported by the worker, so the first startup takes a few seconds; the warm-up
inference then runs in the background and /health reports "warming" until it
finishes.

Environment variables:
    ALOUD_HOST       Bind address (default 0.0.0.0). Set 127.0.0.1 to keep the
                     server off the LAN.
    ALOUD_PORT       Port to serve on (default 8000). Useful for running a
                     second backend alongside the first without a port clash.
    ALOUD_QUEUE_MAX  Prefetch queue bound, read by ``app`` (default 8).
"""

from __future__ import annotations

import os

import uvicorn

HOST = os.environ.get("ALOUD_HOST", "0.0.0.0")
PORT = int(os.environ.get("ALOUD_PORT", "8000"))

if __name__ == "__main__":
    # Pass the app as an import string but with reload disabled, and stay at one
    # worker: the model is 325 MB and the phonemizer keeps process-global state,
    # so a second worker would double the memory and reintroduce the race that
    # the single synthesis thread exists to prevent.
    uvicorn.run("app:app", host=HOST, port=PORT, reload=False, log_level="info")
