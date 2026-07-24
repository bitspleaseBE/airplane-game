# Bastion Bomber

Portrait top-down siege game: tap the water around an island fortress to deploy bombers, dodge corner turrets, and bring down the keep.

Built with **Godot 4.7** (Compatibility / GL renderer) for web, Android, and iOS.

## Play

```bash
godot --path .
```

Or open this folder in the Godot 4.7 editor and press Play.

**Controls:** tap / click the blue water around the island to spawn a bomber. Each bastion has a fixed squadron (40 on level 1, growing as you advance). Destroy the central keep to win; spend the squadron with the keep still standing and you lose. Beat a bastion to pan to the next of 20 islands.

## Automated playtest

```bash
tools/playtest.sh                 # deploy 6 bombers, screenshot every 3s, ~25s
tools/playtest.sh --planes=15 --duration=60   # full run to a win/lose ending
```

Simulates taps, saves screenshots and a `summary.json` to `playtest/latest/`, and prints a `PLAYTEST_SUMMARY` JSON line. Agents follow the write code → playtest → improve loop in `.cursor/skills/playtest-loop/`.

## Project layout

- `scenes/` — main level, plane, turret, keep, bullet, HUD
- `scripts/` — gameplay logic
- `assets/` — Kenney CC0 art used by the game (see `assets/CREDITS.md`)
- `inspiration/` — original Kenney packs (ignored by Godot via `.gdignore`)
- `blueprint.md` — design decisions
- `build/` — export output (created when you export)

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
- Squadron: 40 + 3×(level−1) bombers per bastion
- Keep HP: 100 + 4×(level−1); corner AA and outer towers scale up
- Stars on win: 3 = lean run, 1 = used all but 5 planes, 2 = in between
- One bullet downs a plane (sizzle-down, no bomb)

## License

Code: yours. Art: Kenney CC0 — see `assets/CREDITS.md` and `assets/licenses/`.
