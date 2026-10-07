import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'
import { fileURLToPath } from 'node:url'
import { dirname } from 'node:path'

// Root is pinned to this config's own directory so the dev server serves the
// frontend correctly no matter what working directory it's launched from.
const root = dirname(fileURLToPath(import.meta.url))

// Aloud frontend. Backend (Kokoro TTS) runs on :8000 and is called directly
// via VITE_API_BASE (defaults to http://localhost:8000) from src/lib/api.ts.
export default defineConfig({
  root,
  plugins: [react()],
  server: {
    port: 5173,
    strictPort: true,
  },
  // pdfjs ships large assets; keep them out of the inlining path.
  build: {
    target: 'es2020',
  },
})
