// ─────────────────────────────────────────────────────────────────────────────
// Popup — engine status, one big button, and the settings that matter.
//
// It holds no reader state of its own: the active tab is asked for a snapshot,
// and every setting is written straight to shared prefs, which the content
// script is already watching. Change the voice here mid-sentence and the page
// re-synthesizes on the spot.
// ─────────────────────────────────────────────────────────────────────────────

import { loadPrefs, savePrefs } from '../shared/prefs'
import type { BgRequest, BgResponse, TabRequest, TabResponse } from '../shared/protocol'
import type { Prefs } from '../shared/types'
import { fillVoiceSelect } from '../shared/voices'

const $ = <T extends HTMLElement>(id: string): T => document.getElementById(id) as T

const els = {
  statusDot: $<HTMLSpanElement>('status-dot'),
  statusText: $<HTMLSpanElement>('status-text'),
  primary: $<HTMLButtonElement>('primary'),
  hint: $<HTMLParagraphElement>('hint'),
  voice: $<HTMLSelectElement>('voice'),
  rate: $<HTMLInputElement>('rate'),
  rateValue: $<HTMLOutputElement>('rate-value'),
  backend: $<HTMLInputElement>('backend'),
}

/** The four boolean settings, wired identically. */
const TOGGLES = ['autoScroll', 'highlightWords', 'clickToJump', 'skipSkippable'] as const
type ToggleKey = (typeof TOGGLES)[number]

let prefs: Prefs
let tabId: number | undefined
/** True when the content script reports a reader is up in this tab. */
let readerActive = false
/** Pending re-check while the engine reports `warming`. */
let warmingRecheck = 0

function send(msg: BgRequest): Promise<BgResponse> {
  return chrome.runtime.sendMessage(msg) as Promise<BgResponse>
}

// ── status ──────────────────────────────────────────────────────────────────

/**
 * Ask the engine how it is and say so honestly (§1.2, A4.6).
 *
 * `warming` is the case worth the extra branch: the backend is up, its model is
 * loading, and it will be answering in a few seconds. Telling that user to go
 * start a server they already started is the specific failure F1.7 names. So it
 * gets its own dot, its own copy, and — because it resolves on its own — a
 * re-check rather than an instruction.
 */
async function refreshEngine() {
  const res = await send({ kind: 'health' }).catch(() => null)
  const state = res?.kind === 'health' ? res.state : 'offline'
  const voiceCount = res?.kind === 'health' ? res.voiceCount : 0
  const ok = state === 'ok'

  els.statusDot.classList.toggle('is-ok', ok)
  els.statusDot.classList.toggle('is-warming', state === 'warming')
  els.statusDot.classList.toggle('is-off', state === 'offline')
  els.statusText.textContent = ok
    ? `${voiceCount} voices`
    : state === 'warming'
      ? 'Warming up…'
      : 'Engine offline'

  if (state === 'offline') {
    setHint('The local speech engine isn’t responding. Start the Aloud backend, then try again.', true)
  } else if (state === 'warming') {
    setHint('The voice engine is loading its model. Reading will work in a moment.')
    // It fixes itself, so check back rather than leaving stale copy on screen.
    clearTimeout(warmingRecheck)
    warmingRecheck = window.setTimeout(() => void refreshEngine(), 2000)
  } else if (els.hint.classList.contains('is-error')) {
    setHint('')
  }

  if (ok) {
    const voices = await send({ kind: 'voices' }).catch(() => null)
    if (voices?.kind === 'voices' && voices.voices.length) {
      fillVoiceSelect(els.voice, voices.voices)
      els.voice.value = prefs.voiceId
      // The stored voice is gone (different model build) — fall back to the
      // backend's default rather than showing a blank picker.
      if (!els.voice.value) {
        els.voice.value = voices.default
        prefs = await savePrefs({ voiceId: voices.default })
      }
    }
  }
}

