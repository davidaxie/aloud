// ─────────────────────────────────────────────────────────────────────────────
// Running headers/footers and page numbers in PDF text — the noise pass of the
// PDF pipeline (./pdf) — plus its line joins and cross-page stitching, kept
// free of pdf.js so they can be tested on plain lines and paragraphs.
// Mirrors PDFTextExtractor.swift in the iOS/Mac app.
// ─────────────────────────────────────────────────────────────────────────────

/** One visual line of a page. Lines are ordered top-to-bottom. */
export interface Line {
  text: string
  y: number // representative baseline y (larger = higher up the page)
  height: number // representative font height
}

export function median(nums: number[]): number {
  if (nums.length === 0) return 0
  const s = [...nums].sort((a, b) => a - b)
  const mid = s.length >> 1
  return s.length % 2 ? s[mid] : (s[mid - 1] + s[mid]) / 2
}

/**
 * A page's typical line spacing: the median of consecutive baseline gaps
 * (robust to headings / outliers), or the font height when there's one line.
 */
export function typicalGap(lines: Line[]): number {
  if (lines.length === 0) return 0
  const gaps: number[] = []
  for (let i = 1; i < lines.length; i++) gaps.push(lines[i - 1].y - lines[i].y)
  return median(gaps) || lines[0].height * 1.2
}

/**
 * Purely a page number: up to four digits or a well-formed roman numeral
 * ("xii"; not "Did" or "vivid", spelled with its letters).
 */
export function isPageNumberLine(text: string): boolean {
  const t = text.trim()
  return /^\d{1,4}$/.test(t) || romanValue(t) !== null
}

const ROMAN_NUMERAL = /^M{0,3}(?:CM|CD|D?C{0,3})(?:XC|XL|L?X{0,3})(?:IX|IV|V?I{0,3})$/i
const ROMAN_DIGITS: Record<string, number> = { I: 1, V: 5, X: 10, L: 50, C: 100, D: 500, M: 1000 }

/** A well-formed roman numeral's value, either case ("xiv" is 14), else null. */
export function romanValue(text: string): number | null {
  const t = text.trim()
  if (t.length === 0 || t.length > 7 || !ROMAN_NUMERAL.test(t)) return null
  const digits = [...t.toUpperCase()].map((c) => ROMAN_DIGITS[c])
  return digits.reduce((total, d, i) => (i + 1 < digits.length && d < digits[i + 1] ? total - d : total + d), 0)
}

/** A folio may count on from one on a page up to this many pages away. */
export const FOLIO_REACH = 2

/**
 * Each page's edge lines that are folios, by index. A bare numeral is a folio
 * only when it looks like one: it counts on from a numeral on a page up to
 * two away by the pages between. A roman one must sit at the same height, as
 * front matter numbers its pages ("vii", "viii"), so a bare "II" opening a
 * chapter stays (H047). Digits may sit at the head of one page and the foot of
 * the next; where no page nearby shows a number (a lone page, plates between)
 * the page's outermost line still is one. And a numeral set larger than the
 * page's text is a heading ("7", "1984"), never a folio (J040).
 */
export function folioLines(pageLines: Line[][]): Set<number>[] {
  const numerals = pageLines.map((lines) => {
    const n = lines.length
    const size = median(lines.map((l) => l.height))
    return [...new Set([0, 1, n - 2, n - 1])]
      .filter((index) => index >= 0 && index < n)
      .flatMap((index) => {
        const line = lines[index]
        const t = line.text.trim()
        const roman = /^\d{1,4}$/.test(t) ? null : romanValue(t)
        if (roman === null && !/^\d{1,4}$/.test(t)) return []
        return [
          {
            index,
            line,
            value: roman ?? Number(t),
            roman: roman !== null,
            outermost: index === 0 || index === n - 1,
            bodySized: line.height <= size * 1.2,
          },
        ]
      })
  })
  return numerals.map((own, page) => {
    const nearby: number[] = []
    for (let other = page - FOLIO_REACH; other <= page + FOLIO_REACH; other++) {
      if (other !== page && other >= 0 && other < numerals.length) nearby.push(other)
    }
    const folios = new Set<number>()
    for (const numeral of own) {
      const countsOn = nearby.some((other) =>
        numerals[other].some(
          (o) =>
            o.roman === numeral.roman &&
            o.value - numeral.value === other - page &&
            (!numeral.roman ||
              Math.abs(o.line.y - numeral.line.y) <= Math.max(2, numeral.line.height * 0.25)),
        ),
      )
      if (numeral.roman) {
        if (countsOn) folios.add(numeral.index)
        continue
      }
      const lone = nearby.every((other) => numerals[other].every((o) => o.roman))
      if (numeral.bodySized && (countsOn || (lone && numeral.outermost))) folios.add(numeral.index)
    }
    return folios
  })
}

