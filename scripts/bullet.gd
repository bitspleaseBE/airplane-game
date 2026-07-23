class_name Bullet
extends Area2D

## Turret projectile. One hit downs a plane.

var velocity: Vector2 = Vector2.ZERO
var lifetime: float = 2.0


func setup(pos: Vector2, angle: float) -> void:
	global_position = pos
	rotation = angle
	velocity = Vector2.RIGHT.rotated(angle) * GameConfig.BULLET_SPEED


func _ready() -> void:
	add_to_group("bullets")
	collision_layer = 4
	collision_mask = 2  # planes
	area_entered.connect(_on_area_entered)


func _physics_process(delta: float) -> void:
	global_position += velocity * delta
	lifetime -= delta
	if lifetime <= 0.0:
		queue_free()
	# Despawn far from island
	if global_position.distance_to(GameConfig.ISLAND_CENTER) > 900.0:
		queue_free()


func _on_area_entered(area: Area2D) -> void:
	if area is PlaneUnit:
		area.take_hit()
		queue_free()
