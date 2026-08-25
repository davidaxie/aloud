"""Aloud FastAPI backend.

A tiny local, fully-offline HTTP service that turns text into natural speech
using the Kokoro neural TTS model. The Kokoro model is loaded exactly once as a
module-level singleton (see ``kokoro_engine``) when this module is imported.

Synthesis does NOT run in FastAPI's threadpool. Every request is handed to a
single worker thread (see ``synth_queue``) because the phonemizer underneath
Kokoro is not thread-safe; the handler blocks until that worker is done. Waiting
requests are ordered ``now`` before ``prefetch``.

Endpoints
    GET  /health      -> engine status, warm flag, queue depth, voice count
    GET  /voices      -> full voice list + default voice
    POST /synthesize  -> raw WAV bytes (audio/wav)

Environment variables:
    ALOUD_QUEUE_MAX  Max WAITING prefetch requests before /synthesize answers
                     429 + Retry-After. Default 8. `now` requests are never
                     rejected for depth.
"""

from __future__ import annotations

import io
import logging
import os

# Configure logging BEFORE importing the engine so the one-time model-load
# message (emitted at import time by kokoro_engine) is actually captured at
# INFO level rather than dropped by the default WARNING last-resort handler.
logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
logger = logging.getLogger("aloud.app")

import soundfile as sf
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
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

# Permissive CORS — this is a localhost dev tool consumed by a local frontend.
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=False,
    allow_methods=["*"],
    allow_headers=["*"],
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
        req.voice,
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


@app.post("/synthesize")
def synthesize(req: SynthesizeRequest) -> Response:
    """Synthesize speech and return a 16-bit PCM WAV.

    - 200 with ``Content-Type: audio/wav`` and raw WAV bytes on success.
    - 400 on empty/invalid text — **not** retryable, the client skips it.
    - 429 + ``Retry-After: 1`` when the prefetch backlog is full.
    - 500 on synthesis failure.
    - 503 + ``Retry-After: 2`` when the model is not loaded.

    Every error body carries ``retryable`` so the clients' retry policy is a
    property of the response rather than a guess about the status code.

    The call runs on the single synthesis worker; this handler's threadpool
    thread parks until the worker is done.
    """
    # Validate text up front so we return a clean 400 rather than a 500.
    if not req.text or not req.text.strip():
        return _error(400, "text must be a non-empty string", retryable=False, req=req)

    if not engine.model_loaded:
        return _error(503, "speech model is not loaded", retryable=True, req=req, retry_after=2)

    try:
        samples, sample_rate = synth_queue.submit(
            req.text, req.voice, req.speed, _priority_of(req)
        )
    except QueueFullError as exc:
        # Shed speculative load honestly instead of queueing without bound. The
        # client backs off and re-asks; the listener never notices.
        return _error(429, str(exc), retryable=True, req=req, retry_after=1)
    except ValueError as exc:
        # Defensive: engine also guards against empty text.
        return _error(400, str(exc), retryable=False, req=req)
    except Exception as exc:  # noqa: BLE001 — surface any synthesis failure as 500
        logger.exception("Synthesis failed")
        return _error(500, f"synthesis failed: {exc}", retryable=True, req=req)

    # Encode the float32 waveform to WAV (PCM 16-bit) entirely in memory. This
    # runs on the request thread, off the worker, so encoding never delays the
    # next sentence's inference.
    try:
        buf = io.BytesIO()
        sf.write(buf, samples, sample_rate, format="WAV", subtype="PCM_16")
        buf.seek(0)
        wav_bytes = buf.read()
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
  <p>Build it with <code>./build_app.sh</code> (or <code>cd frontend &amp;&amp; npm run build</code>),
     then reload.</p>
</div></body></html>
"""


if os.path.isfile(_INDEX_HTML):
    # Serve Vite's hashed bundles with proper caching/range headers. The
    # catch-all below would also serve them, but a real StaticFiles mount is the
    # canonical path and is checked before the catch-all (registered first wins).
    _assets_dir = os.path.join(_DIST_DIR, "assets")
    if os.path.isdir(_assets_dir):
        app.mount("/assets", StaticFiles(directory=_assets_dir), name="assets")

    @app.get("/", include_in_schema=False)
    def serve_index() -> FileResponse:
        """Serve the built single-page app shell at the root."""
        return FileResponse(_INDEX_HTML)

    @app.get("/{full_path:path}", include_in_schema=False)
    def spa_fallback(full_path: str) -> FileResponse:
        """Serve a real static file if one exists, else fall back to index.html.

        This is a catch-all for GET requests only, registered after every API
        route, so it never shadows /health, /voices, /synthesize, or /docs.
        """
        requested = os.path.normpath(os.path.join(_DIST_DIR, full_path))
        # Guard against path traversal: only serve files inside dist.
        if requested.startswith(_DIST_DIR + os.sep) and os.path.isfile(requested):
            return FileResponse(requested)
        # Unknown non-API path -> hand back the SPA shell (client-side routing).
        return FileResponse(_INDEX_HTML)

    logger.info("Serving built frontend from %s", _DIST_DIR)
else:
    logger.warning(
        "frontend/dist not found at %s — serving a placeholder page. "
        "Run ./build_app.sh (or 'cd frontend && npm run build') to build the UI.",
        _DIST_DIR,
    )

    @app.get("/", include_in_schema=False)
    def serve_placeholder() -> HTMLResponse:
        """Friendly page shown when the frontend hasn't been built yet."""
        return HTMLResponse(_PLACEHOLDER_HTML)
