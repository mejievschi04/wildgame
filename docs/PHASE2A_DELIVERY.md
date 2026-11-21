# Phase 2a delivery — modular building + sound layer

Date: 2026-11-21 · Commits: `Phase 2a-1` (building), `Phase 2a-2` (audio)

## Building (GDD §9)
| Requirement | Implementation |
|---|---|
| Ghost placement + validation | `player/build_controller.gd` — green/red ghost, reason shown in HUD (uneven ground, water, occupied, no socket, no support, too close) |
| Optional snapping | Foundations snap to a neighbour's 2 m grid; **G** toggles snapping (free placement + rotation with **R**) |
| Material requirements, resources delivered in stages | Placing creates a **blueprint** (free); hold **E** with a stone/axe to deliver whatever materials you carry; it becomes solid when complete |
| Foundations → pillars/walls → roof | Walls/doorways on foundation edges, pillars on corners, door in a doorway, roof on top when ≥2 walls/pillars support it |
| Structural support | Support graph (`supported_by`); removing a piece collapses dependents that lose all support (25 % refund dropped on the ground) |
| Repair / dismantle with partial refund | **E** repairs damaged pieces (+40 % per primary material); hold **R** dismantles (blueprint: full refund, built: 50 %) |
| MVP pieces | Foundation, wattle wall, doorway, door, pillar, thatch roof, fence, storage basket (12 slots), drying rack, lean-to |
| Radial build menu | **B** — mouse, keyboard focus or gamepad D-pad; shows cost vs. what you carry |
| Shelter matters | Lean-to +6 °C; roofed foundation +5 °C, +2 °C per wall (max 3). Feeds body temperature and sleep checks |
| Persistence | Pieces, blueprint progress, health, supports, door state, storage contents, drying progress |

## Sound (GDD §14)
- `core/sound_synth.gd` generates all 24 sounds **procedurally** at startup (~120 ms): footsteps per surface
  (grass/wood/water), gathering rustle, chop, stone knock, swing, pickup, craft, place/build/dismantle/collapse,
  door, eat/drink, fire ignite + crackle loop, tool break, hurt, UI click; ambient wind, day birds, night crickets.
- Original, licence-free, and clearly **placeholder** — to be replaced by recorded/CC0 sounds (see Asset Bible).
- Volumes go through the Master/SFX buses (Settings → Звук). Important sounds show **captions** when
  Settings → Доступность → Субтитры is on.

## Manual test (≈8 min)
1. New game; gather ~10 sticks, ~10 fibres, a few stones; craft a stone axe; chop 4 wood.
2. Press **B** → «Настил» → aim at flat ground → LMB. A translucent blueprint appears. Look at it, hold **E** → materials delivered.
3. **B** → «Плетёная стена»: aim at the floor edge → it snaps; place 3 walls + «Стена с проёмом»; **B** → «Дверь из прутьев» into the doorway.
4. **B** → «Кровля из травы»: invalid until 2 walls exist, then snaps on top. Deliver materials to all blueprints.
5. Stand inside at night: the cold warning should disappear sooner than outside; you can sleep without a fire if the room is closed.
6. **E** on the door opens/closes it (creak). Hold **R** on a wall → dismantled, 50 % back. Hold **R** on the floor → everything on it collapses (rumble), materials drop.
7. Build a «Плетёный короб», store items, save, load → contents intact. Hang raw meat on a «Сушильная рама» → dried meat after ~10 min.
8. Listen: footsteps change on the wooden floor and in the river; birds by day, crickets at night, crackling near a lit fire.

## Automated tests
`./tests/run_tests.sh` — 46 tests (+7 building, +3 audio).

## Known limitations
- I verified sounds by analysis (non-silent, no clipping, correct loop flags) and by running the game — **not by listening**. Mix levels need a human pass.
- No weather yet, so nothing damages buildings except dismantling/collapse (damage + repair are implemented and tested).
- Snapping covers single-storey buildings; no stairs, ceilings or second floors. Roofs are flat-pitched single tiles.
- Furniture on floors is only supported by the floor beneath (no wall-mounted items).
- Fire spreading to buildings is not simulated yet.

## Next incremental task (proposal)
Phase 2b — **basic weather**: rain/wind/cold snaps affecting body temperature, extinguishing exposed fires,
slowly damaging unroofed pieces and wet clothing; shelter blocks rain. Then Phase 3 (prey + predator AI).
