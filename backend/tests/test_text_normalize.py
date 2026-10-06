"""text_normalize.normalize_for_tts: zero-width joiners (F079 backend twin).

ZWJ and ZWNJ are spelling inside emoji sequences and Persian/Indic words, and
leftovers between Latin letters. Same rule as TextNormalizer.swift. Pure string
tests; nothing is loaded or synthesized.
"""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from text_normalize import normalize_for_tts  # noqa: E402

ZWNJ = "‌"
ZWJ = "‍"


class JoinerTests(unittest.TestCase):
    def test_zero_width_family_between_latin_letters_is_deleted(self) -> None:
        self.assertEqual(
            normalize_for_tts("zero​width‌chars‍here﻿"),
            "zerowidthcharshere",
        )

    def test_zwj_emoji_sequence_stays_one_emoji(self) -> None:
        woman_technologist = f"\U0001f469{ZWJ}\U0001f4bb"
        self.assertEqual(
            normalize_for_tts(f"She typed {woman_technologist} all night."),
            f"She typed {woman_technologist} all night.",
        )

    def test_zwj_beside_presentation_selector_and_symbol_is_kept(self) -> None:
        # Rainbow flag: WHITE FLAG, VS16, ZWJ, RAINBOW. Health worker: WOMAN, ZWJ, STAFF OF AESCULAPIUS, VS16.
        rainbow = f"\U0001f3f3️{ZWJ}\U0001f308"
        health = f"\U0001f469{ZWJ}⚕️"
        self.assertEqual(normalize_for_tts(f"{rainbow} {health}"), f"{rainbow} {health}")

    def test_persian_zwnj_is_kept(self) -> None:
        word = f"می{ZWNJ}خواهم"  # "I want"
        self.assertEqual(normalize_for_tts(word), word)

    def test_devanagari_joiners_are_kept(self) -> None:
        half_form = f"क्{ZWJ}ष"  # KA VIRAMA ZWJ SSA
        no_conjunct = f"क्{ZWNJ}ष"
        self.assertEqual(normalize_for_tts(half_form), half_form)
        self.assertEqual(normalize_for_tts(no_conjunct), no_conjunct)

    def test_joiner_at_the_edges_of_latin_text_is_deleted(self) -> None:
        self.assertEqual(normalize_for_tts(f"{ZWJ}word{ZWNJ}"), "word")
        self.assertEqual(normalize_for_tts(f"café{ZWJ}s"), "cafés")


if __name__ == "__main__":
    unittest.main()
