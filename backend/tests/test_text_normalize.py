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


class HyphenTests(unittest.TestCase):
    """J032: only a hyphen at a line break is a wrap. A suspended hyphen the
    author wrote mid-line ("pre- and post-war") is spoken as written, and so is
    one wrapped just before and/or/nor, the follower list TextNormalizer.swift
    uses."""

    def test_suspended_hyphens_mid_line_are_kept(self) -> None:
        for text in (
            "Both pre- and post-war housing, short- and long-term.",
            "first- or second-order effects",
            "the x- and y-axis",
            "mid- to late-1990s",
            "long- versus short-term",
            "sixteenth- through eighteenth-century",
            "up- and downstream",
        ):
            self.assertEqual(normalize_for_tts(text), text)

    def test_line_wrap_hyphen_is_rejoined(self) -> None:
        self.assertEqual(normalize_for_tts("inter-\nnational"), "international")
        self.assertEqual(normalize_for_tts("inter- \r\n  national law"), "international law")
        self.assertEqual(normalize_for_tts("house-\nkeeper-\nship"), "housekeepership")

    def test_unicode_line_breaks_count_as_line_breaks(self) -> None:
        for brk in (" ", " ", "\u0085"):
            self.assertEqual(normalize_for_tts(f"inter-{brk}national"), "international", repr(brk))

    def test_suspended_hyphen_wrapped_before_a_follower_is_kept(self) -> None:
        self.assertEqual(
            normalize_for_tts("short-\nand long-term, two- \nor three-day, neither-\nnor"),
            "short- and long-term, two- or three-day, neither- nor",
        )

    def test_compounds_without_a_space_are_untouched(self) -> None:
        self.assertEqual(normalize_for_tts("well-being and long-term"), "well-being and long-term")


class CompatibilityFormTests(unittest.TestCase):
    """L031: NFKC made "3¼" into "31⁄4" and "10⁶" into "106", a different
    number aloud. Fractions and superscripts are kept, the set
    TextNormalizer.keepsCompatibilityForm keeps on iPhone and Mac."""

    def test_fractions_and_superscripts_are_kept(self) -> None:
        for text in (
            "It is 3¼ miles.",
            "Add ½ cup",
            "Take 2 ¾ hours",
            "2 ⅓ cups and ⅛ inch",
            "10⁶ cells",
            "x² + y³, note¹ and ↉",
            "xⁿ⁺¹ and 2⁻³",
        ):
            self.assertEqual(normalize_for_tts(text), text)

    def test_other_compatibility_forms_are_still_folded(self) -> None:
        self.assertEqual(normalize_for_tts("ﬁne ﬂour"), "fine flour")
        self.assertEqual(normalize_for_tts("Ｆｕｌｌ width"), "Full width")
        self.assertEqual(normalize_for_tts("ﬁ¼ﬂ"), "fi¼fl")


class SurrogateTests(unittest.TestCase):
    """L037: a client chunker can cut an emoji in half, and the phonemizer could
    not encode the lone half, so the whole chunk failed and was skipped."""

    def test_lone_surrogates_are_dropped(self) -> None:
        self.assertEqual(normalize_for_tts("Hello \ud83d world."), "Hello world.")
        self.assertEqual(normalize_for_tts("\udc00中文"), "中文")
        self.assertEqual(normalize_for_tts("\ud840"), "")

    def test_whole_astral_characters_are_kept(self) -> None:
        text = "Smile \U0001f600 and \U00020000."
        self.assertEqual(normalize_for_tts(text), text)

    def test_the_result_can_be_encoded(self) -> None:
        normalize_for_tts("cut \ud83d here and \ude00 there").encode("utf-8")


class IdeographicPunctuationTests(unittest.TestCase):
    """L032: espeak-ng dropped the ideographic comma and full stop, so a
    Chinese voice never paused."""

    def test_ideographic_comma_and_full_stop_become_ascii(self) -> None:
        self.assertEqual(
            normalize_for_tts("你好、世界。再见。"),
            "你好, 世界. 再见.",
        )


if __name__ == "__main__":
    unittest.main()
