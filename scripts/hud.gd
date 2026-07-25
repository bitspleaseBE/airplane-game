extends CanvasLayer

## HUD: squadron count, keep HP, level, star ratings, win/lose overlays, sound toggle,
## first-play briefing, and one-shot wing-unlock vignettes.

const SETTINGS_PATH := "user://settings.cfg"
const _AUDIO_ON: Texture2D = preload("res://assets/ui/audio_on.png")
const _AUDIO_OFF: Texture2D = preload("res://assets/ui/audio_off.png")
const _STAR_FULL: Texture2D = preload("res://assets/ui/star.png")
const _STAR_EMPTY: Texture2D = preload("res://assets/ui/star_empty.png")

## Defense upgrades only — airframe unlocks use the wing vignette instead.
const _UNLOCK_TOASTS := {
	4: "BASTION UPGRADE: MISSILE BATTERIES\nHeads on a swivel, ace.",
	13: "BASTION UPGRADE: FLAK GUNS\nThe sky just grew teeth.",
}

const _WING_HINTS := {
	GameConfig.PlaneType.GUNSHIP: "Tap the water, commander —\nsoft the guns, then the keep",
	GameConfig.PlaneType.BOMBER: "Tap the water, commander —\nscramble the bombers",
	GameConfig.PlaneType.STRIKE: "Tap the water, commander —\nloose the strike jets",
	GameConfig.PlaneType.CARPET: "Tap the water, commander —\none pass, three gifts",
}

## First bastion of each new wing.
const _WING_UNLOCK_LEVELS := {
	6: GameConfig.PlaneType.BOMBER,
	11: GameConfig.PlaneType.STRIKE,
	16: GameConfig.PlaneType.CARPET,
}

const _WING_BRIEFINGS := {
	GameConfig.PlaneType.BOMBER: "NEW PLANE: BOMBER\nDrops one big bomb on the keep.\nDeploys slower than gunships.",
	GameConfig.PlaneType.STRIKE: "NEW PLANE: STRIKE\nFires a missile from range, then peels off.\nDeploys faster — spam them.",
	GameConfig.PlaneType.CARPET: "NEW PLANE: CARPET\nDrops three bombs in one pass.\nSlowest to deploy — make each count.",
}

const _WING_CONTINUE_TEXT := "TAP TO CONTINUE"

## CueLabel rect: first-play (lower) vs wing unlock (raised, gap above continue).
const _CUE_RECT_FIRST := Vector4(-300.0, -210.0, 300.0, -70.0)
const _CUE_RECT_WING := Vector4(-300.0, -400.0, 300.0, -200.0)

const _WING_SETTINGS_KEYS := {
	GameConfig.PlaneType.BOMBER: "bomber",
	GameConfig.PlaneType.STRIKE: "strike",
	GameConfig.PlaneType.CARPET: "carpet",
}

const _FIRST_BRIEFING_TEXT := "TAP THE OPEN WATER\nTO DEPLOY YOUR JETFIGHTERS"

enum BriefingKind { NONE, FIRST, WING }

var _main: Node2D
var _sound_on: bool = true
var _campaign_complete: bool = false
var _last_level: int = 0
var _toast_tween: Tween
var _briefing_open := false
var _briefing_kind: BriefingKind = BriefingKind.NONE
var _briefing_wing: GameConfig.PlaneType = GameConfig.PlaneType.BOMBER
var _briefing_tween: Tween
var _vig_pulse_tween: Tween
var _cue_label_tween: Tween
var _stars_tween: Tween
var _wing_brief_queued := false
var _playtest := false
var _force_wing_briefing := false

@onready var squadron_label: Label = $Root/TopBar/SquadronRow/SquadronLabel
@onready var keep_bar: ProgressBar = $Root/TopBar/KeepBar
@onready var sound_button: Button = $Root/TopBar/SoundButton
@onready var level_label: Label = $Root/LevelLabel
@onready var wing_label: Label = $Root/TopBar/SquadronRow/WingLabel
@onready var toast_label: Label = $Root/ToastLabel
@onready var hint_label: Label = $Root/HintLabel
@onready var overlay: Control = $Root/Overlay
@onready var overlay_vignette: ColorRect = $Root/Overlay/Vignette
@onready var overlay_dim: ColorRect = $Root/Overlay/Dim
@onready var overlay_modal: PanelContainer = $Root/Overlay/Modal
@onready var stars_row: HBoxContainer = $Root/Overlay/Modal/Body/StarsRow
@onready var result_label: Label = $Root/Overlay/Modal/Body/ResultLabel
@onready var stats_label: Label = $Root/Overlay/Modal/Body/StatsLabel
@onready var restart_button: Button = $Root/Overlay/Modal/Body/ActionRow/RestartButton
@onready var new_game_button: Button = $Root/Overlay/Modal/Body/ActionRow/NewGameButton
@onready var version_label: Label = $Root/VersionLabel
@onready var briefing: Control = $Root/Briefing
@onready var briefing_vignette: ColorRect = $Root/Briefing/Vignette
@onready var tap_cue: Control = $Root/Briefing/TapCue
@onready var wing_demo: Control = $Root/Briefing/WingDemo
@onready var cue_label: Label = $Root/Briefing/CueLabel
@onready var continue_label: Label = $Root/Briefing/ContinueLabel


