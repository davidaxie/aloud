// ─────────────────────────────────────────────────────────────────────────────
// Test harness for the extension's `node --test` suite.
//
// The sources are TypeScript with extensionless imports, so each test bundles
// the module it needs with the repo's own esbuild into a temp directory and
// imports that. The DOM here is a deliberately tiny stand-in — just the calls
// extract.ts makes — and there is no audio anywhere: Audio is a fake whose
// play() each test scripts.
//
//   node --test tests/*.test.mjs        (from extension/)
// ─────────────────────────────────────────────────────────────────────────────
import * as esbuild from 'esbuild'
import { mkdtemp } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { dirname, join } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'

export const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..')
// ALOUD_EXT_SRC points the suite at another copy of src/ (e.g. the pre-fix tree).
export const SRC = process.env.ALOUD_EXT_SRC ?? join(ROOT, 'src')

/** Bundle `src/<entry>` to a throwaway ESM file and import it fresh. */
export async function load(entry) {
  const dir = await mkdtemp(join(tmpdir(), 'aloud-ext-test-'))
  const outfile = join(dir, 'bundle.mjs')
  await esbuild.build({
    entryPoints: [join(SRC, entry)],
    bundle: true,
    format: 'esm',
    platform: 'neutral',
    target: 'es2022',
    outfile,
    logLevel: 'silent',
  })
  return import(pathToFileURL(outfile).href)
}

// ── a DOM just big enough for extract.ts ─────────────────────────────────────

export const NodeTypes = { ELEMENT_NODE: 1, TEXT_NODE: 3 }

class FakeNode {
  constructor(nodeType) {
    this.nodeType = nodeType
    this.parentNode = null
    this.childNodes = []
    this.ownerDocument = null
  }
  get parentElement() {
    return this.parentNode && this.parentNode.nodeType === 1 ? this.parentNode : null
  }
  get firstChild() {
    return this.childNodes[0] ?? null
  }
  get nextSibling() {
    if (!this.parentNode) return null
    const siblings = this.parentNode.childNodes
    return siblings[siblings.indexOf(this) + 1] ?? null
  }
  get isConnected() {
    let n = this
    while (n.parentNode) n = n.parentNode
    return n === this.ownerDocument
  }
  contains(other) {
    for (let n = other; n; n = n.parentNode) if (n === this) return true
    return false
  }
  append(...kids) {
    for (const k of kids) {
      const node = typeof k === 'string' ? new FakeText(k) : k
      node.parentNode = this
      node.ownerDocument = this.ownerDocument ?? this
      for (const d of descendants(node)) d.ownerDocument = node.ownerDocument
      this.childNodes.push(node)
    }
    return this
  }
}

function* descendants(node) {
  for (const c of node.childNodes) {
    yield c
    yield* descendants(c)
  }
}

export class FakeText extends FakeNode {
  constructor(data) {
    super(3)
    this.data = data
  }
  get textContent() {
    return this.data
  }
}

/** Selector support: comma lists of tag names and `[attr="value"]`. */
function matches(el, selector) {
  return selector.split(',').some((part) => {
    const s = part.trim()
    const attr = /^\[([\w-]+)="([^"]*)"\]$/.exec(s)
    if (attr) return el.getAttribute(attr[1]) === attr[2]
    return el.tagName === s.toUpperCase()
  })
}

export class FakeElement extends FakeNode {
  constructor(tag, attrs = {}) {
    super(1)
    this.tagName = tag.toUpperCase()
    this.attrs = { ...attrs }
  }
  get className() {
    return this.attrs.class ?? ''
  }
  get id() {
    return this.attrs.id ?? ''
  }
  hasAttribute(name) {
    return name in this.attrs
  }
  getAttribute(name) {
    return this.attrs[name] ?? null
  }
  get textContent() {
    return this.childNodes.map((c) => c.textContent).join('')
  }
  get children() {
    return this.childNodes.filter((c) => c.nodeType === 1)
  }
  get firstElementChild() {
    return this.children[0] ?? null
  }
  get childElementCount() {
    return this.children.length
  }
  checkVisibility() {
    return true
  }
  querySelectorAll(selector) {
    return [...descendants(this)].filter((n) => n.nodeType === 1 && matches(n, selector))
  }
  querySelector(selector) {
    return this.querySelectorAll(selector)[0] ?? null
  }
}

/** `h('p', {class: 'x'}, 'text', h('b', {}, 'bold'))` */
export function h(tag, attrs = {}, ...kids) {
  return new FakeElement(tag, attrs).append(...kids)
}

export class FakeDocument extends FakeNode {
  constructor({ contentType = 'text/html', title = '', body }) {
    super(9)
    this.contentType = contentType
    this.title = title
    this.location = { hostname: 'example.test', pathname: '/', search: '' }
    this.ownerDocument = this
    const html = new FakeElement('html')
    html.ownerDocument = this
    this.append(html)
    html.append(h('head'), body)
    this.documentElement = html
    this.body = body
  }
  get isConnected() {
    return true
  }
  querySelectorAll(selector) {
    return this.documentElement.querySelectorAll(selector)
  }
  querySelector(selector) {
    return this.documentElement.querySelector(selector)
  }
}

