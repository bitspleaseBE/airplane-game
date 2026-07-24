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
	PlaneType.GUNSHIP: Vector2(0.9, 0.9),
	PlaneType.BOMBER: Vector2.ONE,
	PlaneType.STRIKE: Vector2(0.95, 0.95),
	PlaneType.CARPET: Vector2(1.12, 1.12),
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
## Standoff sits deep inside AA range (360) so the run in and out is still a gamble.
const STRIKE_STANDOFF := 160.0
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
const CARPET_START_RANGE := 130.0
const CARPET_SPEED_MULT := 0.9

## Stronghold evolution — staggered so no level introduces two new things.
const MISSILE_TOWER_UNLOCK_LEVEL := 4
const FLAK_TOWER_UNLOCK_LEVEL := 13

## Flak battery: shell bursts at the plane's predicted spot, hits everything nearby.
const FLAK_RANGE := 300.0
const FLAK_COOLDOWN := 2.4
const FLAK_SHELL_SPEED := 320.0
const FLAK_BURST_RADIUS := 60.0

const SQUADRON_BASE := 40
const SQUADRON_PER_LEVEL := 3
## Alias for level-1 squadron (playtest / HUD defaults).
const SQUADRON_SIZE := SQUADRON_BASE

const KEEP_MAX_HP := 100
const KEEP_HP_PER_LEVEL := 4  # level 20 → 100 + 76 = 176
const KEEP_BOMB_DAMAGE := 20
const TURRET_MAX_HP := 40
const TURRET_BOMB_DAMAGE := 20

const PLANE_SPEED := 220.0
const PLANE_BOMB_RADIUS := 95.0
const PLANE_SCALE := 0.9

## Hold-to-deploy gap between birds — lighter wings scramble faster.
const PLANE_DEPLOY_INTERVALS := {
	PlaneType.STRIKE: 0.35,
	PlaneType.GUNSHIP: 0.45,
	PlaneType.BOMBER: 0.55,
	PlaneType.CARPET: 0.75,
}

const TURRET_RANGE := 360.0
const TURRET_FIRE_COOLDOWN := 1.2
## From bastion 3 up, corner guns reach farther and cycle faster so blitz dies.
const TURRET_RANGE_HOT := 410.0
const TURRET_FIRE_COOLDOWN_HOT := 0.75
const TURRET_ROTATE_SPEED := 3.5
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

## Campaign milestones: oversized islands with denser outer defenses.
const STRONGHOLD_LEVELS := [10, 15, 20]


func level_t(level: int) -> float:
	var n := clampi(level, 1, LEVEL_COUNT)
	if LEVEL_COUNT <= 1:
		return 0.0
	return float(n - 1) / float(LEVEL_COUNT - 1)


func is_stronghold_level(level: int) -> bool:
	return clampi(level, 1, LEVEL_COUNT) in STRONGHOLD_LEVELS


func squadron_for_level(level: int) -> int:
	return SQUADRON_BASE + (clampi(level, 1, LEVEL_COUNT) - 1) * SQUADRON_PER_LEVEL


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
		if n == 10:
			return Vector2i(4, 5)
		if n == 15:
			return Vector2i(7, 9)
		return Vector2i(8, 10)
	if n <= 2:
		return Vector2i(1, 1)
	if n <= 5:
		return Vector2i(3, 3) if n >= 3 else Vector2i(2, 3)
	if n >= 16:
		return Vector2i(4, 6)
	if n >= FLAK_TOWER_UNLOCK_LEVEL:
		return Vector2i(3, 5)
	var t := level_t(level)
	var lo := clampi(1 + int(floor(t * 3.0)), 1, 4)
	var hi := clampi(2 + int(floor(t * 4.0)), lo, 6)
	return Vector2i(lo, hi)


func turret_range_for_level(level: int) -> float:
	return TURRET_RANGE_HOT if clampi(level, 1, LEVEL_COUNT) >= 3 else TURRET_RANGE


func turret_cooldown_for_level(level: int) -> float:
	return TURRET_FIRE_COOLDOWN_HOT if clampi(level, 1, LEVEL_COUNT) >= 3 else TURRET_FIRE_COOLDOWN


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
	keep_max_hp: int, gun_count: int, squadron: int, level: int = 1
) -> int:
	var dmg := maxi(expected_keep_damage_per_plane(plane_type_for_level(level)), 1)
	var cap := ceili(float(keep_max_hp) / float(dmg)) + 2 + int(gun_count / 2)
	var one_star_min := squadron - 5
	return mini(cap, one_star_min - 2)


func stars_for_win(
	planes_used: int, keep_max_hp: int, gun_count: int, squadron: int, level: int = 1
) -> int:
	var three := three_star_max_used(keep_max_hp, gun_count, squadron, level)
	var one_min := squadron - 5
	if planes_used <= three:
		return 3
	if planes_used >= one_min:
		return 1
	return 2