func _ready() -> void:
	version_label.text = "v%s" % ProjectSettings.get_setting("application/config/version", "?")
	sound_button.pressed.connect(_on_sound_toggled)
	briefing.gui_input.connect(_on_briefing_gui_input)
	_playtest = OS.get_cmdline_user_args().has("--playtest")
	_force_wing_briefing = _parse_force_wing_briefing()
	if _playtest:
		_sound_on = false
		_refresh_sound_button()
		return
	_sound_on = _load_sound_enabled()
	_apply_sound()


func setup(main_ref: Node2D) -> void:
	_main = main_ref
	_main.squadron_changed.connect(_on_squadron)
	_main.keep_hp_changed.connect(_on_keep_hp)
	_main.game_won.connect(_on_won)
	_main.game_lost.connect(_on_lost)
	if _main.has_signal("level_changed"):
		_main.level_changed.connect(_on_level)
	restart_button.pressed.connect(_on_restart)
	new_game_button.pressed.connect(_on_new_game)
	overlay.visible = false
	stars_row.visible = false
	new_game_button.visible = false
	briefing.visible = false
	if wing_demo and wing_demo.has_method("stop"):
		wing_demo.stop()
	_on_squadron(GameConfig.squadron_for_level(1))
	_on_keep_hp(GameConfig.KEEP_MAX_HP, GameConfig.KEEP_MAX_HP)
	_on_level(1)
	_maybe_show_first_briefing()


func force_briefing() -> void:
	## Playtest / debug: show the first-play briefing even if already seen.
	_show_first_briefing()


func force_wing_briefing(plane_type: GameConfig.PlaneType) -> void:
	## Playtest / debug: show a wing unlock vignette immediately.
	_show_wing_briefing(plane_type)


func is_briefing_open() -> bool:
	return _briefing_open


func _parse_force_wing_briefing() -> bool:
	for arg in OS.get_cmdline_user_args():
		if arg == "--wing-briefing" or arg.begins_with("--wing-briefing="):
			return true
	return false


func _forced_wing_type() -> GameConfig.PlaneType:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--wing-briefing="):
			var v := arg.trim_prefix("--wing-briefing=").strip_edges().to_lower()
			match v:
				"strike", "11":
					return GameConfig.PlaneType.STRIKE
				"carpet", "16":
					return GameConfig.PlaneType.CARPET
				_:
					return GameConfig.PlaneType.BOMBER
	return GameConfig.PlaneType.BOMBER


func _maybe_show_first_briefing() -> void:
	var args := OS.get_cmdline_user_args()
	if args.has("--briefing"):
		_show_first_briefing()
		return
	if _playtest:
		return
	if _load_briefing_seen():
		return
	_show_first_briefing()


func _show_first_briefing() -> void:
	if _briefing_open:
		return
	_briefing_kind = BriefingKind.FIRST
	_set_cue_rect(_CUE_RECT_FIRST)
	cue_label.text = _FIRST_BRIEFING_TEXT
	continue_label.visible = false
	tap_cue.visible = true
	if wing_demo and wing_demo.has_method("stop"):
		wing_demo.stop()
	_open_briefing_shell()
	if _briefing_tween and _briefing_tween.is_valid():
		_briefing_tween.kill()
	_briefing_tween = create_tween()
	_briefing_tween.set_parallel(true)
	tap_cue.modulate = Color(1, 1, 1, 0)
	cue_label.modulate = Color(1, 1, 1, 0)
	_briefing_tween.tween_property(tap_cue, "modulate:a", 1.0, 0.5).set_delay(0.1)
	_briefing_tween.tween_property(cue_label, "modulate:a", 1.0, 0.5).set_delay(0.15)
	_start_briefing_ambiance(false)


