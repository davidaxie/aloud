// ─────────────────────────────────────────────────────────────────────────────
// Reader — the hero surface. Renders the document as flowing, book-like prose
// grouped by paragraph. The currently-spoken sentence gets a soft highlight and
// is gently scrolled into view; clicking any sentence seeks playback there. The
// specific word being spoken is emphasized in real time (karaoke read-along).
//
// Performance: each paragraph is memoized and only re-renders when the active
// sentence enters or leaves it, so highlighting a book of thousands of sentences
// touches just two paragraphs per step. The fast-changing word highlight is
// isolated to <ActiveWords>: it is the ONLY component subscribed to
// `currentWord`, so a new word re-renders one sentence — never the document.
//
// Keyboard: the sentences are one roving-tabindex group (see ../lib/readerNav),
// so the whole book is a single Tab stop on the way to the player controls. A
// sentence keeps the same element whether or not it is active, so focus stays
// put when playback reaches or leaves it — which is why Space and ←/→ on a
// focused sentence still drive the transport, as the header hint says.
// ─────────────────────────────────────────────────────────────────────────────
import {
  memo,
  useEffect,
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
  type CSSProperties,
} from 'react'
import { player } from '../lib/player'
import { tokenizeSentence } from '../lib/chunker'
import {
  autoScrollAllowed,
  browsingAfter,
  clickSeekGate,
  isScrollKey,
  sentenceFocusTarget,
  sentenceKeyAction,
  tabStopSentence,
} from '../lib/readerNav'
import { useStore } from '../store'
import type { Doc, Paragraph, Sentence } from '../types'

// Emphasis for the word currently being spoken. Kept inline (no stylesheet edit
// needed) using the theme-aware accent token so it stays legible in light + dark.
// No transition: the highlight snaps for tight audio sync and there is nothing to
// animate under prefers-reduced-motion.
const ACTIVE_WORD_STYLE: CSSProperties = { color: 'var(--accent)', fontWeight: 600 }

// Bracketed content that "skip skippable" is dropping from playback. Dimmed so the
// reader can see it's being skipped while the display copy stays byte-for-byte intact.
const SKIPPED_WORD_STYLE: CSSProperties = { color: 'var(--text-faint)' }

function seek(sid: number) {
  player.seekTo(sid)
}

/** Text in the reader is selected, so a click there was part of selecting it. */
function selectingInReader(): boolean {
  const selection = window.getSelection()
  if (!selection || selection.isCollapsed) return false
  const node = selection.anchorNode
  const el = node instanceof Element ? node : node?.parentElement
  return !!el?.closest('.reader')
}

// A click on a sentence plays from it, but not a double-click on a word or a
// drag across a phrase: the user is selecting text to copy (L033).
const clickSeek = clickSeekGate(seek, selectingInReader)

/**
 * Enter plays from the sentence. Space plays/pauses and ←/→ step sentences, as
 * they do anywhere on the page (focus follows the step); ↑/↓, Home and End
 * move focus.
 */
function onSentenceKeyDown(e: React.KeyboardEvent, sid: number, count: number) {
  if (e.metaKey || e.ctrlKey || e.altKey) return
  const action = sentenceKeyAction(e.key)
  if (!action) return
  e.preventDefault()
  const reader = (e.currentTarget as HTMLElement).closest('.reader')
  const focus = (target: number) =>
    reader?.querySelector<HTMLElement>(`[data-sentence="${target}"]`)?.focus()
  switch (action) {
    case 'seek':
      seek(sid)
      return
    case 'toggle':
      player.toggle()
      return
    case 'step-next':
      player.next()
      focus(useStore.getState().currentSentence)
      return
    case 'step-prev':
      player.prev()
      focus(useStore.getState().currentSentence)
      return
    default:
      focus(sentenceFocusTarget(sid, action, count))
  }
}

/**
 * The active sentence's words, as individual spans. This component alone
 * subscribes to `currentWord`, so a newly-spoken word re-renders just this
 * sentence. Tokenization is memoized on the text, and the split is
 * non-destructive — the visible copy is byte-identical to `sentence.text`.
 */
const ActiveWords = memo(function ActiveWords({ text }: { text: string }) {
  const currentWord = useStore((s) => s.currentWord)
  const skipSkippable = useStore((s) => s.skipSkippable)
  const tokens = useMemo(() => tokenizeSentence(text), [text])

  return (
    <>
      {tokens.map((tk, i) => {
        // Only dim when skipping is on; the active word is always a spoken word,
        // so a skipped token can never be the current highlight.
        const skipped = skipSkippable && tk.isSkippable
        if (tk.isWord) {
          const isCurrent = !skipped && i === currentWord
          return (
            <span
              key={i}
              className={isCurrent ? 'reader__word is-current' : 'reader__word'}
              style={skipped ? SKIPPED_WORD_STYLE : isCurrent ? ACTIVE_WORD_STYLE : undefined}
            >
              {tk.text}
            </span>
          )
        }
        // Whitespace / bare-punctuation run — reproduced verbatim, never highlighted.
        return (
          <span key={i} style={skipped ? SKIPPED_WORD_STYLE : undefined}>
            {tk.text}
          </span>
        )
      })}
    </>
  )
})

