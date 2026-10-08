// The service worker's activation paths: a selection made inside a subframe,
// from the context menu (F070) or the shortcut (G034), and keyboard shortcuts
// that are real rather than assumed (F012); and a default backend URL on the
// port the backend serves on by default.
import assert from 'node:assert/strict'
import { readFile } from 'node:fs/promises'
import { join } from 'node:path'
import { test } from 'node:test'
import { load, ROOT, SRC } from './harness.mjs'

function chromeMock() {
  const on = {}
  const event = (name) => ({ addListener: (fn) => (on[name] = fn) })
  const sent = []
  const chrome = {
    runtime: { onInstalled: event('installed'), onMessage: event('message') },
    contextMenus: { onClicked: event('menu'), removeAll: () => {}, create: () => {} },
    commands: {
      onCommand: event('command'),
      // What Chrome reports after refusing a clashing suggestion: no binding.
      getAll: () =>
        Promise.resolve([
          { name: 'toggle-read', shortcut: 'Alt+A' },
          { name: 'next-sentence', shortcut: '' },
          { name: 'prev-sentence', shortcut: 'Alt+Comma' },
        ]),
    },
    tabs: {
      get: (id) => Promise.resolve({ id, url: 'https://example.test/article' }),
      query: () => Promise.resolve([{ id: 1 }]),
      sendMessage: (tabId, msg, opts) => {
        sent.push({ tabId, msg, opts })
        return Promise.resolve(msg.kind === 'ping' ? { kind: 'pong' } : { kind: 'ok' })
      },
    },
    scripting: { executeScript: () => Promise.resolve([]) },
    storage: { sync: { get: () => Promise.resolve({}) }, local: { get: () => Promise.resolve({}) } },
  }
  return { chrome, on, sent }
}

const mock = chromeMock()
globalThis.chrome = mock.chrome
await load('background/index.ts')
const settle = () => new Promise((r) => setTimeout(r, 10))

test('F070: a selection in a subframe is read from the text Chrome reports', async () => {
  mock.sent.length = 0
  mock.on.menu(
    { menuItemId: 'aloud-read-selection', frameId: 7, selectionText: 'Text selected inside the iframe.' },
    { id: 1 },
  )
  await settle()
  const command = mock.sent.find((s) => s.msg.kind === 'command')
  assert.ok(command)
  assert.equal(command.msg.action, 'start-selection')
  assert.equal(command.msg.text, 'Text selected inside the iframe.')
})

test('F070: a selection in the page itself still reads the live DOM selection', async () => {
  mock.sent.length = 0
  mock.on.menu({ menuItemId: 'aloud-read-selection', frameId: 0, selectionText: 'In the page.' }, { id: 1 })
  await settle()
  const command = mock.sent.find((s) => s.msg.kind === 'command')
  assert.equal(command.msg.action, 'start-selection')
  assert.equal(command.msg.text, undefined)
})

test('F012: the bar is told the bindings Chrome really made', async () => {
  const reply = await new Promise((resolve) => {
    assert.equal(mock.on.message({ kind: 'shortcuts' }, {}, resolve), true)
  })
  assert.deepEqual(reply, { kind: 'shortcuts', toggle: 'Alt+A', next: '', prev: 'Alt+Comma' })

  const ui = await load('content/ui.ts')
  assert.equal(ui.withShortcut('Next sentence', reply.next), 'Next sentence')
  assert.equal(ui.withShortcut('Play / pause', reply.toggle), 'Play / pause (Alt+A)')
})

