// ─────────────────────────────────────────────────────────────────────────────
// Reader — the hero surface. Renders the document as flowing, book-like prose
// grouped by paragraph. The currently-spoken sentence gets a soft highlight and
// is gently scrolled into view; clicking any sentence seeks playback there. The
// specific word being spoken is emphasized in real time (karaoke read-along).
//
// Performance: each paragraph is memoized and only re-renders when the active
// sentence enters or leaves it, so highlighting a book of thousands of sentences
// touches just two paragraphs per step. The fast-changing word highlight is
// isolated to <ActiveSentence>: it is the ONLY component subscribed to
// `currentWord`, so a new word re-renders one sentence — never the document.
// ─────────────────────────────────────────────────────────────────────────────
import { memo, useEffect, useMemo, useRef, type CSSProperties } from 'react'
import { player } from '../lib/player'
import { tokenizeSentence } from '../lib/chunker'
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

function onSentenceKeyDown(e: React.KeyboardEvent, sid: number) {
  if (e.key === 'Enter') {
    e.preventDefault()
    seek(sid)
  }
}

/**
 * The active sentence, rendered as individual word spans. This component alone
 * subscribes to `currentWord`, so a newly-spoken word re-renders just this
 * sentence. Tokenization is memoized on the text, and the split is
 * non-destructive — the visible copy is byte-identical to `sentence.text`.
 */
const ActiveSentence = memo(function ActiveSentence({
  sentence,
  sid,
}: {
  sentence: Sentence
  sid: number
}) {
  const currentWord = useStore((s) => s.currentWord)
  const skipSkippable = useStore((s) => s.skipSkippable)
  const tokens = useMemo(() => tokenizeSentence(sentence.text), [sentence.text])

  return (
    <span
      className="reader__sent is-active"
      data-sentence={sid}
      data-active="true"
      role="button"
      tabIndex={0}
      onClick={() => seek(sid)}
      onKeyDown={(e) => onSentenceKeyDown(e, sid)}
    >
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
      })}{' '}
    </span>
  )
})

interface ReaderParagraphProps {
  paragraph: Paragraph
  sentences: Sentence[]
  /** The active sentence id if it lives in this paragraph, else -1. */
  activeId: number
  showPage: boolean
}

const ReaderParagraph = memo(function ReaderParagraph({
  paragraph,
  sentences,
  activeId,
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
          // The active sentence is word-tokenized and reacts to currentWord; every
          // other sentence stays plain text so it never re-renders on word changes.
          if (sid === activeId) {
            return <ActiveSentence key={sid} sentence={s} sid={sid} />
          }
          return (
            <span
              key={sid}
              className="reader__sent"
              data-sentence={sid}
              role="button"
              tabIndex={0}
              onClick={() => seek(sid)}
              onKeyDown={(e) => onSentenceKeyDown(e, sid)}
            >
              {s.text}{' '}
            </span>
          )
        })}
      </p>
    </>
  )
})

interface ReaderProps {
  doc: Doc
}

export function Reader({ doc }: ReaderProps) {
  const currentSentence = useStore((s) => s.currentSentence)
  const autoScroll = useStore((s) => s.autoScroll)
  const scrollRef = useRef<HTMLDivElement>(null)
  // Timestamp of the last deliberate user scroll — we back off auto-scroll for a
  // short window after it so we never fight someone reading ahead.
  const userScrolledAt = useRef(0)

  const activePara =
    currentSentence >= 0 ? doc.sentences[currentSentence]?.para ?? -1 : -1

  // Auto-scroll the active sentence to center, unless the user just scrolled or the
  // auto-scroll option is off (then we never programmatically move the view).
  useEffect(() => {
    if (!autoScroll) return
    if (currentSentence < 0) return
    const container = scrollRef.current
    if (!container) return
    if (Date.now() - userScrolledAt.current < 1800) return

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

  // Unambiguous user-intent signals (wheel / touch) mark a manual scroll.
  useEffect(() => {
    const container = scrollRef.current
    if (!container) return
    const mark = () => {
      userScrolledAt.current = Date.now()
    }
    container.addEventListener('wheel', mark, { passive: true })
    container.addEventListener('touchmove', mark, { passive: true })
    return () => {
      container.removeEventListener('wheel', mark)
      container.removeEventListener('touchmove', mark)
    }
  }, [])

  return (
    <div className="reader" ref={scrollRef}>
      <article className="reader__col">
        <header className="reader__head">
          <h1 className="reader__title">{doc.title}</h1>
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
