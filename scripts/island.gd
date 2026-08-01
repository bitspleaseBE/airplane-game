class_name Island
extends Node2D

## One fortress island: procedural coast, keep, corner AA, outer towers, trees.

signal keep_destroyed
signal keep_hp_changed(current: int, maximum: int)

const ISLAND_LUT_SIZE := 256
const GRASS_MIN_RADIUS_BASE := 145.0
## Slack around the outermost sand so the shelf, foam and sandbars all fit inside
## the beach quad. Matches the padding the old CPU bake sized its image with.
const BEACH_PAD := 110.0
## World-unit range the 16-bit coast LUT is normalised against. The largest
## possible sand radius is ISLAND_RADIUS_STRONGHOLD * 1.7 = 782.
const LUT_RANGE := 1024.0
## Must match MAX_ISLETS / MAX_LOBES in shaders/island_beach.gdshader.
const MAX_ISLETS := 4
const MAX_LOBES := 8
## Must match GRAIN_TILE in shaders/island_beach.gdshader — the input-space period
## of the shared noise tile, which bounds a useful per-island grain offset.
const GRAIN_TILE := 114.28571


## Full-bleed quad the beach shader draws into. A Sprite2D would size its quad
## from a texture — pointless here, since the shader generates every pixel — and
## would put the node scale in the way of local space. Drawing the rect directly
## keeps local space equal to island-relative space.
class BeachQuad:
	extends Node2D

	var span: float = 0.0

	func _draw() -> void:
		draw_rect(Rect2(-span * 0.5, -span * 0.5, span, span), Color.WHITE)


## Distinct coastline silhouettes so every bastion reads differently.
enum CoastShape {
	ROUND,
	BAY,
	DOUBLE_BAY,
	CRESCENT,
	PENINSULA,
	## Long tropical spit / sandbar arm off a compact body.
	ARM,
	KIDNEY,
	COVE,
	LOBED,
	## Curved hook arm — common reef/atoll fragment silhouette.
	HOOK,
}

var level: int = 1
var island_radius: float = GameConfig.ISLAND_RADIUS
var active: bool = false
## Scenery-only islet: no keep, turrets, or towers.
var scenic: bool = false

var _main: Node2D
var _rng := RandomNumberGenerator.new()
var _sand_lut: PackedFloat32Array = PackedFloat32Array()
var _grass_lut: PackedFloat32Array = PackedFloat32Array()
var _islets: Array = []
## Soft turquoise sandbar / reef blobs that touch the coastal shelf.
var _shallow_lobes: Array = []
var _tower_positions: Array[Vector2] = []
var _turret_positions: Array[Vector2] = []
var _grass_min_radius: float = GRASS_MIN_RADIUS_BASE
var _coast_shape: CoastShape = CoastShape.ROUND
var _beach: BeachQuad
var _built := false

var _keep_scene: PackedScene = preload("res://scenes/keep.tscn")
var _turret_scene: PackedScene = preload("res://scenes/turret.tscn")
var _tower_scene: PackedScene = preload("res://scenes/tower.tscn")
var _beach_shader: Shader = preload("res://shaders/island_beach.gdshader")
var _noise_tex: Texture2D = preload("res://assets/textures/water_noise.png")

@onready var land: Node2D = $Land
@onready var keep: Keep = $Keep
@onready var turrets_root: Node2D = $Turrets
@onready var towers_root: Node2D = $Towers


func build(level_num: int, main_ref: Node2D) -> void:
	scenic = false
	level = level_num
	_main = main_ref
	# Stable per-level seed so each bastion keeps its silhouette across retries.
	_rng.seed = hash("bastion_%d" % level)
	var base_r := GameConfig.island_radius_for_level(level)
	# Size jitter so the chain isn't a parade of same-radius disks.
	if GameConfig.is_stronghold_level(level):
		island_radius = base_r
	else:
		island_radius = base_r * _rng.randf_range(0.78, 1.16)
	# Outer guns need a grass ring past the fort. Tiny jittered islets
	# (e.g. L4 missile unlock) used to starve that ring and place zero towers.
	var want_towers := GameConfig.tower_count_range_for_level(level).y
	if want_towers > 0:
		island_radius = maxf(island_radius, GameConfig.ISLAND_RADIUS)
	_grass_min_radius = lerpf(120.0, 155.0, GameConfig.level_t(level))
	if want_towers > 0:
		# Placement band: min_d = fort+30, max_d ≈ grass+20 → grass must clear ~125+.
		_grass_min_radius = maxf(_grass_min_radius, GameConfig.FORT_CLEAR_RADIUS + 45.0)
	if GameConfig.is_stronghold_level(level):
		_grass_min_radius = lerpf(_grass_min_radius, 175.0, 0.7)
	_coast_shape = _coast_shape_for_level(level)

	_clear_children(land)
	_clear_defenses(false)

	_generate_island_shape()
	_make_beach()

	_place_keep()
	_place_turrets()
	_scatter_towers()
	_scatter_trees()
	_built = true
	set_active(false)


