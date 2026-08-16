class_name Turret
extends Node2D

## Corner AA turret: commits to a bird and fires bullets.
##
## Each corner gun owns the sector facing out from its own corner and cannot
## swing past it. That limit is the spine of the game's tactics: it means the
## fortress's coverage is genuinely uneven, that the water one gun is not
## watching is really safer, and that every gun the player silences opens a
## permanent hole on that side of the island. A freely-rotating gun made all
## approaches equivalent and reduced deploying to random tapping.
##
## Targeting also skips planes whose shot line would pass through the keep.

signal destroyed(pos: Vector2)

const BARREL_ART_OFFSET := PI * 0.5
## Sector width the barrel may traverse, centred on the outward bearing. Sized
## against the fort's four corner mounts (90° apart): four live guns close the
## ring, three leave a usable gap, two leave the island wide open. That is the
## difficulty curve, drawn in geometry rather than in stat multipliers.
const ARC_SPAN := PI * 0.67  # ~120°
## Slack past the sector edge before a plane stops being worth tracking.
const TRACK_SLACK := 0.12

## The sector is not nailed down. Under sustained pressure the mount traverses
## to meet it, and drifts back to its corner when the sky clears.
##
## This is what stops the game collapsing into a single decision. A fixed sector
## makes coverage legible, but it also makes the gap between sectors permanent —
## so the best play becomes "find the hole once, then feed the whole squadron
## through it in a straight line", which is exactly what the campaign is meant
## to refuse. A lane you lean on closes, and you have to keep moving.
const SECTOR_SLEW_SPEED := 0.5
const SECTOR_RECENTRE_SPEED := 0.16
## How far off its corner a mount may be pulled. Wide enough that the two guns
## flanking an empty corner mount can between them close the 90° hole it leaves
## — otherwise every three-gun bastion keeps a lane no amount of pressure can
## shut, and feeding the squadron down it in a straight line simply wins.
## Still bounded, so a feint cannot drag the whole fort to one side and strip
## the rest of the island bare.
const SECTOR_HOME_SPAN := 1.0  # ~57°
## Gunners under-lead a little and scatter a little. Perfect prediction turned
## the slower airframes into free kills — the sector should be dangerous, not
## deterministic, or there is no point flying through one under any plan.
const LEAD_FACTOR := 0.88
const AIM_JITTER := 0.05
const PAD_COLOR := Color(0.85, 0.28, 0.28)

var max_hp: int = GameConfig.TURRET_MAX_HP
var hp: int = GameConfig.TURRET_MAX_HP
var fire_cooldown: float = 0.0
var _main: Node2D
var _dead: bool = false
var _keep_center: Vector2 = GameConfig.ISLAND_CENTER
var _range: float = GameConfig.TURRET_RANGE
var _cooldown: float = GameConfig.TURRET_FIRE_COOLDOWN
## World-space bearing from the keep out through this corner — the mount's
## resting orientation, which its sector drifts back toward.
var _home_center: float = 0.0
## Where the sector is pointed right now.
var _sector_center: float = 0.0
## CCW start of the allowed arc.
var _arc_start: float = 0.0
## Gun commits to one bird instead of re-picking the nearest every frame.
## Without the commitment the barrel chases whichever plane is momentarily
## closest, which looks like noise and cannot be baited — with it, a decoy
## genuinely buys the next wave a window.
var _locked: PlaneUnit = null
var _lock_timer: float = 0.0

@onready var barrel: Sprite2D = $Barrel
@onready var base: Sprite2D = $Base
@onready var hp_bar: ProgressBar = $HpBar


func configure(
	main_ref: Node2D,
	keep_center: Vector2 = Vector2.ZERO,
	range_override: float = -1.0,
	cooldown_override: float = -1.0,
) -> void:
	_main = main_ref
	_range = range_override if range_override > 0.0 else GameConfig.TURRET_RANGE
	_cooldown = cooldown_override if cooldown_override > 0.0 else GameConfig.TURRET_FIRE_COOLDOWN
	_keep_center = keep_center if keep_center != Vector2.ZERO else (
		main_ref.active_center if main_ref and "active_center" in main_ref else GameConfig.ISLAND_CENTER
	)
	# Outward from the keep through this corner, with the sector centred on it.
	var outward := global_position - _keep_center
	_home_center = outward.angle() if outward.length_squared() > 0.001 else 0.0
	_sector_center = _home_center
	_arc_start = _sector_center - ARC_SPAN * 0.5
	# Start facing down the middle of the sector.
	if barrel:
		barrel.rotation = _arc_to_world(ARC_SPAN * 0.5) + BARREL_ART_OFFSET


