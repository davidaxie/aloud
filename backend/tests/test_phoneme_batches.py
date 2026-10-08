"""Long punctuation-free phoneme runs are split, not crashed on (F059)."""

from __future__ import annotations

import re
import types
import unittest
from unittest import mock

import numpy as np

from support import load_module  # noqa: I001 — puts backend/ on sys.path first

from phoneme_batches import (
    MAX_PHONEMES,
    MAX_RUN,
    TooLongError,
    check_length,
    respell_for_model,
    split_for_model,
)
from synth_queue import JobCancelledError
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


# espeak-ng's Mandarin output for real sentences (backend venv, kokoro_onnx
# 0.5.0): its ASCII names for the retroflex sounds end in a full stop.
ESPEAK_CMN = {
    # 路上的人很多. 他说,这是什么?
    "lus.ˈɑŋ tˈə ˈəɜn χˈən tˈuo. thˈɑ s.wˈo,ts.ˈo s.ˈi. s.ˈəɜn mˈo?":
        "luʂˈɑŋ tˈə ˈəɜn χˈən tˈuo. thˈɑ ʂwˈo,ʈʂˈo ʂˈɻ ʂˈəɜn mˈo?",
    # 知道吃饭是日常生活,出租车.
    "ts.i.tˈɑu ts.hˈi. fˈan s.ˈi. ˈi. ts.hˈɑɜŋ s.ˈəŋ χˈuoɜ,ts.hˈu tsˈu ts.hˈo.":
        "ʈʂɻtˈɑu ʈʂʰˈɻ fˈan ʂˈɻ ˈi. ʈʂʰˈɑɜŋ ʂˈəŋ χˈuoɜ,ʈʂʰˈu tsˈu ʈʂʰˈo.",
    # 我是. 你是.  (the second "." of each "i.." is the sentence's own)
    "wˈo s.ˈi.. nˈi s.ˈi..": "wˈo ʂˈɻ. nˈi ʂˈɻ.",
    # 他说yes. 是你.  (a full stop after a Latin word or after 你 stays)
    "thˈɑ s.wˈo (en)jˈɛs(cmn). s.ˈi. nˈi.": "thˈɑ ʂwˈo (en)jˈɛs(cmn). ʂˈɻ nˈi.",
}


class RespellTests(unittest.TestCase):
    """L032: Mandarin syllables carried the model's sentence-final token."""

    def test_mandarin_retroflex_names_become_ipa(self) -> None:
        for espeak, expected in ESPEAK_CMN.items():
            self.assertEqual(respell_for_model(espeak, "cmn"), expected)

    def test_other_languages_pass_through(self) -> None:
        for lang in ("en-us", "en-gb", "fr-fr", "hi"):
            self.assertEqual(respell_for_model("jˈɛs. s.ˈi.", lang), "jˈɛs. s.ˈi.")


class LengthTests(unittest.TestCase):
    def test_phonemes_over_the_bound_are_refused(self) -> None:
        check_length("a" * MAX_PHONEMES)
        with self.assertRaises(TooLongError):
            check_length("a" * (MAX_PHONEMES + 1))

    def test_too_long_is_a_value_error(self) -> None:
        # Anything that maps ValueError to "not retryable" keeps doing so.
        self.assertTrue(issubclass(TooLongError, ValueError))


class FakeKokoro:
    """kokoro_onnx 0.5.0's batching and its crash, with one sample per phoneme."""

    def __init__(self, model_path: str, voices_path: str) -> None:
        self.tokenizer = types.SimpleNamespace(phonemize=lambda text, lang: text)

    def get_voices(self) -> list[str]:
        return ["af_heart", "jf_alpha", "jm_kumo", "zf_xiaobei"]

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

    def test_text_that_phonemizes_too_long_never_reaches_the_model(self) -> None:
        # L034: U+FDFA x 2,000 passes the 2,000-character check but phonemizes
        # to about 120,000 phonemes, 300 model calls on the single worker.
        engine = self.module.engine
        text = "word " * (MAX_PHONEMES // 5 + 10)
        with mock.patch.object(engine._kokoro, "create") as create:
            with self.assertRaises(TooLongError):
                engine.synthesize(text, "af_heart", 1.0)
        create.assert_not_called()

    def test_a_job_told_to_stop_skips_the_rest(self) -> None:
        engine = self.module.engine
        text = " ".join(str(year) for year in range(1950, 2020)) * 2  # several model calls
        with mock.patch.object(engine._kokoro, "create", wraps=engine._kokoro.create) as create:
            with self.assertRaises(JobCancelledError):
                engine.synthesize(text, "af_heart", 1.0, should_stop=lambda: True)
        self.assertEqual(create.call_count, 1)

    def test_a_job_never_told_to_stop_runs_in_full(self) -> None:
        engine = self.module.engine
        text = " ".join(str(year) for year in range(1950, 2020)) * 2
        samples, _ = engine.synthesize(text, "af_heart", 1.0, should_stop=lambda: False)
        self.assertEqual(len(samples), len(normalize_for_tts(text).replace(" ", "")))

    def test_japanese_voices_are_not_offered(self) -> None:
        # L032: espeak-ng's Japanese says "Chinese letter" for every kanji, and
        # no Japanese G2P is installed, so the j voices are left out.
        engine = self.module.engine
        ids = [voice["id"] for voice in engine.list_voices()]
        self.assertEqual(ids, ["af_heart", "zf_xiaobei"])
        self.assertFalse(engine.has_voice("jf_alpha"))
        self.assertEqual(engine.voice_count, 2)

    def test_a_japanese_voice_is_never_phonemized_as_japanese(self) -> None:
        engine = self.module.engine
        tokenizer = engine._kokoro.tokenizer
        with mock.patch.object(tokenizer, "phonemize", wraps=tokenizer.phonemize) as phonemize:
            engine.synthesize("吾輩は猫である。", "jf_alpha", 1.0)
        self.assertEqual(phonemize.call_args.args[1], "en-us")

    def test_mandarin_reaches_the_model_respelled(self) -> None:
        engine = self.module.engine
        espeak, expected = next(iter(ESPEAK_CMN.items()))
        with mock.patch.object(
            engine._kokoro.tokenizer, "phonemize", return_value=espeak
        ), mock.patch.object(engine._kokoro, "create", wraps=engine._kokoro.create) as create:
            engine.synthesize("路上的人很多。他说，这是什么？", "zf_xiaobei", 1.0)
        self.assertEqual(create.call_args.args[0], expected)
        self.assertEqual(create.call_args.kwargs["lang"], "cmn")

    def test_text_left_empty_by_normalization_is_refused(self) -> None:
        # L037: a chunk holding only half an emoji is a 400, never a crash.
        with self.assertRaises(ValueError):
            self.module.engine.synthesize("\ud83d", "af_heart", 1.0)

    def test_a_normal_sentence_is_one_model_call(self) -> None:
        engine = self.module.engine
        with mock.patch.object(engine._kokoro, "create", wraps=engine._kokoro.create) as create:
            engine.synthesize("A short sentence, with a pause.", "af_heart", 1.0)
        self.assertEqual(create.call_count, 1)


if __name__ == "__main__":
    unittest.main()
