// F058 / F062 / F063: the App shell must actually mount the pieces the pure
// modules provide (their behaviour is tested in the sibling test files).
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'

const app = readFileSync(new URL('../src/App.tsx', import.meta.url), 'utf8')

test('F058: the toast host is mounted, so skip notices reach the user', () => {
  assert.match(app, /<Toast \/>/)
})

test('F062: the engine watch replaces the one-shot health poll', () => {
  assert.match(app, /watchEngine\(\{/)
  assert.doesNotMatch(app, /setInterval\(/, 'a bare interval stops for good once the engine is ok')
})

test('F063: file drops anywhere on the window are guarded', () => {
  assert.match(app, /guardFileDrops\(window,/)
})

test('G015: a dropped PDF is parsed before the open book is closed', () => {
  assert.match(app, /openPdf\(file, \{ loadPdf, player\b/)
  const drop = app.slice(app.indexOf('guardFileDrops(window,'), app.indexOf('[handleFile]'))
  assert.doesNotMatch(drop, /handleReset\(\)/, 'tearing the book down first loses it when the drop is unreadable')
})

test('H029: New abandons a PDF that is still parsing', () => {
  const reset = app.slice(app.indexOf('const handleReset'), app.indexOf('}, [reset])'))
  assert.match(reset, /cancelPdfIntake\(\)/)
})

test('G016: a healthy /health answer clears a stale engine-offline banner', () => {
  assert.match(app, /onHealthy: async \(\) => \{[^}]*player\.engineRecovered\(\)/)
})

test('I018: the dev reader dials the backend on 127.0.0.1, the address it binds', () => {
  const api = readFileSync(new URL('../src/lib/api.ts', import.meta.url), 'utf8')
  const env = readFileSync(new URL('../.env.development', import.meta.url), 'utf8')
  assert.match(api, /VITE_API_BASE \?\? 'http:\/\/127\.0\.0\.1:8000'/)
  assert.match(env, /^VITE_API_BASE=http:\/\/127\.0\.0\.1:8000$/m)
  assert.doesNotMatch(env, /^VITE_API_BASE=http:\/\/localhost/m, 'localhost can reach another program on ::1')
})

const reader = readFileSync(new URL('../src/components/Reader.tsx', import.meta.url), 'utf8')

test('J041: opening a PDF is announced from a live region that stays mounted', () => {
  assert.match(app, /openPdf\(file, \{ loadPdf, player, announce: setAnnouncement \}\)/)
  const region = app.search(
    /<p className="visually-hidden" role="status" aria-live="polite">\s*\{announcement\}\s*<\/p>/,
  )
  assert.ok(region > 0, 'no polite live region for the announcement')
  // Mounted with the toast host, outside the views that swap: a region mounted
  // together with its text is not read out.
  assert.ok(region > app.indexOf('<Toast />'))
  const reset = app.slice(app.indexOf('const handleReset'), app.indexOf('}, [reset])'))
  assert.match(
    reset,
    /setAnnouncement\((?:''|open \? closedMessage\(open\) : '')\)/,
    'New leaves a stale "Preparing" behind',
  )
})

test('J041: the reader takes the focus the loading view dropped, on its title', () => {
  assert.match(reader, /<h1 className="reader__title" ref=\{titleRef\} tabIndex=\{-1\}>/)
  const effect = reader.slice(reader.indexOf('const titleRef'), reader.indexOf('const activePara'))
  assert.match(effect, /useEffect\(\(\) => \{/)
  assert.match(effect, /focused !== document\.body\) return/, 'focus moved on purpose is taken away')
  assert.match(effect, /titleRef\.current\?\.focus\(\{ preventScroll: true \}\)/)
  assert.match(effect, /\}, \[\]\)/, 'runs once, as the reader mounts')
})

const dropzone = readFileSync(new URL('../src/components/Dropzone.tsx', import.meta.url), 'utf8')

test('K017: New says the book closed and hands its focus to the drop target', () => {
  const reset = app.slice(app.indexOf('const handleReset'), app.indexOf('}, [reset])'))
  // The open book is read before the store forgets it.
  assert.ok(reset.indexOf('useStore.getState().doc') < reset.indexOf('reset()'))
  assert.match(reset, /setAnnouncement\(open \? closedMessage\(open\) : ''\)/, 'nothing is said')
  assert.match(reset, /setFocusDropzone\(true\)/)
  assert.match(app, /const \[focusDropzone, setFocusDropzone\] = useState\(false\)/, 'first load moves focus')
  assert.match(app, /<Dropzone onFile=\{handleFile\} focusOnMount=\{focusDropzone\} \/>/)
})

test('K017: the drop target takes focus the reset button dropped, once, as it mounts', () => {
  assert.match(dropzone, /<button\s+ref=\{buttonRef\}\s+type="button"\s+className=\{`dropzone/)
  const effect = dropzone.slice(dropzone.indexOf('useEffect('), dropzone.indexOf('function pick'))
  assert.match(effect, /if \(!focusOnMount\) return/)
  assert.match(effect, /focused !== document\.body\) return/, 'focus moved on purpose is taken away')
  assert.match(effect, /buttonRef\.current\?\.focus\(\)/)
  assert.match(effect, /\}, \[\]\)/, 'runs once, as the drop target mounts')
})

test('J043: the sentence being read is marked current for assistive technology', () => {
  const span = reader.slice(reader.indexOf('data-sentence={sid}'), reader.indexOf('role="button"'))
  assert.match(span, /data-active=\{active \? 'true' : undefined\}/)
  assert.match(span, /aria-current=\{active \? 'true' : undefined\}/)
})
