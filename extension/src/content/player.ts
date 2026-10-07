// ─────────────────────────────────────────────────────────────────────────────
// Playback engine.
//
// The engine owns audio: it synthesizes sentences via the backend (with buffering
// + caching), plays them gaplessly, auto-advances, and reports position/status
// through hooks. Nothing above it touches audio directly.
//
// ── How gap-free playback works ──────────────────────────────────────────────
// Every sentence is synthesized to a WAV blob, wrapped in an object URL, and
// cached under `${voiceId}|${skip}|${sentenceId}`. When we play sentence N we
// (a) ensure N's audio at priority `now` and (b) keep filling a buffer of
// speculative `prefetch` work ahead of it. Kokoro synthesizes ~5x faster than
// realtime, so by the time N finishes, N+1's URL is already resolved and we can
// `audio.src = url; play()` with no audible gap.
//
// ── Buffering is measured in seconds, not sentences (§1.5, F2.1–F2.4) ────────
// The old `LOOKAHEAD = 2` was a lie dressed as a constant: two sentences is 1–2
// seconds of audio when the sentences are short, so a run of short lines emptied
// the buffer and the reader heard the gap. The target is now BUFFER_TARGET_SECONDS
// of *listening* time, and because playbackRate consumes source faster than
// realtime, the required source depth is `target × rate` — at 2x, a minute of
// listening needs two minutes of audio. A floor of MIN_LOOKAHEAD sentences applies
// regardless, so we never sit idle behind one very long sentence.
//
// Depth is real, not guessed: a WAV's duration comes straight out of its header
// (no decode), and only sentences we have never synthesized fall back to a
// chars-per-second estimate — itself refined from every clip we do measure.
//
// ── One bad sentence is not the end (§1.4, F1.5) ─────────────────────────────
// A failed synthesis used to stop playback and blame the backend. Now the
// transport retries (see api.ts), and a sentence that still fails is SKIPPED:
// playback advances, the sentence is reported to the UI, and status stays
// `playing`. Only a run of MAX_CONSECUTIVE_SKIPS failures — which is an engine
// that has gone away, not a sentence that won't read — stops anything, and it
// stops on the FIRST of the engine's failures in the run so resuming loses
// nothing. A sentence the engine refused (400) refuses every time, so the stop
// never rewinds over one: resuming carries on past it instead of stopping on it
// again. A sentence with nothing to say (a bracketed aside with skipping on) is
// never sent at all — it plays as silence. A request that never reached an
// engine (backend down, extension reloaded) says nothing about its sentence, so
// it is not skipped: playback stops right there. Once the extension is gone
// from the page, cached audio does not play on either (G019).
//
// ── Cache invalidation ───────────────────────────────────────────────────────
// The key embeds voice + skip-mode, so changing either routes future lookups to
// fresh keys — stale audio can never be replayed. On a change we also actively
// DROP every non-matching entry: in-flight requests are aborted (so the backend
// stops wasting cycles) and resolved object URLs are revoked. The cache is bounded
// by total decoded BYTES as well as entry count (F2.6), and eviction never takes
// the current or next sentence. Rate is deliberately NOT in the key: every clip is
// synthesized at speed 1.0 and sped up client-side with `playbackRate`, so one
// cached WAV serves every speed and a speed change is instant, even mid-sentence.
//
// ── Stale-continuation guard ─────────────────────────────────────────────────
// Async synth results can arrive after the user has moved on. A monotonic
// `playToken` is captured when a play starts; any continuation whose token no
// longer matches is a no-op. With AbortController on the request, this
// guarantees we never play audio for a superseded position.
// ─────────────────────────────────────────────────────────────────────────────

import { spokenText } from '../shared/chunker'
import type { SynthPriority } from '../shared/protocol'
import type { PlayerStatus, Prefs, ReadDoc, WordToken } from '../shared/types'
import { wavDuration, WAV_HEADER_BYTES } from '../shared/wav'
import { extensionAlive, isAbortError, RELOADED_MESSAGE, SynthesisError, synthesize } from './api'

/**
 * Entry cap. Sized so it can never be what stops the buffer reaching its target:
 * the deepest legitimate buffer is `BUFFER_TARGET_SECONDS × 3` (max rate) of
 * source, which at the 0.35s floor on estimated sentence duration is ~514
 * sentences — so a smaller cap would quietly reimpose the count-based limit that
 * F2.1 exists to remove. A cap of 96 measured out at 41s against a 60s target.
 */
const MAX_CACHE_ENTRIES = 512
/**
 * Max total bytes of live audio (§1.5, F2.6) — the bound that actually binds.
 * Half the desktop reader's figure on purpose: this cache lives inside someone
 * else's page, and 24kHz mono PCM is ~48 KB/s, so 128 MB is still ~45 minutes of
 * audio — far more than any buffer target can ask for.
 */
