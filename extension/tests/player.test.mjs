// Playback failures: a play() the browser refuses (F011), an engine that is
// down or failing (F064), and an extension reloaded under the page (F068,
// G019); sentences with nothing to say or that the engine refuses (G017), and
// failures on either side of a move the user made (G018); Play at the end
// listening again (H036), and a far seek or a quick run of steps not stuck
// behind old look-ahead (H038, H031); pauses and media keys from outside the
// reader (K005, K007), and the word lit being the one heard on Web Audio (K011).
// Silent throughout: Audio is a fake and the worker is a scripted mock.
import assert from 'node:assert/strict'
import { afterEach, test } from 'node:test'
import {
  DEFAULT_TEST_PREFS,
  FakeAudio,
  FakeAudioContext,
  installPlaybackGlobals,
  load,
  until,
  wavBase64,
} from './harness.mjs'

const { AloudPlayer } = await load('content/player.ts')
const api = await load('content/api.ts')

const SENTENCES = [
  'The headline of the article.',
  'The opening sentence that sets the scene.',
  'The second sentence that adds context.',
  'A fourth sentence.',
  'A fifth sentence.',
  'A sixth sentence.',
]

function doc(sentences = SENTENCES) {
  return {
    title: 'Test',
    sentences: sentences.map((text, id) => ({
      id, raw: text, text, start: 0, end: text.length,
      tokens: [{ text, isWord: true, weight: 1 }],
    })),
  }
}

/** A worker stand-in. `synth(msg)` decides each synthesis reply; every call is logged. */
function worker(synth) {
  const calls = []
  return {
    calls,
    chrome: {
      runtime: {
        id: 'test',
        sendMessage(msg) {
          calls.push(msg)
          if (msg.kind === 'synth') return synth(msg)
          if (msg.kind === 'abort') return Promise.resolve(undefined)
          return Promise.resolve(undefined)
        },
      },
    },
  }
}

const OK = () => Promise.resolve({ kind: 'synth', ok: true, audio: wavBase64() })
const fail = (status, retryable) => () =>
  Promise.resolve({ kind: 'synth', ok: false, error: 'nope', aborted: false, retryable, status, retryAfterMs: null })

function rig(synth, { prefs = DEFAULT_TEST_PREFS, sentences = SENTENCES } = {}) {
  const w = worker(synth)
  installPlaybackGlobals(w.chrome)
  const seen = { statuses: [], skips: [], words: [] }
  const player = new AloudPlayer({
    prefs: () => prefs,
    onStatus: (status, error) => seen.statuses.push({ status, error }),
    onSentence: () => {},
    onWord: (index) => seen.words.push(index),
    onSkip: (index, message) => seen.skips.push({ index, message }),
    onBuffer: () => {},
  })
  player.load(doc(sentences))
  return { player, seen, w, last: () => seen.statuses.at(-1) }
}

let current = null
afterEach(() => {
  current?.player.stop() // clears the fill interval and the word loop
  current = null
  FakeAudio.play = () => Promise.resolve()
})

test('F011: an autoplay refusal pauses and asks for a click instead of "playing" silently', async () => {
  FakeAudio.play = () => Promise.reject(new DOMException('play() failed', 'NotAllowedError'))
  current = rig(OK)
  current.player.play()
  await until(() => current.last().status === 'paused', 3000, "status 'paused' (stuck at 'playing')")
  assert.match(current.last().error, /click play/i)
  assert.equal(current.player.currentIndex, 0)

  // The click on the bar unlocks audio: play resumes the same sentence.
  FakeAudio.play = () => Promise.resolve()
  current.player.play()
  assert.equal(current.player.status, 'playing')
  assert.equal(current.player.currentIndex, 0)
  assert.equal(current.last().error, null)
})

