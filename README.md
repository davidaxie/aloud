# Aloud

**Offline read-aloud for iPhone and Mac.** Add a PDF or a text file, or pick a public-domain classic, and Aloud reads it to you in a natural neural voice, highlighting each sentence and word as it goes. The voice runs on your device. No accounts, no cloud, no tracking.

## What it does

- **Two voices.** The System voice (Apple's built-in speech) works from the first launch. The natural voice is [Kokoro](https://huggingface.co/hexgrad/Kokoro-82M), an 82M-parameter neural TTS model that runs on the device through sherpa-onnx. It downloads once (353 MB) and then never needs the network.
- **Follow along.** The sentence being read is highlighted, the spoken word is marked inside it, and the page follows the voice. Tap or click any sentence to read from there.
- **A library that remembers.** Each book is copied into Aloud, and the Continue card picks up at the sentence where you stopped. Contents shows chapters (found even in PDFs without bookmarks), a search of the book, and a history of where you stopped.
- **Classics.** A shelf of public-domain books from Project Gutenberg, with search and listening times.
- **For long listening.** Speeds from 0.5x to 3x, a sleep timer, eleven curated voices (eight Kokoro speakers and three of Aloud's own blends), Siri and Shortcuts intents, lock-screen and media-key controls. If your headphones disconnect, Aloud pauses instead of playing through the speakers.
- **Mac app.** A native window with a TextKit 2 book page, full menus, and a keyboard for everything (table below).

## How it works

- **Sentences are the unit of playback.** Text comes out of PDFKit, goes through a normalizer that repairs hyphenation, ligatures and running headers, and is split into sentences. An actor (`SynthesisScheduler`) keeps two queues, "play now" ahead of "look ahead", with exactly one synthesis in flight and an LRU cache of clips keyed by document, voice and speed. An `AVAudioEngine` schedules the clips back to back, so playback has no gaps.
- **Fast starts on long sentences.** Kokoro renders a whole sentence before returning anything, which made a jump into a long sentence silent for several seconds on a phone. `ColdLeadPlan` cuts the sentence at its clause marks into a short lead plus pieces that are made while earlier pieces play, then joins them into one cached clip.
- **Speed without the metallic ring.** Apple's time-pitch unit leaves an audible ring on speech. Aloud splits the speed-up between Kokoro speaking faster itself (`NativeSpeed`, tuned against measured spectra) and its own pitch-synchronous overlap-add stretcher (`SpeechStretcher`, after Bill Cox's Sonic), which blends whole pitch periods in the time domain.
- **Word highlighting without word timestamps.** `WordTimingEstimator` spreads each clip's real duration across its words by estimated syllables plus punctuation pauses, so the marked word tracks the voice at any speed.
- **Blended voices.** A Kokoro voice is a 510 x 256 table of style vectors: half steers timbre, half steers pacing and pitch. `KokoroVoiceBlends` mixes each half of stock speakers on its own weights to make three new voices.
- **Built for a phone.** The model is offered only on devices with enough memory, its download is resumable, Wi-Fi first, and pinned to one Hugging Face revision with a SHA-256 per file. `ThermalGuard` hands reading to the System voice when the phone gets hot and returns when it cools.
- **One core, two apps.** The iPhone and Mac apps share the core in `ios/Aloud/` behind a small platform layer (`ios/Aloud/Platform/`). About 3,000 XCTest and XCUITest methods cover it, including source lints (one of them checks the keyboard table in this README against the Mac's menus).

## Tech stack

Swift 5.9, SwiftUI, AVFoundation, PDFKit, NaturalLanguage, TextKit 2, App Intents, sherpa-onnx (Kokoro, with vendored espeak-ng data), XcodeGen, XCTest. The legacy web app is Python (FastAPI, kokoro-onnx), React with TypeScript and pdf.js, and a Manifest V3 Chrome extension.

## Running locally

Requirements: macOS 14 or later on Apple silicon, Xcode at `/Applications/Xcode.app` (`ios/xcenv.sh` pins it), [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`) and Python 3. The iPhone app needs iOS 17 or later. The Xcode project is generated from `ios/project.yml`; edit the spec, not the project.

**1. Fetch the Classics.** The books aren't in git. `tools/gutenberg_fetch.py` downloads the curated queue in `tools/gutenberg_queue.json` into `books/`, and `ios/sync_bookshelf.sh` copies them into the app (the build scripts run it). Point it at your checkout's `books/` with `ALOUD_BOOKS_SRC`:

```bash
python3 tools/gutenberg_fetch.py --count 60
export ALOUD_BOOKS_SRC="$PWD/books/"
```

**2. Mac app.**

```bash
./build_app.sh             # build the Release app, check it, and print where Aloud.app is
./build_app.sh --install   # the same, then copy it to ~/Applications
```

The build is signed ad hoc for your Mac (so the App Sandbox applies) and isn't notarized. The script checks the bundle id, the sandbox entitlements and the signature, and refuses to install into a synced folder.

**3. iPhone app.**

```bash
cd ios
./build.sh           # sync the Classics, generate the project, build for the Simulator
./build.sh --test    # the same, then run the tests
```

`ios/xcenv.sh` pins the Simulator `build.sh` uses; change `XCB_SIM_ID` to one of yours (`xcrun simctl list devices`). To run on your own iPhone, run `./sync_bookshelf.sh` and `xcodegen generate` in `ios/`, open `ios/Aloud.xcodeproj`, choose the **Aloud** scheme and your iPhone, set your team under *Signing & Capabilities*, and press Run.

`ios/xcb.sh` wraps `xcodebuild` with the pinned toolchain and destinations. For example:

```bash
cd ios
./xcb.sh -project Aloud.xcodeproj -scheme Aloud test -only-testing:AloudTests
./xcb.sh -project Aloud.xcodeproj -scheme AloudMac test
```

**4. The natural voice.** In the app, open **Settings › Voice & speed** and click **Download** (353 MB, once, from Hugging Face). Before a flight, the [airplane check](./docs/mac-airplane-check.md) lists what to try with Wi-Fi off.

## Keyboard shortcuts (Mac)

Every command is also a menu item. The menus, the tooltips and this table come from one source, `ios/AloudMac/Commands/MacShortcuts.swift`, and `ReadmeShortcutsLintTests` fails if this table drifts from it.

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

The table shows each item's title at rest: **Play** reads **Pause** while playing, and in a PDF the chapter commands read **Previous Page** and **Next Page**. Play, pause and the 15-second skips also answer to the media keys, AirPods, Control Center and the Dock menu.

## Privacy

Nothing leaves your device. The one exception is the natural-voice download from Hugging Face, and only when you ask for it: it fetches two files and sends nothing about you or your books. The Mac app is sandboxed, reads only the files you choose, and its one network permission is for that download.

## Repository layout

```
ios/
├── Aloud/            # the shared core, plus the iPhone's own screens
├── AloudMac/         # the Mac's own files (window, menus, reader page)
├── AloudTests/       # unit tests and source lints
├── AloudMacTests/    # Mac-hosted unit tests
├── AloudUITests/     # iPhone UI tests
├── AloudMacUITests/  # Mac UI tests
└── project.yml       # XcodeGen spec
build_app.sh          # the Mac app: build, check, and --install
tools/                # the Gutenberg fetcher and catalog normalizer
docs/                 # the airplane check, the legacy notes, product plans
backend/ frontend/ extension/   # the legacy web app (below)
```

## Legacy web app and Chrome extension

Aloud started as a local web app: a FastAPI server running Kokoro through `kokoro-onnx` (`backend/`), a React reader for PDFs (`frontend/`), and a Chrome extension (`extension/`) that reads any web page through the same server. The extension never edits the page: it builds an offset index over the page's text nodes and paints highlights with the CSS Custom Highlight API, and a Readability-style scorer finds the article. The native apps replaced the web app; [docs/legacy-web-app.md](./docs/legacy-web-app.md) explains why. The code still runs:

```bash
brew install espeak-ng
cd backend && uv venv --python 3.12 .venv && uv pip install --python .venv/bin/python -r requirements.txt
.venv/bin/python download_models.py     # Kokoro model and voices, about 340 MB, once
cd ../frontend && npm install && cd ..
./run.sh                                # server on http://127.0.0.1:8000, reader on http://localhost:5173

cd extension && npm install && npm run build   # then load extension/dist at chrome://extensions
```

## Licenses

Kokoro is Apache-2.0, espeak-ng is GPL-3.0 and onnxruntime is MIT. Their license texts ship in `ios/Aloud/Resources/Licenses/` and `ios/Aloud/Resources/KokoroAssets/`, and the app shows them under Settings › Licenses.