const MAX_CACHE_BYTES = 128 * 1024 * 1024
/** Seconds of *listening* time we try to keep ready ahead of the playhead (F2.1). */
const BUFFER_TARGET_SECONDS = 60
/** Never fewer than this many sentences ahead, however short they are (F2.1). */
const MIN_LOOKAHEAD = 3
/**
 * Speculative requests allowed in flight at once. The backend bounds its prefetch
 * queue at 8 and answers 429 past that; staying under it means the common case
 * never has to spend a retry.
 */
const MAX_PREFETCH_INFLIGHT = 6
/** How often the idle filler tops the buffer up while playing (F2.3). */
const FILL_INTERVAL_MS = 500
/** Seed for the duration estimate, refined from every clip we measure (§1.5). */
const SEED_CHARS_PER_SECOND = 15
/**
 * Consecutive skips that mean "the engine is gone", not "that sentence was odd".
 * Below this we keep playing; at it we stop, because racing silently through a
 * whole page skipping every sentence helps nobody.
 */
const MAX_CONSECUTIVE_SKIPS = 3
/**
 * A busy backend (prefetch queue full) or a warming one: says nothing about
 * the sentence, so look-ahead turned away with these is asked for again.
 */
const BUSY_STATUSES = new Set([429, 503])

/**
 * Stands in for an object URL when a sentence has nothing to say — skipping
 * left only brackets and punctuation. The backend answers 400 for empty text,
 * so such a sentence is never sent: it is stepped over as silence (G017).
 */
const SILENT = 'silent:'
/** Spoken text without a letter or digit has nothing for the voice to read. */
const HAS_SPEAKABLE = /[\p{L}\p{N}]/u

/**
 * Chrome's autoplay policy refused to start audio. The keyboard shortcut and the
 * popup reach the page from outside, so the page itself may never have had a
 * click — and only a click on the page (the bar is on the page) unlocks its audio.
 */
const AUTOPLAY_BLOCKED_MESSAGE = 'Chrome blocked the audio — click play on the Aloud bar to start.'

const NOW: SynthPriority = 'now'
const PREFETCH: SynthPriority = 'prefetch'

export interface PlayerHooks {
  /** Freshest user settings; read on every access so changes apply immediately. */
  prefs(): Prefs
  onStatus(status: PlayerStatus, error: string | null): void
  /** Active sentence changed (index into doc.sentences, -1 for none). */
  onSentence(index: number): void
  /** Active word changed (index into the current sentence's tokens, -1 for none). */
  onWord(tokenIndex: number): void
  /** A sentence could not be synthesized and was skipped. Playback continues. */
  onSkip(index: number, message: string): void
  /**
   * Buffer depth (F2.7). `secondsAhead` is listening time — what the user would
   * hear uninterrupted if the engine died now. `readyThrough` is the last
   * sentence index whose audio is contiguously ready, which is what a
   * sentence-denominated scrub bar can actually paint.
   */
  onBuffer(secondsAhead: number, readyThrough: number): void
}

/** One cache slot: the pending/settled synth for a `${voice}|${skip}|${id}` key. */
interface CacheEntry {
  key: string
  sentenceId: number
  /** Resolves to the object URL of the synthesized WAV. */
  promise: Promise<string>
  /** Set once resolved, so we can revoke on eviction. Null while in-flight. */
  url: string | null
  /** Decoded size in bytes; 0 until resolved. Drives the byte bound. */
  bytes: number
  /** True duration in seconds, read from the WAV header. Null until resolved. */
  duration: number | null
  /** Queue class this was requested at — used to count speculative work in flight. */
  priority: SynthPriority
  /** Aborts the underlying request when the entry becomes stale. */
  controller: AbortController
}

export class AloudPlayer {
  private doc: ReadDoc | null = null
  private audio: HTMLAudioElement | null = null

  /** Sentence index we intend to be on. */
  private index = -1
  /** Index whose object URL is currently loaded on the audio element (-1 = none). */
  private loadedIndex = -1
  /** Whether we intend audio to be running (drives auto-advance on 'ended'). */
  private wantPlaying = false
  /** Bumped whenever the active position changes; stale continuations check it. */
  private playToken = 0

  private currentStatus: PlayerStatus = 'idle'
  private currentError: string | null = null

  // ── word-level highlight (karaoke) ────────────────────────────────────────
  /** Word tokens of the sentence whose audio is currently loaded. */
  private tokens: WordToken[] = []
  /**
   * Per-word time windows for the loaded sentence, in playback order. Built once
   * the audio's real duration is known. `token` indexes back into `tokens`;
   * whitespace and skipped tokens get no window.
   */
  private windows: Array<{ start: number; end: number; token: number }> = []
  /** rAF handle for the highlight loop (0 = not running). */
  private rafId = 0
  /** Last word index reported; guards against per-frame callbacks. */
  private lastWordIndex = -1

  // Insertion-ordered Map = our LRU; oldest key first. Entries are re-inserted
  // (touched) on access so recently used sentences survive eviction.
  private cache = new Map<string, CacheEntry>()
  /** Running sum of `entry.bytes`, so the byte bound costs no iteration. */
  private cacheBytes = 0

