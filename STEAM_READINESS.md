# Steam readiness — Bastion Bomber

Living checklist for the "ship this on Steam" push. Each loop iteration picks
the highest item that is still open, lands it, and ticks it here. Keep the
`[ ]` / `[x]` markers intact.

## Where this actually stands

Bastion Bomber is a well-built **portrait touch game**: 20 procedural bastions,
four airframe wings, a readable threat overlay, an automated playtest harness
and a perf gate in CI. As a mobile/web product it is close to done.

As a **Steam product it is not started**, and the gap is structural, not
polish. Honest framing: "triple A" describes 100+ person, eight-figure
productions — that is not a target a project this size can reach, and chasing
the label produces worse decisions than chasing the actual bar. The real bar
is *a premium PC game a Steam customer does not ask for a refund on*. That is
reachable, and it is what this checklist tracks.

The three things that decide it:

1. **It has to be a PC game.** Right now there is no desktop build at all.
2. **It has to hold a PC session.** 20 levels / 2–5 minutes total is a demo.
3. **It has to look and sound finished on a 27" monitor**, not on a phone.

## P0 — cannot submit without these

- [x] Desktop export presets (Windows / Linux / macOS)
- [x] Window handling: resizable, fullscreen toggle, sane min size, vsync
- [x] Pause menu (Esc / gamepad Start) — resume, restart, options, quit
- [x] Options menu: master / SFX / music volume, fullscreen, vsync
- [x] Persistent save: campaign progress + per-level stars, survives restart
- [x] Keyboard + mouse controls that feel native (not emulated touch)
- [x] Full gamepad support (menus + gameplay) — Steam Deck needs it
- [ ] Level select / campaign map so progress is visible and resumable
- [ ] Steamworks: app id, achievements, cloud saves, rich presence
- [ ] Store assets: capsule art, trailer, screenshots, description
- [ ] Legal: EULA, credits screen, third-party licence attributions in-game

## Branches

- `claude/airplane-game-triple-a-7vkgmm` — PR #11, under review. Frozen.
- `claude/airplane-game-steam-round2` — active. Branched off the PR so the work
  stacks; rebase after #11 merges.

## P1 — decides whether it reads as premium

- [x] A second verb. Placement was the only decision; decoy drones let the
      player *cause* the gap instead of only finding it

- [ ] Music. A silent Steam game reads as unfinished (blueprint deferred it)
- [ ] Content volume: 20 bastions is ~30 min. Needs 3–5× that, or a mode that
      makes the existing content replayable (endless / daily / challenge)
- [ ] Meta progression so a session has a reason to continue
- [ ] Landscape / widescreen presentation — portrait on a 21:9 monitor is a
      letterboxed strip. Either letterbox deliberately with framing art, or
      make the play field aspect-aware
- [ ] Title / main menu screen. The game currently boots straight into level 1
- [ ] Accessibility: colourblind-safe threat palette (the entire read is
      warm-vs-cool right now), text scale, reduced motion, screen-shake toggle
- [ ] Localisation pass (at minimum EFIGS)
- [ ] Difficulty options — casual / normal / veteran squadron sizes

## P2 — the polish that separates good from shipped

- [ ] Controller glyph prompts, remappable bindings
- [ ] Stats / after-action screen with campaign totals
- [ ] Achievements surfaced in-game (not just Steam)
- [ ] Photo mode / replay is a cheap "premium" signal for a game this pretty
- [ ] Crash / error telemetry opt-in

## Iteration log

### Iteration 1 — PC platform foundation

Landed:
- `scripts/settings.gd` autoload: audio / video / accessibility settings plus
  campaign progress and per-bastion best stars, all in `user://settings.cfg`.
- `default_bus_layout.tres`: Master / SFX / Music / Ambience, so the options
  menu offers a real mix instead of one global mute.
- `scripts/pause_menu.gd`: Esc / Start pause with resume, restart, options,
  two-step quit. Options covers four volume sliders, mute, fullscreen, v-sync,
  screen-shake strength, reduced motion, and four colourblind palettes.
- Input map: Esc/P/Start pause, Space/Enter/A scramble, WASD + arrows + left
  stick aim, F11 fullscreen, M mute, R retry.
- `scripts/deploy_reticle.gd`: keyboard/gamepad aiming crosshair that also
  shows whether a scramble would be accepted and how much scramble gap is left.
- Desktop export presets (Windows / Linux / macOS), resizable 576×1024 window.

Verified: Linux and Windows release exports build; the exported Linux binary
was launched under xvfb and played a real siege. Pause and options pages
captured via two new playtest flags (`--pause-menu`, `--reticle`). Perf gate
passes at CI scale with no regression against `main`
(idle p95 33.3 → 34.6 ms, combat p95 44.4 → 44.4 ms).

