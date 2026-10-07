// H065: every pdf.js loading task starts a worker holding the file, so it is
// destroyed however the parse ends: opened and parsed, failed to open (locked,
// corrupt), failed while parsing, or abandoned. Stub task: no pdf.js, no worker.
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { withPdfDocument } from '../src/lib/pdfTask.ts'

function stubTask(open: () => Promise<{ pages: number }>) {
  const task = {
    destroyed: 0,
    promise: open(),
    destroy: async () => {
      task.destroyed++
    },
  }
  task.promise.catch(() => {})
  return task
}

const locked = () => Object.assign(new Error('No password given'), { name: 'PasswordException' })
const describe = (err: unknown) =>
  new Error(`could not open: ${(err as { name?: string }).name ?? 'unknown'}`)

test('H065: a PDF that fails to open still has its worker torn down', async () => {
  const task = stubTask(() => Promise.reject(locked()))
  await assert.rejects(
    withPdfDocument(task, describe, async () => 'parsed'),
    /could not open: PasswordException/,
  )
  assert.equal(task.destroyed, 1)
})

test('H065: a failure while parsing pages still tears the worker down', async () => {
  const task = stubTask(async () => ({ pages: 3 }))
  await assert.rejects(
    withPdfDocument(task, describe, async () => {
      throw new Error('getTextContent failed')
    }),
    /getTextContent failed/,
  )
  assert.equal(task.destroyed, 1)
})

test('H065: a parsed PDF is torn down once', async () => {
  const task = stubTask(async () => ({ pages: 3 }))
  const pages = await withPdfDocument(task, describe, async (doc) => doc.pages)
  assert.equal(pages, 3)
  assert.equal(task.destroyed, 1)
})

test('H065: an abandoned parse stops the worker at once and rejects as aborted', async () => {
  const task = stubTask(async () => ({ pages: 3 }))
  const controller = new AbortController()
  let releaseParse!: () => void
  const parsing = withPdfDocument(
    task,
    describe,
    () =>
      new Promise<string>((resolve) => {
        releaseParse = () => resolve('parsed')
      }),
    controller.signal,
  )
  await new Promise((r) => setTimeout(r, 0))
  controller.abort()
  assert.equal(task.destroyed, 1, 'destroyed when abandoned, not when the parse returns')
  releaseParse()
  await assert.rejects(parsing, { name: 'AbortError' })
  assert.equal(task.destroyed, 1)
})

test('H065: loadPdf hands its loading task to withPdfDocument', () => {
  const src = readFileSync(new URL('../src/lib/pdf.ts', import.meta.url), 'utf8')
  assert.match(src, /withPdfDocument\(\s*pdfjs\.getDocument\(/)
  assert.doesNotMatch(src, /getDocument\([^)]*\)\.promise/, 'the task must not be dropped')
})
