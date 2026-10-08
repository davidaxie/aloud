#!/usr/bin/env python3
"""Tests for tools/catalog_normalize.py (no network required).

Run with:
    python3 -m unittest tools.test_catalog_normalize -v
"""

from __future__ import annotations

import io
import json
import os
import sys
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))
import catalog_normalize as cn  # noqa: E402


class TitleTests(unittest.TestCase):
    def assertTitle(self, raw: str, expected: str) -> None:
        self.assertEqual(cn.normalize_title(raw), expected)

    def test_major_words_capitalized_minor_words_lowered(self):
        self.assertTitle("The call of the wild", "The Call of the Wild")
        self.assertTitle("I am a woman", "I Am a Woman")

    def test_alternative_title_keeps_lowercase_or(self):
        self.assertTitle("Frankenstein; or, the modern prometheus",
                         "Frankenstein; or, The Modern Prometheus")

    def test_subtitle_after_colon_starts_capitalized(self):
        self.assertTitle("The Blue Castle: a novel", "The Blue Castle: A Novel")

    def test_trailing_complete_is_dropped(self):
        self.assertTitle("Life On The Mississippi, Complete", "Life on the Mississippi")
        self.assertTitle("The Adventures of Ferdinand Count Fathom — Complete",
                         "The Adventures of Ferdinand Count Fathom")

    def test_each_hyphen_part_capitalized(self):
        self.assertTitle("The case-book of Sherlock Holmes", "The Case-Book of Sherlock Holmes")

    def test_ellipsis_and_volume_numbers_unchanged(self):
        self.assertTitle("Occasion ... for Disaster", "Occasion ... for Disaster")
        self.assertTitle("The Mysteries of London, v. 4/4", "The Mysteries of London, v. 4/4")

    def test_brackets_and_ampersand_left_alone(self):
        self.assertTitle("Love and Freindship [sic]", "Love and Freindship [sic]")
        self.assertTitle("Literally translated, with notes, arguments, &c.",
                         "Literally Translated, with Notes, Arguments, &c.")

    def test_sentence_period_starts_a_segment(self):
        self.assertTitle("The String of Pearls; Or, The Barber of Fleet Street. A Domestic Romance.",
                         "The String of Pearls; or, The Barber of Fleet Street. A Domestic Romance.")

    def test_no_letter_is_ever_lowered(self):
        self.assertTitle("McTeague", "McTeague")
        self.assertTitle("The Black Moth: A Romance of the XVIIIth Century",
                         "The Black Moth: A Romance of the XVIIIth Century")

    def test_title_rules_are_idempotent(self):
        for raw in ("The call of the wild", "Frankenstein; or, the modern prometheus",
                    "Life On The Mississippi, Complete", "Love and Freindship [sic]"):
            once = cn.normalize_title(raw)
            self.assertEqual(cn.normalize_title(once), once, raw)


class AuthorTests(unittest.TestCase):
    def assertAuthor(self, raw: str, expected: str) -> None:
        self.assertEqual(cn.normalize_author(raw), expected)

    def test_parenthesized_expansions_dropped(self):
        self.assertAuthor("H. P. (Howard Phillips) Lovecraft", "H. P. Lovecraft")
        self.assertAuthor("Mark Twain (Samuel Clemens)", "Mark Twain")

    def test_bare_initial_takes_the_expansion(self):
        self.assertAuthor("T. (Tobias) Smollett", "Tobias Smollett")

    def test_pseudonym_and_et_al_dropped(self):
        self.assertAuthor("Adela Florence Cory Nicolson (AKA Laurence Hope), et al.",
                          "Adela Florence Cory Nicolson")

    def test_run_together_initials_spaced(self):
        self.assertAuthor("G.K. Chesterton", "G. K. Chesterton")

    def test_trailing_degree_unchanged(self):
        self.assertAuthor("Rev. A. Bernstein, B.D.", "Rev. A. Bernstein, B.D.")

    def test_title_of_rank_dropped(self):
        self.assertAuthor("Emperor of Rome Marcus Aurelius", "Marcus Aurelius")
        self.assertAuthor("Emperor of Hindustan Babur", "Babur")
        self.assertAuthor("Raymond King Cummings", "Raymond King Cummings")

    def test_pseudonym_of_rewritten_to_the_pen_name(self):
        self.assertAuthor("C. Collodi--Pseudonym of Carlo Lorenzini", "C. Collodi")

    def test_trailing_baron_dropped(self):
        self.assertAuthor("George Gordon Byron, Baron Byron", "George Gordon Byron")

    def test_a_real_name_is_left_alone(self):
        self.assertAuthor("Mary Wollstonecraft Shelley", "Mary Wollstonecraft Shelley")

    def test_lowercase_first_letter_raised(self):
        self.assertAuthor("abbé Prévost", "Abbé Prévost")


