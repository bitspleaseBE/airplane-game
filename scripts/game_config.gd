extends Node

## Shared gameplay constants for Bastion Bomber PoC.

const SQUADRON_SIZE := 100
const KEEP_MAX_HP := 100
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
const TOWER_COUNT_MIN := 2
const TOWER_COUNT_MAX := 4
const TOWER_MG_RANGE := 200.0
const TOWER_MG_COOLDOWN := 0.45
const TOWER_MISSILE_RANGE := 310.0
const TOWER_MISSILE_COOLDOWN := 2.8
const MISSILE_SPEED := 210.0
const MISSILE_TURN_RATE := 2.8
const MISSILE_DAMAGE := 3
const MISSILE_LIFETIME := 4.0

const ISLAND_CENTER := Vector2(360, 640)
const ISLAND_RADIUS := 300.0
const KEEP_RADIUS := 90.0
const FORT_CLEAR_RADIUS := 110.0
const WATER_MIN_RADIUS := 315.0
