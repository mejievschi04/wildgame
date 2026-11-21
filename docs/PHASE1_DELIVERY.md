# Phase 1 delivery — initial playable loop (graybox)

Date: 2026-11-21 · Engine: Godot 4.7.2 · Language of in-game text: Russian

## What is implemented (and verified)
| GDD requirement (Master Prompt, Phase 1) | Status | Where |
|---|---|---|
| First-person movement (walk/sprint/crouch/jump, stamina, weight slowdown, water slowdown, fall damage/fracture) | ✅ | `player/player.gd` |
| Interaction traces + interface-based interactables (hold-to-interact) | ✅ | `player/player.gd`, contract in `docs/ARCHITECTURE.md §3` |
| Collectible resources (hand-gathered + tool-hit nodes, regrowth) | ✅ | `world/resource_node.gd`, `data/resource_nodes.json` |
| Data-driven item definitions | ✅ | `data/items.json` → `core/item_data.gd` via `ItemDB` |
| Inventory + equipment (24 slots, hand slot, weight, durability, drag & drop, hotbar 1–6) | ✅ | `core/inventory.gd`, `ui/inventory_screen.gd` |
| Crafting recipes (tool tags, station requirement, craft time) | ✅ | `data/recipes.json`, `core/crafting.gd` |
| Survival stats: health, stamina, hunger, thirst, body temperature, rest + conditions | ✅ | `core/survival_stats.gd` |
| Day/night (sun, moon, sky, ambient temperature curve) | ✅ | `world/day_night.gd` |
| Campfire with fuel, friction ignition, warmth, light, cooking, crafting station | ✅ | `world/campfire.gd` |
| Save/load (versioned JSON, 3 slots + autosave, atomic write) | ✅ | `autoload/save_manager.gd`, `ForestWorld.collect_save/apply_save` |
| Small graybox forest test map | ✅ | `world/forest_world.gd` (~260×260 m, river, mountain rim, ~560 nodes, 2 POIs) |
| UI: main menu, pause, settings, HUD, inventory/crafting, journal, contextual prompts | ✅ | `ui/` |
| Accessibility: remap keys, FOV, HUD scale, high contrast, reduce camera motion, toggle sprint/crouch, difficulty rates | ✅ | `ui/settings_menu.gd`, `autoload/settings.gd` |

Extra: water drinking/waterskin + boiling, raw food sickness, leaf bed + sleep time-skip (wakes from cold if the fire dies),
deer carcass (butcher with knife), abandoned camp cache with story clue, journal entries for Act I beats.

## Manual test script (≈10 minutes)
1. Run: open the folder in Godot 4.7 and press F5 (or `godot --path .`). Main menu shows a live camp at dawn.
2. **Новая игра**. You spawn in a clearing at 10:00. Press **J** — the journal has the first entry.
3. Look at **Валежник** (stick pile) and hold **E** → +2 Палка. Gather stones (**Россыпь камней**) and fibres/berries (**Куст**).
4. **Tab** → Изготовление → **Каменный топор** → Изготовить (progress bar). Select the axe → «Взять в руку» (or press its number 1–6).
5. Close (Tab). Look at a **Сосна**, press **LMB** repeatedly → Полено; the axe's durability bar decreases.
6. Equip a **Камень**, hit a **Кремнёвая жила** at the river bank (east) → Кремень. Craft **Кремнёвый нож** (needs a stone in the bag).
7. Craft **Камни и растопка для костра**, use it from the hotbar → green ghost → LMB to place (R rotates, RMB cancels).
8. At the fire: **E** add fuel, then hold **E** 4 s to ignite. Stand close: the cold warning disappears at night.
9. Follow the river south-east to the **Туша оленя** (z≈26), hold **E** with the knife → meat, hide, bones.
10. At the lit fire: **R** to cook meat, wait ~40 s, **E** to take it. Craft **Пустой бурдюк**, fill it at the river (**R**), boil it on the fire.
11. Craft & place **Лежанка из листьев** near the fire; at night press **E** on it → wake at ~06:30, day 2, autosave written.
12. **Esc** → Сохранить игру → Ячейка 1. Change something, Esc → Загрузить игру → Ячейка 1 — state restored (fire, harvested nodes, inventory, time).
13. Cross the river to the north-east to find the **abandoned camp** and its cache (journal clue).
14. Settings → Управление: rebind Interact, verify the prompt shows the new key. Toggle high contrast / HUD scale.

## Automated tests
`./tests/run_tests.sh` — 36 tests (data integrity & translations, inventory, crafting, survival model,
save format, and headless integration tests that boot a real GameSession and drive gather → craft → fire → cook,
water, sleep, save/restore). Fails on any assertion, non-zero exit or GDScript runtime error.
Tests write to `user://test_saves`, never to player saves.

Screenshots for visual checks: `godot --path . res://scenes/game.tscn -- --autoshot=/abs/out.png --shot-scenario=camp --shot-hour=21.3`
(scenarios in `game/auto_shot.gd`).

## Known limitations (honest list)
- All art is **placeholder graybox**; icons are colour swatches with initials. No audio at all yet (Phase 2).
- No animals/NPC AI, no combat damage to creatures — spear exists as an item only (Phase 3).
- No building system beyond placing campfire/bed (Phase 2: modular ghost building, foundations, walls, roof).
- No weather (rain/wind), no clothing items (fixed +4 °C insulation), no food spoilage, no fire spreading.
- Gamepad: movement/look/actions are bound in the input map but **not tested on hardware**; rebinding UI edits keyboard/mouse only.
- Performance: only a spot check — 60 FPS (vsync-capped) in a 1600×900 window on Apple M4, ~1040 draw calls by day / ~530 at night. No formal benchmark yet (GDD §17); trees are individual nodes, MultiMesh/LOD is a later optimisation.
- Language: only Russian strings exist; the locale system supports adding `en` etc. in `locale/strings.json`.
- Godot editor import of the project was done headless; first open in the editor will re-import silently.

## Next incremental task (proposal)
Phase 2a — **audio feedback + modular building ghost**: snapping foundation/wall/roof pieces with material costs
and placement validation, repair/dismantle with partial refund, plus a minimal sound layer (gather/craft/fire/footsteps)
using original or CC0-licensed sounds recorded in the asset bible.
