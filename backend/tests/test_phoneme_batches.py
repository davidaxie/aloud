"""Long punctuation-free phoneme runs are split, not crashed on (F059)."""

from __future__ import annotations

import re
import types
import unittest
from unittest import mock

import numpy as np

from support import load_module  # noqa: I001 — puts backend/ on sys.path first

from phoneme_batches import MAX_RUN, split_for_model
from text_normalize import normalize_for_tts

# kokoro_onnx 0.5.0's context: a batch of this many phonemes or more indexes past
# the end of the 510-row voice-style table.
KOKORO_MAX_PHONEMES = 510


def runs(piece: str) -> list[str]:
    return [part.strip() for part in re.split(r"[.,!?;]", piece)]


class SplitTests(unittest.TestCase):
    def test_ordinary_phonemes_pass_through_untouched(self) -> None:
        phonemes = "həlˈoʊ, wˈɜːld. ðɪs ɪz ɐ tˈɛst!"
        self.assertEqual(split_for_model(phonemes), [phonemes])

    def test_long_run_is_cut_at_spaces_with_nothing_lost(self) -> None:
        # Shaped like the years 1950-2019 read aloud: well over 510 phonemes, no marks.
        phonemes = " ".join(f"nˈaɪntiːn fˈɪfti{i}" for i in range(70))
        self.assertGreater(len(phonemes), 2 * KOKORO_MAX_PHONEMES)

        pieces = split_for_model(phonemes)
        self.assertGreater(len(pieces), 1)
        for piece in pieces:
            for run in runs(piece):
                self.assertLess(len(run), MAX_RUN)
        self.assertEqual(" ".join(pieces).split(), phonemes.split())

    def test_long_run_between_sentences_keeps_its_neighbours(self) -> None:
        long_run = " ".join(["wˈʌn"] * 200)
        phonemes = f"bɪfˈoːɹ. {long_run}. ˈæftɚ"
        pieces = split_for_model(phonemes)
        for piece in pieces:
            for run in runs(piece):
                self.assertLess(len(run), MAX_RUN)
        joined = " ".join(pieces)
        self.assertTrue(joined.startswith("bɪfˈoːɹ."))
        self.assertTrue(joined.endswith("ˈæftɚ"))
        self.assertEqual(joined.replace(".", " ").split(), phonemes.replace(".", " ").split())

    def test_a_word_with_no_space_to_cut_at_is_cut_in_place(self) -> None:
        phonemes = "x" * 1000
        pieces = split_for_model(phonemes)
        self.assertTrue(all(len(piece) < MAX_RUN for piece in pieces))
        self.assertEqual("".join(pieces), phonemes)


class FakeKokoro:
    """kokoro_onnx 0.5.0's batching and its crash, with one sample per phoneme."""

    def __init__(self, model_path: str, voices_path: str) -> None:
        self.tokenizer = types.SimpleNamespace(phonemize=lambda text, lang: text)

    def get_voices(self) -> list[str]:
        return ["af_heart"]

    def create(self, text, voice, speed=1.0, lang="en-us", is_phonemes=False, trim=True):
        audio = []
        for batch in re.split(r"[.,!?;]", text):
            batch = batch.strip()
            if len(batch) >= KOKORO_MAX_PHONEMES:
                raise IndexError(f"index {KOKORO_MAX_PHONEMES} is out of bounds for axis 0")
            audio.append(np.ones(len(batch.replace(" ", "")), dtype=np.float32))
        return np.concatenate(audio), 24000


class EngineTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        fake_onnx = types.ModuleType("kokoro_onnx")
        fake_onnx.Kokoro = FakeKokoro
        with mock.patch("os.path.exists", return_value=True):
            cls.module = load_module(
                "kokoro_engine_under_test", "kokoro_engine.py", {"kokoro_onnx": fake_onnx}
            )

    def test_a_row_of_years_is_spoken_in_full(self) -> None:
        text = " ".join(str(year) for year in range(1950, 2020)) * 2  # no punctuation at all
        expected = len(normalize_for_tts(text).replace(" ", ""))
        self.assertGreater(len(text), KOKORO_MAX_PHONEMES)

        samples, rate = self.module.engine.synthesize(text, "af_heart", 1.0)
        self.assertEqual(rate, 24000)
        self.assertEqual(len(samples), expected)

    def test_a_normal_sentence_is_one_model_call(self) -> None:
        engine = self.module.engine
        with mock.patch.object(engine._kokoro, "create", wraps=engine._kokoro.create) as create:
            engine.synthesize("A short sentence, with a pause.", "af_heart", 1.0)
        self.assertEqual(create.call_count, 1)


if __name__ == "__main__":
    unittest.main()
