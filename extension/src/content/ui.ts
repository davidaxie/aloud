// ─────────────────────────────────────────────────────────────────────────────
// The floating player bar.
//
// Lives in a closed-off shadow root attached to a single <div> on documentElement.
// `:host { all: initial }` plus the shadow boundary means the page cannot style
// us and we cannot style the page — no reset-CSS arms race, no inherited
// 14px-Comic-Sans surprises. The visual language (warm paper, one orange accent,
// pill transport, light/dark twins) mirrors the desktop reader.
//
// The bar is a dumb view: it renders a snapshot and reports intent through
// callbacks. It owns no playback state.
// ─────────────────────────────────────────────────────────────────────────────

import type { PlayerStatus, ReaderEngineState, Voice } from '../shared/types'
import { fillVoiceSelect } from '../shared/voices'
import { RELOADED_MESSAGE } from './api'

export interface BarView {
  status: PlayerStatus
  /** 0-based sentence index, -1 when nothing is cued. */
  index: number
  total: number
  title: string
  error: string | null
  voices: Voice[]
  voiceId: string
  rate: number
  /**
   * What the speech engine is doing — `warming` is not a fault (§1.2), and
   * `reloaded` is not the engine at all but the extension gone from this page.
   */
  engine: ReaderEngineState
  /** The page was longer than the reader's safety valves, so the end isn't the end. */
  truncated: boolean
  /** Listening seconds of audio ready ahead of the playhead (F2.7). */
  bufferAhead: number
  /** Last sentence index whose audio is contiguously ready; -1 when none is. */
  readyThrough: number
}

export interface BarCallbacks {
  onToggle(): void
  onNext(): void
  onPrev(): void
  onClose(): void
  /** Track click: 0..1 through the document. */
  onSeekFraction(fraction: number): void
  onVoice(voiceId: string): void
  onRate(rate: number): void
}

const RATE_PRESETS = [0.5, 0.75, 1, 1.25, 1.5, 1.75, 2, 2.5, 3]

/** Keyboard shortcuts as Chrome actually bound them; empty when the user has none. */
export interface Shortcuts {
  toggle: string
  next: string
  prev: string
}

/**
 * A tooltip that names its shortcut only when one exists. The bindings come
 * from chrome.commands, never from a constant: Chrome refuses a suggested key
 * that clashes with one of its own, and the user can rebind any of them.
 */
export function withShortcut(label: string, shortcut: string | undefined): string {
  return shortcut ? `${label} (${shortcut})` : label
}

/**
 * The play button's name. While a sentence is buffering the button pauses, so
 * it is named Pause, as in the web app and on iPhone and Mac (H034, I022);
 * `busy` marks the wait.
 */
export function playButtonLabel(status: PlayerStatus): { label: 'Play' | 'Pause'; busy: boolean } {
  const pauses = status === 'playing' || status === 'buffering'
  return { label: pauses ? 'Pause' : 'Play', busy: status === 'buffering' }
}

/** What the polite live region says while the play button waits on audio. */
export const LOADING_ANNOUNCEMENT = 'Loading audio'

/** The status line when the last sentence ends a page the reader cut short. */
export const TRUNCATED_MESSAGE = 'Reached Aloud’s length limit — select later text to go on.'

