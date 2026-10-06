// ─────────────────────────────────────────────────────────────────────────────
// Engine watch — keeps the engine badge honest.
//
// Probes /health until the backend answers ok (so a server that starts AFTER the
// page loads is picked up), then stops. When playback later finds the engine
// down it sets the state to 'offline', and the watch starts probing again, so
// the badge clears itself once the server is back instead of waiting for the
// next Play.
// ─────────────────────────────────────────────────────────────────────────────
import type { EngineState } from '../types'

export interface EngineWatchDeps {
  /** One /health probe. Never throws: a down engine answers { ok: false }. */
  probe: () => Promise<{ ok: boolean; state: EngineState }>
  getEngineState: () => EngineState
  setEngineState: (state: EngineState) => void
  /** Runs after each healthy answer (the voice roster loads here). */
  onHealthy?: () => Promise<void> | void
  /** Calls `listener` whenever the engine state changes; returns an unsubscribe. */
  subscribe: (listener: (state: EngineState) => void) => () => void
  intervalMs?: number
}

/** Start watching. Returns a function that stops every probe and subscription. */
export function watchEngine(deps: EngineWatchDeps): () => void {
  const intervalMs = deps.intervalMs ?? 2500
  let stopped = false
  let timer: ReturnType<typeof setInterval> | undefined

  const stopPolling = () => {
    if (timer) clearInterval(timer)
    timer = undefined
  }

  const check = async () => {
    const health = await deps.probe()
    if (stopped) return
    deps.setEngineState(health.state)
    if (health.ok) {
      await deps.onHealthy?.()
      stopPolling()
    }
  }

  const startPolling = () => {
    if (timer || stopped) return
    timer = setInterval(() => {
      if (deps.getEngineState() === 'ok') stopPolling()
      else void check()
    }, intervalMs)
  }

  void check()
  startPolling()
  // Playback reporting the engine down restarts the probes.
  const unsubscribe = deps.subscribe((state) => {
    if (state === 'offline') startPolling()
  })

  return () => {
    stopped = true
    stopPolling()
    unsubscribe()
  }
}
