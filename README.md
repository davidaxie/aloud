# Aloud

**Offline read-aloud for Mac and iPhone.** Add a PDF or a text file, or pick
one of 442 bundled classics, and Aloud reads it to you, highlighting each
sentence as it goes. Everything runs on your device. The System voice works
from the first launch. The natural voice, Kokoro, works offline once you've
downloaded it (353 MB, once).

No accounts, no cloud and no tracking. Your books never leave your device.

---

## What it does

- **Two voices.** The **System voice** is Apple's built-in speech, always
  there and always offline. The **natural voice** is
  [Kokoro](https://huggingface.co/hexgrad/Kokoro-82M), an 82M-parameter neural
  voice that runs on the device through sherpa-onnx, with eight curated
  speakers. It downloads once, then never needs the network again.
- **Follow along.** The sentence being read is highlighted and the page
  follows the voice. Click a sentence (tap it on the iPhone) to read from
  there.
- **A library that remembers.** Each book is copied into Aloud, so it still
  opens when the original moves or you're offline. The Continue card picks
  up at the sentence where you stopped.
- **Classics.** 442 public-domain books from Project Gutenberg ship inside
  the app, with search and listening times.
- **For long listening.** Speeds from 0.5× to 3×, a sleep timer, and
  Contents with a search of the book. On the Mac you can drive everything
  from the keyboard.
- **Made for headphones and planes.** If your headphones disconnect, Aloud
  pauses instead of playing through the speakers. It never needs a network
  to read.

## Requirements

- **Mac:** macOS 14 or later, on Apple silicon.
- **iPhone:** iOS 17 or later.
- **To build:** Xcode at `/Applications/Xcode.app` (`ios/xcenv.sh` pins it)
  and [XcodeGen](https://github.com/yonaskolb/XcodeGen)
  (`brew install xcodegen`). The Xcode project is generated from
  `ios/project.yml`; edit the spec, not the project.

## Build and install

### Mac

```bash
./build_app.sh             # build, check, and print where Aloud.app is
./build_app.sh --install   # the same, then copy it to ~/Applications
```

`build_app.sh` builds the `AloudMac` scheme in Release through `ios/xcb.sh`.
It then checks the result: the shipping bundle id
(`com.davidxie.Aloud.mac`), no test hooks in the binary, the App Sandbox
with no temporary exception, no debugger entitlement (get-task-allow), and
a signature that verifies. It never launches the app. Open Aloud yourself
from Finder or Spotlight.

- **Where it installs:** `--install` copies the app to `~/Applications`.
  That needs no administrator, unlike `/Applications`. It never installs
  into this repo, because the repo lives in OneDrive and codesign rejects
  the extended attributes OneDrive puts on synced files. For the same
  reason, the build's derived data stays in
  `~/Library/Developer/Xcode/DerivedData/Aloud-mac`.
- **Signing:** the app is signed ad hoc for this Mac, so the sandbox
  applies. It isn't notarized, so Gatekeeper on another Mac would refuse a
  copy. Build it on that Mac instead.
- **For development:** the Debug build is **Aloud Dev**
  (`com.davidxie.Aloud.mac.dev`), with its own container. It starts muted
  outside Xcode. Run the Mac tests with
  `cd ios && ./xcb.sh -project Aloud.xcodeproj -scheme AloudMac test`.
  They are hosted, windowless and silent.

### iPhone

```bash
cd ios
./build.sh           # sync the Classics, generate the project, build for the simulator
./build.sh --test    # the same, then run the tests
```

To put it on your own iPhone, run `./sync_bookshelf.sh` and
`xcodegen generate` in `ios/`, open `ios/Aloud.xcodeproj` in Xcode, choose the **Aloud** scheme and your
iPhone, set your team under *Signing & Capabilities*, and press Run.

`ios/xcb.sh` wraps `xcodebuild`. It takes the toolchain and the pinned
simulator from `ios/xcenv.sh`, writes the full log to a temporary file and
prints its path, and adds the right destination and derived-data path for
each scheme. It refuses an unsigned Mac build. Use it instead of calling
`xcodebuild` directly, from `ios/`. For example:

```bash
cd ios
./xcb.sh -project Aloud.xcodeproj -scheme Aloud test -only-testing:AloudTests
```

### The Classics

The 442 classics aren't in git. `ios/sync_bookshelf.sh` copies them from
the main checkout's `books/` folder into `ios/Aloud/Resources/Bookshelf`
when either build script runs. `tools/gutenberg_fetch.py` fills `books/`
from Project Gutenberg.

## First run

1. Aloud opens to an empty Library with one featured classic. One click (or
   tap) adds it and starts reading in the System voice.
2. **More classics** opens the shelf. **Add a file** (⌘O on the Mac) adds a
   PDF or a text file. On the Mac you can also drop files on the window or
   the Dock icon, or use Finder's *Open With*.
3. For the natural voice, go to **Aloud › Settings… (⌘,) › Voice & speed**
   on the Mac, or **Settings › Voice & speed** from the Library on the
   iPhone. Click **Download**: 353 MB, once, from Hugging Face. Aloud also
   offers it after you've listened for a minute.

Quitting keeps your place. On the Mac, closing the window keeps the book
playing, and a click on the Dock icon brings the window back.

## Keyboard shortcuts (Mac)

Every command here is also a menu item, and the buttons' tooltips name
their keys. The menus, the tooltips and this table all come from one
source, `ios/AloudMac/Commands/MacShortcuts.swift`, and a lint
(`ReadmeShortcutsLintTests`) fails if this table drifts from it.

<!-- shortcuts:begin (checked against MacShortcuts.swift; keep the columns and the order) -->
| Keys | Command | Menu |
|---|---|---|
| `Space` | Play | Playback |
| `←` | Back 15 Seconds | Playback |
| `→` | Forward 15 Seconds | Playback |
| `⌘←` | Previous Chapter | Playback |
| `⌘→` | Next Chapter | Playback |
| `⌘J` | Follow the Voice | Playback |
| `]` | Faster | Playback |
| `[` | Slower | Playback |
| `⌘Z` | Undo Jump | Edit |
| `⌘F` | Find… | Edit |
| `⌘⌫` | Delete Book… | Edit |
| `⌃⌘S` | Show Contents | View |
| `⌘+` | Make Text Bigger | View |
| `⌘-` | Make Text Smaller | View |
| `⌘[` | Back | View |
| `⌘O` | Add from Files… | File |
| `⇧⌘O` | Add a Classic… | File |
| `⌘W` | Close | File |
| `⌘,` | Settings… | Aloud |
| `⌃⌘F` | Enter Full Screen | View |
| `⌘M` | Minimize | Window |
| `⌘H` | Hide Aloud | Aloud |
| `⌘Q` | Quit Aloud | Aloud |
<!-- shortcuts:end -->

- The table shows each menu item's title at rest. **Play** reads **Pause**
  while playing, **Try Again** after an error and **Listen Again** at the
  end of the book. **Show Contents** reads **Hide Contents** while the
  Contents panel is open. In a PDF, the chapter commands read **Previous
  Page** and **Next Page**.
- Space, ←, →, `[` and `]` work anywhere in the window unless the control
  with the focus uses the key itself: a text field types it, a focused
  button presses on Space, and a slider takes the arrows. For that reason
  the menus don't show them beside their items; the tooltips do.
- ⌘V (Edit › Paste) in the Library adds what you copied, with or without a
  focused control: a PDF or text file copied in Finder, or copied text,
  which becomes a book titled from its first line. In a search field it
  pastes into the field.
- Play/pause and the 15-second skips also answer to the media keys (F7, F8
  and F9), AirPods, Control Center and the Dock menu.

## Privacy

Nothing leaves your device. The one exception is the natural-voice download
from Hugging Face, and only when you ask for it. It fetches two files
(`model.onnx` and `voices.bin`) and sends nothing about you or your books.

- Books are copied into Aloud's own container and read there.
- There are no accounts, analytics, ads or notifications.
- The Mac app is sandboxed. It can read only the files you choose, and its
  one network permission is for that download.

## On a plane

Download the natural voice before you board. Then follow the
[airplane check](./docs/mac-airplane-check.md): what to try with Wi-Fi off,
what each honest pause looks like, and the launch, first-audio and battery
budgets to measure.

## Repository layout

```
ios/
├── Aloud/            # the shared core, plus the iPhone's own screens
├── AloudMac/         # the Mac's own files (window, menus, reader page)
├── AloudTests/       # unit tests and source lints (iOS suite)
├── AloudMacTests/    # Mac-hosted unit tests
├── AloudUITests/     # iPhone UI tests
├── AloudMacUITests/  # Mac UI tests
├── project.yml       # XcodeGen spec, the source of truth for Aloud.xcodeproj
├── build.sh          # iPhone: sync, generate, build (and --test)
├── xcb.sh, xcenv.sh  # the xcodebuild wrapper and its pinned environment
└── sync_bookshelf.sh # books/ → the bundled Classics
build_app.sh          # the Mac app: build, check, and --install
docs/                 # the airplane check, the legacy notes, the old plans
tools/                # the Gutenberg fetcher and catalog normalizer
legacy/               # the legacy web app's packager
backend/ frontend/ extension/   # the legacy web app (below)
```

## Legacy web app and extension

Before the native apps, Aloud was a local web app: a Python TTS server
(`backend/`), a browser reader for PDFs (`frontend/`), and a Chrome
extension (`extension/`) that read web pages through the same server. **It
is no longer the main app.** [docs/legacy-web-app.md](./docs/legacy-web-app.md)
explains why. The code stays for reference and still runs.

### Setup

It needs Python 3.12 (through [uv](https://github.com/astral-sh/uv)), Node 18
or later, and espeak-ng.

```bash
brew install espeak-ng
cd backend
uv venv --python 3.12 .venv
uv pip install --python .venv/bin/python -r requirements.txt
.venv/bin/python download_models.py   # the Kokoro model and voices, about 340 MB, once
cd ../frontend && npm install
```

`requirements.txt` applies `backend/constraints.txt`, which pins every
package the server installs, including the ones its direct requirements pull
in, to the versions its tests ran against.

The server offers every Kokoro voice except the Japanese ones. It turns text
into sounds with espeak-ng, which can't read kanji and spells each one out as
the English words "Chinese letter", so a Japanese voice spoke gibberish. They
stay hidden until the server gets a Japanese pronunciation library (such as
misaki[ja] or pyopenjtalk), which it doesn't have yet.

### Run

```bash
./run.sh   # the server on http://127.0.0.1:8000 and the reader on http://localhost:5173
```

Open http://localhost:5173 and drop in a PDF. `./run.sh` stops both on
Ctrl-C. If port 8000 is taken, `ALOUD_PORT=8001 ./run.sh` moves the server,
and the reader follows it. If port 5173 is taken, `./run.sh` stops and says
so rather than moving the reader elsewhere; `ALOUD_UI_PORT=5174 ./run.sh`
moves it, and the address it prints follows.

The server listens on this Mac only. To reach it from a phone or another
computer on your network, opt in with `ALOUD_HOST=0.0.0.0` and list every
name the other device uses for this Mac in `ALOUD_ALLOWED_HOSTS`. These are
added to `localhost` and `127.0.0.1`, which this Mac keeps using, for example
`ALOUD_HOST=0.0.0.0 ALOUD_ALLOWED_HOSTS=my-mac.local ./run.sh`.
Requests with any other Host name are refused. The server has no login, so do
this only on a network you trust.

The reader on port 5173 (or `ALOUD_UI_PORT`) only works on this Mac. For the other device, build
the reader once with `cd frontend && npm run build`. The server then serves it
itself, so open http://my-mac.local:8000 on the phone. No other setting is
needed. The extension only talks to a server on its own computer: its
*Local TTS server* accepts only `127.0.0.1`, `localhost` or `[::1]`, so the
text of the pages it reads never leaves that computer. To use it on another
computer, run the server there too. Any other page that calls the server from
its own origin needs that origin in `ALOUD_CORS_ORIGINS`.

### The extension

```bash
cd extension && npm install && npm run build   # → extension/dist
```

In Chrome, open `chrome://extensions`, turn on *Developer mode*, choose
*Load unpacked* and pick `extension/dist`. With the server running, press
<kbd>Alt</kbd>+<kbd>A</kbd> on any article.

`legacy/build_web_app.sh` still packages the old pywebview `Aloud.app`, with
the limits that retired it.
