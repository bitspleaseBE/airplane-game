class_name DeployReticle
extends Node2D

## Aiming reticle for keyboard and gamepad play.
##
## Touch and mouse both point at the water directly, so on those devices the
## reticle stays hidden and out of the way. A stick or WASD has no pointer of
## its own, so it gets one: a crosshair the player walks around the ocean,
## coloured for whether a scramble would be accepted there. That colour is the
## whole reason this exists — without a pointer the player cannot tell that the
## island itself is not deployable until a press silently does nothing.

## Sized in world units under a 0.6–0.8 camera zoom, so it has to be generous
## on paper to stay findable on screen.
const RING_RADIUS := 21.0
const RING_WIDTH := 3.0
const TICK_LEN := 11.0
const OK_COLOR := Color(0.62, 0.95, 0.78)
const BLOCKED_COLOR := Color(1.0, 0.42, 0.36)
const PULSE_RATE := 3.4

var deployable: bool = true
var ready_fraction: float = 1.0

var _time: float = 0.0


func _ready() -> void:
	visible = false
	z_index = 20


func _process(delta: float) -> void:
	if not visible:
		return
	_time += delta
	queue_redraw()


func _draw() -> void:
	var base := OK_COLOR if deployable else BLOCKED_COLOR
	var pulse := 0.88 + sin(_time * PULSE_RATE) * 0.12
	var col := Color(base.r, base.g, base.b, pulse)

	draw_arc(Vector2.ZERO, RING_RADIUS, 0.0, TAU, 28, Color(0, 0, 0, 0.35), RING_WIDTH + 2.0)
	draw_arc(Vector2.ZERO, RING_RADIUS, 0.0, TAU, 28, col, RING_WIDTH)
	for i in 4:
		var dir := Vector2.from_angle(TAU * float(i) / 4.0)
		draw_line(dir * (RING_RADIUS + 3.0), dir * (RING_RADIUS + 3.0 + TICK_LEN), col, RING_WIDTH)

	# Scramble-gap arc: the deploy clock is the only resource in the game, so a
	# controller player needs to see it at the point of aim rather than infer it.
	if ready_fraction < 1.0:
		var sweep := TAU * clampf(ready_fraction, 0.0, 1.0)
		draw_arc(
			Vector2.ZERO,
			RING_RADIUS - 6.0,
			-PI * 0.5,
			-PI * 0.5 + sweep,
			24,
			Color(1.0, 0.92, 0.6, 0.75),
			2.0
		)
