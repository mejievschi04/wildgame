class_name MapData
extends RefCounted
## The world map (Far Cry Primal style): a painted hide made from the real terrain, plus fog of war.
##
## paint(): hillshaded relief on tanned-hide colours, contour lines, ink rivers and lake, stippled forest,
## snowy peaks. Pure function of the world's heights (deterministic per SEED), cached to user://.
## Exploration: a coarse grid over the playable area; cells around the player are revealed as they walk.

const RES := 2048  # map image size (covers the playable square: ~4 m per pixel on the 8 km map)
const FOG_RES := 256  # exploration grid (~31 m cells)
const REVEAL_RADIUS := 110.0
const START_REVEAL := 170.0
const CONTOUR := 12.0  # metres between contour lines
const CACHE_VERSION := 3


static func extent() -> float:
	return ForestWorld.PLAYABLE


## World (x, z) -> map uv 0..1 (north = -z at the top).
static func to_uv(x: float, z: float) -> Vector2:
	var e := extent()
	return Vector2((x + e) / (2.0 * e), (z + e) / (2.0 * e))


static func from_uv(uv: Vector2) -> Vector2:
	var e := extent()
	return Vector2(uv.x * 2.0 * e - e, uv.y * 2.0 * e - e)


static func cache_path() -> String:
	return "user://map_%d_v%d_%08x.png" % [ForestWorld.SEED, CACHE_VERSION, ForestWorld.bake_hash & 0xFFFFFFFF]


## Returns the cached map, or null when it still has to be painted.
static func cached() -> Image:
	if FileAccess.file_exists(cache_path()):
		var img := Image.load_from_file(cache_path())
		if img and img.get_width() == RES:
			return img
	return null


## Paints the map from the world's terrain grid (safe to call from a worker thread: only reads arrays).
static func paint(heights: PackedFloat32Array, grid: int, size: float, forest: Image, water_level: float,
		creeks: Array = []) -> Image:
	var img := Image.create(RES, RES, false, Image.FORMAT_RGB8)
	var e := extent()
	var row := grid + 1
	var cell := size / grid
	var half := size * 0.5
	var px := 2.0 * e / RES  # metres per map pixel
	var paper_noise := FastNoiseLite.new()
	paper_noise.seed = ForestWorld.SEED + 404
	paper_noise.frequency = 0.02
	paper_noise.fractal_octaves = 4
	var stipple := RandomNumberGenerator.new()
	stipple.seed = ForestWorld.SEED + 405
	var hs := PackedFloat32Array()
	hs.resize(RES * RES)
	for y in RES:
		for x in RES:
			hs[y * RES + x] = _h(heights, row, cell, half, -e + (x + 0.5) * px, -e + (y + 0.5) * px)
	# Hide colours: pale tanned leather in the lowlands, warm umber hills, ash grey heights, chalk snow.
	var low := Color(0.80, 0.70, 0.52)
	var mid := Color(0.70, 0.56, 0.38)
	var high := Color(0.56, 0.50, 0.44)
	var snow := Color(0.90, 0.88, 0.82)
	var ink := Color(0.24, 0.16, 0.10)
	var water := Color(0.36, 0.45, 0.46)
	var light := Vector3(-0.6, 0.75, -0.55).normalized()  # from the north-west, like an old map
	for y in RES:
		for x in RES:
			var i := y * RES + x
			var h := hs[i]
			var hx := hs[i + 1] - hs[i - 1] if x > 0 and x < RES - 1 else 0.0
			var hy := hs[i + RES] - hs[i - RES] if y > 0 and y < RES - 1 else 0.0
			var n := Vector3(-hx, 2.0 * px, -hy).normalized()
			var shade := clampf(n.dot(light), 0.0, 1.0)
			var c: Color
			if h < water_level + 0.15:
				var depth := clampf((water_level + 0.15 - h) / 4.0, 0.0, 1.0)
				c = water.lerp(water.darkened(0.35), depth)
				# wave hatching on the water
				if int(y + x * 0.25) % 7 == 0 and depth > 0.15:
					c = c.lightened(0.08)
			else:
				var t := clampf((h - 2.0) / 140.0, 0.0, 1.0)
				c = low.lerp(mid, smoothstep(0.0, 0.45, t)).lerp(high, smoothstep(0.45, 0.8, t))
				c = c.lerp(snow, smoothstep(0.82, 0.95, t))
				c = c.darkened(0.42 * (1.0 - shade)).lightened(0.12 * shade * shade)
				# contour lines
				var band := fposmod(h, CONTOUR)
				var steep := Vector2(hx, hy).length() / (2.0 * px)
				if band < CONTOUR * 0.06 + steep * 0.6:
					c = c.lerp(ink, 0.22)
				# forest: dark stipple, denser where the canopy is thicker
				var fu := (float(x) / RES * 2.0 * e + half - e) / size
				var fv := (float(y) / RES * 2.0 * e + half - e) / size
				var fd := forest.get_pixel(clampi(int(fu * forest.get_width()), 0, forest.get_width() - 1),
					clampi(int(fv * forest.get_height()), 0, forest.get_height() - 1)).r if forest else 0.0
				if stipple.randf() < fd * 0.45:
					c = c.lerp(Color(0.22, 0.27, 0.15), 0.55)
				# shoreline ink
				if h < water_level + 1.2:
					c = c.lerp(ink, 0.45 * (1.0 - (h - water_level - 0.15) / 1.05))
			# paper grain + stains
			var g := paper_noise.get_noise_2d(x, y)
			c = c.lightened(maxf(g, 0.0) * 0.08).darkened(maxf(-g, 0.0) * 0.12)
			img.set_pixel(x, y, c)
	# Creeks: thin ink-blue lines, widening downstream.
	for pts: PackedVector3Array in creeks:
		for i in pts.size() - 1:
			var a := to_uv(pts[i].x, pts[i].z) * RES
			var b := to_uv(pts[i + 1].x, pts[i + 1].z) * RES
			var r := lerpf(0.6, 1.4, float(i) / pts.size())
			var steps := maxi(ceili(a.distance_to(b) * 2.0), 1)
			for k in steps + 1:
				var p := a.lerp(b, float(k) / steps)
				for oy in range(floori(p.y - r), ceili(p.y + r) + 1):
					for ox in range(floori(p.x - r), ceili(p.x + r) + 1):
						if ox < 0 or oy < 0 or ox >= RES or oy >= RES:
							continue
						var cover := clampf(r + 0.5 - Vector2(ox + 0.5, oy + 0.5).distance_to(p), 0.0, 1.0)
						if cover > 0.0:
							img.set_pixel(ox, oy, img.get_pixel(ox, oy).lerp(water.darkened(0.15), cover * 0.85))
	# A worn, darker rim like the edge of a stretched hide.
	for y in RES:
		for x in RES:
			var d := Vector2(x - RES * 0.5, y - RES * 0.5).length() / (RES * 0.5)
			var k := smoothstep(0.82, 1.38, d)
			if k > 0.0:
				img.set_pixel(x, y, img.get_pixel(x, y).darkened(k * 0.55))
	return img


