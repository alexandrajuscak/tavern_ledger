# Fighter implementation plan (next task)

Input for implementing the Fighter (class version `fighter-phb`, Player's Handbook 2014, levels 1–20) and one simple
subclass on the generic engine ([CLASS_FEATURE_ENGINE.md](CLASS_FEATURE_ENGINE.md)). Nothing here is seeded yet.
Summaries in the catalog must be project-authored and short; mechanics are structured; each feature links its source.

## Features by level

| Level | Feature | Engine representation | Automation |
|---|---|---|---|
| 1 | Proficiencies (starting) | effects `proficiency`: saves STR, CON (`primary_class`); groups light / medium / heavy armor, shields (heavy armor `primary_class`), simple and martial weapons; choice `skill` ×2 from Acrobatics, Animal Handling, Athletics, History, Insight, Intimidation, Perception, Survival (`primary_class`). Multiclass grants (light + medium armor, shields, simple + martial weapons) as `applies_to = multiclass` / `always` | automated |
| 1 | Fighting Style | choice `option` (group `fighting-style`, `replaceable`): Archery (`attack_bonus` +2, weapon `ranged`), Defense (`ac_bonus` +1, armor `worn`), Dueling (`damage_bonus` +2, weapon `one_handed_melee_only`), Great Weapon Fighting (informational), Protection (informational), Two-Weapon Fighting (informational until off-hand attacks are modelled) | partially automated |
| 1 | Second Wind | resource `fixed 1`, `short_or_long_rest`; scaling `healing` = `1d10 + fighter level` (shown, HP not changed) | partially automated |
| 2 | Action Surge | resource table `[[2, 1], [17, 2]]`, `short_or_long_rest` | automated (tracking) |
| 3 | Martial Archetype | choice `subclass` (selection level 3) | automated |
| 4, 6, 8, 12, 14, 16, 19 | Ability Score Improvement | one repeatable feature version (`asi`, `allow_feat`), seven unlocks | partially automated (feats: placeholder) |
| 5 | Extra Attack | `extra_attack` 1 (min 5), 2 (min 11), 3 (min 20); scaling `attacks` `[[5,2],[11,3],[20,4]]` | automated |
| 9 | Indomitable | resource table `[[9, 1], [13, 2], [17, 3]]`, `long_rest` (reroll a save: the reroll itself is the player's) | automated (tracking) |
| 11, 20 | Extra Attack (more attacks) | same feature, higher `min_level` effects (no separate unlock needed) | automated |
| 13, 17 | Indomitable (more uses) | same resource table | automated |
| 17 | Action Surge (two uses) | same resource table | automated |

TCE optional class features (optional unlocks, `is_optional`): additional fighting styles (Blind Fighting, Interception,
Superior Technique, Thrown Weapon Fighting, Unarmed Fighting — as options of the same choice with
`source_status = optional_rule`) and Martial Versatility (optional feature at the ASI levels: replace a fighting style /
maneuver; uses the `replaceable` choice; the change itself is a normal choice edit).

## Proposed first subclass: Champion (PHB)

| Level | Feature | Representation | Automation |
|---|---|---|---|
| 3 | Improved Critical | `critical_range` 19 | automated |
| 7 | Remarkable Athlete | needs "half proficiency bonus to STR / DEX / CON checks without proficiency" + running jump | informational (gap below) |
| 10 | Additional Fighting Style | second instance of the fighting-style choice (subclass unlock with its own choice; options must differ from the first: validation note) | partially automated |
| 15 | Superior Critical | `critical_range` 18 (the lowest wins) | automated |
| 18 | Survivor | regain HP at the start of the turn under half HP | informational |

## Required reusable feature types (all exist)

Level unlocks, repeatable ASI unlocks, option choice with option-bound effects, skill choice, subclass choice, resources
(fixed / table), short-rest and long-rest recovery, `extra_attack`, `critical_range`, conditional attack / damage / AC
bonuses, proficiency grants with `primary_class` / `multiclass`, scaling tables, informational effects.

## Expected resources

Second Wind 1 (short or long rest) · Action Surge 1 → 2 at 17 (short or long rest) · Indomitable 1 / 2 / 3 at 9 / 13 / 17
(long rest).

## Expected choices

Two skills (first class only), Fighting Style, Martial Archetype at 3, seven ASIs, Champion's Additional Fighting Style
at 10, Martial Versatility (optional).

## Known limitations / remaining gaps before Fighter

1. **Half proficiency to checks** (Remarkable Athlete; also Bard Jack of All Trades) is not an effect type yet. Adding a
   `skill_half_proficiency` effect (applied by the derived layer to skills without proficiency) is additive and needs no
   redesign. Until then: informational.
2. **The two fighting-style choices** (base + Champion 10) must not pick the same option; validation across choices is a
   small addition to `_cf_choice_error` (config `distinct_from`).
3. Second Wind healing and Survivor do not change hit points (no HP automation by design).
4. Great Weapon Fighting and Two-Weapon Fighting stay informational (reroll rules; no off-hand attack modelling).
5. Official proficiency data for the 11 other classes is not seeded; only Fighter will be.

None of these is a blocker for the Fighter base class; items 1 and 2 are small additions to make during the task.

## Test plan

- SQL: Fighter 1–20 unlock table (features active per level), Fighting Style options and their effects (Archery bow +2,
  Defense in armor +1, Dueling one weapon +2), Second Wind / Action Surge / Indomitable maximums at 1, 2, 9, 13, 17,
  short / long rest behaviour, Extra Attack 2 / 3 / 4, seven ASIs incomplete until chosen, Champion critical 19 → 18,
  multiclass Fighter grants (no saving throws), level decrease preserves choices, export / import.
- API: owner / DM / outsider, choices, resources, rests, preview.
- Browser: Fighter on a new character, choices, resources on the Resources tab, Combat attack count and critical range.
- Local demo: turn "Local Hero" (Fighter 3) into a full Fighter demo with Champion.
