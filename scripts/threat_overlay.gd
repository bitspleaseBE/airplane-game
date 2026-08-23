class_name ThreatOverlay
extends Node2D

## Draws where the bastion's living guns can shoot, and where they are looking
## right now.
##
## This adds no gameplay state of its own — it is a readout of the targeting
## that turret.gd and tower.gd already run. Without it the player taps blind:
## every stretch of water looks equally safe, so no deploy is better than any
## other and there is nothing to get good at. With it, "which water is the fort
## not covering" becomes a question you can answer at a glance.
##
## Three layers, coarse to urgent:
##   sector    — the slice a corner gun can ever traverse to. Static, so the
##               gaps between sectors read as fortress layout, and a silenced
##               gun leaves a visible permanent hole.
##   searching — dim wedge, the gun's current facing.
##   locked    — hot wedge plus a centreline: this gun has a bird and will fire.
##
## Everything is masked off the island itself. Deploys only ever land on water,
## so that is the only place the readout informs a decision — and painting the
## fort would bury the emplacement art the player also needs to read. Every gun
## uses the same warm threat colour: the question is "is this water hot", not
## "which calibre", and weapon type is already carried by the pad rings.

## Radial bands per wedge, and angular segments across it. Both are kept as low
## as the shoreline mask tolerates: this layer is large translucent geometry
## redrawn constantly, which is exactly the fill-rate the no-threads web build
## cannot afford. Cones are narrow enough to need fewer segments than sectors.
const WEDGE_BANDS := 4
const SECTOR_SEGMENTS := 10
const CONE_SEGMENTS := 6
## The readout is a soft haze over slow-moving barrels; refreshing it at 30 Hz
## under 60 Hz gameplay is imperceptible and halves the geometry it rebuilds.
const REDRAW_INTERVAL := 1.0 / 30.0
const RAY_STEPS := 8
## Matches the firing tolerance in Turret._process / Tower._process, so the
## wedge covers exactly the angles a gun will actually shoot into.
const CONE_HALF_ANGLE := 0.4
## Warm orange rather than pure red: a low-alpha red over this palette's teal
## water desaturates to grey and reads as cloud shadow instead of as danger.
## The colourblind modes in Settings replace it — this whole layer is a
## warm-over-cool read, which is exactly what a red-green deficiency loses, so
## the hue is a setting rather than a constant.
const THREAT_COLOR_DEFAULT := Color(1.0, 0.33, 0.05)
## Sectors stack wherever corner guns overlap, so each one has to stay light.
const SECTOR_ALPHA := 0.13
## Crisp boundaries are what make a sector read as a deliberate line of fire
## rather than as terrain shading — and the boundary is the thing the player is
## actually aiming to slip past.
const SECTOR_EDGE_ALPHA := 0.3
const SEARCH_ALPHA := 0.24
const LOCKED_ALPHA := 0.5
## Locked wedges breathe so a hot gun catches the eye in a busy frame.
const PULSE_RATE := 7.0
const PULSE_DEPTH := 0.06
## Where along a cone the haze peaks, as a fraction of the gun's reach.
const CONE_PEAK_T := 0.72
## Distance past the shoreline over which the mask fades in.
const SHORE_FEATHER := 46.0

var _main: Node2D
var _time: float = 0.0
var _island: Island
var _center: Vector2 = Vector2.ZERO
var _redraw_accum: float = 0.0
var _threat_color: Color = THREAT_COLOR_DEFAULT
var _alpha_scale: float = 1.0


func setup(main_ref: Node2D) -> void:
	_main = main_ref
	_refresh_palette()
	Settings.accessibility_changed.connect(_refresh_palette)


func _refresh_palette() -> void:
	_threat_color = Settings.threat_color()
	_alpha_scale = Settings.threat_alpha_scale()
	queue_redraw()


func _process(delta: float) -> void:
	_time += delta
	_redraw_accum += delta
	if _redraw_accum >= REDRAW_INTERVAL:
		_redraw_accum = 0.0
		queue_redraw()


