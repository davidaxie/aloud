// ─────────────────────────────────────────────────────────────────────────────
// PDF intake — open a picked or dropped file as the document.
//
// The file is parsed BEFORE the open document is closed. The reading session
// lives only in memory, so a dropped file that turns out to be unreadable
// (scanned, locked, corrupt) must leave the open book and the place in it as
// they were, and just say why. Kept free of React and pdf.js so it can be
// tested with stubs.
// ─────────────────────────────────────────────────────────────────────────────
import { useStore } from '../store'
import type { Doc } from '../types'

export interface IntakeDeps {
  loadPdf: (file: File, onProgress: (progress: number) => void) => Promise<Doc>
  player: { load(doc: Doc): void; pause(): void; stop(): void }
}

/** Parse `file` and make it the document; on failure, keep whatever was open. */
export async function openPdf(file: File, deps: IntakeDeps): Promise<void> {
  const store = useStore.getState
  const open = store().doc
  // Hold the open book still while the new one parses; it is closed only once
  // the new one has parsed.
  if (open && (store().status === 'playing' || store().status === 'buffering')) {
    deps.player.pause()
  }
  const before = { fileName: store().fileName, status: store().status }

  store().setError(null)
  store().setFileName(file.name)
  store().setStatus('loading')
  store().setLoadProgress(0)
  try {
    const parsed = await deps.loadPdf(file, (p) => store().setLoadProgress(p))
    if (open) {
      try {
        deps.player.stop()
      } catch (err) {
        console.error('player.stop failed', err)
      }
      store().reset()
      store().setFileName(file.name)
    }
    store().setDoc(parsed)
    // The player owns audio; loading may throw in stub builds, so guard it
    // without discarding the successfully-parsed document.
    try {
      deps.player.load(parsed)
    } catch (err) {
      console.error('player.load failed', err)
    }
    store().setStatus('ready')
  } catch (err) {
    const message =
      err instanceof Error ? `Could not read that PDF — ${err.message}` : 'Could not read that PDF.'
    if (open) {
      // The open book stays, paused where it was.
      store().setFileName(before.fileName)
      store().setStatus(before.status)
      store().setError(message)
      return
    }
    store().setDoc(null)
    store().setFileName(null)
    store().setStatus('error')
    store().setError(message)
  }
}
