class_name Island
extends Node2D

## One fortress island: procedural coast, keep, corner AA, outer towers, trees.

signal keep_destroyed
signal keep_hp_changed(current: int, maximum: int)

const ISLAND_LUT_SIZE := 256
## Coarse texture for distant bastions; the active island uses near-native.
const ISLAND_IMG_SCALE := 3.0
const ISLAND_IMG_SCALE_ACTIVE := 1.5
const GRASS_MIN_RADIUS_BASE := 145.0

## How much beach texture to generate during build().
enum BakeQuality {
	NONE, ## Shape + defenses only; texture queued later.
	COARSE, ## Async low-res (distant islands).
	HIRES, ## Sync near-native (active bastion — ready before play).
}

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
var _base_sprite: Sprite2D
var _hires_done := false
var _hires_baking := false
## Bumped to discard superseded WorkerThreadPool bake results.
var _bake_gen := 0
var _bake_task_id := -1
var _built := false

var _keep_scene: PackedScene = preload("res://scenes/keep.tscn")
var _turret_scene: PackedScene = preload("res://scenes/turret.tscn")
var _tower_scene: PackedScene = preload("res://scenes/tower.tscn")

@onready var land: Node2D = $Land
@onready var keep: Keep = $Keep
@onready var turrets_root: Node2D = $Turrets
@onready var towers_root: Node2D = $Towers


func build(level_num: int, main_ref: Node2D, quality: BakeQuality = BakeQuality.COARSE) -> void:
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
	_bake_gen += 1
	_hires_done = false
	_hires_baking = false
	_base_sprite = Sprite2D.new()
	_base_sprite.position = Vector2.ZERO
	_base_sprite.z_index = -2
	land.add_child(_base_sprite)

	_place_keep()
	_place_turrets()
	_scatter_towers()
	_scatter_trees()
	_built = true
	_finish_bake(quality)
	set_active(false)


## Empty tropical islet — land + palms only. Used to break up open ocean.
func build_scenic(seed_key: int, radius: float, main_ref: Node2D, quality: BakeQuality = BakeQuality.COARSE) -> void:
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
	_bake_gen += 1
	_hires_done = false
	_hires_baking = false
	_base_sprite = Sprite2D.new()
	_base_sprite.position = Vector2.ZERO
	_base_sprite.z_index = -2
	land.add_child(_base_sprite)

	_scatter_trees()
	_built = true
	_finish_bake(quality)
	set_active(false)


func _finish_bake(quality: BakeQuality) -> void:
	match quality:
		BakeQuality.HIRES:
			var img := _render_island_image(ISLAND_IMG_SCALE_ACTIVE)
			_base_sprite.texture = ImageTexture.create_from_image(img)
			_base_sprite.scale = Vector2.ONE * ISLAND_IMG_SCALE_ACTIVE
			_hires_done = true
		BakeQuality.COARSE:
			_start_bake_async(false)
		BakeQuality.NONE:
			pass


func _hide_keep() -> void:
	if keep == null:
		return
	keep.visible = false
	keep.set_process(false)
	if keep.hp_bar:
		keep.hp_bar.visible = false


func is_built() -> bool:
	return _built


## Kick a background hi-res bake so the next level has a crisp beach ready.
func prefetch_hires() -> void:
	if not _built or _hires_done or _hires_baking:
		return
	_start_bake_async(true)


## Block until a hi-res beach texture exists — used when activating a bastion.
func ensure_hires_ready() -> void:
	if not _built or _hires_done:
		return
	# Invalidate any in-flight coarse/hires worker, then bake sync on the main thread.
	_bake_gen += 1
	_hires_baking = false
	_bake_task_id = -1
	var img := _render_island_image(ISLAND_IMG_SCALE_ACTIVE)
	if _base_sprite and is_instance_valid(_base_sprite):
		_base_sprite.texture = ImageTexture.create_from_image(img)
		_base_sprite.scale = Vector2.ONE * ISLAND_IMG_SCALE_ACTIVE
	_hires_done = true


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
	# Pixel math runs on WorkerThreadPool; only ImageTexture apply hits the main thread.
	if on and not _hires_done and not _hires_baking:
		_start_bake_async(true)
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


