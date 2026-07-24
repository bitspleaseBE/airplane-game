# Bastion Bomber — Game Blueprint

One page, short answers. This drives build order, scope, and the automated
asset search — keep the **bold field labels** and `[ ]` checkboxes intact so
tooling can parse it. Mark a checkbox like `[x]`.

**Status:** [x] draft · [ ] agreed — **Last updated:** 2026-07-23

## 1. Pitch

Two sentences, max. What is this game and why is it fun?

**Pitch:** Deploy swarms of bombers around an island fortress and watch them dive toward the keep while corner turrets try to shoot them down. It's a one-thumb siege: place planes, burn the squadron, bring the bastion down.

## 2. Story & setting

- **Setting / era:** Soft-cartoon modern war; bright Kenney top-down island fortress.
- **Why are we in a tower:** We aren't — the enemy is. The player is the attacking air wing.
- **Who are the enemies and what do they want:** An entrenched stronghold crew defending a coastal bastion; they want to keep the keep standing.
- **How much story in v1:** [x] none · [ ] intro screen only · [ ] light between-wave flavor text · [ ] more

## 3. Perspective & presentation

- **View:** [ ] 2D side-view · [x] 2D top-down · [ ] first-person scope view · [ ] other:
- **Dimension:** [x] 2D · [ ] 3D
- **Orientation:** [ ] landscape · [x] portrait

## 4. Core loop

- **The 30-second loop:** Tap water around the island to spawn a bomber; it flies toward the keep, drops a bomb if it survives, then exits. Turrets track and shoot planes that get close.
- **Aiming:** Tap spawn point on water; plane auto-flies toward the keep (and bombs whatever is under the drop).
- **Ammo & reload:** Fixed squadron per level (15 bombers). No regen.
- **Weak points / headshots:** Keep is the win target; corner turrets are optional but make bombing safer if destroyed.
- **Between waves:** [ ] upgrade shop · [x] auto-continue · [ ] repair/ability choices
- **The hook — what makes it OUR game (one sentence):** Drop planes around a living fortress and watch the swarm race the turrets to the keep.

## 5. Win / lose

- **Lose when:** Squadron is spent (all planes used or destroyed) and the keep still stands.
- **Run structure:** [ ] endless + score · [ ] survive N waves = win · [x] level-based campaign
- **Target run length:** Full game 2–5 minutes, rather too short than too long; ~30–90 seconds per level.
- **Difficulty curve:** Harder every level, exactly one new thing per level; dumping the whole squadron at once wins early levels but must fail later ones (gates in `.cursor/skills/design-gates/`).

## 6. Player persona

- **Who's playing:** Casual mobile/web players who like short siege/swarm moments.
- **They come back because:** Quick “one more try” with clearer placement and less wasted planes.
- **Session context:** [x] 5-min break · [ ] 15-min session · [ ] longer sittings

## 7. Target platform & input

- **Primary:** [ ] desktop browser · [ ] mobile browser · [x] both (deployed on GitHub Pages either way)
- **Input:** [ ] mouse + keyboard · [ ] touch · [x] both
- **Performance floor:** Mid-range phone browser / desktop browser at 60fps with ~20 planes + 4 turrets.
- **Note:** Native Android + iOS export presets included; web is the always-playable path.

## 8. Tone of voice

- **In-game text sounds like:** Cool, badass, military-bro radio chatter — confident swagger, a bit over the top, never grim.
- **Example line we'd actually ship:** “BASTION DOWN. Nothing left but smoke and glory.”

## 9. Visual style

- **Style:** [ ] pixel art — tile size: 16 / 32 / 64 · [x] flat vector · [ ] hand-drawn · [ ] low-poly 3D
- **Palette / mood:** Bright Kenney greens/blues/greys; sunny island fortress under siege.
- **Reference games / images:** Kenney tower-defense top-down pack; swarm/siege feel like a reverse tower defense.

## 10. Audio direction

- **SFX character:** Soft cartoon hits, whooshes, small booms (CC0 if added).
- **Ambience:** Soft looping beach / birds island bed for cinematic mood (under combat SFX).
- **Music:** None for v1 PoC (silent is fine).

## 11. Scope & success (the honesty section)

- **v1.0 is done when:** (max 5 bullets)
  - One portrait island with water, keep, and 4 corner turrets
  - Tap-to-deploy bombers that fly to the keep and bomb it
  - Turrets shoot planes; one hit = sizzle-down crash (no bomb)
  - Win (keep destroyed) and lose (squadron spent) screens with restart
  - HTML5 export works; Android/iOS presets documented
- **Explicit non-goals for v1.0:** (things we agree NOT to build)
  - Multiple plane types (napalm, carpet, guided, etc.) — *shipped later, in v1.2: level-bound wings (gunship / bomber / strike / carpet)*
  - Stronghold evolution (missile, AA) — *shipped later, in v1.2: missile at 4, flak at 13*
  - Multi-level campaign / shop / upgrades
  - Online multiplayer or leaderboards
  - Full music score
- **Time budget / target date:** PoC now
- **Why we're building this:** [x] fun & learning · [ ] portfolio piece · [ ] real release ambitions

## 12. Inspirations

- **Games we're borrowing from, and what exactly:**
  - Reverse tower defense / swarm placement (tap spawn, watch AI attack)
  - Clash Royale-ish “drop onto map” feel, but tap-edge spawn instead of hand drag
  - Kenney TD top-down art language

## 13. Asset search inputs (machine-read by the asset finder)

- **License policy:** [x] CC0 only · [ ] CC0 + CC-BY with credits file · [ ] anything free for commercial use
- **Search keywords:** top-down plane bomber, fortress turret, island water grass sand tiles, smoke explosion particles
- **Asset needs, in priority order:**
  1. Top-down bomber plane (+ optional shadow)
  2. Corner turret (base + barrel) and keep/castle tiles
  3. Water / sand / grass terrain tiles
  4. Bullet + bomb sprites
  5. Smoke trail + explosion frames
