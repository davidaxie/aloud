// ─────────────────────────────────────────────────────────────────────────────
// Backend (Kokoro) HTTP client.
// The UI imports getHealth/getVoices for bootstrap; the player imports synthesize.
//
// ── Retry policy (EXECUTION-PRD-1.1 §1.4) ──────────────────────────────────────
// One transient 500 used to end playback. It no longer can: every synthesis is
// attempted up to 3 times (2 retries) with a 30s per-attempt timeout, backing off
// 250ms then 750ms, honouring `Retry-After` when the server asks for longer. What
// is retryable is decided by the response, not by guesswork: 429/503/500, network
// failures and timeouts are; a 400 (the text itself is unusable) never is, and a
// caller abort — a seek, a voice change, an eviction — is not an error at all and
// must propagate instantly and untouched so the UI stays responsive.
//
// Errors carry the HTTP status and a `retryable` flag so the PLAYER can decide the
// user-visible consequence. This module never touches the store: the rule that
// only a failing /health raises the global "offline" banner (§1.4) is only
// enforceable if the transport layer stays opinion-free.
// ─────────────────────────────────────────────────────────────────────────────
import type { EngineState, SynthesizeRequest, Voice } from '../types'

export const API_BASE = import.meta.env.VITE_API_BASE ?? 'http://127.0.0.1:8000'

/** Per-attempt ceiling. A request still running after this is treated as a timeout. */
const ATTEMPT_TIMEOUT_MS = 30_000
/** Attempts after the first. 3 total tries. (§1.4) */
const MAX_RETRIES = 2
/** Backoff before retry #1 and #2. `Retry-After` wins when it asks for longer. */
const BACKOFF_MS = [250, 750]
/** /health is a liveness probe, not work — it should answer in milliseconds. */
const HEALTH_TIMEOUT_MS = 5_000

// ── errors ────────────────────────────────────────────────────────────────────

/**
 * A synthesis request that failed for a reason the caller may care about.
 *
 * `retryable` is already resolved against the §1.4 policy — by the time this
 * escapes `synthesize()`, every permitted retry has been spent. It is reported
 * anyway because "the engine refused this text" (400) and "the engine is
 * struggling" (503 three times) deserve different copy.
 *
 * User aborts are NOT reported through this type; they propagate as the original
 * `AbortError` so existing `isAbortError()` checks keep working.
 */
export class SynthesisError extends Error {
  /** HTTP status, or null for a network failure / timeout (no response arrived). */
  readonly status: number | null
  /** Whether the failure class is retryable at all (retries are already spent). */
  readonly retryable: boolean
  /** True when the attempt exceeded ATTEMPT_TIMEOUT_MS rather than answering. */
  readonly timedOut: boolean
  /** How many attempts were made in total (1 = failed on the first try). */
  readonly attempts: number

  constructor(
    message: string,
    opts: { status?: number | null; retryable: boolean; timedOut?: boolean; attempts?: number },
  ) {
    super(message)
    this.name = 'SynthesisError'
    this.status = opts.status ?? null
    this.retryable = opts.retryable
    this.timedOut = opts.timedOut ?? false
    this.attempts = opts.attempts ?? 1
  }
}

/** True for the DOMException a fetch abort produces (and its cross-realm twins). */
export function isAbortError(err: unknown): boolean {
  return err instanceof DOMException
    ? err.name === 'AbortError'
    : typeof err === 'object' && err !== null && (err as { name?: string }).name === 'AbortError'
}

/** The abort rejection shape `fetch` uses, for the paths where we abort ourselves. */
function abortError(): DOMException {
  return new DOMException('Aborted', 'AbortError')
}

// ── health ────────────────────────────────────────────────────────────────────

export interface HealthResult {
  /** Legacy convenience: true only when the engine is loaded AND warm. */
  ok: boolean
  /**
   * The distinction the review asked for: a warming engine is healthy and about
   * to work, and must never be reported as "offline" (§1.2, F1.7).
   */
  state: EngineState
  voiceCount: number
  /** Warm-up inference has completed. False on backends predating 1.1. */
  warm: boolean
  /** Requests waiting behind the one in flight. 0 on backends predating 1.1. */
  queueDepth: number
}

