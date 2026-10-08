// ─────────────────────────────────────────────────────────────────────────────
// App — the shell that wires Aloud together: bootstrap (health + voices), theme,
// keyboard shortcuts, PDF intake, and the three main surfaces (empty / loading /
// reading) plus the fixed player bar.
// ─────────────────────────────────────────────────────────────────────────────
import { useCallback, useEffect, useState } from 'react'
import { getHealth, getVoices } from './lib/api'
import { guardFileDrops, isPdf } from './lib/dropGuard'
import { watchEngine } from './lib/engineWatch'
import { cancelPdfIntake, closedMessage, openPdf } from './lib/intake'
import { loadPdf } from './lib/pdf'
import { player } from './lib/player'
import { useStore } from './store'
import { useTheme } from './hooks/useTheme'
import { useKeyboard } from './hooks/useKeyboard'
import { Dropzone } from './components/Dropzone'
import { LoadingView } from './components/LoadingView'
import { Reader } from './components/Reader'
import { PlayerBar } from './components/PlayerBar'
import { ThemeToggle } from './components/ThemeToggle'
import { StatusBadge, ErrorBanner } from './components/StatusBadge'
import { Toast } from './components/Toast'
import { WaveIcon, FileIcon } from './components/Icons'
import type { Doc } from './types'

// One reader per book, so the next book opens at its top (L035).
const readerKeys = new WeakMap<Doc, number>()
let lastReaderKey = 0
function readerKey(doc: Doc): number {
  let key = readerKeys.get(doc)
  if (key === undefined) {
    key = ++lastReaderKey
    readerKeys.set(doc, key)
  }
  return key
}

export default function App() {
  useTheme()
  useKeyboard()

  const doc = useStore((s) => s.doc)
  const status = useStore((s) => s.status)

  const setEngineState = useStore((s) => s.setEngineState)
  const setVoices = useStore((s) => s.setVoices)
  const setVoiceId = useStore((s) => s.setVoiceId)
  const reset = useStore((s) => s.reset)
  // What a screen reader hears as a PDF opens (J041): the view that had focus
  // is replaced by the loading view, and only failures are alerts.
  const [announcement, setAnnouncement] = useState('')
  // The header's reset button goes with the book it closes, so the empty state
  // takes the focus from then on (K017); the first page load leaves it be.
  const [focusDropzone, setFocusDropzone] = useState(false)

  // ── Bootstrap: probe the backend and load the voice roster. ────────────────
  // Re-polls while offline so a backend that starts AFTER the page loads (the
  // common case with the packaged app) is picked up and the badge clears itself.
  // Playback finding the engine down later starts the probes again.
  useEffect(() => {
    let cancelled = false

    const loadVoicesOnce = async () => {
      try {
        const { voices, default: defaultId } = await getVoices()
        if (cancelled) return
        setVoices(voices)
        // Keep the persisted voice if it's still installed; otherwise adopt the
        // backend default so the picker never points at a missing voice.
        const ids = new Set(voices.map((v) => v.id))
        const current = useStore.getState().voiceId
        if (!ids.has(current) && defaultId) setVoiceId(defaultId)
      } catch {
        /* No voices available — the picker shows an empty, disabled state. */
      }
    }

    const stopWatching = watchEngine({
      probe: getHealth, // never throws → { ok: false } when down
      getEngineState: () => useStore.getState().engineState,
      setEngineState,
      onHealthy: async () => {
        // A banner saying the engine is offline is now false (G016).
        player.engineRecovered()
        if (useStore.getState().voices.length === 0) await loadVoicesOnce()
      },
      subscribe: (listener) =>
        useStore.subscribe((s, prev) => {
          if (s.engineState !== prev.engineState) listener(s.engineState)
        }),
    })

    return () => {
      cancelled = true
      stopWatching()
    }
  }, [setEngineState, setVoices, setVoiceId])

  // ── PDF intake. ────────────────────────────────────────────────────────────
  // Parses first, so a file that can't be read leaves an open book in place.
  const handleFile = useCallback(
    (file: File) => openPdf(file, { loadPdf, player, announce: setAnnouncement }),
    [],
  )

  const handleReset = useCallback(() => {
    const open = useStore.getState().doc
    // 'New' while a PDF parses abandons it, so it can't open over what comes next.
    cancelPdfIntake()
    // Say the book closed, over any word of a parse it abandoned, and hand the
    // focus the reset button had to the drop target (K017).
    setAnnouncement(open ? closedMessage(open) : '')
    setFocusDropzone(true)
    try {
      player.stop()
    } catch (err) {
      console.error('player.stop failed', err)
    }
    reset()
  }, [reset])

  // ── Drops anywhere on the page. ────────────────────────────────────────────
  // Without this, a PDF dropped on the reader opens in place of the app and the
  // reading session is lost. A dropped PDF replaces the open document once it
  // has parsed; one that can't be read leaves it open.
  useEffect(
    () =>
      guardFileDrops(window, (file) => {
        if (useStore.getState().status === 'loading') return
        if (!isPdf(file)) {
          useStore.getState().pushToast('That file isn\u2019t a PDF')
          return
        }
        void handleFile(file)
      }),
    [handleFile],
  )

  const isLoading = status === 'loading'

  return (
    <div className="app">
      <header className="app__header">
        <div className="brand">
          <span className="brand__mark" aria-hidden>
            <WaveIcon size={20} />
          </span>
          <span className="brand__name">Aloud</span>
        </div>

        <div className="app__header-right">
          {doc && (
            <button
              type="button"
              className="ghost-btn"
              onClick={handleReset}
              title="Open a different PDF"
            >
              <FileIcon size={17} />
              <span>New</span>
            </button>
          )}
          <span className="kbd-hint" aria-hidden>
            <kbd>Space</kbd> play <span className="kbd-hint__sep">·</span>
            <kbd>←</kbd>
            <kbd>→</kbd> sentence
          </span>
          <ThemeToggle />
        </div>
      </header>

      <div className="app__banners">
        <StatusBadge />
        <ErrorBanner />
      </div>

      <main className="app__main">
        {/* A PDF parsing over an open book keeps the reader mounted beneath
            the loading view, so one that can't be read leaves the book's view
            as it was (L035). A new book is a new reader, from its top. */}
        {doc && <Reader key={readerKey(doc)} doc={doc} held={isLoading} />}
        {isLoading ? (
          doc ? (
            <div className="app__main-over">
              <LoadingView />
            </div>
          ) : (
            <LoadingView />
          )
        ) : doc ? null : (
          // A first PDF that couldn't be read took the focus away with the
          // drop target; the new one takes it back (L044).
          <Dropzone onFile={handleFile} focusOnMount={focusDropzone || status === 'error'} />
        )}
      </main>

      {doc && !isLoading && <PlayerBar doc={doc} />}
      <Toast />
      <p className="visually-hidden" role="status" aria-live="polite">
        {announcement}
      </p>
    </div>
  )
}
