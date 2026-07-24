class_name Tower
extends Node2D

## Outer defense. The stronghold's arsenal evolves across the campaign:
## machine guns from the start, missile launchers, then flak batteries
## (airburst area denial). Each type gets a color-coded pad ring so it
## reads at a glance.

signal destroyed(pos: Vector2)

enum Weapon { MACHINE_GUN, MISSILE, FLAK }

const PAD_COLORS := {
	Weapon.MACHINE_GUN: Color(0.4, 0.72, 0.32),
	Weapon.MISSILE: Color(0.95, 0.62, 0.2),
	Weapon.FLAK: Color(0.82, 0.24, 0.3),
}

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
			barrel.modulate = Color.WHITE
			barrel.offset = Vector2(0, -12)
			barrel.scale = Vector2(0.9, 0.9)
			_range = GameConfig.TOWER_MG_RANGE
			_cooldown = GameConfig.TOWER_MG_COOLDOWN
		Weapon.MISSILE:
			# Launcher art already includes a pad.
			base.visible = false
			barrel.texture = preload("res://assets/turrets/missile_launcher.png")
			barrel.modulate = Color.WHITE
			barrel.offset = Vector2(0, -6)
			barrel.scale = Vector2(0.95, 0.95)
			_range = GameConfig.TOWER_MISSILE_RANGE
			_cooldown = GameConfig.TOWER_MISSILE_COOLDOWN
		Weapon.FLAK:
			# Beefier silhouette, crimson tint — the airburst battery.
			base.visible = true
			base.scale = Vector2(1.0, 1.0)
			barrel.texture = preload("res://assets/turrets/turret_red.png")
			barrel.modulate = Color(0.85, 0.5, 0.55)
			barrel.offset = Vector2(0, -12)
			barrel.scale = Vector2(1.05, 1.05)
			_range = GameConfig.FLAK_RANGE
			_cooldown = GameConfig.FLAK_COOLDOWN
	barrel.z_index = 1
	queue_redraw()


## Color-coded pad ring drawn under the sprites.
func _draw() -> void:
	var col: Color = PAD_COLORS.get(weapon, Color.WHITE)
	draw_circle(Vector2.ZERO, 26.0, Color(col.r, col.g, col.b, 0.22))
	draw_arc(Vector2.ZERO, 26.0, 0.0, TAU, 40, Color(col.r, col.g, col.b, 0.8), 3.0)


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
		Weapon.FLAK:
			# Airburst at the plane's predicted position when the shell arrives.
			var shell_scene: PackedScene = preload("res://scenes/flak_shell.tscn")
			var shell: FlakShell = shell_scene.instantiate()
			var muzzle := global_position + Vector2.RIGHT.rotated(aim_angle) * 24.0
			var flight_t := global_position.distance_to(target.global_position) / GameConfig.FLAK_SHELL_SPEED
			var predicted := target.global_position + target.current_velocity() * flight_t
			var burst := global_position + (predicted - global_position).limit_length(GameConfig.FLAK_RANGE)
			_main.register_bullet(shell)
			shell.setup(muzzle, burst, _main)


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
