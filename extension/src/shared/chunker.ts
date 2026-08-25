// ─────────────────────────────────────────────────────────────────────────────
// Sentence chunking + word tokenization.
//
// Ported from the desktop reader (frontend/src/lib/chunker.ts) with one crucial
// change: the desktop version splits a *normalized* paragraph string and returns
// text, because it renders the text itself. Here the text already lives in the
// page's DOM, so every split must come back as OFFSETS into the original string
// — that is the only way to rebuild a Range over the live nodes.
//
// Hence `splitWithOffsets`, which:
//   1. Splits on sentence boundaries (Intl.Segmenter, which reports an `index`
//      for each segment; a manual offset-tracking scanner otherwise).
//   2. Merges boundaries that fell on abbreviations ("Dr.", "e.g.", "U.S.", …).
//   3. Soft-splits pathologically long sentences on clause boundaries so a
//      single TTS request never gets a giant blob.
//   4. Trims whitespace off each span by moving the offsets inward, so a
//      highlight never starts on a newline left over from the HTML source.
// ─────────────────────────────────────────────────────────────────────────────

import type { WordToken } from './types'

/** Default soft-split ceiling. Sentences longer than this are broken on clauses. */
export const MAX_SENTENCE_LEN = 350

/** A half-open character span of some source string. */
export interface Span {
  start: number
  end: number
}

// ── Intl.Segmenter is not in our TS lib target, so declare the tiny slice of
// its surface we use and feature-detect the constructor at runtime.
interface SentenceSegmenter {
  segment(input: string): Iterable<{ segment: string; index: number }>
}
type SegmenterCtor = new (
  locales?: string | string[],
  options?: { granularity?: 'grapheme' | 'word' | 'sentence' },
) => SentenceSegmenter

const SegmenterImpl: SegmenterCtor | undefined =
  typeof Intl !== 'undefined' && 'Segmenter' in Intl
    ? (Intl as unknown as { Segmenter: SegmenterCtor }).Segmenter
    : undefined

// Abbreviations that commonly precede a period *inside* a sentence. Stored
// lowercased and without the trailing dot. If a candidate sentence ends with one
// of these, the following break is treated as spurious and merged back.
const ABBREVIATIONS = new Set([
  // Titles / honorifics
  'mr', 'mrs', 'ms', 'dr', 'prof', 'sr', 'jr', 'st', 'mt', 'rev', 'hon',
  'gen', 'col', 'capt', 'lt', 'sgt', 'gov', 'sen', 'rep', 'pres', 'supt',
  // Latin / editorial
  'eg', 'ie', 'etc', 'vs', 'viz', 'al', 'cf', 'ca', 'approx', 'est', 'esp',
  // Months (often abbreviated in references / dates)
  'jan', 'feb', 'mar', 'apr', 'jun', 'jul', 'aug', 'sep', 'sept', 'oct', 'nov', 'dec',
  // Org / bibliographic
  'inc', 'ltd', 'co', 'corp', 'dept', 'univ', 'assn', 'bros',
  'no', 'nos', 'vol', 'pp', 'fig', 'figs', 'eq', 'ref', 'ed', 'eds', 'repr',
])

/**
 * Should the boundary at the end of `seg` be undone (merged into the next
 * segment)? True when `seg` ends with an abbreviation, an initial, an
 * initialism, or a bare list marker — all of which end in a period that a naive
 * splitter mistakes for a sentence terminator.
 */
