// ─────────────────────────────────────────────────────────────────────────────
// Window-level file-drop guard.
//
// A file dropped where nothing handles it gets the browser default: the tab
// navigates to the file, and the reading session (which lives only in memory)
// is gone. The Dropzone handles drops on itself, but it is unmounted once a
// document is open. This guard claims every file drag on the page and hands the
// dropped file to the app instead. Drops a component already handled (it called
// preventDefault) are left to that component.
// ─────────────────────────────────────────────────────────────────────────────

/** True for a PDF by MIME type or, failing that, by extension. */
export function isPdf(file: { name: string; type: string }): boolean {
  return file.type === 'application/pdf' || /\.pdf$/i.test(file.name)
}

interface FileDrag {
  defaultPrevented: boolean
  preventDefault(): void
  dataTransfer?: {
    types: ArrayLike<string>
    files: ArrayLike<File>
    dropEffect: string
  } | null
}

function carriesFiles(e: FileDrag): boolean {
  return !!e.dataTransfer && Array.from(e.dataTransfer.types).includes('Files')
}

/**
 * Install the guard on `target` (the window). `onFile` receives the first
 * dropped file. Returns a function that removes the guard.
 */
export function guardFileDrops(target: EventTarget, onFile: (file: File) => void): () => void {
  const onDragOver = (event: Event) => {
    const e = event as unknown as FileDrag
    if (!carriesFiles(e)) return
    // Required for 'drop' to fire here instead of the browser opening the file.
    e.preventDefault()
    if (e.dataTransfer) e.dataTransfer.dropEffect = 'copy'
  }
  const onDrop = (event: Event) => {
    const e = event as unknown as FileDrag
    if (!carriesFiles(e)) return
    if (e.defaultPrevented) return // the Dropzone already took it
    e.preventDefault()
    const file = e.dataTransfer?.files[0]
    if (file) onFile(file)
  }
  target.addEventListener('dragover', onDragOver)
  target.addEventListener('drop', onDrop)
  return () => {
    target.removeEventListener('dragover', onDragOver)
    target.removeEventListener('drop', onDrop)
  }
}
