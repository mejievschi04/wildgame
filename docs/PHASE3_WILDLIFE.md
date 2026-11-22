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


## Fauna art pass 2 — realistic procedural animals (2026-11-21)
Five species, generated in Blender (no downloaded assets): `blender -b --python tools/blender/gen_animals.py -- [wolf deer roe bear mammoth]`
(~30 s each). Library: `tools/blender/fauna_lib.py`; species data: `gen_animals.py` (wolf), `species_more.py` (others).

| Step | What |
|---|---|
| Anatomy | signed-distance sculpt: smooth union of tapered capsules + ellipsoids (ribcage, brisket, scapulae, haunches, flank folds, skull, cheeks, muzzle, jaw, ears), eye sockets subtracted → surface-nets mesh → smoothed, decimated to 12–20k tris |
| Coat | per-vertex region rules (saddle, belly, rump patch, muzzle, eye rims, nose leather, hooves/pads) × fur-strand noise → Cycles bake: albedo (× baked AO), tangent normal (strand bump), roughness — 2k PNGs in `assets/models/animals/textures/` |
| Fur | alpha-tested hair cards rooted on the body (ruff, mane, mammoth skirt up to 1 m, bear shag), strand atlas generated per species; cards take their root's skin weights; in game: two-sided, no shadow casting, hidden beyond 70 m |
| Parts | glossy eyes, mammoth tusks, bear claws (rigid to head/feet bones) |
| Rig/clips | same bone names as before (+ mammoth trunk `snout2-4`); clips idle/walk/run/graze/alert/attack/death with stance/swing leg cycles, lateral-sequence walk, gallop (wolf/deer/bear) or amble (mammoth), trunk sway |

Preview: `blender -b --python tools/blender/preview_animal.py -- out.png assets/models/animals/SK_Bear.gltf [clip] [frame]`.
In-game check: `godot --path . res://scenes/game.tscn -- --autoshot=/abs/out.png --shot-scenario=fauna --shot-hour=10`
(prints `FAUNA_GROUND` = body height above terrain; must be ~0).

| Species | Diet / behaviour | Notes |
|---|---|---|
| Roe deer «Косуля» | prey, herds of 1–3 (≤5) | fastest runner, 3 meat |
| Cave bear «Пещерный медведь» | predator, **territorial** (engages inside 14 m), does not hunt deer | 260 HP, 32 dmg swipe, high bleed chance, 14 meat |
| Woolly mammoth «Шерстистый мамонт» | **defensive**: grazes, charges a player within 9 m or one who hurts it, calms after 9 s | 900 HP, 55 dmg tusk toss, fears fire, 40 meat |

Fixes in this pass: animals used to sink until the belly capsule touched the terrain (deer legs ~0.5 m underground,
mammoth ~1 m) — a ground-contact sphere now carries them. Wolves only hunt `prey` species. Creature death causes are
per species (`DEATH_BEAR`, `DEATH_MAMMOTH`).

Tests added (3): every species loads with all 7 clips and shadowless alpha fur; mammoth charges then calms, and turns
on an attacker; bear is territorial and doesn't hunt; wolves skip mammoths but take roe.

Limitations: procedural sculpts read as realistic at gameplay distance; in extreme close-ups faces are simpler than
hand-sculpted assets.

### Pass 2b — nine more species, one commit each (2026-11-22)
Species files: `species_mega.py` (rhino, bison, horse, lion, boar, hare), `species_more.py` (+ Megaloceros, reindeer),
`gen_animals.py` (+ fox, a rescaled wolf).

| Species | Diet | Notes |
|---|---|---|
| Woolly rhino «Шерстистый носорог» | defensive, charges at 12 m (poor eyesight) | flattened front horn ~1 m, 600 HP |
| Steppe bison «Степной бизон» | defensive, charges at 6 m, herds 3–5 | dark mane/beard, tawny rear, curved horns |
| Wild horse «Дикая лошадь» | prey, herds 3–6, fastest (12.5 m/s) | Przewalski dun, erect mane, mealy muzzle |
| Giant deer «Большерогий олень» | prey, 220 HP — too big for wolves | palmate antlers ~3.4 m span |
| Cave lion «Пещерный лев» | predator, territorial 10 m, hunts prey ≤ 250 HP | maneless, winter ruff, pounce |
| Wild boar «Кабан» | defensive, charges at 7 m | bristle crest, tusks |
| Reindeer «Северный олень» | prey, herds 3–6 | white neck mane, swept antlers |
| Red fox «Лиса» / Brown hare «Заяц-русак» | prey, solitary | small game (1 meat / 1 hide) |

Director: `Wildlife.MAX_TOTAL = 24` live animals; species flagged `"common"` (deer, roe) are topped up first, the rest
in seeded-random order. Wolves skip prey above `max_prey_health` (160). With all 14 species in view: ~43 FPS (same as
an empty scene on the M4 at 1600×900).
