// F003 (web twin): a printed book puts its title atop left-hand pages and the
// chapter's atop right-hand ones, so neither header reaches half the pages and
// the old document-wide rule read both aloud at almost every page turn.
import { test } from 'node:test'
import assert from 'node:assert/strict'
import {
  type Line,
  detectRunningHeaders,
  folioLines,
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
  const folios = folioLines(pages)
  pages.forEach((lines, idx) => {
    const kept = stripNoise(lines, running[idx], folios[idx]).map((l) => l.text)
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
  const folios = folioLines(pages)
  pages.forEach((lines, idx) => {
    if (heads[idx] !== null || idx < 4) return
    const kept = stripNoise(lines, running[idx], folios[idx]).map((l) => l.text)
    assert.ok(CHAPTERS.includes(kept[0]), `page ${idx + 1} lost its chapter title: ${kept[0]}`)
  })
  // The front matter is untouched.
  assert.deepEqual(stripNoise(pages[0], running[0], folios[0]).map((l) => l.text), [BOOK, 'Andrew Chen'])
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
  const folios = folioLines(pages)
  assert.ok(stripNoise(pages[6], running[6], folios[6]).some((l) => l.text === '* * *'))
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
  const folios = folioLines(pages)
  for (let idx = 1; idx <= 5; idx++) {
    assert.equal(stripNoise(pages[idx], running[idx], folios[idx])[0].text, `Step ${idx}`, `page ${idx + 1}`)
  }
})

test('G014: a running head that keeps its leading number but carries a folio still goes', () => {
  const pages: Line[][] = Array.from({ length: 20 }, (_, idx) => {
    const lines = body(idx + 1, 700)
    if (idx >= 8 && idx <= 12) lines.unshift({ text: `Part 2 \u00b7 ${idx + 1}`, y: 760, height: 9 })
    return lines
  })
  const running = runningHeadersByPage(pages)
  const folios = folioLines(pages)
  for (let idx = 8; idx <= 12; idx++) {
    assert.equal(stripNoise(pages[idx], running[idx], folios[idx])[0].text, body(idx + 1, 700)[0].text)
  }
})

// J040 (web twin of H047): any bare numeral among a page's two outer lines was
// dropped as a folio, whatever its size or place, so a chapter headed "7",
// "IV" or "1984" lost its heading on screen and in the audio, and so did an
// edge line that merely spells with roman letters ("Did", "vivid").

/** Ten pages under a running head with folios at the foot; page 5 opens a chapter. */
function novel(heading: Line): Line[][] {
  return Array.from({ length: 10 }, (_, idx) => {
    const page = idx + 1
    if (idx === 4) return [heading, ...body(page, 560), folio(page)]
    return [head('THE NOVEL'), ...body(page, 700), folio(page)]
  })
}

function kept(pages: Line[][]): string[][] {
  const running = runningHeadersByPage(pages)
  const folios = folioLines(pages)
  return pages.map((lines, idx) => stripNoise(lines, running[idx], folios[idx]).map((l) => l.text))
}

test('J040: a bare numeral heading a chapter, set larger than the text, stays', () => {
  for (const text of ['IV', '7', '1984', 'II']) {
    const pages = kept(novel({ text, y: 620, height: 24 }))
    assert.equal(pages[4][0], text, `the chapter heading "${text}" was dropped`)
    pages.forEach((lines, idx) => {
      assert.ok(!lines.includes(String(idx + 1)), `page ${idx + 1} still reads its folio`)
      assert.ok(!lines.includes('THE NOVEL'), `page ${idx + 1} still reads its running head`)
    })
  }
})

test('J040: a roman numeral is a folio only when it counts on with the pages (H047)', () => {
  // A body-sized "II" heading a chapter has no "i" or "iii" beside it.
  assert.equal(kept(novel({ text: 'II', y: 620, height: 11 }))[4][0], 'II')
  // Front matter numbered "v" to "ix" at its foot loses every folio.
  const roman = ['v', 'vi', 'vii', 'viii', 'ix']
  const front = roman.map((text, idx) => [...body(idx + 1, 700), { text, y: 40, height: 9 }])
  kept(front).forEach((lines, idx) => assert.ok(!lines.includes(roman[idx]), roman[idx]))
})

test('J040: a word spelled with roman letters is not a numeral', () => {
  const words = ['Did', 'vivid', 'Mid', 'Civic', 'mild']
  const pages = words.map((text, idx) => [
    { text, y: 714, height: 11 },
    ...body(idx + 1, 700),
    folio(idx + 1),
  ])
  kept(pages).forEach((lines, idx) => assert.equal(lines[0], words[idx]))
})

test('J040: digit folios still go at the head of one page and the foot of the next, or alone', () => {
  // The chapter's opening page drops its folio to the foot; the others carry it at the head.
  const pages = Array.from({ length: 6 }, (_, idx) => {
    const page = idx + 1
    const number = { text: String(page + 40), y: idx === 2 ? 40 : 760, height: 9 }
    return idx === 2 ? [...body(page, 560), number] : [number, ...body(page, 700)]
  })
  kept(pages).forEach((lines, idx) => assert.ok(!lines.includes(String(idx + 41)), `page ${idx + 1}`))
  // A one-page document's page number at its foot.
  assert.deepEqual(kept([[...body(1, 700), folio(3)]])[0], body(1, 700).map((l) => l.text))
})
