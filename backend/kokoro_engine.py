"""Singleton wrapper around the Kokoro ONNX TTS model.

The model (~325 MB) and voice bank (~28 MB) are loaded exactly once, at import
time, and reused for every request. Loading is expensive (a few seconds), so it
must never happen per-request.

Public surface:
    synthesize(text, voice, speed) -> (samples: np.ndarray float32, sample_rate: int)
    list_voices() -> list[VoiceMeta]   # parsed metadata for every installed voice
    voice_count -> int
    default_voice -> str
    model_loaded -> bool
"""

from __future__ import annotations

import logging
import os
import time

import numpy as np
from kokoro_onnx import Kokoro

from text_normalize import normalize_for_tts
from voices import VoiceMeta, build_voice_metadata, lang_for_voice

logger = logging.getLogger("aloud.kokoro")

# Model asset locations, resolved relative to this file so the server can be
# launched from any working directory.
_HERE = os.path.dirname(os.path.abspath(__file__))
_MODEL_PATH = os.path.join(_HERE, "models", "kokoro-v1.0.onnx")
_VOICES_PATH = os.path.join(_HERE, "models", "voices-v1.0.bin")

# Speed clamp range required by the HTTP contract.
_MIN_SPEED = 0.5
_MAX_SPEED = 2.0

# Preferred default voice; falls back to the first installed voice if absent.
_PREFERRED_DEFAULT = "af_heart"


class KokoroEngine:
    """Loads Kokoro once and exposes synthesis + voice metadata."""

    def __init__(self, model_path: str, voices_path: str) -> None:
        if not os.path.exists(model_path):
            raise FileNotFoundError(f"Kokoro model not found: {model_path}")
        if not os.path.exists(voices_path):
            raise FileNotFoundError(f"Kokoro voices not found: {voices_path}")

        t0 = time.time()
        self._kokoro = Kokoro(model_path, voices_path)
        # Snapshot the installed voice ids and precompute their metadata.
        self._voice_ids: list[str] = sorted(self._kokoro.get_voices())
        self._voices: list[VoiceMeta] = build_voice_metadata(self._voice_ids)
        load_secs = time.time() - t0
        logger.info(
            "Kokoro model loaded in %.2fs (%d voices)",
            load_secs,
            len(self._voice_ids),
        )

    # -- metadata ---------------------------------------------------------

    def list_voices(self) -> list[VoiceMeta]:
        """Return parsed metadata for every installed voice."""
        return self._voices

    @property
    def voice_count(self) -> int:
        return len(self._voice_ids)

    @property
    def default_voice(self) -> str:
        """Preferred default voice id, or the first installed voice if missing."""
        if _PREFERRED_DEFAULT in self._voice_ids:
            return _PREFERRED_DEFAULT
        return self._voice_ids[0] if self._voice_ids else _PREFERRED_DEFAULT

    @property
    def model_loaded(self) -> bool:
        return self._kokoro is not None

    def has_voice(self, voice: str) -> bool:
        return voice in self._voice_ids

    # -- synthesis --------------------------------------------------------

    def synthesize(
        self, text: str, voice: str, speed: float
    ) -> tuple[np.ndarray, int]:
        """Synthesize ``text`` with ``voice`` at ``speed``.

        - ``speed`` is clamped to the supported 0.5-2.0 range.
        - An unknown ``voice`` falls back to the default voice.
        - ``lang`` is derived from the voice id (e.g. a British voice uses
          en-gb) so pronunciation matches the voice.

        Returns ``(samples, sample_rate)`` where samples is a float32 waveform.
        Raises ``ValueError`` on empty text; propagates other errors to the
        caller for a 500 response.
        """
        if text is None or not text.strip():
            raise ValueError("text must be a non-empty string")

        # Clean typographic artifacts (ligatures, soft hyphens, exotic spaces,
        # smart quotes, dashes, line-wrap hyphenation, control chars) that make
        # the espeak-ng phonemizer mis-phonemize and garble the speech.
        text = normalize_for_tts(text)

        clamped_speed = float(max(_MIN_SPEED, min(_MAX_SPEED, speed)))

        # Fall back to the default voice rather than failing on a bad id.
        if not self.has_voice(voice):
            logger.warning("Unknown voice %r; falling back to %s", voice, self.default_voice)
            voice = self.default_voice

        lang = lang_for_voice(voice)
        samples, sample_rate = self._kokoro.create(
            text, voice=voice, speed=clamped_speed, lang=lang
        )
        return samples, sample_rate


# Module-level singleton: constructed once when this module is first imported.
engine = KokoroEngine(_MODEL_PATH, _VOICES_PATH)
