class_name ResourceNode
extends StaticBody3D
## Harvestable world node (tree, rock, bush, ...). Behaviour comes from data/resource_nodes.json:
##  hand_yield → gathered with [interact] (hold); hit_yield → LMB swing with a tool having hit_tag.
## Visuals are PLACEHOLDER graybox primitives.

var node_id: String
var kind: StringName
var cfg: Dictionary = {}
var capacity := 1
var remaining := 1
var regrow_seconds := 0.0
var regrow_left := 0.0

var _full_parts: Array[Node3D] = []
var _depleted_parts: Array[Node3D] = []
var _shape: CollisionShape3D
var _visual: Node3D


func setup(p_id: String, p_kind: StringName, size_scale: float = 1.0, yaw: float = 0.0) -> void:
	node_id = p_id
	kind = p_kind
	name = p_id
	cfg = ItemDB.get_node_kind(kind)
	capacity = int(cfg.get("capacity", 1))
	remaining = capacity
	regrow_seconds = float(cfg.get("regrow", 0.0))
	collision_layer = 1 if bool(cfg.get("blocking", true)) else 4
	collision_mask = 0
	add_to_group("interactable")
	add_to_group("persistent")
	add_to_group("time_sim")
	add_to_group("slow_sim")
	add_to_group("resource_node")
	_visual = Node3D.new()
	_visual.rotation.y = yaw
	add_child(_visual)
	_build(size_scale)
	_refresh()


func get_save_id() -> String:
	return node_id


func is_modified() -> bool:
	return remaining != capacity or regrow_left > 0.0


func save_state() -> Dictionary:
	return {"r": remaining, "g": regrow_left}


func load_state(d: Dictionary) -> void:
	remaining = clampi(int(d.get("r", capacity)), 0, capacity)
	regrow_left = float(d.get("g", 0.0))
	_refresh()


func get_display_name() -> String:
	return String(TranslationServer.translate("NODE_%s" % String(kind).to_upper()))


func get_interactions(player: Node) -> Array:
	if cfg.has("hand_yield"):
		if remaining <= 0:
			return [{"action": &"interact", "text": Loc.t("ACT_EMPTY"), "hold": 0.0, "enabled": false}]
		return [{"action": &"interact", "text": Loc.t("ACT_GATHER_%s" % String(kind).to_upper()),
			"hold": float(cfg.get("hold", 0.5)), "enabled": true}]
	if cfg.has("hit_tag"):
		if remaining <= 0:
			return []
		var tag := StringName(str(cfg.hit_tag))
		var hand: ItemStack = player.inventory.hand
		var ok := hand != null and hand.get_data().has_tag(tag)
		var text := Loc.t("ACT_HIT_%s" % String(kind).to_upper()) if ok else Loc.t("NEED_%s" % String(tag).to_upper())
		return [{"action": &"primary_action", "text": text, "hold": 0.0, "enabled": ok, "swing": true}]
	return []


func perform_interaction(player: Node, action: StringName) -> void:
	if action != &"interact" or remaining <= 0 or not cfg.has("hand_yield"):
		return
	_give(player, cfg.hand_yield)
	_consume_one()


## LMB swing with the equipped item. Returns true when the hit landed (tool wears).
func on_hit(player: Node, item: ItemData) -> bool:
	if remaining <= 0 or not cfg.has("hit_tag"):
		return false
	var tag := StringName(str(cfg.hit_tag))
	if item == null or not item.has_tag(tag):
		Events.toast(Loc.t("NEED_%s" % String(tag).to_upper()), &"warn")
		return false
	_give(player, cfg.hit_yield)
	_consume_one()
	_shake()
	return true


func simulate(seconds: float) -> void:
	if regrow_seconds <= 0.0 or remaining >= capacity or regrow_left <= 0.0:
		return
	regrow_left -= seconds
	if regrow_left <= 0.0:
		regrow_left = 0.0
		remaining = capacity
		_refresh()


func _give(player: Node, yields: Dictionary) -> void:
	for id: String in yields.keys():
		player.give_item(StringName(id), int(yields[id]))


func _consume_one() -> void:
	remaining -= 1
	if regrow_seconds > 0.0 and regrow_left <= 0.0:
		regrow_left = regrow_seconds
	_refresh()


