class_name BuildingPiece
extends StaticBody3D
## One modular building piece (data/building_pieces.json). Lifecycle:
##   blueprint (translucent, soft collision) → materials delivered in stages → built (solid).
## Structural support (GDD §9, simplified): foundation rests on terrain; walls/pillars/doors rest on
## a foundation; a roof rests on ≥1 remaining wall/pillar; a gable rests on a roof. Losing support collapses
## dependents.
## Visuals (BuildingVisuals) go up in construction STAGES as materials are delivered, and built pieces can be
## UPGRADED through material tiers (wattle -> logs -> stone, ...): more health, warmer walls.

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
## Material tier (0 = base). Tier definitions: def.tiers[tier - 1] = {name, cost, health (multiplier), warmth}.
var tier := 0
## Crops when this is a garden bed (see FarmPlot).
var farm: FarmPlot

var _visual: Node3D
var _hinge: Node3D  # door only
var _dry_root: Node3D
var _stages_shown := -1  # construction stages currently shown as real material


# ---------------------------------------------------------------- setup

## Called by ForestWorld.spawn_structure before the node enters the tree.
func pre_setup(state: Dictionary) -> void:
	piece_id = StringName(str(state.get("piece", "foundation")))
	def = ItemDB.get_piece(piece_id)
	tier = clampi(int(state.get("tier", 0)), 0, max_tier())
	max_health = _tier_health()
	health = max_health
	if def.has("slots"):
		storage = Inventory.new(int(def.slots), 9999.0)
	if piece_id == &"garden_bed":
		farm = FarmPlot.new(self)


func _ready() -> void:
	add_to_group("interactable")
	add_to_group("structure")
	add_to_group("building")
	add_to_group("time_sim")
	collision_mask = 0
	_make_visual()
	_build_collision()
	_refresh()


func _make_visual() -> void:
	if _visual:
		_visual.queue_free()
	_visual = BuildingPiece.build_visual(piece_id, tier, hash(structure_id))
	add_child(_visual)
	_hinge = _visual.get_node_or_null("Hinge")
	_dry_root = _visual.get_node_or_null("DryRoot")
	_stages_shown = -1
	if farm:
		farm.attach(_visual)


# ---------------------------------------------------------------- tiers

func tiers() -> Array:
	return def.get("tiers", [])


func max_tier() -> int:
	return tiers().size()


func _tier_def(t: int) -> Dictionary:
	return tiers()[t - 1] if t > 0 and t <= tiers().size() else {}


func _tier_health() -> float:
	return float(def.get("health", 100)) * float(_tier_def(tier).get("health", 1.0))


## Extra warmth (°C) this piece adds to a roofed room at its current tier.
func warmth() -> float:
	return float(_tier_def(tier).get("warmth", 0.0)) if built else 0.0


## Materials for the next tier as {StringName: int}; empty when fully upgraded.
func upgrade_cost() -> Dictionary:
	var out := {}
	var c: Dictionary = _tier_def(tier + 1).get("cost", {})
	for k: String in c.keys():
		out[StringName(k)] = int(c[k])
	return out


func can_upgrade(inv: Inventory) -> bool:
	if not built or tier >= max_tier() or not inv.has_tag(&"tool_hammer"):
		return false
	var c := upgrade_cost()
	for id: StringName in c.keys():
		if inv.count_of(id) < int(c[id]):
			return false
	return true


## Rebuilds the piece in the next material tier: the new structure goes up stage by stage in front of you.
func upgrade(inv: Inventory) -> bool:
	if not can_upgrade(inv):
		return false
	var c := upgrade_cost()
	for id: StringName in c.keys():
		inv.remove_item(id, int(c[id]))
	var ratio := health / max_health
	tier += 1
	max_health = _tier_health()
	health = max_health * maxf(ratio, 0.5) if ratio < 1.0 else max_health
	_make_visual()
	_rebuild_collision()
	_refresh(false)
	if is_inside_tree():
		var n := stage_count()
		var nodes := BuildingVisuals.stage_nodes(_visual)
		for i in n:
			for s: Node3D in nodes.get(i, []):
				s.scale = Vector3(1, 0.001, 1)
			get_tree().create_timer(0.3 * i + 0.05).timeout.connect(_reveal_stage.bind(i))
		Events.toast(Loc.t("MSG_UPGRADED", {"name": display_name()}), &"good")
	return true


func stage_count() -> int:
	return int(_visual.get_meta("stages", 1)) if _visual else 1


## Construction stages already standing in real materials: proportional to what has been delivered.
func stages_done() -> int:
	if built:
		return stage_count()
	var total := 0
	var have := 0
	var c := cost()
	for id: StringName in c.keys():
		total += int(c[id])
		have += mini(int(delivered.get(id, 0)), int(c[id]))
	if total <= 0:
		return 0
	return mini(floori(float(have) / total * stage_count()), stage_count())


