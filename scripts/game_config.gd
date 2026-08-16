extends Node

## Shared gameplay constants and level-scaling helpers for Bastion Bomber.

const LEVEL_COUNT := 20

## Airframes are bound to level bands — you earn a new wing as the campaign advances.
enum PlaneType { GUNSHIP, BOMBER, STRIKE, CARPET }

const PLANE_TYPE_NAMES := {
	PlaneType.GUNSHIP: "GUNSHIP",
	PlaneType.BOMBER: "BOMBER",
	PlaneType.STRIKE: "STRIKE",
	PlaneType.CARPET: "CARPET",
}

## Sprite tint per airframe so the wing reads at a glance.
const PLANE_TYPE_TINTS := {
	PlaneType.GUNSHIP: Color(0.72, 0.86, 0.58),
	PlaneType.BOMBER: Color(1.0, 1.0, 1.0),
	PlaneType.STRIKE: Color(0.62, 0.78, 1.0),
	PlaneType.CARPET: Color(1.0, 0.6, 0.48),
}

## Visual silhouette only — Area2D scale stays fixed so hitboxes stay fair.
const PLANE_TYPE_SPRITE_SCALES := {
	PlaneType.GUNSHIP: Vector2(1.05, 1.05),
	PlaneType.BOMBER: Vector2(1.18, 1.18),
	PlaneType.STRIKE: Vector2(1.1, 1.1),
	PlaneType.CARPET: Vector2(1.3, 1.3),
}

const GUNSHIP_MAX_LEVEL := 5
const BOMBER_MAX_LEVEL := 10
const STRIKE_MAX_LEVEL := 15

## Gunship (levels 1–5): hunts corner AA first, strafes with its nose gun.
const GUNSHIP_STRAFE_RANGE := 250.0
const GUNSHIP_SHOT_COUNT := 5
const GUNSHIP_SHOT_DAMAGE := 4  # 5 × 4 = 20, same payload as one bomb
const GUNSHIP_SHOT_INTERVAL := 0.16
const GUNSHIP_SHOT_JITTER := 28.0
const GUNSHIP_SPEED_MULT := 1.08

## Strike jet (levels 11–15): fires a guided missile from standoff, then banks away.
## Standoff still sits inside AA reach so the run in and out is a gamble, but it
## has to scale with that reach: corner guns now cover up to 470, and launching
## at the old 160 meant the jets flew almost to the keep before releasing, which
## is the bomber's job and got them killed doing it.
const STRIKE_STANDOFF := 230.0
const STRIKE_MISSILE_DAMAGE := 20
const STRIKE_MISSILE_SPEED := 300.0
const STRIKE_MISSILE_TURN_RATE := 4.5
const STRIKE_SPEED_MULT := 1.15

## Bomber (levels 6–10): must overfly the keep — needs pace to punch through AA.
const BOMBER_SPEED_MULT := 1.35

## Carpet bomber (levels 16–20): one plane lays 3 bombs along the keep track.
const CARPET_BOMB_COUNT := 3
const CARPET_BOMB_DAMAGE := 10
const CARPET_BOMB_INTERVAL := 0.22
const CARPET_BOMB_SPACING := 36.0
## Start the pass outside bomb radius so the stick centers on the keep.
const CARPET_START_RANGE := 170.0
## Carpet bombers overfly the whole fort on a locked heading, which makes them
## the easiest airframe for a leading gunner to solve. They need the pace to
## survive the run they are forced to make.
const CARPET_SPEED_MULT := 1.2

## Stronghold evolution — staggered so no level introduces two new things.
const MISSILE_TOWER_UNLOCK_LEVEL := 4
const FLAK_TOWER_UNLOCK_LEVEL := 13

## Flak battery: shell bursts at the plane's predicted spot, hits everything nearby.
const FLAK_RANGE := 300.0
const FLAK_COOLDOWN := 2.4
const FLAK_SHELL_SPEED := 320.0
const FLAK_BURST_RADIUS := 60.0

