#!/usr/bin/env bash
# Boot both halves of Aloud: the local Kokoro TTS backend and the reader UI.
# Ctrl-C stops both.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKEND="$ROOT/backend"
FRONTEND="$ROOT/frontend"

# --- preflight ---------------------------------------------------------------
if [[ ! -x "$BACKEND/.venv/bin/python" ]]; then
  echo "✗ Python venv missing. See README → Setup (uv venv + uv pip install)." >&2
  exit 1
fi
if [[ ! -f "$BACKEND/models/kokoro-v1.0.onnx" || ! -f "$BACKEND/models/voices-v1.0.bin" ]]; then
  echo "→ Kokoro models missing; downloading (~340 MB, one time)…"
  "$BACKEND/.venv/bin/python" "$BACKEND/download_models.py"
fi
if [[ ! -d "$FRONTEND/node_modules" ]]; then
  echo "→ Installing frontend deps…"
  (cd "$FRONTEND" && npm install)
fi

# --- launch ------------------------------------------------------------------
pids=()
cleanup() { echo; echo "Stopping Aloud…"; for pid in "${pids[@]}"; do kill "$pid" 2>/dev/null || true; done; }
trap cleanup EXIT INT TERM

echo "→ Starting TTS backend on http://localhost:8000 …"
( cd "$BACKEND" && exec .venv/bin/python run.py ) &
pids+=($!)

echo "→ Starting reader UI on http://localhost:5173 …"
( cd "$FRONTEND" && exec npm run dev ) &
pids+=($!)

echo
echo "Aloud is starting. Open  →  http://localhost:5173"
echo "(Press Ctrl-C to stop both.)"
wait
