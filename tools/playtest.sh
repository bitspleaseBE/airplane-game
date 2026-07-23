#!/usr/bin/env bash
# Automated playtest: launches the game windowed, simulates taps, saves
# screenshots + summary.json to playtest/latest/. Extra args are forwarded
# to the harness, e.g.: tools/playtest.sh --planes=15 --duration=60
# Override the output dir (e.g. to avoid clashing with a concurrent run):
#   OUT=playtest/run-$$ tools/playtest.sh
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="${OUT:-playtest/latest}"
mkdir -p "$OUT"
touch playtest/.gdignore  # keep Godot from importing the output PNGs
rm -f "$OUT"/*.png "$OUT"/summary.json

godot --path . -- --playtest --out="$OUT" "$@"

echo
echo "Playtest artifacts in $OUT:"
ls -1 "$OUT"
