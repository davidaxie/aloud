// ─────────────────────────────────────────────────────────────────────────────
// OptionsMenu — compact popover with the reader's toggleable options. A sliders
// chip (matching the voice/rate triggers) opens a small dialog with two switches:
//   • Auto-scroll — follow the current line while playing (store only).
//   • Skip content in ( ) — drop parentheticals from what's read + highlighted.
// The skip toggle routes through the player (like voice/rate) so it re-synthesizes
// the current sentence immediately; auto-scroll only reads from the store.
// ─────────────────────────────────────────────────────────────────────────────
import { useEffect, useRef, useState } from 'react'
import type { SVGProps } from 'react'
import { player } from '../lib/player'
import { useStore } from '../store'
import { ChevronIcon } from './Icons'

function SlidersIcon({ size = 17, ...p }: SVGProps<SVGSVGElement> & { size?: number }) {
  return (
    <svg
      width={size}
      height={size}
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth={1.75}
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden
      focusable={false}
      {...p}
    >
      <path d="M4 6h10M18 6h2M4 12h2M10 12h10M4 18h10M18 18h2" />
      <circle cx="16" cy="6" r="2" />
      <circle cx="8" cy="12" r="2" />
      <circle cx="16" cy="18" r="2" />
    </svg>
  )
}

interface OptionRowProps {
  label: string
  hint: string
  checked: boolean
  onChange: (v: boolean) => void
}

/** A full-width labelled row that is itself the switch (role=switch, aria-checked). */
function OptionRow({ label, hint, checked, onChange }: OptionRowProps) {
  return (
    <button
      type="button"
      role="switch"
      aria-checked={checked}
      className={`opt-row${checked ? ' is-on' : ''}`}
      onClick={() => onChange(!checked)}
    >
      <span className="opt-row__text">
        <span className="opt-row__label">{label}</span>
        <span className="opt-row__hint">{hint}</span>
      </span>
      <span className="opt-switch" aria-hidden>
        <span className="opt-switch__thumb" />
      </span>
    </button>
  )
}

export function OptionsMenu() {
  const autoScroll = useStore((s) => s.autoScroll)
  const skipSkippable = useStore((s) => s.skipSkippable)
  const setAutoScroll = useStore((s) => s.setAutoScroll)

  const [open, setOpen] = useState(false)
  const wrapRef = useRef<HTMLDivElement>(null)
  const triggerRef = useRef<HTMLButtonElement>(null)

  // Close on outside click / Escape (mirrors VoicePicker / RateControl). Escape
  // from a switch hands focus back to the chip (H066).
  useEffect(() => {
    if (!open) return
    const onDown = (e: MouseEvent) => {
      if (!wrapRef.current?.contains(e.target as Node)) setOpen(false)
    }
    const onKey = (e: KeyboardEvent) => {
      if (e.key !== 'Escape') return
      const hadFocus = wrapRef.current?.contains(document.activeElement) ?? false
      setOpen(false)
      if (hadFocus) triggerRef.current?.focus()
    }
    document.addEventListener('mousedown', onDown)
    document.addEventListener('keydown', onKey)
    return () => {
      document.removeEventListener('mousedown', onDown)
      document.removeEventListener('keydown', onKey)
    }
  }, [open])

  return (
    <div className="options-menu" ref={wrapRef}>
      <button
        ref={triggerRef}
        type="button"
        className="control-chip control-chip--icon"
        onClick={() => setOpen((o) => !o)}
        aria-haspopup="dialog"
        aria-expanded={open}
        aria-label="Reading options"
        title="Reading options"
      >
        <SlidersIcon size={17} />
        <ChevronIcon size={15} className="control-chip__chevron" />
      </button>

      {open && (
        <div className="popover popover--options" role="dialog" aria-label="Reading options">
          <div className="popover__heading">Reading options</div>
          <div className="opt-list">
            <OptionRow
              label="Auto-scroll"
              hint="Keep the current line in view"
              checked={autoScroll}
              onChange={setAutoScroll}
            />
            <OptionRow
              label="Skip content in ( )"
              hint="Don't read parentheticals aloud"
              checked={skipSkippable}
              onChange={(v) => player.setSkipSkippable(v)}
            />
          </div>
        </div>
      )}
    </div>
  )
}
