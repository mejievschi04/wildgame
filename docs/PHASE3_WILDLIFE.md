# Phase 3 — wildlife: deer (prey) & wolf (predator), hunting, tracking, combat

## Assets (built in Blender — user decision 2026-11-21)
`tools/blender/gen_animals.py`: skin-modifier body over an anatomical joint graph, subdivided, vertex-colour coat
(dark dorsal saddle, pale belly, white rump on deer, dark muzzle) × scanned leather normal detail; 22-bone named
rig with automatic weights; procedural clips idle / walk / run / graze / alert / attack / death (glTF NLA tracks).
Output `assets/models/animals/SK_Deer.gltf` (~10.7k tris), `SK_Wolf.gltf` (~8.9k tris). Semi-realistic at mid
distance; close-up they read as smooth sculpts (no fur cards) — upgrade path: fur shells or hand-sculpted meshes.

## AI (`world/animal.gd`, data `data/animals.json`)
| | |
|---|---|
| Perception | sight (range × player visibility, FOV, line of sight), hearing (player noise: sprint 1.0, walk 0.45, crouch 0.12, + bursts from chopping/gathering/jumping/throwing), **smell only downwind** (weather wind direction) |
| Visibility | crouch ×0.55, night ×0.5 (torch ×1.3), fog lowers it |
| Deer | IDLE/GRAZE/WANDER → ALERT (looks at you) → FLEE (alarms herd mates within 35 m) → RECOVER; flees when hurt |
| Wolf | PATROL → SUSPICIOUS → INVESTIGATE last known position → CHASE only with a reason (hungry, night, weak player, provoked) → ATTACK with 0.45 s wind-up, 1.6 s cooldown, bleeding chance; **gives up** after 22 s / 45 m (then calm 60 s); **retreats** below 40 % health; **fears fire/torches**; hunts deer (kills leave half the meat) |
| Movement | faces where it moves, probes ahead for obstacles, water and map edge; unsticks itself; no teleporting |
| Population | `world/wildlife.gd`: ≤8 deer in herds of 2–4, ≤3 wolves; spawned 55–110 m away, despawned beyond 165 m; only carcasses are saved |
| Tracking | `world/tracks.gd`: hoof/paw decals every ~1.1 m, fade over ~1.25 game days; look at the ground to read «Следы: олень · ~N мин назад» |

## Player
- Melee: equipped item damage (spear 30, axe 18, knife 14, stone 6, fist 3) on creatures.
- Spear throw: with the spear in hand **hold RMB** to aim (zoom), **LMB** to throw (48 dmg × speed); the spear wears and lies on the ground to be picked up.
- Wolf bites: damage, knock-back, possible bleeding (bandage cures), screen shake (respects «reduce motion»), red flash.
- HUD: subtle arc above the reticle — ochre when an animal notices you, red when a predator is hunting you.
- Carcasses: butcher with a knife (deer: 6 meat, 2 hides, 3 bones; wolf: 3/1/2). The riverside POI now shows a deer model.

## Tests
`tests/test_wildlife.gd` (9): wind-dependent smell, noise/visibility, herd flight, predator give-up & retreat, wolf bite,
hunt + butcher loot + journal, spear throw damage + wear, director limits & spawn distance, carcass persistence.

## Known limitations
- Animals have no navmesh (local steering only) and can get briefly stuck in dense trees.
- No hit-location damage, no limping/blood trails yet; tracks show species and age, not direction arrows.
- Human NPCs / factions (rest of Master-Prompt Phase 3) are not implemented yet.