func _show_wing_briefing(plane_type: GameConfig.PlaneType) -> void:
	if _briefing_open:
		return
	if not _WING_BRIEFINGS.has(plane_type):
		return
	_briefing_kind = BriefingKind.WING
	_briefing_wing = plane_type
	_set_cue_rect(_CUE_RECT_WING)
	cue_label.text = _WING_BRIEFINGS[plane_type]
	continue_label.text = _WING_CONTINUE_TEXT
	continue_label.visible = true
	tap_cue.visible = false
	if wing_demo and wing_demo.has_method("setup"):
		wing_demo.setup(plane_type)
	_open_briefing_shell()
	if _briefing_tween and _briefing_tween.is_valid():
		_briefing_tween.kill()
	_briefing_tween = create_tween()
	_briefing_tween.set_parallel(true)
	cue_label.modulate = Color(1, 1, 1, 0)
	continue_label.modulate = Color(1, 1, 1, 0)
	_briefing_tween.tween_property(cue_label, "modulate:a", 1.0, 0.45).set_delay(0.1)
	_briefing_tween.tween_property(continue_label, "modulate:a", 1.0, 0.45).set_delay(0.2)
	_start_briefing_ambiance(true)


func _set_cue_rect(rect: Vector4) -> void:
	cue_label.offset_left = rect.x
	cue_label.offset_top = rect.y
	cue_label.offset_right = rect.z
	cue_label.offset_bottom = rect.w


func _open_briefing_shell() -> void:
	_briefing_open = true
	hint_label.visible = false
	briefing.visible = true
	briefing.mouse_filter = Control.MOUSE_FILTER_STOP
	briefing.modulate = Color(1, 1, 1, 1)
	if briefing_vignette.material:
		briefing_vignette.material.set_shader_parameter("pulse", 0.0)


func _start_briefing_ambiance(pulse_continue: bool = false) -> void:
	if _vig_pulse_tween and _vig_pulse_tween.is_valid():
		_vig_pulse_tween.kill()
	if briefing_vignette.material:
		_vig_pulse_tween = create_tween().set_loops()
		_vig_pulse_tween.tween_method(_set_vig_pulse, 0.15, 1.0, 1.4).set_trans(Tween.TRANS_SINE)
		_vig_pulse_tween.tween_method(_set_vig_pulse, 1.0, 0.15, 1.4).set_trans(Tween.TRANS_SINE)

	if _cue_label_tween and _cue_label_tween.is_valid():
		_cue_label_tween.kill()
	_cue_label_tween = create_tween().set_loops()
	# Pulse the continue cue on wing briefs; body text stays steady and readable.
	var pulse_target: CanvasItem = continue_label if pulse_continue else cue_label
	_cue_label_tween.tween_property(pulse_target, "modulate", Color(1, 0.93, 0.72, 1.0), 0.7)
	_cue_label_tween.tween_property(pulse_target, "modulate", Color(1, 0.85, 0.45, 0.75), 0.7)


func _set_vig_pulse(v: float) -> void:
	# Briefing + result overlay share one ShaderMaterial instance.
	if briefing_vignette and briefing_vignette.material:
		briefing_vignette.material.set_shader_parameter("pulse", v)
	elif overlay_vignette and overlay_vignette.material:
		overlay_vignette.material.set_shader_parameter("pulse", v)


func _start_overlay_ambiance() -> void:
	if _vig_pulse_tween and _vig_pulse_tween.is_valid():
		_vig_pulse_tween.kill()
	if overlay_vignette and overlay_vignette.material:
		overlay_vignette.material.set_shader_parameter("pulse", 0.0)
		_vig_pulse_tween = create_tween().set_loops()
		_vig_pulse_tween.tween_method(_set_vig_pulse, 0.15, 1.0, 1.4).set_trans(Tween.TRANS_SINE)
		_vig_pulse_tween.tween_method(_set_vig_pulse, 1.0, 0.15, 1.4).set_trans(Tween.TRANS_SINE)


func _stop_overlay_ambiance() -> void:
	if _vig_pulse_tween and _vig_pulse_tween.is_valid():
		_vig_pulse_tween.kill()
	if overlay_vignette and overlay_vignette.material:
		overlay_vignette.material.set_shader_parameter("pulse", 0.0)