class DisplayTitleTests(unittest.TestCase):
    def assertDisplay(self, title: str, expected: str) -> None:
        self.assertEqual(cn.display_title(title), expected)

    def test_alternative_title_dropped(self):
        self.assertDisplay("Frankenstein; or, The Modern Prometheus", "Frankenstein")
        self.assertDisplay("The Knights of the Cross, or, Krzyzacy: Historical Romance",
                           "The Knights of the Cross")
        self.assertDisplay("A Christmas Carol in Prose; Being a Ghost Story of Christmas",
                           "A Christmas Carol in Prose")
        self.assertDisplay("The String of Pearls; or, The Barber of Fleet Street. A Domestic Romance.",
                           "The String of Pearls")

    def test_generic_subtitle_dropped(self):
        self.assertDisplay("The Blue Castle: A Novel", "The Blue Castle")
        self.assertDisplay("The Monk: A Romance", "The Monk")
        self.assertDisplay("The Last of the Mohicans; A Narrative of 1757", "The Last of the Mohicans")
        self.assertDisplay("Up from Slavery: An Autobiography", "Up from Slavery")
        self.assertDisplay("Aesop's Fables; A New Translation", "Aesop's Fables")
        self.assertDisplay("Three Hundred Aesop’s Fables: Translated by George Fyler Townsend",
                           "Three Hundred Aesop’s Fables")
        self.assertDisplay("The Satires of Juvenal: Literally Translated into English Prose",
                           "The Satires of Juvenal")
        self.assertDisplay("In Praise of Folly: Illustrated with Many Curious Cuts", "In Praise of Folly")
        self.assertDisplay("The Waterloo Roll Call: With Biographical Notes", "The Waterloo Roll Call")
        self.assertDisplay("The Pirate: Andrew Lang Edition", "The Pirate")

    def test_long_title_cut_at_its_first_colon_after_two_words(self):
        self.assertDisplay("Old Times on the Upper Mississippi: The Recollections of a Steamboat Pilot",
                           "Old Times on the Upper Mississippi")
        self.assertDisplay("Under the Witches' Moon: A Romantic Tale of Mediaeval Rome",
                           "Under the Witches' Moon")
        # A one-word head is not a title on its own.
        self.assertDisplay("Erewhon: Or, Over the Range of the Mountains and Far Away",
                           "Erewhon: Or, Over the Range of the Mountains and Far Away")

    def test_short_or_plain_titles_unchanged(self):
        for title in ("Pride and Prejudice", "The Cask of Amontillado",
                      "Ecce Homo: Complete Works, Volume Seventeen",
                      "The Czar's Spy: The Mystery of a Silent Love",
                      "The Young Visiters or, Mr. Salteena's Plan",
                      "The Importance of Being Earnest"):
            self.assertDisplay(title, title)

    def test_display_title_is_idempotent(self):
        for title in ("Frankenstein; or, The Modern Prometheus", "The Blue Castle: A Novel",
                      "Old Times on the Upper Mississippi: The Recollections of a Steamboat Pilot"):
            once = cn.display_title(title)
            self.assertEqual(cn.display_title(once), once)


