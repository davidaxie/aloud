// ─────────────────────────────────────────────────────────────────────────────
// Page → readable sentences, WITHOUT touching the page.
//
// The desktop reader owns its own DOM, so it can wrap each sentence in a <span>.
// Here the page belongs to someone else: injecting wrappers would break their
// CSS selectors, React reconciliation, and text selection. So instead of
// rewriting the DOM we build a *parallel index* of it:
//
//   1. Pick the article root with a compact Readability-style scorer.
//   2. Walk it depth-first, concatenating every visible text node into one flat
//      string and recording, for each node, the [start, end) span it occupies in
//      that string (a `Slice`). Block-level elements close a "block" so a heading
//      can never merge into the paragraph that follows it.
//   3. Sentence-split each block in OFFSET space (see shared/chunker).
//
// The result: sentence N is a pair of character offsets, which `locate()` turns
// back into (textNode, offset) pairs — everything the highlighter needs to build
// a live Range. Nothing is mutated, so the page is exactly as we found it.
// ─────────────────────────────────────────────────────────────────────────────

import { splitWithOffsets, tokenizeSentence } from '../shared/chunker'
import type { ReadSentence } from '../shared/types'

/**
 * One text node's contribution to the flat string. `nodeStart` is non-zero only
 * for the clipped edge nodes of a selection, so the mapping from a flat offset
 * back to a DOM offset is always `nodeStart + (offset - start)`.
 */
export interface Slice {
  node: Text
  nodeStart: number
  start: number
  end: number
}

/**
 * Whether the page has thrown away any text node the flat span `[start, end)`
 * was read from. An app that swaps an article in by `innerHTML` keeps the
 * container — so the extraction root stays connected — but not one of the old
 * text nodes (G020).
 */
export function spanDetached(slices: Slice[], start: number, end: number): boolean {
  for (const s of slices) {
    if (s.end <= start) continue
    if (s.start >= end) break
    if (!s.node.isConnected) return true
  }
  return false
}

/** A point in the DOM: the node and character offset a flat offset maps to. */
export interface DomPoint {
  node: Text
  offset: number
}

export interface Extraction {
  title: string
  /** Flat concatenation of every visible text node under the root. */
  text: string
  /** Sorted, non-overlapping spans of `text`, each backed by one text node. */
  slices: Slice[]
  sentences: ReadSentence[]
  /** The element we decided holds the article — used to scope click-to-jump. */
  root: Element
  /**
   * True when a safety valve (MAX_TEXT / MAX_SENTENCES) cut the page short, so
   * reaching the last sentence is not the end of the page and must not say so.
   */
  truncated: boolean
}

// ── what never gets read ────────────────────────────────────────────────────

/** Elements whose subtree is never speech: chrome, media, controls, code. */
const SKIP_TAGS = new Set([
  'SCRIPT', 'STYLE', 'NOSCRIPT', 'TEMPLATE', 'IFRAME', 'FRAME', 'OBJECT', 'EMBED',
  'SVG', 'CANVAS', 'VIDEO', 'AUDIO', 'MAP', 'AREA', 'TRACK', 'SOURCE',
  'SELECT', 'OPTION', 'TEXTAREA', 'INPUT', 'BUTTON', 'LABEL', 'FORM',
  'NAV', 'ASIDE', 'FOOTER', 'DIALOG', 'MENU',
  // Code blocks read terribly aloud; inline <code> inside a sentence is kept.
  // The one exception is a PRE that IS the document — see plainTextPre().
  'PRE',
])

/**
 * What a selection still never reads (H030): the subtrees that hold no speech
 * at all — scripts, styles, media, embeds and form controls. The rest of
 * SKIP_TAGS, and SKIP_ROLES, JUNK_RE and the link-density rule, guess at what
 * a reader wants from a whole page. A selection says it outright: a comment, a
 * sidebar or a footer the user selected is read like any paragraph.
 */
const SELECTION_SKIP_TAGS = new Set([
  'SCRIPT', 'STYLE', 'NOSCRIPT', 'TEMPLATE', 'IFRAME', 'FRAME', 'OBJECT', 'EMBED',
  'SVG', 'CANVAS', 'VIDEO', 'AUDIO', 'MAP', 'AREA', 'TRACK', 'SOURCE',
  'SELECT', 'OPTION', 'TEXTAREA', 'INPUT', 'BUTTON',
])

