// ─────────────────────────────────────────────────────────────────────────────
// Persisted user settings.
//
// One storage key holds every setting but the backend URL, so a write is atomic
// and a read is a single round-trip. chrome.storage.sync is preferred (settings
// follow the user across their Chrome profiles); if sync is unavailable or over
// quota we transparently fall back to chrome.storage.local.
//
// The backend URL is the exception: where the backend listens is a fact about
// this computer, so it has a key of its own in chrome.storage.local and never
// syncs (L040). It only ever names this computer (L043).
//
// Every surface — service worker, content script, popup — reads through here and
// subscribes via `watchPrefs`, so changing the voice in the popup updates a page
// that is mid-sentence without any explicit message passing.
// ─────────────────────────────────────────────────────────────────────────────

import type { Prefs } from './types'

const KEY = 'aloud.prefs.v1'
/**
 * The backend URL, in chrome.storage.local only. A URL synced from another
 * computer points at a port nothing here may listen on, and turns off the
 * fallback-port scan that would have found the backend here (L040).
 */
const BACKEND_KEY = 'aloud.backendUrl.v1'

export const DEFAULT_PREFS: Prefs = {
  voiceId: 'af_heart',
  rate: 1,
  skipSkippable: true,
  autoScroll: true,
  clickToJump: true,
  highlightWords: true,
  // The backend's default port: DEFAULT_PORT in backend/native_app.py, which
  // run.py and native_app.py both serve on unless ALOUD_PORT says otherwise
  // (native_app.py moves to 8001–8010, or any free port, only when 8000 is
  // taken; while this default is set, the worker looks there too, see
  // BACKEND_FALLBACK_PORTS). A backend on another port is set in the popup's
  // Backend field; the manifest's loopback host permissions cover any port.
  // The popup's placeholder shows this value, and a test checks all three agree.
  // 127.0.0.1, where the backend serves, rather than localhost: macOS tries
  // ::1 first, and a server started there later on the same port would take
  // every request.
  backendUrl: 'http://127.0.0.1:8000',
}

/**
 * Where native_app.py moves when something else holds the default port:
 * FALLBACK_PORTS in backend/native_app.py, which a test checks. While
 * backendUrl is still the default, the worker looks for Aloud on these before
 * calling the engine offline (J044).
 */
export const BACKEND_FALLBACK_PORTS: readonly number[] = Array.from({ length: 10 }, (_, k) => 8001 + k)

/** The default before it named 127.0.0.1; saving any setting stored it. */
const OLD_DEFAULT_BACKEND = 'http://localhost:8000'

/**
 * The backend's own limit on a voice id (MAX_VOICE_CHARS): it answers a longer
 * one with a 400 for every sentence, so such an id would stop every reader on
 * every site until the user picked a voice again (H033).
 */
const MAX_VOICE_CHARS = 64

/**
 * Loopback names, as URL.hostname spells them. The worker sends every sentence
 * the user reads to the backend URL, and a content script in a compromised page
 * renderer can write the storage it lives in, so any other host would let one
 * page send the text of every other page somewhere else (L043).
 */
const LOOPBACK_HOSTS: ReadonlySet<string> = new Set(['127.0.0.1', 'localhost', '[::1]'])

/** Whether `url` is an http(s) URL on this computer, with no credentials in it. */
export function onThisComputer(url: string): boolean {
  try {
    const u = new URL(url)
    return (
      (u.protocol === 'http:' || u.protocol === 'https:') &&
      LOOPBACK_HOSTS.has(u.hostname) &&
      !u.username &&
      !u.password
    )
  } catch {
    return false
  }
}

