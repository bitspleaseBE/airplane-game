extends Node

## Automated playtest harness for agentic dev loops.
## Inert unless the game is launched with user args: `godot --path . -- --playtest`.
## Simulates water taps to deploy bombers, captures screenshots at intervals,
## and writes playtest/latest/summary.json plus a PLAYTEST_SUMMARY line to stdout.
##
## User args (after `--`):
##   --playtest            enable the harness (required)
##   --out=DIR             output dir relative to project root (default playtest/latest)
##   --planes=N|all        bombers to deploy (default 6; "all" = full squadron)
##   --duration=S          max run seconds before ending (default 25)
##   --shot-interval=S     seconds between periodic screenshots (default 3)
##   --strategy=NAME       spread (default) | blitz | waves | flank | column — see _deploy_delay
##   --seed=N              fixed RNG seed for reproducible runs
##   --level=N             forwarded to the game via main.set_level(N) if it exists
##   --briefing            force the first-play mission briefing on screen
##   --wing-briefing[=NAME] force wing unlock vignette (bomber|strike|carpet)
##   --force-lose          after the start shot, fire the lose overlay (HUD UI check)
##   --force-win           after the start shot, fire the win overlay (HUD UI check)
##   --force-campaign-win  win overlay with campaign-complete copy + totals
##   --squadron=N          shrink reserves to N so depleting the budget can resolve as a loss
##   --perf                benchmark mode: vsync off, per-frame CPU/GPU timing,
##                         island-build timing; writes a "perf" block to the summary
##   --ocean=flat|off      perf attribution: flat = island_count 0 (skip the
##                         per-island shader loop), off = hide the ocean rect

const WAVE_SIZE := 5

var _out_dir := "playtest/latest"
var _planes_to_spawn := 6
var _planes_all := false
var _duration := 25.0
var _shot_interval := 3.0
var _strategy := "spread"
var _level := 1
var _rng_seed := -1
var _force_briefing := false
var _force_wing_briefing := false
var _force_wing_name := "bomber"
var _force_lose := false
var _force_win := false
var _force_campaign_win := false
## UI-only captures. The pause panel and the aiming reticle are both built in
## code, so a screenshot is the only thing that catches a layout regression.
var _show_pause := ""
var _show_reticle := false
## Regression check for a shipped bug: restarting from the pause menu while a
## result modal was open left the modal on screen over a live siege with
## mouse_filter=STOP, so every tap was swallowed and the level was unplayable.
var _check_modal_restart := false
var _squadron_cap := -1
var _perf := false
var _ocean_mode := ""  # "" (normal) | "flat" | "off"
var _perf_sampling := false
var _frame_ms := PackedFloat32Array()
var _gpu_ms := PackedFloat32Array()
var _cpu_render_ms := PackedFloat32Array()
var _draw_calls_max := 0

var _main: Node2D
var _result := "timeout"
var _shots: PackedStringArray = []
var _shot_index := 0
var _start_ms := 0
var _game_time := 0.0
var _input_taps := 0
var _direct_spawns := 0
var _missed_deploys := 0
var _deployed := 0
var _decoys_sent := 0
## The harness draws from its own stream, never the global one.
##
## Every placement decision below used to call the global randf()/randi(), which
## combat also draws from — Sfx._play picks a pitch per one-shot, Turret._fire
## jitters its aim. So the number of planes that died earlier in a run decided
## which numbers the harness got later, and any balance change alters how many
## planes die. That made --seed isolate nothing across exactly the comparisons
## it exists for: weakening a defender measured as making two bastions *harder*,
## which is impossible, and was this coupling rather than a real effect.
var _rng := RandomNumberGenerator.new()


