// ─────────────────────────────────────────────────────────────────────────────
// Message contracts.
//
// Two channels, both over chrome.runtime / chrome.tabs messaging:
//
//   content|popup → service worker   (BgRequest → BgResponse)
//     The worker is the ONLY thing that talks to http://localhost:8000. A page's
//     content script cannot: a fetch from an isolated world still carries the
//     page's origin, so a public https:// page hitting a private-network
//     localhost address is exactly what Chrome's Private Network Access rules
//     block. The worker's own chrome-extension:// origin has host permissions
//     for localhost, so it is allowed — and it keeps the backend URL in one place.
//
//   service worker|popup → content   (TabRequest → TabResponse)
//     Transport commands and a state snapshot for the popup.
//
// Audio crosses the first channel as base64, because chrome messaging is
// JSON-serialized: ArrayBuffers and Blobs do not survive it.
// ─────────────────────────────────────────────────────────────────────────────

import type { EngineState, PlayerStatus, Voice } from './types'

// ── content|popup → service worker ──────────────────────────────────────────

/**
 * How badly we want this synthesis (backend contract §1.1).
 *
 * The backend serializes synthesis behind one worker and serves every `now`
 * request before any `prefetch` one. The sentence the user is waiting to hear
 * is `now`; everything speculative is `prefetch`, and only `prefetch` can be
 * rejected with a 429 when the queue is full.
 */
export type SynthPriority = 'now' | 'prefetch'

export type BgRequest =
  /** Is the local TTS server up, warm, and with its model loaded? */
  | { kind: 'health' }
  /** The installed voice roster. */
  | { kind: 'voices' }
  /** Synthesize one sentence. `id` is unique per caller-session and abortable. */
  | {
      kind: 'synth'
      id: number
      text: string
      voice: string
      speed: number
      priority: SynthPriority
    }
  /** Cancel an in-flight `synth` — the user seeked or changed voice. */
  | { kind: 'abort'; id: number }
  /**
   * Popup asked to start/stop reading the given tab. The worker injects the
   * content script if it isn't there yet, then forwards the command.
   */
  | { kind: 'activate'; tabId: number; action: TabAction }

/** What `GET /health` told us, normalized (backend contract §1.2). */
export interface HealthReport {
  state: EngineState
  /** How many voices the engine reports; 0 when we couldn't ask. */
  voiceCount: number
  /** True once start-up warm-up has completed. */
  warm: boolean
  /** Requests queued behind the one in flight; 0 when unknown. */
  queueDepth: number
}

/**
 * A failed synthesis, classified for the caller's retry policy (§1.4).
 *
 * `status` is the HTTP status where there was one; two sentinels stand in for
 * failures that never reached an HTTP response:
 *   0  — transport: the fetch itself threw (backend down, DNS, socket reset)
 *  -1  — the caller's own per-attempt timeout fired
 */
export interface SynthFailure {
  error: string
  /** True when the request was cancelled by us — never retry, never report. */
  aborted: boolean
  /** Retry is worth attempting: 429 / 500 / 503 / transport. Never a 400. */
  retryable: boolean
  status: number
  /** `Retry-After` from the backend, in ms. Null when the header was absent. */
  retryAfterMs: number | null
}

export type BgResponse =
  | ({ kind: 'health' } & HealthReport)
  | { kind: 'voices'; voices: Voice[]; default: string }
  /** `audio` is a base64-encoded WAV. */
  | { kind: 'synth'; ok: true; audio: string }
  | ({ kind: 'synth'; ok: false } & SynthFailure)
  | { kind: 'activate'; ok: boolean; error?: string }
  | { kind: 'error'; error: string }

// ── service worker|popup → content script ───────────────────────────────────

/** Everything a user can trigger from outside the page. */
export type TabAction =
  /** Start reading the page from the top (or resume if already loaded). */
  | 'start'
  /** Start reading just the current text selection. */
  | 'start-selection'
  /** Play if paused, pause if playing; start from the top if nothing is loaded. */
  | 'toggle'
  | 'next'
  | 'prev'
  /** Tear down: stop audio, drop highlights, remove the player bar. */
  | 'stop'

export type TabRequest =
  /** Liveness probe used to decide whether the content script needs injecting. */
  | { kind: 'ping' }
  | { kind: 'command'; action: TabAction }
  /** Popup asks what's happening in this tab. */
  | { kind: 'state' }

export type TabResponse =
  | { kind: 'pong' }
  | { kind: 'ok' }
  | { kind: 'state'; state: TabStateSnapshot }

/** The slice of reader state the popup renders. */
export interface TabStateSnapshot {
  /** True once a page has been parsed and the player bar is up. */
  active: boolean
  status: PlayerStatus
  /** 0-based index of the sentence being spoken, -1 if none. */
  index: number
  total: number
  title: string
  error: string | null
}

// ── base64 (chrome messaging is JSON-only, so WAV bytes travel as text) ──────

/** Bytes → base64. Chunked so a big WAV can't blow the argument limit. */
export function bytesToBase64(bytes: Uint8Array): string {
  const CHUNK = 0x8000
  let binary = ''
  for (let i = 0; i < bytes.length; i += CHUNK) {
    binary += String.fromCharCode(...bytes.subarray(i, i + CHUNK))
  }
  return btoa(binary)
}

/** base64 → an ArrayBuffer, ready to hand straight to `new Blob([…])`. */
export function base64ToBuffer(b64: string): ArrayBuffer {
  const binary = atob(b64)
  const buffer = new ArrayBuffer(binary.length)
  const view = new Uint8Array(buffer)
  for (let i = 0; i < binary.length; i++) view[i] = binary.charCodeAt(i)
  return buffer
}