func _on_briefing_gui_input(event: InputEvent) -> void:
	if not _briefing_open:
		return
	var tapped := false
	if event is InputEventScreenTouch and event.pressed:
		tapped = true
	elif event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		tapped = true
	if tapped:
		get_viewport().set_input_as_handled()
		_dismiss_briefing(true)


func _dismiss_briefing(save_seen: bool = true) -> void:
	if not _briefing_open:
		return
	var kind := _briefing_kind
	var wing := _briefing_wing
	_briefing_open = false
	_briefing_kind = BriefingKind.NONE
	briefing.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if wing_demo and wing_demo.has_method("stop"):
		wing_demo.stop()
	if _vig_pulse_tween and _vig_pulse_tween.is_valid():
		_vig_pulse_tween.kill()
	if _cue_label_tween and _cue_label_tween.is_valid():
		_cue_label_tween.kill()
	if _briefing_tween and _briefing_tween.is_valid():
		_briefing_tween.kill()
	_briefing_tween = create_tween()
	_briefing_tween.tween_property(briefing, "modulate:a", 0.0, 0.35)
	_briefing_tween.tween_callback(func() -> void:
		briefing.visible = false
		briefing.modulate = Color(1, 1, 1, 1)
		tap_cue.visible = true
		continue_label.visible = false
		_set_cue_rect(_CUE_RECT_FIRST)
		hint_label.visible = true
	)
	if save_seen and not _playtest:
		if kind == BriefingKind.FIRST:
			_save_briefing_seen(true)
		elif kind == BriefingKind.WING:
			_save_wing_briefing_seen(wing, true)


func _on_squadron(remaining: int) -> void:
	squadron_label.text = str(remaining)


func _on_keep_hp(current: int, maximum: int) -> void:
	keep_bar.max_value = maximum
	keep_bar.value = current


func _on_level(level: int) -> void:
	level_label.text = "Bastion %d / %d" % [level, GameConfig.LEVEL_COUNT]
	var wing_type: GameConfig.PlaneType = GameConfig.plane_type_for_level(level)
	wing_label.text = GameConfig.plane_name_for_level(level)
	var tint: Color = GameConfig.PLANE_TYPE_TINTS[wing_type]
	wing_label.add_theme_color_override("font_color", Color(tint.r, tint.g, tint.b, 0.95))
	hint_label.text = _WING_HINTS[wing_type]
	var prev := _last_level
	if level != prev and _UNLOCK_TOASTS.has(level):
		_show_toast(_UNLOCK_TOASTS[level])
	if level != prev and _WING_UNLOCK_LEVELS.has(level):
		_queue_wing_briefing(_WING_UNLOCK_LEVELS[level])
	_last_level = level


func _queue_wing_briefing(plane_type: GameConfig.PlaneType) -> void:
	if _wing_brief_queued or _briefing_open:
		return
	if _playtest and not _force_wing_briefing:
		return
	if not _force_wing_briefing and _load_wing_briefing_seen(plane_type):
		return
	_wing_brief_queued = true
	_await_playing_then_show_wing(plane_type)


func _await_playing_then_show_wing(plane_type: GameConfig.PlaneType) -> void:
	# Camera pan leaves state=TRANSITION; wait until the bastion is live.
	while is_instance_valid(_main) and not _main_is_playing():
		await get_tree().process_frame
	await get_tree().process_frame
	_wing_brief_queued = false
	if not is_instance_valid(_main):
		return
	if overlay.visible or _briefing_open:
		return
	if not _force_wing_briefing and _load_wing_briefing_seen(plane_type):
		return
	_show_wing_briefing(plane_type)


func _main_is_playing() -> bool:
	if _main == null:
		return false
	if _main.has_method("is_playing"):
		return bool(_main.is_playing())
	# State.PLAYING == 0
	return int(_main.get("state")) == 0


func _show_toast(message: String) -> void:
	if _toast_tween and _toast_tween.is_valid():
		_toast_tween.kill()
	toast_label.text = message
	toast_label.visible = true
	toast_label.modulate = Color(1, 1, 1, 0)
	_toast_tween = create_tween()
	_toast_tween.tween_property(toast_label, "modulate:a", 1.0, 0.35)
	_toast_tween.tween_interval(3.2)
	_toast_tween.tween_property(toast_label, "modulate:a", 0.0, 0.6)
	_toast_tween.tween_callback(func() -> void: toast_label.visible = false)


