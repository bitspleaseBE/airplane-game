class_name FlakShell
extends Node2D

## AA flak shell: flies to a pre-computed burst point and detonates there,
## downing every plane inside the burst radius. No contact fuse — the danger
## is the airburst, which punishes tight swarms.

var velocity: Vector2 = Vector2.ZERO
var _burst_at: Vector2 = Vector2.ZERO
var _main: Node2D


func setup(pos: Vector2, burst_pos: Vector2, main_ref: Node2D) -> void:
	global_position = pos
	_burst_at = burst_pos
	_main = main_ref
	var dir := (burst_pos - pos).normalized()
	velocity = dir * GameConfig.FLAK_SHELL_SPEED
	rotation = dir.angle()


func _physics_process(delta: float) -> void:
	var step := velocity * delta
	# Burst when we reach (or would overshoot) the fuse point.
	if step.length() >= global_position.distance_to(_burst_at):
		global_position = _burst_at
		_burst()
		return
	global_position += step


func _burst() -> void:
	if _main and is_instance_valid(_main):
		if _main.has_method("get_planes"):
			for child in _main.get_planes():
				if child is PlaneUnit and child.phase == PlaneUnit.Phase.FLYING:
					if child.global_position.distance_to(global_position) <= GameConfig.FLAK_BURST_RADIUS:
						child.take_hit()
		if _main.has_method("spawn_flak_burst"):
			_main.spawn_flak_burst(global_position)
	queue_free()
