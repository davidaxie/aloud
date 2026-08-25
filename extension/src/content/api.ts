// ─────────────────────────────────────────────────────────────────────────────
// Backend client, as seen from the page.
//
// Every call is a message to the service worker, which owns the actual HTTP
// connection to the local Kokoro server (see shared/protocol for why). The
// AbortSignal plumbing is real, not decorative: a seek or voice change fires
// `abort`, the worker cancels its fetch, and the backend stops synthesizing
// audio nobody will hear.
//
// ── Retry policy (EXECUTION-PRD-1.1 §1.4) ────────────────────────────────────
// One transient 500 used to end playback. It no longer can: every synthesis is
// attempted up to 3 times (2 retries), backing off 250ms then 750ms, honouring
// `Retry-After` when the server asks for longer. What is retryable is decided by
// the response — the worker classifies, this module paces, the player decides the
// user-visible consequence. A 400 (the text itself is unusable) is never retried,
// and a caller abort is not an error at all: it propagates instantly, untouched.
//
// The 30s per-attempt timeout lives here rather than in the worker because the
// worker holds the socket but this side holds the user's patience. On expiry we
// send `abort` — the worker drops the fetch, the backend stops work — and count
// it as a retryable failure (`status: -1`, per the protocol's sentinel).
// ─────────────────────────────────────────────────────────────────────────────

import {
  base64ToBuffer,
  type BgRequest,
  type BgResponse,
  type HealthReport,
  type SynthPriority,
} from '../shared/protocol'
import type { Voice } from '../shared/types'

/** Per-attempt ceiling. A request still running after this is treated as a timeout. */
const ATTEMPT_TIMEOUT_MS = 30_000
/** Attempts after the first. 3 total tries. (§1.4) */
const MAX_RETRIES = 2
/** Backoff before retry #1 and #2. `Retry-After` wins when it asks for longer. */
const BACKOFF_MS = [250, 750]

/** Unique per page-session; the worker scopes it by sender, so tabs can't collide. */
let nextRequestId = 1

/** The page must be reloaded after this — no amount of retrying brings it back. */
const RELOADED_MESSAGE = 'Aloud was reloaded — refresh this page to keep reading.'

// ── errors ──────────────────────────────────────────────────────────────────

/**
 * A synthesis that failed for a reason the caller may care about.
 *
 * `retryable` is already resolved against the §1.4 policy — by the time this
 * escapes `synthesize()`, every permitted attempt has been spent. It is reported
 * anyway because "the engine refused this text" (400) and "the engine is
 * struggling" (503 three times) deserve different copy.
 *
 * User aborts are NOT reported through this type; they propagate as the original
 * `AbortError` so `isAbortError()` checks keep working.
 */
export class SynthesisError extends Error {
  /** HTTP status; 0 for a transport failure and -1 for our own timeout. */
  readonly status: number
  /** Whether the failure class is retryable at all (retries are already spent). */
  readonly retryable: boolean
  /** True when the attempt exceeded ATTEMPT_TIMEOUT_MS rather than answering. */
  readonly timedOut: boolean
  /** Total attempts made (1 = failed on the first try). */
  readonly attempts: number

  constructor(
    message: string,
    opts: { status: number; retryable: boolean; timedOut?: boolean; attempts?: number },
  ) {
    super(message)
    this.name = 'SynthesisError'
    this.status = opts.status
    this.retryable = opts.retryable
    this.timedOut = opts.timedOut ?? false
    this.attempts = opts.attempts ?? 1
  }
}

/** True for the DOMException an abort produces (and its cross-realm twins). */
export function isAbortError(err: unknown): boolean {
  return typeof err === 'object' && err !== null && (err as { name?: string }).name === 'AbortError'
}

function abortError(): DOMException {
  return new DOMException('Aborted', 'AbortError')
}

/** The extension was reloaded/updated out from under this page. */
function isContextInvalidated(err: unknown): boolean {
  return err instanceof Error && /context invalidated|receiving end does not exist/i.test(err.message)
}

/**
 * Per-error `Retry-After` hint. A WeakMap rather than a field so `SynthesisError`
 * stays a clean public shape — the pacing request is an implementation detail of
 * the retry loop and is meaningless once the loop is done with it.
 */
const retryDelays = new WeakMap<SynthesisError, number>()

/** Abortable sleep: a seek during backoff cancels the retry instead of delaying it. */
function delay(ms: number, signal?: AbortSignal): Promise<void> {
  return new Promise((resolve, reject) => {
    if (signal?.aborted) {
      reject(abortError())
      return
    }
    const onAbort = () => {
      clearTimeout(timer)
      reject(abortError())
    }
    const timer = setTimeout(() => {
      signal?.removeEventListener('abort', onAbort)
      resolve()
    }, ms)
    signal?.addEventListener('abort', onAbort, { once: true })
  })
}

// ── health / voices ─────────────────────────────────────────────────────────

const OFFLINE: HealthReport = { state: 'offline', voiceCount: 0, warm: false, queueDepth: 0 }

/**
 * How is the local speech engine? Never throws.
 *
 * The full report is returned rather than a boolean because `warming` and
 * `offline` demand different copy: one fixes itself, the other needs the user to
 * go start a server.
 */
export async function getHealth(): Promise<HealthReport> {
  try {
    const res = (await chrome.runtime.sendMessage({ kind: 'health' } satisfies BgRequest)) as
      | BgResponse
      | undefined
    if (res?.kind !== 'health') return OFFLINE
    return { state: res.state, voiceCount: res.voiceCount, warm: res.warm, queueDepth: res.queueDepth }
  } catch {
    return OFFLINE
  }
}

