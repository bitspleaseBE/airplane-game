extends Node

## Player settings and campaign progress, persisted to user://.
##
## Everything the options menu can change lives here, and so does the campaign
## save. Both share one ConfigFile so a single write settles the whole player
## state — the file is tiny and written on change, which is what a desktop
## player expects when they alt-F4 out of a game.
##
## Nothing here touches the display or the mixer while a playtest is running:
## the harness runs headless at a fixed resolution with audio off, and a
## fullscreen request or a bus volume tween would either fail or make the perf
## numbers depend on whatever the last human session chose.

signal audio_changed
signal video_changed
signal accessibility_changed
signal progress_changed

const SETTINGS_PATH := "user://settings.cfg"

## Bus indices must match default_bus_layout.tres.
const BUS_MASTER := 0
const BUS_SFX := 1
const BUS_MUSIC := 2
const BUS_AMBIENCE := 3

const BUS_NAMES := {
	BUS_SFX: "SFX",
	BUS_MUSIC: "Music",
	BUS_AMBIENCE: "Ambience",
}

## Below this a slider is treated as off — linear_to_db(0) is -inf, and a bus
## left at -80 dB still mixes.
const SILENCE_EPSILON := 0.001

enum ColorblindMode { OFF, DEUTERANOPIA, TRITANOPIA, HIGH_CONTRAST }

const COLORBLIND_NAMES := ["Off", "Deuteranopia", "Tritanopia", "High contrast"]

## Threat-overlay hue per mode. The whole tactical read is "is this water hot",
## carried by a warm wedge over cool sea — which is exactly the contrast a
## red-green deficiency loses. Each alternative keeps the *luminance* step as
## well as the hue step, so the wedge reads even in full greyscale.
const THREAT_COLORS := {
	ColorblindMode.OFF: Color(1.0, 0.33, 0.05),
	ColorblindMode.DEUTERANOPIA: Color(1.0, 0.78, 0.05),
	ColorblindMode.TRITANOPIA: Color(1.0, 0.24, 0.42),
	ColorblindMode.HIGH_CONTRAST: Color(1.0, 1.0, 1.0),
}

## Extra alpha multiplier per mode — high contrast trades subtlety for read.
const THREAT_ALPHA_SCALE := {
	ColorblindMode.OFF: 1.0,
	ColorblindMode.DEUTERANOPIA: 1.12,
	ColorblindMode.TRITANOPIA: 1.08,
	ColorblindMode.HIGH_CONTRAST: 1.45,
}

var master_volume: float = 0.8
var sfx_volume: float = 1.0
var music_volume: float = 0.7
var ambience_volume: float = 1.0
## Kept as its own flag rather than folded into master so muting and unmuting
## restores the level the player actually chose.
var muted: bool = false

var fullscreen: bool = false
var vsync: bool = true

var screen_shake: float = 1.0
var reduced_motion: bool = false
var colorblind_mode: ColorblindMode = ColorblindMode.OFF

## Highest bastion the player may start from. 1 until the first win.
var highest_unlocked: int = 1
## level -> best star count (1-3). Missing key means never cleared.
var level_stars: Dictionary = {}
var campaign_completed: bool = false

var _headless: bool = false
var _loaded: bool = false


func _ready() -> void:
	_headless = OS.get_cmdline_user_args().has("--playtest")
	load_all()
	if not _headless:
		apply_audio()
		apply_video()


## --- persistence ---------------------------------------------------------


