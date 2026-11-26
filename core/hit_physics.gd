class_name HitPhysics
extends RefCounted
## The weight of blows, after Far Cry Primal: a club knocks a wolf back and staggers it, a spear thrown into a deer
## shoves it, a mammoth barely notices either. Momentum (N·s) from the weapon is divided by the body's mass into a
## push velocity that the body then brakes on its feet (living) or slides off (a carcass, which also slides down
## slopes too steep to hold it and settles along the ground instead of standing level on a hillside).

## Body mass (kg) per species: what a blow has to move.
const SPECIES_MASS := {
	&"deer": 90.0, &"megaloceros": 500.0, &"wolf": 40.0, &"lion": 190.0, &"smilodon": 280.0, &"bear": 350.0,
	&"rhino": 2000.0, &"bison": 800.0, &"mammoth": 6000.0,
}
const HUMAN_MASS := 75.0
## Gameplay gain on real momentum (a swung arm also puts the body behind the blow).
const GAIN := 1.6
const MAX_PUSH := 7.0          # m/s, no blow throws a body faster than this
const STAGGER_PUSH := 1.2      # m/s of push from which a living body staggers
const FEET_BRAKE := 9.0        # m/s² a living body stops a shove with
const CORPSE_BRAKE := 3.2      # m/s² a carcass slides to a stop with (hide on grass)
const CORPSE_FRICTION := 0.62  # tan of the steepest slope a carcass stays on (~32°)


static func species_mass(species: StringName) -> float:
	return float(SPECIES_MASS.get(species, 120.0))


## Momentum of a melee blow (N·s): the weapon plus the forearm (~2.5 kg) at the head's speed; blunt weapons pass it
## all on, blades and points spend part of it cutting in.
static func melee_impulse(weapon: ItemData, heavy: bool) -> float:
	var mass := 2.5 + (weapon.weight if weapon else 0.0)
	var speed := 12.0 if weapon else 8.0
	var transfer := 1.0
	if weapon:
		if weapon.has_tag(&"blunt"):
			transfer = 1.0
		elif weapon.has_tag(&"tool_axe"):
			transfer = 0.75
		elif weapon.has_tag(&"spear") or weapon.has_tag(&"tool_fishing"):
			transfer = 0.6
		elif weapon.has_tag(&"tool_knife") or weapon.has_tag(&"tool_sickle"):
			transfer = 0.3
	return mass * speed * transfer * GAIN * (1.7 if heavy else 1.0)


## Momentum a projectile hands over when it strikes (most of it: it sticks in).
static func projectile_impulse(mass: float, speed: float) -> float:
	return mass * speed * 2.5


## Push velocity (horizontal, m/s) a body of `body_mass` gets from momentum `j` along `dir`.
static func push_velocity(j: float, dir: Vector3, body_mass: float) -> Vector3:
	var d := Vector3(dir.x, 0.0, dir.z)
	if d.length() < 0.01:
		return Vector3.ZERO
	return d.normalized() * minf(j / maxf(body_mass, 1.0), MAX_PUSH)


## Brakes a push velocity by `brake` m/s² over `delta`.
static func brake(v: Vector3, brake_acc: float, delta: float) -> Vector3:
	var s := v.length()
	if s <= brake_acc * delta:
		return Vector3.ZERO
	return v * ((s - brake_acc * delta) / s)


## Ground normal under (x, z) from the terrain heights.
static func ground_normal(world: ForestWorld, x: float, z: float) -> Vector3:
	var e := 0.6
	var dx := world.height_at(x + e, z) - world.height_at(x - e, z)
	var dz := world.height_at(x, z + e) - world.height_at(x, z - e)
	return Vector3(-dx, 2.0 * e, -dz).normalized()


## Carcass on a slope: slides downhill when the slope is steeper than its friction holds (gravity along the slope
## less friction), otherwise its own slide brakes to a stop. Returns the new slide velocity.
static func corpse_slide(v: Vector3, n: Vector3, delta: float) -> Vector3:
	var g := 9.8
	var down := Vector3(n.x, 0.0, n.z)  # horizontal downhill direction (the normal leans downhill)
	var tan_slope := down.length() / maxf(n.y, 0.05)
	if tan_slope > CORPSE_FRICTION and down.length() > 0.001:
		var sin_a := down.length()
		var cos_a := n.y
		var acc := g * (sin_a - CORPSE_FRICTION * cos_a)
		return (v + down.normalized() * acc * delta).limit_length(6.0)
	return brake(v, CORPSE_BRAKE, delta)


## Tilts a body's model to lie along the ground (`amount` 1 = fully along the normal; living animals take part of
## it so they lean into slopes without leaving their feet).
static func align_to_ground(model: Node3D, body: Node3D, n: Vector3, amount: float, delta: float) -> void:
	var local_n := (body.global_transform.basis.inverse() * n).normalized()
	var target_up := Vector3.UP.lerp(local_n, amount).normalized()
	var q := Quaternion(Vector3.UP, target_up)
	var cur := model.basis.get_rotation_quaternion()
	var s := model.basis.get_scale()
	model.basis = Basis(cur.slerp(q, minf(delta * 6.0, 1.0))).scaled(s)
