---
name: playtest-loop
description: Agentic write-code → playtest → improve loop for Bastion Bomber (Godot 4). Use after implementing or changing any gameplay feature, balance value, visual, scene, or bug fix in this project — run the automated playtest, inspect the screenshots and summary, and iterate until it looks and behaves right. Also use when the user asks to test the game, verify a feature, or take screenshots.
---

# Playtest Loop

After every feature implementation or gameplay change, verify it by actually playing the game — never declare a change done from code alone.

## The loop

```text
Loop:
- [ ] 1. Implement the change
- [ ] 2. Smoke-check for script errors (headless)
- [ ] 3. Run the automated playtest (windowed, ~25s)
- [ ] 4. Read summary.json + view every screenshot
- [ ] 5. Pass? Embed 1–2 screenshots in the response and stop.
       Fail? Fix and go back to step 2.
```

## Step 2: Smoke check

Catches parse/load errors fast without opening a window:

```bash
godot --headless --path . --quit-after 5 2>&1
```

Any `SCRIPT ERROR` or `ERROR` lines mean fix first, don't playtest yet.

## Step 3: Run the playtest

```bash
tools/playtest.sh
```

This launches the game in a small always-on-top window (kept on top so macOS keeps drawing frames for capture), simulates water taps to deploy bombers via the real input pipeline, screenshots every few seconds, and quits on win/lose/timeout. It prints a `PLAYTEST_SUMMARY {...}` JSON line and writes artifacts to `playtest/latest/`.

Options (forwarded to the harness):

```bash
tools/playtest.sh --planes=all --duration=60  # full run, force a win/lose ending
tools/playtest.sh --planes=0 --duration=6     # idle: HUD/visuals only, no spawns
tools/playtest.sh --shot-interval=1           # denser screenshots for animations
tools/playtest.sh --strategy=blitz --seed=7   # dump-all tactic, reproducible run
```

Strategies: `spread` (default, patient, evenly around the island), `blitz` (everything as fast as possible), `waves` (squads of 5 from alternating sides). `--level=N` is forwarded to `main.set_level()` once the game has levels.

Default run deploys 6 bombers over ~25s — good for most feature checks. For win/lose screens or end-of-game logic use the full run; for difficulty and balance questions use the `design-gates` skill and `tools/balance_check.sh` instead.

## Step 4: Evaluate

Read `playtest/latest/summary.json`:

- `result`: `won` / `lost` / `timeout` — does it match what the change should cause?
- `keep_hp`, `planes_remaining` — sanity-check balance math.
- `spawns_via_fallback` should be 0; if > 0, synthesized taps stopped registering — the input path is broken and that itself is a bug to investigate.

Then view **every** screenshot in `playtest/latest/` with the Read tool (they are numbered in order: `01-start.png`, `02-t03s.png`, …, `NN-end-<result>.png`). Check:

- Island, keep, and 4 turrets render; no missing/pink textures, no overlap glitches
- Planes appear on water and progress toward the keep across frames
- HUD: plane count decreases, keep HP bar reacts, version label bottom-left
- Explosions/effects visible where expected
- End frame shows the correct overlay text for the result
- Whatever the current change was supposed to alter actually changed

## Step 5: Report

In the final response, embed the most informative screenshot(s) inline with `![...](absolute path)` so the user sees the result without opening the game, and state the summary outcome plainly.

## How the harness works (for debugging it)

- `scripts/playtest.gd` is an autoload that is inert unless launched with user args `-- --playtest` (normal play is unaffected).
- **Concurrent runs interfere.** If the run ends without a `PLAYTEST_SUMMARY` line, or `playtest/latest/` contains screenshots with duplicate/odd numbering, another game instance is likely running (check `ps aux | grep -i godot`) — it can overwrite artifacts or terminate your run. Rerun with an isolated dir: `OUT=playtest/run-$$ tools/playtest.sh`, and read that dir instead.
- It mutes audio, taps via `Input.parse_input_event` (InputEventScreenTouch), falls back to `main._try_spawn()` if taps don't register, captures via `get_viewport().get_texture().get_image()`, and has a failsafe quit at duration + 15s.
- Screenshots need a window: do NOT combine `--headless` with `--playtest`.
- If you add new game states/signals, extend the harness so the loop keeps measuring them.
