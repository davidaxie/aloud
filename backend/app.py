"""Aloud FastAPI backend.

A tiny local, fully-offline HTTP service that turns text into natural speech
using the Kokoro neural TTS model. The Kokoro model is loaded exactly once as a
module-level singleton (see ``kokoro_engine``) when this module is imported.

Synthesis does NOT run in FastAPI's threadpool. Every request is handed to a
single worker thread (see ``synth_queue``) because the phonemizer underneath
Kokoro is not thread-safe; the handler waits until that worker is done, and
drops the job if the client hangs up first. Waiting requests are ordered
``now`` before ``prefetch``.

Only this machine may use the server. Requests must name ``localhost`` or
``127.0.0.1`` as their Host (so a DNS-rebinding page is refused), and browsers
only let pages served from those hosts, and Chrome extensions, read the
responses. /synthesize also refuses a body that is not sent as JSON, since a
page on any site can POST one without asking first.

Endpoints
    GET  /health      -> engine status, warm flag, queue depth, voice count
    GET  /voices      -> full voice list + default voice
    POST /synthesize  -> raw WAV bytes (audio/wav)

Environment variables:
    ALOUD_QUEUE_MAX  Max WAITING prefetch requests before /synthesize answers
                     429 + Retry-After. Default 8. `now` requests are never
                     rejected for depth.
    ALOUD_ALLOWED_HOSTS  Comma-separated extra Host names to accept, on top of
                     "localhost" and "127.0.0.1", which are always accepted.
                     Needed only when the server is opened to the LAN on
                     purpose (ALOUD_HOST in run.py).
    ALOUD_CORS_ORIGINS  Comma-separated extra browser origins allowed to call
                     the API. Pages on localhost or 127.0.0.1, any port, and
                     Chrome extensions are always allowed.
"""

from __future__ import annotations

import io
import logging
import os
from typing import Any

# Configure logging BEFORE importing the engine so the one-time model-load
# message (emitted at import time by kokoro_engine) is actually captured at
# INFO level rather than dropped by the default WARNING last-resort handler.
logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
logger = logging.getLogger("aloud.app")

import anyio
import soundfile as sf
from fastapi import FastAPI, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.middleware.trustedhost import TrustedHostMiddleware
from fastapi.responses import FileResponse, HTMLResponse, JSONResponse, Response
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel

# Importing the engine triggers the one-time model load and logs load time.
from kokoro_engine import engine
from synth_queue import (
    PRIORITY_NOW,
    PRIORITY_PREFETCH,
    QueueFullError,
    SynthQueue,
    truncate_for_log,
)

app = FastAPI(title="Aloud TTS", version="1.1.0")


def _queue_max() -> int:
    """Read ALOUD_QUEUE_MAX, falling back to 8 on anything unparseable."""
    raw = os.environ.get("ALOUD_QUEUE_MAX", "").strip()
    if not raw:
        return 8
    try:
        return max(0, int(raw))
    except ValueError:
        logger.warning("Ignoring invalid ALOUD_QUEUE_MAX=%r; using 8", raw)
        return 8


# Started at import time, not on the ASGI startup event, so the ~4.1s warm-up
# overlaps with the rest of uvicorn's boot instead of following it. Requests that
# arrive meanwhile queue behind the warm-up job and /health reports "warming".
synth_queue = SynthQueue(
    engine.synthesize,
    max_prefetch=_queue_max(),
    warmup_voice=engine.default_voice,
)
synth_queue.start()

# Input bounds. Both clients cap a chunk at 350 characters, so these only stop
# requests no reader sends: one oversized job would hold the single worker for
# hours, with memory growing in step with the text.
MAX_TEXT_CHARS = 2000
MAX_VOICE_CHARS = 64
MAX_BODY_BYTES = 64 * 1024

# How often a waiting /synthesize request checks whether its client is still
# there. Completion itself wakes the handler at once; this only bounds how long
# an abandoned job can sit in the queue before it is dropped.
_DISCONNECT_POLL_SECS = 0.25

# Any page served from this machine, on any port: the Vite dev server (which
# moves off 5173 when that port is taken) and the built UI on whichever port the
# backend landed on. Also any Chrome extension: Aloud's own has host permission
# only for localhost, so against a LAN backend (ALOUD_HOST) its calls are plain
# CORS requests, and its ID differs per install. A web page cannot have any of
# these origins.
_LOCAL_ORIGIN_REGEX = r"^(http://(localhost|127\.0\.0\.1)(:\d+)?|chrome-extension://[a-p]{32})$"


def _env_list(name: str, default: list[str]) -> list[str]:
    """Read a comma-separated environment variable, or ``default`` when unset."""
    items = [item.strip() for item in os.environ.get(name, "").split(",") if item.strip()]
    return items or default