## Empty tropical islet — land + palms only. Used to break up open ocean.
func build_scenic(seed_key: int, radius: float, main_ref: Node2D) -> void:
	scenic = true
	level = 0
	_main = main_ref
	_rng.seed = hash("scenic_%d" % seed_key)
	island_radius = radius
	_grass_min_radius = clampf(radius * 0.42, 28.0, 70.0)
	var scenic_shapes: Array[CoastShape] = [
		CoastShape.ARM,
		CoastShape.HOOK,
		CoastShape.CRESCENT,
		CoastShape.PENINSULA,
		CoastShape.LOBED,
		CoastShape.KIDNEY,
		CoastShape.BAY,
	]
	_coast_shape = scenic_shapes[seed_key % scenic_shapes.size()]

	_clear_children(land)
	_clear_defenses(false)
	_hide_keep()

	_generate_island_shape()
	_make_beach()

	_scatter_trees()
	_built = true
	set_active(false)


## Hand the coast over to shaders/island_beach.gdshader. This replaced a per-pixel
## GDScript rasteriser that cost 1.3 s at level 1 and 4.3 s at level 20 on the
## main thread — with no way off it, since the web export has no threads. There is
## no longer a quality tier or a background pass: the beach is simply there.
func _make_beach() -> void:
	# build() clears Land first, which frees the previous quad — so re-check
	# validity, not just null, or a rebuild reuses a dangling reference.
	if _beach == null or not is_instance_valid(_beach):
		_beach = BeachQuad.new()
		_beach.position = Vector2.ZERO
		_beach.z_index = -2
		land.add_child(_beach)

	# Arms, islets and sandbars all reach past the nominal radius — size the quad
	# to the true extent so nothing is clipped.
	var extent := island_radius
	for i in _sand_lut.size():
		extent = maxf(extent, _sand_lut[i])
	for islet in _islets:
		extent = maxf(extent, islet[0].length() + float(islet[1]))
	for lobe in _shallow_lobes:
		extent = maxf(extent, lobe[0].length() + float(lobe[1]))
	_beach.span = (extent + BEACH_PAD) * 2.0
	_beach.queue_redraw()

	var mat := ShaderMaterial.new()
	mat.shader = _beach_shader
	mat.set_shader_parameter("coast_lut", _make_coast_lut())
	mat.set_shader_parameter("lut_range", LUT_RANGE)
	mat.set_shader_parameter("noise_tex", _noise_tex)
	# Slide this island to its own patch of the shared noise tile. The old CPU bake
	# seeded FastNoiseLite per level for the same reason — without it every island
	# gets identical shelf bulges and wet-sand banding.
	var grain_rng := RandomNumberGenerator.new()
	grain_rng.seed = hash("grain_%d" % level if not scenic else "grain_scenic_%d" % _rng.seed)
	mat.set_shader_parameter(
		"grain_offset",
		Vector2(grain_rng.randf(), grain_rng.randf()) * GRAIN_TILE,
	)
	mat.set_shader_parameter("islets", _pack_blobs(_islets, MAX_ISLETS))
	mat.set_shader_parameter("islet_count", mini(_islets.size(), MAX_ISLETS))
	mat.set_shader_parameter("lobes", _pack_blobs(_shallow_lobes, MAX_LOBES))
	mat.set_shader_parameter("lobe_count", mini(_shallow_lobes.size(), MAX_LOBES))
	_beach.material = mat


## [centre, radius] pairs as vec3(x, y, radius) for the shader's uniform arrays.
func _pack_blobs(blobs: Array, limit: int) -> PackedVector3Array:
	var out := PackedVector3Array()
	for blob in blobs:
		if out.size() >= limit:
			break
		var c: Vector2 = blob[0]
		out.append(Vector3(c.x, c.y, float(blob[1])))
	return out