### Findings worth acting on

**Fixed: `--seed` did nothing.** `main.gd::_ready` called `randomize()` after
the playtest autoload had seeded, so every "seeded" balance result was
run-to-run noise. Three identical flank runs at bastion 5 went lost / won /
won before the fix, and are byte-identical after it. **Gate 1 was not actually
being measured.** Re-run with the fix, bastion 5 is correct: `flank` wins 3/3,
`column` loses.

**Open: Gate 3 (duration) fails and has for a while.** A winning flank run at
bastion 5 takes ~152 s against a 30–90 s target — and it is not my change,
`main` measures 143 s. Twenty bastions at that pace is ~50 minutes, not the
15–20 the gate asks for. For a Steam release that is arguably the *right*
direction and the gate is the thing that is wrong, but it is a design call, so
it is flagged here rather than quietly retuned.

### Iteration 2 — the second verb, and the measurement that was lying

Landed the **decoy drone / FEINT** layer. The fortress already commits each gun
to one bird for 1.25 s and slews whole sectors toward pressure; `turret.gd`'s
own comments said a decoy "genuinely buys the next wave a window", and nothing
in the game could throw one. Now: a charge arms the next tap, the drone carries
no payload, soaks three hits, loiters inside the AA envelope, and reads closer
to a gunner than it really is — so it wins target selection against a real bird
at similar range. Charges recharge on a timer, but a drone burns a scramble
gap, so a feint is paid for with a bomber's slot in time.

Measured at bastion 5, same seed, rendered: `column` alone spends 46 birds,
`column` + feints spends 27 for the same win, with 6 bullets soaked by drones.
That is the ability doing what it is for.

**Fixed the harness lie underneath it.** Balance was being measured headless.
The dummy renderer does not play the same game: the same level and seed resolve
in ~150 s headless and ~25 s rendered, with *opposite* outcomes. Combined with
the `--seed` bug from iteration 1, no design gate has been measured correctly
in some time. `tools/balance_check.sh` now wraps xvfb, uses a real resolution,
and includes `column` and `decoy` in its strategy set.

### Corrected: the duration finding from iteration 1 was wrong

I reported bastion 5 taking ~152 s against a 30-90 s target. That was a
headless artifact. Rendered, wins land in **12-33 s** — the levels are too
*short*, not too long, and the campaign is under 15 minutes, not 50.

### Iteration 3 — the ordnance economy, and a correction

Retuned keep HP, squadrons, emplacement HP, sector slew, AA reach and the carpet
release point over six measured rounds. Good play now spends **53-92%** of the
wing (was 21-50%) and wins land in **18-47 s** (was 12-19 s). Every bastion
stays winnable: `flank` won 12/12 across bastions 5/10/15/20 x 3 seeds.

**Correction to what this file said an hour ago.** I reported gate 1 as fixed at
bastions 5, 15, 16 and 20 on the strength of one or two seeds each. With three
seeds that is wrong: `column` still wins **1 run in 3 at every level tested**,
strongholds included. Single-seed cells on this game are not evidence — the
squadron size perturbs the shared RNG stream, so `--seed` does not isolate
placement, and any cell decided by a few birds is noise. Only wide-margin cells
(column spending 100% and leaving the keep above 40%) are trustworthy.

What the retune did buy, and it is not small: taking the finale on a locked
bearing went from 13 birds of 76 to 38 of 40. The rule still fails, but the
margin is gone.

### Iteration 4 — the structural fix, and where it lands

Scaled the fort with its island (`fort_scale_for_radius`, capped 1.95), so the
corner mounts sit on a real ring instead of a huddle at the centre. This is the
change the previous iteration identified and it did most of what was hoped:

- Bastion 15 now behaves: a locked bearing loses 2 of 2, good play spends
  48-68%, runs 23-32s.
- Bastion 10 improved: good play 75-84%, locked bearing loses 1 of 2.
- Every bastion stays winnable, good play spends 48-100% (mostly 52-84%), and
  runs land in 23-90s — against 21-50% and 12-19s before any of this work.
- Perf improved rather than regressed: idle p95 33.3 → 29.2 ms, combat
  43.2 → 36.1 ms.

It also surfaced a shipped bug of its own: the stronghold grass lerp pulls the
grass radius toward a fixed 175, which on a scaled fort lands *inside* the
fortress and inverted the outer ring's placement band — bastions 10/15/20 built
with **zero outer guns**. Caught by screenshotting the finale rather than
trusting a clean compile.

