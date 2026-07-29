// ─────────────────────────────────────────────────────────────────────────────
// VoicePicker — compact popover for choosing among ~54 voices. Searchable and
// grouped by language so it stays scannable. Selecting a voice drives the player
// and persists via the store.
// ─────────────────────────────────────────────────────────────────────────────
import { useEffect, useMemo, useRef, useState } from 'react'
import { player } from '../lib/player'
import { useStore } from '../store'
import type { Voice } from '../types'
import { CheckIcon, ChevronIcon, SearchIcon, VoiceIcon } from './Icons'

const REGION: Record<string, string> = {
  'en-us': 'US',
  'en-gb': 'UK',
  en: 'EN',
  'es-es': 'ES',
  es: 'ES',
  'fr-fr': 'FR',
  fr: 'FR',
  'it-it': 'IT',
  it: 'IT',
  'pt-br': 'BR',
  pt: 'PT',
  hi: 'HI',
  ja: 'JA',
  'ja-jp': 'JA',
  zh: 'ZH',
  'zh-cn': 'ZH',
  ko: 'KO',
}

const LANG_NAME: Record<string, string> = {
  'en-us': 'English · US',
  'en-gb': 'English · UK',
  en: 'English',
  es: 'Spanish',
  'es-es': 'Spanish',
  fr: 'French',
  'fr-fr': 'French',
  it: 'Italian',
  'it-it': 'Italian',
  'pt-br': 'Portuguese · Brazil',
  pt: 'Portuguese',
  hi: 'Hindi',
  ja: 'Japanese',
  'ja-jp': 'Japanese',
  zh: 'Chinese',
  'zh-cn': 'Chinese',
  ko: 'Korean',
}

function region(lang: string): string {
  const k = lang.toLowerCase()
  if (REGION[k]) return REGION[k]
  const parts = k.split('-')
  return (parts[1] ?? parts[0] ?? '').toUpperCase()
}

function langName(lang: string): string {
  const k = lang.toLowerCase()
  return LANG_NAME[k] ?? k.toUpperCase()
}

function voiceSublabel(v: Voice): string {
  return `${region(v.lang)} · ${v.gender}`
}

export function VoicePicker() {
  const voices = useStore((s) => s.voices)
  const voiceId = useStore((s) => s.voiceId)

  const [open, setOpen] = useState(false)
  const [query, setQuery] = useState('')
  const wrapRef = useRef<HTMLDivElement>(null)
  const searchRef = useRef<HTMLInputElement>(null)

  const selected = useMemo(
    () => voices.find((v) => v.id === voiceId) ?? null,
    [voices, voiceId],
  )

  // Group filtered voices by language.
  const groups = useMemo(() => {
    const q = query.trim().toLowerCase()
    const filtered = voices.filter((v) => {
      if (!q) return true
      return (
        v.name.toLowerCase().includes(q) ||
        v.lang.toLowerCase().includes(q) ||
        v.gender.toLowerCase().includes(q) ||
        region(v.lang).toLowerCase().includes(q) ||
        langName(v.lang).toLowerCase().includes(q)
      )
    })
    const map = new Map<string, Voice[]>()
    for (const v of filtered) {
      const key = v.lang.toLowerCase()
      const arr = map.get(key)
      if (arr) arr.push(v)
      else map.set(key, [v])
    }
    return [...map.entries()]
      .map(([lang, list]) => ({
        lang,
        name: langName(lang),
        voices: list.sort(
          (a, b) => a.gender.localeCompare(b.gender) || a.name.localeCompare(b.name),
        ),
      }))
      .sort((a, b) => a.name.localeCompare(b.name))
  }, [voices, query])

  // Close on outside click / Escape; focus search on open.
  useEffect(() => {
    if (!open) return
    const onDown = (e: MouseEvent) => {
      if (!wrapRef.current?.contains(e.target as Node)) setOpen(false)
    }
    const onKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape') setOpen(false)
    }
    document.addEventListener('mousedown', onDown)
    document.addEventListener('keydown', onKey)
    const t = window.setTimeout(() => searchRef.current?.focus(), 0)
    return () => {
      document.removeEventListener('mousedown', onDown)
      document.removeEventListener('keydown', onKey)
      window.clearTimeout(t)
    }
  }, [open])

  function choose(id: string) {
    player.setVoice(id)
    setOpen(false)
    setQuery('')
  }

  const disabled = voices.length === 0

  return (
    <div className="voice-picker" ref={wrapRef}>
      <button
        type="button"
        className="control-chip"
        onClick={() => !disabled && setOpen((o) => !o)}
        disabled={disabled}
        aria-haspopup="listbox"
        aria-expanded={open}
        title="Choose a voice"
      >
        <VoiceIcon size={17} />
        <span className="control-chip__label">
          {selected ? selected.name : disabled ? 'No voices' : 'Voice'}
        </span>
        {selected && (
          <span className="control-chip__sub">{voiceSublabel(selected)}</span>
        )}
        <ChevronIcon size={15} className="control-chip__chevron" />
      </button>

      {open && (
        <div className="popover popover--voices" role="dialog" aria-label="Voices">
          <div className="popover__search">
            <SearchIcon size={16} />
            <input
              ref={searchRef}
              type="text"
              value={query}
              onChange={(e) => setQuery(e.target.value)}
              placeholder="Search voices…"
              className="popover__search-input"
              aria-label="Search voices"
            />
          </div>

          <div className="popover__list" role="listbox" aria-label="Available voices">
            {groups.length === 0 && (
              <div className="popover__empty">No voices match “{query}”.</div>
            )}
            {groups.map((g) => (
              <div className="voice-group" key={g.lang}>
                <div className="voice-group__label">{g.name}</div>
                {g.voices.map((v) => {
                  const active = v.id === voiceId
                  return (
                    <button
                      type="button"
                      key={v.id}
                      role="option"
                      aria-selected={active}
                      className={`voice-item${active ? ' is-active' : ''}`}
                      onClick={() => choose(v.id)}
                    >
                      <span className="voice-item__name">{v.name}</span>
                      <span className="voice-item__meta">{voiceSublabel(v)}</span>
                      {active && (
                        <span className="voice-item__check" aria-hidden>
                          <CheckIcon size={16} />
                        </span>
                      )}
                    </button>
                  )
                })}
              </div>
            ))}
          </div>
        </div>
      )}
    </div>
  )
}
