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

**Open: widescreen framing.** The exported desktop build at 1280×800 was
captured mid-siege: playable, but the island is a small object in a large
empty ocean with the HUD pinned to far corners. This is the P1 widescreen item
and it is the most visible "this was a phone game" tell left.
