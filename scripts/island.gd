class_name Island
extends Node2D

## One fortress island: procedural coast, keep, corner AA, outer towers, trees.

signal keep_destroyed
signal keep_hp_changed(current: int, maximum: int)

const ISLAND_LUT_SIZE := 256
## Coarse texture for cheap boot-time builds; the active island re-renders
## near-native on a background thread so its beach stays crisp.
const ISLAND_IMG_SCALE := 3.0
const ISLAND_IMG_SCALE_ACTIVE := 1.5
const GRASS_MIN_RADIUS_BASE := 145.0

## Distinct coastline silhouettes so every bastion reads differently.
enum CoastShape {
	ROUND,
	BAY,
	DOUBLE_BAY,
	CRESCENT,
	PENINSULA,
	KIDNEY,
	COVE,
	LOBED,
}

var level: int = 1
var island_radius: float = GameConfig.ISLAND_RADIUS
var active: bool = false

var _main: Node2D
var _rng := RandomNumberGenerator.new()
var _sand_lut: PackedFloat32Array = PackedFloat32Array()
var _grass_lut: PackedFloat32Array = PackedFloat32Array()
var _islets: Array = []
var _tower_positions: Array[Vector2] = []
var _turret_positions: Array[Vector2] = []
var _grass_min_radius: float = GRASS_MIN_RADIUS_BASE
var _coast_shape: CoastShape = CoastShape.ROUND
var _base_sprite: Sprite2D
var _hires_thread: Thread
var _hires_done := false

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
	# Stable per-level seed so each bastion keeps its silhouette across retries.
	_rng.seed = hash("bastion_%d" % level)
	island_radius = GameConfig.island_radius_for_level(level)
	_grass_min_radius = lerpf(120.0, 155.0, GameConfig.level_t(level))
	if GameConfig.is_stronghold_level(level):
		_grass_min_radius = lerpf(_grass_min_radius, 175.0, 0.7)
	_coast_shape = _coast_shape_for_level(level)

	_clear_children(land)
	_clear_defenses(false)

	_generate_island_shape()
	_hires_done = false
	_base_sprite = Sprite2D.new()
	_base_sprite.texture = ImageTexture.create_from_image(_render_island_image(ISLAND_IMG_SCALE))
	_base_sprite.position = Vector2.ZERO
	_base_sprite.scale = Vector2.ONE * ISLAND_IMG_SCALE
	_base_sprite.z_index = -2
	land.add_child(_base_sprite)

	_place_keep()
	_place_turrets()
	_scatter_towers()
	_scatter_trees()
	set_active(false)


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
	if on and not _hires_done and _hires_thread == null:
		_hires_thread = Thread.new()
		_hires_thread.start(_hires_render_worker)
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
			if _main and _main.has_method("_spawn_explosion"):
				_main._spawn_explosion(pos, 1.4, _main.Boom.BOMB)
		)


