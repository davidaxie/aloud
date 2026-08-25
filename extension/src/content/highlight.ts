// ─────────────────────────────────────────────────────────────────────────────
// Read-along highlighting, drawn with the CSS Custom Highlight API.
//
// The obvious implementation — wrap each sentence in a <span class="aloud"> —
// is not an option on someone else's page: it invalidates their CSS selectors,
// fights React/Vue reconciliation, and breaks native text selection. The Custom
// Highlight API exists for exactly this: you register live Ranges with the
// document and style them via ::highlight(), and the DOM is never modified.
//
// Two layers are painted at once: a calm wash over the whole sentence, and a
// stronger karaoke swipe over the word currently being spoken.
//
// Auto-scroll deliberately yields to the user: any manual scroll suspends it for
// a couple of seconds, so a reader who scrolls back to re-read a paragraph isn't
// yanked forward mid-thought.
// ─────────────────────────────────────────────────────────────────────────────

import { locate, type Slice } from './extract'

const SENTENCE_NAME = 'aloud-sentence'
const WORD_NAME = 'aloud-word'
const STYLE_ID = 'aloud-highlight-style'

/** How long a manual scroll suspends auto-scroll. */
const USER_SCROLL_GRACE_MS = 2200

/** Minimal surface of the Custom Highlight API (not in every TS DOM lib yet). */
interface HighlightLike {
  add(range: Range): void
  clear(): void
}
interface HighlightRegistryLike {
  set(name: string, highlight: HighlightLike): void
  delete(name: string): void
}
type HighlightCtor = new (...ranges: Range[]) => HighlightLike

function registry(): HighlightRegistryLike | null {
  const css = (globalThis as { CSS?: { highlights?: HighlightRegistryLike } }).CSS
  return css?.highlights ?? null
}

function highlightCtor(): HighlightCtor | null {
  return (globalThis as { Highlight?: HighlightCtor }).Highlight ?? null
}

const HIGHLIGHT_CSS = `
::highlight(${SENTENCE_NAME}) {
  background-color: rgba(255, 149, 0, 0.20);
}
::highlight(${WORD_NAME}) {
  background-color: rgba(255, 149, 0, 0.48);
}
@media (prefers-color-scheme: dark) {
  ::highlight(${SENTENCE_NAME}) { background-color: rgba(255, 159, 10, 0.24); }
  ::highlight(${WORD_NAME}) { background-color: rgba(255, 159, 10, 0.55); }
}
`

export class Highlighter {
  /** False on browsers without the Custom Highlight API — playback still works. */
  readonly supported: boolean

  private style: HTMLStyleElement | null = null
  private lastUserScroll = 0
  private onUserScroll = () => {
    this.lastUserScroll = performance.now()
  }

  constructor(private slices: Slice[]) {
    this.supported = !!registry() && !!highlightCtor()
    if (this.supported) this.injectStyle()

    // Only *user-initiated* gestures count as "leave me alone" — programmatic
    // scrolling from this class fires 'scroll', which would otherwise suspend us.
    window.addEventListener('wheel', this.onUserScroll, { passive: true, capture: true })
    window.addEventListener('touchmove', this.onUserScroll, { passive: true, capture: true })
    window.addEventListener('keydown', this.onKeyScroll, true)
  }

  private onKeyScroll = (e: KeyboardEvent) => {
    if (
      e.key === 'PageUp' || e.key === 'PageDown' || e.key === 'Home' ||
      e.key === 'End' || e.key === 'ArrowUp' || e.key === 'ArrowDown'
    ) {
      this.onUserScroll()
    }
  }

  private injectStyle() {
    // ::highlight() rules must live in the page document — highlights are
    // registered per-document, so a shadow-root stylesheet would never apply.
    const existing = document.getElementById(STYLE_ID)
    if (existing) existing.remove()
    const style = document.createElement('style')
    style.id = STYLE_ID
    style.textContent = HIGHLIGHT_CSS
    ;(document.head ?? document.documentElement).appendChild(style)
    this.style = style
  }

  /** Swap in a fresh slice index (a re-extraction after the page changed). */
  setSlices(slices: Slice[]) {
    this.slices = slices
  }

  /** Build a live Range for a flat-text span, or null if it can't be mapped. */
  rangeFor(start: number, end: number): Range | null {
    if (end <= start) return null
    const from = locate(this.slices, start, false)
    const to = locate(this.slices, end, true)
    if (!from || !to) return null
    try {
      const range = document.createRange()
      range.setStart(from.node, Math.min(from.offset, from.node.data.length))
      range.setEnd(to.node, Math.min(to.offset, to.node.data.length))
      // A backwards range means the nodes moved under us (SPA re-render).
      return range.collapsed && start !== end ? null : range
    } catch {
      return null
    }
  }

  private paint(name: string, range: Range | null) {
    const reg = registry()
    const Ctor = highlightCtor()
    if (!reg || !Ctor) return
    if (!range) {
      reg.delete(name)
      return
    }
    reg.set(name, new Ctor(range))
  }

  /** Wash the whole sentence. Passing null clears it. */
  setSentence(range: Range | null) {
    this.paint(SENTENCE_NAME, range)
  }

  /** Karaoke swipe over the current word. Passing null clears it. */
  setWord(range: Range | null) {
    this.paint(WORD_NAME, range)
  }

  clear() {
    const reg = registry()
    reg?.delete(SENTENCE_NAME)
    reg?.delete(WORD_NAME)
  }

  // ── auto-scroll ───────────────────────────────────────────────────────────

  /** Nearest ancestor that actually scrolls, or null when the page itself does. */
  private scrollParent(node: Node): Element | null {
    let el: Element | null =
      node.nodeType === Node.ELEMENT_NODE ? (node as Element) : node.parentElement
    while (el && el !== document.body && el !== document.documentElement) {
      const style = getComputedStyle(el)
      const overflow = `${style.overflowY} ${style.overflow}`
      if (/(auto|scroll|overlay)/.test(overflow) && el.scrollHeight > el.clientHeight + 4) {
        return el
      }
      el = el.parentElement
    }
    return null
  }

  /**
   * Keep `range` comfortably in view. No-op if the user scrolled recently, or if
   * the sentence is already inside the comfortable band — so a paragraph reads
   * through without the page twitching on every sentence.
   */
  scrollIntoView(range: Range) {
    if (performance.now() - this.lastUserScroll < USER_SCROLL_GRACE_MS) return

    const rect = range.getBoundingClientRect()
    if (rect.height === 0 && rect.width === 0) return

    const container = this.scrollParent(range.startContainer)
    const view = container
      ? container.getBoundingClientRect()
      : new DOMRect(0, 0, window.innerWidth, window.innerHeight)

    const topBand = view.top + view.height * 0.18
    const bottomBand = view.top + view.height * 0.82
    if (rect.top >= topBand && rect.bottom <= bottomBand) return

    // Park the sentence a third of the way down: enough context above, plenty of
    // upcoming text below.
    const target = view.top + view.height * 0.33
    const delta = rect.top - target
    const behavior: ScrollBehavior = matchMedia('(prefers-reduced-motion: reduce)').matches
      ? 'auto'
      : 'smooth'

    if (container) container.scrollBy({ top: delta, behavior })
    else window.scrollBy({ top: delta, behavior })
  }

  destroy() {
    this.clear()
    this.style?.remove()
    this.style = null
    window.removeEventListener('wheel', this.onUserScroll, true)
    window.removeEventListener('touchmove', this.onUserScroll, true)
    window.removeEventListener('keydown', this.onKeyScroll, true)
  }
}
