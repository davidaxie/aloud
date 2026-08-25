#!/usr/bin/env bash
# Single entry point: generate → build, with optional --test / --launch / --screenshot FILE.
set -euo pipefail

cd "$(dirname "$0")"
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

SIM_ID="73B6C851-3A20-4D4C-94F7-ED63D6740EB8"
DEST="platform=iOS Simulator,id=$SIM_ID"
BUNDLE_ID="com.davidxie.Aloud"
DERIVED=".derived"

RUN_TEST=0
RUN_LAUNCH=0
SCREENSHOT_FILE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --test) RUN_TEST=1 ;;
    --launch) RUN_LAUNCH=1 ;;
    --screenshot)
      SCREENSHOT_FILE="${2:?--screenshot requires a file path}"
      shift
      ;;
    *)
      echo "usage: $0 [--test] [--launch] [--screenshot FILE]" >&2
      exit 2
      ;;
  esac
  shift
done

./sync_bookshelf.sh
/opt/homebrew/bin/xcodegen generate

xcodebuild -project Aloud.xcodeproj -scheme Aloud \
  -destination "$DEST" -configuration Debug \
  -derivedDataPath "$DERIVED" \
  CODE_SIGNING_ALLOWED=NO build

if [[ "$RUN_TEST" -eq 1 ]]; then
  xcodebuild -project Aloud.xcodeproj -scheme Aloud \
    -destination "$DEST" \
    -derivedDataPath "$DERIVED" \
    CODE_SIGNING_ALLOWED=NO test
fi

boot_simulator() {
  if ! xcrun simctl list devices booted | grep -q "$SIM_ID"; then
    xcrun simctl boot "$SIM_ID"
  fi
  xcrun simctl bootstatus "$SIM_ID"
}

if [[ "$RUN_LAUNCH" -eq 1 ]]; then
  boot_simulator
  open -a Simulator
  APP="$DERIVED/Build/Products/Debug-iphonesimulator/Aloud.app"
  if [[ ! -d "$APP" ]]; then
    echo "error: $APP not found — build must precede --launch" >&2
    exit 1
  fi
  xcrun simctl install "$SIM_ID" "$APP"
  xcrun simctl launch "$SIM_ID" "$BUNDLE_ID"
fi

if [[ -n "$SCREENSHOT_FILE" ]]; then
  boot_simulator
  xcrun simctl io "$SIM_ID" screenshot "$SCREENSHOT_FILE"
  echo "Screenshot written to $SCREENSHOT_FILE"
fi