const OFFLINE: HealthResult = {
  ok: false,
  state: 'offline',
  voiceCount: 0,
  warm: false,
  queueDepth: 0,
}

/**
 * GET /health — is the local TTS backend up, loaded, and warm?
 * Never throws: any network/parse failure resolves to an `offline` result so the
 * UI and the player can poll this on a timer without try/catch. Bounded by
 * HEALTH_TIMEOUT_MS so a wedged backend reads as offline instead of hanging the
 * poll loop forever.
 */
export async function getHealth(): Promise<HealthResult> {
  const controller = new AbortController()
  const timer = setTimeout(() => controller.abort(), HEALTH_TIMEOUT_MS)
  try {
    const res = await fetch(`${API_BASE}/health`, { signal: controller.signal })
    if (!res.ok) return OFFLINE
    const data: unknown = await res.json()
    const d = (data ?? {}) as {
      status?: string
      model_loaded?: boolean
      voice_count?: number
      warm?: boolean
      queue_depth?: number
    }
    const loaded = d.model_loaded === true
    // `warm` is absent on pre-1.1 backends; there, a loaded model IS the ready
    // state, so fall back to `status === 'ok'` rather than reporting an eternal
    // "warming" that would never clear.
    const warm = typeof d.warm === 'boolean' ? d.warm : d.status === 'ok'
    const state: EngineState = d.status === 'ok' && loaded && warm ? 'ok' : 'warming'
    return {
      ok: state === 'ok',
      state,
      voiceCount: typeof d.voice_count === 'number' ? d.voice_count : 0,
      warm,
      queueDepth: typeof d.queue_depth === 'number' ? d.queue_depth : 0,
    }
  } catch {
    // Backend down / DNS / CORS / offline / timeout — report offline, never throw.
    return OFFLINE
  } finally {
    clearTimeout(timer)
  }
}

/** GET /voices — the installed voice roster and the default voice id. */
export async function getVoices(): Promise<{ voices: Voice[]; default: string }> {
  const res = await fetch(`${API_BASE}/voices`)
  if (!res.ok) throw new Error(`getVoices failed: HTTP ${res.status}`)
  const data: unknown = await res.json()
  const d = (data ?? {}) as { voices?: Voice[]; default?: string }
  return {
    voices: Array.isArray(d.voices) ? d.voices : [],
    default: typeof d.default === 'string' ? d.default : 'af_heart',
  }
}

// ── synthesis ─────────────────────────────────────────────────────────────────

/** Parse the error body for a message + the server's own `retryable` verdict. */
async function readErrorBody(res: Response): Promise<{ message: string; retryable?: boolean }> {
  try {
    const data: unknown = await res.json()
    const d = (data ?? {}) as { error?: unknown; retryable?: unknown }
    return {
      message: typeof d.error === 'string' ? d.error : `HTTP ${res.status}`,
      retryable: typeof d.retryable === 'boolean' ? d.retryable : undefined,
    }
  } catch {
    return { message: `HTTP ${res.status}` }
  }
}

/**
 * Whether a status is worth another attempt.
 * 400 is the one hard "no": the backend is telling us this text can never be
 * synthesized, so retrying it burns the user's time to reach the same answer.
 * The server's `retryable` flag refines the 5xx range but can never override 400.
 */
function statusRetryable(status: number, serverSaid: boolean | undefined): boolean {
  if (status === 400) return false
  if (serverSaid !== undefined) return serverSaid
  return status === 429 || status === 503 || status >= 500
}

/** `Retry-After` in ms — seconds form or HTTP-date form. 0 when absent/garbage. */
function retryAfterMs(res: Response): number {
  const raw = res.headers.get('Retry-After')
  if (!raw) return 0
  const seconds = Number(raw)
  if (Number.isFinite(seconds) && seconds >= 0) return Math.min(seconds * 1000, 10_000)
  const at = Date.parse(raw)
  if (Number.isFinite(at)) return Math.max(0, Math.min(at - Date.now(), 10_000))
  return 0
}

/** Abortable sleep: a seek during backoff cancels the retry instead of delaying it. */
function delay(ms: number, signal?: AbortSignal): Promise<void> {
  return new Promise((resolve, reject) => {
    if (signal?.aborted) {
      reject(abortError())
      return
    }
    const timer = setTimeout(() => {
      signal?.removeEventListener('abort', onAbort)
      resolve()
    }, ms)
    function onAbort() {
      clearTimeout(timer)
      reject(abortError())
    }
    signal?.addEventListener('abort', onAbort, { once: true })
  })
}

