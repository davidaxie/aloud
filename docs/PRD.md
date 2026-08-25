# Aloud — Product Requirements Document

**Version:** 1.0 (draft)
**Date:** 2026-07-31
**Status:** proposed
**Companion doc:** [`UX-FEEDBACK.md`](./UX-FEEDBACK.md) — the pro-user review this PRD responds to
**Current build reviewed:** `8475d6d`

---

## 1. Vision

**Aloud is the reading app for people who read by ear and refuse to hand their library to a cloud.**

Everything runs on the machine. Nothing is uploaded, nothing is logged, nothing needs an account. The bar isn't "as good as a cloud TTS app, given the constraints" — it's *better*, because a local model has no per-character billing, no rate limits, and no network latency, and because a private library can afford to be an actual library.

The reading surface should feel like a well-set book, and the audio should behave like a well-mastered audiobook: it starts fast, it never stutters, and it picks up exactly where it left off.

### Positioning

| | Speechify / Natural Reader | macOS "Speak Screen" | **Aloud** |
| --- | --- | --- | --- |
| Voice quality | Excellent | Poor | Excellent (Kokoro, 82M neural) |
| Privacy | Documents uploaded | Local | **Local, no account, no network** |
| Cost | $139/yr | Free | **Free** |
| Reading UI | Cluttered | None | **Book-quality typography** |
| Long-form fit | Good | None | **Target** |

### The one-sentence test

> *"I dropped a 300-page book in on Monday, listened on and off all week at 1.75×, and it never once dropped a sentence or lost my place."*

Version 2.0 ships when that sentence is true.

---

## 2. Target user

**Primary — "the ear reader."** Consumes 2–4 nonfiction books and 10+ papers a month, mostly listening while commuting, walking, or doing chores. Listens at 1.5–2.5×. Comes from Speechify or Voice Dream and is leaving over privacy or cost. Has strong opinions about typography and will notice a ragged highlight.

**Secondary — "the researcher."** Papers, reports, and long PDFs. Needs correct handling of two-column layouts, figures, footnotes, and tables. Wants to skip the references section.

**Secondary — "the accessibility user."** Dyslexia, low vision, or reading fatigue. Depends on the karaoke highlight and on full keyboard and screen-reader operability. For this user, the P0-3 keyboard bug is not an annoyance; it is a lockout.

**Explicitly not the target:** casual users wanting to hear one page; anyone needing voice cloning, dubbing, or multi-speaker narration.

---

## 3. Goals and success metrics

| # | Goal | Metric | Current | Target |
| --- | --- | --- | --- | --- |
| G1 | Audio never stops unexpectedly | Synthesis failure rate at the app's own concurrency | **42%** | **< 0.1%** |
| G2 | Playback is gap-free | Share of listening time spent buffering, 40-min session @2× | **41–69%** | **< 0.5%** |
| G3 | Play feels instant | p50 / p95 time from Play to audio | 7.4 s | **< 400 ms / < 1.2 s** |
| G4 | Books get finished | Share of opened books reaching 80% | n/a (impossible) | **> 40%** |
| G5 | Returning is frictionless | Time from app launch to resumed audio | ∞ (no resume) | **< 3 s, zero clicks beyond Play** |
| G6 | Fully keyboard-operable | Transport shortcuts working from every focus state | fails after sentence click | **100%** |

---

## 4. Release plan

Three releases. **1.1 is not optional and nothing else ships before it.**

| Release | Theme | Ships |
| --- | --- | --- |
| **1.1 — Reliability** | Make the core promise true | F1–F4 |
| **1.5 — The Library** | Make it a place you keep books | F5–F9 |
| **2.0 — Mac Citizen** | Make it belong on the machine | F10–F15 |

---

## 5. Release 1.1 — Reliability

> *Nothing in this release adds a feature. It makes the existing ones work.*

### F1 — Serialized, resilient synthesis  · **P0**

**Problem.** Concurrent calls into espeak-ng corrupt each other's global state. At the player's default 3-way concurrency, 42% of requests fail with `number of lines in input and output must be equal`. One failure ends playback and shows a false "backend offline" error.

**Requirements**

