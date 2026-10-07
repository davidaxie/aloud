// G028 (web twin of F079): the PDF normalizer keeps a ZWJ/ZWNJ that spells an
// emoji sequence or a non-Latin word, and drops one stranded between Latin
// letters — the rule the iPhone/Mac apps and the backend already use.
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { dropStrayJoiners, keepsJoiner } from '../src/lib/joiners.ts'

const ZWJ = '‍'
const ZWNJ = '‌'

test('G028: a ZWJ emoji sequence stays one emoji', () => {
  const coder = `\u{1F469}${ZWJ}\u{1F4BB}` // woman technologist
  assert.equal(dropStrayJoiners(`I am a ${coder} today`), `I am a ${coder} today`)
  const family = `\u{1F468}\u{1F3FD}${ZWJ}\u{1F469}${ZWJ}\u{1F467}` // skin tone + family
  assert.equal(dropStrayJoiners(family), family)
  const heart = `❤️${ZWJ}\u{1F525}` // heart on fire
  assert.equal(dropStrayJoiners(heart), heart)
})

test('G028: Persian and Devanagari keep their joiners', () => {
  const persian = `می${ZWNJ}خواهم`
  assert.equal(dropStrayJoiners(persian), persian)
  const devanagari = `क्${ZWJ}ष` // half form
  assert.equal(dropStrayJoiners(devanagari), devanagari)
})

test('G028: a joiner between Latin letters or at the edges is debris', () => {
  assert.equal(dropStrayJoiners(`of${ZWNJ}fice`), 'office')
  assert.equal(dropStrayJoiners(`a${ZWJ}b ${ZWJ}c${ZWNJ}`), 'ab c')
  assert.equal(dropStrayJoiners(`café${ZWJ}s`), 'cafés')
  assert.equal(keepsJoiner(undefined, undefined), false)
  assert.equal(keepsJoiner('x', '\u{1F4BB}'), true)
})

test('G028: the PDF normalizer no longer deletes every joiner', () => {
  const src = readFileSync(new URL('../src/lib/pdf.ts', import.meta.url), 'utf8')
  assert.doesNotMatch(src, /\\u200C\\u200D/, 'a blanket strip splits emoji and misspells Persian')
  assert.match(src, /s = dropStrayJoiners\(s\)/)
})
