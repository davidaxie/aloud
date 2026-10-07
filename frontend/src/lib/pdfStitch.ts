// ─────────────────────────────────────────────────────────────────────────────
// A page's text runs stitched into visual lines in reading order: the geometry
// pass of the PDF pipeline (./pdf), kept free of pdf.js so it can be tested on
// plain pieces. Lines follow the text's own direction, so a rotated
// (landscape) page and vertical Japanese or Chinese read in order (J037), and a
// page set in columns reads each column in turn (J035). A page with neither is
// grouped into lines exactly as before. Running heads and folios are found on
// the rows as they lie down the page, before any columns are taken apart (K000).
// ─────────────────────────────────────────────────────────────────────────────
import {
  type Line,
  folioLines,
  median,
  runningHeadersByPage,
  stripNoise,
  typicalGap,
} from './pdfHeaders'

// pdfjs' TextItem carries a transform matrix [a,b,c,d,e,f]; e,f are the x,y of
// the text run in the page's default (bottom-left origin) space — so a LARGER y
// is HIGHER on the page. We only pull the fields we actually need off it.
export interface Piece {
  str: string
  x: number // transform[4]
  y: number // transform[5] (baseline; larger = higher up the page)
  w: number // extent along the text, in device space
  h: number // font height (approx), used as the spacing/leading scale
  hasEOL: boolean
  /** The way the text runs, in degrees anticlockwise; 0 (or none) is left to right. */
  angle?: number
}

/** The fields of a pdf.js TextItem this pass reads. */
export interface TextRun {
  str: string
  transform: number[]
  width: number
  height: number
  hasEOL: boolean
}

/**
 * A pdf.js text run as a piece. The run's direction comes from its transform;
 * a vertical font (Japanese tategaki) runs down the page, a quarter turn
 * clockwise from it, and pdf.js gives such a run's length as its height and
 * its size as its width.
 */
export function pieceOf(run: TextRun, vertical: boolean): Piece {
  const t = run.transform
  return {
    str: run.str,
    x: t[4],
    y: t[5],
    w: vertical ? run.height : run.width,
    h: vertical ? run.width : run.height,
    hasEOL: run.hasEOL,
    angle: (Math.atan2(t[1], t[0]) * 180) / Math.PI - (vertical ? 90 : 0),
  }
}

/**
 * Each page's lines in reading order, its running heads and folios gone. They
 * are found on the page's rows top to bottom, as a page was read before
 * columns, so a header row beside a two-column body never splits into a part
 * that lands between the columns (K000); the rows that are left are then read
 * column by column.
 */
export function readingOrderPages(pages: Piece[][]): Line[][] {
  const rows = pages.map(pageRows)
  const rowLines = rows.map((page) => page.map((row) => row.line))
  const running = runningHeadersByPage(rowLines)
  const folios = folioLines(rowLines)
  return rows.map((page, idx) => {
    const kept = new Set(stripNoise(rowLines[idx], running[idx], folios[idx]))
    return readingOrderLines(page.filter((row) => kept.has(row.line)).flatMap((row) => row.pieces))
  })
}

/** One row of a page as a line, with the pieces it was made from. */
interface Row {
  line: Line
  pieces: Piece[]
}

/** A page's rows top to bottom, each direction's in its own frame, stacked as its lines are. */
function pageRows(pieces: Piece[]): Row[] {
  const groups = directionGroups(pieces)
  if (groups === null) return clusterRows(pieces).map((row) => ({ line: lineOf(row), pieces: row }))
  return stack(
    groups.map(([turn, group]) => {
      const turned = new Map(group.map((p) => [upright(p, turn), p]))
      return clusterRows([...turned.keys()]).map((row) => ({
        line: lineOf(row),
        pieces: row.map((p) => turned.get(p) as Piece),
      }))
    }),
    (row) => row.line,
  )
}

/**
 * A page's lines in reading order, top to bottom. Text that runs another way
 * (a landscape page, vertical writing) is read along its own lines: vertical
 * Japanese column by column from the right. When a page mixes directions, the
 * one carrying most of the text is read last and each other comes before it as
 * its own paragraph, so a sideways margin stamp neither splices into a body
 * line nor stands between a sentence and the page it runs on to (K015).
 */
