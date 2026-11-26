class_name Factions
extends Node
## Faction relations with the player (GDD §7): −100 hostile … +100 allied. No shared language:
## relations move through gestures, offerings, barter, help — and drop on aggression or trespass.

signal relation_changed(faction: StringName, value: float)
signal discovered(faction: StringName)

const PATH := "res://data/factions.json"
const HOSTILE := -40.0
const WARY := 10.0
const FRIENDLY := 50.0

var defs: Dictionary = {}
var relations: Dictionary = {}  # StringName -> float
var known: Dictionary = {}  # StringName -> true once met
var world: ForestWorld
var _gesture_cd: Dictionary = {}  # faction -> uptime seconds until gestures count again
var _uptime := 0.0


func _ready() -> void:
	var f := FileAccess.open(PATH, FileAccess.READ)
	var parsed: Variant = JSON.parse_string(f.get_as_text()) if f else {}
	for k: String in (parsed as Dictionary).keys():
		defs[StringName(k)] = parsed[k]
		relations[StringName(k)] = float(parsed[k].get("start", 0))


func _process(delta: float) -> void:
	_uptime += delta


func def_of(faction: StringName) -> Dictionary:
	return defs.get(faction, {})


func relation(faction: StringName) -> float:
	return float(relations.get(faction, 0.0))


## Coarse stance used by NPC brains and UI.
func stance(faction: StringName) -> StringName:
	var r := relation(faction)
	if r <= HOSTILE:
		return &"hostile"
	if r < WARY:
		return &"wary"
	if r < FRIENDLY:
		return &"neutral"
	return &"friendly"


func change(faction: StringName, delta: float, _reason: StringName = &"") -> void:
	if not relations.has(faction):
		return
	var v := clampf(relation(faction) + delta, -100.0, 100.0)
	relations[faction] = v
	relation_changed.emit(faction, v)


func meet(faction: StringName) -> void:
	if known.has(faction):
		return
	known[faction] = true
	discovered.emit(faction)
	if world:
		world.add_journal(str(def_of(faction).get("journal", "")))
		if known.has(&"hunters") and known.has(&"clan") and known.has(&"gatherers"):
			world.add_journal("JOURNAL_ACT2")


## A visible open-palm gesture: small trust gain per faction, rate-limited.
func gesture_seen(faction: StringName) -> bool:
	if _uptime < float(_gesture_cd.get(faction, 0.0)):
		return false
	_gesture_cd[faction] = _uptime + 45.0
	change(faction, 4.0, &"gesture")
	return true


## Value of an item as an offering to this faction (0 = not wanted).
func want_value(faction: StringName, item: StringName) -> int:
	return int((def_of(faction).get("wants", {}) as Dictionary).get(String(item), 0))


func save_state() -> Dictionary:
	var r := {}
	for k: StringName in relations.keys():
		r[String(k)] = relations[k]
	var kn: Array = []
	for k: StringName in known.keys():
		kn.append(String(k))
	return {"rel": r, "known": kn}


func load_state(d: Dictionary) -> void:
	var r: Dictionary = d.get("rel", {})
	for k: String in r.keys():
		if defs.has(StringName(k)):
			relations[StringName(k)] = float(r[k])
	known.clear()
	for k: Variant in d.get("known", []):
		var faction := StringName(str(k))
		if defs.has(faction):
			known[faction] = true