- **F1.1** Backend serializes all synthesis behind a process-wide lock. Only one `kokoro.create()` call is in flight at any moment.
- **F1.2** Requests queue rather than fail. Queue depth is bounded (default 8); overflow returns `429` with `Retry-After`, never a 500.
- **F1.3** `/synthesize` accepts an optional `priority` field (`now` | `prefetch`). The queue is a priority queue: a `now` request preempts queued `prefetch` work.
- **F1.4** Client retries a failed synthesis up to 2 times with 250ms/750ms backoff before surfacing anything to the user.
- **F1.5** A sentence that fails all retries is **skipped, not fatal.** Playback advances; the sentence is marked in the reader with a small inline "couldn't read this" affordance; playback state stays `playing`.
- **F1.6** Client sets a 30s request timeout. Timeouts count as retryable failures.
- **F1.7** Error copy distinguishes causes. "Backend offline" appears only when `/health` actually fails. Synthesis failures say what they are.
- **F1.8** Backend logs every 4xx/5xx with the offending text and voice at WARNING.

**Acceptance**

- 500 sentences of *Platform Revolution* synthesized through the live player: **zero user-visible errors, zero unplanned stops.**
- Loopback load test at 1/3/6 concurrent clients: **0% 5xx** at every level.
- Chaos test — backend injects a 30% forced failure rate — playback completes 100 sentences with no stop and ≤ 30 skip markers.
- Sequential throughput stays ≥ 5× real-time on an M-series Mac.

---

### F2 — Time-based buffering with warm start  · **P0**

**Problem.** Buffer depth is `LOOKAHEAD = 2` *sentences*, which is 1–2 seconds of audio when the next two sentences are short — and 8% of this book's sentences are under 40 characters. Cold start costs 7.4s of undifferentiated spinner.

**Requirements**

- **F2.1** Buffer target is expressed in **seconds of audio ahead**, not sentence count. Default 60s; floor 3 sentences regardless.
- **F2.2** Target scales with playback rate: at 2×, 60s of listening needs 120s of source audio.
- **F2.3** The pipeline continues filling toward the target during idle time, not only when a sentence begins.
- **F2.4** The current sentence always takes strict priority over prefetch (see F1.3).
- **F2.5** Backend performs a warm-up inference at startup, before `/health` reports `ok`, so the first user-facing synthesis is never the cold one.
- **F2.6** Cache is bounded by **total decoded bytes** (default 256MB) as well as entry count, so long clips can't blow memory.
- **F2.7** Buffer state is visible: a subtle secondary fill on the scrub bar showing how far ahead audio is ready.
- **F2.8** If audio isn't ready within 800ms, show a progress affordance with elapsed feedback — never a bare indeterminate spinner.

**Acceptance**

- p50 Play-to-audio **< 400 ms**, p95 **< 1.2 s**, cold app.
- 40-minute continuous session at 2.5× on *Platform Revolution*: **< 0.5%** of wall time in `buffering`, **zero** stalls longer than 500 ms.
- Buffer stays ≥ 45s ahead through a 200-sentence run containing at least 20 sentences under 40 characters.
- Peak process RSS stays under 1.5 GB across a full book.

---

### F3 — Keyboard transport that never dies  · **P0**

**Problem.** `isSelfHandlingControl()` suppresses global shortcuts for anything with `role="button"`, including the reader's sentence spans — whose own `onKeyDown` handles only `Enter`. After clicking a sentence, `Space`, `←`, and `→` all silently stop working.

**Requirements**

- **F3.1** Transport shortcuts work from every focus state except a genuine text input.
- **F3.2** Reader sentences are focusable and handle `Enter`/`Space` (jump here) and arrows (transport) themselves, or opt out of the suppression list explicitly.
- **F3.3** Full shortcut set, all working from the reader:

  | Key | Action |
  | --- | --- |
  | `Space` | Play / pause |
  | `←` `→` | Previous / next sentence |
  | `↑` `↓` | Previous / next paragraph |
  | `⇧←` `⇧→` | Back / forward 30 seconds |
  | `[` `]` | Speed down / up one preset |
  | `⌘←` `⌘→` | Previous / next chapter |
  | `J` `K` `L` | Back 10s / play-pause / forward 10s |
  | `B` | Toggle bookmark at current sentence |
  | `?` | Shortcut overlay |
  | `⌘F` | Find in document |
  | `Esc` | Close popover / overlay |

- **F3.4** Scrub bar (`role="slider"`) implements `Home`, `End`, `PageUp`, `PageDown` (±1% of document) in addition to arrows.
- **F3.5** Every shortcut is discoverable from the `?` overlay. The permanent header hint is removed after the user's third session.
- **F3.6** Visible focus rings on all interactive elements; logical tab order; popovers trap focus and restore it on close.

**Acceptance**

