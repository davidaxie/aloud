// ─────────────────────────────────────────────────────────────────────────────
// Shared types — the contract every module builds against.
// Owned by scaffolding; agents import from here and must not redefine these.
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

/** One spoken unit — a sentence. The atom of playback + highlighting. */
export interface Sentence {
  /** Stable index into Doc.sentences (0-based). */
  id: number
  /** The sentence text to synthesize + display. */
  text: string
  /** 0-based paragraph index this sentence belongs to. */
  para: number
  /** 1-based source PDF page this sentence starts on. */
  page: number
}

/**
 * One display token of a sentence, produced for word-level read-along
 * highlighting. The split is non-destructive: concatenating the `text` of every
 * token of a sentence reproduces that sentence verbatim (whitespace + punctuation
 * preserved), so the reader can render tokens without altering the visible copy.
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
   * True when this token falls entirely inside a bracketed span — parentheses
   * `( )`, square brackets `[ ]`, or curly braces `{ }` (the bracket chars
   * themselves included). When the reader's "skip skippable content" option is on
   * these tokens are neither synthesized nor highlighted (they are dimmed in the
   * display); when off they read normally. Always false outside brackets.
   */
  isSkippable: boolean
}

/** A paragraph groups sentences for reader layout. */
export interface Paragraph {
  /** 0-based paragraph index (matches Sentence.para). */
  id: number
  /** Sentence ids in this paragraph, in order. */
  sentenceIds: number[]
  /** 1-based page this paragraph starts on. */
  page: number
}

/** A fully-parsed document ready to read + play. */
export interface Doc {
  /** Best-effort title (from PDF metadata or filename). */
  title: string
  /** Number of pages in the source PDF. */
  pageCount: number
  /** All sentences in reading order. */
  sentences: Sentence[]
  /** All paragraphs in reading order. */
  paragraphs: Paragraph[]
}

/** Player lifecycle. */
export type PlayerStatus =
  | 'idle' // no document
  | 'loading' // parsing a PDF
  | 'ready' // document parsed, not playing
  | 'playing'
  | 'paused'
  | 'buffering' // waiting on synthesis for the current sentence
  | 'ended' // reached the end of the document
  | 'error'

export type Theme = 'light' | 'dark'

/**
 * Scheduling class for a synthesis request (backend contract v1.1).
 *
 * The backend serializes all synthesis behind a single worker, so a speculative
 * prefetch queued a moment earlier would otherwise delay the sentence the user
 * is actually waiting for. `now` jumps the queue; `prefetch` waits and is the
 * only class subject to the queue bound.
 */
export type SynthesisPriority = 'now' | 'prefetch'

/** Request body for POST /synthesize. */
export interface SynthesizeRequest {
  text: string
  voice: string
  /** Playback rate multiplier, 0.5–2.0. Maps to Kokoro speed. */
  speed: number
  /** Defaults to 'now' when omitted. */
  priority?: SynthesisPriority
}

/**
 * Liveness of the local speech engine.
 *
 * Distinguishing `warming` from `offline` matters: during warm-up the backend is
 * healthy and about to work, and telling the user it is "offline" sends them to
 * check a server that is fine (UX-FEEDBACK P0-1, F1.7).
 */
export type EngineState =
  | 'unknown' // not probed yet
  | 'ok' // model loaded and warm
  | 'warming' // up, running its warm-up inference
  | 'offline' // /health did not answer

/** A transient, self-dismissing message. Recoverable problems use these. */
export interface Toast {
  /** Monotonic id; changing it re-triggers the display for a repeated message. */
  id: number
  text: string
}
