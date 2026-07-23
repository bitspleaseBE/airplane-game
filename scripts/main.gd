extends Node2D

## Main level: island fortress, tap-to-deploy bombers, win/lose flow.

signal squadron_changed(remaining: int)
signal keep_hp_changed(current: int, maximum: int)
signal game_won
signal game_lost

enum State { PLAYING, WON, LOST }

var state: State = State.PLAYING
var planes_remaining: int = GameConfig.SQUADRON_SIZE
var active_planes: int = 0
var _spawn_cooldown: float = 0.0
var _holding: bool = false
var _hold_pos: Vector2 = Vector2.ZERO

const HOLD_SPAWN_INTERVAL := 0.15

@onready var keep: Keep = $Keep
@onready var planes: Node2D = $Planes
@onready var bullets: Node2D = $Bullets
@onready var effects: Node2D = $Effects
@onready var hud: CanvasLayer = $HUD
@onready var turrets_root: Node2D = $Turrets
@onready var towers_root: Node2D = $Towers
@onready var ocean: ColorRect = $Ocean

var _plane_scene: PackedScene = preload("res://scenes/plane.tscn")
var _explosion_scene: PackedScene = preload("res://scenes/explosion.tscn")
var _tower_scene: PackedScene = preload("res://scenes/tower.tscn")

enum Boom { BOMB, CRASH, BIG }

## Positions of procedurally placed outer towers (also used to keep trees clear).
var _tower_positions: Array[Vector2] = []


func _ready() -> void:
	randomize()
	_build_island_decor()
	_wire_turrets()
	keep.destroyed.connect(_on_keep_destroyed)
	keep.hp_changed.connect(_on_keep_hp_changed)
	hud.setup(self)
	_emit_hud()
	Sfx.start_island_ambient(self)


func _process(delta: float) -> void:
	_spawn_cooldown = max(_spawn_cooldown - delta, 0.0)
	if state != State.PLAYING or not _holding:
		return
	_hold_pos = get_global_mouse_position()
	if _spawn_cooldown <= 0.0:
		_try_spawn(_hold_pos)


func _unhandled_input(event: InputEvent) -> void:
	if state != State.PLAYING:
		_holding = false
		return

	if event is InputEventScreenTouch:
		if event.pressed:
			_holding = true
			_hold_pos = _screen_to_world(event.position)
			_try_spawn(_hold_pos)
		elif event.index == 0:
			_holding = false
	elif event is InputEventScreenDrag:
		_hold_pos = _screen_to_world(event.position)
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		_holding = event.pressed
		if event.pressed:
			_hold_pos = get_global_mouse_position()
			_try_spawn(_hold_pos)
	elif event is InputEventMouseMotion and _holding:
		_hold_pos = get_global_mouse_position()


func _screen_to_world(screen_pos: Vector2) -> Vector2:
	return get_viewport().get_canvas_transform().affine_inverse() * screen_pos


func _try_spawn(world_pos: Vector2) -> void:
	if planes_remaining <= 0 or _spawn_cooldown > 0.0:
		return

	var dist := world_pos.distance_to(GameConfig.ISLAND_CENTER)
	var theta := (world_pos - GameConfig.ISLAND_CENTER).angle()
	var shore := _lut_at(_sand_lut, theta) if _sand_lut.size() > 0 else GameConfig.WATER_MIN_RADIUS
	if dist < maxf(shore + 12.0, GameConfig.WATER_MIN_RADIUS * 0.85):
		return  # Must tap water around the island

	_spawn_cooldown = HOLD_SPAWN_INTERVAL
	planes_remaining -= 1
	active_planes += 1
	_emit_hud()

	var plane: PlaneUnit = _plane_scene.instantiate()
	planes.add_child(plane)
	plane.setup(world_pos, GameConfig.ISLAND_CENTER, self)
	plane.finished.connect(_on_plane_finished)
	plane.exploded.connect(func(pos: Vector2) -> void: _spawn_explosion(pos, 1.0, Boom.CRASH))


func _on_plane_finished(_delivered_bomb: bool) -> void:
	active_planes = max(active_planes - 1, 0)
	if state == State.PLAYING and planes_remaining <= 0 and active_planes <= 0 and keep.hp > 0:
		_set_lost()


func _on_keep_hp_changed(current: int, maximum: int) -> void:
	keep_hp_changed.emit(current, maximum)


func _on_keep_destroyed() -> void:
	if state != State.PLAYING:
		return
	_spawn_explosion(keep.global_position, 2.2, Boom.BIG)
	_set_won()


func _set_won() -> void:
	state = State.WON
	game_won.emit()


func _set_lost() -> void:
	state = State.LOST
	game_lost.emit()


func restart() -> void:
	get_tree().reload_current_scene()