## The seed the harness was asked to run, or -1 for none. Read by main.gd,
## which must not call randomize() over the top of a requested seed — that is
## what made the balance gate non-reproducible: --seed was set here, then
## clobbered a frame later when the level scene came up, so Gate 1 was really
## measuring run-to-run noise.
func requested_seed() -> int:
	return _rng_seed


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	if not args.has("--playtest"):
		set_process(false)
		return
	for arg in args:
		if arg.begins_with("--out="):
			_out_dir = arg.trim_prefix("--out=")
		elif arg.begins_with("--planes="):
			var v := arg.trim_prefix("--planes=")
			if v == "all":
				_planes_all = true
				_planes_to_spawn = GameConfig.SQUADRON_SIZE
			else:
				_planes_to_spawn = int(v)
		elif arg.begins_with("--duration="):
			_duration = float(arg.trim_prefix("--duration="))
		elif arg.begins_with("--shot-interval="):
			_shot_interval = float(arg.trim_prefix("--shot-interval="))
		elif arg.begins_with("--strategy="):
			_strategy = arg.trim_prefix("--strategy=")
		elif arg.begins_with("--seed="):
			_rng_seed = int(arg.trim_prefix("--seed="))
		elif arg.begins_with("--level="):
			_level = int(arg.trim_prefix("--level="))
		elif arg == "--briefing":
			_force_briefing = true
		elif arg == "--wing-briefing" or arg.begins_with("--wing-briefing="):
			_force_wing_briefing = true
			if arg.begins_with("--wing-briefing="):
				_force_wing_name = arg.trim_prefix("--wing-briefing=").strip_edges().to_lower()
		elif arg == "--force-lose":
			_force_lose = true
			_planes_to_spawn = 0
			_duration = mini(_duration, 4.0)
		elif arg == "--force-win":
			_force_win = true
			_planes_to_spawn = 0
			_duration = mini(_duration, 4.0)
		elif arg == "--force-campaign-win":
			_force_campaign_win = true
			_force_win = true
			_planes_to_spawn = 0
			_duration = mini(_duration, 4.0)
		elif arg.begins_with("--squadron="):
			_squadron_cap = int(arg.trim_prefix("--squadron="))
		elif arg == "--pause-menu" or arg.begins_with("--pause-menu="):
			_show_pause = "root"
			if arg.begins_with("--pause-menu="):
				_show_pause = arg.trim_prefix("--pause-menu=").strip_edges().to_lower()
			_planes_to_spawn = 0
			_duration = minf(_duration, 4.0)
		elif arg == "--reticle":
			_show_reticle = true
		elif arg == "--modal-restart":
			_check_modal_restart = true
			_planes_to_spawn = 0
			_duration = minf(_duration, 8.0)
		elif arg == "--perf":
			_perf = true
		elif arg.begins_with("--ocean="):
			_ocean_mode = arg.trim_prefix("--ocean=")
	if _perf:
		# Uncap the frame rate so FPS reflects real headroom, and let the
		# renderer report per-viewport CPU/GPU time.
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
		Engine.max_fps = 0
		RenderingServer.viewport_set_measure_render_time(get_viewport().get_viewport_rid(), true)
		# Periodic screenshots stall the pipeline (GPU readback) — start/end only.
		_shot_interval = 100000.0
	if not _show_pause.is_empty():
		process_mode = Node.PROCESS_MODE_ALWAYS
	# Seed both: the harness's own stream for placement, and the global one so
	# the level's procedural content is still reproducible.
	if _rng_seed >= 0:
		_rng.seed = _rng_seed
		seed(_rng_seed)
	else:
		_rng.randomize()
	DirAccess.make_dir_recursive_absolute(_abs_out())
	AudioServer.set_bus_mute(0, true)
	# Keep the window unoccluded: macOS stops presenting frames for hidden
	# windows, which would freeze screenshot capture.
	DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_ALWAYS_ON_TOP, true)
	# Failsafe: never hang the agent's terminal, and still report what we have.
	get_tree().create_timer(_duration + 15.0).timeout.connect(func() -> void:
		printerr("PLAYTEST failsafe timeout hit")
		_result = "failsafe-timeout"
		_write_summary()
		get_tree().quit(1)
	)
	_run()


