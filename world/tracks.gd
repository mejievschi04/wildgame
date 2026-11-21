class_name Tracks
extends Node3D
## Footprint decals left by animals (GDD §6 "urmărirea urmelor"). Players can read species and age.

const MAX := 320
const LIFETIME := 1800.0  # simulated seconds (~1.25 game days at 24 min/day)

var _tracks: Array = []  # {species, pos, yaw, born, decal}
var _time := 0.0
var _left := false
static var _textures: Dictionary = {}


func _ready() -> void:
	add_to_group("time_sim")


func add(species: StringName, kind: String, pos: Vector3, yaw: float) -> void:
	_left = not _left
	var sc0 := float(ItemDB.get_animal(species).get("track_scale", 1.0)) if ItemDB.animals.has(species) else 1.0
	var side := Vector3(cos(yaw), 0, -sin(yaw)) * (0.11 if _left else -0.11) * sc0
	var p := pos + side
	var d := Decal.new()
	d.texture_albedo = _texture(kind)
	d.size = Vector3(0.16, 0.5, 0.2) if kind == "hoof" else Vector3(0.14, 0.5, 0.16)
	var sc := float(ItemDB.get_animal(species).get("track_scale", 1.0)) if ItemDB.animals.has(species) else 1.0
	d.size *= Vector3(sc, 1.0, sc)
	d.modulate = Color(0.16, 0.12, 0.09, 0.85)
	d.distance_fade_enabled = true
	d.distance_fade_begin = 22.0
	d.distance_fade_length = 8.0
	d.cull_mask = 1
	add_child(d)
	d.global_position = p + Vector3.UP * 0.15
	d.rotation.y = yaw
	_tracks.append({"species": species, "pos": p, "yaw": yaw, "born": _time, "decal": d})
	while _tracks.size() > MAX:
		var old: Dictionary = _tracks.pop_front()
		(old.decal as Node).queue_free()


func _process(delta: float) -> void:
	simulate(delta)


func simulate(seconds: float) -> void:
	_time += seconds
	var i := 0
	while i < _tracks.size():
		var t: Dictionary = _tracks[i]
		var age := _time - float(t.born)
		if age > LIFETIME:
			(t.decal as Node).queue_free()
			_tracks.remove_at(i)
			continue
		(t.decal as Decal).modulate.a = 0.85 * (1.0 - age / LIFETIME)
		i += 1


## Nearest footprint within radius: {species, age (s), yaw} or {}.
func nearest(pos: Vector3, radius: float = 0.8) -> Dictionary:
	var best := {}
	var best_d := radius
	for t: Dictionary in _tracks:
		var d := Vector2(pos.x, pos.z).distance_to(Vector2(t.pos.x, t.pos.z))
		if d < best_d:
			best_d = d
			best = {"species": t.species, "age": _time - float(t.born), "yaw": t.yaw}
	return best


func count() -> int:
	return _tracks.size()


static func _texture(kind: String) -> Texture2D:
	if _textures.has(kind):
		return _textures[kind]
	var img := Image.create(64, 64, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var blobs: Array = []
	if kind == "hoof":
		blobs = [[Vector2(24, 30), Vector2(7, 18)], [Vector2(40, 30), Vector2(7, 18)]]
	elif kind == "pad":  # elephant-like round footprint
		blobs = [[Vector2(32, 32), Vector2(24, 26)]]
	else:
		blobs = [[Vector2(32, 40), Vector2(11, 10)], [Vector2(20, 22), Vector2(4, 5)], [Vector2(28, 16), Vector2(4, 5)],
			[Vector2(36, 16), Vector2(4, 5)], [Vector2(44, 22), Vector2(4, 5)]]
	for y in 64:
		for x in 64:
			var a := 0.0
			for b: Array in blobs:
				var c: Vector2 = b[0]
				var r: Vector2 = b[1]
				var q := Vector2((x - c.x) / r.x, (y - c.y) / r.y).length()
				a = maxf(a, clampf(1.2 - q, 0.0, 1.0))
			img.set_pixel(x, y, Color(1, 1, 1, a))
	img.generate_mipmaps()
	_textures[kind] = ImageTexture.create_from_image(img)
	return _textures[kind]