func _draw() -> void:
	if _main == null or not _main.has_method("get_active_island"):
		return
	_island = _main.get_active_island()
	if _island == null or not _island.is_built():
		return
	# Hide the readout once the siege is decided — the result modal owns the
	# screen at that point and the wedges only add noise behind it.
	if "state" in _main and _main.state != _main.State.PLAYING:
		return
	_center = _island.get_center()
	var guns := _island.living_guns()
	# Sectors first, as a base wash; the live cones read on top of them.
	for gun in guns:
		var span: float = gun.threat_sector_span()
		if span > 0.0:
			var mid: float = gun.threat_sector_center()
			_draw_wedge(gun, mid, span * 0.5, SECTOR_ALPHA, false, SECTOR_SEGMENTS)
			_draw_ray(gun, mid - span * 0.5, SECTOR_EDGE_ALPHA, 2.0)
			_draw_ray(gun, mid + span * 0.5, SECTOR_EDGE_ALPHA, 2.0)
	for gun in guns:
		var locked: bool = gun.threat_locked()
		var alpha := SEARCH_ALPHA
		if locked:
			alpha = LOCKED_ALPHA + sin(_time * PULSE_RATE) * PULSE_DEPTH
		_draw_wedge(gun, gun.threat_aim(), CONE_HALF_ANGLE, alpha, true, CONE_SEGMENTS)
		if locked:
			_draw_centreline(gun)


## One wedge, drawn as concentric bands so alpha can follow both a radial
## profile and the shoreline mask.
func _draw_wedge(
	gun: Node2D, aim: float, half_angle: float, peak: float, coned: bool, segments: int
) -> void:
	var origin: Vector2 = gun.global_position - global_position
	var reach: float = gun.threat_range()
	var ring_pts: Array = []
	var ring_cols: Array = []
	for band in WEDGE_BANDS + 1:
		var t := float(band) / float(WEDGE_BANDS)
		var radial := _radial_profile(t, coned)
		var pts := PackedVector2Array()
		var cols := PackedColorArray()
		for seg in segments + 1:
			var a := aim - half_angle + half_angle * 2.0 * float(seg) / float(segments)
			var p := origin + Vector2.from_angle(a) * reach * t
			pts.append(p)
			var alpha: float = minf(peak * radial * _water_mask(p) * _alpha_scale, 1.0)
			cols.append(Color(_threat_color.r, _threat_color.g, _threat_color.b, alpha))
		ring_pts.append(pts)
		ring_cols.append(cols)

	for band in WEDGE_BANDS:
		var inner: PackedVector2Array = ring_pts[band]
		var outer: PackedVector2Array = ring_pts[band + 1]
		var inner_c: PackedColorArray = ring_cols[band]
		var outer_c: PackedColorArray = ring_cols[band + 1]
		var poly := PackedVector2Array()
		var cols := PackedColorArray()
		for i in inner.size():
			poly.append(inner[i])
			cols.append(inner_c[i])
		for i in range(outer.size() - 1, -1, -1):
			poly.append(outer[i])
			cols.append(outer_c[i])
		draw_polygon(poly, cols)


## Full strength across the useful span, easing off only at the edge of reach.
## The shoreline mask already does the shaping, and it has to: on the late
## stronghold islands the coast sits most of the way out to a gun's maximum
## range, so any falloff tied to range instead of to the water leaves the ring
## the player actually taps into almost unmarked.
func _radial_profile(t: float, coned: bool) -> float:
	var hold := CONE_PEAK_T if coned else 0.82
	if t <= hold:
		return 1.0
	return 1.0 - (t - hold) / (1.0 - hold)


## 0 over the island, ramping to 1 across the surf line — deploys only land on
## water, so that is the only place the readout has anything to say.
func _water_mask(local_point: Vector2) -> float:
	var world := local_point + global_position
	var offset := world - _center
	var shore: float = _island.get_shore_radius(offset.angle())
	return clampf((offset.length() - shore) / SHORE_FEATHER, 0.0, 1.0)


func _draw_centreline(gun: Node2D) -> void:
	_draw_ray(gun, gun.threat_aim(), 0.45, 2.0)


## A line out from a gun, segmented so it can be masked off the island and fade
## out at the limit of reach.
func _draw_ray(gun: Node2D, angle: float, alpha: float, width: float) -> void:
	var origin: Vector2 = gun.global_position - global_position
	var reach: float = gun.threat_range()
	var dir := Vector2.from_angle(angle)
	var steps := RAY_STEPS
	for i in steps:
		var t0 := float(i) / float(steps)
		var t1 := float(i + 1) / float(steps)
		var p0 := origin + dir * reach * t0
		var a := minf(alpha * _water_mask(p0) * (1.0 - t0 * t0) * _alpha_scale, 1.0)
		if a <= 0.012:
			continue
		# Boundary lines sit a shade brighter than the wash they edge, whatever
		# palette is active — that contrast is what makes them read as a line.
		var edge := _threat_color.lightened(0.25)
		edge.a = a
		draw_line(p0, origin + dir * reach * t1, edge, width)
