class_name RecipeData
extends Resource
## Crafting recipe. Built from data/recipes.json rows by ItemDB.

@export var id: StringName
@export var result: StringName
@export var result_count: int = 1
@export var ingredients: Dictionary = {}  # StringName item id -> int count
@export var required_tag: StringName = &""  # tool tag that must be in inventory/hand (not consumed)
@export var station: StringName = &""  # e.g. &"campfire" (must be near a lit one)
@export var craft_time: float = 1.0


static func from_dict(d: Dictionary) -> RecipeData:
	var r := RecipeData.new()
	r.id = StringName(str(d.get("id", "")))
	r.result = StringName(str(d.get("result", r.id)))
	r.result_count = int(d.get("count", 1))
	var ing: Dictionary = d.get("ingredients", {})
	for k: String in ing.keys():
		r.ingredients[StringName(k)] = int(ing[k])
	r.required_tag = StringName(str(d.get("tool", "")))
	r.station = StringName(str(d.get("station", "")))
	r.craft_time = float(d.get("time", 1.0))
	return r
