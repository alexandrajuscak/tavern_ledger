# Derived character stats: audit

This audit covers the state of the code before the derived-stats feature (migration `20261015001400`) was added.
It is limited to what that feature touches.

## Ruleset

The repository has no edition or ruleset field. The catalog (`supabase/seed/reference_data.sql`, generated from the
wikidot 5e datasets) and `js/dnd.js` (an SRD 5.1 weapon table, `profBonus = ceil(level / 4) + 1`) both follow **D&D 5e
(2014 PHB / SRD 5.1)**. The feature implements those rules and does not mix in 2024 rules. In particular:

- an armor Strength requirement that isn't met costs 10 ft of speed;
- wearing armor or a shield without proficiency gives disadvantage on Strength and Dexterity checks, saves and
  attacks, and prevents spellcasting;
- a finesse weapon uses the better of Strength and Dexterity.

## What exists

| Concern | Where | Notes |
|---|---|---|
| Armor Class | `characters.ac int not null default 10` | A **manual, stored** number. It's editable in the Combat tab (`numInput('ac')`) and nothing calculates it. |
| Ability scores | `characters.strength … charisma` (int 1–30) | Modifiers are calculated in the browser: `mod()` in `js/dnd.js`. |
| Level / proficiency bonus | `characters.level` (1–20) | The browser derives the proficiency bonus: `profBonus(level)`. Nothing stores it. Multiclassing isn't modeled; `level` is the total level. |
| Speed | `characters.speed int default 30` | A stored, editable number. It's a reliable **base speed**. |
| Saving throws | `characters.save_proficiencies` jsonb `{str: true}` | Calculated in the browser. |
| Skills | `characters.skill_proficiencies` jsonb | Calculated in the browser. There's no advantage/disadvantage model. |
| Armor and weapon proficiencies | `characters.equipment_proficiencies` jsonb `{light, medium, heavy, shields, simple, martial}` | Set by the Stats-tab chips and by JSON import/export (`js/transfer.js`). There's no firearms or specific-item proficiency. |
| Tool and other proficiencies | `characters.proficiencies` text | Free text, not structured. |
| Attacks | `attacks` table, filled in manually | `proficient` boolean, `ability` (str/dex/finesse/spell/none), `magic_bonus`. The browser calculates to-hit and damage. The rows aren't linked to inventory. |
| Equipment | `character_equipment` (slot table, PK `character_id, slot_id`) | **The single source of truth.** Written only by `equip_item` / `unequip_item`. `inventory_items.equipped` is a read-only projection. |
| Attunement | `inventory_items.is_attuned` | Written by `attune_item` / `unattune_item`. A limit of 3 is enforced. |
| Armor data | `armor_stats` | Already separates `base_ac` (armor) from `ac_bonus` (shield) with a check constraint, plus `dex_modifier_mode` full/capped/none, `dex_cap`, `strength_requirement`, `stealth_disadvantage` and `is_shield`. **No change needed.** |
| Weapon data | `weapon_stats` (+ `weapon_property_links`, `firearm_stats`) | `weapon_group` simple/martial/firearm, `is_ranged`, damage dice and type, properties (finesse, versatile, two-handed …). |
| Magic armor, weapons and shields | `item_modifiers` + `item_modifier_effects` | Applied to inventory instances through `inventory_item_modifiers`, e.g. `armor-plus-1` → `ac_bonus 1`, `weapon-plus-1` → `attack_bonus 1` and `damage_bonus 1`. |
| Permanent item effects | **missing** | Ring and Cloak of Protection and Bracers of Defense have no structured data. Only `consumable_effects` exist, and they're for one-shot use. |
| Named magic armor and shields (Sentinel Shield, Mithral Armor …) | `items` (kind armor) **without** `armor_stats` and without `base_item_id` | A data gap: their AC can't be derived. |
| Realtime | `subscribeCharacter` (`js/store.js`) | Listens to `characters` and the child tables, including `inventory_items` and `character_equipment`. |

