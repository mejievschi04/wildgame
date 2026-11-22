class_name LogPiece
extends WorldPickup
## A log bucked off a felled trunk: a real piece of that tree (its bark, fresh-cut ends) that rolls off the
## trunk and lies on the ground until picked up (gives wood). Saved like any other pickup.


## mesh: the log built in its own local space (axis along +Y, centred at the origin).
func setup_log(p_stack: ItemStack, mesh: Mesh, radius: float, length: float) -> void:
	stack = p_stack
	add_to_group("interactable")
	add_to_group("pickup")
	collision_layer = 4
	collision_mask = 1
	mass = 18.0
	continuous_cd = true
	angular_damp = 4.0
	linear_damp = 1.2
	# Bark grips: a log rolls a little off the trunk, then stops (it would otherwise roll down every slope).
	var pm := PhysicsMaterial.new()
	pm.friction = 1.0
	pm.rough = true
	physics_material_override = pm
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	add_child(mi)
	var shape := CylinderShape3D.new()
	shape.radius = radius
	shape.height = length
	Graybox.add_shape(self, shape)