func _process(delta: float) -> void:
	# Game time, not wall time. Under --fixed-fps the engine advances a fixed
	# delta per frame regardless of how long the frame actually took, so on a
	# software renderer wall clock runs far ahead of the simulation — a bastion
	# that takes 50s of game time reported 160s of wall clock, which is not a
	# number the duration gate can use. Accumulating delta gives the figure a
	# player would experience.
	_game_time += delta
	if not _perf:
		return
	# The game re-feeds island arrays to the ocean shader as builds finish, so
	# attribution overrides must be re-asserted every frame.
	_apply_ocean_mode()
	if not _perf_sampling:
		return
	_frame_ms.append(delta * 1000.0)
	var rid := get_viewport().get_viewport_rid()
	_gpu_ms.append(RenderingServer.viewport_get_measured_render_time_gpu(rid))
	_cpu_render_ms.append(RenderingServer.viewport_get_measured_render_time_cpu(rid))
	_draw_calls_max = maxi(
		_draw_calls_max,
		int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)),
	)


func _apply_ocean_mode() -> void:
	if _ocean_mode.is_empty() or _main == null or not "ocean" in _main:
		return
	var ocean: CanvasItem = _main.ocean
	if ocean == null:
		return
	if _ocean_mode == "off":
		ocean.visible = false
	elif _ocean_mode == "flat":
		var mat := ocean.material as ShaderMaterial
		if mat:
			mat.set_shader_parameter("island_count", 0)


func _run() -> void:
	_start_ms = Time.get_ticks_msec()
	while get_tree().current_scene == null:
		await get_tree().process_frame
	await get_tree().process_frame
	_main = get_tree().current_scene

	# Campaign _ready finishes before current_scene is assigned.
	await get_tree().process_frame

	if _main.has_signal("game_won"):
		_main.game_won.connect(func(_stars: int = 0, _done: bool = false) -> void: _result = "won")
		_main.game_lost.connect(func() -> void: _result = "lost")
	if _main.has_method("set_level"):
		_main.set_level(_level)
	if _squadron_cap > 0 and "planes_remaining" in _main:
		_main.squadron_size = _squadron_cap
		_main.planes_remaining = _squadron_cap
		if _main.has_signal("squadron_changed"):
			_main.squadron_changed.emit(_squadron_cap)
		_planes_to_spawn = _squadron_cap
		_planes_all = true
	elif _planes_all and "squadron_size" in _main:
		_planes_to_spawn = int(_main.squadron_size)

	if _force_briefing:
		var hud := _main.get_node_or_null("HUD")
		if hud and hud.has_method("force_briefing"):
			hud.force_briefing()
			# Let the pop-in tween settle before the first shot.
			await get_tree().create_timer(0.7).timeout
	elif _force_wing_briefing:
		var hud_w := _main.get_node_or_null("HUD")
		if hud_w and hud_w.has_method("force_wing_briefing"):
			var wing_type: GameConfig.PlaneType = GameConfig.PlaneType.BOMBER
			match _force_wing_name:
				"strike", "11":
					wing_type = GameConfig.PlaneType.STRIKE
				"carpet", "16":
					wing_type = GameConfig.PlaneType.CARPET
				_:
					wing_type = GameConfig.PlaneType.BOMBER
			hud_w.force_wing_briefing(wing_type)
			await get_tree().create_timer(1.4).timeout

	if _show_reticle:
		# Nudging the reticle through the normal path is what proves the
		# keyboard aim wiring works, not just that the node draws.
		Input.action_press("cursor_right")
		await get_tree().create_timer(0.35).timeout
		Input.action_release("cursor_right")
		await get_tree().process_frame

	if _check_modal_restart:
		await _run_modal_restart_check()
		return

	if not _show_pause.is_empty():
		var menu := _main.get_node_or_null("PauseMenu")
		if menu and menu.has_method("open"):
			menu.open()
			if _show_pause == "options" and menu.has_method("show_options"):
				menu.show_options()
			await get_tree().create_timer(0.3).timeout
		await _screenshot("pause")
		_result = "pause-menu"
		_write_summary()
		get_tree().quit(0)
		return

	await _screenshot("start")

	if _force_lose and _main.has_method("_set_lost"):
		if "planes_deployed" in _main:
			_main.planes_deployed = 9
		if "planes_crashed" in _main:
			_main.planes_crashed = 9
		if "guns_destroyed" in _main:
			_main.guns_destroyed = 2
		_main._set_lost()
		await get_tree().create_timer(0.5).timeout
	elif _force_win:
		# Seed after-action numbers so the modal isn't a wall of zeros.
		if _force_campaign_win:
			if "campaign_planes_deployed" in _main:
				_main.campaign_planes_deployed = 186
			if "campaign_planes_crashed" in _main:
				_main.campaign_planes_crashed = 61
			if "campaign_guns_destroyed" in _main:
				_main.campaign_guns_destroyed = 94
		else:
			if "planes_deployed" in _main:
				_main.planes_deployed = 12
			if "planes_crashed" in _main:
				_main.planes_crashed = 4
			if "guns_destroyed" in _main:
				_main.guns_destroyed = 7
		if "state" in _main:
			_main.state = 1  # State.WON
		if _main.has_signal("game_won"):
			_main.game_won.emit(3, _force_campaign_win)
		await get_tree().create_timer(0.5).timeout

	if _perf:
		# Let boot bakes / first-frame hitches settle before measuring.
		await get_tree().create_timer(1.0).timeout
		_perf_sampling = true

	var next_shot := _shot_interval
	while _elapsed() < _duration and _result == "timeout":
		if _force_lose or _force_win:
			await get_tree().process_frame
			continue
		if _strategy == "decoy" and _should_feint():
			await _deploy_decoy()
			await get_tree().create_timer(_deploy_delay(_deployed)).timeout
			continue
		if _deployed < _planes_to_spawn:
			if await _deploy_bomber(_deployed):
				_deployed += 1
				await get_tree().create_timer(_deploy_delay(_deployed)).timeout
			else:
				# Spawn cooldown or blocked tap — back off briefly and retry.
				await get_tree().create_timer(0.2).timeout
		else:
			await get_tree().create_timer(0.25).timeout
		if _elapsed() >= next_shot:
			await _screenshot("t%02ds" % int(_elapsed()))
			next_shot = _elapsed() + _shot_interval

	_perf_sampling = false
	print("PLAYTEST loop done, result=%s elapsed=%.1f" % [_result, _elapsed()])
	# Let the win/lose overlay (or final effects) render before the last frame.
	# Stars flip one-by-one (~1.8s); give force overlays enough settle time.
	var settle := 2.0 if (_force_win or _force_lose) else 1.0
	await get_tree().create_timer(settle).timeout
	await _screenshot("end-" + _result)
	print("PLAYTEST end shot saved")
	_write_summary()
	get_tree().quit(0)


