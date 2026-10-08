// ─────────────────────────────────────────────────────────────────────────────
// Slim, non-blocking notices shown just under the header.
//   • StatusBadge — calm warning when the local speech engine isn't reachable.
//   • ErrorBanner — recoverable errors (e.g. a PDF that couldn't be parsed).
// ─────────────────────────────────────────────────────────────────────────────
import { useEffect, useRef } from 'react'
import { useStore } from '../store'
import { CloseIcon } from './Icons'

export function StatusBadge() {
  const engineState = useStore((s) => s.engineState)
  // `unknown` (not yet probed) stays silent so the banner never flashes during
  // a normal startup where the first /health lands moments later.
  if (engineState === 'ok' || engineState === 'unknown') return null

  if (engineState === 'warming') {
    return (
      <div className="banner banner--warn" role="status">
        <span className="banner__dot" aria-hidden />
        <span className="banner__text">
          <strong>Speech engine warming up.</strong> Audio will be ready in a
          moment.
        </span>
      </div>
    )
  }

  return (
    <div className="banner banner--warn" role="status">
      <span className="banner__dot" aria-hidden />
      <span className="banner__text">
        <strong>Speech engine offline.</strong> Reading works, but audio needs the
        local Aloud server running.
      </span>
    </div>
  )
}

/**
 * Where the focus goes when the error banner holding it goes away: the play
 * button with a book open, else the drop target, else the book's title.
 */
function focusAfterBanner(): void {
  for (const selector of ['.play-btn', '.dropzone', '.reader__title']) {
    const target = document.querySelector<HTMLElement>(selector)
    if (!target) continue
    target.focus()
    return
  }
}

export function ErrorBanner() {
  const error = useStore((s) => s.error)
  const setError = useStore((s) => s.setError)
  const bannerRef = useRef<HTMLDivElement>(null)

  // Dismiss, or the error clearing itself (the engine is back, G016), takes
  // the banner and the focus it held: hand the focus on first, while the
  // banner is still on the page, instead of dropping it on the body (L046).
  useEffect(
    () =>
      useStore.subscribe((s, prev) => {
        if (!prev.error || s.error) return
        if (!bannerRef.current?.contains(document.activeElement)) return
        focusAfterBanner()
      }),
    [],
  )

  if (!error) return null

  return (
    <div className="banner banner--error" role="alert" ref={bannerRef}>
      <span className="banner__text">{error}</span>
      <button
        type="button"
        className="banner__close icon-btn icon-btn--sm"
        onClick={() => setError(null)}
        aria-label="Dismiss"
      >
        <CloseIcon size={16} />
      </button>
    </div>
  )
}
