extends CanvasLayer

## HUD: squadron count, keep HP, level, star ratings, win/lose overlays, sound toggle,
## and a one-shot warm mission briefing on first play.

const SETTINGS_PATH := "user://settings.cfg"
const _AUDIO_ON: Texture2D = preload("res://assets/ui/audio_on.png")
const _AUDIO_OFF: Texture2D = preload("res://assets/ui/audio_off.png")
const _STAR_FULL: Texture2D = preload("res://assets/ui/star.png")
const _STAR_EMPTY: Texture2D = preload("res://assets/ui/star_empty.png")

## Radio-chatter callouts when a new airframe or bastion defense comes online.
const _UNLOCK_TOASTS := {
	4: "BASTION UPGRADE: MISSILE BATTERIES\nHeads on a swivel, ace.",
	6: "NEW AIRFRAME: BOMBER WING\nOne big egg, right on the keep.",
	11: "NEW AIRFRAME: STRIKE WING\nFire and forget from way out.",
	13: "BASTION UPGRADE: FLAK GUNS\nThe sky just grew teeth.",
	16: "NEW AIRFRAME: CARPET WING\nThree eggs a pass. Flatten it.",
}

const _WING_HINTS := {
	GameConfig.PlaneType.GUNSHIP: "Tap the water, commander —\nsoft the guns, then the keep",
	GameConfig.PlaneType.BOMBER: "Tap the water, commander —\nscramble the bombers",
	GameConfig.PlaneType.STRIKE: "Tap the water, commander —\nloose the strike jets",
	GameConfig.PlaneType.CARPET: "Tap the water, commander —\none pass, three gifts",
}

var _main: Node2D
var _sound_on: bool = true
var _campaign_complete: bool = false
var _last_level: int = 0
var _toast_tween: Tween
var _briefing_open := false
var _briefing_tween: Tween
var _vig_pulse_tween: Tween
var _cue_label_tween: Tween
var _playtest := false

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
@onready var stars_row: HBoxContainer = $Root/Overlay/StarsRow
@onready var result_label: Label = $Root/Overlay/ResultLabel
@onready var restart_button: Button = $Root/Overlay/ActionRow/RestartButton
@onready var new_game_button: Button = $Root/Overlay/ActionRow/NewGameButton
@onready var version_label: Label = $Root/VersionLabel
@onready var briefing: Control = $Root/Briefing
@onready var briefing_vignette: ColorRect = $Root/Briefing/Vignette
@onready var tap_cue: Control = $Root/Briefing/TapCue
@onready var cue_label: Label = $Root/Briefing/CueLabel


func _ready() -> void:
	version_label.text = "v%s" % ProjectSettings.get_setting("application/config/version", "?")
	sound_button.pressed.connect(_on_sound_toggled)
	briefing.gui_input.connect(_on_briefing_gui_input)
	_playtest = OS.get_cmdline_user_args().has("--playtest")
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
	_on_squadron(GameConfig.squadron_for_level(1))
	_on_keep_hp(GameConfig.KEEP_MAX_HP, GameConfig.KEEP_MAX_HP)
	_on_level(1)
	_maybe_show_first_briefing()


func force_briefing() -> void:
	## Playtest / debug: show the briefing even if already seen.
	_show_briefing()


func is_briefing_open() -> bool:
	return _briefing_open


func _maybe_show_first_briefing() -> void:
	var args := OS.get_cmdline_user_args()
	if args.has("--briefing"):
		_show_briefing()
		return
	if _playtest:
		return
	if _load_briefing_seen():
		return
	_show_briefing()


func _show_briefing() -> void:
	if _briefing_open:
		return
	_briefing_open = true
	hint_label.visible = false
	briefing.visible = true
	briefing.mouse_filter = Control.MOUSE_FILTER_STOP
	briefing.modulate = Color(1, 1, 1, 1)
	tap_cue.modulate = Color(1, 1, 1, 0)
	cue_label.modulate = Color(1, 1, 1, 0)
	if briefing_vignette.material:
		briefing_vignette.material.set_shader_parameter("pulse", 0.0)

	if _briefing_tween and _briefing_tween.is_valid():
		_briefing_tween.kill()
	_briefing_tween = create_tween()
	_briefing_tween.set_parallel(true)
	_briefing_tween.tween_property(tap_cue, "modulate:a", 1.0, 0.5).set_delay(0.1)
	_briefing_tween.tween_property(cue_label, "modulate:a", 1.0, 0.5).set_delay(0.15)

	_start_briefing_ambiance()