func _scatter_towers() -> void:
	_tower_positions.clear()
	var rng_range := GameConfig.tower_count_range_for_level(level)
	var count := _rng.randi_range(rng_range.x, rng_range.y)
	var center := Vector2.ZERO
	var blocked: Array[Vector2] = _turret_positions.duplicate()
	# Stratify angles so guns fan across the island instead of clustering.
	var sector := TAU / float(maxi(count, 1))
	var sector_offset := _rng.randf() * TAU

	var attempts := 0
	var slot := 0
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
		# Fan across the band — not stacked on the keep, not on the shoreline.
		var t := _rng.randf_range(0.2, 0.95)
		var dist := lerpf(min_d, max_d, t)
		var pos := center + Vector2.from_angle(theta) * dist
		var too_close := false
		for b in blocked:
			if pos.distance_to(b) < 72.0:
				too_close = true
				break
		if too_close:
			continue
		for p in _tower_positions:
			if pos.distance_to(p) < 90.0:
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
## missiles from 4, flak batteries from 13. Newly unlocked tiers get one
## guaranteed emplacement so the change is visible.
func _pick_tower_weapon(index: int) -> Tower.Weapon:
	if level >= GameConfig.FLAK_TOWER_UNLOCK_LEVEL and index == 0:
		return Tower.Weapon.FLAK
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
	var beach_len_est := 0.0
	for i in ISLAND_LUT_SIZE:
		var theta := TAU * float(i) / float(ISLAND_LUT_SIZE)
		var sand_r := _sand_lut[i]
		var grass_r := _grass_lut[i]
		var shelf := sand_r - grass_r
		if shelf > 55.0:
			long_beach_slots.append(theta)
			beach_len_est += shelf
	# A handful of shoreline palms, a few more where beaches run long.
	var base_count := _rng.randi_range(3, 5)
	if GameConfig.is_stronghold_level(level):
		base_count += _rng.randi_range(2, 4)
	var beach_bonus := clampi(int(beach_len_est / 400.0), 0, 6)
	var count := mini(base_count + beach_bonus, 10)

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
		if d < GameConfig.FORT_CLEAR_RADIUS + 25.0:
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
		return CoastShape.CRESCENT
	if level_num == 20:
		return CoastShape.LOBED
	var order: Array[CoastShape] = [
		CoastShape.ROUND,
		CoastShape.BAY,
		CoastShape.PENINSULA,
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

	var grass_base := big_r * _rng.randf_range(0.48, 0.56)
	var sand_base := big_r * _rng.randf_range(0.84, 0.94)
	var axis := _rng.randf() * TAU

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

	for i in ISLAND_LUT_SIZE:
		var theta := TAU * float(i) / float(ISLAND_LUT_SIZE)
		var nx := cos(theta) * 3.0
		var ny := sin(theta) * 3.0
		var shape_m := profile[i]
		var g := grass_base * shape_m + fine.get_noise_2d(nx, ny) * 0.028 * big_r
		var s := sand_base * shape_m + fine.get_noise_2d(nx + 9.0, ny + 9.0) * 0.04 * big_r
		for h in harmonics:
			g += h[1] * sin(h[0] * theta + h[3])
			s += h[2] * sin(h[0] * theta + h[3] + 0.7)
		# Keep the fort clear, but let bays cut deep into the outer ring.
		var g_floor := _grass_min_radius * lerpf(0.72, 0.92, shape_m)
		g = clampf(g, g_floor, big_r * 0.72)
		var shelf := lerpf(38.0, 110.0, shelf_boost[i])
		# Long beaches opposite deep bites; thin shelves inside coves.
		if shape_m < 0.85:
			shelf = lerpf(28.0, 48.0, shape_m)
		# Erratic beach width so the sand ring never reads as concentric.
		shelf += fine.get_noise_2d(nx * 1.7 + 40.0, ny * 1.7 + 40.0) * 20.0
		s = clampf(s, g + shelf * 0.85, minf(big_r, g + shelf + 20.0))
		# Prefer the profiled sand when the shelf boost asks for a wide beach.
		if shelf_boost[i] > 0.55:
			s = maxf(s, g + shelf)
		_grass_lut[i] = g
		_sand_lut[i] = minf(s, big_r)

	# Kill only pixel-level wiggle; keep the chunky erratic bumps.
	_smooth_lut(_grass_lut, 2)
	_smooth_lut(_sand_lut, 2)
	for i in ISLAND_LUT_SIZE:
		_sand_lut[i] = maxf(_sand_lut[i], _grass_lut[i] + 30.0)

	var want_islets := _coast_shape == CoastShape.LOBED or _coast_shape == CoastShape.PENINSULA or _rng.randf() < 0.4
	if want_islets:
		var islet_n := _rng.randi_range(1, 3) if _coast_shape == CoastShape.LOBED else _rng.randi_range(1, 2)
		for i in islet_n:
			var ang := axis + PI + _rng.randf_range(-1.0, 1.0)
			if _coast_shape == CoastShape.LOBED:
				ang = axis + TAU * float(i) / 3.0 + _rng.randf_range(-0.3, 0.3)
			var islet_r := _rng.randf_range(14.0, 30.0)
			var lo := _lut_at(_sand_lut, ang) + islet_r + 18.0
			var hi := big_r - islet_r - 2.0
			if hi <= lo:
				continue
			_islets.append([Vector2.from_angle(ang) * _rng.randf_range(lo, hi), islet_r])


## Writes a 0.55–1.25 radius multiplier and a 0–1 beach-width boost per LUT sample.
func _build_coast_profile(profile: PackedFloat32Array, shelf_boost: PackedFloat32Array, axis: float) -> void:
	for i in ISLAND_LUT_SIZE:
		var theta := TAU * float(i) / float(ISLAND_LUT_SIZE)
		var m := 1.0
		var shelf := 0.35
		match _coast_shape:
			CoastShape.ROUND:
				m = 1.0 + 0.06 * sin(2.0 * theta + axis)
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
				m = lerpf(0.62, 1.18, (along + 1.0) * 0.5)
				# Scoop the inner arc.
				var inner := exp(-0.5 * pow(wrapf(theta - axis - PI, -PI, PI) / 0.85, 2.0))
				m -= 0.18 * inner
				shelf = lerpf(0.35, 1.0, 1.0 - inner)
			CoastShape.PENINSULA:
				var along := cos(theta - axis)
				m = lerpf(0.78, 1.28, pow((along + 1.0) * 0.5, 1.4))
				shelf = lerpf(0.55, 0.85, (along + 1.0) * 0.5)
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
				m = lerpf(0.72, 1.22, pow(tri, 1.1))
				shelf = lerpf(0.45, 0.9, tri)
		profile[i] = clampf(m, 0.55, 1.3)
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


func _hires_render_worker() -> void:
	var img := _render_island_image(ISLAND_IMG_SCALE_ACTIVE)
	_apply_hires_texture.call_deferred(img)


func _apply_hires_texture(img: Image) -> void:
	if _hires_thread:
		_hires_thread.wait_to_finish()
		_hires_thread = null
	_hires_done = true
	if _base_sprite and is_instance_valid(_base_sprite):
		_base_sprite.texture = ImageTexture.create_from_image(img)
		_base_sprite.scale = Vector2.ONE * ISLAND_IMG_SCALE_ACTIVE


func _exit_tree() -> void:
	if _hires_thread:
		_hires_thread.wait_to_finish()
		_hires_thread = null


func _render_island_image(img_scale: float) -> Image:
	var pad := 26.0
	var size := int(ceil((island_radius + pad) * 2.0 / img_scale))
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	var c := size * 0.5
	# Smooth spatial noise for sand/grass texture — per-pixel white noise reads
	# as static at near-native res. Deterministic per level, thread-safe reads.
	var tex_noise := FastNoiseLite.new()
	tex_noise.seed = hash("grain_%d" % level)
	tex_noise.frequency = 0.14
	tex_noise.fractal_octaves = 2
	for y in size:
		for x in size:
			var p := Vector2(float(x) - c + 0.5, float(y) - c + 0.5) * img_scale
			var dist := p.length()
			var theta := atan2(p.y, p.x)
			# Bake shallow halo so open-ocean water still reads a shoreline.
			var col := _shade_island(p, dist, _lut_at(_sand_lut, theta), _lut_at(_grass_lut, theta), tex_noise)
			for islet in _islets:
				var islet_dist: float = p.distance_to(islet[0])
				var islet_r: float = islet[1]
				if islet_dist > islet_r + 26.0:
					continue
				var islet_grass := islet_r * 0.55 if islet_r > 15.0 else 0.0
				var icol := _shade_island(p, islet_dist, islet_r, islet_grass, tex_noise)
				if icol.a > col.a:
					col = icol
			if col.a > 0.004:
				img.set_pixel(x, y, col)
	return img


func _shade_island(p: Vector2, dist: float, sand_r: float, grass_r: float, noise: FastNoiseLite) -> Color:
	var shallow_a := (1.0 - smoothstep(sand_r, sand_r + 22.0, dist)) * 0.4
	var land_a := 1.0 - smoothstep(sand_r - 2.0, sand_r + 2.0, dist)
	if shallow_a <= 0.004 and land_a <= 0.004:
		return Color(0, 0, 0, 0)
	# Shallow water: brighter turquoise hugging the shore, fading seaward.
	var near := 1.0 - smoothstep(sand_r, sand_r + 22.0, dist)
	var out := Color(0.45, 0.78, 0.76).lerp(Color(0.62, 0.88, 0.84), near * 0.6)
	out.a = shallow_a
	# Foam band hugging the waterline — width undulates so it reads as surf.
	var foam_w := 12.0 + noise.get_noise_2d(p.x * 0.22 + 400.0, p.y * 0.22) * 6.0
	var foam := (1.0 - smoothstep(0.0, foam_w, absf(dist - (sand_r + 1.0)))) * 0.85
	if foam > 0.01:
		out = Color(
			lerpf(out.r, 0.98, foam),
			lerpf(out.g, 0.99, foam),
			lerpf(out.b, 0.96, foam),
			maxf(out.a, foam * 0.9),
		)
	if land_a > 0.004:
		var dry := Color(0.94, 0.85, 0.60)
		var wet_sand := Color(0.66, 0.56, 0.40)
		# Wave-washed wet band, patchy around the coast: some stretches soaked,
		# others nearly dry, so the dark edge never reads as a uniform ring.
		var wave := noise.get_noise_2d(p.x * 0.18 + 250.0, p.y * 0.18) * 9.0
		var wet_mod := clampf(0.5 + noise.get_noise_2d(p.x * 0.04 + 700.0, p.y * 0.04) * 1.1, 0.12, 1.0)
		var wet := smoothstep(sand_r - 46.0 + wave, sand_r - 4.0, dist)
		var col := dry.lerp(wet_sand, wet * wet * wet_mod)
		var grain := noise.get_noise_2d(p.x, p.y) * 0.035
		col = Color(col.r + grain, col.g + grain * 0.85, col.b + grain * 0.65)
		if grass_r > 0.0:
			var g := 1.0 - smoothstep(grass_r - 10.0, grass_r + 10.0, dist)
			var glow := clampf(1.0 - dist / maxf(grass_r * 0.9, 1.0), 0.0, 1.0) * 0.55
			var grass_col := Color(0.34, 0.60, 0.26).lerp(Color(0.55, 0.72, 0.38), glow)
			var patch := noise.get_noise_2d(p.x * 0.3 + 900.0, p.y * 0.3) * 0.03
			grass_col = Color(grass_col.r + patch, grass_col.g + patch, grass_col.b + patch * 0.6)
			var rim := (1.0 - smoothstep(0.0, 12.0, absf(dist - (grass_r - 6.0)))) * 0.1
			col = col.lerp(grass_col.darkened(rim), g)
		out = Color(
			lerpf(out.r, col.r, land_a),
			lerpf(out.g, col.g, land_a),
			lerpf(out.b, col.b, land_a),
			land_a + out.a * (1.0 - land_a),
		)
	return out