class _BodySizeLimit:
    """Refuse request bodies over ``max_bytes`` before anything parses them.

    Checks the declared Content-Length, then counts the bytes actually streamed,
    since a chunked request declares none. The body is buffered (it is small by
    construction) and handed on unchanged; later receives, such as the
    disconnect the /synthesize handler watches for, go to the server as usual.
    """

    def __init__(self, app: Any, max_bytes: int) -> None:
        self.app = app
        self.max_bytes = max_bytes

    async def __call__(self, scope: dict, receive: Any, send: Any) -> None:
        if scope["type"] != "http" or scope["method"] not in ("POST", "PUT", "PATCH"):
            await self.app(scope, receive, send)
            return

        for name, value in scope.get("headers", []):
            if name == b"content-length" and value.strip().isdigit() and int(value) > self.max_bytes:
                await self._too_large(scope, receive, send)
                return

        chunks: list[bytes] = []
        size = 0
        while True:
            message = await receive()
            if message["type"] == "http.disconnect":
                return
            chunk = message.get("body", b"")
            size += len(chunk)
            if size > self.max_bytes:
                await self._too_large(scope, receive, send)
                return
            chunks.append(chunk)
            if not message.get("more_body", False):
                break

        body = b"".join(chunks)
        replayed = False

        async def replay() -> dict:
            nonlocal replayed
            if not replayed:
                replayed = True
                return {"type": "http.request", "body": body, "more_body": False}
            return await receive()

        await self.app(scope, replay, send)

    async def _too_large(self, scope: dict, receive: Any, send: Any) -> None:
        logger.warning("413 request body over %d bytes | path=%s", self.max_bytes, scope.get("path"))
        response = JSONResponse(
            status_code=413,
            content={"error": f"request body is larger than {self.max_bytes} bytes", "retryable": False},
        )
        await response(scope, receive, send)


# Registered innermost first: the host check runs before everything, and CORS
# wraps the body limit so even a 413 is readable by the page that caused it.
app.add_middleware(_BodySizeLimit, max_bytes=MAX_BODY_BYTES)
app.add_middleware(
    CORSMiddleware,
    allow_origins=_env_list("ALOUD_CORS_ORIGINS", []),
    allow_origin_regex=_LOCAL_ORIGIN_REGEX,
    allow_credentials=False,
    allow_methods=["GET", "POST"],
    allow_headers=["Content-Type"],
    # The dev reader is cross-origin and backs off by this header on 429/503.
    expose_headers=["Retry-After"],
)
app.add_middleware(
    TrustedHostMiddleware,
    # The env list adds to this Mac's own names rather than replacing them, so
    # opening the server to the LAN never shuts out the local reader, run.sh's
    # readiness check or the native window.
    allowed_hosts=["localhost", "127.0.0.1", *_env_list("ALOUD_ALLOWED_HOSTS", [])],
)


class SynthesizeRequest(BaseModel):
    """Request body for POST /synthesize."""

    text: str
    voice: str = "af_heart"
    speed: float = 1.0
    # Typed as a plain str, not a Literal: an unknown value from an older or
    # third-party client must degrade to "now" (see _priority_of), never become
    # a 422 that is not in the documented status table.
    priority: str = PRIORITY_NOW


def _priority_of(req: SynthesizeRequest) -> str:
    """Map the request's priority to a queue class.

    Anything that is not literally "prefetch" is treated as "now": guessing
    wrong in that direction only costs queue position, while guessing wrong the
    other way would park a sentence the listener is waiting on behind
    speculative work.
    """
    return PRIORITY_PREFETCH if req.priority == PRIORITY_PREFETCH else PRIORITY_NOW


def _is_json(content_type: str | None) -> bool:
    """True for ``application/json`` or ``application/*+json``, parameters ignored."""
    media = (content_type or "").split(";", 1)[0].strip().lower()
    if media == "application/json":
        return True
    return media.startswith("application/") and media.endswith("+json")


def _error(
    status: int,
    message: str,
    *,
    retryable: bool,
    req: SynthesizeRequest,
    retry_after: int | None = None,
) -> JSONResponse:
    """Build an error response and log it at WARNING (A1.6, A1.7).

    Every 4xx/5xx carries the truncated offending text and the voice, so a
    report of "it skipped a sentence" can be reproduced from the log alone. The
    ``retryable`` flag is what tells both clients whether to back off and try
    again or to skip the sentence and keep playing.
    """
    logger.warning(
        "%d %s | voice=%s speed=%.2f priority=%s text=%r",
        status,
        message,
        truncate_for_log(req.voice, MAX_VOICE_CHARS),
        req.speed,
        _priority_of(req),
        truncate_for_log(req.text),
    )
    headers = {"Retry-After": str(retry_after)} if retry_after is not None else None
    return JSONResponse(
        status_code=status,
        content={"error": message, "retryable": retryable},
        headers=headers,
    )