## Squadron size is calibrated per wing rather than on one global ramp: a
## gunship puts a fraction of a bomb on the keep, a carpet run puts three, and
## the airframes lose birds at very different rates. Values come from measured
## well-flown runs (tools/balance_check.sh) and are sized so a good siege ends
## with roughly a third of the wing spare while a sloppy one runs dry — which
## is what makes an individual deploy worth thinking about.
## Vector2i(size at the wing's first level, growth per level within the band).
const SQUADRON_BY_WING := {
	PlaneType.GUNSHIP: Vector2i(36, 3),  # levels 1–5   → 36..48
	PlaneType.BOMBER: Vector2i(30, 3),   # levels 6–10  → 30..42
	PlaneType.STRIKE: Vector2i(42, 3),   # levels 11–15 → 42..54
	PlaneType.CARPET: Vector2i(50, 3),   # levels 16–20 → 50..62
}
const SQUADRON_BASE := 36
## Alias for level-1 squadron (playtest / HUD defaults).
const SQUADRON_SIZE := SQUADRON_BASE

## Fractions of the squadron a win may cost for each star rating. Deriving the
## bands from the squadron rather than from a theoretical damage-per-plane
## figure keeps them honest: the old model assumed every bird delivered, so
## three stars sat at roughly half the plane count anyone can actually achieve.
const THREE_STAR_FRACTION := 0.55
const TWO_STAR_FRACTION := 0.8

const KEEP_MAX_HP := 100
const KEEP_HP_PER_LEVEL := 4  # level 20 → 100 + 76 = 176
const KEEP_BOMB_DAMAGE := 20
const TURRET_MAX_HP := 40
const TURRET_BOMB_DAMAGE := 20

const PLANE_SPEED := 220.0
const PLANE_BOMB_RADIUS := 70.0
## Body scale for the Area2D; sprites size up further via PLANE_TYPE_SPRITE_SCALES.
const PLANE_SCALE := 1.05
## Flight contrail cadence (seconds between puffs while airborne).
const PLANE_TRAIL_INTERVAL := 0.07

## Gap between birds leaving the deck — lighter wings scramble faster. This
## applies to every deploy, taps included: it is the game's only resource clock,
## so it also sets how long the player has to read the board between decisions.
## Fast enough to keep a siege flowing, slow enough that a deploy is a choice
## rather than a reflex.
const PLANE_DEPLOY_INTERVALS := {
	PlaneType.STRIKE: 0.5,
	PlaneType.GUNSHIP: 0.62,
	PlaneType.BOMBER: 0.75,
	PlaneType.CARPET: 1.0,
}

const TURRET_RANGE := 360.0
const TURRET_FIRE_COOLDOWN := 1.2
## Corner guns reach farther from bastion 3, and cycle faster from bastion 5.
## Staggered on purpose: landing both upgrades on the same level alongside the
## third gun and a denser tower ring made bastion 3 a wall, and broke the
## one-new-thing-per-level rule four ways at once.
const TURRET_RANGE_HOT := 410.0
const TURRET_FIRE_COOLDOWN_HOT := 0.75
const TURRET_COOLDOWN_HOT_LEVEL := 5
## Depth of covered water a corner gun holds beyond its own shoreline. Islands
## nearly double in radius across the campaign; a flat range meant that by the
## late strongholds the AA envelope stopped short of the sea entirely, so the
## approach was never contested and choosing where to come in stopped mattering.
## Scaling reach with the island keeps the corridor a real, readable space.
const TURRET_WATER_REACH := 105.0
## Ceiling on that growth. Without it the late strongholds reach clear across
## the screen, which both erases the cold water the tactic depends on and makes
## the deep run a carpet wing has to fly simply unsurvivable.
const TURRET_RANGE_CAP := 470.0
const TURRET_ROTATE_SPEED := 3.5
## How fast a barrel swings, rad/s. Deliberately slower than a plane's run: a
## gun facing the wrong way stays wrong for long enough that the player can
## spend that window, which is what makes tap placement a decision at all.
const TURRET_TRAVERSE_SPEED := 1.5
## Seconds a gun stays committed to one bird before re-picking. Long enough
## that a decoy on the far side actually pulls the barrel off your real run.
const TURRET_TARGET_LOCK_TIME := 1.25
const BULLET_SPEED := 380.0
const BULLET_DAMAGE := 1

