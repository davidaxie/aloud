// Playback failure paths of the web player (F058, F061, F062), driven against a
// muted rig: a fake <audio> element that never makes a sound and a fake
// /synthesize that answers locally. No network, no real audio.
import './support/hooks.mjs'
import { after, beforeEach, test } from 'node:test'
import assert from 'node:assert/strict'

/** What the next play() calls do, in order; 'ok' once the list runs out. */
let playOutcomes: Array<'ok' | DOMException> = []
let audioEl: FakeAudio | null = null
/** Every /synthesize body the player sent, in order. */
let synthBodies: Array<{ text: string; priority?: string }> = []
/** Sentence texts the fake backend answers 400 for (it is up, it just can't read them). */
let unreadable = new Set<string>()
/** The fake backend's prefetch lane is full: it answers 429 to look-ahead. */
let busyPrefetch = false
/** The fake backend is not running: every /synthesize fails in transport. */
let backendDown = false
/** The fake backend never answers: requests stay in flight until aborted. */
let hangSynth = false
/** Texts of the /synthesize requests the player aborted while in flight. */
let abortedTexts: string[] = []
/** While set, each /synthesize answer waits here until the test releases it. */
let heldSynth: Array<() => void> | null = null
/** The handlers the player gave the browser's media session (J036). */
const mediaActions = new Map<string, (() => void) | null>()

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

// The ⏯ key, the browser's media controls and headphone buttons reach the page
// through navigator.mediaSession (J036). Node's own navigator has none.
Object.defineProperty(globalThis, 'navigator', {
  configurable: true,
  value: {
    mediaSession: {
      setActionHandler: (action: string, handler: (() => void) | null) => {
        mediaActions.set(action, handler)
      },
    },
  },
})