class BookTests(unittest.TestCase):
    def book(self, **fields) -> dict:
        base = {"gutenberg_id": 215, "title": "The call of the wild", "author": "Jack London",
                "year": 1903, "file": "215-the-call-of-the-wild.txt", "words": 31_000}
        base.update(fields)
        return base

    def test_override_wins_verbatim(self):
        raw = self.book(gutenberg_id=6768, title="The Man Upstairs", author=". G. Wodehouse")
        out = cn.normalize_book(raw, {"6768": {"author": "P. G. Wodehouse"}})
        self.assertEqual(out["author"], "P. G. Wodehouse")
        self.assertEqual(out["header_author"], ". G. Wodehouse")

    def test_override_beats_the_rules(self):
        out = cn.normalize_book(self.book(), {"215": {"title": "The call of the WILD"}})
        self.assertEqual(out["title"], "The call of the WILD")

    def test_header_fields_only_when_changed(self):
        out = cn.normalize_book(self.book(), {})
        self.assertEqual(out["title"], "The Call of the Wild")
        self.assertEqual(out["header_title"], "The call of the wild")
        self.assertNotIn("header_author", out)

    def test_stale_header_field_dropped(self):
        stale = self.book(title="White Fang", author="Jack London", header_author="Jack London")
        self.assertNotIn("header_author", cn.normalize_book(stale, {}))

    def test_other_fields_and_key_order_kept(self):
        raw = self.book()
        out = cn.normalize_book(raw, {})
        for key in ("gutenberg_id", "year", "file", "words"):
            self.assertEqual(out[key], raw[key])
        self.assertEqual(list(out)[: len(raw)], list(raw))

    def test_full_title_kept_when_the_display_title_is_shorter(self):
        raw = self.book(gutenberg_id=84, title="Frankenstein; or, the modern prometheus",
                        author="Mary Wollstonecraft Shelley")
        out = cn.normalize_book(raw, {})
        self.assertEqual(out["title"], "Frankenstein")
        self.assertEqual(out["full_title"], "Frankenstein; or, The Modern Prometheus")
        self.assertEqual(out["header_title"], "Frankenstein; or, the modern prometheus")
        self.assertNotIn("full_title", cn.normalize_book(self.book(), {}))

    def test_an_override_title_keeps_the_full_title(self):
        raw = self.book(gutenberg_id=41537, title="The Divine Comedy of Dante Alighieri: The Inferno",
                        author="Dante Alighieri")
        out = cn.normalize_book(raw, {"41537": {"title": "The Inferno"}})
        self.assertEqual(out["title"], "The Inferno")
        self.assertEqual(out["full_title"], "The Divine Comedy of Dante Alighieri: The Inferno")
        self.assertEqual(out["header_title"], "The Divine Comedy of Dante Alighieri: The Inferno")

    def test_rank_copied_from_the_override(self):
        out = cn.normalize_book(self.book(gutenberg_id=1063, title="The Cask of Amontillado"),
                                {"1063": {"rank": 1}})
        self.assertEqual(out["rank"], 1)
        self.assertNotIn("rank", cn.normalize_book(self.book(), {}))
        self.assertNotIn("rank", cn.normalize_book(dict(out), {}), "a rank the overrides dropped goes")

    def test_shipped_overrides_rank_the_short_shelf(self):
        ranked = sorted((o["rank"], int(i)) for i, o in cn.load_overrides().items() if "rank" in o)
        self.assertEqual([i for _, i in ranked], [1063, 14838, 67173, 66446, 67160, 23172, 1934, 2002])

    def test_normalize_book_is_idempotent(self):
        overrides = cn.load_overrides()
        for raw in (self.book(),
                    self.book(gutenberg_id=84, title="Frankenstein; or, the modern prometheus"),
                    self.book(gutenberg_id=41537, title="The Divine Comedy of Dante Alighieri: The Inferno"),
                    self.book(gutenberg_id=1063, title="The Cask of Amontillado"),
                    self.book(gutenberg_id=500, title="The Adventures of Pinocchio",
                              author="C. Collodi--Pseudonym of Carlo Lorenzini"),
                    self.book(gutenberg_id=6768, title="The Man Upstairs", author=". G. Wodehouse"),
                    self.book(gutenberg_id=245, title="Life On The Mississippi, Complete",
                              author="Mark Twain (Samuel Clemens)")):
            once = cn.normalize_book(raw, overrides)
            self.assertEqual(cn.normalize_book(once, overrides), once)


