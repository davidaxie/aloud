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
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SYNC = ROOT / "ios" / "sync_bookshelf.sh"
NORMALIZE = ROOT / "tools" / "catalog_normalize.py"
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

    def sync(self, script: Path = SYNC) -> subprocess.CompletedProcess:
        env = {**os.environ, "ALOUD_BOOKS_SRC": f"{self.src}/", "ALOUD_BOOKSHELF_DST": f"{self.dst}/"}
        return subprocess.run(["bash", str(script)], env=env, capture_output=True, text=True, timeout=50)

    def sync_with_overrides(self, overrides_text: str) -> subprocess.CompletedProcess:
        """Runs a copy of the sync and the normalizer, laid out as in the repo,
        beside a tools/catalog_overrides.json holding `overrides_text`."""
        tree = self.src.parent / "repo"
        (tree / "ios").mkdir(parents=True)
        (tree / "tools").mkdir()
        script = tree / "ios" / SYNC.name
        script.write_bytes(SYNC.read_bytes())
        (tree / "tools" / NORMALIZE.name).write_bytes(NORMALIZE.read_bytes())
        (tree / "tools" / "catalog_overrides.json").write_text(overrides_text, encoding="utf-8")
        return self.sync(script)

    def assertBundleMatchesItsCatalog(self) -> None:
        shipped = json.loads((self.dst / "catalog.json").read_text(encoding="utf-8"))
        self.assertEqual(sorted(b["file"] for b in shipped["books"]),
                         sorted(p.name for p in self.dst.iterdir() if p.name != "catalog.json"))

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

    def test_a_null_header_title_keeps_the_bundle(self):
        # catalog_normalize reads a null header_title as the raw title and fails.
        entry = {**book(900003, "Sanditon", "3-sanditon.txt"), "header_title": None}
        self.write_catalog(self.src, [entry])
        self.assertBundleKept(self.sync(), "header_title is not a string")

    # The normalizer runs before the bundle changes

    def test_a_catalog_that_cannot_be_built_keeps_the_bundle(self):
        """A typo in catalog_overrides.json, with a book renamed since the last
        sync: rsync --delete must not swap the files under the old catalog."""
        self.write_catalog(self.src, [book(900001, "Emma", "1-emma.txt"),
                                      book(900002, "Persuasion", "2-persuasion-renamed.txt")])
        self.assertBundleKept(self.sync_with_overrides('{ "900001": {"title": "Emma"} '),
                              "catalog_overrides.json")

    def test_overrides_that_are_not_objects_keep_the_bundle(self):
        self.write_catalog(self.src, [book(900003, "Sanditon", "3-sanditon.txt")])
        self.assertBundleKept(self.sync_with_overrides('{"900003": "Sanditon"}'), "skipping sync")

    def test_override_values_that_are_not_titles_keep_the_bundle(self):
        """A null or numeric override crashed the lint (exit 1, read as lint
        violations, so the catalog shipped); a blank one shipped a blank row."""
        self.write_catalog(self.src, [book(900003, "Sanditon", "3-sanditon.txt")])
        for value in ("null", "1984", '""', '"   "'):
            for key in ("title", "author"):
                with self.subTest(key=key, value=value):
                    tree = self.src.parent / "repo"
                    if tree.exists():
                        shutil.rmtree(tree)
                    result = self.sync_with_overrides(f'{{"900003": {{"{key}": {value}}}}}')
                    self.assertBundleKept(result, f"{key} must be a non-empty string")

    def test_a_catalog_that_fails_the_lint_still_lands_whole(self):
        """The lint fails the build as before, with the files and catalog in step."""
        self.write_catalog(self.src, [book(900003, "Sanditon", "3-sanditon.txt")])
        result = self.sync_with_overrides('{"900003": {"title": "sanditon"}}')
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("lowercase major word 'sanditon'", result.stderr)
        self.assertNotIn("skipping sync", result.stderr)
        self.assertBundleMatchesItsCatalog()

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

    def test_an_unchanged_catalog_keeps_its_mtime(self):
        """Xcode recopies the folder when catalog.json's mtime moves."""
        self.write_catalog(self.src, [book(900001, "Emma", "1-emma.txt")])
        self.assertEqual(self.sync().returncode, 0)
        catalog = self.dst / "catalog.json"
        os.utime(catalog, ns=(1_000_000_000, 1_000_000_000))
        result = self.sync()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(catalog.stat().st_mtime_ns, 1_000_000_000)
        self.assertEqual(sorted(p.name for p in self.dst.iterdir()), ["1-emma.txt", "catalog.json"])

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
