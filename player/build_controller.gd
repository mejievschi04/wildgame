class_name BuildController
extends Node
## Build mode: ghost preview of a building piece with snapping and placement validation.
## Placing creates a BLUEPRINT (no cost yet); materials are delivered afterwards (GDD §9 "resources
## delivered in stages"). Evaluation is a pure function of (aim, yaw) → testable headless.

const RANGE := 7.0
const SOCKET_RADIUS := 2.2
const GHOST_OK := Color(0.45, 0.85, 0.5, 0.42)
const GHOST_BAD := Color(0.92, 0.36, 0.3, 0.42)
## Pieces that compete for the same socket.
const OCCUPANCY := {"wall": "wall", "fence": "wall", "pillar": "pillar", "roof": "roof", "door": "door", "floor": "floor", "gable": "gable"}

var player: Player
var active := false
var piece_id: StringName = &""
var def: Dictionary = {}
var snap := true
var yaw_offset := 0.0
var valid := false
var reason := ""
var _ghost: Node3D
var _ghost_mat: StandardMaterial3D
var _xform := Transform3D.IDENTITY
var _supports: Array[String] = []


func world() -> ForestWorld:
	return player.world


func begin(id: StringName) -> void:
	cancel()
	player.placement.cancel()
	piece_id = id
	def = ItemDB.get_piece(id)
	active = true
	yaw_offset = 0.0
	_ghost_mat = StandardMaterial3D.new()
	_ghost_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_ghost_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_ghost = BuildingPiece.build_visual(id)
	BuildingPiece.apply_look(_ghost, &"ghost", _ghost_mat)
	player.get_tree().current_scene.add_child(_ghost)
	_ghost.visible = false


func cancel() -> void:
	active = false
	valid = false
	if _ghost:
		_ghost.queue_free()
		_ghost = null


func toggle_snap() -> void:
	snap = not snap


func _physics_process(_delta: float) -> void:
	if not active:
		return
	if Input.is_action_just_pressed("alt_interact"):
		yaw_offset += PI / 8.0
	if Input.is_action_just_pressed("toggle_snap"):
		toggle_snap()
	var aim := _aim()
	var res := evaluate(aim.pos, aim.normal, aim.collider, player.rotation.y + yaw_offset)
	valid = res.valid
	reason = res.reason
	_xform = res.xform
	_supports.assign(res.supports)
	_ghost.visible = true
	_ghost.global_transform = _xform
	_ghost_mat.albedo_color = GHOST_OK if valid else GHOST_BAD


func confirm() -> BuildingPiece:
	if not active:
		return null
	if not valid:
		Events.toast(reason, &"warn")
		return null
	var p: BuildingPiece = world().spawn_structure(&"piece", _xform, {"piece": String(piece_id), "on": _supports.duplicate()})
	Events.building_placed.emit(p)
	return p


func _aim() -> Dictionary:
	var cam := player.camera
	var from := cam.global_position
	var fwd := -cam.global_transform.basis.z
	var q := PhysicsRayQueryParameters3D.create(from, from + fwd * RANGE, 1 | 4)
	q.exclude = [player.get_rid()]
	var hit := player.get_world_3d().direct_space_state.intersect_ray(q)
	if hit.is_empty():
		var p := from + fwd * 4.0
		return {"pos": Vector3(p.x, world().height_at(p.x, p.z), p.z), "normal": Vector3.UP, "collider": null}
	return {"pos": hit.position, "normal": hit.normal, "collider": hit.collider}


# ---------------------------------------------------------------- evaluation

func _result(xf: Transform3D, ok: bool, why: String = "", supports: Array = []) -> Dictionary:
	return {"valid": ok, "reason": why, "xform": xf, "supports": supports}


func evaluate(aim: Vector3, normal: Vector3, collider: Object, yaw: float) -> Dictionary:
	var mode := str(def.get("snap", "ground"))
	var res: Dictionary
	match mode:
		"ground_grid":
			res = _eval_foundation(aim, yaw)
		"edge", "corner", "top", "doorway", "gable":
			res = _eval_socket(mode, aim)
		"ground_or_floor":
			if collider is BuildingPiece and (collider as BuildingPiece).piece_id == &"foundation" and normal.y > 0.9:
				res = _eval_on_floor(aim, collider as BuildingPiece, yaw)
			else:
				res = _eval_ground(aim, normal, collider, yaw)
		_:
			res = _eval_ground(aim, normal, collider, yaw)
	if res.valid and _overlaps_player(res.xform):
		res.valid = false
		res.reason = Loc.t("BUILD_INVALID_TOO_CLOSE")
	return res