/** The installed voice roster. Returns an empty list if the backend is down. */
export async function getVoices(): Promise<{ voices: Voice[]; default: string }> {
  try {
    const res = (await chrome.runtime.sendMessage({ kind: 'voices' } satisfies BgRequest)) as
      | BgResponse
      | undefined
    if (res?.kind !== 'voices') return { voices: [], default: 'af_heart' }
    return { voices: res.voices, default: res.default }
  } catch {
    return { voices: [], default: 'af_heart' }
  }
}

// ── synthesis ───────────────────────────────────────────────────────────────

export interface SynthRequest {
  text: string
  voice: string
  speed: number
  /** Queue class: `now` for the sentence being waited on, `prefetch` for lookahead. */
  priority: SynthPriority
}

/** How one attempt finished — whichever of the three outcomes got there first. */
type Settled =
  | { kind: 'response'; res: BgResponse | undefined }
  | { kind: 'transport'; err: unknown }
  | { kind: 'timeout' }
  | { kind: 'abort' }

/**
 * One attempt.
 *
 * The worker holds the socket, so cancelling means messaging it — but a message
 * is a request, not a guarantee. If the worker is wedged or was evicted between
 * our send and its reply, waiting on that reply would outlive the timeout it was
 * supposed to enforce and stall playback indefinitely. So the timeout and the
 * caller's abort each RACE the response rather than politely asking for it: the
 * `abort` message still goes out so the backend stops working, but this side
 * stops waiting either way.
 */
async function attemptSynthesize(
  req: SynthRequest,
  attempt: number,
  signal?: AbortSignal,
): Promise<Blob> {
  const id = nextRequestId++
  const attempts = attempt + 1

  const cancel = () => {
    void chrome.runtime.sendMessage({ kind: 'abort', id } satisfies BgRequest).catch(() => {})
  }

  let timer: ReturnType<typeof setTimeout> | undefined
  let onAbort: (() => void) | undefined

  const outcome: Settled = await Promise.race<Settled>([
    chrome.runtime.sendMessage({ kind: 'synth', id, ...req } satisfies BgRequest).then(
      (res) => ({ kind: 'response', res: res as BgResponse | undefined }),
      (err: unknown) => ({ kind: 'transport', err }),
    ),
    new Promise<Settled>((resolve) => {
      timer = setTimeout(() => resolve({ kind: 'timeout' }), ATTEMPT_TIMEOUT_MS)
    }),
    new Promise<Settled>((resolve) => {
      if (signal?.aborted) {
        resolve({ kind: 'abort' })
        return
      }
      onAbort = () => resolve({ kind: 'abort' })
      signal?.addEventListener('abort', onAbort, { once: true })
    }),
  ]).finally(() => {
    clearTimeout(timer)
    if (onAbort) signal?.removeEventListener('abort', onAbort)
  })

  if (outcome.kind === 'abort') {
    cancel() // stop the backend synthesizing audio nobody will hear
    throw abortError()
  }

  if (outcome.kind === 'timeout') {
    cancel()
    throw new SynthesisError(`synthesis timed out after ${ATTEMPT_TIMEOUT_MS}ms`, {
      status: -1,
      retryable: true,
      timedOut: true,
      attempts,
    })
  }

  if (outcome.kind === 'transport') {
    // A dead message port. If the extension was reloaded the page is beyond
    // saving and retrying is pointless; anything else may just be a worker that
    // got evicted mid-flight, which the next attempt will respawn.
    const fatal = isContextInvalidated(outcome.err)
    throw new SynthesisError(fatal ? RELOADED_MESSAGE : 'Speech engine unreachable.', {
      status: 0,
      retryable: !fatal,
      attempts,
    })
  }

  const res = outcome.res
  if (res?.kind !== 'synth') {
    throw new SynthesisError('Unexpected response from the speech engine.', {
      status: 0,
      retryable: false,
      attempts,
    })
  }
  if (res.ok) return new Blob([base64ToBuffer(res.audio)], { type: 'audio/wav' })

  // The worker reporting its own cancellation — a race we already lost, not a
  // failure to report or retry.
  if (res.aborted) throw abortError()

  const err = new SynthesisError(res.error, {
    status: res.status,
    retryable: res.retryable,
    attempts,
  })
  if (res.retryAfterMs !== null) retryDelays.set(err, res.retryAfterMs)
  throw err
}

/**
 * Synthesize one sentence to a WAV blob, applying the §1.4 retry policy.
 *
 * Throws `SynthesisError` (carrying `status` and `retryable`) once every
 * permitted attempt is spent, or the original `AbortError` if `signal` fired — a
 * stale request must die instantly and must never be retried.
 */
export async function synthesize(req: SynthRequest, signal?: AbortSignal): Promise<Blob> {
  for (let attempt = 0; ; attempt++) {
    if (signal?.aborted) throw abortError()
    try {
      return await attemptSynthesize(req, attempt, signal)
    } catch (err) {
      if (isAbortError(err)) throw err
      const se =
        err instanceof SynthesisError
          ? err
          : new SynthesisError(err instanceof Error ? err.message : String(err), {
              status: 0,
              retryable: false,
              attempts: attempt + 1,
            })
      if (!se.retryable || attempt >= MAX_RETRIES) throw se
      const backoff = BACKOFF_MS[Math.min(attempt, BACKOFF_MS.length - 1)]
      // The server knows its own queue depth better than our fixed curve does.
      await delay(Math.max(backoff, retryDelays.get(se) ?? 0), signal)
    }
  }
}
