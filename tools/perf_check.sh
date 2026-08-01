#!/usr/bin/env bash
# Automated performance gate: runs the --perf playtest scenarios and checks
# frame-time / bake budgets. Budget rationale and interpretation live in
# .cursor/skills/perf-check/SKILL.md.
#
# Usage: tools/perf_check.sh
#        PERF_SCALE=10 tools/perf_check.sh   # slower machine (e.g. CI llvmpipe)
#        GODOT=~/godot/godot tools/perf_check.sh
#
# Individual budget overrides (milliseconds, applied before PERF_SCALE):
#   IDLE_P95_BUDGET_MS OCEAN_COST_BUDGET_MS COMBAT_P95_BUDGET_MS
#   ISLAND_BUILD_BUDGET_MS
#
# Exit code: 0 = all gates pass, 1 = at least one gate over budget.
set -euo pipefail
cd "$(dirname "$0")/.."

GODOT="${GODOT:-godot}"
SEED="${SEED:-7}"
IDLE_DURATION="${IDLE_DURATION:-10}"
COMBAT_DURATION="${COMBAT_DURATION:-20}"

# Headless CI runners have no display server; wrap in a virtual one.
RUNNER=()
if [ "$(uname)" = "Linux" ] && [ -z "${DISPLAY:-}" ] && command -v xvfb-run >/dev/null; then
  RUNNER=(xvfb-run -a)
fi

mkdir -p playtest
touch playtest/.gdignore

run_scenario() {
  local name="$1"
  shift
  local out="playtest/perf/$name"
  mkdir -p "$out"
  rm -f "$out"/*.png "$out"/summary.json
  echo "--- perf scenario: $name ---"
  ${RUNNER[@]+"${RUNNER[@]}"} "$GODOT" --path . --resolution 720x1280 --audio-driver Dummy -- \
    --playtest --perf --seed="$SEED" --out="$out" "$@"
  if [ ! -f "$out/summary.json" ]; then
    echo "PERF_CHECK error: $name produced no summary.json" >&2
    exit 1
  fi
}

run_scenario idle   --planes=0   --duration="$IDLE_DURATION"
run_scenario flat   --planes=0   --duration="$IDLE_DURATION" --ocean=flat
run_scenario combat --planes=all --duration="$COMBAT_DURATION" --strategy=blitz --level=13

echo
python3 - <<'PY'
import json, os, sys

def perf(name):
    with open(f"playtest/perf/{name}/summary.json") as f:
        return json.load(f)["perf"]

idle, flat, combat = perf("idle"), perf("flat"), perf("combat")
scale = float(os.environ.get("PERF_SCALE", "1"))

def budget(env, default):
    return float(os.environ.get(env, default)) * scale

# The water shader is the only difference between idle and flat, so the avg
# frame-time delta is the shader's island-loop cost at 720x1280.
ocean_cost = idle["frame_ms"]["avg"] - flat["frame_ms"]["avg"]

# Defaults = Jul 2026 M2 Ultra measurements + ~25% headroom (regression guard).
gates = [
    ("idle_p95_ms",      idle["frame_ms"]["p95"],              budget("IDLE_P95_BUDGET_MS", 10.0)),
    ("ocean_cost_ms",    ocean_cost,                           budget("OCEAN_COST_BUDGET_MS", 6.5)),
    ("combat_p95_ms",    combat["frame_ms"]["p95"],            budget("COMBAT_P95_BUDGET_MS", 11.0)),
    ("island_build_ms",  idle["island_build"]["build_ms"],     budget("ISLAND_BUILD_BUDGET_MS", 20.0)),
]

print(f"=== Perf gates (720x1280, seed fixed, scale x{scale:g}) ===")
failed = []
for name, value, limit in gates:
    ok = value <= limit
    if not ok:
        failed.append(name)
    print(f"{'PASS' if ok else 'FAIL':4}  {name:16} {value:8.2f}  (budget {limit:.2f})")

report = {
    "result": "fail" if failed else "pass",
    "failed_gates": failed,
    "scale": scale,
    "gates": {n: {"value": round(v, 2), "budget": round(l, 2)} for n, v, l in gates},
    "scenarios": {"idle": idle, "flat": flat, "combat": combat},
}
with open("playtest/perf/report.json", "w") as f:
    json.dump(report, f, indent=2)
print("PERF_CHECK_RESULT " + json.dumps({k: report[k] for k in ("result", "failed_gates", "gates")}))
sys.exit(1 if failed else 0)
PY
