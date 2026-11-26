class_name Raids
extends Node
## Night raids (in the manner of The Forest): most nights a war party of a rival tribe comes for the player, and
## now and then one comes by day (at most one a day, at a random hour between 9 and 17, smaller, without torches,
## and it stays until the fight is decided or night falls).
##
##   approach  2-5 armed raiders set out ~130 m away, from their tribe's side of the map, the leader with a burning
##             torch (its light through the trees is the first sign), and track the player down.
##   stalk     at ~45 m (or once they see the player) they spread out on an arc 20-30 m away, each behind a
##             tree trunk when one is near, and watch; they shift position, and one now and then makes a mock
##             charge: runs in to a few metres, stops, and backs off.
##   attack    after a while, or as soon as the player comes close or hurts one of them, all of them fight
##             (HumanNPC combat: attack tokens, slots around the player, spear throws). A badly hurt raider
##             runs, catches their breath and comes back to the stalk (hit and run).
##   withdraw  when half of them are down, at dawn, or after a long fight they run back the way they came
##             and are gone once out of sight.
##
## Who raids: armed tribes with a territorial or wary temper that dislike the player (stance hostile, or wary
## for territorial ones). Better relations stop the raids. Raiders are transient: they are not saved, and a
## raid that is due while the player sleeps wakes them with the raiders close by.

const SPAWN_DIST := 130.0
const SPAWN_DIST_ASLEEP := 85.0
const STALK_AT := 45.0
const STALK_RING := Vector2(20.0, 30.0)
const STALK_TIME := Vector2(18.0, 34.0)
const NEAR_TRIGGER := 10.0  # the player walking up to a stalker starts the fight
const MAX_TIME := 330.0
const GONE_DIST := 115.0
const SETTLEMENT_CLEAR := 220.0  # (x0.3 past a town's radius) no raid on a player inside a town
const RAID_START := 22.5
const RAID_END := 3.5
## Now and then a war party comes by day too: at most one a day, at a random hour, smaller odds than at night.
const DAY_START := 9.0
const DAY_END := 17.0
const DAY_CHANCE_MAX := 0.5

var world: ForestWorld
var enabled := true
var party: Array[HumanNPC] = []
var faction: StringName = &""
var phase := &""  # "", approach, stalk, attack, withdraw
var wake_player := false  # set when a raid arrives during the player's sleep (Player.sleep_at stops)
var _group: TribeGroup
var _origin := Vector3.ZERO  # where they came from (and run back to)
var _phase_t := 0.0
var _total_t := 0.0
var _stalk_for := 25.0
var _shift_t := 0.0
var _feint_t := 0.0
var _track_t := 0.0
var _plan_night := -1  # the in-game day whose night is planned
var _plan_hour := -1.0  # hour of tonight's raid (-1 = none tonight)
var _plan_day := -1  # the in-game day whose daylight raid is planned
var _day_hour := -1.0  # hour of today's daylight raid (-1 = none today)
var by_day := false  # the current raid came by daylight: no torch, and it does not end at dawn
var _count := 0
var _tick := 0.0
var rng := RandomNumberGenerator.new()


func _ready() -> void:
	add_to_group("time_sim")
	rng.seed = hash(ForestWorld.SEED) ^ 0x5a1d


func active() -> bool:
	return phase != &""


## Tribes that would raid the player tonight, with a weight (hostile ones far more often).
func raiders() -> Dictionary:
	var out := {}
	var fs := world.factions
	if fs == null:
		return out
	for f: StringName in fs.defs.keys():
		var d: Dictionary = fs.def_of(f)
		if not bool(d.get("armed", false)) or d.get("variants", []).is_empty() or _site(f) == Vector2.INF:
			continue
		var stance := fs.stance(f)
		var temper := str(d.get("temper", "wary"))
		if stance == &"hostile":
			out[f] = 3.0
		elif stance == &"wary" and temper == "territorial":
			out[f] = 1.0
	return out


