class_name PlaneUnit
extends Area2D

## One aircraft of the squadron. The airframe (type) is bound to the level band:
## GUNSHIP hunts corner AA and strafes, BOMBER drops one heavy bomb, STRIKE fires
## a guided missile from standoff, CARPET lays three bombs along the keep track.

signal finished(delivered_bomb: bool)
signal exploded(pos: Vector2)

enum Phase { FLYING, SIZZLING, EXITING }

var phase: Phase = Phase.FLYING
var type: GameConfig.PlaneType = GameConfig.PlaneType.BOMBER
var speed: float = GameConfig.PLANE_SPEED
var target: Vector2 = GameConfig.ISLAND_CENTER
var bomb_dropped: bool = false
var _main: Node2D
var _smoke_timer: float = 0.0
var _spin: float = 0.0
var _exit_dir: Vector2 = Vector2.RIGHT
var _exit_time: float = 0.0
var _keep_pos: Vector2 = GameConfig.ISLAND_CENTER

# Soft fading contrail (world-space discs — never black smoke).
var _contrail_root: Node2D
var _contrail_points: PackedVector2Array = PackedVector2Array()
var _contrail_ages: PackedFloat32Array = PackedFloat32Array()
var _contrail_sample: float = 0.0
var _contrail_pool: Array[Polygon2D] = []
const CONTRAIL_LIFE := 0.5
const CONTRAIL_SAMPLE := 0.03

# Gunship strafing run
var _shots_left: int = GameConfig.GUNSHIP_SHOT_COUNT
var _shot_timer: float = 0.0
# Strike jet
var _missile_fired: bool = false
# Carpet run: locked heading + remaining bombs once the run starts
var _carpet_run: bool = false
var _carpet_dir: Vector2 = Vector2.RIGHT
var _bombs_left: int = GameConfig.CARPET_BOMB_COUNT
var _bomb_timer: float = 0.0
var _carpet_stick: int = 0
var _done: bool = false

@onready var sprite: Sprite2D = $Sprite
@onready var shadow: Sprite2D = $Shadow
@onready var collision: CollisionShape2D = $CollisionShape2D


func setup(
	spawn_pos: Vector2,
	keep_pos: Vector2,
	main_ref: Node2D,
	plane_type: GameConfig.PlaneType = GameConfig.PlaneType.BOMBER,
) -> void:
	global_position = spawn_pos
	_keep_pos = keep_pos
	_main = main_ref
	type = plane_type
	match type:
		GameConfig.PlaneType.GUNSHIP:
			speed = GameConfig.PLANE_SPEED * GameConfig.GUNSHIP_SPEED_MULT
		GameConfig.PlaneType.BOMBER:
			speed = GameConfig.PLANE_SPEED * GameConfig.BOMBER_SPEED_MULT
		GameConfig.PlaneType.STRIKE:
			speed = GameConfig.PLANE_SPEED * GameConfig.STRIKE_SPEED_MULT
		GameConfig.PlaneType.CARPET:
			speed = GameConfig.PLANE_SPEED * GameConfig.CARPET_SPEED_MULT
		_:
			speed = GameConfig.PLANE_SPEED
	target = _pick_target(keep_pos)
	_apply_type_look()
	# Sprite faces +X in Kenney pack
	rotation = (target - global_position).angle()


func _ready() -> void:
	add_to_group("planes")
	collision_layer = 2
	collision_mask = 4
	monitoring = true
	monitorable = true
	# Keep Area2D scale fixed so hitboxes stay fair across wing types.
	scale = Vector2.ONE * GameConfig.PLANE_SCALE
	_apply_type_look()
	area_entered.connect(_on_area_entered)
	_spawn_punch()


func _apply_type_look() -> void:
	if sprite == null:
		return
	sprite.modulate = GameConfig.PLANE_TYPE_TINTS[type]
	sprite.scale = GameConfig.PLANE_TYPE_SPRITE_SCALES[type]


