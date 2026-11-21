# WILDBOUND: Primal Age — Architecture Audit & Map

## 0. Audit of the starting point (2026-11-21)

| Item | Finding |
|---|---|
| Repository | Empty except the GDD (`WILDBOUND_Primal_Age_GDD.docx`). No existing systems to preserve. |
| Engine | GDD recommends UE5. UE5 is **not installed**. **Godot 4.7.2** is installed → chosen (user decision). |
| Hardware | Apple M4, 16 GB RAM, Metal 4 → Forward+ renderer (Metal backend). |
| Tools | Blender 5.3 (asset pipeline), Xcode, Cursor, git. |
| In-game language | Russian (`ru`) by default, localization-ready (`locale/strings.json`). |

### UE5 → Godot mapping of GDD concepts

| GDD (UE5) | Godot implementation |
|---|---|
| Data Assets / Data Tables | JSON data tables in `data/` → typed `Resource` classes (`ItemData`, `RecipeData`) at load |
| Gameplay Tags | `PackedStringArray tags` on items (`tool_axe`, `fuel`, …) |
| Interface-based interactables | Duck-typed contract + group `interactable` (see §3) |
| PlayerController / Character | `Player` (`CharacterBody3D`) |
| SaveGame | `SaveManager` autoload, versioned JSON in `user://saves/` |
| Event bus / decoupled events | `Events` autoload (signals only) |
| Behavior Trees / StateTree | Phase 3: explicit state machines (`Idle→Patrol→Suspicious→…`) |
| Blueprints for tuning | JSON tables + exported constants; GDScript for gameplay |
| C++ for core systems | GDScript now; hot paths can move to GDExtension (C++) later if profiling demands |

## 1. Layering

```
autoload/   Global services (no gameplay state of a running world)
  events.gd        signal bus
  localization.gd  loads locale/strings.json into TranslationServer
  item_db.gd       item/recipe/resource-node registry from data/*.json
  settings.gd      user://settings.cfg, input remapping, video/audio apply
  save_manager.gd  versioned save slots
  game.gd          scene flow: menu ↔ session, pending save data
  sfx.gd           procedural sound streams + pooled 2D/3D players, captions

core/       Pure logic, no scene tree dependency → unit-testable
  item_data.gd, recipe_data.gd, item_stack.gd
  inventory.gd     slots + hand slot + simplified weight
  crafting.gd      recipe checks/execution
  survival_stats.gd health, stamina, hunger, thirst, body temperature, rest, conditions
  input_setup.gd   default action map (keyboard physical keys + gamepad)
  sound_synth.gd   offline synth (noise/tones/envelopes → AudioStreamWAV)

player/     Player character, interaction, placement
world/      Forest graybox generation, day/night, interactables, structures
ui/         Theme, HUD, inventory/crafting/journal, menus
scenes/     Tiny .tscn entry points (main menu, game session, tests)
tests/      Headless test runner + suites
data/       Designer-facing tables
locale/     Translations
```

Dependency rule: `core` never references nodes; `world`/`player` use `core`; `ui` reads
`player`/`world` state and calls their public methods; nothing in `core` knows about UI.

## 2. Runtime flow

```
scenes/main_menu.tscn ─(New/Continue)→ Game.start_session(save) → scenes/game.tscn
  GameSession
   ├─ ForestWorld (terrain, water, scatter, POIs, DayNight, structures, pickups)
   ├─ Player (stats, inventory, interaction ray, placement)
   └─ UI layer: HUD, InventoryScreen(+Crafting, Journal), PauseMenu, DeathScreen
```

## 3. Contracts

**Interactable** (group `interactable`, on the collider or an ancestor):
- `get_interactions(player) -> Array[Dictionary]` — each `{action, text, hold, enabled}`;
  `action` is `interact` (E) or `alt_interact` (R); `hold` seconds (0 = instant).
- `perform_interaction(player, action: StringName) -> void`
- optional `on_hit(player, item: ItemData) -> bool` — LMB swing with equipped tool; return true if the hit "landed" (costs durability).
- `get_display_name() -> String`

**Persistent** (group `persistent`): `get_save_id() -> String`, `save_state() -> Dictionary`, `load_state(d)`.
Generated nodes have deterministic ids (fixed seed), so saves store only *changed* state.
Runtime-spawned objects (pickups, structures) are serialized as lists and re-spawned.

**Time simulation** (group `time_sim`): `simulate(seconds)` — used for sleeping/time skips
so fires, regrowth and needs advance consistently without running physics.

## 3b. Building

`BuildingPiece` (one script, data from `data/building_pieces.json`) is spawned through
`ForestWorld.spawn_structure(&"piece", xform, {"piece": id, "on": [support ids]})`.
`BuildController.evaluate(aim, normal, collider, yaw)` is a pure query returning
`{valid, reason, xform, supports}`, so snapping is unit-tested headless.
Support is a graph of structure ids; `ForestWorld.remove_piece()` cascades collapse.

## 4. Data tables

- `data/items.json` — id, category, weight, max_stack, max_durability, tags, food/water/health,
  sickness_chance, cook_result/cook_time, use_result, fuel_seconds, place, damage, icon colour.
- `data/recipes.json` — result, ingredients, required tool tag, station, craft time.
- `data/resource_nodes.json` — harvestable node kinds: hand yield vs tool-hit yield, capacity, regrow.
- `data/building_pieces.json` — building pieces: cost, snap mode, health, class, shelter value, footprint.

Name/description keys are derived: `ITEM_<ID>` / `ITEM_<ID>_DESC`, `NODE_<KIND>`.
Tests validate that every reference and every key exists.

## 5. Save format (version 1)

```json
{ "version": 1, "saved_at": 0, "label": "…",
  "world": { "time_hours": 12.0, "day": 1, "journal": [], "nodes": {"tree_12": {…}},
             "pickups": [], "structures": [] },
  "player": { "pos": [x,y,z], "yaw": 0, "pitch": 0, "stats": {…}, "inventory": {…} } }
```
`SaveManager._migrate()` upgrades older versions; newer-than-supported versions are refused.

## 6. Multiplayer readiness (not implemented)

Gameplay mutations go through explicit methods (`Inventory.add_item`, `perform_interaction`,
`ForestWorld.spawn_structure`) rather than UI code mutating state, so they can later become
server-authoritative RPCs. No networking exists yet.

## 7. Performance notes

Shared meshes/materials/shapes per resource kind; static terrain trimesh; no per-animal simulation yet.
Targets per GDD §17 are measured, not assumed.