/** Make `doc` the global document, with the globals extract.ts reads. */
export function installDocument(doc, selection = null) {
  globalThis.Node = NodeTypes
  globalThis.document = doc
  globalThis.window ??= globalThis
  globalThis.window.getSelection = () => selection
}

// ── playback stand-ins ──────────────────────────────────────────────────────

/**
 * A silent Audio. `FakeAudio.play` decides what play() does for every element,
 * so a test can stand in for Chrome's autoplay policy or an undecodable clip.
 */
export class FakeAudio extends EventTarget {
  static play = () => Promise.resolve()
  static last = null
  constructor() {
    super()
    this.src = ''
    this.playbackRate = 1
    this.preservesPitch = true
    this.preload = ''
    this.currentTime = 0
    this.duration = NaN
    this.ended = false
    this.paused = true
    this.error = null
    FakeAudio.last = this
  }
  get currentSrc() {
    return this.src
  }
  play() {
    this.paused = false
    return FakeAudio.play(this)
  }
  pause() {
    this.paused = true
  }
  load() {}
  removeAttribute(name) {
    if (name === 'src') this.src = ''
  }
}

/** Globals AloudPlayer touches, with no sound and no real timers left running. */
export function installPlaybackGlobals(chrome) {
  globalThis.window ??= globalThis
  globalThis.Audio = FakeAudio
  globalThis.requestAnimationFrame = (cb) => setTimeout(() => cb(0), 16)
  globalThis.cancelAnimationFrame = (id) => clearTimeout(id)
  globalThis.chrome = chrome
}

/**
 * A silent AudioContext: it decodes the harness's 16-bit mono WAVs, and its
 * buffer sources only record how they were started. A test moves `currentTime`
 * and calls a source's `onended` itself. Nothing reaches a speaker.
 */
export class FakeAudioContext {
  static last = null
  constructor() {
    this.state = 'running'
    this.currentTime = 0
    this.destination = {}
    this.sources = []
    FakeAudioContext.last = this
  }
  resume() {
    this.state = 'running'
    return Promise.resolve()
  }
  suspend() {
    this.state = 'suspended'
    return Promise.resolve()
  }
  decodeAudioData(bytes) {
    const view = new DataView(bytes)
    if (bytes.byteLength < 44 || view.getUint32(0) !== 0x52494646) {
      return Promise.reject(new DOMException('Unable to decode audio data', 'EncodingError'))
    }
    const data = new Float32Array((bytes.byteLength - 44) / 2)
    for (let i = 0; i < data.length; i++) data[i] = view.getInt16(44 + i * 2, true) / 32768
    return Promise.resolve(fakeBuffer(view.getUint32(24, true), [data]))
  }
  createBuffer(channels, length, sampleRate) {
    return fakeBuffer(sampleRate, Array.from({ length: channels }, () => new Float32Array(length)))
  }
  createBufferSource() {
    const node = {
      buffer: null,
      playbackRate: { value: 1 },
      onended: null,
      started: null,
      stopped: false,
      connect() {},
      disconnect() {},
      start(when, offset) {
        node.started = { when, offset }
      },
      stop() {
        node.stopped = true
      },
    }
    this.sources.push(node)
    return node
  }
}

function fakeBuffer(sampleRate, channels) {
  return {
    sampleRate,
    length: channels[0].length,
    numberOfChannels: channels.length,
    duration: channels[0].length / sampleRate,
    getChannelData: (c) => channels[c],
    copyToChannel: (source, c) => channels[c].set(source),
  }
}

/** A tiny but valid 16-bit mono WAV, base64 — what the worker hands back. */
export function wavBase64(samples = 2400, rate = 24000) {
  const data = samples * 2
  const buf = Buffer.alloc(44 + data)
  buf.write('RIFF', 0)
  buf.writeUInt32LE(36 + data, 4)
  buf.write('WAVE', 8)
  buf.write('fmt ', 12)
  buf.writeUInt32LE(16, 16)
  buf.writeUInt16LE(1, 20)
  buf.writeUInt16LE(1, 22)
  buf.writeUInt32LE(rate, 24)
  buf.writeUInt32LE(rate * 2, 28)
  buf.writeUInt16LE(2, 32)
  buf.writeUInt16LE(16, 34)
  buf.write('data', 36)
  buf.writeUInt32LE(data, 40)
  return buf.toString('base64')
}

/** Resolve once `predicate()` holds, polling; reject after `ms`. */
export async function until(predicate, ms = 5000, what = 'condition') {
  const deadline = Date.now() + ms
  while (!predicate()) {
    if (Date.now() > deadline) throw new Error(`timed out waiting for ${what}`)
    await new Promise((r) => setTimeout(r, 5))
  }
}

export const DEFAULT_TEST_PREFS = {
  voiceId: 'af_heart',
  rate: 1,
  skipSkippable: false,
  autoScroll: true,
  highlightWords: true,
  clickToJump: true,
  backendUrl: 'http://localhost:8000',
}