function setHint(text: string, isError = false) {
  els.hint.textContent = text
  els.hint.hidden = !text
  els.hint.classList.toggle('is-error', isError && !!text)
}

// ── active tab ──────────────────────────────────────────────────────────────

async function refreshTab() {
  const [tab] = await chrome.tabs.query({ active: true, currentWindow: true })
  tabId = tab?.id

  const url = tab?.url ?? ''
  const restricted =
    !url ||
    /^(chrome|edge|about|devtools|view-source|chrome-extension):/.test(url) ||
    url.startsWith('https://chromewebstore.google.com')

  if (restricted) {
    els.primary.disabled = true
    els.primary.textContent = 'Can’t read this page'
    setHint('Browser pages are off-limits to extensions. Open an article and try again.')
    return
  }

  let snapshot: TabResponse | null = null
  if (tabId !== undefined) {
    // Fails when the content script hasn't been injected into this tab yet —
    // which simply means "not reading".
    snapshot = await (chrome.tabs.sendMessage(tabId, { kind: 'state' } satisfies TabRequest) as
      Promise<TabResponse>).catch(() => null)
  }

  readerActive = snapshot?.kind === 'state' && snapshot.state.active
  els.primary.disabled = false
  els.primary.classList.toggle('is-stop', readerActive)
  els.primary.textContent = readerActive ? 'Stop reading' : 'Read this page'

  if (snapshot?.kind === 'state' && snapshot.state.active) {
    const { index, total, status } = snapshot.state
    const position = index >= 0 ? index + 1 : 0
    setHint(status === 'ended' ? 'Finished this page.' : `Sentence ${position} of ${total}.`)
  }
}

// ── settings ────────────────────────────────────────────────────────────────

function renderPrefs() {
  els.rate.value = String(prefs.rate)
  els.rateValue.textContent = `${prefs.rate.toFixed(2).replace(/0$/, '').replace(/\.$/, '')}×`
  els.backend.value = prefs.backendUrl
  if (els.voice.options.length) els.voice.value = prefs.voiceId
  for (const key of TOGGLES) {
    $(`t-${key}`).setAttribute('aria-checked', String(prefs[key]))
  }
}

function wire() {
  els.primary.addEventListener('click', async () => {
    if (tabId === undefined) return
    const res = await send({
      kind: 'activate',
      tabId,
      action: readerActive ? 'stop' : 'start',
    }).catch(() => null)

    if (res?.kind === 'activate' && !res.ok) {
      setHint(res.error ?? 'Couldn’t start reading this page.', true)
      return
    }
    // Hand focus back to the page so keyboard shortcuts land where the user
    // is looking.
    window.close()
  })

  for (const key of TOGGLES) {
    $(`t-${key}`).addEventListener('click', async () => {
      prefs = await savePrefs({ [key]: !prefs[key as ToggleKey] })
      renderPrefs()
    })
  }

  // Label tracks the drag; the write is debounced so a sweep across the slider
  // doesn't hammer chrome.storage (and its write-per-minute quota).
  let rateTimer = 0
  els.rate.addEventListener('input', () => {
    const rate = Number(els.rate.value)
    els.rateValue.textContent = `${rate}×`
    clearTimeout(rateTimer)
    rateTimer = window.setTimeout(async () => {
      prefs = await savePrefs({ rate })
    }, 160)
  })

  els.voice.addEventListener('change', async () => {
    prefs = await savePrefs({ voiceId: els.voice.value })
  })

  els.backend.addEventListener('change', async () => {
    const url = els.backend.value.trim()
    prefs = await savePrefs({ backendUrl: url })
    renderPrefs() // a rejected URL snaps back to the stored one
    await refreshEngine()
  })
}

// ── boot ────────────────────────────────────────────────────────────────────

async function main() {
  prefs = await loadPrefs()
  renderPrefs()
  wire()
  await Promise.all([refreshTab(), refreshEngine()])
  renderPrefs()
}

void main()
