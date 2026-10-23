# Class implementation log (checkpoints)

Working log of the "all official classes" task (started 2026-10-16). Each class is a checkpoint: data, seed, SQL, API,
browser, UX review. A class is listed as complete only when its row says so. Coverage: [CLASS_COVERAGE.md](CLASS_COVERAGE.md).

## Phase 0: preparation (done)

- Local data backup: `%USERPROFILE%\tavern-ledger-local-backups\2026-10-16_before_all_classes.dump`
  (sha256 `e2167b503204d984b2cbed33c647a01c997f9a946ea71da0b5749ced0fb17933`) + fingerprint file.
- **Barbarian was missing from the class catalog** (12 classes). Added to `data/classes/_reference.json`; the class seed
  now has 13 class versions / 260 level rows. Sort orders of the caster classes shifted by one (both seeds regenerated).
- Pipeline: `classes_fetch.py` (13 class pages, 15 implemented-subclass pages, 3 option pages, SRD 5.1 multiclassing JSON),
  `classes_extract.py` (raw structure), `generate_class_feature_seed.py` (validated seed + coverage JSON).
- The fandom Classes overview is blocked (HTTP 403 / 402): recorded, not retried. Discovery: 13 wikidot class pages + RPGBOT.
- The multiclass proficiency table is not on the wikidot pages; source: SRD 5.1 multiclassing (dnd5eapi.co, CC-BY-4.0),
  cross-checked by the generator. Artificer (not in the SRD): to be resolved at the Artificer checkpoint.
- Migration `20261017000100_class_engine_extensions.sql` (+ rollback `rollback_class_engine_extensions.sql`).
- Subclass catalog: 118 official subclasses (6 setting-specific), 92 UA + 5 Plane Shift rows in the backlog only.

## Checkpoints

| # | Class | Data | SQL | API | Browser | UX review | Status |
|---|---|---|---|---|---|---|---|
| 1 | Fighter + Champion | done | 46/46 | 15 (CAF) + 6 catalog | class_martial_ui_test (shared) | class page redesign | complete |
| 2 | Rogue + Thief | done | 20/20 | 6 (CAR) | class_martial_ui_test 23/23 (3 runs) | — | complete |
| 3 | Wizard + Evocation | done | 20/20 | CAW 5 | class_spell_ui_test (shared) | Spells tab redesign | complete |
| 4 | Cleric + Life | done | 19/19 | CAC 2 | class_spell_ui_test | — | complete |
| 5 | Bard + Lore | done | 18/18 | CAB 2 | class_spell_ui_test | — | complete |
| 6 | Sorcerer + Draconic Bloodline | done | 19/19 | CAS 4 | class_spell_ui_test 21/21 | — | complete |
| 7 | Paladin + Oath of Devotion | done | 16/16 | CAP 4 | class_hybrid_ui_test (shared) | slot riders, pool amounts, aura in saves | complete |
| 8 | Ranger + Hunter | done | 13/13 | CAN 2 | class_hybrid_ui_test | optional replacements on the class page | complete |
| 9 | Warlock + Fiend | done | 18/18 | CAK 4 | class_hybrid_ui_test 17/17 | Pact recovery, Pact slot riders | complete |
| 10 | Barbarian + Berserker | done | 23/23 | CAE (Rage) | class_barbarian_ui_test 11/11 | active states (Start / End Rage), state-spent resources | complete |
| 11 | Monk + Open Hand | done | 11/11 | — | class_monk_ui_test 9/9 | feature save DCs, Ki by amount | complete |
| 12 | Druid + Circle of the Moon | done | 22/22 | CAE (Wild Shape, companions) | class_druid_ui_test 14/14 | Wild Shape panel and form picker, Companions card | complete |
| 13 | Artificer + Alchemist | done | 18/18 | CAE (infusions) | class_artificer_ui_test 10/10 | Infused items card and dialog | complete |

## Martial phase validation (Phase 1)

