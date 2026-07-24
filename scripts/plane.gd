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


func _apply_type_look() -> void:
	if sprite == null:
		return
	sprite.modulate = GameConfig.PLANE_TYPE_TINTS[type]
	sprite.scale = GameConfig.PLANE_TYPE_SPRITE_SCALES[type]


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
		Phase.SIZZLING:
			_sizzle(delta)
		Phase.EXITING:
			_exit(delta)


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
	shadow.position = Vector2(8, 10)
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
	_bomb_timer -= delta
	if _bombs_left > 0 and _bomb_timer <= 0.0:
		_bomb_timer = GameConfig.CARPET_BOMB_INTERVAL
		_bombs_left -= 1
		bomb_dropped = true
		var along := (float(_carpet_stick) - 1.0) * GameConfig.CARPET_BOMB_SPACING
		var blast_pos := _keep_pos - _carpet_dir * along
		_carpet_stick += 1
		if _main and _main.has_method("launch_bomb"):
			_main.launch_bomb(global_position, blast_pos, GameConfig.CARPET_BOMB_DAMAGE)
		elif _main and _main.has_method("apply_bomb_at"):
			_main.apply_bomb_at(blast_pos, GameConfig.CARPET_BOMB_DAMAGE)
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
	# Fall onto the keep so the boom lands after the release, not as a blink.
	if _main and _main.has_method("launch_bomb"):
		_main.launch_bomb(global_position, _keep_pos, GameConfig.KEEP_BOMB_DAMAGE)
	elif _main and _main.has_method("apply_bomb_at"):
		_main.apply_bomb_at(_keep_pos, GameConfig.KEEP_BOMB_DAMAGE)


func _begin_exit(dir: Vector2) -> void:
	phase = Phase.EXITING
	_exit_dir = dir if dir.length_squared() > 0.001 else Vector2.RIGHT
	_exit_time = 0.0


func _exit(delta: float) -> void:
	_exit_time += delta
	global_position += _exit_dir * speed * 1.15 * delta
	rotation = _exit_dir.angle()
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
		_smoke_timer = 0.08
		_emit_smoke_puff()

	if modulate.a <= 0.05 or scale.x < 0.35:
		exploded.emit(global_position)
		_finish(false)


func _emit_smoke_puff() -> void:
	# Lightweight: spawn a temporary sprite from smoke frames
	var puff := Sprite2D.new()
	var idx := randi_range(0, 8)
	var path := "res://assets/effects/smoke/smoke_%02d.png" % idx
	if ResourceLoader.exists(path):
		puff.texture = load(path)
	puff.global_position = global_position
	puff.scale = Vector2(0.12, 0.12)
	puff.modulate = Color(1, 1, 1, 0.7)
	puff.z_index = 5
	var parent := get_parent().get_parent().get_node_or_null("Effects")
	if parent:
		parent.add_child(puff)
	else:
		get_tree().current_scene.add_child(puff)
	var tw := puff.create_tween()
	tw.tween_property(puff, "modulate:a", 0.0, 0.45)
	tw.parallel().tween_property(puff, "scale", Vector2(0.25, 0.25), 0.45)
	tw.tween_callback(puff.queue_free)


func _finish(delivered: bool) -> void:
	# queue_free is deferred to end-of-frame; without this guard, exit/sizzle
	# can emit finished again and under-count active_planes → false lose.
	if _done:
		return
	_done = true
	set_physics_process(false)
	# Mark deletion before emitting so squadron-spent checks skip this bird.
	queue_free()
	finished.emit(delivered)


func is_spent() -> bool:
	return _done or is_queued_for_deletion()


func _on_area_entered(area: Area2D) -> void:
	if area.is_in_group("bullets"):
		take_hit()
		area.queue_free()