## Outer defense towers (procedural, smaller than keep AA).
const TOWER_MAX_HP := 30
const TOWER_BOMB_DAMAGE := 20
const TOWER_MG_RANGE := 200.0
const TOWER_MG_COOLDOWN := 0.45
const TOWER_MISSILE_RANGE := 310.0
const TOWER_MISSILE_COOLDOWN := 2.8
const MISSILE_SPEED := 210.0
const MISSILE_TURN_RATE := 2.8
const MISSILE_DAMAGE := 3
const MISSILE_LIFETIME := 4.0

## Soft cloud banks + ocean shadows. Off for now — they muddy plane/AA readability.
const CLOUDS_ENABLED := false

## Legacy single-island defaults (level-1 center / radius). Prefer runtime active center.
const ISLAND_CENTER := Vector2(360, 640)
const ISLAND_RADIUS := 240.0
const ISLAND_RADIUS_MAX := 380.0
## Milestone bastions (10 / 15 / 20) punch above the normal size curve.
const ISLAND_RADIUS_STRONGHOLD := 460.0
const KEEP_RADIUS := 90.0
const FORT_CLEAR_RADIUS := 110.0
const WATER_MIN_RADIUS := 255.0
## Guns stay this far inside the grass line so they don't sit on the beach.
const TOWER_INLAND_MARGIN := 52.0

const ISLAND_SPACING_MIN := 1400.0
const ISLAND_SPACING_MAX := 1800.0
const CAMERA_PAN_DURATION := 1.2

## Empty tropical islets between bastions — scenery only, no guns.
const SCENIC_ISLAND_COUNT_MIN := 8
const SCENIC_ISLAND_COUNT_MAX := 12
const SCENIC_RADIUS_MIN := 55.0
const SCENIC_RADIUS_MAX := 135.0
const SCENIC_SEP_FROM_BASTION := 560.0
const SCENIC_SEP_FROM_SCENIC := 400.0

## Campaign milestones: oversized islands with denser outer defenses.
const STRONGHOLD_LEVELS := [10, 15, 20]


func level_t(level: int) -> float:
	var n := clampi(level, 1, LEVEL_COUNT)
	if LEVEL_COUNT <= 1:
		return 0.0
	return float(n - 1) / float(LEVEL_COUNT - 1)


func is_stronghold_level(level: int) -> bool:
	return clampi(level, 1, LEVEL_COUNT) in STRONGHOLD_LEVELS


## First campaign level that flies the given wing.
func wing_band_start(plane_type: PlaneType) -> int:
	match plane_type:
		PlaneType.BOMBER:
			return GUNSHIP_MAX_LEVEL + 1
		PlaneType.STRIKE:
			return BOMBER_MAX_LEVEL + 1
		PlaneType.CARPET:
			return STRIKE_MAX_LEVEL + 1
		_:
			return 1


func squadron_for_level(level: int) -> int:
	var n := clampi(level, 1, LEVEL_COUNT)
	var wing := plane_type_for_level(n)
	var spec: Vector2i = SQUADRON_BY_WING[wing]
	return spec.x + (n - wing_band_start(wing)) * spec.y


func plane_type_for_level(level: int) -> PlaneType:
	var n := clampi(level, 1, LEVEL_COUNT)
	if n <= GUNSHIP_MAX_LEVEL:
		return PlaneType.GUNSHIP
	if n <= BOMBER_MAX_LEVEL:
		return PlaneType.BOMBER
	if n <= STRIKE_MAX_LEVEL:
		return PlaneType.STRIKE
	return PlaneType.CARPET


func plane_name_for_level(level: int) -> String:
	return PLANE_TYPE_NAMES[plane_type_for_level(level)]


func deploy_interval_for_plane(plane_type: PlaneType) -> float:
	return PLANE_DEPLOY_INTERVALS.get(plane_type, PLANE_DEPLOY_INTERVALS[PlaneType.BOMBER])


func deploy_interval_for_level(level: int) -> float:
	return deploy_interval_for_plane(plane_type_for_level(level))


func island_radius_for_level(level: int) -> float:
	var n := clampi(level, 1, LEVEL_COUNT)
	if is_stronghold_level(n):
		# 10 / 15 / 20 step up so the finale feels like a real fortress isle.
		if n == 10:
			return lerpf(ISLAND_RADIUS_MAX, ISLAND_RADIUS_STRONGHOLD, 0.55)
		if n == 15:
			return lerpf(ISLAND_RADIUS_MAX, ISLAND_RADIUS_STRONGHOLD, 0.8)
		return ISLAND_RADIUS_STRONGHOLD
	return lerpf(ISLAND_RADIUS, ISLAND_RADIUS_MAX, level_t(n))


