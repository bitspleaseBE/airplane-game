extends Node2D

## Campaign world: 20 fortress islands, camera pan between levels, star ratings.

signal squadron_changed(remaining: int)
signal keep_hp_changed(current: int, maximum: int)
signal game_won(stars: int, campaign_complete: bool)
signal game_lost
signal level_changed(level: int)
signal decoys_changed(charges: int, max_charges: int, recharge_t: float)

enum State { PLAYING, WON, LOST, TRANSITION }

var state: State = State.PLAYING
var current_level: int = 1
var squadron_size: int = GameConfig.SQUADRON_BASE
var planes_remaining: int = GameConfig.SQUADRON_BASE
var active_planes: int = 0
var last_stars: int = 0
var active_center: Vector2 = GameConfig.ISLAND_CENTER

## Per-siege after-action report (reset each level / retry).
var planes_deployed: int = 0
var planes_crashed: int = 0
var guns_destroyed: int = 0
## Running campaign totals — only banked on wins.
var campaign_planes_deployed: int = 0
var campaign_planes_crashed: int = 0
var campaign_guns_destroyed: int = 0

## Bullets soaked by decoys this siege. Not shown to the player — it is the
## balance signal for whether the feint layer is actually pulling fire.
var decoy_hits_absorbed: int = 0

## Decoy charges: the second verb. See GameConfig's decoy block.
var decoy_charges: int = GameConfig.DECOY_START_CHARGES
## Single-shot arm: the next deploy sends a drone instead of a bird, then the
## arm clears. A held toggle turned into "did I leave it on?" every time the
## board got busy, which is exactly the wrong thing to think about mid-siege.
var decoy_armed: bool = false
var _decoy_recharge: float = 0.0
var _decoy_emit_accum: float = 0.0

var _spawn_cooldown: float = 0.0
var _holding: bool = false
var _hold_pos: Vector2 = Vector2.ZERO
## Virtual cursor for keyboard / gamepad. Inactive until one of them is used,
## so a mouse or touch player never sees it.
var _cursor_active: bool = false
var _cursor_pos: Vector2 = GameConfig.ISLAND_CENTER
## A press that arrived mid-scramble, held until the deck is clear. Dropping it
## instead would read as the game ignoring taps.
var _queued_pos: Vector2 = Vector2.ZERO
var _has_queued: bool = false
var _islands: Array[Island] = []
## Empty tropical islets between bastions — not playable targets.
var _scenic_islands: Array[Island] = []
var _active_island: Island
var _last_keep_max_hp: int = GameConfig.KEEP_MAX_HP
var _last_gun_count: int = 0
var _pending_ordnance: int = 0
## Island indices still waiting for shape + defenses.
var _pending_island_builds: Array[int] = []
## Scenic indices waiting to be built.
var _pending_scenic_builds: Array[int] = []
## Space out background bastion/scenic builds so idle frames stay responsive.
var _build_drain_cd: float = 0.0

## Framing. The camera zooms out on the bigger bastions so the whole island
## plus a ring of open water always fits across the screen.
##
## This is a playability constraint, not a look: at the default zoom the level
## 15 and 20 islands are wider than the viewport, so there was simply no water
## to tap to the east or west of them. Whole approach bearings did not exist,
## which is fatal for a siege that is supposed to keep changing direction.
const DEFAULT_ZOOM := 0.8
const MIN_ZOOM := 0.5
## Depth of tappable water that must stay on screen outside the sand.
const DEPLOY_RING_MARGIN := 120.0

## Must match MAX_ISLANDS in shaders/water.gdshader.
const OCEAN_MAX_ISLANDS := 12
## How far past a coast the water shader still reads it: the depth ramp reaches
## 520 world units, the shore warp can pull the contour 45 further out, and the
## sandbar term another 110. Coasts whose influence can't reach the drawn ocean
## rect are left out of the upload entirely.
const OCEAN_INFLUENCE_MARGIN := 700.0
## Re-cull once the camera has drifted this far since the last upload. Far inside
## the margin above, so the uploaded set is never stale enough to show.
const OCEAN_RECULL_STEP := 64.0

## Keyboard / gamepad aiming. The reticle has to cross the tappable ring in
## about the time a bird takes to fly in, or moving the attack around the island
## costs more than the scramble gap it is meant to fit inside.
const CURSOR_SPEED := 620.0
## Below this a stick reading is drift, not intent — a nudged reticle that never
## stops moving is worse than none.
const CURSOR_DEADZONE := 0.22

const DECOY_EMIT_INTERVAL := 0.1

## Camera position the ocean uniforms were last culled for.
var _ocean_uniform_pos := Vector2(INF, INF)

