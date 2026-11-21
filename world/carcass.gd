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
	var deer := AssetLib.instance(str(ItemDB.get_animal(&"deer").model))
	Animal._fix_materials(deer)
	add_child(deer)
	var players := deer.find_children("*", "AnimationPlayer", true, false)
	if not players.is_empty():
		var ap: AnimationPlayer = players[0]
		ap.play("death")
		ap.seek(ap.current_animation_length, true)
		ap.pause()
	_body_parts.append(deer)
	_body_parts.append(Graybox.part(self, Graybox.cylinder(0.9, 0.9, 0.01, 16), Color(0.22, 0.05, 0.04, 0.8), Vector3(0, 0.01, 0)))
	_bones = Node3D.new()
	add_child(_bones)
	for i in 4:
		var bone := AssetLib.instance(AssetLib.item_model_path(&"bone"))
		bone.position = Vector3(-0.3 + i * 0.2, 0.02, 0.1 * (i % 2))
		bone.rotation = Vector3(PI * 0.5, 0.6 * i, 0)
		bone.scale = Vector3.ONE * 1.6
		_bones.add_child(bone)
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
