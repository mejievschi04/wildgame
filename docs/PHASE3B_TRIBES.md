# Phase 3b — people & tribes (GDD §7, Act II)

## People (Blender + MPFB)
`tools/blender/gen_humans.py` builds 5 NPC bodies with the MPFB (MakeHuman) add-on — M1/M2/M3 (men, one older),
F1/F2 (women, one older) — with the UE-style `game_engine` rig. Macro morphs are baked; helper geometry removed
(eyes kept). Clothing is **cut from body regions** (tunic with a flared hem, leggings, foot wraps), relaxed to hide
anatomy, thickened, textured with the scanned leather; a hair/hood shell on the crown and nape, beards on some men.
Clips (rotations authored in armature space): idle, walk, run, alert, gesture (open palm), attack (spear thrust),
sit (by the fire), death. ~58k tris each (Godot generates LODs). Armed NPCs carry the spear item model on `hand_r`.

## Tribes (`data/factions.json`, `world/factions.gd`)
| Faction | Temper | Start | Camp | Wants (offering value) | Gives (barter) |
|---|---|---|---|---|---|
| Nomad hunters | wary, armed | 0 | east (92, 62) | flint, hide, wood, stone | dried meat, spear, bandage |
| Territorial clan | territorial (34 m), armed | −15 | north-west, palisade | cooked/dried meat, hide | flint, knife, torch |
| Gatherers | peaceful, unarmed | +20 | south (−35, 78) | sticks, fibre, raw meat, flint | berries, cooked mushrooms, bandage, waterskin |

Relation −100…+100 → stance: hostile ≤ −40 < wary < 10 ≤ neutral < 50 ≤ friendly. Saved with the world.

## Behaviour (`world/human_npc.gd`)
- Perception only: sight (range × player visibility, 210° FOV, line of sight), hearing (player noise); they see your gesture.
- Routine: idle / sit by the fire / patrol / gather around camp.
- Noticed player → SUSPICIOUS → INVESTIGATE, by temper:
  - gatherers greet (open palm) or flee; never fight;
  - hunters keep distance (WARN when wary and close), greet when neutral+, fight when hostile;
  - clan: inside their territory → **WARN** (caption: shout + "leave" gesture); ignored for 6 s while close → trust −12 and **COMBAT**.
- Combat: spear thrust with 0.55 s wind-up, 18 dmg + bleed chance; give up after 25 s / 35 m / when you leave the territory;
  flee when below 40 % health. Attacking one rallies armed kin within 40 m (gatherers flee). Kills: −60 trust; the dead stay dead.

## Diplomacy (no shared language)
- **T — open-palm gesture**: if seen within 25 m, +4 trust (once per 45 s per tribe), calms warnings.
- **E — offering**: give the item they value most that you carry → trust + value.
- **R — barter** (trust ≥ 10): give one wanted item, receive one of their goods.
- Sleep is refused next to wary/hostile armed strangers or while a predator hunts you.
- Journal: an entry per tribe when first met; meeting all three opens Act II ("Три народа").

## Tests
`tests/test_tribes.gd` (7): camps & fires, clan warn → attack, gesture rate-limit + offering + barter, rally/flee on
aggression, NPC spear hit, discovery journal + sleep safety, persistence of relations/discoveries/deaths.

## Limitations
- Bodies are realistic but skin/clothes are untextured-by-hand (flat skin tone, leather), hair is a shell (no strands),
  faces have no expressions; NPC hands hold the spear rigidly.
- No pathfinding — NPCs move in straight lines inside their camps; no NPC-vs-wolf fights yet.
- Barter is one-for-one; no quests yet (Act II goal: find where your group went).

## Hominin races (concept sheet) — step 1: Homo sapiens (2026-11-22)
The six races follow the user's concept sheet: Heidelbergensis, Neanderthal, Homo sapiens, Denisovan,
Homo erectus and "Homo antiquus". The player is Homo sapiens. Generator: `tools/blender/gen_hominins.py -- SapiensM SapiensF`,
about 60 s per model. It reuses the rig, clips and severable parts from `gen_humans.py`.
- Body: MPFB macros + species morph targets; **5 facial-expression blend shapes** (`expr_focused`, `expr_angry`,
  `expr_surprised`, `expr_pain`, `expr_happy`) mixed from MakeHuman expression units.
- Skin is baked on the MakeHuman UVs: mottling, pores, forehead wrinkles by age, dirt on hands and feet, lips and eyelids (from MPFB masks),
  eyebrows, the concept's white face paint, and a hair-coloured scalp and beard base under the strands.
- Eyes: spheres with a generated iris texture (sclera, iris streaks, limbal ring, pupil).
- Hair and beard are strand cards on a thin-strand atlas. They hug the scalp down to ear level, then fall and collide with the body and
  clothes (BVH), and are kept off the face. Their weights blend from the head to the body under the strand.
- Clothing per the concept: fur mantle (or one-shoulder fur for women), crossed leather straps, belt and wrist wraps as
  surface ribbons, slit hide kilt/skirt with a jagged hem, a hide top for women, fur boots, and a cord necklace with teeth. Fur garments carry fur cards.
- In game: the gatherers tribe is now Homo sapiens (`SapiensF`, `SapiensM`). NPC strand cards use the shared fur-card
  material path (alpha scissor, no shadows); skin gets subsurface scattering.
- Preview: `tools/blender/preview_face.py` (expression sheet), web bestiary "Oameni" section.
- Budget: M ≈ 124k tris including hair and fur cards (body + clothes ≈ 47k), F ≈ 89k. That's above the sheet's 25–40k; a hair-card LOD
  pass is the follow-up.
