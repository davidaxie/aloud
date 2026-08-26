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
import http.client
import json
import os
import re
import sys
import tempfile
import time
import urllib.error
import urllib.request
from datetime import date
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
QUEUE_PATH = ROOT / "tools" / "gutenberg_queue.json"
BOOKS_DIR = ROOT / "books"
CATALOG_PATH = BOOKS_DIR / "catalog.json"
# Lock lives in tools/ (not books/) so it never gets synced into the app bundle.
LOCK_PATH = ROOT / "tools" / ".gutenberg_fetch.lock"

USER_AGENT = "Aloud/1.0 (personal offline reading app; contact: local user)"

# Download tuning. Every blocking socket operation is capped by
# SOCKET_TIMEOUT_S, and the whole transfer by a wall-clock budget that scales
# with the declared Content-Length at a slow-link floor rate: generous enough
# that a 3+ MB classic (Les Misérables, War and Peace) finishes on a slow
# connection, bounded so a mirror that trickles bytes can't hang the run.
SOCKET_TIMEOUT_S = 30.0
READ_CHUNK = 64 * 1024
MIN_RATE_BYTES_PER_S = 20 * 1024
BUDGET_FLOOR_S = 90.0
BUDGET_UNKNOWN_SIZE_S = 300.0
BUDGET_CAP_S = 900.0

# A lock file older than this is assumed to be left over from a crashed run.
STALE_LOCK_S = 2 * 60 * 60
POLITE_DELAY_S = 2.0


def _mirror_dir(book_id: int) -> str:
    """PG mirror path layout: id 2701 -> 2/7/0/2701, id 84 -> 8/84, id 7 -> 0/7."""
    s = str(book_id)
    if len(s) == 1:
        return f"0/{s}"
    return "/".join(s[:-1]) + f"/{s}"


# The pglaf mirror is Project Gutenberg's own bulk-friendly host; the main
# site rate-limits scripted access aggressively, so try the mirror first.
URL_PATTERNS = [
    "https://gutenberg.pglaf.org/{mdir}/{id}-0.txt",
    "https://gutenberg.pglaf.org/{mdir}/{id}.txt",
    "https://www.gutenberg.org/cache/epub/{id}/pg{id}.txt",
    "https://www.gutenberg.org/files/{id}/{id}-0.txt",
    "https://www.gutenberg.org/files/{id}/{id}.txt",
]
START_RE = re.compile(r"\*\*\* ?START OF (?:THE|THIS) PROJECT GUTENBERG EBOOK[^*]*\*\*\*")
END_RE = re.compile(r"\*\*\* ?END OF (?:THE|THIS) PROJECT GUTENBERG EBOOK[^*]*\*\*\*")
# Legacy (pre-2003) etexts have no "*** START/END ... ***" markers: the header
# ends with the "small print" legal block ("*END*THE SMALL PRINT! FOR PUBLIC
# DOMAIN ETEXTS*Ver...") and the text closes with a line like
# "End of The Project Gutenberg Etext of ..." — match both, case-insensitively.
LEGACY_START_RE = re.compile(r"\*END\*? ?THE SMALL PRINT[^\n]*", re.IGNORECASE)
LEGACY_END_RE = re.compile(
    r"^\s*(?:The\s+)?End of (?:(?:the|this)\s+)?Project Gutenberg(?:'s)?\s",
    re.IGNORECASE | re.MULTILINE,
)


def slugify(title: str) -> str:
    slug = re.sub(r"[^a-z0-9]+", "-", title.lower()).strip("-")
    return slug[:60] or "book"


def load_json(path: Path, default):
    if path.exists():
        return json.loads(path.read_text(encoding="utf-8"))
    return default


def _download_budget_s(expected_bytes: int | None) -> float:
    """Wall-clock budget for one URL, scaled to the declared size."""
    if expected_bytes is None:
        return BUDGET_UNKNOWN_SIZE_S
    scaled = BUDGET_FLOOR_S + expected_bytes / MIN_RATE_BYTES_PER_S
    return min(BUDGET_CAP_S, scaled)


