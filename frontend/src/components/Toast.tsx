// ─────────────────────────────────────────────────────────────────────────────
// Toast — the transient notice for recoverable problems (F4.3): a sentence the
// voice couldn't read, audio the browser wouldn't start. Announced politely and
// gone after a few seconds. The live region stays mounted so screen readers
// catch each new message; the toast id re-arms the timer for a repeated one.
// ─────────────────────────────────────────────────────────────────────────────
import { useEffect } from 'react'
import { useStore } from '../store'

const TOAST_MS = 4000

export function Toast() {
  const toast = useStore((s) => s.toast)
  const dismissToast = useStore((s) => s.dismissToast)
  const id = toast?.id

  useEffect(() => {
    if (id === undefined) return
    const timer = window.setTimeout(dismissToast, TOAST_MS)
    return () => window.clearTimeout(timer)
  }, [id, dismissToast])

  return (
    <div className="toast-region" role="status" aria-live="polite">
      {toast && (
        <div key={toast.id} className="toast">
          {toast.text}
        </div>
      )}
    </div>
  )
}
