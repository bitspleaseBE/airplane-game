class_name Sfx
extends RefCounted

## One-shot arcade SFX (Kenney CC0) + looping island ambience (BigSoundBank CC0).

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
const _AMBIENT_ISLAND: AudioStream = preload("res://assets/sfx/ambient_island.ogg")

## Ambient sits above one-shots so the island bed stays primary.
const AMBIENT_TARGET_DB := -14.0
const AMBIENT_FADE_IN_SEC := 2.8
const BOMB_DB := -24.0
const BIG_BOOM_DB := -20.0
const BIG_CRUNCH_DB := -26.0
const CRASH_DB := -28.0
const GUN_HIT_DB := -32.0


static func bomb(host: Node) -> void:
	_play(host, _CRUNCH.pick_random(), BOMB_DB, randf_range(0.92, 1.08))


static func big_boom(host: Node) -> void:
	_play(host, _LOW.pick_random(), BIG_BOOM_DB, randf_range(0.9, 1.05))
	_play(host, _CRUNCH.pick_random(), BIG_CRUNCH_DB, randf_range(0.75, 0.9))


static func plane_crash(host: Node) -> void:
	_play(host, _SOFT.pick_random(), CRASH_DB, randf_range(0.95, 1.15))


## Quick strafe impact tick — quiet, high pitch, so bursts don't drown the mix.
static func gun_hit(host: Node) -> void:
	_play(host, _SOFT.pick_random(), GUN_HIT_DB, randf_range(1.25, 1.45))


## Soft looping beach / birds bed under the siege.
static func start_island_ambient(host: Node) -> void:
	if host == null or _AMBIENT_ISLAND == null:
		return
	if host.has_node("IslandAmbient"):
		return

	var stream := _AMBIENT_ISLAND.duplicate()
	if stream is AudioStreamOggVorbis:
		(stream as AudioStreamOggVorbis).loop = true

	var player := AudioStreamPlayer.new()
	player.name = "IslandAmbient"
	player.stream = stream
	player.volume_db = -40.0
	host.add_child(player)
	player.play()

	var tween := host.create_tween()
	tween.tween_property(player, "volume_db", AMBIENT_TARGET_DB, AMBIENT_FADE_IN_SEC)


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
