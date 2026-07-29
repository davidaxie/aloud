"""Aloud FastAPI backend.

A tiny local, fully-offline HTTP service that turns text into natural speech
using the Kokoro neural TTS model. The Kokoro model is loaded exactly once as a
module-level singleton (see ``kokoro_engine``) when this module is imported.

Endpoints
    GET  /health      -> engine status + voice count
    GET  /voices      -> full voice list + default voice
    POST /synthesize  -> raw WAV bytes (audio/wav)
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

app = FastAPI(title="Aloud TTS", version="1.0.0")

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


@app.get("/health")
def health() -> dict:
    """Liveness/readiness probe with basic engine info."""
    return {
        "status": "ok",
        "engine": "kokoro",
        "model_loaded": engine.model_loaded,
        "voice_count": engine.voice_count,
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

    - 400 (JSON ``{"error": ...}``) on empty/invalid text.
    - 500 (JSON ``{"error": ...}``) on synthesis failure.
    - 200 with ``Content-Type: audio/wav`` and raw WAV bytes on success.
    """
    # Validate text up front so we return a clean 400 rather than a 500.
    if not req.text or not req.text.strip():
        return JSONResponse(status_code=400, content={"error": "text must be a non-empty string"})

    try:
        samples, sample_rate = engine.synthesize(req.text, req.voice, req.speed)
    except ValueError as exc:
        # Defensive: engine also guards against empty text.
        return JSONResponse(status_code=400, content={"error": str(exc)})
    except Exception as exc:  # noqa: BLE001 — surface any synthesis failure as 500
        logger.exception("Synthesis failed")
        return JSONResponse(status_code=500, content={"error": f"synthesis failed: {exc}"})

    # Encode the float32 waveform to WAV (PCM 16-bit) entirely in memory.
    try:
        buf = io.BytesIO()
        sf.write(buf, samples, sample_rate, format="WAV", subtype="PCM_16")
        buf.seek(0)
        wav_bytes = buf.read()
    except Exception as exc:  # noqa: BLE001
        logger.exception("WAV encoding failed")
        return JSONResponse(status_code=500, content={"error": f"encoding failed: {exc}"})

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
