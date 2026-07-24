extends Node2D

## Campaign world: 20 fortress islands, camera pan between levels, star ratings.

signal squadron_changed(remaining: int)
signal keep_hp_changed(current: int, maximum: int)
signal game_won(stars: int, campaign_complete: bool)
signal game_lost
signal level_changed(level: int)

enum State { PLAYING, WON, LOST, TRANSITION }

var state: State = State.PLAYING
var current_level: int = 1
var squadron_size: int = GameConfig.SQUADRON_BASE
var planes_remaining: int = GameConfig.SQUADRON_BASE
var active_planes: int = 0
var last_stars: int = 0
var active_center: Vector2 = GameConfig.ISLAND_CENTER

var _spawn_cooldown: float = 0.0
var _holding: bool = false
var _hold_pos: Vector2 = Vector2.ZERO
var _islands: Array[Island] = []
var _active_island: Island
var _last_keep_max_hp: int = GameConfig.KEEP_MAX_HP
var _last_gun_count: int = 0
var _pending_ordnance: int = 0

const HOLD_SPAWN_INTERVAL := 0.15

@onready var camera: Camera2D = $Camera
@onready var islands_root: Node2D = $Islands
@onready var planes: Node2D = $Planes
@onready var bullets: Node2D = $Bullets
@onready var effects: Node2D = $Effects
@onready var hud: CanvasLayer = $HUD
@onready var ocean: ColorRect = $Camera/Ocean

var _plane_scene: PackedScene = preload("res://scenes/plane.tscn")
var _explosion_scene: PackedScene = preload("res://scenes/explosion.tscn")
var _island_scene: PackedScene = preload("res://scenes/island.tscn")
var _strike_missile_scene: PackedScene = preload("res://scenes/strike_missile.tscn")

enum Boom { BOMB, CRASH, BIG }

## Playtest / HUD alias for the active keep.
var keep: Keep:
	get:
		return _active_island.keep if _active_island else null


func _ready() -> void:
	randomize()
	_build_campaign()
	_apply_open_ocean()
	_sync_map_layers_to_camera()
	_activate_level(1, false)
	hud.setup(self)
	_emit_hud()
	Sfx.start_island_ambient(self)


func _process(delta: float) -> void:
	_sync_map_layers_to_camera()
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


func set_level(n: int) -> void:
	## Playtest hook: snap to level N without camera tween.
	var level := clampi(n, 1, GameConfig.LEVEL_COUNT)
	_clear_combatants()
	_activate_level(level, false)


func advance_or_restart() -> void:
	if state == State.LOST:
		retry_level()
	elif state == State.WON:
		if current_level >= GameConfig.LEVEL_COUNT:
			restart_campaign()
		else:
			goto_next_level()


func retry_level() -> void:
	_clear_combatants()
	if _active_island:
		_active_island.reset_for_retry()
		_wire_active_island()
	squadron_size = GameConfig.squadron_for_level(current_level)
	planes_remaining = squadron_size
	active_planes = 0
	state = State.PLAYING
	_emit_hud()
	level_changed.emit(current_level)


func goto_next_level() -> void:
	if current_level >= GameConfig.LEVEL_COUNT:
		restart_campaign()
		return
	_clear_combatants()
	var next := current_level + 1
	_activate_level(next, true)


func restart_campaign() -> void:
	get_tree().reload_current_scene()


func restart() -> void:
	## Back-compat for HUD / playtest.
	advance_or_restart()


