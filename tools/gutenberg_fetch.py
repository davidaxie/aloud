#!/usr/bin/env python3
"""Fetch public-domain classics from Project Gutenberg into the Aloud bookshelf.

Reads tools/gutenberg_queue.json (curated, ordered), downloads the next N books
that aren't in books/catalog.json yet, strips the Gutenberg boilerplate, and
updates the catalog. Designed to run repeatedly (e.g. a daily scheduled task):
each run tops the shelf up by --count books until the queue is exhausted.

Usage:
    python3 tools/gutenberg_fetch.py --count 5
"""

from __future__ import annotations

import argparse
import json
import re
import sys
import time
import urllib.error
import urllib.request
from datetime import date
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
QUEUE_PATH = ROOT / "tools" / "gutenberg_queue.json"
BOOKS_DIR = ROOT / "books"
CATALOG_PATH = BOOKS_DIR / "catalog.json"

USER_AGENT = "Aloud/1.0 (personal offline reading app; contact: local user)"
URL_PATTERNS = [
    "https://www.gutenberg.org/cache/epub/{id}/pg{id}.txt",
    "https://www.gutenberg.org/files/{id}/{id}-0.txt",
    "https://www.gutenberg.org/files/{id}/{id}.txt",
]
START_RE = re.compile(r"\*\*\* ?START OF (?:THE|THIS) PROJECT GUTENBERG EBOOK[^*]*\*\*\*")
END_RE = re.compile(r"\*\*\* ?END OF (?:THE|THIS) PROJECT GUTENBERG EBOOK[^*]*\*\*\*")
POLITE_DELAY_S = 2.0


def slugify(title: str) -> str:
    slug = re.sub(r"[^a-z0-9]+", "-", title.lower()).strip("-")
    return slug[:60] or "book"


def load_json(path: Path, default):
    if path.exists():
        return json.loads(path.read_text(encoding="utf-8"))
    return default


def fetch_text(book_id: int) -> str | None:
    for pattern in URL_PATTERNS:
        url = pattern.format(id=book_id)
        req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
        try:
            with urllib.request.urlopen(req, timeout=60) as res:
                raw = res.read()
            try:
                return raw.decode("utf-8")
            except UnicodeDecodeError:
                return raw.decode("latin-1")
        except (urllib.error.HTTPError, urllib.error.URLError, TimeoutError):
            continue
    return None


def header_field(raw: str, field: str) -> str | None:
    m = re.search(rf"^{field}:\s*(.+)$", raw[:4000], re.MULTILINE)
    return m.group(1).strip() if m else None


def strip_boilerplate(raw: str) -> str:
    start = START_RE.search(raw)
    end = END_RE.search(raw)
    body = raw[start.end():end.start()] if start and end else raw
    return body.strip("\n") + "\n"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--count", type=int, default=5, help="books to fetch this run")
    args = parser.parse_args()

    queue = load_json(QUEUE_PATH, [])
    if not queue:
        print(f"error: queue not found or empty at {QUEUE_PATH}", file=sys.stderr)
        return 1

    BOOKS_DIR.mkdir(parents=True, exist_ok=True)
    catalog = load_json(CATALOG_PATH, {"books": []})
    have = {b["gutenberg_id"] for b in catalog["books"]}

    pending = [q for q in queue if q["id"] not in have]
    if not pending:
        print("Bookshelf complete — queue exhausted, nothing to fetch.")
        return 0

    fetched = 0
    for item in pending:
        if fetched >= args.count:
            break
        book_id = item["id"]
        print(f"Fetching #{book_id}: {item['title']} — {item['author']} ...")
        raw = fetch_text(book_id)
        if raw is None:
            print(f"  ! all mirrors failed for #{book_id}, skipping this run")
            continue
        if "Project Gutenberg" not in raw[:2000] or len(raw) < 10_000:
            print(f"  ! #{book_id} doesn't look like a Gutenberg text, skipping")
            continue

        # The file's own header is authoritative — it self-corrects any bad ID
        # mapping in the queue.
        title = header_field(raw, "Title") or item["title"]
        author = header_field(raw, "Author") or item["author"]
        body = strip_boilerplate(raw)
        words = len(body.split())

        filename = f"{book_id}-{slugify(title)}.txt"
        (BOOKS_DIR / filename).write_text(body, encoding="utf-8")
        catalog["books"].append(
            {
                "gutenberg_id": book_id,
                "title": title,
                "author": author,
                "year": item.get("year"),
                "file": filename,
                "words": words,
                "source": f"https://www.gutenberg.org/ebooks/{book_id}",
                "added": date.today().isoformat(),
            }
        )
        CATALOG_PATH.write_text(
            json.dumps(catalog, indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
        )
        fetched += 1
        print(f"  + {filename} ({words:,} words)")
        time.sleep(POLITE_DELAY_S)

    remaining = len([q for q in queue if q["id"] not in {b['gutenberg_id'] for b in catalog['books']}])
    print(f"Done: {fetched} fetched this run, {len(catalog['books'])} on the shelf, {remaining} still queued.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
