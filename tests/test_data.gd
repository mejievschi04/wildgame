extends TestCase


func test_tables_load() -> void:
	check(ItemDB.items.size() >= 20, "items loaded")
	check(ItemDB.recipes.size() >= 8, "recipes loaded")
	check(ItemDB.node_kinds.size() >= 8, "node kinds loaded")


func test_tables_valid() -> void:
	var errors := ItemDB.validate()
	for e in errors:
		failures.append(e)


func test_mvp_recipes_present() -> void:
	# GDD §8 MVP recipes implemented in Phase 1.
	for id in [&"stone_axe", &"flint_knife", &"spear", &"torch", &"bandage", &"campfire_kit", &"leaf_bed_kit", &"waterskin"]:
		check(ItemDB.get_recipe(id) != null, "recipe %s exists" % id)


func test_item_translations() -> void:
	for item: ItemData in ItemDB.items.values():
		check(Loc.has_key(item.name_key), "missing ru key %s" % item.name_key)
		check(Loc.has_key(item.desc_key), "missing ru key %s" % item.desc_key)
	for kind: StringName in ItemDB.node_kinds.keys():
		check(Loc.has_key("NODE_%s" % String(kind).to_upper()), "missing node name for %s" % kind)


## Scans all scripts for literal UPPER_CASE keys and checks they exist in the ru table.
func test_literal_keys_translated() -> void:
	var re := RegEx.new()
	re.compile("\"([A-Z][A-Z0-9]+_[A-Z0-9_]+)\"")
	var ignore := ["TEST_ONLY"]
	for dir_path in ["res://autoload", "res://core", "res://player", "res://world", "res://ui", "res://game"]:
		var dir := DirAccess.open(dir_path)
		for f in dir.get_files():
			if not f.ends_with(".gd"):
				continue
			var text := FileAccess.get_file_as_string(dir_path + "/" + f)
			for m in re.search_all(text):
				var key := m.get_string(1)
				if key in ignore or key.ends_with("_"):
					continue
				check(Loc.has_key(key), "%s: untranslated key %s" % [f, key])


func test_dynamic_keys_translated() -> void:
	var keys := PackedStringArray()
	for a: StringName in InputSetup.REMAPPABLE:
		keys.append("ACTION_%s" % String(a).to_upper())
	for c in HUD.CONDITION_KEYS:
		keys.append("COND_%s" % String(c).to_upper())
	for cat in ["resource", "tool", "weapon", "food", "drink", "medical", "placeable"]:
		keys.append("CAT_%s" % cat.to_upper())
	for kind: StringName in ItemDB.node_kinds.keys():
		var k: Dictionary = ItemDB.get_node_kind(kind)
		if k.has("hand_yield"):
			keys.append("ACT_GATHER_%s" % String(kind).to_upper())
		if k.has("hit_tag"):
			keys.append("ACT_HIT_%s" % String(kind).to_upper())
			keys.append("NEED_%s" % String(k.hit_tag).to_upper())
	for r: RecipeData in ItemDB.all_recipes():
		if r.required_tag != &"":
			keys.append("TAG_%s" % String(r.required_tag).to_upper())
		if r.station != &"":
			keys.append("REQ_STATION_%s" % String(r.station).to_upper())
	for cause in ["starvation", "dehydration", "hypothermia", "bleeding", "food_poisoning", "fall", "injury", "wolf", "tree"]:
		keys.append("DEATH_%s" % cause.to_upper())
	for j in ["START", "WATER", "FIRE", "FIRST_NIGHT", "OLD_CAMP", "CARCASS", "SHELTER", "RAIN", "HUNT", "WOLF"]:
		keys.append("JOURNAL_%s" % j)
		keys.append("JOURNAL_%s_TITLE" % j)
	for s in SaveManager.SLOTS:
		keys.append("SLOT_%s" % s.to_upper())
	for cat in ["food", "drink", "medical"]:
		keys.append("BTN_USE_%s" % cat.to_upper())
	for k in keys:
		check(Loc.has_key(k), "untranslated dynamic key %s" % k)
