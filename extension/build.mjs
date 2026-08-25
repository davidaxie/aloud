// ─────────────────────────────────────────────────────────────────────────────
// Extension build.
//
// esbuild produces three bundles with different output formats, because Chrome
// treats each surface differently:
//   • content.js    — IIFE. MV3 content scripts are classic scripts; ESM would
//                     throw "Cannot use import statement outside a module".
//   • background.js — ESM. The service worker is declared "type": "module".
//   • popup.js      — IIFE. Loaded by popup.html with a plain <script>.
//
// Everything else (manifest, popup.html/css, icons) is copied verbatim into
// dist/, which is the unpacked-extension folder you load in chrome://extensions.
//
//   node build.mjs           one-shot build
//   node build.mjs --watch   rebuild on change (leave running while developing)
// ─────────────────────────────────────────────────────────────────────────────
import * as esbuild from 'esbuild'
import { cp, mkdir, rm } from 'node:fs/promises'
import { existsSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const ROOT = dirname(fileURLToPath(import.meta.url))
const SRC = join(ROOT, 'src')
const OUT = join(ROOT, 'dist')

const watch = process.argv.includes('--watch')

/** Shared esbuild options; per-entry format/entry are layered on top. */
const common = {
  bundle: true,
  target: 'chrome114', // MV3 baseline we support; keeps output modern + small
  platform: 'browser',
  logLevel: 'info',
  // Sourcemaps only in watch mode — a shipped .zip doesn't need them.
  sourcemap: watch ? 'inline' : false,
  minify: !watch,
  legalComments: 'none',
}

const BUNDLES = [
  { in: join(SRC, 'content/index.ts'), out: join(OUT, 'content.js'), format: 'iife' },
  { in: join(SRC, 'background/index.ts'), out: join(OUT, 'background.js'), format: 'esm' },
  { in: join(SRC, 'popup/popup.ts'), out: join(OUT, 'popup.js'), format: 'iife' },
]

/** Copy the non-bundled assets (manifest, popup shell, icons) into dist/. */
async function copyStatic() {
  await cp(join(SRC, 'manifest.json'), join(OUT, 'manifest.json'))
  await cp(join(SRC, 'popup/popup.html'), join(OUT, 'popup.html'))
  await cp(join(SRC, 'popup/popup.css'), join(OUT, 'popup.css'))
  if (existsSync(join(ROOT, 'icons'))) {
    await cp(join(ROOT, 'icons'), join(OUT, 'icons'), {
      recursive: true,
      // Skip the generator script — only the PNGs belong in the package.
      filter: (src) => !src.endsWith('.py'),
    })
  }
}

await rm(OUT, { recursive: true, force: true })
await mkdir(OUT, { recursive: true })
await copyStatic()

if (watch) {
  // One context per bundle so each rebuilds independently on change.
  const contexts = await Promise.all(
    BUNDLES.map((b) =>
      esbuild.context({ ...common, entryPoints: [b.in], outfile: b.out, format: b.format }),
    ),
  )
  await Promise.all(contexts.map((c) => c.watch()))
  console.log('watching… (reload the extension in chrome://extensions after a rebuild)')
} else {
  await Promise.all(
    BUNDLES.map((b) =>
      esbuild.build({ ...common, entryPoints: [b.in], outfile: b.out, format: b.format }),
    ),
  )
  console.log(`built → ${OUT}`)
}