/** Normalize a header/footer candidate so "Page 3" and "Page 4" collapse. */
export function normalizeRunning(text: string): string {
  return text
    .toLowerCase()
    .replace(/\d+/g, '#') // page numbers vary; ignore the digits
    .replace(/\s+/g, ' ')
    .trim()
}

/**
 * Detect running headers/footers: the top/bottom line of each page, normalized,
 * that repeats across a majority of pages. Returns the set of normalized forms
 * to strip. Only meaningful for multi-page docs. Each page contributes a
 * candidate line once, even when the edge windows overlap on short pages (a
 * two-line title page would otherwise count its title twice).
 */
export function detectRunningHeaders(pageLines: Line[][]): Set<string> {
  const counts = new Map<string, number>()
  for (const lines of pageLines) {
    const n = lines.length
    // Consider the outer two lines at each edge — headers can be 1-2 lines.
    for (const index of new Set([0, 1, n - 1, n - 2])) {
      if (index < 0 || index >= n) continue
      const key = normalizeRunning(lines[index].text)
      if (key.length >= 2) counts.set(key, (counts.get(key) ?? 0) + 1)
    }
  }
  const pages = pageLines.length
  const threshold = Math.max(2, Math.ceil(pages * 0.5))
  const repeating = new Set<string>()
  if (pages < 3) return repeating // too few pages to be confident
  for (const [key, n] of counts) if (n >= threshold) repeating.add(key)
  return repeating
}

/**
 * The number a numbered heading leads with — "Step 3", "Question 12:", "Day 4 —
 * Arrival" — or null. A page label ("Page 3", "p. 3") is a folio, not a heading.
 */
export function headingNumber(text: string): string | null {
  const m = /^\s*(\p{L}+)\.?\s*(\d+)/u.exec(text)
  if (!m || /^(page|pg|p)$/i.test(m[1])) return null
  return m[2]
}

/** A part-of-the-book header needs this many pages... */
export const MINIMUM_RUN = 3
/** ...no more than this many pages apart (a chapter opening or blank between). */
export const MAXIMUM_RUN_GAP = 4

/**
 * Each page's running headers and footers: the document-wide ones, plus a line
 * that runs through part of the book. A printed book puts its title on
 * left-hand pages and the chapter's on right-hand ones, so neither reaches half
 * the pages. Such a line is set apart from the body by a paragraph gap, sits at
 * the same height in the same size, and recurs at least MINIMUM_RUN times no
 * more than MAXIMUM_RUN_GAP pages apart. A chapter's title on its opening page
 * sits lower or larger, so it stays. So do numbered headings that open pages
 * ("Step 1", "Step 2", …): they fold to one key, but a running head keeps its
 * leading number ("Chapter 3 · 47") while a heading counts up.
 */
export function runningHeadersByPage(pageLines: Line[][]): Set<string>[] {
  const global = detectRunningHeaders(pageLines)
  const byPage = pageLines.map(() => new Set(global))
  if (pageLines.length < MINIMUM_RUN) return byPage

  const seen = new Map<string, Array<{ page: number; y: number; height: number; text: string }>>()
  pageLines.forEach((lines, page) => {
    const n = lines.length
    if (n < 3) return
    const breakGap = typicalGap(lines) * 1.6
    const keys = new Set<string>()
    for (const index of new Set([0, 1, n - 1, n - 2])) {
      const line = lines[index]
      const apart =
        index <= 1 ? line.y - lines[index + 1].y > breakGap : lines[index - 1].y - line.y > breakGap
      const key = normalizeRunning(line.text)
      if (!apart || key.length < 2 || isPageNumberLine(line.text) || keys.has(key)) continue
      keys.add(key)
      const hits = seen.get(key) ?? []
      hits.push({ page, y: line.y, height: line.height, text: line.text })
      seen.set(key, hits)
    }
  })

  for (const [key, hits] of seen) {
    if (hits.length < MINIMUM_RUN || global.has(key)) continue
    if (new Set(hits.map((h) => headingNumber(h.text))).size > 1) continue
    const y = median(hits.map((h) => h.y))
    const height = median(hits.map((h) => h.height))
    const placed = hits.filter(
      (h) =>
        Math.abs(h.y - y) <= Math.max(2, height * 0.25) &&
        Math.abs(h.height - height) <= Math.max(1, height * 0.2),
    )
    let run: number[] = []
    const close = () => {
      if (run.length >= MINIMUM_RUN) for (const page of run) byPage[page].add(key)
      run = []
    }
    for (const hit of placed) {
      const last = run[run.length - 1]
      if (last !== undefined && hit.page - last > MAXIMUM_RUN_GAP) close()
      run.push(hit.page)
    }
    close()
  }
  return byPage
}

