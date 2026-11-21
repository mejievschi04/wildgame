extends Node
## Registry of item, recipe and resource-node definitions loaded from data/*.json tables.

const ITEMS_PATH := "res://data/items.json"
const RECIPES_PATH := "res://data/recipes.json"
const NODES_PATH := "res://data/resource_nodes.json"

var items: Dictionary = {}  # StringName -> ItemData
var recipes: Dictionary = {}  # StringName -> RecipeData
var recipe_order: Array[StringName] = []
var node_kinds: Dictionary = {}  # StringName -> Dictionary


func _ready() -> void:
	reload()


func reload() -> void:
	items.clear()
	recipes.clear()
	recipe_order.clear()
	node_kinds.clear()
	for row: Dictionary in _load_json(ITEMS_PATH, []):
		var item := ItemData.from_dict(row)
		if items.has(item.id):
			push_error("ItemDB: duplicate item id '%s'" % item.id)
		items[item.id] = item
	for row: Dictionary in _load_json(RECIPES_PATH, []):
		var r := RecipeData.from_dict(row)
		recipes[r.id] = r
		recipe_order.append(r.id)
	var kinds: Dictionary = _load_json(NODES_PATH, {})
	for k: String in kinds.keys():
		node_kinds[StringName(k)] = kinds[k]


func get_item(id: StringName) -> ItemData:
	return items.get(id)


func get_recipe(id: StringName) -> RecipeData:
	return recipes.get(id)


func all_recipes() -> Array[RecipeData]:
	var out: Array[RecipeData] = []
	for id in recipe_order:
		out.append(recipes[id])
	return out


func get_node_kind(kind: StringName) -> Dictionary:
	return node_kinds.get(kind, {})


## Returns a list of human-readable data errors (empty = valid).
func validate() -> PackedStringArray:
	var errors := PackedStringArray()
	for item: ItemData in items.values():
		for ref: StringName in [item.cook_result, item.use_result]:
			if ref != &"" and not items.has(ref):
				errors.append("item %s references unknown item %s" % [item.id, ref])
		if item.has_durability() and item.max_stack > 1:
			errors.append("item %s has durability but max_stack > 1" % item.id)
		if item.category == &"placeable" and item.place == &"":
			errors.append("placeable item %s has no 'place' structure" % item.id)
	for r: RecipeData in recipes.values():
		if not items.has(r.result):
			errors.append("recipe %s: unknown result %s" % [r.id, r.result])
		for ing: StringName in r.ingredients.keys():
			if not items.has(ing):
				errors.append("recipe %s: unknown ingredient %s" % [r.id, ing])
	for kind: StringName in node_kinds.keys():
		var k: Dictionary = node_kinds[kind]
		for field in ["hand_yield", "hit_yield"]:
			var y: Dictionary = k.get(field, {})
			for id: String in y.keys():
				if not items.has(StringName(id)):
					errors.append("node %s: unknown %s item %s" % [kind, field, id])
	return errors


static func _load_json(path: String, fallback: Variant) -> Variant:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_error("ItemDB: cannot open %s" % path)
		return fallback
	var json := JSON.new()
	if json.parse(f.get_as_text()) != OK:
		push_error("ItemDB: %s line %d: %s" % [path, json.get_error_line(), json.get_error_message()])
		return fallback
	if typeof(json.data) != typeof(fallback):
		push_error("ItemDB: %s has unexpected root type" % path)
		return fallback
	return json.data
