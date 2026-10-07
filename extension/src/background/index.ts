// ─────────────────────────────────────────────────────────────────────────────
// Service worker — the extension's privileged core.
//
// Two jobs:
//
//  1. TTS proxy. It is the only place that talks to the local Kokoro server.
//     Requests originate from the chrome-extension:// origin, which holds host
//     permissions for localhost, so they sidestep both CORS and Chrome's
//     Private Network Access block on public-page → localhost fetches. WAV bytes
//     come back to the content script base64-encoded (chrome messaging is JSON).
//     In-flight requests are abortable by id so a seek doesn't waste synthesis.
//
//  2. Activation. The content script is injected ON DEMAND (activeTab), never
//     declared for <all_urls> — so installing Aloud does not ask for permission
//     to read every site you visit. The user's action click, keyboard command,
//     or context-menu click is the gesture that grants access to that one tab.
//
// MV3 workers are killed when idle, so everything here is stateless apart from
// `inflight`, which only ever holds requests that are, by definition, keeping
// the worker alive.
// ─────────────────────────────────────────────────────────────────────────────

import { loadPrefs } from '../shared/prefs'
import {
  bytesToBase64,
  type BgRequest,
  type BgResponse,
  type HealthReport,
  type SynthFailure,
  type SynthPriority,
  type TabAction,
  type TabRequest,
} from '../shared/protocol'
import type { EngineState, Voice } from '../shared/types'

// ── context menus ───────────────────────────────────────────────────────────

const MENU_PAGE = 'aloud-read-page'
const MENU_SELECTION = 'aloud-read-selection'

chrome.runtime.onInstalled.addListener(() => {
  // removeAll first so a reload of the unpacked extension can't duplicate items.
  chrome.contextMenus.removeAll(() => {
    chrome.contextMenus.create({
      id: MENU_SELECTION,
      title: 'Read selection aloud',
      contexts: ['selection'],
    })
    chrome.contextMenus.create({
      id: MENU_PAGE,
      title: 'Read this page aloud',
      contexts: ['page'],
    })
  })
})

/**
 * Fire-and-forget dispatch for the surfaces that have nowhere to show an error.
 *
 * A context-menu click or an Alt+A on a chrome:// page rejects, and there is no
 * UI reachable from here to say so — a content script is precisely what such a
 * page will not run. Swallowing it into the worker log is the honest limit; what
 * matters is that it stops being an unhandled rejection that kills the worker
 * mid-synthesis. The popup path reports the same failure properly.
 */
function dispatchQuietly(tabId: number, action: TabAction, text?: string): void {
  void dispatch(tabId, action, text).catch((err: unknown) => {
    console.warn('[Aloud]', errorMessage(err))
  })
}

chrome.contextMenus.onClicked.addListener((info, tab) => {
  if (tab?.id === undefined) return
  const action: TabAction = info.menuItemId === MENU_SELECTION ? 'start-selection' : 'start'
  // A selection inside a subframe (an embed, Chrome's PDF viewer) is invisible
  // to the top frame's script, whose own selection is empty or stale, and
  // activeTab can't reach a cross-origin frame. So the reader, which always
  // lives in the top frame, reads the text Chrome reports instead.
  const text = action === 'start-selection' && info.frameId ? info.selectionText : undefined
  dispatchQuietly(tab.id, action, text)
})

// ── keyboard commands ───────────────────────────────────────────────────────

chrome.commands.onCommand.addListener((command) => {
  const action: TabAction =
    command === 'next-sentence' ? 'next' : command === 'prev-sentence' ? 'prev' : 'toggle'
  void chrome.tabs.query({ active: true, currentWindow: true }).then(async ([tab]) => {
    if (tab?.id === undefined) return
    const text = action === 'toggle' ? await subframeSelection(tab.id) : undefined
    dispatchQuietly(tab.id, action, text)
  })
})

