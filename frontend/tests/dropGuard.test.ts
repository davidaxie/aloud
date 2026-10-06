// F063: a file dropped anywhere on the page must not fall through to the
// browser default (opening the file in place of the app).
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { guardFileDrops, isPdf } from '../src/lib/dropGuard.ts'

function fileDrag(type: string, files: Array<{ name: string; type: string }>, types = ['Files']) {
  const e = new Event(type, { cancelable: true })
  Object.defineProperty(e, 'dataTransfer', { value: { types, files, dropEffect: 'none' } })
  return e as Event & { dataTransfer: { dropEffect: string } }
}

const pdf = { name: 'B.pdf', type: 'application/pdf' }

test('a file dragged over the page is claimed, so the browser will not open it', () => {
  const win = new EventTarget()
  guardFileDrops(win, () => {})
  const over = fileDrag('dragover', [pdf])
  win.dispatchEvent(over)
  assert.equal(over.defaultPrevented, true)
  assert.equal(over.dataTransfer.dropEffect, 'copy')
})

test('a dropped PDF is handed to the app and the default is prevented', () => {
  const win = new EventTarget()
  const got: unknown[] = []
  guardFileDrops(win, (f) => got.push(f))
  const drop = fileDrag('drop', [pdf])
  win.dispatchEvent(drop)
  assert.equal(drop.defaultPrevented, true)
  assert.deepEqual(got, [pdf])
})

test('a drop the Dropzone already handled is not handled twice', () => {
  const win = new EventTarget()
  const got: unknown[] = []
  win.addEventListener('drop', (e) => e.preventDefault()) // the Dropzone, nearer the target
  guardFileDrops(win, (f) => got.push(f))
  win.dispatchEvent(fileDrag('drop', [pdf]))
  assert.deepEqual(got, [])
})

test('dragging text (no files) is left alone', () => {
  const win = new EventTarget()
  guardFileDrops(win, () => assert.fail('not a file drop'))
  const over = fileDrag('dragover', [], ['text/plain'])
  const drop = fileDrag('drop', [], ['text/plain'])
  win.dispatchEvent(over)
  win.dispatchEvent(drop)
  assert.equal(over.defaultPrevented, false)
  assert.equal(drop.defaultPrevented, false)
})

test('the returned function removes the guard', () => {
  const win = new EventTarget()
  const remove = guardFileDrops(win, () => assert.fail('guard removed'))
  remove()
  const drop = fileDrag('drop', [pdf])
  win.dispatchEvent(drop)
  assert.equal(drop.defaultPrevented, false)
})

test('isPdf accepts by type or extension only', () => {
  assert.equal(isPdf({ name: 'a.PDF', type: '' }), true)
  assert.equal(isPdf({ name: 'scan', type: 'application/pdf' }), true)
  assert.equal(isPdf({ name: 'notes.txt', type: 'text/plain' }), false)
})
