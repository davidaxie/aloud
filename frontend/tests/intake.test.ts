// G015: a PDF dropped on an open book is parsed before the book is closed, so
// an unreadable drop (scanned, locked, corrupt) keeps the book and the place
// in it. H029: a parse abandoned with 'New' never opens over what came next.
// Stub parser and player: no pdf.js, no audio.
import './support/hooks.mjs'
import { beforeEach, test } from 'node:test'
import assert from 'node:assert/strict'

const { cancelPdfIntake, openPdf } = await import('../src/lib/intake.ts')
const { useStore } = await import('../src/store.ts')

const state = () => useStore.getState()

function makeDoc(title: string, count: number) {
  const ids = Array.from({ length: count }, (_, id) => id)
  return {
    title,
    pageCount: 1,
    sentences: ids.map((id) => ({ id, text: `${title} ${id}.`, para: 0, page: 1 })),
    paragraphs: [{ id: 0, sentenceIds: ids, page: 1 }],
  }
}

const SCANNED = 'No readable text found in this PDF. It may be a scanned document (images only).'

function stubPlayer() {
  const calls: string[] = []
  return {
    calls,
    load: () => {
      calls.push('load')
    },
    pause: () => {
      calls.push('pause')
      state().setStatus('paused')
    },
    stop: () => {
      calls.push('stop')
    },
  }
}

const file = (name: string) => ({ name, type: 'application/pdf' }) as File

beforeEach(() => {
  state().reset()
})

test('G015: an unreadable PDF dropped on an open book leaves the book and its place', async () => {
  const book = makeDoc('Book', 1000)
  state().setDoc(book)
  state().setFileName('book.pdf')
  state().setCurrentSentence(400)
  state().setStatus('playing')
  const player = stubPlayer()

  await openPdf(file('scan.pdf'), {
    loadPdf: async () => {
      throw new Error(SCANNED)
    },
    player,
  })

  assert.equal(state().doc, book)
  assert.equal(state().fileName, 'book.pdf')
  assert.equal(state().currentSentence, 400)
  assert.equal(state().status, 'paused')
  assert.match(state().error ?? '', /Could not read that PDF/)
  assert.deepEqual(player.calls, ['pause'], 'the open book is never stopped')
})

test('G015: a readable PDF replaces the open book once it has parsed', async () => {
  state().setDoc(makeDoc('Book', 10))
  state().setFileName('book.pdf')
  state().setCurrentSentence(4)
  state().setStatus('paused')
  const next = makeDoc('Next', 3)
  const player = stubPlayer()
  let stoppedBeforeParse = false

  await openPdf(file('next.pdf'), {
    loadPdf: async () => {
      stoppedBeforeParse = player.calls.includes('stop')
      return next
    },
    player,
  })

  assert.equal(stoppedBeforeParse, false)
  assert.equal(state().doc, next)
  assert.equal(state().fileName, 'next.pdf')
  assert.equal(state().status, 'ready')
  assert.deepEqual(player.calls, ['stop', 'load'])
})

test('G015: with nothing open, an unreadable PDF shows the error on the empty state', async () => {
  await openPdf(file('scan.pdf'), {
    loadPdf: async () => {
      throw new Error(SCANNED)
    },
    player: stubPlayer(),
  })
  assert.equal(state().doc, null)
  assert.equal(state().fileName, null)
  assert.equal(state().status, 'error')
  assert.match(state().error ?? '', /scanned/)
})

/** A parse that finishes when the test says so, and the signal it was given. */
function deferredParse() {
  let resolve!: (doc: ReturnType<typeof makeDoc>) => void
  let reject!: (err: Error) => void
  let signal: AbortSignal | undefined
  let progress!: (p: number) => void
  const loadPdf = (_file: File, onProgress: (p: number) => void, s: AbortSignal) => {
    signal = s
    progress = onProgress
    return new Promise<ReturnType<typeof makeDoc>>((res, rej) => {
      resolve = res
      reject = rej
    })
  }
  return {
    loadPdf,
    resolve: (doc: ReturnType<typeof makeDoc>) => resolve(doc),
    reject: (err: Error) => reject(err),
    progress: (p: number) => progress(p),
    get signal() {
      return signal
    },
  }
}

/** What App's 'New' button does (handleReset). */
function pressNew(player: { stop(): void }) {
  cancelPdfIntake()
  player.stop()
  state().reset()
}

test('H029: a parse abandoned with New does not open over the book opened since', async () => {
  state().setDoc(makeDoc('X', 10))
  state().setFileName('x.pdf')
  state().setStatus('paused')
  const player = stubPlayer()
  const slow = deferredParse()

  const first = openPdf(file('a.pdf'), { loadPdf: slow.loadPdf, player })
  assert.equal(state().status, 'loading')
  pressNew(player)
  assert.equal(slow.signal?.aborted, true, 'the abandoned parse is told to stop')

  const b = makeDoc('B', 5)
  await openPdf(file('b.pdf'), { loadPdf: async () => b, player })
  state().setCurrentSentence(3)
  state().setStatus('playing')

  slow.progress(0.9)
  slow.resolve(makeDoc('A', 1000))
  await first

  assert.equal(state().doc, b)
  assert.equal(state().fileName, 'b.pdf')
  assert.equal(state().currentSentence, 3)
  assert.equal(state().status, 'playing')
  assert.deepEqual(player.calls, ['stop', 'load'], 'A is never loaded, B never stopped for it')
})

test('H029: an abandoned parse that fails raises no error over the next book', async () => {
  state().setDoc(makeDoc('X', 10))
  state().setFileName('x.pdf')
  state().setStatus('paused')
  const player = stubPlayer()
  const slow = deferredParse()

  const first = openPdf(file('a.pdf'), { loadPdf: slow.loadPdf, player })
  pressNew(player)
  const b = makeDoc('B', 5)
  await openPdf(file('b.pdf'), { loadPdf: async () => b, player })
  state().setStatus('playing')

  slow.reject(new Error(SCANNED))
  await first

  assert.equal(state().doc, b)
  assert.equal(state().fileName, 'b.pdf')
  assert.equal(state().status, 'playing')
  assert.equal(state().error, null)
})

test('H029: New during a parse with nothing opened after leaves the empty state', async () => {
  const player = stubPlayer()
  const slow = deferredParse()
  const first = openPdf(file('a.pdf'), { loadPdf: slow.loadPdf, player })
  pressNew(player)
  slow.resolve(makeDoc('A', 3))
  await first
  assert.equal(state().doc, null)
  assert.equal(state().status, 'idle')
  assert.equal(state().loadProgress, 0)
})