class LintTests(unittest.TestCase):
    RAW = [
        {"gutenberg_id": 215, "title": "The call of the wild", "author": "Jack London"},
        {"gutenberg_id": 6768, "title": "The Man Upstairs", "author": ". G. Wodehouse"},
        {"gutenberg_id": 831, "title": "Four Arthurian Romances",
         "author": "de Troyes, active 12th century Chrétien"},
    ]

    def test_lint_flags_raw_spellings(self):
        problems = cn.lint(self.RAW)
        self.assertIn("#215 title: lowercase major word 'call' in 'The call of the wild'", problems)
        self.assertTrue(any(p.startswith("#6768 author:") for p in problems))
        self.assertTrue(any(p.startswith("#831 author:") for p in problems))

    def test_lint_passes_normalized_forms(self):
        overrides = cn.load_overrides()
        normalized = [cn.normalize_book(b, overrides) for b in self.RAW]
        self.assertEqual(cn.lint(normalized), [])
        self.assertEqual([b["author"] for b in normalized],
                         ["Jack London", "P. G. Wodehouse", "Chrétien de Troyes"])

    def test_lowercase_minor_word_starting_a_segment_is_flagged(self):
        self.assertTrue(cn.title_violations("The Blue Castle: a novel"))
        self.assertEqual(cn.title_violations("Frankenstein; or, The Modern Prometheus"), [])

    def test_a_title_over_sixty_characters_is_flagged(self):
        sixty = "Gulliver's Travels into Several Remote Regions of the World!"
        self.assertEqual(len(sixty), 60)
        self.assertEqual(cn.title_violations(sixty), [])
        long = "Memoirs of the Author of a Vindication of the Rights of Woman"
        self.assertEqual(len(long), 61)
        self.assertEqual(cn.title_violations(long),
                         ["longer than 60 characters (61): '" + long + "'"])

    def test_pseudonym_and_double_hyphen_authors_are_flagged(self):
        self.assertTrue(cn.author_violations("C. Collodi--Pseudonym of Carlo Lorenzini"))
        self.assertTrue(cn.author_violations("A. Writer--B. Writer"))
        self.assertTrue(cn.author_violations("Pseudonym Smith"))
        self.assertEqual(cn.author_violations("Carlo Collodi"), [])

    def test_brackets_and_ampersand_skipped(self):
        self.assertEqual(cn.title_violations("Love and Freindship [sic]"), [])
        self.assertEqual(cn.title_violations("Notes, Arguments, &c."), [])

    def test_null_numeric_and_blank_values_are_flagged_not_raised(self):
        """The sync reads a crash's exit 1 as "lint violations only" and ships
        the catalog, so a bad value must be a lint line, never a TypeError."""
        books = [{"gutenberg_id": 1, "title": None, "author": "Jane Austen"},
                 {"gutenberg_id": 2, "title": 1984, "author": None},
                 {"gutenberg_id": 3, "title": "", "author": "Jane Austen"},
                 {"gutenberg_id": 4, "title": "   ", "author": "   "}]
        problems = cn.lint(books)
        self.assertIn("#1 title: is not a string: None", problems)
        self.assertIn("#2 title: is not a string: 1984", problems)
        self.assertIn("#2 author: is not a string: None", problems)
        self.assertIn("#3 title: is empty", problems)
        self.assertIn("#4 title: is empty", problems)
        self.assertTrue(any(p.startswith("#4 author:") for p in problems))