func _eval_foundation(aim: Vector3, yaw: float) -> Dictionary:
	var w := world()
	var xf := Transform3D()
	var snapped := false
	if snap:
		var best_d := INF
		for f in w.pieces_near(aim, 4.5):
			if f.piece_id != &"foundation":
				continue
			var b := f.global_transform.basis
			for off: Vector3 in [Vector3(BuildingPiece.GRID, 0, 0), Vector3(-BuildingPiece.GRID, 0, 0),
					Vector3(0, 0, BuildingPiece.GRID), Vector3(0, 0, -BuildingPiece.GRID)]:
				var p := f.global_position + b * off
				var d := Vector2(p.x, p.z).distance_to(Vector2(aim.x, aim.z))
				if d < best_d:
					best_d = d
					xf = Transform3D(b, p)
		snapped = best_d < 2.0
	if not snapped:
		var basis := Basis(Vector3.UP, yaw)
		var top := -INF
		for c: Vector3 in _corners(basis, aim):
			top = maxf(top, w.height_at(c.x, c.z))
		xf = Transform3D(basis, Vector3(aim.x, top - 0.1, aim.z))
	for f in w.pieces_near(xf.origin, 1.0):
		if f.piece_id == &"foundation" and f.global_position.distance_to(xf.origin) < 0.6:
			return _result(xf, false, Loc.t("BUILD_INVALID_BLOCKED"))
	var y := xf.origin.y
	if w.height_at(xf.origin.x, xf.origin.z) < ForestWorld.WATER_LEVEL + 0.1:
		return _result(xf, false, Loc.t("BUILD_INVALID_WATER"))
	for c: Vector3 in _corners(xf.basis, xf.origin) + [xf.origin]:
		var h := w.height_at(c.x, c.z)
		if h > y + 0.25 or h < y - 1.9:
			return _result(xf, false, Loc.t("BUILD_INVALID_GROUND"))
	if _blocked(xf, Vector3(1.9, 0.3, 1.9), [], true):
		return _result(xf, false, Loc.t("BUILD_INVALID_BLOCKED"))
	return _result(xf, true)


func _corners(basis: Basis, center: Vector3) -> Array:
	var out: Array = []
	for sx in [-0.95, 0.95]:
		for sz in [-0.95, 0.95]:
			out.append(center + basis * Vector3(sx, 0, sz))
	return out


## All candidate sockets for a mode near the aim point: [{xform, supports}].
func find_sockets(mode: String, aim: Vector3) -> Array:
	var w := world()
	var out: Array = []
	if mode == "doorway":
		for d in w.pieces_near(aim, 5.0):
			if d.piece_id == &"doorway":
				out.append({"xform": d.global_transform, "supports": [d.structure_id]})
		return out
	if mode == "gable":
		# Gable ends close the triangle under a pitched roof, at both ends of its ridge (local +-X).
		for r in w.pieces_near(aim, 5.0):
			if r.piece_id != &"roof":
				continue
			var rb := r.global_transform.basis
			for sx: float in [-1.0, 1.0]:
				out.append({"xform": Transform3D(Basis(Vector3.UP, r.global_rotation.y + PI * 0.5), r.global_position + rb * Vector3(sx, 0, 0)),
					"supports": [r.structure_id]})
		return out
	for f in w.pieces_near(aim, 5.0):
		if f.piece_id != &"foundation":
			continue
		var b := f.global_transform.basis
		var top := f.global_position + b.y.normalized() * BuildingPiece.FOUNDATION_H
		var yaw := f.global_rotation.y
		match mode:
			"edge":
				for e: Array in [[Vector3(0, 0, -1), 0.0], [Vector3(0, 0, 1), 0.0], [Vector3(1, 0, 0), PI * 0.5], [Vector3(-1, 0, 0), PI * 0.5]]:
					out.append({"xform": Transform3D(Basis(Vector3.UP, yaw + e[1]), top + b * e[0]), "supports": [f.structure_id]})
			"corner":
				for sx in [-0.88, 0.88]:
					for sz in [-0.88, 0.88]:
						out.append({"xform": Transform3D(Basis(Vector3.UP, yaw), top + b * Vector3(sx, 0, sz)), "supports": [f.structure_id]})
			"top":
				var sup: Array = []
				for d in w.dependents_of(f):
					if d.provides_support():
						sup.append(d.structure_id)
				out.append({"xform": Transform3D(Basis(Vector3.UP, yaw), top + Vector3.UP * BuildingPiece.WALL_H),
					"supports": sup, "ok": sup.size() >= 2})
	return out