export function readingOrderLines(pieces: Piece[]): Line[] {
  const groups = directionGroups(pieces)
  if (groups === null) return columnLines(pieces, 0)
  return stack(
    groups.map(([turn, group]) => columnLines(turn === 0 ? group : group.map((p) => upright(p, turn)), 0)),
    (line) => line,
  )
}

/** A page's pieces by direction, the one carrying most text first; null when all run left to right. */
function directionGroups(pieces: Piece[]): Array<[number, Piece[]]> | null {
  const groups = new Map<number, Piece[]>()
  for (const p of pieces) {
    const turn = directionOf(p)
    const group = groups.get(turn)
    if (group) group.push(p)
    else groups.set(turn, [p])
  }
  if (groups.size === 0 || (groups.size === 1 && groups.has(0))) return null
  return [...groups]
    .filter(([, group]) => textLength(group) > 0)
    .sort(([, a], [, b]) => textLength(b) - textLength(a))
}

/**
 * Each direction's lines (or rows), the main one first, as one page. Each y is
 * in its own frame, so the main one keeps its place and each other is set a
 * clear paragraph gap above the one after it: the two never run together.
 */
function stack<T>(groups: T[][], asLine: (item: T) => Line): T[] {
  let page: T[] = []
  for (const group of groups) {
    if (group.length === 0) continue
    if (page.length > 0) {
      const lines = page.map(asLine)
      const own = group.map(asLine)
      const last = own[own.length - 1]
      const gap = 2 * Math.max(typicalGap(lines), typicalGap(own), lines[0].height, last.height)
      const shift = lines[0].y + gap - last.y
      for (const line of own) line.y += shift
    }
    page = [...group, ...page]
  }
  return page
}

/**
 * A piece's direction in degrees, 0 to 359: within 10° of a right angle it is
 * that right angle (a scan's text layer leans a little line to line), and any
 * other slant is taken to the nearest 5°.
 */
function directionOf(p: Piece): number {
  const angle = p.angle ?? 0
  const right = Math.round(angle / 90) * 90
  const turn = (Math.abs(angle - right) <= 10 ? right : Math.round(angle / 5) * 5) % 360
  return turn < 0 ? turn + 360 : turn + 0 // + 0 folds -0 into 0
}

/** cos and sin of a whole-degree angle, exact at the right angles. */
function cosSin(turn: number): [number, number] {
  if (turn === 90) return [0, 1]
  if (turn === 180) return [-1, 0]
  if (turn === 270) return [0, -1]
  const r = (turn * Math.PI) / 180
  return [Math.cos(r), Math.sin(r)]
}

/** The piece in a frame turned so its text runs left to right, lines downward. */
function upright(p: Piece, turn: number): Piece {
  const [c, s] = cosSin(turn)
  return { ...p, x: p.x * c + p.y * s, y: p.y * c - p.x * s }
}

const LETTER = /\p{L}/gu
const RIGHT_TO_LEFT_LETTER =
  /[\p{Script=Arabic}\p{Script=Hebrew}\p{Script=Syriac}\p{Script=Thaana}\p{Script=Nko}\p{Script=Adlam}]/gu

/** Most of the pieces' letters are in a script written right to left. */
function rightToLeft(pieces: Piece[]): boolean {
  let letters = 0
  let backward = 0
  for (const p of pieces) {
    letters += p.str.match(LETTER)?.length ?? 0
    backward += p.str.match(RIGHT_TO_LEFT_LETTER)?.length ?? 0
  }
  return backward * 2 > letters
}

function visible(p: Piece): boolean {
  return p.str.trim() !== ''
}

function textLength(pieces: Piece[]): number {
  return pieces.reduce((n, p) => n + p.str.trim().length, 0)
}

/** Where a piece ends along its line. */
function endOf(p: Piece): number {
  return p.x + (p.w || scaleWidth(p))
}

// ── Columns ──────────────────────────────────────────────────────────────────

/** Columns inside columns go no deeper than this (four across at most). */
const MAX_COLUMN_DEPTH = 2
/** Each column needs this many lines of its own before a page counts as set in columns. */
const MIN_COLUMN_ROWS = 3
/** ...and its lines this many characters, at the median: prose, not a table's cells. */
const MIN_COLUMN_CHARS = 12

/**
 * A page's lines with any columns read one after another. The rows above and
 * below a band of columns, and the ones that cross its gutter (a title, a
 * figure caption set across the page, a centred folio), stay where they are,
 * as do a header or footer row set apart at the top or bottom. A page with no
 * gutter comes out exactly as buildLines groups it.
 */