/**
 * Per-error `Retry-After` hint. A WeakMap rather than a field so `SynthesisError`
 * stays a clean public shape — the pacing request is an implementation detail of
 * the retry loop and is meaningless once the loop is done with it.
 */
const retryDelays = new WeakMap<SynthesisError, number>()

/**
 * One attempt. Owns its own AbortController so the 30s timeout can fire without
 * disturbing the caller's signal, while a caller abort still cancels the fetch
 * immediately (the two are chained, not merged, so we can tell them apart —
 * a timeout is retryable, a user abort is not).
 */
async function attemptSynthesize(
  body: string,
  attempt: number,
  signal?: AbortSignal,
): Promise<Blob> {
  const controller = new AbortController()
  let timedOut = false
  const onCallerAbort = () => controller.abort()
  signal?.addEventListener('abort', onCallerAbort, { once: true })
  const timer = setTimeout(() => {
    timedOut = true
    controller.abort()
  }, ATTEMPT_TIMEOUT_MS)

  try {
    const res = await fetch(`${API_BASE}/synthesize`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body,
      signal: controller.signal,
    })
    if (!res.ok) {
      const { message, retryable } = await readErrorBody(res)
      const err = new SynthesisError(`synthesize failed: HTTP ${res.status} — ${message}`, {
        status: res.status,
        retryable: statusRetryable(res.status, retryable),
        attempts: attempt + 1,
      })
      // Stash the server's pacing request on the error so the retry loop can honour it.
      retryDelays.set(err, retryAfterMs(res))
      throw err
    }
    return await res.blob()
  } catch (err) {
    if (err instanceof SynthesisError) throw err
    if (isAbortError(err)) {
      // The caller's abort wins: it means the result is no longer wanted at all.
      if (signal?.aborted) throw err
      if (timedOut) {
        throw new SynthesisError(`synthesize timed out after ${ATTEMPT_TIMEOUT_MS}ms`, {
          status: null,
          retryable: true,
          timedOut: true,
          attempts: attempt + 1,
        })
      }
    }
    // Anything else at this layer is a transport failure: DNS, refused, reset,
    // CORS. The backend may simply be restarting, so it is retryable.
    throw new SynthesisError(
      `synthesize failed: ${err instanceof Error ? err.message : String(err)}`,
      { status: null, retryable: true, attempts: attempt + 1 },
    )
  } finally {
    clearTimeout(timer)
    signal?.removeEventListener('abort', onCallerAbort)
  }
}

/**
 * POST /synthesize — returns a WAV blob for one chunk of text.
 *
 * Applies the §1.4 retry policy. Throws `SynthesisError` (with `status` and
 * `retryable`) once every permitted attempt is spent, or the original
 * `AbortError` if `signal` fired — a stale request must die instantly and must
 * never be retried.
 *
 * `req.priority` decides the backend's queue class: `now` for the sentence the
 * user is waiting on, `prefetch` for speculative look-ahead (the player passes
 * it for the sentences it warms ahead of the playhead). Omitted, it is sent as
 * `now`, which is also the backend's default.
 */
export async function synthesize(req: SynthesizeRequest, signal?: AbortSignal): Promise<Blob> {
  const body = JSON.stringify({ priority: 'now', ...req })

  for (let attempt = 0; ; attempt++) {
    if (signal?.aborted) throw abortError()
    try {
      return await attemptSynthesize(body, attempt, signal)
    } catch (err) {
      // A user abort is not a failure — never retried, never wrapped.
      if (isAbortError(err)) throw err
      const se =
        err instanceof SynthesisError
          ? err
          : new SynthesisError(String(err), { retryable: false, attempts: attempt + 1 })
      if (!se.retryable || attempt >= MAX_RETRIES) throw se
      const backoff = BACKOFF_MS[Math.min(attempt, BACKOFF_MS.length - 1)]
      // The server knows its own queue depth better than our fixed curve does.
      await delay(Math.max(backoff, retryDelays.get(se) ?? 0), signal)
    }
  }
}
