// Playback failures: a play() the browser refuses (F011), an engine that is
// down or failing (F064), and an extension reloaded under the page (F068,
// G019); sentences with nothing to say or that the engine refuses (G017), and
// failures on either side of a move the user made (G018).
// Silent throughout: Audio is a fake and the worker is a scripted mock.
import assert from 'node:assert/strict'
import { afterEach, test } from 'node:test'
import {
  DEFAULT_TEST_PREFS,
  FakeAudio,
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
  const seen = { statuses: [], skips: [] }
  const player = new AloudPlayer({
    prefs: () => prefs,
    onStatus: (status, error) => seen.statuses.push({ status, error }),
    onSentence: () => {},
    onWord: () => {},
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
