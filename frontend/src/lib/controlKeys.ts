// ─────────────────────────────────────────────────────────────────────────────
// Keyboard and label decisions for the player controls: the global transport
// keys, the position slider, the play button and the voice list. Kept free of
// React and the DOM so they can be tested without a browser.
// ─────────────────────────────────────────────────────────────────────────────
import type { PlayerStatus } from '../types'

/**
 * What a key landed on, as far as the global transport keys care:
 * - `typing`: a text field, which owns every key
 * - `range`: a native slider (the speed control), which owns the arrows
 * - `track`: the position slider, which owns the arrows, Home/End and Page keys
 * - `button`: a button, link or switch; it has no arrow behaviour, and Space presses it
 * - `composite`: an item in a list, tab row or menu, whose arrows move within it
 * - `other`: anything else (the page, a sentence)
 */
export type KeyTargetKind = 'typing' | 'range' | 'track' | 'button' | 'composite' | 'other'

export type GlobalShortcut = 'toggle' | 'prev' | 'next'

/**
 * The transport action for a key pressed on a target of `kind`, or null to leave
 * the key to the target. `focusVisible` is whether the target shows keyboard
 * focus: Chrome leaves focus on a button the mouse clicked, without the ring,
 * and Space must then play or pause as the header says rather than press that
 * button again (H027). A button reached with Tab still presses on Space.
 */
export function globalShortcut(
  key: string,
  kind: KeyTargetKind,
  focusVisible: boolean,
): GlobalShortcut | null {
  if (kind === 'typing' || kind === 'composite') return null
  switch (key) {
    case ' ':
    case 'Spacebar': // legacy alias
      return kind === 'button' && focusVisible ? null : 'toggle'
    case 'ArrowLeft':
      return kind === 'range' || kind === 'track' ? null : 'prev'
    case 'ArrowRight':
      return kind === 'range' || kind === 'track' ? null : 'next'
    default:
      return null
  }
}

/** Share of the book PageUp/PageDown move on the position slider. */
const PAGE_STEP_FRACTION = 0.05

/**
 * The sentence index a key pressed on the position slider moves to, or null if
 * the slider does not handle it (H037). ←/↓ and →/↑ step one sentence, PageUp
 * and PageDown a twentieth of the book, Home and End go to either end.
 */
export function positionKeyTarget(key: string, current: number, total: number): number | null {
  if (total <= 0) return null
  const at = Math.min(total - 1, Math.max(0, current))
  const page = Math.max(1, Math.round(total * PAGE_STEP_FRACTION))
  let target: number
  switch (key) {
    case 'ArrowRight':
    case 'ArrowUp':
      target = at + 1
      break
    case 'ArrowLeft':
    case 'ArrowDown':
      target = at - 1
      break
    case 'PageDown':
      target = at + page
      break
    case 'PageUp':
      target = at - page
      break
    case 'Home':
      target = 0
      break
    case 'End':
      target = total - 1
      break
    default:
      return null
  }
  return Math.min(total - 1, Math.max(0, target))
}

/** What a screen reader says for the position slider: the sentence and its page. */
export function positionValueText(pos: number, total: number, page?: number): string {
  const sentence = `Sentence ${Math.max(1, Math.min(pos, total))} of ${total}`
  return page ? `${sentence}, page ${page}` : sentence
}

/**
 * The play button's name. While a sentence is buffering the button pauses, so
 * it is named Pause, as on iPhone and Mac (H034); `busy` marks the wait.
 */
export function playButtonLabel(status: PlayerStatus): {
  label: 'Play' | 'Pause'
  title: string
  busy: boolean
} {
  const pauses = status === 'playing' || status === 'buffering'
  return {
    label: pauses ? 'Pause' : 'Play',
    title: pauses ? 'Pause (Space)' : 'Play (Space)',
    busy: status === 'buffering',
  }
}

/**
 * The option focus moves to in a list of `count` for a key pressed on option
 * `index` (-1 for the search field above the list), or null for other keys
 * (H066). ↓/↑ step, Home/End go to either end.
 */
export function listKeyTarget(key: string, index: number, count: number): number | null {
  if (count <= 0) return null
  switch (key) {
    case 'ArrowDown':
      return Math.min(count - 1, index + 1)
    case 'ArrowUp':
      return index < 0 ? null : Math.max(0, index - 1)
    case 'Home':
      return index < 0 ? null : 0
    case 'End':
      return index < 0 ? null : count - 1
    default:
      return null
  }
}
