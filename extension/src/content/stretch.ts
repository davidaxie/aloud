// ─────────────────────────────────────────────────────────────────────────────
// Speed change without a pitch change, for clips played through Web Audio.
//
// The <audio> element speeds speech up and keeps its pitch (preservesPitch).
// An AudioBufferSourceNode cannot: its playbackRate resamples, so 2x would also
// sound an octave up. On a page whose CSP keeps the reader on Web Audio (J039)
// the clip is stretched here instead, by waveform-similarity overlap-add
// (WSOLA), the same family of method Chrome uses for the element.
//
// Each output frame is a windowed slice of the input, taken near where the rate
// says it should come from, slid by up to TOLERANCE_SECONDS to where its
// waveform best continues the previous frame's. Overlapped at half a frame,
// the windows add up to one, so loudness is kept and no seam clicks.
// ─────────────────────────────────────────────────────────────────────────────

/** Frame length, seconds: a few pitch periods of a speaking voice. */
const FRAME_SECONDS = 0.03
/** How far a frame may slide to line its waveform up with the one before. */
const TOLERANCE_SECONDS = 0.008
/** The similarity search runs at about this rate, which is plenty for speech. */
const SEARCH_RATE = 12_000

/**
 * `channels` (one per audio channel, all one length) played `rate` times as
 * fast at the same pitch: new channels about `length / rate` samples long.
 * A rate of 1 returns the input itself.
 */
export function timeStretch(
  channels: Float32Array<ArrayBuffer>[],
  rate: number,
  sampleRate: number,
): Float32Array<ArrayBuffer>[] {
  const n = channels[0]?.length ?? 0
  if (rate === 1 || !(rate > 0) || n === 0) return channels

  // Frames on a grid of the search's step, so a frame's offsets line up with it.
  const step = Math.max(1, Math.round(sampleRate / SEARCH_RATE))
  const hop = Math.max(step, Math.round((FRAME_SECONDS * sampleRate) / 2 / step) * step)
  const frame = hop * 2
  const tolerance = Math.max(1, Math.round((TOLERANCE_SECONDS * sampleRate) / step))
  const outLength = Math.max(1, Math.round(n / rate))

  // A periodic Hann window: two of them half a frame apart sum to exactly one.
  const window = new Float32Array(frame)
  for (let i = 0; i < frame; i++) window[i] = 0.5 - 0.5 * Math.cos((2 * Math.PI * i) / frame)

  const guide = decimate(channels, step)
  const out = channels.map(() => new Float32Array(outLength + frame))
  const weight = new Float32Array(outLength + frame)

  let previous = 0
  for (let at = 0; at < outLength; at += hop) {
    const nominal = Math.round(at * rate)
    const from = at === 0 ? 0 : bestMatch(guide, previous + hop, nominal, tolerance, hop, step)
    const count = Math.min(frame, n - from)
    for (let c = 0; c < channels.length; c++) {
      const src = channels[c]
      const dst = out[c]
      for (let i = 0; i < count; i++) dst[at + i] += src[from + i] * window[i]
    }
    for (let i = 0; i < count; i++) weight[at + i] += window[i]
    previous = from
  }

  // Only the clip's two ends are short of a full overlap; even them out there.
  for (const dst of out) {
    for (let i = 0; i < outLength; i++) if (weight[i] > 1e-3) dst[i] /= weight[i]
  }
  return out.map((dst) => dst.slice(0, outLength))
}

/** The channels mixed and box-averaged down by `step`, for the search. */
function decimate(channels: Float32Array<ArrayBuffer>[], step: number): Float32Array<ArrayBuffer> {
  const n = channels[0].length
  const guide = new Float32Array(Math.floor(n / step))
  for (let j = 0; j < guide.length; j++) {
    let sum = 0
    for (const ch of channels) for (let i = j * step; i < (j + 1) * step; i++) sum += ch[i]
    guide[j] = sum
  }
  return guide
}

/**
 * The input offset near `nominal` whose first `hop` samples look most like
 * what follows the previous frame at `natural`, by cross-correlation on the
 * decimated guide. Offsets are in input samples; the search in guide samples.
 */
function bestMatch(
  guide: Float32Array<ArrayBuffer>,
  natural: number,
  nominal: number,
  tolerance: number,
  hop: number,
  step: number,
): number {
  const len = hop / step
  const last = guide.length - len
  const target = Math.round(natural / step)
  const centre = Math.round(nominal / step)
  const fallback = Math.max(0, Math.min(nominal, (guide.length - 1) * step))
  if (last < 0 || target > last) return fallback
  const lo = Math.max(0, centre - tolerance)
  const hi = Math.min(last, centre + tolerance)
  if (lo > hi) return fallback
  let best = lo
  let bestScore = -Infinity
  for (let p = lo; p <= hi; p++) {
    let score = 0
    for (let i = 0; i < len; i++) score += guide[target + i] * guide[p + i]
    if (score > bestScore) {
      bestScore = score
      best = p
    }
  }
  return best * step
}
