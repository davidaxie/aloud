#!/usr/bin/env bash
# Syncs the canonical Classics Bookshelf into this checkout's app resources
# and builds the bundled catalog (title case, repaired authors) from it.
# The canonical copy lives outside the worktree; Resources/Bookshelf is gitignored.
# ALOUD_BOOKS_SRC and ALOUD_BOOKSHELF_DST point it elsewhere (the tests do).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="${ALOUD_BOOKS_SRC:-/Users/davidxie/Library/CloudStorage/OneDrive-Personal/CS/Aloud/books/}"
DST="${ALOUD_BOOKSHELF_DST:-$HERE/Aloud/Resources/Bookshelf/}"
NORMALIZE="$HERE/../tools/catalog_normalize.py"

# The bundle keeps what it has, but it must still pass the lint.
keep_bundle() {
  if [[ -f "$DST/catalog.json" ]]; then
    python3 "$NORMALIZE" --check "$DST/catalog.json"
  fi
  exit 0
}

if [[ ! -d "$SRC" ]]; then
  echo "warning: bookshelf source missing at $SRC — skipping sync" >&2
  keep_bundle
fi

# A source that is there but not whole (the empty folder the fetcher makes
# before its first download, or one OneDrive hasn't finished syncing) never
# reaches rsync --delete: that would empty the bundle and keep its old
# catalog.json, which --exclude protects. Each book needs the fields the app
# decodes, with their types, and its file beside the catalog.
if ! problems="$(python3 - "$SRC" 2>&1 <<'PY'
import json, os, sys

src = sys.argv[1]
try:
    with open(os.path.join(src, "catalog.json"), encoding="utf-8") as f:
        books = json.load(f)["books"]
    if not isinstance(books, list):
        raise TypeError("'books' is not a list")
except (OSError, ValueError, KeyError, TypeError) as err:
    sys.exit(f"no readable catalog.json ({err})")

def is_int(value):
    return isinstance(value, int) and not isinstance(value, bool)

problems, seen = [], set()
for index, book in enumerate(books):
    if not isinstance(book, dict):
        problems.append(f"books[{index}] is not an object")
        continue
    where = f"books[{index}] #{book.get('gutenberg_id')}"
    if not is_int(book.get("gutenberg_id")):
        problems.append(f"{where}: gutenberg_id is not an integer")
    elif book["gutenberg_id"] in seen:
        problems.append(f"{where}: gutenberg_id is listed twice")
    else:
        seen.add(book["gutenberg_id"])
    if not is_int(book.get("words")):
        problems.append(f"{where}: words is not an integer")
    if book.get("year") is not None and not is_int(book["year"]):
        problems.append(f"{where}: year is neither an integer nor null")
    for key in ("title", "author", "file"):
        if not isinstance(book.get(key), str) or not book[key]:
            problems.append(f"{where}: {key} is not a string")
    for key in ("header_title", "header_author"):
        if book.get(key) is not None and not isinstance(book[key], str):
            problems.append(f"{where}: {key} is not a string")
    name = book.get("file")
    if isinstance(name, str) and name and (os.path.basename(name) != name
                                           or not os.path.isfile(os.path.join(src, name))):
        problems.append(f"{where}: {name} is not in the source")
if not books:
    problems.append("catalog.json lists no books")
if problems:
    shown = problems[:5] + ([f"... and {len(problems) - 5} more"] if len(problems) > 5 else [])
    sys.exit("; ".join(shown))
PY
)"; then
  echo "warning: bookshelf source at $SRC is not whole — skipping sync: $problems" >&2
  keep_bundle
fi

mkdir -p "$DST"
# catalog.json is derived, never copied; rewriting it every build would change
# its mtime and make Xcode recopy the ~270 MB folder reference.
rsync -a --delete --exclude catalog.json "${SRC%/}/" "$DST"
python3 "$NORMALIZE" "$SRC/catalog.json" --out "$DST/catalog.json"
echo "Bookshelf synced: $(ls "$DST" | wc -l | tr -d ' ') files"