def _read_all(res, url: str, budget_s: float) -> bytes:
    """Read the whole response body under a hard wall-clock budget.

    read1() performs at most one underlying socket recv per call, and the
    socket timeout is re-derived from the remaining budget before each read,
    so a connection that trickles bytes can never defer the deadline: every
    blocking call is individually capped and the deadline is re-checked
    between reads.
    """
    deadline = time.monotonic() + budget_s
    try:
        sock = res.fp.raw._sock  # CPython internals; best-effort
    except AttributeError:
        sock = None
    chunks: list[bytes] = []
    while True:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError(f"deadline ({budget_s:.0f}s) exceeded for {url}")
        if sock is not None:
            try:
                sock.settimeout(min(SOCKET_TIMEOUT_S, remaining))
            except OSError:
                sock = None
        chunk = res.read1(READ_CHUNK)
        if not chunk:
            return b"".join(chunks)
        chunks.append(chunk)


def fetch_text(book_id: int) -> str | None:
    for pattern in URL_PATTERNS:
        url = pattern.format(id=book_id, mdir=_mirror_dir(book_id))
        req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
        try:
            with urllib.request.urlopen(req, timeout=SOCKET_TIMEOUT_S) as res:
                declared = res.headers.get("Content-Length")
                expected = int(declared) if declared and declared.strip().isdigit() else None
                raw = _read_all(res, url, _download_budget_s(expected))
            # A mirror (or proxy) that closes the connection early makes
            # read1() report a clean EOF instead of raising IncompleteRead,
            # so verify the length ourselves — a shortfall is a failed
            # attempt, not a shorter book.
            if expected is not None and len(raw) < expected:
                print(
                    f"    (truncated: {len(raw):,}/{expected:,} bytes from {url})",
                    flush=True,
                )
                continue
            try:
                return raw.decode("utf-8")
            except UnicodeDecodeError:
                return raw.decode("latin-1")
        except (OSError, http.client.HTTPException) as err:
            # OSError covers HTTPError/URLError/TimeoutError/socket errors;
            # HTTPException covers e.g. IncompleteRead when a chunked
            # response is cut off mid-chunk. Either way: next mirror.
            print(f"    ({type(err).__name__} on {url})", flush=True)
            continue
    return None


def header_field(raw: str, field: str) -> str | None:
    m = re.search(rf"^{field}:\s*(.+)$", raw[:4000], re.MULTILINE)
    return m.group(1).strip() if m else None


def _boilerplate_bounds(raw: str) -> tuple[int | None, int | None]:
    start = START_RE.search(raw)
    end = END_RE.search(raw)
    s = start.end() if start else None
    e = end.start() if end else None
    if s is None:
        # Last small-print marker: the block's own closing line.
        legacy_start = None
        for legacy_start in LEGACY_START_RE.finditer(raw):
            pass
        if legacy_start is not None and (e is None or legacy_start.end() < e):
            s = legacy_start.end()
    if e is None:
        # Last "End of ... Project Gutenberg ..." line after the body start,
        # so a mention inside the header can't truncate the whole book.
        candidates = [m for m in LEGACY_END_RE.finditer(raw) if s is None or m.start() > s]
        if candidates:
            e = candidates[-1].start()
    return s, e


def strip_boilerplate(raw: str) -> tuple[str, bool]:
    """Strip the Gutenberg header/footer (modern or legacy format).

    Returns (body, clean). clean is False when one or both markers were
    missing — the caller keeps the text but should warn loudly, because some
    license boilerplate may remain.
    """
    s, e = _boilerplate_bounds(raw)
    if s is not None and e is not None and s < e:
        return raw[s:e].strip("\n") + "\n", True
    if s is not None:
        return raw[s:].strip("\n") + "\n", False
    if e is not None:
        return raw[:e].strip("\n") + "\n", False
    return raw.strip("\n") + "\n", False


