// ─────────────────────────────────────────────────────────────────────────────
// Playback engine.
// The player owns audio: it synthesizes sentences via the backend (with lookahead
// buffering + caching), plays them gaplessly, auto-advances, and drives the store
// (status, currentSentence, error). The UI calls these methods; it never touches
// audio directly.
//
// ── How gap-free playback works ────────────────────────────────────────────────
// Every sentence is synthesized to a WAV blob, wrapped in an object URL, and cached
// keyed by `${voiceId}|${rate}|${sentenceId}`. When we play sentence N we (a) ensure
// N's audio, and (b) fire-and-forget PREFETCH of N+1 and N+2 concurrently. Kokoro
// synthesizes ~5x faster than realtime, so by the time N finishes playing, N+1's
// object URL is already resolved in the cache and we can `audio.src = url; play()`
// with no audible gap. If N itself isn't ready yet we surface status 'buffering'
// until its blob lands, then 'playing'.
//
// ── Cache invalidation ─────────────────────────────────────────────────────────
// The key embeds voice + rate, so changing either simply routes future lookups to
// fresh keys — old entries can never be mistakenly replayed. On voice/rate change
// we also actively DROP every entry whose key no longer matches the current
// params: in-flight requests are aborted (to stop wasting the backend) and resolved
// object URLs are revoked (to free memory). An LRU cap (MAX_CACHE) bounds total
// live URLs; evicting an entry aborts it if in-flight or revokes its URL if resolved.
//
// ── Stale-continuation guard ───────────────────────────────────────────────────
// Async synth results can arrive after the user has moved on. A monotonic
// `playToken` is captured when a play starts; any continuation whose token no
// longer matches the current one is a no-op. Combined with AbortController on the
// fetch, this guarantees we never play audio for a superseded position.
// ─────────────────────────────────────────────────────────────────────────────
import { synthesize, SynthesisError } from './api'
import { spokenText, tokenizeSentence } from './chunker'
import { useStore } from '../store'
import type { Doc, SynthesisPriority, WordToken } from '../types'

export interface Player {
  /** Attach a freshly parsed document and reset playback to its start. */
  load(doc: Doc): void
  /** Begin/resume playback from the current sentence. */
  play(): void
  /** Pause without losing position. */
  pause(): void
  /** Toggle play/pause. */
  toggle(): void
  /** Advance to the next sentence (keeps playing if playing). */
  next(): void
  /** Go back one sentence (keeps playing if playing). */
  prev(): void
  /** Jump to a specific sentence index and play from there. */
  seekTo(index: number): void
  /** Change playback rate (0.5–3.0); applied live via playbackRate, no re-synth. */
  setRate(rate: number): void
  /** Change voice by id; re-synthesizes upcoming audio with the new voice. */
  setVoice(voiceId: string): void
  /** Toggle skipping of bracketed/parenthetical content; re-synthesizes the current sentence. */
  setSkipSkippable(skip: boolean): void
  /** Stop, clear buffers, and detach the current document. */
  stop(): void
}

/** Max number of live object URLs / cache entries kept at once (LRU). */
const MAX_CACHE = 30
/** How many sentences ahead of the current one to prefetch concurrently. */
const LOOKAHEAD = 2
/** Cache marker for a sentence with nothing to say (no request is made). */
const SILENT = 'silent:'
/** Letters or digits in any script: anything else is not worth a request. */
const HAS_SPEAKABLE = /[\p{L}\p{N}]/u
/** Unreadable sentences in a row before playback gives up and reports it. */
const MAX_CONSECUTIVE_SKIPS = 3

/** Convenience accessor for the freshest store state on every call. */
const store = () => useStore.getState()

/** One cache slot: the pending/settled synth for a `${voice}|${rate}|${id}` key. */
interface CacheEntry {
  key: string
  /** Resolves to the object URL of the synthesized WAV. */
  promise: Promise<string>
  /** Set once resolved, so we can revoke on eviction. Null while in-flight. */
  url: string | null
  /** Aborts the underlying fetch when the entry becomes stale. */
  controller: AbortController
}

function errorName(err: unknown): string | undefined {
  return typeof err === 'object' && err !== null ? (err as { name?: string }).name : undefined
}

