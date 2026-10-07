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
  loadPdf: (
    file: File,
    onProgress: (progress: number) => void,
    signal: AbortSignal,
  ) => Promise<Doc>
  player: { load(doc: Doc): void; pause(): void; stop(): void }
  /**
   * Says what is happening to a screen reader (J041): the view that had focus
   * is swapped for the loading view, so nothing else would. '' clears it.
   */
  announce?: (message: string) => void
}

/** What a screen reader hears once a PDF has opened, like the reader's header. */
export function openedMessage(doc: Doc): string {
  return `Opened ${doc.title}, ${doc.pageCount} ${doc.pageCount === 1 ? 'page' : 'pages'}`
}

/** The parse in progress, if any. */
let parsing: AbortController | null = null

/**
 * Abandon the parse in progress (H029): 'New' while a PDF parses, or a newer
 * file. Its result, or its failure, then never reaches the store, and the
 * parse itself stops.
 */
export function cancelPdfIntake(): void {
  parsing?.abort()
  parsing = null
}

/** Parse `file` and make it the document; on failure, keep whatever was open. */
export async function openPdf(file: File, deps: IntakeDeps): Promise<void> {
  cancelPdfIntake()
  const controller = new AbortController()
  parsing = controller
  const stale = () => controller.signal.aborted
  const store = useStore.getState
  const open = store().doc
  // Hold the open book still while the new one parses; it is closed only once
  // the new one has parsed. pause() also stands down a sentence still being
  // synthesized, so it can't put the book back over the loading view (J038).
  if (open && (store().status === 'playing' || store().status === 'buffering')) {
    deps.player.pause()
  }
  const before = { fileName: store().fileName, status: store().status }

  store().setError(null)
  store().setFileName(file.name)
  store().setStatus('loading')
  store().setLoadProgress(0)
  deps.announce?.(`Preparing ${file.name}\u2026`)
  try {
    const parsed = await deps.loadPdf(
      file,
      (p) => {
        if (!stale()) store().setLoadProgress(p)
      },
      controller.signal,
    )
    // Abandoned while it parsed: whatever the user opened since stays.
    if (stale()) return
    parsing = null
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
    deps.announce?.(openedMessage(parsed))
  } catch (err) {
    if (stale()) return
    parsing = null
    // The error banner is an alert: it says why.
    deps.announce?.('')
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
