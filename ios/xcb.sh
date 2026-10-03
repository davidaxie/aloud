#!/usr/bin/env bash
# xcodebuild wrapper: full log to a per-invocation mktemp file (path printed
# up front; /tmp/xcb-last.log is a convenience symlink to the newest run, so
# concurrent invocations from different worktrees never clobber each other's
# logs), filtered progress to stdout, heartbeat every 60 s so long phases are
# never silent.
#
# Sources xcenv.sh so DEVELOPER_DIR matches build.sh exactly, and injects
# build.sh's canonical -destination / -derivedDataPath / CODE_SIGNING_ALLOWED
# defaults into any project build that doesn't specify them — a hand-typed
# invocation can't silently drift onto the wrong toolchain or device. The Mac
# schemes (AloudMac*) get the Mac defaults instead: this Mac, derived data
# outside OneDrive, and ad hoc signing, never CODE_SIGNING_ALLOWED=NO.
set -o pipefail
source "$(dirname "$0")/xcenv.sh"

log=$(mktemp /tmp/xcb.XXXXXXXX)
ln -sfn "$log" /tmp/xcb-last.log   # points at the newest run only
echo "[xcb] full log: $log"

args=("$@")
# The scheme after -scheme (or the target after -target) and the derived-data
# path after -derivedDataPath, if given. AloudMac and AloudMacUI build the Mac
# app, which is signed ad hoc so its entitlements apply: an unsigned Mac build
# runs unsandboxed and writes into the real ~/Library and ~/Documents. Its
# derived data stays out of OneDrive, whose extended attributes codesign
# rejects. -alltargets would build the Mac targets with the iOS defaults, so
# it is refused: name a scheme.
scheme=""
derived=""
for ((i = 0; i < ${#args[@]}; i++)); do
  case ${args[i]} in
    -scheme|-target) scheme=${args[i+1]:-} ;;
    -derivedDataPath) derived=${args[i+1]:-} ;;
    -alltargets)
      echo "[xcb] refusing: -alltargets builds the Mac app unsigned; name a scheme" >&2
      exit 2 ;;
  esac
done
if [[ $scheme == AloudMac* ]]; then
  if [[ " $* " == *"CODE_SIGNING_ALLOWED=NO"* ]]; then
    echo "[xcb] refusing: $scheme is never built unsigned (unsigned means unsandboxed)" >&2
    exit 2
  fi
  if [[ " $* " == *" test"* && " $* " == *" -configuration Release "* ]]; then
    echo "[xcb] refusing: Mac tests run Debug only, never the shipping identity" >&2
    exit 2
  fi
  if [[ $derived == *CloudStorage* || $derived == *OneDrive* ]]; then
    echo "[xcb] refusing: Mac derived data under OneDrive (codesign rejects its xattrs)" >&2
    exit 2
  fi
  # A -target build takes the target's own SDK; -destination is for schemes.
  [[ " $* " == *" -destination "* || " $* " == *" -target "* ]] || args+=(-destination "$XCB_MAC_DEST")
  [[ -n $derived ]]                        || args+=(-derivedDataPath "$XCB_MAC_DERIVED")
  [[ " $* " == *"CODE_SIGN_IDENTITY"* ]]   || args+=(CODE_SIGN_IDENTITY=-)
elif [[ " $* " == *" -project "* || " $* " == *" -workspace "* || " $* " == *" -scheme "* ]]; then
  [[ " $* " == *" -destination "* ]]       || args+=(-destination "$XCB_DEST")
  [[ " $* " == *" -derivedDataPath "* ]]   || args+=(-derivedDataPath "$XCB_DERIVED")
  [[ " $* " == *"CODE_SIGNING_ALLOWED"* ]] || args+=(CODE_SIGNING_ALLOWED=NO)
fi

( while true; do
    sleep 60
    lines=$(wc -l < "$log" 2>/dev/null | tr -d ' ' || echo 0)
    echo "[xcb] still running $(date +%H:%M:%S) - ${lines} log lines"
  done ) &
hb=$!
trap 'kill $hb 2>/dev/null' EXIT

xcodebuild "${args[@]}" 2>&1 | tee "$log" \
  | grep -E --line-buffered "error|failed|passed|SUCCEEDED|FAILED|Testing"
status=${PIPESTATUS[0]}
kill $hb 2>/dev/null
if [[ $status -ne 0 ]]; then
  echo "[xcb] xcodebuild exited $status — full log: $log"
fi
exit $status
