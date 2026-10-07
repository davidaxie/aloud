// ─────────────────────────────────────────────────────────────────────────────
// PlayerBar — the fixed, minimal transport. A slim seekable progress bar spans
// the top; below it, position + title on the left, play/prev/next in the center,
// and the voice + speed controls on the right.
// ─────────────────────────────────────────────────────────────────────────────
import { useRef, useState } from 'react'
import type { PointerEvent as ReactPointerEvent } from 'react'
import { playButtonLabel, positionKeyTarget, positionValueText } from '../lib/controlKeys'
import { player } from '../lib/player'
import { useStore } from '../store'
import type { Doc } from '../types'
import { PauseIcon, PlayIcon, NextIcon, PrevIcon, SpinnerIcon } from './Icons'
import { VoicePicker } from './VoicePicker'
import { RateControl } from './RateControl'
import { OptionsMenu } from './OptionsMenu'

interface PlayerBarProps {
  doc: Doc
}

export function PlayerBar({ doc }: PlayerBarProps) {
  const status = useStore((s) => s.status)
  const currentSentence = useStore((s) => s.currentSentence)
  const fileName = useStore((s) => s.fileName)

  const total = doc.sentences.length
  const pos = currentSentence >= 0 ? currentSentence + 1 : 0
  const page = currentSentence >= 0 ? doc.sentences[currentSentence]?.page : undefined

  const isPlaying = status === 'playing'
  const isBuffering = status === 'buffering'
  // Buffering pauses on a press, so the button is named Pause then (H034).
  const playButton = playButtonLabel(status)

  // Local drag preview so we don't spam the synthesizer while scrubbing.
  const trackRef = useRef<HTMLDivElement>(null)
  const [preview, setPreview] = useState<number | null>(null)

  const shownIndex = preview ?? Math.max(0, currentSentence)
  const fraction = total > 1 ? shownIndex / (total - 1) : 0

  function indexFromClientX(clientX: number): number {
    const track = trackRef.current
    if (!track || total === 0) return 0
    const rect = track.getBoundingClientRect()
    const frac = rect.width > 0 ? (clientX - rect.left) / rect.width : 0
    const clamped = Math.min(1, Math.max(0, frac))
    return Math.round(clamped * (total - 1))
  }

  function onPointerDown(e: ReactPointerEvent<HTMLDivElement>) {
    if (total === 0) return
    e.currentTarget.setPointerCapture(e.pointerId)
    setPreview(indexFromClientX(e.clientX))
  }
  function onPointerMove(e: ReactPointerEvent<HTMLDivElement>) {
    if (preview === null) return
    setPreview(indexFromClientX(e.clientX))
  }
  function onPointerUp(e: ReactPointerEvent<HTMLDivElement>) {
    if (preview === null) return
    const target = indexFromClientX(e.clientX)
    setPreview(null)
    player.seekTo(target)
  }

  return (
    <footer className="player">
      <div
        ref={trackRef}
        className={`player__track${preview !== null ? ' is-scrubbing' : ''}`}
        role="slider"
        aria-label="Playback position"
        aria-valuemin={1}
        aria-valuemax={total}
        aria-valuenow={Math.max(1, pos)}
        aria-valuetext={positionValueText(pos, total, page)}
        tabIndex={0}
        onPointerDown={onPointerDown}
        onPointerMove={onPointerMove}
        onPointerUp={onPointerUp}
        onKeyDown={(e) => {
          if (e.metaKey || e.ctrlKey || e.altKey) return
          // Arrows step a sentence, Page keys a twentieth of the book, Home/End
          // the ends (H037); playing or paused stays as it was.
          const target = positionKeyTarget(e.key, currentSentence, total)
          if (target === null) return
          e.preventDefault()
          player.moveTo(target)
        }}
      >
        <div className="player__track-fill" style={{ width: `${fraction * 100}%` }} />
        <div className="player__track-thumb" style={{ left: `${fraction * 100}%` }} />
      </div>

      <div className="player__row">
        <div className="player__meta">
          <div className="player__name" title={doc.title || fileName || undefined}>
            {doc.title || fileName || 'Untitled'}
          </div>
          <div className="player__pos">
            {pos} / {total}
            {page ? ` · p.${page}` : ''}
          </div>
        </div>

        <div className="player__transport">
          <button
            type="button"
            className="icon-btn transport-btn"
            onClick={() => player.prev()}
            aria-label="Previous sentence"
            title="Previous (←)"
          >
            <PrevIcon size={20} />
          </button>

          <button
            type="button"
            className="play-btn"
            onClick={() => player.toggle()}
            aria-label={playButton.label}
            aria-busy={playButton.busy}
            title={playButton.title}
            data-state={status}
          >
            {isBuffering ? (
              <SpinnerIcon size={22} />
            ) : isPlaying ? (
              <PauseIcon size={22} />
            ) : (
              <PlayIcon size={22} />
            )}
          </button>

          <span className="visually-hidden" role="status" aria-live="polite">
            {isBuffering ? 'Loading audio' : ''}
          </span>

          <button
            type="button"
            className="icon-btn transport-btn"
            onClick={() => player.next()}
            aria-label="Next sentence"
            title="Next (→)"
          >
            <NextIcon size={20} />
          </button>
        </div>

        <div className="player__controls">
          <VoicePicker />
          <RateControl />
          <OptionsMenu />
        </div>
      </div>
    </footer>
  )
}
