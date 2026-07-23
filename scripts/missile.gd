class_name Missile
extends Area2D

## Homing AA missile fired by outer defense towers.

var velocity: Vector2 = Vector2.ZERO
var lifetime: float = GameConfig.MISSILE_LIFETIME
var _target: PlaneUnit
var _main: Node2D
var _smoke_timer: float = 0.0


func setup(pos: Vector2, angle: float, target: PlaneUnit, main_ref: Node2D) -> void:
	global_position = pos
	rotation = angle
	velocity = Vector2.RIGHT.rotated(angle) * GameConfig.MISSILE_SPEED
	_target = target
	_main = main_ref


func _ready() -> void:
	add_to_group("bullets")
	collision_layer = 4
	collision_mask = 2
	area_entered.connect(_on_area_entered)


func _physics_process(delta: float) -> void:
	if is_instance_valid(_target) and _target.phase == PlaneUnit.Phase.FLYING:
		var desired := (_target.global_position - global_position).normalized()
		var current := velocity.normalized()
		var blended := current.lerp(desired, clampf(GameConfig.MISSILE_TURN_RATE * delta, 0.0, 1.0)).normalized()
		velocity = blended * GameConfig.MISSILE_SPEED
		rotation = velocity.angle()
	else:
		_target = null

	global_position += velocity * delta
	lifetime -= delta
	_smoke_timer -= delta
	if _smoke_timer <= 0.0:
		_smoke_timer = 0.06
		_emit_trail()

	if lifetime <= 0.0:
		_impact(false)
		return
	if global_position.distance_to(GameConfig.ISLAND_CENTER) > 1000.0:
		queue_free()


func _emit_trail() -> void:
	var puff := Sprite2D.new()
	var idx := randi_range(0, 8)
	var path := "res://assets/effects/smoke/smoke_%02d.png" % idx
	if ResourceLoader.exists(path):
		puff.texture = load(path)
	puff.global_position = global_position - velocity.normalized() * 8.0
	puff.scale = Vector2(0.08, 0.08)
	puff.modulate = Color(1, 1, 1, 0.55)
	puff.z_index = 5
	var parent: Node = null
	if _main and is_instance_valid(_main):
		parent = _main.get_node_or_null("Effects")
	if parent:
		parent.add_child(puff)
	else:
		get_tree().current_scene.add_child(puff)
	var tw := puff.create_tween()
	tw.tween_property(puff, "modulate:a", 0.0, 0.35)
	tw.parallel().tween_property(puff, "scale", Vector2(0.16, 0.16), 0.35)
	tw.tween_callback(puff.queue_free)


func _on_area_entered(area: Area2D) -> void:
	if area is PlaneUnit:
		area.take_hit()
		_impact(true)


func _impact(hit: bool) -> void:
	if hit and _main and _main.has_method("_spawn_explosion"):
		_main._spawn_explosion(global_position, 0.7, _main.Boom.BOMB)
	queue_free()