- Class page redesign (`js/feature-ui.js`): overview, Next actions (Choose / Allocate buttons, keyboard), At a glance
  (attacks, critical range, damage riders, quick resource use), subclass block with picker (source, implementation,
  setting-specific folded), features grouped by level (old levels folded, state remembered), finished choices folded
  ("Chosen: … · Change"), playtest options folded, unsaved choice edits survive re-renders (drafts).
- Read model migration `20261017000200_class_page_read_model.sql` (category, version label, subclass catalog fields).
- Regression: SQL suites (inventory 200, derived 56, lineages 84, spells 45, classes 84, features 94), per-class suites,
  browser class_feature_ui_test 36/36 (updated for the new page), class_slot_ui_test 29/29, class_martial_ui_test 23/23.
- Runners: migration count from the folder, expected catalog counts from the seed summary, per-class SQL / API / browser
  suites discovered automatically, rollback chain of the 20261017* migrations (newest first) + rollback_class_catalog.sql.
- Plain runner (run_local.sh): passed up to the final re-apply; the re-apply exposed that rollback_inventory.sql did not drop
  the new spellcasting RPCs (fixed).

## Spellcaster phase validation (Phase 2)

- Engine: `20261017000300_spellcasting_class_extensions.sql` (spellbook acquisition + summary, resource config
  slot_recovery / conversion, recharge_by_level, spell choices in_spellbook / castable / spell_lists, RPCs recover_spell_slots
  (max_slots, also_expend), convert_spell_slot, use / restore_temporary_spell_slot).
- `20261017000400_spells_ux.sql`: class source label fix (a non-spellcasting subclass no longer renames the class source,
  existing labels repaired), castable level in the class read model, spell choices above the castable level -> "invalid".
- Spells tab redesign: Spellcasting summary first (DC / attack lead, calculation folded, spellbook summary), Spell slots with
  class actions (Recover slots dialog, Flexible casting dialog, temporary slots with Use / Restore), "Your spells" grouped
  Ready to cast / Not prepared / Not available yet (state remembered), Add Spell records the spellbook acquisition, spell
  details show and edit it, the free-text legacy model folded away unless used.
- Magical Secrets-style choices without a list read the whole official catalog up to the castable level.
- Regression: spell_ui_test 28/28 (breakdown now folded), class_slot_ui 29/29, class_feature_ui 36/36, martial 23/23,
  class_spell_ui 21/21; API class catalog 40/40.

## Half-caster / Pact Magic phase validation (Phase 3)

- Engine: `20261017000500_hybrid_caster_extensions.sql` (effect types save_bonus_ability, condition_immunity,
  spell_list_addition; derived saving_throws.<k>.class_bonus, condition_immunities (names, lineage + class) and
  condition_immunity_sources; expanded spell lists enforced by set_character_spell and shown on the source; invocation
  prerequisites see known spells and features; recover_spell_slots pool 'pact'; attack riders report uses_slot / slot_pool).
- Fixed on the way: the class wrapper replaced the lineage's condition immunities instead of merging them.
- Sheet: saving throws include the class bonus (title names the source); slot riders get "Spend a slot…" (At a glance and
  Combat tab; dice per slot level; standard or Pact pool); pool / points resources are spent by an amount; Eldritch Master
  "Regain Pact slots…".
- Tests: paladin 16, ranger 13, warlock 18 (SQL); class_catalog_api_test 50/50; class_hybrid_ui_test 17/17.

## Multiclass and class setup UX (Phase 3 review)

- `20261017000600_class_setup_flow.sql`: preview_character_class_add (the class is added in a savepoint through
  set_character_class, read back and rolled back: features, proficiencies, choices, slots, resources, prerequisites of every
  class with the scores checked), get_class_starting_equipment (groups, options, catalog candidates for "any martial weapon",
  categories and "one of"), apply_class_starting_equipment (primary class only, once per character, validated picks, items
  added through add_inventory_item and noted as starting equipment), character_starting_equipment (RPC-only record).
- `js/class-setup.js`: guided "Choose class" / "Add class (multiclass)" dialog with a live preview; unmet prerequisites block
  the button until "My DM allows this multiclass anyway" is ticked; the starting equipment review opens after the first class
  and stays available on the class card ("Starting equipment…") until applied.
