# Asset Bible — WILDBOUND: Primal Age (GDD §13)

All current 3D/2D content is **PLACEHOLDER graybox** built from primitives in code
(`world/graybox.gd`, `player/hand_models.gd`, item icons = colour + initials). Every placeholder
is marked in code comments and in item tooltips (`[временная модель]`).
No third-party models are imported. Third-party CC0 audio is listed below; any future import
must list its source + licence here.

## Pipeline
Blender 5.x → **glTF 2.0 (.glb)** (Godot-native; FBX only if a DCC requires it) → `assets/` → import
→ collision → LOD → in-game test with `tests/run_tests.sh` + an AutoShot screenshot.

## Naming
| Prefix | Use | Example |
|---|---|---|
| `SM_` | static mesh | `SM_Tree_Pine_A.glb` |
| `SK_` | skinned mesh | `SK_Hunter_Male_A.glb` |
| `T_` | texture (`_D` albedo, `_N` normal, `_ORM` occlusion/roughness/metal) | `T_Rock_Granite_ORM.png` |
| `M_` / `MI_` | master material / material instance (`.tres`) | `MI_Bark_Pine.tres` |
| `AN_` | animation | `AN_Deer_Flee.res` |

## Scale, origin, orientation
- 1 Blender unit = 1 m (Godot); authoring reference in **centimetres** — apply scale before export.
- +Y up, −Z forward (Godot); in Blender export with "+Y Up".
- Origin at ground contact, centred (trees: trunk base; items: centre of mass; doors: hinge).

## Collision
- Simple primitives preferred (`-col` / `-colonly` suffix convention on glTF import).
- Trees: trunk cylinder only, canopy none. Rocks: convex hull. Structures: boxes per module.
- Layers: 1 world · 2 player · 3 soft interactables (bushes, piles, pickups) · 4 water (ray-only).

## LOD / performance
- LOD0 hero character 35–60k tris (GDD, benchmark-adjusted); props ≤ 3k; trees LOD0 ≤ 8k + impostor at distance.
- Use Godot auto-LOD on import + visibility ranges; MultiMesh for grass/small rocks.

## UV & materials
- UV0 non-overlapping for unique textures; UV1 lightmap only if baked lighting is adopted.
- PBR metal/rough; texel density ~512 px/m props, 1024 px/m hero; dirt/wear via detail masks.

## Rigs & animation
- Humans: one shared humanoid skeleton (Godot `SkeletonProfileHumanoid` retarget compatible).
- Animals: per-species skeleton; required clips: idle, walk, trot/run, graze, alert, flee, attack (predators), hit, death.
- Root motion off by default; locomotion blendspaces driven by speed.

## Replacing a placeholder
1. Export `SM_*.glb`, drop into `assets/models/...`.
2. In the relevant builder (e.g. `ResourceNode._build`) swap the Graybox primitives for `preload("res://assets/...glb").instantiate()`; keep collision shapes.
3. Set `"placeholder": false` for the item in `data/items.json` and add its icon.

## Audio
Every `Sfx.NAMES` event now loads a sound file; `core/sound_synth.gd` remains the fallback if an
asset fails to load. Replacement rules:
- Format: WAV 16-bit, 44.1 kHz; mono for positional sources and ambience loops.
- Naming: `SFX_<Category>_<Name>_<Variant>` (e.g. `SFX_Step_Wood_03.wav`), ambience `AMB_*`, music `MUS_*`.
- Keep the `Sfx.NAMES` keys; swap `SoundSynth.build()` output for `load()`ed streams with random variants.
- Every imported sound lists its source and licence in this file (CC0 or own recordings only).