func _start_briefing_ambiance() -> void:
	if _vig_pulse_tween and _vig_pulse_tween.is_valid():
		_vig_pulse_tween.kill()
	if briefing_vignette.material:
		_vig_pulse_tween = create_tween().set_loops()
		_vig_pulse_tween.tween_method(_set_vig_pulse, 0.15, 1.0, 1.4).set_trans(Tween.TRANS_SINE)
		_vig_pulse_tween.tween_method(_set_vig_pulse, 1.0, 0.15, 1.4).set_trans(Tween.TRANS_SINE)

	if _cue_label_tween and _cue_label_tween.is_valid():
		_cue_label_tween.kill()
	_cue_label_tween = create_tween().set_loops()
	_cue_label_tween.tween_property(cue_label, "modulate", Color(1, 0.93, 0.72, 1.0), 0.7)
	_cue_label_tween.tween_property(cue_label, "modulate", Color(1, 0.85, 0.45, 0.75), 0.7)


func _set_vig_pulse(v: float) -> void:
	# Briefing + lose overlay share the vignette material — one pulse drives both.
	if briefing_vignette and briefing_vignette.material:
		briefing_vignette.material.set_shader_parameter("pulse", v)


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
	_briefing_open = false
	briefing.mouse_filter = Control.MOUSE_FILTER_IGNORE
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
		hint_label.visible = true
	)
	if save_seen and not _playtest:
		_save_briefing_seen(true)


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
	if level != _last_level and _UNLOCK_TOASTS.has(level):
		_show_toast(_UNLOCK_TOASTS[level])
	_last_level = level


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
	_stop_overlay_ambiance()
	overlay.visible = true
	overlay_vignette.visible = false
	overlay_dim.visible = true
	overlay_dim.color = Color(0.05, 0.15, 0.08, 0.72)
	result_label.add_theme_color_override("font_color", Color(1, 1, 1, 1))
	result_label.add_theme_constant_override("outline_size", 0)
	_set_stars(stars)
	stars_row.visible = true
	new_game_button.visible = false
	if campaign_complete:
		result_label.text = "ARCHIPELAGO CLEARED.\nEvery bastion is smoke and glory."
		restart_button.text = "Run it back"
	else:
		result_label.text = "BASTION DOWN.\nNothing left but smoke and glory."
		restart_button.text = "Next bastion"
	_arm_action_buttons()


func _on_lost() -> void:
	_campaign_complete = false
	hint_label.visible = false
	if _briefing_open:
		_dismiss_briefing(true)
	overlay.visible = true
	overlay_vignette.visible = true
	overlay_dim.visible = false
	result_label.add_theme_color_override("font_color", Color(1, 0.93, 0.72, 0.95))
	result_label.add_theme_color_override("font_outline_color", Color(0.12, 0.06, 0.02, 0.85))
	result_label.add_theme_constant_override("outline_size", 5)
	stars_row.visible = false
	result_label.text = "Squadron's gone.\nUnacceptable, Commander."
	restart_button.text = "Try again"
	new_game_button.visible = true
	new_game_button.text = "Start over"
	_start_overlay_ambiance()
	_arm_action_buttons()


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


func _set_stars(stars: int) -> void:
	var filled := clampi(stars, 0, 3)
	for i in stars_row.get_child_count():
		var icon := stars_row.get_child(i) as TextureRect
		if icon == null:
			continue
		icon.texture = _STAR_FULL if i < filled else _STAR_EMPTY
		icon.modulate = Color(1, 1, 1, 1.0 if i < filled else 0.55)


func _on_restart() -> void:
	_stop_overlay_ambiance()
	overlay.visible = false
	stars_row.visible = false
	new_game_button.visible = false
	hint_label.visible = true
	if _main:
		_main.advance_or_restart()


func _on_new_game() -> void:
	_stop_overlay_ambiance()
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
