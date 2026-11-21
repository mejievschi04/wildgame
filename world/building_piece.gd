class_name BuildingPiece
extends StaticBody3D
## One modular building piece (data/building_pieces.json). Lifecycle:
##   blueprint (translucent, soft collision) → materials delivered in stages → built (solid).
## Structural support (GDD §9, simplified): foundation rests on terrain; walls/pillars/doors rest on
## a foundation; a roof rests on ≥1 remaining wall/pillar. Losing support collapses dependents.
## Visuals are PLACEHOLDER graybox primitives.

const FOUNDATION_H := 0.3
const WALL_H := 2.2
const GRID := 2.0
const DOOR_W := 1.0
const DOOR_H := 1.95
const DRY_TIME := 600.0
const DRY_SLOTS := 4
const REPAIR_FRACTION := 0.4

var structure_type: StringName = &"piece"
var structure_id := ""
var piece_id: StringName
var def: Dictionary = {}
var built := false
var delivered: Dictionary = {}  # StringName -> int
var max_health := 100.0
var health := 100.0
var supported_by: Array[String] = []
var door_open := false
var storage: Inventory
var drying: Array = []  # [{id, t}]

var _visual: Node3D
var _hinge: Node3D  # door only
var _dry_root: Node3D


# ---------------------------------------------------------------- setup

## Called by ForestWorld.spawn_structure before the node enters the tree.
func pre_setup(state: Dictionary) -> void:
	piece_id = StringName(str(state.get("piece", "foundation")))
	def = ItemDB.get_piece(piece_id)
	max_health = float(def.get("health", 100))
	health = max_health
	if def.has("slots"):
		storage = Inventory.new(int(def.slots), 9999.0)


func _ready() -> void:
	add_to_group("interactable")
	add_to_group("structure")
	add_to_group("building")
	add_to_group("time_sim")
	collision_mask = 0
	_visual = BuildingPiece.build_visual(piece_id)
	add_child(_visual)
	_hinge = _visual.get_node_or_null("Hinge")
	_dry_root = _visual.get_node_or_null("DryRoot")
	_build_collision()
	_refresh()


func needs_support() -> bool:
	return str(def.get("snap", "")) in ["edge", "corner", "top", "doorway"]


func piece_class() -> String:
	return str(def.get("class", ""))


func provides_support() -> bool:
	return bool(def.get("support", false))


func display_name() -> String:
	return Loc.t("BUILD_%s" % String(piece_id).to_upper())


func get_display_name() -> String:
	return display_name()


# ---------------------------------------------------------------- materials

func cost() -> Dictionary:
	return ItemDB.piece_cost(piece_id)


func missing() -> Dictionary:
	var out := {}
	var c := cost()
	for id: StringName in c.keys():
		var m := int(c[id]) - int(delivered.get(id, 0))
		if m > 0:
			out[id] = m
	return out


func can_deliver(inv: Inventory) -> bool:
	var m := missing()
	for id: StringName in m.keys():
		if inv.count_of(id) > 0:
			return true
	return false


## Moves as many missing materials as possible from the inventory. Returns true when completed.
func deliver_from(inv: Inventory) -> bool:
	var m := missing()
	for id: StringName in m.keys():
		var n := mini(inv.count_of(id), int(m[id]))
		if n > 0 and inv.remove_item(id, n):
			delivered[id] = int(delivered.get(id, 0)) + n
	if missing().is_empty():
		complete()
		return true
	_refresh()
	return false


func complete() -> void:
	built = true
	delivered.clear()
	health = max_health
	_refresh()


## Refund for dismantling/collapse: blueprints return everything delivered, built pieces a ratio of cost.
func refund(ratio: float) -> Dictionary:
	if not built:
		return delivered.duplicate()
	var out := {}
	var c := cost()
	for id: StringName in c.keys():
		var n := floori(int(c[id]) * ratio)
		if n > 0:
			out[id] = n
	return out


func damage(amount: float) -> void:
	if not built:
		return
	health = maxf(health - amount, 0.0)
	if health <= 0.0:
		var world := _world()
		if world:
			world.remove_piece(self, 0.25, null)


