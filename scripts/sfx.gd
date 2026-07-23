class_name Sfx
extends RefCounted

## One-shot arcade SFX (Kenney CC0). Spawns short-lived AudioStreamPlayers.

const _CRUNCH: Array[AudioStream] = [
	preload("res://assets/sfx/explosion_crunch_00.ogg"),
	preload("res://assets/sfx/explosion_crunch_01.ogg"),
	preload("res://assets/sfx/explosion_crunch_02.ogg"),
]
const _LOW: Array[AudioStream] = [
	preload("res://assets/sfx/explosion_low_00.ogg"),
	preload("res://assets/sfx/explosion_low_01.ogg"),
]
const _SOFT: Array[AudioStream] = [
	preload("res://assets/sfx/impact_soft_00.ogg"),
	preload("res://assets/sfx/impact_soft_01.ogg"),
]


static func bomb(host: Node) -> void:
	_play(host, _CRUNCH.pick_random(), -10.0, randf_range(0.92, 1.08))


static func big_boom(host: Node) -> void:
	_play(host, _LOW.pick_random(), -6.0, randf_range(0.9, 1.05))
	_play(host, _CRUNCH.pick_random(), -12.0, randf_range(0.75, 0.9))


static func plane_crash(host: Node) -> void:
	_play(host, _SOFT.pick_random(), -14.0, randf_range(0.95, 1.15))


static func _play(host: Node, stream: AudioStream, volume_db: float, pitch: float) -> void:
	if host == null or stream == null:
		return
	var player := AudioStreamPlayer.new()
	player.stream = stream
	player.volume_db = volume_db
	player.pitch_scale = pitch
	host.add_child(player)
	player.finished.connect(player.queue_free)
	player.play()
