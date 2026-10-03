# The legacy web app

Aloud began as a web app. The native apps for Mac and iPhone, built from
`ios/`, have replaced it (mac PRD M20). This note says what the web app was,
why it was retired, and what is left of it.

## What it was

Three pieces around one local server:

- **`backend/`**: a Python 3.12 server (FastAPI) that ran Kokoro through
  `kokoro-onnx`, with espeak-ng from Homebrew as its phonemizer. It answered
  `/health`, `/voices` and `/synthesize` on `localhost:8000`, and read the
  model from `backend/models/` (about 340 MB, downloaded by
  `download_models.py`).
- **`frontend/`**: a Vite, React and TypeScript reader for PDFs. pdf.js
  pulled out the text, the page split it into sentences and asked the server
  for each one, and the current sentence was highlighted as it played.
- **`extension/`**: a Manifest V3 Chrome extension that read any web page
  through the same server, highlighting with the CSS Custom Highlight API
  instead of changing the page.

`run.sh` started the server and the reader together. `build_app.sh`, now
`legacy/build_web_app.sh`, wrapped them in a Mac app: `Aloud.app` at the
repo root (bundle id `com.davidxie.aloud`), which opened the reader in a
pywebview window.

## Why it was retired

That `Aloud.app` was not a real app bundle. Its executable was a short shell
script that ran the repo's own `backend/.venv` Python on
`backend/native_app.py`, with absolute paths written in when it was built.
So:

- it worked only on the Mac that built it, and only while the repo stayed
  where it was. Moving the repo, or deleting the venv or the models, broke it;
- it needed the whole developer setup on that Mac: uv, Python 3.12,
  espeak-ng and Node;
- it was unsigned and unsandboxed, so Gatekeeper asked before the first
  launch, and it could read anything your user account can;
- closing the window stopped the server, and the audio with it.

The native app has none of these problems. It is a self-contained, signed,
sandboxed bundle. It shares its reading core with the iPhone app and keeps
reading when the window closes. It has the System voice from the first
launch, and the natural voice works offline once downloaded.

There was nothing to migrate. The web app stored no books: the reader kept
the open PDF in memory, and pywebview's private mode discarded its few
preferences on every quit.

## What stays

The code stays in the repo for reference, and still runs:

- `backend/`, `frontend/` and `extension/` are unchanged. Nothing in `ios/`
  builds from them or calls them.
- `run.sh` still starts the server and the reader. The README's
  [Legacy web app and extension](../README.md#legacy-web-app-and-extension)
  section has the setup and the commands.
- `legacy/build_web_app.sh` still packages the pywebview `Aloud.app` the old
  way, with the same limits.
- The web app's plans and its review stay in `docs/`:
  [PRD.md](./PRD.md), [EXECUTION-PRD-1.1.md](./EXECUTION-PRD-1.1.md) and
  [UX-FEEDBACK.md](./UX-FEEDBACK.md).

These are no longer the main app, and new work goes into `ios/`.

## Cleaning up, when you're ready

None of this happens automatically. Deleting is your call:

- the old `Aloud.app`, at the repo root or wherever you dragged it (for
  example `/Applications`). `./build_app.sh` mentions it if it finds one;
- `backend/models/` (about 340 MB) and `backend/.venv/`, both gitignored.
  You need them again only to run the legacy app.