test('F011: a clip the browser cannot play is skipped, not waited on forever', async () => {
  let first = true
  FakeAudio.play = () => {
    if (!first) return Promise.resolve()
    first = false
    return Promise.reject(new DOMException('no supported source', 'NotSupportedError'))
  }
  current = rig(OK)
  current.player.play()
  await until(() => current.player.currentIndex === 1, 3000, 'advance past the bad clip')
  assert.deepEqual(current.seen.skips.map((s) => s.index), [0])
  assert.match(current.seen.skips[0].message, /browser couldn’t play/)
})

test('F011: an audio error event skips the loaded sentence exactly once', async () => {
  current = rig(OK)
  current.player.play()
  await until(() => current.player.status === 'playing', 3000, 'playing')
  FakeAudio.last.dispatchEvent(new Event('error'))
  await until(() => current.player.currentIndex === 1, 3000, 'advance past the errored clip')
  await new Promise((r) => setTimeout(r, 50))
  assert.deepEqual(current.seen.skips.map((s) => s.index), [0])
  assert.equal(current.player.currentIndex, 1)
})

test('F011/F061: a run of clips the browser cannot play stops instead of skipping the page', async () => {
  // Every clip synthesizes fine but none will play: the streak must survive the
  // successful syntheses, or the player skips through the whole page.
  FakeAudio.play = () => Promise.reject(new DOMException('no supported source', 'NotSupportedError'))
  current = rig(OK)
  current.player.play()
  await until(() => current.player.status === 'error', 3000, "status 'error' (skipped through the page)")
  assert.equal(current.seen.skips.length, 3)
  assert.equal(current.player.currentIndex, 0, 'stops where the run began')
  assert.equal(current.player.wasSkipped(0), false)
})

test('F011/F061: a clip that plays after a refused one clears the failure streak', async () => {
  // Two unplayable clips, then one that plays: the run is broken, so two more
  // failures later must not add up to a stop.
  const outcomes = ['bad', 'bad', 'ok', 'bad', 'bad']
  FakeAudio.play = () =>
    outcomes.shift() === 'bad'
      ? Promise.reject(new DOMException('no supported source', 'NotSupportedError'))
      : Promise.resolve()
  current = rig(OK)
  current.player.play()
  await until(() => current.player.currentIndex === 2 && current.player.status === 'playing', 3000, 'playing sentence 2')
  FakeAudio.last.dispatchEvent(new Event('ended'))
  await until(() => current.player.currentIndex === 5, 3000, 'advance past two more bad clips')
  assert.notEqual(current.player.status, 'error')
  assert.deepEqual(current.seen.skips.map((s) => s.index), [0, 1, 3, 4])
})

test('F064: an unreachable backend stops on the first sentence, and play resumes there', async () => {
  let up = false
  current = rig((msg) => (up ? OK(msg) : fail(0, true)(msg)))
  current.player.play()
  await until(() => current.player.status === 'error', 5000, "status 'error'")
  assert.equal(current.player.currentIndex, 0, 'skipped the headline on the way to the error')
  assert.equal(current.seen.skips.length, 0)
  assert.match(current.last().error, /unreachable/)

  up = true
  current.w.calls.length = 0
  current.player.play()
  await until(() => current.player.status === 'playing', 5000, 'playing again')
  const firstNow = current.w.calls.find((c) => c.kind === 'synth' && c.priority === 'now')
  assert.equal(firstNow.text, SENTENCES[0])
})

test('F064: a run of failing sentences stops where the run began', async () => {
  current = rig(fail(500, false))
  current.player.play()
  await until(() => current.player.status === 'error', 5000, "status 'error'")
  assert.equal(current.player.currentIndex, 0)
  assert.equal(current.player.wasSkipped(0), false)
  assert.equal(current.seen.skips.length, 3)
})

