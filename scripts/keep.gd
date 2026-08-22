class_name Keep
extends Area2D

## Central stronghold. Destroy it to win the level.

signal destroyed
signal hp_changed(current: int, maximum: int)

var max_hp: int = GameConfig.KEEP_MAX_HP
var hp: int = GameConfig.KEEP_MAX_HP
var _dead: bool = false

## Base collision radius from keep.tscn, kept so scaling stays idempotent
## across level activations and retries.
const BASE_BODY_RADIUS := 72.0
## Where the HP bar sits above an unscaled fort.
const BASE_BAR_TOP := -108.0
const BASE_BAR_HEIGHT := 16.0

@onready var visual: Node2D = $Visual
@onready var hp_bar: ProgressBar = $HpBar
@onready var body: CollisionShape2D = $CollisionShape2D


func _ready() -> void:
	add_to_group("keep")
	collision_layer = 8
	collision_mask = 0
	hp = max_hp
	_update_hp_bar()
	hp_changed.emit(hp, max_hp)


## Grows the fortress with its island. The sprite and the hitbox scale together
## so bombing a big fort is neither easier nor harder than bombing a small one
## relative to its silhouette; the HP bar deliberately does not scale, it only
## moves clear, so it stays the same readable size on every bastion.
func configure_scale(fort_scale: float) -> void:
	var f := maxf(fort_scale, 0.01)
	if visual:
		visual.scale = Vector2.ONE * f
	if body:
		# Duplicate first: the shape resource is shared by every instance of the
		# scene, so writing radius in place would resize every other keep too.
		var circle := body.shape.duplicate() as CircleShape2D
		if circle:
			circle.radius = BASE_BODY_RADIUS * f
			body.shape = circle
	if hp_bar:
		hp_bar.offset_top = BASE_BAR_TOP * f
		hp_bar.offset_bottom = BASE_BAR_TOP * f + BASE_BAR_HEIGHT


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
