extends CanvasLayer

## HUD: squadron count, keep HP, level, star ratings, win/lose overlays, sound toggle.

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
	GameConfig.PlaneType.GUNSHIP: "Tap the water, ace —\nsoft the guns, then the keep",
	GameConfig.PlaneType.BOMBER: "Tap the water, ace —\nscramble the bombers",
	GameConfig.PlaneType.STRIKE: "Tap the water, ace —\nloose the strike jets",
	GameConfig.PlaneType.CARPET: "Tap the water, ace —\none pass, three gifts",
}

var _main: Node2D
var _sound_on: bool = true
var _campaign_complete: bool = false
var _last_level: int = 0
var _toast_tween: Tween

@onready var squadron_label: Label = $Root/TopBar/SquadronRow/SquadronLabel
@onready var keep_bar: ProgressBar = $Root/TopBar/KeepBar
@onready var sound_button: Button = $Root/TopBar/SoundButton
@onready var level_label: Label = $Root/LevelLabel
@onready var wing_label: Label = $Root/WingLabel
@onready var toast_label: Label = $Root/ToastLabel
@onready var hint_label: Label = $Root/HintLabel
@onready var overlay: ColorRect = $Root/Overlay
@onready var stars_row: HBoxContainer = $Root/Overlay/StarsRow
@onready var result_label: Label = $Root/Overlay/ResultLabel
@onready var restart_button: Button = $Root/Overlay/RestartButton
@onready var version_label: Label = $Root/VersionLabel


func _ready() -> void:
	version_label.text = "v%s" % ProjectSettings.get_setting("application/config/version", "?")
	sound_button.pressed.connect(_on_sound_toggled)
	if OS.get_cmdline_user_args().has("--playtest"):
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
	overlay.visible = false
	stars_row.visible = false
	_on_squadron(GameConfig.squadron_for_level(1))
	_on_keep_hp(GameConfig.KEEP_MAX_HP, GameConfig.KEEP_MAX_HP)
	_on_level(1)


func _on_squadron(remaining: int) -> void:
	squadron_label.text = str(remaining)


func _on_keep_hp(current: int, maximum: int) -> void:
	keep_bar.max_value = maximum
	keep_bar.value = current


func _on_level(level: int) -> void:
	level_label.text = "Bastion %d / %d" % [level, GameConfig.LEVEL_COUNT]
	var wing_type: GameConfig.PlaneType = GameConfig.plane_type_for_level(level)
	wing_label.text = "%s WING" % GameConfig.plane_name_for_level(level)
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
	overlay.visible = true
	overlay.color = Color(0.05, 0.15, 0.08, 0.72)
	_set_stars(stars)
	stars_row.visible = true
	if campaign_complete:
		result_label.text = "ARCHIPELAGO CLEARED.\nEvery bastion is smoke and glory."
		restart_button.text = "Run it back"
	else:
		result_label.text = "BASTION DOWN.\nNothing left but smoke and glory."
		restart_button.text = "Next bastion"


func _on_lost() -> void:
	_campaign_complete = false
	hint_label.visible = false
	overlay.visible = true
	overlay.color = Color(0.15, 0.05, 0.05, 0.72)
	stars_row.visible = false
	result_label.text = "Squadron's spent and that\nkeep's still smug. Unacceptable."
	restart_button.text = "Re-engage"


func _set_stars(stars: int) -> void:
	var filled := clampi(stars, 0, 3)
	for i in stars_row.get_child_count():
		var icon := stars_row.get_child(i) as TextureRect
		if icon == null:
			continue
		icon.texture = _STAR_FULL if i < filled else _STAR_EMPTY
		icon.modulate = Color(1, 1, 1, 1.0 if i < filled else 0.55)


func _on_restart() -> void:
	overlay.visible = false
	stars_row.visible = false
	hint_label.visible = true
	if _main:
		_main.advance_or_restart()


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