test('F068: a reloaded extension says refresh, not "start the backend"', async () => {
  const w = worker(() => {
    throw new Error('Extension context invalidated.')
  })
  installPlaybackGlobals(w.chrome)
  const statuses = []
  const player = new AloudPlayer({
    prefs: () => DEFAULT_TEST_PREFS,
    onStatus: (status, error) => statuses.push({ status, error }),
    onSentence: () => {},
    onWord: () => {},
    onSkip: () => {},
    onBuffer: () => {},
  })
  current = { player }
  player.load(doc())
  player.play()
  await until(() => player.status === 'error', 3000, "status 'error'")
  assert.equal(statuses.at(-1).error, api.RELOADED_MESSAGE)
  assert.equal(player.currentIndex, 0)
})

test('F068: getHealth tells a reloaded extension apart from an offline engine', async () => {
  installPlaybackGlobals({
    runtime: {
      sendMessage() {
        throw new Error('Extension context invalidated.')
      },
    },
  })
  assert.equal((await api.getHealth()).state, 'reloaded')

  installPlaybackGlobals({ runtime: { sendMessage: () => Promise.reject(new Error('Could not connect')) } })
  assert.equal((await api.getHealth()).state, 'offline')
})

test('F068: the bar puts the refresh message ahead of "offline"', async () => {
  const ui = await load('content/ui.ts')
  const line = ui.statusLine({
    status: 'error', index: 0, total: 3, title: 't', error: 'x', voices: [], voiceId: 'v',
    rate: 1, engine: 'reloaded', truncated: false, bufferAhead: 0, readyThrough: -1,
  })
  assert.equal(line.text, api.RELOADED_MESSAGE)
})

/** Synth replies by sentence text; anything unlisted synthesizes fine. */
const byText = (table) => (msg) => (table.get(msg.text) ?? OK)(msg)
const HELD = () => new Promise(() => {})
const synthTexts = (w) => w.calls.filter((c) => c.kind === 'synth').map((c) => c.text)

test('G017: a sentence with nothing left to say plays as silence and is never sent', async () => {
  // Skipping bracketed asides empties these three; the backend answers 400 for
  // empty text, so sending them stopped the reader on the first, every time.
  const sentences = ['Zero is fine.', '(Laughter.)', '(Applause.)', '(Music.)', 'Four is fine.']
  current = rig((msg) => (msg.text.trim() ? OK(msg) : fail(400, false)(msg)), {
    prefs: { ...DEFAULT_TEST_PREFS, skipSkippable: true },
    sentences,
  })
  current.player.play()
  await until(() => current.player.status === 'playing', 3000, 'playing sentence 0')
  FakeAudio.last.dispatchEvent(new Event('ended'))
  await until(
    () => current.player.currentIndex === 4 || current.player.status === 'error',
    3000,
    'sentence 4 or a stop',
  )
  await until(() => current.player.status !== 'buffering', 3000, 'sentence 4 to settle')
  assert.equal(current.player.status, 'playing', current.last().error ?? '')
  assert.equal(current.player.currentIndex, 4)
  assert.deepEqual(current.seen.skips, [])
  assert.ok(!synthTexts(current.w).includes(''), 'empty text was sent to the backend')
})

test('G017: a run of sentences the engine refuses stops past them, so play carries on', async () => {
  const refused = fail(400, false)
  current = rig(byText(new Map([[SENTENCES[1], refused], [SENTENCES[2], refused], [SENTENCES[3], refused]])))
  current.player.play()
  await until(() => current.player.status === 'playing', 3000, 'playing sentence 0')
  FakeAudio.last.dispatchEvent(new Event('ended'))
  await until(() => current.player.status === 'error', 3000, "status 'error'")
  assert.equal(current.player.currentIndex, 4, 'stopped on a sentence that will refuse again')
  for (const i of [1, 2, 3]) assert.equal(current.player.wasSkipped(i), true)

  current.player.play()
  await until(() => current.player.status === 'playing', 3000, 'playing again')
  assert.equal(current.player.currentIndex, 4)
})