func repair_item() -> StringName:
	var c := cost()
	return c.keys()[0] if not c.is_empty() else &""


func repair(inv: Inventory) -> bool:
	var item := repair_item()
	if item == &"" or not inv.remove_item(item, 1):
		return false
	health = minf(health + max_health * REPAIR_FRACTION, max_health)
	_refresh()
	return true


func shelter_value() -> float:
	return float(def.get("shelter", 0.0)) if built else 0.0


# ---------------------------------------------------------------- interaction

func get_status_text() -> String:
	if not built:
		var parts := PackedStringArray()
		var c := cost()
		for id: StringName in c.keys():
			parts.append("%s %d/%d" % [ItemDB.get_item(id).display_name(), int(delivered.get(id, 0)), int(c[id])])
		return Loc.t("STATUS_BLUEPRINT", {"list": ", ".join(parts)})
	var bits := PackedStringArray()
	match piece_id:
		&"door": bits.append(Loc.t("STATUS_DOOR_OPEN" if door_open else "STATUS_DOOR_CLOSED"))
		&"storage": bits.append(Loc.t("STATUS_STORAGE", {"n": storage.size - storage.free_slots()}))
		&"drying_rack":
			if not drying.is_empty():
				bits.append(Loc.t("STATUS_DRYING", {"n": drying.size()}))
	if health < max_health:
		bits.append(Loc.t("STATUS_HEALTH", {"p": roundi(health / max_health * 100.0)}))
	return " · ".join(bits)


func get_interactions(player: Node) -> Array:
	var inv: Inventory = player.inventory
	var opts: Array = []
	if not built:
		var has_tool := inv.has_tag(&"tool_hammer")
		var can := can_deliver(inv)
		var text := Loc.t("NEED_TOOL_HAMMER") if not has_tool else (Loc.t("ACT_DELIVER") if can else Loc.t("ACT_NO_MATERIALS"))
		opts.append({"action": &"interact", "text": text, "hold": 0.6, "enabled": has_tool and can, "op": &"deliver"})
	else:
		var primary := _primary_option(inv)
		if not primary.is_empty():
			opts.append(primary)
		elif health < max_health:
			var item := repair_item()
			opts.append({"action": &"interact", "text": Loc.t("ACT_REPAIR", {"item": ItemDB.get_item(item).display_name()}),
				"hold": 1.0, "enabled": inv.count_of(item) > 0, "op": &"repair"})
	opts.append({"action": &"alt_interact", "text": Loc.t("ACT_DISMANTLE"), "hold": 1.5, "enabled": true, "op": &"dismantle"})
	return opts


func _primary_option(inv: Inventory) -> Dictionary:
	match piece_id:
		&"door":
			return {"action": &"interact", "text": Loc.t("ACT_CLOSE" if door_open else "ACT_OPEN"), "hold": 0.0, "enabled": true, "op": &"door"}
		&"storage":
			return {"action": &"interact", "text": Loc.t("ACT_OPEN_STORAGE"), "hold": 0.0, "enabled": true, "op": &"storage"}
		&"drying_rack":
			var ready := _dry_ready_index()
			if ready >= 0:
				return {"action": &"interact", "text": Loc.t("ACT_TAKE", {"item": ItemDB.get_item(&"meat_dried").display_name()}),
					"hold": 0.0, "enabled": true, "op": &"dry_take"}
			if inv.count_of(&"meat_raw") > 0 and drying.size() < DRY_SLOTS:
				return {"action": &"interact", "text": Loc.t("ACT_HANG", {"item": ItemDB.get_item(&"meat_raw").display_name()}),
					"hold": 0.0, "enabled": true, "op": &"dry_hang"}
	return {}


func perform_interaction(player: Node, action: StringName) -> void:
	var op: StringName = &""
	for o: Dictionary in get_interactions(player):
		if o.action == action and o.enabled:
			op = o.get("op", &"")
	var inv: Inventory = player.inventory
	match op:
		&"deliver":
			if deliver_from(inv):
				Events.toast(Loc.t("MSG_BUILT", {"name": display_name()}), &"good")
				Events.building_completed.emit(self)
		&"repair":
			repair(inv)
		&"door":
			set_door_open(not door_open)
		&"storage":
			Events.open_storage.emit(self)
		&"dry_hang":
			if inv.remove_item(&"meat_raw", 1):
				drying.append({"id": &"meat_raw", "t": 0.0})
				_refresh()
		&"dry_take":
			var i := _dry_ready_index()
			drying.remove_at(i)
			player.give_item(&"meat_dried", 1)
			_refresh()
		&"dismantle":
			_world().remove_piece(self, 0.5, player)


