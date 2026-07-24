extends Node2D

## Plays a short explosion animation then frees itself.

@onready var sprite: Sprite2D = $Sprite

var _frames: Array[Texture2D] = []
var _index: int = 0
var _timer: float = 0.0
const FRAME_TIME := 0.05


func _ready() -> void:
	for i in range(9):
		var path := "res://assets/effects/explosion/explosion_%02d.png" % i
		if ResourceLoader.exists(path):
			_frames.append(load(path))
	if _frames.is_empty():
		queue_free()
		return
	sprite.texture = _frames[0]
	sprite.scale = Vector2(0.0875, 0.0875)


func _process(delta: float) -> void:
	_timer += delta
	if _timer >= FRAME_TIME:
		_timer = 0.0
		_index += 1
		if _index >= _frames.size():
			queue_free()
			return
		sprite.texture = _frames[_index]