func keep_hp_for_level(level: int) -> int:
	return KEEP_MAX_HP + (clampi(level, 1, LEVEL_COUNT) - 1) * KEEP_HP_PER_LEVEL


func turret_count_for_level(level: int) -> int:
	# L1–2 teach the loop with 2 guns; L3+ demands a third so blitz stops free-winning.
	var n := clampi(level, 1, LEVEL_COUNT)
	if n <= 2:
		return 2
	if n <= 9:
		return 3
	if is_stronghold_level(n):
		return 4
	if n <= 14:
		return 3
	return 4


func tower_count_range_for_level(level: int) -> Vector2i:
	# 1 early → denser late; milestone bastions pack a thick outer ring.
	# L10 is still a bomber-overfly siege — keep the ring fat, not impossible.
	var n := clampi(level, 1, LEVEL_COUNT)
	if is_stronghold_level(n):
		# Milestone rings are thick, but not so thick that the corridor closes
		# entirely — a carpet wing still has to fly the whole fort to deliver.
		# Bastion 10 is the first stronghold and the fast bomber wing punches
		# through a thin ring whatever direction it comes from; 15 flies the
		# fragile strike wing and was drowning in guns.
		if n == 10:
			return Vector2i(5, 6)
		if n == 15:
			return Vector2i(4, 5)
		return Vector2i(6, 7)
	# One addition at a time through the opening bastions: L3 brings a third
	# corner gun, L4 the first missile launcher, L5 the faster gun cycle.
	if n <= 3:
		return Vector2i(1, 1)
	if n <= 5:
		return Vector2i(2, 2)
	# The bomber bastions used to thin out here: three corner guns and a couple
	# of towers on a mid-sized island left so much slack that nothing the player
	# did with placement showed up in the result.
	if n <= 9:
		return Vector2i(3, 4)
	if n >= 16:
		return Vector2i(4, 6)
	if n >= FLAK_TOWER_UNLOCK_LEVEL:
		return Vector2i(3, 5)
	var t := level_t(level)
	var lo := clampi(1 + int(floor(t * 3.0)), 1, 4)
	var hi := clampi(2 + int(floor(t * 4.0)), lo, 6)
	return Vector2i(lo, hi)


func turret_range_for_level(level: int) -> float:
	var n := clampi(level, 1, LEVEL_COUNT)
	var base := TURRET_RANGE_HOT if n >= 3 else TURRET_RANGE
	return clampf(island_radius_for_level(n) + TURRET_WATER_REACH, base, TURRET_RANGE_CAP)


func turret_cooldown_for_level(level: int) -> float:
	var n := clampi(level, 1, LEVEL_COUNT)
	return TURRET_FIRE_COOLDOWN_HOT if n >= TURRET_COOLDOWN_HOT_LEVEL else TURRET_FIRE_COOLDOWN


## Rough keep punch per bird — used for star thresholds across wing types.
func expected_keep_damage_per_plane(plane_type: PlaneType) -> int:
	match plane_type:
		PlaneType.GUNSHIP:
			# Most shots go into AA; expect ~half the payload on the keep.
			return GUNSHIP_SHOT_COUNT * GUNSHIP_SHOT_DAMAGE / 2
		PlaneType.STRIKE:
			return STRIKE_MISSILE_DAMAGE
		PlaneType.CARPET:
			# Stick centered on the keep — expect ~2 of 3 on target.
			return CARPET_BOMB_DAMAGE * 2
		_:
			return KEEP_BOMB_DAMAGE


func three_star_max_used(
	_keep_max_hp: int, _gun_count: int, squadron: int, _level: int = 1
) -> int:
	return maxi(int(floor(float(squadron) * THREE_STAR_FRACTION)), 1)


func stars_for_win(
	planes_used: int, keep_max_hp: int, gun_count: int, squadron: int, level: int = 1
) -> int:
	if planes_used <= three_star_max_used(keep_max_hp, gun_count, squadron, level):
		return 3
	if planes_used <= int(floor(float(squadron) * TWO_STAR_FRACTION)):
		return 2
	return 1
