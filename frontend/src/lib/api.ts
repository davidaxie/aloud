// ─────────────────────────────────────────────────────────────────────────────
// Backend (Kokoro) HTTP client.
// The UI imports getHealth/getVoices for bootstrap; the player imports synthesize.
// ─────────────────────────────────────────────────────────────────────────────
import type { SynthesizeRequest, Voice } from '../types'

export const API_BASE = import.meta.env.VITE_API_BASE ?? 'http://localhost:8000'

export interface HealthResult {
  ok: boolean
  voiceCount: number
}

/**
 * GET /health — is the local TTS backend up and the model loaded?
 * Never throws: any network/parse failure resolves to `{ ok: false }` so the UI
 * can poll this safely on a timer without try/catch.
 */
export async function getHealth(): Promise<HealthResult> {
  try {
    const res = await fetch(`${API_BASE}/health`)
    if (!res.ok) return { ok: false, voiceCount: 0 }
    const data: unknown = await res.json()
    const d = (data ?? {}) as {
      status?: string
      model_loaded?: boolean
      voice_count?: number
    }
    return {
      ok: d.status === 'ok' && d.model_loaded === true,
      voiceCount: typeof d.voice_count === 'number' ? d.voice_count : 0,
    }
  } catch {
    // Backend down / DNS / CORS / offline — report not-ok rather than throwing.
    return { ok: false, voiceCount: 0 }
  }
}

/** GET /voices — the installed voice roster and the default voice id. */
export async function getVoices(): Promise<{ voices: Voice[]; default: string }> {
  const res = await fetch(`${API_BASE}/voices`)
  if (!res.ok) throw new Error(`getVoices failed: HTTP ${res.status}`)
  const data: unknown = await res.json()
  const d = (data ?? {}) as { voices?: Voice[]; default?: string }
  return {
    voices: Array.isArray(d.voices) ? d.voices : [],
    default: typeof d.default === 'string' ? d.default : 'af_heart',
  }
}

/**
 * POST /synthesize — returns a WAV blob for one chunk of text.
 * Throws on any non-2xx response or network failure. Pass `signal` to abort a
 * request that has become stale (user seeked / changed voice or rate).
 */
export async function synthesize(
  req: SynthesizeRequest,
  signal?: AbortSignal,
): Promise<Blob> {
  const res = await fetch(`${API_BASE}/synthesize`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(req),
    signal,
  })
  if (!res.ok) throw new Error(`synthesize failed: HTTP ${res.status}`)
  return res.blob()
}
