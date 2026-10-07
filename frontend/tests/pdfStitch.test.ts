// G022 (web twin): Han and kana have no case, so a Chinese or Japanese sentence
// that ran over a page break never passed the lowercase test and was split in
// two at every page turn; and "。" didn't end a sentence, so a page opening
// with a year was glued onto a finished paragraph.
import './support/hooks.mjs'
import { test } from 'node:test'
import assert from 'node:assert/strict'
import {
  type Block,
  appendLine,
  appendPageParagraphs,
  continuesUnspacedCJK,
  looksFinished,
} from '../src/lib/pdfHeaders.ts'
import type { Piece } from '../src/lib/pdfStitch.ts'

const { buildLines, pieceOf, readingOrderLines, readingOrderPages } = await import('../src/lib/pdfStitch.ts')

/** The previous page's last paragraph, then the next page's first one. */
function stitched(previous: string, next: string): Block[] {
  const blocks: Block[] = [{ text: previous, page: 1 }]
  appendPageParagraphs(blocks, [next], 2)
  return blocks
}

const texts = (blocks: Block[]) => blocks.map((b) => b.text)

test('a Chinese or Japanese sentence rejoins across a page break, with no space', () => {
  assert.deepEqual(texts(stitched('我们今天去', '公园散步。')), ['我们今天去公园散步。'])
  assert.deepEqual(texts(stitched('今日は公園へ', '散歩に行きました。')), ['今日は公園へ散歩に行きました。'])
  assert.deepEqual(texts(stitched('他说：「我们', '走吧。」')), ['他说：「我们走吧。」'])
  // The block keeps the page it started on.
  assert.equal(stitched('我们今天去', '公园散步。')[0].page, 1)
})

test('"。" and its closers finish a sentence, so the next page starts afresh', () => {
  assert.equal(stitched('我们在公园散步。', '1949年10月1日，中华人民共和国成立。').length, 2)
  assert.equal(stitched('「行きましょう。」', '2時に出発した。').length, 2)
  assert.equal(stitched('『行きましょう。』', '2時に出発した。').length, 2)
  assert.equal(stitched('我们在公园散步。', '第二天下雨了。').length, 2)
  assert.ok(looksFinished('我们在公园散步。'))
  assert.ok(looksFinished('「行きましょう。」'))
  assert.ok(!looksFinished('「行きましょう」と'))
})

test('an unfinished CJK sentence still takes a page that opens with a digit', () => {
  assert.deepEqual(texts(stitched('那是在', '1949年的秋天。')), ['那是在 1949年的秋天。'])
})

test('a page that goes on lowercase in any script is stitched, not just ASCII', () => {
  assert.deepEqual(texts(stitched('He spoke with great', 'élan and wit.')), [
    'He spoke with great élan and wit.',
  ])
  assert.deepEqual(texts(stitched('Он вошёл в', 'комнату.')), ['Он вошёл в комнату.'])
  assert.equal(stitched('He sat down.', '1949 was a year.').length, 2)
  assert.equal(stitched('He sat down', 'The next day it rained.').length, 2)
})

test('a line wrap inside Chinese or Japanese joins with no space; other scripts keep theirs', () => {
  assert.equal(appendLine('我们今天去', '公园散步。'), '我们今天去公园散步。')
  assert.equal(appendLine('我们今天去，', ' 公园散步。'), '我们今天去，公园散步。')
  assert.equal(appendLine('カタカナの', 'テキスト'), 'カタカナのテキスト')
  assert.equal(appendLine('우리는 오늘', '공원에 갔다.'), '우리는 오늘 공원에 갔다.')
  assert.equal(appendLine('the cat', 'sat'), 'the cat sat')
  assert.equal(appendLine('inter-', 'national'), 'international')
})

