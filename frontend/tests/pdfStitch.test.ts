// G022 (web twin): Han and kana have no case, so a Chinese or Japanese sentence
// that ran over a page break never passed the lowercase test and was split in
// two at every page turn; and "。" didn't end a sentence, so a page opening
// with a year was glued onto a finished paragraph.
import { test } from 'node:test'
import assert from 'node:assert/strict'
import {
  type Block,
  appendLine,
  appendPageParagraphs,
  continuesUnspacedCJK,
  looksFinished,
} from '../src/lib/pdfHeaders.ts'

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

test('Han outside the Basic Multilingual Plane counts as Chinese', () => {
  assert.ok(continuesUnspacedCJK('他去了', '𠮷野家。'))
  assert.ok(continuesUnspacedCJK('𠮷 ', '野家'))
  assert.ok(!continuesUnspacedCJK('他去了', 'Tokyo'))
  assert.ok(!continuesUnspacedCJK('', '野家'))
})
