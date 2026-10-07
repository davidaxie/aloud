// ─────────────────────────────────────────────────────────────────────────────
// useKeyboard — global transport shortcuts. Space toggles play/pause; ←/→ step
// sentences. Never hijacks keys while the user is typing in a field, and ignores
// modified chords (⌘/Ctrl/Alt) so browser shortcuts keep working. A control
// keeps the keys it uses itself: a slider its arrows, a button reached with Tab
// its Space (see ../lib/controlKeys).
// ─────────────────────────────────────────────────────────────────────────────
import { useEffect } from 'react'
import { FocusOrigin, globalShortcut, type KeyTargetKind } from '../lib/controlKeys'
import { player } from '../lib/player'
import { useStore } from '../store'

/** What the key landed on, for the decisions in ../lib/controlKeys. */
function keyTargetKind(el: EventTarget | null): KeyTargetKind {
  if (!(el instanceof HTMLElement)) return 'other'
  if (el.tagName === 'INPUT' && (el as HTMLInputElement).type === 'range') return 'range'
  if (
    el.tagName === 'INPUT' ||
    el.tagName === 'TEXTAREA' ||
    el.tagName === 'SELECT' ||
    el.isContentEditable ||
    el.getAttribute('role') === 'textbox'
  ) {
    return 'typing'
  }
  if (el.closest('[role="option"], [role="tab"], [role="menuitem"]')) return 'composite'
  if (el.closest('[role="slider"]')) return 'track'
  if (el.closest('button, a, [role="button"], [role="checkbox"], [role="switch"]')) return 'button'
  return 'other'
}

/**
 * How focus reached each element, saved as it arrives: Chromium already marks
 * a clicked button :focus-visible by the time a keydown listener runs (I021).
 */
const focusOrigin = new FocusOrigin()

export function useKeyboard(): void {
  const hasDoc = useStore((s) => s.doc !== null)

  // Listens from the start, so the control focused before a book opens is known.
  useEffect(() => {
    const onFocusIn = (e: FocusEvent) => focusOrigin.focused(e.target)
    const onPointerDown = (e: PointerEvent) => focusOrigin.pressed(e.target, document.activeElement)
    window.addEventListener('focusin', onFocusIn, true)
    window.addEventListener('pointerdown', onPointerDown, true)
    return () => {
      window.removeEventListener('focusin', onFocusIn, true)
      window.removeEventListener('pointerdown', onPointerDown, true)
    }
  }, [])

  useEffect(() => {
    if (!hasDoc) return

    const onKey = (e: KeyboardEvent) => {
      if (e.defaultPrevented) return
      // A dropped PDF is parsing while the open book waits behind the loading view.
      if (useStore.getState().status === 'loading') return
      if (e.metaKey || e.ctrlKey || e.altKey) return
      // Fields, sliders and lists keep the keys they use; a button the mouse
      // left focused does not keep Space or the arrows (H027). How it got focus
      // is read from focusin, not :focus-visible here (I021).
      const action = globalShortcut(
        e.key,
        keyTargetKind(e.target),
        focusOrigin.reachedByKeyboard(e.target),
      )
      if (!action) return
      // Also stops a focused button from being pressed by the same Space.
      e.preventDefault()
      if (action === 'toggle') player.toggle()
      else if (action === 'prev') player.prev()
      else player.next()
    }

    window.addEventListener('keydown', onKey)
    return () => window.removeEventListener('keydown', onKey)
  }, [hasDoc])
}
