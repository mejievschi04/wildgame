extends TestCase


func test_stacking_and_overflow() -> void:
	var inv := Inventory.new(3, 30.0)
	eq(inv.add_item(&"stick", 25), 0, "25 sticks fit in one stack (limit 30)")
	eq(inv.add_item(&"stick", 70), 5, "overflow beyond 3×30 returned")
	eq(inv.count_of(&"stick"), 90, "total sticks")
	eq(inv.free_slots(), 0, "all slots used")


func test_durability_items_do_not_stack() -> void:
	var inv := Inventory.new(4)
	eq(inv.add_item(&"stone_axe", 2), 0, "two axes fit")
	check(inv.get_slot(0).count == 1 and inv.get_slot(1).count == 1, "axes in separate slots")
	eq(inv.get_slot(0).durability, ItemDB.get_item(&"stone_axe").max_durability, "fresh durability")


func test_remove_all_or_nothing() -> void:
	var inv := Inventory.new(4)
	inv.add_item(&"fiber", 5)
	check(not inv.remove_item(&"fiber", 6), "cannot remove more than owned")
	eq(inv.count_of(&"fiber"), 5, "nothing removed on failure")
	check(inv.remove_item(&"fiber", 5), "remove exact")
	eq(inv.free_slots(), 4, "slot freed")


func test_equip_and_wear() -> void:
	var inv := Inventory.new(4)
	inv.add_item(&"flint_knife")
	check(inv.equip_slot(0), "knife equips")
	check(inv.get_slot(0) == null and inv.hand != null, "moved to hand")
	check(inv.has_tag(&"tool_knife"), "hand counts for tool tags")
	eq(inv.count_of(&"flint_knife"), 0, "hand excluded from consumable counts")
	var dur := inv.hand.durability
	check(not inv.wear_hand(1), "does not break on first use")
	eq(inv.hand.durability, dur - 1, "durability decreases")
	check(inv.wear_hand(10000), "breaks when worn out")
	check(inv.hand == null, "broken tool removed")
	inv.add_item(&"berries", 3)
	check(not inv.equip_slot(0), "food is not equippable")


func test_weight_factor() -> void:
	var inv := Inventory.new(10, 10.0)
	inv.add_item(&"wood", 6)  # 9 kg
	near(inv.weight_factor(), 1.0, 0.001, "under limit → full speed")
	inv.add_item(&"wood", 4)  # 15 kg = 1.5×
	near(inv.weight_factor(), 0.5, 0.001, "1.5× limit → half speed")


func test_swap_merges_stacks() -> void:
	var inv := Inventory.new(4)
	inv.add_item(&"stone", 15)
	inv.slots[1] = ItemStack.new(&"stone", 10)
	inv.swap_slots(1, 0)
	eq(inv.get_slot(0).count, 20, "merged up to stack limit")
	eq(inv.get_slot(1).count, 5, "remainder stays")


func test_serialization_roundtrip() -> void:
	var inv := Inventory.new(6)
	inv.add_item(&"stone", 7)
	inv.add_item(&"stone_axe")
	inv.equip_slot(1)
	inv.wear_hand(5)
	var json := JSON.stringify(inv.to_dict())
	var inv2 := Inventory.new(6)
	inv2.from_dict(JSON.parse_string(json))
	eq(inv2.count_of(&"stone"), 7, "stones restored")
	eq(inv2.hand.id, &"stone_axe", "hand restored")
	eq(inv2.hand.durability, ItemDB.get_item(&"stone_axe").max_durability - 5, "durability restored")
