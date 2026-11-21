class_name WorldPickup
extends RigidBody3D
## A dropped item stack lying in the world (PLACEHOLDER box visual tinted by the item colour).

var stack: ItemStack


func setup(p_stack: ItemStack) -> void:
	stack = p_stack
	add_to_group("interactable")
	add_to_group("pickup")
	collision_layer = 4
	collision_mask = 1
	mass = 1.0
	continuous_cd = true
	var path := AssetLib.item_model_path(stack.id)
	var size := Vector3(0.3, 0.18, 0.3)
	if path != "":
		var m := AssetLib.instance(path)
		add_child(m)
		var box := AssetLib.aabb(m)
		# Lay long items (tools, sticks) on their side.
		if box.size.y > maxf(box.size.x, box.size.z) * 1.5:
			m.rotation_degrees = Vector3(90, 0, 0)
			box = Transform3D(m.basis, Vector3.ZERO) * box
		m.position = -(box.position + box.size * 0.5)
		size = box.size.max(Vector3(0.12, 0.08, 0.12))
	else:
		Graybox.part(self, Graybox.box(size), stack.get_data().icon_color if stack.get_data() else Color.GRAY)
	Graybox.add_shape(self, Graybox.box_shape(size))


func get_display_name() -> String:
	var data := stack.get_data()
	return data.display_name() if data else "?"


func get_interactions(_player: Node) -> Array:
	return [{"action": &"interact", "text": Loc.t("ACT_PICKUP", {"n": stack.count}), "hold": 0.0, "enabled": true}]


func perform_interaction(player: Node, _action: StringName) -> void:
	var before := stack.count
	var leftover: int = player.inventory.add_stack(stack)
	if leftover < before:
		Events.item_gained.emit(stack.id, before - leftover)
		Sfx.play(&"pop", global_position, -6.0)
	if leftover <= 0:
		queue_free()
	else:
		stack.count = leftover
		Events.toast(Loc.t("MSG_INVENTORY_FULL"), &"warn")


func to_dict() -> Dictionary:
	var p := global_position
	return {"item": stack.to_dict(), "pos": [p.x, p.y, p.z]}