- Automated matrix: every shortcut fires correctly from each of {body, sentence span, play button, scrub bar, voice chip, options chip}. **Zero dead combinations.**
- Full session — open, play, navigate, change voice and speed, bookmark, finish — completed with keyboard only.
- VoiceOver announces state changes for play/pause, position, and voice selection.

---

### F4 — Honest, self-clearing status  · **P1**

**Requirements**

- **F4.1** Errors clear automatically on the next successful synthesis.
- **F4.2** At most **one** status banner at a time; the more severe wins.
- **F4.3** Recoverable errors are transient toasts, not persistent banners.
- **F4.4** Persistent banners are reserved for states requiring user action (backend genuinely unreachable, models missing).
- **F4.5** Every error names a cause and an action.
- **F4.6** Only one backend can bind a port: `native_app.py` probes `GET /health` over HTTP before treating a port as free, instead of relying on a `SO_REUSEADDR` bind test. A second launch attaches to the running instance and focuses its window instead of starting a second server.

**Acceptance**

- Kill the backend mid-playback, restart it: exactly one banner appears, and it disappears on its own once audio resumes.
- Launching `Aloud.app` while a dev backend holds port 8000 results in exactly one listener on that port.

---

## 6. Release 1.5 — The Library

### F5 — Library and resume  · **P0**

**Problem.** The app persists five preferences and nothing else. Closing the window discards the document, the parsed text, and the position.

**Requirements**

- **F5.1** Parsed documents persist in IndexedDB keyed by content hash (not path), so a moved or renamed file is still recognized.
- **F5.2** Stored per document: title, author, page count, sentence count, parsed text, last position (sentence + intra-sentence offset), progress %, last-opened time, per-document voice and speed overrides.
- **F5.3** The empty state becomes a library: recent documents as cards with title, cover-derived accent, progress ring, and time remaining. The dropzone persists as one of the cards.
- **F5.4** Opening the app restores the last document at the last position, paused and ready. Press Play and you're back.
- **F5.5** Position saves on every sentence change, debounced, and on window close.
- **F5.6** Re-dropping an already-known file resumes it rather than re-parsing.
- **F5.7** "New" is additive — it opens a document alongside the library rather than destroying the session. Removing a document from the library asks for confirmation.
- **F5.8** Library supports search, sort (recent / title / progress), and "mark as finished."
- **F5.9** A visible storage figure with a one-click way to clear cached audio while keeping positions.

**Acceptance**

- Open a book, listen to sentence 1,847, force-quit, relaunch: **the same sentence is cued, in under 3 seconds, with zero clicks beyond Play.**
- 20 documents in the library; empty state renders in < 200 ms.
- Rename and move a PDF on disk, re-drop it: resumes at the stored position without re-parsing.

---

### F6 — Structure: chapters, contents, and skipping front matter  · **P0**

**Problem.** A 323-page book offers a single 1,280px scrub bar for 4,946 sentences — 3.9 sentences per pixel, no labels. The first ninety seconds of playback are the cover, the dedication, and a flattened table of contents.

**Requirements**

