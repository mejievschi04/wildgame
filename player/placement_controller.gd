class_name PlacementController
extends Node
## Ghost preview placement for placeable items (campfire, bed). Phase 2 extends this into the
## modular building system (snapping, foundations, structural support).

const RANGE := 5.0
const MAX_SLOPE_DOT := 0.82  # min normal.y
const FOOTPRINTS := {&"campfire": Vector3(1.4, 0.6, 1.4), &"bed": Vector3(1.0, 0.5, 2.1)}

var player: Player
var active := false
var valid := false
var structure: StringName = &""
var item_id: StringName = &""
var slot := -1
var yaw_offset := 0.0
var _ghost: Node3D
var _ghost_mat: StandardMaterial3D
var _xform := Transform3D.IDENTITY


func begin(p_slot: int, data: ItemData) -> void:
	cancel()
	player.build.cancel()
	slot = p_slot
	item_id = data.id
	structure = data.place
	yaw_offset = 0.0
	active = true
	_ghost_mat = StandardMaterial3D.new()
	_ghost_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_ghost_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_ghost = Node3D.new()
	var mi := MeshInstance3D.new()
	mi.mesh = Graybox.box(FOOTPRINTS.get(structure, Vector3.ONE))
	mi.material_override = _ghost_mat
	mi.position.y = FOOTPRINTS.get(structure, Vector3.ONE).y * 0.5
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_ghost.add_child(mi)
	player.get_tree().current_scene.add_child(_ghost)
	Events.toast(Loc.t("HINT_PLACEMENT", {
		"place": InputSetup.label(&"primary_action"), "rotate": InputSetup.label(&"alt_interact"),
		"cancel": InputSetup.label(&"secondary_action")}), &"info")


func cancel() -> void:
	active = false
	if _ghost:
		_ghost.queue_free()
		_ghost = null


func _physics_process(_delta: float) -> void:
	if not active:
		return
	if Input.is_action_just_pressed("alt_interact"):
		yaw_offset += PI / 8.0
	# Item may have been moved/dropped meanwhile.
	var s := player.inventory.get_slot(slot)
	if s == null or s.id != item_id:
		cancel()
		return
	var cam := player.camera
	var from := cam.global_position
	var to := from - cam.global_transform.basis.z * RANGE
	var q := PhysicsRayQueryParameters3D.create(from, to, 1)
	q.exclude = [player.get_rid()]
	var hit := player.get_world_3d().direct_space_state.intersect_ray(q)
	if hit.is_empty():
		# Project down from max range.
		q = PhysicsRayQueryParameters3D.create(to + Vector3.UP * 2.0, to + Vector3.DOWN * 6.0, 1)
		hit = player.get_world_3d().direct_space_state.intersect_ray(q)
	if hit.is_empty():
		valid = false
		_ghost.visible = false
		return
	_ghost.visible = true
	var pos: Vector3 = hit.position
	var normal: Vector3 = hit.normal
	var yaw := player.rotation.y + yaw_offset
	_xform = Transform3D(Basis(Vector3.UP, yaw), pos)
	_ghost.global_transform = _xform
	valid = normal.y >= MAX_SLOPE_DOT and pos.y > ForestWorld.WATER_LEVEL + 0.15 \
		and hit.collider is Node and (hit.collider as Node).is_in_group("terrain") \
		and _footprint_clear(pos, yaw) and pos.distance_to(player.global_position) > 0.9
	_ghost_mat.albedo_color = Color(0.4, 0.85, 0.45, 0.4) if valid else Color(0.9, 0.3, 0.25, 0.4)


func _footprint_clear(pos: Vector3, yaw: float) -> bool:
	var size: Vector3 = FOOTPRINTS.get(structure, Vector3.ONE)
	var shape := BoxShape3D.new()
	shape.size = size * Vector3(0.95, 0.8, 0.95)
	var q := PhysicsShapeQueryParameters3D.new()
	q.shape = shape
	q.transform = Transform3D(Basis(Vector3.UP, yaw), pos + Vector3(0, size.y * 0.5 + 0.25, 0))
	q.collision_mask = 1 | 2 | 4
	var hits := player.get_world_3d().direct_space_state.intersect_shape(q, 8)
	for h: Dictionary in hits:
		var c: Node = h.collider
		if c == null or c.is_in_group("terrain"):
			continue
		return false
	return true


func confirm() -> void:
	if not active:
		return
	if not valid:
		Events.toast(Loc.t("MSG_CANNOT_PLACE"), &"warn")
		return
	var s := player.inventory.get_slot(slot)
	if s == null or s.id != item_id:
		cancel()
		return
	player.inventory.take_from_slot(slot, 1)
	player.world.spawn_structure(structure, _xform)
	cancel()