/** ARIA roles that mark page furniture rather than content. */
const SKIP_ROLES = new Set([
  'navigation', 'banner', 'complementary', 'contentinfo', 'search', 'form',
  'menu', 'menubar', 'toolbar', 'tablist', 'dialog', 'alertdialog', 'button',
])

/** Elements that start a new block, so sentences never span across them. */
const BLOCK_TAGS = new Set([
  'ADDRESS', 'ARTICLE', 'ASIDE', 'BLOCKQUOTE', 'DD', 'DIV', 'DL', 'DT',
  'FIELDSET', 'FIGCAPTION', 'FIGURE', 'FOOTER', 'FORM', 'H1', 'H2', 'H3', 'H4',
  'H5', 'H6', 'HEADER', 'HR', 'LI', 'MAIN', 'NAV', 'OL', 'P', 'SECTION',
  'TABLE', 'TBODY', 'TD', 'TFOOT', 'TH', 'THEAD', 'TR', 'UL',
  // Walked only in a selection (H030), where they still end a block.
  'DIALOG', 'MENU', 'PRE',
])

/**
 * Class/id fragments that reliably mean "not the article".
 *
 * The reference-apparatus entries (references, reflist, citations, navboxes,
 * infoboxes, edit links) matter more than they look: on a Wikipedia page they
 * are the difference between hearing the article and hearing four hundred
 * citations read aloud.
 */
const JUNK_RE =
  /(^|[-_\s])(ads?|advert|advertisement|promo|sponsor|banner|share|sharing|social|comment|comments|disqus|related|recirc|recommend|newsletter|subscribe|signup|paywall|cookie|consent|gdpr|popup|modal|overlay|lightbox|breadcrumbs?|pagination|pager|sidebar|widget|masthead|toolbar|skip-link|screen-reader|visually-hidden|sr-only|byline|caption-credit|copyright|tag-list|meta-data|references|reflist|footnotes?|bibliography|navbox|infobox|catlinks|editsection|noprint|hatnote|shortdescription|toc)([-_\s]|$)/i

/** Positive/negative class-name signals for the Readability-style scorer. */
const POSITIVE_RE = /(article|body|content|entry|main|page|post|story|text|blog|column|prose|markdown)/i
const NEGATIVE_RE =
  /(comment|combx|disqus|foot|footer|masthead|menu|meta|nav|promo|related|scroll|share|shoutbox|sidebar|sponsor|ad-|advert|popup|tweet|social|subscribe|newsletter|cookie|banner|breadcrumb|widget|toolbar|byline|hidden|reference|citation|footnote|bibliograph|infobox|navbox|catlinks)/i

/**
 * Structural prior on a candidate container, straight out of Readability: a
 * <div> or <article> is where prose lives; a list, form or table is where data
 * and navigation live. Without this a citation list — hundreds of comma-rich
 * <li>s — outscores the article it belongs to.
 */
const TAG_WEIGHT: Record<string, number> = {
  ARTICLE: 10, MAIN: 10, SECTION: 5, DIV: 5, BLOCKQUOTE: 3, PRE: 3, TD: 3,
  OL: -8, UL: -8, DL: -5, DD: -3, DT: -3, LI: -8, FORM: -5, TABLE: -3,
  ASIDE: -10, NAV: -15, HEADER: -10, FOOTER: -10,
  H1: -5, H2: -5, H3: -5, H4: -5, H5: -5, H6: -5,
}

/** How much a scoring node contributes, by tag. Prose counts for more than lists. */
const SOURCE_WEIGHT: Record<string, number> = {
  P: 1, BLOCKQUOTE: 1, H2: 0.5, H3: 0.5, LI: 0.35, DD: 0.35,
}

/** Safety valves so a pathological page can't hang the tab. */
const MAX_TEXT = 600_000
const MAX_SENTENCES = 8000

// ── root selection ──────────────────────────────────────────────────────────

function classId(el: Element): string {
  const cls = typeof el.className === 'string' ? el.className : ''
  return `${cls} ${el.id ?? ''}`
}