/**
 * Text selected in the focused subframe, for the shortcut to read (G034).
 *
 * The context menu is told what was selected; a keyboard command is not, and
 * the reader in the top frame sees only its own selection — empty, or stale
 * from before the user clicked into the frame. So ask every frame activeTab
 * lets us into. Chrome's PDF viewer and cross-origin embeds are not among
 * them: there the PDF toast points to the context menu instead. Undefined
 * means "let the top frame decide", which is also the answer on any failure.
 */
async function subframeSelection(tabId: number): Promise<string | undefined> {
  try {
    const results = await chrome.scripting.executeScript({
      target: { tabId, allFrames: true },
      func: () => ({ text: getSelection()?.toString() ?? '', focused: document.hasFocus() }),
    })
    for (const { frameId, result } of results) {
      // The top frame reports focus whenever a frame inside it has it, so only a
      // subframe's focus says where the user selected last.
      if (frameId === 0 || !result?.focused) continue
      const text = result.text.trim()
      if (text) return text
    }
  } catch {
    // A page no script may enter: dispatch reports it.
  }
  return undefined
}

// ── injection + dispatch ────────────────────────────────────────────────────

/** Pages where content scripts can never run — worth a clear error, not a crash. */
function isRestricted(url: string | undefined): boolean {
  if (!url) return true
  return (
    url.startsWith('chrome://') ||
    url.startsWith('chrome-extension://') ||
    url.startsWith('edge://') ||
    url.startsWith('about:') ||
    url.startsWith('devtools://') ||
    url.startsWith('view-source:') ||
    url.startsWith('https://chromewebstore.google.com') ||
    url.startsWith('https://chrome.google.com/webstore')
  )
}

/**
 * Make sure the content script is live in `tabId`, then send it `action`.
 *
 * The ping-then-inject dance keeps injection idempotent: a second Alt+A must
 * reach the EXISTING reader (so it pauses) rather than spawn a second one.
 */
async function dispatch(tabId: number, action: TabAction, text?: string): Promise<void> {
  const tab = await chrome.tabs.get(tabId).catch(() => undefined)
  if (isRestricted(tab?.url)) throw new Error("Aloud can't read this page.")

  let alive = false
  try {
    const pong = await chrome.tabs.sendMessage<TabRequest, unknown>(tabId, { kind: 'ping' })
    alive = !!pong
  } catch {
    alive = false // no receiver yet
  }

  if (!alive) {
    await chrome.scripting.executeScript({ target: { tabId }, files: ['content.js'] })
  }

  await chrome.tabs.sendMessage<TabRequest, unknown>(tabId, { kind: 'command', action, text })
}

/**
 * The bindings Chrome actually gave our commands. Never assume the manifest's
 * suggestions: Chrome drops one that clashes with its own shortcuts, and the
 * user can rebind any of them at chrome://extensions/shortcuts.
 */
async function shortcuts(): Promise<{ toggle: string; next: string; prev: string }> {
  const bound = new Map((await chrome.commands.getAll()).map((c) => [c.name, c.shortcut ?? '']))
  return {
    toggle: bound.get('toggle-read') ?? '',
    next: bound.get('next-sentence') ?? '',
    prev: bound.get('prev-sentence') ?? '',
  }
}

// ── backend calls ───────────────────────────────────────────────────────────

/**
 * In-flight synth requests, so an abort can cancel one.
 *
 * The key is scoped to the SENDER, not just the request id: each content script
 * numbers its requests from 1, so two tabs reading at once both have a request
 * "3" — and an unscoped map would let a seek in one tab abort the other tab's
 * audio. Frame id is in the key too, for a page reading inside an iframe.
 */
const inflight = new Map<string, AbortController>()

/** Stable identity for a caller's request. The popup has no tab; that's fine. */
function requestKey(sender: chrome.runtime.MessageSender, id: number): string {
  return `${sender.tab?.id ?? 'popup'}:${sender.frameId ?? 0}:${id}`
}

async function backendBase(): Promise<string> {
  return (await loadPrefs()).backendUrl
}