  // ── buffering ─────────────────────────────────────────────────────────────
  /** setInterval handle for the idle filler (0 = not running). */
  private fillTimer = 0
  /** Last values handed to `onBuffer`, so we only report real movement. */
  private reportedBuffer = -1
  private reportedThrough = -2
  /**
   * Measured synthesis speed, in characters of spoken text per second of audio.
   * Seeded per §1.5 and refined by an exponential moving average from every clip
   * whose true duration we learn — so estimates for un-synthesized sentences get
   * better as the session goes on, and are voice-specific in practice.
   */
  private charsPerSecond = SEED_CHARS_PER_SECOND

  // ── failure tracking ──────────────────────────────────────────────────────
  /** Sentences that failed every retry and were skipped. */
  private skipped = new Set<number>()
  /**
   * Sentences skipped in a row since the last success or the last move the user
   * made. At MAX_CONSECUTIVE_SKIPS we stop. `rewind` is false for a sentence the
   * engine refused (400): it would fail the same way again, so the stop must
   * never land on it.
   */
  private streak: Array<{ index: number; rewind: boolean }> = []

  // Snapshot of the prefs that current audio was produced under, so applyPrefs()
  // knows what actually changed.
  private lastVoice: string
  private lastSkip: boolean
  private lastRate: number

  constructor(private hooks: PlayerHooks) {
    const p = hooks.prefs()
    this.lastVoice = p.voiceId
    this.lastSkip = p.skipSkippable
    this.lastRate = p.rate
  }

  get status(): PlayerStatus {
    return this.currentStatus
  }

  get currentIndex(): number {
    return this.index
  }

  get total(): number {
    return this.doc?.sentences.length ?? 0
  }

  /** Sentences that couldn't be read and were skipped, for the UI to mark. */
  wasSkipped(index: number): boolean {
    return this.skipped.has(index)
  }

  // ── status / position plumbing ────────────────────────────────────────────

  private setStatus(status: PlayerStatus, error: string | null = null) {
    if (this.currentStatus === status && this.currentError === error) return
    this.currentStatus = status
    this.currentError = error
    this.hooks.onStatus(status, error)
  }

  private setIndex(i: number) {
    if (i === this.index) return
    // A new sentence always clears the word highlight, so a stale word from the
    // previous sentence can never linger on the new one.
    this.lastWordIndex = -1
    this.index = i
    this.hooks.onSentence(i)
    this.hooks.onWord(-1)
  }

  // ── audio element (created lazily) ────────────────────────────────────────

  private ensureAudio(): HTMLAudioElement {
    if (!this.audio) {
      const a = new Audio()
      a.preload = 'auto'
      // Rate is applied client-side (pitch preserved) so we can reach a true 3x
      // and change speed instantly without re-synthesizing.
      a.preservesPitch = true
      a.playbackRate = this.hooks.prefs().rate
      a.addEventListener('ended', () => this.onEnded())
      // A clip that can't load or decode never fires 'ended'; without this the
      // reader would sit on it forever, showing pause over silence.
      a.addEventListener('error', () => this.onAudioError())
      // The natural (1.0x) WAV duration lands here; per-word windows are laid
      // out in media-time, so raising playbackRate speeds the highlight in step.
      a.addEventListener('loadedmetadata', () => this.onLoadedMetadata())
      this.audio = a
    }
    return this.audio
  }

  // ── word-level highlight ──────────────────────────────────────────────────

  /**
   * Adopt sentence `i`'s tokens for the highlight and reset per-word state.
   * Called when its audio is assigned; the time windows are filled in by
   * onLoadedMetadata() once the WAV's duration is known.
   */
  private prepareWords(i: number) {
    this.tokens = this.doc?.sentences[i]?.tokens ?? []
    this.windows = []
    this.lastWordIndex = -1
    this.hooks.onWord(-1)
  }

  /**
   * Distribute the sentence's real audio duration across its word tokens by
   * weight. When skipping is on, skippable tokens are omitted from BOTH the
   * total and the layout — they aren't in the spoken audio, so giving them no
   * window keeps every remaining window aligned.
   */
  private computeWindows(duration: number) {
    this.windows = []
    const skip = this.hooks.prefs().skipSkippable
    const spoken = (tk: WordToken) => tk.weight > 0 && !(skip && tk.isSkippable)
    let total = 0
    for (const tk of this.tokens) if (spoken(tk)) total += tk.weight
    if (total <= 0 || !(duration > 0)) return
    let acc = 0
    for (let i = 0; i < this.tokens.length; i++) {
      const tk = this.tokens[i]
      if (!spoken(tk)) continue
      const start = (acc / total) * duration
      acc += tk.weight
      const end = (acc / total) * duration
      this.windows.push({ start, end, token: i })
    }
  }

  private onLoadedMetadata() {
    const d = this.audio?.duration
    if (d !== undefined && Number.isFinite(d) && d > 0) this.computeWindows(d)
  }

