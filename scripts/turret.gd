class_name Turret
extends Node2D

## Corner AA turret: tracks nearest plane and fires bullets.

signal destroyed(pos: Vector2)

var max_hp: int = GameConfig.TURRET_MAX_HP
var hp: int = GameConfig.TURRET_MAX_HP
var fire_cooldown: float = 0.0
var _main: Node2D
var _dead: bool = false

@onready var barrel: Sprite2D = $Barrel
@onready var base: Sprite2D = $Base
@onready var hp_bar: ProgressBar = $HpBar


func configure(main_ref: Node2D) -> void:
	_main = main_ref


func _ready() -> void:
	add_to_group("turrets")
	hp = max_hp
	_update_hp_bar()


func _process(delta: float) -> void:
	if _dead or _main == null:
		return
	if _main.state != _main.State.PLAYING:
		return

	fire_cooldown = max(fire_cooldown - delta, 0.0)
	var plane := _nearest_plane()
	if plane == null:
		return

	var to_plane: Vector2 = plane.global_position - global_position
	# Kenney turret art faces up (-Y); offset so rotation 0 aims right in world space.
	var desired := to_plane.angle() + PI * 0.5
	barrel.rotation = lerp_angle(barrel.rotation, desired, GameConfig.TURRET_ROTATE_SPEED * delta)

	if to_plane.length() <= GameConfig.TURRET_RANGE and fire_cooldown <= 0.0:
		if abs(angle_difference(barrel.rotation, desired)) < 0.4:
			_fire(to_plane.angle())
			fire_cooldown = GameConfig.TURRET_FIRE_COOLDOWN


func _nearest_plane() -> PlaneUnit:
	var best: PlaneUnit = null
	var best_d := GameConfig.TURRET_RANGE
	for child in _main.get_planes():
		if child is PlaneUnit and child.phase == PlaneUnit.Phase.FLYING:
			var d: float = global_position.distance_to(child.global_position)
			if d < best_d:
				best_d = d
				best = child
	return best


func _fire(aim_angle: float) -> void:
	var bullet_scene: PackedScene = preload("res://scenes/bullet.tscn")
	var bullet: Bullet = bullet_scene.instantiate()
	var muzzle := global_position + Vector2.RIGHT.rotated(aim_angle) * 28.0
	_main.register_bullet(bullet)
	bullet.setup(muzzle, aim_angle)


func take_damage(amount: int) -> void:
	if _dead:
		return
	hp = max(hp - amount, 0)
	_update_hp_bar()
	barrel.modulate = Color(1.0, 0.5, 0.5)
	var tw := create_tween()
	tw.tween_property(barrel, "modulate", Color.WHITE, 0.2)
	if hp <= 0:
		_die()


func _die() -> void:
	_dead = true
	destroyed.emit(global_position)
	visible = false
	set_process(false)


func is_destroyed() -> bool:
	return _dead


func _update_hp_bar() -> void:
	if hp_bar:
		hp_bar.max_value = max_hp
		hp_bar.value = hp
		hp_bar.visible = hp < max_hp and not _dead