test('G018: failures before a Next do not count toward a stop after it', async () => {
  const broken = fail(500, false)
  current = rig(
    byText(new Map([[SENTENCES[0], broken], [SENTENCES[1], broken], [SENTENCES[2], HELD], [SENTENCES[3], broken]])),
  )
  current.player.play()
  await until(() => current.player.currentIndex === 2, 3000, 'waiting on sentence 2')
  current.player.next()
  await until(() => current.player.currentIndex !== 3, 3000, 'leave sentence 3')
  await until(() => current.player.status !== 'buffering', 3000, 'settle')
  assert.equal(current.player.currentIndex, 4, 'sent back to before the Next')
  assert.equal(current.player.status, 'playing')
  assert.deepEqual(current.seen.skips.map((s) => s.index), [0, 1, 3])
})

test('G018: failures before a seek do not count toward a stop after it', async () => {
  const broken = fail(500, false)
  current = rig(
    byText(new Map([[SENTENCES[0], broken], [SENTENCES[1], broken], [SENTENCES[2], HELD], [SENTENCES[4], broken]])),
  )
  current.player.play()
  await until(() => current.player.currentIndex === 2, 3000, 'waiting on sentence 2')
  current.player.seekTo(4)
  await until(() => current.player.currentIndex === 5 || current.player.status === 'error', 3000, 'leave sentence 4')
  await until(() => current.player.status !== 'buffering', 3000, 'settle')
  assert.equal(current.player.currentIndex, 5, 'sent back to before the seek')
  assert.equal(current.player.status, 'playing')
})

test('G019: once the extension is reloaded, cached audio does not play on', async () => {
  current = rig(OK)
  current.player.play()
  await until(() => current.player.status === 'playing', 3000, 'playing sentence 0')
  // Sentence 1 is cached: nothing would have to reach the worker to play it.
  await until(() => synthTexts(current.w).includes(SENTENCES[1]), 3000, 'prefetch of sentence 1')
  await new Promise((r) => setTimeout(r, 20))
  let plays = 0
  FakeAudio.play = () => {
    plays++
    return Promise.resolve()
  }

  delete current.w.chrome.runtime.id // what Chrome does to an orphaned content script
  FakeAudio.last.dispatchEvent(new Event('ended'))
  await new Promise((r) => setTimeout(r, 20))
  assert.equal(plays, 0, 'the orphan kept playing its buffer')
  assert.equal(current.player.status, 'error')
  assert.equal(current.last().error, api.RELOADED_MESSAGE)

  current.player.play()
  assert.equal(plays, 0)
  assert.equal(current.player.status, 'error')
})

/** Another reader (the web app, another tab) keeps the backend's prefetch lane full. */
const busyPrefetch = (msg) => (msg.priority === 'prefetch' ? fail(429, true)(msg) : OK(msg))
const askedNow = (text) =>
  current.w.calls.some((c) => c.kind === 'synth' && c.priority === 'now' && c.text === text)

test('G032: look-ahead turned away as busy is asked again at now, not marked unreadable', async () => {
  current = rig(busyPrefetch)
  current.player.play()
  await until(() => current.player.status === 'playing', 3000, 'playing')
  // Sentence 0 ends while sentence 1's look-ahead is still being retried.
  FakeAudio.last.dispatchEvent(new Event('ended'))
  await until(
    () =>
      current.seen.skips.length > 0 ||
      (current.player.currentIndex === 1 && current.player.status === 'playing'),
    5000,
    'sentence 1 playing or skipped',
  )
  assert.deepEqual(current.seen.skips, [], 'a busy backend says nothing about the sentence')
  assert.equal(current.player.currentIndex, 1)
  assert.ok(askedNow(SENTENCES[1]), 'sentence 1 is asked for again in the now lane')
})