The read policies on the affected tables: `characters`, `character_equipment` and `inventory_items` follow
`can_access_character` / `can_read_inventory`, which allow the owner, the campaign DM and an admin. Catalog tables
follow `can_view_item`, which lets players see private homebrew only if it's their own.

## Conflicting or legacy fields

- `characters.ac` is a manual value, and it would conflict with a calculated AC. It is **kept** and shown as
  "Previously entered AC" only when it differs. It never silently overrides the calculation. Characters whose AC
  comes from features the app doesn't model (Unarmored Defense, natural armor …) get a new, explicit,
  nullable `characters.ac_override`.
- `characters.equipment_proficiencies` is the old proficiency store. It stays readable as a **mirror**
  of `character_proficiencies`, kept in sync by triggers, so JSON import/export and cached sheets keep working.
- `inventory_items.equipped` is already only a projection. The calculation ignores it. A legacy row (one with no
  catalog item) flagged as equipped produces a warning and has no effect.
- `attacks.proficient` and `attacks.magic_bonus` stay as they are: they belong to custom attacks. Equipped weapons get a
  derived attack representation, which isn't a second stored attack.

## Proposed source of truth

| Data | Source of truth |
|---|---|
| Equipped state | `character_equipment` |
| Attunement | `inventory_items.is_attuned` |
| Armor, shield and weapon numbers | `armor_stats` / `weapon_stats` for the item itself or, failing that, its `base_item_id` |
| Proficiencies | `character_proficiencies` (new) |
| Permanent item effects | `item_effects` (new, catalog level) + `item_modifier_effects` (instance level) |
| Derived AC, speed, warnings and weapon attacks | `get_character_derived_stats(character)` (new, read-only, RLS) |

## Required migration (`20261015001400_derived_character_stats.sql`)

1. `proficiency_groups`: a lookup of simple-weapons, martial-weapons, firearms, light-armor, medium-armor,
   heavy-armor and shields, mapped to `weapon_stats.weapon_group` and the armor `category_id`.
2. `character_proficiencies`: a group **or** a specific item (weapon, armor, shield or tool), with a source and notes.
   It's filled once from the existing `equipment_proficiencies` flags, because those are explicit user data.
3. Mirror triggers between `characters.equipment_proficiencies` and `character_proficiencies`.
4. `item_effects`: permanent effects with an activation mode (owned / equipped / attuned /
   equipped_and_attuned), a stacking rule and validated targets.
5. `characters.ac_override` (nullable).
6. `set_character_proficiency` (SECURITY DEFINER, explicit authorization).
7. `get_character_derived_stats` (SECURITY INVOKER, so RLS applies).
8. RLS, grants, and the Realtime publication for `character_proficiencies`.

The data for well-known items goes in a separate seed file, `supabase/seed/item_effects.sql`. Migrations run
before the catalog seed, so these rows can't be in the migration.

## Required frontend changes

- `js/inventory-api.js`: `getDerivedStats`, `setCharacterProficiency`.
- `js/sheet.js`:
  - the Combat tab AC tile shows the derived AC, with a breakdown dialog and a warning line;
  - speed shows the derived value;
  - a new "Equipped weapons" section;
  - the Stats-tab proficiency chips call the RPC and gain a "Manage proficiencies" dialog for specific weapons, armor and tools;
  - derived stats refresh on equipment, attunement, proficiency and relevant character changes, including over Realtime.
- `js/store.js`: subscribe to `character_proficiencies`.
- `js/inventory-ui.js`: call back after each refresh so the sheet re-reads derived stats, and show a
  "Not proficient" note next to equipped items.

## Data gaps (not fixed in this task)

- 62 named magic armors and shields have no `armor_stats` and no `base_item_id`. If one is equipped, the result is
  the warning `armor_stats_unknown`, and AC falls back to the unarmored formula.
- Class, race and background proficiencies aren't structured, so nothing is inferred from `class_name`.
- Only the 4 items in `item_effects.sql` (Ring of Protection, Cloak of Protection, Bracers of Defense, Gauntlets of
  Ogre Power) have permanent effects. Every other magic item has none yet.
- The homebrew editor can't author permanent effects yet. Homebrew armor, shield and weapon stats do work.
