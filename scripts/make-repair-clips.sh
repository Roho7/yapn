#!/bin/sh
# Synthesises a `spoken ||| expected` file into clips: NNN.wav (16 kHz mono, macOS `say`) and
# NNN.json (the Prompt that `bench run --clips` reads, `written` being the expected text).
# Usage: scripts/make-repair-clips.sh [data/repairs.txt [data/repair-clips]]
# Rerun after editing the text file; the output directory is rebuilt from scratch.
set -eu
cd "$(dirname "$0")/.."
SOURCE=${1:-data/repairs.txt}
OUT=${2:-data/repair-clips}
rm -rf "$OUT"
mkdir -p "$OUT"
python3 -I - "$SOURCE" "$OUT" <<'PY'
import json, subprocess, sys

source, out = sys.argv[1], sys.argv[2]
category = None
clip = 0
for number, line in enumerate(open(source, encoding="utf-8"), 1):
    line = line.strip()
    if not line:
        continue
    if line.startswith("#"):
        body = line.lstrip("#").strip()
        if body.startswith("category:"):
            category = body[len("category:"):].strip()
        continue
    if category is None or "|||" not in line:
        sys.exit(f"{source}:{number}: expected 'spoken ||| expected' under a '# category:' header")
    spoken, expected = (part.strip() for part in line.split("|||", 1))
    segments = expected.replace("\\n", "\n").split("`")
    if len(segments) % 2 == 0:
        sys.exit(f"{source}:{number}: unbalanced backticks")
    clip += 1
    stem = f"{out}/{clip:03d}"
    subprocess.run(["say", "-o", f"{stem}.wav", "--data-format=LEI16@16000", spoken], check=True)
    prompt = {"id": clip, "category": category, "written": "".join(segments), "tokens": segments[1::2]}
    with open(f"{stem}.json", "w", encoding="utf-8") as f:
        json.dump(prompt, f, indent=2, sort_keys=True)
        f.write("\n")
    print(f"{clip:03d} {spoken}")
PY
