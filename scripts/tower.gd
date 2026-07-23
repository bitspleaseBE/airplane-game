class_name Tower
extends Node2D

## Smaller outer defense: machine gun or missile launcher.

signal destroyed(pos: Vector2)

enum Weapon { MACHINE_GUN, MISSILE }

var weapon: Weapon = Weapon.MACHINE_GUN
var max_hp: int = GameConfig.TOWER_MAX_HP
var hp: int = GameConfig.TOWER_MAX_HP
var fire_cooldown: float = 0.0
var _main: Node2D
var _dead: bool = false
var _range: float = GameConfig.TOWER_MG_RANGE
var _cooldown: float = GameConfig.TOWER_MG_COOLDOWN

@onready var barrel: Sprite2D = $Barrel
@onready var base: Sprite2D = $Base
@onready var hp_bar: ProgressBar = $HpBar


func configure(main_ref: Node2D, weapon_type: Weapon = Weapon.MACHINE_GUN) -> void:
	_main = main_ref
	weapon = weapon_type
	_apply_weapon_visuals()


func _ready() -> void:
	add_to_group("turrets")
	add_to_group("towers")
	hp = max_hp
	_apply_weapon_visuals()
	_update_hp_bar()


func _apply_weapon_visuals() -> void:
	if barrel == null or base == null:
		return
	match weapon:
		Weapon.MACHINE_GUN:
			base.visible = true
			base.scale = Vector2(0.85, 0.85)
			barrel.texture = preload("res://assets/turrets/turret_green.png")
			barrel.offset = Vector2(0, -12)
			barrel.scale = Vector2(0.9, 0.9)
			_range = GameConfig.TOWER_MG_RANGE
			_cooldown = GameConfig.TOWER_MG_COOLDOWN
		Weapon.MISSILE:
			# Launcher art already includes a pad.
			base.visible = false
			barrel.texture = preload("res://assets/turrets/missile_launcher.png")
			barrel.offset = Vector2(0, -6)
			barrel.scale = Vector2(0.95, 0.95)
			_range = GameConfig.TOWER_MISSILE_RANGE
			_cooldown = GameConfig.TOWER_MISSILE_COOLDOWN
	barrel.z_index = 1


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
	var desired := to_plane.angle() + PI * 0.5
	barrel.rotation = lerp_angle(barrel.rotation, desired, GameConfig.TURRET_ROTATE_SPEED * delta)

	if to_plane.length() <= _range and fire_cooldown <= 0.0:
		if abs(angle_difference(barrel.rotation, desired)) < 0.45:
			_fire(to_plane.angle(), plane)
			fire_cooldown = _cooldown


func _nearest_plane() -> PlaneUnit:
	var best: PlaneUnit = null
	var best_d := _range
	for child in _main.get_planes():
		if child is PlaneUnit and child.phase == PlaneUnit.Phase.FLYING:
			var d: float = global_position.distance_to(child.global_position)
			if d < best_d:
				best_d = d
				best = child
	return best


func _fire(aim_angle: float, target: PlaneUnit) -> void:
	match weapon:
		Weapon.MACHINE_GUN:
			var bullet_scene: PackedScene = preload("res://scenes/bullet.tscn")
			var bullet: Bullet = bullet_scene.instantiate()
			var muzzle := global_position + Vector2.RIGHT.rotated(aim_angle) * 22.0
			_main.register_bullet(bullet)
			bullet.setup(muzzle, aim_angle)
		Weapon.MISSILE:
			var missile_scene: PackedScene = preload("res://scenes/missile.tscn")
			var missile: Missile = missile_scene.instantiate()
			var muzzle := global_position + Vector2.RIGHT.rotated(aim_angle) * 24.0
			_main.register_bullet(missile)
			missile.setup(muzzle, aim_angle, target, _main)


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