func set_door_open(open: bool) -> void:
	door_open = open
	if _hinge:
		var tw := create_tween()
		tw.tween_property(_hinge, "rotation:y", deg_to_rad(-100.0) if open else 0.0, 0.25).set_trans(Tween.TRANS_SINE)


func _dry_ready_index() -> int:
	for i in drying.size():
		if float(drying[i].t) >= DRY_TIME:
			return i
	return -1


func simulate(seconds: float) -> void:
	if piece_id != &"drying_rack" or drying.is_empty():
		return
	for d: Dictionary in drying:
		d.t = float(d.t) + seconds
	_refresh()


func _process(delta: float) -> void:
	if piece_id == &"drying_rack" and not drying.is_empty():
		for d: Dictionary in drying:
			d.t = float(d.t) + delta


func _world() -> ForestWorld:
	var n := get_parent()
	while n != null and not n is ForestWorld:
		n = n.get_parent()
	return n as ForestWorld


# ---------------------------------------------------------------- visuals & collision

func _refresh() -> void:
	if _visual == null:
		return
	collision_layer = 1 if built else 4
	BuildingPiece.apply_look(_visual, &"built" if built else &"blueprint")
	if _dry_root:
		for c in _dry_root.get_children():
			c.queue_free()
		for i in drying.size():
			var done := float(drying[i].t) >= DRY_TIME
			Graybox.part(_dry_root, Graybox.box(Vector3(0.12, 0.28, 0.05)),
				Color(0.48, 0.29, 0.19) if done else Color(0.66, 0.25, 0.24), Vector3(-0.5 + i * 0.33, -0.2, 0))
	if _hinge:
		_hinge.rotation.y = deg_to_rad(-100.0) if door_open else 0.0


## Applies blueprint/ghost materials to every mesh (originals kept in meta).
static func apply_look(root: Node, look: StringName, ghost_mat: Material = null) -> void:
	for mi: MeshInstance3D in root.find_children("*", "MeshInstance3D", true, false):
		if not mi.has_meta("orig"):
			mi.set_meta("orig", mi.material_override)
		match look:
			&"built":
				mi.material_override = mi.get_meta("orig")
				mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
			&"blueprint":
				mi.material_override = _blueprint_mat()
				mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			&"ghost":
				mi.material_override = ghost_mat
				mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


static var _bp_mat: StandardMaterial3D


static func _blueprint_mat() -> StandardMaterial3D:
	if _bp_mat == null:
		_bp_mat = StandardMaterial3D.new()
		_bp_mat.albedo_color = Color(0.77, 0.6, 0.35, 0.38)
		_bp_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		_bp_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	return _bp_mat


func _build_collision() -> void:
	match piece_id:
		&"foundation":
			Graybox.add_shape(self, Graybox.box_shape(Vector3(GRID, FOUNDATION_H, GRID)), Vector3(0, FOUNDATION_H * 0.5, 0))
		&"wall":
			Graybox.add_shape(self, Graybox.box_shape(Vector3(GRID, WALL_H, 0.16)), Vector3(0, WALL_H * 0.5, 0))
		&"doorway":
			var side := (GRID - DOOR_W) * 0.5
			for sx in [-1.0, 1.0]:
				Graybox.add_shape(self, Graybox.box_shape(Vector3(side, WALL_H, 0.16)), Vector3(sx * (DOOR_W + side) * 0.5, WALL_H * 0.5, 0))
			Graybox.add_shape(self, Graybox.box_shape(Vector3(DOOR_W, WALL_H - DOOR_H, 0.16)), Vector3(0, (WALL_H + DOOR_H) * 0.5, 0))
		&"door":
			# Swings with the hinge: transform synced in _physics_process.
			_door_shape = Graybox.add_shape(self, Graybox.box_shape(Vector3(DOOR_W - 0.06, DOOR_H - 0.04, 0.08)))
			_physics_process(0.0)
		&"pillar":
			Graybox.add_shape(self, Graybox.cyl_shape(0.14, WALL_H), Vector3(0, WALL_H * 0.5, 0))
		&"roof":
			Graybox.add_shape(self, Graybox.box_shape(Vector3(GRID + 0.3, 0.14, GRID + 0.3)), Vector3(0, 0.2, 0), Vector3(-12, 0, 0))
		&"lean_to":
			Graybox.add_shape(self, Graybox.box_shape(Vector3(3.0, 2.75, 0.12)), Vector3(0, 1.08, -0.08), Vector3(-38, 0, 0))
		_:
			var fp: Array = def.get("footprint", [1, 1, 1])
			var size := Vector3(float(fp[0]), float(fp[1]), float(fp[2]))
			Graybox.add_shape(self, Graybox.box_shape(size), Vector3(0, size.y * 0.5, 0))


