# Aloud 1.1 "Reliability" — Execution PRD

**Version:** 1.0
**Date:** 2026-07-31
**Status:** in execution
**Parents:** [`PRD.md`](./PRD.md) §5 (Release 1.1), [`UX-FEEDBACK.md`](./UX-FEEDBACK.md) P0-1, P0-3, P1-1, P1-2, P2
**Scope:** F1, F2, F3, F4 — plus **F1/F2 parity for the new browser extension**, which ships the same player and therefore the same defect.

> The product PRD says it plainly: *"1.1 is not optional and nothing else ships before it."* This document turns F1–F4 into file-level work with a fixed interface contract, so the backend and both clients can be built in parallel without waiting on each other.

---

## 0. Why the extension is in this release

Aloud now has **two** clients:

| Client | Location | Player |
| --- | --- | --- |
| Desktop reader | `frontend/` | `frontend/src/lib/player.ts` |
| Browser extension | `extension/` | `extension/src/content/player.ts` (port of the same engine) |

The extension's player is a direct port — same `LOOKAHEAD = 2`, same fire-and-forget prefetch, same "one failure ends playback" error path. **Every P0-1 symptom in the review reproduces in the extension.** Fixing only the desktop client would ship a known-broken second client.

`PRD.md` lists the extension as F15/P3 ("web article capture"). That is now stale: the extension exists, reads pages in place with sentence + word highlighting, and is a first-class client. It is treated as such here.

### Reproduction on this machine (2026-07-31, M4 Pro, backend `8475d6d`)

12 real sentences per level, model pre-warmed:

| In-flight | Failures | Avg latency | Wall |
| --- | --- | --- | --- |
| 1 | **0 / 12** | 767 ms | 9,204 ms |
| 3 (player default) | **1 / 12** | 1,254 ms | 4,842 ms |
| 6 (scrubbing) | **2 / 12** | 1,969 ms | 3,798 ms |

Failure signature matches the review exactly:

```
HTTP 500 {"error":"synthesis failed: number of lines in input and output
          must be equal, we have: input=3, output=2"}
```

Lower rate than the review's 42% (different sentence mix and machine load), same defect, same fix. **Sequential is the only configuration that never fails.**

---

## 1. Interface contract (frozen — build against this)

Everything below is fixed before implementation starts so the backend and both clients can be written simultaneously.

### 1.1 `POST /synthesize`

Request:

```jsonc
{
  "text": "…",              // required, non-empty
  "voice": "af_heart",
  "speed": 1.0,
  "priority": "now"          // NEW. "now" | "prefetch". Default "now".
}
```

Responses:

| Status | When | Body | Client behaviour |
| --- | --- | --- | --- |
| `200` | success | `audio/wav` bytes | play |
| `400` | empty/invalid text | `{"error": …}` | **not** retryable — skip the sentence |
| `429` | prefetch queue full | `{"error": …, "retryable": true}` + `Retry-After: 1` | retryable; honour `Retry-After` |
| `500` | synthesis failed | `{"error": …, "retryable": true}` | retryable |
| `503` | model not loaded | `{"error": …, "retryable": true}` + `Retry-After: 2` | retryable |

### 1.2 `GET /health`

```jsonc
{
  "status": "ok",            // "ok" only once warm-up has COMPLETED; "warming" before that
  "engine": "kokoro",
  "model_loaded": true,
  "voice_count": 54,
  "warm": true,              // NEW
  "queue_depth": 0           // NEW — requests waiting, excluding the one in flight
}
```

`status` is one of `"ok"` | `"warming"`. Clients must distinguish:

- unreachable → **"Speech engine offline"** (persistent banner, user action needed)
- `"warming"` → **"Warming up the voice engine…"** (transient, no error styling)
- `"ok"` → no banner

### 1.3 Serialization and priority (backend)

- Exactly **one** `kokoro.create()` call in flight process-wide, enforced by a single worker.
- Waiting requests form a **priority queue**: all `now` requests are served before any `prefetch` request; FIFO within a priority class.
- Queue bound applies to **`prefetch` only** (`ALOUD_QUEUE_MAX`, default 8). A `now` request is never rejected for depth — it preempts.
- Warm-up is simply the first job the worker runs.

### 1.4 Client retry policy (identical in both clients)

