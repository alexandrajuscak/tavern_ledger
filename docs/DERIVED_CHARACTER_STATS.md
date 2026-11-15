# Derived character stats

Equipment, attunement and proficiencies change a character's Armor Class, speed, attacks and warnings. The database
calculates these numbers on demand. It never writes them back to the character, so the stored sheet values (base speed,
ability scores, the old `ac` column) stay exactly as the user entered them.

Migration: `supabase/migrations/20261015001400_derived_character_stats.sql`. Item data:
`supabase/seed/item_effects.sql`. Background and design decisions: [DERIVED_STATS_AUDIT.md](DERIVED_STATS_AUDIT.md).
Related: [ARMOR_CLASS.md](ARMOR_CLASS.md), [CHARACTER_PROFICIENCIES.md](CHARACTER_PROFICIENCIES.md), [LINEAGES.md](LINEAGES.md).

Since migration 20261015001500 the result also contains a **lineage layer** (ability increases, walking speed and other
movement modes, size, senses, languages, resistances, natural armor, natural weapons, lineage proficiencies, innate
spells and limited-use actions). Order: stored base values → lineage → items → manual overrides. Without a lineage the
result is exactly the one described below. Details: [LINEAGES.md](LINEAGES.md#calculation-order-derived-stats).

## Ruleset

D&D 5e, 2014 PHB / SRD 5.1 (`"ruleset": "dnd5e-2014"` in the result). 2024 rules are not mixed in.

## Sources of truth

| Data | Source |
|---|---|
| Equipped state | `character_equipment` (`inventory_items.equipped` is ignored) |
| Attunement | `inventory_items.is_attuned` |
| Armor, shield and weapon numbers | `armor_stats` / `weapon_stats` of the item, or else of its `base_item_id` |
| Proficiencies | `character_proficiencies` |
| Permanent item effects | `item_effects` (catalog level) and `item_modifier_effects` (instance level, e.g. Armor +1) |
| Result | `get_character_derived_stats(p_character uuid) returns jsonb` |

`get_character_derived_stats` is `SECURITY INVOKER`. RLS decides what it can see: the owner, the campaign DM and an
admin get a result; anyone else gets `42501 Character not found`. Private homebrew the caller can't see contributes
nothing and shows up as a `hidden_item` warning.

## Result shape (top level)

| Key | Contents |
|---|---|
| `proficiency_bonus` | `{value, source: "level", level}`. `value = (level - 1) / 4 + 2` |
| `abilities` | per ability: `base`, `score`, `modifier`, `override`, `bonus`, `sources` |
| `armor_class` | `value`, `calculated`, `override`, `source` (`calculated`/`override`), `legacy_stored`, `base_formula`, `breakdown[]`, `alternatives[]`, `inactive_effects[]` (see [ARMOR_CLASS.md](ARMOR_CLASS.md)) |
| `speed` | `base` (stored `characters.speed`), `value`, `breakdown[]` |
| `armor`, `shield` | the equipped piece and its stats and proficiency match, or `null` |
| `armor_consequences` | `nonproficient_armor`, `nonproficient_shield`, `ability_check_disadvantage`, `saving_throw_disadvantage`, `attack_disadvantage` (`["str","dex"]` or `[]`), `spellcasting_restricted`, `stealth_disadvantage`, `stealth_sources`, `strength_requirement_unmet`, `strength_requirement`, `strength_current`, `speed_penalty` |
| `saving_throws` | per ability: `item_bonus`, `disadvantage` |
| `skills` | `stealth` plus any skill an item affects: `advantage`, `disadvantage`, `sources` |
| `equipped_weapon_attacks[]` | one per weapon in `main_hand` / `off_hand` (see below) |
| `tools[]` | tools in the character's inventory with `proficient` |
| `proficiencies[]` | the character's proficiency rows with display names |
| `other_effects[]` | `resistance` and `carrying_capacity_bonus` effects: returned, not used yet |
| `effects[]` | every permanent effect with `active`, `inactive_reason`, `applied` |
| `warnings[]` | structured warnings (below) |

Every breakdown entry names its source (`source_type`, `source_id`, `item_id`, `source_name`), so the UI can explain
each number and link to the item.

## Item effects (`item_effects`)

One row per effect, keyed by `(item_id, seq)`.

| Column | Values |
|---|---|
| `effect_type` | `ac_bonus`, `attack_bonus`, `damage_bonus`, `save_bonus`, `ability_bonus`, `ability_override`, `speed_bonus`, `speed_penalty`, `resistance`, `carrying_capacity_bonus`, `skill_advantage`, `skill_disadvantage` |
| `target` | ability (`str` …), skill or damage type, depending on the type; validated by a trigger |
| `activation` | `owned`, `equipped`, `attuned`, `equipped_and_attuned` |
| `stacking` | `additive` (all count), `highest_only` (best per type and target), `non_stacking_group` (best per `stack_group`), `override` (the highest override; ability scores only, never below the base score) |
| `conditions` | `{"no_armor": true, "no_shield": true}` (Bracers of Defense) |

An effect that is not active has an `inactive_reason`: `not_equipped`, `not_attuned`, `wearing_armor` or `using_shield`.
Instance modifiers (`armor-plus-1`, `weapon-plus-1` …) work while the item is equipped, and also attuned if the item or
the modifier requires attunement. A weapon's own attack and damage bonuses apply to that weapon only.

Seeded effects (`item_effects.sql`): Ring of Protection, Cloak of Protection (+1 AC, +1 saves), Bracers of Defense
(+2 AC without armor or shield), Gauntlets of Ogre Power (Strength 19). All need the item equipped and attuned.

## Speed

`speed.value = characters.speed + speed_bonus effects - speed_penalty effects - 10 if the armor's Strength
requirement is not met`, never below 0. The stored base speed is not changed.

## Equipped weapon attacks

| Field | Rule |
|---|---|
| `ability` | finesse: the better of STR and DEX; ranged: DEX; otherwise STR (`ability_rule` says which) |
| `attack_bonus` | ability modifier + proficiency bonus (only if proficient) + magic attack bonuses |
| `damage` | dice + ability modifier + magic damage bonuses, e.g. `1d8 + 3` |
| `proficient`, `proficiency` | match by the specific item (or its base item) first, then the weapon group |
| `attack_disadvantage` | true while wearing armor or a shield without proficiency |

**Weapon cards (Play → Attacks, R-A, T7 `?v=40`, `js/weapon-card.js`, `js/weapon-icons.js`).** Each equipped weapon is a card
in the style of the spell cards. At a glance: icon, name, slot, damage-type chip, property chips (group, finesse, light,
versatile with its two-handed dice, heavy, two-handed, loading, thrown …), **Reach 5 ft** for a melee weapon (Reach (10 ft) with
the reach property), **Range normal / long** for ranged and thrown weapons, a **Magic +N** tag (or "+N to hit, +M damage") for the
weapon's own bonus, rarity / magic / attunement / infusion / modifier tags, To hit and Damage, the item description and the player's
notes, the weapon blocks (R-D2) and the unchanged "How this is calculated" breakdown. Like a spell card, the **name opens a details
dialog** (`openWeaponDetail`): type, To hit, Damage, two-handed dice, ability rule, reach, range, proficiency, slot, each property
explained, description, notes. Rules:
- The numbers come only from `equipped_weapon_attacks`; nothing is recomputed in the browser. The dialog reads nothing either.
- The item facts come only from the masked inventory data the sheet already has (the Inventory panel's rows and the
  character's knowledge read). An unidentified or partly identified copy shows its decoy name and description and the revealed
  facts only, never the derived `name` (that is the catalog name). Without the panel's data (fluent path before the Inventory tab
  was opened) the card shows the stored row's name only and gets the rest when the inventory loads; it never fetches anything.
- An equipped item in a hand whose catalog row the player cannot read (`hidden_item`) gets a card with its decoy and no numbers
  (unchanged; in practice every unidentified campaign weapon of a player takes this path).
- The magic tag sums the breakdown parts whose `source_id` is this inventory row (catalog effects, modifiers such as +1,
  infusions), never global bonuses. It is shown only for a copy the viewer knows.
- **Mastery is not shown:** no weapon mastery data exists in the derived read, the inventory view or the catalog (weapon mastery
  only appears as class / feat text). Adding it would need data and a read change, out of scope for a frontend release.
- Weapon blocks "Weapon actions", "Special", "Condition" (R-D2) come from derived `weapon_blocks`, absent for an unknown copy.
- Hooks kept for tests: `.entry.derived-weapon[data-weapon]`, `[data-attack-bonus]`, one `details[data-details]` / `<summary>`;
  new: `[data-action=weapon-detail][data-wpn-id]` (name button), `[data-wpn-magic]`, `.modal [data-wpn-detail]`.

**Weapon card icons (`js/weapon-icons.js`, pure, unit test `supabase/tests/js/weapon_icons.test.mjs`).** Only icons already in
the repo (the repo has no per-weapon art; candidates from outside the repo need the owner's licence check first). Resolution:
1. the DM's uploaded icon (`custom_icon`, docs/CUSTOM_ICONS.md), sent by the server only for a copy the viewer knows;
2. the item's own gallery key (`items.icon_key`, picked in the homebrew / Content editor), known copy only;
3. the base weapon map below, by the catalog item id;
4. the category: firearm group → `item.firearm`, ranged → `item.ammunition`, melee by damage type (slashing → sword,
   piercing → spear head, bludgeoning → hammer);
5. the generic weapon icon `item.weapons`.

Steps 2–4 run only when the derived row has an `item_id` (the server nulls it for a masked copy) **and** the masked inventory view
does not say `known: false`. The derived row of a masked copy still carries the true group, damage type and range, so even step 4
would leak: a masked copy gets only its decoy face's icon (`info.icon` from the masked inventory row) or the generic icon. The
weapon's name is never used for the icon. No database field, no extra query, no payload change.

| Icon (registry key → file) | Weapons |
|---|---|
| `slot.main-hand` → `equipment-slots/main-hand.webp` (sword) | longsword, shortsword, greatsword, rapier, scimitar, double-bladed scimitar; melee slashing fallback |
| `slot.off-hand` → `equipment-slots/off-hand.webp` (dagger) | dagger |
| `spell.damage.slashing` → `damage-types/slashing.webp` (broad blade) | handaxe, battleaxe, greataxe, glaive, halberd, sickle, whip |
| `spell.damage.piercing` → `damage-types/piercing.webp` (spear head) | spear, javelin, pike, lance, trident, yklwa, war pick, morningstar; melee piercing fallback |
| `item.weapons` → `items/weapons.webp` (war hammer) | club, greatclub, mace, maul, warhammer, light hammer, flail, quarterstaff; melee bludgeoning fallback; generic |
| `item.ammunition` → `items/ammunition.webp` (arrows) | longbow, shortbow, light / hand / heavy crossbow, dart, sling, blowgun, hoopak; ranged fallback |
| `item.firearm` → `items/firearm.webp` (flintlock) | palm pistol, pistol, musket, pepperbox, blunderbuss, bad news, hand mortar; firearm group fallback |

## Warnings

| Code | Severity | Meaning |
|---|---|---|
| `nonproficient_armor` / `nonproficient_shield` | warning | still counts for AC; disadvantage on STR/DEX checks, saves and attacks |
| `spellcasting_restricted` | warning | no spellcasting while wearing non-proficient armor or shield |
| `stealth_disadvantage` | info | the armor imposes disadvantage on Stealth |
| `strength_requirement_unmet` | warning | `required`, `current`, `speed_penalty: 10` |
| `armor_stats_unknown` | warning | the equipped armor or shield has no `armor_stats`; AC falls back to unarmored |
| `hidden_item` | warning | an equipped item is private homebrew the caller can't see |
| `legacy_equipped_ignored` | info | `count` of old free-text rows marked equipped; they have no effect |
| `nonproficient_weapon` | info | no proficiency bonus on that weapon's attack |

## Frontend

`js/inventory-api.js`: `getDerivedStats(characterId)`, `setCharacterProficiency(characterId, {group, item, enabled})`,
`getProficiencyGroups()`, `searchProficiencyItems(kind, query)`. `js/derived-ui.js` turns the result into text and
dialogs: `warningText`, `acNote`, `openAcBreakdown`, `equippedWeaponsHTML`, `toolsHTML`, `openProficiencyManager`.
The sheet re-reads derived stats after equip, unequip, attune, proficiency changes and Realtime updates of the
character, its equipment, inventory and proficiencies.

## Not modeled yet

- Class features (Unarmored Defense, Fighting Style: Defense), feats, Mage Armor, Barkskin and other temporary or
  combat effects. Use the manual AC override. (Lineage natural armor is calculated, see [ARMOR_CLASS.md](ARMOR_CLASS.md).)
- Two-weapon fighting: the off-hand attack still adds the ability modifier to damage.
- Saves and skills are still calculated in the browser; the server only adds item bonuses and (dis)advantage flags.
- `resistance` and `carrying_capacity_bonus` are returned but not used.
- 62 named magic armors and shields have no armor stats; only 4 catalog items have permanent effects; the homebrew
  editor can't author effects.

## Class feature layer (20261015001800)

`get_character_derived_stats` wraps the 1700 function (`_derived_stats_levels`). Class effects that the core understands
(ability bonus from an ASI, AC bonus with armor / shield conditions, save, speed, resistance, skill advantage) enter
through `_character_effects` with `source_type = 'class_feature'` (AC breakdown, inactive effects and ability sources show
them); `_proficiency_match` also matches class proficiencies. The wrapper adds: `skills.<k>.class_proficient` /
`class_expertise` (the sheet uses the highest of manual, lineage and class), `saving_throws.<k>.class_proficient`, class
proficiencies in `proficiencies` (`source_type = 'class'`), class languages, weapon-conditional attack / damage bonuses
(`class_attack_bonus`, `class_damage_bonus`), `feature_attacks`, `attacks_per_action`, `critical_range`, initiative
sources, immunities, unarmored AC formulas (`base_formula = 'class_feature'`), and `class_features` (applied effects,
warnings, resolution order). Stored character values are never changed. Details: [CLASS_FEATURE_ENGINE.md](CLASS_FEATURE_ENGINE.md).

## Wild Shape layer (20261017001300)

The public `get_character_derived_stats(c)` is now `_wild_shape_layer(c, _derived_stats_full(c))`. Without an active form
it returns exactly the previous result. In a form:

- **Abilities:** `abilities.str / dex / con` carry the form score. `form_score` and `form_name` are set, and `base` stays
  the character's own score (`_derived_stats_core`; nothing is overwritten).
- **Saves and skills:** `saving_throws[k].form_total` and `skills[k].form_total` hold the highest of your bonus, a gained
  form proficiency and the form's printed bonus. The sheet uses `form_total` when present.
- **Defense and movement:** `armor_class`, `speed`, `senses` (with Passive Perception) and the resistances come from the
  form.
- **Items:** only items **worn** by the form keep their effects (`_item_active_in_form`). Equipped weapons are listed only
  when they are active in the form.
- **`wild_shape`:** the full transformed sheet (see [TRANSFORMATION_ENGINE.md](TRANSFORMATION_ENGINE.md)).
