// The content script's wiring: listening before the first await (F065),
// noticing an app's own pushState navigation (F071) and hash routes and swapped
// text (G020), standing down for a reader injected after a reload (G019), and
// a shortcut's subframe selection and PDF hint (G034).
import assert from 'node:assert/strict'
import { test } from 'node:test'
import {
  DEFAULT_TEST_PREFS,
  FakeDocument,
  FakeText,
  h,
  installPlaybackGlobals,
  load,
  NodeTypes,
  wavBase64,
} from './harness.mjs'

test('F065: a command sent the moment injection returns is answered, not dropped', async () => {
  const listeners = []
  let releasePrefs
  const prefsPending = new Promise((resolve) => (releasePrefs = resolve))

  const win = new EventTarget()
  win.location = { pathname: '/article', search: '' }
  win.getSelection = () => null
  globalThis.window = win
  globalThis.document = new EventTarget()
  globalThis.chrome = {
    runtime: {
      onMessage: { addListener: (fn) => listeners.push(fn) },
      sendMessage: () => Promise.resolve(undefined),
    },
    storage: {
      // The first storage read of a session is the slow part of boot.
      sync: { get: () => prefsPending },
      local: { get: () => Promise.resolve({}) },
      onChanged: { addListener: () => {} },
    },
  }

  await load('content/index.ts')
  // executeScript has returned; the worker's message can arrive right now.
  assert.equal(listeners.length, 1, 'no onMessage listener yet: Chrome drops the command')

  const replies = []
  const keepOpen = listeners[0]({ kind: 'ping' }, {}, (r) => replies.push(r))
  assert.equal(keepOpen, true, 'the reply channel must stay open until the reader is ready')
  assert.deepEqual(replies, [])

  releasePrefs({ 'aloud.prefs.v1': DEFAULT_TEST_PREFS })
  await new Promise((r) => setTimeout(r, 20))
  assert.deepEqual(replies, [{ kind: 'pong' }])

  // Once ready, messages are answered on the spot.
  const later = []
  assert.equal(listeners[0]({ kind: 'ping' }, {}, (r) => later.push(r)), false)
  assert.deepEqual(later, [{ kind: 'pong' }])
})

test('F071: an app navigating with pushState ends the reading; replaceState does not', async () => {
  const { watchNavigation } = await load('content/navigation.ts')
  const host = new EventTarget()
  host.location = { pathname: '/posts/one', search: '' }
  host.navigation = new EventTarget()
  let left = 0
  watchNavigation(host, () => left++)

  const entryChange = (navigationType) => {
    const e = new Event('currententrychange')
    e.navigationType = navigationType
    host.navigation.dispatchEvent(e)
  }

  // A site tidying its own address (tracking parameters) is not a move.
  host.location.search = '?utm_source=feed'
  entryChange('replace')
  assert.equal(left, 0)

  // history.pushState to the next article: no popstate, no hashchange.
  host.location = { pathname: '/posts/two', search: '' }
  entryChange('push')
  assert.equal(left, 1)

  // Back to the first article fires popstate too; the move is reported once.
  host.location = { pathname: '/posts/one', search: '?utm_source=feed' }
  entryChange('traverse')
  host.dispatchEvent(new Event('popstate'))
  assert.equal(left, 2)
})

test('G020: a hash-routed app moving to another article ends the reading', async () => {
  const { watchNavigation } = await load('content/navigation.ts')
  const host = new EventTarget()
  host.location = { pathname: '/', search: '', hash: '#/quickstart' }
  host.navigation = new EventTarget()
  let left = 0
  watchNavigation(host, () => left++)
  const go = (hash) => {
    host.location.hash = hash
    const e = new Event('currententrychange')
    e.navigationType = 'push'
    host.navigation.dispatchEvent(e)
    host.dispatchEvent(new Event('hashchange'))
  }

  go('#/quickstart?id=install') // docsify's in-page anchor: same article
  assert.equal(left, 0)
  go('#/configuration')
  assert.equal(left, 1)
  go('#!/legacy/route')
  assert.equal(left, 2)

  // An ordinary page's anchors are not routes.
  const plain = new EventTarget()
  plain.location = { pathname: '/post', search: '', hash: '#intro' }
  let plainLeft = 0
  watchNavigation(plain, () => plainLeft++)
  plain.location.hash = '#comments'
  plain.dispatchEvent(new Event('hashchange'))
  assert.equal(plainLeft, 0)
})

test('G020: text swapped out inside a container the page keeps is noticed', async () => {
  const { spanDetached } = await load('content/extract.ts')
  const first = new FakeText('The old article. ')
  const second = new FakeText('Its second sentence.')
  const article = h('article', {}, h('p', {}, first), h('p', {}, second))
  new FakeDocument({ body: h('body', {}, article) })
  const slices = [
    { node: first, nodeStart: 0, start: 0, end: 17 },
    { node: second, nodeStart: 0, start: 17, end: 37 },
  ]
  assert.equal(spanDetached(slices, 17, 37), false)

  // innerHTML on the container: its old children go, the container stays.
  for (const child of article.childNodes) child.parentNode = null
  article.childNodes = []
  article.append(h('p', {}, 'The new article.'))
  assert.equal(article.isConnected, true)
  assert.equal(spanDetached(slices, 17, 37), true)
  assert.equal(spanDetached([], 0, 10), false, 'plain text read without a DOM')
})

