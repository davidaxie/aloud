// ─────────────────────────────────────────────────────────────────────────────
// Web Audio playback, for pages whose CSP refuses the reader's media (J039).
//
// The <audio> element loads each clip from a blob: URL, and Chrome checks that
// load against the page's CSP media-src. The load starts from a timer task, not
// from the content script, so the isolated world's exemption does not apply: on
// a page whose media-src (or default-src) leaves out blob:, GitHub's among
// them, no sentence could ever play. Web Audio loads nothing, since the WAV
// bytes are decoded in memory, so the page's CSP has no say over it.
//
// WebAudioClip has the slice of HTMLAudioElement the player uses, so the player
// drives either one the same way: src, play/pause, playbackRate at the same
// pitch (see stretch.ts), currentTime in the clip's own seconds for the word
// highlight, and the loadedmetadata, ended and error events.
// ─────────────────────────────────────────────────────────────────────────────

import { timeStretch } from './stretch'

/** What the player uses of an audio element; WebAudioClip has the same. */
export interface Clip extends EventTarget {
  src: string
  readonly currentSrc: string
  playbackRate: number
  preservesPitch: boolean
  readonly currentTime: number
  readonly duration: number
  readonly ended: boolean
  play(): Promise<void>
  pause(): void
  removeAttribute(name: string): void
  load(): void
}

/**
 * How long a start waits for Chrome to let the audio run. Its autoplay policy
 * does not refuse a resume(), it leaves it waiting, so a context still not
 * running after this is a refusal: the player asks for the click on the bar.
 */
const RESUME_GRACE_MS = 1000

/** Whether this browser has Web Audio to fall back on. */
export function webAudioAvailable(): boolean {
  return typeof AudioContext === 'function'
}

function isRunning(ctx: AudioContext): boolean {
  return ctx.state === 'running'
}

export class WebAudioClip extends EventTarget implements Clip {
  preservesPitch = true
  duration = NaN

  private url = ''
  private rate = 1
  private ctx: AudioContext | null = null
  private buffer: AudioBuffer | null = null
  private decoding: Promise<AudioBuffer | null> = Promise.resolve(null)
  private node: AudioBufferSourceNode | null = null
  /** Bumped by every new src: a decode or play() for an older one stands down. */
  private srcGen = 0
  /** Bumped by every play() and pause(): an older play() stands down. */
  private playGen = 0
  /** Clip seconds where playback starts next, or stands while paused. */
  private offset = 0
  /** The context's clock when the playing node started. */
  private startedAt = 0
  private finished = false

  /** `blobFor` hands back the WAV behind one of the player's object URLs. */
  constructor(private readonly blobFor: (url: string) => Blob | undefined) {
    super()
  }

  get src(): string {
    return this.url
  }

  set src(url: string) {
    this.halt()
    this.srcGen++
    this.playGen++
    this.url = url
    this.buffer = null
    this.offset = 0
    this.duration = NaN
    this.finished = false
    this.decoding = url ? this.decode(url, this.srcGen) : Promise.resolve(null)
  }

  get currentSrc(): string {
    return this.url
  }

  get ended(): boolean {
    return this.finished
  }

  get playbackRate(): number {
    return this.rate
  }

  /** A new rate takes effect at once, from where the clip has got to. */
  set playbackRate(rate: number) {
    if (rate === this.rate) return
    const playing = this.node !== null
    if (playing) {
      this.offset = this.currentTime
      this.halt()
    }
    this.rate = rate
    if (playing) this.begin()
  }

  get currentTime(): number {
    if (!this.node || !this.ctx) return this.offset
    const t = this.offset + (this.ctx.currentTime - this.startedAt) * this.rate
    return Number.isFinite(this.duration) ? Math.min(this.duration, t) : t
  }

