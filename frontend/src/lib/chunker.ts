// ─────────────────────────────────────────────────────────────────────────────
// Sentence chunking.  Owned by the "PDF" agent.
//
// Turns a reconstructed paragraph of text into TTS-friendly chunks:
//   1. Split into sentences (Intl.Segmenter when available, regex otherwise).
//   2. Merge boundaries that fell on abbreviations ("Dr.", "e.g.", "U.S.", …)
//      so we don't over-split.
//   3. Soft-split any pathologically long sentence on clause boundaries so a
//      single TTS request never gets a giant blob (e.g. a PDF with no periods).
// ─────────────────────────────────────────────────────────────────────────────

import type { WordToken } from '../types'

/** Default soft-split ceiling. Sentences longer than this are broken on clauses. */
export const MAX_SENTENCE_LEN = 350

// ── Intl.Segmenter is not in the ES2020 lib we target, so declare the tiny
// slice of its surface we use and feature-detect the constructor at runtime.
interface SentenceSegmenter {
  segment(input: string): Iterable<{ segment: string }>
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
// lowercased and without the trailing dot. If a candidate sentence ends with
// one of these, the following break is treated as spurious and merged back.
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
 * initialism, or a bare list marker — all of which end in a period that a
 * naive splitter mistakes for a sentence terminator.
 */
function endsWithAbbreviation(seg: string): boolean {
  const trimmed = seg.trimEnd()
  // Bare list / enumeration marker like "1." or "2)" left dangling.
  if (/^\(?\d+[.)]$/.test(trimmed.trimStart())) return true

  // Last whitespace-delimited token.
  const lastToken = trimmed.split(/\s+/).pop() ?? ''
  // Single initial: "J." — or an initialism / e.g. / i.e. / U.S. / a.m.
  if (/^[A-Za-z]\.$/.test(lastToken)) return true
  if (/^([A-Za-z]\.){2,}$/.test(lastToken)) return true

  // Known abbreviation word (strip trailing dot, ignore leading punctuation).
  const bare = lastToken.replace(/[.,;:!?)"'\]]+$/, '').replace(/^[("'[]+/, '').toLowerCase()
  return ABBREVIATIONS.has(bare)
}

/** Raw split using Intl.Segmenter if present, else a manual scanner. */
function rawSplit(text: string): string[] {
  if (SegmenterImpl) {
    const seg = new SegmenterImpl('en', { granularity: 'sentence' })
    const out: string[] = []
    for (const { segment } of seg.segment(text)) {
      if (segment.trim()) out.push(segment)
    }
    return out
  }
  return manualSplit(text)
}

/**
 * Lookbehind-free sentence scanner (fallback when Intl.Segmenter is missing).
 * Breaks after terminal punctuation (. ! ? …) plus any trailing closing
 * quotes/brackets, but only when followed by whitespace or end-of-text — so
 * decimals ("3.14") and mid-word dots don't trigger a break.
 */
function manualSplit(text: string): string[] {
  const out: string[] = []
  const closers = '"\')]}'
  let start = 0
  for (let i = 0; i < text.length; i++) {
    const c = text[i]
    if (c !== '.' && c !== '!' && c !== '?' && c !== '…') continue
    // Absorb trailing closing quotes/brackets after the terminator.
    let j = i + 1
    while (j < text.length && closers.includes(text[j])) j++
    // A boundary only if the next char is whitespace or we hit the end.
    if (j < text.length && !/\s/.test(text[j])) continue
    out.push(text.slice(start, j))
    // Skip the run of whitespace to the next sentence start.
    while (j < text.length && /\s/.test(text[j])) j++
    start = j
    i = j - 1
  }
  if (start < text.length) out.push(text.slice(start))
  return out.filter((s) => s.trim().length > 0)
}

/**
 * Split a paragraph into sentences. Prefers Intl.Segmenter, falls back to a
 * regex-free scanner, then repairs spurious breaks that landed on
 * abbreviations. Returned sentences are trimmed and non-empty.
 */
export function splitIntoSentences(text: string): string[] {
  const normalized = text.replace(/\s+/g, ' ').trim()
  if (!normalized) return []

  const raw = rawSplit(normalized)

  // Merge a segment into the next when its trailing period is really an
  // abbreviation/initial rather than a sentence end.
  const merged: string[] = []
  for (let i = 0; i < raw.length; i++) {
    let piece = raw[i]
    while (i < raw.length - 1 && endsWithAbbreviation(piece)) {
      i++
      // Preserve a single space across the (undone) boundary.
      piece = piece.replace(/\s+$/, '') + ' ' + raw[i].replace(/^\s+/, '')
    }
    const cleaned = piece.trim()
    if (cleaned) merged.push(cleaned)
  }
  return merged
}

/**
 * Break a very long sentence into smaller chunks on clause boundaries so TTS
 * requests stay reasonable. Prefers to cut just after clause punctuation
 * (, ; : — – )), then after a plain space, and only hard-cuts as a last resort.
 */
export function softSplitLongSentence(sentence: string, maxLen = MAX_SENTENCE_LEN): string[] {
  const s = sentence.trim()
  if (s.length <= maxLen) return s ? [s] : []

  // Candidate cut points: the index just past clause punctuation + whitespace.
  const breaks: number[] = []
  const re = /[,;:)—–]\s+/g
  let m: RegExpExecArray | null
  while ((m = re.exec(s)) !== null) breaks.push(m.index + m[0].length)

  const chunks: string[] = []
  let start = 0
  while (s.length - start > maxLen) {
    // Furthest clause break that still fits inside [start, start+maxLen].
    let cut = -1
    for (const b of breaks) {
      if (b <= start) continue
      if (b - start <= maxLen) cut = b
      else break
    }
    if (cut <= start) {
      // No clause boundary in range — fall back to the last space that fits.
      const space = s.lastIndexOf(' ', start + maxLen)
      cut = space > start ? space + 1 : start + maxLen // else hard cut
    }
    const chunk = s.slice(start, cut).trim()
    if (chunk) chunks.push(chunk)
    start = cut
  }
  const tail = s.slice(start).trim()
  if (tail) chunks.push(tail)
  return chunks
}

/**
 * Full paragraph → chunk pipeline: sentence-split, then soft-split any
 * over-long sentence. This is what the PDF loader consumes.
 */
export function chunkParagraph(text: string, maxLen = MAX_SENTENCE_LEN): string[] {
  const out: string[] = []
  for (const sentence of splitIntoSentences(text)) {
    for (const chunk of softSplitLongSentence(sentence, maxLen)) out.push(chunk)
  }
  return out
}

// ─────────────────────────────────────────────────────────────────────────────
// Word-level tokenization — powers the karaoke read-along highlight. This is a
// display/timing concern (not TTS chunking), but it lives here beside the other
// text utilities. Everything below is purely functional and non-destructive.
// ─────────────────────────────────────────────────────────────────────────────

/**
 * Rough syllable estimate for a single word. Used only to weight how long a word
 * is likely spoken relative to its neighbours — it is NOT linguistically exact.
 * Counts vowel groups, discounts a silent trailing "e", and floors at 1. Any
 * non-letters are ignored, so a token's surrounding punctuation is harmless.
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
 * marks pause longest, clause marks (comma/semicolon/colon) briefly, dashes a
 * touch. Multiple trailing marks (e.g. "?!") accumulate.
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
 * span (`( )`, `[ ]`, `{ }`), the bracket characters themselves included. Handles
 * arbitrary nesting via independent per-type depth counters (a char is "inside"
 * whenever any type has an open depth). Unbalanced brackets are tolerated: an
 * opener is only honoured when a closer of its type exists somewhere in the
 * sentence — so a lone unmatched opener with no closer at all leaves the rest of
 * the sentence as normal text, while an unmatched opener in a sentence that does
 * contain a closer skips through to end-of-sentence. Stray closers are ignored.
 */
function bracketMask(text: string): boolean[] {
  const n = text.length
  const inside = new Array<boolean>(n).fill(false)
  // "A closer exists" guard, per bracket type — only then do we honour its opener.
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
 * Split a sentence into display tokens for word-level read-along highlighting.
 *
 * Non-destructive: concatenating every token's `text` reproduces the input
 * verbatim (all whitespace + punctuation preserved). Each maximal whitespace run
 * becomes a non-word token (weight 0, never highlighted); each maximal
 * non-whitespace run becomes one word token carrying a relative spoken-duration
 * weight. `isWord` is true only when the run contains a letter or digit, so a
 * lone "—" still carries pause time but is not visually emphasized.
 *
 * `isSkippable` is true only when every character of the token lies inside a
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
    // Skippable only if the whole token sits inside a bracketed span.
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
 * Build the text to actually synthesize for a sentence. When `skipSkippable` is
 * off the original text is returned verbatim. When on, tokens inside bracketed
 * spans are dropped and the surviving whitespace is collapsed so removing a
 * parenthetical never leaves a doubled space or a space before punctuation.
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
