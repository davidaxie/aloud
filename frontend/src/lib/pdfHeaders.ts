// ─────────────────────────────────────────────────────────────────────────────
// Running headers/footers and page numbers in PDF text — the noise pass of the
// PDF pipeline (./pdf), kept free of pdf.js so it can be tested on plain lines.
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

/** Purely a page number / roman numeral (running-foot noise). */
export function isPageNumberLine(text: string): boolean {
  const t = text.trim()
  return /^\d{1,4}$/.test(t) || /^[ivxlcdm]{1,7}$/i.test(t)
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
 * body line that happens to match isn't nuked) and standalone page numbers.
 */
export function stripNoise(lines: Line[], running: Set<string>): Line[] {
  const n = lines.length
  return lines.filter((line, idx) => {
    const nearEdge = idx <= 1 || idx >= n - 2
    if (nearEdge && running.has(normalizeRunning(line.text))) return false
    if (nearEdge && isPageNumberLine(line.text)) return false
    return true
  })
}
