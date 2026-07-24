class_name Island
extends Node2D

## One fortress island: procedural coast, keep, corner AA, outer towers, trees.

signal keep_destroyed
signal keep_hp_changed(current: int, maximum: int)

const ISLAND_LUT_SIZE := 256
const ISLAND_IMG_SCALE := 3.0  # Half-res-ish; soft edges hide the upscale.
const GRASS_MIN_RADIUS_BASE := 145.0

var level: int = 1
var island_radius: float = GameConfig.ISLAND_RADIUS
var active: bool = false

var _main: Node2D
var _sand_lut: PackedFloat32Array = PackedFloat32Array()
var _grass_lut: PackedFloat32Array = PackedFloat32Array()
var _islets: Array = []
var _tower_positions: Array[Vector2] = []
var _turret_positions: Array[Vector2] = []
var _grass_min_radius: float = GRASS_MIN_RADIUS_BASE

var _keep_scene: PackedScene = preload("res://scenes/keep.tscn")
var _turret_scene: PackedScene = preload("res://scenes/turret.tscn")
var _tower_scene: PackedScene = preload("res://scenes/tower.tscn")

@onready var land: Node2D = $Land
@onready var keep: Keep = $Keep
@onready var turrets_root: Node2D = $Turrets
@onready var towers_root: Node2D = $Towers


func build(level_num: int, main_ref: Node2D) -> void:
	level = level_num
	_main = main_ref
	island_radius = GameConfig.island_radius_for_level(level)
	_grass_min_radius = lerpf(120.0, 155.0, GameConfig.level_t(level))

	_clear_children(land)
	_clear_defenses(false)

	_generate_island_shape()
	var base := Sprite2D.new()
	base.texture = _render_island_texture()
	base.position = Vector2.ZERO
	base.scale = Vector2.ONE * ISLAND_IMG_SCALE
	base.z_index = -2
	land.add_child(base)

	_place_keep()
	_place_turrets()
	_scatter_towers()
	_scatter_trees()
	set_active(false)


func reset_for_retry() -> void:
	_clear_defenses(true)
	_place_keep()
	_place_turrets()
	_scatter_towers()
	set_active(true)


func set_active(on: bool) -> void:
	active = on
	if keep:
		keep.set_process(on)
		if keep.hp_bar:
			keep.hp_bar.visible = on
	for turret in turrets_root.get_children():
		if turret is Turret:
			turret.set_process(on and not turret.is_destroyed())
			if turret.hp_bar:
				turret.hp_bar.visible = on and turret.hp < turret.max_hp and not turret.is_destroyed()
	for tower in towers_root.get_children():
		if tower is Tower:
			tower.set_process(on and not tower.is_destroyed())
			if tower.hp_bar:
				tower.hp_bar.visible = on and tower.hp < tower.max_hp and not tower.is_destroyed()


func get_center() -> Vector2:
	return global_position


func get_shore_radius(theta: float) -> float:
	if _sand_lut.is_empty():
		return island_radius * 0.9
	return _lut_at(_sand_lut, theta)


func get_water_min_radius() -> float:
	# Furthest sand lobe + margin — safe outer ring for spawn validation.
	var max_sand := island_radius * 0.85
	for i in _sand_lut.size():
		max_sand = maxf(max_sand, _sand_lut[i])
	return max_sand + 15.0


func gun_count() -> int:
	var n := 0
	for turret in turrets_root.get_children():
		if turret is Turret and not turret.is_destroyed():
			n += 1
	for tower in towers_root.get_children():
		if tower is Tower and not tower.is_destroyed():
			n += 1
	return n


func gun_count_initial() -> int:
	return _turret_positions.size() + _tower_positions.size()


func apply_bomb_at(pos: Vector2, damage: int) -> void:
	if keep and is_instance_valid(keep) and keep.hp > 0:
		if pos.distance_to(keep.global_position) <= GameConfig.PLANE_BOMB_RADIUS + GameConfig.KEEP_RADIUS * 0.35:
			keep.take_damage(damage)
	for turret in turrets_root.get_children():
		if turret is Turret and is_instance_valid(turret) and not turret.is_destroyed():
			if pos.distance_to(turret.global_position) <= GameConfig.PLANE_BOMB_RADIUS + 30.0:
				turret.take_damage(GameConfig.TURRET_BOMB_DAMAGE)
	for tower in towers_root.get_children():
		if tower is Tower and is_instance_valid(tower) and not tower.is_destroyed():
			if pos.distance_to(tower.global_position) <= GameConfig.PLANE_BOMB_RADIUS + 28.0:
				tower.take_damage(GameConfig.TOWER_BOMB_DAMAGE)


