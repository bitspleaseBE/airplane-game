---
name: perf-check
description: Automated performance gate for Bastion Bomber (Godot 4). Run after implementing or changing any feature that could affect frame rate or load hitches — shaders, rendering, effects, island generation/baking, scene structure, spawn density, UI overlays, or anything that touches the main loop. Also use when the user reports the game running slow (especially in the browser), asks for a performance benchmark, or when tuning the perf budgets themselves.
---

# Performance Check

The game ships as a no-threads web export, so it must stay cheap: the browser
renders the full-screen water shader on WebGL at device-pixel resolution, and
any main-thread GDScript work (island bakes) becomes a visible freeze.

## When to run

After implementing or changing a feature, run the gate before calling the work
done — same bar as the playtest loop. Skip only for pure copy/docs changes
with no runtime impact.

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

## What this gate is (and is not)

The gate runs **native Godot** at a phone-portrait resolution (720×1280). It is
a regression proxy for the expensive paths — not a mobile-browser benchmark.

| Signal | Means |
|--------|--------|
| Local pass on a real GPU | Unlikely to have obviously regressed idle/combat/bake/ocean cost on capable hardware |
| Local fail | Fix the change (or get an explicit budget tradeoff) before shipping |
| CI fail on llvmpipe | Usually **calibration**, not “the game is too heavy for phones” |

It does **not** measure:

- Real Safari / Chrome WebGL on device
- No-threads WASM slowdown
- Phone thermal throttling or device-pixel (Retina) fill-rate
- An iPhone 12 Pro (or any specific handset)

For true mobile-browser numbers, export web and profile on device (or browser
DevTools). Treat bake budgets as especially predictive for web freezes; treat
frame-time gates as native proxies that still catch shader/gameplay regressions
early.

## CI (llvmpipe) vs phones

`.github/workflows/perf-check.yml` runs on `ubuntu-latest` with xvfb + Mesa
**llvmpipe** (CPU software GL). That path is an order of magnitude slower than
a real GPU and often caps around ~7–8 fps (~130 ms frames), so the workflow
widens budgets with `PERF_SCALE`.

Implications:

- A CI fail with idle/combat p95 just over the scaled budget is usually a
  **runner calibration** miss — bump `PERF_SCALE` from the job’s
  `playtest/perf/report.json` artifact, not the script’s default budgets.
- On llvmpipe, `ocean_cost_ms` is often ~0 or negative (idle ≈ flat); do not
  treat CI ocean cost as a phone/WebGL forecast.
- Do **not** read CI llvmpipe timings as “too heavy for iPhone 12 Pro.” An A14
  class GPU is far closer to a local real-GPU pass than to software GL. The
  remaining phone risk is the web stack (WASM, WebGL, main-thread bakes), which
  this job does not run.

## When budgets fail

1. A FAIL after a code change = that change regressed performance. Fix the
   change, don't raise the budget.
2. After deliberately *optimizing*, tighten the budget to the new
   measurement + ~25% so the win is locked in.
3. Only raise a budget when the cost is a deliberate, user-approved tradeoff
   — say so in the commit message.
4. CI-only fails right after a runner-image change → recalibrate `PERF_SCALE`
   in the workflow (see above).

## One-off profiling (no gate)

For exploratory benchmarking use the harness directly — any playtest run
accepts `--perf` (vsync off, per-frame sampling, `perf` block in
summary.json) and `--ocean=flat|off` for shader attribution:

```bash
OUT=playtest/perf-x tools/playtest.sh --perf --planes=0 --duration=12
godot --path . --resolution 1440x2560 -- --playtest --perf --out=playtest/perf-x
```