func _ready() -> void:
	add_to_group("turrets")
	hp = max_hp
	_update_hp_bar()


## Red pad ring: marks this as the keep's own AA battery.
func _draw() -> void:
	draw_circle(Vector2.ZERO, 27.0, Color(PAD_COLOR.r, PAD_COLOR.g, PAD_COLOR.b, 0.22))
	draw_arc(Vector2.ZERO, 27.0, 0.0, TAU, 40, Color(PAD_COLOR.r, PAD_COLOR.g, PAD_COLOR.b, 0.8), 3.0)


func _process(delta: float) -> void:
	if _dead or _main == null:
		return
	if _main.state != _main.State.PLAYING:
		return

	fire_cooldown = max(fire_cooldown - delta, 0.0)
	_lock_timer = max(_lock_timer - delta, 0.0)
	_slew_sector(delta)
	var plane := _acquire_target()
	if plane == null:
		return

	var to_plane: Vector2 = plane.global_position - global_position
	# Aim where the bird will be, not where it is. Corner AA is the fortress's
	# real teeth: inside its sector a committed gun should land the shot, so
	# that flying through a hot sector is a decision with a cost rather than a
	# dice roll. The gaps between sectors are where the player earns safety.
	var desired_world := (_lead_point(plane) - global_position).angle()
	_rotate_barrel_toward(desired_world, delta)

	if to_plane.length() <= _range and fire_cooldown <= 0.0:
		# Only fire when barrel is on the plane and the shot won't hit the keep.
		if not _shot_hits_keep(plane.global_position):
			var aim_world := _barrel_world_angle()
			# Compare against the clamped aim — the barrel cannot leave the
			# mount's sector, however far outside it the bird actually is.
			var clamped := _arc_to_world(_world_to_arc(desired_world))
			if abs(angle_difference(aim_world, clamped)) < 0.4:
				_fire(clamped + randf_range(-AIM_JITTER, AIM_JITTER))
				fire_cooldown = _cooldown


## Traverse the whole sector toward whatever is pressing this mount, and let it
## settle back to its corner when nothing is.
func _slew_sector(delta: float) -> void:
	var contact := _contact_bearing()
	var goal := _home_center
	var rate := SECTOR_RECENTRE_SPEED
	if not is_inf(contact):
		# Clamp the goal to the arc this mount may be pulled across, so leaning
		# on one side shifts the fort's attention without unpinning it.
		goal = _home_center + clampf(
			angle_difference(_home_center, contact), -SECTOR_HOME_SPAN, SECTOR_HOME_SPAN
		)
		rate = SECTOR_SLEW_SPEED
	var step := rate * delta
	_sector_center += clampf(angle_difference(_sector_center, goal), -step, step)
	_arc_start = _sector_center - ARC_SPAN * 0.5


## Bearing of the nearest bird in range with sector limits ignored. The crew can
## see a raid it cannot yet bring the barrel onto — that sighting is what lets
## the mount traverse to meet it. INF when the sky is clear.
func _contact_bearing() -> float:
	var best := INF
	var best_d := _range
	for child in _main.get_planes():
		if child is PlaneUnit and child.phase == PlaneUnit.Phase.FLYING:
			var to: Vector2 = child.global_position - global_position
			var d: float = to.length()
			if d < best_d:
				best_d = d
				best = to.angle()
	return best


## Hold the current bird until it dies, leaves, or the lock expires; only then
## look for a new one. This is what makes the aim wedge worth reading.
func _acquire_target() -> PlaneUnit:
	if _lock_timer > 0.0 and _is_engageable(_locked):
		return _locked
	_locked = _nearest_plane()
	_lock_timer = GameConfig.TURRET_TARGET_LOCK_TIME if _locked != null else 0.0
	return _locked


func _is_engageable(plane: PlaneUnit) -> bool:
	if plane == null or not is_instance_valid(plane) or plane.is_queued_for_deletion():
		return false
	if plane.phase != PlaneUnit.Phase.FLYING:
		return false
	var to: Vector2 = plane.global_position - global_position
	if to.length() > _range:
		return false
	if _angle_outside_sector(to.angle()):
		return false
	return not _shot_hits_keep(plane.global_position)


func _nearest_plane() -> PlaneUnit:
	var best: PlaneUnit = null
	var best_d := _range
	for child in _main.get_planes():
		if child is PlaneUnit and child.phase == PlaneUnit.Phase.FLYING:
			var to: Vector2 = child.global_position - global_position
			var d: float = to.length()
			if d >= best_d:
				continue
			# Skip planes we can't bring the barrel onto (deep in the keep wedge)
			# or whose shot line would punch through the keep.
			if _angle_outside_sector(to.angle()):
				continue
			if _shot_hits_keep(child.global_position):
				continue
			best_d = d
			best = child
	return best