- Removed the class-name hardcoding from the class card button ("Version / subclass" now depends on the catalog only); the
  class editor lists implemented subclasses (not only spellcasting progressions).
- Starting wealth (gold alternative) is not on the wikidot class pages: class_versions.starting_gold stays empty (documented gap).
- Tests: class_setup_tests.sql 10/10, class_setup_ui_test 15/15.

## Martial, nature and artificer phases (Phases D, E, F)

- `20261017000700_martial_engine_extensions.sql`: class_feature_states + character_active_states (effects with
  conditions.state apply only while active; start spends the state's resource; rests end states), effect conditions
  `ability`, scaled damage / attack bonuses, effect `save_dc` -> derived `feature_dcs`.
- `20261017000800_creatures_and_transformations.sql`: creature catalog (SRD 5.1 via dnd5eapi.co, CC-BY-4.0, mechanics only,
  334 creatures, `scripts/data-migration/creatures_fetch.py` + `generate_creature_seed.py` -> `supabase/seed/creatures.sql`),
  effect `transform_form` (CR table by level, fly / swim limits, cost), character_transformations (form HP, carry-over),
  character_companions, category `transformation`.
- `20261017000900_infusions_and_attunement.sql`: infusion engine on inventory instance modifiers (item_modifiers.managed_by,
  RPC-only), character_infusions, attunement limit from class effects, attunement required by a modifier.
- Data: barbarian.json, monk.json, druid.json, artificer.json, options/infusions.json (16 official; Armor of Tools UA
  excluded). Extractor fix: Druid equipment lines separated by `<br />`.
- Frontend: Rage cards (class page + Combat), feature DCs, Wild Shape panel / picker, Companions card, Infused items card;
  export / import carries companions (schema updated).
- Tests: barbarian 23, monk 11, druid 22, artificer 18, class_setup 10 (SQL); class_catalog_api_test 69/69; browser
  barbarian 11, monk 9, druid 14, artificer 10, setup 15, transfer 7.
- Phase 3 regression (run_local): 578 PASSED, 0 failed up to the lineage rollback; stopped there (the remaining re-apply
  stages are repeated by the final validation).

## Phase 7

- Docs: CLASS_COVERAGE.md (generated), CLASS_ENGINE_REVIEW.md, CLASS_FRONTEND_API.md, FRONTEND_UX_REVIEW.md,
  CLASS_TEST_CHARACTERS.md (13 showcase characters from scripts/seed-local-demo.ps1).
- Accessible-name sweep: 0 unnamed controls on the class pages and dialogs.
- Final validation (2026-10-17):
  - `run_supabase_local.sh`: 293 passed, "ALL SUPABASE CHECKS PASSED". It earlier found A13 (infusion modifiers counted)
    and `rollback_class_levels` leaving barbarian behind; both were fixed.
  - Full browser suite: 16 suites, 382 checks, 0 failed.
  - `run_local.sh` (plain PostgreSQL): every stage up to the inventory rollback passed, including the class suites twice
    (232 per pass), the catalog / feature / level / spell / lineage rollbacks and concurrency. The re-apply after
    `rollback_inventory.sql` then failed because `_infusion_item_refusal` was not dropped. Fix: the function and
    `_transform_refusal` are now in the drop list. Targeted rerun of that stage: only base / pgcrypto functions are left,
    and the re-apply passes (inventory 200, derived 56, lineage 84, slots 84, artificer 18).
- Local data: the task-start backup was restored data-only onto the 28-migration schema and the seeds were re-run. All 19
  fingerprint tables are identical (character_spells compared on its original columns; migration 0300 adds 3
  acquisition columns). The 13 showcase characters were then added by the seeder, and the 9 original characters are still
  identical. Persistence after stop-local / start-local is confirmed (the probe change was reverted). The services are
  stopped.

## Open follow-ups (tracked)

- (done) Spell choices above the castable level after a level decrease are flagged "invalid" (BA14).