## Point damage from a gunship strafe — hits whatever sits under the impact.
func apply_gunfire_at(pos: Vector2, damage: int) -> void:
	if keep and is_instance_valid(keep) and keep.hp > 0:
		if pos.distance_to(keep.global_position) <= GameConfig.KEEP_RADIUS * 0.9:
			keep.take_damage(damage)
			return
	for turret in turrets_root.get_children():
		if turret is Turret and is_instance_valid(turret) and not turret.is_destroyed():
			if pos.distance_to(turret.global_position) <= 34.0:
				turret.take_damage(damage)
				return
	for tower in towers_root.get_children():
		if tower is Tower and is_instance_valid(tower) and not tower.is_destroyed():
			if pos.distance_to(tower.global_position) <= 32.0:
				tower.take_damage(damage)
				return


func _clear_children(node: Node) -> void:
	while node.get_child_count() > 0:
		var c := node.get_child(0)
		node.remove_child(c)
		c.free()


func _clear_defenses(_keep_keep: bool) -> void:
	_clear_children(turrets_root)
	_clear_children(towers_root)
	_tower_positions.clear()
	_turret_positions.clear()


func _place_keep() -> void:
	if keep == null:
		keep = _keep_scene.instantiate()
		add_child(keep)
		keep.name = "Keep"
	keep.position = Vector2.ZERO
	keep.z_index = 1
	keep.configure(GameConfig.keep_hp_for_level(level))
	if not keep.destroyed.is_connected(_on_keep_destroyed):
		keep.destroyed.connect(_on_keep_destroyed)
	if not keep.hp_changed.is_connected(_on_keep_hp_changed):
		keep.hp_changed.connect(_on_keep_hp_changed)


func _on_keep_destroyed() -> void:
	keep_destroyed.emit()


func _on_keep_hp_changed(current: int, maximum: int) -> void:
	keep_hp_changed.emit(current, maximum)


func _place_turrets() -> void:
	_turret_positions.clear()
	var count := GameConfig.turret_count_for_level(level)
	var angles: Array[float] = []
	# Spread evenly with jitter so they sit near keep corners.
	for i in count:
		angles.append(TAU * float(i) / float(count) + PI * 0.25 + randf_range(-0.12, 0.12))

	for ang in angles:
		var dist := GameConfig.FORT_CLEAR_RADIUS * 0.95 + randf_range(-6.0, 10.0)
		var local := Vector2.from_angle(ang) * dist
		_turret_positions.append(local)
		var turret: Turret = _turret_scene.instantiate()
		turrets_root.add_child(turret)
		turret.position = local
		turret.configure(_main, get_center())
		turret.destroyed.connect(func(pos: Vector2) -> void:
			if _main and _main.has_method("_spawn_explosion"):
				_main._spawn_explosion(pos, 1.4, _main.Boom.BOMB)
		)


func _scatter_towers() -> void:
	_tower_positions.clear()
	var rng_range := GameConfig.tower_count_range_for_level(level)
	var count := randi_range(rng_range.x, rng_range.y)
	var center := Vector2.ZERO
	var blocked: Array[Vector2] = _turret_positions.duplicate()

	var attempts := 0
	while _tower_positions.size() < count and attempts < 400:
		attempts += 1
		var theta := randf() * TAU
		var min_d := GameConfig.FORT_CLEAR_RADIUS + 35.0
		var max_d := _lut_at(_grass_lut, theta) - 28.0
		if max_d <= min_d:
			continue
		var pos := center + Vector2.from_angle(theta) * randf_range(min_d, max_d)
		var too_close := false
		for b in blocked:
			if pos.distance_to(b) < 70.0:
				too_close = true
				break
		if too_close:
			continue
		for p in _tower_positions:
			if pos.distance_to(p) < 85.0:
				too_close = true
				break
		if too_close:
			continue

		_tower_positions.append(pos)
		var tower: Tower = _tower_scene.instantiate()
		towers_root.add_child(tower)
		tower.position = pos
		tower.configure(_main, _pick_tower_weapon(_tower_positions.size() - 1))
		tower.destroyed.connect(func(pos2: Vector2) -> void:
			if _main and _main.has_method("_spawn_explosion"):
				_main._spawn_explosion(pos2, 1.2, _main.Boom.BOMB)
		)