  /** Token index of the word whose [start,end) window contains time `t` (-1 = none). */
  private wordIndexAt(t: number): number {
    const w = this.windows
    const n = w.length
    if (n === 0) return -1
    if (t <= w[0].start) return w[0].token
    const last = w[n - 1]
    if (t >= last.end) return last.token
    let lo = 0
    let hi = n - 1
    while (lo <= hi) {
      const mid = (lo + hi) >> 1
      const win = w[mid]
      if (t < win.start) hi = mid - 1
      else if (t >= win.end) lo = mid + 1
      else return win.token
    }
    return last.token
  }

  /** rAF body: map audio.currentTime → active word, reporting only on change. */
  private wordLoop = () => {
    const audio = this.audio
    if (!audio || !this.wantPlaying) {
      this.rafId = 0
      return
    }
    const idx = this.wordIndexAt(audio.currentTime)
    if (idx !== this.lastWordIndex) {
      this.lastWordIndex = idx
      this.hooks.onWord(idx)
    }
    this.rafId = requestAnimationFrame(this.wordLoop)
  }

  private startWordLoop() {
    if (this.rafId) return
    this.rafId = requestAnimationFrame(this.wordLoop)
  }

  private stopWordLoop() {
    if (this.rafId) {
      cancelAnimationFrame(this.rafId)
      this.rafId = 0
    }
  }

  // ── cache ─────────────────────────────────────────────────────────────────

  private keyFor(sentenceId: number): string {
    const { voiceId, skipSkippable } = this.hooks.prefs()
    return `${voiceId}|${skipSkippable ? 's' : 'f'}|${sentenceId}`
  }

  /** Cache entry for `sentenceId` at the current params, without creating one. */
  private peek(sentenceId: number): CacheEntry | undefined {
    return this.cache.get(this.keyFor(sentenceId))
  }

  /**
   * Return the cache entry for `sentenceId` at the CURRENT voice + skip mode,
   * creating it (and kicking off synthesis) on a miss. Touches it for LRU.
   *
   * An entry already in flight keeps the priority it was created with: the
   * backend has queued it and there is no way to promote it from here. In
   * practice that is the good case — it means prefetch got there first. If the
   * backend turns it away as busy instead, playIndex asks again at `now` (G032).
   */
  private ensure(sentenceId: number, priority: SynthPriority): CacheEntry {
    const { voiceId, skipSkippable } = this.hooks.prefs()
    const key = this.keyFor(sentenceId)

    const hit = this.cache.get(key)
    if (hit) {
      this.cache.delete(key)
      this.cache.set(key, hit)
      return hit
    }

    const sentence = this.doc!.sentences[sentenceId]
    const controller = new AbortController()
    const entry: CacheEntry = {
      key,
      sentenceId,
      url: null,
      bytes: 0,
      duration: null,
      priority,
      controller,
      promise: Promise.resolve(''), // placeholder, overwritten below
    }
    // Always synthesize at speed 1.0 — playback rate lives on the element.
    const text = spokenText(sentence.text, skipSkippable)
    if (!HAS_SPEAKABLE.test(text)) {
      // Nothing to say: never ask the backend, which answers 400 for empty text
      // (G017). playIndex steps past it.
      entry.url = SILENT
      entry.duration = 0
      entry.promise = Promise.resolve(SILENT)
    } else {
      entry.promise = this.synth(entry, text, voiceId, priority)
    }
    this.cache.set(key, entry)
    this.evict()
    return entry
  }

  /** Run one synthesis request, wrap the WAV in an object URL, and cache-guard it. */
  private async synth(
    entry: CacheEntry,
    text: string,
    voice: string,
    priority: SynthPriority,
  ): Promise<string> {
    try {
      const blob = await synthesize({ text, voice, speed: 1, priority }, entry.controller.signal)
      const url = URL.createObjectURL(blob)
      entry.url = url
      const duration = await this.measure(blob, text)

      // Evicted or invalidated while we were resolving: nobody is waiting on this
      // URL, so revoke it rather than leak it. Crucially, `bytes` stays 0 until
      // the entry is known to be live and counted — otherwise a `forget()` during
      // the await above would subtract bytes that were never added, and a
      // negative total would quietly switch the byte bound off.
      if (this.cache.get(entry.key) !== entry) {
        URL.revokeObjectURL(url)
        return url
      }
      entry.bytes = blob.size
      entry.duration = duration
      this.cacheBytes += entry.bytes
      this.evict()
      return url
    } catch (err) {
      // Drop failed/aborted entries so a later visit re-attempts synthesis.
      if (this.cache.get(entry.key) === entry) this.forget(entry.key)
      throw err
    }
  }

