class_name ResourceNode
extends StaticBody3D
## Harvestable world node (tree, rock, bush, ...). Behaviour comes from data/resource_nodes.json:
##  hand_yield → gathered with [interact] (hold); hit_yield → LMB swing with a tool having hit_tag.

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
var _scattered_mesh: Mesh
var _scattered_basis := Basis.IDENTITY
var _scattered_scale := Vector3.ONE
var _scattered_bounds := AABB()


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
	if regrow_seconds > 0.0:
		add_to_group("time_sim")
		add_to_group("slow_sim")
	add_to_group("resource_node")
	if kind in [&"sticks", &"stones"]:
		add_to_group("gather_pile")
	_visual = Node3D.new()
	_visual.rotation.y = yaw
	add_child(_visual)
	if _scattered_mesh:
		_build_scattered()
	else:
		_build(size_scale)
	_refresh()


## Keep the exact mesh, orientation and scale of the generated object.
func setup_scattered(id: String, resource_kind: StringName, mesh: Mesh, xf: Transform3D) -> void:
	add_to_group("scattered_resource")
	_scattered_mesh = mesh
	_scattered_basis = xf.basis.orthonormalized()
	_scattered_scale = xf.basis.get_scale()
	var bounds := mesh.get_aabb()
	_scattered_bounds = AABB(bounds.position * _scattered_scale, bounds.size * _scattered_scale)
	position = xf.origin
	setup(id, resource_kind)


func _build_scattered() -> void:
	var art := MeshInstance3D.new()
	art.mesh = _scattered_mesh
	art.basis = _scattered_basis.scaled_local(_scattered_scale)
	art.visibility_range_end = 160.0 if kind != &"wild_grass" else 75.0
	if kind == &"wild_grass":
		art.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_visual.add_child(art)
	_full(art)
	_shape = Graybox.add_shape(self, Graybox.box_shape(Vector3.ONE))
	_shape.basis = _scattered_basis


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
	# The right tool in the pack doubles the take (a sickle for grain and flax, a digging stick for roots).
	var mult := 1
	var bonus_tag := StringName(str(cfg.get("bonus_tag", "")))
	if bonus_tag != &"" and player.inventory.has_tag(bonus_tag):
		mult = 2
	for id: String in (cfg.hand_yield as Dictionary).keys():
		player.give_item(StringName(id), int(cfg.hand_yield[id]) * mult)
	var extra: Dictionary = cfg.get("hand_bonus", {})  # e.g. a few seeds now and then
	for id: String in extra.keys():
		if randf() < float(extra[id]):
			player.give_item(StringName(id), 1)
	_consume_one()
	Sfx.play(&"stone_knock" if kind in [&"stones", &"loose_stone"] else &"rustle", global_position + Vector3.UP * 0.3, -4.0)


## LMB swing with the equipped item. Returns true when the hit landed (tool wears).
func on_hit(player: Node, item: ItemData) -> bool:
	if remaining <= 0 or not cfg.has("hit_tag"):
		return false
	var tag := StringName(str(cfg.hit_tag))
	if item == null or not item.has_tag(tag):
		Events.toast(Loc.t("NEED_%s" % String(tag).to_upper()), &"warn")
		return false
	_give(player, cfg.hit_yield)
	_roll_bonus(player)
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


## Optional "hit_bonus": {item: chance} -- e.g. a flint nodule cracked out of a boulder now and then.
func _roll_bonus(player: Node) -> void:
	var bonus: Dictionary = cfg.get("hit_bonus", {})
	for id: String in bonus.keys():
		if randf() < float(bonus[id]):
			player.give_item(StringName(id), 1)


func _consume_one() -> void:
	remaining -= 1
	if regrow_seconds > 0.0 and regrow_left <= 0.0:
		regrow_left = regrow_seconds
	_refresh()


