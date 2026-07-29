// ─────────────────────────────────────────────────────────────────────────────
// Inline SVG icon set. No network, no icon packages. All icons use `currentColor`
// so color is controlled entirely by CSS. Stroke icons share a calm 1.75 weight.
// ─────────────────────────────────────────────────────────────────────────────
import type { SVGProps } from 'react'

type IconProps = SVGProps<SVGSVGElement> & { size?: number }

function base({ size = 20, ...props }: IconProps): SVGProps<SVGSVGElement> {
  return {
    width: size,
    height: size,
    viewBox: '0 0 24 24',
    fill: 'none',
    stroke: 'currentColor',
    strokeWidth: 1.75,
    strokeLinecap: 'round',
    strokeLinejoin: 'round',
    'aria-hidden': true,
    focusable: false,
    ...props,
  }
}

export function PlayIcon({ size = 20, ...p }: IconProps) {
  // Solid triangle reads better at the large transport size.
  return (
    <svg {...base({ size, ...p })} fill="currentColor" stroke="none">
      <path d="M8 5.14v13.72a1 1 0 0 0 1.53.85l10.79-6.86a1 1 0 0 0 0-1.7L9.53 4.29A1 1 0 0 0 8 5.14Z" />
    </svg>
  )
}

export function PauseIcon({ size = 20, ...p }: IconProps) {
  return (
    <svg {...base({ size, ...p })} fill="currentColor" stroke="none">
      <rect x="6" y="5" width="4" height="14" rx="1.3" />
      <rect x="14" y="5" width="4" height="14" rx="1.3" />
    </svg>
  )
}

export function PrevIcon({ size = 20, ...p }: IconProps) {
  return (
    <svg {...base({ size, ...p })} fill="currentColor" stroke="none">
      <rect x="5" y="5" width="2.4" height="14" rx="1" />
      <path d="M20 6.2v11.6a1 1 0 0 1-1.53.85L9 12.85a1 1 0 0 1 0-1.7l9.47-5.8A1 1 0 0 1 20 6.2Z" />
    </svg>
  )
}

export function NextIcon({ size = 20, ...p }: IconProps) {
  return (
    <svg {...base({ size, ...p })} fill="currentColor" stroke="none">
      <rect x="16.6" y="5" width="2.4" height="14" rx="1" />
      <path d="M4 6.2v11.6a1 1 0 0 0 1.53.85L15 12.85a1 1 0 0 0 0-1.7L5.53 5.35A1 1 0 0 0 4 6.2Z" />
    </svg>
  )
}

export function SunIcon(p: IconProps) {
  return (
    <svg {...base(p)}>
      <circle cx="12" cy="12" r="4" />
      <path d="M12 2v2.5M12 19.5V22M4.22 4.22l1.77 1.77M18.01 18.01l1.77 1.77M2 12h2.5M19.5 12H22M4.22 19.78l1.77-1.77M18.01 5.99l1.77-1.77" />
    </svg>
  )
}

export function MoonIcon(p: IconProps) {
  return (
    <svg {...base(p)}>
      <path d="M20 14.5A8 8 0 1 1 9.5 4a6.5 6.5 0 0 0 10.5 10.5Z" />
    </svg>
  )
}

export function SpinnerIcon({ size = 20, ...p }: IconProps) {
  return (
    <svg {...base({ size, ...p })} className={`spinner ${p.className ?? ''}`.trim()}>
      <path d="M12 3a9 9 0 1 0 9 9" opacity="0.9" />
    </svg>
  )
}

export function FileIcon({ size = 20, ...p }: IconProps) {
  return (
    <svg {...base({ size, ...p })}>
      <path d="M14 3H7a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2V8Z" />
      <path d="M14 3v5h5" />
    </svg>
  )
}

export function UploadIcon({ size = 22, ...p }: IconProps) {
  return (
    <svg {...base({ size, ...p })}>
      <path d="M12 15V4" />
      <path d="m8 8 4-4 4 4" />
      <path d="M5 15v3a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2v-3" />
    </svg>
  )
}

export function SearchIcon({ size = 18, ...p }: IconProps) {
  return (
    <svg {...base({ size, ...p })}>
      <circle cx="11" cy="11" r="7" />
      <path d="m20 20-3.2-3.2" />
    </svg>
  )
}

export function CheckIcon({ size = 18, ...p }: IconProps) {
  return (
    <svg {...base({ size, ...p })}>
      <path d="m5 12.5 4.5 4.5L19 6.5" />
    </svg>
  )
}

export function CloseIcon({ size = 18, ...p }: IconProps) {
  return (
    <svg {...base({ size, ...p })}>
      <path d="M6 6l12 12M18 6 6 18" />
    </svg>
  )
}

export function ChevronIcon({ size = 18, ...p }: IconProps) {
  return (
    <svg {...base({ size, ...p })}>
      <path d="m6 9 6 6 6-6" />
    </svg>
  )
}

export function SpeedIcon({ size = 18, ...p }: IconProps) {
  return (
    <svg {...base({ size, ...p })}>
      <path d="M4 15a8 8 0 0 1 16 0" />
      <path d="M12 15 15 9" />
      <circle cx="12" cy="15" r="1.1" fill="currentColor" stroke="none" />
    </svg>
  )
}

export function VoiceIcon({ size = 18, ...p }: IconProps) {
  return (
    <svg {...base({ size, ...p })}>
      <path d="M12 3a3 3 0 0 0-3 3v6a3 3 0 0 0 6 0V6a3 3 0 0 0-3-3Z" />
      <path d="M5 11a7 7 0 0 0 14 0M12 18v3" />
    </svg>
  )
}

export function WaveIcon({ size = 20, ...p }: IconProps) {
  // Small brand mark — a calm equalizer wave.
  return (
    <svg {...base({ size, ...p })}>
      <path d="M4 10.5v3M8 7.5v9M12 4.5v15M16 8.5v7M20 11v2" />
    </svg>
  )
}
