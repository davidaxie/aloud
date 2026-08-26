#!/usr/bin/env python3
"""Regression tests for tools/gutenberg_fetch.py (no network required).

Run with:
    python3 -m unittest tools.test_gutenberg_fetch -v
or:
    cd tools && python3 -m unittest test_gutenberg_fetch -v
"""

from __future__ import annotations

import http.client
import json
import os
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))
import gutenberg_fetch as gf  # noqa: E402


class MirrorDirTests(unittest.TestCase):
    def test_layout(self):
        self.assertEqual(gf._mirror_dir(7), "0/7")
        self.assertEqual(gf._mirror_dir(84), "8/84")
        self.assertEqual(gf._mirror_dir(2701), "2/7/0/2701")
        self.assertEqual(gf._mirror_dir(2600), "2/6/0/2600")


MODERN = (
    "Title: Example Book\nAuthor: Someone\n\n"
    "*** START OF THE PROJECT GUTENBERG EBOOK EXAMPLE ***\n"
    "\nActual body text here.\n\n"
    "*** END OF THE PROJECT GUTENBERG EBOOK EXAMPLE ***\n"
    "License trailer.\n"
)

LEGACY = (
    "The Project Gutenberg Etext of New York, by James Fenimore Cooper\n"
    "...announcement...\n"
    "*START**THE SMALL PRINT!**FOR PUBLIC DOMAIN ETEXTS**START*\n"
    "Why is this Small Print statement here? You know: lawyers.\n"
    "It also tells you about the end of this etext.\n"
    "*END*THE SMALL PRINT! FOR PUBLIC DOMAIN ETEXTS*Ver.04.29.93*END*\n"
    "\nNEW YORK\n\nThe actual legacy body text.\n\n"
    "End of The Project Gutenberg Etext of New York, by Cooper\n"
)


class StripBoilerplateTests(unittest.TestCase):
    def test_modern_markers_stripped(self):
        body, clean = gf.strip_boilerplate(MODERN)
        self.assertTrue(clean)
        self.assertIn("Actual body text", body)
        self.assertNotIn("START OF THE PROJECT", body)
        self.assertNotIn("License trailer", body)

    def test_legacy_markers_stripped(self):
        # Finding 40: pre-2003 etexts without *** START/END *** markers must
        # still lose the small-print header and the "End of ... Etext" tail.
        body, clean = gf.strip_boilerplate(LEGACY)
        self.assertTrue(clean)
        self.assertIn("The actual legacy body text.", body)
        self.assertNotIn("SMALL PRINT", body)
        self.assertNotIn("End of The Project Gutenberg", body)

    def test_legacy_end_case_insensitive_variants(self):
        for tail in (
            "End of the Project Gutenberg Etext of X\n",
            "END OF THIS PROJECT GUTENBERG ETEXT\n",  # needs trailing word? no: \s matches \n
            "The End of The Project Gutenberg Etext of X\n",
            "End of Project Gutenberg's Alice in Wonderland\n",
        ):
            raw = LEGACY.rsplit("End of The Project Gutenberg", 1)[0] + tail
            body, clean = gf.strip_boilerplate(raw)
            self.assertTrue(clean, f"tail not matched: {tail!r}")
            self.assertNotIn(tail.strip()[:20], body)

    def test_no_markers_kept_but_flagged(self):
        raw = "Just some text with no markers at all.\nMore text.\n"
        body, clean = gf.strip_boilerplate(raw)
        self.assertFalse(clean)
        self.assertIn("Just some text", body)

    def test_start_only_strips_head_and_flags(self):
        raw = "Header junk\n*** START OF THE PROJECT GUTENBERG EBOOK X ***\nBody only.\n"
        body, clean = gf.strip_boilerplate(raw)
        self.assertFalse(clean)
        self.assertIn("Body only.", body)
        self.assertNotIn("Header junk", body)


class BudgetTests(unittest.TestCase):
    def test_scales_with_size(self):
        # Finding 7: a 3.3 MB book must get far more than 90 s.
        self.assertEqual(gf._download_budget_s(None), gf.BUDGET_UNKNOWN_SIZE_S)
        self.assertEqual(gf._download_budget_s(100_000), gf.BUDGET_FLOOR_S + 100_000 / gf.MIN_RATE_BYTES_PER_S)
        big = gf._download_budget_s(3_300_000)
        self.assertGreater(big, 200.0)
        self.assertLessEqual(big, gf.BUDGET_CAP_S)
        self.assertEqual(gf._download_budget_s(10**9), gf.BUDGET_CAP_S)


class FakeResponse:
    """Stands in for http.client.HTTPResponse inside urlopen()."""

    def __init__(self, data: bytes, content_length: int | None = None,
                 read1_exc: Exception | None = None,
                 trickle_delay: float = 0.0, chunk: int = 8192):
        self._data = data
        self._pos = 0
        self._exc = read1_exc
        self._delay = trickle_delay
        self._chunk = chunk
        self.headers = {}
        if content_length is not None:
            self.headers["Content-Length"] = str(content_length)
        self.fp = None  # _read_all's socket grab falls back gracefully

    def read1(self, n: int = -1) -> bytes:
        if self._exc is not None:
            raise self._exc
        if self._delay:
            time.sleep(self._delay)
        take = min(n if n > 0 else self._chunk, self._chunk)
        out = self._data[self._pos:self._pos + take]
        self._pos += len(out)
        return out

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