test('F012: default shortcuts clash with neither Chrome nor typing', async () => {
  const manifest = JSON.parse(await readFile(join(SRC, 'manifest.json'), 'utf8'))
  // Chrome's own Back/Forward on Windows and Linux: it refuses to assign these.
  const chromeOwn = new Set(['Alt+Left', 'Alt+Right'])
  for (const [name, command] of Object.entries(manifest.commands)) {
    const keys = command.suggested_key
    assert.ok(!chromeOwn.has(keys.default), `${name}: ${keys.default} is Chrome's own shortcut`)
    // On a Mac, Alt is Option: Option+key types a character (å, ˘…) or moves
    // the caret by word, so it needs Control or Command to be a shortcut.
    assert.ok(keys.mac, `${name}: no mac binding, so it falls back to an Option shortcut`)
    assert.match(keys.mac, /^(MacCtrl|Command)\+/, `${name}: ${keys.mac} is typing on a Mac`)
  }
})

test('F012: no surface hard-codes a shortcut', async () => {
  for (const file of ['content/ui.ts', 'popup/popup.html']) {
    const source = await readFile(join(SRC, file), 'utf8')
    assert.doesNotMatch(source, /Alt\+[←→A]|<kbd>Alt<\/kbd>/, `${file} names a binding Chrome may not have made`)
  }
})

/** Script the frames' answers to the shortcut's selection lookup. */
function frames(results) {
  const calls = []
  mock.chrome.scripting.executeScript = (opts) => {
    calls.push(opts)
    if (!opts.func) return Promise.resolve([])
    return results instanceof Error ? Promise.reject(results) : Promise.resolve(results)
  }
  return calls
}

test('G034: the shortcut reads a selection made in the focused subframe', async () => {
  mock.sent.length = 0
  const calls = frames([
    // The top frame counts as focused whenever a frame inside it is.
    { frameId: 0, result: { text: 'A stale selection up top.', focused: true } },
    { frameId: 3, result: { text: 'Left behind in another frame.', focused: false } },
    { frameId: 4, result: { text: '  A paragraph selected in the frame. ', focused: true } },
  ])
  mock.on.command('toggle-read')
  await settle()
  assert.equal(calls[0]?.target.allFrames, true)
  const command = mock.sent.find((s) => s.msg.kind === 'command')
  assert.equal(command.msg.action, 'toggle')
  assert.equal(command.msg.text, 'A paragraph selected in the frame.')
})

test('G034: with nothing selected in a subframe the shortcut leaves it to the page', async () => {
  for (const results of [
    [{ frameId: 0, result: { text: 'Selected in the page.', focused: true } }],
    [{ frameId: 2, result: { text: '', focused: true } }],
    new Error('Cannot access contents of the page.'),
  ]) {
    mock.sent.length = 0
    frames(results)
    mock.on.command('toggle-read')
    await settle()
    const command = mock.sent.find((s) => s.msg.kind === 'command')
    assert.ok(command, 'the shortcut did nothing')
    assert.equal(command.msg.action, 'toggle')
    assert.equal(command.msg.text, undefined)
  }
})

test('G034: next and previous never go looking for a selection', async () => {
  mock.sent.length = 0
  const calls = frames([{ frameId: 4, result: { text: 'Selected.', focused: true } }])
  mock.on.command('next-sentence')
  await settle()
  assert.equal(calls.length, 0)
  assert.equal(mock.sent.find((s) => s.msg.kind === 'command').msg.action, 'next')
})

test('the default backend URL dials the port the backend serves on by default', async () => {
  const { DEFAULT_PREFS } = await load('shared/prefs.ts')
  const nativeApp = await readFile(join(ROOT, '..', 'backend', 'native_app.py'), 'utf8')
  const backendPort = nativeApp.match(/^DEFAULT_PORT = (\d+)$/m)?.[1]
  assert.ok(backendPort, 'DEFAULT_PORT not found in backend/native_app.py')
  const url = new URL(DEFAULT_PREFS.backendUrl)
  assert.equal(url.port, backendPort)
  // I018: 127.0.0.1, not localhost, which macOS tries on ::1 first, where
  // another server on the same port can take every request.
  assert.equal(url.hostname, '127.0.0.1')
  const popup = await readFile(join(SRC, 'popup', 'popup.html'), 'utf8')
  assert.match(popup, new RegExp(`placeholder="${DEFAULT_PREFS.backendUrl}"`))
  const manifest = JSON.parse(await readFile(join(SRC, 'manifest.json'), 'utf8'))
  assert.ok(manifest.host_permissions.includes(`http://${url.hostname}/*`), 'no host permission for the default backend')
})

