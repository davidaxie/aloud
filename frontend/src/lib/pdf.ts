// ─────────────────────────────────────────────────────────────────────────────
// PDF → Doc pipeline.  Owned by the "PDF" agent.
//
// Uses pdfjs-dist in the browser to extract each page's text, reconstruct
// readable reading-order text (line joining, de-hyphenation, paragraph
// detection, header/footer + page-number stripping), then chunk it into
// sentences via ./chunker for TTS + highlighting.
// ─────────────────────────────────────────────────────────────────────────────
import * as pdfjs from 'pdfjs-dist'
// Vite resolves `?url` to the emitted asset URL (typed via vite/client). The
// worker is a hard requirement for pdfjs in a browser build.
import workerUrl from 'pdfjs-dist/build/pdf.worker.min.mjs?url'
import type { Doc, Paragraph, Sentence } from '../types'
import { chunkParagraph } from './chunker'
import { dropStrayJoiners } from './joiners'
import { bundledCMapReaderFactory } from './pdfCMaps'
import {
  type Block,
  type Line,
  appendLine,
  appendPageParagraphs,
  runningHeadersByPage,
  stripNoise,
  typicalGap,
} from './pdfHeaders'

pdfjs.GlobalWorkerOptions.workerSrc = workerUrl

// Adobe's predefined CMaps, which CJK PDFs with non-embedded fonts need for their
// text (see ./pdfCMaps). Each is emitted as its own asset and fetched only when a
// PDF names it. `exhaustive` lets the glob reach into node_modules.
const CMapReaderFactory = bundledCMapReaderFactory(
  import.meta.glob<string>('/node_modules/pdfjs-dist/cmaps/*.bcmap', {
    query: '?url',
    import: 'default',
    exhaustive: true,
  }),
)

// ── Local geometry types ────────────────────────────────────────────────────
// pdfjs' TextItem carries a transform matrix [a,b,c,d,e,f]; e,f are the x,y of
// the text run in the page's default (bottom-left origin) space — so a LARGER y
// is HIGHER on the page. We only pull the fields we actually need off it.
interface Piece {
  str: string
  x: number // transform[4]
  y: number // transform[5] (baseline; larger = higher up the page)
  w: number // width in device space
  h: number // font height (approx), used as the spacing/leading scale
  hasEOL: boolean
}

/** Strip control chars / form-feed artifacts (\f, NUL, etc.) from a run. */
function sanitize(s: string): string {
  // Remove C0 controls except tab/newline, plus DEL — covers form-feed (\f=\x0c).
  // This is a light per-piece pass so geometry/line-building isn't confused by
  // stray controls; the comprehensive Unicode cleanup happens in normalizeText.
  // eslint-disable-next-line no-control-regex
  return s.replace(/[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]/g, '')
}

/**
 * Normalize a reconstructed paragraph for clean DISPLAY *and* clean TTS tokens.
 * Runs on each folded paragraph BEFORE it is chunked into sentences, so the
 * reader text shown on screen matches the audio the synthesizer produces from
 * the same source string. Order matters: Unicode folding first, then
 * invisible-char removal, then space/punctuation cleanup, then whitespace
 * collapse. Every rule is idempotent, so a second pass is a no-op.
 */