func _try_spawn(world_pos: Vector2) -> void:
	if state != State.PLAYING or _active_island == null:
		return
	if planes_remaining <= 0 or _spawn_cooldown > 0.0:
		return

	var center := active_center
	var dist := world_pos.distance_to(center)
	var theta := (world_pos - center).angle()
	var shore: float = _active_island.get_shore_radius(theta)
	var water_min: float = _active_island.get_water_min_radius()
	if dist < maxf(shore + 12.0, water_min * 0.85):
		return  # Must tap water around the active island
	# Keep deploys in a ring around the active bastion (not on distant islands).
	if dist > water_min + 220.0:
		return

	_spawn_cooldown = HOLD_SPAWN_INTERVAL
	planes_remaining -= 1
	active_planes += 1
	_emit_hud()

	var plane: PlaneUnit = _plane_scene.instantiate()
	planes.add_child(plane)
	plane.setup(world_pos, center, self, GameConfig.plane_type_for_level(current_level))
	plane.finished.connect(_on_plane_finished)
	plane.exploded.connect(func(pos: Vector2) -> void: _spawn_explosion(pos, 1.0, Boom.CRASH))


func _on_plane_finished(_delivered_bomb: bool) -> void:
	active_planes = max(active_planes - 1, 0)
	_check_squadron_spent()


func _check_squadron_spent() -> void:
	# Don't call the siege while strike missiles are still in the air.
	if state == State.PLAYING and planes_remaining <= 0 and active_planes <= 0 and _pending_ordnance <= 0:
		if keep and keep.hp > 0:
			_set_lost()


func _on_keep_hp_changed(current: int, maximum: int) -> void:
	keep_hp_changed.emit(current, maximum)


func _on_keep_destroyed() -> void:
	if state != State.PLAYING:
		return
	if keep:
		_spawn_explosion(keep.global_position, 2.2, Boom.BIG)
	_set_won()


func _set_won() -> void:
	state = State.WON
	_last_keep_max_hp = keep.max_hp if keep else GameConfig.KEEP_MAX_HP
	_last_gun_count = _active_island.gun_count_initial() if _active_island else 0
	var used := squadron_size - planes_remaining
	last_stars = GameConfig.stars_for_win(
		used, _last_keep_max_hp, _last_gun_count, squadron_size, current_level
	)
	var campaign_done := current_level >= GameConfig.LEVEL_COUNT
	game_won.emit(last_stars, campaign_done)


func _set_lost() -> void:
	state = State.LOST
	game_lost.emit()


func apply_bomb_at(pos: Vector2, damage: int) -> void:
	_spawn_explosion(pos, 1.0, Boom.BOMB)
	if _active_island:
		_active_island.apply_bomb_at(pos, damage)


## Gunship strafe: tracer flash + point damage on whatever is under the impact.
func apply_gunfire(from_pos: Vector2, impact_pos: Vector2, damage: int) -> void:
	_spawn_tracer(from_pos, impact_pos)
	Sfx.gun_hit(self)
	if _active_island:
		_active_island.apply_gunfire_at(impact_pos, damage)


func launch_strike_missile(pos: Vector2, angle: float, target_pos: Vector2) -> void:
	var missile: StrikeMissile = _strike_missile_scene.instantiate()
	bullets.add_child(missile)
	missile.setup(pos, angle, target_pos, self)
	_pending_ordnance += 1


func ordnance_resolved() -> void:
	_pending_ordnance = max(_pending_ordnance - 1, 0)
	_check_squadron_spent()


## Dark airburst puff cloud where a flak shell detonates.
func spawn_flak_burst(pos: Vector2) -> void:
	Sfx.bomb(self)
	for i in 4:
		var puff := Sprite2D.new()
		var idx := randi_range(0, 12)
		var path := "res://assets/effects/smoke/smoke_%02d.png" % idx
		if ResourceLoader.exists(path):
			puff.texture = load(path)
		puff.global_position = pos + Vector2.from_angle(randf() * TAU) * randf_range(0.0, 24.0)
		puff.scale = Vector2(0.14, 0.14)
		puff.modulate = Color(0.25, 0.23, 0.26, 0.85)
		puff.z_index = 14
		effects.add_child(puff)
		var tw := puff.create_tween()
		tw.tween_property(puff, "modulate:a", 0.0, 0.7)
		tw.parallel().tween_property(puff, "scale", Vector2(0.3, 0.3), 0.7)
		tw.tween_callback(puff.queue_free)