const ICONS = {
  play: '<svg viewBox="0 0 24 24" width="20" height="20" fill="currentColor" aria-hidden="true"><path d="M8 5.14v13.72a1 1 0 0 0 1.54.84l10.1-6.86a1 1 0 0 0 0-1.68L9.54 4.3A1 1 0 0 0 8 5.14Z"/></svg>',
  pause: '<svg viewBox="0 0 24 24" width="20" height="20" fill="currentColor" aria-hidden="true"><rect x="6.5" y="4.5" width="4" height="15" rx="1.4"/><rect x="13.5" y="4.5" width="4" height="15" rx="1.4"/></svg>',
  spinner: '<svg class="spin" viewBox="0 0 24 24" width="20" height="20" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" aria-hidden="true"><path d="M12 3a9 9 0 1 0 9 9" /></svg>',
  prev: '<svg viewBox="0 0 24 24" width="17" height="17" fill="currentColor" aria-hidden="true"><path d="M18.3 5.2a1 1 0 0 0-1.54-.84L8.5 9.9V5.6a1 1 0 0 0-1.54-.84L1.6 8.3a1 1 0 0 0 0 1.68l5.36 3.54A1 1 0 0 0 8.5 12.7V8.4l8.26 5.44a1 1 0 0 0 1.54-.84V5.2Z" transform="translate(2.2 2.8)"/></svg>',
  next: '<svg viewBox="0 0 24 24" width="17" height="17" fill="currentColor" aria-hidden="true"><path d="M1.6 5.2a1 1 0 0 1 1.54-.84L11.4 9.9V5.6a1 1 0 0 1 1.54-.84l5.36 3.54a1 1 0 0 1 0 1.68l-5.36 3.54a1 1 0 0 1-1.54-.84V8.4L3.14 13.84A1 1 0 0 1 1.6 13V5.2Z" transform="translate(2.2 2.8)"/></svg>',
  close: '<svg viewBox="0 0 24 24" width="15" height="15" fill="none" stroke="currentColor" stroke-width="2.1" stroke-linecap="round" aria-hidden="true"><path d="M6 6l12 12M18 6L6 18"/></svg>',
  caret: '<svg class="caret" viewBox="0 0 24 24" width="12" height="12" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M6 9l6 6 6-6"/></svg>',
  wave: '<svg viewBox="0 0 24 24" width="15" height="15" fill="currentColor" aria-hidden="true"><rect x="4" y="8.5" width="2.6" height="7" rx="1.3"/><rect x="10.7" y="4.5" width="2.6" height="15" rx="1.3"/><rect x="17.4" y="7" width="2.6" height="10" rx="1.3"/></svg>',
}