test('G032: busy look-ahead for a sentence paused while buffering is cued at now, not skipped', async () => {
  current = rig(busyPrefetch)
  current.player.play()
  await until(() => current.player.status === 'playing', 3000, 'playing')
  FakeAudio.last.dispatchEvent(new Event('ended'))
  current.player.pause()
  await until(
    () => current.seen.skips.length > 0 || askedNow(SENTENCES[1]),
    5000,
    'sentence 1 cued or skipped',
  )
  assert.deepEqual(current.seen.skips, [])
  assert.equal(current.player.status, 'paused')
  assert.equal(current.player.wasSkipped(1), false)

  current.player.play()
  await until(() => current.player.status === 'playing', 3000, 'playing again')
  assert.equal(current.player.currentIndex, 1)
})

test('H036: Play at "Finished" listens again from the first sentence, not the last one again', async () => {
  current = rig(OK, { sentences: SENTENCES.slice(0, 3) })
  current.player.play()
  for (let i = 0; i < 3; i++) {
    await until(() => current.player.currentIndex === i && current.player.status === 'playing', 3000, `playing ${i}`)
    FakeAudio.last.ended = true
    FakeAudio.last.dispatchEvent(new Event('ended'))
  }
  await until(() => current.player.status === 'ended', 3000, 'finished')
  assert.equal(current.player.currentIndex, 2)

  current.player.toggle() // the bar's Play, Alt+A
  assert.equal(current.player.currentIndex, 0, 'replayed only the last sentence')
  await until(() => current.player.status === 'playing', 3000, 'playing again')
  assert.equal(current.player.currentIndex, 0)
})

test('H038: a far seek aborts the old look-ahead and fetches ahead of the new place', async () => {
  const sentences = Array.from({ length: 40 }, (_, i) => `Sentence number ${i} of a long article goes here.`)
  // The backend works through `now` at once and sits on look-ahead.
  current = rig((msg) => (msg.priority === 'now' ? OK(msg) : HELD(msg)), { sentences })
  const prefetched = () => current.w.calls.filter((c) => c.kind === 'synth' && c.priority === 'prefetch')
  current.player.play()
  await until(() => current.player.status === 'playing', 3000, 'playing sentence 0')
  await until(() => prefetched().length >= 6, 3000, 'look-ahead in flight')
  const before = prefetched().length

  current.player.seekTo(30) // click-to-jump far down the page
  await until(() => current.player.currentIndex === 30 && current.player.status === 'playing', 3000, 'playing 30')
  await until(
    () => prefetched().slice(before).some((c) => c.text === sentences[31]),
    3000,
    'look-ahead for sentence 31 (the stale requests hold the whole in-flight budget)',
  )
  const aborted = current.w.calls.filter((c) => c.kind === 'abort').length
  assert.ok(aborted >= before, `only ${aborted} of ${before} stale requests aborted`)
})

const LONG = Array.from({ length: 40 }, (_, i) => `Sentence number ${i} of a long article goes here.`)

/** Sentence numbers whose synthesis requests were aborted, without repeats. */
function abortedSentences(w) {
  const textById = new Map(w.calls.filter((c) => c.kind === 'synth').map((c) => [c.id, c.text]))
  const ids = w.calls.filter((c) => c.kind === 'abort').map((c) => LONG.indexOf(textById.get(c.id)))
  return [...new Set(ids)].sort((a, b) => a - b)
}

test('H031: a step while playing drops the requests for the sentences it leaves', async () => {
  current = rig(HELD, { sentences: LONG }) // the backend sits on everything
  current.player.play()
  await until(() => current.player.status === 'buffering', 3000, 'buffering sentence 0')
  for (let k = 0; k < 4; k++) current.player.next()
  assert.equal(current.player.currentIndex, 4)
  // Sentence 4 must not wait behind 0–3 in the backend's queues.
  await until(() => abortedSentences(current.w).length >= 4, 3000, 'requests for 0–3 aborted')
  await new Promise((r) => setTimeout(r, 20))
  assert.deepEqual(abortedSentences(current.w), [0, 1, 2, 3])
})