@onready var camera: Camera2D = $Camera
@onready var islands_root: Node2D = $Islands
@onready var threat: ThreatOverlay = $Threat
@onready var planes: Node2D = $Planes
@onready var bullets: Node2D = $Bullets
@onready var effects: Node2D = $Effects
@onready var hud: CanvasLayer = $HUD
@onready var ocean: ColorRect = $Camera/Ocean
@onready var reticle: DeployReticle = $Reticle
@onready var pause_menu: CanvasLayer = $PauseMenu

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
	# A harness run with an explicit --seed owns the global RNG; randomizing
	# here would throw it away and make every balance result unrepeatable.
	if Playtest.requested_seed() < 0:
		randomize()
	_build_campaign()
	_apply_open_ocean()
	_apply_clouds_enabled()
	_sync_map_layers_to_camera()
	_activate_level(1, false)
	threat.setup(self)
	hud.setup(self)
	if pause_menu.has_method("setup"):
		pause_menu.setup(self)
	_cursor_pos = active_center
	_emit_hud()
	Sfx.start_island_ambient(self)


func _process(delta: float) -> void:
	_sync_map_layers_to_camera()
	# The ocean uniforms are view-culled, so they follow the camera — during a
	# pan, a kick, or a level snap.
	if camera and camera.position.distance_to(_ocean_uniform_pos) > OCEAN_RECULL_STEP:
		_apply_open_ocean()
	# Background bastion/scenic builds still cost a coast LUT plus defence and palm
	# nodes, so keep them off frames where the player is deploying. The old spacing
	# was sized for the multi-hundred-millisecond pixel bake, which the beach
	# shader removed; one build per few frames is plenty now.
	_build_drain_cd = maxf(_build_drain_cd - delta, 0.0)
	if active_planes <= 0 and not _holding and _build_drain_cd <= 0.0:
		if _drain_island_build_queue():
			_build_drain_cd = 0.05
	_spawn_cooldown = max(_spawn_cooldown - delta, 0.0)
	if state == State.PLAYING:
		_tick_decoy_recharge(delta)
	if state == State.PLAYING and _has_queued and _spawn_cooldown <= 0.0:
		var queued := _queued_pos
		_has_queued = false
		_try_spawn(queued, false)
	# Safety net: if the counter is empty and nothing's airborne, settle the siege.
	if state == State.PLAYING and planes_remaining <= 0 and active_planes <= 0:
		_check_squadron_spent()
	_update_cursor(delta)
	if state != State.PLAYING or not _holding:
		return
	_hold_pos = _cursor_pos if _cursor_active else get_global_mouse_position()
	# Hold-to-repeat respects scramble gap; discrete presses bypass it.
	if _spawn_cooldown <= 0.0:
		_try_spawn(_hold_pos, false)


func _unhandled_input(event: InputEvent) -> void:
	# Window-level hotkeys work whatever the siege is doing — a player who
	# wants fullscreen or silence should not have to find a menu first.
	if event.is_action_pressed("toggle_fullscreen"):
		Settings.toggle_fullscreen()
		get_viewport().set_input_as_handled()
		return
	if event.is_action_pressed("toggle_mute"):
		Settings.toggle_muted()
		get_viewport().set_input_as_handled()
		return
	# R re-flies the current bastion. Deliberately not wired on a win — there
	# the player wants "next", and the modal already offers it.
	if event.is_action_pressed("arm_decoy"):
		toggle_decoy_arm()
		get_viewport().set_input_as_handled()
		return
	if event.is_action_pressed("restart_level") and state in [State.PLAYING, State.LOST]:
		retry_level()
		get_viewport().set_input_as_handled()
		return

	if state != State.PLAYING:
		_holding = false
		return

	# Keyboard / gamepad scramble at the reticle rather than at the pointer.
	if event.is_action_pressed("deploy"):
		_activate_cursor()
		_holding = true
		_hold_pos = _cursor_pos
		_try_spawn(_hold_pos, true)
		get_viewport().set_input_as_handled()
		return
	if event.is_action_released("deploy"):
		_holding = false
		return

	# With emulate_touch_from_mouse, a click emits ScreenTouch AND MouseButton.
	# Only the touch path may spawn — handling both double-deploys one bird.
	var touch_from_mouse: bool = ProjectSettings.get_setting(
		"input_devices/pointing/emulate_touch_from_mouse", false
	)

	if event is InputEventMouseMotion and event.relative != Vector2.ZERO:
		_cursor_active = false
		reticle.visible = false

	if event is InputEventScreenTouch:
		if event.pressed:
			_cursor_active = false
			reticle.visible = false
			_holding = true
			_hold_pos = _screen_to_world(event.position)
			_try_spawn(_hold_pos, true)
		elif event.index == 0:
			_holding = false
	elif event is InputEventScreenDrag:
		_hold_pos = _screen_to_world(event.position)
	elif not touch_from_mouse and event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		_holding = event.pressed
		if event.pressed:
			_hold_pos = get_global_mouse_position()
			_try_spawn(_hold_pos, true)
	elif not touch_from_mouse and event is InputEventMouseMotion and _holding:
		_hold_pos = get_global_mouse_position()


