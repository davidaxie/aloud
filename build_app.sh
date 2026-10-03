#!/usr/bin/env bash
#
# build_app.sh — build Aloud for Mac, the native app, in Release.
#
# What it does:
#   1. Syncs the Classics shelf and regenerates the Xcode project from
#      ios/project.yml, as ios/build.sh does for the iPhone.
#   2. Builds the AloudMac scheme in Release through ios/xcb.sh, which keeps
#      the derived data in ~/Library/Developer/Xcode/DerivedData/Aloud-mac
#      (never under OneDrive) and signs ad hoc, so the sandbox is real. It
#      refuses an unsigned Mac build: unsigned means unsandboxed.
#   3. Checks the result as the release hygiene does: the shipping bundle id
#      (com.davidxie.Aloud.mac), no test hooks in the binary, sandboxed with
#      no temporary exception, and a signature that verifies.
#   4. Prints where Aloud.app is. With --install, it also copies the app to
#      ~/Applications/Aloud.app.
#
# It never launches Aloud. Open it yourself, from Finder or Spotlight.
#
# Where it installs, and where it never does:
#   - ~/Applications, not /Applications: the build is yours alone, and
#     /Applications would need an administrator.
#   - Never into this repo. The repo lives in OneDrive, and codesign rejects
#     the extended attributes OneDrive puts on the files it syncs. A signed
#     bundle in a synced folder can also be rewritten under it, and then its
#     signature no longer verifies.
#
# The old web app's packager (pywebview, com.davidxie.aloud) is
# legacy/build_web_app.sh; see docs/legacy-web-app.md.
#
# Usage: ./build_app.sh [--install]
#
set -euo pipefail

usage() {
  echo "usage: $0 [--install]"
  echo "  Builds Aloud for Mac (Release) and prints where Aloud.app is."
  echo "  --install  also copies it to ~/Applications/Aloud.app"
  echo "  It never launches the app."
}

INSTALL=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --install) INSTALL=1 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
  shift
done

# Absolute path to the repo root (this script's own directory).
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IOS="$REPO_ROOT/ios"
# DEVELOPER_DIR and the Mac's derived-data path: the constants xcb.sh uses.
# shellcheck source=ios/xcenv.sh
source "$IOS/xcenv.sh"

SHIPPING_ID="com.davidxie.Aloud.mac"
APP="$XCB_MAC_DERIVED/Build/Products/Release/Aloud.app"
BIN="$APP/Contents/MacOS/Aloud"
DEST_DIR="$HOME/Applications"
DEST="$DEST_DIR/Aloud.app"

echo "==> Aloud for Mac (Release)"
echo "    repo    : $REPO_ROOT"
echo "    derived : $XCB_MAC_DERIVED"

# --- sanity checks --------------------------------------------------------------
# hw.optional.arm64, not uname -m: a Terminal under Rosetta reads x86_64.
if [[ $(sysctl -n hw.optional.arm64 2>/dev/null || true) != 1 ]]; then
  echo "ERROR: Aloud for Mac builds for Apple silicon only (ARCHS = arm64)." >&2
  exit 1
fi
if [[ ! -d $DEVELOPER_DIR ]]; then
  echo "ERROR: Xcode not found at $DEVELOPER_DIR (ios/xcenv.sh pins it)." >&2
  exit 1
fi

# --- 1. the shelf and the project ------------------------------------------
echo "==> Syncing the Classics shelf"
"$IOS/sync_bookshelf.sh"
if [[ ! -f "$IOS/Aloud/Resources/Bookshelf/catalog.json" ]]; then
  echo "ERROR: no Classics shelf at ios/Aloud/Resources/Bookshelf." >&2
  echo "       It is synced from books/ (tools/gutenberg_fetch.py fills it)." >&2
  exit 1
fi

XCODEGEN="$(command -v xcodegen || true)"
[[ -n $XCODEGEN ]] || XCODEGEN=/opt/homebrew/bin/xcodegen
if [[ -x $XCODEGEN ]]; then
  echo "==> Generating ios/Aloud.xcodeproj from ios/project.yml"
  ( cd "$IOS" && "$XCODEGEN" generate )
else
  echo "    note: XcodeGen not found (brew install xcodegen); building the committed project"
fi

# --- 2. build -----------------------------------------------------------------
# xcb.sh adds this Mac as the destination, the derived data outside OneDrive
# and the ad hoc identity; it prints the path of its full log first.
echo "==> Building scheme AloudMac, Release"
if ! "$IOS/xcb.sh" -project "$IOS/Aloud.xcodeproj" -scheme AloudMac -configuration Release build; then
  echo "ERROR: the Release build failed; the full log is /tmp/xcb-last.log" >&2
  exit 1
fi
if [[ ! -x $BIN ]]; then
  echo "ERROR: the build reported success, but $BIN is missing" >&2
  exit 1
fi