const CSS = `
:host {
  all: initial;
  position: fixed;
  left: 50%;
  bottom: 22px;
  transform: translateX(-50%);
  z-index: 2147483647;
  contain: layout style;

  --bg: rgba(255, 255, 255, 0.86);
  --text: #131314;
  --muted: #6a6a6f;
  --faint: #9b9ba2;
  --line: #e2e2e6;
  --line-strong: #d3d3d9;
  --accent: #ff9500;
  --accent-strong: #e6850a;
  --accent-soft: rgba(255, 149, 0, 0.14);
  --danger: #c0392b;
  --shadow: 0 6px 16px rgba(0,0,0,.10), 0 20px 48px rgba(0,0,0,.16);
  --ease: cubic-bezier(.22,.61,.36,1);
  --font: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
}
@media (prefers-color-scheme: dark) {
  :host {
    --bg: rgba(24, 24, 26, 0.88);
    --text: #f2f2f4;
    --muted: #a3a3ab;
    --faint: #74747c;
    --line: #313136;
    --line-strong: #43434a;
    --accent: #ff9f0a;
    --accent-strong: #ffb340;
    --accent-soft: rgba(255, 159, 10, 0.20);
    --danger: #f0a79b;
    --shadow: 0 8px 20px rgba(0,0,0,.5), 0 24px 56px rgba(0,0,0,.55);
  }
}

.bar {
  font-family: var(--font);
  color: var(--text);
  background: var(--bg);
  -webkit-backdrop-filter: saturate(1.4) blur(20px);
  backdrop-filter: saturate(1.4) blur(20px);
  border: 1px solid var(--line);
  border-radius: 18px;
  box-shadow: var(--shadow);
  overflow: hidden;
  width: min(660px, calc(100vw - 32px));
  animation: rise .26s var(--ease);
}
@keyframes rise {
  from { opacity: 0; transform: translateY(14px) scale(.985); }
  to { opacity: 1; transform: none; }
}

.track {
  position: relative;
  height: 3px;
  background: var(--line);
  cursor: pointer;
}
.track::before { content: ""; position: absolute; inset: -7px 0; }
.fill {
  position: absolute;
  inset: 0 auto 0 0;
  width: 0;
  background: linear-gradient(90deg, var(--accent), var(--accent-strong));
  transition: width .2s var(--ease);
}
/* How far ahead audio is actually ready — the same information the desktop
   reader paints, so a stall is visible a few seconds before it is audible. */
.buffer {
  position: absolute;
  inset: 0 auto 0 0;
  width: 0;
  background: var(--accent-soft);
  transition: width .3s var(--ease);
}

.row {
  display: flex;
  align-items: center;
  gap: 12px;
  padding: 9px 12px 9px 10px;
}

.transport { display: flex; align-items: center; gap: 2px; flex: 0 0 auto; }

button {
  font: inherit;
  color: inherit;
  background: none;
  border: none;
  padding: 0;
  cursor: pointer;
  -webkit-appearance: none;
  appearance: none;
}
button:focus-visible, select:focus-visible {
  outline: 2px solid var(--accent);
  outline-offset: 2px;
}

.icon {
  display: inline-grid;
  place-items: center;
  width: 32px;
  height: 32px;
  border-radius: 999px;
  color: var(--muted);
  transition: background-color .18s var(--ease), color .18s var(--ease), transform .12s var(--ease);
}
.icon:hover { background: var(--accent-soft); color: var(--text); }
.icon:active { transform: scale(.93); }

.play {
  display: grid;
  place-items: center;
  width: 40px;
  height: 40px;
  margin: 0 2px;
  border-radius: 999px;
  color: #fff;
  background: var(--accent);
  box-shadow: 0 2px 8px rgba(255,149,0,.35);
  transition: transform .14s var(--ease), background-color .18s var(--ease);
}
.play:hover { background: var(--accent-strong); transform: scale(1.05); }
.play:active { transform: scale(.96); }

.meta { flex: 1 1 auto; min-width: 0; display: flex; flex-direction: column; gap: 1px; }
.title {
  font-size: 13px;
  font-weight: 600;
  letter-spacing: -.005em;
  line-height: 1.25;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}
.sub {
  font-size: 11.5px;
  color: var(--faint);
  font-variant-numeric: tabular-nums;
  letter-spacing: .01em;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}
.sub.is-error { color: var(--danger); }
/* Warming is a working engine, not a broken one — it gets the accent, not red. */
.sub.is-pending { color: var(--accent-strong); }
/* Heard, not seen: the play button's loading announcement. */
.live {
  position: absolute;
  width: 1px;
  height: 1px;
  margin: -1px;
  padding: 0;
  overflow: hidden;
  clip: rect(0 0 0 0);
  white-space: nowrap;
  border: 0;
}

.controls { display: flex; align-items: center; gap: 6px; flex: 0 0 auto; }

.chip {
  position: relative;
  display: inline-flex;
  align-items: center;
  height: 30px;
  padding: 0 6px 0 8px;
  border: 1px solid var(--line-strong);
  border-radius: 999px;
  color: var(--muted);
  transition: border-color .18s var(--ease), color .18s var(--ease);
}
.chip:hover { border-color: var(--faint); color: var(--text); }
.chip select {
  font: inherit;
  font-size: 12px;
  font-weight: 550;
  color: var(--text);
  background: transparent;
  border: none;
  -webkit-appearance: none;
  appearance: none;
  cursor: pointer;
  padding: 0 14px 0 4px;
  max-width: 104px;
  text-overflow: ellipsis;
}
.chip .caret {
  position: absolute;
  right: 6px;
  pointer-events: none;
  color: var(--faint);
}
.chip.rate select { max-width: 56px; font-variant-numeric: tabular-nums; }
.chip .wave { color: var(--faint); flex: 0 0 auto; }

.spin { animation: spin .9s linear infinite; }
@keyframes spin { to { transform: rotate(360deg); } }

@media (max-width: 620px) {
  .meta { display: none; }
  .chip select { max-width: 72px; }
}
@media (prefers-reduced-motion: reduce) {
  .bar, .fill, .icon, .play { animation: none; transition: none; }
}
`

type Tone = 'normal' | 'pending' | 'error'