func _eval_socket(mode: String, aim: Vector3) -> Dictionary:
	var best: Dictionary = {}
	var best_d := INF
	for s: Dictionary in find_sockets(mode, aim):
		var d := (s.xform as Transform3D).origin.distance_to(aim)
		if mode == "top":
			d = Vector2(s.xform.origin.x, s.xform.origin.z).distance_to(Vector2(aim.x, aim.z))
		if d < best_d:
			best_d = d
			best = s
	var fallback := Transform3D(Basis(Vector3.UP, player.rotation.y if player else 0.0), aim)
	if best.is_empty() or best_d > SOCKET_RADIUS:
		var why := "BUILD_INVALID_NO_DOORWAY" if mode == "doorway" else ("BUILD_INVALID_NO_ROOF" if mode == "gable" else "BUILD_INVALID_NO_SOCKET")
		return _result(fallback, false, Loc.t(why))
	var xf: Transform3D = best.xform
	if not best.get("ok", true):
		return _result(xf, false, Loc.t("BUILD_INVALID_NO_SUPPORT"), best.supports)
	if _socket_occupied(xf.origin):
		return _result(xf, false, Loc.t("BUILD_INVALID_BLOCKED"), best.supports)
	return _result(xf, true, "", best.supports)


func _socket_occupied(pos: Vector3) -> bool:
	var mine: String = OCCUPANCY.get(str(def.get("class", "")), str(def.get("class", "")))
	for p in world().pieces_near(pos, 1.0):
		var theirs: String = OCCUPANCY.get(p.piece_class(), p.piece_class())
		if theirs == mine and p.global_position.distance_to(pos) < 0.3:
			return true
	return false


func _footprint() -> Vector3:
	var fp: Array = def.get("footprint", [1.0, 1.0, 1.0])
	return Vector3(float(fp[0]), float(fp[1]), float(fp[2]))


func _eval_ground(aim: Vector3, normal: Vector3, collider: Object, yaw: float) -> Dictionary:
	var xf := Transform3D(Basis(Vector3.UP, yaw), aim)
	if collider != null and not (collider is Node and (collider as Node).is_in_group("terrain")):
		return _result(xf, false, Loc.t("BUILD_INVALID_GROUND"))
	if normal.y < 0.78:
		return _result(xf, false, Loc.t("BUILD_INVALID_GROUND"))
	if aim.y < ForestWorld.WATER_LEVEL + 0.1:
		return _result(xf, false, Loc.t("BUILD_INVALID_WATER"))
	if _blocked(xf, _footprint(), [], false):
		return _result(xf, false, Loc.t("BUILD_INVALID_BLOCKED"))
	return _result(xf, true)


func _eval_on_floor(aim: Vector3, floor_piece: BuildingPiece, yaw: float) -> Dictionary:
	var xf := Transform3D(Basis(Vector3.UP, yaw), aim)
	var local := floor_piece.global_transform.affine_inverse() * aim
	var fp := _footprint()
	var half := maxf(fp.x, fp.z) * 0.5
	if absf(local.x) > 1.0 - half * 0.5 or absf(local.z) > 1.0 - half * 0.5:
		return _result(xf, false, Loc.t("BUILD_INVALID_BLOCKED"))
	if _blocked(xf, fp, [floor_piece.get_rid()], false):
		return _result(xf, false, Loc.t("BUILD_INVALID_BLOCKED"))
	return _result(xf, true, "", [floor_piece.structure_id])


## Footprint overlap against world obstacles (trees, rocks, structures). Terrain is ignored.
func _blocked(xf: Transform3D, size: Vector3, exclude: Array, ignore_building: bool) -> bool:
	var shape := BoxShape3D.new()
	shape.size = size * Vector3(0.9, 0.8, 0.9)
	var q := PhysicsShapeQueryParameters3D.new()
	q.shape = shape
	q.transform = Transform3D(xf.basis, xf.origin + Vector3.UP * (size.y * 0.5 + 0.08))
	q.collision_mask = 1 | 4
	q.exclude = exclude
	for h: Dictionary in player.get_world_3d().direct_space_state.intersect_shape(q, 16):
		var c: Node = h.collider
		if c == null or c.is_in_group("terrain") or c is WorldPickup:
			continue
		if ignore_building and c is BuildingPiece:
			continue
		return true
	return false


func _overlaps_player(xf: Transform3D) -> bool:
	if str(def.get("snap", "")) in ["top", "gable"]:
		return false
	var size := _footprint()
	if piece_id == &"foundation":
		size = Vector3(2.0, 0.3, 2.0)
	elif str(def.get("snap", "")) in ["edge", "corner", "doorway"]:
		size = Vector3(2.0 if piece_id != &"pillar" else 0.3, 2.2, 0.2)
	var shape := BoxShape3D.new()
	shape.size = size
	var q := PhysicsShapeQueryParameters3D.new()
	q.shape = shape
	q.transform = Transform3D(xf.basis, xf.origin + Vector3.UP * (size.y * 0.5))
	q.collision_mask = 2
	return not player.get_world_3d().direct_space_state.intersect_shape(q, 1).is_empty()
