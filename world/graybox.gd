class_name Graybox
extends RefCounted
## PLACEHOLDER art helpers: cached primitive meshes/materials for the graybox phase.
## Everything built here is placeholder geometry and must be replaced by SM_* assets (see docs/ASSET_BIBLE.md).

static var _materials: Dictionary = {}
static var _meshes: Dictionary = {}


static func mat(color: Color, roughness: float = 0.9, emission: float = 0.0) -> StandardMaterial3D:
	var key := "%s|%.2f|%.2f" % [color.to_html(), roughness, emission]
	if _materials.has(key):
		return _materials[key]
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.roughness = roughness
	if color.a < 1.0:
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	if emission > 0.0:
		m.emission_enabled = true
		m.emission = color
		m.emission_energy_multiplier = emission
	_materials[key] = m
	return m


## Scanned CC0 PBR materials (assets/textures/materials), object-space triplanar so primitives
## of any size get correctly scaled texture. scale = texture repeats per metre.
static func tex(name: String, tint: Color = Color.WHITE, scale: float = 1.0) -> StandardMaterial3D:
	var key := "tex|%s|%s|%.2f" % [name, tint.to_html(), scale]
	if _materials.has(key):
		return _materials[key]
	var base := "res://assets/textures/materials/T_%s_" % name
	var m := StandardMaterial3D.new()
	m.albedo_texture = load(base + "diff.jpg")
	m.albedo_color = tint
	m.normal_enabled = true
	m.normal_texture = load(base + "nor_gl.jpg")
	m.roughness_texture = load(base + "arm.jpg")
	m.roughness_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_GREEN
	m.ao_enabled = true
	m.ao_texture = load(base + "arm.jpg")
	m.ao_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_RED
	m.uv1_triplanar = true
	m.uv1_scale = Vector3.ONE * scale
	m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	_materials[key] = m
	return m


static func part_mat(parent: Node3D, mesh: Mesh, material: Material, pos: Vector3 = Vector3.ZERO,
		rot_deg: Vector3 = Vector3.ZERO, scl: Vector3 = Vector3.ONE) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = material
	mi.position = pos
	mi.rotation_degrees = rot_deg
	mi.scale = scl
	parent.add_child(mi)
	return mi


static func cylinder(top: float, bottom: float, height: float, segments: int = 8) -> CylinderMesh:
	var key := "cyl|%.3f|%.3f|%.3f|%d" % [top, bottom, height, segments]
	if not _meshes.has(key):
		var c := CylinderMesh.new()
		c.top_radius = top
		c.bottom_radius = bottom
		c.height = height
		c.radial_segments = segments
		c.rings = 1
		_meshes[key] = c
	return _meshes[key]


static func sphere(radius: float, segments: int = 10) -> SphereMesh:
	var key := "sph|%.3f|%d" % [radius, segments]
	if not _meshes.has(key):
		var s := SphereMesh.new()
		s.radius = radius
		s.height = radius * 2.0
		s.radial_segments = segments
		s.rings = maxi(segments / 2, 3)
		_meshes[key] = s
	return _meshes[key]


static func box(size: Vector3) -> BoxMesh:
	var key := "box|%s" % size
	if not _meshes.has(key):
		var b := BoxMesh.new()
		b.size = size
		_meshes[key] = b
	return _meshes[key]


static func part(parent: Node3D, mesh: Mesh, color: Color, pos: Vector3 = Vector3.ZERO,
		rot_deg: Vector3 = Vector3.ZERO, scl: Vector3 = Vector3.ONE, roughness: float = 0.9) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat(color, roughness)
	mi.position = pos
	mi.rotation_degrees = rot_deg
	mi.scale = scl
	parent.add_child(mi)
	return mi


static func add_shape(body: CollisionObject3D, shape: Shape3D, pos: Vector3 = Vector3.ZERO,
		rot_deg: Vector3 = Vector3.ZERO) -> CollisionShape3D:
	var cs := CollisionShape3D.new()
	cs.shape = shape
	cs.position = pos
	cs.rotation_degrees = rot_deg
	body.add_child(cs)
	return cs


static func box_shape(size: Vector3) -> BoxShape3D:
	var s := BoxShape3D.new()
	s.size = size
	return s


static func cyl_shape(radius: float, height: float) -> CylinderShape3D:
	var s := CylinderShape3D.new()
	s.radius = radius
	s.height = height
	return s
