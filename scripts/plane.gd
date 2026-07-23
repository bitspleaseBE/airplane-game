class_name PlaneUnit
extends Area2D

## Bomber that flies toward the keep, drops a bomb if it survives, then exits.

signal finished(delivered_bomb: bool)
signal exploded(pos: Vector2)

enum Phase { FLYING, SIZZLING, EXITING }

var phase: Phase = Phase.FLYING
var speed: float = GameConfig.PLANE_SPEED
var target: Vector2 = GameConfig.ISLAND_CENTER
var bomb_dropped: bool = false
var _main: Node2D
var _smoke_timer: float = 0.0
var _spin: float = 0.0
var _exit_dir: Vector2 = Vector2.RIGHT
var _exit_time: float = 0.0

@onready var sprite: Sprite2D = $Sprite
@onready var shadow: Sprite2D = $Shadow
@onready var collision: CollisionShape2D = $CollisionShape2D


func setup(spawn_pos: Vector2, keep_pos: Vector2, main_ref: Node2D) -> void:
	global_position = spawn_pos
	target = keep_pos
	_main = main_ref
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
	match phase:
		Phase.FLYING:
			_fly(delta)
		Phase.SIZZLING:
			_sizzle(delta)
		Phase.EXITING:
			_exit(delta)


func _fly(delta: float) -> void:
	var dir := (target - global_position).normalized()
	global_position += dir * speed * delta
	rotation = dir.angle()
	shadow.position = Vector2(8, 10)

	if not bomb_dropped and global_position.distance_to(target) <= GameConfig.PLANE_BOMB_RADIUS:
		_drop_bomb()
		_begin_exit(dir)


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
	global_position += _exit_dir * speed * 1.15 * delta
	rotation = _exit_dir.angle()
	# Leave the playfield, then despawn (distance, off-screen, or timeout safety).
	if (
		global_position.distance_to(GameConfig.ISLAND_CENTER) > 520.0
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