function isAbortError(err: unknown): boolean {
  return errorName(err) === 'AbortError'
}

class PlayerImpl implements Player {
  private doc: Doc | null = null
  private audio: HTMLAudioElement | null = null

  /** Sentence index we intend to be on (mirrors store.currentSentence). */
  private index = -1
  /** Index whose object URL is currently loaded on the audio element (-1 = none). */
  private loadedIndex = -1
  /** Whether we intend audio to be running (drives auto-advance on 'ended'). */
  private wantPlaying = false
  /** Bumped whenever the active position changes; stale continuations check it. */
  private playToken = 0
  /**
   * Sentences skipped in a row because the backend couldn't read them or the
   * browser couldn't play them. Reset once a sentence actually starts playing.
   */
  private consecutiveSkips = 0

  // ── word-level highlight (karaoke) ──────────────────────────────────────────
  /** Word tokens of the sentence whose audio is currently loaded on the element. */
  private tokens: WordToken[] = []
  /**
   * Per-word time windows for the loaded sentence, in playback order. Built once
   * the audio's real duration is known and re-derived on voice/rate reloads.
   * `token` indexes back into `tokens`; whitespace tokens are skipped (no window).
   */
  private windows: Array<{ start: number; end: number; token: number }> = []
  /** rAF handle for the highlight loop (0 = not running). */
  private rafId = 0
  /** Last word index pushed to the store; guards against per-frame setState. */
  private lastWordIndex = -1

  // Insertion-ordered Map = our LRU; oldest key is first. Entries are re-inserted
  // (touched) on access so recently used sentences survive eviction.
  private cache = new Map<string, CacheEntry>()

  // ── audio element (created lazily so importing this module never touches DOM) ──
  private ensureAudio(): HTMLAudioElement {
    if (!this.audio) {
      const a = new Audio()
      a.preload = 'auto'
      // Rate is applied client-side via playbackRate (pitch preserved) so we can
      // reach a true 3x and change speed instantly without re-synthesizing. Every
      // clip is synthesized at Kokoro speed 1.0 (natural duration).
      a.preservesPitch = true
      a.playbackRate = store().rate
      a.addEventListener('ended', () => this.onEnded())
      // The natural (1.0x) WAV duration lands here; per-word windows are laid out in
      // media-time, so raising playbackRate speeds the highlight in lockstep.
      a.addEventListener('loadedmetadata', () => this.onLoadedMetadata())
      // A clip the element can't decode never fires 'ended'; without this the
      // player would sit on 'playing' in silence.
      a.addEventListener('error', () => this.onMediaError())
      this.audio = a
    }
    return this.audio
  }

  private setIndex(i: number) {
    // The store clears currentWord whenever the sentence changes; mirror that
    // locally so the next real word is guaranteed to be pushed (never suppressed
    // by a stale lastWordIndex from the previous sentence).
    if (i !== this.index) this.lastWordIndex = -1
    this.index = i
    store().setCurrentSentence(i)
  }

  // ── word-level highlight ────────────────────────────────────────────────────

  /**
   * Tokenize sentence `i` for the highlight and reset per-word state. Called at
   * the moment its audio is assigned to the element; the actual time windows are
   * filled in by onLoadedMetadata() once the WAV's duration is known.
   */
  private prepareWords(i: number) {
    const sentence = this.doc?.sentences[i]
    this.tokens = sentence ? tokenizeSentence(sentence.text) : []
    this.windows = []
    this.lastWordIndex = -1
    store().setCurrentWord(-1)
  }

