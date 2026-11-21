class_name Crafting
extends RefCounted
## Stateless recipe evaluation/execution. Timing (craft_time) is handled by the caller (UI).


## Returns {ok, missing: {id: n}, tool_ok, station_ok}.
static func check(recipe: RecipeData, inv: Inventory, stations: Array) -> Dictionary:
	var missing := {}
	for id: StringName in recipe.ingredients.keys():
		var need := int(recipe.ingredients[id])
		var have := inv.count_of(id)
		if have < need:
			missing[id] = need - have
	var tool_ok := recipe.required_tag == &"" or inv.has_tag(recipe.required_tag)
	var station_ok := recipe.station == &"" or stations.has(recipe.station)
	return {
		"ok": missing.is_empty() and tool_ok and station_ok,
		"missing": missing,
		"tool_ok": tool_ok,
		"station_ok": station_ok,
	}


## Consumes ingredients and adds the result. Returns {ok, leftover}; leftover = result
## units that did not fit (caller drops them in the world so nothing is lost).
static func craft(recipe: RecipeData, inv: Inventory, stations: Array) -> Dictionary:
	if not check(recipe, inv, stations).ok:
		return {"ok": false, "leftover": 0}
	for id: StringName in recipe.ingredients.keys():
		inv.remove_item(id, int(recipe.ingredients[id]))
	var leftover := inv.add_item(recipe.result, recipe.result_count)
	return {"ok": true, "leftover": leftover}