func needs_support() -> bool:
	return str(def.get("snap", "")) in ["edge", "corner", "top", "doorway", "gable"]


func piece_class() -> String:
	return str(def.get("class", ""))


func provides_support() -> bool:
	return bool(def.get("support", false))


func display_name() -> String:
	var key := "BUILD_%s" % String(piece_id).to_upper()
	if tier > 0 and Loc.has_key("%s_T%d" % [key, tier]):
		return Loc.t("%s_T%d" % [key, tier])
	return Loc.t(key)


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
	var c := cost().duplicate()
	for t in range(1, tier + 1):  # upgrades are part of what the piece is made of
		for k: String in (_tier_def(t).get("cost", {}) as Dictionary).keys():
			c[StringName(k)] = int(c.get(StringName(k), 0)) + int(_tier_def(t).cost[k])
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
	if tier > 0:  # patch an upgraded piece with what it is made of now
		var tc: Dictionary = _tier_def(tier).get("cost", {})
		if not tc.is_empty():
			return StringName(str(tc.keys()[0]))
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
		return Loc.t("STATUS_BLUEPRINT", {"list": ", ".join(parts)}) + "  ·  " \
			+ Loc.t("STATUS_STAGE", {"n": stages_done(), "total": stage_count()})
	var bits := PackedStringArray()
	match piece_id:
		&"door": bits.append(Loc.t("STATUS_DOOR_OPEN" if door_open else "STATUS_DOOR_CLOSED"))
		&"storage": bits.append(Loc.t("STATUS_STORAGE", {"n": storage.size - storage.free_slots()}))
		&"drying_rack":
			if not drying.is_empty():
				bits.append(Loc.t("STATUS_DRYING", {"n": drying.size()}))
		&"garden_bed":
			bits.append(farm.status_text())
	if health < max_health:
		bits.append(Loc.t("STATUS_HEALTH", {"p": roundi(health / max_health * 100.0)}))
	return " · ".join(bits)


func get_interactions(player: Node) -> Array:
	var inv: Inventory = player.inventory
	var opts: Array = []
	if not built:
		var tool := StringName(str(def.get("tool", "tool_hammer")))  # a garden bed is dug, not hammered
		var has_tool := inv.has_tag(tool)
		var can := can_deliver(inv)
		var text := Loc.t("NEED_%s" % String(tool).to_upper()) if not has_tool else (Loc.t("ACT_DELIVER") if can else Loc.t("ACT_NO_MATERIALS"))
		opts.append({"action": &"interact", "text": text, "hold": 0.6, "enabled": has_tool and can, "op": &"deliver"})
	else:
		var primary := _primary_option(inv)
		if not primary.is_empty():
			opts.append(primary)
		elif health < max_health:
			var item := repair_item()
			opts.append({"action": &"interact", "text": Loc.t("ACT_REPAIR", {"item": ItemDB.get_item(item).display_name()}),
				"hold": 1.0, "enabled": inv.count_of(item) > 0, "op": &"repair"})
		elif tier < max_tier():
			opts.append(_upgrade_option(inv))
	opts.append({"action": &"alt_interact", "text": Loc.t("ACT_DISMANTLE"), "hold": 1.5, "enabled": true, "op": &"dismantle"})
	return opts


## "Upgrade to <next tier> (materials)": hold to rebuild the piece in better material.
func _upgrade_option(inv: Inventory) -> Dictionary:
	var parts := PackedStringArray()
	var c := upgrade_cost()
	for id: StringName in c.keys():
		parts.append("%s %d/%d" % [ItemDB.get_item(id).display_name(), mini(inv.count_of(id), int(c[id])), int(c[id])])
	var key := "BUILD_%s_T%d" % [String(piece_id).to_upper(), tier + 1]
	var text := Loc.t("ACT_UPGRADE", {"name": Loc.t(key) if Loc.has_key(key) else display_name(), "cost": ", ".join(parts)})
	if not inv.has_tag(&"tool_hammer"):
		text = Loc.t("NEED_TOOL_HAMMER")
	return {"action": &"interact", "text": text, "hold": 1.4, "enabled": can_upgrade(inv), "op": &"upgrade"}


func _primary_option(inv: Inventory) -> Dictionary:
	match piece_id:
		&"garden_bed":
			return farm.option(inv)
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
			Sfx.play(&"build", global_position + Vector3.UP)
			if deliver_from(inv):
				Events.toast(Loc.t("MSG_BUILT", {"name": display_name()}), &"good")
				Events.building_completed.emit(self)
		&"repair":
			repair(inv)
		&"upgrade":
			upgrade(inv)
		&"plant", &"water", &"harvest":
			farm.perform(op, player)
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
	if open != door_open and is_inside_tree():
		Sfx.play(&"door", global_position + Vector3.UP)
	door_open = open
	if _hinge:
		var tw := create_tween()
		tw.tween_property(_hinge, "rotation:y", deg_to_rad(-100.0) if open else 0.0, 0.25).set_trans(Tween.TRANS_SINE)


