---
name: design-gates
description: Playability boundaries and balance gates for Bastion Bomber. Use when adding or tuning levels, changing balance constants in game_config.gd, adjusting difficulty, evaluating whether the game is too easy/hard/long, or writing any player-facing text. Defines which design rules are automatically testable via tools/balance_check.sh and which need agent review, plus the tone-of-voice standard for all game copy.
---

# Design Gates

Four boundaries keep the game playable. Check them whenever levels, balance
values, or player-facing text change. Gates 1 and 3 are machine-tested; gates
2 and 4 are review checklists.

## Gate 1 — Placement must pay (auto-tested)

Deploys are rate-limited, so tapping faster is not a strategy — **where** each
bird enters is. The gate is therefore not "does blitz lose" but "does reading
the board beat not reading it".

`flank` deploys into the quiet corridors (it scores every approach against the
living guns' sectors and current aim); `blitz`, `spread` and `waves` all place
birds without reading anything. Compare `planes_deployed` on wins:

| Level | flank vs. random placement | both |
|-------|----------------------------|------|
| 1–2   | may be even — the opening bastions are meant to forgive | must win |
| 5+    | flank should win using **meaningfully fewer planes** | flank must win |
| 16–20 | flank's edge should be largest; random play should be marginal | — |

If `flank` and the random strategies converge, placement has stopped being a
decision — the usual causes are guns that can traverse to cover every approach
(check `Turret.ARC_SPAN`), an AA envelope that no longer reaches the water
(check `turret_range_for_level` against `island_radius_for_level`), or a deploy
rate high enough that saturation beats geometry.

Run the gate:

```bash
tools/balance_check.sh              # level 1
LEVEL=5 tools/balance_check.sh      # any level
```

**Per-seed variance is high** — a single run of each strategy proves nothing.
Use at least 3 seeds per cell before concluding anything. (Island layout is
seeded from the level number, so `--seed` only varies tap placement.)

## Gate 2 — One new thing per level (review)

Each level introduces **exactly one** new element — a mechanic, enemy,
plane type, or rule. Not zero (boring), not two (overwhelming). When adding
a level, state in the commit/PR what the one new thing is. If a level idea
needs two new things, split it into two levels.

## Gate 3 — Duration (auto-tested)

A single level's winning run should land around **30–90 seconds**. The full
20-island campaign is longer than the old 2–5 minute PoC target — judge total
time by summing winning-level runs, and cut or shorten levels if the campaign
drags past ~15–20 minutes of active play.

- Check `elapsed_s` in each `summary.json` from `tools/balance_check.sh`.
- `result: "timeout"` at the 300 s cap means the level cannot resolve — automatic fail.
- Prefer short, punchy sieges over padding.

## Gate 4 — Tone of voice (review)

All player-facing text is **cool / badass / military-bro / a bit over the
top**. Confident swagger, radio-chatter punch, never grim, never corporate.

**Do:**
- "BASTION DOWN. Nothing left but smoke and glory."
- "Squadron's spent and that keep's still smug. Unacceptable, pilot."
- "Tap the water, commander — scramble the bombers."

**Don't:**
- "You win!" / "Game over" (flat)
- "Please tap the water to begin" (polite/corporate)
- "All your soldiers have died" (grim)

Player-facing strings live in `scripts/hud.gd` (result overlays, buttons),
`scenes/hud.tscn` (hint, title), and any future level intro/dialog scenes.
Every new or changed string gets read aloud against the Do/Don't list.

## What can be simulated vs. what needs eyes

Automatable (via the playtest harness — see the `playtest-loop` skill):
- Win/lose outcome per strategy, per level, with a fixed seed
- Time-to-resolution, planes spent, keep/turret HP remaining
- Input pipeline integrity (taps registering)
- Visual regressions via screenshots (agent reads the frames)

Needs agent judgment on screenshots: readability, visual clutter, effect
timing. Needs a human: fun, game feel, audio mix — flag these for the user
instead of guessing.

## Iterative balance loop

```text
- [ ] 1. Change balance constants / level design
- [ ] 2. tools/balance_check.sh (per affected level)
- [ ] 3. Compare results against Gate 1 + Gate 3 tables
- [ ] 4. Off target? Adjust game_config.gd values and repeat
- [ ] 5. On target? Run the playtest-loop skill for visual verification
```

When levels land in the game, expose `set_level(n)` on the main scene — the
harness already forwards `--level=N` to it.