## Coast radii as a 256x2 texture: row 0 sand, row 1 grass, each value packed
## big-endian across R and G. 8 bits over LUT_RANGE would step the coastline in
## 4-unit jumps, which shows as facets on the shoreline.
func _make_coast_lut() -> ImageTexture:
	var img := Image.create(ISLAND_LUT_SIZE, 2, false, Image.FORMAT_RGBA8)
	for i in ISLAND_LUT_SIZE:
		var sand := int(round(clampf(_sand_lut[i] / LUT_RANGE, 0.0, 1.0) * 65535.0))
		var grass := int(round(clampf(_grass_lut[i] / LUT_RANGE, 0.0, 1.0) * 65535.0))
		img.set_pixel(i, 0, Color8(sand >> 8, sand & 0xFF, 0, 255))
		img.set_pixel(i, 1, Color8(grass >> 8, grass & 0xFF, 0, 255))
	return ImageTexture.create_from_image(img)


func _hide_keep() -> void:
	if keep == null:
		return
	keep.visible = false
	keep.set_process(false)
	if keep.hp_bar:
		keep.hp_bar.visible = false


func is_built() -> bool:
	return _built


func reset_for_retry() -> void:
	# Keep the silhouette; reshuffle only living defenses.
	_rng.seed = hash("bastion_%d_retry" % level)
	_clear_defenses(true)
	_place_keep()
	_place_turrets()
	_scatter_towers()
	set_active(true)


func set_active(on: bool) -> void:
	active = on
	if scenic:
		return
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
	for islet in _islets:
		max_sand = maxf(max_sand, islet[0].length() + float(islet[1]))
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
	# Prefer living guns so SEAD runs actually soft the nest.
	for turret in turrets_root.get_children():
		if turret is Turret and is_instance_valid(turret) and not turret.is_destroyed():
			if pos.distance_to(turret.global_position) <= 38.0:
				turret.take_damage(damage)
				return
	for tower in towers_root.get_children():
		if tower is Tower and is_instance_valid(tower) and not tower.is_destroyed():
			if pos.distance_to(tower.global_position) <= 36.0:
				tower.take_damage(damage)
				return
	if keep and is_instance_valid(keep) and keep.hp > 0:
		if pos.distance_to(keep.global_position) <= GameConfig.KEEP_RADIUS * 0.9:
			keep.take_damage(damage)


## Living corner AA first (near the keep), then outer towers — gunship doctrine.
func get_defense_positions() -> Array[Vector2]:
	var out: Array[Vector2] = []
	for turret in turrets_root.get_children():
		if turret is Turret and not turret.is_destroyed():
			out.append(turret.global_position)
	for tower in towers_root.get_children():
		if tower is Tower and not tower.is_destroyed():
			out.append(tower.global_position)
	return out


func get_gunship_target(from_pos: Vector2) -> Vector2:
	## Prefer living corner AA (splash the keep while softing guns). Outer towers next.
	var best := Vector2.ZERO
	var best_score := INF
	var keep_pos := get_center()
	for turret in turrets_root.get_children():
		if turret is Turret and not turret.is_destroyed():
			var score: float = from_pos.distance_to(turret.global_position)
			score += keep_pos.distance_to(turret.global_position) * 0.25
			if score < best_score:
				best_score = score
				best = turret.global_position
	if best_score < INF:
		return best
	for tower in towers_root.get_children():
		if tower is Tower and not tower.is_destroyed():
			var score2: float = from_pos.distance_to(tower.global_position)
			if score2 < best_score:
				best_score = score2
				best = tower.global_position
	if best_score < INF:
		return best
	return keep_pos


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
	keep.visible = true
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
	var count := clampi(GameConfig.turret_count_for_level(level), 0, 4)
	# Keep guns sit on the fort's four circular corner towers — never mid-wall.
	# When count < 4, occupy a random subset of those fixed mounts.
	var corner_angles: Array[float] = [
		PI * 0.25,   # SE
		PI * 0.75,   # SW
		PI * 1.25,   # NW
		PI * 1.75,   # NE
	]
	# Fisher–Yates so which corners stay empty varies per bastion/retry.
	for i in range(corner_angles.size() - 1, 0, -1):
		var j := _rng.randi_range(0, i)
		var tmp: float = corner_angles[i]
		corner_angles[i] = corner_angles[j]
		corner_angles[j] = tmp
	var dist := GameConfig.FORT_CLEAR_RADIUS * 0.95
	for i in count:
		var local := Vector2.from_angle(corner_angles[i]) * dist
		_turret_positions.append(local)
		var turret: Turret = _turret_scene.instantiate()
		turrets_root.add_child(turret)
		turret.position = local
		turret.configure(
			_main,
			get_center(),
			GameConfig.turret_range_for_level(level),
			GameConfig.turret_cooldown_for_level(level),
		)
		turret.destroyed.connect(func(pos: Vector2) -> void:
			if _main and _main.has_method("spawn_gun_kill_flash"):
				_main.spawn_gun_kill_flash(pos)
			elif _main and _main.has_method("_spawn_explosion"):
				_main._spawn_explosion(pos, 1.7, _main.Boom.BOMB)
		)


