# Aloud — Pro-User Feedback Review

**Reviewer stance:** a demanding daily listener. I read 2–4 nonfiction books and a dozen papers a month, mostly by ear. I pay for Speechify, I've used Voice Dream and Natural Reader, and I switched to a local tool because I don't want my reading list on someone's server. I care about two things above all: **the audio never stops**, and **the app remembers where I was**.

**Date:** 2026-07-31
**Build:** `8475d6d` (main), macOS 15.5 / Apple M4 Pro / 14 cores
**Tested on:** the packaged `Aloud.app` and the dev build at `localhost:5173`

**Test documents**
| Document | Size | Why |
| --- | --- | --- |
| *Platform Revolution* (Parker/Van Alstyne/Choudary) | 323 pp, 4,946 sentences | The real use case — a full trade nonfiction book |
| *Speech and Language Processing* (Jurafsky & Martin), ch. 2 | 36 pp | Academic PDF with drop caps, dialogue blocks, figures |
| A 4-page slide deck | 4 pp | The "wrong" document a user will inevitably drop in |
| `samples/the-quiet-hour.pdf` | 1 pp | The happy path the app was built against |

---

## Verdict

**Aloud is one good week away from being genuinely excellent, and it is currently unusable for its own core use case.**

The taste on display is real. The typography, the light/dark palettes, the restraint in the chrome — this is the nicest-looking read-aloud app I've used, and I include the paid ones in that. Somebody made deliberate, correct choices about measure, leading, and accent discipline. The word-level karaoke highlight is better than Speechify's.

But I could not listen to a book on it. Playback dies within a minute or two, every time, with a red banner telling me the speech engine is offline while the speech engine is demonstrably running. And even if it hadn't died, closing the window would have thrown away my place in a 4,946-sentence book with no way to get it back.

Those two things — **P0-1** and **P0-2** below — are the whole review. Everything else is commentary.

---

## What is genuinely excellent

I want to be specific about this, because the fixes below shouldn't touch any of it.

- **The reading surface.** Iowan Old Style at a 68ch measure with 1.75 line-height, warm-white and warm-near-black. It reads like a book, not like a web page pretending to be one. The `text-wrap: pretty` and the page rules are thoughtful.
- **The word-level highlight.** Syllable-weighted timing windows distributed across the real WAV duration, with the whole thing isolated to a single memoized `<ActiveSentence>` so a word change re-renders one sentence rather than 4,946. That's the right architecture and it shows — no jank at all while a word ticks along.
- **Auto-scroll that yields.** It backs off for 1.8s after a wheel event. I scrolled ahead to check something, and it let me. Measured: scrollTop 150 → 1650 and it stayed there. Most apps get this wrong.
- **PDF parsing speed.** 323 pages parsed in **1.06 seconds**, in-browser. I expected 15.
- **Text reconstruction quality.** De-hyphenation, running-header detection, cross-page paragraph stitching, NFKC folding, ligature repair. On body prose the extracted text is clean enough that I never noticed an artifact while listening.
- **Offline is real.** No accounts, no telemetry, no network after setup. This is the reason I'd choose it.

---

## P0 — Blockers

### P0-1. Playback fails constantly because the TTS backend is not thread-safe

**This is the bug. Everything else is cosmetic next to it.**

The player fires three concurrent `/synthesize` requests (current sentence + `LOOKAHEAD = 2`). FastAPI runs the sync `synthesize` endpoint in a threadpool, so all three land in `kokoro.create()` simultaneously. espeak-ng — the phonemizer underneath — keeps global state and is not thread-safe. The calls corrupt each other.

Measured, against the running backend, with distinct real sentences from the book:

| In-flight requests | Failure rate |
| --- | --- |
| 1 (sequential) | **0 / 12** |
| 3 (the app's own default) | **5 / 12 — 42%** |
| 6 (what scrubbing produces) | **12 / 24 — 50%** |

Every failure is the same phonemizer race:

```
HTTP 500 {"error":"synthesis failed: number of lines in input and output
          must be equal, we have: input=1, output=45"}
```

What this looks like from the couch: I clicked into the book at 15%, and **on the very first seek** playback stopped and I got a red banner reading *"Speech engine offline — is the backend running?"* The backend was running fine. It had answered a `/health` check one second earlier.

Two things make this worse than it needs to be:

1. **No retry.** `synthesize()` in `lib/api.ts` has no timeout and no retry. One 500 → `handleSynthError()` → `wantPlaying = false`, status `error`, playback over. A transient race becomes a full stop.
2. **The error message is wrong and it scares people.** "Is the backend running?" sends the user to check a server that is healthy. The real answer is "we asked it to do three things at once and it isn't allowed to."

**Fix:** serialize synthesis behind a lock (or run a single worker). One request at a time already achieves **~7× real-time** on this machine — 12 real sentences in 14.2s sequential — which is far more headroom than the player needs. Then add a bounded retry (2 attempts, ~250ms backoff) and *never* stop playback on a single sentence's failure — skip it, mark it, keep going.

---

### P0-2. The app forgets everything the moment you close it

`store.ts` persists exactly five things: `theme`, `voiceId`, `rate`, `skipSkippable`, `autoScroll`. The document, the position, and the file itself are all in memory only. Closing the window (which also kills the backend) discards them.

So: I get 90 minutes into a 323-page book, close the laptop lid for the night, and tomorrow I re-open the app to an empty dropzone. I have to find the PDF in Finder again, re-drop it, wait, and then hunt for sentence 1,847 of 4,946 by dragging a progress bar with no chapter labels and no text preview.

Nobody finishes a book this way. This single gap turns a book reader into a page reader.

There's a smaller sibling: the **"New" button discards the open document instantly with no confirmation.** One stray click at hour three and it's gone.

**Fix:** a document library. Persist parsed docs in IndexedDB keyed by content hash, with last position, last-opened time, and progress. Show recents on the empty state. Resume on open. Make "New" additive rather than destructive.

---

### P0-3. Keyboard transport dies the moment you click a sentence

Clicking a sentence to jump there is the app's signature interaction. Doing it breaks the keyboard.

Measured: focus a sentence span, press `Space` → status `paused` → `paused`. Press `→` → position `3 / 4946` → `3 / 4946`. Nothing happens.

The cause is in `useKeyboard.ts`. `isSelfHandlingControl()` bails out on anything matching `[role="button"]`, on the reasonable theory that a focused button handles its own Space. But the sentence spans in `Reader.tsx` carry `role="button"` and `tabIndex={0}`, and their `onKeyDown` only handles `Enter`. So the global handler stands down for a control that then does nothing.

The result is that the two headline shortcuts advertised in the header — the ones printed in that permanent `Space play · ← → sentence` hint — silently stop working after the most common click in the app, and there's no feedback explaining why. I assumed the app had frozen.

**Fix:** exclude the reader's sentence spans from the self-handling check (a `data-transport-passthrough` attribute, or drop `role="button"` in favour of a proper focusable element that handles Space/Arrows itself).

---

## P1 — Things that make it feel unfinished

### P1-1. Seven and a half seconds of silence when you press Play

Measured cold, on a freshly loaded book: **7,453ms from clicking Play to `status === "playing"`.** A spinner, and nothing else, for seven and a half seconds. I pressed it twice the first time because I assumed the click hadn't registered.

Two contributing causes, both fixable:

- **No model warm-up.** The first inference after load costs ~4.1s (ORT graph warm-up / weight paging); every subsequent one is ~0.87s. Nothing runs a throwaway inference at startup.
- **No request prioritization.** Play fires the sentence you're waiting for *and* two prefetches simultaneously. Under 3-way concurrency the request you actually need slows from 0.92s to ~1.47s — a 60% tax paid by the user, to speculatively fetch audio for a sentence they may never reach.

**Fix:** synthesize a short warm-up phrase on startup; give the current sentence strict priority over lookahead; and show elapsed feedback if the wait exceeds ~1.5s rather than an undifferentiated spinner.

### P1-2. The buffer is measured in sentences, not seconds

`LOOKAHEAD = 2` means the buffer depth depends on how long the next two sentences happen to be. Across this book: median sentence 134 chars, but **396 sentences (8%) are under 40 characters** — headings, list markers, "Check.", fragments. Those synthesize to 1–2s of audio.

At 1× that's survivable. At 2.5×, a 2-second clip gives you 0.8s of playback to cover a ~1s synthesis, so any run of short sentences guarantees a stall. I measured a 40-second listening window at each speed:

| Speed | Stalls | Time spent buffering |
| --- | --- | --- |
| 1.0× | 2 | 16.0s of 40s (**41%**) |
| 2.5× | 4 | 26.8s of 40s (**69%**) |

Some of that is P0-1 bleeding through, but the structural point stands independently: **buffer depth should be expressed in seconds of audio ahead (target 45–60s), not sentences,** and the pipeline should keep filling during idle time instead of only topping up when a sentence starts. Right now it can never get more than two sentences ahead no matter how much idle CPU is available.

### P1-3. The voice picker opens on Chinese

54 voices. The list is grouped by language and sorted alphabetically by language name, so it opens on **CHINESE** — eight Chinese voices — and an English reader with an English book has to scroll past them. The currently-selected voice isn't scrolled into view. Total content is 2,060px in a 380px viewport: **5.4 screens of scrolling** to browse.

Compounding it:

- **No preview.** The only way to hear a voice is to select it, which restarts the current sentence. Auditioning 54 voices means 54 sentence restarts.
- **The names are meaningless.** "Heart", "Xiaobei", "Yunjian", "Fable", "Alice". Nothing tells me which one is good for a 300-page business book at 2×.
- **Search doesn't match how people think.** Typing `brit` returns **0 results** — the label is "UK". `calm`, `deep`, `warm`, `news` all return nothing. There are no descriptive attributes to search.

**Fix:** put the document's language first and the current voice at the top; add an inline ▶ audition button per row that plays a cached 3-second sample without touching playback state; add searchable descriptors (British, warm, bright, narration); collapse languages the user has never selected.

### P1-4. Position is reported in sentence numbers

The player says `1201 / 4946 · p.82`. I have never once in my life wanted to know that I am on sentence 1,201.

Missing, and expected by anyone coming from Speechify or Audible:

- **Time remaining** — in the chapter and in the book, adjusted for playback rate. This is trivially computable: sentence character counts × measured chars-per-second.
- **Chapter / section awareness.** A 323-page book has no table of contents in this app. To reach chapter 6 I drag a 1,280px bar across 4,946 sentences — **3.9 sentences per pixel** — with no labels and no text preview under the cursor.
- **Percentage complete.**

### P1-5. Front matter is read as if it were the book

Press Play on *Platform Revolution* and the first things you hear are: "PLATFORM." "REVOLUTION." "HOW NETWORKED MARKETS ARE TRANSFORMING THE ECONOMY — AND HOW TO MAKE THEM WORK FOR YOU." "Geoffrey G. Parker, Marshall W. Van Alstyne, and Sangeet Paul Choudary." "To the memory of my mother, Mary Lynn Goodrich Parker."

Then the table of contents, flattened into one unbroken run-on:

> "PREFACE 1. TODAY: Welcome to the Platform Revolution 2. NETWORK EFFECTS: The Power of the Platform 3. ARCHITECTURE: Principles for Designing a Successful Platform 4. DISRUPTION: How Platforms Conquer and Transform…"

That's ninety seconds of noise before the book starts, and no way to skip it except manual hunting. Detect front matter (copyright, dedication, ToC) and offer **"Start at Chapter 1"** as the default.

### P1-6. Tables become gibberish

The longest "sentence" in the book is:

> "Angie's List Logistics and Munchery, Foodpanda, Haier Group Delivery Media Medium, Viki, YouTube, Wikipedia, Huffington Post, Kindle Publishing Operating Systems iOS, Android, MacOS…"

That's a two-dimensional table read left-to-right as prose. 275 sentences in this book exceed 300 characters, and a good share of them are flattened tables and figure labels. They should be detected and either skipped or announced as *"Table — skipped."*

### P1-7. A slide deck produces a reader containing one arrow

Dropping a 4-page deck yields: **"4 pages · 1 sentences"**, and the single extracted sentence is `→`.

The error path only triggers when zero sentences are found (`'No readable text found…'`). One junk sentence counts as success, so the user gets a working-looking reader containing an arrow, and a player showing `1 / 1`. There's no "this looks like a scanned document or a slide deck" warning and no OCR fallback.

Add a plausibility check — sentences per page, average length, alphabetic ratio — and warn when a document parses to near-nothing.

---

## P2 — Polish, in a UI that otherwise earns high standards

### The multi-line sentence highlight is ragged
`box-decoration-break: clone` gives each wrapped line its own rounded box, so a three-line sentence renders as three separate lozenges with mismatched right edges and visible gaps between lines. On a page this typographically careful it's the one thing that looks broken. A padded inline-highlight technique or a single SVG/`::highlight()` region would fix it.

### The error banner never clears
`setError(null)` is only called in `player.load()`. Once a synthesis error fires, the red *"Speech engine offline"* banner stays up forever — through recovery, through successful playback, until manually dismissed. I have a screenshot of the app happily playing audio with a red offline banner above it. Clear the error on the next successful synthesis.

### Two banners say the same thing at once
When the backend really is down, `StatusBadge` (amber, "Speech engine offline. Reading works, but audio needs the local Aloud server running.") and `ErrorBanner` (red, "Speech engine offline — is the backend running?") both render, stacked, eating 80px of reading area. Pick one.

### The speed slider is a 104-pixel toy
`min=0.5 max=3 step=0.05` across **104px** — 50 steps over 104 pixels, roughly **2 pixels per step**. Hitting exactly 1.5× or 2× by dragging is luck. Meanwhile `globals.css` still carries fully-styled `.popover--rate`, `.rate-presets`, and `.rate-preset` rules for a preset UI that no component renders any more — dead code from a better design. Bring the presets back: 1×, 1.25×, 1.5×, 1.75×, 2×, 2.5×, 3× as tap targets, with the slider for fine adjustment.

### The scrub bar ignores standard slider keys
It's `role="slider"`, so a keyboard user reasonably expects `Home`/`End`/`PageUp`/`PageDown`. Measured: `End` and `PageDown` do nothing; only `←`/`→` work, moving **one sentence** at a time. On a 4,946-sentence book, arrow-stepping the scrub bar is not a navigation method.

### The keyboard hint is permanent chrome
`Space play · ← → sentence` sits in the header forever. I learned it in five seconds; it decorates my screen for the next three hundred hours. Fade it after first use, or move it into a `?` overlay.

### Changing voice restarts the sentence
Measured: mid-sentence at word "G.", switch voice, and playback resumes from the sentence's first word. Correct behaviour would be to resynthesize and resume at the equivalent time offset — the per-word timing windows needed to do that already exist.

### Page rules interrupt the flow
`— PAGE 5 —` rules appear every few paragraphs. In a reflowed reading view, PDF page boundaries are an implementation detail, not a reading landmark. They should be off by default, or replaced with chapter markers.

### Narrow-window layout inverts
Below 720px the player stacks title *under* the transport controls and grows to ~200px tall, taking a quarter of the reading area on a small window. The reader also clips abruptly at the player edge with no fade mask.

---

## Packaging / platform

### Two backends can bind port 8000 simultaneously
`native_app.py:choose_port()` tests `_port_is_free(8000)` by binding `127.0.0.1:8000` with `SO_REUSEADDR`. If a dev server already holds `0.0.0.0:8000`, that bind **succeeds** on macOS, so the check reports "free" and the app starts a second server on the same port. Verified:

```
Python  49074   TCP *:8000 (LISTEN)            # run.sh backend
Python  49122   TCP 127.0.0.1:8000 (LISTEN)    # Aloud.app backend
```

Two processes, two 325MB model loads, ~1GB of RAM, and requests non-deterministically routed to one of them. Probe `/health` over HTTP before deciding a port is free.

### Missing macOS citizenship
No **Now Playing / media key** integration (`navigator.mediaSession` is not used anywhere) — I can't pause from my headphones or the Touch Bar, and Aloud doesn't appear in Control Centre. No sleep timer. No window-size persistence. No "Open Recent" menu. No Services/Share-sheet entry to send a PDF to Aloud from Preview. For an app whose entire premise is long-form listening on a Mac, these are the table stakes.

### PDF only
No EPUB, no plain text, no `.docx`, no web article, no clipboard paste. A `extension/` directory exists but is untracked and unreferenced. Half my listening queue is EPUB and web articles.

---

## Measurements appendix

| Metric | Value |
| --- | --- |
| PDF parse, 323 pages | 1,060 ms |
| DOM nodes for 4,946 sentences | 6,067 |
| Reader scroll height | 400,541 px |
| JS heap after load | 16 MB used / 53 MB total |
| Kokoro model load | 0.29 s |
| Synthesis, first inference | 4.11 s |
| Synthesis, warm sequential | 0.87 s for 6.27 s audio (**7.2× real-time**) |
| Synthesis, 3 concurrent | 1.47–1.52 s each |
| Synthesis, 5 concurrent | 2.24–2.49 s each |
| **Failure rate, 1 concurrent** | **0 / 12** |
| **Failure rate, 3 concurrent** | **5 / 12** |
| **Failure rate, 6 concurrent** | **12 / 24** |
| Time from Play to audio (cold) | 7,453 ms |
| Prev-sentence latency (LRU hit) | 117–124 ms |
| Buffering share of 40s window @1× | 41% |
| Buffering share of 40s window @2.5× | 69% |
| ONNX providers available | CoreML, Azure, CPU |
| ONNX provider in use | **CPU only** |

A note on that last row: CoreML is available and unused. Worth an experiment — though with serialized synthesis already at 7× real-time, correctness matters far more than more speed.

---

## If I could only have four things

1. **Serialize synthesis, retry twice, never stop playback on one bad sentence.** (P0-1)
2. **Remember my book and my place.** (P0-2)
3. **Keep the keyboard alive after I click a sentence.** (P0-3)
4. **Tell me how much time is left, and let me jump to a chapter.** (P1-4, P1-5)

Do those four and I will use this every day and stop paying for Speechify. The rest of the list is what would make me tell other people about it.