  /**
   * True duration from the WAV header, and a refinement of the chars-per-second
   * estimate while we're here. Falls back to the current estimate for anything
   * we can't parse.
   */
  private async measure(blob: Blob, text: string): Promise<number> {
    let duration: number | null = null
    try {
      duration = wavDuration(await blob.slice(0, WAV_HEADER_BYTES).arrayBuffer(), blob.size)
    } catch {
      duration = null
    }
    if (duration === null || !(duration > 0)) return this.estimateFromText(text)
    if (text.length > 0) {
      // Exponential moving average — one weird clip shouldn't move the estimate
      // much, but a different voice's steady-state should be reached quickly.
      const observed = text.length / duration
      this.charsPerSecond = this.charsPerSecond * 0.8 + observed * 0.2
    }
    return duration
  }

  private estimateFromText(text: string): number {
    return Math.max(0.35, text.length / this.charsPerSecond)
  }

  /** Best available source-seconds figure for sentence `j`. */
  private durationOf(j: number): number {
    const entry = this.peek(j)
    if (entry?.duration != null) return entry.duration
    const sentence = this.doc?.sentences[j]
    if (!sentence) return 0
    return this.estimateFromText(spokenText(sentence.text, this.hooks.prefs().skipSkippable))
  }

  /** Delete one entry: un-count its bytes, abort or revoke, drop the key. */
  private forget(key: string) {
    const entry = this.cache.get(key)
    if (!entry) return
    this.cache.delete(key)
    this.cacheBytes -= entry.bytes
    this.dropResources(entry)
  }

  /**
   * Enforce both bounds, oldest-first, but never take the sentence we're playing
   * or the one after it — evicting those would guarantee the stall the buffer
   * exists to prevent (§1.5).
   */
  private evict() {
    while (this.cache.size > MAX_CACHE_ENTRIES || this.cacheBytes > MAX_CACHE_BYTES) {
      let victim: string | null = null
      for (const [key, entry] of this.cache) {
        if (entry.sentenceId === this.index || entry.sentenceId === this.index + 1) continue
        victim = key
        break
      }
      // Everything left is protected — the bound yields rather than the playback.
      if (victim === null) break
      this.forget(victim)
    }
  }

  /** Free an entry: abort if in-flight, revoke its URL if resolved. */
  private dropResources(entry: CacheEntry) {
    if (entry.url === SILENT) return
    if (entry.url) URL.revokeObjectURL(entry.url)
    else entry.controller.abort()
  }

  /** Drop every cached entry whose key doesn't match the current voice + skip. */
  private invalidateStaleParams() {
    const { voiceId, skipSkippable } = this.hooks.prefs()
    const prefix = `${voiceId}|${skipSkippable ? 's' : 'f'}|`
    for (const key of [...this.cache.keys()]) {
      if (!key.startsWith(prefix)) this.forget(key)
    }
  }

  // ── buffering ─────────────────────────────────────────────────────────────

  /** Seconds of the current sentence still to play, at 1.0x source time. */
  private remainingInCurrent(): number {
    const audio = this.audio
    if (this.loadedIndex === this.index && audio && Number.isFinite(audio.duration)) {
      return Math.max(0, audio.duration - audio.currentTime)
    }
    return this.index >= 0 ? this.durationOf(this.index) : 0
  }

  /**
   * Top the buffer up toward BUFFER_TARGET_SECONDS of listening time (F2.1–F2.4).
   *
   * Walks forward from the playhead scheduling `prefetch` work until either the
   * target depth is scheduled or too much is already in flight, then reports how
   * much *contiguously ready* audio sits ahead — which is the only figure a
   * listener can actually hear, and the one the scrub bar paints.
   */
  private fill() {
    if (!this.doc || this.index < 0) return
    const rate = Math.max(0.1, this.hooks.prefs().rate)
    // At 2x, a minute of listening needs two minutes of source audio (F2.2).
    const targetSource = BUFFER_TARGET_SECONDS * rate

    let inFlight = 0
    for (const entry of this.cache.values()) {
      if (!entry.url && entry.priority === PREFETCH) inFlight++
    }

    // The current sentence only counts as buffered if its audio actually exists;
    // while we are waiting on it, depth ahead of the playhead is zero by
    // definition, however much is ready behind it.
    let contiguous = !!this.peek(this.index)?.url
    let ready = contiguous ? this.remainingInCurrent() : 0
    let readyThrough = contiguous ? this.index : this.index - 1
    let scheduled = 0

    for (let k = 1; this.index + k < this.total; k++) {
      // The floor wins over the target: three sentences ahead, always (F2.1).
      if (k > MIN_LOOKAHEAD && scheduled >= targetSource) break
      const j = this.index + k

      let entry = this.peek(j)
      if (!entry) {
        if (inFlight >= MAX_PREFETCH_INFLIGHT) break
        entry = this.ensure(j, PREFETCH)
        // A no-op catch keeps a prefetch failure from becoming an unhandled
        // rejection; the real error surfaces when we actually reach `j`.
        entry.promise.catch(() => {})
        if (!entry.url) inFlight++
      }

      const seconds = this.durationOf(j)
      scheduled += seconds
      if (contiguous && entry.url) {
        ready += seconds
        readyThrough = j
      } else {
        contiguous = false
      }
    }

    this.reportBuffer(ready / rate, readyThrough)
  }