func _dry_ready_index() -> int:
	for i in drying.size():
		if float(drying[i].t) >= DRY_TIME:
			return i
	return -1


func _rained_on() -> bool:
	var w := get_tree().get_first_node_in_group("weather") as Weather if is_inside_tree() else null
	return w != null and w.rain_at(global_position) > 0.1


func simulate(seconds: float) -> void:
	if farm and built:
		farm.grow(seconds, _rained_on())
		return
	if piece_id != &"drying_rack" or drying.is_empty() or _rained_on():
		return
	for d: Dictionary in drying:
		d.t = float(d.t) + seconds
	_refresh()


func _process(delta: float) -> void:
	if farm and built:
		farm.grow(delta, _rained_on())
	if piece_id == &"drying_rack" and not drying.is_empty() and not _rained_on():
		for d: Dictionary in drying:
			d.t = float(d.t) + delta


func _world() -> ForestWorld:
	var n := get_parent()
	while n != null and not n is ForestWorld:
		n = n.get_parent()
	return n as ForestWorld


# ---------------------------------------------------------------- visuals & collision

## Shows delivered construction stages in real material, the rest as a plan. New stages rise into place.
func _refresh(reveal: bool = true) -> void:
	if _visual == null:
		return
	collision_layer = 1 if built else 4
	var n := stages_done()
	BuildingPiece.apply_stages(_visual, n)
	if reveal and _stages_shown >= 0 and n > _stages_shown and is_inside_tree():
		var nodes := BuildingVisuals.stage_nodes(_visual)
		for i in range(_stages_shown, n):
			for s: Node3D in nodes.get(i, []):
				s.scale = Vector3(1, 0.001, 1)
			get_tree().create_timer(0.25 * (i - _stages_shown) + 0.02).timeout.connect(_reveal_stage.bind(i))
	_stages_shown = n
	if _dry_root:
		for c in _dry_root.get_children():
			c.queue_free()
		for i in drying.size():
			var done := float(drying[i].t) >= DRY_TIME
			Graybox.part(_dry_root, Graybox.box(Vector3(0.12, 0.28, 0.05)),
				Color(0.48, 0.29, 0.19) if done else Color(0.66, 0.25, 0.24), Vector3(-0.5 + i * 0.33, -0.2, 0))
	if _hinge:
		_hinge.rotation.y = deg_to_rad(-100.0) if door_open else 0.0


## A construction stage rises into place: grows up from its base, a puff of dust, a knock of the maul.
func _reveal_stage(i: int) -> void:
	if not is_instance_valid(_visual) or not is_inside_tree():
		return
	for s: Node3D in BuildingVisuals.stage_nodes(_visual).get(i, []):
		s.scale = Vector3(1, 0.001, 1)
		create_tween().tween_property(s, "scale", Vector3.ONE, 0.45).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	_dust_puff()
	Sfx.play(&"build", global_position + Vector3.UP, -4.0, 0.15)


func _dust_puff() -> void:
	var p := CPUParticles3D.new()
	p.one_shot = true
	p.explosiveness = 0.85
	p.amount = 14
	p.lifetime = 1.6
	p.emission_shape = CPUParticles3D.EMISSION_SHAPE_BOX
	p.emission_box_extents = Vector3(0.9, 0.3, 0.9)
	p.direction = Vector3.UP
	p.spread = 70.0
	p.initial_velocity_min = 0.3
	p.initial_velocity_max = 1.1
	p.damping_min = 0.8
	p.damping_max = 1.6
	p.gravity = Vector3(0, -0.4, 0)
	p.scale_amount_min = 1.0
	p.scale_amount_max = 2.2
	var fade := Gradient.new()
	fade.set_color(0, Color(0.55, 0.48, 0.38, 0.3))
	fade.set_color(1, Color(0.55, 0.48, 0.38, 0.0))
	p.color_ramp = fade
	p.mesh = TreeNode._puff_quad(0.5)
	add_child(p)
	p.position = Vector3(0, 0.5, 0)
	p.emitting = true
	get_tree().create_timer(p.lifetime + 0.3).timeout.connect(p.queue_free)


## Stage i looks built when i < done, otherwise like a translucent plan.
static func apply_stages(root: Node, done: int) -> void:
	var nodes := BuildingVisuals.stage_nodes(root)
	for i: int in nodes:
		for s: Node in nodes[i]:
			BuildingPiece.apply_look(s, &"built" if i < done else &"blueprint")


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


func _rebuild_collision() -> void:
	for c in get_children():
		if c is CollisionShape3D:
			remove_child(c)
			c.queue_free()
	_door_shape = null
	_build_collision()