/** Fraction of an element's text that sits inside links — high means "nav". */
function linkDensity(el: Element): number {
  const total = el.textContent?.length ?? 0
  if (!total) return 0
  let linked = 0
  for (const a of el.querySelectorAll('a')) linked += a.textContent?.length ?? 0
  return linked / total
}

/**
 * Pick the element most likely to be the article body.
 *
 * Classic Readability: every paragraph-ish node contributes a score to its
 * ancestors (full to the parent, half to the grandparent, a third above that),
 * weighted by length and comma count; class/id names nudge candidates up or
 * down; link-heavy candidates are discounted. Semantic containers get a head
 * start so a well-marked-up page short-circuits to the obvious answer.
 */
function findContentRoot(doc: Document): Element {
  const body = doc.body
  if (!body) return doc.documentElement

  const scores = new Map<Element, number>()
  const bump = (el: Element | null, amount: number) => {
    if (!el || el === body || el.tagName === 'HTML') return
    scores.set(el, (scores.get(el) ?? 0) + amount)
  }

  // Semantic head start — an explicit <article> should win unless it is empty.
  for (const el of doc.querySelectorAll('article, main, [role="main"]')) {
    if ((el.textContent?.trim().length ?? 0) > 200) bump(el, 40)
  }

  for (const el of doc.querySelectorAll('p, li, blockquote, h2, h3, dd')) {
    const text = el.textContent ?? ''
    if (text.trim().length < 25) continue
    let score = 1
    score += (text.match(/,/g)?.length ?? 0)
    score += Math.min(Math.floor(text.length / 100), 3)
    score *= SOURCE_WEIGHT[el.tagName] ?? 0.5
    bump(el.parentElement, score)
    bump(el.parentElement?.parentElement ?? null, score / 2)
    bump(el.parentElement?.parentElement?.parentElement ?? null, score / 3)
  }

  /** Final score for a candidate: content + structure + naming, minus link noise. */
  const finalScore = (el: Element, raw: number): number => {
    const name = classId(el)
    let score = raw + (TAG_WEIGHT[el.tagName] ?? 0)
    if (POSITIVE_RE.test(name)) score += 25
    if (NEGATIVE_RE.test(name)) score -= 25
    // A wall of links is a nav column, however many paragraphs it contains.
    return score * (1 - Math.min(linkDensity(el), 0.9))
  }

  let best: Element | null = null
  let bestScore = 0
  for (const [el, raw] of scores) {
    const score = finalScore(el, raw)
    if (score > bestScore) {
      bestScore = score
      best = el
    }
  }

  // Too little signal to trust (link farms, apps, single-screen pages) — read
  // the whole body and lean on the per-element skip rules instead.
  if (!best || bestScore < 12) return body

  // Climb while the parent is at least as good: a winning <div> is often one
  // column of a wrapper that holds the intro, the body AND the outro.
  let parent = best.parentElement
  while (parent && parent !== body && parent.tagName !== 'HTML') {
    const score = finalScore(parent, scores.get(parent) ?? 0)
    if (score < bestScore) break
    best = parent
    bestScore = score
    parent = parent.parentElement
  }
  return best
}

/**
 * The <pre> that IS the document, when there is one.
 *
 * Chrome shows a text/plain response (a Gutenberg .txt, an RFC, a raw README) as
 * `body > pre`. That PRE is the article, not a code block, so the SKIP_TAGS rule
 * that keeps code out of speech must not swallow it. Outside a text/plain
 * document we only trust a PRE that is the body's sole element and holds no code.
 */
function plainTextPre(doc: Document): Element | null {
  const pre = doc.body?.firstElementChild
  if (!pre || pre.tagName !== 'PRE') return null
  if (doc.contentType === 'text/plain') return pre
  const codeLike = pre.querySelector('code') !== null || /(^|\s)lang(uage)?-/.test(classId(pre))
  return doc.body.childElementCount === 1 && !codeLike ? pre : null
}

/**
 * Paragraphs of a plain-text run, as [start, end) spans of `text`.
 *
 * Plain text marks a paragraph with a blank line and wraps its lines at ~70
 * columns, so a single newline is NOT a break: only a blank line (whitespace
 * allowed) starts a new block.
 */