func _exit_tree() -> void:
	# Workers must not touch this Node — wait so free() during rebuild can't race.
	_bake_gen += 1
	if _bake_task_id >= 0:
		WorkerThreadPool.wait_for_task_completion(_bake_task_id)
		_bake_task_id = -1
	_hires_baking = false


func _bake_hires() -> void:
	## Kept for callers; routes through the threaded path.
	_start_bake_async(true)


func _start_bake_async(hires: bool) -> void:
	if not is_instance_valid(self) or _base_sprite == null:
		return
	if hires:
		if _hires_done or _hires_baking:
			return
		_hires_baking = true
	# Bump gen so any in-flight bake's result is discarded (workers use snapshots only).
	_bake_gen += 1
	var gen := _bake_gen
	var img_scale := ISLAND_IMG_SCALE_ACTIVE if hires else ISLAND_IMG_SCALE
	# Snapshot all inputs so the worker never touches this Node.
	var snap_radius := island_radius
	var snap_level := level
	var snap_sand := _sand_lut.duplicate()
	var snap_grass := _grass_lut.duplicate()
	var snap_islets: Array = _islets.duplicate(true)
	var snap_lobes: Array = _shallow_lobes.duplicate(true)
	var result_holder: Array = []
	_bake_task_id = WorkerThreadPool.add_task(func() -> void:
		result_holder.append(Island.render_island_image(
			img_scale, snap_radius, snap_level, snap_sand, snap_grass, snap_islets, snap_lobes
		))
	)
	_finish_bake_async(_bake_task_id, result_holder, img_scale, hires, gen)


func _finish_bake_async(
	task_id: int, result_holder: Array, img_scale: float, hires: bool, gen: int
) -> void:
	while not WorkerThreadPool.is_task_completed(task_id):
		await get_tree().process_frame
	WorkerThreadPool.wait_for_task_completion(task_id)
	if _bake_task_id == task_id:
		_bake_task_id = -1
	if not is_instance_valid(self) or gen != _bake_gen:
		return
	if result_holder.is_empty():
		if hires:
			_hires_baking = false
		return
	# Don't let a late coarse bake overwrite a hi-res (or in-flight hi-res).
	if not hires and (_hires_done or _hires_baking):
		return
	var img: Image = result_holder[0]
	if _base_sprite and is_instance_valid(_base_sprite):
		_base_sprite.texture = ImageTexture.create_from_image(img)
		_base_sprite.scale = Vector2.ONE * img_scale
	if hires:
		_hires_done = true
		_hires_baking = false


## Thread-safe pixel bake — no Node access; all inputs are value snapshots.
static func render_island_image(
	img_scale: float,
	p_radius: float,
	p_level: int,
	sand_lut: PackedFloat32Array,
	grass_lut: PackedFloat32Array,
	islets: Array,
	shallow_lobes: Array,
) -> Image:
	var pad := 110.0
	# Arms / islets can stick past the nominal radius — size the bake to the true extent.
	var extent := p_radius
	for i in sand_lut.size():
		extent = maxf(extent, sand_lut[i])
	for islet in islets:
		extent = maxf(extent, islet[0].length() + float(islet[1]))
	for lobe in shallow_lobes:
		extent = maxf(extent, lobe[0].length() + float(lobe[1]))
	var size := int(ceil((extent + pad) * 2.0 / img_scale))
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	var c := size * 0.5
	var tex_noise := FastNoiseLite.new()
	tex_noise.seed = hash("grain_%d" % p_level)
	tex_noise.frequency = 0.14
	tex_noise.fractal_octaves = 2
	for y in size:
		for x in size:
			var p := Vector2(float(x) - c + 0.5, float(y) - c + 0.5) * img_scale
			var dist := p.length()
			var theta := atan2(p.y, p.x)
			var col := _shade_island_static(
				p, dist, _lut_at_static(sand_lut, theta), _lut_at_static(grass_lut, theta), tex_noise
			)
			for islet in islets:
				var islet_dist: float = p.distance_to(islet[0])
				var islet_r: float = islet[1]
				if islet_dist > islet_r + 78.0:
					continue
				var islet_grass := islet_r * 0.55 if islet_r > 15.0 else 0.0
				var icol := _shade_island_static(p, islet_dist, islet_r, islet_grass, tex_noise)
				if icol.a > col.a:
					col = icol
			var sand_here := _lut_at_static(sand_lut, theta)
			if dist >= sand_here - 1.0:
				for lobe in shallow_lobes:
					var ld: float = p.distance_to(lobe[0])
					var lr: float = lobe[1]
					if ld > lr:
						continue
					var la := (1.0 - smoothstep(lr * 0.15, lr, ld)) * 0.72
					la *= 0.65 + 0.35 * tex_noise.get_noise_2d(p.x * 0.1 + 50.0, p.y * 0.1)
					if la <= 0.004:
						continue
					var sc := Color(0.60, 0.90, 0.88).lerp(Color(0.80, 0.97, 0.95), 1.0 - ld / lr)
					var a := maxf(col.a, la)
					var t := la / maxf(a, 0.001)
					col = Color(
						lerpf(col.r, sc.r, t),
						lerpf(col.g, sc.g, t),
						lerpf(col.b, sc.b, t),
						a,
					)
			if col.a > 0.004:
				img.set_pixel(x, y, col)
	return img