Object.assign(globalThis, {
  Audio: FakeAudio,
  requestAnimationFrame: () => 0,
  cancelAnimationFrame: () => {},
  fetch: async (url: string | URL, init?: RequestInit) => {
    if (String(url).endsWith('/synthesize')) {
      const body = JSON.parse(String(init?.body))
      synthBodies.push(body)
      if (heldSynth) await new Promise<void>((release) => heldSynth!.push(release))
      if (backendDown) throw new TypeError('Failed to fetch')
      if (hangSynth) {
        return new Promise<Response>((_, reject) => {
          init?.signal?.addEventListener(
            'abort',
            () => {
              abortedTexts.push(body.text)
              reject(new DOMException('aborted', 'AbortError'))
            },
            { once: true },
          )
        })
      }
      if (busyPrefetch && body.priority === 'prefetch') {
        return new Response(JSON.stringify({ detail: 'busy', retryable: true }), {
          status: 429,
          headers: { 'Content-Type': 'application/json', 'Retry-After': '0' },
        })
      }
      if (unreadable.has(body.text)) {
        return new Response(JSON.stringify({ detail: 'no phonemes', retryable: false }), {
          status: 400,
          headers: { 'Content-Type': 'application/json' },
        })
      }
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

/** Outlast api.ts's retry backoff (250 ms + 750 ms) for a failing request. */
const outlastRetries = () => new Promise((r) => setTimeout(r, 1300))

beforeEach(() => {
  playOutcomes = []
  synthBodies = []
  unreadable = new Set()
  busyPrefetch = false
  backendDown = false
  hangSynth = false
  abortedTexts = []
  heldSynth = null
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

test('look-ahead synthesis rides the prefetch lane; the sentence being played is now', async () => {
  player.play()
  await settle()
  const lane = new Map(synthBodies.map((b) => [b.text, b.priority]))
  assert.equal(lane.get('Sentence number 0.'), 'now')
  assert.equal(lane.get('Sentence number 1.'), 'prefetch')
  assert.equal(lane.get('Sentence number 2.'), 'prefetch')
})

test('a run of sentences the backend answers 400 for stops without calling it offline', async () => {
  unreadable = new Set(['Sentence number 0.', 'Sentence number 1.', 'Sentence number 2.'])
  player.play()
  await settle()
  assert.equal(state().status, 'error')
  assert.deepEqual(state().skippedSentences, [0, 1])
  assert.notEqual(state().engineState, 'offline')
  assert.ok(state().error)
  assert.doesNotMatch(state().error ?? '', /offline/i)
})

test('G033: a run of unplayable clips says to press Play, not to reload the page', async () => {
  const bad = () => new DOMException('no supported source', 'NotSupportedError')
  playOutcomes = [bad(), bad(), bad()]
  player.play()
  await settle()
  assert.equal(state().status, 'error')
  // A reload loses the open document and the place in it.
  assert.doesNotMatch(state().error ?? '', /reload/i)
  assert.match(state().error ?? '', /press Play/)
})

test('G032: look-ahead turned away as busy is asked again, not marked unreadable', async () => {
  busyPrefetch = true
  player.play()
  await settle()
  assert.equal(state().currentSentence, 0)
  // Sentence 0 ends while sentence 1's look-ahead is still being retried.
  audioEl!.dispatchEvent(new Event('ended'))
  await outlastRetries()
  await settle()
  assert.deepEqual(state().skippedSentences, [])
  assert.equal(state().currentSentence, 1)
  assert.equal(state().status, 'playing')
  assert.ok(
    synthBodies.some((b) => b.text === 'Sentence number 1.' && b.priority === 'now'),
    'sentence 1 is asked for again in the now lane',
  )
})

test('G016: the engine coming back clears the offline banner playback left', async () => {
  backendDown = true
  player.play()
  await outlastRetries()
  await settle()
  assert.equal(state().engineState, 'offline')
  assert.match(state().error ?? '', /offline/)

  backendDown = false
  player.engineRecovered() // App calls this on each healthy /health answer
  assert.equal(state().error, null)
  assert.equal(state().status, 'paused')
  assert.equal(state().currentSentence, 0)
})

test('G016: a healthy probe leaves other errors alone', () => {
  state().setError('Could not read that PDF \u2014 it is locked.')
  state().setStatus('error')
  player.engineRecovered()
  assert.match(state().error ?? '', /Could not read/)
  assert.equal(state().status, 'error')
})

test('H031: a seek drops the requests for the position it leaves', async () => {
  const ids = Array.from({ length: 40 }, (_, id) => id)
  player.load({
    title: 'Long',
    pageCount: 1,
    sentences: ids.map((id) => ({ id, text: `Line ${id}.`, para: 0, page: 1 })),
    paragraphs: [{ id: 0, sentenceIds: ids, page: 1 }],
  })
  hangSynth = true
  try {
    player.play()
    await settle()
    player.seekTo(30)
    await settle()
    // Sentence 30 must not wait behind 0 and its look-ahead in the backend queue.
    assert.deepEqual([...abortedTexts].sort(), ['Line 0.', 'Line 1.', 'Line 2.'])

    abortedTexts = []
    for (let k = 0; k < 8; k++) player.next()
    await settle()
    assert.equal(state().currentSentence, 38)
    // Every sentence stepped over is dropped; the landing one and its look-ahead stay.
    assert.deepEqual(
      [...abortedTexts].sort((a, b) => parseInt(a.slice(5)) - parseInt(b.slice(5))),
      ['Line 30.', 'Line 31.', 'Line 32.', 'Line 33.', 'Line 34.', 'Line 35.', 'Line 36.', 'Line 37.'],
    )
  } finally {
    player.stop()
  }
})

test('H031: a step while paused drops the requests for the sentence it leaves', async () => {
  hangSynth = true
  try {
    player.next() // paused: cues sentence 1 and warms 2 and 3
    await settle()
    player.next()
    player.next()
    await settle()
    assert.equal(state().currentSentence, 3)
    assert.deepEqual([...abortedTexts].sort(), ['Sentence number 1.', 'Sentence number 2.'])
  } finally {
    player.stop()
  }
})

test('H036: Play at the end listens again from the first sentence, not the last one again', async () => {
  try {
    player.play()
    for (let i = 0; i < doc.sentences.length; i++) {
      await settle()
      assert.equal(state().currentSentence, i)
      assert.equal(state().status, 'playing')
      // A finished clip reports ended, which turns the resume-in-place check off.
      audioEl!.ended = i === doc.sentences.length - 1
      audioEl!.dispatchEvent(new Event('ended'))
    }
    assert.equal(state().status, 'ended')
    assert.equal(state().currentSentence, 3)

    player.toggle() // the Play button, Space
    assert.equal(state().currentSentence, 0, 'replayed only the last sentence')
    await settle()
    assert.equal(state().currentSentence, 0)
    assert.equal(state().status, 'playing')
  } finally {
    audioEl!.ended = false
    player.stop()
  }
})

/** The browser or the OS pauses or resumes the element, not the player (J036). */
function pauseFromOutside() {
  audioEl!.paused = true
  audioEl!.dispatchEvent(new Event('pause'))
}
function resumeFromOutside() {
  audioEl!.paused = false
  audioEl!.dispatchEvent(new Event('play'))
}

/** Let the held /synthesize answers through, and stop holding new ones. */
function releaseSynth() {
  const held = heldSynth ?? []
  heldSynth = null
  for (const release of held) release()
}

test('J036: the ⏯ key and the browser media controls go through the player', async () => {
  try {
    player.play()
    await settle()
    for (const action of ['play', 'pause', 'nexttrack', 'previoustrack']) {
      assert.equal(typeof mediaActions.get(action), 'function', `no ${action} handler`)
    }
    mediaActions.get('pause')!()
    assert.equal(state().status, 'paused')
    assert.equal(audioEl!.paused, true)
    mediaActions.get('play')!()
    await settle()
    assert.equal(state().status, 'playing')
    assert.equal(audioEl!.paused, false)
    mediaActions.get('nexttrack')!()
    await settle()
    assert.equal(state().currentSentence, 1)
    mediaActions.get('previoustrack')!()
    await settle()
    assert.equal(state().currentSentence, 0)
    assert.equal(state().status, 'playing')

    // A dropped PDF parsing behind the loading view: the keys are off, as Space is.
    mediaActions.get('pause')!()
    state().setStatus('loading')
    mediaActions.get('play')!()
    mediaActions.get('nexttrack')!()
    await settle()
    assert.equal(state().status, 'loading')
    assert.equal(state().currentSentence, 0)
    assert.equal(audioEl!.paused, true)
  } finally {
    player.stop()
  }
})

test('J036: a pause from outside the player shows as paused, and one press plays again', async () => {
  try {
    player.play()
    await settle()
    assert.equal(state().status, 'playing')
    pauseFromOutside()
    assert.equal(state().status, 'paused', 'the bar still says playing over silence')
    player.toggle() // the Play button, Space
    await settle()
    assert.equal(state().status, 'playing')
    assert.equal(audioEl!.paused, false, 'the first press did nothing audible')
  } finally {
    player.stop()
  }
})

test('J036: a resume from outside the player plays on into the next sentence', async () => {
  try {
    player.play()
    await settle()
    player.pause()
    resumeFromOutside()
    assert.equal(state().status, 'playing', 'the bar says paused over audio')
    audioEl!.dispatchEvent(new Event('ended'))
    await settle()
    assert.equal(state().currentSentence, 1, 'reading stopped after one sentence')
    assert.equal(state().status, 'playing')
  } finally {
    player.stop()
  }
})

test('J036: the player’s own pauses and a clip running out are not taken for outside ones', async () => {
  try {
    player.play()
    await settle()
    // Moving on pauses the element; its pause event can land before the next clip.
    player.seekTo(2)
    pauseFromOutside()
    await settle()
    assert.equal(state().currentSentence, 2)
    assert.equal(state().status, 'playing')
    player.next()
    pauseFromOutside()
    await settle()
    assert.equal(state().currentSentence, 3)
    assert.equal(state().status, 'playing')

    // A clip that ran out says pause, then ended.
    player.seekTo(0)
    await settle()
    audioEl!.ended = true
    pauseFromOutside()
    assert.equal(state().status, 'playing')
    audioEl!.dispatchEvent(new Event('ended'))
    audioEl!.ended = false
    await settle()
    assert.equal(state().currentSentence, 1)
    assert.equal(state().status, 'playing')
  } finally {
    audioEl!.ended = false
    player.stop()
  }
})

test('J036: an outside resume while a dropped PDF parses keeps the book held', async () => {
  try {
    player.play()
    await settle()
    player.pause()
    state().setStatus('loading')
    resumeFromOutside()
    assert.equal(state().status, 'loading')
    assert.equal(audioEl!.paused, true)
  } finally {
    player.stop()
  }
})

/** Drop b.pdf on the open book (as App does), with a parse that waits for the test. */
async function dropWhileBuffering() {
  const { openPdf } = await import('../src/lib/intake.ts')
  const next = { ...doc, title: 'Next' }
  let finishParse!: (parsed: typeof doc) => void
  const opening = openPdf({ name: 'b.pdf', type: 'application/pdf' } as File, {
    loadPdf: () => new Promise((resolve) => (finishParse = resolve)),
    player,
  })
  assert.equal(state().status, 'loading')
  return { next, opening, finish: () => finishParse(next) }
}

test('J038: a sentence still buffering when a PDF is dropped leaves the loading view up', async () => {
  state().setDoc(doc)
  heldSynth = []
  player.play()
  await settle()
  assert.equal(state().status, 'buffering')
  const drop = await dropWhileBuffering()
  releaseSynth() // the open book's clip lands while the drop parses
  await settle()
  assert.equal(state().status, 'loading', 'the old book came back over the loading view')
  assert.equal(audioEl!.paused, true)
  drop.finish()
  await drop.opening
  assert.equal(state().doc, drop.next)
  assert.equal(state().status, 'ready')
  player.stop()
})

test('J038: an unreadable buffering sentence is not skipped over the loading view', async () => {
  state().setDoc(doc)
  unreadable = new Set(['Sentence number 0.'])
  heldSynth = []
  player.play()
  await settle()
  const drop = await dropWhileBuffering()
  releaseSynth()
  await settle()
  assert.equal(state().status, 'loading')
  assert.deepEqual(state().skippedSentences, [])
  drop.finish()
  await drop.opening
  player.stop()
})

test('J038: the engine going down while a sentence buffers does not replace the loading view', async () => {
  state().setDoc(doc)
  backendDown = true
  player.play()
  await settle()
  const drop = await dropWhileBuffering()
  await outlastRetries()
  await settle()
  assert.equal(state().status, 'loading')
  assert.equal(state().error, null)
  drop.finish()
  await drop.opening
  player.stop()
})

test('J038: Play after a pause while buffering plays the clip that landed, without asking again', async () => {
  try {
    heldSynth = []
    player.play()
    await settle()
    assert.equal(state().status, 'buffering')
    player.pause()
    releaseSynth()
    await settle()
    assert.equal(state().status, 'paused')
    player.play()
    await settle()
    assert.equal(state().status, 'playing')
    assert.equal(state().currentSentence, 0)
    assert.equal(synthBodies.filter((b) => b.text === 'Sentence number 0.').length, 1)
  } finally {
    player.stop()
  }
})

test('K013: the media session hears a buffering sentence as playing, so the ⏯ key pauses it', async () => {
  const { mediaPlaybackState } = await import('../src/lib/player.ts')
  const session = (globalThis.navigator as unknown as { mediaSession: { playbackState?: string } })
    .mediaSession
  const own = player.play
  try {
    player.play()
    await settle()
    assert.equal(state().status, 'playing')
    assert.equal(session.playbackState, 'playing')

    // A seek pauses the element while the next sentence synthesizes. Left to
    // judge by the element, the browser sends play for the ⏯ key.
    heldSynth = []
    player.seekTo(3)
    await settle()
    assert.equal(state().status, 'buffering')
    assert.equal(audioEl!.paused, true)
    assert.equal(session.playbackState, 'playing', 'the browser takes the buffering sentence for paused')

    // A Play from a hub or a headset meanwhile leaves the sentence on its way.
    let plays = 0
    player.play = () => {
      plays++
      own.call(player)
    }
    mediaActions.get('play')!()
    assert.equal(plays, 0, 'play() asked for the buffering sentence again')
    player.play = own

    mediaActions.get('pause')!()
    assert.equal(state().status, 'paused')
    assert.equal(session.playbackState, 'paused')
    releaseSynth()
    await settle()
    assert.equal(state().status, 'paused', 'the sentence played through the pause')
    assert.equal(audioEl!.paused, true)

    player.stop()
    assert.equal(session.playbackState, 'none')
    for (const status of ['ready', 'paused', 'ended', 'error', 'loading'] as const) {
      assert.equal(mediaPlaybackState(status), 'paused', status)
    }
  } finally {
    player.play = own
    releaseSynth()
    player.stop()
  }
})