test('I018: the old localhost default saved with other settings moves to 127.0.0.1', async () => {
  const { loadPrefs } = await load('shared/prefs.ts')
  const sync = mock.chrome.storage.sync
  const realGet = sync.get
  try {
    for (const [stored, expected] of [
      ['http://localhost:8000', 'http://127.0.0.1:8000'],
      ['http://localhost:8000/', 'http://127.0.0.1:8000'],
      ['http://localhost:8001', 'http://localhost:8001'],
      // L043: only this computer; a backend on another one is refused.
      ['http://my-mac.local:8000', 'http://127.0.0.1:8000'],
    ]) {
      sync.get = () => Promise.resolve({ 'aloud.prefs.v1': { rate: 1.5, backendUrl: stored } })
      const prefs = await loadPrefs()
      assert.equal(prefs.backendUrl, expected, stored)
      assert.equal(prefs.rate, 1.5)
    }
  } finally {
    sync.get = realGet
  }
})

/** Message the worker as `sender` and wait for its answer. */
const ask = (msg, sender = {}) => new Promise((resolve) => mock.on.message(msg, sender, resolve))

test('J044: the fallback ports the worker looks on are the ones the backend moves to', async () => {
  const { BACKEND_FALLBACK_PORTS, DEFAULT_PREFS } = await load('shared/prefs.ts')
  const nativeApp = await readFile(join(ROOT, '..', 'backend', 'native_app.py'), 'utf8')
  const range = nativeApp.match(/^FALLBACK_PORTS = range\(DEFAULT_PORT \+ (\d+), DEFAULT_PORT \+ (\d+)\)$/m)
  assert.ok(range, 'FALLBACK_PORTS not found in backend/native_app.py')
  const port = Number(new URL(DEFAULT_PREFS.backendUrl).port)
  const expected = []
  for (let p = port + Number(range[1]); p < port + Number(range[2]); p++) expected.push(p)
  assert.deepEqual([...BACKEND_FALLBACK_PORTS], expected)
})

test('J044: with the default backend URL, a backend that moved to a fallback port is found and used', async () => {
  const realFetch = globalThis.fetch
  const sync = mock.chrome.storage.sync
  const realGet = sync.get
  const asked = []
  globalThis.fetch = async (url) => {
    asked.push(String(url))
    const { port, pathname } = new URL(url)
    // Django's runserver holds 8000; some other service answers on 8001.
    if (port === '8000') return new Response('<h1>Not Found</h1>', { status: 404 })
    if (port === '8001') return Response.json({ status: 'ok' })
    if (port === '8003' && pathname === '/health') {
      return Response.json({ status: 'ok', engine: 'kokoro', model_loaded: true, voice_count: 54, warm: true, queue_depth: 0 })
    }
    if (port === '8003' && pathname === '/synthesize') return new Response(new Uint8Array([82, 73, 70, 70]))
    throw new TypeError('fetch failed') // nothing listening
  }
  try {
    const report = await ask({ kind: 'health' })
    assert.equal(report.state, 'ok', 'a running backend reported offline')
    assert.equal(report.voiceCount, 54)

    const synth = await ask(
      { kind: 'synth', id: 1, text: 'Hello there.', voice: 'af_heart', speed: 1, priority: 'now' },
      { tab: { id: 1 }, frameId: 0 },
    )
    assert.equal(synth.ok, true)
    assert.ok(asked.includes('http://127.0.0.1:8003/synthesize'), `synthesis went to ${asked.at(-1)}`)

    // A backend URL the user set is never second-guessed.
    sync.get = () => Promise.resolve({ 'aloud.prefs.v1': { backendUrl: 'http://127.0.0.1:9000' } })
    asked.length = 0
    assert.equal((await ask({ kind: 'health' })).state, 'offline')
    assert.deepEqual(asked, ['http://127.0.0.1:9000/health'])
  } finally {
    globalThis.fetch = realFetch
    sync.get = realGet
  }
})

