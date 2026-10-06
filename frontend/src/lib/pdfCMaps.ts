// ─────────────────────────────────────────────────────────────────────────────
// Adobe's predefined CMaps for pdf.js.
//
// CJK PDFs whose fonts aren't embedded (HeiseiMin with UniJIS-UCS2-H, STSong
// with UniGB-UCS2-H, older Word and Distiller exports) name one of Adobe's
// built-in CMaps instead of carrying their own character map. pdf.js has to
// fetch that file to turn the codes back into text; without it the font becomes
// an error font, getTextContent returns nothing, and the PDF is rejected as a
// scanned document. pdfjs-dist ships the files in `cmaps/`; pdf.ts hands their
// bundled URLs to bundledCMapReaderFactory, which pdf.js then asks by name.
//
// Kept free of Vite-only syntax so it runs under plain Node in tests.
// ─────────────────────────────────────────────────────────────────────────────

/** Bundled-asset loaders keyed by path, as `import.meta.glob(…, { query: '?url' })` returns them. */
export type CMapUrlLoaders = Record<string, () => Promise<string>>

/** What pdf.js expects back for one CMap. */
export interface CMapData {
  cMapData: Uint8Array
  isCompressed: boolean
}

type Fetch = (url: string) => Promise<{ ok: boolean; status: number; arrayBuffer(): Promise<ArrayBuffer> }>

/**
 * A pdf.js `CMapReaderFactory` class that reads the packed (.bcmap) CMaps from
 * their bundled URLs. pdf.js constructs it itself and calls `fetch({ name })`
 * with a bare CMap name such as `UniJIS-UCS2-H` or `Adobe-Japan1-UCS2`.
 */
export function bundledCMapReaderFactory(
  loaders: CMapUrlLoaders,
  fetchImpl: Fetch = (url) => fetch(url),
) {
  const byName = new Map<string, () => Promise<string>>()
  for (const [path, load] of Object.entries(loaders)) {
    const file = path.slice(path.lastIndexOf('/') + 1)
    byName.set(file.replace(/\.bcmap$/, ''), load)
  }

  return class BundledCMapReaderFactory {
    // pdf.js passes { baseUrl, isCompressed }; the URLs come from the bundle instead.
    constructor(_options?: unknown) {}

    async fetch({ name }: { name: string }): Promise<CMapData> {
      const load = byName.get(name)
      if (!load) throw new Error(`Unknown CMap: ${name}`)
      const url = await load()
      const res = await fetchImpl(url)
      if (!res.ok) throw new Error(`Unable to load CMap ${name}: HTTP ${res.status}`)
      return { cMapData: new Uint8Array(await res.arrayBuffer()), isCompressed: true }
    }
  }
}