## Where a tribe lives: its field camp or its regional base.
func _site(f: StringName) -> Vector2:
	var d := world.factions.def_of(f)
	if d.has("camp"):
		return Camps.site(d)
	for id: String in Camps.REGIONAL_BASES:
		var faction_of := &"varkai" if id == "aruun" else StringName(id)
		if faction_of == f:
			return Camps.site(Camps.REGIONAL_BASES[id])
	return Vector2.INF


func _hour() -> float:
	return world.day_night.time_hours if world and world.day_night else 12.0


func _night_key() -> int:
	# The night of day N runs from its evening into the small hours of day N+1.
	var day := world.day_night.day
	return day - 1 if _hour() < 12.0 else day


## Decides once per night whether and when a war party comes.
func _plan() -> void:
	var key := _night_key()
	if key == _plan_night:
		return
	_plan_night = key
	_plan_hour = -1.0
	var who := raiders()
	if who.is_empty():
		return
	var hostile := who.values().count(3.0)
	var chance := clampf(0.35 + 0.12 * key + 0.15 * hostile, 0.0, 0.9)
	if rng.randf() > chance:
		return
	var span := (24.0 - RAID_START) + RAID_END
	_plan_hour = fposmod(RAID_START + rng.randf() * span, 24.0)


## Decides once per day whether a war party comes by daylight, and at what hour.
func _plan_daylight() -> void:
	var day := world.day_night.day
	if day == _plan_day:
		return
	_plan_day = day
	_day_hour = -1.0
	var who := raiders()
	if who.is_empty():
		return
	var hostile := who.values().count(3.0)
	if rng.randf() > clampf(0.12 + 0.07 * day + 0.1 * hostile, 0.0, DAY_CHANCE_MAX):
		return
	_day_hour = rng.randf_range(DAY_START, DAY_END)


func _due_daylight(hour: float) -> bool:
	return _day_hour >= 0.0 and hour >= _day_hour and hour < DAY_END + 1.5


## Starts whichever raid is due now (night or day). Returns true if one set out.
func _launch_due(dist: float) -> bool:
	_plan()
	_plan_daylight()
	var h := _hour()
	var night := _due(h)
	var daylight := not night and _due_daylight(h)
	if not (night or daylight) or not _player_ok():
		return false
	if night:
		_plan_hour = -1.0
	else:
		_day_hour = -1.0
	return not start(_pick_faction(), -1, dist).is_empty()


func _due(hour: float) -> bool:
	if _plan_hour < 0.0:
		return false
	# The night wraps over midnight: compare on a clock that starts at noon.
	var now := fposmod(hour - 12.0, 24.0)
	var at := fposmod(_plan_hour - 12.0, 24.0)
	return now >= at and now < fposmod(RAID_END + 1.5 - 12.0, 24.0)


func _player_ok() -> bool:
	var p := world.player as Node3D
	if p == null or p.get("dead") == true:
		return false
	var at := Vector2(p.global_position.x, p.global_position.z)
	for id: String in Camps.REGIONAL_BASES:  # inside a town its guards are the danger, not a war party
		var town := Camps.site(Camps.REGIONAL_BASES[id])
		if town.distance_to(at) < Camps.Layout.radius(id) + SETTLEMENT_CLEAR * 0.3:
			return false
	return world.cave_at(p.global_position) == null if world.has_method("cave_at") else true


func _process(delta: float) -> void:
	if world == null or not is_instance_valid(world.player):
		return
	_tick -= delta
	if _tick > 0.0:
		return
	_tick = 0.25
	_update(0.25)


func _update(dt: float) -> void:
	if not active():
		for c in get_children():  # fallen raiders stay where they fell until the player is far away
			if c is HumanNPC and c.global_position.distance_to((world.player as Node3D).global_position) > 180.0:
				c.queue_free()
		if not enabled:
			return
		_launch_due(SPAWN_DIST)
		return
	_total_t += dt
	_phase_t += dt
	_direct(dt)


func _pick_faction() -> StringName:
	var who := raiders()
	var total := 0.0
	for w: float in who.values():
		total += w
	var r := rng.randf() * total
	for f: StringName in who.keys():
		r -= float(who[f])
		if r <= 0.0:
			return f
	return who.keys()[0] if not who.is_empty() else &""