const KOKORO = { status: 'ok', engine: 'kokoro', model_loaded: true, voice_count: 54, warm: true, queue_depth: 0 }
const SYNTH = { kind: 'synth', id: 1, text: 'Hello there.', voice: 'af_heart', speed: 1, priority: 'now' }
const RIFF = () => new Response(new Uint8Array([82, 73, 70, 70]))

test('K001: another server answering /health on the default port is not taken for the backend', async () => {
  const realFetch = globalThis.fetch
  const asked = []
  let aloud = true
  globalThis.fetch = async (url) => {
    asked.push(String(url))
    const { port, pathname } = new URL(url)
    // Another uvicorn app holds 8000 with a /health of its own; Aloud moved on.
    if (port === '8000') return pathname === '/health' ? Response.json({ status: 'ok' }) : new Response('', { status: 404 })
    if (aloud && port === '8001' && pathname === '/health') return Response.json(KOKORO)
    if (aloud && port === '8001' && pathname === '/synthesize') return RIFF()
    throw new TypeError('fetch failed') // nothing listening
  }
  try {
    const report = await ask({ kind: 'health' })
    assert.equal(report.voiceCount, 54, 'the other server was taken for the backend')
    const synth = await ask(SYNTH, { tab: { id: 1 }, frameId: 0 })
    assert.equal(synth.ok, true)
    assert.ok(asked.includes('http://127.0.0.1:8001/synthesize'), `synthesis went to ${asked.at(-1)}`)

    // With Aloud nowhere, the other server's answer is no backend either.
    aloud = false
    assert.equal((await ask({ kind: 'health' })).state, 'offline')
  } finally {
    globalThis.fetch = realFetch
  }
})

test('K004: a rescan neither sends synthesis to the default port nor waits on a slow port above the backend', async () => {
  const realFetch = globalThis.fetch
  const asked = []
  let aloudPort = '8003'
  /** Ports whose /health hangs, as a suspended dev server's does, until released. */
  const stalled = new Map()
  globalThis.fetch = (url, init = {}) => {
    asked.push(String(url))
    const { port, pathname } = new URL(url)
    if (stalled.has(port) && pathname === '/health') {
      return new Promise((_, reject) => {
        const fail = () => reject(new TypeError('fetch failed'))
        stalled.get(port).push(fail)
        init.signal?.addEventListener('abort', fail)
      })
    }
    if (port === '8000') return Promise.resolve(new Response('<h1>Not Found</h1>', { status: 404 }))
    if (port === aloudPort && pathname === '/health') return Promise.resolve(Response.json(KOKORO))
    if (port === aloudPort && pathname === '/synthesize') return Promise.resolve(RIFF())
    return Promise.reject(new TypeError('fetch failed'))
  }
  const release = () => {
    for (const fails of stalled.values()) for (const fail of fails.splice(0)) fail()
    stalled.clear()
  }
  try {
    assert.equal((await ask({ kind: 'health' })).voiceCount, 54)

    // A poll's rescan waits on 8002, below the backend: synthesis meanwhile
    // goes where the backend was found.
    stalled.set('8002', [])
    const polled = ask({ kind: 'health' })
    await settle()
    asked.length = 0
    const synth = await ask(SYNTH, { tab: { id: 1 }, frameId: 0 })
    assert.equal(synth.ok, true, `synthesis went to ${asked.find((u) => u.endsWith('/synthesize'))}`)
    assert.deepEqual(asked, ['http://127.0.0.1:8003/synthesize'])
    release()
    assert.equal((await polled).voiceCount, 54)

    // A slow port above the backend does not hold up the answer.
    aloudPort = '8001'
    stalled.set('8005', [])
    const late = new Promise((resolve) => setTimeout(() => resolve('still waiting'), 1000))
    const report = await Promise.race([ask({ kind: 'health' }), late])
    assert.notEqual(report, 'still waiting', 'the scan waited on a port above the backend')
    assert.equal(report.voiceCount, 54)
  } finally {
    release()
    globalThis.fetch = realFetch
  }
})