  /**
   * Distribute the sentence's real audio duration across its word tokens by weight.
   * When skipping is on, skippable (bracketed) tokens are omitted from BOTH the
   * total and the window layout — they aren't in the spoken audio, so giving them
   * no window keeps every remaining window aligned and ensures they can never be
   * reported as the active word.
   */
  private computeWindows(duration: number) {
    this.windows = []
    const skip = store().skipSkippable
    const spoken = (tk: WordToken) => tk.weight > 0 && !(skip && tk.isSkippable)
    let total = 0
    for (const tk of this.tokens) if (spoken(tk)) total += tk.weight
    if (total <= 0 || !(duration > 0)) return
    let acc = 0
    for (let i = 0; i < this.tokens.length; i++) {
      const tk = this.tokens[i]
      if (!spoken(tk)) continue // whitespace + skipped tokens carry no time / highlight
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

  /** rAF body: map audio.currentTime → active word, pushing the store only on change. */
  private wordLoop = () => {
    const audio = this.audio
    if (!audio || !this.wantPlaying) {
      this.rafId = 0
      return
    }
    const idx = this.wordIndexAt(audio.currentTime)
    if (idx !== this.lastWordIndex) {
      this.lastWordIndex = idx
      store().setCurrentWord(idx)
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

  // ── cache ─────────────────────────────────────────────────────────────────────

  /**
   * Return the cache entry for `sentenceId` at the CURRENT voice+rate, creating it
   * (and kicking off synthesis) on a miss. Touches the entry for LRU freshness.
   *
   * `priority` picks the backend's queue lane: `now` for the sentence the user is
   * on, `prefetch` for look-ahead, so speculative work never delays a sentence
   * someone is waiting to hear. An entry already in flight keeps the lane it was
   * created with (the backend has queued it); that just means prefetch got there
   * first.
   */
  private ensure(sentenceId: number, priority: SynthesisPriority = 'now'): CacheEntry {
    const { voiceId, skipSkippable } = store()
    // Rate is NOT in the key: every clip is synthesized at speed 1.0 and sped up
    // client-side via playbackRate, so one cached WAV serves all rates. The skip
    // flag stays in the key so spoken-vs-skipped parentheticals cache independently.
    const key = `${voiceId}|${skipSkippable ? 's' : 'f'}|${sentenceId}`

    const hit = this.cache.get(key)
    if (hit) {
      // LRU touch: re-insert to move to the newest (last) position.
      this.cache.delete(key)
      this.cache.set(key, hit)
      return hit
    }

    const sentence = this.doc!.sentences[sentenceId]
    const controller = new AbortController()
    const entry: CacheEntry = {
      key,
      url: null,
      controller,
      // Throwaway placeholder; overwritten on the next line. Keeps the type honest
      // without an `undefined!` cast.
      promise: Promise.resolve(''),
    }
    // When skipping is on, synthesize only the non-skippable (spoken) text. Always
    // at speed 1.0 — playback rate is applied on the audio element, not baked in.
    const text = spokenText(sentence.text, skipSkippable)
    if (!HAS_SPEAKABLE.test(text)) {
      // Nothing to say (a fully bracketed aside, a rule line): never ask the
      // backend — it answers 400 for empty text. playIndex steps past it.
      entry.url = SILENT
      entry.promise = Promise.resolve(SILENT)
    } else {
      entry.promise = this.synth(entry, text, voiceId, 1, priority)
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
    speed: number,
    priority: SynthesisPriority,
  ): Promise<string> {
    try {
      const blob = await synthesize({ text, voice, speed, priority }, entry.controller.signal)
      const url = URL.createObjectURL(blob)
      entry.url = url
      // If we were evicted/invalidated while the request was in flight, no one is
      // waiting on this URL any more — revoke it now so it can't leak.
      if (this.cache.get(entry.key) !== entry) URL.revokeObjectURL(url)
      return url
    } catch (err) {
      // Drop failed/aborted entries so a later visit re-attempts synthesis.
      if (this.cache.get(entry.key) === entry) this.cache.delete(entry.key)
      throw err
    }
  }

  /** Enforce the LRU cap by dropping oldest entries. */
  private evict() {
    while (this.cache.size > MAX_CACHE) {
      const oldestKey = this.cache.keys().next().value as string | undefined
      if (oldestKey === undefined) break
      const entry = this.cache.get(oldestKey)!
      this.cache.delete(oldestKey)
      this.dropResources(entry)
    }
  }

  /** Free an entry's resources: abort if in-flight, revoke its URL if resolved. */
  private dropResources(entry: CacheEntry) {
    if (entry.url === SILENT) return
    if (entry.url) URL.revokeObjectURL(entry.url)
    else entry.controller.abort()
  }

  /** Drop every cached entry whose key doesn't match the current voice+rate+skip. */
  private invalidateStaleParams() {
    const { voiceId, skipSkippable } = store()
    const prefix = `${voiceId}|${skipSkippable ? 's' : 'f'}|`
    for (const [key, entry] of [...this.cache]) {
      if (!key.startsWith(prefix)) {
        this.cache.delete(key)
        this.dropResources(entry)
      }
    }
  }

  /** Prefetch the next LOOKAHEAD sentences so their audio is ready on advance. */
  private prefetchAround(i: number) {
    const n = this.doc?.sentences.length ?? 0
    for (let k = 1; k <= LOOKAHEAD; k++) {
      const j = i + k
      if (j >= 0 && j < n) {
        // Attach a no-op catch so a prefetch failure/abort never becomes an
        // unhandled rejection; the real error surfaces when we actually reach `j`.
        this.ensure(j, 'prefetch').promise.catch(() => {})
      }
    }
  }

  // ── core play flow ──────────────────────────────────────────────────────────

  /** Synthesize (if needed) and play sentence `i`, then keep it + neighbors warm. */
  private async playIndex(i: number) {
    if (!this.doc) return
    const n = this.doc.sentences.length
    if (n === 0) return
    i = Math.min(n - 1, Math.max(0, i))

    this.wantPlaying = true
    // Halt the old sentence's highlight and drop its (now-stale) timing before we
    // switch position; the new sentence's windows are rebuilt on loadedmetadata.
    this.stopWordLoop()
    this.windows = []
    this.setIndex(i)
    const token = ++this.playToken

    const entry = this.ensure(i)
    this.prefetchAround(i)

    // Show buffering only if the current sentence isn't already synthesized.
    if (!entry.url) store().setStatus('buffering')

    let url: string
    try {
      url = await entry.promise
    } catch (err) {
      // Superseded or intentionally aborted → silently stand down.
      if (token !== this.playToken || isAbortError(err)) return
      // The backend answered but can't read THIS sentence (400, or retries
      // spent on a non-transport error): skip it and keep playing, as the
      // API contract says. Only a transport failure means the engine is down,
      // so a run of unreadable sentences stops without blaming the engine.
      if (err instanceof SynthesisError && err.status !== null) {
        if (!this.skip(i)) {
          this.stopAfterSkips(
            'The speech engine couldn\u2019t read these sentences \u2014 try skipping ahead.',
          )
        }
        return
      }
      this.handleSynthError()
      return
    }

    // A newer play/seek/stop happened while we were synthesizing → abandon.
    if (token !== this.playToken) return

    if (url === SILENT) {
      // Intentionally silent sentence: step past it without playing audio.
      this.advanceFrom(i)
      return
    }

    // The engine answered: clear the offline badge and banner (F4.1, F4.4), and
    // this sentence's skipped mark if an earlier attempt failed.
    const s = store()
    s.setEngineState('ok')
    if (s.error) s.setError(null)
    s.unmarkSkipped(i)
    const audio = this.ensureAudio()
    // Tokenize the sentence now so the 'loadedmetadata' fired by the next line
    // has tokens to lay out. Also resets the highlight for the fresh sentence.
    this.prepareWords(i)
    audio.src = url
    audio.playbackRate = store().rate // re-assert the chosen rate for the new clip
    this.loadedIndex = i

    // Paused during buffering: leave the sentence cued but don't start playing.
    if (!this.wantPlaying) {
      store().setStatus('paused')
      return
    }

    store().setStatus('playing')
    try {
      await audio.play()
    } catch (err) {
      // play() rejects if superseded (src swapped / paused): ignore those. Any
      // other refusal must not leave the status on 'playing' with no audio.
      if (token !== this.playToken || isAbortError(err)) return
      this.onPlayRejected(err, i)
      return
    }
    // Only drive the highlight for the position we're actually still on.
    if (token !== this.playToken) return
    this.consecutiveSkips = 0
    this.startWordLoop()
  }

  /**
   * Step over sentence `i`, which the backend couldn't read or the browser
   * couldn't play, and keep going (F1.5): mark it in the reader and say so.
   * Returns false once too many have failed in a row, so the caller stops and
   * reports it instead of skipping through the whole book.
   */
  private skip(i: number): boolean {
    if (this.consecutiveSkips >= MAX_CONSECUTIVE_SKIPS - 1) return false
    this.consecutiveSkips++
    store().markSkipped(i)
    store().pushToast('Skipped a sentence that couldn\u2019t be read')
    this.advanceFrom(i)
    return true
  }

  /**
   * play() refused to start sentence `i`. An autoplay block (Safari runs the first
   * play() after the synth fetch, outside the click) pauses with a hint, and the
   * next press resumes in place inside a gesture. Any other refusal means the clip
   * can't be played, so it is stepped over like an unreadable sentence.
   */
  private onPlayRejected(err: unknown, i: number) {
    if (errorName(err) === 'NotAllowedError') {
      this.wantPlaying = false
      this.stopWordLoop()
      store().setStatus('paused')
      store().pushToast('Press play to start audio')
      return
    }
    this.skipUnplayable(i)
  }

  /**
   * The element failed on the clip it was playing (undecodable or cut-off audio).
   * Only the clip for the current position counts: a late error for a clip already
   * replaced is ignored, and a paused clip's failure surfaces when play() rejects
   * on resume.
   */
  private onMediaError() {
    if (!this.wantPlaying || !this.audio?.error || this.loadedIndex !== this.index) return
    this.playToken++ // the pending play() for this clip no longer matters
    this.stopWordLoop()
    this.skipUnplayable(this.index)
  }

  /** Skip an unplayable sentence, or stop with an error after too many in a row. */
  private skipUnplayable(i: number) {
    if (this.skip(i)) return
    this.stopAfterSkips('Couldn\u2019t play the audio for these sentences \u2014 try reloading the page.')
  }

  /** Too many sentences failed in a row: stop and say why (the engine itself is up). */
  private stopAfterSkips(message: string) {
    this.wantPlaying = false
    this.consecutiveSkips = 0
    this.stopWordLoop()
    store().setError(message)
    store().setStatus('error')
  }

  /** Move past sentence `i` without playing it (silent or skipped). */
  private advanceFrom(i: number) {
    if (!this.wantPlaying) {
      store().setStatus('paused')
      return
    }
    this.onEnded()
  }

  /** Fired when a sentence finishes: auto-advance, or end the document. */
  private onEnded() {
    if (!this.wantPlaying) return
    const n = this.doc?.sentences.length ?? 0
    if (this.index + 1 >= n) {
      // Reached the end of the document. Stop the loop but leave the final word
      // lit as a natural resting state.
      this.wantPlaying = false
      this.playToken++ // invalidate any pending continuation
      this.stopWordLoop()
      store().setStatus('ended')
      return
    }
    this.playIndex(this.index + 1)
  }

  private handleSynthError() {
    this.wantPlaying = false
    this.consecutiveSkips = 0
    const s = store()
    s.setEngineState('offline')
    s.setError('Speech engine offline — is the backend running?')
    s.setStatus('error')
  }

  // ── public API ────────────────────────────────────────────────────────────────

  load(doc: Doc) {
    this.stop()
    this.doc = doc
    // Reset position to the first sentence and mark the document ready.
    this.index = 0
    this.loadedIndex = -1
    this.wantPlaying = false
    store().setCurrentSentence(0)
    store().setError(null)
    store().setStatus('ready')
  }

  play() {
    if (!this.doc) return
    const audio = this.ensureAudio()

    // Resume-in-place: if we're merely paused mid-sentence and the current
    // sentence's audio is still loaded, resume without re-synthesizing (keeps the
    // exact playback position instead of restarting the sentence).
    if (
      this.loadedIndex === this.index &&
      this.index >= 0 &&
      !audio.ended &&
      audio.currentSrc
    ) {
      this.wantPlaying = true
      audio.playbackRate = store().rate
      store().setStatus('playing')
      const token = this.playToken
      const i = this.index
      audio.play().then(
        () => {
          if (token === this.playToken) this.consecutiveSkips = 0
        },
        (err) => {
          if (token !== this.playToken || isAbortError(err)) return
          this.onPlayRejected(err, i)
        },
      )
      this.prefetchAround(this.index)
      // Resume the highlight in place — tokens/windows for this sentence are
      // still valid, so it picks up from the current playback position.
      this.startWordLoop()
      return
    }

    this.playIndex(this.index < 0 ? 0 : this.index)
  }

  pause() {
    this.wantPlaying = false
    if (this.audio) this.audio.pause()
    // Freeze the highlight loop but keep the last word lit while paused.
    this.stopWordLoop()
    store().setStatus('paused')
  }

  toggle() {
    const s = store().status
    if (s === 'playing' || s === 'buffering') this.pause()
    else this.play()
  }

  next() {
    if (!this.doc) return
    this.jump(this.index + 1)
  }

  prev() {
    if (!this.doc) return
    this.jump(this.index - 1)
  }

  /** Move to a neighbouring sentence, preserving whether we were playing. */
  private jump(target: number) {
    if (!this.doc) return
    const n = this.doc.sentences.length
    const i = Math.min(n - 1, Math.max(0, target))
    const wasPlaying =
      this.wantPlaying || store().status === 'playing' || store().status === 'buffering'

    if (this.audio) this.audio.pause()

    if (wasPlaying) {
      this.playIndex(i)
    } else {
      // Cue the new sentence without playing (so a later play() starts here).
      this.playToken++ // invalidate any pending continuation
      this.stopWordLoop()
      this.windows = []
      this.loadedIndex = -1
      this.setIndex(i) // clears currentWord in the store on sentence change
      this.ensure(i).promise.catch(() => {})
      this.prefetchAround(i)
      if (store().status !== 'ready') store().setStatus('paused')
    }
  }

  seekTo(index: number) {
    if (!this.doc) return
    if (this.audio) this.audio.pause()
    // seekTo always plays from the target (playIndex clamps the index).
    this.playIndex(index)
  }

  setRate(rate: number) {
    store().setRate(rate) // clamps to 0.5–3.0 and persists
    // Applied live on the element — no re-synthesis, instant even mid-sentence.
    if (this.audio) this.audio.playbackRate = store().rate
  }

  setVoice(voiceId: string) {
    store().setVoiceId(voiceId)
    this.reloadCurrent()
  }

  setSkipSkippable(skip: boolean) {
    if (store().skipSkippable === skip) return
    store().setSkipSkippable(skip)
    // Same lifecycle as a voice/rate change: drop now-stale-skip cache entries and
    // re-synthesize the current sentence with the new setting, preserving play state.
    this.reloadCurrent()
  }

  /**
   * Shared by setRate/setVoice: stop the now-stale audio, drop cache entries for
   * the old params, and re-synthesize the CURRENT sentence at the new params for
   * immediate feedback (resuming playback if we were playing).
   */
  private reloadCurrent() {
    if (!this.doc || this.index < 0) {
      // Nothing cued yet — just discard any stale-param entries.
      this.invalidateStaleParams()
      return
    }
    const wasPlaying =
      this.wantPlaying || store().status === 'playing' || store().status === 'buffering'

    if (this.audio) this.audio.pause() // stop old-param audio before revoking URLs
    this.stopWordLoop()
    this.invalidateStaleParams() // abort in-flight old-param synths + revoke URLs
    this.loadedIndex = -1

    if (wasPlaying) {
      this.playIndex(this.index)
    } else {
      // Re-synth restarts the sentence from its start, so clear the highlight.
      this.playToken++
      this.windows = []
      this.lastWordIndex = -1
      store().setCurrentWord(-1)
      this.ensure(this.index).promise.catch(() => {})
      this.prefetchAround(this.index)
    }
  }

  stop() {
    this.playToken++
    this.wantPlaying = false
    this.consecutiveSkips = 0
    this.stopWordLoop()

    if (this.audio) {
      this.audio.pause()
      this.audio.removeAttribute('src')
      this.audio.load() // detach any loaded resource
    }

    // Revoke every live URL and abort every in-flight request.
    for (const entry of this.cache.values()) this.dropResources(entry)
    this.cache.clear()

    this.doc = null
    this.index = -1
    this.loadedIndex = -1
    // Clear all word-highlight state on a full stop / new document.
    this.tokens = []
    this.windows = []
    this.lastWordIndex = -1
    store().setCurrentSentence(-1)
    store().setCurrentWord(-1)
    store().setStatus('idle')
  }
}

/** The single shared playback engine for the app. */
export const player: Player = new PlayerImpl()
