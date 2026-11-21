extends TestCase


func test_missing_ingredients() -> void:
	var inv := Inventory.new(8)
	inv.add_item(&"stick", 1)
	var res := Crafting.check(ItemDB.get_recipe(&"stone_axe"), inv, [])
	check(not res.ok, "cannot craft without ingredients")
	eq(res.missing.get(&"stone", 0), 1, "stone missing")
	eq(res.missing.get(&"fiber", 0), 3, "fiber missing")


func test_tool_requirement() -> void:
	var inv := Inventory.new(8)
	inv.add_item(&"flint", 2)
	inv.add_item(&"fiber", 1)
	var r := ItemDB.get_recipe(&"flint_knife")
	check(not Crafting.check(r, inv, []).tool_ok, "knife needs a hammerstone")
	inv.add_item(&"stone", 1)
	check(Crafting.check(r, inv, []).ok, "stone in bag satisfies tool_hammer")


func test_station_requirement() -> void:
	var inv := Inventory.new(8)
	inv.add_item(&"stick", 1)
	inv.add_item(&"fiber", 3)
	var r := ItemDB.get_recipe(&"torch")
	check(not Crafting.check(r, inv, []).ok, "torch needs a lit campfire")
	check(Crafting.check(r, inv, [&"campfire"]).ok, "near campfire ok")


func test_craft_consumes_and_produces() -> void:
	var inv := Inventory.new(8)
	inv.add_item(&"stick", 3)
	inv.add_item(&"stone", 2)
	inv.add_item(&"fiber", 5)
	var res := Crafting.craft(ItemDB.get_recipe(&"stone_axe"), inv, [])
	check(res.ok, "crafted")
	eq(inv.count_of(&"stone_axe"), 1, "axe produced")
	eq(inv.count_of(&"stick"), 2, "stick consumed")
	eq(inv.count_of(&"stone"), 1, "stone consumed")
	eq(inv.count_of(&"fiber"), 2, "fiber consumed")


func test_full_inventory_reports_leftover() -> void:
	var inv := Inventory.new(2)
	inv.add_item(&"fiber", 4)
	inv.add_item(&"berries", 30)
	var res := Crafting.craft(ItemDB.get_recipe(&"bandage"), inv, [])
	check(res.ok, "crafted even when the freed slot is reused")
	inv = Inventory.new(1)
	inv.add_item(&"fiber", 40)
	res = Crafting.craft(ItemDB.get_recipe(&"bandage"), inv, [])
	check(res.ok and int(res.leftover) == 1, "result reported as leftover when no room")