test('J047: only the popup may activate a tab, not a content script in a page', async () => {
  mock.chrome.runtime.id = 'test'
  mock.chrome.runtime.getURL = (path) => `chrome-extension://test/${path}`
  const injected = frames([])
  mock.sent.length = 0
  const page = 'https://evil.example/article'
  const fromPage = await ask(
    { kind: 'activate', tabId: 7, action: 'start' },
    { id: 'test', tab: { id: 5, url: page }, frameId: 0, url: page },
  )
  assert.equal(fromPage.ok, false)
  assert.equal(injected.length, 0, 'the reader was injected into another tab')
  assert.equal(mock.sent.length, 0, 'another tab was sent a command')

  const fromPopup = await ask({ kind: 'activate', tabId: 7, action: 'start' }, { id: 'test', url: 'chrome-extension://test/popup.html' })
  assert.equal(fromPopup.ok, true)
  assert.ok(mock.sent.some((s) => s.tabId === 7 && s.msg.kind === 'command' && s.msg.action === 'start'))
})

/** A storage area holding `items`, as chrome.storage's get and set see it. */
function fakeArea(items = {}) {
  return {
    items,
    get: (key) => Promise.resolve(key in items ? { [key]: structuredClone(items[key]) } : {}),
    set: (more) => Promise.resolve(void Object.assign(items, structuredClone(more))),
  }
}

/** Run `fn` with `areas` in place of the mock's storage areas. */
async function withStorage(areas, fn) {
  const storage = mock.chrome.storage
  const real = { ...storage }
  Object.assign(storage, areas)
  try {
    return await fn()
  } finally {
    Object.assign(storage, real)
  }
}

test('L043: a backend URL off this computer is refused, and no request leaves it', async () => {
  const { loadPrefs, savePrefs, onThisComputer } = await load('shared/prefs.ts')
  const realFetch = globalThis.fetch
  const asked = []
  globalThis.fetch = async (url) => {
    asked.push(String(url))
    const { pathname } = new URL(url)
    if (pathname === '/health') return Response.json(KOKORO)
    if (pathname === '/synthesize') return RIFF()
    return Response.json({ voices: [], default: 'af_heart' })
  }
  try {
    // Written by a content script in a compromised page: to sync, as before
    // the split, or to this computer's own key.
    const planted = 'https://collector.example'
    for (const areas of [
      { sync: fakeArea({ 'aloud.prefs.v1': { rate: 1.5, backendUrl: planted } }), local: fakeArea() },
      { sync: fakeArea(), local: fakeArea({ 'aloud.backendUrl.v1': planted }) },
    ]) {
      await withStorage(areas, async () => {
        assert.equal((await loadPrefs()).backendUrl, 'http://127.0.0.1:8000')
        asked.length = 0
        await ask({ kind: 'health' })
        await ask({ kind: 'voices' })
        await ask(SYNTH, { tab: { id: 1 }, frameId: 0 })
        assert.ok(asked.length > 0)
        for (const url of asked) assert.equal(new URL(url).hostname, '127.0.0.1', `the worker sent a request to ${url}`)
        assert.equal((await savePrefs({ backendUrl: planted })).backendUrl, 'http://127.0.0.1:8000')
      })
    }
  } finally {
    globalThis.fetch = realFetch
  }

  for (const url of ['http://127.0.0.1:8123', 'http://localhost:8001/', 'http://[::1]:8000', 'https://127.0.0.1:8443']) {
    assert.equal(onThisComputer(url), true, url)
  }
  for (const url of [
    'https://collector.example',
    'http://203.0.113.9:80',
    'http://my-mac.local:8000',
    'http://127.0.0.1:8000@collector.example',
    'http://user:pw@127.0.0.1:8000',
    'http://127.0.0.1.collector.example',
    'file:///etc/passwd',
    'not a url',
  ]) {
    assert.equal(onThisComputer(url), false, url)
  }
})