export function paragraphSpans(
  text: string,
  start: number,
  end: number,
): Array<{ start: number; end: number }> {
  const out: Array<{ start: number; end: number }> = []
  const blank = /\n[^\S\n]*(?:\n[^\S\n]*)+/g
  blank.lastIndex = start
  let from = start
  for (let m = blank.exec(text); m && m.index < end; m = blank.exec(text)) {
    if (/\S/.test(text.slice(from, m.index))) out.push({ start: from, end: m.index })
    from = Math.min(end, m.index + m[0].length)
  }
  if (/\S/.test(text.slice(from, end))) out.push({ start: from, end })
  return out
}

/** Best-effort human title for the player bar. */
function pageTitle(doc: Document, root: Element): string {
  const h1 = root.querySelector('h1') ?? doc.querySelector('h1')
  const heading = h1?.textContent?.replace(/\s+/g, ' ').trim()
  if (heading && heading.length > 2 && heading.length <= 140) return heading
  const title = doc.title?.replace(/\s+/g, ' ').trim()
  return title || doc.location.hostname || 'This page'
}

// ── the walk ────────────────────────────────────────────────────────────────

interface WalkState {
  text: string
  slices: Slice[]
  blocks: Array<{ start: number; end: number }>
  blockStart: number
  blockHasText: boolean
  /** Restrict collection to this range (selection reading); undefined = whole root. */
  restrict?: Range
  /** Our own injected UI, which must never be read back to the user. */
  uiHost: Element | null
  /** Set when a safety valve stopped collection before the page ran out. */
  truncated: boolean
}

function isHidden(el: Element): boolean {
  if (el.hasAttribute('hidden')) return true
  if (el.getAttribute('aria-hidden') === 'true') return true
  // checkVisibility covers display:none, visibility:hidden, content-visibility
  // and detached subtrees in one cheap call (Chrome 105+).
  const check = (el as Element & { checkVisibility?: (o?: object) => boolean }).checkVisibility
  if (typeof check === 'function') {
    return !check.call(el, { checkVisibilityCSS: true, contentVisibilityAuto: true })
  }
  const style = el.ownerDocument.defaultView?.getComputedStyle(el)
  return !!style && (style.display === 'none' || style.visibility === 'hidden')
}

function shouldSkip(el: Element, state: WalkState): boolean {
  // Never read our own UI back to the user. The marker attribute covers the
  // player bar and any toast; uiHost covers anything passed in explicitly.
  if (el.hasAttribute('data-aloud')) return true
  if (state.uiHost && (el === state.uiHost || state.uiHost.contains(el))) return true
  // A selection is read as selected: only what can never be speech is left out
  // of it, and the page-furniture guesses below are for whole pages (H030).
  const selecting = state.restrict !== undefined
  if ((selecting ? SELECTION_SKIP_TAGS : SKIP_TAGS).has(el.tagName)) return true

  const role = el.getAttribute('role')
  if (!selecting && role && SKIP_ROLES.has(role)) return true

  // Footnote/reference markers: "1", "[2]" read aloud mid-sentence is noise.
  if (el.tagName === 'SUP' && (el.textContent?.trim().length ?? 0) <= 4) return true

  if (!selecting && JUNK_RE.test(classId(el))) return true
  if (isHidden(el)) return true
  if (selecting) return false

  // A list whose text is almost entirely link text is navigation, not prose.
  if (el.tagName === 'LI' || el.tagName === 'UL' || el.tagName === 'OL') {
    const len = el.textContent?.length ?? 0
    if (len > 0 && len < 400 && linkDensity(el) > 0.8) return true
  }
  return false
}

/** Close the current block, recording it if it held any real text. */
function closeBlock(state: WalkState) {
  if (state.blockHasText && state.text.length > state.blockStart) {
    state.blocks.push({ start: state.blockStart, end: state.text.length })
  }
  // A newline separator keeps the flat text readable for debugging. No slice
  // covers it, and no sentence span ever reaches it (spans live inside blocks).
  if (state.blockHasText) state.text += '\n'
  state.blockStart = state.text.length
  state.blockHasText = false
}

