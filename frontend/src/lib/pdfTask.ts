// ─────────────────────────────────────────────────────────────────────────────
// A pdf.js document's lifetime.
//
// Every getDocument() starts its own worker thread and hands it the file's
// bytes, and only destroying the loading task stops that worker. So a file
// that fails to open (locked, corrupt) or to parse, or a parse the user
// abandons, must still be torn down; otherwise each attempt leaves a worker
// holding a copy of the file until the tab is closed (H065). Kept free of
// pdf.js so it can be tested with stubs.
// ─────────────────────────────────────────────────────────────────────────────

/** The part of a pdf.js loading task this needs. */
export interface PdfLoadingTask<D> {
  promise: Promise<D>
  destroy(): Promise<void>
}

function abortError(): DOMException {
  return new DOMException('The PDF parse was abandoned.', 'AbortError')
}

/**
 * Open the document `task` loads, run `parse` on it, and destroy the task
 * however that ends: parsed, failed to open, failed to parse, or abandoned
 * through `signal`. `openError` turns a failure to open into the message the
 * user sees; an abandoned parse rejects with an AbortError instead.
 */
export async function withPdfDocument<D, T>(
  task: PdfLoadingTask<D>,
  openError: (err: unknown) => Error,
  parse: (doc: D) => Promise<T>,
  signal?: AbortSignal,
): Promise<T> {
  let destroyed: Promise<void> | null = null
  const destroy = () => {
    destroyed ??= task.destroy().catch(() => {})
    return destroyed
  }
  // Abandoned: stop the worker now, so a long parse stops with it.
  const onAbort = () => void destroy()
  signal?.addEventListener('abort', onAbort, { once: true })
  try {
    if (signal?.aborted) throw abortError()
    let doc: D
    try {
      doc = await task.promise
    } catch (err) {
      if (signal?.aborted) throw abortError()
      throw openError(err)
    }
    if (signal?.aborted) throw abortError()
    let parsed: T
    try {
      parsed = await parse(doc)
    } catch (err) {
      if (signal?.aborted) throw abortError()
      throw err
    }
    if (signal?.aborted) throw abortError()
    return parsed
  } finally {
    signal?.removeEventListener('abort', onAbort)
    await destroy()
  }
}
