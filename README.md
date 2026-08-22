# Bastion Bomber

Portrait top-down siege game: tap the water around an island fortress to deploy bombers, dodge corner turrets, and bring down the keep.

Built with **Godot 4.7** (Compatibility / GL renderer) for desktop (Windows / Linux / macOS), web, Android, and iOS.

## Play

```bash
godot --path .
```

Or open this folder in the Godot 4.7 editor and press Play.

**Controls:** tap / click the blue water around the island to deploy a plane, or hold to stream them. On desktop and controller, `WASD` / left stick walks an aiming reticle over the sea and `Space` / `A` scrambles at it — the reticle turns red over water a bird cannot launch from, and its inner arc is the scramble gap counting down. `Esc` / `Start` pauses, `F11` toggles fullscreen, `M` mutes, `R` re-flies the bastion. Birds leave the deck on a fixed scramble gap, so mashing gains you nothing — **where** each one enters is the whole game.

Read the water before you tap. Every corner gun owns a sector, drawn on the sea as a warm wedge; the cool gaps between sectors are the safe lanes in. A wedge that brightens is a gun that has locked onto one of your birds and is about to fire — and a gun stays committed for over a second, so a bird sent into a hot sector buys the next one a clean run. Silence a gun and its sector goes dark for good.

**Keep moving.** Sectors are not fixed. Lean on one lane and the mounts traverse to meet you — you will watch the wedges swing across your approach and shut it. Find the next quiet water, hit from there, and let the fort chase. A squadron flown down a single bearing gets ground down; on the milestone strongholds it simply fails.

Destroy the central keep to win; spend the squadron with the keep still standing and you lose. Beat a bastion to pan to the next of 20 islands.

**Airframes are earned per level band:** gunships (1–5) hunt corner AA then strafe with their nose gun, bombers (6–10) drop one heavy bomb, strike jets (11–15) fire a guided missile from standoff and bank away, carpet bombers (16–20) begin their run 265 px out and lay three bombs along the keep track. The stronghold evolves too — missile batteries from level 4, flak airbursts from 13.

## Automated playtest

```bash
tools/playtest.sh                 # deploy 6 bombers, screenshot every 3s, ~25s
tools/playtest.sh --planes=15 --duration=60   # full run to a win/lose ending
```

Simulates taps, saves screenshots and a `summary.json` to `playtest/latest/`, and prints a `PLAYTEST_SUMMARY` JSON line. Agents follow the write code → playtest → improve loop in `.cursor/skills/playtest-loop/`.

Extra capture flags: `--pause-menu` / `--pause-menu=options` shoot the pause
panel (built in code, so a screenshot is the only layout regression test),
and `--reticle` drives the keyboard aim path so the crosshair appears in the
frames.

`--seed=N` is now authoritative: the level scene used to call `randomize()`
after the harness seeded, so every "seeded" balance result was really
run-to-run noise. Same seed, same outcome.

Strategies are `spread` / `blitz` / `waves` (random placement), `flank` (re-reads the board before every deploy and moves to whatever water is quiet now), and `column` (locks the quietest bearing once and commits the whole squadron to it). The pair that matters is **`flank` must win where `column` fails** — that is the measurement that the siege still demands changing direction. See `.cursor/skills/design-gates/`.

## Project layout

- `scenes/` — main level, plane, turret, keep, bullet, HUD
- `scripts/` — gameplay logic
- `assets/` — Kenney CC0 art used by the game (see `assets/CREDITS.md`)
- `inspiration/` — original Kenney packs (ignored by Godot via `.gdignore`)
- `blueprint.md` — design decisions
- `build/` — export output (created when you export)

## Options and saves

`Esc` opens the pause menu; **Options** covers master / effects / music /
ambience levels, fullscreen, v-sync, screen-shake strength, reduced motion,
and a colourblind mode for the threat overlay. The entire tactical read is a
warm wedge over cool sea, which is exactly the contrast a red-green deficiency
loses, so the wedge hue and its alpha are both settings rather than constants.

Everything persists to `user://settings.cfg` — settings, campaign progress
(highest bastion reached), and the best star rating per bastion. Stars only
ever improve, so replaying a cleared bastion can't cost you a rating. On the
web build `user://` is browser storage; on desktop it is the platform's app
data directory.

## Desktop export

Presets: `Windows Desktop`, `Linux`, `macOS`. Requires Godot **4.7.1** export
templates.