func _refresh() -> void:
	var depleted := remaining <= 0
	var visible_parts := _full_parts.size()
	if kind == &"stones":
		visible_parts = ceili(float(visible_parts * remaining) / capacity)
	for i in _full_parts.size():
		_full_parts[i].visible = not depleted and i < visible_parts
	for p in _depleted_parts:
		p.visible = depleted
	if kind in [&"rock", &"flint", &"clay", &"deadwood"]:
		var k := lerpf(0.45 if kind != &"deadwood" else 0.7, 1.0, float(remaining) / float(capacity))
		for p in _full_parts:
			p.scale = p.get_meta("base_scale", Vector3.ONE) * k
	if _shape:
		var hide_when_empty := _scattered_mesh != null or kind in [&"sticks", &"deadwood", &"stones", &"mushroom", &"rock", &"flint", &"clay", &"wild_grain", &"wild_carrot", &"herbs", &"flax", &"reeds"]
		_shape.set_deferred("disabled", depleted and hide_when_empty)
		if _scattered_mesh and not depleted:
			var ratio := lerpf(0.45, 1.0, float(remaining) / float(capacity)) if kind == &"rock" else 1.0
			_shape.position = _scattered_basis * (_scattered_bounds.get_center() * ratio)
			(_shape.shape as BoxShape3D).size = (_scattered_bounds.size * ratio).max(Vector3(0.32, 0.30, 0.32))
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
			var tree_scale := s * AssetLib.TREE_MODEL_SCALE
			var tree := _art(AssetLib.pick(AssetLib.TREES[species], node_id), Vector3.ONE * tree_scale)
			_full(tree)
			var stump := _art(AssetLib.pick(AssetLib.TREES[&"stump"], node_id), Vector3.ONE * 0.5)
			_depleted(stump)
			_tree_shapes(maxf(AssetLib.aabb(tree).size.y * tree_scale, 6.0))
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
		&"deadwood":
			# a dry twig bush standing out of the grass: breaking twigs off it gives sticks (TwigBush)
			var variant := absi(hash(node_id)) % TwigBush.VARIANTS
			var full := MeshInstance3D.new()
			full.mesh = TwigBush.mesh(variant)
			full.scale = Vector3.ONE * s
			_visual.add_child(full)
			_full(full)
			var stubs := MeshInstance3D.new()
			stubs.mesh = TwigBush.mesh(variant, true)
			stubs.scale = Vector3.ONE * s
			_visual.add_child(stubs)
			_depleted(stubs)
			_shape = Graybox.add_shape(self, Graybox.box_shape(Vector3(1.3, 1.2, 1.3) * s), Vector3(0, 0.6 * s, 0))
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
		&"hazel":
			# A hazel bush: leafy sprigs with clusters of brown nuts in their husks.
			var rngh := RandomNumberGenerator.new()
			rngh.seed = hash(node_id + "hazel")
			for i in 11:
				var sprig := _art(AssetLib.PLANTS[&"shrub"][i % 3], Vector3.ONE * rngh.randf_range(3.0, 4.0) * s)
				var a := TAU * i / 11.0 + rngh.randf() * 0.4
				sprig.position = Vector3(cos(a), 0, sin(a)) * rngh.randf_range(0.1, 0.45) * s
				sprig.rotation = Vector3(cos(a) * 0.3, rngh.randf() * TAU, sin(a) * 0.3)
			var nuts := Node3D.new()
			_visual.add_child(nuts)
			var nm := Graybox.mat(Color(0.45, 0.3, 0.16), 0.5)
			var husk := Graybox.mat(Color(0.48, 0.55, 0.25), 0.8)
			for i in 9:
				var a := rngh.randf() * TAU
				var r := rngh.randf_range(0.25, 0.7) * s
				var c := Vector3(cos(a) * r, rngh.randf_range(0.35, 0.85) * s, sin(a) * r)
				for k in 3:
					Graybox.part_mat(nuts, Graybox.sphere(0.03, 6), nm, c + Vector3(k * 0.035 - 0.035, 0, 0))
				Graybox.part_mat(nuts, Graybox.sphere(0.045, 6), husk, c + Vector3(0, 0.03, 0), Vector3.ZERO, Vector3(1.6, 0.6, 1.0))
			_full(nuts)
			_shape = Graybox.add_shape(self, Graybox.box_shape(Vector3(1.8, 1.2, 1.8) * s), Vector3(0, 0.55 * s, 0))
		&"wild_grain", &"wild_carrot", &"herbs", &"flax", &"reeds", &"clay":
			var plant := Node3D.new()
			_visual.add_child(plant)
			WildPlants.build(kind, plant, hash(node_id), s)
			_full(plant)
			var h: float = {&"reeds": 1.6, &"flax": 0.7, &"wild_grain": 0.8, &"clay": 0.3}.get(kind, 0.5)
			_shape = Graybox.add_shape(self, Graybox.box_shape(Vector3(1.1, h, 1.1) * s), Vector3(0, h * 0.5 * s, 0))


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
	set_meta("trunk_shape", Graybox.cyl_shape(0.38 * AssetLib.TREE_MODEL_SCALE, h))
	set_meta("stump_shape", Graybox.cyl_shape(0.36, 0.6))
	_shape = Graybox.add_shape(self, get_meta("trunk_shape"), Vector3(0, h * 0.5, 0))