## Win the level, let the modal settle, then restart from the pause menu and
## assert the siege is actually playable afterwards. Prints MODAL_RESTART_CHECK
## with pass/fail so a caller can gate on it.
func _run_modal_restart_check() -> void:
	var hud := _main.get_node_or_null("HUD")
	var menu := _main.get_node_or_null("PauseMenu")
	if hud == null or menu == null:
		print("MODAL_RESTART_CHECK fail reason=missing-nodes")
		_result = "modal-restart-fail"
		_write_summary()
		get_tree().quit(1)
		return

	_main._set_won()
	# Stars flip one at a time; wait the modal out so this exercises the real
	# state a player would hit, not a half-built overlay.
	await get_tree().create_timer(2.6).timeout
	var overlay_after_win: bool = hud.overlay.visible

	menu.open()
	await get_tree().create_timer(0.25).timeout
	menu._on_restart_level()
	await get_tree().create_timer(0.6).timeout

	var overlay_still_up: bool = hud.overlay.visible
	var playing: bool = _main.state == _main.State.PLAYING
	var unpaused := not get_tree().paused
	var ok := overlay_after_win and not overlay_still_up and playing and unpaused
	print(
		(
			"MODAL_RESTART_CHECK %s modal_shown=%s modal_cleared=%s playing=%s unpaused=%s"
			% [
				"pass" if ok else "fail",
				overlay_after_win,
				not overlay_still_up,
				playing,
				unpaused,
			]
		)
	)
	await _screenshot("modal-restart")
	_result = "modal-restart-pass" if ok else "modal-restart-fail"
	_write_summary()
	get_tree().quit(0 if ok else 1)


