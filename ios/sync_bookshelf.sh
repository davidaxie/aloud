#!/usr/bin/env bash
# Syncs the canonical Classics Bookshelf into app resources.
# The canonical copy lives outside the worktree; Resources/Bookshelf is gitignored.
set -euo pipefail

SRC="/Users/davidxie/Library/CloudStorage/OneDrive-Personal/CS/Aloud/books/"
DST="/Users/davidxie/Library/CloudStorage/OneDrive-Personal/CS/Aloud/.claude/worktrees/aloud-extension-review-3acd07/ios/Aloud/Resources/Bookshelf/"

if [[ ! -d "$SRC" ]]; then
  echo "warning: bookshelf source missing at $SRC — skipping sync" >&2
  exit 0
fi

mkdir -p "$DST"
rsync -a --delete "$SRC" "$DST"
echo "Bookshelf synced: $(ls "$DST" | wc -l | tr -d ' ') files"