func _spawn_tracer(from_pos: Vector2, impact_pos: Vector2) -> void:
	var line := Line2D.new()
	line.points = PackedVector2Array([from_pos, impact_pos])
	line.width = 3.0
	line.default_color = Color(1.0, 0.9, 0.45, 0.9)
	line.z_index = 14
	effects.add_child(line)
	var spark := Sprite2D.new()
	spark.texture = preload("res://assets/projectiles/bullet.png")
	spark.global_position = impact_pos
	spark.scale = Vector2(0.5, 0.5)
	spark.modulate = Color(1.0, 0.85, 0.4, 0.95)
	spark.z_index = 14
	effects.add_child(spark)
	var tw := line.create_tween()
	tw.tween_property(line, "modulate:a", 0.0, 0.12)
	tw.tween_callback(line.queue_free)
	var tw2 := spark.create_tween()
	tw2.tween_property(spark, "scale", Vector2(1.1, 1.1), 0.14)
	tw2.parallel().tween_property(spark, "modulate:a", 0.0, 0.14)
	tw2.tween_callback(spark.queue_free)


func register_bullet(bullet: Node2D) -> void:
	bullets.add_child(bullet)


func get_planes() -> Array:
	return planes.get_children()


func get_active_island() -> Island:
	return _active_island


func get_defense_positions() -> Array[Vector2]:
	if _active_island:
		return _active_island.get_defense_positions()
	return []


func get_gunship_target(from_pos: Vector2) -> Vector2:
	if _active_island and _active_island.has_method("get_gunship_target"):
		return _active_island.get_gunship_target(from_pos)
	return active_center


func current_plane_type() -> GameConfig.PlaneType:
	return GameConfig.plane_type_for_level(current_level)


func active_water_min_radius() -> float:
	if _active_island:
		return _active_island.get_water_min_radius()
	return GameConfig.WATER_MIN_RADIUS


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
	if keep:
		keep_hp_changed.emit(keep.hp, keep.max_hp)
	level_changed.emit(current_level)


func _build_campaign() -> void:
	_islands.clear()
	# Free immediately so a rebuild never stacks keeps on the same spot.
	while islands_root.get_child_count() > 0:
		var c := islands_root.get_child(0)
		islands_root.remove_child(c)
		c.free()

	var positions := _layout_island_positions()
	for i in GameConfig.LEVEL_COUNT:
		var island: Island = _island_scene.instantiate()
		islands_root.add_child(island)
		island.global_position = positions[i]
		island.build(i + 1, self)
		_islands.append(island)


func _layout_island_positions() -> Array[Vector2]:
	## Chain of islands with gentle turns. Every new center must clear ALL
	## previous ones — the old absolute-angle walk folded back on itself.
	var positions: Array[Vector2] = []
	var min_sep := GameConfig.ISLAND_SPACING_MIN
	var pos := GameConfig.ISLAND_CENTER
	positions.append(pos)

	var heading := randf() * TAU
	for i in range(1, GameConfig.LEVEL_COUNT):
		var placed := false
		var level_num := i + 1  # 1-based bastion index for the island being placed
		var spacing_min := GameConfig.ISLAND_SPACING_MIN
		var spacing_max := GameConfig.ISLAND_SPACING_MAX
		var level_sep := min_sep
		if GameConfig.is_stronghold_level(level_num) or GameConfig.is_stronghold_level(i):
			spacing_min += 220.0
			spacing_max += 280.0
			level_sep += 220.0
		for attempt in 48:
			var spacing := randf_range(spacing_min, spacing_max)
			# Early attempts: soft turn along the chain. Later: any direction.
			var dir: float
			if attempt < 20:
				dir = heading + randf_range(-0.55, 0.55)
			else:
				dir = randf() * TAU
				spacing = spacing_min + float(attempt) * 25.0
			var candidate := pos + Vector2.from_angle(dir) * spacing
			if _island_clear_of(candidate, positions, level_sep):
				heading = (candidate - pos).angle()
				pos = candidate
				positions.append(candidate)
				placed = true
				break
		if not placed:
			# Guaranteed unique slot on a golden-angle ring from the origin.
			var ring := level_sep * (1.0 + float(i) * 0.95)
			var ang := float(i) * TAU * 0.61803398875
			var fallback := GameConfig.ISLAND_CENTER + Vector2.from_angle(ang) * ring
			# Nudge out until clear of everything already placed.
			var guard := 0
			while not _island_clear_of(fallback, positions, level_sep) and guard < 30:
				guard += 1
				fallback = GameConfig.ISLAND_CENTER + Vector2.from_angle(ang) * (ring + float(guard) * 200.0)
			heading = (fallback - pos).angle()
			pos = fallback
			positions.append(fallback)
	return positions


