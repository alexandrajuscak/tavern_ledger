# Spell data model

Migration `20261015001600_spell_catalog.sql`. All catalog tables are read-only for clients (select for `anon` and
`authenticated`); character tables are written only through security-definer RPCs.

## Catalog

| Table | Purpose |
|---|---|
| `spell_schools` | 8 schools (inserted by the migration) |
| `catalog_spells` | canonical spell (slug id). `owner_id` null = official; set = homebrew, optionally shared with `campaign_id` |
| `spell_versions` | one published version: mechanics, source book / label / URL, `status` current/legacy, `rule_status` official/playtest/homebrew, `source_marker` (dunamancy, graviturgy, chronurgy, technomagic), `setting`, `superseded_by_version_id`, `parse_notes` |
| `spell_effects` | structured effects per version (`seq`): category (damage, healing, temp_hp, condition, ...), mechanism, timing, dice, flat modifier, `adds_spell_mod`, damage mode, half on save, scaling (character level / slot level, dice, base) and `automation` |
| `spell_effect_damage_types` | possible damage types of one damage effect |
| `spell_damage_type_links` | per version, damage types `always` or by `choice` (for filtering) |

### `spell_versions` fields

- **Casting time**: `casting_time_raw`, `casting_time_unit` (action, bonus_action, reaction, minute, hour, special),
  `casting_time_amount`, `reaction_trigger`.
- **Range / area**: `range_raw`, `range_type` (self, touch, sight, unlimited, distance, special), `range_distance`,
  `range_unit`, `area_shape`, `area_size`.
- **Duration**: `duration_raw`, `duration_type`, `duration_amount`, `duration_unit`, `requires_concentration`.
- **Components**: `components_raw`, V/S/M flags, `material_text`, `material_cost_gp`, `material_consumed`,
  `components_parse_status` (`uncertain` when the text could not be parsed reliably).
- **Resolution**: `mechanism` (attack, save, automatic, check, multiple, none, unresolved), `attack_type`,
  `save_ability`, `has_higher_levels`, `automation` (automated, partially_automated, informational, unresolved).
- `is_ritual`, `level` (0 = cantrip), `school_id`.

Raw text is always kept next to parsed values; a value that cannot be parsed is null and noted, never guessed.

### Visibility

`can_view_spell(spell_id)`: official rows for everyone (including anonymous); homebrew rows for the owner, an admin and
members of the linked campaign. Every catalog policy (versions, effects, damage links) goes through it, and
`set_character_spell` refuses a spell the caller cannot see.

### Read model

- `v_spell_catalog` (security_invoker): flat list for the picker and filters, with `damage_types`, `damage_choice`,
  `class_lists` (array of list ids, query with `class_lists=cs.{artificer-spell-list}`), `scope` and `search_text`.
- `get_spell_detail(version)`: everything a spell card needs, including effects and class lists.

## Class foundation

`classes`, `class_versions`, `class_spell_lists`, `class_spell_list_entries`, `spell_slot_progressions`,
`spell_slot_progression_levels` (populated by `classes.sql` since migration 1700). See [CLASS_FOUNDATION.md](CLASS_FOUNDATION.md).

## Character tables

| Table | Purpose |
|---|---|
| `character_spellcasting_sources` | a source of spells on a character: type (class, subclass, feat, item, manual, other), label, class version and spell list, casting ability and allowed alternatives, fixed DC / attack, bonuses, preparation and ritual mode, slot use, class level / progression (future), `enforce_spell_list`, `always_prepared_allowed`, `is_preview` |
| `character_spells` | one grant: source + spell version, `known`, `prepared`, `always_prepared`, counts-against-limit flags, `uses_spell_slot`, `ritual_allowed`, casting ability override, notes. Unique per (source, spell version) |

Since migration 1700 a source can belong to a character class (`character_class_id`): it then follows the class
(version, list, preparation, ability default) and is removed only with the class. A trigger on `character_spells`
enforces the class's spell level, cantrip availability and prepared limit for such sources
([SPELLCASTING_SOURCES.md](SPELLCASTING_SOURCES.md)).

Lineage spells are **not** stored: they come from `lineage_trait_effects.spell_version_id` through `_lineage_effects`.
Deleting a source deletes its grants; deleting the character deletes both. Both tables are in the Realtime publication.

The old `spells` (free-text) and `spell_slots` tables are unchanged and still used.

## Functions

| Function | Kind |
|---|---|
| `get_character_spellbook(character)` | read; RLS (owner, campaign DM, admin). Returns `sources`, `spells` (merged per version, all grants kept), `unresolved_grants`, `free_text_spells` (with `catalog_match`), `slots` |
| `save_character_spellcasting_source(character, source)` | write; rejects unknown keys (e.g. `character_id`, `created_by`) |
| `delete_character_spellcasting_source(source)` | write |
| `set_character_spell(character, source, version, known, prepared, always_prepared, casting_ability, ritual_allowed, notes)` | write; upsert |
| `set_character_spell_prepared(character_spell, prepared)` | write |
| `remove_character_spell(character_spell)` | write |
| `_spell_stat`, `_spell_summary`, `_character_spell_grants` | helpers |

Errors: `42501` for not found / not allowed, `22023` for invalid input (message is user-readable).

## Rollback

`supabase/rollback/rollback_spells.sql` removes only this feature (tables, functions, view, the lineage column, the
migration record) and keeps free-text spells and slots. It refuses to run while the class level feature (1700) exists:
run `rollback_class_levels.sql` first. `rollback_lineages.sql` refuses to run while the spell tables exist.
`rollback_inventory.sql` covers versions up to 1700.