/**
 * `/health` and `/voices` are probes, not work — they should answer in
 * milliseconds. Bounding them means a wedged backend reads as offline instead of
 * hanging the popup's spinner and the reader's poll loop forever.
 */
const PROBE_TIMEOUT_MS = 5_000

async function probe(url: string): Promise<Response> {
  const controller = new AbortController()
  const timer = setTimeout(() => controller.abort(), PROBE_TIMEOUT_MS)
  try {
    return await fetch(url, { signal: controller.signal })
  } finally {
    clearTimeout(timer)
  }
}

const OFFLINE: HealthReport = { state: 'offline', voiceCount: 0, warm: false, queueDepth: 0 }

/**
 * Ask the backend how it is (contract §1.2) and normalize the answer.
 *
 * The distinction that matters is `warming` vs `offline`: a backend that is
 * loading its model answers `{"status":"warming"}` and will be fine in a few
 * seconds, so clients must not tell the user to go start a server that is
 * already running. Older backends only ever say `"ok"`, and have no `warm` or
 * `queue_depth`; we degrade to sensible values rather than reading them as a
 * fault.
 */
async function health(): Promise<HealthReport> {
  try {
    const res = await probe(`${await backendBase()}/health`)
    if (!res.ok) return OFFLINE
    const d = (await res.json()) as {
      status?: string
      model_loaded?: boolean
      voice_count?: number
      warm?: boolean
      queue_depth?: number
    }

    const loaded = d.model_loaded !== false // absent = assume loaded (old shape)
    const state: EngineState =
      d.status === 'warming' ? 'warming' : d.status === 'ok' && loaded ? 'ok' : 'offline'

    return {
      state,
      voiceCount: typeof d.voice_count === 'number' ? d.voice_count : 0,
      warm: typeof d.warm === 'boolean' ? d.warm : state === 'ok',
      queueDepth: typeof d.queue_depth === 'number' ? d.queue_depth : 0,
    }
  } catch {
    // Backend down / wrong port / offline — report it rather than throwing, so
    // callers can poll this on a timer without try/catch.
    return OFFLINE
  }
}

async function voices(): Promise<{ voices: Voice[]; default: string }> {
  try {
    const res = await probe(`${await backendBase()}/voices`)
    if (!res.ok) return { voices: [], default: 'af_heart' }
    const d = (await res.json()) as { voices?: Voice[]; default?: string }
    return {
      voices: Array.isArray(d.voices) ? d.voices : [],
      default: typeof d.default === 'string' ? d.default : 'af_heart',
    }
  } catch {
    return { voices: [], default: 'af_heart' }
  }
}

/**
 * A backend failure carrying everything the content script's retry policy needs.
 * The worker classifies; the player decides. Keeping the classification here
 * means one place knows what an HTTP status means.
 */
class BackendError extends Error {
  constructor(
    message: string,
    readonly status: number,
    readonly retryable: boolean,
    readonly retryAfterMs: number | null,
  ) {
    super(message)
    this.name = 'BackendError'
  }
}

/**
 * Is this status worth another attempt? (§1.1)
 *
 * `429` is the bounded prefetch queue saying "later", `503` is a model that
 * isn't loaded yet, and `500` is the phonemizer race that this whole release
 * exists to survive — all three pass. A `400` is a bad sentence: the same bytes
 * will fail the same way forever, so it is skipped, not retried.
 */
function statusRetryable(status: number): boolean {
  if (status === 429 || status === 503) return true
  if (status === 400) return false
  return status >= 500
}

/** `Retry-After: 2` (seconds) or an HTTP-date → ms. Null when absent/unparseable. */
function retryAfterMs(header: string | null): number | null {
  if (!header) return null
  const seconds = Number(header.trim())
  if (Number.isFinite(seconds) && seconds >= 0) return Math.min(60_000, seconds * 1000)
  const date = Date.parse(header)
  if (Number.isFinite(date)) return Math.min(60_000, Math.max(0, date - Date.now()))
  return null
}