## Sends a war party of `f` for the player now (size <= 0: by the day). Returns the raiders.
func start(f: StringName, size := -1, dist := SPAWN_DIST) -> Array[HumanNPC]:
	if f == &"" or active():
		return party
	var p := world.player as Node3D
	var defs := world.factions.def_of(f)
	var day := world.day_night.day if world.day_night else 1
	var size_was_default := size <= 0
	if size <= 0:
		size = clampi(2 + day / 2 + (1 if world.factions.stance(f) == &"hostile" else 0), 2, 5)
	var site := _site(f)
	var toward := Vector2(site.x - p.global_position.x, site.y - p.global_position.z).normalized()
	if toward == Vector2.ZERO:
		toward = Vector2.RIGHT
	var center := Vector3.INF
	for attempt in 16:
		var a := toward.rotated(rng.randf_range(-0.6, 0.6) + (attempt / 2) * 0.4 * (1 if attempt % 2 else -1))
		var c := p.global_position + Vector3(a.x, 0.0, a.y) * dist
		if world.habitat_ok_for_people(world.ground_point(c.x, c.z)):
			center = world.ground_point(c.x, c.z)
			break
	if center == Vector3.INF:
		return party
	faction = f
	_origin = center
	_total_t = 0.0
	by_day = _hour() >= 5.5 and _hour() < 21.0
	if size_was_default and by_day:
		size = maxi(2, size - 1)  # by day a smaller band, out in the open
	_count += 1
	_group = TribeGroup.new("raid_%d" % _count, f, center, center)
	var variants: Array = defs.get("variants", ["M1"])
	party.clear()
	for i in size:
		var a := TAU * i / size + rng.randf() * 0.5
		var pos := world.ground_point(center.x + cos(a) * 2.5, center.z + sin(a) * 2.5) + Vector3.UP * 0.1
		var n := HumanNPC.new()
		n.setup("raider_%d_%d" % [_count, i], f, str(variants[i % variants.size()]), world.factions, world,
			center, pos, rng.randi())
		n.armed = true
		n.spears = 1 + (1 if i % 2 == 0 else 0)
		n.group = _group
		n.raider = true
		_group.members.append(n)
		add_child(n)
		n.look_at(Vector3(p.global_position.x, n.global_position.y, p.global_position.z), Vector3.UP, true)
		if i == 0 and not by_day:
			n.carry_torch()
		party.append(n)
	_set_phase(&"approach")
	return party


func _set_phase(p: StringName) -> void:
	phase = p
	_phase_t = 0.0
	match p:
		&"approach":
			_track_t = 0.0
			for n in _alive():
				n.raid_order(&"approach", _player_pos())
		&"stalk":
			_stalk_for = rng.randf_range(STALK_TIME.x, STALK_TIME.y)
			_shift_t = rng.randf_range(7.0, 11.0)
			_feint_t = rng.randf_range(5.0, 9.0)
			_assign_stalk_spots()
			_caption("CAPTION_RAID_STALK")
		&"attack":
			for n in _alive():
				n.raid_order(&"attack", _player_pos())
			_caption("CAPTION_RAID_ATTACK")
		&"withdraw":
			var away := _origin - _player_pos()
			away.y = 0.0
			var back := _player_pos() + away.normalized() * (GONE_DIST + 60.0)
			for n in _alive():
				n.raid_order(&"withdraw", back)


func _alive() -> Array[HumanNPC]:
	var out: Array[HumanNPC] = []
	for n in party:
		if is_instance_valid(n) and not n.is_dead():
			out.append(n)
	return out


func _player_pos() -> Vector3:
	return (world.player as Node3D).global_position


func _caption(key: String) -> void:
	if bool(Settings.get_value("accessibility", "subtitles")):
		Sfx.caption.emit(Loc.t(key))


