class_name ThrownSpear
extends WorldPickup
## A thrown spear: flies point-first, damages the first creature it hits, then lies on the ground
## as a normal pickup (GDD §10 "suliță aruncată"). Arrows reuse it with their own damage, speed and break chance.

const BASE_DAMAGE := 48.0
const WEAR := 8

var thrower: Node3D
var flying := true
var base_damage := BASE_DAMAGE
## Impact speed at which base_damage applies in full (damage scales 0.4x..1.2x with speed).
var ref_speed := 22.0
var wear := WEAR
## Chance the projectile is destroyed on landing (arrows snap; spears only wear).
var break_chance := 0.0


func launch(p_stack: ItemStack, from: Vector3, vel: Vector3, by: Node3D) -> void:
	setup(p_stack)
	thrower = by
	collision_mask = 1 | Animal.LAYER_CREATURE
	contact_monitor = true
	max_contacts_reported = 2
	lock_rotation = true
	body_entered.connect(_on_body_entered)
	global_position = from
	linear_velocity = vel
	_orient()


func _physics_process(_delta: float) -> void:
	if flying:
		_orient()
		if linear_velocity.length() < 1.0 and get_contact_count() > 0:
			_land()


func _orient() -> void:
	if linear_velocity.length() > 0.5:
		global_transform.basis = Basis.looking_at(-linear_velocity.normalized())


func _on_body_entered(body: Node) -> void:
	if not flying or body == thrower:
		return
	if body is HumanNPC and not (body as HumanNPC).is_dead():
		(body as HumanNPC).take_damage(base_damage * clampf(linear_velocity.length() / ref_speed, 0.4, 1.2), thrower, global_position)
		linear_velocity *= 0.1
	elif body is Animal and not (body as Animal).is_dead():
		var speed := linear_velocity.length()
		(body as Animal).take_damage(base_damage * clampf(speed / ref_speed, 0.4, 1.2), thrower, global_position)
		Sfx.play(&"chop", global_position, -4.0)
		linear_velocity *= 0.1
	_land()


func _land() -> void:
	flying = false
	lock_rotation = false
	if break_chance > 0.0 and randf() < break_chance:
		queue_free()
		return
	if stack.durability > 0:
		stack.durability -= wear
		if stack.durability <= 0:
			Events.toast(Loc.t("MSG_TOOL_BROKE", {"item": stack.get_data().display_name()}), &"danger")
			queue_free()