  /** Report buffer depth, only on movement worth repainting. */
  private reportBuffer(seconds: number, readyThrough: number) {
    if (Math.abs(seconds - this.reportedBuffer) < 0.25 && readyThrough === this.reportedThrough) {
      return
    }
    this.reportedBuffer = seconds
    this.reportedThrough = readyThrough
    this.hooks.onBuffer(seconds, readyThrough)
  }

  private startFilling() {
    this.fill()
    if (this.fillTimer) return
    this.fillTimer = window.setInterval(() => this.fill(), FILL_INTERVAL_MS)
  }

  private stopFilling() {
    if (this.fillTimer) {
      clearInterval(this.fillTimer)
      this.fillTimer = 0
    }
  }

  // ── core play flow ────────────────────────────────────────────────────────

  /** Synthesize (if needed) and play sentence `i`, keeping the buffer fed. */
  private async playIndex(i: number) {
    if (!this.doc) return
    const n = this.total
    if (n === 0) return
    i = Math.min(n - 1, Math.max(0, i))

    // The extension was reloaded under the page: everything still cached would
    // play on for up to a minute, under a second reader the next Alt+A starts.
    if (!extensionAlive()) {
      this.halt(i, RELOADED_MESSAGE)
      return
    }

    this.wantPlaying = true
    // Halt the old sentence's highlight and drop its now-stale timing before we
    // move; the new windows are rebuilt on loadedmetadata.
    this.stopWordLoop()
    this.windows = []
    this.setIndex(i)
    const token = ++this.playToken

    const entry = this.ensure(i, NOW)
    this.startFilling()

    // Show buffering only if this sentence isn't already synthesized.
    if (!entry.url) this.setStatus('buffering')

    let url: string
    try {
      url = await entry.promise
    } catch (err) {
      // Superseded or intentionally aborted → silently stand down.
      if (token !== this.playToken || isAbortError(err)) return
      // Look-ahead the backend turned away as busy (429, prefetch lane full —
      // another tab or the web app can fill it) or warming (503) says nothing
      // about this sentence: ask again in the `now` lane, which is never turned
      // away for being full. synth() already dropped the failed entry, so
      // ensure() makes a fresh one. A `now` failure still skips (G032).
      if (
        entry.priority === PREFETCH &&
        err instanceof SynthesisError &&
        BUSY_STATUSES.has(err.status)
      ) {
        if (this.wantPlaying) void this.playIndex(i)
        else this.ensure(i, NOW).promise.catch(() => {})
        return
      }
      this.skipSentence(i, err)
      return
    }

    // A newer play/seek/stop happened while we were synthesizing → abandon.
    if (token !== this.playToken) return

    if (url === SILENT) {
      // Nothing to say: step past it as if it had played. Neither a failure nor
      // a success, so the streak stands either way.
      if (this.wantPlaying) this.advanceFrom(i)
      return
    }

    const audio = this.ensureAudio()
    // Adopt the tokens now so the 'loadedmetadata' fired by the next line has
    // something to lay out.
    this.prepareWords(i)
    audio.src = url
    audio.playbackRate = this.hooks.prefs().rate
    this.loadedIndex = i

    // Paused during buffering: leave the sentence cued but don't start.
    if (!this.wantPlaying) {
      this.setStatus('paused')
      return
    }

    this.setStatus('playing')
    try {
      await audio.play()
    } catch (err) {
      // play() rejects if superseded (src swapped / paused) — expected and
      // harmless — or because it can't play at all, which must not pass for
      // playing.
      if (token !== this.playToken || isAbortError(err)) return
      this.playRefused(i, err)
      return
    }
    if (token !== this.playToken) return
    // A sentence that actually started playing clears the failure streak (the
    // error it produced already went with status 'playing', F4.1). Not before:
    // a clip that synthesizes but won't play is a failure too, and a run of
    // them must stop rather than skip through the page.
    this.streak = []
    this.startWordLoop()
  }

  /**
   * audio.play() said no. Autoplay policy (NotAllowedError) is the common case;
   * stand down to `paused` and ask for the click that unlocks audio, so the next
   * play resumes this sentence. Anything else means this clip will not play:
   * skip it like a failed synthesis.
   */
  private playRefused(i: number, err: unknown) {
    this.stopWordLoop()
    if ((err as { name?: string } | null)?.name === 'NotAllowedError') {
      this.wantPlaying = false
      this.stopFilling()
      this.setStatus('paused', AUTOPLAY_BLOCKED_MESSAGE)
      return
    }
    // Both the 'error' event and the play() rejection report one bad clip;
    // whichever arrives first acts, and the token turns the other stale.
    this.playToken++
    this.loadedIndex = -1
    this.skipSentence(i, err)
  }

