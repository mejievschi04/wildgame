extends Node
## Versioned JSON save slots in user://saves/. Gameplay code builds/consumes the dictionaries.

const SAVE_VERSION := 1
## Overridden by the test runner so tests never touch real player saves.
var save_dir := "user://saves"
const SLOTS := ["autosave", "slot1", "slot2", "slot3"]


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(save_dir)


func slot_path(slot: String) -> String:
	return "%s/%s.json" % [save_dir, slot]


func save_game(slot: String, data: Dictionary) -> bool:
	DirAccess.make_dir_recursive_absolute(save_dir)
	data["version"] = SAVE_VERSION
	data["saved_at"] = Time.get_unix_time_from_system()
	# Write to a temp file first so a crash mid-write never corrupts the slot.
	var tmp := slot_path(slot) + ".tmp"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		push_error("SaveManager: cannot write %s" % tmp)
		return false
	f.store_string(JSON.stringify(data, "\t"))
	f.close()
	var dir := DirAccess.open(save_dir)
	if dir.file_exists(slot + ".json"):
		dir.remove(slot + ".json")
	if dir.rename(slot + ".json.tmp", slot + ".json") != OK:
		push_error("SaveManager: rename failed for %s" % slot)
		return false
	Events.game_saved.emit(slot)
	return true


func load_game(slot: String) -> Dictionary:
	var path := slot_path(slot)
	if not FileAccess.file_exists(path):
		return {}
	var f := FileAccess.open(path, FileAccess.READ)
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	if not parsed is Dictionary:
		push_error("SaveManager: corrupt save %s" % path)
		return {}
	return _migrate(parsed)


func has_save(slot: String) -> bool:
	return FileAccess.file_exists(slot_path(slot))


func has_any_save() -> bool:
	return latest_slot() != ""


## Slot with the newest saved_at, or "".
func latest_slot() -> String:
	var best := ""
	var best_t := -1.0
	for info: Dictionary in list_slots():
		if info.exists and float(info.saved_at) > best_t:
			best_t = float(info.saved_at)
			best = info.slot
	return best


func list_slots() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for slot: String in SLOTS:
		var info := {"slot": slot, "exists": false, "saved_at": 0.0, "day": 0}
		if has_save(slot):
			var d := load_game(slot)
			if not d.is_empty():
				info.exists = true
				info.saved_at = float(d.get("saved_at", 0.0))
				info.day = int(d.get("world", {}).get("day", 1))
		out.append(info)
	return out


func delete_slot(slot: String) -> void:
	if has_save(slot):
		DirAccess.remove_absolute(slot_path(slot))


func _migrate(d: Dictionary) -> Dictionary:
	var v := int(d.get("version", 0))
	if v > SAVE_VERSION:
		push_error("SaveManager: save version %d is newer than supported %d" % [v, SAVE_VERSION])
		return {}
	# v0 → v1: no structural changes yet; future migrations go here step by step.
	d["version"] = SAVE_VERSION
	return d