static func _h(heights: PackedFloat32Array, row: int, cell: float, half: float, x: float, z: float) -> float:
	var gx := clampf((x + half) / cell, 0.0, row - 1.001)
	var gz := clampf((z + half) / cell, 0.0, row - 1.001)
	var ix := int(gx)
	var iz := int(gz)
	var u := gx - ix
	var v := gz - iz
	var a := iz * row + ix
	var top := lerpf(heights[a], heights[a + 1], u)
	var bottom := lerpf(heights[a + row], heights[a + row + 1], u)
	return lerpf(top, bottom, v)


# ---------------------------------------------------------------- fog of war

static func new_fog() -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(FOG_RES * FOG_RES)
	b.fill(0)
	return b


## Marks the cells within `radius` of (x, z) as explored. Returns true when something new was revealed.
static func reveal(fog: PackedByteArray, x: float, z: float, radius: float) -> bool:
	var cell := 2.0 * extent() / FOG_RES
	var uv := to_uv(x, z) * FOG_RES
	var r := ceili(radius / cell)
	var changed := false
	for dy in range(-r, r + 1):
		for dx in range(-r, r + 1):
			var cx := int(uv.x) + dx
			var cy := int(uv.y) + dy
			if cx < 0 or cy < 0 or cx >= FOG_RES or cy >= FOG_RES:
				continue
			var d := Vector2(dx, dy).length() * cell
			if d > radius:
				continue
			var i := cy * FOG_RES + cx
			var v := 255 if d < radius - cell else 170
			if fog[i] < v:
				fog[i] = v
				changed = true
	return changed


static func explored(fog: PackedByteArray, x: float, z: float) -> bool:
	var uv := to_uv(x, z) * FOG_RES
	var cx := int(uv.x)
	var cy := int(uv.y)
	if cx < 0 or cy < 0 or cx >= FOG_RES or cy >= FOG_RES:
		return false
	return fog[cy * FOG_RES + cx] > 0


## Fog as an image: alpha = how unexplored (soft edges come from linear filtering when drawn bigger).
static func fog_image(fog: PackedByteArray) -> Image:
	var img := Image.create(FOG_RES, FOG_RES, false, Image.FORMAT_LA8)
	for i in fog.size():
		img.set_pixel(i % FOG_RES, i / FOG_RES, Color(1.0, 1.0, 1.0, 1.0 - fog[i] / 255.0))  # tinted when drawn
	return img