## True when the column has flown far enough since the last feint and a charge
## is actually available.
func _should_feint() -> bool:
	if _deployed <= 0 or _deployed >= _planes_to_spawn:
		return false
	# A feint is refused once the wing is spent, so without this the loop would
	# sit here re-arming a charge it can never use for the rest of the run.
	if "planes_remaining" in _main and _main.planes_remaining <= 0:
		return false
	if not ("decoy_charges" in _main) or _main.decoy_charges <= 0:
		return false
	return _deployed >= (_decoys_sent + 1) * DECOY_EVERY


## Arm a feint and throw it at the busiest water, which is the only place a
## decoy earns anything: it drags those mounts off the lane the column needs.
func _deploy_decoy() -> void:
	if not _main.has_method("set_decoy_armed"):
		return
	var center: Vector2 = (
		_main.active_center if "active_center" in _main else GameConfig.ISLAND_CENTER
	)
	var water_min := GameConfig.WATER_MIN_RADIUS
	if _main.has_method("active_water_min_radius"):
		water_min = _main.active_water_min_radius()
	var theta := _feint_angle(_column_angle if _column_locked else _coldest_angle())
	var world := center + Vector2.from_angle(theta) * _deploy_radius(theta, water_min)
	var before: int = _main.decoy_charges
	_main.set_decoy_armed(true)
	_tap(world)
	for _f in 30:
		await get_tree().process_frame
		if _main.decoy_charges < before:
			_decoys_sent += 1
			return
	# Input path did not take it; go through the game API like _deploy_bomber.
	if _main.has_method("_try_decoy"):
		_main.set_decoy_armed(true)
		_main._try_decoy(world)
		if _main.decoy_charges < before:
			_decoys_sent += 1
			return
	_main.set_decoy_armed(false)


## Tap water around the island; position and pacing depend on the strategy.
## Returns true when a plane was actually deployed.
func _deploy_bomber(i: int) -> bool:
	# Squadron exhausted (game may cap below what we were asked to deploy).
	if "planes_remaining" in _main and _main.planes_remaining <= 0:
		_deployed = _planes_to_spawn
		return false

	var center: Vector2 = (
		_main.active_center if "active_center" in _main else GameConfig.ISLAND_CENTER
	)
	var water_min := GameConfig.WATER_MIN_RADIUS
	if _main.has_method("active_water_min_radius"):
		water_min = _main.active_water_min_radius()
	# Mix near-shore lagoon taps with deep open-water taps (both must work), but
	# never past the edge of the screen: a human cannot tap water they cannot
	# see, so measuring placements out there would flatter every strategy with
	# deploys nobody can actually make. On the big late islands this was most of
	# the deep band, and it showed up as spawns_via_fallback in the summary.
	var theta := _deploy_angle(i)
	var world := center + Vector2.from_angle(theta) * _deploy_radius(theta, water_min)

	# Property may be missing if main.gd currently fails to parse; stay quiet.
	var before: int = _main.planes_remaining if "planes_remaining" in _main else -1
	_tap(world)
	# Deploys are rate-limited, and a tap during the scramble gap is parked
	# rather than dropped — so wait out a full gap before calling it a miss.
	var wait_frames := int(ceil((GameConfig.deploy_interval_for_level(_level) + 0.2) * 60.0))
	for _f in wait_frames:
		await get_tree().process_frame
		if before >= 0 and _main.planes_remaining < before:
			_input_taps += 1
			return true
	if _main.has_method("_try_spawn"):
		# Input transform mismatch fallback: spawn through the game API instead.
		# from_press=true — discrete taps always deploy, same as a real click.
		_main._try_spawn(world, true)
		if before >= 0 and _main.planes_remaining < before:
			_direct_spawns += 1
			return true
	_missed_deploys += 1
	return before < 0  # Unknown state: don't retry forever, assume it worked.


