class_name Inventory
extends RefCounted
## Slot inventory + one hand (equipment) slot + simplified weight.
## Weight never blocks pickup; it slows the carrier (see weight_factor()).

signal changed

const HOTBAR_SIZE := 6

var size: int
var slots: Array = []  # ItemStack or null
var hand: ItemStack = null
var max_weight: float


func _init(p_size: int = 24, p_max_weight: float = 30.0) -> void:
	size = p_size
	max_weight = p_max_weight
	slots.resize(size)


func get_slot(i: int) -> ItemStack:
	return slots[i] if i >= 0 and i < size else null


## Adds items, stacking first. Returns how many did NOT fit.
func add_item(id: StringName, count: int = 1, durability: int = -1) -> int:
	var data := ItemDB.get_item(id)
	if data == null:
		push_error("Inventory.add_item: unknown item '%s'" % id)
		return count
	var remaining := count
	var limit := data.stack_limit()
	if limit > 1:
		for s: ItemStack in slots:
			if remaining <= 0:
				break
			if s != null and s.id == id and s.count < limit:
				var n := mini(limit - s.count, remaining)
				s.count += n
				remaining -= n
	for i in size:
		if remaining <= 0:
			break
		if slots[i] == null:
			var n := mini(limit, remaining)
			var dur := durability
			if dur < 0 and data.has_durability():
				dur = data.max_durability
			slots[i] = ItemStack.new(id, n, dur)
			remaining -= n
	if remaining != count:
		changed.emit()
	return remaining


func add_stack(stack: ItemStack) -> int:
	return add_item(stack.id, stack.count, stack.durability)


func can_fit(id: StringName, count: int = 1) -> bool:
	var data := ItemDB.get_item(id)
	if data == null:
		return false
	var limit := data.stack_limit()
	var room := 0
	for s: ItemStack in slots:
		if s == null:
			room += limit
		elif s.id == id and limit > 1:
			room += limit - s.count
		if room >= count:
			return true
	return room >= count


## Count in bag slots (the hand slot is equipment and is never consumed by recipes).
func count_of(id: StringName) -> int:
	var n := 0
	for s: ItemStack in slots:
		if s != null and s.id == id:
			n += s.count
	return n


## All-or-nothing removal. Takes from the last slots first to keep the hotbar intact.
func remove_item(id: StringName, count: int = 1) -> bool:
	if count_of(id) < count:
		return false
	var remaining := count
	for i in range(size - 1, -1, -1):
		var s: ItemStack = slots[i]
		if s == null or s.id != id:
			continue
		var n := mini(s.count, remaining)
		s.count -= n
		remaining -= n
		if s.count <= 0:
			slots[i] = null
		if remaining <= 0:
			break
	changed.emit()
	return true


## Removes up to `count` from a slot and returns them as a new stack (or null).
func take_from_slot(i: int, count: int = -1) -> ItemStack:
	var s := get_slot(i)
	if s == null:
		return null
	var n := s.count if count < 0 else mini(count, s.count)
	var out := ItemStack.new(s.id, n, s.durability)
	s.count -= n
	if s.count <= 0:
		slots[i] = null
	changed.emit()
	return out


func first_slot_of(id: StringName) -> int:
	for i in size:
		if slots[i] != null and (slots[i] as ItemStack).id == id:
			return i
	return -1


func has_tag(tag: StringName) -> bool:
	if hand != null and hand.get_data() and hand.get_data().has_tag(tag):
		return true
	for s: ItemStack in slots:
		if s != null and s.get_data() and s.get_data().has_tag(tag):
			return true
	return false


## Returns the first bag slot index whose item matches the predicate (Callable(ItemData)->bool).
func find_slot(predicate: Callable) -> int:
	for i in size:
		var s: ItemStack = slots[i]
		if s != null and s.get_data() and predicate.call(s.get_data()):
			return i
	return -1


func total_weight() -> float:
	var w := hand.weight() if hand else 0.0
	for s: ItemStack in slots:
		if s != null:
			w += s.weight()
	return w


## 1.0 up to max_weight, then linearly down to 0.5 at 1.5 × max_weight.
func weight_factor() -> float:
	var ratio := total_weight() / max_weight
	if ratio <= 1.0:
		return 1.0
	return clampf(1.0 - (ratio - 1.0), 0.5, 1.0)


func is_overweight() -> bool:
	return total_weight() > max_weight


func free_slots() -> int:
	var n := 0
	for s: Variant in slots:
		if s == null:
			n += 1
	return n


## Moves the stack in slot i into the hand; the previous hand item goes back to slot i.
func equip_slot(i: int) -> bool:
	var s := get_slot(i)
	if s == null or s.get_data() == null or not s.get_data().is_equippable():
		return false
	var prev := hand
	hand = s
	slots[i] = prev
	changed.emit()
	return true


func unequip() -> bool:
	if hand == null:
		return true
	for i in size:
		if slots[i] == null:
			slots[i] = hand
			hand = null
			changed.emit()
			return true
	return false


## Wears the hand item. Returns true if it broke.
func wear_hand(amount: int = 1) -> bool:
	if hand == null or hand.durability < 0:
		return false
	hand.durability -= amount
	if hand.durability <= 0:
		hand = null
		changed.emit()
		return true
	changed.emit()
	return false


func swap_slots(a: int, b: int) -> void:
	if a == b or a < 0 or b < 0 or a >= size or b >= size:
		return
	var sa: ItemStack = slots[a]
	var sb: ItemStack = slots[b]
	# Merge equal stackables.
	if sa != null and sb != null and sa.id == sb.id and sa.get_data().stack_limit() > 1:
		var limit := sa.get_data().stack_limit()
		var n := mini(limit - sb.count, sa.count)
		sb.count += n
		sa.count -= n
		if sa.count <= 0:
			slots[a] = null
	else:
		slots[a] = sb
		slots[b] = sa
	changed.emit()


func clear() -> void:
	slots.clear()
	slots.resize(size)
	hand = null
	changed.emit()


func to_dict() -> Dictionary:
	var arr: Array = []
	for s: ItemStack in slots:
		arr.append(s.to_dict() if s != null else null)
	return {"slots": arr, "hand": hand.to_dict() if hand else null}


func from_dict(d: Dictionary) -> void:
	slots.clear()
	slots.resize(size)
	var arr: Array = d.get("slots", [])
	for i in mini(arr.size(), size):
		if arr[i] is Dictionary:
			var st := ItemStack.from_dict(arr[i])
			if ItemDB.get_item(st.id) != null:
				slots[i] = st
	hand = null
	var h: Variant = d.get("hand")
	if h is Dictionary:
		var hs := ItemStack.from_dict(h)
		if ItemDB.get_item(hs.id) != null:
			hand = hs
	changed.emit()
