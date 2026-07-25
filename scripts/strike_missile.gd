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
	var back := velocity.normalized() * 12.0
	var parent: Node = null
	if _main and is_instance_valid(_main):
		parent = _main.get_node_or_null("Effects")
	if parent == null:
		parent = get_tree().current_scene

	# Bright exhaust streak so the missile reads against the ocean.
	var streak := Line2D.new()
	streak.points = PackedVector2Array([global_position, global_position - back * 1.6])
	streak.width = 4.0
	streak.default_color = Color(1.0, 0.75, 0.35, 0.85)
	streak.z_index = 6
	streak.begin_cap_mode = Line2D.LINE_CAP_ROUND
	streak.end_cap_mode = Line2D.LINE_CAP_ROUND
	parent.add_child(streak)
	var tw_s := streak.create_tween()
	tw_s.tween_property(streak, "modulate:a", 0.0, 0.22)
	tw_s.parallel().tween_property(streak, "width", 1.0, 0.22)
	tw_s.tween_callback(streak.queue_free)

	var puff := Sprite2D.new()
	puff.texture = FxAtlas.smoke_frame(randi_range(0, 8))
	puff.global_position = global_position - back
	puff.scale = Vector2(0.12, 0.12)
	puff.modulate = Color(1.0, 0.88, 0.65, 0.7)
	puff.z_index = 5
	parent.add_child(puff)
	var tw := puff.create_tween()
	tw.tween_property(puff, "modulate:a", 0.0, 0.35)
	tw.parallel().tween_property(puff, "scale", Vector2(0.24, 0.24), 0.35)
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