## Moves and paints the keyboard / gamepad reticle. Called every frame so the
## readout of "would a scramble be accepted here" stays live as the fort
## traverses, not only at the moment of a press.
func _update_cursor(delta: float) -> void:
	var stick := Input.get_vector("cursor_left", "cursor_right", "cursor_up", "cursor_down")
	if stick.length() > CURSOR_DEADZONE:
		_activate_cursor()
		_cursor_pos += stick * CURSOR_SPEED * delta
	elif not _cursor_active:
		return

	# Keep the reticle inside the water the camera is actually showing —
	# walking it off screen loses the player their pointer entirely.
	var half := get_viewport_rect().size * 0.5 / camera.zoom
	var cam := camera.global_position
	_cursor_pos.x = clampf(_cursor_pos.x, cam.x - half.x, cam.x + half.x)
	_cursor_pos.y = clampf(_cursor_pos.y, cam.y - half.y, cam.y + half.y)

	reticle.global_position = _cursor_pos
	reticle.deployable = state == State.PLAYING and _is_deployable(_cursor_pos)
	var gap := GameConfig.deploy_interval_for_level(current_level)
	reticle.ready_fraction = 1.0 if gap <= 0.0 else 1.0 - clampf(_spawn_cooldown / gap, 0.0, 1.0)
	reticle.visible = state == State.PLAYING


func _activate_cursor() -> void:
	if _cursor_active:
		return
	_cursor_active = true
	# Start from wherever the pointer last was, so switching input mid-siege
	# does not teleport the aim across the island.
	var mouse := get_global_mouse_position()
	_cursor_pos = mouse if mouse.distance_to(active_center) < 2000.0 else active_center
	reticle.global_position = _cursor_pos
	reticle.visible = true


func _screen_to_world(screen_pos: Vector2) -> Vector2:
	return get_viewport().get_canvas_transform().affine_inverse() * screen_pos


func set_level(n: int) -> void:
	## Playtest hook: snap to level N without camera tween.
	var level := clampi(n, 1, GameConfig.LEVEL_COUNT)
	_clear_combatants()
	_activate_level(level, false)


func is_playing() -> bool:
	return state == State.PLAYING


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
	_reset_decoys()
	_reset_siege_stats()
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
	## In-place restart — avoid reload_current_scene()'s full teardown hitch.
	_clear_combatants()
	_pending_island_builds.clear()
	_pending_scenic_builds.clear()
	if _active_island:
		_disconnect_island(_active_island)
		_active_island = null
	campaign_planes_deployed = 0
	campaign_planes_crashed = 0
	campaign_guns_destroyed = 0
	_build_campaign()
	_apply_open_ocean()
	_activate_level(1, false)
	_emit_hud()
	Sfx.start_island_ambient(self)


func restart() -> void:
	## Back-compat for HUD / playtest.
	advance_or_restart()


## Water only, and clear of every other island's sand.
func _is_deployable(world_pos: Vector2) -> bool:
	if _active_island == null:
		return false
	var center := active_center
	var theta := (world_pos - center).angle()
	# Land only — shallow lagoon and deep open water are both fair game.
	if world_pos.distance_to(center) < _active_island.get_shore_radius(theta) + 12.0:
		return false
	# Don't seed a bird on top of another bastion's island — or a scenic islet.
	for island in _islands:
		if island == null or island == _active_island:
			continue
		var other_c: Vector2 = island.get_center()
		var other_shore: float = island.get_shore_radius((world_pos - other_c).angle())
		if world_pos.distance_to(other_c) < other_shore + 12.0:
			return false
	for scenic in _scenic_islands:
		if scenic == null or not scenic.is_built():
			continue
		var sc: Vector2 = scenic.get_center()
		var ss: float = scenic.get_shore_radius((world_pos - sc).angle())
		if world_pos.distance_to(sc) < ss + 12.0:
			return false
	return true


## --- decoys --------------------------------------------------------------


func toggle_decoy_arm() -> void:
	set_decoy_armed(not decoy_armed)


func set_decoy_armed(on: bool) -> void:
	var want := on and decoy_charges > 0 and state == State.PLAYING
	if want == decoy_armed:
		return
	decoy_armed = want
	_emit_decoys()


func _reset_decoys() -> void:
	decoy_hits_absorbed = 0
	decoy_charges = GameConfig.DECOY_START_CHARGES
	_decoy_recharge = 0.0
	decoy_armed = false
	_emit_decoys()