func _build_collision() -> void:
	var th: float = [0.16, 0.24, 0.3][clampi(tier, 0, 2)]  # wattle, logs, stone
	match piece_id:
		&"foundation":
			Graybox.add_shape(self, Graybox.box_shape(Vector3(GRID, FOUNDATION_H, GRID)), Vector3(0, FOUNDATION_H * 0.5, 0))
		&"wall":
			Graybox.add_shape(self, Graybox.box_shape(Vector3(GRID, WALL_H, th)), Vector3(0, WALL_H * 0.5, 0))
		&"half_wall":
			var hh := BuildingVisuals.HALF_WALL_H
			Graybox.add_shape(self, Graybox.box_shape(Vector3(GRID, hh, th)), Vector3(0, hh * 0.5, 0))
		&"doorway":
			var side := (GRID - DOOR_W) * 0.5
			for sx in [-1.0, 1.0]:
				Graybox.add_shape(self, Graybox.box_shape(Vector3(side, WALL_H, th)), Vector3(sx * (DOOR_W + side) * 0.5, WALL_H * 0.5, 0))
			Graybox.add_shape(self, Graybox.box_shape(Vector3(DOOR_W, WALL_H - DOOR_H, th)), Vector3(0, (WALL_H + DOOR_H) * 0.5, 0))
		&"window_wall":
			var w := BuildingVisuals.WINDOW
			for r: Rect2 in BuildingVisuals._rects_minus(Rect2(-GRID * 0.5, 0.0, GRID, WALL_H), w):
				Graybox.add_shape(self, Graybox.box_shape(Vector3(r.size.x, r.size.y, th)), Vector3(r.get_center().x, r.get_center().y, 0))
		&"gable":
			var pts := PackedVector3Array()
			for z: float in [-0.07, 0.07]:
				for p: Vector2 in [Vector2(-1.0, 0.0), Vector2(1.0, 0.0), Vector2(0.0, BuildingVisuals.RIDGE_Y - 0.1)]:
					pts.append(Vector3(p.x, p.y, z))
			var shape := ConvexPolygonShape3D.new()
			shape.points = pts
			Graybox.add_shape(self, shape)
		&"door":
			# Swings with the hinge: transform synced in _physics_process.
			_door_shape = Graybox.add_shape(self, Graybox.box_shape(Vector3(DOOR_W - 0.06, DOOR_H - 0.04, 0.08)))
			_physics_process(0.0)
		&"pillar":
			Graybox.add_shape(self, Graybox.cyl_shape(0.14 if tier == 0 else 0.2, WALL_H), Vector3(0, WALL_H * 0.5, 0))
		&"roof":
			# Two pitched slopes, eave to ridge (see BuildingVisuals._roof).
			var run := BuildingVisuals.EAVE_Z
			var rise := BuildingVisuals.RIDGE_Y - BuildingVisuals.EAVE_Y
			var pitch := atan2(rise, run)
			for side: float in [-1.0, 1.0]:
				var n := Vector3(0, run, side * rise).normalized()
				var c := Vector3(0, BuildingVisuals.EAVE_Y + rise * 0.5, side * run * 0.5) + n * 0.12
				Graybox.add_shape(self, Graybox.box_shape(Vector3(BuildingVisuals.ROOF_HALF_X * 2.0, 0.2, Vector2(run, rise).length())),
					c, Vector3(rad_to_deg(side * pitch), 0, 0))
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


## Visual for a piece (also used for ghost previews): procedural, staged and tiered -- see BuildingVisuals.
static func build_visual(id: StringName, p_tier: int = 0, seed: int = 0) -> Node3D:
	return BuildingVisuals.build(id, p_tier, seed)


# ---------------------------------------------------------------- persistence

func save_state() -> Dictionary:
	var dl := {}
	for id: StringName in delivered.keys():
		dl[String(id)] = delivered[id]
	var dr: Array = []
	for d: Dictionary in drying:
		dr.append({"id": String(d.id), "t": d.t})
	var out := {"piece": String(piece_id), "built": built, "delivered": dl, "health": health,
		"on": supported_by.duplicate(), "door_open": door_open, "drying": dr, "tier": tier}
	if storage:
		out["storage"] = storage.to_dict()
	if farm:
		out["farm"] = farm.save_state()
	return out


func load_state(d: Dictionary) -> void:
	built = bool(d.get("built", false))
	var t := clampi(int(d.get("tier", tier)), 0, max_tier())
	if t != tier:
		tier = t
		max_health = _tier_health()
		if is_inside_tree():
			_make_visual()
			_rebuild_collision()
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
	if farm and d.has("farm"):
		farm.load_state(d.farm)
	_refresh(false)  # restored pieces stand as they were; only live construction animates