func _refresh() -> void:
	var depleted := remaining <= 0
	for p in _full_parts:
		p.visible = not depleted
	for p in _depleted_parts:
		p.visible = depleted
	if kind in [&"rock", &"flint"]:
		var k := lerpf(0.45, 1.0, float(remaining) / float(capacity))
		for p in _full_parts:
			p.scale = p.get_meta("base_scale", Vector3.ONE) * k
	if _shape:
		var hide_when_empty := kind in [&"sticks", &"stones", &"mushroom", &"rock", &"flint"]
		_shape.disabled = depleted and hide_when_empty
		if kind in [&"tree_pine", &"tree_birch"]:
			_shape.shape = _get_meta_shape("stump_shape") if depleted else _get_meta_shape("trunk_shape")
			_shape.position.y = (_shape.shape as CylinderShape3D).height * 0.5


func _get_meta_shape(key: String) -> Shape3D:
	return get_meta(key)


func _shake() -> void:
	if _visual == null:
		return
	var tw := create_tween()
	var base := _visual.position
	tw.tween_property(_visual, "position", base + Vector3(0.04, 0, 0.03), 0.04)
	tw.tween_property(_visual, "position", base - Vector3(0.03, 0, 0.04), 0.05)
	tw.tween_property(_visual, "position", base, 0.06)


func _full(n: Node3D) -> Node3D:
	_full_parts.append(n)
	n.set_meta("base_scale", n.scale)
	return n


func _depleted(n: Node3D) -> Node3D:
	_depleted_parts.append(n)
	return n


