// The service worker's activation paths: a selection made inside a subframe
// (F070), and keyboard shortcuts that are real rather than assumed (F012).
import assert from 'node:assert/strict'
import { readFile } from 'node:fs/promises'
import { join } from 'node:path'
import { test } from 'node:test'
import { load, SRC } from './harness.mjs'

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
