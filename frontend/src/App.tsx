// ─────────────────────────────────────────────────────────────────────────────
// App — the shell that wires Aloud together: bootstrap (health + voices), theme,
// keyboard shortcuts, PDF intake, and the three main surfaces (empty / loading /
// reading) plus the fixed player bar.
// ─────────────────────────────────────────────────────────────────────────────
import { useCallback, useEffect } from 'react'
import { getHealth, getVoices } from './lib/api'
import { guardFileDrops, isPdf } from './lib/dropGuard'
import { watchEngine } from './lib/engineWatch'
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

export default function App() {
  useTheme()
  useKeyboard()

  const doc = useStore((s) => s.doc)
  const status = useStore((s) => s.status)

  const setEngineState = useStore((s) => s.setEngineState)
  const setVoices = useStore((s) => s.setVoices)
  const setVoiceId = useStore((s) => s.setVoiceId)
  const setDoc = useStore((s) => s.setDoc)
  const setFileName = useStore((s) => s.setFileName)
  const setStatus = useStore((s) => s.setStatus)
  const setLoadProgress = useStore((s) => s.setLoadProgress)
  const setError = useStore((s) => s.setError)
  const reset = useStore((s) => s.reset)

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
  const handleFile = useCallback(
    async (file: File) => {
      setError(null)
      setFileName(file.name)
      setStatus('loading')
      setLoadProgress(0)
      try {
        const parsed = await loadPdf(file, (p) => setLoadProgress(p))
        setDoc(parsed)
        // The player owns audio; loading may throw in stub builds, so guard it
        // without discarding the successfully-parsed document.
        try {
          player.load(parsed)
        } catch (err) {
          console.error('player.load failed', err)
        }
        setStatus('ready')
      } catch (err) {
        setDoc(null)
        setFileName(null)
        setStatus('error')
        setError(
          err instanceof Error
            ? `Could not read that PDF — ${err.message}`
            : 'Could not read that PDF.',
        )
      }
    },
    [setDoc, setError, setFileName, setLoadProgress, setStatus],
  )

  const handleReset = useCallback(() => {
    try {
      player.stop()
    } catch (err) {
      console.error('player.stop failed', err)
    }
    reset()
  }, [reset])

  // ── Drops anywhere on the page. ────────────────────────────────────────────
  // Without this, a PDF dropped on the reader opens in place of the app and the
  // reading session is lost. A dropped PDF replaces the open document instead.
  useEffect(
    () =>
      guardFileDrops(window, (file) => {
        if (useStore.getState().status === 'loading') return
        if (!isPdf(file)) {
          useStore.getState().pushToast('That file isn\u2019t a PDF')
          return
        }
        if (useStore.getState().doc) handleReset()
        void handleFile(file)
      }),
    [handleFile, handleReset],
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
        {isLoading ? (
          <LoadingView />
        ) : doc ? (
          <Reader doc={doc} />
        ) : (
          <Dropzone onFile={handleFile} />
        )}
      </main>

      {doc && !isLoading && <PlayerBar doc={doc} />}
      <Toast />
    </div>
  )
}
