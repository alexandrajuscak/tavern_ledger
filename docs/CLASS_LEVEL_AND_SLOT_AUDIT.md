# Class level and spell slot audit

Focused audit before building character class levels, spell slot progression, Pact Magic and the rest engine
(migration `20261015001700`). Scope: what exists, what is missing, what conflicts, and the decisions taken.

## Current schema (before this task)

| Area | What exists | Notes |
|---|---|---|
| `characters.level` | int 1-20, edited by hand (Bio tab, Level Up wizard, import) | the only level; no per-class levels |
| `characters.class_name`, `subclass` | free text | shown in the header, the character list and exports |
| `characters.hit_die`, `hit_dice_current` | one die type, a counter | the Level Up wizard and the front-end long rest change them |
| Proficiency bonus | `get_character_derived_stats`: `(greatest(level,1)-1)/4 + 2` from `characters.level`; the front end also has `profBonus(level)` for the free-text spell DC and the Level Up preview | backend value is used for attacks, Spell Save DC, lineage limited uses |
| Lineage level gates | `_lineage_effects` compares `min_level` with `characters.level` | |
| `classes`, `class_versions` | 9 spellcasting classes, one current 2014 version each (ability, preparation mode, ritual mode, `caster_type`, `slot_progression_id` null, `spell_list_id`) | written by `supabase/seed/spells.sql`; no hit die, no contribution rule, no start level, no per-level data |
| `class_spell_lists`, entries | 9 lists, 1,543 entries | |
| `spell_slot_progressions`, `_levels` | tables, **empty** | `(progression_id, class_level, slot_level, slots)` |
| `character_spellcasting_sources` | class sources are `is_preview`; `class_level`, `progression_id` columns unused | no link to a character class |
| `character_spells` | known / prepared / always prepared, counters flags | no level eligibility, no limits |
| `spell_slots` | manual `total` / `used` per level 1-9 | edited on the Spells tab and in the Level Up wizard |
| `feature_trackers` | free resources: `current`, `max`, `reset_on` short / long / none | no source, no formula, no event log |
| Rest | **front end only** (`sheet.js rest()`): short rest restores `reset_on = short` trackers; long rest restores HP, temp HP, death saves, half the hit dice, all trackers and the manual slots | not transactional, no audit, no Pact Magic |
| Audit models | `inventory_events` (use, transfer) | pattern reused for resource events |
| JSON export / import | `level`, `class`, `subclass`, `hitDice`, `spellSlots` (manual), `resources` (trackers), spellcasting sources and catalog spells | no class rows |
| Tests / runners | SQL (inventory, derived, lineage, spell), API 129, browser 5 suites; 17 migrations; seeds reference_data, item_effects, spells, lineages | |

## Missing relationships

- No `character_classes` (character ↔ class version ↔ level), so no total level from classes and no multiclassing.
- Class spellcasting sources are not tied to a class row (cannot be removed with the class, cannot know their class level).
- No per-level class data (cantrips known, spells known, slots, Pact Magic, max spell level).
- No contribution rule for multiclass slots; no subclass versions (one-third casters).
- No runtime slot state separate from maximums; no resource engine with sources, formulas and events.

## Conflicts and legacy fields

