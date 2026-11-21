# Asset Bible — WILDBOUND: Primal Age (GDD §13)

All current 3D/2D content is **PLACEHOLDER graybox** built from primitives in code
(`world/graybox.gd`, `player/hand_models.gd`, item icons = colour + initials). Every placeholder
is marked in code comments and in item tooltips (`[временная модель]`).
**No third-party or copyrighted assets are imported.** Any future import must list source + licence here.

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
Most sounds remain **procedural placeholders** (`core/sound_synth.gd`); the selected replacements are listed below. Replacement rules:
- Format: OGG Vorbis (loops) / WAV 16-bit (short one-shots), 44.1 kHz, mono for 3D sources.
- Naming: `SFX_<Category>_<Name>_<Variant>` (e.g. `SFX_Step_Wood_03.wav`), ambience `AMB_*`, music `MUS_*`.
- Keep the `Sfx.NAMES` keys; swap `SoundSynth.build()` output for `load()`ed streams with random variants.
- Every imported sound lists its source and licence in this file (CC0 or own recordings only).

### Integrated CC0 sound files
- `assets/audio/SFX_Axe_Chop_09.wav` — SFXMint, “Stump Block Axe Chopping Wood 09”, AI-generated, CC0 1.0; used on tree impacts. Source: https://sfxmint.com/sounds/axe-chopping-wood-09
- `assets/audio/SFX_Axe_Chop_05.wav` — SFXMint, “Glancing Axe Chopping Wood 05”, AI-generated, CC0 1.0; used when an axe swing misses. Source: https://sfxmint.com/sounds/axe-chopping-wood-05
- `assets/audio/AMB_Campfire_Crackle.wav` — SFXMint, “Steady Burning Fireplace Crackling 50”, AI-generated, CC0 1.0; prepared loop used by campfires. Source: https://sfxmint.com/sounds/ambience-fireplace-50
- Original downloaded stereo files are preserved in `assets/audio/source/`; runtime copies are downmixed to mono for 3D positioning.
