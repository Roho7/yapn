#!/bin/sh
# Rebuilds and relaunches the notch preview whenever a file under Sources/Yapn changes.
# Usage: scripts/notch-dev.sh [--notch-live | --notch-demo]   (default --notch-live: driven by your mic)
set -u
cd "$(dirname "$0")/.."
MODE="${1:---notch-live}"
command -v swift >/dev/null && swift --version >/dev/null 2>&1 || export DEVELOPER_DIR=/Library/Developer/CommandLineTools
BIN=.build/debug/Yapn
pid=""

stamp() { find Sources/Yapn Sources/DictationCore -name '*.swift' -exec stat -f '%m %N' {} + | sort | md5 -q; }

relaunch() {
  [ -n "$pid" ] && kill "$pid" 2>/dev/null && wait "$pid" 2>/dev/null
  if swift build --product Yapn 2>&1 | grep -E "error|warning: unre" ; then
    echo "build failed; waiting for the next save"
    pid=""
    return
  fi
  "$BIN" "$MODE" &
  pid=$!
  echo "running $MODE (pid $pid). Save a file to reload, Ctrl-C to stop."
}

trap '[ -n "$pid" ] && kill "$pid" 2>/dev/null; exit 0' INT TERM
last=$(stamp)
relaunch
while sleep 0.5; do
  now=$(stamp)
  [ "$now" != "$last" ] && { last=$now; echo "change detected, rebuilding"; relaunch; }
done
