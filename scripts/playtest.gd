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
##   --strategy=NAME       spread (default) | blitz | waves — see _deploy_delay
##   --seed=N              fixed RNG seed for reproducible runs
##   --level=N             forwarded to the game via main.set_level(N) if it exists

const WAVE_SIZE := 5

var _out_dir := "playtest/latest"
var _planes_to_spawn := 6
var _duration := 25.0
var _shot_interval := 3.0
var _strategy := "spread"
var _level := 1
var _rng_seed := -1

var _main: Node2D
var _result := "timeout"
var _shots: PackedStringArray = []
var _shot_index := 0
var _start_ms := 0
var _input_taps := 0
var _direct_spawns := 0
var _missed_deploys := 0
var _deployed := 0


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
			_planes_to_spawn = GameConfig.SQUADRON_SIZE if v == "all" else int(v)
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
	if _rng_seed >= 0:
		seed(_rng_seed)
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


func _run() -> void:
	_start_ms = Time.get_ticks_msec()
	while get_tree().current_scene == null:
		await get_tree().process_frame
	await get_tree().process_frame
	_main = get_tree().current_scene

	if _main.has_signal("game_won"):
		_main.game_won.connect(func() -> void: _result = "won")
		_main.game_lost.connect(func() -> void: _result = "lost")
	if _level > 1 and _main.has_method("set_level"):
		_main.set_level(_level)

	await _screenshot("start")

	var next_shot := _shot_interval
	while _elapsed() < _duration and _result == "timeout":
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

	print("PLAYTEST loop done, result=%s elapsed=%.1f" % [_result, _elapsed()])
	# Let the win/lose overlay (or final effects) render before the last frame.
	await get_tree().create_timer(1.0).timeout
	await _screenshot("end-" + _result)
	print("PLAYTEST end shot saved")
	_write_summary()
	get_tree().quit(0)


## Tap water around the island; position and pacing depend on the strategy.
## Returns true when a plane was actually deployed.
func _deploy_bomber(i: int) -> bool:
	# Squadron exhausted (game may cap below what we were asked to deploy).
	if "planes_remaining" in _main and _main.planes_remaining <= 0:
		_deployed = _planes_to_spawn
		return false

	var radius := GameConfig.WATER_MIN_RADIUS + randf_range(15.0, 55.0)
	var world := GameConfig.ISLAND_CENTER + Vector2.from_angle(_deploy_angle(i)) * radius

	# Property may be missing if main.gd currently fails to parse; stay quiet.
	var before: int = _main.planes_remaining if "planes_remaining" in _main else -1
	_tap(world)
	await get_tree().process_frame
	await get_tree().process_frame
	if before >= 0 and _main.planes_remaining < before:
		_input_taps += 1
		return true
	if _main.has_method("_try_spawn"):
		# Input transform mismatch fallback: spawn through the game API instead.
		_main._try_spawn(world)
		if before >= 0 and _main.planes_remaining < before:
			_direct_spawns += 1
			return true
	_missed_deploys += 1
	return before < 0  # Unknown state: don't retry forever, assume it worked.


func _deploy_angle(i: int) -> float:
	match _strategy:
		"blitz":
			# Panic-dump: mash taps anywhere around the island.
			return randf() * TAU
		"waves":
			# Each squad of WAVE_SIZE attacks from the next side (N/E/S/W).
			var wave := i / WAVE_SIZE
			return TAU * 0.25 * float(wave % 4) + randf_range(-0.5, 0.5)
		_:
			# spread: patient, evenly distributed around the island.
			return TAU * float(i) / float(maxi(_planes_to_spawn, 1)) + randf_range(-0.15, 0.15)


func _deploy_delay(i: int) -> float:
	match _strategy:
		"blitz":
			return 0.55  # Just above the game's spawn cooldown = max rate.
		"waves":
			return 4.0 if i % WAVE_SIZE == 0 else 0.55
		_:
			return 1.2


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
		"level": _level,
		"seed": _rng_seed,
		"elapsed_s": snappedf(_elapsed(), 0.1),
		"keep_hp": _main.keep.hp if is_instance_valid(_main) and "keep" in _main else -1,
		"planes_remaining": _main.planes_remaining if is_instance_valid(_main) and "planes_remaining" in _main else -1,
		"planes_deployed": _deployed,
		"taps_via_input": _input_taps,
		"spawns_via_fallback": _direct_spawns,
		"missed_deploys": _missed_deploys,
		"screenshots": _shots,
		"out_dir": _out_dir,
	}
	print("PLAYTEST_SUMMARY " + JSON.stringify(summary))
	var f := FileAccess.open(_abs_out().path_join("summary.json"), FileAccess.WRITE)
	f.store_string(JSON.stringify(summary, "  "))
	f.close()


func _elapsed() -> float:
	return float(Time.get_ticks_msec() - _start_ms) / 1000.0


func _abs_out() -> String:
	return ProjectSettings.globalize_path("res://" + _out_dir)