| Conflict | Decision |
|---|---|
| `characters.level` is hand-edited, class levels would be a second truth | `character_classes` is authoritative when rows exist. `characters.level` stays as a **compatibility mirror**: a trigger sets it to the sum of class levels, and a guard rejects a different hand-edited value while class rows exist. Characters without class rows keep the legacy value (fallback, reported as such). Nothing existing is overwritten until the user adds a class; the first class defaults to the current level so the total does not jump. |
| Front-end `profBonus(level)` | stays only for the legacy free-text DC and the Level Up preview; it reads the mirrored level, so it agrees with the backend |
| Manual `spell_slots` vs derived slots | derived maximums are authoritative for characters with spellcasting classes; the manual tracker stays for characters without them (labelled legacy) and is never deleted |
| Preview class sources from the spell foundation | adding a class adopts an existing unlinked preview source of the same class version (spells kept); otherwise a new linked source is created |
| Front-end rest | replaced by `short_rest_character` / `long_rest_character` (slots, Pact Magic, resources, trackers, manual slots, temporary slots; transactional, audited, idempotent). HP, temp HP, death saves and hit dice keep the existing explicit front-end long-rest behaviour, applied after the RPC succeeds. |
| Level Up wizard writes `level` and slot totals | with class rows it asks which class gains the level, calls `set_character_class`, and skips the manual slot step |
| Artificer multiclass rounding | Black Citadel says "half, rounded down"; Tasha's Artificer multiclassing rule is "half, rounded up", and the Artificer single-class table equals the standard table at ⌈level / 2⌉ for every level (validated by the generator). Decision: `half_up`, conflict recorded. |
| No multiclassing page on dnd5e.wikidot.com (404) | the standard multiclass spellcaster table is the full-caster table from the class pages; cross-checked against Black Citadel |

## Source-of-truth recommendation

```
character_classes (class version + level [+ subclass version])
  + class_versions (contribution rule, start level, casting rules)
  + class_version_levels (per-level cantrips / spells known / max spell level / Pact Magic)
  + spell_slot_progressions (standard, single-class, Pact Magic tables)
  = total level, proficiency bonus, effective caster level, slot maximums, limits   (computed on read)
runtime only: character_spell_slot_state (expended), temporary slots, character_resources (expended), resource_events
```

## Migration requirements

- New migration `20261015001700_class_levels_and_slots.sql`; new seed `supabase/seed/classes.sql` (after `spells.sql`,
  before `lineages.sql`), generated from the cached class pages.
- `class_versions`: add hit die, rules label, contribution rule, spellcasting start level, prepared formula, Pact Magic
  flag, implementation status. Add Fighter, Monk, Rogue (non-casting) so multiclass characters can be represented.
- `get_character_derived_stats` is wrapped (renamed base + new function) to add the level source; rollback restores it.
- Spell eligibility and prepared limits are enforced by a trigger on `character_spells`, so the 1600 spell RPCs are not
  replaced.

## Frontend impact

Bio: new "Class and Spellcasting Foundation" card; level input becomes read-only when classes exist. Spells: new Slot
Tracker (standard + Pact Magic panels, Short / Long Rest, manual adjust), class sources show class level, max spell
level and limits. Header rest buttons call the backend. Level Up wizard: class-aware. Realtime: new character tables.

## JSON import / export impact

Export gains `classes` (class version, level, primary, subclass version), `slotState` (expended standard / pact) and
`characterResources`. Import recreates classes through the RPC (unknown versions become a warning and the legacy
`class` text stays), then slot state. Older files keep working (`level`, `class`, manual `spellSlots`).

## Rollback impact

`rollback_class_levels.sql` removes only this feature: new tables, functions, triggers, columns, the derived-stats
wrapper (the base is renamed back), the Fighter / Monk / Rogue rows and seeded progressions; `characters.level` keeps
its last mirrored value. `rollback_spells.sql` refuses to run while this feature exists; `rollback_inventory.sql`
covers 1700.

## Unresolved class-version questions

- Only the 2014-aligned versions in the repository (PHB; Artificer TCE). No 2024 versions are created; the model
  supports them as separate `class_versions` rows (`rules_edition`).
- Optional class features (TCE "Optional class features") are not modelled.
- Wizard spellbook size (spells copied) is not tracked; only the prepared formula applies.
- Eldritch Knight / Arcane Trickster exist only as spellcasting progression data (no features, no school limits).

## Scope exclusions

Class features, subclasses (beyond the two one-third progressions), subclass expanded lists, Wild Shape, companions,
familiars, infusions, invocations, Sorcery Points and Font of Magic, Metamagic, Arcane Recovery, Channel Divinity, Ki,
Rage, maneuvers, HP level-up automation, ASI / feats, Mystic Arcanum selection, casting automation, damage / healing
application, concentration, material consumption.
