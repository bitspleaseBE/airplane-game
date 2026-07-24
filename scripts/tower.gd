class_name Tower
extends Node2D

## Outer defense. The stronghold's arsenal evolves across the campaign:
## machine guns from the start, missile launchers, then flak batteries
## (airburst area denial) and smoke screens (slow field, no gun).
## Each type gets a color-coded pad ring so it reads at a glance.

signal destroyed(pos: Vector2)

enum Weapon { MACHINE_GUN, MISSILE, FLAK, SMOKE }

const PAD_COLORS := {
	Weapon.MACHINE_GUN: Color(0.4, 0.72, 0.32),
	Weapon.MISSILE: Color(0.95, 0.62, 0.2),
	Weapon.FLAK: Color(0.82, 0.24, 0.3),
	Weapon.SMOKE: Color(0.55, 0.63, 0.74),
}

var weapon: Weapon = Weapon.MACHINE_GUN
var max_hp: int = GameConfig.TOWER_MAX_HP
var hp: int = GameConfig.TOWER_MAX_HP
var fire_cooldown: float = 0.0
var _main: Node2D
var _dead: bool = false
var _range: float = GameConfig.TOWER_MG_RANGE
var _cooldown: float = GameConfig.TOWER_MG_COOLDOWN
var _smoke_puff_timer: float = 0.0

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
		Weapon.SMOKE:
			# No gun — a squat generator that hazes the airspace around it.
			base.visible = true
			base.scale = Vector2(0.95, 0.95)
			barrel.texture = preload("res://assets/keep/stone_octagon.png")
			barrel.modulate = Color(0.62, 0.68, 0.78)
			barrel.offset = Vector2.ZERO
			barrel.rotation = 0.0
			barrel.scale = Vector2(0.55, 0.55)
			_range = GameConfig.SMOKE_FIELD_RADIUS
			_cooldown = 0.0
	barrel.z_index = 1
	queue_redraw()


## Color-coded pad ring (and haze disc for smoke) drawn under the sprites.
func _draw() -> void:
	var col: Color = PAD_COLORS.get(weapon, Color.WHITE)
	if weapon == Weapon.SMOKE:
		draw_circle(Vector2.ZERO, GameConfig.SMOKE_FIELD_RADIUS, Color(col.r, col.g, col.b, 0.07))
		draw_arc(Vector2.ZERO, GameConfig.SMOKE_FIELD_RADIUS, 0.0, TAU, 48, Color(col.r, col.g, col.b, 0.28), 2.0)
	draw_circle(Vector2.ZERO, 26.0, Color(col.r, col.g, col.b, 0.22))
	draw_arc(Vector2.ZERO, 26.0, 0.0, TAU, 40, Color(col.r, col.g, col.b, 0.8), 3.0)


func _process(delta: float) -> void:
	if _dead or _main == null:
		return
	if _main.state != _main.State.PLAYING:
		return

	if weapon == Weapon.SMOKE:
		_smoke_process(delta)
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


## Slow every plane inside the haze and keep the field visibly churning.
func _smoke_process(delta: float) -> void:
	for child in _main.get_planes():
		if child is PlaneUnit and child.phase != PlaneUnit.Phase.SIZZLING:
			if global_position.distance_to(child.global_position) <= GameConfig.SMOKE_FIELD_RADIUS:
				child.apply_smoke_slow()

	_smoke_puff_timer -= delta
	if _smoke_puff_timer <= 0.0:
		_smoke_puff_timer = 0.3
		_emit_haze_puff()


func _emit_haze_puff() -> void:
	var puff := Sprite2D.new()
	var idx := randi_range(0, 12)
	var path := "res://assets/effects/smoke/smoke_%02d.png" % idx
	if ResourceLoader.exists(path):
		puff.texture = load(path)
	var offset := Vector2.from_angle(randf() * TAU) * randf_range(0.0, GameConfig.SMOKE_FIELD_RADIUS * 0.85)
	puff.global_position = global_position + offset
	puff.scale = Vector2(0.2, 0.2)
	puff.modulate = Color(0.85, 0.88, 0.95, 0.0)
	puff.z_index = 6
	var parent: Node = _main.get_node_or_null("Effects") if _main else null
	if parent:
		parent.add_child(puff)
	else:
		add_child(puff)
	var tw := puff.create_tween()
	tw.tween_property(puff, "modulate:a", 0.35, 0.4)
	tw.parallel().tween_property(puff, "scale", Vector2(0.45, 0.45), 1.6)
	tw.tween_property(puff, "modulate:a", 0.0, 1.2)
	tw.tween_callback(puff.queue_free)


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
		Weapon.SMOKE:
			pass


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