  async play(): Promise<void> {
    const src = this.srcGen
    const gen = ++this.playGen
    const superseded = () => src !== this.srcGen || gen !== this.playGen
    const buffer = await this.decoding
    if (superseded()) throw new DOMException('The play() request was interrupted.', 'AbortError')
    if (!buffer) throw new DOMException('This sentence’s audio could not be played.', 'NotSupportedError')
    await this.unlock()
    if (superseded()) throw new DOMException('The play() request was interrupted.', 'AbortError')
    if (this.node) return
    if (this.finished) {
      // As the element does: play() after the end starts the clip again.
      this.finished = false
      this.offset = 0
    }
    this.begin()
  }

  pause() {
    this.playGen++
    if (!this.node) return
    this.offset = this.currentTime
    this.halt()
  }

  removeAttribute(name: string) {
    if (name === 'src') this.src = ''
  }

  /** With no clip loaded, let the audio device go until the next play(). */
  load() {
    if (!this.url && this.ctx && isRunning(this.ctx)) void this.ctx.suspend().catch(() => {})
  }

  private context(): AudioContext {
    this.ctx ??= new AudioContext()
    return this.ctx
  }

  private async decode(url: string, gen: number): Promise<AudioBuffer | null> {
    try {
      const blob = this.blobFor(url)
      if (!blob) throw new Error('The clip is gone.')
      const buffer = await this.context().decodeAudioData(await blob.arrayBuffer())
      if (gen !== this.srcGen) return null
      this.buffer = buffer
      this.duration = buffer.duration
      this.dispatchEvent(new Event('loadedmetadata'))
      return buffer
    } catch {
      if (gen !== this.srcGen) return null
      this.dispatchEvent(new Event('error'))
      return null
    }
  }

  /** Get the context running, or report the autoplay refusal as the element does. */
  private async unlock(): Promise<void> {
    const ctx = this.context()
    if (isRunning(ctx)) return
    let timer: ReturnType<typeof setTimeout> | undefined
    await Promise.race([
      ctx.resume().catch(() => {}),
      new Promise<void>((resolve) => (timer = setTimeout(resolve, RESUME_GRACE_MS))),
    ])
    clearTimeout(timer)
    if (!isRunning(ctx)) {
      throw new DOMException('Chrome did not let the audio start.', 'NotAllowedError')
    }
  }

  /** Start the loaded clip from `offset` at the current rate. */
  private begin() {
    const buffer = this.buffer
    if (!buffer) return
    const ctx = this.context()
    const node = ctx.createBufferSource()
    let from = this.offset
    if (this.rate !== 1 && this.preservesPitch) {
      node.buffer = this.stretched(buffer, from)
      from = 0
    } else {
      node.buffer = buffer
      node.playbackRate.value = this.rate
    }
    node.connect(ctx.destination)
    node.onended = () => {
      if (this.node !== node) return
      this.node = null
      this.offset = this.duration
      this.finished = true
      this.dispatchEvent(new Event('ended'))
    }
    this.node = node
    this.startedAt = ctx.currentTime
    node.start(0, from)
  }

  /** The rest of the clip from `from` seconds, sped up at the same pitch. */
  private stretched(buffer: AudioBuffer, from: number): AudioBuffer {
    const start = Math.min(buffer.length, Math.round(from * buffer.sampleRate))
    const channels: Float32Array<ArrayBuffer>[] = []
    for (let c = 0; c < buffer.numberOfChannels; c++) channels.push(buffer.getChannelData(c).subarray(start))
    const out = timeStretch(channels, this.rate, buffer.sampleRate)
    const result = this.context().createBuffer(out.length, Math.max(1, out[0].length), buffer.sampleRate)
    out.forEach((data, c) => result.copyToChannel(data, c))
    return result
  }

  /** Stop the playing node, if any, without it counting as the clip ending. */
  private halt() {
    const node = this.node
    if (!node) return
    this.node = null
    node.onended = null
    try {
      node.stop()
    } catch {
      // never started
    }
    node.disconnect()
  }
}
