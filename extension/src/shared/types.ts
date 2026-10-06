// ─────────────────────────────────────────────────────────────────────────────
// Shared types for the Aloud extension.
//
// The Voice / WordToken / PlayerStatus shapes mirror the desktop reader
// (frontend/src/types.ts) so the two front-ends stay conceptually identical and
// speak to the same backend contract. ReadSentence is extension-specific: it
// carries the offsets we need to map a spoken sentence back onto live DOM.
// ─────────────────────────────────────────────────────────────────────────────

/** A selectable Kokoro voice, as returned by the backend GET /voices. */
export interface Voice {
  /** Kokoro voice id, e.g. "af_heart", "am_michael". */
  id: string
  /** Human-friendly display name, e.g. "Heart". */
  name: string
  /** BCP-47-ish language tag, e.g. "en-us", "en-gb". */
  lang: string
  /** Speaker gender where known. */
  gender: 'female' | 'male' | 'other'
}

/**
 * One display token of a sentence, produced for word-level read-along
 * highlighting. The split is non-destructive: concatenating the `text` of every
 * token reproduces the sentence verbatim, so token offsets are simply the
 * running sum of token lengths — which is exactly what we need to turn "word 7"
 * into a DOM Range.
 */
export interface WordToken {
  /** Exact source text of this token — a word (+its punctuation) or a whitespace run. */
  text: string
  /** True for highlightable word runs; false for whitespace runs (never highlighted). */
  isWord: boolean
  /**
   * Relative spoken-duration weight used to distribute a sentence's audio time
   * across its words. 0 for whitespace tokens; >= 1 for word tokens (estimated
   * syllables plus a small pause for trailing punctuation).
   */
  weight: number
  /**
   * True when this token falls entirely inside a bracketed span — `( )`, `[ ]`
   * or `{ }`. When "skip parentheticals" is on these are neither synthesized
   * nor highlighted.
   */
  isSkippable: boolean
}

/**
 * One spoken unit of the page. `start`/`end` index into the flat text built by
 * the extractor, which is what lets the highlighter rebuild a DOM Range for it.
 */
export interface ReadSentence {
  /** Stable index into ReadDoc.sentences (0-based). */
  id: number
  /** Verbatim slice of the flat page text — whitespace and newlines preserved. */
  raw: string
  /** Whitespace-normalized text: what we display and what we synthesize. */
  text: string
  /** Absolute [start, end) offsets into the flat page text. */
  start: number
  end: number
  /** Word tokens of `raw`, in order. Offsets are cumulative token lengths. */
  tokens: WordToken[]
}

/** Everything the player and highlighter need for one page (or one selection). */
export interface ReadDoc {
  /** Best-effort page/article title, shown in the player bar. */
  title: string
  /** All sentences in reading order. */
  sentences: ReadSentence[]
}

/**
 * What the local speech engine is doing, as far as the client can tell.
 *
 * These are three genuinely different situations and the UI must not conflate
 * them: `offline` is the user's problem to fix (start the backend), `warming`
 * fixes itself in a few seconds, and `ok` deserves no chrome at all. Reporting
 * a warming engine as "offline" — which is what we used to do — slanders a
 * backend that is working exactly as designed.
 */
export type EngineState =
  | 'ok' // model loaded, warm-up finished
  | 'warming' // reachable, still doing its first inference
  | 'offline' // unreachable, or answering with something we don't understand

/**
 * The engine as a reader on a page sees it. `reloaded` is not the engine at all:
 * the extension was reloaded or updated under the page, so nothing the page asks
 * can be answered until it is refreshed — and the backend is not to blame.
 */
export type ReaderEngineState = EngineState | 'reloaded'

/** Player lifecycle. */
export type PlayerStatus =
  | 'idle' // nothing loaded
  | 'ready' // page parsed, not playing
  | 'playing'
  | 'paused'
  | 'buffering' // waiting on synthesis for the current sentence
  | 'ended' // reached the end of the page
  | 'error'

/** User-tunable settings, persisted in chrome.storage.sync. */
export interface Prefs {
  /** Kokoro voice id. */
  voiceId: string
  /** Playback rate multiplier, 0.5–3.0. Applied client-side, never re-synthesized. */
  rate: number
  /** Skip bracketed/parenthetical content when reading aloud. */
  skipSkippable: boolean
  /** Keep the spoken sentence scrolled into view. */
  autoScroll: boolean
  /** Clicking a sentence on the page jumps playback there. */
  clickToJump: boolean
  /** Paint the karaoke word highlight on top of the sentence highlight. */
  highlightWords: boolean
  /** Where the local Aloud TTS server lives. */
  backendUrl: string
}