func _scatter_towers() -> void:
	_tower_positions.clear()
	var rng_range := GameConfig.tower_count_range_for_level(level)
	var count := _rng.randi_range(rng_range.x, rng_range.y)
	if count <= 0:
		return
	# Normal spacing first; relax if the ring is tight so unlock levels
	# never ship with zero outer guns after announcing them.
	_place_outer_towers(count, 90.0, 72.0)
	if _tower_positions.size() < count:
		_place_outer_towers(count, 64.0, 52.0)


func _place_outer_towers(count: int, peer_sep: float, turret_sep: float) -> void:
	var center := Vector2.ZERO
	var blocked: Array[Vector2] = _turret_positions.duplicate()
	var sector := TAU / float(maxi(count, 1))
	var sector_offset := _rng.randf() * TAU
	var attempts := 0
	var slot := _tower_positions.size()
	while _tower_positions.size() < count and attempts < 500:
		attempts += 1
		var theta := sector_offset + sector * float(slot) + _rng.randf_range(-sector * 0.35, sector * 0.35)
		slot = (slot + 1) % maxi(count, 1)
		var min_d := GameConfig.FORT_CLEAR_RADIUS + 30.0
		var grass_r := _lut_at(_grass_lut, theta)
		var sand_r := _lut_at(_sand_lut, theta)
		# Prefer inland grass; allow the upper beach edge, never near the water.
		var max_d := maxf(grass_r - 30.0, minf(sand_r - 60.0, grass_r + 20.0))
		if max_d <= min_d:
			continue
		var t := _rng.randf_range(0.2, 0.95)
		var dist := lerpf(min_d, max_d, t)
		var pos := center + Vector2.from_angle(theta) * dist
		var too_close := false
		for b in blocked:
			if pos.distance_to(b) < turret_sep:
				too_close = true
				break
		if too_close:
			continue
		for p in _tower_positions:
			if pos.distance_to(p) < peer_sep:
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
			if _main and _main.has_method("spawn_gun_kill_flash"):
				_main.spawn_gun_kill_flash(pos2)
			elif _main and _main.has_method("_spawn_explosion"):
				_main._spawn_explosion(pos2, 1.5, _main.Boom.BOMB)
		)


## The stronghold's arsenal evolves with the campaign: MGs from level 1,
## missiles from 4, flak batteries from 13. Newly unlocked tiers get one
## guaranteed emplacement so the change is visible.
func _pick_tower_weapon(index: int) -> Tower.Weapon:
	if level >= GameConfig.FLAK_TOWER_UNLOCK_LEVEL and index == 0:
		return Tower.Weapon.FLAK
	if level >= GameConfig.MISSILE_TOWER_UNLOCK_LEVEL and index == 0:
		return Tower.Weapon.MISSILE
	var roll := _rng.randf()
	if level >= GameConfig.FLAK_TOWER_UNLOCK_LEVEL and roll < 0.2:
		return Tower.Weapon.FLAK
	if level >= GameConfig.MISSILE_TOWER_UNLOCK_LEVEL and roll < 0.45:
		return Tower.Weapon.MISSILE
	return Tower.Weapon.MACHINE_GUN


