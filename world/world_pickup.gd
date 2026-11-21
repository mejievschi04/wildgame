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
	var data := stack.get_data()
	var col := data.icon_color if data else Color.GRAY
	Graybox.part(self, Graybox.box(Vector3(0.3, 0.18, 0.3)), col)
	Graybox.add_shape(self, Graybox.box_shape(Vector3(0.3, 0.18, 0.3)))


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