class ReadAllTests(unittest.TestCase):
    def test_reads_everything(self):
        data = b"x" * 200_000
        res = FakeResponse(data)
        self.assertEqual(gf._read_all(res, "u", 30.0), data)

    def test_trickle_hits_deadline(self):
        # Finding 3 (trickle): the deadline must fire even though every
        # individual read succeeds — small reads, deadline checked between.
        res = FakeResponse(b"y" * 10_000, trickle_delay=0.05, chunk=1)
        t0 = time.monotonic()
        with self.assertRaises(TimeoutError):
            gf._read_all(res, "u", 0.3)
        self.assertLess(time.monotonic() - t0, 2.0)


class FetchTextTests(unittest.TestCase):
    def _full(self) -> bytes:
        return ("Title: T\n\n*** START OF THE PROJECT GUTENBERG EBOOK T ***\n"
                + "words " * 5000
                + "\n*** END OF THE PROJECT GUTENBERG EBOOK T ***\n").encode()

    def test_truncated_mirror_falls_through(self):
        # Finding 1: Content-Length shortfall = failed attempt, next mirror.
        full = self._full()
        responses = [
            FakeResponse(full[: len(full) // 2], content_length=len(full)),
            FakeResponse(full, content_length=len(full)),
        ]
        with mock.patch("urllib.request.urlopen", side_effect=responses):
            text = gf.fetch_text(84)
        self.assertEqual(text, full.decode())

    def test_all_mirrors_truncated_returns_none(self):
        full = self._full()
        responses = [
            FakeResponse(full[:100], content_length=len(full))
            for _ in gf.URL_PATTERNS
        ]
        with mock.patch("urllib.request.urlopen", side_effect=responses):
            self.assertIsNone(gf.fetch_text(84))

    def test_incomplete_read_falls_through(self):
        # Findings 3/23: IncompleteRead (HTTPException, not OSError) must be
        # caught and treated as a failed mirror, not abort the run.
        full = self._full()
        responses = [
            FakeResponse(b"", read1_exc=http.client.IncompleteRead(b"partial")),
            FakeResponse(full, content_length=len(full)),
        ]
        with mock.patch("urllib.request.urlopen", side_effect=responses):
            text = gf.fetch_text(84)
        self.assertEqual(text, full.decode())

    def test_latin1_fallback(self):
        full = ("*** START OF THE PROJECT GUTENBERG EBOOK T ***\ncaf\xe9\n"
                "*** END OF THE PROJECT GUTENBERG EBOOK T ***\n").encode("latin-1")
        with mock.patch("urllib.request.urlopen",
                        side_effect=[FakeResponse(full, content_length=len(full))]):
            text = gf.fetch_text(84)
        self.assertIn("café", text)


class LockTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self._orig = gf.LOCK_PATH
        gf.LOCK_PATH = Path(self._tmp.name) / "fetch.lock"

    def tearDown(self):
        gf.LOCK_PATH = self._orig
        self._tmp.cleanup()

    def test_single_instance(self):
        # Finding 11: a second concurrent run must not proceed.
        self.assertTrue(gf.acquire_lock())
        self.assertFalse(gf.acquire_lock())
        gf.release_lock()
        self.assertTrue(gf.acquire_lock())
        gf.release_lock()

    def test_stale_lock_takeover(self):
        self.assertTrue(gf.acquire_lock())
        old = time.time() - gf.STALE_LOCK_S - 60
        os.utime(gf.LOCK_PATH, (old, old))
        self.assertTrue(gf.acquire_lock())
        gf.release_lock()

    def test_release_without_lock_is_harmless(self):
        gf.release_lock()


class SaveCatalogTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self._orig = gf.CATALOG_PATH
        gf.CATALOG_PATH = Path(self._tmp.name) / "catalog.json"

    def tearDown(self):
        gf.CATALOG_PATH = self._orig
        self._tmp.cleanup()

    def test_atomic_write_roundtrip(self):
        # Finding 39: written via temp file + os.replace, no temp leftovers.
        catalog = {"books": [{"gutenberg_id": 84, "title": "Frankenstein"}]}
        gf.save_catalog(catalog)
        self.assertEqual(json.loads(gf.CATALOG_PATH.read_text()), catalog)
        leftovers = [p for p in Path(self._tmp.name).iterdir()
                     if p.name != "catalog.json"]
        self.assertEqual(leftovers, [])

    def test_failed_serialization_leaves_old_file(self):
        gf.save_catalog({"books": []})
        before = gf.CATALOG_PATH.read_text()
        with self.assertRaises(TypeError):
            gf.save_catalog({"books": [object()]})
        self.assertEqual(gf.CATALOG_PATH.read_text(), before)
        leftovers = [p for p in Path(self._tmp.name).iterdir()
                     if p.name != "catalog.json"]
        self.assertEqual(leftovers, [])


if __name__ == "__main__":
    unittest.main(verbosity=2)