/** A stored backend URL, or the default for anything not on this computer. */
function sanitizeBackend(raw: unknown): string {
  if (typeof raw !== 'string' || !/^https?:\/\//.test(raw)) return DEFAULT_PREFS.backendUrl
  const url = raw.replace(/\/+$/, '')
  return onThisComputer(url) && url !== OLD_DEFAULT_BACKEND ? url : DEFAULT_PREFS.backendUrl
}

/** Clamp/normalize anything we read back, so a corrupt value can't wedge playback. */
function sanitize(raw: unknown): Prefs {
  const p = { ...DEFAULT_PREFS, ...((raw as Partial<Prefs>) ?? {}) }
  return {
    voiceId:
      typeof p.voiceId === 'string' && p.voiceId && p.voiceId.length <= MAX_VOICE_CHARS
        ? p.voiceId
        : DEFAULT_PREFS.voiceId,
    rate: Number.isFinite(p.rate) ? Math.min(3, Math.max(0.5, p.rate)) : DEFAULT_PREFS.rate,
    skipSkippable: !!p.skipSkippable,
    autoScroll: !!p.autoScroll,
    clickToJump: !!p.clickToJump,
    highlightWords: !!p.highlightWords,
    backendUrl: sanitizeBackend(p.backendUrl),
  }
}

/** The synced settings, as stored: sync first, then local, then nothing. */
async function loadShared(): Promise<Partial<Prefs> | undefined> {
  try {
    const got = await chrome.storage.sync.get(KEY)
    if (got && got[KEY] !== undefined) return got[KEY] as Partial<Prefs>
  } catch {
    /* sync disabled — fall through to local */
  }
  try {
    return (await chrome.storage.local.get(KEY))?.[KEY] as Partial<Prefs> | undefined
  } catch {
    return undefined
  }
}

/** Write the synced settings, falling back to local storage. */
async function saveShared(shared: Omit<Prefs, 'backendUrl'>): Promise<void> {
  try {
    await chrome.storage.sync.set({ [KEY]: shared })
  } catch {
    // Quota or sync-disabled: local still gives us persistence on this machine.
    try {
      await chrome.storage.local.set({ [KEY]: shared })
    } catch {
      /* storage unavailable — settings stay in memory for this session */
    }
  }
}

/**
 * This computer's backend URL. The first read after the split moves a URL
 * saved with the synced settings here, once, and drops it from them (L040).
 */
async function loadBackend(shared: Partial<Prefs> | undefined): Promise<string> {
  let stored: unknown
  try {
    stored = (await chrome.storage.local.get(BACKEND_KEY))?.[BACKEND_KEY]
  } catch {
    return DEFAULT_PREFS.backendUrl
  }
  if (stored !== undefined) return sanitizeBackend(stored)
  const moved = sanitizeBackend(shared?.backendUrl)
  try {
    await chrome.storage.local.set({ [BACKEND_KEY]: moved })
    if (shared && 'backendUrl' in shared) {
      const { backendUrl: _synced, ...rest } = sanitize(shared)
      await saveShared(rest)
    }
  } catch {
    /* storage unavailable — read it from the synced settings again next time */
  }
  return moved
}

/** Read prefs, falling back to local storage and finally to the defaults. */
export async function loadPrefs(): Promise<Prefs> {
  const shared = await loadShared()
  return { ...sanitize(shared), backendUrl: await loadBackend(shared) }
}

/** Merge `patch` into the stored prefs. Returns the resulting full Prefs. */
export async function savePrefs(patch: Partial<Prefs>): Promise<Prefs> {
  const next = sanitize({ ...(await loadPrefs()), ...patch })
  const { backendUrl, ...shared } = next
  if ('backendUrl' in patch) {
    try {
      await chrome.storage.local.set({ [BACKEND_KEY]: backendUrl })
    } catch {
      /* storage unavailable — the URL stays in memory for this session */
    }
  }
  if (Object.keys(patch).some((k) => k !== 'backendUrl')) await saveShared(shared)
  return next
}

/**
 * Call `cb` whenever prefs change in ANY surface (including this one). Returns an
 * unsubscribe function. Both storage areas are watched because `savePrefs` may
 * have fallen back to local, and the backend URL lives in local anyway; the
 * prefs are read back whole, since a change holds only one of the two keys.
 */
export function watchPrefs(cb: (prefs: Prefs) => void): () => void {
  const listener = (
    changes: { [k: string]: chrome.storage.StorageChange },
    _area: string,
  ) => {
    if (!(KEY in changes) && !(BACKEND_KEY in changes)) return
    void loadPrefs().then(cb)
  }
  chrome.storage.onChanged.addListener(listener)
  return () => chrome.storage.onChanged.removeListener(listener)
}
