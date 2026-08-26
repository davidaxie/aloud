#!/usr/bin/env bash
# xcodebuild wrapper: full log to /tmp/xcb-last.log, filtered progress to
# stdout, heartbeat every 60 s so long phases are never silent.
set -o pipefail

( while true; do
    sleep 60
    lines=$(wc -l < /tmp/xcb-last.log 2>/dev/null | tr -d ' ' || echo 0)
    echo "[xcb] still running $(date +%H:%M:%S) - ${lines} log lines"
  done ) &
hb=$!
trap 'kill $hb 2>/dev/null' EXIT

xcodebuild "$@" 2>&1 | tee /tmp/xcb-last.log \
  | grep -E --line-buffered "error|failed|passed|SUCCEEDED|FAILED|Testing"
status=${PIPESTATUS[0]}
kill $hb 2>/dev/null
exit $status