  /** The loaded clip failed to load or decode (see ensureAudio). */
  private onAudioError() {
    const i = this.loadedIndex
    if (!this.wantPlaying || i < 0 || i !== this.index) return
    this.playRefused(i, new DOMException('This sentence’s audio could not be played.', 'NotSupportedError'))
  }

  /**
   * A sentence exhausted every retry. Mark it, tell the UI, and keep going —
   * one unreadable sentence must never end the session (F1.5).
   *
   * A *run* of them is different in kind: that is the engine having gone away,
   * and racing through the rest of the page in silence would be worse than
   * stopping and saying so.
   */
  private skipSentence(i: number, err: unknown) {
    const message = describeFailure(err)

    // Nothing reached an engine, so the sentence is not the problem. Skipping
    // would only race through the opening of the page on the way to a stop.
    if (err instanceof SynthesisError && err.status === 0) {
      this.halt(i, message)
      return
    }

    this.skipped.add(i)
    // A 400 is this sentence's fault, not the engine's (see describeFailure).
    this.streak.push({ index: i, rewind: !(err instanceof SynthesisError && err.status === 400) })
    this.hooks.onSkip(i, message)

    if (this.streak.length >= MAX_CONSECUTIVE_SKIPS) {
      // Stop where the engine's failures began: those sentences weren't at
      // fault, and resuming must read them rather than start past them. A
      // sentence the engine refused stays skipped — stopping on it would only
      // stop on it again at every resume (G017) — so a run of nothing else
      // stops just past it.
      const retry = this.streak.filter((s) => s.rewind).map((s) => s.index)
      for (const j of retry) this.skipped.delete(j)
      if (retry.length > 0 || i + 1 < this.total) {
        this.halt(retry.length > 0 ? retry[0] : i + 1, message)
        return
      }
      this.streak = []
    }
    if (!this.wantPlaying) {
      this.setStatus('paused')
      return
    }
    if (i + 1 >= this.total) {
      this.wantPlaying = false
      this.stopWordLoop()
      this.stopFilling()
      this.setStatus('ended')
      return
    }
    void this.playIndex(i + 1)
  }

  /** Stop on sentence `i` with an error. play() starts again from exactly there. */
  private halt(i: number, message: string) {
    this.wantPlaying = false
    this.playToken++
    this.stopWordLoop()
    this.stopFilling()
    this.streak = []
    this.loadedIndex = -1
    this.setIndex(i)
    this.setStatus('error', message)
  }

  /** Fired when a sentence finishes: auto-advance, or end the document. */
  private onEnded() {
    if (!this.wantPlaying) return
    this.advanceFrom(this.index)
  }

  /** Sentence `i` is done: play the next one, or end the document. */
  private advanceFrom(i: number) {
    if (i + 1 >= this.total) {
      // Leave the final word lit as a natural resting state.
      this.wantPlaying = false
      this.playToken++
      this.stopWordLoop()
      this.stopFilling()
      this.setStatus('ended')
      return
    }
    void this.playIndex(i + 1)
  }

  // ── public API ────────────────────────────────────────────────────────────

  /** Attach a freshly extracted document and reset playback to its start. */
  load(doc: ReadDoc) {
    this.reset()
    this.doc = doc
    this.index = 0
    this.loadedIndex = -1
    this.wantPlaying = false
    this.hooks.onSentence(0)
    this.setStatus('ready')
  }

  /** Begin/resume playback from the current sentence. */
  play() {
    if (!this.doc) return
    if (!extensionAlive()) {
      this.halt(Math.max(0, this.index), RELOADED_MESSAGE)
      return
    }
    const audio = this.ensureAudio()

    // Resume-in-place: if we're merely paused mid-sentence and that sentence's
    // audio is still loaded, resume without re-synthesizing so we keep the exact
    // playback position instead of restarting the sentence.
    if (this.loadedIndex === this.index && this.index >= 0 && !audio.ended && audio.currentSrc) {
      this.wantPlaying = true
      audio.playbackRate = this.hooks.prefs().rate
      this.setStatus('playing')
      const token = this.playToken
      audio.play().then(
        () => {
          if (token === this.playToken) this.streak = []
        },
        (err: unknown) => {
          if (token === this.playToken && !isAbortError(err)) this.playRefused(this.index, err)
        },
      )
      this.startFilling()
      this.startWordLoop()
      return
    }

    void this.playIndex(this.index < 0 ? 0 : this.index)
  }

  /** Pause without losing position. */
  pause() {
    this.wantPlaying = false
    this.audio?.pause()
    // Freeze the highlight loop but keep the last word lit while paused.
    this.stopWordLoop()
    this.stopFilling()
    this.setStatus('paused')
  }

  toggle() {
    if (this.currentStatus === 'playing' || this.currentStatus === 'buffering') this.pause()
    else this.play()
  }

  next() {
    this.jump(this.index + 1)
  }

  prev() {
    this.jump(this.index - 1)
  }

