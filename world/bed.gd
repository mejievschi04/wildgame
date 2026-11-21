class_name LeafBed
extends StaticBody3D
## Placed leaf bed: sleep (time skip) and respawn point. PLACEHOLDER graybox.

var structure_type: StringName = &"bed"
var structure_id := ""


func _ready() -> void:
	collision_layer = 1
	collision_mask = 0
	add_to_group("interactable")
	add_to_group("structure")
	Graybox.part(self, Graybox.box(Vector3(0.95, 0.16, 2.0)), Color(0.36, 0.4, 0.2), Vector3(0, 0.08, 0))
	Graybox.part(self, Graybox.box(Vector3(0.8, 0.1, 1.8)), Color(0.45, 0.42, 0.22), Vector3(0, 0.18, 0))
	for x in [-0.5, 0.5]:
		Graybox.part(self, Graybox.cylinder(0.05, 0.05, 2.1, 6), Color(0.4, 0.3, 0.2),
			Vector3(x, 0.06, 0), Vector3(90, 0, 0))
	Graybox.add_shape(self, Graybox.box_shape(Vector3(1.0, 0.3, 2.1)), Vector3(0, 0.15, 0))


func get_display_name() -> String:
	return Loc.t("STRUCT_BED")


func get_interactions(player: Node) -> Array:
	var check: Dictionary = player.can_sleep()
	return [
		{"action": &"interact", "text": Loc.t("ACT_SLEEP") if check.ok else check.reason, "hold": 0.0, "enabled": check.ok},
		{"action": &"alt_interact", "text": Loc.t("ACT_DISMANTLE"), "hold": 1.0, "enabled": true},
	]


func perform_interaction(player: Node, action: StringName) -> void:
	match action:
		&"interact":
			player.sleep_at(self)
		&"alt_interact":
			player.give_item(&"leaf_bed_kit", 1)
			queue_free()


func save_state() -> Dictionary:
	return {}


func load_state(_d: Dictionary) -> void:
	pass