func _scatter_trees() -> void:
	var tree_tex: Texture2D = preload("res://assets/terrain/palm_tree.png")
	var blocked: Array[Vector2] = _turret_positions.duplicate()
	blocked.append_array(_tower_positions)
	var placed: Array[Vector2] = []

	# Longer sand shelves get denser palm lines; short beaches stay sparse.
	var long_beach_slots: Array[float] = []
	for i in ISLAND_LUT_SIZE:
		var theta := TAU * float(i) / float(ISLAND_LUT_SIZE)
		var sand_r := _sand_lut[i]
		var grass_r := _grass_lut[i]
		var shelf := sand_r - grass_r
		if shelf > 55.0:
			long_beach_slots.append(theta)
	# Uniform 0–10 palms; scenic islets stay sparse so they don't read as bases.
	var count := _rng.randi_range(0, 4) if scenic else _rng.randi_range(0, 10)

	var attempts := 0
	while placed.size() < count and attempts < 500:
		attempts += 1
		var theta: float
		if long_beach_slots.size() > 0 and _rng.randf() < 0.7:
			theta = long_beach_slots[_rng.randi_range(0, long_beach_slots.size() - 1)]
			theta += _rng.randf_range(-0.04, 0.04)
		else:
			theta = _rng.randf() * TAU
		var grass_r := _lut_at(_grass_lut, theta)
		var sand_r := _lut_at(_sand_lut, theta)
		var shelf := sand_r - grass_r
		# Long beaches: plant palms out on the sand. Short edges: grass rim only.
		var d: float
		if shelf > 60.0 and _rng.randf() < 0.65:
			d = lerpf(grass_r + 6.0, sand_r - 10.0, _rng.randf_range(0.15, 0.75))
		else:
			d = grass_r + _rng.randf_range(-8.0, minf(14.0, shelf * 0.3))
		if d < GameConfig.FORT_CLEAR_RADIUS + 25.0 and not scenic:
			continue
		if scenic and d < _grass_min_radius * 0.35:
			continue
		var pos := Vector2.from_angle(theta) * d
		var occupied := false
		for b in blocked:
			if pos.distance_to(b) < 48.0:
				occupied = true
				break
		if not occupied:
			for p in placed:
				if pos.distance_to(p) < 46.0:
					occupied = true
					break
		if occupied:
			continue
		placed.append(pos)
		var t := Sprite2D.new()
		t.texture = tree_tex
		t.position = pos
		var ts := _rng.randf_range(0.6, 0.82)
		t.scale = Vector2(ts, ts)
		t.rotation = _rng.randf() * TAU
		t.z_index = -1
		land.add_child(t)


func _coast_shape_for_level(level_num: int) -> CoastShape:
	## Cycle silhouettes; strongholds get the most dramatic coastlines.
	if level_num == 10:
		return CoastShape.DOUBLE_BAY
	if level_num == 15:
		return CoastShape.ARM
	if level_num == 20:
		return CoastShape.HOOK
	var order: Array[CoastShape] = [
		CoastShape.ROUND,
		CoastShape.ARM,
		CoastShape.BAY,
		CoastShape.PENINSULA,
		CoastShape.HOOK,
		CoastShape.KIDNEY,
		CoastShape.COVE,
		CoastShape.CRESCENT,
		CoastShape.LOBED,
		CoastShape.DOUBLE_BAY,
	]
	return order[(level_num - 1) % order.size()]