function normalizeText(input: string): string {
  // 1. Unicode NFKC - expands typographic ligatures to their letters
  //    (U+FB01 fi, U+FB02 fl, U+FB00 ff, U+FB03 ffi, U+FB04 ffl) and folds
  //    other compatibility forms (full-width forms, most exotic spaces, etc.)
  //    to plain equivalents. Fixes the most common garbled ligature runs.
  let s = input.normalize('NFKC')

  // 2. Strip characters that must never reach display or TTS:
  //    - soft hyphen U+00AD (a discretionary hyphen; invisible, must not speak)
  //    - zero-width space U+200B and BOM U+FEFF
  s = s.replace(/[\u00AD\u200B\uFEFF]/g, '')
  //    - zero-width non-joiner/joiner U+200C/200D, except where they shape an
  //      emoji sequence or a non-Latin word (see ./joiners)
  s = dropStrayJoiners(s)
  //    - control chars: C0 (except tab/LF/CR) + DEL + C1 (U+0080-U+009F).
  //      Normal whitespace is preserved here and collapsed in step 5.
  // eslint-disable-next-line no-control-regex
  s = s.replace(/[\x00-\x08\x0b\x0c\x0e-\x1f\x7f-\x9f]/g, '')

  // 3. Map every remaining exotic space to a plain ASCII space. NFKC folds
  //    most of these already, but be explicit so nothing slips through: NBSP
  //    (U+00A0), the U+2000-U+200A en/em/thin/hair/figure spaces, narrow
  //    no-break (U+202F), math space (U+205F), ideographic space (U+3000).
  s = s.replace(/[\u00A0\u2000-\u200A\u202F\u205F\u3000]/g, ' ')

  // 4. Punctuation cleanup for natural speech + tidy display.
  //    Curly/smart quotes -> straight quotes (NFKC leaves these untouched).
  s = s
    .replace(/[\u2018\u2019\u201A\u201B]/g, "'")
    .replace(/[\u201C\u201D\u201E\u201F]/g, '"')
  //    Horizontal ellipsis U+2026 -> three dots (NFKC leaves it untouched).
  s = s.replace(/\u2026/g, '...')
  //    Bullets and pilcrows are layout marks, not speech -> drop them.
  //    Replacing with a space keeps a "bullet+word" run from gluing.
  //    U+2022 U+2023 U+2043 U+2219 (bullets) + U+00B6 (pilcrow).
  s = s.replace(/[\u2022\u2023\u2043\u2219\u00B6]/g, ' ')
  //    Minus sign U+2212 -> hyphen-minus so "-5" is plain ASCII.
  s = s.replace(/\u2212/g, '-')
  //    Em dash U+2014 / horizontal bar U+2015 is always a phrase separator:
  //    force single spaces around it so TTS pauses instead of gluing words.
  s = s.replace(/\s*[\u2014\u2015]\s*/g, ' \u2014 ')
  //    (En dash U+2013 is left as-is so numeric ranges like "1990-95" stay
  //    tight; the whitespace collapse below still tidies any stray spacing.)

  // 5. Whitespace: collapse every run (including the tabs/newlines kept
  //    above) to a single space, then remove spaces sitting BEFORE
  //    punctuation and just inside opening brackets - both frequent
  //    extraction artifacts ("word ." -> "word.", "( x )" -> "(x)").
  s = s.replace(/\s+/g, ' ')
  s = s.replace(/ +([,.;:!?%)\]}])/g, '$1')
  s = s.replace(/([(\[{]) +/g, '$1')

  return s.trim()
}

/**
 * Group a page's pieces into visual lines. Pieces are clustered by baseline y
 * (within half a line's height), then ordered left-to-right within each line.
 * Lines are returned top-to-bottom.
 */
function buildLines(pieces: Piece[]): Line[] {
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

  return clusters.map((cluster) => {
    const byX = cluster.sort((a, b) => a.x - b.x)
    const height = Math.max(...byX.map((p) => p.h || 0)) || 8
    const y = Math.max(...byX.map((p) => p.y))
    return { text: joinPiecesOnLine(byX), y, height }
  })
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

/**
 * Fold a page's lines into paragraphs. A paragraph break is inferred from a
 * vertical gap noticeably larger than the page's typical line spacing (i.e. a
 * blank line). Lines within a paragraph are joined, de-hyphenating words split
 * across the line break.
 */
function linesToParagraphs(lines: Line[]): string[] {
  if (lines.length === 0) return []

  // Typical line spacing = median of consecutive baseline gaps (robust to
  // headings / outliers). Fall back to font height when there's one line.
  const typical = typicalGap(lines)

  const paragraphs: string[] = []
  let buf = ''
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i]
    const gapBefore = i === 0 ? 0 : lines[i - 1].y - line.y
    // A gap ~1.6x the normal leading (or bigger) means a blank line above.
    const isNewParagraph = i > 0 && gapBefore > typical * 1.6

    if (isNewParagraph && buf) {
      paragraphs.push(buf)
      buf = ''
    }
    buf = buf ? appendLine(buf, line.text) : line.text
  }
  if (buf) paragraphs.push(buf)
  // Normalize each folded paragraph (ligatures, invisible chars, exotic spaces,
  // smart punctuation, whitespace) up front, so BOTH the displayed reader text
  // and the chunked TTS tokens are clean, and so the cross-page stitching
  // heuristics (looksFinished / continuation, in ./pdfHeaders) see plain ASCII
  // punctuation. normalizeText also trims, and drops paragraphs that normalize
  // to empty. De-hyphenation already ran during the appendLine join above, so
  // trailing hyphens needed for cross-page joins are preserved here.
  return paragraphs.map(normalizeText).filter(Boolean)
}

/** Best-effort title from PDF metadata `info.Title`, else the filename stem. */
function resolveTitle(infoTitle: unknown, file: File): string {
  if (typeof infoTitle === 'string' && infoTitle.trim()) return infoTitle.trim()
  return file.name.replace(/\.[^.]+$/, '') || file.name || 'Untitled'
}

/**
 * Parse a PDF file into a fully-chunked Doc (text extracted, joined across
 * line-wraps/hyphenation, split into paragraphs and sentences in reading order).
 *
 * @param file       the user-dropped PDF
 * @param onProgress optional 0..1 progress callback (per page parsed)
 */
export async function loadPdf(
  file: File,
  onProgress?: (progress: number) => void,
): Promise<Doc> {
  // Copy into a fresh Uint8Array: pdfjs may transfer/detach the buffer.
  let data: Uint8Array
  try {
    data = new Uint8Array(await file.arrayBuffer())
  } catch {
    throw new Error('Could not read the file. Please try selecting the PDF again.')
  }
  if (data.byteLength === 0) throw new Error('The PDF file is empty.')

  let pdf: pdfjs.PDFDocumentProxy
  try {
    pdf = await pdfjs.getDocument({ data, CMapReaderFactory }).promise
  } catch (err) {
    // pdfjs throws PasswordException (name) for encrypted files.
    const name = (err as { name?: string })?.name
    if (name === 'PasswordException') {
      throw new Error('This PDF is password-protected. Please remove the password and try again.')
    }
    if (name === 'InvalidPDFException') {
      throw new Error('This file is not a valid PDF or is corrupted.')
    }
    const msg = err instanceof Error ? err.message : String(err)
    throw new Error(`Failed to open the PDF: ${msg}`)
  }

  const pageCount = pdf.numPages
  if (pageCount === 0) throw new Error('The PDF has no pages.')

  // Title from metadata (fall back to filename).
  let infoTitle: unknown
  try {
    const meta = await pdf.getMetadata()
    infoTitle = (meta.info as { Title?: unknown } | undefined)?.Title
  } catch {
    infoTitle = undefined // metadata is optional
  }
  // The title is displayed too, so normalize it (metadata titles routinely
  // carry ligatures / smart quotes). Fall back to the raw value if normalizing
  // somehow empties it, so we never show a blank title.
  const rawTitle = resolveTitle(infoTitle, file)
  const title = normalizeText(rawTitle) || rawTitle

  // ── Pass 1: extract lines per page (needed before header detection). ──
  const pageLines: Line[][] = []
  for (let pageNum = 1; pageNum <= pageCount; pageNum++) {
    const page = await pdf.getPage(pageNum)
    const content = await page.getTextContent()

    const pieces: Piece[] = []
    for (const item of content.items) {
      // Skip TextMarkedContent items (they have no `str`).
      if (!('str' in item)) continue
      const str = sanitize(item.str)
      // Keep whitespace-only runs out; geometry handles spacing.
      if (str.trim() === '' && !item.hasEOL) continue
      const t = item.transform as number[]
      pieces.push({
        str,
        x: t[4],
        y: t[5],
        w: item.width,
        h: item.height,
        hasEOL: item.hasEOL,
      })
    }

    pageLines.push(buildLines(pieces))
    page.cleanup() // free page resources as we go
    onProgress?.(pageNum / pageCount)
  }

  // ── Detect repeating headers/footers: across the whole document, and per
  //    page for the ones that run through a chapter or alternate. ──
  const running = runningHeadersByPage(pageLines)

  // ── Pass 2: strip noise, fold into paragraphs, stitch across pages. ──
  const blocks: Block[] = []
  pageLines.forEach((lines, idx) => {
    const cleaned = stripNoise(lines, running[idx])
    const paras = linesToParagraphs(cleaned)
    appendPageParagraphs(blocks, paras, idx + 1)
  })

  // ── Chunk blocks into sentences + paragraphs with cross-referenced ids. ──
  const sentences: Sentence[] = []
  const paragraphs: Paragraph[] = []
  for (const block of blocks) {
    const chunks = chunkParagraph(block.text)
    if (chunks.length === 0) continue
    const paraId = paragraphs.length
    const sentenceIds: number[] = []
    for (const text of chunks) {
      const id = sentences.length
      sentences.push({ id, text, para: paraId, page: block.page })
      sentenceIds.push(id)
    }
    paragraphs.push({ id: paraId, sentenceIds, page: block.page })
  }

  await pdf.destroy() // release the worker document

  if (sentences.length === 0) {
    throw new Error(
      'No readable text found in this PDF. It may be a scanned document (images only).',
    )
  }

  return { title, pageCount, sentences, paragraphs }
}
