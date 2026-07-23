extends CanvasLayer

## HUD: squadron count, keep HP, win/lose overlays.

var _main: Node2D

@onready var squadron_label: Label = $Root/TopBar/SquadronLabel
@onready var keep_label: Label = $Root/TopBar/KeepLabel
@onready var keep_bar: ProgressBar = $Root/TopBar/KeepBar
@onready var hint_label: Label = $Root/HintLabel
@onready var overlay: ColorRect = $Root/Overlay
@onready var result_label: Label = $Root/Overlay/ResultLabel
@onready var restart_button: Button = $Root/Overlay/RestartButton


func setup(main_ref: Node2D) -> void:
	_main = main_ref
	_main.squadron_changed.connect(_on_squadron)
	_main.keep_hp_changed.connect(_on_keep_hp)
	_main.game_won.connect(_on_won)
	_main.game_lost.connect(_on_lost)
	restart_button.pressed.connect(_on_restart)
	overlay.visible = false
	_on_squadron(GameConfig.SQUADRON_SIZE)
	_on_keep_hp(GameConfig.KEEP_MAX_HP, GameConfig.KEEP_MAX_HP)


func _on_squadron(remaining: int) -> void:
	squadron_label.text = "Planes: %d" % remaining


func _on_keep_hp(current: int, maximum: int) -> void:
	keep_label.text = "Keep"
	keep_bar.max_value = maximum
	keep_bar.value = current


func _on_won() -> void:
	hint_label.visible = false
	overlay.visible = true
	overlay.color = Color(0.05, 0.15, 0.08, 0.72)
	result_label.text = "Bastion down.\nStronghold conquered."
	restart_button.text = "Fly again"


func _on_lost() -> void:
	hint_label.visible = false
	overlay.visible = true
	overlay.color = Color(0.15, 0.05, 0.05, 0.72)
	result_label.text = "Keep still standing.\nSquadron spent."
	restart_button.text = "Try again"


func _on_restart() -> void:
	if _main:
		_main.restart()