func _barrel_world_angle() -> float:
	return barrel.rotation - BARREL_ART_OFFSET


## Where the bird will be when a bullet fired now would reach it. One pass is
## plenty at these speeds and keeps the miss margin readable rather than exact.
func _lead_point(plane: PlaneUnit) -> Vector2:
	var flight := global_position.distance_to(plane.global_position) / GameConfig.BULLET_SPEED
	return plane.global_position + plane.current_velocity() * flight * LEAD_FACTOR


## Outside this gun's sector — another corner's problem, not worth tracking.
func _angle_outside_sector(world_angle: float) -> bool:
	return abs(angle_difference(_sector_center, world_angle)) > ARC_SPAN * 0.5 + TRACK_SLACK


## True if the segment turret → target intersects the keep disc.
func _shot_hits_keep(target_pos: Vector2) -> bool:
	var a := global_position
	var b := target_pos
	var c := _keep_center
	var r := GameConfig.KEEP_RADIUS * 0.75
	var ab := b - a
	var ab_len_sq := ab.length_squared()
	if ab_len_sq < 0.001:
		return true
	var t := clampf((c - a).dot(ab) / ab_len_sq, 0.0, 1.0)
	return (a + ab * t).distance_to(c) < r


## Unsigned CCW delta from → to, in [0, TAU).
func _ccw_delta(from_a: float, to_a: float) -> float:
	var d := angle_difference(from_a, to_a)
	if d < 0.0:
		d += TAU
	return d


## Map a world aim into [0, ARC_SPAN] along the allowed arc (clamps if inside wedge).
func _world_to_arc(world_angle: float) -> float:
	var t := _ccw_delta(_arc_start, world_angle)
	if t <= ARC_SPAN:
		return t
	# Outside the sector: snap to whichever edge is nearer.
	var past_edge := t - ARC_SPAN
	if past_edge < (TAU - t):
		return ARC_SPAN
	return 0.0


func _arc_to_world(arc_t: float) -> float:
	return _arc_start + clampf(arc_t, 0.0, ARC_SPAN)


func _rotate_barrel_toward(desired_world: float, delta: float) -> void:
	# Move in arc-parameter space so we never traverse the keep-facing wedge.
	var cur_t := _world_to_arc(_barrel_world_angle())
	var dst_t := _world_to_arc(desired_world)
	var max_step := GameConfig.TURRET_TRAVERSE_SPEED * delta
	var next_t := cur_t + clampf(dst_t - cur_t, -max_step, max_step)
	barrel.rotation = _arc_to_world(next_t) + BARREL_ART_OFFSET


func _fire(aim_angle: float) -> void:
	var bullet_scene: PackedScene = preload("res://scenes/bullet.tscn")
	var bullet: Bullet = bullet_scene.instantiate()
	var muzzle := global_position + Vector2.RIGHT.rotated(aim_angle) * 28.0
	_main.register_bullet(bullet)
	bullet.setup(muzzle, aim_angle)


## --- Threat readout (see scripts/threat_overlay.gd) ---

func threat_aim() -> float:
	return _barrel_world_angle()


func threat_range() -> float:
	return _range


func threat_color() -> Color:
	return PAD_COLOR


func threat_locked() -> bool:
	return _is_engageable(_locked)


## The whole sector this gun can ever cover — drawn faintly so the gaps between
## sectors (and the hole a silenced gun leaves) are visible at a glance.
func threat_sector_center() -> float:
	return _sector_center


func threat_sector_span() -> float:
	return ARC_SPAN


func take_damage(amount: int) -> void:
	if _dead:
		return
	hp = max(hp - amount, 0)
	_update_hp_bar()
	barrel.modulate = Color(1.0, 0.5, 0.5)
	var tw := create_tween()
	tw.tween_property(barrel, "modulate", Color.WHITE, 0.2)
	if hp <= 0:
		_die()


func _die() -> void:
	_dead = true
	destroyed.emit(global_position)
	visible = false
	set_process(false)


func is_destroyed() -> bool:
	return _dead


func reset() -> void:
	_dead = false
	_locked = null
	_lock_timer = 0.0
	_sector_center = _home_center
	_arc_start = _sector_center - ARC_SPAN * 0.5
	hp = max_hp
	visible = true
	set_process(true)
	if barrel:
		barrel.modulate = Color.WHITE
	_update_hp_bar()


func _update_hp_bar() -> void:
	if hp_bar:
		hp_bar.max_value = max_hp
		hp_bar.value = hp
		hp_bar.visible = hp < max_hp and not _dead