func _spawn_punch() -> void:
	## Brief scramble pop so each deploy reads on the water.
	if sprite == null:
		return
	var base := sprite.scale
	var tint: Color = GameConfig.PLANE_TYPE_TINTS[type]
	sprite.scale = base * 0.55
	sprite.modulate = Color(1.4, 1.4, 1.25, 0.4)
	var tw := create_tween()
	tw.tween_property(sprite, "scale", base * 1.14, 0.09).set_ease(Tween.EASE_OUT)
	tw.parallel().tween_property(sprite, "modulate", Color(1.25, 1.25, 1.1, 1.0), 0.09)
	tw.tween_property(sprite, "scale", base, 0.1)
	tw.parallel().tween_property(sprite, "modulate", tint, 0.12)


func _pick_target(keep_pos: Vector2) -> Vector2:
	# Gunships soft corner AA with the first shots, then finish on the keep
	# so SEAD doesn't starve the objective.
	if type == GameConfig.PlaneType.GUNSHIP and _shots_left > 2:
		if _main and _main.has_method("get_gunship_target"):
			return _main.get_gunship_target(global_position)
	return keep_pos


func _physics_process(delta: float) -> void:
	match phase:
		Phase.FLYING:
			_fly(delta)
			_update_contrail(delta, true)
		Phase.SIZZLING:
			_sizzle(delta)
			_update_contrail(delta, false)
		Phase.EXITING:
			_exit(delta)
			_update_contrail(delta, true)


func current_velocity() -> Vector2:
	if phase != Phase.FLYING:
		return Vector2.ZERO
	return Vector2.from_angle(rotation) * speed


func _fly(delta: float) -> void:
	if _carpet_run:
		_carpet_pass(delta)
		return

	if type == GameConfig.PlaneType.GUNSHIP and _shots_left > 0:
		_retarget_gunship()

	var dir := (target - global_position).normalized()
	global_position += dir * speed * delta
	rotation = dir.angle()
	shadow.position = Vector2(14, 18)
	var dist := global_position.distance_to(target)
	var keep_dist := global_position.distance_to(_keep_pos)

	match type:
		GameConfig.PlaneType.GUNSHIP:
			if dist <= GameConfig.GUNSHIP_STRAFE_RANGE and _shots_left > 0:
				_shot_timer -= delta
				if _shot_timer <= 0.0:
					_shot_timer = GameConfig.GUNSHIP_SHOT_INTERVAL
					_fire_gun()
			# Magazine spent, or overflew the fort — peel off.
			if _shots_left <= 0 or keep_dist <= GameConfig.PLANE_BOMB_RADIUS * 0.6:
				_begin_exit(dir)
		GameConfig.PlaneType.BOMBER:
			if not bomb_dropped and dist <= GameConfig.PLANE_BOMB_RADIUS:
				_drop_bomb()
				_begin_exit(dir)
		GameConfig.PlaneType.STRIKE:
			if not _missile_fired and dist <= GameConfig.STRIKE_STANDOFF:
				_fire_strike_missile()
				# Bank away hard — the missile does the rest.
				var bank := 2.1 if randf() < 0.5 else -2.1
				_begin_exit(dir.rotated(bank))
		GameConfig.PlaneType.CARPET:
			if keep_dist <= GameConfig.CARPET_START_RANGE:
				_carpet_run = true
				_carpet_dir = (_keep_pos - global_position).normalized()
				if _carpet_dir.length_squared() < 0.001:
					_carpet_dir = dir
				_bomb_timer = 0.0
				_carpet_stick = 0


func _retarget_gunship() -> void:
	## Keep hunting living guns; once the nest is quiet, swing to the keep.
	target = _pick_target(_keep_pos)


## Straight run across the fort; sticks land on the keep track (not random dirt).
func _carpet_pass(delta: float) -> void:
	global_position += _carpet_dir * speed * delta
	rotation = _carpet_dir.angle()
	shadow.position = Vector2(14, 18)
	_bomb_timer -= delta
	if _bombs_left > 0 and _bomb_timer <= 0.0:
		_bomb_timer = GameConfig.CARPET_BOMB_INTERVAL
		_bombs_left -= 1
		bomb_dropped = true
		var along := (float(_carpet_stick) - 1.0) * GameConfig.CARPET_BOMB_SPACING
		var blast_pos := _keep_pos - _carpet_dir * along
		_carpet_stick += 1
		_release_ordnance(blast_pos, GameConfig.CARPET_BOMB_DAMAGE)
	if _bombs_left <= 0:
		_begin_exit(_carpet_dir)


