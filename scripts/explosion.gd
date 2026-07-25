extends Node2D

## Plays a short explosion animation then frees itself.
## Base sprite scale is larger so bomb/crash tiers read on the open ocean.

@onready var sprite: Sprite2D = $Sprite

var _frames: Array[Texture2D] = []
var _index: int = 0
var _timer: float = 0.0
var _frame_time: float = 0.05
const BASE_SPRITE_SCALE := 0.14


func _ready() -> void:
	_frames = FxAtlas.EXPLOSION.duplicate()
	if _frames.is_empty():
		queue_free()
		return
	sprite.texture = _frames[0]
	sprite.scale = Vector2(BASE_SPRITE_SCALE, BASE_SPRITE_SCALE)
	# Bigger blasts linger a hair so the boom lands on the eye.
	if scale.x >= 1.8:
		_frame_time = 0.06
	_spawn_shock_ring()


func _process(delta: float) -> void:
	_timer += delta
	if _timer >= _frame_time:
		_timer = 0.0
		_index += 1
		if _index >= _frames.size():
			queue_free()
			return
		sprite.texture = _frames[_index]


func _spawn_shock_ring() -> void:
	## Expanding disc under the fireball — ground hits read without new art.
	var ring := Polygon2D.new()
	var pts := PackedVector2Array()
	var n := 20
	for i in n:
		var a := TAU * float(i) / float(n)
		pts.append(Vector2(cos(a), sin(a)) * 18.0)
	ring.polygon = pts
	ring.color = Color(1.0, 0.85, 0.45, 0.55)
	ring.z_index = -1
	add_child(ring)
	var tw := ring.create_tween()
	var grow := 2.4 + scale.x * 0.6
	tw.tween_property(ring, "scale", Vector2(grow, grow), 0.28).set_ease(Tween.EASE_OUT)
	tw.parallel().tween_property(ring, "color:a", 0.0, 0.28)
	tw.tween_callback(ring.queue_free)
