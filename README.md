# Aloud

**Offline text-to-speech for your PDFs.** Drop in a PDF and Aloud reads it to you in a natural, neural voice — think Speechify, but everything runs locally on your machine. No accounts, no cloud, no data leaving your laptop. Built for focused, long-form listening with a clean, minimal reader and light/dark modes.

<p align="center"><em>A window, a chair, and a story unfolding at exactly the speed you can follow.</em></p>

---

## Why it's different

- **Genuinely natural voices, fully offline.** Aloud uses [Kokoro](https://github.com/thewh1teagle/kokoro-onnx), an 82M-parameter neural TTS model, running locally via ONNX. 50+ voices across several languages. After the one-time model download, it needs no internet at all.
- **Follow along as it reads.** The current sentence is highlighted and gently auto-scrolls into view. Click any sentence to jump there.
- **Buffered, gap-free playback.** The next sentences are synthesized ahead of time (Kokoro runs ~5× faster than real-time), so playback stays smooth.
- **Made for focus.** A calm, book-like reader with a refined serif, comfortable measure, and a warm light mode / easy-on-the-eyes dark mode. Keyboard-driven.

## Architecture

```
Aloud/
├── backend/          # Local Python TTS server (FastAPI + Kokoro)
│   ├── app.py            # /health, /voices, /synthesize
│   ├── kokoro_engine.py  # loads the model once, synthesizes WAV
│   ├── voices.py         # voice metadata
│   ├── models/           # kokoro-v1.0.onnx + voices-v1.0.bin (downloaded, git-ignored)
│   └── .venv/            # Python 3.12 virtualenv (git-ignored)
├── frontend/         # Vite + React + TypeScript reader (PDFs)
│   └── src/
│       ├── lib/pdf.ts        # PDF → sentences/paragraphs (pdf.js)
│       ├── lib/player.ts     # buffered audio playback engine
│       ├── lib/api.ts        # talks to the backend
│       ├── store.ts          # app state (zustand)
│       └── components/       # the reader UI
├── extension/        # Chrome extension — reads any web page aloud
└── docs/             # PRD, execution PRD, and the pro-user review
```

One backend, two clients. The **desktop reader** extracts text from a PDF in the browser, splits it into sentences, and asks the local backend to synthesize each one; audio plays sentence-by-sentence with the active sentence highlighted. The **extension** does the same for a live web page, without modifying it.

## Read any web page — the extension

`extension/` is a Manifest V3 Chrome extension that brings the same voice, the same reader-mode extraction and the same word-level highlight to anything you're reading in the browser.

- **It doesn't touch the page.** Instead of wrapping sentences in `<span>`s — which breaks the site's CSS, its framework, and text selection — it builds a parallel offset index over the page's text nodes and paints highlights with the CSS Custom Highlight API.
- **Reader-mode extraction.** A Readability-style scorer finds the article and skips the nav, ads, sidebars, comments, code blocks, footnote markers and citation lists.
- **Click any sentence** to start reading from there. Selection reading and a right-click "Read selection aloud" are both supported.
- **Minimal permissions.** `activeTab` only — the content script is injected when you ask for it, so installing Aloud doesn't grant it every site you visit.

```bash
cd extension
npm install
npm run build     # → extension/dist
```

Then load `extension/dist` at `chrome://extensions` → *Developer mode* → *Load unpacked*. Press <kbd>Alt</kbd>+<kbd>A</kbd> on any article, with the backend running.

See [`extension/README.md`](./extension/README.md) for the full picture.

## Setup

Requires **Python 3.12** (managed via [`uv`](https://github.com/astral-ai/uv)), **Node 18+**, and **espeak-ng** (Kokoro's phonemizer).

```bash
# 1. System dependency for the phonemizer
brew install espeak-ng

# 2. Backend: create the venv and install Python deps
cd backend
uv venv --python 3.12 .venv
uv pip install --python .venv/bin/python -r requirements.txt

# 3. Download the Kokoro model + voices (~340 MB, one time)
python download_models.py     # (run with .venv/bin/python)

# 4. Frontend deps
cd ../frontend
npm install
```

## Run

From the project root, start both servers (see `run.sh`), or run them in two terminals:

```bash
# Terminal 1 — TTS backend (http://localhost:8000)
cd backend && .venv/bin/python run.py

# Terminal 2 — reader UI (http://localhost:5173)
cd frontend && npm run dev
```

Open **http://localhost:5173**, drop in a PDF, and press play.

## Install as a Mac app

Prefer a double-click app over the terminal? Once the [Setup](#setup) is done (venv created, model downloaded, `npm install` run), package Aloud into a native `.app`:

```bash
./build_app.sh
```

This builds the frontend and produces **`Aloud.app`** at the repo root. Then:

1. **(Optional)** Drag `Aloud.app` into `/Applications`.
2. **First launch:** right-click `Aloud.app` → **Open** → **Open**. The app is unsigned, so Gatekeeper asks for this one-time approval. After that, just double-click it like any other app.
3. Launching starts the local TTS backend automatically and opens the reader in a **native window** — no terminal, no `localhost` in a browser tab. Closing the window shuts the backend down.

**Note:** the app is *not* a fully bundled binary. It runs the Python in `backend/.venv` against `backend/native_app.py` using absolute paths baked in at build time, and it reads the model from `backend/models/`. So the repo must stay where it was when you ran `build_app.sh` — if you move it, just re-run `./build_app.sh`.

## Keyboard shortcuts

| Key | Action |
| --- | --- |
| `Space` | Play / pause |
| `→` | Next sentence |
| `←` | Previous sentence |

## Privacy

Everything runs on your machine. The only network access is the one-time voice-model download during setup. Your PDFs are never uploaded anywhere.

## Where it's going

- [`docs/UX-FEEDBACK.md`](./docs/UX-FEEDBACK.md) — a pro-user review of the current build, with measurements.
- [`docs/PRD.md`](./docs/PRD.md) — the product plan it prompted: 1.1 Reliability, 1.5 The Library, 2.0 Mac Citizen.
- [`docs/EXECUTION-PRD-1.1.md`](./docs/EXECUTION-PRD-1.1.md) — the file-level execution plan for release 1.1, including the frozen backend/client interface contract.

## Tech

React · TypeScript · Vite · zustand · pdf.js · FastAPI · Kokoro (ONNX Runtime)