func _direct(dt: float) -> void:
	var alive := _alive()
	var p := world.player as Node3D
	var pp := p.global_position
	if phase == &"withdraw":
		for n in alive:
			if n.global_position.distance_to(pp) > GONE_DIST:
				party.erase(n)
				n.queue_free()
		if _alive().is_empty() or _phase_t > 90.0:
			_end()
		return
	var down := party.size() - alive.size()
	for n in alive:
		if n.health < n.max_health * 0.4:
			down += 1
	# A night party leaves at dawn; a daylight one at nightfall (the next night has its own).
	var light := _hour() >= 5.5 and _hour() < 21.0
	var over := light != by_day
	if alive.is_empty() or down * 2 >= party.size() or over or _total_t > MAX_TIME or p.get("dead") == true:
		_set_phase(&"withdraw")
		return
	match phase:
		&"approach":
			_track_t -= dt
			if _track_t <= 0.0:
				_track_t = 3.0
				for n in alive:
					n.raid_order(&"approach", pp)
			for n in alive:
				if n.global_position.distance_to(pp) < STALK_AT or n.awareness > 0.6 or n.state == HumanNPC.State.COMBAT:
					_set_phase(&"stalk")
					return
		&"stalk":
			for n in alive:
				if n.global_position.distance_to(pp) < NEAR_TRIGGER or n.state == HumanNPC.State.COMBAT:
					_set_phase(&"attack")
					return
			if _phase_t > _stalk_for:
				_set_phase(&"attack")
				return
			_shift_t -= dt
			if _shift_t <= 0.0:
				_shift_t = rng.randf_range(7.0, 11.0)
				_assign_stalk_spots()
			_feint_t -= dt
			if _feint_t <= 0.0:
				_feint_t = rng.randf_range(7.0, 12.0)
				var n: HumanNPC = alive[rng.randi() % alive.size()]
				if n.raid_mode == &"stalk":
					var to := (n.global_position - pp)
					to.y = 0.0
					n.raid_order(&"feint", pp + to.normalized() * rng.randf_range(5.0, 7.0))
		&"attack":
			for n in alive:
				if n.raid_mode != &"attack":
					n.raid_order(&"attack", pp)


## Spots on an arc around the player, on their side, each behind a tree trunk where one is close.
func _assign_stalk_spots() -> void:
	var alive := _alive()
	if alive.is_empty():
		return
	var pp := _player_pos()
	var mid := Vector3.ZERO
	for n in alive:
		mid += n.global_position
	mid /= alive.size()
	var base := atan2(mid.x - pp.x, mid.z - pp.z)
	var spread := deg_to_rad(40.0 + 25.0 * alive.size())
	var trees := _trunks_near(pp, STALK_RING.y + 12.0)
	for i in alive.size():
		var t := 0.5 if alive.size() == 1 else float(i) / (alive.size() - 1)
		var a := base + (t - 0.5) * spread + rng.randf_range(-0.15, 0.15)
		var r := rng.randf_range(STALK_RING.x, STALK_RING.y)
		var spot := pp + Vector3(sin(a), 0.0, cos(a)) * r
		var best_d := 7.0
		for tr: Vector3 in trees:
			var d := Vector2(tr.x - spot.x, tr.z - spot.z).length()
			var tr_r := Vector2(tr.x - pp.x, tr.z - pp.z).length()
			if d < best_d and tr_r > STALK_RING.x - 4.0:
				best_d = d
				var behind := Vector3(tr.x - pp.x, 0.0, tr.z - pp.z).normalized()
				spot = tr + behind * 1.1  # the trunk between them and the player
		alive[i].raid_order(&"stalk", world.ground_point(spot.x, spot.z))


func _trunks_near(at: Vector3, radius: float) -> Array[Vector3]:
	var out: Array[Vector3] = []
	for n in get_tree().get_nodes_in_group("resource_node"):
		if n is TreeNode and (n as TreeNode).stage == TreeNode.Stage.STANDING:
			var q := (n as Node3D).global_position
			if absf(q.x - at.x) < radius and absf(q.z - at.z) < radius:
				out.append(q)
	return out


func _end() -> void:
	for n in party:
		if is_instance_valid(n) and not n.is_dead():
			n.queue_free()
	party.clear()
	phase = &""
	faction = &""


## Time skip (sleep): a raid due in this span arrives now, close, and wakes the player.
func simulate(seconds: float) -> void:
	if not enabled or active() or world == null or world.day_night == null:
		return
	if _launch_due(SPAWN_DIST_ASLEEP):
		wake_player = true