- **F6.1** Detect document structure from PDF outline/bookmarks where present; fall back to heuristics (font size, weight, numbering patterns, page breaks) where not.
- **F6.2** A contents sidebar (`⌘\`) listing chapters with per-chapter progress and duration. Click to jump.
- **F6.3** Detect and label front matter (title page, copyright, dedication, table of contents) and back matter (notes, bibliography, index).
- **F6.4** Default start position is **the first body chapter**, with a one-tap "start from the beginning" alternative.
- **F6.5** Option: skip back matter automatically (default on for notes/index, off for appendices).
- **F6.6** Scrub bar shows chapter tick marks and a hover tooltip with chapter name plus the first few words at that position.
- **F6.7** Chapter navigation via `⌘←` / `⌘→`.

**Acceptance**

- On 10 trade nonfiction PDFs, chapters are detected with ≥ 85% precision and recall against a hand-labelled ground truth.
- Default Play on *Platform Revolution* begins at "TODAY: Welcome to the Platform Revolution," not "PLATFORM."
- Reaching any chapter takes ≤ 2 interactions.

---

### F7 — Human-scale progress  · **P1**

**Requirements**

- **F7.1** Replace `1201 / 4946` with **time remaining in chapter** and **time remaining in book**, adjusted for current speed.
- **F7.2** Estimates derive from measured characters-per-second for the active voice, refined as the session proceeds.
- **F7.3** Show percent complete and current chapter name in the player.
- **F7.4** Page number remains available, de-emphasized.
- **F7.5** Estimates update live when speed changes.

**Acceptance**

- Predicted chapter duration is within **±8%** of actual across 10 chapters.
- The player never displays a raw sentence index in its primary line.

---

### F8 — A voice picker you can actually use  · **P1**

**Problem.** 54 voices, opening on Chinese, 5.4 screens of scrolling, no preview, meaningless names, and `brit` matches nothing.

**Requirements**

- **F8.1** Ordering: current voice first, then recently used, then voices matching the document's detected language, then everything else.
- **F8.2** Inline **audition** button per row. Plays a cached ~3s sample. Does not change the selected voice and does not disturb playback state.
- **F8.3** Samples pre-generated at first run (54 × 3s, background, low priority) and cached on disk.
- **F8.4** Each voice carries searchable descriptors — language, region, gender, and character tags (warm, bright, deep, measured, narration, conversational).
- **F8.5** Search matches names, languages, regions, aliases (`british` → UK, `american` → US), and descriptors.
- **F8.6** Languages the user has never used are collapsed behind "Show all languages."
- **F8.7** Changing voice mid-sentence resynthesizes and **resumes at the equivalent time offset**, not from the sentence start. (The per-word timing windows needed for this already exist.)
- **F8.8** Per-document voice memory.

**Acceptance**

- Selecting a known-good English voice from a cold open takes ≤ 2 interactions and requires no scrolling.
- Auditioning 5 voices does not move the playback position.
- `brit`, `british`, `warm`, `deep`, `narration` all return sensible results.

---

### F9 — Extraction quality and difficult documents  · **P1**

**Requirements**

- **F9.1** Two-column and multi-column layouts detected and read in correct column order.
- **F9.2** Tables detected and either skipped or announced ("Table — skipped"), never read left-to-right as prose.
- **F9.3** Figure captions, footnotes, and endnote markers detected; footnotes read on demand rather than inline (option, default off).
- **F9.4** Post-parse plausibility check: sentences-per-page, mean sentence length, alphabetic character ratio. A document that parses to near-nothing gets an explicit warning naming the likely cause (scanned, slide deck, image-only), not a reader containing one arrow.
- **F9.5** Optional OCR fallback for image-only PDFs, using a local engine, behind an explicit opt-in with a clear time estimate.
- **F9.6** Manual "skip this sentence / skip this block" control that persists per document.
- **F9.7** Support **EPUB** (highest-value format after PDF), plain text, and Markdown.

**Acceptance**

- On a 10-document corpus (5 trade books, 3 two-column papers, 1 slide deck, 1 scanned book), extraction is judged "clean enough to listen to" for all 8 text-bearing documents, and the two degenerate ones produce an accurate warning.
- Zero flattened tables read aloud as prose in the trade-book set.

---

## 7. Release 2.0 — Mac Citizen

### F10 — System integration  · **P1**

- **F10.1** `navigator.mediaSession` metadata and action handlers: title, chapter, artwork; play, pause, previous/next chapter, seek.
- **F10.2** Headphone and keyboard media keys control playback; Aloud appears in Control Centre's Now Playing.
- **F10.3** Native menu bar: File (Open, Open Recent, Library), Playback (transport, speed, chapter), View (theme, font size, contents), Window, Help.
- **F10.4** Window size, position, and theme persist across launches.
- **F10.5** Services / Share-sheet entry so a PDF can be sent to Aloud from Preview or Finder.
- **F10.6** Dock badge or progress on the icon during long parses.
- **F10.7** Signed and notarized build; no right-click-to-open Gatekeeper dance.
- **F10.8** Self-contained bundle — model and Python runtime included, so moving the `.app` doesn't break it. (Today the bundle hard-codes absolute paths at build time.)

### F11 — Sleep timer and session controls  · **P2**

- End of chapter, or 15/30/45/60 minutes, with a gentle fade-out. Persist the last choice.

### F12 — Bookmarks, highlights, and notes  · **P2**

- Bookmark the current sentence with `B`. Highlight a text selection. Attach a note. All persisted per document, listed in the sidebar, exportable to Markdown.

### F13 — Export to audio  · **P2**

- Export a chapter or a whole document to M4A/MP3 with chapter markers, at a chosen voice and speed. Background job with progress and cancel. Enables listening in a normal podcast app on a phone.

### F14 — Reading preferences  · **P2**

- Font size, line height, measure width, font family (2–3 curated serifs plus a dyslexia-friendly face), theme (light / dark / sepia / high-contrast), page-rule visibility, highlight style (sentence only, word only, both, none).

### F15 — Web article capture  · **P3**

- The untracked `extension/` directory suggests this is already contemplated. A browser extension that sends a reader-mode extraction of the current page into Aloud's library.

---

## 8. Design principles

1. **The audio is the product.** Any change that risks a stutter loses to any change that prevents one.
2. **Silence is a bug.** Every wait longer than 800ms needs an explanation on screen.
3. **The page is a book, not a UI.** Chrome retreats. When playing, everything but the text should be capable of fading away.
4. **One accent colour.** The existing single-orange discipline is correct and stays.
5. **Never lose the reader's place.** Position is sacred — persist it aggressively, restore it invisibly, and confirm before discarding anything.
6. **Keyboard-first.** Every action has a shortcut; no shortcut ever silently dies.
7. **Honest machinery.** Say what actually broke. Never blame a component that is working.

---

## 9. Non-goals

- Cloud sync, accounts, or any server-side component.
- Voice cloning, custom voice training, multi-speaker narration.
- Real-time translation.
- Mobile apps in this scope. (A local-network handoff to a phone is a future consideration; the export in F13 covers the practical need.)
- A general-purpose PDF viewer — Aloud reflows text for listening and does not aim to render original page layout.
- Windows/Linux in this scope, though nothing in the architecture should preclude them.

---

## 10. Technical notes

**Synthesis concurrency (F1).** The fix is a lock, not a thread pool. Measured: one request at a time reaches 7.2× real-time and never fails; three at a time reach 1.5s each and fail 42% of the time. Serialization costs nothing the user can hear and removes the entire failure class. If more throughput is ever needed, the correct route is separate *processes* (each with its own espeak state), not threads.

**Priority queue (F1.3/F2.4).** A single lock is not sufficient on its own — a `now` request must be able to jump ahead of queued `prefetch` work, otherwise a seek waits behind two speculative sentences it will never play.

**Warm-up (F2.5).** First inference costs 4.11s; subsequent ones 0.87s. A throwaway synthesis before `/health` returns `ok` moves that cost off the user's critical path entirely.

**CoreML.** `onnxruntime` reports CoreML available; the session runs CPU-only. Worth measuring, but strictly after F1 — correctness first, and 7× real-time is already sufficient headroom.

**Reader virtualization.** 4,946 sentences currently render as 6,067 DOM nodes across 400,541px of scroll height, and it performs fine. A 1,000-page document would not. Virtualize before shipping the library, since the library invites bigger books.

**Storage.** IndexedDB for parsed documents and positions; a disk cache for voice samples and any exported audio. Cache is bounded by bytes and separately clearable from positions.

**Structure detection (F6).** Prefer the PDF outline when present — most trade ebooks have one, and it's exact. Heuristics are the fallback, not the primary path.

---

## 11. Milestones

| Milestone | Contents | Exit criteria |
| --- | --- | --- |
| **M1 — Don't stop** | F1, F2 | 40-minute session at 2.5×, zero stops, < 0.5% buffering |
| **M2 — Don't forget** | F5, F4 | Force-quit and relaunch resumes in < 3s |
| **M3 — Don't get lost** | F6, F7, F3 | Chapter navigation and time remaining; zero dead shortcuts |
| **M4 — Sound right** | F8, F9 | Voice selection in ≤ 2 interactions; clean extraction on the 10-doc corpus |
| **M5 — Belong on the Mac** | F10, F11, F14 | Media keys, sleep timer, signed build |
| **M6 — Beyond the window** | F12, F13, F15 | Bookmarks, export, capture |

---

## 12. Open questions

1. **Is CoreML worth the risk?** Potentially faster, but a second execution provider is a second source of numerical and stability differences. Measure after M1; ship only with a CPU fallback.
2. **How much audio should be cached to disk?** Caching a whole book's audio makes re-listening instant and makes F13 export nearly free, at ~500MB–1GB per book. Probably worth it, gated behind a per-document opt-in.
3. **EPUB before or after structure detection?** EPUB has real structural markup, so it would *validate* the chapter model rather than stress it. There's an argument for pulling F9.7 forward into 1.5.
4. **What is the right default speed?** The target user listens at 1.5–2×; the app defaults to 1×. A first-run speed preference may be worth more than it costs.
5. **How aggressive should front-matter skipping be?** Starting at Chapter 1 by default is right for trade books and wrong for papers, where the abstract is the most important part. Likely document-type-dependent.