function appendText(node: Text, state: WalkState) {
  let data = node.data
  let nodeStart = 0

  // Selection reading: clip the two edge nodes to the selected characters.
  if (state.restrict) {
    if (!state.restrict.intersectsNode(node)) return
    if (node === state.restrict.endContainer) data = data.slice(0, state.restrict.endOffset)
    if (node === state.restrict.startContainer) {
      nodeStart = state.restrict.startOffset
      data = data.slice(nodeStart)
    }
  }

  if (!data) return
  const start = state.text.length
  state.text += data
  state.slices.push({ node, nodeStart, start, end: start + data.length })
  if (/\S/.test(data)) state.blockHasText = true
}

function walk(el: Element, state: WalkState) {
  for (let child = el.firstChild; child; child = child.nextSibling) {
    if (state.text.length > MAX_TEXT) {
      state.truncated = true
      return
    }

    if (child.nodeType === Node.TEXT_NODE) {
      appendText(child as Text, state)
      continue
    }
    if (child.nodeType !== Node.ELEMENT_NODE) continue

    const e = child as Element
    // Cheap prune: for a selection, ignore whole subtrees outside it.
    if (state.restrict && !state.restrict.intersectsNode(e)) continue
    if (shouldSkip(e, state)) continue

    if (e.tagName === 'BR') {
      closeBlock(state)
      continue
    }
    const isBlock = BLOCK_TAGS.has(e.tagName)
    if (isBlock) closeBlock(state)
    walk(e, state)
    if (isBlock) closeBlock(state)
  }
}

// ── assembly ────────────────────────────────────────────────────────────────

/** Does this span carry actual words, or is it a stray bullet / number / glyph? */
function isSpeakable(normalized: string): boolean {
  if (normalized.length < 2) return false
  if (!/[A-Za-z0-9À-ɏЀ-ӿ一-鿿]/.test(normalized)) return false
  return true
}

/**
 * Sentence-split every block. `plain` unwraps hard line breaks first: the
 * sentence segmenter treats a newline as a hard stop, which would cut wrapped
 * plain text into line fragments. Newline → space keeps every offset intact.
 */
function buildSentences(state: WalkState, plain = false): ReadSentence[] {
  const out: ReadSentence[] = []
  for (const block of state.blocks) {
    const body = state.text.slice(block.start, block.end)
    if (body.trim().length < 3) continue

    for (const span of splitWithOffsets(plain ? body.replace(/[\r\n]/g, ' ') : body)) {
      const start = block.start + span.start
      const end = block.start + span.end
      const raw = state.text.slice(start, end)
      const text = raw.replace(/\s+/g, ' ').trim()
      if (!isSpeakable(text)) continue
      if (out.length >= MAX_SENTENCES) {
        state.truncated = true
        return out
      }
      out.push({ id: out.length, raw, text, start, end, tokens: tokenizeSentence(raw) })
    }
  }
  return out
}

function newState(uiHost: Element | null, restrict?: Range): WalkState {
  return {
    text: '',
    slices: [],
    blocks: [],
    blockStart: 0,
    blockHasText: false,
    restrict,
    uiHost,
    truncated: false,
  }
}

/** `plain`: root is a plain-text PRE, whose paragraphs are its blank lines. */
function run(
  root: Element,
  uiHost: Element | null,
  restrict?: Range,
  plain = false,
): Extraction | null {
  const state = newState(uiHost, restrict)
  walk(root, state)
  closeBlock(state)
  if (plain) state.blocks = state.blocks.flatMap((b) => paragraphSpans(state.text, b.start, b.end))

  const sentences = buildSentences(state, plain)
  if (sentences.length === 0) return null

  return {
    title: pageTitle(root.ownerDocument, root),
    text: state.text,
    slices: state.slices,
    sentences,
    root,
    truncated: state.truncated,
  }
}

/** Extract the article from the current document. Returns null if there's no prose. */
export function extractPage(uiHost: Element | null): Extraction | null {
  const pre = plainTextPre(document)
  if (pre) return run(pre, uiHost, undefined, true)
  return run(findContentRoot(document), uiHost)
}

/**
 * Read text that has no reachable DOM behind it: a selection Chrome reported
 * from a frame this script can't see into. There is nothing to highlight, so
 * there are no slices — the text is read as plain text.
 */