func apply_bomb_at(pos: Vector2, damage: int) -> void:
	_spawn_explosion(pos, 1.0, Boom.BOMB)
	# Damage keep if close
	if pos.distance_to(keep.global_position) <= GameConfig.PLANE_BOMB_RADIUS + GameConfig.KEEP_RADIUS * 0.35:
		keep.take_damage(damage)
	# Damage keep-corner turrets if close
	for turret in turrets_root.get_children():
		if turret is Turret and is_instance_valid(turret) and not turret.is_destroyed():
			if pos.distance_to(turret.global_position) <= GameConfig.PLANE_BOMB_RADIUS + 30.0:
				turret.take_damage(GameConfig.TURRET_BOMB_DAMAGE)
	# Damage outer towers if close
	for tower in towers_root.get_children():
		if tower is Tower and is_instance_valid(tower) and not tower.is_destroyed():
			if pos.distance_to(tower.global_position) <= GameConfig.PLANE_BOMB_RADIUS + 28.0:
				tower.take_damage(GameConfig.TOWER_BOMB_DAMAGE)


func register_bullet(bullet: Node2D) -> void:
	bullets.add_child(bullet)


func get_planes() -> Array:
	return planes.get_children()


func _spawn_explosion(pos: Vector2, scale_mul: float = 1.0, boom: Boom = Boom.BOMB) -> void:
	var fx: Node2D = _explosion_scene.instantiate()
	effects.add_child(fx)
	fx.global_position = pos
	fx.scale = Vector2.ONE * scale_mul
	match boom:
		Boom.BOMB:
			Sfx.bomb(self)
		Boom.CRASH:
			Sfx.plane_crash(self)
		Boom.BIG:
			Sfx.big_boom(self)


func _emit_hud() -> void:
	squadron_changed.emit(planes_remaining)
	keep_hp_changed.emit(keep.hp, keep.max_hp)


func _wire_turrets() -> void:
	for turret in turrets_root.get_children():
		if turret is Turret:
			turret.configure(self)
			turret.destroyed.connect(func(pos: Vector2) -> void: _spawn_explosion(pos, 1.4, Boom.BOMB))
	for tower in towers_root.get_children():
		if tower is Tower:
			tower.destroyed.connect(func(pos: Vector2) -> void: _spawn_explosion(pos, 1.2, Boom.BOMB))


const ISLAND_LUT_SIZE := 256
const ISLAND_IMG_SCALE := 2.0  # Render at half res; soft edges hide the upscale.
const GRASS_MIN_RADIUS := 145.0  # Keeps the fortress + turrets on grass.

var _sand_lut: PackedFloat32Array = PackedFloat32Array()
var _grass_lut: PackedFloat32Array = PackedFloat32Array()
var _islets: Array = []  # Each entry: [Vector2 offset from center, float radius]


func _build_island_decor() -> void:
	var island := $Island
	var center := GameConfig.ISLAND_CENTER

	_generate_island_shape()
	_apply_water_shader()

	var base := Sprite2D.new()
	base.texture = _render_island_texture()
	base.position = center
	base.scale = Vector2.ONE * ISLAND_IMG_SCALE
	base.z_index = -2
	island.add_child(base)

	_scatter_towers(center)
	_scatter_trees(island, center)


## Organic random coastline: grass and sand outlines are generated
## independently so beach width varies around the island. Low-frequency
## harmonics give the overall lean, gaussian bumps add arms/peninsulas and
## bays, and seamless fractal noise crinkles the fine detail. Occasionally
## spawns tiny offshore islets. The grass core never shrinks below
## GRASS_MIN_RADIUS so the fortress and turrets always sit on land.
func _generate_island_shape() -> void:
	var big_r := GameConfig.ISLAND_RADIUS
	_sand_lut.resize(ISLAND_LUT_SIZE)
	_grass_lut.resize(ISLAND_LUT_SIZE)
	_islets.clear()

	var fine := FastNoiseLite.new()
	fine.seed = randi()
	fine.fractal_octaves = 3
	fine.frequency = 0.9

	var grass_base := big_r * randf_range(0.48, 0.56)
	var sand_base := big_r * randf_range(0.82, 0.94)

	# Shared low-frequency harmonics: [k, grass amp, sand amp, phase]
	var harmonics: Array = []
	for k in [2, 3, 4, 5]:
		harmonics.append([
			float(k),
			randf_range(0.015, 0.05) * big_r,
			randf_range(0.02, 0.07) * big_r,
			randf() * TAU,
		])

	# Gaussian bumps on the coastline: positive = arm/lobe, negative = bay.
	var bumps: Array = []  # [center angle, angular width, amplitude]
	for i in randi_range(1, 3):
		bumps.append([randf() * TAU, randf_range(0.25, 0.55), randf_range(0.10, 0.22) * big_r])
	for i in randi_range(0, 2):
		bumps.append([randf() * TAU, randf_range(0.20, 0.45), -randf_range(0.05, 0.11) * big_r])

	for i in ISLAND_LUT_SIZE:
		var theta := TAU * float(i) / float(ISLAND_LUT_SIZE)
		# Sample noise on a circle so it wraps seamlessly at theta = 0.
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
			# Vegetation follows arms at reduced strength, so long spits
			# end in bare sand while their base stays green.
			g += b[2] * 0.35 * exp(-0.5 * pow(d / (b[1] * 0.8), 2.0))
		g = clampf(g, GRASS_MIN_RADIUS, big_r * 0.65)
		_grass_lut[i] = g
		_sand_lut[i] = clampf(s, g + 40.0, big_r)

	# Occasional tiny offshore islets in the surrounding water.
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


