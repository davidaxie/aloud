"""Shared helpers for the backend tests.

Nothing here loads the Kokoro model, plays audio or opens a socket. The app is
imported with a stand-in engine and driven with raw ASGI messages, the way the
server would drive it, so no HTTP client library is needed.
"""

from __future__ import annotations

import asyncio
import importlib.util
import json
import logging
import sys
import threading
import types
from pathlib import Path
from typing import Any, Callable

import numpy as np

BACKEND = Path(__file__).resolve().parent.parent
if str(BACKEND) not in sys.path:
    sys.path.insert(0, str(BACKEND))

from synth_queue import SynthQueue  # noqa: E402


class FakeEngine:
    """Just enough of ``kokoro_engine.engine`` for ``app`` to import and serve."""

    model_loaded = True
    voice_count = 1
    default_voice = "af_heart"

    def list_voices(self) -> list:
        return []

    def synthesize(self, text: str, voice: str, speed: float, should_stop=None):
        return np.zeros(240, dtype=np.float32), 24000


def load_module(name: str, filename: str, stubs: dict[str, types.ModuleType] | None = None):
    """Import ``backend/<filename>`` under ``name``, with ``stubs`` in sys.modules meanwhile."""
    stubs = stubs or {}
    saved = {key: sys.modules.get(key) for key in stubs}
    sys.modules.update(stubs)
    try:
        spec = importlib.util.spec_from_file_location(name, BACKEND / filename)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
    finally:
        for key, value in saved.items():
            if value is None:
                sys.modules.pop(key, None)
            else:
                sys.modules[key] = value
    return module


_app_module = None


def load_app():
    """The ``app`` module, imported once with a fake engine."""
    global _app_module
    if _app_module is None:
        fake = types.ModuleType("kokoro_engine")
        fake.engine = FakeEngine()
        _app_module = load_module("aloud_app_under_test", "app.py", {"kokoro_engine": fake})
        # app configures INFO logging at import; keep test output quiet.
        logging.disable(logging.CRITICAL)
    return _app_module


# The warm-up text test queues use, so recording synths can leave it out.
WARMUP_TEXT = "(warm-up)"


def make_queue(synth_fn: Callable[[str, str, float], Any], **kwargs) -> SynthQueue:
    """A started queue whose warm-up has finished, so tests see only their own jobs."""
    queue = SynthQueue(synth_fn, warmup_text=WARMUP_TEXT, **kwargs)
    queue.start()
    for _ in range(200):
        if queue.warm:
            break
        threading.Event().wait(0.01)
    return queue


def silent_synth(text: str, voice: str, speed: float):
    return np.zeros(240, dtype=np.float32), 24000


class Reply:
    def __init__(self, status: int, headers: dict[str, str], body: bytes) -> None:
        self.status = status
        self.headers = headers
        self.body = body

    def json(self) -> Any:
        return json.loads(self.body.decode("utf-8"))


def call(
    app: Any,
    method: str,
    path: str,
    *,
    body: bytes = b"",
    headers: dict[str, str] | None = None,
    host: str = "localhost:8000",
    chunks: list[bytes] | None = None,
    hang_up_after_body: bool = False,
    content_type: str | None = "application/json",
) -> Reply:
    """Send one request through ``app`` and collect the response.

    ``chunks`` streams the body in pieces with no Content-Length, like a chunked
    upload. ``hang_up_after_body`` makes the client disconnect as soon as the
    body is sent; otherwise it stays connected until the response arrives.
    ``content_type`` is the Content-Type a POST carries; None sends none, the
    way a cross-site page's simple request can.
    """
    pieces = chunks if chunks is not None else [body]
    header_list = [(b"host", host.encode())]
    if method in ("POST", "PUT", "PATCH"):
        if content_type is not None:
            headers = {"content-type": content_type, **(headers or {})}
        if chunks is None:
            header_list.append((b"content-length", str(len(body)).encode()))
    for key, value in (headers or {}).items():
        header_list.append((key.lower().encode(), value.encode()))
    scope = {
        "type": "http",
        "asgi": {"version": "3.0"},
        "http_version": "1.1",
        "method": method,
        "scheme": "http",
        "path": path,
        "raw_path": path.encode(),
        "query_string": b"",
        "root_path": "",
        "headers": header_list,
        "client": ("127.0.0.1", 50000),
        "server": ("127.0.0.1", 8000),
    }

    async def run() -> Reply:
        pending = [
            {"type": "http.request", "body": piece, "more_body": i < len(pieces) - 1}
            for i, piece in enumerate(pieces)
        ]
        never = asyncio.Event()

        async def receive() -> dict:
            if pending:
                return pending.pop(0)
            if hang_up_after_body:
                return {"type": "http.disconnect"}
            await never.wait()
            return {"type": "http.disconnect"}

        sent: list[dict] = []

        async def send(message: dict) -> None:
            sent.append(message)

        await app(scope, receive, send)
        start = next(m for m in sent if m["type"] == "http.response.start")
        reply_headers = {k.decode().lower(): v.decode() for k, v in start.get("headers", [])}
        reply_body = b"".join(m.get("body", b"") for m in sent if m["type"] == "http.response.body")
        return Reply(start["status"], reply_headers, reply_body)

    return asyncio.run(run())


def synth_body(text: str, voice: str = "af_heart", priority: str = "now") -> bytes:
    return json.dumps({"text": text, "voice": voice, "speed": 1.0, "priority": priority}).encode()
