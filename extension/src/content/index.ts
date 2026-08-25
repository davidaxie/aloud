// ─────────────────────────────────────────────────────────────────────────────
// Content script entry — the reader controller.
//
// Injected on demand (never declared for <all_urls>), so this file may be
// evaluated at most once per page but must survive being *asked* to inject
// again: the service worker pings first, and a second Alt+A has to reach the
// existing reader rather than spawn a rival one. Hence the window-level guard.
//
// It owns the wiring, not the logic:
//   extract.ts     page → sentences + offset index
//   player.ts      sentences → gap-free audio, position, word timing
//   highlight.ts   offsets → live Ranges painted on the page, auto-scroll
//   ui.ts          the floating bar
// ─────────────────────────────────────────────────────────────────────────────

import { loadPrefs, savePrefs, watchPrefs } from '../shared/prefs'
import type { TabAction, TabRequest, TabResponse, TabStateSnapshot } from '../shared/protocol'
import type { EngineState, PlayerStatus, Prefs, ReadDoc, Voice } from '../shared/types'
import { getHealth, getVoices } from './api'
import { extractPage, extractSelection, offsetOf, type Extraction } from './extract'
import { Highlighter } from './highlight'
import { AloudPlayer } from './player'
import { PlayerBar, showToast } from './ui'

/** Health poll cadence while the engine is warming, offline, or struggling. */
const HEALTH_POLL_BUSY_MS = 4_000
/** …and once everything is working. Cheap enough to leave running while reading. */
const HEALTH_POLL_IDLE_MS = 30_000

// A second injection would create a second player over the same page. Bail out
// early; the already-running instance keeps serving messages.
declare global {
  interface Window {
    __aloudReaderInjected?: boolean
  }
}
if (window.__aloudReaderInjected) {
  // eslint-disable-next-line no-console
  console.debug('[Aloud] reader already present')
} else {
  window.__aloudReaderInjected = true
  void main()
}