func _apply_water_shader() -> void:
	if ocean == null or ocean.material == null:
		return
	var mat := ocean.material as ShaderMaterial
	if mat == null:
		return
	# Encode radius / ISLAND_RADIUS into R of a 256x1 texture for coastline foam.
	var img := Image.create(ISLAND_LUT_SIZE, 1, false, Image.FORMAT_RGBA8)
	for i in ISLAND_LUT_SIZE:
		var r_norm := clampf(_sand_lut[i] / GameConfig.ISLAND_RADIUS, 0.0, 1.0)
		img.set_pixel(i, 0, Color(r_norm, 0.0, 0.0, 1.0))
	var lut_tex := ImageTexture.create_from_image(img)
	mat.set_shader_parameter("radius_lut", lut_tex)
	mat.set_shader_parameter("island_center", GameConfig.ISLAND_CENTER)
	mat.set_shader_parameter("island_radius", GameConfig.ISLAND_RADIUS)


func _render_island_texture() -> ImageTexture:
	var pad := 26.0  # Room for islets and their shallow halos near the rim.
	var size := int(ceil((GameConfig.ISLAND_RADIUS + pad) * 2.0 / ISLAND_IMG_SCALE))
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	var c := size * 0.5
	for y in size:
		for x in size:
			var p := Vector2(float(x) - c + 0.5, float(y) - c + 0.5) * ISLAND_IMG_SCALE
			var dist := p.length()
			var theta := atan2(p.y, p.x)
			# Main coast: the water shader draws foam/shallows, so no halo here.
			var col := _shade_island(dist, _lut_at(_sand_lut, theta), _lut_at(_grass_lut, theta), false)
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


## Shade one pixel of an island: wet sand at the waterline → dry beach →
## grass with a sunlit center, plus speckle grain. Islets bake their own
## shallow turquoise halo since the ocean foam shader can't follow them.
func _shade_island(dist: float, sand_r: float, grass_r: float, halo: bool) -> Color:
	var shallow_a := 0.0
	if halo:
		shallow_a = (1.0 - smoothstep(sand_r - 2.0, sand_r + 18.0, dist)) * 0.35
	var land_a := 1.0 - smoothstep(sand_r - 2.5, sand_r + 1.5, dist)
	if shallow_a <= 0.004 and land_a <= 0.004:
		return Color(0, 0, 0, 0)
	var out := Color(0.45, 0.78, 0.76, shallow_a)
	if land_a > 0.004:
		# Dry beach → wet darker sand right at the waterline (classic beach read).
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


## 2-4 smaller outer towers on the grass ring, random mix of MG / missile.
func _scatter_towers(center: Vector2) -> void:
	_tower_positions.clear()
	var count := randi_range(GameConfig.TOWER_COUNT_MIN, GameConfig.TOWER_COUNT_MAX)

	var blocked: Array[Vector2] = []
	for turret in turrets_root.get_children():
		if turret is Node2D:
			blocked.append(turret.global_position)

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
		tower.global_position = pos
		var weapon: Tower.Weapon = (
			Tower.Weapon.MACHINE_GUN if randf() < 0.55 else Tower.Weapon.MISSILE
		)
		tower.configure(self, weapon)


## 0-10 palms, weighted towards 0-5, lining the grass/beach boundary — clear
## of the fortress footprint, the turrets, outer towers, and each other.
func _scatter_trees(island: Node2D, center: Vector2) -> void:
	var tree_tex: Texture2D = preload("res://assets/terrain/palm_tree.png")
	var count := randi_range(0, 5) if randf() < 0.7 else randi_range(6, 10)

	var blocked: Array[Vector2] = []
	for turret in turrets_root.get_children():
		if turret is Node2D:
			blocked.append(turret.global_position)
	blocked.append_array(_tower_positions)

	var placed: Array[Vector2] = []
	var attempts := 0
	while placed.size() < count and attempts < 300:
		attempts += 1
		var theta := randf() * TAU
		# Hug the treeline: straddle the grass/beach boundary with a bit of
		# jitter, leaning slightly into the grass.
		var d := _lut_at(_grass_lut, theta) + randf_range(-14.0, 4.0)
		if d < GameConfig.FORT_CLEAR_RADIUS + 25.0:
			continue
		var pos := center + Vector2.from_angle(theta) * d
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
		island.add_child(t)
