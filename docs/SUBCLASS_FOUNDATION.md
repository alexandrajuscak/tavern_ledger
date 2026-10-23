# Subclass foundation

Part of the class feature engine ([CLASS_FEATURE_ENGINE.md](CLASS_FEATURE_ENGINE.md)).

## Model

- `subclasses`: canonical identity (id, class, name, scope).
- `subclass_versions` (from 1700, extended): `subclass_id`, `class_version_id` (parent class version; `null` = any
  version of the class), `selection_level` (`null` = the class version's `subclass_level`), source book / label / URL,
  status current / legacy, `superseded_by_version_id`, `setting`, `requires_dm_permission` + `dm_permission_note`,
  `implementation_status` (`progression_only`, `features_partial`, `partial`, `complete`), `content_scope`, notes.
  The 1700 spellcasting columns (Eldritch Knight, Arcane Trickster) are unchanged.
- `class_versions.subclass_level`: when the class chooses its subclass (seed `class_features.sql`: Cleric, Sorcerer,
  Warlock 1; Druid, Wizard 2; the others 3).
- Subclass features are ordinary `class_feature_unlocks` with `subclass_version_id`: the same choices, resources,
  effects, spell grants (always-prepared subclass spells), scaling and replacement rules as class features. A subclass
  unlock may replace (`replace`) or change (`modify`) a feature of its class. Companion and transformation templates are
  future engines; their features would be informational until then.

## Selection

`character_classes.subclass_version_id` (one active subclass per class row). Chosen through
`set_character_subclass(character, class row, subclass)` (it calls `set_character_class`, which also sets up a
subclass spellcasting source). Rules (trigger `character_classes_before_write`):

- the subclass must belong to the class (and to the class version when the subclass names one);
- a **newly** chosen subclass needs the selection level;
- a subclass already chosen is **kept** when the level drops below the selection level or the class version changes.

Never auto-selected, never silently deleted.

## Status (read model)

| Status | Meaning |
|---|---|
| `not_yet` / `available` | no subclass; below / at or above the selection level (warning `subclass_not_chosen` when the catalog has features for the class) |
| `active` | chosen and level reached; subclass features resolve |
| `below_level` | kept, inactive (warning `subclass_below_level`) |
| `incompatible` | kept, belongs to another class version (warning `subclass_incompatible`); its features are inactive |

The class feature "Subclass" (choice kind `subclass`) shows the selection inside its feature card; it is complete when a
subclass is chosen.

## Content

Official subclass content: only the canonical rows of Eldritch Knight and Arcane Trickster (progression only). The
synthetic "Test Path" (test fixture) exercises the engine.
