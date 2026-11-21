# Art pass 1 — semi-realistic environment (CC0 scans + Blender)

Direction (user, 2026-11-21): **semi-realism, not cartoon**; target 60 FPS @ 1080p on Apple M4 (balanced).

## Pipeline (reproducible)
| Step | Tool | Output |
|---|---|---|
| Download CC0 scans | `tools/polyhaven.py texture|model <id> [res]` | `art_source/` (git-ignored) + `docs/ASSET_CREDITS.md` |
| Props: weld, decimate to budget, origin bottom-centre, alpha MASK | `blender -b --python tools/blender/process_props.py` | `assets/models/{rocks,trees,plants,ground,props}/SM_*.gltf` |
| Foliage cards rendered from scanned saplings/shrubs (RGBA albedo) | `tools/blender/bake_cards.py` | `assets/models/trees/textures/T_*Card_D.png` |
| Procedural trees: spruce, Scots pine, alder (bark scans + cards, custom normals) | `tools/blender/gen_trees.py` | `SM_Spruce_0[1-3]`, `SM_Pine_0[1-2]`, `SM_Alder_0[1-2]` (1.5–3k tris) |
| Terrain layer atlases (Texture2DArray, 6×2K) | `tools/blender/terrain_arrays.py` | `assets/textures/terrain/T_Terrain_{albedo,normal,arm}.jpg` |
| Lookdev render in Blender | `tools/blender/preview.py -- out.png a.gltf …` | preview PNG |

## In engine
- `world/asset_lib.gd` — asset lists + cached loading; foliage gets backlight translucency.
- `world/shaders/terrain.gdshader` — forest floor / grass / mud / rock / river pebbles / snow, blended by a
  forest-density mask (from tree positions), height, slope, macro noise; anti-tiling; wet shoreline.
- `world/shaders/water.gdshader` — depth colour, scrolling normals, refraction, soft shoreline.
- `world/vegetation.gd` — chunked MultiMesh grass & ferns with visibility ranges; fallen trunks, stumps,
  mossy rocks, branches, shrubs.
- Resource nodes use real assets (trees → stumps when felled, mossy rocks, flint nodules, shrub-sprig berry bushes,
  branch piles, stone piles). Campfire = scanned stone fire pit; storage = scanned wicker basket.
- Building pieces, bed, tools, old camp: primitives with scanned PBR materials (`Graybox.tex()`: Log, Wattle,
  Thatch, Leather, Rock).
- Lighting: AgX tonemapping, SSAO, volumetric fog, soft sun shadows.

## Performance (measured, window 1600×900, M4, frontmost window, vsync off)
| Config | FPS |
|---|---|
| Old: MSAA 2× + alpha-to-coverage, 4096 shadows | 33 |
| TAA, 4096 shadows | 51 |
| **Medium preset**: TAA, 2048 shadow atlas, 65 m, 2 splits | ~60 (vsync on: 54–60) |
Shadow atlas size was the dominant cost (alpha-tested foliage cards in the shadow pass).
Presets Низкое/Среднее/Высокое + AA (FXAA/SMAA/TAA/MSAA) + upscaler (FSR2/MetalFX) are in Settings → Видео.
Main-menu camera (whole valley in view) runs ~45 FPS at Medium.

## Still placeholder / next
- Deer carcass, mushrooms, dropped-item boxes, item icons (colour + initials).
- Building pieces & tools are textured primitives, not modelled meshes; no first-person hands.
- No wind animation on foliage yet; no impostors for distant trees.
- Sounds: placeholders — the user will supply final audio.

## Art pass 2 (items, icons, wind)
- `tools/blender/gen_items.py` builds a model for **every item** (23) from scanned textures — knapped flint
  and axe heads via convex hulls, bark/willow handles, leather bindings, food, waterskins — and renders a
  256 px inventory icon for each (`assets/icons/T_Icon_<id>.png`).
- Items use these models in the hand (per-item hold pose), on the ground (pickups) and on the campfire.
- `world/shaders/foliage.gdshader`: alpha-tested foliage with translucency + wind sway driven by global
  shader uniforms `wind_strength` / `wind_direction` (set by weather).
- Still placeholder: deer carcass (replaced by the deer model in Phase 3), building pieces are textured
  primitives (not sculpted meshes), no first-person arms.