interface ReaderParagraphProps {
  paragraph: Paragraph
  sentences: Sentence[]
  /** The active sentence id if it lives in this paragraph, else -1. */
  activeId: number
  /** The reader's single Tab stop if it lives in this paragraph, else -1. */
  tabStopId: number
  /** Sentences here that playback stepped over, if any. */
  skipped: number[] | undefined
  showPage: boolean
}

const ReaderParagraph = memo(function ReaderParagraph({
  paragraph,
  sentences,
  activeId,
  tabStopId,
  skipped,
  showPage,
}: ReaderParagraphProps) {
  return (
    <>
      {showPage && (
        <div className="reader__page-mark" aria-hidden>
          <span>Page {paragraph.page}</span>
        </div>
      )}
      <p className="reader__para">
        {paragraph.sentenceIds.map((sid) => {
          const s = sentences[sid]
          if (!s) return null
          const active = sid === activeId
          const wasSkipped = skipped?.includes(sid) ?? false
          // The active sentence is word-tokenized and reacts to currentWord; every
          // other sentence stays plain text so it never re-renders on word changes.
          // Same element either way, so a focused sentence keeps focus.
          return (
            <span
              key={sid}
              className={`reader__sent${active ? ' is-active' : ''}${wasSkipped ? ' is-skipped' : ''}`}
              data-sentence={sid}
              data-active={active ? 'true' : undefined}
              aria-current={active ? 'true' : undefined}
              role="button"
              tabIndex={sid === tabStopId ? 0 : -1}
              title={wasSkipped ? 'Skipped: this sentence couldn\u2019t be read' : undefined}
              onClick={(e) => clickSeek.click(sid, e.detail)}
              onKeyDown={(e) => onSentenceKeyDown(e, sid, sentences.length)}
            >
              {active ? <ActiveWords text={s.text} /> : s.text}{' '}
            </span>
          )
        })}
      </p>
    </>
  )
})

interface ReaderProps {
  doc: Doc
  /**
   * Another PDF is parsing (L035): the reader stays mounted under the loading
   * view, out of sight, so a file that can't be read leaves the book showing
   * where it was, scroll and all.
   */
  held?: boolean
}