func _on_won(stars: int = 3, campaign_complete: bool = false) -> void:
	_campaign_complete = campaign_complete
	hint_label.visible = false
	if _briefing_open:
		_dismiss_briefing(true)
	_show_result_backdrop()
	result_label.add_theme_color_override("font_color", Color(1, 0.93, 0.72, 0.95))
	result_label.add_theme_color_override("font_outline_color", Color(0.12, 0.06, 0.02, 0.85))
	result_label.add_theme_constant_override("outline_size", 5)
	_animate_stars(stars)
	_fill_result_stats(campaign_complete)
	new_game_button.visible = false
	if campaign_complete:
		result_label.text = "ARCHIPELAGO CLEARED.\nOutstanding work, Commander.\nEvery bastion is smoke and glory."
		restart_button.text = "Run it back"
	else:
		result_label.text = "BASTION DOWN.\nWell flown, Commander.\nNothing left but smoke and glory."
		restart_button.text = "Next bastion"
	_arm_action_buttons()


func _on_lost() -> void:
	_campaign_complete = false
	hint_label.visible = false
	if _briefing_open:
		_dismiss_briefing(true)
	_stop_stars_tween()
	_show_result_backdrop()
	result_label.add_theme_color_override("font_color", Color(1, 0.93, 0.72, 0.95))
	result_label.add_theme_color_override("font_outline_color", Color(0.12, 0.06, 0.02, 0.85))
	result_label.add_theme_constant_override("outline_size", 5)
	stars_row.visible = false
	_fill_result_stats(false)
	result_label.text = "Squadron's spent.\nUnacceptable, Commander."
	restart_button.text = "Try again"
	new_game_button.visible = true
	new_game_button.text = "Start over"
	_arm_action_buttons()


func _fill_result_stats(campaign_complete: bool) -> void:
	var deployed := 0
	var crashed := 0
	var guns := 0
	if _main and _main.has_method("result_stats"):
		var stats: Dictionary = _main.result_stats(campaign_complete)
		deployed = int(stats.get("planes_deployed", 0))
		crashed = int(stats.get("planes_crashed", 0))
		guns = int(stats.get("guns_destroyed", 0))
	elif _main:
		deployed = int(_main.get("planes_deployed")) if "planes_deployed" in _main else 0
		crashed = int(_main.get("planes_crashed")) if "planes_crashed" in _main else 0
		guns = int(_main.get("guns_destroyed")) if "guns_destroyed" in _main else 0
	var scope := "Campaign" if campaign_complete else "This siege"
	stats_label.text = "%s report\nAirframes deployed: %d\nShot down: %d\nGuns silenced: %d" % [
		scope, deployed, crashed, guns
	]


func _show_result_backdrop() -> void:
	## Warm vignette + centered after-action modal.
	overlay.visible = true
	overlay_vignette.visible = true
	overlay_dim.visible = true
	if overlay_modal:
		overlay_modal.visible = true
		var half := Vector2(
			(overlay_modal.offset_right - overlay_modal.offset_left) * 0.5,
			(overlay_modal.offset_bottom - overlay_modal.offset_top) * 0.5
		)
		overlay_modal.pivot_offset = half
		overlay_modal.modulate = Color(1, 1, 1, 0)
		overlay_modal.scale = Vector2(0.92, 0.92)
		var tw := create_tween()
		tw.set_parallel(true)
		tw.tween_property(overlay_modal, "modulate:a", 1.0, 0.22)
		tw.tween_property(overlay_modal, "scale", Vector2.ONE, 0.28).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	_start_overlay_ambiance()


func _arm_action_buttons() -> void:
	# Ignore the tap/click that was already in flight when the overlay appeared,
	# otherwise a spawn tap becomes an accidental try-again / next-bastion.
	restart_button.disabled = true
	new_game_button.disabled = true
	get_tree().create_timer(0.35).timeout.connect(func() -> void:
		if is_instance_valid(restart_button):
			restart_button.disabled = false
		if is_instance_valid(new_game_button):
			new_game_button.disabled = false
	)


