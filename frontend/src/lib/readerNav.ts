// ─────────────────────────────────────────────────────────────────────────────
// Keyboard model for the reader's sentences.
//
// The sentences form one roving-tabindex group: a single tab stop (the sentence
// last focused, else the one being read, else the first), with the arrow keys,
// Home and End moving focus inside it. A book of thousands of sentences is then
// one Tab to cross, not thousands, on the way to the player controls. Enter and
// Space both activate a sentence (play from here), per the ARIA button pattern.
// ─────────────────────────────────────────────────────────────────────────────

export type SentenceKeyAction = 'seek' | 'next' | 'prev' | 'first' | 'last'

/** What a key pressed on a focused sentence does, or null to leave it alone. */
export function sentenceKeyAction(key: string): SentenceKeyAction | null {
  switch (key) {
    case 'Enter':
    case ' ':
    case 'Spacebar': // legacy alias
      return 'seek'
    case 'ArrowDown':
    case 'ArrowRight':
      return 'next'
    case 'ArrowUp':
    case 'ArrowLeft':
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
  action: Exclude<SentenceKeyAction, 'seek'>,
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