- Per-attempt timeout **30 s** (`AbortController`).
- Retry on `429`, `500`, `503`, network error, timeout. **Never** retry `400` or a user abort.
- Max **2 retries** (3 attempts total). Backoff **250 ms**, then **750 ms**; a `Retry-After` header wins if larger.
- Exhausted retries → **skip the sentence, keep playing.** Never set the global error state; never set `wantPlaying = false`.
- The global "offline" error is set **only** when `/health` itself fails.

### 1.5 Buffering (both clients)

- Buffer depth is measured in **seconds of source audio ready ahead of the playhead**, not sentences.
- Target: `BUFFER_TARGET_SECONDS = 60` of *listening* time. Because `playbackRate` consumes source faster, required source seconds = `60 × rate` (F2.2).
- Floor: always at least **3 sentences** ahead regardless of duration.
- The current sentence is requested with `priority: "now"`; everything speculative uses `"prefetch"`.
- The pipeline tops up on a timer while playing (idle fill, F2.3) — not only on sentence change.
- Unknown durations are estimated from character count via a **measured** chars-per-second figure, seeded at 15 c/s and refined from real decoded clips.
- Cache is bounded by **decoded bytes** (256 MB default) *and* entry count; eviction is LRU and never evicts the current or next sentence.

---

## 2. Work items

### A1 — Backend: serialized priority queue, warm-up, honest health

**Owns:** `backend/app.py`, `backend/kokoro_engine.py`, `backend/native_app.py`, `backend/run.py`

| Req | Detail |
| --- | --- |
| A1.1 | Single synthesis worker. One `kokoro.create()` in flight process-wide. (F1.1) |
| A1.2 | Priority queue; `now` preempts `prefetch`; FIFO within a class. (F1.3) |
| A1.3 | Bounded prefetch queue (`ALOUD_QUEUE_MAX`, default 8) → `429` + `Retry-After`, never a 500. (F1.2) |
| A1.4 | Warm-up inference at startup; `/health` reports `status:"warming"`, `warm:false` until it completes. (F2.5) |
| A1.5 | `/health` gains `warm` and `queue_depth`. (§1.2) |
| A1.6 | Every 4xx/5xx logged at WARNING with truncated text + voice. (F1.8) |
| A1.7 | Error bodies carry `retryable`. (§1.1) |
| A1.8 | `native_app.choose_port()` probes `GET /health` over HTTP before treating a port as free — the `SO_REUSEADDR` bind test reports a busy `0.0.0.0:8000` as free and starts a second 325 MB model. (F4.6) |

**Constraint:** synthesis must stay ≥ 5× real-time sequentially. Do not add per-request model work.

### A2 — Desktop player: retry, skip, time-based buffer

**Owns:** `frontend/src/lib/player.ts`, `frontend/src/lib/api.ts`

| Req | Detail |
| --- | --- |
| A2.1 | `synthesize()` takes `priority`, applies §1.4 retry/timeout, surfaces `retryable` and HTTP status. |
| A2.2 | Failed-after-retries sentence is **skipped**: advance, `markSkipped(id)`, stay `playing`. (F1.5) |
| A2.3 | Buffer scheduler per §1.5, replacing `LOOKAHEAD = 2`. (F2.1–F2.4) |
| A2.4 | Byte-bounded LRU cache; never evict current/next. (F2.6) |
| A2.5 | Publish `bufferAheadSeconds` to the store on change. (F2.7) |
| A2.6 | Clear the global error on the next successful synthesis. (F4.1) |
| A2.7 | New public method `seekBySeconds(delta)` — walks sentences by known/estimated duration and sets `currentTime` within the landing sentence. Needed by J/K/L and ⇧←/⇧→. |
| A2.8 | Health polling sets `engineState`; only a failing `/health` sets `error`. (F1.7) |

### A3 — Desktop UI: keyboard, status, progress

**Owns:** `frontend/src/App.tsx`, `frontend/src/components/**`, `frontend/src/hooks/**`, `frontend/src/styles/globals.css`