/**
 * The single status line, most severe first (F4.2, F4.5).
 *
 * Three of these used to collapse into one another. They must not: `offline` is
 * the user's to fix and says how, `warming` fixes itself and must never be
 * styled as a fault, and `buffering` is the engine working as designed. Every
 * error names a cause and, where the user can act, an action.
 */
export function statusLine(view: BarView): { text: string; tone: Tone } {
  // Nothing on this page can reach the extension any more; restarting the
  // backend (what "offline" asks for) would not help.
  if (view.engine === 'reloaded') return { text: RELOADED_MESSAGE, tone: 'error' }
  if (view.engine === 'offline') {
    return { text: 'Speech engine offline — start the Aloud backend.', tone: 'error' }
  }
  if (view.error) return { text: view.error, tone: 'error' }
  if (view.engine === 'warming') {
    return { text: 'Warming up the voice engine…', tone: 'pending' }
  }
  if (view.status === 'buffering') return { text: 'Buffering…', tone: 'pending' }
  if (view.status === 'ended') {
    return view.truncated
      ? { text: TRUNCATED_MESSAGE, tone: 'pending' }
      : { text: 'Finished', tone: 'normal' }
  }
  const position = view.index >= 0 ? view.index + 1 : 0
  return { text: `${position} / ${view.total}`, tone: 'normal' }
}

export class PlayerBar {
  readonly host: HTMLDivElement

  private root: ShadowRoot
  private trackEl!: HTMLDivElement
  private fillEl!: HTMLDivElement
  private bufferEl!: HTMLDivElement
  private playEl!: HTMLButtonElement
  private liveEl!: HTMLSpanElement
  /** The play button's current name and the toggle shortcut its tooltip names. */
  private playLabel: 'Play' | 'Pause' = 'Play'
  private toggleKey: string | undefined
  private titleEl!: HTMLDivElement
  private subEl!: HTMLDivElement
  private voiceEl!: HTMLSelectElement
  private rateEl!: HTMLSelectElement

  /** Signature of the rendered voice list, so we only rebuild <option>s on change. */
  private voiceSig = ''

  constructor(private cb: BarCallbacks) {
    this.host = document.createElement('div')
    this.host.id = 'aloud-player-root'
    // Belt and braces: the shadow boundary hides us from page CSS, and this
    // marker lets our own extractor recognise and skip the subtree.
    this.host.setAttribute('data-aloud', 'ui')
    // Closed: the page's scripts share this DOM, and through an open root they
    // could work the controls — plant a voice that is synced to every tab
    // (H033). `root` is the only way in.
    this.root = this.host.attachShadow({ mode: 'closed' })
    this.render()
    document.documentElement.appendChild(this.host)
  }