func _tick_decoy_recharge(delta: float) -> void:
	if decoy_charges >= GameConfig.DECOY_MAX_CHARGES:
		if _decoy_recharge != 0.0:
			_decoy_recharge = 0.0
			_emit_decoys()
		return
	_decoy_recharge += delta
	if _decoy_recharge >= GameConfig.DECOY_RECHARGE_SEC:
		_decoy_recharge = 0.0
		decoy_charges += 1
		_decoy_emit_accum = DECOY_EMIT_INTERVAL
	# The readout is a slowly filling pip, so pushing it at 10 Hz under 60 Hz
	# gameplay is invisible and keeps a per-frame signal out of the main loop.
	_decoy_emit_accum += delta
	if _decoy_emit_accum >= DECOY_EMIT_INTERVAL:
		_decoy_emit_accum = 0.0
		_emit_decoys()


func _emit_decoys() -> void:
	var t := 0.0
	if decoy_charges < GameConfig.DECOY_MAX_CHARGES:
		t = clampf(_decoy_recharge / GameConfig.DECOY_RECHARGE_SEC, 0.0, 1.0)
	decoys_changed.emit(decoy_charges, GameConfig.DECOY_MAX_CHARGES, t)


## Sends a drone from `world_pos`. Costs a charge and a scramble gap but no
## squadron — the trade is a bomber's slot in time, not a bird.
##
## Blocked once the squadron is spent: with nothing left to escort, a drone
## would only stall the loss check while charges kept trickling back.
func _try_decoy(world_pos: Vector2) -> void:
	if decoy_charges <= 0 or planes_remaining <= 0:
		set_decoy_armed(false)
		return

	decoy_charges -= 1
	decoy_armed = false
	# Decoys leave the same deck as the wing, so they burn the same gap. The
	# gap is the whole economy; a free decoy would make spamming them correct.
	_spawn_cooldown = GameConfig.deploy_interval_for_level(current_level)
	active_planes += 1
	_emit_decoys()

	var island_radius: float = (
		_active_island.island_radius if _active_island else GameConfig.ISLAND_RADIUS
	)
	var orbit := GameConfig.decoy_orbit_radius(
		island_radius, GameConfig.turret_range_for_level(current_level)
	)
	var drone: PlaneUnit = _plane_scene.instantiate()
	planes.add_child(drone)
	drone.setup(world_pos, active_center, self, GameConfig.plane_type_for_level(current_level))
	drone.setup_decoy(orbit)
	drone.finished.connect(_on_plane_finished)
	drone.exploded.connect(_on_decoy_exploded)


## Decoys are expected to die — they do not count against the siege's crash
## tally, which is what the star rating reads.
func note_decoy_hit() -> void:
	decoy_hits_absorbed += 1


func _on_decoy_exploded(pos: Vector2) -> void:
	_spawn_explosion(pos, 1.15, Boom.CRASH)


## from_press: true on click/tap — parks the request if the deck is still busy.
## false while holding or draining the queue — simply waits its turn.
##
## The scramble gap applies to every deploy, taps included. It is the whole
## economy: birds leave the deck at a fixed rate, so the only thing the player
## controls is *where* each one enters. Letting taps bypass it made mashing the
## dominant strategy at every difficulty and left placement meaningless.
func _try_spawn(world_pos: Vector2, from_press: bool = false) -> void:
	if state != State.PLAYING or _active_island == null:
		return
	if hud and hud.has_method("is_briefing_open") and hud.is_briefing_open():
		return
	if planes_remaining <= 0:
		return
	if _spawn_cooldown > 0.0:
		if from_press and _is_deployable(world_pos):
			_queued_pos = world_pos
			_has_queued = true
		return
	if not _is_deployable(world_pos):
		return

	if decoy_armed:
		_try_decoy(world_pos)
		return

	var center := active_center
	var plane_type: GameConfig.PlaneType = GameConfig.plane_type_for_level(current_level)
	_spawn_cooldown = GameConfig.deploy_interval_for_plane(plane_type)
	planes_remaining -= 1
	active_planes += 1
	planes_deployed += 1
	_emit_hud()

	var plane: PlaneUnit = _plane_scene.instantiate()
	planes.add_child(plane)
	plane.setup(world_pos, center, self, plane_type)
	plane.finished.connect(_on_plane_finished)
	plane.exploded.connect(_on_plane_exploded)


func _on_plane_finished(_delivered_bomb: bool) -> void:
	active_planes = max(active_planes - 1, 0)
	_check_squadron_spent()
	# Re-check next idle frame — covers any residual living-node timing.
	call_deferred("_check_squadron_spent")


func _on_plane_exploded(pos: Vector2) -> void:
	planes_crashed += 1
	_spawn_explosion(pos, 1.45, Boom.CRASH)
	_camera_kick(3.0)


func _check_squadron_spent() -> void:
	# Don't call the siege while strike missiles are still in the air.
	# Count live plane nodes too — counters alone can desync if finished
	# double-fires or a plane is freed without the signal.
	if state != State.PLAYING or planes_remaining > 0 or _pending_ordnance > 0:
		return
	if active_planes > 0 or _living_plane_count() > 0:
		return
	if keep and keep.hp > 0:
		_set_lost()