## How far out to release along `theta`.
##
## Depth is part of the tactic, not scenery. A pilot who is reading the board
## also releases close to the beach — every extra length of open water is
## another second under the guns — while unthinking play scatters birds across
## the whole visible sea. Modelling that as random for every strategy quietly
## made the reading strategies fly 40% further under fire the moment the camera
## started framing the bigger bastions properly.
func _deploy_radius(theta: float, water_min: float) -> float:
	# Never inside the sand: on a bastion wider than the view the visible limit
	# can fall short of the shoreline, and clamping blindly would aim at land.
	var near := water_min + 20.0
	var far := maxf(_max_visible_radius(theta), near)
	match _strategy:
		"flank", "column", "decoy":
			return clampf(water_min + _rng.randf_range(20.0, 110.0), near, far)
		_:
			return clampf(water_min + _rng.randf_range(20.0, 420.0), near, far)


## Furthest a deploy can sit from the bastion along `theta` and still be on
## screen. Assumes the camera is centred on the active bastion, which it is
## outside of level transitions.
func _max_visible_radius(theta: float) -> float:
	var view: Vector2 = get_viewport().get_visible_rect().size * 0.5
	var cam: Camera2D = _main.camera if "camera" in _main else null
	if cam:
		view /= cam.zoom
	view -= Vector2(56.0, 56.0)  # keep clear of the HUD edges
	var dir := Vector2.from_angle(theta)
	var limit := INF
	if absf(dir.x) > 0.001:
		limit = minf(limit, absf(view.x / dir.x))
	if absf(dir.y) > 0.001:
		limit = minf(limit, absf(view.y / dir.y))
	return limit


func _deploy_angle(i: int) -> float:
	match _strategy:
		"blitz":
			# Panic-dump: mash taps anywhere around the island.
			return _rng.randf() * TAU
		"flank":
			# Skilled placement proxy: send the bird in where the bastion's guns
			# are not currently looking. This is the strategy the threat readout
			# is meant to let a human play — if it does not beat the random
			# strategies, placement is not yet a real decision.
			return _coldest_angle()
		"decoy", "column":
			# The strongest one-direction attack available: find the quietest
			# bearing once, then commit the whole squadron to it. The campaign is
			# supposed to answer sustained pressure from a fixed heading, so from
			# the third bastion on this must fail — see the design-gates skill.
			if !_column_locked:
				_column_locked = true
				_column_angle = _coldest_angle()
			return _column_angle + _rng.randf_range(-0.05, 0.05)
		"waves":
			# Each squad of WAVE_SIZE attacks from the next side (N/E/S/W).
			var wave := i / WAVE_SIZE
			return TAU * 0.25 * float(wave % 4) + _rng.randf_range(-0.5, 0.5)
		_:
			# spread: patient, evenly distributed around the island.
			return TAU * float(i) / float(maxi(_planes_to_spawn, 1)) + _rng.randf_range(-0.15, 0.15)


## Score every approach corridor by how much living gun attention covers the
## run in, then pick at random from the quietest few. Mirrors what a player
## reads off the threat wedges — and picking from a band rather than the single
## argmin matters: always taking the one best bearing funnels the whole squadron
## down one lane, which lets a single gun hold the lock and eat all of it.
const FLANK_SAMPLES := 24
const FLANK_COLD_BAND := 7

## "column" locks one bearing for the whole siege.
var _column_locked := false
var _column_angle := 0.0

## Birds between feints for the `decoy` strategy. Sized so a charge is spent
## roughly as fast as one comes back — the point of the gate is to measure a
## decoy layer under its own recharge rate, not an unlimited one.
const DECOY_EVERY := 5


func _coldest_angle() -> float:
	var scored := _scored_bearings()
	if scored.is_empty():
		return _rng.randf() * TAU
	var pick: Array = scored[_rng.randi() % mini(FLANK_COLD_BAND, scored.size())]
	return float(pick[1]) + _rng.randf_range(-0.12, 0.12)


