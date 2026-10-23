# Class foundation (catalog)

The class catalog behind spells, slots and class levels. Character-side rules (class rows, total level, proficiency
bonus, limits) are in [CLASS_LEVELS.md](CLASS_LEVELS.md); slots in [SPELL_SLOTS.md](SPELL_SLOTS.md). Per-level numbers:
[CLASS_PROGRESSION_COVERAGE.md](CLASS_PROGRESSION_COVERAGE.md) (generated). Class features: the generic engine exists
([CLASS_FEATURE_ENGINE.md](CLASS_FEATURE_ENGINE.md)); its official catalog is still empty.

## Tables

| Table | Rows | Written by | Notes |
|---|---|---|---|
| `classes` | 12 | `spells.sql` (9 casters), `classes.sql` (all 12) | artificer, bard, cleric, druid, fighter, monk, paladin, ranger, rogue, sorcerer, warlock, wizard |
| `class_versions` | 12 | `spells.sql` (spellcasting basics) + `classes.sql` (hit die, contribution, start level, prepared formula, prerequisites, limitations) | one current 2014 version each; `rules_label`, `status`, `superseded_by_version_id`, `implementation_status` |
| `class_version_levels` | 240 | `classes.sql` | per class level: PB, cantrips known, spells known, highest spell level, Pact slots / level |
| `subclass_versions`, `subclass_version_levels` | 2 / 36 | `classes.sql` | Eldritch Knight, Arcane Trickster: spellcasting progression only |
| `class_spell_lists`, `class_spell_list_entries` | 9 / 1543 | `spells.sql` | Fighter, Monk and Rogue have no list; the one-third casters use the Wizard list |
| `spell_slot_progressions`, `spell_slot_progression_levels` | 5 / 289 | `classes.sql` | standard, half, Artificer, one-third, Pact Magic |

Seed order: `reference_data.sql`, `item_effects.sql`, `spells.sql`, `classes.sql`, `lineages.sql`. The shared columns of
the nine spellcasting versions come from `data/spells/_reference.json` in both generators, so loading either seed again
changes nothing (checked by `spell_catalog_checksum.sql` and `class_catalog_checksum.sql`).

## Pipeline

```
python scripts/data-migration/classes_fetch.py        # 12 class pages, 2 subclass pages, 4 reference pages -> data/raw/classes_html/ (git-ignored)
python scripts/data-migration/classes_normalize.py    # -> data/normalized/classes/{classes,progressions}.json + data/reports/class_progression_report.json
python scripts/data-migration/generate_class_seed.py  # -> supabase/seed/classes.sql + data/reports/class_seed_summary.json (--check: validate only)
python scripts/data-migration/class_coverage.py       # -> docs/CLASS_PROGRESSION_COVERAGE.md
```

Hand-entered metadata (rules labels, contribution rules, prepared formulas, limitations, subclass ids) lives in
`data/classes/_reference.json`; every value cites the class page section it comes from. Hit dice and multiclass
prerequisites are parsed from the pages. 27 checks, 1 recorded conflict (Artificer rounding).

## Class versions

| Version | Ability | Preparation | Ritual | Multiclass slots | Casts from | Hit die |
|---|---|---|---|---|---|---|
| `artificer-tce` | INT | prepared | prepared | half, rounded up | 1 | d8 |
| `bard-phb` | CHA | known | known | full | 1 | d8 |
| `cleric-phb` | WIS | prepared | prepared | full | 1 | d8 |
| `druid-phb` | WIS | prepared | prepared | full | 1 | d8 |
| `fighter-phb` | — | — | — | none (Eldritch Knight: one third) | — | d10 |
| `monk-phb` | — | — | — | none | — | d8 |
| `paladin-phb` | CHA | prepared | none | half, rounded down | 2 | d10 |
| `ranger-phb` | WIS | known | none | half, rounded down | 2 | d10 |
| `rogue-phb` | — | — | — | none (Arcane Trickster: one third) | — | d8 |
| `sorcerer-phb` | CHA | known | none | full | 1 | d6 |
| `warlock-phb` | CHA | known | none | Pact Magic (separate) | 1 | d8 |
| `wizard-phb` | INT | spellbook | spellbook | full | 1 | d6 |

## Next steps (not in this phase)

1. Class features as data (levels, uses through `character_resources`), subclass choice and features.
2. Subclass expanded / always-prepared spell lists.
3. Feat catalog (prerequisites can use the total level from the classes).
4. Wizard spellbook tracking, Mystic Arcanum selection, Font of Magic (temporary slots are ready).
5. 2024 class versions as separate rows.

## Class feature engine (20261015001800)

- `classes.content_scope`, `class_versions.content_scope` (`official` / `test`): synthetic test content is marked and
  shown as "Test fixture". `class_versions.subclass_level`: when the class chooses its subclass (seed `class_features.sql`).
- Canonical `subclasses` and extended `subclass_versions` ([SUBCLASS_FOUNDATION.md](SUBCLASS_FOUNDATION.md)).
- Feature catalog tables (`class_features`, `class_feature_versions`, `class_feature_unlocks`, scaling, choices, options,
  effects, resources): [CLASS_FEATURE_ENGINE.md](CLASS_FEATURE_ENGINE.md). No official features yet; Fighter is next
  ([FIGHTER_IMPLEMENTATION_PLAN.md](FIGHTER_IMPLEMENTATION_PLAN.md)).