test('H031: a step while paused drops the requests for the sentence it leaves', async () => {
  current = rig(HELD, { sentences: LONG })
  for (let k = 0; k < 5; k++) current.player.next() // each cues its sentence at `now`
  assert.equal(current.player.currentIndex, 5)
  assert.equal(current.player.status, 'ready')
  await until(() => abortedSentences(current.w).length >= 4, 3000, 'requests for 1–4 aborted')
  await new Promise((r) => setTimeout(r, 20))
  // The landing sentence and its look-ahead stay in flight.
  assert.deepEqual(abortedSentences(current.w), [1, 2, 3, 4])
})

test('J046: /health answering again clears an unreachable-engine stop to paused, on the same sentence', async () => {
  current = rig(fail(0, false))
  current.player.play()
  await until(() => current.player.status === 'error', 3000, "status 'error'")
  assert.match(current.last().error, /unreachable/)
  current.player.engineRecovered()
  assert.equal(current.player.status, 'paused')
  assert.equal(current.last().error, null)
  assert.equal(current.player.currentIndex, 0)

  // Any other error stays: it was never about the engine being down.
  current.player.stop()
  current = rig(fail(400, false))
  current.player.play()
  await until(() => current.player.status === 'error', 3000, "status 'error'")
  current.player.engineRecovered()
  assert.equal(current.player.status, 'error')
})

/** Chrome on a page whose CSP media-src leaves out blob: the element can load no clip. */
function refuseBlobMedia() {
  FakeAudio.play = (el) => {
    setTimeout(() => el.dispatchEvent(new Event('error')))
    return Promise.reject(new DOMException('Failed to load because no supported source was found.', 'NotSupportedError'))
  }
  globalThis.AudioContext = FakeAudioContext
  FakeAudioContext.last = null
}

/** The buffer source the Web Audio clip started most recently. */
async function startedSource(after = null) {
  await until(() => {
    const s = FakeAudioContext.last?.sources.at(-1)
    return s && s !== after && s.started && !s.stopped
  }, 3000, 'a Web Audio source to start')
  return FakeAudioContext.last.sources.at(-1)
}

test('J039: on a page whose CSP refuses blob: media, every sentence plays through Web Audio', async () => {
  refuseBlobMedia()
  try {
    current = rig(OK)
    current.player.play()
    const first = await startedSource()
    assert.equal(current.player.status, 'playing')
    assert.equal(current.player.currentIndex, 0)
    assert.deepEqual(current.seen.skips, [], 'a sentence was skipped as unplayable')

    first.onended() // the clip plays out
    const second = await startedSource(first)
    assert.equal(current.player.currentIndex, 1)
    assert.equal(second.buffer.length, 2400)
    assert.deepEqual(current.seen.skips, [])
    assert.equal(current.last().error, null)
  } finally {
    delete globalThis.AudioContext
  }
})

test('J039: a clip Web Audio cannot decode either is skipped once, and reading goes on', async () => {
  refuseBlobMedia()
  let first = true
  const synth = (msg) => {
    if (!first) return OK(msg)
    first = false
    return Promise.resolve({ kind: 'synth', ok: true, audio: Buffer.from('not a wav at all').toString('base64') })
  }
  try {
    current = rig(synth)
    current.player.play()
    await startedSource()
    assert.equal(current.player.currentIndex, 1)
    assert.deepEqual(current.seen.skips.map((s) => s.index), [0])
    assert.match(current.seen.skips[0].message, /browser couldn’t play/)
  } finally {
    delete globalThis.AudioContext
  }
})