@app.get("/health")
def health() -> dict:
    """Liveness/readiness probe with engine, warm-up and queue state.

    ``status`` is "warming" until the startup inference completes and "ok"
    after, so a client can tell "still starting" (transient, no error styling)
    from "unreachable" (persistent banner). The three older fields are unchanged
    because two shipped clients read them.
    """
    warm = synth_queue.warm
    return {
        "status": "ok" if warm else "warming",
        "engine": "kokoro",
        "model_loaded": engine.model_loaded,
        "voice_count": engine.voice_count,
        "warm": warm,
        "queue_depth": synth_queue.queue_depth,
    }


@app.get("/voices")
def voices() -> dict:
    """Return every installed voice's metadata plus the default voice id."""
    return {
        "voices": engine.list_voices(),
        "default": engine.default_voice,
    }


def _encode_wav(samples: Any, sample_rate: int) -> bytes:
    """Encode a float32 waveform as 16-bit PCM WAV, entirely in memory."""
    buf = io.BytesIO()
    sf.write(buf, samples, sample_rate, format="WAV", subtype="PCM_16")
    buf.seek(0)
    return buf.read()


async def _wait_for_job(job: Any, request: Request) -> bool:
    """Wait for the worker to finish ``job`` without holding the event loop.

    Returns False, after cancelling the job, when the client hangs up first. The
    web player aborts every request it no longer needs (a seek, a voice change,
    its own 30 s timeout); without this the worker would still synthesize each
    abandoned sentence, in order, before the one the listener is waiting on.
    """
    while not await anyio.to_thread.run_sync(job.done.wait, _DISCONNECT_POLL_SECS):
        if await request.is_disconnected():
            synth_queue.cancel(job)
            return False
    return True


@app.post("/synthesize")
async def synthesize(req: SynthesizeRequest, request: Request) -> Response:
    """Synthesize speech and return a 16-bit PCM WAV.

    - 200 with ``Content-Type: audio/wav`` and raw WAV bytes on success.
    - 400 on empty/invalid text or an over-long voice id — **not** retryable,
      the client skips it.
    - 413 when the text is over ``MAX_TEXT_CHARS`` or the body is over
      ``MAX_BODY_BYTES`` — **not** retryable.
    - 415 when the body is not sent as JSON — **not** retryable. Both clients
      send ``Content-Type: application/json``; a cross-site page can only skip
      the CORS preflight by leaving it out.
    - 429 + ``Retry-After: 1`` when the prefetch backlog is full.
    - 500 on synthesis failure.
    - 503 + ``Retry-After: 2`` when the model is not loaded.

    Every error body carries ``retryable`` so the clients' retry policy is a
    property of the response rather than a guess about the status code.

    The call runs on the single synthesis worker. If the client hangs up while
    the job is still waiting, the job is dropped and never synthesized.
    """
    # FastAPI 0.132+ already refuses an untyped body, but a venv set up before
    # requirements.txt pinned it can hold an older release that parses it as
    # JSON, so do not rely on the default.
    if not _is_json(request.headers.get("content-type")):
        return _error(
            415, "request body must be sent as application/json", retryable=False, req=req
        )

    # Validate text up front so we return a clean 400 rather than a 500.
    if not req.text or not req.text.strip():
        return _error(400, "text must be a non-empty string", retryable=False, req=req)
    if len(req.text) > MAX_TEXT_CHARS:
        return _error(
            413, f"text is longer than {MAX_TEXT_CHARS} characters", retryable=False, req=req
        )
    if len(req.voice) > MAX_VOICE_CHARS:
        return _error(
            400, f"voice is longer than {MAX_VOICE_CHARS} characters", retryable=False, req=req
        )

    if not engine.model_loaded:
        return _error(503, "speech model is not loaded", retryable=True, req=req, retry_after=2)

    try:
        job = synth_queue.enqueue(req.text, req.voice, req.speed, _priority_of(req))
    except QueueFullError as exc:
        # Shed speculative load honestly instead of queueing without bound. The
        # client backs off and re-asks; the listener never notices.
        return _error(429, str(exc), retryable=True, req=req, retry_after=1)
    except Exception as exc:  # noqa: BLE001 — e.g. the queue is shutting down
        logger.exception("Could not queue synthesis")
        return _error(500, f"synthesis failed: {exc}", retryable=True, req=req)

    if not await _wait_for_job(job, request):
        # Nobody is left to read a response; 499 is the conventional
        # "client closed request" and only shows up in the access log.
        logger.info(
            "Client left; dropped %s job | voice=%s text=%r",
            job.priority,
            truncate_for_log(req.voice, MAX_VOICE_CHARS),
            truncate_for_log(req.text),
        )
        return Response(status_code=499)

    try:
        samples, sample_rate = synth_queue.result(job)
    except ValueError as exc:
        # Defensive: engine also guards against empty text.
        return _error(400, str(exc), retryable=False, req=req)
    except Exception as exc:  # noqa: BLE001 — surface any synthesis failure as 500
        logger.exception("Synthesis failed")
        return _error(500, f"synthesis failed: {exc}", retryable=True, req=req)

    # Encode on a threadpool thread, off both the event loop and the worker, so
    # encoding never delays another request or the next sentence's inference.
    try:
        wav_bytes = await anyio.to_thread.run_sync(_encode_wav, samples, sample_rate)
    except Exception as exc:  # noqa: BLE001
        logger.exception("WAV encoding failed")
        return _error(500, f"encoding failed: {exc}", retryable=True, req=req)

    return Response(content=wav_bytes, media_type="audio/wav")


