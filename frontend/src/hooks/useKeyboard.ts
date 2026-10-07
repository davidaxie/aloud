// ─────────────────────────────────────────────────────────────────────────────
// useKeyboard — global transport shortcuts. Space toggles play/pause; ←/→ step
// sentences. Never hijacks keys while the user is typing in a field, and ignores
// modified chords (⌘/Ctrl/Alt) so browser shortcuts keep working.
// ─────────────────────────────────────────────────────────────────────────────
import { useEffect } from 'react'
import { player } from '../lib/player'
import { useStore } from '../store'

function isTypingTarget(el: EventTarget | null): boolean {
  if (!(el instanceof HTMLElement)) return false
  const tag = el.tagName
  return (
    tag === 'INPUT' ||
    tag === 'TEXTAREA' ||
    tag === 'SELECT' ||
    el.isContentEditable ||
    el.getAttribute('role') === 'textbox'
  )
}

// Controls that handle Space/Enter/Arrows themselves — don't let the global
// transport shortcuts double-fire on top of a focused button, link, or slider
// (e.g. clicking Play focuses it; pressing Space would then toggle twice).
function isSelfHandlingControl(el: EventTarget | null): boolean {
  if (!(el instanceof HTMLElement)) return false
  return !!el.closest(
    'button, a, [role="button"], [role="slider"], [role="checkbox"], [role="tab"], [role="menuitem"], [role="option"]',
  )
}

export function useKeyboard(): void {
  const hasDoc = useStore((s) => s.doc !== null)

  useEffect(() => {
    if (!hasDoc) return

    const onKey = (e: KeyboardEvent) => {
      if (e.defaultPrevented) return
      // A dropped PDF is parsing while the open book waits behind the loading view.
      if (useStore.getState().status === 'loading') return
      if (e.metaKey || e.ctrlKey || e.altKey) return
      if (isTypingTarget(e.target)) return
      // Space/Arrows on a focused control (Play, Prev/Next, sliders…) belong to
      // that control, not the global transport.
      if (isSelfHandlingControl(e.target)) return

      switch (e.key) {
        case ' ':
        case 'Spacebar': // legacy alias
          e.preventDefault()
          player.toggle()
          break
        case 'ArrowLeft':
          e.preventDefault()
          player.prev()
          break
        case 'ArrowRight':
          e.preventDefault()
          player.next()
          break
        default:
          break
      }
    }

    window.addEventListener('keydown', onKey)
    return () => window.removeEventListener('keydown', onKey)
  }, [hasDoc])
}
