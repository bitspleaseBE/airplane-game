class_name StrikeMissile
extends Node2D

## Air-to-ground guided missile fired by STRIKE-wing jets from standoff range.
## Homes on a fixed ground point, detonates as a bomb, and reports back to main
## so win/lose isn't decided while ordnance is still in the air.

var velocity: Vector2 = Vector2.ZERO
var lifetime: float = 5.0
var _target: Vector2 = Vector2.ZERO
var _main: Node2D
var _smoke_timer: float = 0.0
var _resolved: bool = false

@onready var sprite: Sprite2D = $Sprite


func setup(pos: Vector2, angle: float, target_pos: Vector2, main_ref: Node2D) -> void:
	global_position = pos
	rotation = angle
	velocity = Vector2.RIGHT.rotated(angle) * GameConfig.STRIKE_MISSILE_SPEED
	_target = target_pos
	_main = main_ref


func _physics_process(delta: float) -> void:
	var desired := (_target - global_position).normalized()
	var current := velocity.normalized()
	var blended := current.lerp(
		desired, clampf(GameConfig.STRIKE_MISSILE_TURN_RATE * delta, 0.0, 1.0)
	).normalized()
	velocity = blended * GameConfig.STRIKE_MISSILE_SPEED
	rotation = velocity.angle()
	global_position += velocity * delta

	_smoke_timer -= delta
	if _smoke_timer <= 0.0:
		_smoke_timer = 0.05
		_emit_trail()

	lifetime -= delta
	if global_position.distance_to(_target) <= 16.0 or lifetime <= 0.0:
		_detonate()


func _emit_trail() -> void:
	var puff := Sprite2D.new()
	var idx := randi_range(0, 8)
	var path := "res://assets/effects/smoke/smoke_%02d.png" % idx
	if ResourceLoader.exists(path):
		puff.texture = load(path)
	puff.global_position = global_position - velocity.normalized() * 10.0
	puff.scale = Vector2(0.09, 0.09)
	puff.modulate = Color(1.0, 0.92, 0.8, 0.6)
	puff.z_index = 5
	var parent: Node = null
	if _main and is_instance_valid(_main):
		parent = _main.get_node_or_null("Effects")
	if parent:
		parent.add_child(puff)
	else:
		get_tree().current_scene.add_child(puff)
	var tw := puff.create_tween()
	tw.tween_property(puff, "modulate:a", 0.0, 0.3)
	tw.parallel().tween_property(puff, "scale", Vector2(0.18, 0.18), 0.3)
	tw.tween_callback(puff.queue_free)


func _detonate() -> void:
	if _resolved:
		return
	_resolved = true
	if _main and is_instance_valid(_main):
		if _main.has_method("apply_bomb_at"):
			_main.apply_bomb_at(global_position, GameConfig.STRIKE_MISSILE_DAMAGE)
		if _main.has_method("ordnance_resolved"):
			_main.ordnance_resolved()
	queue_free()
