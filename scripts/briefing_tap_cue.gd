extends Control

## Concentric warm ripples + a pulsing plane — "tap here" without a flat arrow.

@export var ring_count := 3
@export var plane_tex: Texture2D

var _phase := 0.0
var _plane: TextureRect


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	if plane_tex:
		_plane = TextureRect.new()
		_plane.texture = plane_tex
		_plane.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		_plane.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		_plane.custom_minimum_size = Vector2(44, 44)
		_plane.size = Vector2(44, 44)
		_plane.pivot_offset = Vector2(22, 22)
		_plane.modulate = Color(1.0, 0.92, 0.7, 0.95)
		_plane.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(_plane)


func _process(delta: float) -> void:
	if not visible:
		return
	_phase += delta
	queue_redraw()
	if _plane:
		var bob := sin(_phase * 2.4) * 3.0
		var s := 1.0 + sin(_phase * 3.1) * 0.08
		_plane.position = size * 0.5 - _plane.size * 0.5 + Vector2(0.0, bob)
		_plane.scale = Vector2(s, s)
		_plane.rotation = sin(_phase * 1.3) * 0.12


func _draw() -> void:
	var c := size * 0.5
	for i in ring_count:
		var t := fposmod(_phase * 0.55 + float(i) / float(ring_count), 1.0)
		var r := lerpf(12.0, minf(size.x, size.y) * 0.4, t)
		var a := (1.0 - t) * (1.0 - t) * 0.65
		var col := Color(0.98, 0.86, 0.45, a)
		draw_arc(c, r, 0.0, TAU, 48, col, 2.5, true)
		draw_arc(c, r, 0.0, TAU, 48, Color(1.0, 0.95, 0.8, a * 0.3), 4.0, true)
	draw_circle(c + Vector2(0, 4), 16.0, Color(0.95, 0.7, 0.25, 0.14 + 0.05 * sin(_phase * 3.0)))
