#!/usr/bin/env bash
# Balance gates: play the full squadron with each strategy and report outcomes.
# Pass/fail criteria live in .cursor/skills/design-gates/SKILL.md.
# Usage: tools/balance_check.sh            # level 1
#        LEVEL=3 tools/balance_check.sh    # a specific level
set -euo pipefail
cd "$(dirname "$0")/.."

LEVEL="${LEVEL:-1}"
SEED="${SEED:-7}"
STRATEGIES=(blitz spread waves)

mkdir -p playtest
touch playtest/.gdignore

for strat in "${STRATEGIES[@]}"; do
  OUT="playtest/balance/$strat"
  mkdir -p "$OUT"
  rm -f "$OUT"/*.png "$OUT"/summary.json
  echo "--- strategy: $strat (level $LEVEL, seed $SEED) ---"
  godot --path . -- --playtest --out="$OUT" --strategy="$strat" \
    --planes=all --duration=300 --shot-interval=15 --seed="$SEED" --level="$LEVEL"
done

echo
echo "=== Balance results (level $LEVEL) ==="
for strat in "${STRATEGIES[@]}"; do
  printf '%-8s %s\n' "$strat" "$(tr -d '\n' < "playtest/balance/$strat/summary.json")"
done