test('L043: every request the worker makes is checked against this computer first', async () => {
  const source = await readFile(join(SRC, 'background', 'index.ts'), 'utf8')
  const fetches = [...source.matchAll(/(?<![\w.])fetch\(/g)]
  assert.equal(fetches.length, 1, 'a fetch in the worker skips the loopback check')
  const guard = source.slice(source.lastIndexOf('function ', fetches[0].index), fetches[0].index)
  assert.match(guard, /if \(!onThisComputer\(url\)\) return Promise\.reject/)
})

test('L040: the backend URL stays on the computer it was set on; the other settings sync', async () => {
  const { loadPrefs, savePrefs, watchPrefs } = await load('shared/prefs.ts')
  // One sync store shared by two computers, as saved before the split.
  const sync = fakeArea({ 'aloud.prefs.v1': { voiceId: 'bf_emma', rate: 1.5, backendUrl: 'http://127.0.0.1:8123' } })
  const laptop = fakeArea()
  const desktop = fakeArea()
  const on = (local, fn) => withStorage({ sync, local }, fn)

  // The laptop, where it was set, keeps it; the copy in sync is dropped.
  const first = await on(laptop, loadPrefs)
  assert.equal(first.backendUrl, 'http://127.0.0.1:8123')
  assert.equal(first.voiceId, 'bf_emma')
  assert.equal(first.rate, 1.5)
  assert.equal('backendUrl' in sync.items['aloud.prefs.v1'], false, 'the backend URL is still synced')
  assert.equal(sync.items['aloud.prefs.v1'].voiceId, 'bf_emma')

  // The desktop never sees it, so its default URL still scans the fallback ports.
  assert.equal((await on(desktop, loadPrefs)).backendUrl, 'http://127.0.0.1:8000')
  const moved = await on(desktop, () => savePrefs({ backendUrl: 'http://127.0.0.1:8001' }))
  assert.equal(moved.backendUrl, 'http://127.0.0.1:8001')
  assert.equal((await on(laptop, loadPrefs)).backendUrl, 'http://127.0.0.1:8123', 'the desktop moved the laptop')

  // The rest still follows the user.
  await on(laptop, () => savePrefs({ rate: 2 }))
  const desk = await on(desktop, loadPrefs)
  assert.equal(desk.rate, 2)
  assert.equal(desk.backendUrl, 'http://127.0.0.1:8001')
  assert.equal('backendUrl' in sync.items['aloud.prefs.v1'], false)

  // Moved once: a URL an older build syncs later is not taken up.
  sync.items['aloud.prefs.v1'].backendUrl = 'http://127.0.0.1:9999'
  assert.equal((await on(laptop, loadPrefs)).backendUrl, 'http://127.0.0.1:8123')
  assert.equal((await on(desktop, loadPrefs)).backendUrl, 'http://127.0.0.1:8001')

  // A change to the synced settings reports this computer's URL, not another's.
  let listener
  mock.chrome.storage.onChanged = { addListener: (fn) => (listener = fn), removeListener: () => {} }
  const seen = []
  const stop = watchPrefs((p) => seen.push(p))
  await on(desktop, async () => {
    listener({ 'aloud.prefs.v1': { newValue: { ...sync.items['aloud.prefs.v1'], rate: 2.5 } } }, 'sync')
    await settle()
  })
  stop()
  assert.equal(seen.at(-1)?.backendUrl, 'http://127.0.0.1:8001')
})
