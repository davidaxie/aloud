// F003 (web twin): a printed book puts its title atop left-hand pages and the
// chapter's atop right-hand ones, so neither header reaches half the pages and
// the old document-wide rule read both aloud at almost every page turn.
import { test } from 'node:test'
import assert from 'node:assert/strict'
import {
  type Line,
  detectRunningHeaders,
  runningHeadersByPage,
  stripNoise,
} from '../src/lib/pdfHeaders.ts'

const BOOK = 'THE COLD START PROBLEM'
const CHAPTERS = ['Tiny Speck', 'The Atomic Network', 'The Tipping Point']
const LETTERS = 'abcdefghijklmnopqrstuvwxyz'

/** Body lines whose text differs from page to page even once digits are ignored. */
function body(page: number, top: number): Line[] {
  return [0, 1, 2, 3, 4, 5].map((k) => ({
    text: `the ${LETTERS[page % 26]} story goes on, line ${k}`,
    y: top - k * 14,
    height: 11,
  }))
}

const folio = (page: number): Line => ({ text: String(page), y: 40, height: 9 })
const head = (text: string): Line => ({ text, y: 760, height: 9 })

/**
 * Four pages of front matter, then three 8-page chapters that open on a
 * right-hand page with a larger title set lower and no running head. After
 * that the book title heads even pages and the chapter title odd ones.
 */
function book(): { pages: Line[][]; heads: Array<string | null> } {
  const pages: Line[][] = [
    [{ text: BOOK, y: 600, height: 24 }, { text: 'Andrew Chen', y: 500, height: 14 }],
    [
      { text: 'Copyright reserved.', y: 200, height: 9 },
      { text: 'Printed in the USA.', y: 188, height: 9 },
      { text: 'First edition.', y: 176, height: 9 },
    ],
    [{ text: 'For the builders.', y: 600, height: 12 }],
    [],
  ]
  const heads: Array<string | null> = [null, null, null, null]
  CHAPTERS.forEach((chapter) => {
    for (let k = 0; k < 8; k++) {
      const page = pages.length + 1
      if (k === 0) {
        pages.push([{ text: chapter, y: 620, height: 20 }, ...body(page, 560), folio(page)])
        heads.push(null)
      } else {
        const text = page % 2 === 0 ? BOOK : chapter
        pages.push([head(text), ...body(page, 700), folio(page)])
        heads.push(text)
      }
    }
  })
  return { pages, heads }
}

test('F003: alternating left/right running heads miss the half-the-pages bar on their own', () => {
  const { pages } = book()
  assert.deepEqual([...detectRunningHeaders(pages)], [])
})

test('F003: alternating book and chapter heads are stripped from every page that has one', () => {
  const { pages, heads } = book()
  const running = runningHeadersByPage(pages)
  pages.forEach((lines, idx) => {
    const kept = stripNoise(lines, running[idx]).map((l) => l.text)
    const head = heads[idx]
    if (head !== null) {
      assert.ok(!kept.includes(head), `page ${idx + 1} still opens with "${head}"`)
      // The page now starts on body text, so a sentence cut by the page turn rejoins.
      assert.equal(kept[0], body(idx + 1, 700)[0].text, `page ${idx + 1}`)
    }
    // Folios go too, as before.
    assert.ok(!kept.includes(String(idx + 1)), `page ${idx + 1} folio`)
  })
})

test('F003: a chapter title on its opening page, set lower and larger, stays', () => {
  const { pages, heads } = book()
  const running = runningHeadersByPage(pages)
  pages.forEach((lines, idx) => {
    if (heads[idx] !== null || idx < 4) return
    const kept = stripNoise(lines, running[idx]).map((l) => l.text)
    assert.ok(CHAPTERS.includes(kept[0]), `page ${idx + 1} lost its chapter title: ${kept[0]}`)
  })
  // The front matter is untouched.
  assert.deepEqual(stripNoise(pages[0], running[0]).map((l) => l.text), [BOOK, 'Andrew Chen'])
})

test('F003: an edge line that recurs only far apart is body text, not a running head', () => {
  // A section break at the foot of pages 1, 7 and 13: set apart, same place,
  // but more than four pages between each, so it is not a running footer.
  const pages: Line[][] = Array.from({ length: 14 }, (_, idx) => {
    const lines = body(idx + 1, 700)
    if (idx % 6 === 0) lines.push({ text: '* * *', y: 500, height: 11 })
    return lines
  })
  const running = runningHeadersByPage(pages)
  assert.ok(stripNoise(pages[6], running[6]).some((l) => l.text === '* * *'))
  assert.ok(running.every((set) => !set.has('* * *')))
})

test('G014: numbered headings that open nearby pages are kept', () => {
  // A worksheet: pages 2-6 each open with "Step N", set apart at the top margin
  // in the same place and size, so the digits-folded key "step #" recurs on
  // consecutive pages. It is a heading, not a running head.
  const pages: Line[][] = Array.from({ length: 20 }, (_, idx) => {
    const lines = body(idx + 1, 700)
    if (idx >= 1 && idx <= 5) lines.unshift({ text: `Step ${idx}`, y: 730, height: 14 })
    return lines
  })
  const running = runningHeadersByPage(pages)
  for (let idx = 1; idx <= 5; idx++) {
    assert.equal(stripNoise(pages[idx], running[idx])[0].text, `Step ${idx}`, `page ${idx + 1}`)
  }
})

test('G014: a running head that keeps its leading number but carries a folio still goes', () => {
  const pages: Line[][] = Array.from({ length: 20 }, (_, idx) => {
    const lines = body(idx + 1, 700)
    if (idx >= 8 && idx <= 12) lines.unshift({ text: `Part 2 \u00b7 ${idx + 1}`, y: 760, height: 9 })
    return lines
  })
  const running = runningHeadersByPage(pages)
  for (let idx = 8; idx <= 12; idx++) {
    assert.equal(stripNoise(pages[idx], running[idx])[0].text, body(idx + 1, 700)[0].text)
  }
})
