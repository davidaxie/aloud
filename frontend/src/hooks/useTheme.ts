// ─────────────────────────────────────────────────────────────────────────────
// useTheme — mirrors the store's theme onto <html data-theme="…"> and keeps the
// browser `color-scheme` in sync. The store already resolves the persisted /
// system value on init, so this hook only reflects it to the DOM.
// ─────────────────────────────────────────────────────────────────────────────
import { useEffect } from 'react'
import { useStore } from '../store'
import type { Theme } from '../types'

export function useTheme(): Theme {
  const theme = useStore((s) => s.theme)

  useEffect(() => {
    const root = document.documentElement
    root.setAttribute('data-theme', theme)
    root.style.colorScheme = theme
  }, [theme])

  return theme
}