// K006 (web twin of J032): a suspended hyphen that wrapped at a line end lost
// its hyphen and its space, so two words were read as one.
test('K006: a hyphen wrapped before and, or, nor is a suspended one and stays', () => {
  assert.equal(appendLine('the short-', 'and long-term effects'), 'the short- and long-term effects')
  assert.equal(appendLine('a two-', 'or three-day trip'), 'a two- or three-day trip')
  assert.equal(appendLine('neither pre-', 'nor post-war'), 'neither pre- nor post-war')
  assert.deepEqual(texts(stitched('Effects were seen in both the short-', 'and long-term groups.')), [
    'Effects were seen in both the short- and long-term groups.',
  ])
  // A word broken at the wrap still rejoins, a soft hyphen always.
  assert.equal(appendLine('the re-', 'order queue'), 'the reorder queue')
  assert.equal(appendLine('a bright or-', 'ange'), 'a bright orange')
  assert.equal(appendLine('Ferdin­', 'and rode on'), 'Ferdinand rode on')
})

test('Han outside the Basic Multilingual Plane counts as Chinese', () => {
  assert.ok(continuesUnspacedCJK('他去了', '𠮷野家。'))
  assert.ok(continuesUnspacedCJK('𠮷 ', '野家'))
  assert.ok(!continuesUnspacedCJK('他去了', 'Tokyo'))
  assert.ok(!continuesUnspacedCJK('', '野家'))
})

// ── A page's pieces into lines (./pdfStitch) ────────────────────────────────

/** One run, `w` wide (about half an em a character unless given). */
function run(str: string, x: number, y: number, w = str.length * 5, h = 10): Piece {
  return { str, x, y, w, h, hasEOL: false }
}

/** A line set one run per word, justified across x0..x1 (or ragged when x1 is null). */
function words(text: string, y: number, x0 = 72, x1: number | null = 540): Piece[] {
  const parts = text.split(' ')
  const widths = parts.map((p) => p.length * 5)
  const total = widths.reduce((a, b) => a + b, 0)
  const space = x1 === null || parts.length < 2 ? 2.5 : (x1 - x0 - total) / (parts.length - 1)
  let x = x0
  return parts.map((str, i) => {
    const piece = run(str, x, y, widths[i])
    x += widths[i] + space
    return piece
  })
}

const lineTexts = (pieces: Piece[]) => readingOrderLines(pieces).map((l) => l.text)

// J035: lines were grouped by baseline across the whole page, so the two
// columns of a paper were read "left line 1, right line 1, left line 2, …".
const LEFT = [
  'The fox left the barn at dawn and ran',
  'along the hedge until it reached the',
  'stream, where it stopped to drink and',
  'to listen for the dogs of the farm on',
  'the far side of the hill behind the',
  'mill, and then it slept until noon.',
]
const RIGHT = [
  'Results show that the method works in',
  'every case we tried, on every machine',
  'we could find and with every input we',
  'had to hand, from the smallest to the',
  'largest, so we conclude that it is',
  'robust and ready for wider use.',
]

/** Two justified columns (72..297 and 315..540) from `top`, the right one `drop` lower. */
function columns(left: string[], right: string[], top: number, drop = 0): Piece[] {
  const full = (text: string, i: number, all: string[]) => (i === all.length - 1 ? text.length * 5 : 225)
  return [
    ...left.map((text, i) => run(text, 72, top - i * 12, full(text, i, left))),
    ...right.map((text, i) => run(text, 315, top - drop - i * 12, full(text, i, right))),
  ]
}

test('J035: a two-column page reads the left column, then the right', () => {
  assert.deepEqual(lineTexts(columns(LEFT, RIGHT, 700)), [...LEFT, ...RIGHT])
  // Baselines off the shared grid read the same way.
  assert.deepEqual(lineTexts(columns(LEFT, RIGHT, 700, 6)), [...LEFT, ...RIGHT])
})

test('J035: a title, a header and a centred folio stay where they are around the columns', () => {
  const page = [
    run('Journal of Small Tests', 72, 780, 110, 8),
    run('3', 534, 780, 6, 8),
    run('A Study of Foxes and Methods', 200, 750, 220, 16),
    ...columns(LEFT, RIGHT, 700),
    run('3', 303, 40, 5, 9),
  ]
  assert.deepEqual(lineTexts(page), [
    'Journal of Small Tests 3',
    'A Study of Foxes and Methods',
    ...LEFT,
    ...RIGHT,
    '3',
  ])
})

