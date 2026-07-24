extends Node

## Shared gameplay constants and level-scaling helpers for Bastion Bomber.

const LEVEL_COUNT := 20

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
const PLANE_BOMB_RADIUS := 70.0
const PLANE_SCALE := 0.9

const TURRET_RANGE := 360.0
const TURRET_FIRE_COOLDOWN := 1.2
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
const KEEP_RADIUS := 90.0
const FORT_CLEAR_RADIUS := 110.0
const WATER_MIN_RADIUS := 255.0

const ISLAND_SPACING_MIN := 1400.0
const ISLAND_SPACING_MAX := 1800.0
const CAMERA_PAN_DURATION := 1.2


func level_t(level: int) -> float:
	var n := clampi(level, 1, LEVEL_COUNT)
	if LEVEL_COUNT <= 1:
		return 0.0
	return float(n - 1) / float(LEVEL_COUNT - 1)


func squadron_for_level(level: int) -> int:
	return SQUADRON_BASE + (clampi(level, 1, LEVEL_COUNT) - 1) * SQUADRON_PER_LEVEL


func island_radius_for_level(level: int) -> float:
	return lerpf(ISLAND_RADIUS, ISLAND_RADIUS_MAX, level_t(level))


func keep_hp_for_level(level: int) -> int:
	return KEEP_MAX_HP + (clampi(level, 1, LEVEL_COUNT) - 1) * KEEP_HP_PER_LEVEL


func turret_count_for_level(level: int) -> int:
	# 2 → 4 across the campaign.
	return clampi(2 + int(round(level_t(level) * 2.0)), 2, 4)


func tower_count_range_for_level(level: int) -> Vector2i:
	# 1–2 early → 4–6 late.
	var t := level_t(level)
	var lo := clampi(1 + int(floor(t * 3.0)), 1, 4)
	var hi := clampi(2 + int(floor(t * 4.0)), lo, 6)
	return Vector2i(lo, hi)


func three_star_max_used(keep_max_hp: int, gun_count: int, squadron: int) -> int:
	var cap := ceili(float(keep_max_hp) / float(KEEP_BOMB_DAMAGE)) + 2 + int(gun_count / 2)
	var one_star_min := squadron - 5
	return mini(cap, one_star_min - 2)


func stars_for_win(planes_used: int, keep_max_hp: int, gun_count: int, squadron: int) -> int:
	var three := three_star_max_used(keep_max_hp, gun_count, squadron)
	var one_min := squadron - 5
	if planes_used <= three:
		return 3
	if planes_used >= one_min:
		return 1
	return 2
