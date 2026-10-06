// F062: after playback reports the engine offline, /health must be probed again
// so the badge clears once the backend is back.
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { watchEngine } from '../src/lib/engineWatch.ts'

type State = 'unknown' | 'ok' | 'warming' | 'offline'

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms))

function fakeStore() {
  let state: State = 'unknown'
  const listeners = new Set<(s: State) => void>()
  return {
    get: () => state,
    set: (next: State) => {
      if (next === state) return
      state = next
      for (const l of listeners) l(next)
    },
    subscribe: (l: (s: State) => void) => {
      listeners.add(l)
      return () => {
        listeners.delete(l)
      }
    },
  }
}

test('the watch probes again after an outage and clears the badge on recovery', async () => {
  const store = fakeStore()
  let backendUp = true
  let probes = 0
  let healthyCalls = 0
  const stop = watchEngine({
    probe: async () => {
      probes++
      return backendUp ? { ok: true, state: 'ok' } : { ok: false, state: 'offline' }
    },
    getEngineState: store.get,
    setEngineState: store.set,
    onHealthy: () => {
      healthyCalls++
    },
    subscribe: store.subscribe,
    intervalMs: 5,
  })

  await sleep(40)
  assert.equal(store.get(), 'ok')
  assert.equal(probes, 1, 'polling stops once the engine is ok')
  assert.equal(healthyCalls, 1)

  // Playback finds the engine down (player.handleSynthError).
  backendUp = false
  store.set('offline')
  await sleep(40)
  assert.ok(probes > 1, 'an outage restarts the probes')
  assert.equal(store.get(), 'offline')

  // The backend comes back: the badge clears without anyone pressing Play.
  backendUp = true
  await sleep(40)
  assert.equal(store.get(), 'ok')
  const settled = probes
  await sleep(30)
  assert.equal(probes, settled, 'and polling stops again')
  stop()
})

test('stop() ends probing even while offline', async () => {
  const store = fakeStore()
  let probes = 0
  const stop = watchEngine({
    probe: async () => {
      probes++
      return { ok: false, state: 'offline' }
    },
    getEngineState: store.get,
    setEngineState: store.set,
    subscribe: store.subscribe,
    intervalMs: 5,
  })
  await sleep(20)
  stop()
  const count = probes
  store.set('ok')
  store.set('offline')
  await sleep(30)
  assert.equal(probes, count)
})
