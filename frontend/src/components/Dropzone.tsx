// ─────────────────────────────────────────────────────────────────────────────
// Dropzone — the empty-state hero. Large drag-and-drop target that also supports
// click-to-browse. Accepts only PDFs; hands the chosen file back to App.
// ─────────────────────────────────────────────────────────────────────────────
import { useEffect, useRef, useState } from 'react'
import type { DragEvent } from 'react'
import { UploadIcon, WaveIcon } from './Icons'

interface DropzoneProps {
  onFile: (file: File) => void
  /** Take focus as it mounts, when the control that had it went away (K017). */
  focusOnMount?: boolean
}

function isPdf(file: File): boolean {
  return file.type === 'application/pdf' || /\.pdf$/i.test(file.name)
}

export function Dropzone({ onFile, focusOnMount = false }: DropzoneProps) {
  const buttonRef = useRef<HTMLButtonElement>(null)
  const inputRef = useRef<HTMLInputElement>(null)
  const [dragging, setDragging] = useState(false)
  const [rejected, setRejected] = useState(false)
  const dragDepth = useRef(0)

  // The empty state replaces the reader, and with it the reset button that had
  // focus: take focus here, so a screen reader lands on what to do next
  // instead of nowhere (K017). Focus moved somewhere on purpose stays there.
  useEffect(() => {
    if (!focusOnMount) return
    const focused = document.activeElement
    if (focused && focused !== document.body) return
    buttonRef.current?.focus()
  }, [])

  function pick() {
    inputRef.current?.click()
  }

  function handleFiles(files: FileList | null) {
    const file = files?.[0]
    if (!file) return
    if (!isPdf(file)) {
      setRejected(true)
      window.setTimeout(() => setRejected(false), 2200)
      return
    }
    setRejected(false)
    onFile(file)
  }

  function onDragEnter(e: DragEvent) {
    e.preventDefault()
    dragDepth.current += 1
    setDragging(true)
  }
  function onDragOver(e: DragEvent) {
    e.preventDefault()
    e.dataTransfer.dropEffect = 'copy'
  }
  function onDragLeave(e: DragEvent) {
    e.preventDefault()
    dragDepth.current -= 1
    if (dragDepth.current <= 0) {
      dragDepth.current = 0
      setDragging(false)
    }
  }
  function onDrop(e: DragEvent) {
    e.preventDefault()
    dragDepth.current = 0
    setDragging(false)
    handleFiles(e.dataTransfer.files)
  }

  return (
    <div className="dropzone-wrap">
      <button
        ref={buttonRef}
        type="button"
        className={`dropzone${dragging ? ' is-dragging' : ''}${rejected ? ' is-rejected' : ''}`}
        onClick={pick}
        onDragEnter={onDragEnter}
        onDragOver={onDragOver}
        onDragLeave={onDragLeave}
        onDrop={onDrop}
        aria-label="Drop a PDF here or click to browse"
      >
        <span className="dropzone__mark" aria-hidden>
          <WaveIcon size={30} />
        </span>

        <span className="dropzone__icon" aria-hidden>
          <UploadIcon size={26} />
        </span>

        <span className="dropzone__title">
          {rejected ? 'That file isn’t a PDF' : 'Drop a PDF to begin'}
        </span>
        <span className="dropzone__hint">
          {rejected
            ? 'Please choose a .pdf file to read aloud.'
            : 'or click to browse — everything stays on your device'}
        </span>

        <input
          ref={inputRef}
          type="file"
          accept="application/pdf,.pdf"
          className="visually-hidden"
          onChange={(e) => {
            handleFiles(e.target.files)
            e.target.value = ''
          }}
          tabIndex={-1}
        />
      </button>

      <p className="dropzone__foot">
        Aloud reads long documents in a natural neural voice, entirely offline.
      </p>
    </div>
  )
}
