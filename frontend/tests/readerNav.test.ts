// F066 / F067: the reader's sentences are one roving-tabindex group, and Enter
// activates a focused sentence. G013: Space and ←/→ stay the transport keys.
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { sentenceFocusTarget, sentenceKeyAction, tabStopSentence } from '../src/lib/readerNav.ts'

test('F066: Enter activates a focused sentence', () => {
  assert.equal(sentenceKeyAction('Enter'), 'seek')
  assert.equal(sentenceKeyAction('a'), null)
  assert.equal(sentenceKeyAction('Tab'), null)
})

test('G013: Space and the side arrows stay transport keys on a focused sentence', () => {
  // A click leaves focus on the sentence. Space must then pause, not restart
  // the clicked sentence, and the arrows must step playback, as the header says.
  assert.equal(sentenceKeyAction(' '), 'toggle')
  assert.equal(sentenceKeyAction('Spacebar'), 'toggle')
  assert.equal(sentenceKeyAction('ArrowRight'), 'step-next')
  assert.equal(sentenceKeyAction('ArrowLeft'), 'step-prev')
})

test('G013: the reader sends Space and the side arrows to the player', () => {
  const src = readFileSync(new URL('../src/components/Reader.tsx', import.meta.url), 'utf8')
  assert.match(src, /case 'toggle':\s*player\.toggle\(\)/)
  assert.match(src, /case 'step-next':\s*player\.next\(\)/)
  assert.match(src, /case 'step-prev':\s*player\.prev\(\)/)
})

test('F067: up/down arrows, Home and End move focus inside the group, clamped', () => {
  assert.equal(sentenceKeyAction('ArrowDown'), 'next')
  assert.equal(sentenceKeyAction('ArrowUp'), 'prev')
  assert.equal(sentenceFocusTarget(4, 'next', 10), 5)
  assert.equal(sentenceFocusTarget(9, 'next', 10), 9)
  assert.equal(sentenceFocusTarget(0, 'prev', 10), 0)
  assert.equal(sentenceFocusTarget(5, 'first', 10), 0)
  assert.equal(sentenceFocusTarget(5, 'last', 10), 9)
})

test('F067: exactly one sentence is a tab stop', () => {
  // Nothing read or focused yet: the first sentence.
  assert.equal(tabStopSentence(null, -1, 5137), 0)
  // The sentence being read.
  assert.equal(tabStopSentence(null, 12, 5137), 12)
  // The sentence the keyboard user moved to wins over playback.
  assert.equal(tabStopSentence(40, 12, 5137), 40)
  // Out of range falls back to the first; an empty document has none.
  assert.equal(tabStopSentence(null, 9000, 5137), 0)
  assert.equal(tabStopSentence(null, -1, 0), -1)
})

test('F066/F067: the reader renders one sentence element type with a roving tabIndex', () => {
  // Guard the component wiring the pure helpers above depend on.
  const src = readFileSync(new URL('../src/components/Reader.tsx', import.meta.url), 'utf8')
  assert.doesNotMatch(src, /<ActiveSentence\b/, 'a separate active-sentence element remounts and drops focus')
  assert.match(src, /tabIndex=\{sid === tabStopId \? 0 : -1\}/)
  assert.doesNotMatch(src, /tabIndex=\{0\}/)
})

test('F058: the reader marks skipped sentences inline', () => {
  const src = readFileSync(new URL('../src/components/Reader.tsx', import.meta.url), 'utf8')
  assert.match(src, /useStore\(\(s\) => s\.skippedSentences\)/)
  assert.match(src, /' is-skipped'/)
})
