class_name Turret
extends Node2D

## Corner AA turret: tracks nearest plane and fires bullets.
## Barrel is limited to a 270° arc; the 90° wedge toward the keep is off-limits.
## Targeting also skips planes whose shot line would pass through the keep.

signal destroyed(pos: Vector2)

const BARREL_ART_OFFSET := PI * 0.5
const BLOCKED_HALF_ANGLE := PI * 0.25  # ±45° around keep = 90° forbidden wedge
const ARC_SPAN := PI * 1.5  # 270° allowed

var max_hp: int = GameConfig.TURRET_MAX_HP
var hp: int = GameConfig.TURRET_MAX_HP
var fire_cooldown: float = 0.0
var _main: Node2D
var _dead: bool = false
var _keep_center: Vector2 = GameConfig.ISLAND_CENTER
## World-space angle from this turret toward the keep (center of forbidden wedge).
var _blocked_center: float = 0.0
## CCW start of the allowed arc (one edge of the keep-facing wedge).
var _arc_start: float = 0.0

@onready var barrel: Sprite2D = $Barrel
@onready var base: Sprite2D = $Base
@onready var hp_bar: ProgressBar = $HpBar


func configure(main_ref: Node2D, keep_center: Vector2 = Vector2.ZERO) -> void:
	_main = main_ref
	_keep_center = keep_center if keep_center != Vector2.ZERO else (
		main_ref.active_center if main_ref and "active_center" in main_ref else GameConfig.ISLAND_CENTER
	)
	_blocked_center = (_keep_center - global_position).angle()
	# Allowed arc runs CCW from (blocked + 45°) across 270° to (blocked - 45°).
	_arc_start = _blocked_center + BLOCKED_HALF_ANGLE
	# Face outward (away from keep) — midpoint of the allowed arc.
	barrel.rotation = _arc_to_world(ARC_SPAN * 0.5) + BARREL_ART_OFFSET


func _ready() -> void:
	add_to_group("turrets")
	hp = max_hp
	_update_hp_bar()


func _process(delta: float) -> void:
	if _dead or _main == null:
		return
	if _main.state != _main.State.PLAYING:
		return

	fire_cooldown = max(fire_cooldown - delta, 0.0)
	var plane := _nearest_plane()
	if plane == null:
		return

	var to_plane: Vector2 = plane.global_position - global_position
	var desired_world := to_plane.angle()
	_rotate_barrel_toward(desired_world, delta)

	if to_plane.length() <= GameConfig.TURRET_RANGE and fire_cooldown <= 0.0:
		# Only fire when barrel is on the plane and the shot won't hit the keep.
		if not _shot_hits_keep(plane.global_position):
			var aim_world := _barrel_world_angle()
			# Compare against the clamped aim (barrel can't enter the keep wedge).
			var clamped := _arc_to_world(_world_to_arc(desired_world))
			if abs(angle_difference(aim_world, clamped)) < 0.4:
				_fire(clamped)
				fire_cooldown = GameConfig.TURRET_FIRE_COOLDOWN


func _nearest_plane() -> PlaneUnit:
	var best: PlaneUnit = null
	var best_d := GameConfig.TURRET_RANGE
	for child in _main.get_planes():
		if child is PlaneUnit and child.phase == PlaneUnit.Phase.FLYING:
			var to: Vector2 = child.global_position - global_position
			var d: float = to.length()
			if d >= best_d:
				continue
			# Skip planes we can't bring the barrel onto (deep in the keep wedge)
			# or whose shot line would punch through the keep.
			if _angle_deep_in_wedge(to.angle()):
				continue
			if _shot_hits_keep(child.global_position):
				continue
			best_d = d
			best = child
	return best


func _barrel_world_angle() -> float:
	return barrel.rotation - BARREL_ART_OFFSET


## Deep in the wedge (not just near the arc edge) — not worth tracking.
func _angle_deep_in_wedge(world_angle: float) -> bool:
	return abs(angle_difference(_blocked_center, world_angle)) < BLOCKED_HALF_ANGLE * 0.55


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
	# Inside the 90° forbidden wedge: snap to the nearer allowed edge.
	var into_wedge := t - ARC_SPAN
	if into_wedge < (TAU - t):
		return ARC_SPAN
	return 0.0


func _arc_to_world(arc_t: float) -> float:
	return _arc_start + clampf(arc_t, 0.0, ARC_SPAN)


func _rotate_barrel_toward(desired_world: float, delta: float) -> void:
	# Move in arc-parameter space so we never traverse the keep-facing wedge.
	var cur_t := _world_to_arc(_barrel_world_angle())
	var dst_t := _world_to_arc(desired_world)
	var max_step := GameConfig.TURRET_ROTATE_SPEED * delta
	var next_t := cur_t + clampf(dst_t - cur_t, -max_step, max_step)
	barrel.rotation = _arc_to_world(next_t) + BARREL_ART_OFFSET


func _fire(aim_angle: float) -> void:
	var bullet_scene: PackedScene = preload("res://scenes/bullet.tscn")
	var bullet: Bullet = bullet_scene.instantiate()
	var muzzle := global_position + Vector2.RIGHT.rotated(aim_angle) * 28.0
	_main.register_bullet(bullet)
	bullet.setup(muzzle, aim_angle)


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
