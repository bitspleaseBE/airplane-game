extends CanvasLayer

## HUD: squadron count, keep HP, level, star ratings, win/lose overlays, sound toggle.

const SETTINGS_PATH := "user://settings.cfg"
const _SPEAKER_ON: Texture2D = preload("res://assets/ui/speaker_on.png")
const _SPEAKER_OFF: Texture2D = preload("res://assets/ui/speaker_off.png")

var _main: Node2D
var _sound_on: bool = true
var _campaign_complete: bool = false

@onready var squadron_label: Label = $Root/TopBar/SquadronLabel
@onready var keep_label: Label = $Root/TopBar/KeepLabel
@onready var keep_bar: ProgressBar = $Root/TopBar/KeepBar
@onready var sound_button: Button = $Root/TopBar/SoundButton
@onready var level_label: Label = $Root/LevelLabel
@onready var hint_label: Label = $Root/HintLabel
@onready var overlay: ColorRect = $Root/Overlay
@onready var stars_label: Label = $Root/Overlay/StarsLabel
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
	stars_label.visible = false
	_on_squadron(GameConfig.squadron_for_level(1))
	_on_keep_hp(GameConfig.KEEP_MAX_HP, GameConfig.KEEP_MAX_HP)
	_on_level(1)


func _on_squadron(remaining: int) -> void:
	squadron_label.text = "Planes: %d" % remaining


func _on_keep_hp(current: int, maximum: int) -> void:
	keep_label.text = "Keep"
	keep_bar.max_value = maximum
	keep_bar.value = current


func _on_level(level: int) -> void:
	level_label.text = "Bastion %d / %d" % [level, GameConfig.LEVEL_COUNT]


func _on_won(stars: int = 3, campaign_complete: bool = false) -> void:
	_campaign_complete = campaign_complete
	hint_label.visible = false
	overlay.visible = true
	overlay.color = Color(0.05, 0.15, 0.08, 0.72)
	stars_label.visible = true
	stars_label.text = _star_string(stars)
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
	stars_label.visible = false
	result_label.text = "Squadron's spent and that\nkeep's still smug. Unacceptable."
	restart_button.text = "Re-engage"


func _star_string(stars: int) -> String:
	var filled := clampi(stars, 0, 3)
	var s := ""
	for i in 3:
		s += "★" if i < filled else "☆"
	return s


func _on_restart() -> void:
	overlay.visible = false
	stars_label.visible = false
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
	sound_button.icon = _SPEAKER_ON if _sound_on else _SPEAKER_OFF
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
