# Combat Builder: local handover

**State:** implemented and tested **locally only**. Nothing was committed, pushed, deployed or run against production.
`main` is still `adc42fe`; all changes are uncommitted in the working tree.

## What is in the working tree

| Group | Paths |
|---|---|
| Migrations | `supabase/migrations/20261106000100_combat_builder_schema.sql`, `supabase/migrations/20261106000200_combat_builder_functions.sql` |
| Rollbacks | `supabase/rollback/rollback_combat_builder_functions.sql`, `supabase/rollback/rollback_combat_builder_schema.sql` |
| Seed and data (**git-ignored by design**: the private catalog package, like the other nine seeds) | `supabase/seed/combat_monsters.sql` (sha256 `546335ac03caf4f7…`), `scripts/data-migration/combat_monsters_srd521.py`, `data/raw/srd_5.2.1/monster_blocks.txt`, `data/raw/srd_5.2.1/_manifest.json`, `data/normalized/combat_monsters_srd521.json`, `data/reports/combat_monsters_seed_summary.json`. `supabase/config.toml` `[db.seed]` lists it as the 10th seed (tracked change) |
| Frontend (new) | `js/combat.js`, `js/combat-api.js`, `js/combat-library.js`, `js/combat-icons.js`, `css/combat.css` |
| Frontend (changed) | `index.html` (Combat link, stylesheet), `js/app.js` (route, unmount, link), `js/config.js` (`COMBAT_BUILDER = 'dm'`), `js/store.js` (`applyCharacterHp`), `js/sheet.js` (Damage/Heal through `apply_character_hp`); `?v=17` → `?v=18` in all modules and 6 test files |
| Tests (new) | `supabase/tests/combat_builder_tests.sql`, `supabase/tests/combat_concurrency_test.sh`, `supabase/tests/combat_query_plans.sql`, `supabase/tests/api/combat_api_test.py`, `supabase/tests/browser/combat_builder_ui_test.py`, `supabase/tests/browser/combat_perf_probe.py` |
| Tests (changed) | `supabase/tests/browser/isolation.py` (combat residue and cleanup); `supabase/tests/run_browser_local.sh` (+ the two combat suites); `supabase/tests/run_local.sh` and `supabase/tests/run_supabase_local.sh` (the Combat Builder rollbacks first in the newest-first list); `?v=18` in 6 browser tests (`deployment_environment_test.py`, `gameplay_polish_ui_test.py`, `production_polish_smoke.py`, `production_timeout_incident_test.py`, `skills_spell_icon_ui_test.py`, `ui_refinement_ui_test.py`) and 2 scripts (`scripts/deploy/validate_exports.py`, `scripts/local/spell_icon_coverage.py`: their module import URLs only) |
| Rollback (changed) | `supabase/rollback/rollback_inventory.sql` (the full return-to-base rollback now also drops the Combat Builder first) |
| Docs (new) | `docs/COMBAT_BUILDER_AUDIT.md`, `COMBAT_RULES_AND_LICENSING.md`, `COMBAT_BUILDER_ARCHITECTURE.md`, `COMBAT_DATA_MODEL.md`, `COMBAT_PERMISSIONS.md`, `COMBAT_INITIATIVE_RULES.md`, `COMBAT_EFFECTS_AND_CONDITIONS.md`, `COMBAT_REALTIME.md`, `COMBAT_HOMEBREW_CREATURES.md`, `COMBAT_BUILDER_TESTING.md`, `COMBAT_BUILDER_VISUAL_REVIEW.md`, `COMBAT_BUILDER_LOCAL_HANDOVER.md`, `COMBAT_BUILDER_PRODUCTION_PLAN.md` |
| Docs (updated) | `UI_DESIGN_SYSTEM.md`, `UI_COMPONENTS.md`, `UI_USABILITY_REVIEW.md`, `LOCAL_DEVELOPMENT.md`, `LOCAL_MANUAL_TESTING.md`, `ICON_ASSET_INVENTORY.md`, `V6_KNOWN_LIMITATIONS.md` |

## Local database

- **Applied with psql:**
  - the two migrations;
  - the seed: 73 / 32 / 30 rows.

  `supabase_migrations.schema_migrations` was not changed, the same practice as the four previous migrations; it still
  records 42 rows.