// ── a booted reader ──────────────────────────────────────────────────────────

/** A DOM node that accepts anything — enough for the bar and toasts — and records text set on it. */
function anyNode(written) {
  const node = new Proxy(function () {}, {
    get(_t, key) {
      if (key === 'then') return undefined
      if (key === Symbol.toPrimitive) return () => ''
      if (key === Symbol.iterator) return function* () {}
      return node
    },
    set(_t, key, value) {
      if (key === 'textContent' && typeof value === 'string') written.push(value)
      return true
    },
    apply: () => node,
    construct: () => node,
  })
  return node
}

/** A page of nothing in particular, which `document` events really reach. */
function anyDocument(written) {
  const doc = new EventTarget()
  const node = () => anyNode(written)
  return Object.assign(doc, {
    contentType: 'text/html',
    createElement: node,
    createRange: node,
    documentElement: node(),
    head: node(),
    body: node(),
    getElementById: () => null,
    activeElement: null,
  })
}

/** Install a silent page around `doc`; `boot()` injects the content script into it. */
function page(doc) {
  const listeners = []
  const win = new EventTarget()
  Object.assign(win, {
    location: { pathname: '/article', search: '', hash: '' },
    getSelection: () => null,
    setTimeout,
    clearTimeout,
    setInterval,
    clearInterval,
  })
  globalThis.window = win
  globalThis.document = doc
  globalThis.Node = NodeTypes
  installPlaybackGlobals({
    runtime: {
      id: 'test',
      onMessage: { addListener: (fn) => listeners.push(fn) },
      sendMessage: (msg) =>
        Promise.resolve(msg.kind === 'synth' ? { kind: 'synth', ok: true, audio: wavBase64() } : undefined),
    },
    storage: {
      sync: { get: () => Promise.resolve({ 'aloud.prefs.v1': DEFAULT_TEST_PREFS }) },
      local: { get: () => Promise.resolve({}) },
      onChanged: { addListener: () => {} },
    },
  })
  return {
    win,
    /** Inject a reader and return a function that messages it. */
    async boot() {
      const at = listeners.length
      await load('content/index.ts')
      await new Promise((r) => setTimeout(r, 20))
      return (msg) => new Promise((resolve) => listeners[at](msg, {}, resolve))
    },
  }
}

test('G019: a reader injected after a reload stops the orphan left from before it', async () => {
  const p = page(anyDocument([]))
  const orphan = await p.boot()
  await orphan({ kind: 'command', action: 'start-selection', text: 'One sentence here. Another one there.' })
  assert.equal((await orphan({ kind: 'state' })).state.active, true)

  // The reloaded extension's script runs in a fresh isolated world: the
  // window-level guard is unset there, and the orphan can't be messaged.
  delete p.win.__aloudReaderInjected
  const fresh = await p.boot()
  try {
    assert.equal((await orphan({ kind: 'state' })).state.active, false, 'two readers on one page')

    // The newcomer never hears its own announcement.
    await fresh({ kind: 'command', action: 'start-selection', text: 'Reading again now.' })
    assert.equal((await fresh({ kind: 'state' })).state.active, true)
  } finally {
    // Our side door, not the page's: keeps a failure from leaving audio timers running.
    await orphan({ kind: 'command', action: 'stop' })
    await fresh({ kind: 'command', action: 'stop' })
  }
})

test('G034: the shortcut reads a selection the worker found in a subframe', async () => {
  const p = page(anyDocument([]))
  const reader = await p.boot()
  await reader({ kind: 'command', action: 'toggle', text: 'A paragraph selected inside the frame.' })
  const { state } = await reader({ kind: 'state' })
  assert.equal(state.active, true)
  assert.equal(state.title, 'Selection')
  await reader({ kind: 'command', action: 'stop' })
})

test('G034: the PDF message points to the context menu that can read a selection', async () => {
  const written = []
  const doc = new FakeDocument({
    contentType: 'application/pdf',
    body: h('body', {}, h('embed', { type: 'application/pdf' })),
  })
  doc.documentElement.appendChild = () => {}
  Object.assign(doc, {
    createElement: () => anyNode(written),
    addEventListener() {},
    dispatchEvent: () => true,
  })
  const p = page(doc)
  p.win.getSelection = () => ({ isCollapsed: true, rangeCount: 0 }) // nothing selected up here
  const reader = await p.boot()
  // Toast timers are seconds long; they must not hold the test run open.
  const realSetTimeout = globalThis.setTimeout
  globalThis.setTimeout = (fn, ms, ...args) => {
    const t = realSetTimeout(fn, ms, ...args)
    if (ms >= 1000) t.unref?.()
    return t
  }
  try {
    await reader({ kind: 'command', action: 'toggle' })
  } finally {
    globalThis.setTimeout = realSetTimeout
  }
  const toast = written.find((t) => /PDF/.test(t))
  assert.ok(toast, `no PDF message among ${JSON.stringify(written)}`)
  assert.match(toast, /Read selection aloud/)
})