async function main() {
  let prefs: Prefs = await loadPrefs()

  let extraction: Extraction | null = null
  let bar: PlayerBar | null = null
  let highlighter: Highlighter | null = null
  let voices: Voice[] = []

  let status: PlayerStatus = 'idle'
  let error: string | null = null
  let sentenceIndex = -1
  let engine: EngineState = 'ok'
  let bufferAhead = 0
  let readyThrough = -1

  const player = new AloudPlayer({
    prefs: () => prefs,
    onStatus: (next, err) => {
      status = next
      error = err
      if (err) showToastOnce(err)
      // An error is worth an immediate second opinion from /health: it decides
      // whether the bar says "offline" or names the real, narrower cause (F1.7).
      if (err) void pollHealth()
      paintBar()
    },
    onSentence: (index) => {
      sentenceIndex = index
      paintSentence()
      paintBar()
    },
    onWord: (tokenIndex) => paintWord(tokenIndex),
    // A skipped sentence is a transient toast, never a stop (F1.5, F4.3).
    onSkip: (_index, message) => showToastOnce(message),
    onBuffer: (seconds, through) => {
      bufferAhead = seconds
      readyThrough = through
      paintBar()
    },
  })

  // ── rendering ─────────────────────────────────────────────────────────────

  function paintBar() {
    bar?.update({
      status,
      index: sentenceIndex,
      total: player.total,
      title: extraction?.title ?? '',
      error,
      voices,
      voiceId: prefs.voiceId,
      rate: prefs.rate,
      engine,
      bufferAhead,
      readyThrough,
    })
  }

  function paintSentence() {
    if (!highlighter || !extraction) return
    const sentence = extraction.sentences[sentenceIndex]
    if (!sentence) {
      highlighter.setSentence(null)
      highlighter.setWord(null)
      return
    }
    const range = highlighter.rangeFor(sentence.start, sentence.end)
    highlighter.setSentence(range)
    highlighter.setWord(null)
    if (range && prefs.autoScroll) highlighter.scrollIntoView(range)
  }

  function paintWord(tokenIndex: number) {
    if (!highlighter || !extraction) return
    if (!prefs.highlightWords || tokenIndex < 0) {
      highlighter.setWord(null)
      return
    }
    const sentence = extraction.sentences[sentenceIndex]
    const token = sentence?.tokens[tokenIndex]
    if (!sentence || !token || !token.isWord) {
      highlighter.setWord(null)
      return
    }
    // Token offsets are the running sum of token lengths — the tokenizer is
    // non-destructive, so this lands exactly on the word in the source text.
    let offset = sentence.start
    for (let i = 0; i < tokenIndex; i++) offset += sentence.tokens[i].text.length
    highlighter.setWord(highlighter.rangeFor(offset, offset + token.text.length))
  }

  // Don't stack duplicate toasts for a backend that stays down.
  let lastToast = ''
  let clearToast: (() => void) | null = null
  function showToastOnce(message: string) {
    if (message === lastToast) return
    lastToast = message
    clearToast?.()
    clearToast = showToast(message, 5000)
    setTimeout(() => {
      if (lastToast === message) lastToast = ''
    }, 6000)
  }

  // ── activation ────────────────────────────────────────────────────────────

  function ensureChrome() {
    if (!highlighter) highlighter = new Highlighter(extraction?.slices ?? [])
    if (!bar) {
      bar = new PlayerBar({
        onToggle: () => player.toggle(),
        onNext: () => player.next(),
        onPrev: () => player.prev(),
        onClose: () => teardown(),
        onSeekFraction: (f) => {
          const target = Math.min(player.total - 1, Math.floor(f * player.total))
          player.seekTo(Math.max(0, target))
        },
        onVoice: (voiceId) => void savePrefs({ voiceId }),
        onRate: (rate) => void savePrefs({ rate }),
      })
    }
  }

  /** Parse the page (or the selection) and start reading it. */
  function start(mode: 'page' | 'selection'): boolean {
    const host = bar?.host ?? null
    const next = mode === 'selection' ? extractSelection(host) : extractPage(host)

    if (!next) {
      showToastOnce(
        mode === 'selection'
          ? 'Nothing selected to read.'
          : document.contentType === 'application/pdf'
            ? 'Chrome renders PDFs in a plugin Aloud can’t reach — open it in the Aloud app instead.'
            : 'No readable text found on this page.',
      )
      return false
    }

    extraction = next
    ensureChrome()
    highlighter!.setSlices(next.slices)
    highlighter!.clear()
    player.load({ title: next.title, sentences: next.sentences } satisfies ReadDoc)
    paintBar()
    player.play()
    void pollHealth()

    if (voices.length === 0) {
      void getVoices().then((v) => {
        voices = v.voices
        paintBar()
      })
    }
    return true
  }

  function teardown() {
    clearTimeout(healthTimer)
    player.stop()
    highlighter?.destroy()
    highlighter = null
    bar?.destroy()
    bar = null
    extraction = null
    sentenceIndex = -1
    error = null
    clearToast?.()
  }

  const isActive = () => extraction !== null

  // ── engine health ─────────────────────────────────────────────────────────
  // Only /health may call the engine offline (§1.4). A failed synthesis is a
  // failed synthesis: blaming a backend that is up and answering is exactly the
  // dishonesty F1.7 forbids, and it sends the user off to restart something that
  // was never down. Polling is adaptive — often while something is wrong or
  // still warming, rarely once everything works — so a healthy page costs one
  // localhost request every 30 seconds and lets the MV3 worker sleep between them.

  let healthTimer = 0
  let healthInFlight = false

  async function pollHealth() {
    if (healthInFlight) return
    healthInFlight = true
    try {
      const report = await getHealth()
      if (report.state !== engine) {
        engine = report.state
        paintBar()
      }
    } finally {
      healthInFlight = false
      scheduleHealth()
    }
  }

  function scheduleHealth() {
    clearTimeout(healthTimer)
    if (!isActive()) return
    const unsettled = engine !== 'ok' || status === 'buffering' || status === 'error'
    healthTimer = window.setTimeout(
      () => void pollHealth(),
      unsettled ? HEALTH_POLL_BUSY_MS : HEALTH_POLL_IDLE_MS,
    )
  }

  // ── external commands (service worker / popup) ────────────────────────────

  function handle(action: TabAction) {
    switch (action) {
      case 'start':
        // Already reading this page? Treat it as resume rather than restart, so
        // a second Alt+A from the popup doesn't lose the reader's place.
        if (isActive()) player.play()
        else start('page')
        break
      case 'start-selection':
        start('selection')
        break
      case 'toggle':
        if (isActive()) player.toggle()
        else if (!window.getSelection()?.isCollapsed) start('selection')
        else start('page')
        break
      case 'next':
        if (isActive()) player.next()
        break
      case 'prev':
        if (isActive()) player.prev()
        break
      case 'stop':
        teardown()
        break
    }
  }

  chrome.runtime.onMessage.addListener(
    (msg: TabRequest, _sender, sendResponse: (r: TabResponse) => void) => {
      switch (msg.kind) {
        case 'ping':
          sendResponse({ kind: 'pong' })
          return false
        case 'command':
          handle(msg.action)
          sendResponse({ kind: 'ok' })
          return false
        case 'state':
          sendResponse({ kind: 'state', state: snapshot() })
          return false
        default:
          return false
      }
    },
  )

  function snapshot(): TabStateSnapshot {
    return {
      active: isActive(),
      status,
      index: sentenceIndex,
      total: player.total,
      title: extraction?.title ?? '',
      error,
    }
  }

  // ── settings changed anywhere (popup, another tab) ────────────────────────

  watchPrefs((next) => {
    const wordsChanged = next.highlightWords !== prefs.highlightWords
    prefs = next
    player.applyPrefs()
    if (wordsChanged) paintWord(-1)
    paintBar()
  })

  // ── click a sentence to jump there ────────────────────────────────────────

  /** Interactive things a click means something else on — never hijack those. */
  const INTERACTIVE = 'a,button,input,select,textarea,label,summary,[contenteditable],[role="button"],[role="link"],[role="tab"],[onclick]'

  /** Chrome exposes caretRangeFromPoint; the standard name is caretPositionFromPoint. */
  function caretAt(x: number, y: number): { node: Node; offset: number } | null {
    const doc = document as Document & {
      caretRangeFromPoint?: (x: number, y: number) => Range | null
      caretPositionFromPoint?: (
        x: number,
        y: number,
      ) => { offsetNode: Node; offset: number } | null
    }
    const range = doc.caretRangeFromPoint?.(x, y)
    if (range) return { node: range.startContainer, offset: range.startOffset }
    const pos = doc.caretPositionFromPoint?.(x, y)
    return pos ? { node: pos.offsetNode, offset: pos.offset } : null
  }

  /** Sentence containing (or immediately following) a flat-text offset. */
  function sentenceAtOffset(offset: number): number {
    if (!extraction) return -1
    const list = extraction.sentences
    let lo = 0
    let hi = list.length - 1
    let candidate = -1
    while (lo <= hi) {
      const mid = (lo + hi) >> 1
      if (list[mid].start <= offset) {
        candidate = mid
        lo = mid + 1
      } else {
        hi = mid - 1
      }
    }
    if (candidate === -1) return list.length ? 0 : -1
    // Clicked in the gap after a sentence (whitespace, a skipped element): the
    // user means the next thing to be read, not the one just finished.
    if (offset > list[candidate].end && candidate + 1 < list.length) return candidate + 1
    return candidate
  }

  document.addEventListener(
    'click',
    (e) => {
      if (!isActive() || !prefs.clickToJump) return
      if (e.button !== 0 || e.altKey || e.ctrlKey || e.metaKey || e.shiftKey) return
      const target = e.target as Element | null
      if (!target || target.closest?.('[data-aloud]')) return
      if (target.closest?.(INTERACTIVE)) return
      // A click that ends a drag-selection isn't a jump request.
      if (!window.getSelection()?.isCollapsed) return
      if (extraction?.root && !extraction.root.contains(target)) return

      const caret = caretAt(e.clientX, e.clientY)
      if (!caret) return
      const offset = offsetOf(extraction!.slices, caret.node, caret.offset)
      if (offset < 0) return
      const index = sentenceAtOffset(offset)
      if (index >= 0) player.seekTo(index)
    },
    true,
  )

  // ── in-page keys ──────────────────────────────────────────────────────────
  // Deliberately minimal: Alt+A / Alt+← / Alt+→ are real browser commands
  // (they work even when the page steals focus), so the only key we claim here
  // is Escape, and only while reading and not while typing.

  document.addEventListener('keydown', (e) => {
    if (e.key !== 'Escape' || !isActive()) return
    const el = document.activeElement as HTMLElement | null
    if (el && (el.isContentEditable || /^(INPUT|TEXTAREA|SELECT)$/.test(el.tagName))) return
    teardown()
  })

  // ── page lifecycle ────────────────────────────────────────────────────────

  // Client-side navigation swaps the article out from under our Ranges; stop
  // rather than highlight nonsense in the new page.
  let lastPath = location.pathname + location.search
  const onNavigate = () => {
    const path = location.pathname + location.search
    if (path !== lastPath) {
      lastPath = path
      if (isActive()) teardown()
    }
  }
  window.addEventListener('popstate', onNavigate)
  window.addEventListener('hashchange', onNavigate)
  window.addEventListener('pagehide', () => teardown())
}
