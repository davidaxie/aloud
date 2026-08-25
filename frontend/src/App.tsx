// ─────────────────────────────────────────────────────────────────────────────
// App — the shell that wires Aloud together: bootstrap (health + voices), theme,
// keyboard shortcuts, PDF intake, and the three main surfaces (empty / loading /
// reading) plus the fixed player bar.
// ─────────────────────────────────────────────────────────────────────────────
import { useCallback, useEffect } from 'react'
import { getHealth, getVoices } from './lib/api'
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
  useEffect(() => {
    let cancelled = false
    let timer: ReturnType<typeof setInterval> | undefined

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

    const check = async () => {
      const health = await getHealth() // never throws → { ok: false } when down
      if (cancelled) return
      setEngineState(health.state)
      if (health.ok) {
        if (useStore.getState().voices.length === 0) await loadVoicesOnce()
        if (timer) {
          clearInterval(timer)
          timer = undefined
        }
      }
    }

    check()
    timer = setInterval(() => {
      if (useStore.getState().engineState === 'ok') {
        if (timer) clearInterval(timer)
        timer = undefined
      } else {
        void check()
      }
    }, 2500)

    return () => {
      cancelled = true
      if (timer) clearInterval(timer)
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
    </div>
  )
}