### Integrated CC0 sound files
- `assets/audio/SFX_Step_Grass_000.wav`–`SFX_Step_Grass_004.wav` and `SFX_Step_Wood_000.wav`–`SFX_Step_Wood_004.wav` — Kenney, Material Impacts & Footsteps, CC0 1.0; randomized across grass and wood footfalls. Official pack: https://kenney.nl/assets/impact-sounds. Samples retrieved via https://instrictlogic.com/AssetLibrary/sounds/banks/material-impacts-footsteps-kenney-2362a2f7/
- `assets/audio/SFX_Chop_001.wav` — Kenney, RPG Audio, CC0 1.0; `SFX_Chop_002.wav`–`SFX_Chop_003.wav` and `SFX_Build_*.wav` — rubberduck, wood impacts; `SFX_Step_Water_*.wav`, `SFX_Stone_Knock_*.wav`, `SFX_Tool_Break_*.wav`, and `SFX_Collapse_001.wav` — rubberduck, Foley, Weather & Environmental Loops and Everyday Foley & Mechanical SFX, CC0 1.0; includes wet steps, wood and stone impacts, timber break sounds, and a layered wood-and-stone fall. Sources: https://kenney.nl/assets/rpg-audio, https://instrictlogic.com/AssetLibrary/sounds/banks/foley-weather-environmental-loops-rubberduck-2dbd2ff0/ and https://instrictlogic.com/AssetLibrary/sounds/banks/everyday-foley-mechanical-sfx-rubberduck-03d5f8b0/
- `assets/audio/SFX_Rustle_*.wav`, `SFX_Whoosh_*.wav`, `SFX_Place_*.wav`, `SFX_Dismantle_*.wav`, `SFX_Tree_Creak_*.wav`, and `SFX_Door_*.wav` — Kenney, RPG Audio, CC0 1.0; cloth, knife-slice, book-place, creak, and wooden door foley. Official pack: https://kenney.nl/assets/rpg-audio. The falling tree now uses a creak event before its impact instead of a door sound.
- `assets/audio/SFX_Craft_*.wav` and `SFX_Pop_*.wav` — rubberduck, Everyday Foley & Mechanical SFX, CC0 1.0; tool-handling and plop variants. Source: https://instrictlogic.com/AssetLibrary/sounds/banks/everyday-foley-mechanical-sfx-rubberduck-03d5f8b0/
- `assets/audio/SFX_UI_Click_*.wav` — Kenney, Interface Clicks, Buttons & Notifications, CC0 1.0. Source: https://instrictlogic.com/AssetLibrary/sounds/banks/interface-clicks-buttons-notifications-kenney-26bde112/
- `assets/audio/SFX_Eat_001.wav` — Luthien22, “Chewing Food Crunchy”, recorded foley, CC0 1.0; shortened for a single eating action. Source: https://sfxfree.com/sound/fs-244370-chewing-food-crunchy
- `assets/audio/SFX_Drink_001.wav` — anagar, “Human Water Gulp Swallow”, recorded foley, CC0 1.0; trimmed for a single drink action. Source: https://sfxfree.com/sound/fs-267932-human-water-gulp-swallow
- `assets/audio/SFX_Fire_Ignite.wav` — qubodup, “Flare ignition”, recorded match ignition and accelerated, CC0 1.0. Source: https://opengameart.org/content/flare-ignition
- `assets/audio/SFX_Hurt_001.wav`–`SFX_Hurt_006.wav` — Lasse Bührmann (EmoPreben), “Pain sounds”, recorded vocal foley, CC0 1.0; randomized with reduced playback level. Source: https://opengameart.org/content/pain-sounds-by-emopreben
- `assets/audio/AMB_Wind_Loop.wav` — SketchMan3, “wind whoosh loop”, CC0 1.0; wind loop prepared from an OpenGameArt ambient recording. Source: https://opengameart.org/content/wind-whoosh-loop
- `assets/audio/AMB_Birds_Loop.wav` — isaiah658, “Ambient Bird Sounds”, CC0 1.0; crossfaded at the end for continuous playback. Source: https://opengameart.org/content/ambient-bird-sounds
- `assets/audio/AMB_Crickets_Loop.wav` — Wolfgang_, “Crickets Ambient Noise - loopable”, CC0 1.0. Source: https://opengameart.org/content/crickets-ambient-noise-loopable
- `assets/audio/AMB_Rain_Loop.wav` — Kresiek the Furry, “AMB Rain Loop 1”, CC0 1.0. Source: https://opengameart.org/content/amb-rain-loop-1
- `assets/audio/SFX_Axe_Chop_09.wav` — SFXMint, “Stump Block Axe Chopping Wood 09”, AI-generated, CC0 1.0; used on tree impacts. Source: https://sfxmint.com/sounds/axe-chopping-wood-09
- `assets/audio/SFX_Axe_Chop_05.wav` — SFXMint, “Glancing Axe Chopping Wood 05”, AI-generated, CC0 1.0; used when an axe swing misses. Source: https://sfxmint.com/sounds/axe-chopping-wood-05
- `assets/audio/AMB_Campfire_Crackle.wav` — SFXMint, “Steady Burning Fireplace Crackling 50”, AI-generated, CC0 1.0; prepared loop used by campfires. Source: https://sfxmint.com/sounds/ambience-fireplace-50
- Original downloaded stereo files are preserved in `assets/audio/source/`; runtime copies are downmixed to mono for 3D positioning.
