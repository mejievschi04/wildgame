class_name Stash
extends StaticBody3D
## Hide-covered cache at an abandoned camp: one-time loot + journal clue. PLACEHOLDER graybox.

var save_id := "poi_stash"
var contents := {&"hide": 1, &"fiber": 4, &"flint": 2, &"meat_cooked": 1}
var journal_key := "JOURNAL_OLD_CAMP"
var looted := false
var _cover: MeshInstance3D


func _ready() -> void:
	collision_layer = 1
	collision_mask = 0
	add_to_group("interactable")
	add_to_group("persistent")
	for i in 5:
		var a := TAU * i / 5.0
		Graybox.part(self, Graybox.sphere(0.16, 6), Color(0.45, 0.44, 0.4), Vector3(cos(a) * 0.45, 0.1, sin(a) * 0.45))
	_cover = Graybox.part(self, Graybox.sphere(0.45, 8), Color(0.55, 0.42, 0.28), Vector3(0, 0.15, 0), Vector3.ZERO, Vector3(1.2, 0.5, 1.0))
	Graybox.add_shape(self, Graybox.box_shape(Vector3(1.2, 0.5, 1.2)), Vector3(0, 0.2, 0))
	_refresh()


func get_save_id() -> String:
	return save_id


func is_modified() -> bool:
	return looted


func save_state() -> Dictionary:
	return {"looted": looted}


func load_state(d: Dictionary) -> void:
	looted = bool(d.get("looted", false))
	_refresh()


func get_display_name() -> String:
	return Loc.t("NODE_STASH")


func get_interactions(_player: Node) -> Array:
	if looted:
		return [{"action": &"interact", "text": Loc.t("ACT_EMPTY"), "hold": 0.0, "enabled": false}]
	return [{"action": &"interact", "text": Loc.t("ACT_SEARCH"), "hold": 1.5, "enabled": true}]


func perform_interaction(player: Node, _action: StringName) -> void:
	if looted:
		return
	for id: StringName in contents.keys():
		player.give_item(id, contents[id])
	looted = true
	player.world.add_journal(journal_key)
	_refresh()


func _refresh() -> void:
	if _cover:
		_cover.material_override = Graybox.mat(Color(0.3, 0.26, 0.2) if looted else Color(0.55, 0.42, 0.28))
