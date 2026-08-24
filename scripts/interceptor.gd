class_name Interceptor
extends Area2D

## The stronghold's own fighter — the only defender in the game that can move.
##
## Everything else the fort has is bolted down. A corner mount slews its sector
## but never leaves its corner, which is exactly why a fixed attack bearing
## survived every attempt to tune it out: against static guns, coming in the
## same way twice costs about what coming in differently costs. An interceptor
## changes that by going where the pressure is. Keep hitting one lane and they
## settle over it; switch lanes and they have to fly across the island first,
## and that transit is the window the player is buying.
##
## Deliberately slower than every attacking wing. It is a threat you out-manoeuvre,
## not one you out-run — if it could chase a bomber down from behind, moving the
## attack would stop being an answer and this would just be more damage.

signal destroyed(pos: Vector2)

var hp: int = GameConfig.INTERCEPTOR_HP

var _main: Node2D
var _keep_center: Vector2 = GameConfig.ISLAND_CENTER
var _fire_cooldown: float = 0.0
var _locked: PlaneUnit = null
var _lock_timer: float = 0.0
var _dead: bool = false
var _bullet_scene: PackedScene = preload("res://scenes/bullet.tscn")

@onready var sprite: Sprite2D = $Sprite


func setup(spawn_pos: Vector2, keep_center: Vector2, main_ref: Node2D) -> void:
	global_position = spawn_pos
	_keep_center = keep_center
	_main = main_ref
	hp = GameConfig.INTERCEPTOR_HP


func _ready() -> void:
	add_to_group("interceptors")
	# Layer 4 (defenses) so attacking fire can find it; it is not on the bullet
	# layer, so it never eats a shot meant for the fort.
	collision_layer = 8
	collision_mask = 0
	z_index = 9
	if sprite:
		sprite.modulate = GameConfig.INTERCEPTOR_TINT
	_launch_flourish()


## Rises out of the keep rather than popping into existence, so the player can
## see where the thing came from the first time it happens to them.
func _launch_flourish() -> void:
	scale = Vector2.ONE * 0.4
	modulate.a = 0.0
	var tw := create_tween()
	tw.tween_property(self, "scale", Vector2.ONE, 0.3).set_trans(Tween.TRANS_BACK).set_ease(
		Tween.EASE_OUT
	)
	tw.parallel().tween_property(self, "modulate:a", 1.0, 0.25)


func _physics_process(delta: float) -> void:
	if _dead or _main == null:
		return
	if "state" in _main and _main.state != _main.State.PLAYING:
		return

	_fire_cooldown = maxf(_fire_cooldown - delta, 0.0)
	_lock_timer = maxf(_lock_timer - delta, 0.0)

	var target := _acquire_target()
	var goal := _station_point(target)
	var to_goal := goal - global_position
	if to_goal.length() > 6.0:
		var dir := to_goal.normalized()
		global_position += dir * GameConfig.INTERCEPTOR_SPEED * delta
		rotation = dir.angle()

	if target == null or _fire_cooldown > 0.0:
		return
	var to_target: Vector2 = target.global_position - global_position
	if to_target.length() <= GameConfig.INTERCEPTOR_ENGAGE_RANGE:
		_fire(to_target.angle())
		_fire_cooldown = GameConfig.INTERCEPTOR_FIRE_COOLDOWN


## Where to sit. With a target, close to just inside engagement range rather
## than ramming it — an interceptor that flies onto the bird it is shooting at
## reads as a collision and denies the player the moment where they see the
## threat and route around it. With nothing to chase, drift back over the keep.
func _station_point(target: PlaneUnit) -> Vector2:
	if target == null:
		var home := _keep_center - global_position
		if home.length() < GameConfig.INTERCEPTOR_PATROL_RADIUS * 0.5:
			return global_position
		return _keep_center
	var offset: Vector2 = target.global_position - _keep_center
	var hold: Vector2 = target.global_position
	if offset.length() > GameConfig.INTERCEPTOR_PATROL_RADIUS:
		# Do not chase a bird out to sea; hold the edge of the patrol ring on
		# that bearing and let it come to you.
		hold = _keep_center + offset.normalized() * GameConfig.INTERCEPTOR_PATROL_RADIUS
	return hold


func _acquire_target() -> PlaneUnit:
	if _lock_timer > 0.0 and _is_engageable(_locked):
		return _locked
	_locked = _nearest_plane()
	_lock_timer = GameConfig.INTERCEPTOR_LOCK_TIME if _locked != null else 0.0
	return _locked


func _is_engageable(plane: PlaneUnit) -> bool:
	if plane == null or not is_instance_valid(plane) or plane.is_queued_for_deletion():
		return false
	return plane.phase == PlaneUnit.Phase.FLYING


## Same lure rule as every other defender — a decoy reads closer than it is, so
## the feint layer pulls interceptors off a lane exactly like it pulls a mount.
func _nearest_plane() -> PlaneUnit:
	if _main == null or not _main.has_method("get_planes"):
		return null
	var best: PlaneUnit = null
	var best_score := INF
	for child in _main.get_planes():
		if child is PlaneUnit and child.phase == PlaneUnit.Phase.FLYING:
			var d: float = global_position.distance_to(child.global_position)
			var score: float = d * GameConfig.DECOY_LURE_BIAS if child.is_decoy else d
			if score >= best_score:
				continue
			best_score = score
			best = child
	return best


func _fire(aim_angle: float) -> void:
	if _main == null or not _main.has_method("register_bullet"):
		return
	var bullet: Bullet = _bullet_scene.instantiate()
	_main.register_bullet(bullet)
	bullet.setup(global_position + Vector2.RIGHT.rotated(aim_angle) * 20.0, aim_angle)


## Shot down by gunship fire or caught in a blast, same as any emplacement.
func take_damage(amount: int) -> void:
	if _dead:
		return
	hp -= amount
	if sprite:
		sprite.modulate = Color(1.4, 1.0, 1.0)
		var tw := create_tween()
		tw.tween_property(sprite, "modulate", GameConfig.INTERCEPTOR_TINT, 0.2)
	if hp <= 0:
		_dead = true
		destroyed.emit(global_position)
		queue_free()


func is_alive() -> bool:
	return not _dead and not is_queued_for_deletion()