def acquire_lock() -> bool:
    """Single-instance guard: O_CREAT|O_EXCL lock file with stale takeover.

    Prevents a manual run from racing the scheduled one — both would load the
    same catalog snapshot, fetch the same books, and the last writer would
    drop the other's catalog entries.
    """
    LOCK_PATH.parent.mkdir(parents=True, exist_ok=True)
    for _ in range(2):
        try:
            fd = os.open(LOCK_PATH, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o644)
        except FileExistsError:
            try:
                age = time.time() - LOCK_PATH.stat().st_mtime
            except FileNotFoundError:
                continue  # holder released between open and stat; retry once
            if age <= STALE_LOCK_S:
                return False
            # Left behind by a crashed run — take it over.
            try:
                LOCK_PATH.unlink()
            except FileNotFoundError:
                pass
            continue
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(f"{os.getpid()}\n")
        return True
    return False


def release_lock() -> None:
    try:
        LOCK_PATH.unlink()
    except FileNotFoundError:
        pass


def save_catalog(catalog: dict) -> None:
    """Atomically replace catalog.json (temp file + fsync + os.replace).

    A crash mid-write must never leave a truncated catalog: the scheduled run
    would then crash on load every day until someone repaired it by hand.
    """
    fd, tmp = tempfile.mkstemp(
        dir=str(CATALOG_PATH.parent), prefix=".catalog-", suffix=".tmp"
    )
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(json.dumps(catalog, indent=2, ensure_ascii=False) + "\n")
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, CATALOG_PATH)
    except BaseException:
        try:
            os.unlink(tmp)
        except FileNotFoundError:
            pass
        raise


def run(queue: list, count: int) -> int:
    BOOKS_DIR.mkdir(parents=True, exist_ok=True)
    catalog = load_json(CATALOG_PATH, {"books": []})
    have = {b["gutenberg_id"] for b in catalog["books"]}

    pending = [q for q in queue if q["id"] not in have]
    if not pending:
        print("Bookshelf complete — queue exhausted, nothing to fetch.")
        return 0

    fetched = 0
    for item in pending:
        if fetched >= count:
            break
        book_id = item["id"]
        print(f"Fetching #{book_id}: {item['title']} — {item['author']} ...")
        raw = fetch_text(book_id)
        if raw is None:
            print(f"  ! all mirrors failed for #{book_id}, skipping this run")
            continue
        # Mirror files may start directly at the "*** START OF THE PROJECT
        # GUTENBERG EBOOK ***" marker with no header preamble — match
        # case-insensitively.
        if "PROJECT GUTENBERG" not in raw[:4000].upper() or len(raw) < 10_000:
            print(f"  ! #{book_id} doesn't look like a Gutenberg text, skipping")
            continue

        # The file's own header is authoritative — it self-corrects any bad ID
        # mapping in the queue.
        title = header_field(raw, "Title") or item["title"]
        author = header_field(raw, "Author") or item["author"]
        body, clean = strip_boilerplate(raw)
        if not clean:
            print(
                f"  ! WARNING: #{book_id} ({title}) is missing Gutenberg "
                "START/END boilerplate markers (legacy or unusual format) — "
                "some license text may remain; keeping the file, please "
                "inspect it by hand.",
                flush=True,
            )
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
        save_catalog(catalog)
        have.add(book_id)
        fetched += 1
        print(f"  + {filename} ({words:,} words)")
        time.sleep(POLITE_DELAY_S)

    remaining = len([q for q in queue if q["id"] not in have])
    print(
        f"Done: {fetched} fetched this run, {len(catalog['books'])} on the shelf, "
        f"{remaining} still queued."
    )
    return 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--count", type=int, default=5, help="books to fetch this run")
    args = parser.parse_args()

    queue = load_json(QUEUE_PATH, [])
    if not queue:
        print(f"error: queue not found or empty at {QUEUE_PATH}", file=sys.stderr)
        return 1

    if not acquire_lock():
        print(f"Another fetch run is already in progress (lock: {LOCK_PATH}) — exiting.")
        return 0
    try:
        return run(queue, args.count)
    finally:
        release_lock()


if __name__ == "__main__":
    sys.exit(main())