## Where to throw a feint in order to open `lane`.
##
## Not the globally hottest water — that was the first thing tried and it barely
## moved the needle. A mount can only be dragged SECTOR_HOME_SPAN (~57°) off its
## own corner, so a decoy on the far side of the island pulls mounts that were
## never covering the lane anyway. The feint has to land just outside the lane,
## inside the slew span of the very mounts holding it, and alternate sides so
## the two flanking mounts both get walked away from the corridor.
const FEINT_OFFSET := 0.92  # ~53°, just inside SECTOR_HOME_SPAN


func _feint_angle(lane: float) -> float:
	var side := 1.0 if _decoys_sent % 2 == 0 else -1.0
	return lane + side * FEINT_OFFSET + _rng.randf_range(-0.08, 0.08)


## Every approach bearing paired with how much living gun attention covers the
## run in, sorted coldest first.
func _scored_bearings() -> Array:
	var island: Object = _main.get_active_island() if _main.has_method("get_active_island") else null
	if island == null or not island.has_method("living_guns"):
		return []
	var guns: Array = island.living_guns()
	if guns.is_empty():
		return []
	var center: Vector2 = island.get_center()
	var spawn_r: float = _main.active_water_min_radius() + 90.0

	var scored: Array = []
	for i in FLANK_SAMPLES:
		var theta := TAU * float(i) / float(FLANK_SAMPLES)
		var spawn := center + Vector2.from_angle(theta) * spawn_r
		var score := 0.0
		# Integrate threat along the whole corridor, not just at the deploy
		# point — and past the keep as well as up to it, because the heavier
		# wings have to fly out the far side before their payload is spent.
		for step in 6:
			var probe: Vector2 = spawn.lerp(center, float(step) / 5.0 * 1.3)
			for gun in guns:
				var to_probe: Vector2 = probe - gun.global_position
				var d: float = to_probe.length()
				var reach: float = gun.threat_range()
				if d > reach:
					continue
				var bearing: float = to_probe.angle()
				# A gun that cannot traverse this far is no threat here at all —
				# the sector gaps are the main thing worth reading.
				var span: float = gun.threat_sector_span()
				if span > 0.0 and absf(angle_difference(gun.threat_sector_center(), bearing)) > span * 0.5:
					continue
				var facing: float = cos(angle_difference(gun.threat_aim(), bearing))
				score += (0.35 + maxf(facing, 0.0)) * (1.0 - d / reach)
		scored.append([score, theta])
	scored.sort_custom(func(a, b): return a[0] < b[0])
	return scored


func _deploy_delay(i: int) -> float:
	# Stay just above the level's deploy gap so taps aren't eaten by cooldown.
	var scramble: float = GameConfig.deploy_interval_for_level(_level) + 0.05
	match _strategy:
		"blitz", "flank", "column", "decoy":
			return scramble
		"waves":
			return 4.0 if i % WAVE_SIZE == 0 else scramble
		_:
			return maxf(1.2, scramble)


## Synthesize a screen touch through the real input pipeline.
func _tap(world: Vector2) -> void:
	var screen: Vector2 = get_viewport().get_canvas_transform() * world
	var press := InputEventScreenTouch.new()
	press.index = 0
	press.position = screen
	press.pressed = true
	Input.parse_input_event(press)
	var release := InputEventScreenTouch.new()
	release.index = 0
	release.position = screen
	release.pressed = false
	Input.parse_input_event(release)


func _screenshot(label: String) -> void:
	# Wait for a real draw, but bounded: frame_post_draw never fires while the
	# OS skips presenting, so after 1.5s force a draw and take what we get.
	var drew := [false]
	RenderingServer.frame_post_draw.connect(
		func() -> void: drew[0] = true, CONNECT_ONE_SHOT
	)
	var t0 := Time.get_ticks_msec()
	while not drew[0] and Time.get_ticks_msec() - t0 < 1500:
		await get_tree().process_frame
	if not drew[0]:
		RenderingServer.force_draw()
	var img := get_viewport().get_texture().get_image()
	_shot_index += 1
	var file := "%02d-%s.png" % [_shot_index, label]
	img.save_png(_abs_out().path_join(file))
	_shots.append(file)


