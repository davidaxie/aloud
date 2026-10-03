#!/bin/bash
# Repairs macOS framework bundles in the Swift package artifacts that were
# zipped without their symlinks. onnxruntime-libs 1.27.1 ships its macOS
# static framework with Versions/Current and the top-level entries as copies,
# so Xcode embeds a malformed bundle that codesign rejects. A macOS framework
# needs Versions/Current -> A and top-level symlinks into it.
#
# Usage: repair_static_frameworks.sh <DerivedData>/<project>/SourcePackages/artifacts
# Idempotent; run as the Mac schemes' build pre-action, before Xcode plans the build.
set -euo pipefail
root="${1:?artifacts root}"
[ -d "$root" ] || exit 0
find "$root" -path '*/macos-*' -name '*.framework' -type d -prune | while IFS= read -r fw; do
  current="$fw/Versions/Current"
  [ -d "$current" ] && [ ! -L "$current" ] || continue
  name=$(basename "$fw" .framework)
  echo "repairing $fw"
  # Anything only at the top level (Modules) joins Versions/A.
  for entry in Headers Modules Resources "$name"; do
    if [ -e "$fw/$entry" ] && [ ! -L "$fw/$entry" ] && [ ! -e "$fw/Versions/A/$entry" ]; then
      mv "$fw/$entry" "$fw/Versions/A/$entry"
    fi
  done
  rm -rf "$current"
  ln -s A "$current"
  for entry in Headers Modules Resources "$name"; do
    [ -e "$fw/Versions/A/$entry" ] || continue
    rm -rf "${fw:?}/$entry"
    ln -s "Versions/Current/$entry" "$fw/$entry"
  done
done