func _fire_gun() -> void:
	_shots_left -= 1
	bomb_dropped = true  # payload delivered (for finished-signal semantics)
	if _main and _main.has_method("apply_gunfire"):
		var jitter := Vector2(
			randf_range(-GameConfig.GUNSHIP_SHOT_JITTER, GameConfig.GUNSHIP_SHOT_JITTER),
			randf_range(-GameConfig.GUNSHIP_SHOT_JITTER, GameConfig.GUNSHIP_SHOT_JITTER)
		)
		_main.apply_gunfire(global_position, target + jitter, GameConfig.GUNSHIP_SHOT_DAMAGE)


func _fire_strike_missile() -> void:
	_missile_fired = true
	bomb_dropped = true
	if _main and _main.has_method("launch_strike_missile"):
		_main.launch_strike_missile(global_position, rotation, _keep_pos)


func _drop_bomb() -> void:
	bomb_dropped = true
	_release_ordnance(global_position, GameConfig.KEEP_BOMB_DAMAGE)


func _release_ordnance(blast_pos: Vector2, damage: int) -> void:
	## Visual-only release flash — damage still hits immediately (no delayed bomb).
	if _main and _main.has_method("spawn_bomb_release"):
		_main.spawn_bomb_release(global_position, blast_pos)
	if _main and _main.has_method("apply_bomb_at"):
		_main.apply_bomb_at(blast_pos, damage)


func _begin_exit(dir: Vector2) -> void:
	phase = Phase.EXITING
	_exit_dir = dir if dir.length_squared() > 0.001 else Vector2.RIGHT
	_exit_time = 0.0


func _exit(delta: float) -> void:
	_exit_time += delta
	global_position += _exit_dir * speed * 1.15 * delta
	rotation = _exit_dir.angle()
	shadow.position = Vector2(14, 18)
	# Leave the playfield, then despawn (distance, off-screen, or timeout safety).
	if (
		global_position.distance_to(_keep_pos) > 700.0
		or not _is_roughly_on_screen()
		or _exit_time > 4.0
	):
		_finish(bomb_dropped)


func _is_roughly_on_screen() -> bool:
	var margin := 80.0
	var screen_pos := get_viewport().get_canvas_transform() * global_position
	var size := get_viewport_rect().size
	return (
		screen_pos.x > -margin
		and screen_pos.y > -margin
		and screen_pos.x < size.x + margin
		and screen_pos.y < size.y + margin
	)


func take_hit() -> void:
	if phase != Phase.FLYING:
		return
	phase = Phase.SIZZLING
	_spin = randf_range(-6.0, 6.0)
	collision.set_deferred("disabled", true)
	modulate = Color(1.0, 0.7, 0.5)


func _sizzle(delta: float) -> void:
	_spin += delta
	rotation += _spin * delta * 3.0
	global_position += Vector2.DOWN.rotated(rotation) * 40.0 * delta
	global_position += Vector2(cos(rotation), sin(rotation)) * speed * 0.35 * delta
	# Shrink / fade
	scale = scale.lerp(Vector2(0.4, 0.4), delta * 1.5)
	modulate.a = max(modulate.a - delta * 0.6, 0.0)

	_smoke_timer -= delta
	if _smoke_timer <= 0.0:
		_smoke_timer = 0.06
		_emit_crash_smoke()

	if modulate.a <= 0.05 or scale.x < 0.35:
		exploded.emit(global_position)
		_finish(false)


func _effects_parent() -> Node:
	if _main and is_instance_valid(_main):
		var under_main: Node = _main.get_node_or_null("Effects")
		if under_main:
			return under_main
	var under_scene: Node = get_parent().get_parent().get_node_or_null("Effects")
	if under_scene:
		return under_scene
	return get_tree().current_scene