func load_all() -> void:
	var cfg := ConfigFile.new()
	var err := cfg.load(SETTINGS_PATH)
	_loaded = true
	if err != OK:
		return

	# "audio/enabled" is the pre-mixer key the HUD sound button used to write.
	muted = not bool(cfg.get_value("audio", "enabled", true))
	master_volume = _clamp01(cfg.get_value("audio", "master", master_volume))
	sfx_volume = _clamp01(cfg.get_value("audio", "sfx", sfx_volume))
	music_volume = _clamp01(cfg.get_value("audio", "music", music_volume))
	ambience_volume = _clamp01(cfg.get_value("audio", "ambience", ambience_volume))

	fullscreen = bool(cfg.get_value("video", "fullscreen", fullscreen))
	vsync = bool(cfg.get_value("video", "vsync", vsync))

	screen_shake = _clamp01(cfg.get_value("access", "screen_shake", screen_shake))
	reduced_motion = bool(cfg.get_value("access", "reduced_motion", reduced_motion))
	colorblind_mode = _clamp_mode(cfg.get_value("access", "colorblind", colorblind_mode))

	highest_unlocked = clampi(
		int(cfg.get_value("progress", "highest_unlocked", 1)), 1, GameConfig.LEVEL_COUNT
	)
	campaign_completed = bool(cfg.get_value("progress", "campaign_completed", false))
	level_stars = _sanitize_stars(cfg.get_value("progress", "stars", {}))


func save_all() -> void:
	if _headless:
		return
	var cfg := ConfigFile.new()
	# Load first: the HUD still owns the briefing-seen sections and we must not
	# drop them on a settings write.
	cfg.load(SETTINGS_PATH)

	cfg.set_value("audio", "enabled", not muted)
	cfg.set_value("audio", "master", master_volume)
	cfg.set_value("audio", "sfx", sfx_volume)
	cfg.set_value("audio", "music", music_volume)
	cfg.set_value("audio", "ambience", ambience_volume)

	cfg.set_value("video", "fullscreen", fullscreen)
	cfg.set_value("video", "vsync", vsync)

	cfg.set_value("access", "screen_shake", screen_shake)
	cfg.set_value("access", "reduced_motion", reduced_motion)
	cfg.set_value("access", "colorblind", int(colorblind_mode))

	cfg.set_value("progress", "highest_unlocked", highest_unlocked)
	cfg.set_value("progress", "campaign_completed", campaign_completed)
	cfg.set_value("progress", "stars", level_stars)

	cfg.save(SETTINGS_PATH)


## --- audio ---------------------------------------------------------------


func set_master_volume(v: float) -> void:
	master_volume = _clamp01(v)
	_after_audio_change()


func set_sfx_volume(v: float) -> void:
	sfx_volume = _clamp01(v)
	_after_audio_change()


func set_music_volume(v: float) -> void:
	music_volume = _clamp01(v)
	_after_audio_change()


func set_ambience_volume(v: float) -> void:
	ambience_volume = _clamp01(v)
	_after_audio_change()


func set_muted(on: bool) -> void:
	muted = on
	_after_audio_change()


func toggle_muted() -> void:
	set_muted(not muted)


func apply_audio() -> void:
	if _headless:
		return
	_apply_bus(BUS_MASTER, master_volume, muted)
	_apply_bus(BUS_SFX, sfx_volume, false)
	_apply_bus(BUS_MUSIC, music_volume, false)
	_apply_bus(BUS_AMBIENCE, ambience_volume, false)


func _apply_bus(index: int, linear: float, force_mute: bool) -> void:
	if index >= AudioServer.bus_count:
		return
	var silent := force_mute or linear <= SILENCE_EPSILON
	AudioServer.set_bus_mute(index, silent)
	if not silent:
		AudioServer.set_bus_volume_db(index, linear_to_db(linear))


func _after_audio_change() -> void:
	apply_audio()
	save_all()
	audio_changed.emit()


## --- video ---------------------------------------------------------------


func set_fullscreen(on: bool) -> void:
	fullscreen = on
	apply_video()
	save_all()
	video_changed.emit()


func toggle_fullscreen() -> void:
	set_fullscreen(not fullscreen)


func set_vsync(on: bool) -> void:
	vsync = on
	apply_video()
	save_all()
	video_changed.emit()


