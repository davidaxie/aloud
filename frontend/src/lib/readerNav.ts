// ─────────────────────────────────────────────────────────────────────────────
// Keyboard model for the reader's sentences.
//
// The sentences form one roving-tabindex group: a single tab stop (the sentence
// last focused, else the one being read, else the first), with the arrow keys,
// Home and End moving focus inside it. A book of thousands of sentences is then
// one Tab to cross, not thousands, on the way to the player controls. Enter
// plays from the focused sentence. Space and ←/→ stay the app's transport keys
// (play/pause, previous/next sentence) even with a sentence focused — a click
// leaves focus on the sentence, and Space must still pause rather than restart
// it. ↑/↓, Home and End move focus without touching playback.
// ─────────────────────────────────────────────────────────────────────────────

/** Focus moves inside the group; playback is untouched. */
export type SentenceFocusMove = 'next' | 'prev' | 'first' | 'last'

export type SentenceKeyAction = 'seek' | 'toggle' | 'step-next' | 'step-prev' | SentenceFocusMove

/** What a key pressed on a focused sentence does, or null to leave it alone. */
export function sentenceKeyAction(key: string): SentenceKeyAction | null {
  switch (key) {
    case 'Enter':
      return 'seek'
    case ' ':
    case 'Spacebar': // legacy alias
      return 'toggle'
    case 'ArrowRight':
      return 'step-next'
    case 'ArrowLeft':
      return 'step-prev'
    case 'ArrowDown':
      return 'next'
    case 'ArrowUp':
      return 'prev'
    case 'Home':
      return 'first'
    case 'End':
      return 'last'
    default:
      return null
  }
}

/** The sentence focus moves to from `sid` for a movement action, clamped to the document. */
export function sentenceFocusTarget(
  sid: number,
  action: SentenceFocusMove,
  count: number,
): number {
  const last = Math.max(0, count - 1)
  switch (action) {
    case 'next':
      return Math.min(last, sid + 1)
    case 'prev':
      return Math.max(0, sid - 1)
    case 'first':
      return 0
    case 'last':
      return last
  }
}

/**
 * The one sentence that takes part in the Tab order: the one with focus (or
 * last focused while focus stayed in the reader), else the one being read, else
 * the first. -1 for an empty document.
 */
export function tabStopSentence(focused: number | null, current: number, count: number): number {
  if (count <= 0) return -1
  const id = focused ?? current
  return id >= 0 && id < count ? id : 0
}

/** How long auto-scroll holds off after the user scrolls the reader themselves. */
export const USER_SCROLL_HOLD_MS = 1800

/** Keys the browser scrolls the reader with when no sentence takes them. */
export function isScrollKey(key: string): boolean {
  return key === 'PageUp' || key === 'PageDown' || key === 'Home' || key === 'End'
}

/**
 * Whether the keyboard user is browsing after `action` on a focused sentence:
 * ↑/↓, Home and End move focus away from the sentence being read and start
 * it; Enter and ←/→ bring focus and playback together again and end it.
 */
export function browsingAfter(action: SentenceKeyAction | null, browsing: boolean): boolean {
  switch (action) {
    case 'next':
    case 'prev':
    case 'first':
    case 'last':
      return true
    case 'seek':
    case 'step-next':
    case 'step-prev':
      return false
    default:
      return browsing
  }
}

/**
 * Whether a sentence change may scroll the reader to the sentence being read
 * (H035): not with the option off, not just after the user scrolled (wheel,
 * touch, scrollbar, Page keys), and not while the keyboard user is browsing,
 * which would carry the sentence they moved to out of sight.
 */
export function autoScrollAllowed(o: {
  autoScroll: boolean
  current: number
  msSinceUserScroll: number
  browsing: boolean
}): boolean {
  return o.autoScroll && o.current >= 0 && !o.browsing && o.msSinceUserScroll >= USER_SCROLL_HOLD_MS
}

/**
 * How long a click on a sentence waits before it plays from there (L033): the
 * usual double-click time, so the first click of a double-click can be told
 * apart from a click meant to play.
 */
export const CLICK_SEEK_HOLD_MS = 500

export interface ClickSeekTimers {
  set(run: () => void, ms: number): unknown
  clear(handle: unknown): void
}

const WINDOW_TIMERS: ClickSeekTimers = {
  set: (run, ms) => setTimeout(run, ms),
  clear: (handle) => clearTimeout(handle as ReturnType<typeof setTimeout>),
}

export interface ClickSeekGate {
  /** A click on sentence `sid`; `detail` is the click count (0: no pointer behind it). */
  click(sid: number, detail: number): void
  /** Drops a click still waiting, as the reader goes away. */
  cancel(): void
}

/**
 * Click-to-play that leaves selecting text alone (L033, the web twin of the
 * Mac's F005/G008/J022). A click plays from its sentence only once the
 * double-click time has passed with no further click and nothing selected in
 * the reader, so double-clicking a word or dragging across a phrase to copy it
 * neither moves the place nor starts the audio. A click with no pointer behind
 * it (assistive technology) plays at once.
 */
export function clickSeekGate(
  seek: (sid: number) => void,
  selecting: () => boolean,
  timers: ClickSeekTimers = WINDOW_TIMERS,
): ClickSeekGate {
  let pending: unknown = null
  const cancel = () => {
    if (pending !== null) timers.clear(pending)
    pending = null
  }
  return {
    click(sid, detail) {
      cancel()
      if (detail === 0) {
        seek(sid)
        return
      }
      if (detail > 1 || selecting()) return
      pending = timers.set(() => {
        pending = null
        if (!selecting()) seek(sid)
      }, CLICK_SEEK_HOLD_MS)
    },
    cancel,
  }
}
