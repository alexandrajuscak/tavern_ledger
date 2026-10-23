# Class feature engine: audit (before migration 20261015001800)

Focused audit of what existed before the generic class feature engine was built, what could be reused, and what had to be
added. The resulting design is in [CLASS_FEATURE_ENGINE.md](CLASS_FEATURE_ENGINE.md).

## Reusable existing structures

| Existing structure | Where | Reused for |
|---|---|---|
| `classes`, `class_versions`, `class_version_levels` | 1600 / 1700 | the class identity and version a feature unlock belongs to; class level comes from `character_classes` |
| `character_classes` (version, level, `subclass_version_id`, `is_primary`) | 1700 | the character's class rows; the subclass selection stays on the row (one subclass per class row) |
| `subclass_versions` (EK / AT spellcasting only) | 1700 | extended into the subclass version model (canonical id, parent class version, selection level, scope) |
| lineage choices (`lineage_choices`, options, parent option, `_lineage_choice_error`) | 1500 | the shape of choice definitions, dependent sub-choices, validation messages; a separate class table was needed because class choices are per class row and per unlock instance (ASI at 4 and 8) |
| lineage trait replacements | 1500 | the idea of explicit replacement rows (class version: `replaces_unlock_id` + `replacement_mode`) |
| lineage effect resolution (`_lineage_effects`, choice substitution, option-gated effects) | 1500 | the same substitution pattern in `_character_class_effects` |
| item effect engine (`_character_effects`, stacking, activation, `inactive_reason`) | 1400 | class effects that the derived-stats core already understands (ability, AC, saves, speed, resistance, skill advantage) are fed through it, so AC breakdowns and inactive-effect lists work unchanged |
| `_proficiency_match` | 1400 / 1500 | extended with a class-feature layer, so armor / weapon proficiency warnings disappear when a class grants them |
| `_resource_max` (fixed / table / terms, minimum, unlimited) | 1700 | the resource maximum formula language; no arbitrary expressions |
| `character_resources`, `character_resource_events` | 1700 | class resource **state** rows (new `feature_resource_id`), events (new `feature_resource_id` column) |
| `_rest`, `short_rest_character`, `long_rest_character` (rest id, idempotent) | 1700 | rest recovery of class resources; same RPCs, extended result |
| `_character_spell_grants`, `get_character_spellbook` (grant merging per spell version) | 1600 | feature spell grants as one more grant source (`feature:<class row>`) |
| `get_character_derived_stats` wrapper pattern (rename + wrap) | 1700 | the class feature layer wraps the 1700 function the same way |
| `can_access_character`, security-definer RPCs, RLS read policies | base / 1400+ | all new character tables and RPCs |

## Conflicts, duplicates and class-specific assumptions found

- `character_resources` mixed definition and state (one row per character, formula on the row). Class resources need the
  definition in the catalog and only state per character: state rows now carry `feature_resource_id`; for those rows the
  row's name / formula / recharge are ignored and the old manual-resource RPCs refuse to change them.
- `get_character_class_summary.limitations` claimed "class features are not implemented" — replaced by the wrapper.
- `class-ui.js` decided the button label "Version / subclass" with `class_id === 'fighter' || 'rogue'` (spellcasting
  subclass progression). Kept for the progression editor; feature UI has no class names.
- `_class_progress` contains the text "(only a spellcasting subclass contributes)" for Fighter / Rogue. Explanatory only.
- `set_character_class` accepted a subclass at any level (test M10 chose Eldritch Knight at Fighter 2). New rule: a
  subclass is chosen at its selection level; an existing subclass is kept when the level drops. M10's setup was adapted.
- `characters.save_proficiencies` / `skill_proficiencies` are manual; the sheet computed skills itself. Class grants are
  reported by the derived stats (`class_proficient`, `class_expertise`) and the sheet takes the higher value — manual
  values are never written.
- Free-text `features` (Features tab) and `feature_trackers` (Resources tab) remain as manual notes / trackers.

## Missing extension points (added)

Feature catalog and versions; unlocks by class / subclass level; optional and replacement unlocks; structured choices per
unlock instance; character choice storage; optional feature selection; class resource definitions with scaling and
partial recovery; scaling tables; structured prerequisites; feature effects incl. proficiency / spell / attack grants;
attack count and critical range; unarmored AC formulas; a read model; previews; export / import of feature state.

## Affected objects

- Tables: new `subclasses`, `class_features`, `class_feature_versions`, `class_feature_unlocks`, `class_feature_scaling`,
  `class_feature_choices`, `class_feature_choice_options`, `class_feature_effects`, `class_feature_resources`,
  `character_optional_features`, `character_feature_choices`, `character_feature_choice_values`; new columns on
  `classes`, `class_versions`, `subclass_versions`, `character_resources`, `character_resource_events`.
- Replaced (same signature): `_character_effects`, `_proficiency_match`, `_character_spell_grants`,
  `_character_resource_rows` (manual rows only), `_rest`, `character_classes_before_write`.
- Wrapped (renamed + new wrapper): `get_character_derived_stats` (→ `_derived_stats_levels`), `get_character_spellbook`
  (→ `_spellbook_core`), `get_character_class_summary` (→ `_class_summary_core`).
- New RPCs: `get_character_class_features`, `get_character_resources`, `set_character_feature_choice`,
  `set_character_optional_feature`, `set_character_subclass`, `expend_character_resource`, `restore_character_resource`,
  `set_character_resource_state`, `preview_character_class_change`, `export_character_class_features`,
  `import_character_class_features`.
- Frontend: new `js/feature-ui.js`; `js/class-api.js`, `js/class-ui.js` (reviews), `js/sheet.js` (Features / Resources /
  Combat / Stats / rests / export), `js/transfer.js` + `js/app.js` (import report), `js/spell-ui.js` (source label),
  `js/store.js` (Realtime tables), `css/styles.css`.

## Migration, seed, import / export, rollback, tests

- Migration `20261015001800_class_feature_engine.sql` (new, older migrations untouched).
- Seed `supabase/seed/class_features.sql` (after `classes.sql`): subclass selection levels, two canonical subclasses. The
  official feature catalog stays empty. Synthetic content: `supabase/tests/fixtures/class_feature_engine_fixture.sql`
  (never in `config.toml`).
- Export adds `classFeatures` (stable ids, character state only); import resolves on the server and reports unresolved
  entries, which are kept as pending choices.
- Rollback `supabase/rollback/rollback_class_features.sql`; `rollback_class_levels.sql` refuses to run first;
  `rollback_inventory.sql` drops the engine too.
- Tests: `class_feature_tests.sql`, `feature_resource_concurrency_test.sh`, API section, `class_feature_ui_test.py`;
  runners updated.

## Assumptions

- One subclass per class row. A class row's features come from its class version and (when active) its subclass version.
- Prerequisites that need derived data (ability scores, proficiencies, known spells) are evaluated in the read model and
  at write time, never inside the effect resolver (no recursion with the derived stats).
- An ASI applies as an ability bonus only when the player chooses it and does not mark it "already in my scores".
- Temporary features (stances, Rage) are never active merely because the character has them.

## Explicit exclusions

No Fighter content, no class or subclass catalogs, no Wild Shape, creatures, companions, infusions, invocations,
metamagic, maneuvers, feat catalog, attack execution, spell damage / healing, concentration, temporary combat effects,
full level-up wizard or HP level-up workflow.
