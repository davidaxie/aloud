// The content script's wiring: listening before the first await (F065) and
// noticing an app's own pushState navigation (F071).
import assert from 'node:assert/strict'
import { test } from 'node:test'
import { DEFAULT_TEST_PREFS, load } from './harness.mjs'

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