| Req | Detail |
| --- | --- |
| A3.1 | **Fix P0-3.** `isSelfHandlingControl()` must not suppress transport for the reader's sentence spans. Sentences handle `Enter`/`Space` themselves or opt out explicitly. (F3.1, F3.2) |
| A3.2 | Shortcuts: `Space`, `←`/`→`, `↑`/`↓` (paragraph), `⇧←`/`⇧→` (±30 s), `J`/`K`/`L` (−10 s / play-pause / +10 s), `[`/`]` (speed preset), `?` (overlay), `Esc`. (F3.3) |
| A3.3 | Scrub bar implements `Home`, `End`, `PageUp`, `PageDown` (±1%). (F3.4) |
| A3.4 | `?` shortcut overlay; the permanent header hint retires after the third session. (F3.5) |
| A3.5 | **One** banner maximum, most severe wins; recoverable errors are toasts. (F4.2, F4.3) |
| A3.6 | Banner copy names a cause and an action; `warming` is not an error. (F4.5) |
| A3.7 | Secondary buffer fill on the scrub bar. (F2.7) |
| A3.8 | Buffering affordance with elapsed feedback past 800 ms — no bare spinner. (F2.8) |
| A3.9 | Skipped sentences render an inline "couldn't read this" affordance. (F1.5) |
| A3.10 | Speed presets return as tap targets (1×, 1.25×, 1.5×, 1.75×, 2×, 2.5×, 3×); dead `.popover--rate` CSS is either used or deleted. (P2) |
| A3.11 | Multi-line sentence highlight stops rendering as ragged lozenges. (P2) |

**Deferred to 1.5 (needs F6 chapters / F12 bookmarks):** `⌘←`/`⌘→`, `⌘F`, `B`.

### A4 — Extension: F1/F2 parity

**Owns:** `extension/**`

| Req | Detail |
| --- | --- |
| A4.1 | Service worker forwards `priority`; maps `429`/`503`/`500` to `{retryable:true}` and passes `Retry-After` through. |
| A4.2 | Content player: §1.4 retry/timeout, skip-not-fatal, never stop on one sentence. |
| A4.3 | Content player: §1.5 time-based buffering with `now`/`prefetch` priority. |
| A4.4 | Byte-bounded cache. |
| A4.5 | Player bar distinguishes offline / warming / buffering; a skipped sentence is a toast, not a stop. |
| A4.6 | Popup surfaces `warming` distinctly from `offline`. |

---

## 3. Acceptance

Run against the live backend; record numbers.

| # | Test | Pass condition |
| --- | --- | --- |
| T1 | Loopback load, 1/3/6 concurrent clients × 12 sentences | **0 5xx at every level** (was 0 / 1 / 2) |
| T2 | Chaos: backend forced 30% failure, play 100 sentences | playback never stops; ≤ 30 skip markers |
| T3 | Sequential throughput | ≥ 5× real-time |
| T4 | Prefetch flood → queue overflow | `429` + `Retry-After`, **no 500s**; client recovers silently |
| T5 | Warm-up | `/health` reports `warming` then `ok`; first user synthesis is not the cold one |
| T6 | Port guard | launching the app while a dev backend holds 8000 leaves exactly **one** listener |
| T7 | Keyboard matrix | every shortcut fires from {body, sentence span, play button, scrub bar, voice chip}; **zero dead combinations** |
| T8 | Banner lifecycle | kill backend mid-playback then restart → exactly one banner, self-clearing |
| T9 | Extension E2E | loads in Chrome, SW router answers health/voices/synth, popup renders, WAV decodes |
| T10 | Typecheck + build | `frontend` and `extension` both clean |

---

## 4. Execution waves

| Wave | Work | Parallel? |
| --- | --- | --- |
| **0** | Freeze the store/types contract so parallel agents don't collide (done by the orchestrator) | — |
| **1** | A1 backend · A2 desktop player · A3 desktop UI · A4 extension | 4 agents, disjoint file ownership |
| **2** | T1–T6 acceptance · T9 extension E2E · T7/T8/T10 build + review | 3 agents |
| **3** | Integration fixes from wave 2 findings | orchestrator |

File ownership is disjoint by construction. The only shared files — `frontend/src/store.ts` and `frontend/src/types.ts` — are frozen in wave 0 and **read-only** for every agent in wave 1.

---

## 5. Out of scope for 1.1

Everything in `PRD.md` releases 1.5 and 2.0: the library and resume (F5), chapters and front-matter detection (F6), human-scale progress (F7), the voice picker (F8), extraction quality and EPUB (F9), and all Mac-citizenship work (F10–F15). Release 1.1 adds no features; it makes the existing ones work.
