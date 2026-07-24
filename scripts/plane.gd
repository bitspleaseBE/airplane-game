class_name PlaneUnit
extends Area2D

## One aircraft of the squadron. The airframe (type) is bound to the level band:
## GUNSHIP strafes with its nose gun, BOMBER drops one heavy bomb, STRIKE fires
## a guided missile from standoff, CARPET lays three bombs in a line.

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
var _slow_timer: float = 0.0

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
	target = keep_pos
	_main = main_ref
	type = plane_type
	match type:
		GameConfig.PlaneType.STRIKE:
			speed = GameConfig.PLANE_SPEED * GameConfig.STRIKE_SPEED_MULT
		GameConfig.PlaneType.CARPET:
			speed = GameConfig.PLANE_SPEED * GameConfig.CARPET_SPEED_MULT
	if sprite:
		sprite.modulate = GameConfig.PLANE_TYPE_TINTS[type]
	# Sprite faces +X in Kenney pack
	rotation = (target - global_position).angle()


func _ready() -> void:
	add_to_group("planes")
	collision_layer = 2
	collision_mask = 4
	monitoring = true
	monitorable = true
	scale = Vector2.ONE * GameConfig.PLANE_SCALE
	area_entered.connect(_on_area_entered)


func _physics_process(delta: float) -> void:
	_slow_timer = max(_slow_timer - delta, 0.0)
	match phase:
		Phase.FLYING:
			_fly(delta)
		Phase.SIZZLING:
			_sizzle(delta)
		Phase.EXITING:
			_exit(delta)


## Smoke screens re-apply this every frame a plane is inside the haze.
func apply_smoke_slow() -> void:
	_slow_timer = 0.3


func current_velocity() -> Vector2:
	if phase != Phase.FLYING:
		return Vector2.ZERO
	return Vector2.from_angle(rotation) * _effective_speed()


func _effective_speed() -> float:
	if _slow_timer > 0.0:
		return speed * GameConfig.SMOKE_SLOW_FACTOR
	return speed


func _fly(delta: float) -> void:
	if _carpet_run:
		_carpet_pass(delta)
		return

	var dir := (target - global_position).normalized()
	global_position += dir * _effective_speed() * delta
	rotation = dir.angle()
	shadow.position = Vector2(8, 10)
	var dist := global_position.distance_to(target)

	match type:
		GameConfig.PlaneType.GUNSHIP:
			if dist <= GameConfig.GUNSHIP_STRAFE_RANGE and _shots_left > 0:
				_shot_timer -= delta
				if _shot_timer <= 0.0:
					_shot_timer = GameConfig.GUNSHIP_SHOT_INTERVAL
					_fire_gun()
			# Fly over the fort, then peel off.
			if dist <= GameConfig.PLANE_BOMB_RADIUS * 0.6:
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
			if dist <= GameConfig.PLANE_BOMB_RADIUS:
				_carpet_run = true
				_carpet_dir = dir
				_bomb_timer = 0.0


## Straight run across the fort, laying bombs at fixed intervals.
func _carpet_pass(delta: float) -> void:
	global_position += _carpet_dir * _effective_speed() * delta
	rotation = _carpet_dir.angle()
	_bomb_timer -= delta
	if _bombs_left > 0 and _bomb_timer <= 0.0:
		_bomb_timer = GameConfig.CARPET_BOMB_INTERVAL
		_bombs_left -= 1
		bomb_dropped = true
		if _main and _main.has_method("apply_bomb_at"):
			_main.apply_bomb_at(global_position, GameConfig.CARPET_BOMB_DAMAGE)
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
		_main.launch_strike_missile(global_position, rotation, target)


func _drop_bomb() -> void:
	bomb_dropped = true
	if _main and _main.has_method("apply_bomb_at"):
		_main.apply_bomb_at(global_position, GameConfig.KEEP_BOMB_DAMAGE)


func _begin_exit(dir: Vector2) -> void:
	phase = Phase.EXITING
	_exit_dir = dir if dir.length_squared() > 0.001 else Vector2.RIGHT
	_exit_time = 0.0


func _exit(delta: float) -> void:
	_exit_time += delta
	global_position += _exit_dir * _effective_speed() * 1.15 * delta
	rotation = _exit_dir.angle()
	# Leave the playfield, then despawn (distance, off-screen, or timeout safety).
	if (
		global_position.distance_to(target) > 700.0
		or not _is_roughly_on_screen()
		or _exit_time > 4.0
	):
		_finish(true)


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
	finished.emit(delivered)
	queue_free()


func _on_area_entered(area: Area2D) -> void:
	if area.is_in_group("bullets"):
		take_hit()
		area.queue_free()
