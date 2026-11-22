class_name AssetLib
extends RefCounted
## Loads processed art (assets/models/**.gltf) with caching and engine-side material tuning:
## alpha-scissor foliage gets translucency (backlight) and soft shadows-friendly settings.
## Art lists live here so gameplay code asks for "a spruce" rather than a file path.

const TREES := {
	&"spruce": ["res://assets/models/trees/SM_Spruce_01.gltf", "res://assets/models/trees/SM_Spruce_02.gltf",
		"res://assets/models/trees/SM_Spruce_03.gltf"],
	&"pine": ["res://assets/models/trees/SM_Pine_01.gltf", "res://assets/models/trees/SM_Pine_02.gltf"],
	&"alder": ["res://assets/models/trees/SM_Alder_01.gltf", "res://assets/models/trees/SM_Alder_02.gltf"],
	&"stump": ["res://assets/models/trees/SM_Stump_01.gltf", "res://assets/models/trees/SM_Stump_02.gltf"],
	&"dead_trunk": ["res://assets/models/trees/SM_DeadTrunk_01.gltf"],
}
const ROCKS := {
	&"big": ["res://assets/models/rocks/SM_RockMoss_A01.gltf", "res://assets/models/rocks/SM_RockMoss_A02.gltf",
		"res://assets/models/rocks/SM_RockMoss_A03.gltf", "res://assets/models/rocks/SM_RockMoss_A04.gltf",
		"res://assets/models/rocks/SM_RockMoss_A05.gltf", "res://assets/models/rocks/SM_RockMoss_A06.gltf",
		"res://assets/models/rocks/SM_Boulder_01.gltf"],
	&"medium": ["res://assets/models/rocks/SM_RockMoss_B01.gltf", "res://assets/models/rocks/SM_RockMoss_B02.gltf",
		"res://assets/models/rocks/SM_RockMoss_B03.gltf", "res://assets/models/rocks/SM_RockMoss_B04.gltf",
		"res://assets/models/rocks/SM_RockMoss_B05.gltf", "res://assets/models/rocks/SM_RockMoss_B06.gltf",
		"res://assets/models/rocks/SM_RockMoss_B07.gltf"],
	&"small": ["res://assets/models/rocks/SM_Stone_01.gltf", "res://assets/models/rocks/SM_Stone_07.gltf",
		"res://assets/models/rocks/SM_Stone_09.gltf"],
}
const PLANTS := {
	&"fern": ["res://assets/models/plants/SM_Fern_01.gltf", "res://assets/models/plants/SM_Fern_02.gltf",
		"res://assets/models/plants/SM_Fern_03.gltf", "res://assets/models/plants/SM_Fern_04.gltf"],
	&"shrub": ["res://assets/models/plants/SM_Shrub04_01.gltf", "res://assets/models/plants/SM_Shrub03_01.gltf",
		"res://assets/models/plants/SM_Shrub03_02.gltf"],
	&"grass": ["res://assets/models/plants/SM_Grass_01.gltf", "res://assets/models/plants/SM_Grass_02.gltf",
		"res://assets/models/plants/SM_Grass_03.gltf", "res://assets/models/plants/SM_Grass_06.gltf"],
	&"branches": ["res://assets/models/ground/SM_Branches_01.gltf", "res://assets/models/ground/SM_Branches_02.gltf",
		"res://assets/models/ground/SM_Branches_03.gltf"],
}
const PROPS := {
	&"fire_pit": "res://assets/models/props/SM_StoneFirePit_01.gltf",
	&"basket": "res://assets/models/props/SM_WickerBasket_01.gltf",
}

static var _scenes: Dictionary = {}
static var _tuned: Dictionary = {}  # [original material, profile] -> tuned material
static var _icons: Dictionary = {}
const FOLIAGE_SHADER := preload("res://world/shaders/foliage.gdshader")


static func pick(list: Array, key: String) -> String:
	return list[absi(hash(key)) % list.size()]


static func scene(path: String) -> PackedScene:
	if not _scenes.has(path):
		_scenes[path] = load(path)
	return _scenes[path]


## Instantiates an asset with tuned materials. Returns a Node3D (no collision).
static func instance(path: String) -> Node3D:
	var ps := scene(path)
	if ps == null:
		push_error("AssetLib: cannot load %s" % path)
		return Node3D.new()
	var n: Node3D = ps.instantiate()
	var profile: StringName = &"tree" if "/trees/" in path else &"ground"
	for mi: MeshInstance3D in n.find_children("*", "MeshInstance3D", true, false):
		for s in mi.mesh.get_surface_count():
			var m := mi.mesh.surface_get_material(s)
			var t := tuned(m, profile)
			if t != m:
				mi.set_surface_override_material(s, t)
	return n


## MultiMesh has no per-surface overrides. Copy the instance's materials onto a local mesh.
static func mesh(path: String) -> Mesh:
	var n := instance(path)
	var mi: MeshInstance3D = n.find_children("*", "MeshInstance3D", true, false)[0]
	var m := mi.mesh.duplicate() as Mesh
	for surface in m.get_surface_count():
		m.surface_set_material(surface, mi.get_active_material(surface))
	n.free()
	return m


## Alpha-scissor materials become wind-animated foliage ShaderMaterials.
## profile: &"tree" (tall, slow sway) or &"ground" (grass/ferns/shrubs, small flutter).
static func tuned(m: Material, profile: StringName = &"ground") -> Material:
	if not m is BaseMaterial3D:
		return m
	var key := [m, profile]
	if _tuned.has(key):
		return _tuned[key]
	var b := m as BaseMaterial3D
	var out: Material = b
	if b.transparency == BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR:
		var f := ShaderMaterial.new()
		f.shader = FOLIAGE_SHADER
		f.set_shader_parameter("albedo_tex", b.albedo_texture)
		f.set_shader_parameter("albedo_tint", b.albedo_color)
		f.set_shader_parameter("alpha_cut", 0.42)
		if b.normal_enabled and b.normal_texture:
			f.set_shader_parameter("normal_tex", b.normal_texture)
			f.set_shader_parameter("use_normal", true)
		if profile == &"tree":
			f.set_shader_parameter("sway", 0.7)
			f.set_shader_parameter("height_ref", 14.0)
		else:
			f.set_shader_parameter("sway", 0.12)
			f.set_shader_parameter("height_ref", 0.35)
		out = f
	_tuned[key] = out
	return out


## Item model / icon by convention (generated by tools/blender/gen_items.py).
static func item_model_path(id: StringName) -> String:
	var p := "res://assets/models/items/SM_Item_%s.gltf" % id
	return p if ResourceLoader.exists(p) else ""


static func item_icon(id: StringName) -> Texture2D:
	var p := "res://assets/icons/T_Icon_%s.png" % id
	if not _icons.has(p):
		_icons[p] = load(p) if ResourceLoader.exists(p) else null
	return _icons[p]


## Local AABB of an instantiated asset (merged over its meshes).
static func aabb(root: Node3D) -> AABB:
	var box := AABB()
	var first := true
	for mi: MeshInstance3D in root.find_children("*", "MeshInstance3D", true, false):
		var b := mi.transform * mi.get_aabb()
		box = b if first else box.merge(b)
		first = false
	return box
