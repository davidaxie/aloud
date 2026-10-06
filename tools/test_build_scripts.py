#!/usr/bin/env python3
"""Tests for the build scripts: ios/sync_bookshelf.sh against scratch
folders, and legacy/build_web_app.sh's pinned build-time downloads.
No network; nothing outside a temporary directory is touched.

Run with:
    python3 -m unittest tools.test_build_scripts -v
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SYNC = ROOT / "ios" / "sync_bookshelf.sh"
LEGACY = ROOT / "legacy" / "build_web_app.sh"


def book(book_id: int, title: str, file: str, year=None) -> dict:
    return {"gutenberg_id": book_id, "title": title, "author": "Jane Austen",
            "year": year, "file": file, "words": 120000}


class SyncBookshelfTests(unittest.TestCase):
    """The sync replaces the bundle only from a whole source: a readable
    catalog whose books are all beside it, with the types the app decodes.
    Anything less keeps the bundle as it is."""

    def setUp(self):
        # Never run a sync that can't be pointed away from the real folders.
        self.assertIn("ALOUD_BOOKS_SRC", SYNC.read_text(encoding="utf-8"))
        self.assertIn("ALOUD_BOOKSHELF_DST", SYNC.read_text(encoding="utf-8"))
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.src = Path(tmp.name) / "books"
        self.dst = Path(tmp.name) / "Bookshelf"
        self.dst.mkdir()
        self.bundled = [book(900001, "Emma", "1-emma.txt"),
                        book(900002, "Persuasion", "2-persuasion.txt")]
        self.write_catalog(self.dst, self.bundled)
        self.bundle_before = self.snapshot(self.dst)

    # Helpers

    @staticmethod
    def write_catalog(folder: Path, books: list, with_files: bool = True) -> None:
        folder.mkdir(parents=True, exist_ok=True)
        (folder / "catalog.json").write_text(json.dumps({"books": books}), encoding="utf-8")
        if with_files:
            for entry in books:
                if isinstance(entry, dict) and isinstance(entry.get("file"), str):
                    (folder / entry["file"]).write_text(f"text of {entry['title']}\n", encoding="utf-8")

    @staticmethod
    def snapshot(folder: Path) -> dict:
        return {p.name: p.read_bytes() for p in sorted(folder.iterdir())}

    def sync(self) -> subprocess.CompletedProcess:
        env = {**os.environ, "ALOUD_BOOKS_SRC": f"{self.src}/", "ALOUD_BOOKSHELF_DST": f"{self.dst}/"}
        return subprocess.run(["bash", str(SYNC)], env=env, capture_output=True, text=True, timeout=50)

    def assertBundleKept(self, result: subprocess.CompletedProcess, reason: str) -> None:
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("skipping sync", result.stderr)
        self.assertIn(reason, result.stderr)
        self.assertEqual(self.snapshot(self.dst), self.bundle_before, "the bundle is untouched")

    # The guard

    def test_missing_source_keeps_the_bundle(self):
        self.assertBundleKept(self.sync(), "missing")

    def test_empty_source_keeps_the_bundle(self):
        self.src.mkdir()
        self.assertBundleKept(self.sync(), "no readable catalog.json")

    def test_a_listed_book_missing_from_the_source_keeps_the_bundle(self):
        self.write_catalog(self.src, [book(900003, "Sanditon", "3-sanditon.txt")])
        (self.src / "3-sanditon.txt").unlink()
        self.assertBundleKept(self.sync(), "3-sanditon.txt is not in the source")

    def test_a_year_that_is_not_a_number_keeps_the_bundle(self):
        self.write_catalog(self.src, [book(900003, "Sanditon", "3-sanditon.txt", year="c. 1817")])
        self.assertBundleKept(self.sync(), "year is neither an integer nor null")

    def test_an_id_in_quotes_keeps_the_bundle(self):
        entry = {**book(900003, "Sanditon", "3-sanditon.txt"), "gutenberg_id": "900003"}
        self.write_catalog(self.src, [entry])
        self.assertBundleKept(self.sync(), "gutenberg_id is not an integer")

    def test_a_duplicate_id_keeps_the_bundle(self):
        self.write_catalog(self.src, [book(900003, "Sanditon", "3-sanditon.txt"),
                                      book(900003, "Lady Susan", "4-lady-susan.txt")])
        self.assertBundleKept(self.sync(), "listed twice")

    def test_a_file_outside_the_folder_keeps_the_bundle(self):
        self.write_catalog(self.src, [book(900003, "Sanditon", "3-sanditon.txt")])
        catalog = {"books": [book(900003, "Sanditon", "../3-sanditon.txt")]}
        (self.src / "catalog.json").write_text(json.dumps(catalog), encoding="utf-8")
        self.assertBundleKept(self.sync(), "is not in the source")

    # A whole source

    def test_a_whole_source_replaces_the_bundle(self):
        books = [book(900001, "Emma", "1-emma.txt", year=1815), book(900003, "Sanditon", "3-sanditon.txt")]
        self.write_catalog(self.src, books)
        result = self.sync()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("skipping sync", result.stderr)
        self.assertEqual(sorted(p.name for p in self.dst.iterdir()),
                         ["1-emma.txt", "3-sanditon.txt", "catalog.json"], "the stale book is gone")
        shipped = json.loads((self.dst / "catalog.json").read_text(encoding="utf-8"))
        self.assertEqual([b["gutenberg_id"] for b in shipped["books"]], [900001, 900003])

    def test_the_real_source_passes_the_guard(self):
        """The canonical books/ (when this machine has it) is whole."""
        real = Path("/Users/davidxie/Library/CloudStorage/OneDrive-Personal/CS/Aloud/books")
        if not (real / "catalog.json").is_file():
            self.skipTest("no canonical books/ here")
        guard = SYNC.read_text(encoding="utf-8").split("<<'PY'\n", 1)[1].split("\nPY\n", 1)[0]
        result = subprocess.run(["python3", "-", str(real)], input=guard, capture_output=True,
                                text=True, timeout=50)
        self.assertEqual(result.returncode, 0, result.stderr)


class LegacyPackagerTests(unittest.TestCase):
    """legacy/build_web_app.sh runs what uv fetches at build time; each
    package is pinned to one release, never whatever is newest that day."""

    def test_every_uv_with_is_pinned(self):
        script = LEGACY.read_text(encoding="utf-8")
        requirements = re.findall(r"--with\s+(?:'([^']+)'|\"([^\"]+)\"|(\S+))", script)
        found = [next(r for r in groups if r) for groups in requirements]
        self.assertTrue(found, "the icon step still uses uv run --with")
        for requirement in found:
            self.assertRegex(requirement, r"^[A-Za-z0-9_.\-\[\]]+==[0-9][0-9A-Za-z.]*$", requirement)


if __name__ == "__main__":
    unittest.main()