## The stronghold's arsenal evolves with the campaign: MGs from level 1,
## missiles from 4, flak batteries from 13, smoke screens from 18. Newly
## unlocked tiers get one guaranteed emplacement so the change is visible.
func _pick_tower_weapon(index: int) -> Tower.Weapon:
	var guaranteed: Array = []
	if level >= GameConfig.SMOKE_TOWER_UNLOCK_LEVEL:
		guaranteed.append(Tower.Weapon.SMOKE)
	if level >= GameConfig.FLAK_TOWER_UNLOCK_LEVEL:
		guaranteed.append(Tower.Weapon.FLAK)
	if index < guaranteed.size():
		return guaranteed[index]
	var roll := randf()
	if level >= GameConfig.FLAK_TOWER_UNLOCK_LEVEL and roll < 0.2:
		return Tower.Weapon.FLAK
	if level >= GameConfig.MISSILE_TOWER_UNLOCK_LEVEL and roll < 0.45:
		return Tower.Weapon.MISSILE
	return Tower.Weapon.MACHINE_GUN


func _scatter_trees() -> void:
	var tree_tex: Texture2D = preload("res://assets/terrain/palm_tree.png")
	var count := randi_range(0, 5) if randf() < 0.7 else randi_range(6, 10)
	var blocked: Array[Vector2] = _turret_positions.duplicate()
	blocked.append_array(_tower_positions)

	var placed: Array[Vector2] = []
	var attempts := 0
	while placed.size() < count and attempts < 300:
		attempts += 1
		var theta := randf() * TAU
		var d := _lut_at(_grass_lut, theta) + randf_range(-14.0, 4.0)
		if d < GameConfig.FORT_CLEAR_RADIUS + 25.0:
			continue
		var pos := Vector2.from_angle(theta) * d
		var occupied := false
		for b in blocked:
			if pos.distance_to(b) < 45.0:
				occupied = true
				break
		if not occupied:
			for p in placed:
				if pos.distance_to(p) < 42.0:
					occupied = true
					break
		if occupied:
			continue
		placed.append(pos)
		var t := Sprite2D.new()
		t.texture = tree_tex
		t.position = pos
		t.scale = Vector2(0.7, 0.7)
		t.z_index = -1
		land.add_child(t)


func _generate_island_shape() -> void:
	var big_r := island_radius
	_sand_lut.resize(ISLAND_LUT_SIZE)
	_grass_lut.resize(ISLAND_LUT_SIZE)
	_islets.clear()

	var fine := FastNoiseLite.new()
	fine.seed = randi()
	fine.fractal_octaves = 3
	fine.frequency = 0.9

	var grass_base := big_r * randf_range(0.48, 0.56)
	var sand_base := big_r * randf_range(0.82, 0.94)

	var harmonics: Array = []
	for k in [2, 3, 4, 5]:
		harmonics.append([
			float(k),
			randf_range(0.015, 0.05) * big_r,
			randf_range(0.02, 0.07) * big_r,
			randf() * TAU,
		])

	var bumps: Array = []
	for i in randi_range(1, 3):
		bumps.append([randf() * TAU, randf_range(0.25, 0.55), randf_range(0.10, 0.22) * big_r])
	for i in randi_range(0, 2):
		bumps.append([randf() * TAU, randf_range(0.20, 0.45), -randf_range(0.05, 0.11) * big_r])

	for i in ISLAND_LUT_SIZE:
		var theta := TAU * float(i) / float(ISLAND_LUT_SIZE)
		var nx := cos(theta) * 3.0
		var ny := sin(theta) * 3.0
		var g := grass_base + fine.get_noise_2d(nx, ny) * 0.035 * big_r
		var s := sand_base + fine.get_noise_2d(nx + 9.0, ny + 9.0) * 0.05 * big_r
		for h in harmonics:
			g += h[1] * sin(h[0] * theta + h[3])
			s += h[2] * sin(h[0] * theta + h[3] + 0.7)
		for b in bumps:
			var d := absf(wrapf(theta - b[0], -PI, PI))
			s += b[2] * exp(-0.5 * pow(d / b[1], 2.0))
			g += b[2] * 0.35 * exp(-0.5 * pow(d / (b[1] * 0.8), 2.0))
		g = clampf(g, _grass_min_radius, big_r * 0.65)
		_grass_lut[i] = g
		_sand_lut[i] = clampf(s, g + 40.0, big_r)

	if randf() < 0.55:
		for i in randi_range(1, 2):
			var ang := randf() * TAU
			var islet_r := randf_range(10.0, 22.0)
			var lo := _lut_at(_sand_lut, ang) + islet_r + 14.0
			var hi := big_r - islet_r - 4.0
			if hi <= lo:
				continue
			_islets.append([Vector2.from_angle(ang) * randf_range(lo, hi), islet_r])


