// Playback failure paths of the web player (F058, F061, F062), driven against a
// muted rig: a fake <audio> element that never makes a sound and a fake
// /synthesize that answers locally. No network, no real audio.
import './support/hooks.mjs'
import { after, beforeEach, test } from 'node:test'
import assert from 'node:assert/strict'

/** What the next play() calls do, in order; 'ok' once the list runs out. */
let playOutcomes: Array<'ok' | DOMException> = []
let audioEl: FakeAudio | null = null

class FakeAudio extends EventTarget {
  preload = ''
  preservesPitch = true
  playbackRate = 1
  currentTime = 0
  duration = Number.NaN
  ended = false
  paused = true
  error: { code: number } | null = null
  #src = ''
  constructor() {
    super()
    audioEl = this
  }
  get src() {
    return this.#src
  }
  set src(value: string) {
    this.#src = value
    this.error = null
  }
  get currentSrc() {
    return this.#src
  }
  removeAttribute(name: string) {
    if (name === 'src') this.#src = ''
  }
  load() {}
  pause() {
    this.paused = true
  }
  play(): Promise<void> {
    const outcome = playOutcomes.shift() ?? 'ok'
    if (outcome !== 'ok') return Promise.reject(outcome)
    this.paused = false
    return Promise.resolve()
  }
}

Object.assign(globalThis, {
  Audio: FakeAudio,
  requestAnimationFrame: () => 0,
  cancelAnimationFrame: () => {},
  fetch: async (url: string | URL) => {
    if (String(url).endsWith('/synthesize')) {
      return new Response(new Uint8Array([82, 73, 70, 70]), {
        status: 200,
        headers: { 'Content-Type': 'audio/wav' },
      })
    }
    return new Response('{}', { status: 404 })
  },
})

const { player } = await import('../src/lib/player.ts')
const { useStore } = await import('../src/store.ts')

const doc = {
  title: 'Rig',
  pageCount: 1,
  sentences: [0, 1, 2, 3].map((id) => ({ id, text: `Sentence number ${id}.`, para: 0, page: 1 })),
  paragraphs: [{ id: 0, sentenceIds: [0, 1, 2, 3], page: 1 }],
}

const state = () => useStore.getState()

/** Let the fake fetches, blob reads and play() promises run to completion. */
async function settle() {
  for (let i = 0; i < 10; i++) await new Promise((r) => setTimeout(r, 0))
}

beforeEach(() => {
  playOutcomes = []
  state().reset()
  player.load(doc)
})

after(() => player.stop())

test('F061: an autoplay block pauses with a hint instead of sitting on playing', async () => {
  playOutcomes = [new DOMException('play() needs a user gesture', 'NotAllowedError')]
  player.play()
  await settle()
  assert.equal(state().status, 'paused')
  assert.match(state().toast?.text ?? '', /Press play/)
  assert.equal(state().currentSentence, 0)

  // The next press resumes in place and plays.
  player.play()
  await settle()
  assert.equal(state().status, 'playing')
  assert.equal(state().currentSentence, 0)
})

test('F061: a clip play() cannot decode is skipped, not stuck on playing', async () => {
  playOutcomes = [new DOMException('no supported source', 'NotSupportedError')]
  player.play()
  await settle()
  assert.deepEqual(state().skippedSentences, [0])
  assert.equal(state().currentSentence, 1)
  assert.equal(state().status, 'playing')
  assert.match(state().toast?.text ?? '', /Skipped a sentence/)
})

test('F061: a media error while playing steps to the next sentence', async () => {
  player.play()
  await settle()
  assert.equal(state().status, 'playing')
  assert.equal(state().currentSentence, 0)

  audioEl!.error = { code: 3 } // MEDIA_ERR_DECODE
  audioEl!.dispatchEvent(new Event('error'))
  await settle()
  assert.deepEqual(state().skippedSentences, [0])
  assert.equal(state().currentSentence, 1)
  assert.equal(state().status, 'playing')
})

test('F061: a run of unplayable clips stops with an error rather than skipping the book', async () => {
  const bad = () => new DOMException('no supported source', 'NotSupportedError')
  playOutcomes = [bad(), bad(), bad()]
  player.play()
  await settle()
  assert.equal(state().status, 'error')
  assert.deepEqual(state().skippedSentences, [0, 1])
  assert.ok(state().error)
})

test('F062: a successful synthesis clears the engine-offline banner', async () => {
  state().setEngineState('offline')
  state().setError('Speech engine offline — is the backend running?')
  player.play()
  await settle()
  assert.equal(state().status, 'playing')
  assert.equal(state().engineState, 'ok')
  assert.equal(state().error, null)
})

test('F058: a skipped sentence loses its mark once it is read', async () => {
  state().markSkipped(0)
  state().markSkipped(2)
  player.play()
  await settle()
  assert.deepEqual(state().skippedSentences, [2])
})
