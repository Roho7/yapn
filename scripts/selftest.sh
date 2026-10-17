#!/bin/sh
# Runs a recorded clip through the bundled app's real pipeline (synthetic Right Option hold,
# transcribe, formatting seam, paste into the frontmost app, clipboard restore) and prints the
# app log plus one SELFTEST JSON line. Exit 0 only if the paste was read, focus stayed put, and the
# clipboard came back byte for byte. Put the cursor in a text field within the countdown.
set -eu
cd "$(dirname "$0")/.."
WAV=$(cd "$(dirname "${1:-data/clips/007.wav}")" && pwd)/$(basename "${1:-data/clips/007.wav}")
DELAY=${SELFTEST_DELAY:-3}
LOGS=$(mktemp -d)

pkill -f 'Dictation.app/Contents/MacOS/Dictation' 2>/dev/null || true
echo "pasting into the frontmost app in ${DELAY}s"
sleep "$DELAY"
open -g -n -W build/Dictation.app --stdout "$LOGS/out" --stderr "$LOGS/err" --args --selftest "$WAV" || true
cat "$LOGS/err" "$LOGS/out"
grep -q '"passed":"true"' "$LOGS/out"
