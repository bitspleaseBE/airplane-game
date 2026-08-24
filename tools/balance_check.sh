#!/usr/bin/env bash
# Balance gates: play the full squadron with each strategy and report outcomes.
# Pass/fail criteria live in .cursor/skills/design-gates/SKILL.md.
# Usage: tools/balance_check.sh            # level 1
#        LEVEL=3 tools/balance_check.sh    # a specific level
#        SEED=11 LEVEL=10 tools/balance_check.sh
#
# --fixed-fps 60 is not optional either. Without it the engine advances on wall
# clock, so frame pacing under load decides how much game time passes between
# the harness's deploys — and identical configs measured 25 vs 34 birds on the
# same level and seed. With it, three consecutive runs are byte-identical.
# (Never pass it to perf_check.sh, which exists to measure real frame times.)
#
# NEVER run these scenarios with --headless. The dummy renderer changes how the
# siege plays out — measured side by side, the same level and seed resolved in
# ~150 s headless and ~25 s rendered, with opposite win/lose outcomes. Every
# gate threshold in the design-gates skill is calibrated against a real
# renderer, so a headless number is not a smaller version of the truth, it is a
# different game. On a machine with no display this wraps Godot in xvfb rather
# than falling back to headless.
set -euo pipefail
cd "$(dirname "$0")/.."

GODOT="${GODOT:-godot}"
LEVEL="${LEVEL:-1}"
SEED="${SEED:-7}"
STRATEGIES=(flank column decoy blitz spread waves)

# Headless CI runners have no display server; wrap in a virtual one.
RUNNER=()
if [ "$(uname)" = "Linux" ] && [ -z "${DISPLAY:-}" ] && command -v xvfb-run >/dev/null; then
  RUNNER=(xvfb-run -a)
fi

mkdir -p playtest
touch playtest/.gdignore

for strat in "${STRATEGIES[@]}"; do
  OUT="playtest/balance/$strat"
  mkdir -p "$OUT"
  rm -f "$OUT"/*.png "$OUT"/summary.json
  echo "--- strategy: $strat (level $LEVEL, seed $SEED) ---"
  ${RUNNER[@]+"${RUNNER[@]}"} "$GODOT" --path . --resolution 720x1280 --audio-driver Dummy \
    --fixed-fps 60 -- \
    --playtest --out="$OUT" --strategy="$strat" \
    --planes=all --duration=300 --shot-interval=120 --seed="$SEED" --level="$LEVEL"
done

echo
echo "=== Balance results (level $LEVEL) ==="
for strat in "${STRATEGIES[@]}"; do
  printf '%-8s %s\n' "$strat" "$(tr -d '\n' < "playtest/balance/$strat/summary.json")"
done