func _living_plane_count() -> int:
	var n := 0
	for p in planes.get_children():
		if not is_instance_valid(p) or p.is_queued_for_deletion():
			continue
		if p.has_method("is_spent") and p.is_spent():
			continue
		n += 1
	return n


func _on_keep_hp_changed(current: int, maximum: int) -> void:
	keep_hp_changed.emit(current, maximum)


func _on_keep_destroyed() -> void:
	if state != State.PLAYING:
		return
	if keep:
		_spawn_explosion(keep.global_position, 2.8, Boom.BIG)
		_camera_kick(8.0)
	_set_won()


func _set_won() -> void:
	state = State.WON
	_last_keep_max_hp = keep.max_hp if keep else GameConfig.KEEP_MAX_HP
	_last_gun_count = _active_island.gun_count_initial() if _active_island else 0
	_refresh_guns_destroyed()
	campaign_planes_deployed += planes_deployed
	campaign_planes_crashed += planes_crashed
	campaign_guns_destroyed += guns_destroyed
	var used := squadron_size - planes_remaining
	last_stars = GameConfig.stars_for_win(
		used, _last_keep_max_hp, _last_gun_count, squadron_size, current_level
	)
	var campaign_done := current_level >= GameConfig.LEVEL_COUNT
	# Banked before the modal opens, so a player who alt-F4s on the win screen
	# still keeps the bastion and the stars they just earned.
	Settings.record_win(current_level, last_stars)
	game_won.emit(last_stars, campaign_done)


## Called by the HUD after the win-star flip finishes — never during the tween.
## Builds the next island's shape and defences so "Next bastion" pans into a
## finished bastion. The beach itself is a shader now, so there is nothing heavy
## left to pre-bake here.
func prep_next_bastion_after_stars() -> void:
	if state != State.WON or current_level >= GameConfig.LEVEL_COUNT:
		return
	_ensure_island_built(current_level)


func _set_lost() -> void:
	state = State.LOST
	_refresh_guns_destroyed()
	game_lost.emit()


func _refresh_guns_destroyed() -> void:
	if _active_island == null:
		guns_destroyed = 0
		return
	guns_destroyed = maxi(_active_island.gun_count_initial() - _active_island.gun_count(), 0)


func _reset_siege_stats() -> void:
	planes_deployed = 0
	planes_crashed = 0
	guns_destroyed = 0


func result_stats(campaign_complete: bool = false) -> Dictionary:
	## After-action numbers for the result modal.
	if campaign_complete:
		return {
			"planes_deployed": campaign_planes_deployed,
			"planes_crashed": campaign_planes_crashed,
			"guns_destroyed": campaign_guns_destroyed,
		}
	return {
		"planes_deployed": planes_deployed,
		"planes_crashed": planes_crashed,
		"guns_destroyed": guns_destroyed,
	}


func apply_bomb_at(pos: Vector2, damage: int) -> void:
	# Punchier blast so bomb hits read clearly vs. grey smoke puffs.
	_spawn_explosion(pos, 1.85, Boom.BOMB)
	_camera_kick(4.5)
	if _active_island:
		_active_island.apply_bomb_at(pos, damage)


## Cosmetic wing-release only — does not delay damage (falling bombs were reverted).
func spawn_bomb_release(from_pos: Vector2, to_pos: Vector2) -> void:
	var bomb := Sprite2D.new()
	bomb.texture = preload("res://assets/projectiles/bomb.png")
	bomb.global_position = from_pos
	bomb.scale = Vector2(0.65, 0.65)
	bomb.z_index = 16
	bomb.modulate = Color(1.0, 1.0, 1.0, 0.95)
	effects.add_child(bomb)
	var mid := from_pos.lerp(to_pos, 0.55) + Vector2(0, -22)
	var tw := bomb.create_tween()
	tw.tween_property(bomb, "global_position", mid, 0.08).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tw.tween_property(bomb, "global_position", to_pos, 0.1).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tw.parallel().tween_property(bomb, "scale", Vector2(0.4, 0.4), 0.18)
	tw.parallel().tween_property(bomb, "modulate:a", 0.0, 0.18)
	tw.tween_callback(bomb.queue_free)


## Gunship strafe: tracer flash + point damage on whatever is under the impact.
func apply_gunfire(from_pos: Vector2, impact_pos: Vector2, damage: int) -> void:
	_spawn_tracer(from_pos, impact_pos)
	Sfx.gun_hit(self)
	if _active_island:
		_active_island.apply_gunfire_at(impact_pos, damage)


