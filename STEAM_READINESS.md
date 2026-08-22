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

### Open: gate 1, and the structural cause

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
