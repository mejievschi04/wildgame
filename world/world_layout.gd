extends RefCounted
## Shared anchors for the world bake, the interactive map, and the session.

const PATH := "res://data/world_layout.json"
const TERRAIN_DIR := "res://assets/terrain/world_layout/"
const VERSION := 2

static var data: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(PATH))


static func point(key: String) -> Vector2:
	var value: Array = data[key]
	return Vector2(float(value[0]), float(value[1]))


static func river_x(river: Dictionary, z: float) -> float:
	var points: Array = river.points
	if z <= float(points[0][0]):
		return float(points[0][1])
	for i in range(1, points.size()):
		var b: Array = points[i]
		if z > float(b[0]):
			continue
		var a: Array = points[i - 1]
		var t := inverse_lerp(float(a[0]), float(b[0]), z)
		var previous: Array = points[maxi(i - 2, 0)]
		var next: Array = points[mini(i + 1, points.size() - 1)]
		var slope_a := (float(b[1]) - float(previous[1])) / (float(b[0]) - float(previous[0]))
		var slope_b := (float(next[1]) - float(a[1])) / (float(next[0]) - float(a[0]))
		var span := float(b[0]) - float(a[0])
		return lerpf(float(a[1]), float(b[1]), t * t * (3.0 - 2.0 * t)) \
			+ span * t * (1.0 - t) * (slope_a * (1.0 - t) - slope_b * t)
	return float(points[-1][1])


## The shoreline traced from the concept map by tools/bake_reference_world.py (coast.json: [x, z] points every
## 50 m, the sea to the south); the analytic coast if the bake has none.
static var _coast: PackedVector2Array = _load_coast()


static func _load_coast() -> PackedVector2Array:
	var out := PackedVector2Array()
	var path := TERRAIN_DIR + "coast.json"
	if FileAccess.file_exists(path):
		for p: Array in JSON.parse_string(FileAccess.get_file_as_string(path)).points:
			out.append(Vector2(float(p[0]), float(p[1])))
	return out


static func coast_z(x: float) -> float:
	var n := _coast.size()
	if n >= 2:
		if x <= _coast[0].x:
			return _coast[0].y + (x - _coast[0].x) * (_coast[1].y - _coast[0].y) / (_coast[1].x - _coast[0].x)
		if x >= _coast[n - 1].x:
			return _coast[n - 1].y + (x - _coast[n - 1].x) * (_coast[n - 1].y - _coast[n - 2].y) \
				/ (_coast[n - 1].x - _coast[n - 2].x)
		var i := clampi(int((x - _coast[0].x) / (_coast[1].x - _coast[0].x)), 0, n - 2)
		while i < n - 2 and x > _coast[i + 1].x:
			i += 1
		while i > 0 and x < _coast[i].x:
			i -= 1
		return lerpf(_coast[i].y, _coast[i + 1].y, inverse_lerp(_coast[i].x, _coast[i + 1].x, x))
	var coast: Dictionary = data.coast
	var dx := x - float(coast.center_x)
	return float(coast.center_z) + dx * float(coast.slope) \
		+ 110.0 * sin(dx * 0.0033) + 54.0 * sin(dx * 0.0103 + 0.55)
