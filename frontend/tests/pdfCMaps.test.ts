// F057: a CJK PDF whose font isn't embedded names one of Adobe's predefined
// CMaps. pdf.js must be able to fetch it, or the text extracts as nothing.
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { readdirSync, readFileSync } from 'node:fs'
import { readFile } from 'node:fs/promises'
import { fileURLToPath } from 'node:url'
import * as pdfjs from 'pdfjs-dist/legacy/build/pdf.mjs'
import { bundledCMapReaderFactory } from '../src/lib/pdfCMaps.ts'

pdfjs.GlobalWorkerOptions.workerSrc = import.meta.resolve('pdfjs-dist/legacy/build/pdf.worker.mjs')

const TEXT = '吾輩は猫'

/** One page of Japanese in non-embedded HeiseiMin-W3, encoded with UniJIS-UCS2-H. */
function japanesePdf(): Uint8Array {
  const hex = [...TEXT].map((c) => c.codePointAt(0)!.toString(16).padStart(4, '0')).join('')
  const content = `BT /F1 24 Tf 20 50 Td <${hex}> Tj ET`
  const objects = [
    '<< /Type /Catalog /Pages 2 0 R >>',
    '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 100] /Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R >>',
    `<< /Length ${content.length} >>\nstream\n${content}\nendstream`,
    '<< /Type /Font /Subtype /Type0 /BaseFont /HeiseiMin-W3 /Encoding /UniJIS-UCS2-H /DescendantFonts [6 0 R] >>',
    '<< /Type /Font /Subtype /CIDFontType0 /BaseFont /HeiseiMin-W3 /CIDSystemInfo << /Registry (Adobe) /Ordering (Japan1) /Supplement 2 >> /FontDescriptor 7 0 R /DW 1000 >>',
    '<< /Type /FontDescriptor /FontName /HeiseiMin-W3 /Flags 6 /FontBBox [-123 -257 1001 910] /ItalicAngle 0 /Ascent 723 /Descent -241 /CapHeight 709 /StemV 69 >>',
  ]
  let out = '%PDF-1.4\n'
  const offsets: number[] = []
  objects.forEach((body, i) => {
    offsets.push(out.length)
    out += `${i + 1} 0 obj\n${body}\nendobj\n`
  })
  const xref = out.length
  out += `xref\n0 ${objects.length + 1}\n0000000000 65535 f \n`
  out += offsets.map((o) => `${String(o).padStart(10, '0')} 00000 n \n`).join('')
  out += `trailer\n<< /Size ${objects.length + 1} /Root 1 0 R >>\nstartxref\n${xref}\n%%EOF\n`
  return new TextEncoder().encode(out) // ASCII only, so offsets are byte offsets
}

/** The shipped cmaps/ folder, shaped like the glob pdf.ts passes in. */
function cmapLoaders() {
  const dir = new URL('../node_modules/pdfjs-dist/cmaps/', import.meta.url)
  const loaders: Record<string, () => Promise<string>> = {}
  for (const file of readdirSync(fileURLToPath(dir))) {
    if (file.endsWith('.bcmap')) {
      loaders[`/node_modules/pdfjs-dist/cmaps/${file}`] = async () => new URL(file, dir).href
    }
  }
  return loaders
}

async function readFileUrl(url: string) {
  const buf = await readFile(new URL(url))
  return {
    ok: true,
    status: 200,
    arrayBuffer: async () => buf.buffer.slice(buf.byteOffset, buf.byteOffset + buf.byteLength) as ArrayBuffer,
  }
}

async function extract(options: Record<string, unknown>): Promise<string> {
  const pdf = await pdfjs.getDocument({ data: japanesePdf(), verbosity: 0, ...options }).promise
  try {
    const page = await pdf.getPage(1)
    const content = await page.getTextContent()
    return content.items.map((item) => ('str' in item ? item.str : '')).join('')
  } finally {
    await pdf.destroy()
  }
}

test('without a CMap reader, pdf.js loses the Japanese text (the reported failure)', async () => {
  assert.equal((await extract({})).trim(), '')
})

test('the bundled CMap reader lets pdf.js extract the Japanese text', async () => {
  const CMapReaderFactory = bundledCMapReaderFactory(cmapLoaders(), readFileUrl)
  assert.equal(await extract({ CMapReaderFactory }), TEXT)
})

test('an unknown CMap name is an error, not empty data', async () => {
  const Factory = bundledCMapReaderFactory({}, readFileUrl)
  await assert.rejects(new Factory().fetch({ name: 'Nope-H' }), /Unknown CMap: Nope-H/)
})

test('pdf.ts hands pdf.js the bundled CMap reader', () => {
  const src = readFileSync(new URL('../src/lib/pdf.ts', import.meta.url), 'utf8')
  assert.match(src, /import\.meta\.glob<string>\('\/node_modules\/pdfjs-dist\/cmaps\/\*\.bcmap'/)
  assert.match(src, /exhaustive: true/, 'without it Vite skips node_modules and the glob is empty')
  assert.match(src, /getDocument\(\{ data, CMapReaderFactory \}\)/)
})
