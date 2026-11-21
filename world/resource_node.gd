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
	Sfx.play(&"stone_knock" if kind == &"stones" else &"rustle", global_position + Vector3.UP * 0.3, -4.0)


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
	Sfx.play(&"axe_chop" if String(kind).begins_with("tree") else &"stone_knock", global_position + Vector3.UP * 1.0)
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
		&"tree_pine", &"tree_birch":
			var species: StringName = &"alder"
			if kind == &"tree_pine":
				species = &"pine" if absi(hash(node_id + "sp")) % 10 < 3 else &"spruce"
			var tree := _art(AssetLib.pick(AssetLib.TREES[species], node_id), Vector3.ONE * s)
			_full(tree)
			var stump := _art(AssetLib.pick(AssetLib.TREES[&"stump"], node_id), Vector3.ONE * 0.5)
			_depleted(stump)
			_tree_shapes(maxf(AssetLib.aabb(tree).size.y * s, 6.0))
		&"rock":
			var rock := _art(AssetLib.pick(AssetLib.ROCKS[&"big"], node_id), Vector3.ONE * s)
			_full(rock)
			_shape = _aabb_shape(rock, s, 0.8)
		&"flint":
			var host := _art(AssetLib.pick(AssetLib.ROCKS[&"medium"], node_id), Vector3.ONE * s)
			_full(host)
			var dark := Color(0.32, 0.33, 0.37)
			for i in 3:
				var a := TAU * i / 3.0 + 0.5
				var nod := _art(AssetLib.ROCKS[&"small"][i % 3], Vector3.ONE * 2.6 * s)
				nod.position = Vector3(cos(a) * 0.45, 0.0, sin(a) * 0.4) * s
				nod.rotation = Vector3(0.4 * i, a, 0.2)
				_tint(nod, dark)
				_full(nod)
			_shape = _aabb_shape(host, s, 0.85)
		&"bush":
			var rngb := RandomNumberGenerator.new()
			rngb.seed = hash(node_id + "bush")
			for i in 9:
				var sprig := _art(AssetLib.PLANTS[&"shrub"][1 + i % 2], Vector3.ONE * rngb.randf_range(2.6, 3.4) * s)
				var a := TAU * i / 9.0 + rngb.randf() * 0.4
				sprig.position = Vector3(cos(a), 0, sin(a)) * rngb.randf_range(0.05, 0.35) * s
				sprig.rotation = Vector3(cos(a) * 0.35, rngb.randf() * TAU, sin(a) * 0.35)
			var berry_mat := StandardMaterial3D.new()
			berry_mat.albedo_color = Color(0.32, 0.04, 0.12)
			berry_mat.roughness = 0.25
			var berries := Node3D.new()
			_visual.add_child(berries)
			var rng := RandomNumberGenerator.new()
			rng.seed = hash(node_id)
			for i in 14:
				var mi := MeshInstance3D.new()
				mi.mesh = Graybox.sphere(0.035, 6)
				mi.material_override = berry_mat
				var a := rng.randf() * TAU
				var r := rng.randf_range(0.2, 0.75) * s
				mi.position = Vector3(cos(a) * r, rng.randf_range(0.15, 0.55) * s, sin(a) * r)
				berries.add_child(mi)
			_full(berries)
			_shape = Graybox.add_shape(self, Graybox.box_shape(Vector3(1.6, 1.0, 1.6) * s), Vector3(0, 0.45 * s, 0))
		&"sticks":
			var b1 := _art(AssetLib.pick(AssetLib.PLANTS[&"branches"], node_id), Vector3.ONE)
			_full(b1)
			var b2 := _art(AssetLib.pick(AssetLib.PLANTS[&"branches"], node_id + "b"), Vector3.ONE * 0.9)
			b2.rotation.y = 1.3
			b2.position = Vector3(0.15, 0.02, 0.1)
			_full(b2)
			_shape = Graybox.add_shape(self, Graybox.box_shape(Vector3(1.4, 0.5, 1.4)), Vector3(0, 0.2, 0))
		&"stones":
			for i in 5:
				var a := TAU * i / 5.0 + 0.4
				var st := _art(AssetLib.ROCKS[&"small"][i % 3], Vector3.ONE * (2.0 + 0.4 * (i % 2)))
				st.position = Vector3(cos(a) * 0.22, 0.0, sin(a) * 0.2)
				st.rotation = Vector3(0, a * 2.0, 0)
				_full(st)
			_shape = Graybox.add_shape(self, Graybox.box_shape(Vector3(0.9, 0.45, 0.9)), Vector3(0, 0.15, 0))
		&"mushroom":
			_full(Graybox.part(_visual, Graybox.cylinder(0.04, 0.05, 0.18, 6), Color(0.86, 0.82, 0.72), Vector3(0, 0.09, 0)))
			_full(Graybox.part(_visual, Graybox.sphere(0.12, 7), Color(0.6, 0.42, 0.26), Vector3(0, 0.19, 0),
				Vector3.ZERO, Vector3(1.2, 0.55, 1.2)))
			_shape = Graybox.add_shape(self, Graybox.box_shape(Vector3(0.5, 0.4, 0.5)), Vector3(0, 0.15, 0))


func _art(path: String, scl: Vector3) -> Node3D:
	var n := AssetLib.instance(path)
	n.scale = scl
	_visual.add_child(n)
	return n


func _aabb_shape(art: Node3D, s: float, shrink: float) -> CollisionShape3D:
	var box := AssetLib.aabb(art)
	var size := box.size * s * shrink
	var cs := Graybox.add_shape(self, Graybox.box_shape(size), Basis(Vector3.UP, _visual.rotation.y) * ((box.position + box.size * 0.5) * s))
	cs.rotation.y = _visual.rotation.y
	return cs


func _tint(root: Node3D, c: Color) -> void:
	for mi: MeshInstance3D in root.find_children("*", "MeshInstance3D", true, false):
		var m := mi.mesh.surface_get_material(0)
		if m is BaseMaterial3D:
			var d := (m as BaseMaterial3D).duplicate() as BaseMaterial3D
			d.albedo_color = c
			mi.material_override = d


func _tree_shapes(h: float) -> void:
	set_meta("trunk_shape", Graybox.cyl_shape(0.38, h))
	set_meta("stump_shape", Graybox.cyl_shape(0.36, 0.6))
	_shape = Graybox.add_shape(self, get_meta("trunk_shape"), Vector3(0, h * 0.5, 0))