# ---------------------------------------------------------------------------
# Static frontend serving
#
# One server serves both the JSON API (above) and the built React UI, so the
# frontend is same-origin and calls /health, /voices, /synthesize relatively.
#
# Ordering matters: the API routes above are registered first and therefore win
# over the catch-all SPA fallback registered below. The fallback is GET-only, so
# POST /synthesize is never shadowed either.
# ---------------------------------------------------------------------------

# frontend/dist lives next to the backend, resolved relative to this file so the
# server works regardless of the current working directory.
_REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
_DIST_DIR = os.path.join(_REPO_ROOT, "frontend", "dist")
_INDEX_HTML = os.path.join(_DIST_DIR, "index.html")

_PLACEHOLDER_HTML = """<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Aloud — build required</title>
<style>
  body{font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;
       background:#0b0b0c;color:#f5f5f7;display:flex;min-height:100vh;margin:0;
       align-items:center;justify-content:center;text-align:center}
  .card{max-width:32rem;padding:2rem}
  code{background:#1c1c1f;color:#ff9500;padding:.15em .45em;border-radius:.35em}
  h1{font-weight:600;letter-spacing:-.01em}
  p{color:#a1a1a6;line-height:1.6}
</style></head>
<body><div class="card">
  <h1>Aloud backend is running</h1>
  <p>The frontend hasn't been built yet, so there's nothing to show here.</p>
  <p>Build it with <code>legacy/build_web_app.sh</code> (or <code>cd frontend &amp;&amp; npm run build</code>),
     then reload.</p>
</div></body></html>
"""


# The routes below are registered whether or not the UI is built yet, and each
# request looks for index.html, so a build made while the server runs replaces
# the placeholder on the next reload, with no restart.

# Serve Vite's hashed bundles with proper caching/range headers. The catch-all
# below also serves them (and is what serves a build made after startup), but a
# real StaticFiles mount is the canonical path and is checked before the
# catch-all (registered first wins).
_assets_dir = os.path.join(_DIST_DIR, "assets")
if os.path.isdir(_assets_dir):
    app.mount("/assets", StaticFiles(directory=_assets_dir), name="assets")


def _spa_shell() -> Response:
    """index.html, which the browser must check with us before each use.

    Its hashed bundles change name on every build, but the shell keeps its
    name. With only Last-Modified to go on, WebKit keeps a copy fresh for
    a tenth of its age, so a window reopened after a rebuild would load the
    old shell and its old bundles, which the build has deleted.

    Until the UI is built this is the placeholder page, checked the same way,
    so the reload it asks for fetches the real shell.
    """
    if not os.path.isfile(_INDEX_HTML):
        return HTMLResponse(_PLACEHOLDER_HTML, headers={"Cache-Control": "no-cache"})
    return FileResponse(_INDEX_HTML, headers={"Cache-Control": "no-cache"})


@app.get("/", include_in_schema=False)
def serve_index() -> Response:
    """Serve the single-page app shell (or the placeholder) at the root."""
    return _spa_shell()


@app.get("/{full_path:path}", include_in_schema=False)
def spa_fallback(full_path: str) -> Response:
    """Serve a real static file if one exists, else fall back to index.html.

    This is a catch-all for GET requests only, registered after every API
    route, so it never shadows /health, /voices, /synthesize, or /docs.
    """
    requested = os.path.normpath(os.path.join(_DIST_DIR, full_path))
    # Guard against path traversal: only serve files inside dist.
    if (
        requested.startswith(_DIST_DIR + os.sep)
        and os.path.isfile(requested)
        and requested != _INDEX_HTML
    ):
        return FileResponse(requested)
    # Unknown non-API path -> hand back the SPA shell (client-side routing).
    return _spa_shell()


if os.path.isfile(_INDEX_HTML):
    logger.info("Serving built frontend from %s", _DIST_DIR)
else:
    logger.warning(
        "frontend/dist not found at %s — serving a placeholder page until it is built. "
        "Run legacy/build_web_app.sh (or 'cd frontend && npm run build') to build the UI.",
        _DIST_DIR,
    )