## Bright kill flash when a pad/tower dies — SEAD payoff.
func spawn_gun_kill_flash(pos: Vector2) -> void:
	_spawn_explosion(pos, 1.7, Boom.BOMB)
	_camera_kick(2.5)
	var flash := Polygon2D.new()
	var pts := PackedVector2Array()
	for i in 16:
		var a := TAU * float(i) / 16.0
		pts.append(Vector2(cos(a), sin(a)) * 28.0)
	flash.polygon = pts
	flash.color = Color(1.0, 0.95, 0.7, 0.75)
	flash.z_index = 18
	flash.global_position = pos
	effects.add_child(flash)
	var tw := flash.create_tween()
	tw.tween_property(flash, "scale", Vector2(2.2, 2.2), 0.22).set_ease(Tween.EASE_OUT)
	tw.parallel().tween_property(flash, "color:a", 0.0, 0.22)
	tw.tween_callback(flash.queue_free)


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
		puff.texture = FxAtlas.smoke_frame()
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
	line.width = 5.0
	line.default_color = Color(1.0, 0.92, 0.4, 0.95)
	line.z_index = 14
	line.begin_cap_mode = Line2D.LINE_CAP_ROUND
	line.end_cap_mode = Line2D.LINE_CAP_ROUND
	effects.add_child(line)
	var spark := Sprite2D.new()
	spark.texture = preload("res://assets/projectiles/bullet.png")
	spark.global_position = impact_pos
	spark.scale = Vector2(0.75, 0.75)
	spark.modulate = Color(1.0, 0.9, 0.45, 1.0)
	spark.z_index = 15
	effects.add_child(spark)
	var tw := line.create_tween()
	tw.tween_property(line, "modulate:a", 0.0, 0.16)
	tw.parallel().tween_property(line, "width", 1.5, 0.16)
	tw.tween_callback(line.queue_free)
	var tw2 := spark.create_tween()
	tw2.tween_property(spark, "scale", Vector2(1.6, 1.6), 0.18)
	tw2.parallel().tween_property(spark, "modulate:a", 0.0, 0.18)
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


func _camera_kick(strength: float = 4.0) -> void:
	## Short screen nudge — juice without wrecking aim readability.
	if camera == null:
		return
	var shake_scale := Settings.screen_shake
	if Settings.reduced_motion:
		shake_scale = minf(shake_scale, 0.25)
	if shake_scale <= 0.01:
		return
	strength *= shake_scale
	var base := camera.offset
	var kick := Vector2(randf_range(-1.0, 1.0), randf_range(-1.0, 1.0)).normalized() * strength
	var tw := create_tween()
	tw.tween_property(camera, "offset", base + kick, 0.04)
	tw.tween_property(camera, "offset", base, 0.1).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)


func _emit_hud() -> void:
	squadron_changed.emit(planes_remaining)
	_emit_decoys()
	if keep:
		keep_hp_changed.emit(keep.hp, keep.max_hp)
	level_changed.emit(current_level)


func _build_campaign() -> void:
	_islands.clear()
	_scenic_islands.clear()
	_pending_island_builds.clear()
	_pending_scenic_builds.clear()
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
		_islands.append(island)
		if i == 0:
			# Only the starting bastion is needed to boot; the rest trickle in from
			# _drain_island_build_queue on idle frames.
			island.build(1, self)
		else:
			_pending_island_builds.append(i)

	_place_scenic_islands(positions)


func _place_scenic_islands(bastion_positions: Array[Vector2]) -> void:
	## Sparse empty islets in the gaps — archipelago feel without crowding sieges.
	var rng := RandomNumberGenerator.new()
	rng.seed = hash("scenic_archipelago")
	var target := rng.randi_range(GameConfig.SCENIC_ISLAND_COUNT_MIN, GameConfig.SCENIC_ISLAND_COUNT_MAX)
	var occupied: Array[Vector2] = bastion_positions.duplicate()
	var placed := 0
	var seed_key := 0

	# Prefer midpoints between consecutive bastions, offset sideways into open water.
	for i in range(bastion_positions.size() - 1):
		if placed >= target:
			break
		if rng.randf() > 0.62:
			continue
		var a: Vector2 = bastion_positions[i]
		var b: Vector2 = bastion_positions[i + 1]
		var mid := (a + b) * 0.5
		var along := (b - a).normalized()
		var side := Vector2(-along.y, along.x)
		if rng.randf() < 0.5:
			side = -side
		var offset := rng.randf_range(380.0, 720.0)
		var candidate := mid + side * offset
		# Nudge along the segment so they aren't always dead-center.
		candidate += along * rng.randf_range(-220.0, 220.0)
		if not _scenic_slot_clear(candidate, occupied, GameConfig.SCENIC_SEP_FROM_BASTION, GameConfig.SCENIC_SEP_FROM_SCENIC, bastion_positions.size()):
			# Flip side and retry once.
			candidate = mid - side * offset + along * rng.randf_range(-180.0, 180.0)
			if not _scenic_slot_clear(candidate, occupied, GameConfig.SCENIC_SEP_FROM_BASTION, GameConfig.SCENIC_SEP_FROM_SCENIC, bastion_positions.size()):
				continue
		_spawn_scenic(candidate, seed_key, rng)
		occupied.append(candidate)
		seed_key += 1
		placed += 1

	# One or two near-field satellites so early sieges aren't lonely open ocean.
	# Queue only, so boot never pays for the whole archipelago at once.
	for i in mini(3, bastion_positions.size()):
		if placed >= target:
			break
		if rng.randf() > 0.7:
			continue
		var anchor2: Vector2 = bastion_positions[i]
		var ang2 := rng.randf() * TAU
		var dist2 := rng.randf_range(420.0, 560.0)
		var candidate3 := anchor2 + Vector2.from_angle(ang2) * dist2
		if not _scenic_slot_clear(candidate3, occupied, 400.0, GameConfig.SCENIC_SEP_FROM_SCENIC, bastion_positions.size()):
			continue
		_spawn_scenic(candidate3, seed_key, rng)
		occupied.append(candidate3)
		seed_key += 1
		placed += 1

	# Fill remaining budget with free-floating islets near the chain.
	var guard := 0
	while placed < target and guard < 80:
		guard += 1
		var anchor: Vector2 = bastion_positions[rng.randi_range(0, bastion_positions.size() - 1)]
		var ang := rng.randf() * TAU
		var dist := rng.randf_range(GameConfig.SCENIC_SEP_FROM_BASTION + 40.0, GameConfig.SCENIC_SEP_FROM_BASTION + 520.0)
		var candidate2 := anchor + Vector2.from_angle(ang) * dist
		if not _scenic_slot_clear(candidate2, occupied, GameConfig.SCENIC_SEP_FROM_BASTION, GameConfig.SCENIC_SEP_FROM_SCENIC, bastion_positions.size()):
			continue
		_spawn_scenic(candidate2, seed_key, rng)
		occupied.append(candidate2)
		seed_key += 1
		placed += 1