// K000: a header row two lines above a two-column body was split with the
// columns, so its right-hand part (here the folio) opened the right column,
// mid-page, where the noise pass never looks.
test('K000: a running head and folio by a two-column body go before the columns are read', () => {
  // Each page's text differs, as a book's does.
  const trees = ['oak', 'elm', 'ash', 'yew']
  const left = (page: number) => LEFT.map((text) => `${trees[page]} ${text}`)
  const right = (page: number) => RIGHT.map((text) => `${trees[page]} ${text}`)
  const headed = trees.map((_, page) => [
    run('Journal of Things', 72, 724, 85),
    run(String(page + 16), 528, 724, 10),
    ...columns(left(page), right(page), 700),
  ])
  readingOrderPages(headed).forEach((lines, page) => {
    assert.deepEqual(lines.map((l) => l.text), [...left(page), ...right(page)])
  })
  // A folio at the foot, under the left column.
  const footed = trees.map((_, page) => [
    ...columns(left(page), right(page), 700),
    run(String(page + 16), 72, 616, 10),
  ])
  readingOrderPages(footed).forEach((lines, page) => {
    assert.deepEqual(lines.map((l) => l.text), [...left(page), ...right(page)])
  })
})

// K012 (web twin): Arabic and Hebrew columns run from the right, but the left
// one was always read first.
test('K012: a right-to-left two-column page reads its right column first', () => {
  const first = Array.from({ length: 6 }, (_, i) => `הטור הראשון של המאמר, שורה ${i + 1}`)
  const second = Array.from({ length: 6 }, (_, i) => `הטור השני של המאמר, שורה ${i + 1}`)
  assert.deepEqual(lineTexts(columns(second, first, 700)), [...first, ...second])
})

test('J035: a caption set across both columns splits the page into bands, each read column by column', () => {
  const caption = 'Figure 1: The fox and the method, side by side.'
  const lower = (text: string) => text.replace(/the/g, 'a')
  const page = [
    ...columns(LEFT, RIGHT, 700),
    run(caption, 100, 600, 400),
    ...columns(LEFT.map(lower), RIGHT.map(lower), 560),
  ]
  assert.deepEqual(lineTexts(page), [...LEFT, ...RIGHT, caption, ...LEFT.map(lower), ...RIGHT.map(lower)])
})

// A normal page must come out byte-for-byte as before.
const PROSE = [
  'The rain had not stopped for three days, and the river behind the mill was higher than',
  'anyone in the village could remember. Children were kept indoors; the baker sold out of',
  'bread by nine; and the old ferryman, who had seen every flood for fifty years, said only',
  'that the water would go down when it was ready, and not before, whatever the council said.',
  'On the fourth morning the clouds broke over the eastern ridge. A thin, pale light fell on',
  'the flooded meadows, and for a while nobody spoke, as if the quiet itself were fragile.',
  'Then the church bell rang, once and then again, and the doors of the houses began to open.',
  'People came out slowly, blinking at the sky, carrying brooms and buckets and spades.',
]

test('J035/J037: a single-column page is grouped into lines exactly as before', () => {
  const page = [
    run('THE MILL ON THE RIVER', 250, 760, 100, 9),
    ...PROSE.flatMap((text, i) =>
      words(text, 700 - i * 13, i === 4 ? 90 : 72, i === 3 || i === 7 ? null : 540),
    ),
    run('47', 301, 40, 10, 9),
  ]
  // A scan's text layer leans a little from line to line; it is still read as level text.
  page[20].angle = 0.6
  page[40].angle = -0.4
  const lines = readingOrderLines(page)
  assert.deepEqual(lines, buildLines(page))
  assert.deepEqual(
    lines.map((l) => l.text),
    ['THE MILL ON THE RIVER', ...PROSE, '47'],
  )
})

