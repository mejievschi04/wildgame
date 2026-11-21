# Combat & dismemberment

Inspired by survival-horror melee (e.g. The Forest): weighty, readable, brutal. The GDD originally asked for
"moderate violence"; the user chose realistic gore, so it is on by default with a toggle:
**Settings → Игра → «Кровь и расчленение»** (off = no severing, minimal blood).

## Player melee (`player/player.gd`)
| Input | Action |
|---|---|
| LMB click | light attack (style per weapon: axe chop, knife slash, spear thrust, fist) |
| LMB hold ≥ 0.4 s, release | **heavy attack**: ×1.8 damage, ×1.8 stamina, staggers, breaks guards |
| RMB (no spear) | **block**: −75 % damage from the front, costs stamina; 0 stamina breaks the guard |
| RMB just before a hit (≤ 0.25 s) | **perfect parry**: no damage, attacker staggered 1.2 s |
| RMB with spear / LMB | aim / throw the spear |
Hits resolve at impact time; a short **hit-stop** (time slows for 40–70 ms) sells the weight.

## Hit locations (`core/body_regions.gd`)
The region is the nearest bone segment to the impact point: head ×2.5, torso ×1, arms ×0.7, legs ×0.75
(animals: head ×2.2). Each human region has its own health.

## Dismemberment (humans, `world/human_npc.gd`)
- Only **cutting** weapons (axe) sever; spear and knife pierce/cut but don't take limbs off.
- When a region's health hits 0: **head** → instant death; **forearm** → drops weapon, bleeds, flees;
  **shin** → falls and bleeds out. Corpses can be dismembered too.
- The skinned body hides the bone chain (`SeveredBones` skeleton modifier, runs after animation);
  a flesh cap + pulsing blood follows the parent bone; the severed part (rest-pose mesh with clothing
  and a flesh-capped cut, exported by `gen_humans.py` → `assets/models/humans/parts/`) flies off as a rigid body.

## Wounds & AI
- Leg wounds → limp (speed ×0.55); forearm wound → drops the spear (pick it up!).
- Bleeding drains health over time and leaves blood drops; wounded animals leave a **blood trail** for 2 min (tracking).
- Armed NPCs: circle you between attacks, raise their guard when they see you winding up (blocks 65 %,
  a heavy blow staggers through it), get staggered by heavy hits and parries, retreat below 40 % health.

## Tests
`tests/test_combat.gd` (7): region mapping, headshot ×2.5 + decapitation, axe vs spear severing + disarm + bleeding,
gore toggle, corpse dismemberment, block/parry/NPC guard, limp + blood trail.

## Limitations
- Severing is by region (head / forearm / shin), not arbitrary cuts; no upper-arm/thigh cuts yet.
- No ragdolls — death is an animation; detached parts are rigid bodies with box colliders.
- Animals take hit-location damage and bleed, but are not dismembered.