function columnLines(pieces: Piece[], depth: number): Line[] {
  const rows = clusterRows(pieces)
  const gutter = depth < MAX_COLUMN_DEPTH ? findGutter(rows) : null
  if (gutter === null) return rows.map(lineOf)

  const crosses = (row: Piece[]) => row.some((p) => visible(p) && p.x < gutter && endOf(p) > gutter)
  const ys = rows.map((row) => Math.max(...row.map((p) => p.y)))
  const gaps = ys.slice(1).map((y, i) => ys[i] - y)
  const apart = 2.5 * median(gaps.filter((g) => g > 0)) || Infinity
  // Up to two rows at the head or foot, set apart from the body, are the
  // page's header or footer even when they don't cross the gutter.
  const head = [1, 2].find((k) => k < rows.length && gaps[k - 1] > apart) ?? 0
  const foot = [1, 2].find((k) => rows.length - k > head && gaps[rows.length - k - 1] > apart) ?? 0

  const lines: Line[] = []
  let band: Piece[][] = []
  const flush = () => {
    if (band.length === 1) lines.push(lineOf(band[0]))
    else if (band.length > 1) {
      const all = band.flat()
      const isLeft = (p: Piece) => (p.x + endOf(p)) / 2 < gutter
      const left = all.filter(isLeft)
      const right = all.filter((p) => !isLeft(p))
      // Arabic or Hebrew columns are read from the right (K012).
      for (const column of rightToLeft(all) ? [right, left] : [left, right]) {
        lines.push(...columnLines(column, depth + 1))
      }
    }
    band = []
  }
  rows.forEach((row, i) => {
    if (i < head || i >= rows.length - foot || crosses(row)) {
      flush()
      lines.push(lineOf(row))
    } else band.push(row)
  })
  flush()
  return lines
}

/**
 * The x of the gutter down the middle of a page set in columns, or null. A
 * gutter is a channel, at least 0.6em wide in the middle three-fifths of the
 * text, that two in three of the rows leave empty. The text either side of it
 * must look like columns of prose: each side has rows of its own, spans a
 * quarter of the page, and its lines mostly fill it and run to a dozen
 * characters, so a contents page (titles left, page numbers right) or a table
 * reads row by row as before.
 */
function findGutter(rows: Piece[][]): number | null {
  const textRows = rows.map((row) => row.filter(visible)).filter((row) => row.length > 0)
  if (textRows.length < 2 * MIN_COLUMN_ROWS) return null
  const all = textRows.flat()
  // A loop, not Math.min(...): a page can carry more runs than a call takes arguments.
  const left = all.reduce((least, p) => Math.min(least, p.x), Infinity)
  const width = all.reduce((most, p) => Math.max(most, endOf(p)), -Infinity) - left
  if (!(width > 0) || width > 100_000) return null
  const size = median(all.map((p) => p.h || 8))

  // How many rows have text over each point across the page.
  const bins = Math.ceil(width) + 1
  const counts = new Array<number>(bins + 1).fill(0)
  const mark = (from: number, to: number) => {
    counts[Math.max(0, Math.floor(from - left))]++
    counts[Math.min(bins, Math.ceil(to - left))]--
  }
  for (const row of textRows) {
    const spans = row.map((p): [number, number] => [p.x, endOf(p)]).sort((a, b) => a[0] - b[0])
    let [from, to] = spans[0]
    for (const [s, e] of spans.slice(1)) {
      if (s <= to) to = Math.max(to, e)
      else {
        mark(from, to)
        ;[from, to] = [s, e]
      }
    }
    mark(from, to)
  }
  for (let i = 1; i <= bins; i++) counts[i] += counts[i - 1]

  // The widest channel in the middle that two in three rows leave empty.
  const open = textRows.length / 3
  let best = { from: 0, to: 0 }
  let from = -1
  const lo = Math.ceil(width * 0.2)
  const hi = Math.floor(width * 0.8)
  for (let i = lo; i <= hi + 1; i++) {
    if (i <= hi && counts[i] <= open) {
      if (from < 0) from = i
    } else if (from >= 0) {
      if (i - from > best.to - best.from) best = { from, to: i }
      from = -1
    }
  }
  if (best.to - best.from < Math.max(3, size * 0.6)) return null
  const gutter = left + (best.from + best.to) / 2

  // Both sides must read as columns of prose.
  const sides: Array<Array<{ from: number; to: number; chars: number }>> = [[], []]
  for (const row of textRows) {
    if (row.some((p) => p.x < gutter && endOf(p) > gutter)) continue
    for (const [side, own] of [row.filter((p) => endOf(p) <= gutter), row.filter((p) => p.x >= gutter)].entries()) {
      if (own.length === 0) continue
      sides[side].push({
        from: Math.min(...own.map((p) => p.x)),
        to: Math.max(...own.map(endOf)),
        chars: textLength(own),
      })
    }
  }
  const prose = sides.every((side) => {
    if (side.length < MIN_COLUMN_ROWS) return false
    const from = Math.min(...side.map((r) => r.from))
    const span = Math.max(...side.map((r) => r.to)) - from
    return (
      span >= width * 0.25 &&
      median(side.map((r) => (r.to - r.from) / span)) >= 0.6 &&
      median(side.map((r) => r.chars)) >= MIN_COLUMN_CHARS
    )
  })
  return prose ? gutter : null
}

