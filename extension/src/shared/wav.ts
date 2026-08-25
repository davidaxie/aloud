// ─────────────────────────────────────────────────────────────────────────────
// WAV duration, from the header alone.
//
// The buffer scheduler is denominated in seconds of audio (§1.5), so it needs a
// duration for every clip it holds — including the ones it has synthesized ahead
// but not yet played. Decoding them to find out would defeat the point: an
// AudioContext decode of a whole book's lookahead costs more than the synthesis
// did.
//
// A PCM WAV carries everything needed in its first few dozen bytes: `fmt ` gives
// the byte rate, `data` gives the payload length, and duration is one division.
// So the scheduler works on measured durations rather than estimates, and the
// chars-per-second fallback is only ever used for sentences that have not been
// synthesized yet.
// ─────────────────────────────────────────────────────────────────────────────

/** Bytes of the head worth reading. Comfortably past `fmt ` in any real WAV. */
export const WAV_HEADER_BYTES = 512

/**
 * Duration in seconds of a PCM WAV, or null if `head` isn't a WAV we understand
 * (in which case the caller should estimate rather than trust a wrong number).
 *
 * `head` is the first WAV_HEADER_BYTES of the file; `totalBytes` is its full
 * length, which is what lets us recover from a `data` chunk that declares a
 * placeholder size — as streamed WAV writers do.
 */
export function wavDuration(head: ArrayBuffer, totalBytes: number): number | null {
  if (head.byteLength < 44) return null
  const view = new DataView(head)
  const tag = (at: number) =>
    String.fromCharCode(
      view.getUint8(at),
      view.getUint8(at + 1),
      view.getUint8(at + 2),
      view.getUint8(at + 3),
    )
  if (tag(0) !== 'RIFF' || tag(8) !== 'WAVE') return null

  let byteRate = 0
  // Chunks follow "RIFF<size>WAVE"; each is <id><size><payload>, word-aligned.
  // Every offset below is relative to the chunk, not the file — a `fmt ` chunk is
  // conventionally at 12 but nothing guarantees it, and assuming so reads the
  // byte rate out of whatever chunk actually landed there.
  for (let at = 12; at + 8 <= head.byteLength; ) {
    const id = tag(at)
    const size = view.getUint32(at + 4, true)
    const payload = at + 8

    // fmt payload: format(0) channels(2) sampleRate(4) byteRate(8) …
    if (id === 'fmt ' && payload + 12 <= head.byteLength) {
      byteRate = view.getUint32(payload + 8, true)
    }

    if (id === 'data') {
      if (byteRate <= 0) return null
      const available = totalBytes - payload
      // Trust the declared size only when it fits inside the file we actually
      // have; a 0 or a 0xFFFFFFFF placeholder means "to the end".
      const dataBytes = size > 0 && size <= available ? size : available
      return dataBytes > 0 ? dataBytes / byteRate : null
    }

    // `size` is unsigned, so this always advances — a garbage length walks off
    // the end of the head and ends the loop rather than spinning.
    at = payload + size + (size % 2)
  }
  return null
}
