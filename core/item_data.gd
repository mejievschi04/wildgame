class_name ItemData
extends Resource
## Static definition of an item type. Built from data/items.json rows by ItemDB.

@export var id: StringName
@export var category: StringName = &"resource"  # resource, tool, weapon, food, drink, medical, placeable
@export var weight: float = 0.1
@export var max_stack: int = 20
@export var max_durability: int = 0  # 0 = indestructible / no durability
@export var tags: PackedStringArray = PackedStringArray()
@export var damage: float = 0.0
@export var fuel_seconds: float = 0.0
@export var food: float = 0.0
@export var water: float = 0.0
@export var health: float = 0.0
@export var sickness_chance: float = 0.0
@export var cures: PackedStringArray = PackedStringArray()
@export var cook_result: StringName = &""
@export var cook_time: float = 0.0
@export var use_result: StringName = &""
@export var place: StringName = &""  # structure type spawned when placed
@export var icon_color: Color = Color("#8a8a82")
@export var placeholder: bool = true  # art is a graybox placeholder


var name_key: String:
	get: return "ITEM_%s" % String(id).to_upper()

var desc_key: String:
	get: return "ITEM_%s_DESC" % String(id).to_upper()


func display_name() -> String:
	return String(TranslationServer.translate(name_key))


func description() -> String:
	return String(TranslationServer.translate(desc_key))


func has_tag(tag: StringName) -> bool:
	return tags.has(String(tag))


func has_durability() -> bool:
	return max_durability > 0


## Items with durability never stack: each instance tracks its own wear.
func stack_limit() -> int:
	return 1 if has_durability() else maxi(max_stack, 1)


func is_consumable() -> bool:
	return category in [&"food", &"drink", &"medical"]


func is_equippable() -> bool:
	return has_tag(&"equippable")


func is_fuel() -> bool:
	return fuel_seconds > 0.0


func is_cookable() -> bool:
	return cook_result != &"" and cook_time > 0.0


static func from_dict(d: Dictionary) -> ItemData:
	var it := ItemData.new()
	it.id = StringName(str(d.get("id", "")))
	it.category = StringName(str(d.get("category", "resource")))
	it.weight = float(d.get("weight", 0.1))
	it.max_stack = int(d.get("max_stack", 20))
	it.max_durability = int(d.get("max_durability", 0))
	it.tags = PackedStringArray(d.get("tags", []))
	it.damage = float(d.get("damage", 0.0))
	it.fuel_seconds = float(d.get("fuel_seconds", 0.0))
	it.food = float(d.get("food", 0.0))
	it.water = float(d.get("water", 0.0))
	it.health = float(d.get("health", 0.0))
	it.sickness_chance = float(d.get("sickness_chance", 0.0))
	it.cures = PackedStringArray(d.get("cures", []))
	it.cook_result = StringName(str(d.get("cook_result", "")))
	it.cook_time = float(d.get("cook_time", 0.0))
	it.use_result = StringName(str(d.get("use_result", "")))
	it.place = StringName(str(d.get("place", "")))
	it.icon_color = Color(str(d.get("icon", "#8a8a82")))
	it.placeholder = bool(d.get("placeholder", true))
	return it