- **Backups** in `%USERPROFILE%\tavern-ledger-local-backups\combat-builder-2026-11-06\`:
  - `before_combat.dump`: before any change, sha256 `76f9d2f4…`;
  - `before_stack_restart.dump`: before the stack restart described below;
  - fingerprints, schema digests (before, after rollback, applied);
  - performance and query logs;
  - screenshots.
- **Rollback proven.** After both rollbacks the schema digest is identical to the pre-task state: 395 functions,
  165 tables, policies, triggers, publication, grants, `_dm_try` md5. Reapplying gives an identical digest.

## The local stack runs on other ports right now

During the task Windows reserved TCP ports 54301–54400 (WinNAT / Hyper-V dynamic range), so the database container could
no longer bind 54322. Restarting needs administrator rights, which the agent did not have. To keep working, the stack
(same project id, same data volume) was started from a scratch copy of `supabase/config.toml` with every port moved by
+1000:
- API `http://127.0.0.1:55321`;
- DB `55322`;
- Studio `55323`;
- Mailpit `55324`.

**The repository's `supabase/config.toml` is unchanged.**

To return to the normal setup:
1. Run an **administrator** PowerShell: `net stop winnat; net start winnat`.
2. Stop the temporary stack from the repository folder:
   `..\.tools\supabase-2.118.0\supabase.exe stop --project-id tavern_ledger`. This removes the containers and **keeps** the
   data volume; never add `--no-backup`.
3. Run `start-local.bat`. It recreates the containers on 54321–54329 from the repository's config; local data is kept.

Until then the app on `http://127.0.0.1:5173/` (`js/config.local.js` → 54321) cannot reach the database.

## Try it

`docs/LOCAL_MANUAL_TESTING.md` section 21 walks through every feature with the demo DM (`local-dm@example.test`).

## Not executed

- **`supabase/tests/run_supabase_local.sh`:** edited (the same rollback-list change), **not run**. It starts from an empty
  volume and would wipe the local data. The identical list change was verified with `run_local.sh`.
- **Anything against production:** nothing ran there.

## Follow-up of 2026-11-07

See [COMBAT_BUILDER_FOLLOWUP.md](COMBAT_BUILDER_FOLLOWUP.md). Still nothing committed, pushed or deployed.

- **Ports:** still reserved on 2026-11-07 (54201–54300 **and** 54301–54400), the agent had no administrator rights, so the
  shifted stack (553xx, same project id and volume) stayed in use. The return-to-standard steps above are unchanged.
- **Added to the working tree:**

  | Group | Paths |
  |---|---|
  | Migration | `supabase/migrations/20261107000100_feat_removal.sql` (applied locally with psql) |
  | Rollback | `supabase/rollback/rollback_feat_removal.sql` (run it **before** the two combat rollbacks) |
  | Frontend (changed) | `js/feat-ui.js`, `js/feat-api.js`, `js/sheet.js`, `js/store.js`, `js/combat.js`, `css/styles.css` |
  | Tests (new) | `supabase/tests/feat_removal_tests.sql`, `supabase/tests/feat_removal_concurrency_test.sh`, `supabase/tests/browser/feat_removal_ui_test.py` |
  | Tests (changed) | `supabase/tests/run_local.sh` (feat suites + rollback), `supabase/tests/run_supabase_local.sh` (rollback list), `supabase/tests/run_browser_local.sh` (+ feat suite) |
  | Docs (new) | `COMBAT_BUILDER_FOLLOWUP.md`, `ABILITY_SCORE_SOURCE_MODEL.md`, `FEAT_REMOVAL.md`, `BUILD_AND_FEAT_USABILITY.md` |

- **Combat Builder changes:** linked player characters' AC, Speed, passives and maximum HP now follow build changes during
  an encounter (targeted refresh of that character, no encounter reload); the Initiative modifier follows the sheet until
  Initiative is entered or rolled; advantage / disadvantage chips name the mode for screen readers.
- **Backup** of this follow-up: `%USERPROFILE%\tavern-ledger-local-backups\combat-followup-2026-11-07\` (`before_followup.dump`,
  fingerprints, function digests, derived-stat comparison, screenshots).
