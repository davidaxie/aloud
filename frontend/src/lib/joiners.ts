// ─────────────────────────────────────────────────────────────────────────────
// Zero-width joiners in PDF text. ZWJ (U+200D) and ZWNJ (U+200C) beside an
// emoji or a letter of a non-Latin script are spelling: they join a ZWJ emoji
// sequence into one emoji and keep Persian and Devanagari words as written.
// Between Latin letters they are leftovers of ligature breaking, and go. Same
// rule as TextNormalizer.keepsJoiner (iOS/Mac) and _keeps_joiner (backend).
// ─────────────────────────────────────────────────────────────────────────────

const ZWNJ = '‌'
const ZWJ = '‍'

/**
 * A character a joiner beside it belongs to: an emoji (or its presentation
 * selector, skin-tone modifier, keycap or flag tag) or a letter or mark of a
 * non-Latin script.
 */
function shapes(ch: string | undefined): boolean {
  if (ch === undefined) return false
  const cp = ch.codePointAt(0) ?? 0
  if (cp <= 0x7f) return false
  if (
    cp === 0xfe0f || // emoji presentation selector
    cp === 0x20e3 || // combining keycap
    (cp >= 0x2190 && cp <= 0x2bff) || // arrows .. misc symbols, dingbats
    (cp >= 0x1f000 && cp <= 0x1faff) || // emoji blocks, incl. skin-tone modifiers
    (cp >= 0xe0020 && cp <= 0xe007f) // tag characters (subdivision flags)
  ) {
    return true
  }
  if (cp < 0x0370 || (cp >= 0x1e00 && cp <= 0x1eff)) return false // Latin, IPA, diacritics
  return /^[\p{L}\p{M}]$/u.test(ch)
}

/** Whether a joiner between `before` and `after` is spelling, not debris. */
export function keepsJoiner(before: string | undefined, after: string | undefined): boolean {
  return shapes(before) || shapes(after)
}

/** Delete each ZWJ/ZWNJ that `keepsJoiner` does not keep. */
export function dropStrayJoiners(text: string): string {
  if (!text.includes(ZWNJ) && !text.includes(ZWJ)) return text
  const chars = Array.from(text) // code points, so an emoji is one entry
  const out: string[] = []
  chars.forEach((ch, i) => {
    if ((ch === ZWNJ || ch === ZWJ) && !keepsJoiner(out[out.length - 1], chars[i + 1])) return
    out.push(ch)
  })
  return out.join('')
}
