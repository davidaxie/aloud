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
# run.py reads the same variable; anything that is not a number falls back.
PORT="${ALOUD_PORT:-8000}"
[[ "$PORT" =~ ^[0-9]+$ ]] || PORT=8000

pids=()
cleanup() { echo; echo "Stopping Aloud…"; for pid in "${pids[@]}"; do kill "$pid" 2>/dev/null || true; done; }
trap cleanup EXIT
trap 'exit 130' INT TERM

# True once an Aloud backend, not just anything, answers on the port.
backend_ready() {
  local body
  body="$(curl -fsS --max-time 2 "http://127.0.0.1:$PORT/health" 2>/dev/null)" || return 1
  [[ "$body" == *'"engine":"kokoro"'* ]]
}

echo "→ Starting TTS backend on http://localhost:$PORT …"
( cd "$BACKEND" && exec .venv/bin/python run.py ) &
backend_pid=$!
pids+=("$backend_pid")

echo "→ Starting reader UI on http://localhost:5173 …"
( cd "$FRONTEND" && exec npm run dev ) &
frontend_pid=$!
pids+=("$frontend_pid")

# Only point anyone at the reader once the backend answers. run.py exits 0 when
# an Aloud backend is already serving (the reader uses that one) and 1 when
# another program holds the port, so a backend that stops is fatal only if
# nothing Aloud answers afterwards.
echo "→ Waiting for the TTS backend to load …"
until backend_ready; do
  if ! kill -0 "$backend_pid" 2>/dev/null; then
    backend_ready && break
    echo "✗ The TTS backend stopped before it was ready (see the message above)." >&2
    exit 1
  fi
  sleep 0.5
done

echo
echo "Aloud is ready. Open  →  http://localhost:5173"
echo "(Press Ctrl-C to stop both.)"

# Stay up while the reader runs. If the backend goes away, stop the reader too
# rather than leave a page that can only say the engine is offline.
while kill -0 "$frontend_pid" 2>/dev/null; do
  if ! kill -0 "$backend_pid" 2>/dev/null && ! backend_ready; then
    echo "✗ The TTS backend stopped." >&2
    exit 1
  fi
  sleep 1
done
