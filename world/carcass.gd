class_name Carcass
extends StaticBody3D
## Fresh deer carcass POI (a predator's kill). Butcher with a knife. PLACEHOLDER graybox.

const BUTCHER_TIME := 4.0
const YIELD := {&"meat_raw": 4, &"hide": 1, &"bone": 2}

var save_id := "poi_carcass"
var butchered := false
var _body_parts: Array[Node3D] = []
var _bones: Node3D


func _ready() -> void:
	collision_layer = 1
	collision_mask = 0
	add_to_group("interactable")
	add_to_group("persistent")
	var fur := Color(0.45, 0.32, 0.2)
	_body_parts.append(Graybox.part(self, Graybox.sphere(0.5, 8), fur, Vector3(0, 0.35, 0), Vector3(0, 0, 90), Vector3(0.75, 1.5, 0.75)))
	_body_parts.append(Graybox.part(self, Graybox.sphere(0.2, 7), fur.darkened(0.1), Vector3(0, 0.25, 0.95), Vector3.ZERO, Vector3(1, 1, 1.5)))
	for p: Vector3 in [Vector3(0.25, 0.12, 0.45), Vector3(-0.25, 0.12, 0.45), Vector3(0.25, 0.12, -0.45), Vector3(-0.25, 0.12, -0.45)]:
		_body_parts.append(Graybox.part(self, Graybox.cylinder(0.04, 0.05, 0.9, 5), fur.darkened(0.2), p + Vector3(0.45 * signf(p.x), 0, 0), Vector3(0, 0, 90)))
	_body_parts.append(Graybox.part(self, Graybox.cylinder(0.9, 0.9, 0.01, 12), Color(0.25, 0.06, 0.05), Vector3(0, 0.01, 0)))
	_bones = Node3D.new()
	add_child(_bones)
	for i in 5:
		Graybox.part(_bones, Graybox.cylinder(0.03, 0.03, 0.5, 5), Color(0.85, 0.8, 0.7), Vector3(-0.4 + i * 0.2, 0.05, 0), Vector3(90, 20.0 * i, 0))
	Graybox.add_shape(self, Graybox.box_shape(Vector3(1.6, 0.6, 2.0)), Vector3(0, 0.3, 0))
	_refresh()


func get_save_id() -> String:
	return save_id


func is_modified() -> bool:
	return butchered


func save_state() -> Dictionary:
	return {"butchered": butchered}


func load_state(d: Dictionary) -> void:
	butchered = bool(d.get("butchered", false))
	_refresh()


func get_display_name() -> String:
	return Loc.t("NODE_CARCASS") if not butchered else Loc.t("NODE_BONES")


func get_interactions(player: Node) -> Array:
	if butchered:
		return []
	var ok: bool = player.inventory.has_tag(&"tool_knife")
	return [{"action": &"interact", "text": Loc.t("ACT_BUTCHER") if ok else Loc.t("NEED_TOOL_KNIFE"),
		"hold": BUTCHER_TIME, "enabled": ok}]


func perform_interaction(player: Node, _action: StringName) -> void:
	if butchered or not player.inventory.has_tag(&"tool_knife"):
		return
	for id: StringName in YIELD.keys():
		player.give_item(id, YIELD[id])
	butchered = true
	Sfx.play(&"rustle", global_position)
	player.world.add_journal("JOURNAL_CARCASS")
	_refresh()


func _refresh() -> void:
	for p in _body_parts:
		p.visible = not butchered
	_bones.visible = butchered