/** POST /synthesize → base64 WAV. Rejects with a classified BackendError. */
async function synthesize(
  req: {
    text: string
    voice: string
    speed: number
    priority: SynthPriority
  },
  key: string,
): Promise<string> {
  const controller = new AbortController()
  inflight.set(key, controller)
  try {
    let res: Response
    try {
      res = await fetch(`${await backendBase()}/synthesize`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          text: req.text,
          voice: req.voice,
          speed: req.speed,
          // Unknown fields are ignored by older backends, so sending this is
          // safe even before A1 lands.
          priority: req.priority ?? 'now',
        }),
        signal: controller.signal,
      })
    } catch (err) {
      if (err instanceof Error && err.name === 'AbortError') throw err
      // Transport failure: the server is down, the port moved, the socket died.
      // Retryable — the next attempt may well find it back.
      throw new BackendError('Speech engine unreachable.', 0, true, null)
    }

    if (!res.ok) {
      // The backend reports its own failures as {"error": …, "retryable": …}.
      const body = (await res.json().catch(() => undefined)) as
        | { error?: string; retryable?: boolean }
        | undefined
      throw new BackendError(
        body?.error ?? `synthesis failed: HTTP ${res.status}`,
        res.status,
        // The body's own verdict wins when present; status is the fallback.
        typeof body?.retryable === 'boolean' ? body.retryable : statusRetryable(res.status),
        retryAfterMs(res.headers.get('Retry-After')),
      )
    }
    const buf = await res.arrayBuffer()
    return bytesToBase64(new Uint8Array(buf))
  } finally {
    inflight.delete(key)
  }
}

/** Turn any thrown value into the wire-level failure the content script reads. */
function toFailure(err: unknown): SynthFailure {
  const aborted = err instanceof Error && err.name === 'AbortError'
  if (aborted) {
    return { error: 'aborted', aborted: true, retryable: false, status: 0, retryAfterMs: null }
  }
  if (err instanceof BackendError) {
    return {
      error: err.message,
      aborted: false,
      retryable: err.retryable,
      status: err.status,
      retryAfterMs: err.retryAfterMs,
    }
  }
  // A bug in the worker, not a backend condition — retrying would just repeat it.
  return { error: errorMessage(err), aborted: false, retryable: false, status: 0, retryAfterMs: null }
}

// ── message router ──────────────────────────────────────────────────────────

chrome.runtime.onMessage.addListener(
  (msg: BgRequest, sender, sendResponse: (r: BgResponse) => void) => {
    switch (msg.kind) {
      case 'health':
        void health().then((h) => sendResponse({ kind: 'health', ...h }))
        return true // async response

      case 'voices':
        void voices().then((v) => sendResponse({ kind: 'voices', ...v }))
        return true

      case 'synth': {
        const key = requestKey(sender, msg.id)
        void synthesize(msg, key).then(
          (audio) => sendResponse({ kind: 'synth', ok: true, audio }),
          (err: unknown) => sendResponse({ kind: 'synth', ok: false, ...toFailure(err) }),
        )
        return true
      }

      case 'abort': {
        const key = requestKey(sender, msg.id)
        inflight.get(key)?.abort()
        inflight.delete(key)
        return false // nothing to report back
      }

      case 'shortcuts':
        void shortcuts().then(
          (keys) => sendResponse({ kind: 'shortcuts', ...keys }),
          () => sendResponse({ kind: 'shortcuts', toggle: '', next: '', prev: '' }),
        )
        return true

      case 'activate':
        void dispatch(msg.tabId, msg.action).then(
          () => sendResponse({ kind: 'activate', ok: true }),
          (err: unknown) =>
            sendResponse({ kind: 'activate', ok: false, error: errorMessage(err) }),
        )
        return true

      default:
        return false
    }
  },
)

function errorMessage(err: unknown): string {
  if (err instanceof Error) return err.message
  return String(err)
}