func _build(s: float) -> void:
	match kind:
		&"tree_pine":
			var h := 8.5 * s
			var trunk_col := Color(0.33, 0.24, 0.17)
			_full(Graybox.part(_visual, Graybox.cylinder(0.14, 0.3, h, 7), trunk_col, Vector3(0, h * 0.5, 0)))
			var green := Color(0.14, 0.24, 0.15)
			for i in 3:
				var cone_h := (3.6 - i * 0.7) * s
				var r := (2.0 - i * 0.45) * s
				var y := h * (0.42 + i * 0.2)
				_full(Graybox.part(_visual, Graybox.cylinder(0.0, r, cone_h, 8), green.lightened(i * 0.04), Vector3(0, y, 0)))
			_depleted(Graybox.part(_visual, Graybox.cylinder(0.26, 0.32, 0.55, 7), trunk_col.lightened(0.15), Vector3(0, 0.27, 0)))
			_tree_shapes(h)
		&"tree_birch":
			var h := 7.0 * s
			_full(Graybox.part(_visual, Graybox.cylinder(0.12, 0.22, h, 7), Color(0.82, 0.8, 0.74), Vector3(0, h * 0.5, 0)))
			var leaf := Color(0.33, 0.45, 0.2)
			_full(Graybox.part(_visual, Graybox.sphere(2.0 * s, 9), leaf, Vector3(0, h * 0.82, 0), Vector3.ZERO, Vector3(1, 1.3, 1)))
			_full(Graybox.part(_visual, Graybox.sphere(1.4 * s, 8), leaf.lightened(0.06), Vector3(0.9 * s, h * 0.68, 0.4 * s)))
			_depleted(Graybox.part(_visual, Graybox.cylinder(0.2, 0.24, 0.5, 7), Color(0.75, 0.72, 0.65), Vector3(0, 0.25, 0)))
			_tree_shapes(h)
		&"rock":
			_full(Graybox.part(_visual, Graybox.sphere(1.0, 7), Color(0.47, 0.46, 0.43), Vector3(0, 0.4 * s, 0),
				Vector3(8, 20, 5), Vector3(1.6, 1.1, 1.3) * s))
			_depleted(Graybox.part(_visual, Graybox.sphere(0.5, 6), Color(0.45, 0.44, 0.41), Vector3(0, 0.05, 0),
				Vector3.ZERO, Vector3(1.8, 0.35, 1.5)))
			_shape = Graybox.add_shape(self, Graybox.box_shape(Vector3(2.6, 1.6, 2.2) * s), Vector3(0, 0.5 * s, 0))
		&"flint":
			_full(Graybox.part(_visual, Graybox.sphere(0.7, 7), Color(0.3, 0.31, 0.33), Vector3(0, 0.3 * s, 0),
				Vector3(10, 0, 12), Vector3(1.3, 0.9, 1.1) * s))
			for i in 3:
				var a := TAU * i / 3.0
				_full(Graybox.part(_visual, Graybox.sphere(0.18, 6), Color(0.62, 0.6, 0.55),
					Vector3(cos(a) * 0.55, 0.45, sin(a) * 0.5) * s))
			_depleted(Graybox.part(_visual, Graybox.sphere(0.4, 6), Color(0.3, 0.31, 0.33), Vector3(0, 0.04, 0),
				Vector3.ZERO, Vector3(1.6, 0.3, 1.3)))
			_shape = Graybox.add_shape(self, Graybox.box_shape(Vector3(1.8, 1.2, 1.6) * s), Vector3(0, 0.4 * s, 0))
		&"bush":
			var col := Color(0.22, 0.35, 0.17)
			Graybox.part(_visual, Graybox.sphere(0.8, 8), col, Vector3(0, 0.45 * s, 0), Vector3.ZERO, Vector3(1.3, 0.85, 1.2) * s)
			_full(Graybox.part(_visual, Graybox.sphere(0.55, 7), col.lightened(0.08), Vector3(0.45, 0.7, 0.2) * s))
			for i in 7:
				var a := TAU * i / 7.0
				_full(Graybox.part(_visual, Graybox.sphere(0.07, 5), Color(0.5, 0.1, 0.22),
					Vector3(cos(a) * 0.9, 0.55 + 0.25 * sin(a * 3.0), sin(a) * 0.85) * s))
			_depleted(Graybox.part(_visual, Graybox.sphere(0.5, 6), Color(0.33, 0.3, 0.17), Vector3(0, 0.6 * s, 0)))
			_shape = Graybox.add_shape(self, Graybox.box_shape(Vector3(1.8, 1.2, 1.8) * s), Vector3(0, 0.6 * s, 0))
		&"sticks":
			for i in 4:
				var a := 40.0 * i + 10.0
				_full(Graybox.part(_visual, Graybox.cylinder(0.035, 0.045, 1.3, 5), Color(0.45, 0.34, 0.22),
					Vector3(0.1 * i - 0.15, 0.06 + 0.05 * i, 0.05 * i), Vector3(90, a, 0)))
			_shape = Graybox.add_shape(self, Graybox.box_shape(Vector3(1.4, 0.5, 1.4)), Vector3(0, 0.2, 0))
		&"stones":
			for i in 4:
				var a := TAU * i / 4.0 + 0.4
				_full(Graybox.part(_visual, Graybox.sphere(0.14 + 0.04 * (i % 2), 6), Color(0.52, 0.51, 0.47),
					Vector3(cos(a) * 0.25, 0.08, sin(a) * 0.22), Vector3(0, 0, 0), Vector3(1.2, 0.7, 1.0)))
			_shape = Graybox.add_shape(self, Graybox.box_shape(Vector3(0.9, 0.45, 0.9)), Vector3(0, 0.15, 0))
		&"mushroom":
			_full(Graybox.part(_visual, Graybox.cylinder(0.04, 0.05, 0.18, 6), Color(0.86, 0.82, 0.72), Vector3(0, 0.09, 0)))
			_full(Graybox.part(_visual, Graybox.sphere(0.12, 7), Color(0.6, 0.42, 0.26), Vector3(0, 0.19, 0),
				Vector3.ZERO, Vector3(1.2, 0.55, 1.2)))
			_shape = Graybox.add_shape(self, Graybox.box_shape(Vector3(0.5, 0.4, 0.5)), Vector3(0, 0.15, 0))


func _tree_shapes(h: float) -> void:
	set_meta("trunk_shape", Graybox.cyl_shape(0.38, h))
	set_meta("stump_shape", Graybox.cyl_shape(0.36, 0.6))
	_shape = Graybox.add_shape(self, get_meta("trunk_shape"), Vector3(0, h * 0.5, 0))