static func _lut_at_static(lut: PackedFloat32Array, theta: float) -> float:
	if lut.is_empty():
		return 0.0
	var n := lut.size()
	var t := fposmod(theta, TAU) / TAU * float(n)
	var i := int(t) % n
	return lerpf(lut[i], lut[(i + 1) % n], t - float(i))


static func _shade_island_static(
	p: Vector2, dist: float, sand_r: float, grass_r: float, noise: FastNoiseLite
) -> Color:
	# Irregular turquoise shelf — width varies, with connected bulges,
	# so it doesn't read as a uniform coast-hugging ring.
	var n_lo := noise.get_noise_2d(p.x * 0.038 + 120.0, p.y * 0.038)
	var n_mid := noise.get_noise_2d(p.x * 0.078 + 880.0, p.y * 0.078)
	var n_bar := noise.get_noise_2d(p.x * 0.05 + 300.0, p.y * 0.05)
	# Always a readable base shelf; noise only warps how far it reaches.
	var shelf_w := lerpf(16.0, 44.0, 0.5 + 0.5 * n_lo)
	shelf_w += maxf(0.0, n_mid - 0.1) * 38.0
	var bar := maxf(0.0, n_bar - 0.1)
	shelf_w += bar * 55.0
	shelf_w = clampf(shelf_w, 14.0, 85.0)
	var shallow_a := (1.0 - smoothstep(sand_r, sand_r + shelf_w, dist)) * 0.7
	# Mild mottling — never erase the shelf.
	shallow_a *= lerpf(0.72, 1.0, clampf(0.5 + n_mid * 0.55 + bar * 0.3, 0.0, 1.0))
	var land_a := 1.0 - smoothstep(sand_r - 2.0, sand_r + 2.0, dist)
	if shallow_a <= 0.004 and land_a <= 0.004:
		return Color(0, 0, 0, 0)
	var near := 1.0 - smoothstep(sand_r, sand_r + maxf(12.0, shelf_w * 0.5), dist)
	var out := Color(0.62, 0.90, 0.88).lerp(Color(0.82, 0.97, 0.95), near * 0.85)
	out.a = shallow_a
	# Foam: undulating surf, always present but uneven.
	var foam_w := 11.0 + noise.get_noise_2d(p.x * 0.22 + 400.0, p.y * 0.22) * 6.0
	var foam := (1.0 - smoothstep(0.0, foam_w, absf(dist - (sand_r + 1.0)))) * 0.75
	var foam_patch := clampf(0.5 + noise.get_noise_2d(p.x * 0.11 + 510.0, p.y * 0.11) * 0.7, 0.35, 1.0)
	foam *= foam_patch
	if foam > 0.01:
		out = Color(
			lerpf(out.r, 0.98, foam),
			lerpf(out.g, 0.99, foam),
			lerpf(out.b, 0.96, foam),
			maxf(out.a, foam * 0.85),
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


func _render_island_image(img_scale: float) -> Image:
	return Island.render_island_image(
		img_scale, island_radius, level, _sand_lut, _grass_lut, _islets, _shallow_lobes
	)


func _shade_island(p: Vector2, dist: float, sand_r: float, grass_r: float, noise: FastNoiseLite) -> Color:
	return Island._shade_island_static(p, dist, sand_r, grass_r, noise)