func _generate_island_shape() -> void:
	var big_r := island_radius
	_sand_lut.resize(ISLAND_LUT_SIZE)
	_grass_lut.resize(ISLAND_LUT_SIZE)
	_islets.clear()

	var fine := FastNoiseLite.new()
	fine.seed = _rng.randi()
	fine.fractal_octaves = 2
	fine.frequency = 0.8

	var grass_base := big_r * _rng.randf_range(0.46, 0.56)
	var sand_base := big_r * _rng.randf_range(0.82, 0.94)
	var axis := _rng.randf() * TAU
	# Dominant wind/wave direction: fat sheltered beaches leeward (downwind),
	# thin wave-cut shelves windward. Arms/spits grow with the wind.
	var wind := axis + _rng.randf_range(-0.5, 0.5)
	if _coast_shape == CoastShape.ARM or _coast_shape == CoastShape.HOOK or _coast_shape == CoastShape.PENINSULA:
		# Spits are wind-built — align the arm with the wind, not against it.
		wind = axis + _rng.randf_range(-0.25, 0.25)
	# Mild ellipse so even "round" coasts aren't perfect disks.
	var stretch := _rng.randf_range(0.1, 0.22)
	# Arm / hook / peninsula may stick past the nominal radius.
	var arm_extend := (
		_coast_shape == CoastShape.ARM
		or _coast_shape == CoastShape.HOOK
		or _coast_shape == CoastShape.PENINSULA
	)
	var sand_cap := big_r * (1.7 if arm_extend else 1.12)
	# Grass stays a compact keep-pad — never rides out onto spits/arms.
	var grass_cap: float
	if scenic:
		grass_cap = big_r * 0.55
	else:
		grass_cap = minf(_grass_min_radius * 1.05, big_r * 0.58)
		# Don't let the 0.58 ratio choke the gun ring on mid-size islets.
		if GameConfig.tower_count_range_for_level(level).y > 0:
			grass_cap = maxf(grass_cap, GameConfig.FORT_CLEAR_RADIUS + 45.0)

	# Multiplicative silhouette first — this is what makes bays/crescents readable.
	var profile := PackedFloat32Array()
	profile.resize(ISLAND_LUT_SIZE)
	var shelf_boost := PackedFloat32Array()
	shelf_boost.resize(ISLAND_LUT_SIZE)
	_build_coast_profile(profile, shelf_boost, axis)

	# More harmonics = erratic, organic outline; amplitude falls off with k
	# so the wiggle stays chunky instead of jagged.
	var harmonics: Array = []
	for k in [2, 3, 4, 6, 7, 9]:
		var falloff := 1.0 / (1.0 + float(k) * 0.35)
		harmonics.append([
			float(k),
			_rng.randf_range(0.015, 0.05) * big_r * falloff,
			_rng.randf_range(0.025, 0.07) * big_r * falloff,
			_rng.randf() * TAU,
		])

	# Keep-pad grass: mild wobble only — independent of the sand silhouette.
	var grass_pad := (
		_grass_min_radius * _rng.randf_range(0.88, 1.0)
		if not scenic
		else big_r * _rng.randf_range(0.38, 0.48)
	)

	# Domain warp: bend the angle each ray samples the silhouette at, so the
	# coast jogs sideways instead of only in/out — kills the "trig curve" look.
	var warp_amp := 0.16 if not scenic else 0.1

	for i in ISLAND_LUT_SIZE:
		var theta := TAU * float(i) / float(ISLAND_LUT_SIZE)
		var nx := cos(theta) * 3.0
		var ny := sin(theta) * 3.0
		# Warped angle for silhouette sampling (grass pad stays unwarped).
		var theta_w := theta + fine.get_noise_2d(nx * 0.8 + 77.0, ny * 0.8 + 77.0) * warp_amp
		var shape_m := _lut_at(profile, theta_w)
		var shelf_b := _lut_at(shelf_boost, theta_w)
		# Ellipse stretch along the silhouette axis (sand only).
		var ellipse := 1.0 + stretch * cos(2.0 * (theta_w - axis))
		shape_m *= ellipse
		# Radial fBm on top of the warp — eroded, not authored.
		shape_m *= 1.0 + fine.get_noise_2d(nx * 1.3 + 200.0, ny * 1.3 + 200.0) * 0.09

		# Grass hugs the castle — readable target pad, never an arm of green.
		var g := grass_pad + fine.get_noise_2d(nx, ny) * 0.04 * grass_pad
		g += harmonics[0][1] * 0.35 * sin(harmonics[0][0] * theta + harmonics[0][3])
		var g_floor: float = (
			GameConfig.FORT_CLEAR_RADIUS * 0.92 if not scenic else grass_pad * 0.7
		)
		g = clampf(g, g_floor, grass_cap)

		# Sand follows the coast silhouette — arms/spits are beach, not grass.
		var s := sand_base * shape_m + fine.get_noise_2d(nx + 9.0, ny + 9.0) * 0.04 * big_r
		for h in harmonics:
			s += h[2] * sin(h[0] * theta_w + h[3] + 0.7)
		var shelf := lerpf(38.0, 110.0, shelf_b)
		# Long beaches opposite deep bites; thin shelves inside coves.
		if shape_m < 0.85:
			shelf = lerpf(28.0, 48.0, shape_m)
		if scenic:
			shelf = lerpf(12.0, 34.0, shelf_b)
		# Lee side (downwind) collects sand: wide sheltered beach. Windward
		# side is wave-cut: tighter shelf.
		var lee := 0.5 + 0.5 * cos(theta - wind)
		shelf *= lerpf(0.72, 1.3, lee)
		# Erratic beach width so the sand ring never reads as concentric.
		shelf += fine.get_noise_2d(nx * 1.7 + 40.0, ny * 1.7 + 40.0) * (8.0 if scenic else 20.0)
		# Arms: sand must clear the keep-pad with a real beach, then stretch out.
		var sand_min := g + (22.0 if scenic else 36.0)
		s = maxf(s, sand_min + shelf * 0.35)
		s = clampf(s, sand_min, sand_cap)
		# Prefer the profiled sand when the shelf boost asks for a wide beach.
		if shelf_b > 0.55:
			s = maxf(s, g + shelf)
		_grass_lut[i] = g
		_sand_lut[i] = minf(s, sand_cap)

	# Kill only pixel-level wiggle; keep the chunky erratic bumps.
	# Arm silhouettes need fewer passes or the spit melts back into a blob.
	var smooth_passes := 1 if arm_extend else 2
	_smooth_lut(_grass_lut, smooth_passes)
	_smooth_lut(_sand_lut, smooth_passes)
	for i in ISLAND_LUT_SIZE:
		# Re-assert: grass never exceeds the keep-pad cap after smoothing.
		_grass_lut[i] = minf(_grass_lut[i], grass_cap)
		_sand_lut[i] = maxf(_sand_lut[i], _grass_lut[i] + (18.0 if scenic else 30.0))

	_islets.clear()
	var want_islets := (
		_coast_shape == CoastShape.LOBED
		or _coast_shape == CoastShape.PENINSULA
		or _coast_shape == CoastShape.ARM
		or _coast_shape == CoastShape.HOOK
		or _rng.randf() < 0.4
	)
	if want_islets and not scenic:
		var islet_n := _rng.randi_range(1, 3) if _coast_shape == CoastShape.LOBED else _rng.randi_range(1, 2)
		for i in islet_n:
			# Fragments continue the spit downwind — broken-off, not sprinkled.
			var ang := wind + _rng.randf_range(-0.6, 0.6)
			if _coast_shape == CoastShape.LOBED:
				ang = axis + TAU * float(i) / 3.0 + _rng.randf_range(-0.3, 0.3)
			elif _coast_shape == CoastShape.ARM or _coast_shape == CoastShape.HOOK:
				# Satellite off the tip of the arm.
				ang = axis + _rng.randf_range(-0.35, 0.35)
			var islet_r := _rng.randf_range(14.0, 30.0)
			var lo := _lut_at(_sand_lut, ang) + islet_r + 18.0
			var hi := sand_cap - islet_r - 2.0
			if hi <= lo:
				continue
			_islets.append([Vector2.from_angle(ang) * _rng.randf_range(lo, hi), islet_r])

	# Shallow lobes: irregular turquoise patches that connect to the shelf.
	# Sandbars drift downwind, so bias placement toward the lee side.
	_shallow_lobes.clear()
	var lobe_n := _rng.randi_range(3, 5) if scenic else _rng.randi_range(4, 7)
	for i in lobe_n:
		var ang: float
		if _rng.randf() < 0.6:
			# Lee cluster: within ~80° of the wind direction.
			ang = wind + _rng.randf_range(-1.4, 1.4) * 0.55
		else:
			ang = axis + TAU * float(i) / float(lobe_n) + _rng.randf_range(-0.7, 0.7)
		var sand_r := _lut_at(_sand_lut, ang)
		var lobe_r := _rng.randf_range(24.0, 55.0) if scenic else _rng.randf_range(32.0, 70.0)
		# Lee lobes sit further out (drifting bar); windward ones hug the surf.
		var lee_l := 0.5 + 0.5 * cos(ang - wind)
		var d := sand_r + _rng.randf_range(2.0, 12.0 + 30.0 * lee_l)
		_shallow_lobes.append([Vector2.from_angle(ang) * d, lobe_r])