// ── Lines ────────────────────────────────────────────────────────────────────

/**
 * Group a page's pieces into visual lines. Pieces are clustered by baseline y
 * (within half a line's height), then ordered left-to-right within each line.
 * Lines are returned top-to-bottom.
 */
export function buildLines(pieces: Piece[]): Line[] {
  return clusterRows(pieces).map(lineOf)
}

/** A page's pieces clustered by baseline, top-to-bottom. */
function clusterRows(pieces: Piece[]): Piece[][] {
  if (pieces.length === 0) return []

  // Sort top-to-bottom (y descending), then left-to-right for stable clustering.
  const sorted = [...pieces].sort((a, b) => b.y - a.y || a.x - b.x)

  const clusters: Piece[][] = []
  let current: Piece[] = []
  let currentY = sorted[0].y
  for (const p of sorted) {
    // Tolerance scales with font height so superscripts/descenders on the same
    // visual line don't spawn a new line; floor keeps tiny fonts sane.
    const tol = Math.max(2, (p.h || 8) * 0.5)
    if (current.length === 0 || Math.abs(p.y - currentY) <= tol) {
      current.push(p)
      // Track the top-most baseline as the line's reference y.
      currentY = Math.max(currentY, p.y)
    } else {
      clusters.push(current)
      current = [p]
      currentY = p.y
    }
  }
  if (current.length) clusters.push(current)
  return clusters
}

/** One cluster of pieces as a line, ordered left-to-right. */
function lineOf(cluster: Piece[]): Line {
  const byX = [...cluster].sort((a, b) => a.x - b.x)
  const height = Math.max(...byX.map((p) => p.h || 0)) || 8
  const y = Math.max(...byX.map((p) => p.y))
  return { text: joinPiecesOnLine(byX), y, height }
}

/**
 * Join left-to-right pieces on one line into text, inserting a space where the
 * horizontal gap between runs is wide enough to be a real word break (and not
 * mere kerning). Respects spaces the PDF already encodes in the runs.
 */
function joinPiecesOnLine(pieces: Piece[]): string {
  let out = ''
  let prevEndX = -Infinity
  for (let i = 0; i < pieces.length; i++) {
    const p = pieces[i]
    const str = p.str
    if (str === '') continue
    const scale = p.h || 8
    if (i > 0) {
      const gap = p.x - prevEndX
      const alreadySpaced = /\s$/.test(out) || /^\s/.test(str)
      // A real word break shows up as a horizontal gap on the order of a space
      // glyph (~0.25em). We trigger at 0.2em rather than 0.25 so slightly narrow
      // spaces (thin-space glyphs, tight tracking, or a small width over-estimate
      // on the previous run) still register as a boundary — glued-together words
      // are a top cause of garbled speech. Intra-word run splits sit at ~0 gap,
      // far below 0.2em, so this won't inject spurious spaces inside a word.
      if (!alreadySpaced && gap > scale * 0.2) out += ' '
    }
    out += str
    // Advance the running x cursor; guard against zero-width runs.
    prevEndX = p.x + (p.w || scaleWidth(p))
  }
  return out.replace(/[ \t]{2,}/g, ' ').trimEnd()
}

/** Rough width estimate for pieces pdfjs reports with width 0. */
function scaleWidth(p: Piece): number {
  return p.str.length * (p.h || 8) * 0.5
}
