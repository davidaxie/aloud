#!/usr/bin/env bash
# Syncs the canonical Classics Bookshelf into this checkout's app resources
# and builds the bundled catalog (title case, repaired authors) from it.
# The canonical copy lives outside the worktree; Resources/Bookshelf is gitignored.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="/Users/davidxie/Library/CloudStorage/OneDrive-Personal/CS/Aloud/books/"
DST="$HERE/Aloud/Resources/Bookshelf/"
NORMALIZE="$HERE/../tools/catalog_normalize.py"

if [[ ! -d "$SRC" ]]; then
  echo "warning: bookshelf source missing at $SRC — skipping sync" >&2
  # The bundle keeps what it has, but it must still pass the lint.
  if [[ -f "$DST/catalog.json" ]]; then
    python3 "$NORMALIZE" --check "$DST/catalog.json"
  fi
  exit 0
fi

mkdir -p "$DST"
# catalog.json is derived, never copied; rewriting it every build would change
# its mtime and make Xcode recopy the ~270 MB folder reference.
rsync -a --delete --exclude catalog.json "$SRC" "$DST"
python3 "$NORMALIZE" "$SRC/catalog.json" --out "$DST/catalog.json"
echo "Bookshelf synced: $(ls "$DST" | wc -l | tr -d ' ') files"
