// ─────────────────────────────────────────────────────────────────────────────
// RateControl — inline playback-speed slider (0.5×–3×). Applied live via the
// player (element playbackRate, pitch-preserved), so dragging is instant and
// never re-synthesizes.
// ─────────────────────────────────────────────────────────────────────────────
import { player } from '../lib/player'
import { useStore } from '../store'
import { SpeedIcon } from './Icons'

const MIN = 0.5
const MAX = 3

function fmt(r: number): string {
  // Trim trailing zeros: 1 → "1×", 1.25 → "1.25×".
  return `${Number(r.toFixed(2))}×`
}

export function RateControl() {
  const rate = useStore((s) => s.rate)
  return (
    <div className="rate-control" title={`Playback speed: ${fmt(rate)}`}>
      <SpeedIcon size={16} />
      <input
        type="range"
        className="rate-slider"
        min={MIN}
        max={MAX}
        step={0.05}
        value={rate}
        onChange={(e) => player.setRate(parseFloat(e.target.value))}
        aria-label="Playback speed"
        aria-valuetext={fmt(rate)}
      />
      <span className="rate-control__value">{fmt(rate)}</span>
    </div>
  )
}