function endsWithAbbreviation(seg: string): boolean {
  const trimmed = seg.trimEnd()
  // Bare list / enumeration marker like "1." or "2)" left dangling.
  if (/^\(?\d+[.)]$/.test(trimmed.trimStart())) return true

  const lastToken = trimmed.split(/\s+/).pop() ?? ''
  // Single initial: "J." — or an initialism / e.g. / i.e. / U.S. / a.m.
  if (/^[A-Za-z]\.$/.test(lastToken)) return true
  if (/^([A-Za-z]\.){2,}$/.test(lastToken)) return true

  const bare = lastToken.replace(/[.,;:!?)"'\]]+$/, '').replace(/^[("'[]+/, '').toLowerCase()
  return ABBREVIATIONS.has(bare)
}

/** Raw offset-preserving split: Intl.Segmenter if present, else a manual scanner. */
function rawSplitOffsets(text: string): Span[] {
  if (SegmenterImpl) {
    const seg = new SegmenterImpl('en', { granularity: 'sentence' })
    const out: Span[] = []
    for (const { segment, index } of seg.segment(text)) {
      if (segment.trim()) out.push({ start: index, end: index + segment.length })
    }
    return out
  }
  return manualSplitOffsets(text)
}

/**
 * Lookbehind-free sentence scanner (fallback when Intl.Segmenter is missing).
 * Breaks after terminal punctuation (. ! ? …) plus any trailing closing
 * quotes/brackets, but only when followed by whitespace or end-of-text — so
 * decimals ("3.14") and mid-word dots don't trigger a break.
 */
function manualSplitOffsets(text: string): Span[] {
  const out: Span[] = []
  const closers = '"\')]}'
  let start = 0
  for (let i = 0; i < text.length; i++) {
    const c = text[i]
    if (c !== '.' && c !== '!' && c !== '?' && c !== '…') continue
    let j = i + 1
    while (j < text.length && closers.includes(text[j])) j++
    if (j < text.length && !/\s/.test(text[j])) continue
    if (text.slice(start, j).trim()) out.push({ start, end: j })
    while (j < text.length && /\s/.test(text[j])) j++
    start = j
    i = j - 1
  }
  if (start < text.length && text.slice(start).trim()) out.push({ start, end: text.length })
  return out
}

/** Move a span's edges inward past whitespace. Returns null if nothing is left. */
function trimSpan(text: string, span: Span): Span | null {
  let { start, end } = span
  while (start < end && /\s/.test(text[start])) start++
  while (end > start && /\s/.test(text[end - 1])) end--
  return end > start ? { start, end } : null
}

/**
 * Break an over-long span on clause boundaries so TTS requests stay reasonable.
 * Prefers to cut just after clause punctuation (, ; : — – )), then after a plain
 * space, and only hard-cuts as a last resort. Mirrors the desktop reader's
 * softSplitLongSentence, in offset space.
 */
function softSplitSpan(text: string, span: Span, maxLen: number): Span[] {
  const len = span.end - span.start
  if (len <= maxLen) return [span]

  const body = text.slice(span.start, span.end)
  // Candidate cut points (relative to span.start): index just past clause
  // punctuation + its trailing whitespace.
  const breaks: number[] = []
  const re = /[,;:)—–]\s+/g
  let m: RegExpExecArray | null
  while ((m = re.exec(body)) !== null) breaks.push(m.index + m[0].length)

  const out: Span[] = []
  let start = 0
  while (len - start > maxLen) {
    // Furthest clause break that still fits inside [start, start+maxLen].
    let cut = -1
    for (const b of breaks) {
      if (b <= start) continue
      if (b - start <= maxLen) cut = b
      else break
    }
    if (cut <= start) {
      // No clause boundary in range — fall back to the last space that fits.
      const space = body.lastIndexOf(' ', start + maxLen)
      cut = space > start ? space + 1 : start + maxLen // else hard cut
    }
    const piece = trimSpan(text, { start: span.start + start, end: span.start + cut })
    if (piece) out.push(piece)
    start = cut
  }
  const tail = trimSpan(text, { start: span.start + start, end: span.end })
  if (tail) out.push(tail)
  return out
}

/**
 * Split `text` into sentence spans, offsets relative to `text` itself. Callers
 * that split a slice of a larger string add their own base offset.
 *
 * Every returned span is non-empty and whitespace-trimmed at both ends.
 */
export function splitWithOffsets(text: string, maxLen = MAX_SENTENCE_LEN): Span[] {
  if (!text.trim()) return []

  const raw = rawSplitOffsets(text)

  // Merge a segment into the next when its trailing period is really an
  // abbreviation/initial rather than a sentence end.
  const merged: Span[] = []
  for (let i = 0; i < raw.length; i++) {
    let span = raw[i]
    while (i < raw.length - 1 && endsWithAbbreviation(text.slice(span.start, span.end))) {
      i++
      span = { start: span.start, end: raw[i].end }
    }
    const trimmed = trimSpan(text, span)
    if (trimmed) merged.push(trimmed)
  }

  const out: Span[] = []
  for (const span of merged) out.push(...softSplitSpan(text, span, maxLen))
  return out
}

// ─────────────────────────────────────────────────────────────────────────────
// Word-level tokenization — powers the karaoke read-along highlight.
// ─────────────────────────────────────────────────────────────────────────────

/**
 * Rough syllable estimate for a single word. Used only to weight how long a word
 * is likely spoken relative to its neighbours — it is NOT linguistically exact.
 * Counts vowel groups, discounts a silent trailing "e", and floors at 1.
 */
export function estimatedSyllables(word: string): number {
  const w = word.toLowerCase().replace(/[^a-z]/g, '')
  if (!w) return 0
  const groups = w.match(/[aeiouy]+/g)
  let count = groups ? groups.length : 0
  // Discount a silent final "e" ("make" → 1) but keep "-le" endings
  // ("table" → 2), and never drop the only vowel ("the" stays 1).
  if (count > 1 && w.endsWith('e') && !w.endsWith('le')) count -= 1
  return Math.max(1, count)
}

