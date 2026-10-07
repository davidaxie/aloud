// F058 / F062 / F063: the App shell must actually mount the pieces the pure
// modules provide (their behaviour is tested in the sibling test files).
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'

const app = readFileSync(new URL('../src/App.tsx', import.meta.url), 'utf8')

test('F058: the toast host is mounted, so skip notices reach the user', () => {
  assert.match(app, /<Toast \/>/)
})

test('F062: the engine watch replaces the one-shot health poll', () => {
  assert.match(app, /watchEngine\(\{/)
  assert.doesNotMatch(app, /setInterval\(/, 'a bare interval stops for good once the engine is ok')
})

test('F063: file drops anywhere on the window are guarded', () => {
  assert.match(app, /guardFileDrops\(window,/)
})

test('G015: a dropped PDF is parsed before the open book is closed', () => {
  assert.match(app, /openPdf\(file, \{ loadPdf, player \}\)/)
  const drop = app.slice(app.indexOf('guardFileDrops(window,'), app.indexOf('[handleFile]'))
  assert.doesNotMatch(drop, /handleReset\(\)/, 'tearing the book down first loses it when the drop is unreadable')
})

test('H029: New abandons a PDF that is still parsing', () => {
  const reset = app.slice(app.indexOf('const handleReset'), app.indexOf('}, [reset])'))
  assert.match(reset, /cancelPdfIntake\(\)/)
})

test('G016: a healthy /health answer clears a stale engine-offline banner', () => {
  assert.match(app, /onHealthy: async \(\) => \{[^}]*player\.engineRecovered\(\)/)
})