  private render() {
    const style = document.createElement('style')
    style.textContent = CSS

    const bar = document.createElement('div')
    bar.className = 'bar'
    bar.innerHTML = `
      <div class="track" role="progressbar" aria-label="Reading progress" aria-valuemin="0" aria-valuemax="100"><div class="buffer"></div><div class="fill"></div></div>
      <div class="row">
        <div class="transport">
          <button class="icon" data-act="prev" title="Previous sentence" aria-label="Previous sentence">${ICONS.prev}</button>
          <button class="play" data-act="toggle" title="Play" aria-label="Play" aria-busy="false">${ICONS.play}</button>
          <span class="live" role="status" aria-live="polite"></span>
          <button class="icon" data-act="next" title="Next sentence" aria-label="Next sentence">${ICONS.next}</button>
        </div>
        <div class="meta">
          <div class="title"></div>
          <div class="sub"></div>
        </div>
        <div class="controls">
          <span class="chip voice">${ICONS.wave}<select aria-label="Voice"></select>${ICONS.caret}</span>
          <span class="chip rate"><select aria-label="Speed"></select>${ICONS.caret}</span>
          <button class="icon" data-act="close" title="Stop reading (Esc)" aria-label="Stop reading">${ICONS.close}</button>
        </div>
      </div>
    `
    this.root.append(style, bar)

    this.trackEl = bar.querySelector('.track')!
    this.fillEl = bar.querySelector('.fill')!
    this.bufferEl = bar.querySelector('.buffer')!
    this.playEl = bar.querySelector('.play')!
    this.liveEl = bar.querySelector('.live')!
    this.titleEl = bar.querySelector('.title')!
    this.subEl = bar.querySelector('.sub')!
    this.voiceEl = bar.querySelector('.chip.voice select')!
    this.rateEl = bar.querySelector('.chip.rate select')!

    for (const preset of RATE_PRESETS) {
      const opt = document.createElement('option')
      opt.value = String(preset)
      opt.textContent = `${preset}×`
      this.rateEl.append(opt)
    }

    // Every handler ignores untrusted events: a click or change the page
    // dispatched is the page's, not the user's (H033).
    bar.addEventListener('click', (e) => {
      if (!e.isTrusted) return
      const btn = (e.target as Element).closest?.('[data-act]') as HTMLElement | null
      if (!btn) return
      e.preventDefault()
      e.stopPropagation()
      switch (btn.dataset.act) {
        case 'toggle': this.cb.onToggle(); break
        case 'next': this.cb.onNext(); break
        case 'prev': this.cb.onPrev(); break
        case 'close': this.cb.onClose(); break
      }
    })

    this.trackEl.addEventListener('pointerdown', (e) => {
      if (!e.isTrusted) return
      const rect = this.trackEl.getBoundingClientRect()
      this.cb.onSeekFraction(Math.min(1, Math.max(0, (e.clientX - rect.left) / rect.width)))
    })

    this.voiceEl.addEventListener('change', (e) => {
      if (e.isTrusted) this.cb.onVoice(this.voiceEl.value)
    })
    this.rateEl.addEventListener('change', (e) => {
      if (e.isTrusted) this.cb.onRate(Number(this.rateEl.value))
    })

    // The page must never see our clicks/keys as its own.
    for (const type of ['keydown', 'keyup', 'pointerdown', 'mousedown'] as const) {
      bar.addEventListener(type, (e) => e.stopPropagation())
    }
  }

  /** Rebuild the voice <option>s, grouped by language, only when the list changes. */
  private syncVoices(voices: Voice[], voiceId: string) {
    const sig = voices.map((v) => v.id).join(',')
    if (sig !== this.voiceSig) {
      this.voiceSig = sig
      if (!fillVoiceSelect(this.voiceEl, voices)) {
        // Backend not reachable yet — keep the chip meaningful rather than blank.
        const opt = document.createElement('option')
        opt.value = voiceId
        opt.textContent = 'Default voice'
        this.voiceEl.append(opt)
      }
    }
    if (this.voiceEl.value !== voiceId) this.voiceEl.value = voiceId
  }

  /** Name the real keyboard shortcuts in the transport tooltips. */
  setShortcuts(keys: Shortcuts) {
    const label = { prev: 'Previous sentence', next: 'Next sentence' }
    for (const act of ['prev', 'next'] as const) {
      const button = this.root.querySelector(`[data-act="${act}"]`)
      button?.setAttribute('title', withShortcut(label[act], keys[act]))
    }
    // The play button's tooltip says what a press does now, as its name does.
    this.toggleKey = keys.toggle
    this.playEl.setAttribute('title', withShortcut(this.playLabel, this.toggleKey))
  }