test('J035: a contents page (titles left, page numbers right) still reads row by row', () => {
  const titles = ['One: The Mill', 'Two: The Rain', 'Three: The Ferry', 'Four: The Flood', 'Five: The Bell', 'Six: The Light']
  const page = titles.flatMap((title, i) => [
    run(title, 72, 700 - i * 14),
    run(String(i * 12 + 1), 530, 700 - i * 14, 10),
  ])
  assert.deepEqual(lineTexts(page), titles.map((title, i) => `${title} ${i * 12 + 1}`))
})

// J037: only the run's origin was read, so vertical Japanese came out as one
// line from the last (leftmost) column to the first, and a landscape page was
// grouped by where its sideways lines start.

/** A run as pdf.js reports it: its transform, and its width and height. */
function item(str: string, transform: number[], width: number, height: number) {
  return { str, transform, width, height, hasEOL: false }
}

test('J037: vertical Japanese reads column by column from the right', () => {
  const col = (str: string, x: number, y = 700) =>
    pieceOf(item(str, [10, 0, 0, 10, x, y], 10, [...str].length * 10), true)
  const page = [col('どこで生れたか', 460), col('名前はまだ無い。', 480), col('吾輩は', 500), col('猫である。', 500, 670)]
  assert.deepEqual(lineTexts(page), ['吾輩は猫である。', '名前はまだ無い。', 'どこで生れたか'])
  // A level folio at the foot of the page comes before the columns (K015), a
  // paragraph gap (1.6 lines, in ./pdf) apart.
  const lines = readingOrderLines([...page, pieceOf(item('12', [9, 0, 0, 9, 300, 40], 10, 9), false)])
  assert.deepEqual(lines.map((l) => l.text), ['12', '吾輩は猫である。', '名前はまだ無い。', 'どこで生れたか'])
  assert.ok(lines[0].y - lines[1].y > 1.6 * (lines[1].y - lines[2].y))
})

test('J037: a landscape page reads its sideways lines in order', () => {
  // Text turned a quarter anticlockwise (pdflscape): each line runs up the
  // page, and the next line sits to its right. The fourth opens a paragraph,
  // indented.
  const text = [
    'It was the brightest of mornings, it was',
    'the dullest of evenings, it was a day of',
    'small things.',
    'It was the season of rain, it was the',
    'season of light.',
  ]
  const page = text.map((str, i) =>
    pieceOf(item(str, [0, 10, -10, 0, 100 + i * 12, i === 3 ? 87 : 72], str.length * 5, 10), false),
  )
  assert.deepEqual(lineTexts(page), text)
})

// K015: the stamp followed the page as its last paragraph, so the next page's
// first words were stitched onto the stamp, not onto the sentence they finish.
test('J037/K015: a sideways stamp in the margin reads before the page, as its own paragraph', () => {
  const tail = 'and in the end the model achieves'
  const body = [...PROSE.slice(0, 6), tail].flatMap((text, i) => words(text, 700 - i * 13, 72, i === 6 ? null : 540))
  const stamp = 'arXiv:2601.00001v1 [cs.CL] 1 Jan 2026'
  // It starts level with the fourth line, so it used to open that line.
  const page = [...body, pieceOf(item(stamp, [0, 10, -10, 0, 30, 661], stamp.length * 5, 10), false)]
  const lines = readingOrderLines(page)
  assert.deepEqual(lines.map((l) => l.text), [stamp, ...PROSE.slice(0, 6), tail])
  assert.ok(lines[0].y - lines[1].y > 1.6 * (lines[1].y - lines[2].y))
  // So the page's last paragraph is its text, and the next page goes on from it.
  const blocks: Block[] = [
    { text: stamp, page: 1 },
    { text: lines.slice(1).map((l) => l.text).join(' '), page: 1 },
  ]
  appendPageParagraphs(blocks, ['state of the art results.'], 2)
  assert.ok(blocks[1].text.endsWith(`${tail} state of the art results.`))
  assert.equal(blocks.length, 2)
})

test('J037: pieceOf keeps a level run as it was', () => {
  assert.deepEqual(pieceOf(item('word', [10, 0, 0, 10, 72, 700], 20, 10), false), {
    str: 'word',
    x: 72,
    y: 700,
    w: 20,
    h: 10,
    hasEOL: false,
    angle: 0,
  })
})
