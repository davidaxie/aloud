"""Convenience launcher for the Aloud backend.

Run with the project venv:

    .venv/bin/python run.py

Starts uvicorn on port 8000. The Kokoro model loads once when ``app`` is
imported by the worker, so the first startup takes a few seconds.
"""

from __future__ import annotations

import uvicorn

HOST = "0.0.0.0"
PORT = 8000

if __name__ == "__main__":
    # Pass the app as an import string but with reload disabled: we want a
    # single process so the model is loaded exactly once.
    uvicorn.run("app:app", host=HOST, port=PORT, reload=False, log_level="info")