func _island_clear_of(candidate: Vector2, existing: Array[Vector2], min_sep: float) -> bool:
	for p in existing:
		if candidate.distance_to(p) < min_sep:
			return false
	return true


func _activate_level(level: int, pan: bool) -> void:
	current_level = clampi(level, 1, GameConfig.LEVEL_COUNT)
	if _active_island:
		_active_island.set_active(false)
		_disconnect_island(_active_island)

	_active_island = _islands[current_level - 1]
	active_center = _active_island.get_center()
	_active_island.set_active(true)
	_wire_active_island()

	squadron_size = GameConfig.squadron_for_level(current_level)
	planes_remaining = squadron_size
	active_planes = 0

	if pan:
		state = State.TRANSITION
		var tw := create_tween()
		tw.set_ease(Tween.EASE_IN_OUT)
		tw.set_trans(Tween.TRANS_CUBIC)
		tw.tween_property(camera, "position", active_center, GameConfig.CAMERA_PAN_DURATION)
		tw.tween_callback(func() -> void:
			state = State.PLAYING
			_emit_hud()
		)
	else:
		camera.position = active_center
		state = State.PLAYING
		_emit_hud()

	level_changed.emit(current_level)


func _wire_active_island() -> void:
	if _active_island == null:
		return
	if not _active_island.keep_destroyed.is_connected(_on_keep_destroyed):
		_active_island.keep_destroyed.connect(_on_keep_destroyed)
	if not _active_island.keep_hp_changed.is_connected(_on_keep_hp_changed):
		_active_island.keep_hp_changed.connect(_on_keep_hp_changed)


func _disconnect_island(island: Island) -> void:
	if island.keep_destroyed.is_connected(_on_keep_destroyed):
		island.keep_destroyed.disconnect(_on_keep_destroyed)
	if island.keep_hp_changed.is_connected(_on_keep_hp_changed):
		island.keep_hp_changed.disconnect(_on_keep_hp_changed)


func _clear_combatants() -> void:
	_holding = false
	for p in planes.get_children():
		p.queue_free()
	for b in bullets.get_children():
		b.queue_free()
	active_planes = 0
	_pending_ordnance = 0


func _apply_open_ocean() -> void:
	if ocean == null or ocean.material == null:
		return
	var mat := ocean.material as ShaderMaterial
	if mat:
		mat.set_shader_parameter("open_ocean", true)


func _sync_map_layers_to_camera() -> void:
	## Ocean/clouds live under the camera in local space so they always fill the
	## view — world-space ColorRects stop drawing at far campaign coordinates.
	if camera == null:
		return
	var view_size := get_viewport().get_visible_rect().size
	var half := view_size / (camera.zoom * 2.0)
	# Pad for stretch/aspect expand and subpixel camera pans.
	half += Vector2(160.0, 160.0)
	var clouds := camera.get_node_or_null("Clouds") as ColorRect
	var shadows := camera.get_node_or_null("CloudShadows") as ColorRect
	for rect in [ocean, clouds, shadows]:
		if rect == null:
			continue
		rect.offset_left = -half.x
		rect.offset_top = -half.y
		rect.offset_right = half.x
		rect.offset_bottom = half.y