## Writes a 0.55–1.6 radius multiplier and a 0–1 beach-width boost per LUT sample.
func _build_coast_profile(profile: PackedFloat32Array, shelf_boost: PackedFloat32Array, axis: float) -> void:
	# Arm-like shapes are chains of gaussian bumps — each segment drifts
	# sideways and narrows, like a wind-built sand spit accreting seaward.
	# Gaussians (not linear tents) keep shoulders and tips rounded.
	var arm_bumps: Array = []
	if (
		_coast_shape == CoastShape.ARM
		or _coast_shape == CoastShape.HOOK
		or _coast_shape == CoastShape.PENINSULA
	):
		var bend_dir := 1.0 if _rng.randf() < 0.5 else -1.0
		var seg_n := 3
		var seg_ang := 0.0
		var reach := 1.22
		var width := 0.48
		# Per-shape character: peninsula = short/broad, arm = long/straightish,
		# hook = long with a hard sideways drift.
		var bend_scale := 0.5
		match _coast_shape:
			CoastShape.PENINSULA:
				seg_n = 2
				reach = 1.28
				width = 0.56
				bend_scale = 0.4
			CoastShape.ARM:
				bend_scale = 0.55
			CoastShape.HOOK:
				bend_scale = 1.0
		for s in seg_n:
			# Jitter each segment so no two arms share a silhouette.
			arm_bumps.append([
				seg_ang,
				reach * _rng.randf_range(0.96, 1.04),
				width * _rng.randf_range(0.88, 1.12),
			])
			seg_ang += bend_dir * _rng.randf_range(0.2, 0.38) * bend_scale
			reach += _rng.randf_range(0.13, 0.2)
			width *= _rng.randf_range(0.62, 0.76)
		# Small opposing stub so the island doesn't look glued to one side.
		arm_bumps.append([PI + _rng.randf_range(-0.3, 0.3), 0.98, 0.34])

	for i in ISLAND_LUT_SIZE:
		var theta := TAU * float(i) / float(ISLAND_LUT_SIZE)
		var m := 1.0
		var shelf := 0.35
		match _coast_shape:
			CoastShape.ROUND:
				m = 1.0 + 0.1 * sin(2.0 * theta + axis)
				shelf = 0.4 + 0.15 * sin(theta * 3.0 + axis)
			CoastShape.BAY:
				# Deep horseshoe bite + fat beach on the far side.
				var d := absf(wrapf(theta - axis, -PI, PI))
				var bite := exp(-0.5 * pow(d / 0.55, 2.0))
				m = 1.0 - 0.38 * bite + 0.12 * exp(-0.5 * pow(wrapf(theta - axis - PI, -PI, PI) / 0.7, 2.0))
				# Headlands flanking the mouth.
				m += 0.14 * exp(-0.5 * pow(absf(d - 0.7) / 0.22, 2.0))
				shelf = lerpf(0.25, 0.95, 1.0 - bite)
			CoastShape.DOUBLE_BAY:
				var d1 := absf(wrapf(theta - axis, -PI, PI))
				var d2 := absf(wrapf(theta - axis - PI, -PI, PI))
				var bite := maxf(exp(-0.5 * pow(d1 / 0.5, 2.0)), exp(-0.5 * pow(d2 / 0.5, 2.0)))
				m = 1.0 - 0.34 * bite
				m += 0.16 * exp(-0.5 * pow(absf(wrapf(theta - axis - PI * 0.5, -PI, PI)) / 0.35, 2.0))
				m += 0.16 * exp(-0.5 * pow(absf(wrapf(theta - axis + PI * 0.5, -PI, PI)) / 0.35, 2.0))
				shelf = lerpf(0.3, 0.9, 1.0 - bite)
			CoastShape.CRESCENT:
				var along := cos(theta - axis)
				m = lerpf(0.58, 1.22, (along + 1.0) * 0.5)
				# Scoop the inner arc.
				var inner := exp(-0.5 * pow(wrapf(theta - axis - PI, -PI, PI) / 0.85, 2.0))
				m -= 0.22 * inner
				shelf = lerpf(0.35, 1.0, 1.0 - inner)
			CoastShape.PENINSULA, CoastShape.ARM, CoastShape.HOOK:
				# Rounded body + the chained gaussian spit built above.
				var body := lerpf(0.64, 0.82, 0.5 + 0.5 * cos(theta - axis + PI * 0.2))
				m = body
				var spit := 0.0
				for b in arm_bumps:
					var d := absf(wrapf(theta - axis - b[0], -PI, PI))
					var gauss: float = exp(-0.5 * pow(d / b[2], 2.0))
					m = maxf(m, lerpf(body, b[1], gauss))
					spit = maxf(spit, gauss)
				shelf = lerpf(0.35, 1.0, spit)
			CoastShape.KIDNEY:
				var along := cos(theta - axis)
				m = lerpf(0.7, 1.15, absf(along))
				var notch := exp(-0.5 * pow(wrapf(theta - axis - PI * 0.5, -PI, PI) / 0.45, 2.0))
				m -= 0.22 * notch
				shelf = lerpf(0.3, 0.85, 1.0 - notch)
			CoastShape.COVE:
				var d := absf(wrapf(theta - axis, -PI, PI))
				var mouth := exp(-0.5 * pow(d / 0.32, 2.0))
				m = 1.0 - 0.42 * mouth
				# Pinch the entrance with two horns.
				m += 0.2 * exp(-0.5 * pow(absf(d - 0.42) / 0.14, 2.0))
				shelf = lerpf(0.2, 0.75, 1.0 - mouth)
			CoastShape.LOBED:
				var tri := 0.5 + 0.5 * cos(3.0 * (theta - axis))
				m = lerpf(0.68, 1.32, pow(tri, 1.1))
				shelf = lerpf(0.45, 0.9, tri)
		profile[i] = clampf(m, 0.48, 1.75)
		shelf_boost[i] = clampf(shelf, 0.0, 1.0)


func _smooth_lut(lut: PackedFloat32Array, passes: int) -> void:
	for p in passes:
		var src := lut.duplicate()
		for i in ISLAND_LUT_SIZE:
			var a := src[(i - 1 + ISLAND_LUT_SIZE) % ISLAND_LUT_SIZE]
			var b := src[i]
			var c := src[(i + 1) % ISLAND_LUT_SIZE]
			lut[i] = (a + b * 2.0 + c) * 0.25


func _lut_at(lut: PackedFloat32Array, theta: float) -> float:
	var t := fposmod(theta, TAU) / TAU * float(ISLAND_LUT_SIZE)
	var i := int(t) % ISLAND_LUT_SIZE
	return lerpf(lut[i], lut[(i + 1) % ISLAND_LUT_SIZE], t - float(i))