func _scenic_slot_clear(
	candidate: Vector2,
	occupied: Array[Vector2],
	bastion_sep: float,
	scenic_sep: float,
	bastion_count: int,
) -> bool:
	for i in occupied.size():
		var min_d := bastion_sep if i < bastion_count else scenic_sep
		if candidate.distance_to(occupied[i]) < min_d:
			return false
	return true


func _spawn_scenic(pos: Vector2, seed_key: int, rng: RandomNumberGenerator) -> void:
	var island: Island = _island_scene.instantiate()
	islands_root.add_child(island)
	island.global_position = pos
	island.visible = false
	var radius := rng.randf_range(GameConfig.SCENIC_RADIUS_MIN, GameConfig.SCENIC_RADIUS_MAX)
	_scenic_islands.append(island)
	# Queue the build so boot stays snappy; islets are tiny, one per idle frame.
	_pending_scenic_builds.append(_scenic_islands.size() - 1)
	island.set_meta("scenic_seed", seed_key)
	island.set_meta("scenic_radius", radius)


func _drain_island_build_queue() -> bool:
	## One bastion shell (and maybe a texture) per idle tick. Returns true if work ran.
	if not _pending_island_builds.is_empty():
		var i: int = _pending_island_builds.pop_front()
		if i >= 0 and i < _islands.size():
			var island: Island = _islands[i]
			if island and is_instance_valid(island):
				island.build(i + 1, self)
				_apply_open_ocean()
				return true
		return false
	if _pending_scenic_builds.is_empty():
		return false
	var si: int = _pending_scenic_builds.pop_front()
	if si < 0 or si >= _scenic_islands.size():
		return false
	var scenic: Island = _scenic_islands[si]
	if scenic == null or not is_instance_valid(scenic):
		return false
	var seed_key: int = int(scenic.get_meta("scenic_seed", si))
	var radius: float = float(scenic.get_meta("scenic_radius", GameConfig.SCENIC_RADIUS_MIN))
	scenic.build_scenic(seed_key, radius, self)
	scenic.visible = true
	_apply_open_ocean()
	return true


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

	# Shape must exist so we know where to aim the camera.
	_ensure_island_built(current_level - 1)

	_active_island = _islands[current_level - 1]
	active_center = _active_island.get_center()
	_active_island.set_active(true)
	_wire_active_island()

	squadron_size = GameConfig.squadron_for_level(current_level)
	planes_remaining = squadron_size
	active_planes = 0
	_reset_decoys()
	_reset_siege_stats()

	# Build the following bastion's shell during this siege so the pan lands on a
	# finished island.
	if current_level < GameConfig.LEVEL_COUNT:
		_ensure_island_built(current_level)

	level_changed.emit(current_level)

	var zoom := _zoom_for_active_island()
	if pan:
		state = State.TRANSITION
		var tw := create_tween()
		tw.set_ease(Tween.EASE_IN_OUT)
		tw.set_trans(Tween.TRANS_CUBIC)
		tw.tween_property(camera, "position", active_center, GameConfig.CAMERA_PAN_DURATION)
		tw.parallel().tween_property(camera, "zoom", Vector2(zoom, zoom), GameConfig.CAMERA_PAN_DURATION)
		tw.tween_callback(_finish_pan_to_bastion)
	else:
		camera.position = active_center
		camera.zoom = Vector2(zoom, zoom)
		state = State.PLAYING
		_emit_hud()
	# The ocean cull is sized from the view rect, so a zoom change has to
	# re-upload coasts even when the camera has not moved.
	_apply_open_ocean()