func _animate_stars(stars: int) -> void:
	## Grey empties first, then flip earned stars to gold one by one.
	_stop_stars_tween()
	var filled := clampi(stars, 0, 3)
	for i in stars_row.get_child_count():
		var icon := stars_row.get_child(i) as TextureRect
		if icon == null:
			continue
		icon.texture = _STAR_EMPTY
		icon.modulate = Color(1, 1, 1, 0.55)
		icon.scale = Vector2.ONE
		icon.pivot_offset = icon.custom_minimum_size * 0.5
	stars_row.visible = true
	stars_row.modulate = Color(1, 1, 1, 0)

	_stars_tween = create_tween()
	_stars_tween.tween_property(stars_row, "modulate:a", 1.0, 0.2)
	_stars_tween.tween_interval(0.12)
	for i in filled:
		var icon := stars_row.get_child(i) as TextureRect
		if icon == null:
			continue
		_stars_tween.tween_property(icon, "scale:x", 0.08, 0.11).set_trans(Tween.TRANS_SINE)
		_stars_tween.tween_callback(_reveal_star.bind(icon))
		_stars_tween.tween_property(icon, "scale:x", 1.0, 0.2).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
		_stars_tween.parallel().tween_property(icon, "scale:y", 1.12, 0.1)
		_stars_tween.tween_property(icon, "scale:y", 1.0, 0.12).set_trans(Tween.TRANS_SINE)
		_stars_tween.tween_interval(0.1)
	# Bake the next bastion only after flips finish — a mid-tween WASM bake
	# freezes the star animation and the Next button alike.
	if not _campaign_complete and _main and _main.has_method("prep_next_bastion_after_stars"):
		_stars_tween.tween_callback(_main.prep_next_bastion_after_stars)


func _reveal_star(icon: TextureRect) -> void:
	if not is_instance_valid(icon):
		return
	icon.texture = _STAR_FULL
	icon.modulate = Color(1, 1, 1, 1)


func _stop_stars_tween() -> void:
	if _stars_tween and _stars_tween.is_valid():
		_stars_tween.kill()
	_stars_tween = null
	for i in stars_row.get_child_count():
		var icon := stars_row.get_child(i) as TextureRect
		if icon:
			icon.scale = Vector2.ONE


func _on_restart() -> void:
	_stop_overlay_ambiance()
	_stop_stars_tween()
	overlay.visible = false
	stars_row.visible = false
	new_game_button.visible = false
	hint_label.visible = true
	if _main:
		_main.advance_or_restart()


func _on_new_game() -> void:
	_stop_overlay_ambiance()
	_stop_stars_tween()
	overlay.visible = false
	stars_row.visible = false
	new_game_button.visible = false
	hint_label.visible = true
	if _main and _main.has_method("restart_campaign"):
		_main.restart_campaign()


func _on_sound_toggled() -> void:
	_sound_on = not _sound_on
	_apply_sound()
	_save_sound_enabled(_sound_on)


func _apply_sound() -> void:
	AudioServer.set_bus_mute(0, not _sound_on)
	_refresh_sound_button()


func _refresh_sound_button() -> void:
	sound_button.icon = _AUDIO_ON if _sound_on else _AUDIO_OFF
	sound_button.text = ""
	sound_button.modulate = Color(1, 1, 1, 1.0)
	sound_button.tooltip_text = "Sound on" if _sound_on else "Sound off"


func _load_sound_enabled() -> bool:
	var cfg := ConfigFile.new()
	if cfg.load(SETTINGS_PATH) != OK:
		return true
	return bool(cfg.get_value("audio", "enabled", true))


func _save_sound_enabled(enabled: bool) -> void:
	var cfg := ConfigFile.new()
	cfg.load(SETTINGS_PATH)
	cfg.set_value("audio", "enabled", enabled)
	cfg.save(SETTINGS_PATH)


func _load_briefing_seen() -> bool:
	var cfg := ConfigFile.new()
	if cfg.load(SETTINGS_PATH) != OK:
		return false
	return bool(cfg.get_value("briefing", "seen", false))


func _save_briefing_seen(seen: bool) -> void:
	var cfg := ConfigFile.new()
	cfg.load(SETTINGS_PATH)
	cfg.set_value("briefing", "seen", seen)
	cfg.save(SETTINGS_PATH)


func _load_wing_briefing_seen(plane_type: GameConfig.PlaneType) -> bool:
	var key: String = _WING_SETTINGS_KEYS.get(plane_type, "")
	if key.is_empty():
		return true
	var cfg := ConfigFile.new()
	if cfg.load(SETTINGS_PATH) != OK:
		return false
	return bool(cfg.get_value("wing_briefing", key, false))


func _save_wing_briefing_seen(plane_type: GameConfig.PlaneType, seen: bool) -> void:
	var key: String = _WING_SETTINGS_KEYS.get(plane_type, "")
	if key.is_empty():
		return
	var cfg := ConfigFile.new()
	cfg.load(SETTINGS_PATH)
	cfg.set_value("wing_briefing", key, seen)
	cfg.save(SETTINGS_PATH)
