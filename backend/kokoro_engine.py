"""Singleton wrapper around the Kokoro ONNX TTS model.

The model (~325 MB) and voice bank (~28 MB) are loaded exactly once, at import
time, and reused for every request. Loading is expensive (a few seconds), so it
must never happen per-request.

``synthesize`` is serialized by a process-wide lock. The espeak-ng phonemizer
that ``Kokoro.create`` calls keeps global state and corrupts concurrent callers
("number of lines in input and output must be equal"). The HTTP layer already
funnels everything through one worker thread (``synth_queue``); the lock makes
that invariant a property of the engine, so scripts, smoke tests and any future
caller cannot reintroduce the race by accident. Uncontended, it costs nothing.

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
import threading
import time
from typing import Callable

import numpy as np
from kokoro_onnx import Kokoro

from phoneme_batches import check_length, respell_for_model, split_for_model
from synth_queue import JobCancelledError
from text_normalize import normalize_for_tts
from voices import VoiceMeta, build_voice_metadata, lang_for_voice, voice_is_speakable

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

        # Guards every create() call — see the module docstring.
        self._lock = threading.Lock()

        t0 = time.time()
        self._kokoro = Kokoro(model_path, voices_path)
        # Snapshot the installed voice ids and precompute their metadata. A
        # voice whose language this engine cannot phonemize is left out, so it
        # is neither listed nor used (see voices.voice_is_speakable).
        self._voice_ids: list[str] = sorted(
            v for v in self._kokoro.get_voices() if voice_is_speakable(v)
        )
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
        self,
        text: str,
        voice: str,
        speed: float,
        should_stop: Callable[[], bool] | None = None,
    ) -> tuple[np.ndarray, int]:
        """Synthesize ``text`` with ``voice`` at ``speed``.

        - ``speed`` is clamped to the supported 0.5-2.0 range.
        - An unknown ``voice`` falls back to the default voice.
        - ``lang`` is derived from the voice id (e.g. a British voice uses
          en-gb) so pronunciation matches the voice.
        - A punctuation-free stretch too long for the model (a row of numbers,
          say) is split at spaces and spoken in full rather than failing.
        - Concurrent callers are serialized; only one inference runs at a time.
        - Text that phonemizes to more than ``phoneme_batches.MAX_PHONEMES``
          raises ``TooLongError`` (a ValueError) before any inference.
        - ``should_stop`` is asked between model calls; once it answers True
          the rest is skipped and ``JobCancelledError`` is raised, so a long
          job nobody is waiting for gives the worker back early.

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
        if not text.strip():
            raise ValueError("text must be a non-empty string")

        clamped_speed = float(max(_MIN_SPEED, min(_MAX_SPEED, speed)))

        # Fall back to the default voice rather than failing on a bad id.
        if not self.has_voice(voice):
            logger.warning("Unknown voice %r; falling back to %s", voice, self.default_voice)
            voice = self.default_voice

        lang = lang_for_voice(voice)
        with self._lock:
            # Phonemize here rather than inside create() so a punctuation-free
            # run too long for the model can be split first (see
            # phoneme_batches); create() would otherwise crash on it.
            phonemes = respell_for_model(self._kokoro.tokenizer.phonemize(text, lang), lang)
            check_length(phonemes)
            parts = []
            for piece in split_for_model(phonemes):
                if parts and should_stop is not None and should_stop():
                    raise JobCancelledError("the client stopped waiting for this sentence")
                parts.append(
                    self._kokoro.create(
                        piece, voice=voice, speed=clamped_speed, lang=lang, is_phonemes=True
                    )
                )
        sample_rate = parts[0][1]
        if len(parts) == 1:
            return parts[0][0], sample_rate
        return np.concatenate([samples for samples, _ in parts]), sample_rate


# Module-level singleton: constructed once when this module is first imported.
engine = KokoroEngine(_MODEL_PATH, _VOICES_PATH)