func _ensure_contrail() -> void:
	if _contrail_root != null and is_instance_valid(_contrail_root):
		return
	var parent := _effects_parent()
	if parent == null:
		return
	_contrail_root = Node2D.new()
	# Effects layer is z 12; plane sprites render at 16 (Planes 8 + Sprite 8).
	# Keep the trail's effective z below every plane so planes fly over it.
	_contrail_root.z_index = 1
	_contrail_root.name = "Contrail"
	parent.add_child(_contrail_root)
	_contrail_pool.clear()
	var disc_budget := GameConfig.contrail_max_points
	var sides := 8 if GameConfig.is_constrained_quality() else 10
	for _i in disc_budget:
		var disc := Polygon2D.new()
		var pts := PackedVector2Array()
		for j in sides:
			var a := TAU * float(j) / float(sides)
			pts.append(Vector2(cos(a), sin(a)) * 5.0)
		disc.polygon = pts
		disc.visible = false
		_contrail_root.add_child(disc)
		_contrail_pool.append(disc)


## Pale age-fading discs — no black smoke on regular flight.
func _update_contrail(delta: float, growing: bool) -> void:
	_ensure_contrail()
	if _contrail_root == null:
		return

	var keep_pts := PackedVector2Array()
	var keep_ages := PackedFloat32Array()
	for i in _contrail_points.size():
		var age := _contrail_ages[i] + delta
		if age < CONTRAIL_LIFE:
			keep_pts.append(_contrail_points[i])
			keep_ages.append(age)
	_contrail_points = keep_pts
	_contrail_ages = keep_ages

	if growing:
		_contrail_sample -= delta
		if _contrail_sample <= 0.0:
			_contrail_sample = CONTRAIL_SAMPLE
			var tip := global_position + Vector2.LEFT.rotated(rotation) * 8.0
			_contrail_points.insert(0, tip)
			_contrail_ages.insert(0, 0.0)
			while _contrail_points.size() > GameConfig.contrail_max_points:
				_contrail_points.remove_at(_contrail_points.size() - 1)
				_contrail_ages.remove_at(_contrail_ages.size() - 1)

	var tint: Color = GameConfig.PLANE_TYPE_TINTS[type]
	var r := lerpf(1.0, tint.r, 0.3)
	var g := lerpf(1.0, tint.g, 0.28)
	var b := lerpf(1.0, tint.b, 0.2)
	for i in _contrail_pool.size():
		var disc: Polygon2D = _contrail_pool[i]
		if i >= _contrail_points.size():
			disc.visible = false
			continue
		var t: float = clampf(_contrail_ages[i] / CONTRAIL_LIFE, 0.0, 1.0)
		# Ease out so the tail thins and vanishes clearly.
		var fade := t * t
		disc.visible = true
		disc.global_position = _contrail_points[i]
		disc.scale = Vector2.ONE * lerpf(0.95, 0.15, fade)
		disc.color = Color(r, g, b, lerpf(0.34, 0.0, fade))


## Crash-only: Kenney smoke while sizzling down.
func _emit_crash_smoke() -> void:
	var parent := _effects_parent()
	if parent == null:
		return
	var puff := Sprite2D.new()
	puff.texture = FxAtlas.smoke_frame(randi_range(0, 8))
	puff.global_position = global_position + Vector2.LEFT.rotated(rotation) * 6.0
	puff.scale = Vector2(0.16, 0.16)
	puff.modulate = Color(0.35, 0.32, 0.3, 0.85)
	puff.z_index = 4
	parent.add_child(puff)
	var tw := puff.create_tween()
	tw.tween_property(puff, "modulate:a", 0.0, 0.55)
	tw.parallel().tween_property(puff, "scale", Vector2(0.34, 0.34), 0.55)
	tw.tween_callback(puff.queue_free)


func _clear_contrail() -> void:
	if _contrail_root != null and is_instance_valid(_contrail_root):
		_contrail_root.queue_free()
	_contrail_root = null
	_contrail_pool.clear()
	_contrail_points = PackedVector2Array()
	_contrail_ages = PackedFloat32Array()


func _finish(delivered: bool) -> void:
	# queue_free is deferred to end-of-frame; without this guard, exit/sizzle
	# can emit finished again and under-count active_planes → false lose.
	if _done:
		return
	_done = true
	set_physics_process(false)
	_clear_contrail()
	# Mark deletion before emitting so squadron-spent checks skip this bird.
	queue_free()
	finished.emit(delivered)


func is_spent() -> bool:
	return _done or is_queued_for_deletion()


func _on_area_entered(area: Area2D) -> void:
	if area.is_in_group("bullets"):
		take_hit()
		area.queue_free()
