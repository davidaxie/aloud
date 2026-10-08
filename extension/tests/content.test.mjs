// The content script's wiring: listening before the first await (F065),
// noticing an app's own pushState navigation (F071) and hash routes and swapped
// text (G020), standing down for a reader injected after a reload (G019), a
// shortcut's subframe selection and PDF hint (G034), its text-field selection
// (H032) and a selection after "Finished" (H036), and a bar the page cannot
// work (H033).
import assert from 'node:assert/strict'
import { test } from 'node:test'
import {
  DEFAULT_TEST_PREFS,
  FakeAudio,
  FakeDocument,
  FakeText,
  h,
  installPlaybackGlobals,
  load,
  NodeTypes,
  until,
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
  // The reload took the orphan's extension away: Chrome cleared its runtime id
  // (L047: only such a reader stands down).
  const runtime = globalThis.chrome.runtime
  const id = runtime.id
  delete runtime.id
  const fresh = await p.boot()
  runtime.id = id
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
  p.win.getSelection = () => ({ isCollapsed: true, rangeCount: 0, toString: () => '' }) // nothing selected up here
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

/** Seconds-long toast timers must not hold the test run open. */
async function withShortTimers(fn) {
  const realSetTimeout = globalThis.setTimeout
  globalThis.setTimeout = (cb, ms, ...args) => {
    const t = realSetTimeout(cb, ms, ...args)
    if (ms >= 1000) t.unref?.()
    return t
  }
  try {
    return await fn()
  } finally {
    globalThis.setTimeout = realSetTimeout
  }
}

/** Poll the reader's state until `ok(state)`. */
async function untilState(reader, ok, what) {
  const deadline = Date.now() + 3000
  for (;;) {
    const { state } = await reader({ kind: 'state' })
    if (ok(state)) return state
    if (Date.now() > deadline) throw new Error(`timed out waiting for ${what}: ${JSON.stringify(state)}`)
    await new Promise((r) => setTimeout(r, 5))
  }
}

test('H032: the shortcut reads text selected in a text field, not the whole page', async () => {
  const written = []
  // No prose on the page: reading it would end in "No readable text found".
  const doc = new FakeDocument({ body: h('body', {}, h('form', {}, h('textarea', {}, 'Draft'))) })
  doc.documentElement.appendChild = () => {}
  Object.assign(doc, {
    createElement: () => anyNode(written),
    createRange: () => anyNode(written),
    getElementById: () => null,
    addEventListener() {},
    dispatchEvent: () => true,
  })
  const p = page(doc)
  // What Chrome reports for a selection inside a <textarea>: collapsed, words in toString().
  p.win.getSelection = () => ({
    isCollapsed: true,
    rangeCount: 1,
    getRangeAt: () => ({ toString: () => '' }),
    toString: () => 'Please proofread this sentence for me.',
  })
  const reader = await p.boot()
  await withShortTimers(() => reader({ kind: 'command', action: 'toggle' }))
  try {
    const { state } = await reader({ kind: 'state' })
    assert.equal(state.active, true, `not reading; said ${JSON.stringify(written)}`)
    assert.equal(state.title, 'Selection')
  } finally {
    await reader({ kind: 'command', action: 'stop' })
  }
})

test('H036: after "Finished", the shortcut reads text selected further on', async () => {
  const p = page(anyDocument([]))
  const reader = await p.boot()
  try {
    await reader({ kind: 'command', action: 'start-selection', text: 'The first sentence. The last sentence.' })
    for (let i = 0; i < 2; i++) {
      await untilState(reader, (s) => s.index === i && s.status === 'playing', `playing ${i}`)
      FakeAudio.last.ended = true
      FakeAudio.last.dispatchEvent(new Event('ended'))
    }
    await untilState(reader, (s) => s.status === 'ended', 'finished')

    // The truncated page's advice: select later text and go on.
    p.win.getSelection = () => ({
      isCollapsed: true,
      rangeCount: 0,
      toString: () => 'Text selected further down the page.',
    })
    await reader({ kind: 'command', action: 'toggle' })
    const { state } = await reader({ kind: 'state' })
    assert.equal(state.total, 1, 'the selection was ignored for the finished page')
    assert.equal(state.index, 0)
  } finally {
    await reader({ kind: 'command', action: 'stop' })
  }
})

/** Finish a two-sentence selection, then press the shortcut with `selection` on the page. */
async function toggleAtFinished(selection) {
  const written = []
  const p = page(anyDocument(written))
  const reader = await p.boot()
  try {
    await reader({ kind: 'command', action: 'start-selection', text: 'The first sentence. The last sentence.' })
    for (let i = 0; i < 2; i++) {
      await untilState(reader, (s) => s.index === i && s.status === 'playing', `playing ${i}`)
      FakeAudio.last.ended = true
      FakeAudio.last.dispatchEvent(new Event('ended'))
    }
    await untilState(reader, (s) => s.status === 'ended', 'finished')
    p.win.getSelection = () => selection
    await reader({ kind: 'command', action: 'toggle' })
    assert.ok(!written.includes('Nothing selected to read.'), 'a toast instead of listening again')
    // Listening again from the first sentence of the same two.
    await untilState(reader, (s) => s.index === 0 && s.total === 2 && s.status !== 'ended', 'listening again')
  } finally {
    await reader({ kind: 'command', action: 'stop' })
  }
}

test('I024: at "Finished", a selection of blank space or an image does not stop the shortcut listening again', async () => {
  // A drag across the gap between two paragraphs: not collapsed, no words.
  await toggleAtFinished({
    isCollapsed: false,
    rangeCount: 1,
    getRangeAt: () => ({ toString: () => '\n' }),
    toString: () => '\n',
  })
})

test('I025: at "Finished", text selected in the bar itself is not read in place of the page', async () => {
  // Chrome: a selection in the bar's closed shadow root is collapsed at its host.
  const host = { nodeType: 1, hasAttribute: (name) => name === 'data-aloud' }
  await toggleAtFinished({
    isCollapsed: true,
    rangeCount: 1,
    anchorNode: { nodeType: 1, childNodes: [{ nodeType: 3 }, host] },
    anchorOffset: 1,
    getRangeAt: () => ({ toString: () => '' }),
    toString: () => 'Finished',
  })
})

// ── the bar belongs to the user, not the page (H033) ─────────────────────────

/** Just enough DOM for PlayerBar and showToast; records listeners and shadow modes. */
function stubDom() {
  const shadows = []
  const created = []
  const found = new Map()
  const el = (tag) => {
    const node = {
      tagName: tag.toUpperCase(),
      dataset: {},
      style: {},
      listeners: {},
      value: '',
      attrs: {},
      classList: { add() {}, remove() {}, toggle() {} },
      setAttribute(name, value) {
        this.attrs[name] = String(value)
      },
      addEventListener(type, fn) {
        ;(this.listeners[type] ??= []).push(fn)
      },
      append() {},
      appendChild: (child) => child,
      remove() {},
      attachShadow(init) {
        shadows.push(init.mode)
        return el('#shadow-root')
      },
      querySelector(selector) {
        if (!found.has(selector)) found.set(selector, el(selector))
        return found.get(selector)
      },
      getBoundingClientRect: () => ({ left: 0, width: 100 }),
    }
    created.push(node)
    return node
  }
  return { shadows, created, found, document: { createElement: el, documentElement: el('html') } }
}

test('H033: the page can neither reach into the bar nor work it with events it dispatches', async () => {
  const dom = stubDom()
  globalThis.document = dom.document
  const { PlayerBar, showToast } = await load('content/ui.ts')
  const calls = []
  new PlayerBar({
    onToggle: () => calls.push('toggle'),
    onNext: () => calls.push('next'),
    onPrev: () => calls.push('prev'),
    onClose: () => calls.push('close'),
    onSeekFraction: (f) => calls.push(`seek ${f}`),
    onVoice: (v) => calls.push(`voice ${v}`),
    onRate: (r) => calls.push(`rate ${r}`),
  })
  showToast('Nothing selected to read.', 10)()
  assert.deepEqual(dom.shadows, ['closed', 'closed'], 'an open shadow root hands the page the controls')

  const bar = dom.created.find((e) => e.className === 'bar')
  const track = dom.found.get('.track')
  const voice = dom.found.get('.chip.voice select')
  const rate = dom.found.get('.chip.rate select')
  const planted = 'x'.repeat(80)
  voice.value = planted
  rate.value = '3'
  const fire = (isTrusted) => {
    const target = { closest: () => ({ dataset: { act: 'toggle' } }) }
    for (const fn of bar.listeners.click) fn({ isTrusted, target, preventDefault() {}, stopPropagation() {} })
    for (const fn of track.listeners.pointerdown) fn({ isTrusted, clientX: 50 })
    for (const fn of voice.listeners.change) fn({ isTrusted })
    for (const fn of rate.listeners.change) fn({ isTrusted })
  }
  fire(false) // document.getElementById('aloud-player-root')…dispatchEvent(new Event('change'))
  assert.deepEqual(calls, [], 'a page script worked the bar')
  fire(true) // the user
  assert.deepEqual(calls, ['toggle', 'seek 0.5', `voice ${planted}`, 'rate 3'])
})

test('I022: while buffering the play button is named Pause, is busy, and the wait is announced', async () => {
  const dom = stubDom()
  globalThis.document = dom.document
  const { PlayerBar, playButtonLabel } = await load('content/ui.ts')
  const noop = () => {}
  const bar = new PlayerBar({
    onToggle: noop, onNext: noop, onPrev: noop, onClose: noop,
    onSeekFraction: noop, onVoice: noop, onRate: noop,
  })
  bar.setShortcuts({ prev: undefined, toggle: 'Alt+A', next: undefined })
  const play = dom.found.get('.play')
  const live = dom.found.get('.live')
  const view = (status) => ({
    status, index: 0, total: 10, title: 'Page', error: null, voices: [], voiceId: 'af_heart',
    rate: 1, engine: 'ok', truncated: false, bufferAhead: 0, readyThrough: -1,
  })

  // A press while buffering pauses (player.toggle), so the name must say so.
  bar.update(view('buffering'))
  assert.equal(play.attrs['aria-label'], 'Pause')
  assert.equal(play.attrs.title, 'Pause (Alt+A)')
  assert.equal(play.attrs['aria-busy'], 'true')
  assert.equal(live.textContent, 'Loading audio')

  bar.update(view('playing'))
  assert.equal(play.attrs['aria-label'], 'Pause')
  assert.equal(play.attrs['aria-busy'], 'false')
  assert.equal(live.textContent, '')

  for (const status of ['ready', 'paused', 'ended', 'error', 'idle']) {
    bar.update(view(status))
    assert.equal(play.attrs['aria-label'], 'Play', status)
    assert.equal(play.attrs.title, 'Play (Alt+A)', status)
  }
  assert.deepEqual(playButtonLabel('buffering'), { label: 'Pause', busy: true })

  // The live region is polite and in the bar's markup.
  const barEl = dom.created.find((e) => e.className === 'bar')
  assert.match(barEl.innerHTML, /class="live" role="status" aria-live="polite"/)
})

test('H033: a voice id past the backend limit is never kept, so it cannot stop every reader', async () => {
  const stored = {}
  globalThis.chrome = {
    storage: {
      sync: {
        get: () => Promise.resolve(stored),
        set: (items) => Promise.resolve(Object.assign(stored, items)),
      },
      local: { get: () => Promise.resolve({}), set: () => Promise.resolve() },
    },
  }
  const { savePrefs, loadPrefs } = await load('shared/prefs.ts')
  assert.equal((await savePrefs({ voiceId: 'x'.repeat(80) })).voiceId, 'af_heart')
  assert.equal((await loadPrefs()).voiceId, 'af_heart')
  assert.equal((await savePrefs({ voiceId: 'bf_emma' })).voiceId, 'bf_emma')
})

test('J045/K009: an Escape the page uses to close its dialog or modal leaves the reading alone', async () => {
  const doc = anyDocument([])
  const p = page(doc)
  const reader = await p.boot()
  /** A key press, bubbling from the document up to the window as Chrome's does. */
  const press = (prevented = false) => {
    const e = Object.assign(new Event('keydown', { cancelable: true }), { key: 'Escape' })
    // The user's own key, which Chrome marks trusted (L047).
    Object.defineProperty(e, 'isTrusted', { value: true })
    if (prevented) e.preventDefault()
    doc.dispatchEvent(e)
    p.win.dispatchEvent(e)
  }
  const active = async () => (await reader({ kind: 'state' })).state.active
  const inside = (selector) => ({ tagName: 'BUTTON', closest: (s) => (s.split(',').includes(selector) ? {} : null) })
  try {
    await reader({ kind: 'command', action: 'start-selection', text: 'One sentence here. Another one there.' })
    assert.equal(await active(), true)

    for (const owner of ['dialog[open]', '[aria-modal="true"]', '[role="dialog"]']) {
      doc.activeElement = inside(owner)
      press()
      assert.equal(await active(), true, `Escape closing a ${owner} ended the reading`)
    }
    doc.activeElement = null
    press(true)
    assert.equal(await active(), true, 'an Escape the page handled ended the reading')

    // A lightbox open with focus left on the page behind it…
    let modals = [{ checkVisibility: () => true }]
    doc.querySelectorAll = () => modals
    press()
    assert.equal(await active(), true, 'Escape closing an open modal ended the reading')
    // …but one closed and left hidden in the DOM no longer owns the key.
    // A closed drawer kept in the DOM to fade (K009): it still has a box, so
    // checkVisibility() passes it unless asked about visibility and opacity.
    modals = [
      { checkVisibility: (o = {}) => !(o.checkVisibilityCSS || o.visibilityProperty) },
      { checkVisibility: (o = {}) => !(o.checkOpacity || o.opacityProperty) },
    ]
    press()
    assert.equal(await active(), false, 'a modal hidden by visibility or opacity kept Escape from stopping the reading')
    await reader({ kind: 'command', action: 'start-selection', text: 'One sentence here. Another one there.' })
    assert.equal(await active(), true)
    modals = [{ checkVisibility: () => false }]
    press()
    assert.equal(await active(), false, 'Escape no longer stops the reading')
  } finally {
    await reader({ kind: 'command', action: 'stop' })
  }
})

test('J046: once /health answers again, the bar stops blaming an unreachable engine', async () => {
  const p = page(anyDocument([]))
  const reader = await p.boot()
  globalThis.chrome.runtime.sendMessage = (msg) => {
    if (msg.kind === 'health') {
      return Promise.resolve({ kind: 'health', state: 'ok', voiceCount: 54, warm: true, queueDepth: 0 })
    }
    if (msg.kind !== 'synth') return Promise.resolve(undefined)
    // After the reader's first health check: the engine was down when it asked.
    const down = { kind: 'synth', ok: false, error: 'Speech engine unreachable.', aborted: false, retryable: false, status: 0, retryAfterMs: null }
    return new Promise((resolve) => setTimeout(() => resolve(down), 30))
  }
  await withShortTimers(async () => {
    try {
      await reader({ kind: 'command', action: 'start-selection', text: 'One sentence here. Another one there.' })
      const state = await untilState(reader, (s) => s.status !== 'buffering' && s.status !== 'ready', 'the stop')
      assert.notEqual(state.status, 'playing')
      const after = await untilState(reader, (s) => s.status !== 'error', 'the unreachable error to clear')
      assert.equal(after.status, 'paused')
      assert.equal(after.error, null)
      assert.equal(after.index, 0, 'Play resumes on the sentence that stopped')
    } finally {
      await reader({ kind: 'command', action: 'stop' })
    }
  })
})

test('L045: a bar first painted with no voices still offers the default voice', async () => {
  const dom = stubDom()
  globalThis.document = dom.document
  const { PlayerBar } = await load('content/ui.ts')
  const noop = () => {}
  const bar = new PlayerBar({ onToggle: noop, onNext: noop, onPrev: noop, onClose: noop, onSeekFraction: noop, onVoice: noop, onRate: noop })
  const voice = dom.found.get('.chip.voice select')
  const options = []
  voice.append = (...kids) => options.push(...kids)
  const view = {
    status: 'paused',
    index: 0,
    total: 2,
    title: 'Selection',
    error: null,
    voices: [],
    voiceId: 'af_heart',
    rate: 1,
    engine: 'offline',
    truncated: false,
    bufferAhead: 0,
    readyThrough: -1,
  }
  bar.update(view)
  bar.update(view)
  assert.deepEqual(options.map((o) => o.value), ['af_heart'], 'the voice chip has no options at all')
})

test('L045: voices missed while the engine was down are fetched once it answers', async () => {
  const p = page(anyDocument([]))
  const reader = await p.boot()
  let up = false
  let asked = 0
  const down = { kind: 'synth', ok: false, error: 'Speech engine unreachable.', aborted: false, retryable: false, status: 0, retryAfterMs: null }
  globalThis.chrome.runtime.sendMessage = (msg) => {
    if (msg.kind === 'health') {
      return Promise.resolve({ kind: 'health', state: up ? 'ok' : 'offline', voiceCount: up ? 1 : 0, warm: up, queueDepth: 0 })
    }
    if (msg.kind === 'voices') {
      asked++
      const voices = up ? [{ id: 'am_michael', name: 'Michael', lang: 'en-us', gender: 'male' }] : []
      return Promise.resolve({ kind: 'voices', voices, default: 'af_heart' })
    }
    if (msg.kind === 'synth') return Promise.resolve(up ? { kind: 'synth', ok: true, audio: wavBase64() } : down)
    return Promise.resolve(undefined)
  }
  // The health poll's seconds, made milliseconds.
  const realTimeout = p.win.setTimeout
  p.win.setTimeout = (fn, ms, ...args) => setTimeout(fn, ms >= 1000 ? 5 : ms, ...args)
  try {
    await reader({ kind: 'command', action: 'start-selection', text: 'One sentence here. Another one there.' })
    await until(() => asked === 1, 2000, 'the voice list asked for at the start')
    up = true
    await until(() => asked === 2, 2000, 'the voice list asked for again once the engine answers')
    await new Promise((r) => setTimeout(r, 50))
    assert.equal(asked, 2, 'the voices were asked for again though the bar has them')
  } finally {
    await reader({ kind: 'command', action: 'stop' })
    p.win.setTimeout = realTimeout
  }
})

test('L047: events a page dispatches neither stop the reader nor move it', async () => {
  const doc = anyDocument([])
  const probed = []
  doc.caretRangeFromPoint = (x, y) => {
    probed.push([x, y])
    return null
  }
  const p = page(doc)
  p.win.getSelection = () => ({ isCollapsed: true, rangeCount: 0, toString: () => '' })
  const reader = await p.boot()
  const active = async () => (await reader({ kind: 'state' })).state.active
  /** Input the user made, which Chrome marks trusted. */
  const trusted = (e) => Object.defineProperty(e, 'isTrusted', { value: true })
  const click = () => Object.assign(new Event('click', { bubbles: true }), { button: 0, clientX: 40, clientY: 60 })
  const escape = () => Object.assign(new Event('keydown'), { key: 'Escape' })
  try {
    await reader({ kind: 'command', action: 'start-selection', text: 'One sentence here. Another one there.' })
    assert.equal(await active(), true)

    // The extension is still here, so no reader is taking over from this one.
    doc.dispatchEvent(new Event('aloud:takeover'))
    assert.equal(await active(), true, 'a page script took the reader over')
    p.win.dispatchEvent(escape())
    assert.equal(await active(), true, 'an Escape a page script dispatched ended the reading')
    doc.dispatchEvent(click())
    assert.deepEqual(probed, [], 'a click a page script dispatched went looking for a sentence to jump to')

    // The user's own click and key still work.
    doc.dispatchEvent(trusted(click()))
    assert.deepEqual(probed, [[40, 60]])
    p.win.dispatchEvent(trusted(escape()))
    assert.equal(await active(), false)
  } finally {
    await reader({ kind: 'command', action: 'stop' })
  }
})
