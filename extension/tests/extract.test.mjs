// Extraction: plain-text pages (F010), the length limit that must not pass for
// the end of the page (F069), reading text with no DOM behind it (F070), and a
// selection read as selected (H030), even from a text field (H032), and words
// hard-wrapped plain text split at a line end read whole (K010).
import assert from 'node:assert/strict'
import { test } from 'node:test'
import { FakeDocument, FakeText, h, installDocument, load } from './harness.mjs'

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

test('K010: a word hard-wrapped plain text split at a line end is read whole', () => {
  const wrapped = [
    'Trade became inter-',
    'national in scope, and two- or three-day fairs gave way to pre- and',
    'post-war markets that were well',
    'known. The guild of mer-\r\nchants had rules, though neither-',
    'nor could say.',
    '',
  ].join('\n')
  installDocument(plainTextDocument(wrapped))
  const got = extract.extractPage(null)
  assert.ok(got)
  assert.deepEqual(got.sentences.map((s) => s.text), [
    'Trade became international in scope, and two- or three-day fairs gave way to pre- and post-war markets that were well known.',
    'The guild of merchants had rules, though neither- nor could say.',
  ])
  // The highlight still works on the text as the page shows it.
  assert.match(got.sentences[0].raw, /inter-\nnational/)

  // A frame's selection is plain text too.
  const frame = extract.extractText('Read the inter-\nnational news.')
  assert.equal(frame.sentences[0].text, 'Read the international news.')
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

/** A drag from the start of `first` to the end of `last`, under `ancestor`. */
function dragSelection(ancestor, first, last) {
  const range = {
    startContainer: first,
    startOffset: 0,
    endContainer: last,
    endOffset: last.data.length,
    commonAncestorContainer: ancestor,
    intersectsNode: () => true,
    toString: () => ancestor.textContent,
  }
  return { isCollapsed: false, rangeCount: 1, getRangeAt: () => range, toString: () => range.toString() }
}

test('H030: a selection across two comments reads both, highlighted, not "Nothing selected"', () => {
  const first = new FakeText('First reply here.')
  const second = new FakeText('Second reply here.')
  const section = h(
    'section',
    {},
    h('div', { class: 'comment' }, h('p', {}, first)),
    h('div', { class: 'comment' }, h('p', {}, second)),
  )
  installDocument(new FakeDocument({ body: h('body', {}, section) }), dragSelection(section, first, second))
  const got = extract.extractSelection(null)
  assert.ok(got, '"Nothing selected to read."')
  assert.deepEqual(got.sentences.map((s) => s.text), ['First reply here.', 'Second reply here.'])
  assert.equal(got.slices.length, 2, 'read from the page, so it can be highlighted')
})

test('H030: a whole WordPress comment reads its author line and its text', () => {
  const author = new FakeText('Ann says:')
  const body = new FakeText('Great post, thanks for writing it.')
  const article = h(
    'article',
    { class: 'comment-body' },
    h('footer', { class: 'comment-meta' }, h('b', { class: 'fn' }, author)),
    h('div', { class: 'comment-content' }, h('p', {}, body)),
    h('script', {}, 'trackComment(42)'),
    h('button', {}, 'Like this comment'),
  )
  installDocument(new FakeDocument({ body: h('body', {}, article) }), dragSelection(article, author, body))
  const got = extract.extractSelection(null)
  assert.ok(got, '"Nothing selected to read."')
  assert.deepEqual(got.sentences.map((s) => s.text), ['Ann says:', 'Great post, thanks for writing it.'])
})

test('I023: a selection leaves out screen-reader-only text, which was never on screen', () => {
  for (const cls of ['sr-only', 'screen-reader-text', 'visually-hidden']) {
    const first = new FakeText('We tested the new parser on real pages.')
    const last = new FakeText('It held up well.')
    const div = h(
      'div',
      {},
      h('p', {}, first),
      h('p', {}, h('a', { href: '#' }, 'Read more', h('span', { class: cls }, ' about the parser test'))),
      h('p', {}, last),
    )
    installDocument(new FakeDocument({ body: h('body', {}, div) }), dragSelection(div, first, last))
    const got = extract.extractSelection(null)
    assert.ok(got, '"Nothing selected to read."')
    assert.deepEqual(
      got.sentences.map((s) => s.text),
      ['We tested the new parser on real pages.', 'Read more', 'It held up well.'],
      cls,
    )
  }
})

test('I023: a selection leaves out a role="button" control, as it does a <button>', () => {
  const first = new FakeText('Great point about parsers.')
  const last = new FakeText('Agreed, thanks.')
  const thread = h(
    'div',
    { class: 'comments' },
    h('p', {}, first),
    h('div', { class: 'actions' }, h('span', { role: 'button' }, 'Reply'), ' ', h('button', {}, 'Share')),
    h('p', {}, last),
  )
  installDocument(new FakeDocument({ body: h('body', {}, thread) }), dragSelection(thread, first, last))
  const got = extract.extractSelection(null)
  assert.ok(got, '"Nothing selected to read."')
  assert.deepEqual(got.sentences.map((s) => s.text), ['Great point about parsers.', 'Agreed, thanks.'])
})

test('H032: text selected in a text field is read, though Chrome reports it collapsed', () => {
  installDocument(new FakeDocument({ body: h('body', {}, h('form', {}, h('textarea', {}, 'Draft'))) }), {
    isCollapsed: true,
    rangeCount: 1,
    getRangeAt: () => ({ toString: () => '' }),
    toString: () => 'Please proofread this sentence for me.',
  })
  const got = extract.extractSelection(null)
  assert.ok(got, '"Nothing selected to read."')
  assert.deepEqual(got.sentences.map((s) => s.text), ['Please proofread this sentence for me.'])
  assert.equal(got.title, 'Selection')
})

test('I025: text selected in the player bar or a toast is never read back', () => {
  const bar = h('div', { id: 'aloud-player-root', 'data-aloud': 'ui' })
  const toast = h('div', { 'data-aloud': 'toast' })
  const doc = new FakeDocument({ body: h('body', {}, h('p', {}, 'The article.')) })
  doc.documentElement.append(bar, toast)
  // Chrome: a selection inside a shadow tree is collapsed at its host.
  const inside = (host, words) => ({
    isCollapsed: true,
    rangeCount: 1,
    anchorNode: doc.documentElement,
    anchorOffset: doc.documentElement.childNodes.indexOf(host),
    getRangeAt: () => ({ toString: () => '' }),
    toString: () => words,
  })
  installDocument(doc, inside(bar, 'Finished'))
  assert.equal(extract.extractSelection(bar), null)
  assert.equal(extract.selectionInUi(window.getSelection(), bar), true)
  installDocument(doc, inside(toast, 'Nothing selected to read.'))
  assert.equal(extract.extractSelection(bar), null)
  // A text field's selection is collapsed at the field, which is the page's.
  const field = h('textarea', {}, 'Draft')
  doc.body.append(field)
  installDocument(doc, { ...inside(field, 'Please proofread this sentence for me.') })
  assert.ok(extract.extractSelection(bar), 'a text field is not our UI')
})

test('H032: an empty selection is still nothing to read', () => {
  installDocument(new FakeDocument({ body: h('body') }), { isCollapsed: true, rangeCount: 0, toString: () => '  ' })
  assert.equal(extract.extractSelection(null), null)
})

test('J042: sections that content-visibility:auto skips off screen are still read', () => {
  // Chrome's checkVisibility, CSSOM View step 5: with contentVisibilityAuto,
  // anything inside a content-visibility:auto container that is off screen
  // (skipping its contents) counts as not visible.
  const skipping = (el) => {
    for (let n = el.parentNode; n; n = n.parentNode) if (n.attrs?.['data-skipping'] === 'true') return true
    return false
  }
  const para = (text) => {
    const p = h('p', {}, text)
    p.checkVisibility = (o) => !(o?.contentVisibilityAuto && skipping(p))
    return p
  }
  const section = (n, offScreen) =>
    h('section', offScreen ? { 'data-skipping': 'true' } : {}, para(`Section ${n} opens here.`), para(`Section ${n} closes here.`))
  const body = h('body', {}, h('article', {}, section(1, false), section(2, true), section(3, true)))
  installDocument(new FakeDocument({ body }))
  const got = extract.extractPage(null)
  assert.ok(got, 'extractPage returned null')
  assert.deepEqual(
    got.sentences.map((s) => s.text),
    [1, 2, 3].flatMap((n) => [`Section ${n} opens here.`, `Section ${n} closes here.`]),
  )
})