func _lut_at(lut: PackedFloat32Array, theta: float) -> float:
	var t := fposmod(theta, TAU) / TAU * float(ISLAND_LUT_SIZE)
	var i := int(t) % ISLAND_LUT_SIZE
	return lerpf(lut[i], lut[(i + 1) % ISLAND_LUT_SIZE], t - float(i))


func _render_island_texture() -> ImageTexture:
	var pad := 26.0
	var size := int(ceil((island_radius + pad) * 2.0 / ISLAND_IMG_SCALE))
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	var c := size * 0.5
	for y in size:
		for x in size:
			var p := Vector2(float(x) - c + 0.5, float(y) - c + 0.5) * ISLAND_IMG_SCALE
			var dist := p.length()
			var theta := atan2(p.y, p.x)
			# Bake shallow halo so open-ocean water still reads a shoreline.
			var col := _shade_island(dist, _lut_at(_sand_lut, theta), _lut_at(_grass_lut, theta), true)
			for islet in _islets:
				var islet_dist: float = p.distance_to(islet[0])
				var islet_r: float = islet[1]
				if islet_dist > islet_r + 26.0:
					continue
				var islet_grass := islet_r * 0.55 if islet_r > 15.0 else 0.0
				var icol := _shade_island(islet_dist, islet_r, islet_grass, true)
				if icol.a > col.a:
					col = icol
			if col.a > 0.004:
				img.set_pixel(x, y, col)
	return ImageTexture.create_from_image(img)


func _shade_island(dist: float, sand_r: float, grass_r: float, halo: bool) -> Color:
	var shallow_a := 0.0
	if halo:
		shallow_a = (1.0 - smoothstep(sand_r - 2.0, sand_r + 18.0, dist)) * 0.35
	var land_a := 1.0 - smoothstep(sand_r - 2.5, sand_r + 1.5, dist)
	if shallow_a <= 0.004 and land_a <= 0.004:
		return Color(0, 0, 0, 0)
	var out := Color(0.45, 0.78, 0.76, shallow_a)
	if land_a > 0.004:
		var dry := Color(0.94, 0.85, 0.60)
		var wet_sand := Color(0.62, 0.52, 0.36)
		var wet := smoothstep(sand_r - 28.0, sand_r + 0.5, dist)
		var col := dry.lerp(wet_sand, wet * wet)
		var grain := randf_range(-0.045, 0.045)
		col = Color(col.r + grain, col.g + grain * 0.85, col.b + grain * 0.65)
		if grass_r > 0.0:
			var g := 1.0 - smoothstep(grass_r - 10.0, grass_r + 10.0, dist)
			var glow := clampf(1.0 - dist / maxf(grass_r * 0.9, 1.0), 0.0, 1.0) * 0.55
			var grass_col := Color(0.34, 0.60, 0.26).lerp(Color(0.55, 0.72, 0.38), glow)
			var rim := (1.0 - smoothstep(0.0, 12.0, absf(dist - (grass_r - 6.0)))) * 0.1
			col = col.lerp(grass_col.darkened(rim), g)
		out = Color(
			lerpf(out.r, col.r, land_a),
			lerpf(out.g, col.g, land_a),
			lerpf(out.b, col.b, land_a),
			land_a + out.a * (1.0 - land_a),
		)
	var n := randf_range(-0.02, 0.02)
	return Color(out.r + n, out.g + n, out.b + n, out.a)
