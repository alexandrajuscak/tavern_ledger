# Combat Builder follow-up (2026-11-07): local stack, review, feat removal, ability sources

Local implementation and validation only: no production access, no deployment, no push, no commit, no catalog re-import.

## 1. Starting state

| Item | Value |
|---|---|
| Repository | `tavern_ledger` (git root), branch `main`, HEAD `adc42fe` |
| Working tree | the uncommitted Combat Builder work (62 modified tracked files, 18 untracked: `css/combat.css`, `js/combat*.js`, 13 `docs/COMBAT_*`); nothing discarded |
| Migration files | 49 (`schema_migrations` records 42; the later ones were applied locally with psql, the project's practice) |
| Docker | the 12 `supabase_*_tavern_ledger` containers up (11 h), `supabase_vector` restarting (cosmetic, as before) |
| Local Supabase | the **shifted** stack: API `127.0.0.1:55321`, DB `55322`, Studio `55323`, Mailpit `55324`, Analytics `55327` (scratch config `…/ea2abd95…/scratchpad/sbwork/supabase/config.toml`, same `project_id` and volume) |
| Excluded TCP ranges | 49356–49455, 49669–49968 (3), 50000–50059 (administered), 53994–54193 (2), **54201–54300**, **54301–54400**, 65229–65328, 65429–65528 |
| Frontend 5173 | not running (and `js/config.local.js` points at 54321) |
| Data | 2 users, 35 characters, 5 campaigns, 335 feats, 73 combat monsters, 0 encounters |
| Backup | `%USERPROFILE%\tavern-ledger-local-backups\combat-followup-2026-11-07\before_followup.dump` (pg_dump -Fc, sha256 `aa2d471336a…`), `fingerprints_start.json` (164 tables, synthetic residue `{}`), `git_status.txt` |

## 2. Standard ports

Still reserved: 54301–54400 **and** 54201–54300 (the standard API 54321, DB 54322, Studio 54323, Mailpit 54324, Analytics 54327,
shadow 54320 and pooler 54329 all fall inside). The agent's shell is **not** elevated (`net session` fails), so WinNAT could
not be restarted. Per the task: no Docker reset, no volume deletion, no destructive stop; the shifted stack stayed, and every
test targeted it explicitly (`API_URL=http://127.0.0.1:55321`, the browser tests' `tavern-ledger:local-supabase` override,
`SUPABASE_CLI` = the shifted wrapper). Standard and shifted configurations were never mixed.

**For the user** (administrator PowerShell), when convenient:

```
net stop winnat
net start winnat
netsh interface ipv4 show excludedportrange protocol=tcp     # 54301-54400 must be gone
..\.tools\supabase-2.118.0\supabase.exe stop --project-id tavern_ledger    # from the repository; keeps the volume
start-local.bat
```

## 3. Local data after the stack check

Same volume (`supabase_db_tavern_ledger`), same data as the start: 2 users, 35 characters, 5 campaigns, catalogs unchanged
(335 feats, 73 combat monsters, 32 legendary sets, 30 conditions), 11 Combat Builder tables present, both demo logins work
(`local-dm@example.test` signed in for the walkthrough; `local-player@example.test` via the API).

## 4. Findings and fixes

| # | Area | Finding | Fix |
|---|---|---|---|
| 1 | Ability display | "+1 items = 16": the note mixed the live base input with the last server total and called every non-lineage / non-background bonus "items" | source rows without "= value", authoritative "Score N" only while it matches the base on screen ("updating…" otherwise) — [ABILITY_SCORE_SOURCE_MODEL.md](ABILITY_SCORE_SOURCE_MODEL.md) |
| 2 | Feats | source-granted feats (ASI, background, lineage) offered only Details | "Granted by …" + Change choice / background / lineage actions — [FEAT_REMOVAL.md](FEAT_REMOVAL.md) |
| 3 | Feats (security) | `remove_character_feat`: governance message (with the campaign name) before the access check | access first; one friendly not-found answer |
| 4 | Feats | repeated / concurrent removal: raw `P0002`, duplicate audit event | lock + re-check; friendly `feat_absent`; one audit event |
| 5 | Feats | removed feat's resources left inactive (orphans) | deleted with the feat |
| 6 | Feats (race) | `set_character_feat_choices` racing a removal stored orphan choice rows | lock before the grant lookup; access before the gate |
| 7 | Realtime | no revision trigger / legacy subscription for the feat tables: other sessions and the Combat Builder never saw feat changes | two `character_revisions` triggers; sheet and legacy subscription handle them |
| 8 | Sheet | page error after a refused save (`change` reached the closed sheet) | guards in `onInput` / `onChange` |
| 9 | Combat Builder | linked characters' AC, Speed, passives, maximum HP cached for the whole encounter; Initiative modifier frozen at Add Party | targeted refresh on build revisions / build columns (no encounter reload); modifier follows the sheet until Initiative is set |
| 10 | Combat Builder (a11y) | advantage / disadvantage chips said only "Next attack" (arrow + colour) | spoken "Advantage: / Disadvantage:" + tooltip |
| – | Rules (documented only) | ASI bonus added after the 20-cap (19 + 2 = 21); feat save proficiency not applied | [V6_KNOWN_LIMITATIONS.md](V6_KNOWN_LIMITATIONS.md); 0 local characters affected by the cap |

## 5. Combat Builder integration (documented behaviour)

| Value of a linked player character | During an encounter |
|---|---|
| Current / temporary HP, death saves | live (Realtime payload of `characters`, as before) |
| Maximum HP (feats such as Tough) | re-read for that participant after a build change |
| AC, Speed, Passive Perception, saves / defenses in the detail panel | re-read (`get_character_reads` derived stats, cached per revision) after a build change that writes a `character_revisions` row: feats and feat choices, classes and class choices (an ASI change writes `character_feature_choices`), optional features, lineage and its choices, background, proficiencies, equipment, inventory items — or a change of a build column of `characters` (abilities, AC override, speed, level, Initiative bonus, maximum HP) |
| Initiative modifier | follows the sheet (DEX modifier of the derived score + misc + item / feature bonus) **until Initiative is entered or rolled**; a rolled Initiative is kept for the combat |
| Monster stat blocks | snapshots; unchanged by any character change |
| Not refreshed live (no revision trigger) | infusions, active states (e.g. Rage), background choices / replacements, item modifiers: re-read when the encounter is reopened |

Only that character is re-read; turns, monsters and other characters are untouched (C5 in the browser suite asserts no
`combat_get_encounter` call). HP-only updates still cause no read.

## 6. Cache and invalidation

| Change | Invalidated | Not invalidated |
|---|---|---|
| Feat removal | character revision (`tl_cache_rev` on `character_feats`, choices, resources, spell sources), `character_revisions` rows `character_feats` / `character_feat_choices` (+ `character_spellcasting_sources`, `character_spells`, `character_resources` when affected); the sheet reloads feats, derived stats, spellbook, class resources; Combat Builder: that character's numbers | catalog, other characters, other encounters, Bio, monster snapshots |
| Base ability edit | character revision (`characters` build column); derived stats re-read after the save; Combat Builder: that character (build-column compare) | the same |

Both read paths: progressive (one Realtime table, `character_revisions`) and `?fluent=0` (per-table subscription, now including
the feat tables). No full page reload is used anywhere.

## 7. Tests (final runs, all against the shifted local stack unless noted)

| Suite | Result |
|---|---|
| `feat_removal_tests.sql` | 60 / 0 |
| `feat_removal_concurrency_test.sh` | 9 / 0 |
| `browser/feat_removal_ui_test.py` (feat removal, ability display, Combat integration, 1366 / 820 / 390 / 360) | 56 / 0 |
| `combat_builder_tests.sql` | 179 / 0 |
| `api/combat_api_test.py` | 35 / 0 |
| `browser/combat_builder_ui_test.py` | 89 / 0 |
| `combat_concurrency_test.sh` | 11 / 0 |
| `browser/combat_perf_probe.py` | 9 / 0 |
| Controlled DM walkthrough (local-dm, synthetic campaign) | 27 / 0 |
| `progressive_read_tests.sql` | 1283 / 0 |
| `fluent_read_tests.sql` (revision trigger count 21 → 23) | 1707 / 0 |
| `gameplay_polish_tests.sql` (Magic Initiate, …) | 70 / 0 |
| Rollback / reapply (throwaway `supabase/postgres:17.6.1.171` container, restored backup) | rollback == pre (functions, triggers, policies, table ACLs, data); reapply == applied; re-run idempotent |
| `combat_monsters.sql` twice (same container) | identical counts and checksums (idempotent) |
| Semantic equality, 35 local characters (migration vs rollback) | identical derived stats |

Plain PostgreSQL (`run_local.sh`) and the full browser runner: see section 9.

## 8. Files

| Group | Paths |
|---|---|
| Migration | `supabase/migrations/20261107000100_feat_removal.sql` |
| Rollback | `supabase/rollback/rollback_feat_removal.sql` |
| Frontend | `js/feat-ui.js`, `js/feat-api.js`, `js/sheet.js`, `js/store.js`, `js/combat.js`, `css/styles.css` |
| Tests (new) | `supabase/tests/feat_removal_tests.sql`, `supabase/tests/feat_removal_concurrency_test.sh`, `supabase/tests/browser/feat_removal_ui_test.py` |
| Tests (changed) | `supabase/tests/fluent_read_tests.sql`, `supabase/tests/run_local.sh`, `supabase/tests/run_supabase_local.sh`, `supabase/tests/run_browser_local.sh` |
| Docs | this file, `ABILITY_SCORE_SOURCE_MODEL.md`, `FEAT_REMOVAL.md`, `BUILD_AND_FEAT_USABILITY.md` (new); `COMBAT_BUILDER_LOCAL_HANDOVER.md`, `COMBAT_BUILDER_PRODUCTION_PLAN.md`, `LOCAL_DEVELOPMENT.md`, `LOCAL_MANUAL_TESTING.md`, `V6_KNOWN_LIMITATIONS.md` (updated) |

## 9. Regression runs and cleanup

| Item | Result |
|---|---|
| Plain PostgreSQL (`run_local.sh`, throwaway `postgres:15`) | **Incomplete.** All migrations applied cleanly, including `20261107000100`, on an empty database; then every stage it reached passed (490 PASSED lines, 0 failed: inventory, derived stats, lineages, spells, class slots, per-class suites up to `feat_tests`). Claude Code stopped the run because the machine was low on memory, so the later stages did not run: feat-removal suites inside the runner and the rollback stage. Both are covered separately on the Supabase stack (60 / 0, 9 / 0) and in the throwaway rollback/reapply container. The container was removed |
| Full browser runner (`run_browser_local.sh`) | **Not run.** It would have started after `run_local.sh` (heavy suites run one at a time). The changed suites ran individually: feat removal 56 / 0, Combat UI 89 / 0, API 35 / 0, perf 9 / 0 |
| Test frontend on 5195 | stopped by Claude Code (low memory) |
| Fingerprints | 164 tables, **identical** to the start; synthetic residue `{}` |
| Local counts | 2 users, 35 characters, 5 campaigns, 0 encounters, 4 feats (as at the start) |
| Throwaway containers | `tl-followup-rb` and `tavern-ledger-pgtest` removed |

---

# Part 2 (2026-11-07 evening): combined follow-up release

Scope: final-total Initiative, Wild Shape overflow, active class features and Artificer Infusions in Play, Herbs & Plants,
Potions, item edit/delete/icon overrides, the deadlock / slow-slot follow-up, and the pending feat-removal / ability-display
tests. Local only: no production access, no commit, push or deploy.

## 10. Starting state (audit, before any edit)

| Item | Value |
|---|---|
| Branch / HEAD | `main` / `adc42fe` (Combat Builder + part 1 still uncommitted) |
| Working tree | 64 modified tracked files, 36 untracked (Combat Builder, feat removal, docs, tests) |
| Migrations | 50 files; the 3 newest (`20261106000100`, `20261106000200`, `20261107000100`) are uncommitted and applied locally via psql |
| Ports | TCP 54201–54300 **and** 54301–54400 still excluded by Windows (winnat). The stack stays on the shifted ports: API `http://127.0.0.1:55321`, DB `55322`, Studio `55323`, Mailpit `55324` |
| Frontend | `127.0.0.1:5173`, `js/config.local.js` (git-ignored) temporarily points at `55321` |
| Local data | 2 users, 35 characters, 5 campaigns, 1 encounter (the user's manual review), 73 SRD monsters, 4 Wild Shape forms (3 expired by wall clock) |
| Backup | `%USERPROFILE%\tavern-ledger-local-backups\combined-release-2026-11-07\before_release.dump` + `fingerprints_start.json` (164 tables) + `git_status.txt` |

To return to the standard ports, an administrator runs `net stop winnat` and `net start winnat`; then
`..\.tools\supabase-2.118.0\supabase.exe stop --project-id tavern_ledger` (volumes kept) and `start-local.bat`.

**Item lifecycle / icon work in the tree:** none beyond what is committed. The item JS files in `git diff` only carry the
`?v=17 → 18` asset bump. The committed base already has the DM content lifecycle (draft, validate, publish, new version,
archive, restore, duplicate, draft delete, usage counts) and the player homebrew item lifecycle. This release builds on that.

## 11. Feature audit

| # | Request | State at start | Work |
|---|---|---|---|
| 1 | Player Initiative = final total | **Partial.** `combat_set_initiative` already stores the typed value unchanged (no modifier added). The UI labels it only "Initiative", and character rows have a **Roll** button that rolls d20 + modifier for a player | frontend (labels, helper text, no Roll on player rows, Enter-to-next) |
| 2 | Automatic monster Initiative | **Done** (server roll, group shared roll, 2024 fixed score, audit, request ids) | keep; rolling one member of a shared group now rolls the whole group |
| 3 | Manual monster final total | **Partial.** Typing works, but a value typed for one member of a shared group does not reach the other members | backend (`combat_set_initiative` propagates to the group, optional correction `reason` inside each value) + frontend (Auto / Manual mode per row) |
| 4 | Wild Shape overflow | **Defect found, different from the formula.** The overflow formula is correct (20 HP form, 21 damage → normal HP 30 → 29, reproduced). The real defect: a form whose wall-clock duration had passed is silently reverted at the start of the mutation, and `apply_character_hp` then sends the **whole** amount to normal HP. Local evidence: 2026-11-07 19:53:50 a Brown Bear form shown with 19 HP took 20 damage in the Combat Builder; normal HP went 17 → 0 (expected 17 → 16). The combat event recorded `form_ended: true, carryover: null`. The sheet path differs: it shows "duration was over" and applies the damage nowhere | backend (one policy in the shared function) + combat history fields + tests with a past `expires_at` |
| 5 | Active class features in Play | **Partial.** Features with a structured `activation` (Rage, Second Wind, Wild Shape, Channel Divinity…) appear in Play groups; resources appear in Ready to use. Selected **options** (Invocations, Metamagic, Fighting Style, Maneuvers, Hunter's Prey, Pact Boon) carry no timing and are not shown in Play | catalog patch (activation on named options) + frontend presentation |
| 6 | Artificer Infusions visible | **Partial.** Build shows the Infused items card. Inventory shows no badge; Play shows nothing | frontend (from the already loaded `get_character_infusions`) |
| 7 | Wild Shape presentation | Done; quality reference | keep |
| 8 | Custom item edit / version / archive / delete | **Mostly done** (see above). Missing: delete preview with full dependency check, permanent delete of an unused published item | backend + frontend |
| 9 | Per-item icon overrides | **Not implemented** (`dm_content.icon` exists but is unvalidated and never reaches `items`) | backend (`items.icon_key` + check) + frontend picker |
| 10 | Herbs & Plants | **Not implemented** | backend (kind + categories) + frontend |
| 11 | Potions | **Exists** as item kind `potion` (46 catalog rows). Inventory has no Potions filter | frontend filter + optional metadata |
| 12 | Feat removal / ability display | **Done in part 1**; the full browser runner, the `run_local` rollback stage and the Combat UI suite after the last chip edits were not re-run | tests only |
| 13 | Deadlock / slow slot spend | Unexplained in gameplay polish; not reproduced by the Combat Builder workload | audit + concurrency tests (evidence first) |

## 12. What was implemented

| Area | Change | Docs |
|---|---|---|
| Initiative | "Final Initiative" inputs with helper text, modifier as reference, no Roll on player rows, Enter-to-next, Auto roll / Manual total per monster or group, group totals propagate (server), Correct-with-reason after Start | COMBAT_INITIATIVE_RULES.md |
| Wild Shape | one policy in the shared server functions: damage always hits the present form with exact overflow; an expired form ends after the damage; heal / correction on an expired form applies nothing; Combat history records form HP used, excess, resulting HP; sheet shows the new normal HP at once | WILD_SHAPE_DAMAGE.md |
| Class options in Play | catalog timing for 208 options; Play cards / reminders from existing reads; no duplicate of attack riders; option casts in Spells | ACTIVE_CLASS_FEATURE_AUDIT.md, ACTIVE_CLASS_FEATURE_PRESENTATION.md |
| Artificer | Inventory "Infused: …" badge, Play "Infused items" | ARTIFICER_INFUSIONS.md |
| Items | Herbs & Plants kind + 11 subtypes, potion / herb / crafting details, icon gallery (`items.icon_key`), Potions / Herbs filters, safe permanent delete (homebrew and unused DM Space items), friendly race messages | HERBS_AND_PLANTS_ITEMS.md, CUSTOM_ITEM_*.md, POTION_AND_HERBAL_CRAFTING_DESIGN.md |
| Deadlocks / slots | evidence reviewed (production deadlocks were the cache upsert, fixed in 20261031000200); new lock-order test: 0 deadlocks, slot spend max ≈ 0.7 s with 10 sessions locking one character, 0.09–0.16 s uncontended | section 13 |

## 13. Deadlocks and spell slots

| | |
|---|---|
| Previous evidence | production, 2026-10-30 → 31: 2 `deadlock detected` (pg_stat_database) and a slowest `get_character_reads` wait of 5.9 s (793 calls, average 662 ms). Gameplay polish reproduced the deadlock locally (concurrent cold reads upserting the same `tl_cache.character_reads` rows in different orders) and fixed it with a try-advisory lock in `tl_cache.put` (`20261031000200`, cache_concurrency_test 2 / 0) |
| This release | local `pg_stat_database.deadlocks` 0 before and after every concurrency run; Postgres log: no "deadlock detected" |
| Lock order (unchanged, confirmed) | character row (`FOR UPDATE`) → its child rows (form, slot state, resources, feats) → combat encounter (`FOR SHARE`) / participant (`FOR UPDATE`) → events. The Combat Builder takes the participant then the character; every character mutation takes the character first and never a participant, so no cycle. Cache writes never wait (try-lock) |
| Tests | `lock_order_concurrency_test.sh` (10 sessions on one Wizard in a running encounter: two slot spenders, combat + sheet HP, coins, equip / unequip, feat assign / remove, cold reads, plus Wild Shape damage from sheet + combat): 13 / 0, exact arithmetic, 0 deadlocks; `combat_concurrency_test.sh` 11 / 0; `cache_concurrency_test.sh` 2 / 0; `slot_concurrency_test.sh`, `feature_resource_concurrency_test.sh` passed |
| Slot spend time | uncontended 90–160 ms (one transaction that recomputes and returns the slot read model); under 10 sessions on the same character max 674 ms, average 290 ms (queueing on the character lock, by design). The 5.9 s production figure was a read wait during the deadlock period, not a slot spend; not reproduced. No timeout was raised |
| Remaining risk | production load differs (network, pooler); keep watching `pg_stat_database.deadlocks` and `pg_stat_statements` after the release |

## 14. Test results (shifted local stack, run one at a time)

| Suite | Result |
|---|---|
| `combat_initiative_tests.sql` (new) | 32 / 0 (3 checks fail against the previous functions) |
| `wild_shape_damage_tests.sql` (new) | 39 / 0 (13 checks fail against the previous functions) |
| `combat_builder_tests.sql` | 179 / 0 |
| `items_herbs_icons_tests.sql` (new) | 48 / 0 |
| `feat_removal_tests.sql` | 60 / 0 |
| `gameplay_polish_tests.sql` | 70 / 0 |
| `progressive_read_tests.sql` / `fluent_read_tests.sql` / `derived_stats_items_lookup_tests.sql` | 1,284 / 0 · 1,707 / 0 · 3 / 0 |
| `combat_api_test.py` | 35 / 0 |
| concurrency: combat 11 / 0, feat removal 9 / 0, Wild Shape 4 / 0, governance 7 / 0, slot, class resource, cache 2 / 0 | all passed, 0 deadlocks |
| `lock_order_concurrency_test.sh` (new) | 13 / 0 |
| `item_deletion_concurrency_test.sh` (new) | 6 / 0 |
| `combined_followup_ui_test.py` (new browser suite) | 43 / 0 |
| Full browser runner `run_browser_local.sh` (38 suites) | first pass 1,228 passed / 10 failed. Fixed: a real regression in the DM item editor (the icon radio stored `null`, breaking Validate) and the Wild Shape toast wording; stale expectations of part 1's ability rows in `lineage_ui_test.py`, `background_ui_test.py`, `wild_shape_ui_test.py` ("= 16", "(your score 10)", the base-input label); my Enter-to-next check. Re-runs: lineage 25 / 0, druid 14 / 0, background 20 / 0, Wild Shape 74 / 0, gameplay polish 35 / 0, combined 43 / 0, Combat UI 89 / 0 |
| Remaining | `ux_redesign_ui_test.py` UX19 / UX21 expect the seeded "Showcase Druid" in Brown Bear form. Your manual review on 2026-11-07 19:53 ended that form and took Baboon form (demo data, left untouched). Not a code defect |
| Rollback / re-apply | inside a rolled-back transaction on the live database: after the three new rollbacks all 475 function definitions equal the pre-release backup (restored into a throwaway container, then removed), `v_item_catalog` text and grants equal; re-applying gives a schema digest identical to the applied state |
| DM walkthrough as `local-dm@example.test` (synthetic campaign) | 24 / 0; isolation check: every public table unchanged afterwards |
| Plain PostgreSQL `run_local.sh` | **incomplete.** Run 1: 1,072 passed / 0 failed, then stopped at the feat-removal step (added in part 1, never reached before) because the harness's stand-in `auth.users` lacked `instance_id` / `created_at` / `updated_at`; fixed in `00_local_harness.sql`, and the runner now loads the SRD monster seed before the new suites. Run 2 was stopped by Claude Code for low system memory during the per-class stage (518 passed / 0 failed so far). The feat-removal, combined follow-up and rollback stages of this runner have therefore **not** run on plain PostgreSQL; the same SQL suites passed on the local Supabase stack (above). Throwaway container removed |
| Not run | `run_supabase_local.sh` (it starts from an empty volume and would delete local development data) |

## 15. Files

| Group | Paths |
|---|---|
| Migrations | `supabase/migrations/20261107000200_combat_initiative_wild_shape.sql`, `20261107000300_items_herbs_icons_deletion.sql`, `20261107000400_class_option_activation.sql` |
| Rollbacks | `supabase/rollback/rollback_combat_initiative_wild_shape.sql`, `rollback_items_herbs_icons_deletion.sql`, `rollback_class_option_activation.sql` |
| Frontend | `js/combat.js`, `js/sheet.js`, `js/active-features.js` (new), `js/item-icon-gallery.js` (new), `js/homebrew-form.js`, `js/inventory-ui.js`, `js/inventory-api.js`, `js/content-editors.js`, `js/dm-api.js`, `js/icons.js`, `js/icon-registry.js` (generated), `css/combat.css`, `css/styles.css` |
| Icons | `assets/icons/plants/{herb,leaf,flower,wildflowers,mushroom,seed,berry,root}.webp`, `assets/icons/potions/{flask,bottle}.webp`, `assets/icons/SOURCE_ICONS.md`, `scripts/local/build_icon_registry.py` (copies of the originals in `../icons_curated/plants/`, outside the repository) |
| Tests | `supabase/tests/combat_initiative_tests.sql`, `wild_shape_damage_tests.sql`, `items_herbs_icons_tests.sql`, `lock_order_concurrency_test.sh`, `item_deletion_concurrency_test.sh`, `supabase/tests/browser/combined_followup_ui_test.py`; updated `isolation.py`, `lineage_ui_test.py`, `background_ui_test.py`, `wild_shape_ui_test.py`, `run_local.sh`, `run_browser_local.sh`, `run_supabase_local.sh` |
| Docs | this file, `COMBAT_INITIATIVE_RULES.md`, `WILD_SHAPE_DAMAGE.md`, `ACTIVE_CLASS_FEATURE_AUDIT.md`, `ACTIVE_CLASS_FEATURE_PRESENTATION.md`, `ARTIFICER_INFUSIONS.md`, `POTION_AND_HERBAL_CRAFTING_DESIGN.md`, `HERBS_AND_PLANTS_ITEMS.md`, `CUSTOM_ITEM_EDITING.md`, `CUSTOM_ITEM_DELETION.md`, `CUSTOM_ITEM_ICONS.md`, `FEAT_REMOVAL.md`, `ABILITY_SCORE_SOURCE_MODEL.md`, `COMBAT_BUILDER_PRODUCTION_PLAN.md`, `LOCAL_MANUAL_TESTING.md`, `LOCAL_DEVELOPMENT.md`, `ICON_ASSET_INVENTORY.md`, `V6_KNOWN_LIMITATIONS.md` |

## 16. Local data

| | |
|---|---|
| Backup | `%USERPROFILE%\tavern-ledger-local-backups\combined-release-2026-11-07\before_release.dump` (+ `fn_*.sql`, the exact pre-change definitions) |
| Fingerprints | 164 tables at start and end. Differences are only the intended ones: `items` (two new columns in every row's text, values NULL / `{}`), `item_kinds` +1, `item_categories` +11, `class_feature_choice_options` (timing keys), and `class_feature_versions` where only `updated_at` of the engine-test fixture rows changed (the class-feature browser suite reloads its fixture; contents verified identical) |
| Counts | 2 users, 35 characters, 5 campaigns, 1 encounter (yours) — as at the start |
| Cleanup | all synthetic users, campaigns, characters, encounters, items, content and audit rows removed; one fixture left by `slot_concurrency_test.sh` (a plain-PostgreSQL script I ran against the live stack: user `slot-alice@test`, character "Slot Racer") was found by the fingerprint check and removed |
| Services | shifted stack still running (55321…). The frontend server on 5173 that I started for your testing was stopped by Claude Code for low memory (not restarted); `js/config.local.js` still points at 55321. Throwaway containers removed |