export function extractText(text: string): Extraction | null {
  const state = newState(null)
  state.text = text.length > MAX_TEXT ? text.slice(0, MAX_TEXT) : text
  state.truncated = text.length > MAX_TEXT
  state.blocks = paragraphSpans(state.text, 0, state.text.length)
  const sentences = buildSentences(state, true)
  if (sentences.length === 0) return null
  return {
    title: 'Selection',
    text: state.text,
    slices: [],
    sentences,
    root: document.body ?? document.documentElement,
    truncated: state.truncated,
  }
}

/**
 * Extract just the user's selection. The walk starts at the selection's common
 * ancestor and clips to the range, so mid-paragraph selections read exactly the
 * highlighted characters — no more, no less.
 */
export function extractSelection(uiHost: Element | null): Extraction | null {
  const sel = window.getSelection()
  if (!sel) return null
  const range = !sel.isCollapsed && sel.rangeCount > 0 ? sel.getRangeAt(0) : null
  if (range && range.toString().trim()) {
    const ancestor = range.commonAncestorContainer
    let root =
      ancestor.nodeType === Node.ELEMENT_NODE
        ? (ancestor as Element)
        : ancestor.parentElement ?? document.body
    // Select-all on a plain-text page anchors on <body>; start inside the PRE
    // that holds every word, so its hard-wrapped lines are read as paragraphs.
    const pre = plainTextPre(document)
    if (pre && root.contains(pre)) root = pre
    const extraction = run(root, uiHost, range, pre !== null && pre.contains(root))
    if (extraction) {
      extraction.title = 'Selection'
      return extraction
    }
  }
  // Text selected in a text field or a shadow tree has no range in the page's
  // DOM — Chrome reports such a selection as collapsed — yet toString() still
  // holds the words (H032). Read them as plain text, as a frame's selection is:
  // nothing to highlight, but nothing lost. The same net catches a walk that
  // found nothing speakable in text the user plainly selected (H030).
  const plain = sel.toString().trim()
  return plain ? extractText(plain) : null
}

// ── offset ⇄ DOM mapping ────────────────────────────────────────────────────

/**
 * Flat offset → DOM point, by binary search over the slices.
 *
 * `isEnd` matters at a boundary: offset 40 is both the end of slice A and the
 * start of slice B. A range's END should land at A's tail (so the highlight
 * stops at the last real character) while a START should land at B's head.
 */
export function locate(slices: Slice[], offset: number, isEnd = false): DomPoint | null {
  if (slices.length === 0) return null
  let lo = 0
  let hi = slices.length - 1
  while (lo <= hi) {
    const mid = (lo + hi) >> 1
    const s = slices[mid]
    // The half-open interval flips for an end point — offset 12 is the END of
    // slice [4,12) but the START of slice [12,20). The search direction has to
    // flip with it, or a boundary offset walks straight past its own slice and
    // lands in the next one, over-covering the range by a whole node.
    if (isEnd ? offset <= s.start : offset < s.start) hi = mid - 1
    else if (isEnd ? offset > s.end : offset >= s.end) lo = mid + 1
    else return { node: s.node, offset: s.nodeStart + (offset - s.start) }
  }
  // Offset fell in a gap (a block separator). Clamp to the nearest slice edge —
  // the one just before it for an end point, just after it for a start.
  const idx = Math.min(Math.max(isEnd ? hi : lo, 0), slices.length - 1)
  const s = slices[idx]
  const clamped = Math.min(Math.max(offset, s.start), s.end)
  return { node: s.node, offset: s.nodeStart + (clamped - s.start) }
}

/**
 * DOM point → flat offset (the inverse of `locate`), used by click-to-jump.
 * Returns -1 when the node isn't part of the extracted text.
 */
export function offsetOf(slices: Slice[], node: Node, nodeOffset: number): number {
  if (node.nodeType !== Node.TEXT_NODE) return -1
  for (const s of slices) {
    if (s.node !== node) continue
    const local = Math.min(Math.max(nodeOffset - s.nodeStart, 0), s.end - s.start)
    return s.start + local
  }
  return -1
}