var _door_shape: CollisionShape3D


func _physics_process(_delta: float) -> void:
	if _door_shape and _hinge:
		# Keep the door's collision aligned with the animated hinge.
		var xf := _hinge.transform * Transform3D(Basis(), Vector3(DOOR_W * 0.5, DOOR_H * 0.5, 0))
		_door_shape.transform = xf


## Builds the PLACEHOLDER visual for a piece (also used for ghost previews).
static func build_visual(id: StringName) -> Node3D:
	var root := Node3D.new()
	var wood := Color(0.42, 0.3, 0.19)
	var stake := Color(0.47, 0.36, 0.23)
	var weave := Color(0.55, 0.43, 0.27)
	var thatch := Color(0.66, 0.57, 0.33)
	match id:
		&"foundation":
			for i in 7:
				Graybox.part(root, Graybox.cylinder(0.14, 0.14, GRID, 7), wood.lightened(0.04 * (i % 2)),
					Vector3(-0.86 + i * 0.287, FOUNDATION_H * 0.5, 0), Vector3(90, 0, 0))
			for sx in [-0.9, 0.9]:
				for sz in [-0.9, 0.9]:
					Graybox.part(root, Graybox.cylinder(0.1, 0.12, 2.0, 6), wood.darkened(0.15), Vector3(sx, -0.95, sz))
		&"wall", &"doorway":
			var n := 7
			for i in n:
				var x := -0.93 + i * (1.86 / (n - 1))
				if id == &"doorway" and absf(x) < DOOR_W * 0.5:
					continue
				Graybox.part(root, Graybox.cylinder(0.045, 0.05, WALL_H, 5), stake, Vector3(x, WALL_H * 0.5, 0))
			var bands := 6
			for j in bands:
				var y := 0.25 + j * 0.34
				if id == &"doorway" and y < DOOR_H:
					var side := (GRID - DOOR_W) * 0.5
					for sx in [-1.0, 1.0]:
						Graybox.part(root, Graybox.box(Vector3(side, 0.22, 0.09)), weave.lightened(0.05 * (j % 2)),
							Vector3(sx * (DOOR_W + side) * 0.5, y, 0))
				else:
					Graybox.part(root, Graybox.box(Vector3(GRID - 0.05, 0.22, 0.09)), weave.lightened(0.05 * (j % 2)), Vector3(0, y, 0))
		&"door":
			var hinge := Node3D.new()
			hinge.name = "Hinge"
			hinge.position = Vector3(-DOOR_W * 0.5, 0, 0)
			root.add_child(hinge)
			Graybox.part(hinge, Graybox.box(Vector3(DOOR_W - 0.06, DOOR_H - 0.04, 0.06)), weave, Vector3(DOOR_W * 0.5, DOOR_H * 0.5, 0))
			for y in [0.4, 1.0, 1.6]:
				Graybox.part(hinge, Graybox.box(Vector3(DOOR_W - 0.02, 0.06, 0.09)), stake.darkened(0.1), Vector3(DOOR_W * 0.5, y, 0))
		&"pillar":
			Graybox.part(root, Graybox.cylinder(0.11, 0.13, WALL_H, 7), wood, Vector3(0, WALL_H * 0.5, 0))
		&"roof":
			var tilt := Node3D.new()
			tilt.position = Vector3(0, 0.2, 0)
			tilt.rotation_degrees = Vector3(-12, 0, 0)
			root.add_child(tilt)
			Graybox.part(tilt, Graybox.box(Vector3(GRID + 0.3, 0.12, GRID + 0.3)), thatch)
			for sx in [-0.95, 0.0, 0.95]:
				Graybox.part(tilt, Graybox.cylinder(0.05, 0.05, GRID + 0.4, 5), wood, Vector3(sx, -0.08, 0), Vector3(90, 0, 0))
		&"fence":
			for i in 4:
				Graybox.part(root, Graybox.cylinder(0.05, 0.06, 1.2, 5), stake, Vector3(-0.9 + i * 0.6, 0.55, 0))
			for y in [0.4, 0.85]:
				Graybox.part(root, Graybox.cylinder(0.035, 0.035, 2.0, 5), wood, Vector3(0, y, 0), Vector3(0, 0, 90))
		&"storage":
			Graybox.part(root, Graybox.box(Vector3(1.0, 0.6, 0.7)), weave, Vector3(0, 0.3, 0))
			Graybox.part(root, Graybox.box(Vector3(1.05, 0.08, 0.75)), stake.darkened(0.1), Vector3(0, 0.64, 0))
		&"drying_rack":
			for sx in [-0.75, 0.75]:
				Graybox.part(root, Graybox.cylinder(0.04, 0.05, 1.7, 5), stake, Vector3(sx, 0.8, 0.25), Vector3(-17, 0, 0))
				Graybox.part(root, Graybox.cylinder(0.04, 0.05, 1.7, 5), stake, Vector3(sx, 0.8, -0.25), Vector3(17, 0, 0))
			Graybox.part(root, Graybox.cylinder(0.035, 0.035, 1.7, 5), wood, Vector3(0, 1.5, 0), Vector3(0, 0, 90))
			var dry := Node3D.new()
			dry.name = "DryRoot"
			dry.position = Vector3(0, 1.5, 0)
			root.add_child(dry)
		&"lean_to":
			for i in 6:
				Graybox.part(root, Graybox.cylinder(0.05, 0.06, 2.9, 5), wood, Vector3(-1.35 + i * 0.54, 1.05, 0.0), Vector3(-38, 0, 0))
			Graybox.part(root, Graybox.box(Vector3(3.0, 2.75, 0.06)), thatch, Vector3(0, 1.08, -0.08), Vector3(-38, 0, 0))
			Graybox.part(root, Graybox.cylinder(0.07, 0.07, 3.2, 6), wood, Vector3(0, 1.95, -0.6), Vector3(0, 0, 90))
			for sx in [-1.4, 1.4]:
				Graybox.part(root, Graybox.cylinder(0.07, 0.08, 2.0, 6), wood, Vector3(sx, 1.0, -0.6))
	return root


# ---------------------------------------------------------------- persistence

func save_state() -> Dictionary:
	var dl := {}
	for id: StringName in delivered.keys():
		dl[String(id)] = delivered[id]
	var dr: Array = []
	for d: Dictionary in drying:
		dr.append({"id": String(d.id), "t": d.t})
	var out := {"piece": String(piece_id), "built": built, "delivered": dl, "health": health,
		"on": supported_by.duplicate(), "door_open": door_open, "drying": dr}
	if storage:
		out["storage"] = storage.to_dict()
	return out


func load_state(d: Dictionary) -> void:
	built = bool(d.get("built", false))
	delivered.clear()
	var dl: Dictionary = d.get("delivered", {})
	for k: String in dl.keys():
		delivered[StringName(k)] = int(dl[k])
	health = float(d.get("health", max_health))
	supported_by.clear()
	for id: Variant in d.get("on", []):
		supported_by.append(str(id))
	door_open = bool(d.get("door_open", false))
	drying.clear()
	for e: Dictionary in d.get("drying", []):
		drying.append({"id": StringName(str(e.id)), "t": float(e.get("t", 0.0))})
	if storage and d.has("storage"):
		storage.from_dict(d.storage)
	_refresh()