Two experiments were tried and reverted, both recorded in the code so nobody
repeats them: trimming bomber speed to 1.22 (worse and noisier), and removing
the stronghold reach bonus on the theory that the scaled ring made it redundant
(clearly worse — it flipped bastion 15 from pass to fail).

### Iteration 5 — interceptors: the first clean gate pass in the game

**Outcome: the mechanic works, and is scoped to bastions 17-19.**

At bastion 17 and 18, adaptive play wins 3 of 3 and a locked bearing loses 3 of
3. That is the campaign's load-bearing rule holding on its own merits, and no
amount of tuning static defences ever produced it anywhere: against guns that
cannot leave their corners, the two strategies cost within ~10% of each other,
and no threshold separates things that cost the same. One defender that can move
to where the player keeps attacking separated them by 3x immediately.

The decoy layer composes with it rather than being bypassed — feints pull a
fighter off a lane on the same lure rule that pulls a gun mount, and in the
first measured pass took one seed from 473 HP remaining down to 13.

**Bastion 20 is excluded, as design.** The finale already runs a maximal fort;
interceptors on top measured unwinnable by adaptive play in 6 of 6 runs across
two strength settings. An unwinnable finale is strictly worse than one a fixed
bearing can take. The finale keeps its fortress, and its known open gate — but
it is now healthy: good play wins at 67-89% on 60-80s runs, against 21% and 16s
when this work started.

### The measurement, third time

Balance runs were still not reproducible. The cause was not the RNG (that fix
was real but insufficient — I claimed it was the answer before testing it, and
repeat runs then differed 25 vs 34 birds). It was **wall-clock pacing**: Godot
advances on real time, so frame pacing under load decided how much game time
passed between the harness's deploys. `--fixed-fps 60` makes three consecutive
runs byte-identical and restores monotonicity — a weaker defender now correctly
measures as a cheaper level.

That is three defects in how this project measures itself: `randomize()`
clobbering `--seed`, headless not playing the same game, and wall-clock pacing.
**Every per-cell number in this file predating that fix carries real noise.**
Aggregate counts across seeds hold; single-cell percentages and any A/B decided
by a few birds do not. A full re-verification under `--fixed-fps` is running and
this file gets the defensible numbers when it lands.

### The defensible gate matrix, and two corrections

Re-run under `--fixed-fps`, 2 seeds per cell. Win/loss and bird counts below are
game state and trustworthy; the durations in that sweep were not, and are
excluded — see the timing note after the table.

| Bastion | adaptive (flank) | fixed bearing (column) | gate |
|---|---|---|---|
| 1  | won 2/2, 47%     | won 2/2      | forgiving by design |
| 5  | won 2/2, 63-66%  | **lost 2/2** | pass |
| 10 | won 2/2, 56-58%  | lost 1/2     | marginal |
| 15 | won 2/2, 51-81%  | **won 2/2**  | **fail** |
| 17 | won 2/2, 61-83%  | **lost 2/2** | pass |
| 18 | won 2/2, 33-40%  | **lost 2/2** | pass |
| 20 | won 2/2, 47-87%  | **lost 2/2** | pass |

**Correction 1: bastion 20 passes.** This file, the README and PR #11 all said a
locked bearing still takes the finale and that no lever could stop it. Measured
properly, a locked bearing loses both seeds *without scratching the keep*
(493/493 remaining). The fort scaling and the ordnance retune did close it; the
wall-clock harness was reporting the opposite outcome.

**Correction 2: bastion 15 is the real failure**, where a clean pass was
previously claimed. A locked bearing wins both seeds on 43-69% of the wing.
That is now the open gate, and 10 is marginal at 1 of 2.

Adaptive play wins 14 of 14 across every cell, so winnability is not in question
anywhere.

**Timing note.** `elapsed_s` was wall-clock, which under `--fixed-fps` diverges
from simulated time by about 2x on a software renderer — a bastion measured at
160s was really ~80s of play. The harness now accumulates delta and reports
game time as `elapsed_s`, keeping wall clock as `wall_s` for spotting hung runs.
Duration figures anywhere in this repo predating that change are inflated.

### Iteration 6 — replayability (next)

The campaign is now ~15-20 minutes of active play and then it is over. Stars are
earned and do nothing. That is the biggest remaining *gameplay* gap for a Steam
product, and it does not need new art.

**Operations: modifiers that change what a bastion demands.** Replay any cleared
bastion under a modifier, each of which invalidates a different habit:

- *Blackout* — no threat overlay. The read has to come off barrel facing and
  emplacement art, which is the skill the overlay currently does for you.
- *Scramble* — half the wing. Every deploy is a real cost.
- *Ace flight* — all four mounts live, faster cycle, from bastion 1.
- *Silent running* — no decoy charges, so lanes must be found rather than made.