test('J039: through Web Audio, speed keeps its pitch and pause resumes where it stopped', async () => {
  refuseBlobMedia()
  try {
    current = rig(OK, { prefs: { ...DEFAULT_TEST_PREFS, rate: 2 } })
    current.player.play()
    const node = await startedSource()
    // 2x is the clip stretched to half its length, not played an octave up.
    assert.equal(node.playbackRate.value, 1)
    assert.ok(Math.abs(node.buffer.length - 1200) <= 1, `${node.buffer.length} samples at 2x`)

    // A quarter of a 0.1 s clip heard at 2x: 0.05 s of it.
    FakeAudioContext.last.currentTime += 0.025
    current.player.pause()
    assert.equal(node.stopped, true)
    current.player.play()
    const resumed = await startedSource(node)
    assert.equal(current.player.currentIndex, 0)
    assert.ok(Math.abs(resumed.buffer.length - 600) <= 2, `resumed with ${resumed.buffer.length} samples left`)
  } finally {
    delete globalThis.AudioContext
  }
})

test('J039: the time stretch keeps the pitch and the loudness', async () => {
  const { timeStretch } = await load('content/stretch.ts')
  const rate = 24000
  const hz = 220
  const input = new Float32Array(rate)
  for (let i = 0; i < input.length; i++) input[i] = 0.5 * Math.sin((2 * Math.PI * hz * i) / rate)
  const rms = (a) => Math.sqrt(a.reduce((s, x) => s + x * x, 0) / a.length)
  for (const speed of [0.5, 1.5, 2, 3]) {
    const [out] = timeStretch([input], speed, rate)
    assert.ok(Math.abs(out.length - rate / speed) <= 1, `${speed}x: ${out.length} samples`)
    const mid = out.subarray(Math.floor(out.length * 0.1), Math.floor(out.length * 0.9))
    let crossings = 0
    for (let i = 1; i < mid.length; i++) if (mid[i - 1] < 0 !== mid[i] < 0) crossings++
    const heard = crossings / 2 / (mid.length / rate)
    assert.ok(Math.abs(heard - hz) / hz < 0.03, `${speed}x sounds at ${heard.toFixed(1)} Hz`)
    assert.ok(Math.abs(rms(mid) / rms(input) - 1) < 0.15, `${speed}x changed the loudness`)
  }
  assert.equal(timeStretch([input], 1, rate)[0], input)
})

// ── outside pauses and the page's media session (K005, K007) ──────────────────

const MEDIA_ACTIONS = ['play', 'pause', 'nexttrack', 'previoustrack']

/**
 * The page's media session, which the ⏯ key, Chrome's media controls and
 * headphone buttons reach. Node's own navigator has none.
 */
function mediaSession() {
  const handlers = new Map()
  Object.defineProperty(globalThis, 'navigator', {
    configurable: true,
    value: { mediaSession: { setActionHandler: (action, handler) => handlers.set(action, handler) } },
  })
  return handlers
}

/** Chrome or the OS pauses or resumes the element, not the player. */
function pauseFromOutside() {
  FakeAudio.last.paused = true
  FakeAudio.last.dispatchEvent(new Event('pause'))
}
function resumeFromOutside() {
  FakeAudio.last.paused = false
  FakeAudio.last.dispatchEvent(new Event('play'))
}

const playingAt = (i) => () => current.player.status === 'playing' && current.player.currentIndex === i

test('K005: the media keys go through the reader only while it reads, then back to the page', async () => {
  const keys = mediaSession()
  current = rig(OK)
  assert.equal(keys.size, 0, 'the page’s media keys were taken before reading began')
  current.player.play()
  await until(playingAt(0), 3000, 'playing')
  for (const action of MEDIA_ACTIONS) assert.equal(typeof keys.get(action), 'function', `no ${action} handler`)

  keys.get('nexttrack')()
  await until(playingAt(1), 3000, 'the next sentence')
  keys.get('previoustrack')()
  await until(playingAt(0), 3000, 'the previous sentence')
  keys.get('pause')()
  assert.equal(current.player.status, 'paused')
  assert.equal(FakeAudio.last.paused, true)
  for (const action of MEDIA_ACTIONS) assert.equal(keys.get(action), null, `paused, the reader kept ${action}`)

  current.player.play()
  await until(playingAt(0), 3000, 'playing again')
  assert.equal(typeof keys.get('pause'), 'function')
  current.player.stop()
  for (const action of MEDIA_ACTIONS) assert.equal(keys.get(action), null, `stopped, the reader kept ${action}`)
})

