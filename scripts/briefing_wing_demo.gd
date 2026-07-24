extends Control

## Looping fly-by for wing-unlock briefings: tinted bird crosses the frame and
## fires / drops matching the airframe.

const PASS_DURATION := 2.6

@export var plane_tex: Texture2D

var _type: GameConfig.PlaneType = GameConfig.PlaneType.BOMBER
var _tint := Color.WHITE
var _active := false
var _phase := 0.0
var _plane: TextureRect
var _fired_this_pass := false
## [{kind:String, age:float, pos:Vector2, vel:Vector2, life:float}, ...]
var _fx: Array = []


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	clip_contents = true
	if plane_tex:
		_plane = TextureRect.new()
		_plane.texture = plane_tex
		_plane.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		_plane.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		_plane.custom_minimum_size = Vector2(56, 56)
		_plane.size = Vector2(56, 56)
		_plane.pivot_offset = Vector2(28, 28)
		_plane.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(_plane)
	visible = false


func setup(plane_type: GameConfig.PlaneType) -> void:
	_type = plane_type
	_tint = GameConfig.PLANE_TYPE_TINTS.get(plane_type, Color.WHITE)
	_phase = 0.0
	_fired_this_pass = false
	_fx.clear()
	_active = true
	visible = true
	if _plane:
		_plane.modulate = Color(_tint.r, _tint.g, _tint.b, 0.95)
		var sc: Vector2 = GameConfig.PLANE_TYPE_SPRITE_SCALES.get(plane_type, Vector2.ONE)
		_plane.scale = sc * 1.15


func stop() -> void:
	_active = false
	visible = false
	_fx.clear()
	if _plane:
		_plane.visible = false


func _process(delta: float) -> void:
	if not _active or not visible:
		return
	_phase += delta
	var cycle := fposmod(_phase, PASS_DURATION)
	var t := cycle / PASS_DURATION
	if t < 0.04:
		_fired_this_pass = false

	var y_mid := size.y * 0.42
	var x := lerpf(-70.0, size.x + 70.0, t)
	var y := y_mid + sin(t * TAU * 1.2) * 10.0
	var nose := Vector2(1.0, sin(t * TAU * 1.2) * 0.15).normalized()

	if _plane:
		_plane.visible = true
		_plane.position = Vector2(x, y) - _plane.size * 0.5
		_plane.rotation = nose.angle()

	# Attack beat mid-pass.
	if not _fired_this_pass and t >= 0.42 and t <= 0.52:
		_fired_this_pass = true
		_spawn_attack(Vector2(x, y), nose)

	_age_fx(delta)
	queue_redraw()


func _spawn_attack(origin: Vector2, nose: Vector2) -> void:
	match _type:
		GameConfig.PlaneType.BOMBER:
			_fx.append({
				"kind": "bomb",
				"age": 0.0,
				"pos": origin + Vector2(0, 8),
				"vel": Vector2(35.0, 210.0),
				"life": 0.42,
				"boom": true,
			})
		GameConfig.PlaneType.STRIKE:
			_fx.append({
				"kind": "missile",
				"age": 0.0,
				"pos": origin + nose * 18.0,
				"vel": nose * 420.0,
				"life": 0.7,
			})
		GameConfig.PlaneType.CARPET:
			for i in 3:
				_fx.append({
					"kind": "bomb",
					"age": -0.12 * float(i),
					"pos": origin + Vector2(-12.0 * float(i), 8.0 + 6.0 * float(i)),
					"vel": Vector2(30.0, 190.0),
					"life": 0.4,
					"boom": true,
				})
		_:
			for i in 3:
				_fx.append({
					"kind": "flash",
					"age": -0.05 * float(i),
					"pos": origin + nose * (22.0 + 14.0 * float(i)),
					"vel": Vector2.ZERO,
					"life": 0.2,
				})


func _age_fx(delta: float) -> void:
	var alive: Array = []
	for fx in _fx:
		fx["age"] = float(fx["age"]) + delta
		if float(fx["age"]) < 0.0:
			alive.append(fx)
			continue
		fx["pos"] = fx["pos"] + fx["vel"] * delta
		var life: float = float(fx["life"])
		if float(fx["age"]) < life:
			alive.append(fx)
		elif bool(fx.get("boom", false)):
			# Bomb hit the dirt — spawn a ground blast after the fall.
			alive.append({
				"kind": "boom",
				"age": 0.0,
				"pos": fx["pos"],
				"vel": Vector2.ZERO,
				"life": 0.45,
			})
	_fx = alive


func _draw() -> void:
	for fx in _fx:
		var age: float = float(fx["age"])
		if age < 0.0:
			continue
		var life: float = maxf(float(fx["life"]), 0.001)
		var u := clampf(age / life, 0.0, 1.0)
		var a := (1.0 - u) * (1.0 - u)
		var pos: Vector2 = fx["pos"]
		match String(fx["kind"]):
			"bomb":
				var r := lerpf(5.5, 3.5, u)
				draw_circle(pos, r + 1.5, Color(0.1, 0.08, 0.05, a * 0.55))
				draw_circle(pos, r, Color(0.28, 0.24, 0.18, a))
			"boom":
				var br := lerpf(10.0, 38.0, u)
				draw_circle(pos, br, Color(1.0, 0.55, 0.18, a * 0.7))
				draw_circle(pos, br * 0.55, Color(1.0, 0.9, 0.45, a * 0.85))
				draw_circle(pos, br * 0.22, Color(1.0, 1.0, 0.95, a))
			"puff":
				var pr := lerpf(6.0, 22.0, u)
				draw_circle(pos, pr, Color(1.0, 0.75, 0.35, a * 0.55))
				draw_circle(pos, pr * 0.55, Color(1.0, 0.9, 0.6, a * 0.35))
			"missile":
				var tip: Vector2 = pos
				var tail: Vector2 = pos - fx["vel"].normalized() * lerpf(28.0, 10.0, u)
				draw_line(tail, tip, Color(0.75, 0.88, 1.0, a), 3.0, true)
				draw_circle(tip, 3.5, Color(1.0, 0.95, 0.85, a))
			"flash":
				draw_circle(pos, lerpf(7.0, 2.0, u), Color(1.0, 0.92, 0.45, a * 0.9))
