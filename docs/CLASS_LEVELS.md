# Character classes and levels

Class and Spellcasting Foundation (migration `20261015001700_class_levels_and_slots.sql`, seed `supabase/seed/classes.sql`).
A character selects one or more explicit class versions with a level each; the total level, proficiency bonus, spell
slots and spell access follow from those rows. Class features come from the generic class feature engine
([CLASS_FEATURE_ENGINE.md](CLASS_FEATURE_ENGINE.md), migration 20261015001800); its official catalog is still empty.

Related: [SPELL_SLOTS.md](SPELL_SLOTS.md) · [RESOURCES_AND_RESTS.md](RESOURCES_AND_RESTS.md) ·
[CLASS_FOUNDATION.md](CLASS_FOUNDATION.md) · [CLASS_PROGRESSION_COVERAGE.md](CLASS_PROGRESSION_COVERAGE.md) (generated) ·
audit: [CLASS_LEVEL_AND_SLOT_AUDIT.md](CLASS_LEVEL_AND_SLOT_AUDIT.md).

## Source of truth

```
character_classes (class version + level [+ subclass version])
  + class_versions / class_version_levels / subclass_versions / spell_slot_progressions
  = total level, proficiency bonus, effective caster level, slot maximums, spell access, limits   (computed on read)
```

Only runtime state is stored (expended slots, temporary slots, resources, events). Nothing derived is copied to the
character, with one documented exception: `characters.level`.

### `characters.level` (legacy, kept as a mirror)

- With class rows, a trigger sets `characters.level` to the sum of the class levels, so every existing consumer
  (derived stats, lineage level gates, XP prompt, hit dice, exports, the character list) uses the class total.
- A hand edit that conflicts with the classes is refused ("The level of … comes from its classes").
- Without class rows the stored level is used and reported as a **fallback** (`level_source = 'legacy'`).
- Adding the first class defaults its level to the current level, so the total does not jump. Removing the last
  class keeps the last level as the fallback. Nothing existing is overwritten silently.

### Proficiency bonus

`(total level − 1) / 4 + 2`, computed by the server. `get_character_derived_stats` now returns
`proficiency_bonus.{value, source: 'total_level', level, level_source, fallback}` and a `level` object; every value that
uses it (weapon attacks, Spell Save DC, spell attack, lineage uses, resources tied to PB) follows a class change. The
front end shows the server value (the old `profBonus(level)` helper is only a fallback while loading).

## Data

| Table | Purpose |
|---|---|
| `class_versions` | + `hit_die`, `rules_label`, `multiclass_contribution` (`full`, `half_down`, `half_up`, `third_down`, `pact`, `none`), `spellcasting_start_level`, `prepared_formula`, `is_pact_magic`, `multiclass_prerequisite`, `implementation_status`, `limitations` |
| `class_version_levels` | per class level: proficiency bonus, cantrips known, spells known, highest spell level, Pact slots and slot level |
| `subclass_versions`, `subclass_version_levels` | one-third casters (Eldritch Knight, Arcane Trickster): spellcasting progression only |
| `character_classes` | `character_id`, `class_id` (from the version), `class_version_id`, `subclass_version_id`, `level` 1-20, `is_primary`, `started_at_level`, `notes` |
| `character_spellcasting_sources.character_class_id` | the class source of a spellcasting class row (created or adopted automatically) |

12 class versions: Artificer (TCE) and the PHB Bard, Cleric, Druid, Fighter, Monk, Paladin, Ranger, Rogue, Sorcerer,
Warlock, Wizard. Every version id is explicit and stable; a character keeps its version until the user changes it.
There is no "newest version wins" rule, and 2014 / 2024 rules are never mixed into one version.

Rules enforced by the database: level 1-20; total at most 20; one row per class (the same class twice is refused; a
different version of a class the character has must be changed explicitly on that row); a subclass must belong to the
class; one primary class (the first class becomes primary; marking another moves it).

## Write path (RPCs only)

| RPC | |
|---|---|
| `set_character_class(character, class_version, level, subclass_version, is_primary, character_class, notes)` | adds a class, or changes level / subclass / primary of the row of that class; pass `character_class` to change the version |
| `remove_character_class(character_class, confirm)` | removes the row, its slot contribution and its class source; refuses without `confirm` when the source has spells; manual, item, feat and lineage spells stay |

Spell choices are never deleted by a level change: spells above the new level stay and are reported
(`spell_above_class_level` warning) for the player to review.

## Read model

`get_character_class_summary(character)`: total level, level source / fallback, proficiency bonus, one entry per class
(version, rules label, source, status, hit die, primary, subclass, contribution with raw and rounded value, and for
spellcasting classes: ability, spell list, preparation and ritual mode, start level, highest spell level, cantrips
known, spells known, prepared limit, counts, over-limit flags, spells above the level, limitations), the multiclass
breakdown, effective caster level, slot maxima, Pact Magic, resources, warnings and the foundation's limitations.
Read access: owner, campaign DM, admin (RLS).

## Multiclass prerequisites

Parsed from each class page ("You must have a … score of 13 or higher in order to multiclass …") into
`multiclass_prerequisite`. Shown as **warnings only** for characters with more than one class; never enforced.

## UI

- **Bio → Classes** ("Class and Spellcasting Foundation"): total level, proficiency bonus, caster level; one row per class
  with version, rules label, source link, hit die, level select, contribution, spell access and limits; Add class,
  Make primary, Version / subclass, Remove. Lowering a level, removing a class and changing a version ask first and say
  what changes. Without classes the card explains the legacy level.
- The Bio **Level** field becomes read-only ("Set by your classes") while classes exist.
- **Level Up** asks which class gains the level, applies it through `set_character_class`, uses that class's hit die and
  skips the manual spell slot step. Characters without classes keep the old wizard.
- The header subtitle shows "Wizard 3 / Warlock 2".

## Not in this phase

Class features, subclass features and expanded lists, Wild Shape, companions, familiars, infusions, invocations, Pact
Boons, Sorcery Points / Font of Magic, Metamagic, Arcane Recovery, Channel Divinity, Ki, Rage, maneuvers, HP level-up
automation (the Level Up wizard still proposes HP), ASI / feats, multiclass proficiencies, prerequisite enforcement.

## Class feature engine (20261015001800)

- **Level changes are reviewed first.** Changing a class level on Bio (and changing a class version) opens a review built
  by `preview_character_class_change` (computed in a rolled-back savepoint): features activated / deactivated, new and
  inactive choices, resources, slots, spell access, proficiency bonus, subclass status, warnings. The change is applied
  only after confirmation.
- **Subclass level.** A subclass is chosen at its selection level (`class_versions.subclass_level` or the subclass
  version's own level); an existing subclass is kept when the level drops (inactive, flagged). Test M10 of
  `class_slot_tests.sql` now chooses Eldritch Knight at Fighter 3 before lowering to 2.
- Lowering a level keeps choices, subclass and resource state; they become inactive and are flagged, never deleted.
