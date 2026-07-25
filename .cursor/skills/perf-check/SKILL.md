---
name: perf-check
description: Automated performance gate for Bastion Bomber (Godot 4). Use after changing shaders, rendering, effects, island generation/baking, scene structure, or anything that could affect frame rate — run tools/perf_check.sh and compare against the budgets. Also use when the user reports the game running slow (especially in the browser), asks for a performance benchmark, or when tuning the perf budgets themselves.
---

# Performance Check

The game ships as a no-threads web export, so it must stay cheap: the browser
renders the full-screen water shader on WebGL at device-pixel resolution, and
any main-thread GDScript work (island bakes) becomes a visible freeze.

## Run the gate

```bash
tools/perf_check.sh
```

Exit 0 = all budgets pass. It runs three fixed-seed scenarios at 720×1280
(vsync off, audio dummy) and prints one PASS/FAIL line per gate:

| Scenario | What it measures |
|----------|------------------|
| `idle`   | Steady-state rendering, level 1, no planes |
| `flat`   | Same but the water shader's per-island loop is skipped (`--ocean=flat`) |
| `combat` | Level-13 blitz: flak, missiles, full bullet load |

Artifacts land in `playtest/perf/<scenario>/` plus a machine-readable
`playtest/perf/report.json`.

## Gates and budgets

Budgets are milliseconds on the reference machine (M2 Ultra, Jul 2026
measurements + ~25% headroom). Override per-gate via env vars, or scale all
of them with `PERF_SCALE=N` on slower machines.

| Gate | Meaning | Default budget |
|------|---------|----------------|
| `idle_p95_ms` | p95 frame time, idle @720×1280 | 10.0 |
| `ocean_cost_ms` | avg frame-time delta idle−flat = water-shader island-loop cost | 6.5 |
| `combat_p95_ms` | p95 frame time under full combat load | 11.0 |
| `bake_hires_ms` | one hi-res island texture bake (GDScript, main-thread on web) | 1200 |
| `bake_coarse_ms` | one coarse island bake | 400 |

Interpretation:

- `ocean_cost_ms` is the browser killer — it scales linearly with pixels and
  runs every frame. If it grew, look at `shaders/water.gdshader` (per-island
  loop, fbm octaves, island_count fed from `main._apply_open_ocean`).
- `bake_*_ms` are freeze-length proxies for the web build (multiply by ~2–5×
  for WASM). If they grew, look at `Island.render_island_image` /
  `_shade_island_static` in `scripts/island.gd`, or the bake image scales.
- `combat_p95_ms` ≈ `idle_p95_ms` + ~1 ms is normal; a bigger gap means
  gameplay/effects code regressed (check `frame_ms.max` in the combat
  summary for hitches vs. sustained load).

## When budgets fail

1. A FAIL after a code change = that change regressed performance. Fix the
   change, don't raise the budget.
2. After deliberately *optimizing*, tighten the budget to the new
   measurement + ~25% so the win is locked in.
3. Only raise a budget when the cost is a deliberate, user-approved tradeoff
   — say so in the commit message.

## One-off profiling (no gate)

For exploratory benchmarking use the harness directly — any playtest run
accepts `--perf` (vsync off, per-frame sampling, `perf` block in
summary.json) and `--ocean=flat|off` for shader attribution:

```bash
OUT=playtest/perf-x tools/playtest.sh --perf --planes=0 --duration=12
godot --path . --resolution 1440x2560 -- --playtest --perf --out=playtest/perf-x
```

## CI

`.github/workflows/perf-check.yml` runs the gate on a software renderer
(xvfb + llvmpipe), which is far slower than real GPUs — it uses `PERF_SCALE`
to widen the budgets. If the job fails right after runner-image changes,
recalibrate: read `playtest/perf/report.json` from the artifact and adjust
`PERF_SCALE` in the workflow, not the script defaults.
