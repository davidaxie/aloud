// ─────────────────────────────────────────────────────────────────────────────
// LoadingView — tasteful progress state shown while a PDF is being parsed.
// ─────────────────────────────────────────────────────────────────────────────
import { useStore } from '../store'
import { FileIcon } from './Icons'

export function LoadingView() {
  const fileName = useStore((s) => s.fileName)
  const progress = useStore((s) => s.loadProgress)
  const pct = Math.round(Math.min(1, Math.max(0, progress)) * 100)

  return (
    <div className="loading-view">
      <div className="loading-card">
        <div className="loading-card__icon" aria-hidden>
          <FileIcon size={22} />
        </div>
        <div className="loading-card__title">Preparing your document</div>
        <div className="loading-card__name" title={fileName ?? undefined}>
          {fileName ?? 'Reading pages…'}
        </div>

        <div
          className="loading-bar"
          role="progressbar"
          aria-valuemin={0}
          aria-valuemax={100}
          aria-valuenow={pct}
          aria-label="Parsing progress"
        >
          <div className="loading-bar__fill" style={{ width: `${pct}%` }} />
        </div>
        <div className="loading-card__pct">{pct}%</div>
      </div>
    </div>
  )
}
