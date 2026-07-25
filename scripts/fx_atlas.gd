class_name FxAtlas
extends RefCounted

## Preloaded VFX frames — avoid sync load() on every boom / smoke puff.

const EXPLOSION: Array[Texture2D] = [
	preload("res://assets/effects/explosion/explosion_00.png"),
	preload("res://assets/effects/explosion/explosion_01.png"),
	preload("res://assets/effects/explosion/explosion_02.png"),
	preload("res://assets/effects/explosion/explosion_03.png"),
	preload("res://assets/effects/explosion/explosion_04.png"),
	preload("res://assets/effects/explosion/explosion_05.png"),
	preload("res://assets/effects/explosion/explosion_06.png"),
	preload("res://assets/effects/explosion/explosion_07.png"),
	preload("res://assets/effects/explosion/explosion_08.png"),
]

const SMOKE: Array[Texture2D] = [
	preload("res://assets/effects/smoke/smoke_00.png"),
	preload("res://assets/effects/smoke/smoke_01.png"),
	preload("res://assets/effects/smoke/smoke_02.png"),
	preload("res://assets/effects/smoke/smoke_03.png"),
	preload("res://assets/effects/smoke/smoke_04.png"),
	preload("res://assets/effects/smoke/smoke_05.png"),
	preload("res://assets/effects/smoke/smoke_06.png"),
	preload("res://assets/effects/smoke/smoke_07.png"),
	preload("res://assets/effects/smoke/smoke_08.png"),
	preload("res://assets/effects/smoke/smoke_09.png"),
	preload("res://assets/effects/smoke/smoke_10.png"),
	preload("res://assets/effects/smoke/smoke_11.png"),
	preload("res://assets/effects/smoke/smoke_12.png"),
]


static func smoke_frame(idx: int = -1) -> Texture2D:
	if SMOKE.is_empty():
		return null
	if idx < 0:
		idx = randi_range(0, SMOKE.size() - 1)
	return SMOKE[clampi(idx, 0, SMOKE.size() - 1)]
