class_name FallingBomb
extends Node2D

## Gravity drop from a bomber (or carpet stick). Detonates on the ground target
## so the boom reads after the release, not as a blink at the wing.

const FALL_SPEED := 320.0
const ARC_HEIGHT := 48.0

var _start: Vector2 = Vector2.ZERO
var _target: Vector2 = Vector2.ZERO
var _damage: int = GameConfig.KEEP_BOMB_DAMAGE
var _main: Node2D
var _t: float = 0.0
var _duration: float = 0.35
var _resolved: bool = false

@onready var sprite: Sprite2D = $Sprite


func setup(from_pos: Vector2, target_pos: Vector2, damage: int, main_ref: Node2D) -> void:
	_start = from_pos
	_target = target_pos
	_damage = damage
	_main = main_ref
	global_position = from_pos
	var dist := from_pos.distance_to(target_pos)
	_duration = clampf(dist / FALL_SPEED, 0.22, 0.55)
	_t = 0.0
	rotation = (target_pos - from_pos).angle() + PI * 0.5


func _physics_process(delta: float) -> void:
	if _resolved:
		return
	_t += delta / _duration
	var u := clampf(_t, 0.0, 1.0)
	# Straight glide with a slight arc so the drop reads in the air.
	var pos := _start.lerp(_target, u)
	pos.y += -sin(u * PI) * ARC_HEIGHT
	global_position = pos
	if sprite:
		sprite.rotation = sin(u * TAU * 2.0) * 0.15
	if u >= 1.0:
		_detonate()


func _detonate() -> void:
	if _resolved:
		return
	_resolved = true
	if _main and is_instance_valid(_main):
		if _main.has_method("apply_bomb_at"):
			_main.apply_bomb_at(_target, _damage)
		if _main.has_method("ordnance_resolved"):
			_main.ordnance_resolved()
	queue_free()
