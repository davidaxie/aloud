// ─────────────────────────────────────────────────────────────────────────────
// Voice presentation helpers, shared by the in-page bar and the popup so both
// pickers group and label voices identically.
// ─────────────────────────────────────────────────────────────────────────────

import type { Voice } from './types'

/** Kokoro language tag → the group label shown in a picker. */
export const LANG_LABELS: Record<string, string> = {
  'en-us': 'English (US)',
  'en-gb': 'English (UK)',
  es: 'Spanish',
  'fr-fr': 'French',
  hi: 'Hindi',
  it: 'Italian',
  ja: 'Japanese',
  'pt-br': 'Portuguese (BR)',
  zh: 'Chinese',
}

/** Group voices by language, preserving the backend's ordering within a group. */
export function groupByLang(voices: Voice[]): Array<[label: string, voices: Voice[]]> {
  const byLang = new Map<string, Voice[]>()
  for (const v of voices) {
    const list = byLang.get(v.lang) ?? []
    list.push(v)
    byLang.set(v.lang, list)
  }
  return [...byLang].map(([lang, list]) => [LANG_LABELS[lang] ?? lang, list])
}

/** Fill a <select> with grouped voice options. Returns true if anything was added. */
export function fillVoiceSelect(select: HTMLSelectElement, voices: Voice[]): boolean {
  select.textContent = ''
  for (const [label, list] of groupByLang(voices)) {
    const group = document.createElement('optgroup')
    group.label = label
    for (const v of list) {
      const opt = document.createElement('option')
      opt.value = v.id
      opt.textContent = v.name
      group.append(opt)
    }
    select.append(group)
  }
  return voices.length > 0
}