# --- 3. check -------------------------------------------------------------------
# The release hygiene checks (mac-contracts, end of phase 1). Each prints a
# line; any failure stops the script before it installs anything.
echo "==> Checking $APP"
fail=0
ok()  { echo "    ok  : $*"; }
bad() { echo "    FAIL: $*" >&2; fail=1; }

id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist" 2>/dev/null || true)
if [[ $id == "$SHIPPING_ID" ]]; then ok "bundle id $id"; else bad "bundle id '$id', expected $SHIPPING_ID"; fi

# The test hooks a Release binary must not carry. The strings are read once,
# and a failed read stops the script rather than passing as "none found".
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
if ! strings -a "$BIN" > "$WORK/strings.txt"; then
  echo "ERROR: couldn't read the strings in $BIN; nothing was installed." >&2
  exit 1
fi
for needle in -uitest- ALOUD_AUDIBLE ALOUD_MUTE MutedRenderPump AloudKokoroModel; do
  n=$(grep -c -- "$needle" "$WORK/strings.txt" || true)
  if [[ $n == 0 ]]; then ok "no '$needle' in the binary"; else bad "$n x '$needle' in the binary"; fi
done

# The signed entitlements, read as a plist: the sandbox key must be true,
# not merely present.
codesign -d --entitlements - --xml "$APP" > "$WORK/entitlements.plist" 2>/dev/null || true
sandbox=$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.app-sandbox' "$WORK/entitlements.plist" 2>/dev/null || true)
if [[ $sandbox == true ]]; then ok "sandboxed"; else bad "not sandboxed"; fi
if grep -q 'temporary-exception' "$WORK/entitlements.plist"; then bad "a temporary exception in Release"; else ok "no temporary exception"; fi

if codesign --verify --deep --strict "$APP" 2>&1; then ok "codesign verifies"; else bad "codesign does not verify"; fi
# "flags=0x10002(adhoc,runtime)": signed ad hoc, with the hardened runtime.
codesign -d --verbose=2 "$APP" 2>&1 | grep -E 'flags|Runtime' | head -3 | sed 's/^/    /' || true

if [[ $fail -ne 0 ]]; then
  echo "ERROR: $APP failed the checks above; nothing was installed." >&2
  exit 1
fi

echo ""
echo "==> Built: $APP"

# --- 4. install (only with --install) -----------------------------------------
if [[ $INSTALL -eq 1 ]]; then
  case "$DEST" in
    *CloudStorage*|*OneDrive*)
      echo "ERROR: refusing to install under OneDrive: $DEST" >&2
      exit 1 ;;
  esac
  if [[ -e $DEST ]]; then
    existing=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$DEST/Contents/Info.plist" 2>/dev/null || echo unknown)
    # Replacing another app, such as the old web app, stays your call.
    if [[ $existing != "$SHIPPING_ID" ]]; then
      echo "ERROR: $DEST is another app ($existing), perhaps the old web app." >&2
      echo "       Move it to the Trash yourself, then run ./build_app.sh --install again." >&2
      exit 1
    fi
    if pgrep -f "$DEST/Contents/MacOS/Aloud" >/dev/null 2>&1; then
      echo "ERROR: Aloud is running from $DEST. Quit it (⌘Q), then run this again." >&2
      exit 1
    fi
  fi
  echo "==> Installing to $DEST"
  mkdir -p "$DEST_DIR"
  # Copy beside it and check the copy, so a failed copy never replaces a
  # working install. ditto keeps the bundle's signature intact.
  STAGE="$DEST_DIR/.Aloud.app.installing"
  rm -rf "$STAGE"
  ditto "$APP" "$STAGE"
  if ! codesign --verify --deep --strict "$STAGE" 2>&1; then
    rm -rf "$STAGE"
    echo "ERROR: the copy in $DEST_DIR doesn't verify; nothing was installed." >&2
    exit 1
  fi
  rm -rf "$DEST"
  mv "$STAGE" "$DEST"
  echo "    ok  : installed $DEST"
fi

# The old web app, if one is still around: deleting it stays your call.
for old in "/Applications/Aloud.app" "$DEST" "$REPO_ROOT/Aloud.app"; do
  [[ -e "$old/Contents/Info.plist" ]] || continue
  old_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$old/Contents/Info.plist" 2>/dev/null || true)
  if [[ $old_id == com.davidxie.aloud ]]; then
    echo "    note: the old web app is still at $old; delete it when you're ready (docs/legacy-web-app.md)"
  fi
done

echo ""
echo "Next steps:"
if [[ $INSTALL -eq 1 ]]; then
  echo "  Open Aloud from ~/Applications, Spotlight or Launchpad."
else
  echo "  Run ./build_app.sh --install to copy it to ~/Applications,"
  echo "  or open it in place from the path above."
fi
echo "  The first run reads in the System voice. For the natural voice:"
echo "  Aloud › Settings… (⌘,) › Voice & speed › Download (353 MB, once)."