  /** Move to a neighbouring sentence, preserving whether we were playing. */
  private jump(target: number) {
    if (!this.doc) return
    const i = Math.min(this.total - 1, Math.max(0, target))
    // The user moved: failures behind them say nothing about where they went,
    // and a stop must never send them back there (G018).
    this.streak = []
    const wasPlaying =
      this.wantPlaying || this.currentStatus === 'playing' || this.currentStatus === 'buffering'

    this.audio?.pause()

    if (wasPlaying) {
      void this.playIndex(i)
      return
    }
    // Cue the new sentence without playing, so a later play() starts here.
    this.playToken++
    this.stopWordLoop()
    this.windows = []
    this.loadedIndex = -1
    this.setIndex(i)
    this.ensure(i, NOW).promise.catch(() => {})
    this.fill()
    if (this.currentStatus !== 'ready') this.setStatus('paused')
  }

  /** Jump to a specific sentence and play from there. */
  seekTo(index: number) {
    if (!this.doc) return
    this.streak = [] // a fresh start, as in jump() (G018)
    this.audio?.pause()
    void this.playIndex(index)
  }

  /**
   * React to a settings change. Rate is live (no re-synthesis); voice or skip
   * mode invalidate the cache and re-synthesize the current sentence so the
   * change is audible immediately rather than at the next sentence boundary.
   */
  applyPrefs() {
    const p = this.hooks.prefs()
    if (p.rate !== this.lastRate) {
      this.lastRate = p.rate
      if (this.audio) this.audio.playbackRate = p.rate
      // Buffer depth is denominated in listening time, so a rate change moves it
      // even though not a byte of audio changed.
      this.fill()
    }
    if (p.voiceId !== this.lastVoice || p.skipSkippable !== this.lastSkip) {
      this.lastVoice = p.voiceId
      this.lastSkip = p.skipSkippable
      this.reloadCurrent()
    }
  }

  /**
   * Stop the now-stale audio, drop cache entries for the old params, and
   * re-synthesize the CURRENT sentence at the new params, resuming playback if
   * we were playing.
   */
  private reloadCurrent() {
    if (!this.doc || this.index < 0) {
      this.invalidateStaleParams()
      return
    }
    const wasPlaying =
      this.wantPlaying || this.currentStatus === 'playing' || this.currentStatus === 'buffering'

    this.audio?.pause() // stop old-param audio before revoking its URL
    this.stopWordLoop()
    this.invalidateStaleParams()
    // New params are a new engine request for every sentence (G018).
    this.streak = []
    this.loadedIndex = -1
    this.reportedBuffer = -1
    this.reportedThrough = -2

    if (wasPlaying) {
      void this.playIndex(this.index)
      return
    }
    // Re-synth restarts the sentence from its start, so clear the word highlight.
    this.playToken++
    this.windows = []
    this.lastWordIndex = -1
    this.hooks.onWord(-1)
    this.ensure(this.index, NOW).promise.catch(() => {})
    this.fill()
  }

  /** Tear down audio + buffers but leave the object reusable. */
  private reset() {
    this.playToken++
    this.wantPlaying = false
    this.stopWordLoop()
    this.stopFilling()

    if (this.audio) {
      this.audio.pause()
      this.audio.removeAttribute('src')
      this.audio.load() // detach any loaded resource
    }

    for (const entry of this.cache.values()) this.dropResources(entry)
    this.cache.clear()
    this.cacheBytes = 0

    this.doc = null
    this.index = -1
    this.loadedIndex = -1
    this.tokens = []
    this.windows = []
    this.lastWordIndex = -1
    this.skipped.clear()
    this.streak = []
    this.reportedBuffer = -1
    this.reportedThrough = -2
    this.hooks.onBuffer(0, -1)
  }

  /** Stop, clear buffers, and detach the document. */
  stop() {
    this.reset()
    this.hooks.onSentence(-1)
    this.hooks.onWord(-1)
    this.setStatus('idle')
  }
}

/**
 * User-facing copy for a spent synthesis.
 *
 * The distinction that earns its keep: a 400 means *this sentence* is the
 * problem and the rest of the page will read fine, so the message must not
 * suggest the engine is broken (F1.7 — never blame a component that is working).
 */
function describeFailure(err: unknown): string {
  if (err instanceof SynthesisError) {
    // The backend is fine; the page lost the extension and must be refreshed.
    if (err.reloaded) return err.message
    if (err.status === 400) return 'Skipped a sentence the voice engine couldn’t read.'
    if (err.status === 0) return 'Speech engine unreachable — is the Aloud backend running?'
    if (err.timedOut) return 'The voice engine took too long — skipped a sentence.'
    return 'Skipped a sentence the voice engine couldn’t read.'
  }
  // The clip arrived but the browser could not play it.
  if ((err as { name?: string } | null)?.name === 'NotSupportedError') {
    return 'Skipped a sentence the browser couldn’t play.'
  }
  return err instanceof Error && err.message ? err.message : 'Skipped an unreadable sentence.'
}
