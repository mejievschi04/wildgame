class_name ItemStack
extends RefCounted
## A concrete quantity of one item type, with per-instance durability.

var id: StringName
var count: int
var durability: int  # -1 when the item has no durability


func _init(p_id: StringName = &"", p_count: int = 1, p_durability: int = -1) -> void:
	id = p_id
	count = p_count
	durability = p_durability


func get_data() -> ItemData:
	return ItemDB.get_item(id)


func durability_ratio() -> float:
	var d := get_data()
	if d == null or not d.has_durability() or durability < 0:
		return 1.0
	return clampf(float(durability) / float(d.max_durability), 0.0, 1.0)


func weight() -> float:
	var d := get_data()
	return d.weight * count if d else 0.0


func copy() -> ItemStack:
	return ItemStack.new(id, count, durability)


func to_dict() -> Dictionary:
	return {"id": String(id), "count": count, "dur": durability}


static func from_dict(d: Dictionary) -> ItemStack:
	return ItemStack.new(StringName(str(d.get("id", ""))), int(d.get("count", 1)), int(d.get("dur", -1)))
