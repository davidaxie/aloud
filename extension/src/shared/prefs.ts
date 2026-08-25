// ─────────────────────────────────────────────────────────────────────────────
// Persisted user settings.
//
// One storage key holds the whole Prefs object, so a write is atomic and a read
// is a single round-trip. chrome.storage.sync is preferred (settings follow the
// user across their Chrome profiles); if sync is unavailable or over quota we
// transparently fall back to chrome.storage.local.
//
// Every surface — service worker, content script, popup — reads through here and
// subscribes via `watchPrefs`, so changing the voice in the popup updates a page
// that is mid-sentence without any explicit message passing.
// ─────────────────────────────────────────────────────────────────────────────

import type { Prefs } from './types'

const KEY = 'aloud.prefs.v1'

export const DEFAULT_PREFS: Prefs = {
  voiceId: 'af_heart',
  rate: 1,
  skipSkippable: true,
  autoScroll: true,
  clickToJump: true,
  highlightWords: true,
  backendUrl: 'http://localhost:8000',
}

/** Clamp/normalize anything we read back, so a corrupt value can't wedge playback. */
function sanitize(raw: unknown): Prefs {
  const p = { ...DEFAULT_PREFS, ...((raw as Partial<Prefs>) ?? {}) }
  return {
    voiceId: typeof p.voiceId === 'string' && p.voiceId ? p.voiceId : DEFAULT_PREFS.voiceId,
    rate: Number.isFinite(p.rate) ? Math.min(3, Math.max(0.5, p.rate)) : DEFAULT_PREFS.rate,
    skipSkippable: !!p.skipSkippable,
    autoScroll: !!p.autoScroll,
    clickToJump: !!p.clickToJump,
    highlightWords: !!p.highlightWords,
    backendUrl:
      typeof p.backendUrl === 'string' && /^https?:\/\//.test(p.backendUrl)
        ? p.backendUrl.replace(/\/+$/, '')
        : DEFAULT_PREFS.backendUrl,
  }
}

/** Read prefs, falling back to local storage and finally to the defaults. */
export async function loadPrefs(): Promise<Prefs> {
  try {
    const got = await chrome.storage.sync.get(KEY)
    if (got && got[KEY] !== undefined) return sanitize(got[KEY])
  } catch {
    /* sync disabled — fall through to local */
  }
  try {
    const got = await chrome.storage.local.get(KEY)
    return sanitize(got?.[KEY])
  } catch {
    return { ...DEFAULT_PREFS }
  }
}

/** Merge `patch` into the stored prefs. Returns the resulting full Prefs. */
export async function savePrefs(patch: Partial<Prefs>): Promise<Prefs> {
  const next = sanitize({ ...(await loadPrefs()), ...patch })
  try {
    await chrome.storage.sync.set({ [KEY]: next })
  } catch {
    // Quota or sync-disabled: local still gives us persistence on this machine.
    try {
      await chrome.storage.local.set({ [KEY]: next })
    } catch {
      /* storage unavailable — settings stay in memory for this session */
    }
  }
  return next
}

/**
 * Call `cb` whenever prefs change in ANY surface (including this one). Returns an
 * unsubscribe function. Both storage areas are watched because `savePrefs` may
 * have fallen back to local.
 */
export function watchPrefs(cb: (prefs: Prefs) => void): () => void {
  const listener = (
    changes: { [k: string]: chrome.storage.StorageChange },
    _area: string,
  ) => {
    if (!(KEY in changes)) return
    cb(sanitize(changes[KEY].newValue))
  }
  chrome.storage.onChanged.addListener(listener)
  return () => chrome.storage.onChanged.removeListener(listener)
}
