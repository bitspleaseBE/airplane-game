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

const HOLD_SPAWN_INTERVAL := 0.5

@onready var keep: Keep = $Keep
@onready var planes: Node2D = $Planes
@onready var bullets: Node2D = $Bullets
@onready var effects: Node2D = $Effects
@onready var hud: CanvasLayer = $HUD
@onready var turrets_root: Node2D = $Turrets

var _plane_scene: PackedScene = preload("res://scenes/plane.tscn")
var _explosion_scene: PackedScene = preload("res://scenes/explosion.tscn")


func _ready() -> void:
	randomize()
	_build_island_decor()
	_wire_turrets()
	keep.destroyed.connect(_on_keep_destroyed)
	keep.hp_changed.connect(_on_keep_hp_changed)
	hud.setup(self)
	_emit_hud()


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
	if dist < GameConfig.WATER_MIN_RADIUS:
		return  # Must tap water around the island

	_spawn_cooldown = HOLD_SPAWN_INTERVAL
	planes_remaining -= 1
	active_planes += 1
	_emit_hud()

	var plane: PlaneUnit = _plane_scene.instantiate()
	planes.add_child(plane)
	plane.setup(world_pos, GameConfig.ISLAND_CENTER, self)
	plane.finished.connect(_on_plane_finished)
	plane.exploded.connect(_spawn_explosion)


func _on_plane_finished(_delivered_bomb: bool) -> void:
	active_planes = max(active_planes - 1, 0)
	if state == State.PLAYING and planes_remaining <= 0 and active_planes <= 0 and keep.hp > 0:
		_set_lost()


func _on_keep_hp_changed(current: int, maximum: int) -> void:
	keep_hp_changed.emit(current, maximum)


func _on_keep_destroyed() -> void:
	if state != State.PLAYING:
		return
	_spawn_explosion(keep.global_position, 2.2)
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
	_spawn_explosion(pos, 1.0)
	# Damage keep if close
	if pos.distance_to(keep.global_position) <= GameConfig.PLANE_BOMB_RADIUS + GameConfig.KEEP_RADIUS * 0.35:
		keep.take_damage(damage)
	# Damage turrets if close
	for turret in turrets_root.get_children():
		if turret is Turret and is_instance_valid(turret) and not turret.is_destroyed():
			if pos.distance_to(turret.global_position) <= GameConfig.PLANE_BOMB_RADIUS + 30.0:
				turret.take_damage(GameConfig.TURRET_BOMB_DAMAGE)


func register_bullet(bullet: Node2D) -> void:
	bullets.add_child(bullet)


func get_planes() -> Array:
	return planes.get_children()


func _spawn_explosion(pos: Vector2, scale_mul: float = 1.0) -> void:
	var fx: Node2D = _explosion_scene.instantiate()
	effects.add_child(fx)
	fx.global_position = pos
	fx.scale = Vector2.ONE * scale_mul


func _emit_hud() -> void:
	squadron_changed.emit(planes_remaining)
	keep_hp_changed.emit(keep.hp, keep.max_hp)


func _wire_turrets() -> void:
	for turret in turrets_root.get_children():
		if turret is Turret:
			turret.configure(self)
			turret.destroyed.connect(func(pos: Vector2): _spawn_explosion(pos, 1.4))


func _build_island_decor() -> void:
	var island := $Island
	var grass_tex: Texture2D = preload("res://assets/terrain/grass.png")
	var sand_tex: Texture2D = preload("res://assets/terrain/sand.png")
	var tree_tex: Texture2D = preload("res://assets/terrain/tree.png")

	# Ocean → beach ring → grass fringe → open courtyard under fort.
	var tile := 56.0
	var radius := GameConfig.ISLAND_RADIUS
	var center := GameConfig.ISLAND_CENTER
	var fort_clear := GameConfig.FORT_CLEAR_RADIUS
	for x in range(-6, 7):
		for y in range(-6, 7):
			var local := Vector2(x * tile * 0.78, y * tile * 0.78)
			var d := local.length()
			if d > radius or d < fort_clear * 0.55:
				continue
			var spr := Sprite2D.new()
			# Outer band = beach sand, inner band = grass approaching the fort
			if d > radius * 0.78:
				spr.texture = sand_tex
			elif d > fort_clear:
				spr.texture = grass_tex
			else:
				# Thin packed-earth apron under fort walls
				spr.texture = sand_tex
				spr.modulate = Color(0.85, 0.82, 0.75)
			spr.position = center + local
			spr.z_index = -2
			island.add_child(spr)

	# Trees on the grass/beach fringe — outside the fortress footprint
	var tree_spots := [
		Vector2(-150, -40), Vector2(155, -55), Vector2(-130, 110),
		Vector2(140, 100), Vector2(-40, -165), Vector2(50, 160),
		Vector2(-160, 50), Vector2(165, 30), Vector2(20, -150),
	]
	for offset in tree_spots:
		if offset.length() < fort_clear + 20.0:
			continue
		var t := Sprite2D.new()
		t.texture = tree_tex
		t.position = center + offset
		t.scale = Vector2(0.75, 0.75)
		t.z_index = -1
		island.add_child(t)
