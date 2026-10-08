// F104: the speed slider's `outline: none` must not leave it without a visible
// keyboard focus indicator (WCAG 2.4.7).
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'

const css = readFileSync(new URL('../src/styles/globals.css', import.meta.url), 'utf8')

/** The declarations of the first rule whose selector list is exactly `selector`. */
function ruleBody(selector: string): { body: string; at: number } | null {
  const escaped = selector.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
  const m = new RegExp(`(^|\\n)${escaped}\\s*\\{([^}]*)\\}`).exec(css)
  return m ? { body: m[2], at: m.index } : null
}

test('the speed slider shows an outline when focused from the keyboard', () => {
  const base = ruleBody('.rate-slider')
  const focus = ruleBody('.rate-slider:focus-visible')
  assert.ok(base, '.rate-slider rule exists')
  assert.ok(focus, '.rate-slider:focus-visible rule exists')
  assert.match(focus.body, /outline:\s*2px solid/)
  assert.doesNotMatch(focus.body, /outline:\s*none/)
  assert.ok(focus.at > base.at, 'declared after the rule that removes the outline')
})

test('F058: skipped sentences and toasts have styles', () => {
  assert.ok(ruleBody('.reader__sent.is-skipped'), 'skipped sentences are marked inline')
  assert.ok(ruleBody('.toast-region'), 'the toast host is placed')
  assert.ok(ruleBody('.toast'), 'the toast is styled')
})

test('H067: the voice search row shows focus, since the field drops its outline', () => {
  const field = ruleBody('.popover__search-input')
  const row = ruleBody('.popover__search:focus-within')
  assert.ok(field, '.popover__search-input rule exists')
  assert.match(field.body, /outline:\s*none/)
  assert.ok(row, '.popover__search:focus-within rule exists')
  assert.match(row.body, /box-shadow:[^;]*var\(--accent\)/)
})

test('L035: a reader held under the loading view is hidden but keeps its layout', () => {
  const held = ruleBody('.reader.is-held')
  assert.ok(held, '.reader.is-held rule exists')
  // display: none would drop the box, and with it the scroll position.
  assert.match(held.body, /visibility:\s*hidden/)
  assert.doesNotMatch(held.body, /display:\s*none/)
  const over = ruleBody('.app__main-over')
  assert.ok(over, '.app__main-over rule exists')
  assert.match(over.body, /position:\s*absolute/)
  assert.match(over.body, /inset:\s*0/)
  assert.match(ruleBody('.app__main')!.body, /position:\s*relative/, 'the overlay is placed over main')
})