func apply_video() -> void:
	if _headless or not _can_manage_window():
		return
	# Borderless fullscreen rather than exclusive: alt-tabbing out of an
	# exclusive-mode GL window on Windows is where "the game froze" reports
	# come from, and this project has nothing to gain from exclusive.
	var want := (
		DisplayServer.WINDOW_MODE_FULLSCREEN if fullscreen else DisplayServer.WINDOW_MODE_WINDOWED
	)
	if DisplayServer.window_get_mode() != want:
		DisplayServer.window_set_mode(want)
	DisplayServer.window_set_vsync_mode(
		DisplayServer.VSYNC_ENABLED if vsync else DisplayServer.VSYNC_DISABLED
	)


## Only desktop owns its window. On the web a persisted fullscreen=true would
## call window_set_mode outside a user gesture, the browser would refuse it, and
## the game would run windowed while this class still believed it was fullscreen
## — so the options toggle needed two clicks to do anything. On Android and iOS
## the app is always fullscreen and this would ask for WINDOWED every launch.
## V-Sync is unimplemented on web and warn-prints on every call.
func _can_manage_window() -> bool:
	if DisplayServer.get_name() == "headless":
		return false
	return OS.has_feature("pc")


## True when the options menu should offer window controls at all.
func can_manage_window() -> bool:
	return _can_manage_window()


## --- accessibility -------------------------------------------------------


func set_screen_shake(v: float) -> void:
	screen_shake = _clamp01(v)
	save_all()
	accessibility_changed.emit()


func set_reduced_motion(on: bool) -> void:
	reduced_motion = on
	save_all()
	accessibility_changed.emit()


func set_colorblind_mode(mode: int) -> void:
	colorblind_mode = _clamp_mode(mode)
	save_all()
	accessibility_changed.emit()


func threat_color() -> Color:
	return THREAT_COLORS.get(colorblind_mode, THREAT_COLORS[ColorblindMode.OFF])


func threat_alpha_scale() -> float:
	return float(THREAT_ALPHA_SCALE.get(colorblind_mode, 1.0))


## --- progress ------------------------------------------------------------


func stars_for(level: int) -> int:
	return int(level_stars.get(level, 0))


func total_stars() -> int:
	var sum := 0
	for v in level_stars.values():
		sum += int(v)
	return sum


func cleared_count() -> int:
	return level_stars.size()


func is_unlocked(level: int) -> bool:
	return level <= highest_unlocked


## Records a win. Stars only ever improve, so a sloppy replay of a cleared
## bastion cannot cost the player the rating they already earned.
func record_win(level: int, stars: int) -> void:
	var n := clampi(level, 1, GameConfig.LEVEL_COUNT)
	var s := clampi(stars, 1, 3)
	if s > stars_for(n):
		level_stars[n] = s
	highest_unlocked = maxi(highest_unlocked, mini(n + 1, GameConfig.LEVEL_COUNT))
	if n >= GameConfig.LEVEL_COUNT:
		campaign_completed = true
	save_all()
	progress_changed.emit()


func reset_progress() -> void:
	highest_unlocked = 1
	level_stars = {}
	campaign_completed = false
	save_all()
	progress_changed.emit()


## --- helpers -------------------------------------------------------------


func _clamp01(v: Variant) -> float:
	return clampf(float(v), 0.0, 1.0)


func _clamp_mode(v: Variant) -> ColorblindMode:
	return clampi(int(v), 0, COLORBLIND_NAMES.size() - 1) as ColorblindMode


## Config values round-trip as untyped dictionaries; coerce so callers can
## trust int keys and 1-3 values.
func _sanitize_stars(raw: Variant) -> Dictionary:
	var out := {}
	if raw is not Dictionary:
		return out
	for k in (raw as Dictionary):
		var level := clampi(int(k), 1, GameConfig.LEVEL_COUNT)
		var stars := clampi(int((raw as Dictionary)[k]), 0, 3)
		if stars > 0:
			out[level] = stars
	return out