func _write_summary() -> void:
	var summary := {
		"result": _result,
		"strategy": _strategy,
		"decoys_sent": _decoys_sent,
		"decoy_hits_absorbed": (
			int(_main.decoy_hits_absorbed) if _main and "decoy_hits_absorbed" in _main else 0
		),
		"level": _level,
		"seed": _rng_seed,
		"elapsed_s": snappedf(_elapsed(), 0.1),
		"wall_s": snappedf(_wall_elapsed(), 0.1),
		"keep_hp": _main.keep.hp if is_instance_valid(_main) and _main.keep != null else -1,
		"planes_remaining": _main.planes_remaining if is_instance_valid(_main) and "planes_remaining" in _main else -1,
		"planes_deployed": _deployed,
		"taps_via_input": _input_taps,
		"spawns_via_fallback": _direct_spawns,
		"missed_deploys": _missed_deploys,
		"screenshots": _shots,
		"out_dir": _out_dir,
	}
	if _perf:
		summary["perf"] = _perf_report()
	print("PLAYTEST_SUMMARY " + JSON.stringify(summary))
	var f := FileAccess.open(_abs_out().path_join("summary.json"), FileAccess.WRITE)
	f.store_string(JSON.stringify(summary, "  "))
	f.close()


func _perf_report() -> Dictionary:
	var window := DisplayServer.window_get_size()
	var report := {
		"ocean_mode": "normal" if _ocean_mode.is_empty() else _ocean_mode,
		"window": "%dx%d" % [window.x, window.y],
		"samples": _frame_ms.size(),
		"fps_avg": 0.0,
		"frame_ms": _stats(_frame_ms),
		"gpu_ms": _stats(_gpu_ms),
		"cpu_render_ms": _stats(_cpu_render_ms),
		"draw_calls_max": _draw_calls_max,
		"node_count": int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT)),
	}
	var total_ms := 0.0
	for v in _frame_ms:
		total_ms += v
	if total_ms > 0.0:
		report["fps_avg"] = snappedf(float(_frame_ms.size()) * 1000.0 / total_ms, 0.1)
	report["island_build"] = _bake_benchmark()
	return report


## Time building one island from scratch — coast LUTs, defences and palms. This is
## all that a level activation costs now that the beach is a shader; it used to
## also rasterise the beach per pixel in GDScript (1.3 s at level 1, 4.3 s at
## level 20) on the main thread, which no-threads web could not escape.
func _bake_benchmark() -> Dictionary:
	if not is_instance_valid(_main) or not _main.has_method("get_active_island"):
		return {}
	var isl: Island = _main.get_active_island()
	if isl == null:
		return {}
	# A throwaway island, so timing never disturbs the one being played.
	var probe: Island = load("res://scenes/island.tscn").instantiate()
	_main.add_child(probe)
	var best := INF
	for rep in 3:
		var t0 := Time.get_ticks_usec()
		probe.build(isl.level, _main)
		best = minf(best, float(Time.get_ticks_usec() - t0) / 1000.0)
	probe.queue_free()
	return {"build_ms": snappedf(best, 0.1)}


func _stats(samples: PackedFloat32Array) -> Dictionary:
	if samples.is_empty():
		return {}
	var s := samples.duplicate()
	s.sort()
	var sum := 0.0
	for v in s:
		sum += v
	var n := s.size()
	return {
		"avg": snappedf(sum / float(n), 0.01),
		"p50": snappedf(s[n / 2], 0.01),
		"p95": snappedf(s[mini(int(float(n) * 0.95), n - 1)], 0.01),
		"max": snappedf(s[n - 1], 0.01),
	}


## Seconds of simulated game time since the run began — what a player would
## have sat through. Duration gates read this.
func _elapsed() -> float:
	return _game_time


## Wall-clock seconds. Only useful for spotting a hung run; under --fixed-fps it
## has no relationship to how long the siege takes to play.
func _wall_elapsed() -> float:
	return float(Time.get_ticks_msec() - _start_ms) / 1000.0


func _abs_out() -> String:
	return ProjectSettings.globalize_path("res://" + _out_dir)