  update(view: BarView) {
    const playing = view.status === 'playing'
    const buffering = view.status === 'buffering'
    this.playEl.innerHTML = buffering ? ICONS.spinner : playing ? ICONS.pause : ICONS.play
    // A press while buffering pauses, so the button is named Pause then (I022).
    const { label, busy } = playButtonLabel(view.status)
    this.playLabel = label
    this.playEl.setAttribute('aria-label', label)
    this.playEl.setAttribute('title', withShortcut(label, this.toggleKey))
    this.playEl.setAttribute('aria-busy', String(busy))
    const announcement = busy ? LOADING_ANNOUNCEMENT : ''
    // Rewritten only on a change, so each paint does not announce it again.
    if (this.liveEl.textContent !== announcement) this.liveEl.textContent = announcement

    this.titleEl.textContent = view.title
    this.titleEl.title = view.title

    // One line, most severe wins (F4.2). The order matters: a warming engine
    // must never read as an offline one, and "buffering" must never read as a
    // fault — each of these is a genuinely different situation for the user.
    const { text, tone } = statusLine(view)
    this.subEl.textContent = text
    this.subEl.classList.toggle('is-error', tone === 'error')
    this.subEl.classList.toggle('is-pending', tone === 'pending')

    const progress = view.total > 0 ? Math.max(0, view.index + 1) / view.total : 0
    // Ready-through is a sentence boundary, so it is already in the track's units.
    const buffered =
      view.total > 0 ? Math.max(progress, Math.max(0, view.readyThrough + 1) / view.total) : 0
    this.fillEl.style.width = `${(progress * 100).toFixed(2)}%`
    this.bufferEl.style.width = `${(buffered * 100).toFixed(2)}%`
    this.trackEl.setAttribute('aria-valuenow', String(Math.round(progress * 100)))

    this.syncVoices(view.voices, view.voiceId)
    const rate = String(view.rate)
    if (this.rateEl.value !== rate) {
      // A rate typed elsewhere might not be one of our presets — add it so the
      // select can actually display it rather than silently snapping.
      if (!RATE_PRESETS.includes(view.rate)) {
        const opt = document.createElement('option')
        opt.value = rate
        opt.textContent = `${view.rate}×`
        this.rateEl.append(opt)
      }
      this.rateEl.value = rate
    }
  }

  destroy() {
    this.host.remove()
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Toast — for the handful of things that happen before there is a player bar to
// put a message in ("no readable text here", "can't read a PDF in the browser").
// ─────────────────────────────────────────────────────────────────────────────

const TOAST_CSS = `
:host {
  all: initial;
  position: fixed;
  left: 50%;
  bottom: 22px;
  transform: translateX(-50%);
  z-index: 2147483647;
}
.toast {
  font-family: ${'-apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif'};
  font-size: 13px;
  font-weight: 500;
  line-height: 1.4;
  color: #f2f2f4;
  background: rgba(28, 28, 30, 0.94);
  -webkit-backdrop-filter: blur(20px);
  backdrop-filter: blur(20px);
  border: 1px solid rgba(255, 255, 255, 0.10);
  border-radius: 14px;
  box-shadow: 0 8px 20px rgba(0,0,0,.34), 0 24px 56px rgba(0,0,0,.4);
  padding: 11px 16px;
  max-width: min(420px, calc(100vw - 32px));
  display: flex;
  align-items: center;
  gap: 9px;
  animation: rise .22s cubic-bezier(.22,.61,.36,1);
}
.dot {
  width: 7px; height: 7px; border-radius: 50%;
  background: #ff9f0a;
  box-shadow: 0 0 0 3px rgba(255,159,10,.18);
  flex: 0 0 auto;
}
.toast.out { animation: fade .28s ease forwards; }
@keyframes rise { from { opacity: 0; transform: translateY(10px); } to { opacity: 1; transform: none; } }
@keyframes fade { to { opacity: 0; transform: translateY(6px); } }
`

/** Show a transient message. Returns a function that dismisses it early. */
export function showToast(message: string, ms = 3600): () => void {
  const host = document.createElement('div')
  host.setAttribute('data-aloud', 'toast')
  const root = host.attachShadow({ mode: 'closed' }) // as the bar's (H033)

  const style = document.createElement('style')
  style.textContent = TOAST_CSS
  const toast = document.createElement('div')
  toast.className = 'toast'
  const dot = document.createElement('span')
  dot.className = 'dot'
  const text = document.createElement('span')
  text.textContent = message
  toast.append(dot, text)
  root.append(style, toast)
  document.documentElement.appendChild(host)

  let done = false
  const dismiss = () => {
    if (done) return
    done = true
    toast.classList.add('out')
    setTimeout(() => host.remove(), 300)
  }
  const timer = setTimeout(dismiss, ms)
  return () => {
    clearTimeout(timer)
    dismiss()
  }
}