test('K007: a pause from outside the reader shows as paused, and one press plays again', async () => {
  mediaSession()
  current = rig(OK)
  current.player.play()
  await until(playingAt(0), 3000, 'playing')
  pauseFromOutside()
  assert.equal(current.player.status, 'paused', 'the bar still says playing over silence')
  current.player.toggle() // the bar's play button
  assert.equal(current.player.status, 'playing')
  assert.equal(FakeAudio.last.paused, false, 'the first press did nothing audible')
})

test('K007: a resume from outside the reader plays on into the next sentence', async () => {
  mediaSession()
  current = rig(OK)
  current.player.play()
  await until(playingAt(0), 3000, 'playing')
  current.player.pause()
  resumeFromOutside()
  assert.equal(current.player.status, 'playing', 'the bar says paused over audio')
  FakeAudio.last.dispatchEvent(new Event('ended'))
  await until(playingAt(1), 3000, 'reading on past the first sentence')
})

test('K007: the reader’s own pauses and a clip running out are not taken for outside ones', async () => {
  mediaSession()
  current = rig(OK)
  current.player.play()
  await until(playingAt(0), 3000, 'playing')
  // Moving on pauses the element; its pause event can land before the next clip.
  current.player.seekTo(2)
  pauseFromOutside()
  await until(playingAt(2), 3000, 'playing the sentence sought')
  current.player.next()
  pauseFromOutside()
  await until(playingAt(3), 3000, 'playing the next sentence')

  // A clip that ran out says pause, then ended.
  FakeAudio.last.ended = true
  pauseFromOutside()
  assert.equal(current.player.status, 'playing')
  FakeAudio.last.dispatchEvent(new Event('ended'))
  FakeAudio.last.ended = false
  await until(playingAt(4), 3000, 'reading on')
})

// ── the word heard on Web Audio (K011) ────────────────────────────────────────

test('K011: through Web Audio, the word lit is the one heard, not the one rendered', async () => {
  refuseBlobMedia()
  // Bluetooth headphones: the speaker trails the context's clock by 0.25 s.
  globalThis.AudioContext = class extends FakeAudioContext {
    outputLatency = 0.2
    baseLatency = 0.05
  }
  const second = () => Promise.resolve({ kind: 'synth', ok: true, audio: wavBase64(24000) })
  try {
    current = rig(second)
    const tokens = [
      { text: 'Hello', isWord: true, weight: 1 },
      { text: ' ', isWord: false, weight: 0 },
      { text: 'there.', isWord: true, weight: 1 },
    ]
    current.player.load({ title: 'Test', sentences: [{ id: 0, raw: 'Hello there.', text: 'Hello there.', start: 0, end: 12, tokens }] })
    current.player.play()
    const node = await startedSource()
    const lit = () => current.seen.words.at(-1)
    const ctx = FakeAudioContext.last

    // 0.6 s rendered of a 1 s clip is 0.35 s heard: still the first word.
    ctx.currentTime += 0.6
    await new Promise((r) => setTimeout(r, 60))
    assert.equal(lit(), 0, 'the highlight ran ahead of the voice')
    ctx.currentTime += 0.3
    await until(() => lit() === 2, 3000, 'the second word')

    // Pause resumes from what was rendered, which still plays out.
    current.player.pause()
    current.player.play()
    const resumed = await startedSource(node)
    assert.ok(Math.abs(resumed.started.offset - 0.9) < 1e-9, `resumed at ${resumed.started.offset}`)
  } finally {
    delete globalThis.AudioContext
  }
})