```bash
mkdir -p build/linux build/windows build/macos
godot --headless --path . --export-release "Linux"           build/linux/BastionBomber.x86_64
godot --headless --path . --export-release "Windows Desktop" build/windows/BastionBomber.exe
godot --headless --path . --export-release "macOS"           build/macos/BastionBomber.zip
```

The window opens at 576×1024 and is resizable; the viewport is 720×1280 with
`expand` stretch, so a wider window shows more ocean rather than stretching the
island. macOS needs codesign identity / team id filled into the preset before
a distributable build.

## Web export

Requires Godot **4.7.1** export templates installed (Editor → Manage Export Templates, or the `.tpz` from [Godot builds](https://github.com/godotengine/godot-builds/releases)).

```bash
mkdir -p build/web
godot --headless --path . --export-release "Web" build/web/index.html
python3 -m http.server 8080 --directory build/web
# open http://localhost:8080
```

### GitHub Pages note

Godot 4 web builds often need SharedArrayBuffer / cross-origin isolation when threads are enabled. This preset has **thread support off**, so a plain static host works. If you later enable threads, serve these headers:

```
Cross-Origin-Opener-Policy: same-origin
Cross-Origin-Embedder-Policy: require-corp
```

## Android export

Preset name: `Android` → `build/android/BastionBomber.apk`

One-time setup:

1. Install [Android Studio](https://developer.android.com/studio) / SDK (platform tools + build-tools).
2. In Godot: Editor → Editor Settings → Export → Android — set SDK path, and debug keystore (Godot can generate one).
3. Install export templates matching 4.7.1.
4. Export:

```bash
mkdir -p build/android
godot --headless --path . --export-debug "Android" build/android/BastionBomber.apk
```

Package id: `com.bastionbomber.game` (portrait).

## iOS export

Preset name: `iOS` (exports an Xcode project / IPA path under `build/ios/`).

One-time setup:

1. Xcode installed (present on this machine).
2. Apple Developer team id + signing in the iOS preset (`application/app_store_team_id`).
3. Export templates 4.7.1.
4. Prefer **Export Project Only**, then open the generated Xcode project to archive/sign.

Orientation is locked to portrait in the preset.

## Balance (campaign)

- Levels: 20 procedural islands in one ocean; camera pans between them
- Framing: the camera zooms out per bastion (0.8 down to ~0.6) so the island plus a ~120 px ring of tappable water always fits across the screen. Not cosmetic — at a fixed zoom the level 15 and 20 islands were wider than the viewport, leaving no water to tap east or west and removing those approach bearings from the game entirely
- Deploy rate: one bird per scramble gap (0.5–1.0 s by wing) for taps *and* holds — the only resource clock in the game
- Squadron: sized per wing, from measured good-play runs — gunship 36→48, bomber 38→54, strike 42→54, carpet 56→76
- Wings by level band: gunship 1–5 (SEAD — prefer corner AA, 5 strafe shots × 4 dmg), bomber 6–10 (one 20-dmg bomb), strike 11–15 (guided missile, 20 dmg, launched 230 px out — scales with AA reach), carpet 16–20 (3 bombs × 10 dmg along the keep track)
- Keep HP: 100 + 4×(level−1); corner AA and outer towers scale up
- Corner AA: each gun covers a ~120° sector centred on its current facing and cannot traverse past it. Four live guns close the ring, three leave a usable gap, two leave the island open. Reach scales with the island (capped at 470) so the contested water stays a real space on the big late strongholds
- Sectors slew: a mount swings its whole sector toward sustained pressure (up to ~57° off its corner) and drifts back when the sky clears. This is what forces the attack to keep moving — a fixed bearing gets answered and shut
- Corner AA leads its target, commits to it for 1.25 s, and traverses at 1.5 rad/s — slower than a bird's run in, which is what makes baiting work
- Outer towers traverse freely but reach short: the close-in punish for overflying, not the strategic ring
- Stronghold arsenal: machine guns from level 1, missile launchers from 4, flak airbursts from 13 (downs every plane within 60 px of the burst)
- Difficulty is staggered one step at a time: third corner gun at 3, missile launcher at 4, faster gun cycle at 5
- Defense pads are color-coded: red = keep AA, green = MG, amber = missile, crimson = flak
- Stars on win: 3 = ≤55% of the squadron, 2 = ≤80%, 1 = more
- One bullet downs a plane (sizzle-down, no payload)

## License

Code: yours. Art: Kenney CC0 — see `assets/CREDITS.md` and `assets/licenses/`.