/**
 * Extra spoken-pause weight from a token's trailing punctuation: sentence-final
 * marks pause longest, clause marks briefly, dashes a touch.
 */
function trailingPauseWeight(token: string): number {
  const m = token.match(/[.,;:!?…—–-]+$/)
  if (!m) return 0
  let extra = 0
  for (const ch of m[0]) {
    if (ch === '.' || ch === '!' || ch === '?' || ch === '…') extra += 1.5
    else if (ch === ',' || ch === ';' || ch === ':') extra += 0.5
    else extra += 0.4 // em-dash / en-dash / hyphen — a brief break
  }
  return extra
}

/** Spoken-duration weight for one non-whitespace token (a word + its punctuation). */
function tokenWeight(token: string): number {
  return Math.max(1, estimatedSyllables(token)) + trailingPauseWeight(token)
}

// Bracket pairs treated as "skippable content" spans.
const OPENERS: Record<string, ')' | ']' | '}'> = { '(': ')', '[': ']', '{': '}' }

/**
 * Per-character mask marking which characters of `text` fall inside a bracketed
 * span, the bracket characters themselves included. Handles nesting via
 * per-type depth counters. Unbalanced brackets are tolerated: an opener is only
 * honoured when a closer of its type exists somewhere in the sentence, and
 * stray closers are ignored.
 */
function bracketMask(text: string): boolean[] {
  const n = text.length
  const inside = new Array<boolean>(n).fill(false)
  const hasClose: Record<string, boolean> = {
    '(': text.indexOf(')') !== -1,
    '[': text.indexOf(']') !== -1,
    '{': text.indexOf('}') !== -1,
  }
  let pd = 0 // ( ) depth
  let sd = 0 // [ ] depth
  let cd = 0 // { } depth
  for (let i = 0; i < n; i++) {
    const c = text[i]
    if (OPENERS[c] && hasClose[c]) {
      if (c === '(') pd++
      else if (c === '[') sd++
      else cd++
      inside[i] = true
    } else if (c === ')' && pd > 0) {
      inside[i] = true
      pd--
    } else if (c === ']' && sd > 0) {
      inside[i] = true
      sd--
    } else if (c === '}' && cd > 0) {
      inside[i] = true
      cd--
    } else {
      inside[i] = pd > 0 || sd > 0 || cd > 0
    }
  }
  return inside
}

/**
 * Split a sentence into tokens for word-level read-along highlighting.
 *
 * Non-destructive: concatenating every token's `text` reproduces the input
 * verbatim. Each maximal whitespace run becomes a non-word token (weight 0,
 * never highlighted); each maximal non-whitespace run becomes one word token
 * carrying a relative spoken-duration weight.
 *
 * `isSkippable` is true only when EVERY character of the token lies inside a
 * bracketed span — so a parenthetical glued mid-word ("word(aside)more") stays
 * spoken, while a well-separated aside ("(as noted)") is flagged in full.
 */
export function tokenizeSentence(text: string): WordToken[] {
  const inside = bracketMask(text)
  const tokens: WordToken[] = []
  const re = /\s+|\S+/g
  let m: RegExpExecArray | null
  while ((m = re.exec(text)) !== null) {
    const raw = m[0]
    const start = m.index
    let skippable = raw.length > 0
    for (let k = 0; k < raw.length; k++) {
      if (!inside[start + k]) {
        skippable = false
        break
      }
    }
    if (raw.trim() === '') {
      tokens.push({ text: raw, isWord: false, weight: 0, isSkippable: skippable })
    } else {
      tokens.push({
        text: raw,
        isWord: /[A-Za-z0-9]/.test(raw),
        weight: tokenWeight(raw),
        isSkippable: skippable,
      })
    }
  }
  return tokens
}

/**
 * Build the text to actually synthesize. When `skipSkippable` is off the input
 * is returned verbatim. When on, tokens inside bracketed spans are dropped and
 * whitespace is collapsed so removing a parenthetical never leaves a doubled
 * space or a space before punctuation.
 */
export function spokenText(text: string, skipSkippable: boolean): string {
  if (!skipSkippable) return text
  let out = ''
  for (const tk of tokenizeSentence(text)) {
    if (!tk.isSkippable) out += tk.text
  }
  return out
    .replace(/\s+/g, ' ')
    .replace(/\s+([,.;:!?…)\]}])/g, '$1')
    .trim()
}