## Widest zoom that still shows the bastion's sand plus a deployable ring.
func _zoom_for_active_island() -> float:
	if _active_island == null or camera == null:
		return DEFAULT_ZOOM
	var view: Vector2 = get_viewport().get_visible_rect().size
	var need: float = _active_island.get_water_min_radius() + DEPLOY_RING_MARGIN
	if need <= 0.0:
		return DEFAULT_ZOOM
	var fit: float = minf(view.x, view.y) * 0.5 / need
	return clampf(fit, MIN_ZOOM, DEFAULT_ZOOM)


func _finish_pan_to_bastion() -> void:
	state = State.PLAYING
	_emit_hud()


func _ensure_island_built(index: int) -> void:
	if index < 0 or index >= _islands.size():
		return
	var island: Island = _islands[index]
	if island == null or not is_instance_valid(island):
		return
	if island.is_built():
		return
	# Pull this index out of the background queue and build now.
	_pending_island_builds.erase(index)
	island.build(index + 1, self)
	_apply_open_ocean()


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
	_has_queued = false
	_spawn_cooldown = 0.0
	for p in planes.get_children():
		p.queue_free()
	for b in bullets.get_children():
		b.queue_free()
	for fx in effects.get_children():
		fx.queue_free()
	active_planes = 0
	_pending_ordnance = 0


func _apply_open_ocean() -> void:
	## Feed nearby island coasts so water lightens near shores and deepens
	## offshore. The shader loops over this array for every pixel, so uploading
	## the whole campaign made the water steadily more expensive as bastions and
	## islets came online — by level 20 it was ~30 coasts deep. Only coasts that
	## can actually tint a drawn pixel go up, which is a couple at a time.
	if ocean == null or ocean.material == null:
		return
	var mat := ocean.material as ShaderMaterial
	if mat == null:
		return
	mat.set_shader_parameter("open_ocean", true)

	var cam_pos: Vector2 = camera.position if camera else Vector2.ZERO
	_ocean_uniform_pos = cam_pos
	# Half-extent of the drawn ocean rect, matching _sync_map_layers_to_camera.
	var half := get_viewport().get_visible_rect().size / (camera.zoom * 2.0) if camera else Vector2.ZERO
	half += Vector2(160.0, 160.0)

	# [gap outside the rect, center, radius] for every coast still in range.
	var near: Array = []
	for island in _islands:
		if island == null or not island.is_built():
			continue
		_collect_ocean_coast(near, island, cam_pos, half)
	for scenic in _scenic_islands:
		if scenic == null or not scenic.is_built():
			continue
		_collect_ocean_coast(near, scenic, cam_pos, half)
	# Nearest first, so hitting the cap drops the coasts that matter least
	# instead of whichever happened to be built first.
	near.sort_custom(func(a: Array, b: Array) -> bool: return a[0] < b[0])

	var centers := PackedVector2Array()
	var radii := PackedFloat32Array()
	for entry in near:
		if centers.size() >= OCEAN_MAX_ISLANDS:
			break
		centers.append(entry[1])
		radii.append(entry[2])
	mat.set_shader_parameter("island_centers", centers)
	mat.set_shader_parameter("island_radii", radii)
	mat.set_shader_parameter("island_count", centers.size())


func _collect_ocean_coast(out: Array, island: Island, cam_pos: Vector2, half: Vector2) -> void:
	var center: Vector2 = island.get_center()
	var radius: float = island.get_water_min_radius()
	# Distance from the island centre to the drawn rect (0 when inside it).
	var d := (center - cam_pos).abs() - half
	var gap := Vector2(maxf(d.x, 0.0), maxf(d.y, 0.0)).length()
	if gap > radius + OCEAN_INFLUENCE_MARGIN:
		return
	out.append([gap, center, radius])


func _apply_clouds_enabled() -> void:
	## Keeps Clouds / CloudsFar / CloudShadows in the scene; just toggles draw.
	for name in ["Clouds", "CloudsFar", "CloudShadows"]:
		var rect := camera.get_node_or_null(name) as CanvasItem
		if rect:
			rect.visible = GameConfig.CLOUDS_ENABLED


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
	var clouds_far := camera.get_node_or_null("CloudsFar") as ColorRect
	var shadows := camera.get_node_or_null("CloudShadows") as ColorRect
	for rect in [ocean, clouds, clouds_far, shadows]:
		if rect == null:
			continue
		rect.offset_left = -half.x
		rect.offset_top = -half.y
		rect.offset_right = half.x
		rect.offset_bottom = half.y