/**
 * Drop noise lines: repeating headers/footers (only near the page edges, so a
 * body line that happens to match isn't nuked) and the page's `folios`
 * (folioLines), so a bare numeral that heads a chapter stays.
 */
export function stripNoise(lines: Line[], running: Set<string>, folios: Set<number>): Line[] {
  const n = lines.length
  return lines.filter((line, idx) => {
    const nearEdge = idx <= 1 || idx >= n - 2
    if (nearEdge && running.has(normalizeRunning(line.text))) return false
    if (nearEdge && folios.has(idx)) return false
    return true
  })
}

// ── Line joins and cross-page stitching ─────────────────────────────────────

/** A reconstructed paragraph plus the 1-based page it starts on. */
export interface Block {
  text: string
  page: number
}

// Han, kana, and the CJK and fullwidth punctuation set between them.
const UNSPACED_CJK =
  '\\u3000-\\u30FF\\u31F0-\\u31FF\\u3400-\\u4DBF\\u4E00-\\u9FFF\\uF900-\\uFAFF' +
  '\\uFF01-\\uFF60\\uFF65-\\uFF9F\\u{20000}-\\u{2FA1F}'
const ENDS_UNSPACED_CJK = new RegExp(`[${UNSPACED_CJK}]$`, 'u')
const STARTS_UNSPACED_CJK = new RegExp(`^[${UNSPACED_CJK}]`, 'u')

/**
 * Chinese or Japanese on both sides of a break: Han and kana have no case, so
 * the lowercase test can't see a sentence go on, and no space belongs there.
 */
export function continuesUnspacedCJK(previous: string, next: string): boolean {
  return ENDS_UNSPACED_CJK.test(previous.replace(/\s+$/, '')) && STARTS_UNSPACED_CJK.test(next)
}

/**
 * Append a wrapped line to the running paragraph buffer, de-hyphenating words
 * broken across the line break: "inter-" + "national" → "international".
 * Only removes the hyphen when a letter precedes it and the next line starts
 * lowercase — the safe, common word-wrap case (leaves "well-Being" alone).
 *
 * The trailing hyphen may be a normal hyphen-minus (U+002D) OR a soft hyphen
 * (U+00AD) that some PDFs emit at the wrap point; both are handled here so the
 * word rejoins WITHOUT a stray space. (Any soft hyphens that survive elsewhere
 * are stripped later by normalizeText.)
 */
export function appendLine(buf: string, next: string): string {
  const nextTrim = next.replace(/^\s+/, '')
  if (/[A-Za-z][-­]$/.test(buf) && /^[a-z]/.test(nextTrim)) {
    return buf.replace(/[-­]$/, '') + nextTrim
  }
  const head = buf.replace(/\s+$/, '')
  // Chinese and Japanese put no space between words: a wrap there is no word
  // break. (Korean does space its words.)
  if (continuesUnspacedCJK(head, nextTrim)) return head + nextTrim
  return head + ' ' + nextTrim
}

/**
 * True if text ends a sentence (terminal punctuation, ignoring closers),
 * Chinese and Japanese "。" and "」" "』" included (NFKC has already made
 * "！" and "？" plain).
 */
export function looksFinished(text: string): boolean {
  return /[.!?…。]["')\]」』]?\s*$/.test(text)
}

/**
 * Stitch this page's paragraphs onto the growing block list, merging the page's
 * first paragraph onto the previous block when the previous block clearly runs
 * on (no terminal punctuation) and this one continues it (starts lowercase or
 * with a digit, in any script, goes on in Chinese or Japanese from Chinese or
 * Japanese, or the previous ended mid-hyphenation). Keeps a block's page =
 * where it started.
 */
export function appendPageParagraphs(blocks: Block[], paras: string[], page: number): void {
  paras.forEach((para, idx) => {
    const prev = blocks[blocks.length - 1]
    const continues =
      idx === 0 &&
      prev !== undefined &&
      !looksFinished(prev.text) &&
      (/^[\p{Ll}\p{N}]/u.test(para) ||
        continuesUnspacedCJK(prev.text, para) ||
        /[A-Za-z]-$/.test(prev.text))
    if (continues) {
      prev.text = appendLine(prev.text, para) // reuse de-hyphenation logic
    } else {
      blocks.push({ text: para, page })
    }
  })
}