export function Reader({ doc, held = false }: ReaderProps) {
  const currentSentence = useStore((s) => s.currentSentence)
  const autoScroll = useStore((s) => s.autoScroll)
  const skippedSentences = useStore((s) => s.skippedSentences)
  const scrollRef = useRef<HTMLDivElement>(null)
  // The sentence the keyboard user last focused, while focus stays in the reader.
  const [focusedId, setFocusedId] = useState<number | null>(null)
  // Timestamp of the last deliberate user scroll — we back off auto-scroll for a
  // short window after it so we never fight someone reading ahead.
  const userScrolledAt = useRef(0)
  // The keyboard user moved focus off the sentence being read (↑/↓/Home/End);
  // auto-scroll leaves the view alone until they come back to it.
  const browsing = useRef(false)
  const titleRef = useRef<HTMLHeadingElement>(null)

  // The reader replaces the loading view, and with it the control that had
  // focus: take focus on the title, so a screen reader lands on the book
  // instead of nowhere (J041). Focus moved somewhere on purpose stays there.
  useEffect(() => {
    const focused = document.activeElement
    if (focused && focused !== document.body) return
    titleRef.current?.focus({ preventScroll: true })
  }, [])

  // Held under the loading view (L035), a click waiting to play is dropped and
  // the focus leaves the hidden sentences, so Enter can't play from one. Shown
  // again after a PDF that couldn't be read, the focus goes back where it was,
  // else to the title, as when the reader mounts.
  const wasHeld = useRef(held)
  const heldFocus = useRef<HTMLElement | null>(null)
  useLayoutEffect(() => {
    if (held) {
      clickSeek.cancel()
      wasHeld.current = true
      const focused = document.activeElement
      if (focused instanceof HTMLElement && scrollRef.current?.contains(focused)) {
        heldFocus.current = focused
        focused.blur()
      }
      return
    }
    if (!wasHeld.current) return
    wasHeld.current = false
    const back = heldFocus.current
    heldFocus.current = null
    const focused = document.activeElement
    if (focused && focused !== document.body) return
    const target = back?.isConnected ? back : titleRef.current
    target?.focus({ preventScroll: true })
  }, [held])

  // A click still waiting to play goes with the reader (L033).
  useEffect(() => () => clickSeek.cancel(), [])

  const activePara =
    currentSentence >= 0 ? doc.sentences[currentSentence]?.para ?? -1 : -1
  const tabStopId = tabStopSentence(focusedId, currentSentence, doc.sentences.length)
  const tabStopPara = tabStopId >= 0 ? doc.sentences[tabStopId]?.para ?? -1 : -1

  // Skipped sentences grouped by paragraph, so only the paragraphs that hold
  // one get a new prop (and re-render) when a sentence is skipped.
  const skippedByPara = useMemo(() => {
    const byPara = new Map<number, number[]>()
    for (const sid of skippedSentences) {
      const para = doc.sentences[sid]?.para
      if (para === undefined) continue
      byPara.set(para, [...(byPara.get(para) ?? []), sid])
    }
    return byPara
  }, [skippedSentences, doc])

  // Auto-scroll the active sentence to center, unless the user just scrolled, the
  // keyboard user is browsing, or the auto-scroll option is off (then we never
  // programmatically move the view).
  useEffect(() => {
    const container = scrollRef.current
    if (!container) return
    const allowed = autoScrollAllowed({
      autoScroll,
      current: currentSentence,
      msSinceUserScroll: Date.now() - userScrolledAt.current,
      browsing: browsing.current,
    })
    if (!allowed) return

    const el = container.querySelector<HTMLElement>('[data-active="true"]')
    if (!el) return

    const reduce =
      typeof window !== 'undefined' &&
      window.matchMedia?.('(prefers-reduced-motion: reduce)').matches
    el.scrollIntoView({
      behavior: reduce ? 'auto' : 'smooth',
      block: 'center',
    })
  }, [currentSentence, autoScroll])

  // Unambiguous user-intent signals mark a manual scroll: wheel, touch, and a
  // drag on the scrollbar (H035). A press on the reader itself, not its text,
  // is on its scrollbar; a drag there sends no wheel event, so every scroll
  // while it is held is the user's.
  useEffect(() => {
    const container = scrollRef.current
    if (!container) return
    let held = false
    const mark = () => {
      userScrolledAt.current = Date.now()
    }
    const onDown = (e: PointerEvent) => {
      if (e.target !== container) return
      held = true
      mark()
    }
    const onUp = () => {
      if (!held) return
      held = false
      mark()
    }
    const onMove = (e: PointerEvent) => {
      if (held && e.buttons === 0) onUp()
    }
    const onScroll = () => {
      if (held) mark()
    }
    container.addEventListener('wheel', mark, { passive: true })
    container.addEventListener('touchmove', mark, { passive: true })
    container.addEventListener('pointerdown', onDown)
    container.addEventListener('scroll', onScroll, { passive: true })
    window.addEventListener('pointerup', onUp)
    window.addEventListener('pointercancel', onUp)
    window.addEventListener('pointermove', onMove, { passive: true })
    return () => {
      container.removeEventListener('wheel', mark)
      container.removeEventListener('touchmove', mark)
      container.removeEventListener('pointerdown', onDown)
      container.removeEventListener('scroll', onScroll)
      window.removeEventListener('pointerup', onUp)
      window.removeEventListener('pointercancel', onUp)
      window.removeEventListener('pointermove', onMove)
    }
  }, [])

  return (
    <div
      className={held ? 'reader is-held' : 'reader'}
      ref={scrollRef}
      onFocus={(e) => {
        const sid = (e.target as HTMLElement).dataset.sentence
        if (sid !== undefined) setFocusedId(Number(sid))
      }}
      onBlur={(e) => {
        // Leaving the reader hands the Tab stop back to the sentence being read,
        // and auto-scroll back to following it. Not while held: the focus
        // comes back to where it was (L035).
        if (held) return
        if (!e.currentTarget.contains(e.relatedTarget as Node | null)) {
          setFocusedId(null)
          browsing.current = false
        }
      }}
      onKeyDown={(e) => {
        // Keys a focused sentence took (or let the browser scroll with) decide
        // whether auto-scroll may move the view next (H035).
        if (e.metaKey || e.ctrlKey || e.altKey) return
        if ((e.target as HTMLElement).dataset.sentence === undefined) return
        browsing.current = browsingAfter(sentenceKeyAction(e.key), browsing.current)
        if (isScrollKey(e.key)) userScrolledAt.current = Date.now()
      }}
      onClick={() => {
        // A click plays from the sentence clicked: follow playback again.
        browsing.current = false
      }}
    >
      <article className="reader__col">
        <header className="reader__head">
          <h1 className="reader__title" ref={titleRef} tabIndex={-1}>
            {doc.title}
          </h1>
          <p className="reader__meta">
            {doc.pageCount} {doc.pageCount === 1 ? 'page' : 'pages'} ·{' '}
            {doc.sentences.length} sentences
          </p>
        </header>

        <div className="reader__body">
          {doc.paragraphs.map((para, i) => {
            const prev = doc.paragraphs[i - 1]
            const showPage = i === 0 ? para.page > 1 : para.page !== prev.page
            return (
              <ReaderParagraph
                key={para.id}
                paragraph={para}
                sentences={doc.sentences}
                activeId={para.id === activePara ? currentSentence : -1}
                tabStopId={para.id === tabStopPara ? tabStopId : -1}
                skipped={skippedByPara.get(para.id)}
                showPage={showPage}
              />
            )
          })}
        </div>

        <div className="reader__end" aria-hidden>
          <span>· · ·</span>
        </div>
      </article>
    </div>
  )
}