Stars become a currency that gates the next tier, and 20 bastions become 60-80
distinct tactical problems without a single new asset. Design constraint: each
modifier must change *what the player does*, not just how much HP something has
— an operation that is only a stat multiplier is a difficulty slider wearing a
hat.

The finale gate is not a tuning problem, so iteration 5 stops tuning. Every
defender in the game is bolted down: a mount slews its sector but never leaves
its corner. Against static guns, flying one bearing repeatedly and flying a
different one each time cost within ~10% of each other at bastion 20, which is
why no squadron size or HP curve could separate them. Discrimination has to be
*positional*, and only something that can move to where the player keeps
attacking provides it.

Interceptors: the stronghold launches its own fighters, they fly to whichever
water the raid is pressing and hold there. Lean on one lane and they stack over
it; switch lanes and they have to transit the island first, and that transit is
the window the player is buying. Deliberately slower than every attacking wing —
a fighter that runs a bomber down from behind would delete the counterplay and
just be more damage. Shootable by strafing runs and blasts, and lurable by
decoys on the same terms as every other defender, so the feint layer composes
with it.

Introduced at bastion 17: 10 and 15 already measure at or near their limit, and
16 is the carpet wing's own new thing.

**Previously open, now being addressed by the above:** A locked bearing still wins bastion 20, though it
now pays 70-96% of the wing to do it against 13 birds of 76 before. Nine
measured rounds of squadron size, keep HP, emplacement HP, ring density, slew
speed and span, AA reach, carpet release and the ring geometry have not
separated it: at bastion 20 adaptive and fixed-bearing play cost within ~10% of
each other, so no threshold can tell them apart. The discrimination has to come
from a mechanic rather than a number — the decoy layer is the model to follow.

### Superseded: gate 1, and the structural cause

`island.gd::_place_turrets` seats all four corner guns at a fixed
`FORT_CLEAR_RADIUS * 0.95` (~105 px) from the island centre whatever the
island's size, because they sit on the fort sprite's corner towers. On the
240-radius opener that is a real ring; on the 460-radius finale it is a huddle
in the middle, ~400 px from the shore it defends. "Four live guns close the ring,
three leave a gap" — the stated spine of the tactics — degenerates as islands
grow, which is why the milestone strongholds measure as the *easiest* levels in
the campaign, and very likely why a third of locked bearings find soft water.

Two ways to fix it, and the choice is a design call because it is visible:

1. **Scale the fort with the island** — mounts stay on the sprite's corners, the
   whole fortress grows with its isle. Keeps the art relationship, changes the
   silhouette of every late bastion.
2. **Decouple the mounts** — guns move out to a real defensive ring at a
   fraction of the island radius, no longer sitting on the fort. Truer to the
   geometry the design describes, but the guns stop reading as part of the fort.

Recommend (1): it preserves what the art is saying and it makes the late
bastions look like the strongholds they are meant to be.

### Superseded: the campaign is far too loose

Rendered matrix, full squadron, bastions 5 and 10:

| Bastion | strategy | seed 7 | seed 11 |
|---|---|---|---|
| 5 | column | won, 46 birds | won, 31 birds |
| 5 | decoy | won, 27 birds | won, 26 birds |
| 5 | flank | won, 24 birds | won, 25 birds |
| 10 | column | lost | **won, 32 birds** |
| 10 | decoy | lost | won, 24 birds |
| 10 | flank | won, **16 of 54** | won, **12 of 54** |

Two failures, both pre-dating this work:

1. **Gate 1 is broken.** `column` must fail from bastion 3 on, and must *never*
   win a milestone stronghold. It wins bastion 5 twice out of two and bastion
   10 once out of two. The commit before this one was titled "make the siege
   about changing direction" and was validated against the broken seed — so the
   rule it added has never actually been measured.
2. **Squadrons are 3-4x oversized.** `flank` clears the bastion 10 stronghold
   on 12-16 birds of 54. The design-gates skill names this exact failure: "If a
   level can be won on a third of its squadron, losses never bite and no
   placement decision can show up in the result." That is *the* reason a
   48-bird siege feels like 48 identical decisions, and tightening the squadron
   is the remedy the skill prescribes.

This is the next iteration: retune squadron sizes and the defensive ring
against the rendered matrix until `column` fails where it must and a good siege
ends with roughly a third of the wing spare.

**Open: widescreen framing.** The exported desktop build at 1280×800 was
captured mid-siege: playable, but the island is a small object in a large
empty ocean with the HUD pinned to far corners. This is the P1 widescreen item
and it is the most visible "this was a phone game" tell left.
