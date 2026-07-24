class_name Keep
extends Area2D

## Central stronghold. Destroy it to win the level.

signal destroyed
signal hp_changed(current: int, maximum: int)

var max_hp: int = GameConfig.KEEP_MAX_HP
var hp: int = GameConfig.KEEP_MAX_HP
var _dead: bool = false

@onready var visual: Node2D = $Visual
@onready var hp_bar: ProgressBar = $HpBar


func _ready() -> void:
	add_to_group("keep")
	collision_layer = 8
	collision_mask = 0
	hp = max_hp
	_update_hp_bar()
	hp_changed.emit(hp, max_hp)


func configure(hp_max: int) -> void:
	max_hp = hp_max
	hp = max_hp
	_dead = false
	visible = true
	set_process(true)
	_update_hp_bar()
	hp_changed.emit(hp, max_hp)


func reset() -> void:
	_dead = false
	hp = max_hp
	visible = true
	if visual:
		visual.modulate = Color.WHITE
	_update_hp_bar()
	hp_changed.emit(hp, max_hp)


func take_damage(amount: int) -> void:
	if _dead:
		return
	hp = max(hp - amount, 0)
	_update_hp_bar()
	hp_changed.emit(hp, max_hp)
	visual.modulate = Color(1.0, 0.45, 0.45)
	var tw := create_tween()
	tw.tween_property(visual, "modulate", Color.WHITE, 0.25)
	if hp <= 0:
		_dead = true
		destroyed.emit()
		visible = false


func _update_hp_bar() -> void:
	if hp_bar:
		hp_bar.max_value = max_hp
		hp_bar.value = hp
