// Extraction: plain-text pages (F010), the length limit that must not pass for
// the end of the page (F069), and reading text with no DOM behind it (F070).
import assert from 'node:assert/strict'
import { test } from 'node:test'
import { FakeDocument, h, installDocument, load } from './harness.mjs'

const extract = await load('content/extract.ts')
const ui = await load('content/ui.ts')

// What Chrome builds for a text/plain response: body > pre > one text run,
// hard-wrapped at ~70 columns, paragraphs separated by blank lines.
const GUTENBERG = [
  'PRIDE AND PREJUDICE',
  '',
  '',
  'It is a truth universally acknowledged, that a single man in possession',
  'of a good fortune, must be in want of a wife.',
  '',
  'However little known the feelings or views of such a man may be on his',
  'first entering a neighbourhood, this truth is so well fixed in the minds',
  'of the surrounding families, that he is considered as the rightful',
  'property of some one or other of their daughters.',
  '',
].join('\n')

function plainTextDocument(text) {
  const pre = h('pre', { style: 'word-wrap: break-word; white-space: pre-wrap;' }, text)
  return new FakeDocument({ contentType: 'text/plain', body: h('body', {}, pre) })
}

test('F010: a text/plain page is read, not skipped as a code block', () => {
  installDocument(plainTextDocument(GUTENBERG))
  const got = extract.extractPage(null)
  assert.ok(got, 'extractPage returned null: "No readable text found on this page."')
  assert.deepEqual(
    got.sentences.map((s) => s.text),
    [
      'PRIDE AND PREJUDICE',
      'It is a truth universally acknowledged, that a single man in possession of a good fortune, must be in want of a wife.',
      'However little known the feelings or views of such a man may be on his first entering a neighbourhood, this truth is so well fixed in the minds of the surrounding families, that he is considered as the rightful property of some one or other of their daughters.',
    ],
  )
  // Offsets still land on the source text, newlines and all.
  const second = got.sentences[1]
  assert.equal(got.text.slice(second.start, second.end), second.raw)
  assert.match(second.raw, /possession\nof a good/)
})

test('F010: select-all on a plain-text page reads the PRE too', () => {
  const doc = plainTextDocument(GUTENBERG)
  const range = { toString: () => GUTENBERG, commonAncestorContainer: doc.body, intersectsNode: () => true }
  installDocument(doc, { isCollapsed: false, rangeCount: 1, getRangeAt: () => range })
  const got = extract.extractSelection(null)
  assert.ok(got, '"Nothing selected to read."')
  assert.equal(got.sentences.length, 3)
})

test('F010: a PRE inside an ordinary article is still skipped as code', () => {
  const body = h(
    'body',
    {},
    h(
      'article',
      {},
      h('p', {}, 'A paragraph of ordinary prose, long enough to count, with a comma or two, here.'),
      h('pre', {}, h('code', {}, 'const x = 1; // never read aloud')),
    ),
  )
  installDocument(new FakeDocument({ body }))
  const got = extract.extractPage(null)
  assert.ok(got)
  assert.ok(got.sentences.every((s) => !s.text.includes('const x')))
})

test('paragraphSpans splits on blank lines only', () => {
  const text = 'one\ntwo\n\nthree\n  \n\nfour'
  const spans = extract.paragraphSpans(text, 0, text.length).map((s) => text.slice(s.start, s.end))
  assert.deepEqual(spans, ['one\ntwo', 'three', 'four'])
})

test('F069: a page past the length limit says so instead of "Finished"', () => {
  const sentence = 'This sentence is here to make the page very long indeed, and it keeps going. '
  const paragraph = sentence.repeat(20)
  const paras = Array.from({ length: 450 }, () => h('p', {}, paragraph)) // ~700k chars
  installDocument(new FakeDocument({ body: h('body', {}, h('article', {}, ...paras)) }))
  const got = extract.extractPage(null)
  assert.ok(got)
  assert.equal(got.truncated, true)

  const view = {
    status: 'ended', index: got.sentences.length - 1, total: got.sentences.length, title: 't',
    error: null, voices: [], voiceId: 'af_heart', rate: 1, engine: 'ok', truncated: got.truncated,
    bufferAhead: 0, readyThrough: -1,
  }
  assert.notEqual(ui.statusLine(view).text, 'Finished')
  assert.equal(ui.statusLine(view).text, ui.TRUNCATED_MESSAGE)
  assert.equal(ui.statusLine({ ...view, truncated: false }).text, 'Finished')
})

test('F069: a page within the limit is not marked truncated', () => {
  installDocument(new FakeDocument({ body: h('body', {}, h('p', {}, 'Short and sweet, as pages go.')) }))
  const got = extract.extractPage(null)
  assert.ok(got)
  assert.equal(got.truncated, false)
})

test('F070: text reported from an unreachable frame is read as plain text', () => {
  installDocument(new FakeDocument({ body: h('body') }))
  const got = extract.extractText('First sentence from the frame. Second one\nwraps a line.')
  assert.ok(got)
  assert.deepEqual(
    got.sentences.map((s) => s.text),
    ['First sentence from the frame.', 'Second one wraps a line.'],
  )
  assert.equal(got.slices.length, 0)
  assert.equal(got.title, 'Selection')
})