class OverridesTests(unittest.TestCase):
    def load(self, text: str) -> dict:
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "catalog_overrides.json"
            path.write_text(text, encoding="utf-8")
            return cn.load_overrides(path)

    def test_the_shipped_overrides_load(self):
        self.assertTrue(cn.load_overrides())

    def test_good_overrides_load(self):
        self.assertEqual(self.load('{"2": {"title": "Emma", "author": "Jane Austen"}}'),
                         {"2": {"title": "Emma", "author": "Jane Austen"}})

    def test_a_positive_integer_rank_loads(self):
        self.assertEqual(self.load('{"1063": {"rank": 1}}'), {"1063": {"rank": 1}})

    def test_a_rank_that_is_not_a_positive_integer_is_an_error(self):
        for text in ('{"2": {"rank": 0}}', '{"2": {"rank": -1}}', '{"2": {"rank": "1"}}',
                     '{"2": {"rank": 1.5}}', '{"2": {"rank": true}}', '{"2": {"rank": null}}'):
            with self.subTest(text=text), self.assertRaises(ValueError):
                self.load(text)

    def test_values_that_are_not_non_empty_strings_are_errors(self):
        for text in ('{"2": {"title": null}}', '{"2": {"title": 1984}}', '{"2": {"title": ""}}',
                     '{"2": {"title": "   "}}', '{"2": {"author": null}}', '{"2": {"author": ""}}',
                     '{"2": "Emma"}', '{"2": null}'):
            with self.subTest(text=text), self.assertRaises(ValueError):
                self.load(text)


class CLITests(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.root = Path(self.dir.name)
        self.src = self.root / "src.json"
        self.src.write_text(json.dumps({"books": LintTests.RAW}, ensure_ascii=False),
                            encoding="utf-8")

    def tearDown(self):
        self.dir.cleanup()

    def run_main(self, *argv: str) -> int:
        with redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()):
            return cn.main(list(argv))

    def test_out_writes_normalized_catalog_and_passes_lint(self):
        dst = self.root / "out" / "catalog.json"
        self.assertEqual(self.run_main(str(self.src), "--out", str(dst)), 0)
        text = dst.read_text(encoding="utf-8")
        self.assertTrue(text.endswith("}\n"))
        books = json.loads(text)["books"]
        self.assertEqual([b["gutenberg_id"] for b in books], [215, 6768, 831])
        self.assertEqual(books[0]["title"], "The Call of the Wild")
        self.assertIn("Chrétien", text, "written with ensure_ascii=False")

    def test_out_leaves_an_identical_file_untouched(self):
        dst = self.root / "catalog.json"
        self.assertEqual(self.run_main(str(self.src), "--out", str(dst)), 0)
        os.utime(dst, (1_000_000_000, 1_000_000_000))
        self.assertEqual(self.run_main(str(self.src), "--out", str(dst)), 0)
        self.assertEqual(dst.stat().st_mtime, 1_000_000_000)
        self.assertEqual([p.name for p in self.root.iterdir() if p.name.startswith(".catalog-")], [])

    def test_check_exit_codes(self):
        self.assertEqual(self.run_main(str(self.src), "--check"), 1)
        dst = self.root / "catalog.json"
        self.run_main(str(self.src), "--out", str(dst))
        self.assertEqual(self.run_main(str(dst), "--check"), 0)

    def test_a_bad_rank_stops_the_build_with_exit_2(self):
        overrides = self.root / "catalog_overrides.json"
        overrides.write_text('{"215": {"rank": 0}}', encoding="utf-8")
        dst = self.root / "catalog.json"
        with mock.patch.object(cn, "OVERRIDES_PATH", overrides):
            self.assertEqual(self.run_main(str(self.src), "--out", str(dst)), 2)
        self.assertFalse(dst.exists(), "nothing is written")

    def test_usage_and_io_errors_exit_2(self):
        self.assertEqual(self.run_main(), 2)
        self.assertEqual(self.run_main(str(self.root / "missing.json"), "--check"), 2)
        self.assertEqual(self.run_main(str(self.src), "--check", "--out", "x.json"), 2)


if __name__ == "__main__":
    unittest.main()
