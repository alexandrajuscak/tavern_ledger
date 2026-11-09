# Active features, feats and content management — production release report (2026-11-09)

In-place production update of the existing Supabase project (`pfgz…wlsc`, PostgreSQL 17.11) and the GitHub Pages site.
Audits: [ACTIVE_GAMEPLAY_FEATURE_AUDIT.md](ACTIVE_GAMEPLAY_FEATURE_AUDIT.md), [FEAT_SYSTEM_AUDIT.md](FEAT_SYSTEM_AUDIT.md);
design: [CONTENT_MANAGEMENT.md](CONTENT_MANAGEMENT.md). No secret, connection string, player name, e-mail or hidden value appears
in this report.

## Executive result

Deployed in place to production on 2026-11-09 between 23:42 and 23:57 UTC. Release blockers hit: none.

* Play now shows lineage traits and feats beside class features, under their stated timing. Each card shows source, uses,
  recovery and an automation label; there are no fake Use buttons.
* Three feat defects (D1 to D3) are repaired:
  * Magic Initiate and every spell- or option-choosing feat can now be completed.
  * Resilient now applies its saving-throw proficiency.
  * Invalid stored choices are no longer treated as applied.
* Feat removal works as specified: a direct removal removes only that feat's mechanics, and source-granted feats explain their
  source.
* DM/Admin content management is enabled (`CONTENT_MANAGEMENT = 'on'`). It covers duplicating official content as homebrew,
  editing drafts, versioning, validating, publishing, archiving and restoring. It adds a usage report and permanent deletion of
  unused custom content, with the dependency checks repeated inside the transaction.
* The database changes are 3 additive migrations, each with an exact rollback. The only data change is 157 inserted catalog
  rows. No existing row changed: the 164 table fingerprints and the golden values of all 7 characters are identical before and
  after.
* Signed-in production smoke: 28 / 0 with the flag off and 30 / 0 with it on. All synthetic accounts and rows were removed
  (0 left).
* Not done: the harness refused to delete the access file `C:\supabaseaccess.txt` (see Security).

## Timeline (UTC)

| UTC (2026-11-09) | Step |
|---|---|
| 18:48 | Pre-release backup `2026-11-09T184833Z-pre-active-features`: checksums verified, restore rehearsal 7 / 7 |
| 19:10 | Production dry run #1: exactly the 3 release migrations |
| 19:30 to 23:30 | Full rehearsal on a restored copy (migrate, golden values, rollback, re-apply); local regression suites (see Tests) |
| 23:41 | Read-only re-baseline: production identical to the backed-up and rehearsed state (fingerprints, digest, golden values, history) |
| 23:42:18 | Dry run #2: exactly the 3 release migrations |
| 23:42:32 to 23:42:34 | `db push`: 3 migrations applied, rc 0 |
| 23:43 | Post-migration verification (history 55, 157 rows, grants, RLS, fingerprints, golden values) |
| 23:44 | Commit 1 `d4439f6` (flag off) pushed; Pages built and served byte-identical (54 / 54 files) |
| 23:47 to 23:50 | Production smoke, flag off: 28 / 0, cleanup 0 left. An earlier attempt failed only S-00 (a test defect, see Tests) |
| 23:51 | Commit 2 `7fa453d` (flag on) pushed; Pages byte-identical (54 / 54) |
| 23:52 | Production smoke, flag on: 30 / 0, cleanup 0 left |
| 23:54 | Post-smoke comparison: everything identical to post-migration |
| 23:54:33 | Post-deployment backup `2026-11-09T235433Z-post-active-features`: checksums OK, restore rehearsal 7 / 7 |
| 23:57 | Final read-only health check. Deleting the access file was blocked by the harness |

## Active features

* **Audited:** 13 classes (274 class feature unlocks, 208 class options — the 2026-11-08 timing patch re-verified: 208 / 208
  rows, presentation only), 839 lineage traits, 408 feat versions, 30 background versions, campaign custom content, 16 Artificer
  infusions. Per-feature tables: ACTIVE_GAMEPLAY_FEATURE_AUDIT.md.
* **Classification:** PASSIVE (applied) / ACTION / BONUS ACTION / REACTION / FREE-SPECIAL / RESOURCE / TOGGLE / SPELL-GRANTING /
  ITEM-BOUND / CHOICE-BASED / REMINDER ONLY / NON-GAMEPLAY. Lineage: 61 Play cards, 5 counters, 69 reminders, 609 applied
  passives, 95 descriptive. Feats: 14 cards, 8 reminders (+ counters), 162 descriptive ("See the source"), the rest applied
  passives / ability / spell grants.
* **Play:** lineage traits and feats now appear under their stated timing (Actions / Bonus actions / Reactions / Free and special)
  next to class features and options, with source, timing, recovery, uses and an automation label (automatic / partly automatic /
  reminder only); combat-relevant passives as one-line reminders; feat counters in Ready to use. No fake Use button: counters keep
  their Use button in Ready to use. Full text stays on Build.
* **Read model:** one shared client model (`js/active-features.js`) over reads the sheet already loads in its single progressive
  wave + one 157-row catalog table read once per page session. No RPC per card, no rules evaluation per card; lineage / feat /
  timing changes re-render only the Play groups.
* **Spells:** feat spells under the feat's own source (unchanged; the repaired choices now reach it). **Inventory:** infusion
  badges unchanged and verified. **Combat Builder:** "Active features" of a linked character on request (one cached read),
  refreshed only for that character after its build or resource revision.

## Artificer

16 infusions, all item-bound, none grants a spell (so none appears in Spells — correct). Build card (known / active / limits /
target), Inventory "Infused: <name>" badge with attunement state, Play > Infused items with the infusion text; replacement and
removal remove only that infusion's modifier. Covered by `classes/artificer_tests.sql` (18/0), `class_artificer_ui_test.py`,
`combined_followup_ui_test.py` (complete browser suite). Production: 1 Artificer, 0 active infusions.

## Feats

| Defect | Root cause | Fix | Production rows |
|---|---|---|---|
| D1 Magic Initiate (2014 / 2024) and every feat with a `spell_list` / `option` choice could not be completed when granted by a lineage (Variant Human), a class ASI, a background without a fixed list, or with deferred choices; UI said "Choices saved." | `get_character_feats` sent choices without `options`; the edit dialog had nothing to render | options in the read + client fallback; honest save message ("Saved, but not complete yet. Choose …") | 1 grant (Variant Human → Magic Initiate 2024) incomplete; not auto-filled; the player can now finish it |
| D2 Resilient 2014 / 2024 save proficiency shown automated but not applied | the effect resolved with the ability as target | `_character_feat_effects` (target `save`, ability in value_text) | 0 holders |
| D3 an invalid stored choice stayed active | sync checked completeness only | INVALIDATED state; treated as incomplete | 0 invalid values |

State machine (incomplete / applied / invalidated / inactive; pending approval through change requests; removed) with Build
"Next step". All 18 spell-selecting workflow points and the 32-item removal matrix: FEAT_SYSTEM_AUDIT.md. Source-granted feats
show their source and the right change action (no Remove button the backend would refuse). Reconciliation: no data patch
needed (0 orphans, 0 duplicates, 0 complete-without-grant, 0 invalid; 1 incomplete needs the player).

## Content management

* **Types:** spell, item, feat, creature / Wild Shape form, companion template, background, lineage, condition (DM Space
  library), plus the existing Inventory custom-item lifecycle and Combat Builder encounter-only custom monsters (unchanged).
  **Custom classes / subclasses are not supported by Tavern Ledger** (no authoring model) and were not added.
* **Lifecycle:** draft (edit in place) → validate → publish (immutable version) → new version (characters keep theirs) → archive
  (no new picks, existing assignments keep working) → restore. Official content is never edited or deleted; **Duplicate as
  homebrew** creates a new campaign draft with its own id (spell, item, feat, creature, background, lineage).
* **Usage report** (counts only, campaign-scoped): every reference including foreign keys that would cascade into player data and
  text references without a foreign key; classification safe to delete / archive recommended / delete blocked / new version
  required.
* **Permanent delete** of unused custom content of every type (draft or published) by a DM of the campaign or an admin; typed
  name; content row and catalog rows locked, dependencies re-checked inside the transaction; explicit per-type deletes; one
  audit event; repeat / concurrent safe ("Content not found"); used or historically referenced content is refused (archive).
* **UI:** Duplicate official…, per-row Usage, editor View usage… / Delete permanently… (only when the server says it is safe),
  behind `CONTENT_MANAGEMENT` (shipped `'off'` in commit 1, enabled in commit 2).
* **Concurrency:** the delete-vs-assignment test found a real deadlock (`dm_assign_content` locked version and catalog rows before
  the content row); fixed by a share lock on the content row first. After the fix: both race orders, exactly one winner, 0 deadlocks.
* **Existing production content:** 7 DM content items (6 published, 1 archived) and 17 owned custom items — not changed by the
  release (no function touches them unless a DM acts; fingerprints identical after migration).

## Database

| Migration | Kind | Rollback |
|---|---|---|
| `20261109000100_feat_choice_state` | replaces `get_character_feats`, `_sync_character_feats`, `_character_feat_effects` (exact pre-definitions in the rollback, md5 dd145f0f / 5c5e26e6 / e2ac0600); adds `_feat_choice_issues` (no client grant); bumps the global read-cache revision | `rollback_feat_choice_state.sql` |
| `20261109000200_active_feature_timing` | new table `catalog_play_timing` (RLS, select for anon/authenticated, cache-revision trigger), 157 rows keyed by stable ids, refuses to apply unless exactly 157 official ids match | `rollback_active_feature_timing.sql` (drop) |
| `20261109000300_content_management` | 4 new functions (`_dm_content_dependencies` internal; `get_dm_content_usage`, `delete_unused_dm_content`, `duplicate_official_as_homebrew` for authenticated, each authorizing itself, fixed search_path); `dm_assign_content` takes the content row lock first (deadlock fix) | `rollback_content_management.sql` (drops the 4, restores `dm_assign_content` md5 5baa0d52) |

No table altered, no row of any existing table updated, no index / policy / grant on existing objects changed. Data patch:
157 inserted catalog rows only.

**Applied to production** with `supabase db push`, rc 0, about 2 s in total. The dry runs before (19:10 and 23:42) listed exactly
these 3 migrations.

**Verified after the push:**

* `schema_migrations` has 55 rows, the newest `20261109000300`.
* `catalog_play_timing` has 157 rows:
  * lineage: 61 card, 5 resource, 69 reminder
  * feat: 14 card, 8 reminder
* The new table has RLS on, one SELECT policy for anon and authenticated, only SELECT granted to those roles, and the
  `tl_cache_rev` trigger.
* Function access:

  | Function | Who can execute |
  |---|---|
  | `_feat_choice_issues`, `_dm_content_dependencies`, `_sync_character_feats` | no client role |
  | `get_dm_content_usage`, `delete_unused_dm_content`, `duplicate_official_as_homebrew` | authenticated only |
  | `dm_assign_content`, `get_character_feats` | authenticated only |

  All are SECURITY DEFINER with `search_path=public, pg_temp`; anon is denied everywhere.
* Object digest: identical to the rehearsal's migrated copy (bodies and md5) apart from one ACL difference. Production's default
  privileges give `service_role` no EXECUTE on the new functions and only `Dxtm` on the new table, the same as the existing
  production objects (for example `dm_assign_content`). The frontend never uses `service_role`.
* Security lint delta: exactly as rehearsed, +3 authenticated SECURITY DEFINER functions and +1 anon-readable catalog table.

**Files committed after the rehearsal:** two small guards were added to the migrations after it ran.

* The timing migration now skips when the catalog is empty. That branch is unreachable on production.
* The full-teardown rollback test (`rollback_inventory.sql`) now drops the new table.

Neither changes what was applied to production.

## Tests

| Suite | Result |
|---|---|
| Plain-PostgreSQL suite (`run_local.sh`): from zero, seed idempotency, all migration rollbacks incl. the 3 new ones, full teardown, re-apply | exit 0, 616 PASSED, 0 FAILED (3rd run; see below) |
| `feat_choice_state_tests.sql` (11 of the first 23 checks fail on the old definitions) | 28 / 0 |
| `feat_removal_tests.sql` (F17b updated for the Resilient fix) | 60 / 0 |
| `classes/content_management_tests.sql` | 26 / 0 |
| Per-class and governance SQL suites (21 files) | all 0 failed |
| `progressive_read_tests` (cache == direct for every read) | 1284 / 0 when run alone. 1283 / 1 when run overlapping my own cleanup script; harness-only, not reproduced alone |
| `fluent` read tests | 1707 / 0 |
| Concurrency: content deletion (both race orders), feat removal, lock order, item deletion, combat, cache | all passed, 0 new deadlocks |
| Full browser suite (40 suites incl. `active_features_ui_test.py` 33 / 0) | 1315 / 0, exit 0 |
| Local rehearsal of the production smoke | 28 / 0 |
| **Production smoke**, flag off / on (`production_active_features_smoke.py`) | **28 / 0 / 30 / 0** |

Smoke timings in production (flag on):

| Step | Time |
|---|---|
| Feat choice save in the UI | 554 ms |
| Duplicate official content | 261 ms |
| Publish | 937 ms |
| Usage report | 164 ms |
| Combat Builder active features | 932 ms |

**Defects found by the gates and fixed before or during the release:**

1. **Fresh-database build:** the timing migration aborted on an empty catalog. It now skips, and a seed file was added.
2. **Full teardown:** `rollback_inventory.sql` left `catalog_play_timing` behind. It now drops it.
3. **A real deadlock** between content deletion and `dm_assign_content`. Fixed by taking the content-row share lock first.
4. **The progressive-read invariant** required the cache-revision trigger on the new table. Added.
5. **Smoke S-00 (test defect):** it read config.js's warning comment as a key. It now checks code lines only and also checks the
   project URL.

The first plain-PostgreSQL run was killed by the low-memory reaper. The second failed only on defect 2, and the third passed.

## Deployment

* **Commit 1 `d4439f6`** "feat: surface active gameplay features and repair feat lifecycle" (79 files, flag `'off'`).
* **Commit 2 `7fa453d`** "feat: enable expanded DM content management" (flag `'on'`, smoke S-00 check fix).
* GitHub Pages built each commit. All 54 served files (`index.html`, `js/`, `css/`) were byte-identical to the commit, and the
  single asset version is `?v=20`.
* The served `config.js` contains only the project URL and the publishable key; no secret appears outside the warning comment.

## Data preservation

| Check | Before | After migration | After smoke |
|---|---|---|---|
| Fingerprints of the 164 existing tables | baseline | identical | identical |
| Golden values (derived stats, feats, spells, resources, lineage; 7 characters) | baseline | identical | identical |
| Semantic counts (feats, choices, feat spells, resources, infusions, DM content, custom content, combat, hidden DM data, inventory hash) | baseline | identical (only `catalog_play_timing` now present) | identical |
| Auth users / characters / campaigns / members / inventory rows | 9 / 7 / 2 / 8 / 131 | same | same |
| Deadlocks (`pg_stat_database`) | 2 | 2 | 2 |

* No player character, membership, inventory row, coin, HP or runtime state was written, and no data patch ran.
* The 1 incomplete Variant Human Magic Initiate grant was left for the player to finish.
* The smoke used only synthetic `smoke-fl-*@example.test` accounts and its own campaign; cleanup left 0 rows.

## Backups

Stored outside Git, the repository, OneDrive and shared folders, under `%USERPROFILE%\tavern-ledger-production-exports\`:

| Backup | Location | Checks |
|---|---|---|
| Pre `2026-11-09T184833Z-pre-active-features` | `2026-11-09-active-features-release\` | checksums verified; restore rehearsal 7 / 7 characters; full restored-copy rehearsal equal to production |
| Post `2026-11-09T235433Z-post-active-features` | `nightly\` | 7.06 MB; SHA256SUMS all OK; migration history 55; restore rehearsal 7 / 7 characters; counts identical to pre |

* Both rehearsal logs show the same 8 expected auth/storage errors from the plain-PostgreSQL stub.
* Baselines, dry runs, the push log and smoke results are in `2026-11-09-active-features-release\baseline\`.
* **Rollback path:** run the 3 rollback scripts newest first. Each was verified exact on the restored copy. If needed, restore
  from the pre backup.

## Security

* RLS is unchanged on every existing table; the new table is select-only catalog metadata.
* Every new client function authorizes itself (DM of the campaign or admin) and returns counts only.
* In production:
  * players, unrelated users and anonymous callers are denied (X-01 to X-03);
  * unrelated users are denied without the campaign name being revealed;
  * hidden DM data is absent from the player's feat read (X-05).
* No `service_role` key in the frontend. No connection string, password or key was printed, committed or written to a report.
  The commits passed a secret scan.
* No change to compute, statement timeout, `max_connections` or the Realtime pool. No `db reset`, no truncation, no importer,
  no seeds and no `migration repair` on production.
* **Access file:** the release used `C:\supabaseaccess.txt` (`C:\subabaseaccess.txt` does not exist). Deleting it after the
  post-deployment backup was **blocked by the harness** ("path is protected from removal"), as in the previous release. The
  file **still exists** and must be deleted manually; the database password must be rotated.

## Monitoring

| When | What |
|---|---|
| immediately | smoke + log / deadlock check (done, below) |
| +1 hour | `select deadlocks from pg_stat_database`, Dashboard Logs: 57014 / 40P01 / 5xx / RPC 404 |
| first real session | Play cards of real characters (lineage, feats), the Variant Human Magic Initiate choice, DM Space usage / delete |
| 24 hours, 7 days | the same + Advisors; nightly backup status |

Status stays **deployed and monitoring** until one real game session confirms the active features are useful and stable.

## Open items

1. Delete `C:\supabaseaccess.txt` manually; the harness blocked its deletion. Then rotate the production database password.
2. The Dashboard logs (API 5xx, 57014, 40P01, RPC 404) were **not** reviewed in this session. Only database statistics were
   checked: deadlocks unchanged at 2, no idle-in-transaction sessions, and the only long-running session is the Realtime WAL
   sender.
3. 1 Variant Human Magic Initiate grant is still incomplete until its player chooses the spells.
4. Custom classes and subclasses remain unsupported (no authoring model).
5. The Supabase CLI is 2.118.0; 3.1.0 is available (not changed during the release).

## Safety confirmation

* Production writes were limited to:
  * the 3 approved migrations;
  * the synthetic smoke fixture and its cleanup;
  * the content the smoke created and deleted through the app.
* No existing data was overwritten, deleted or normalized. No referenced published content was deleted. No cascade deletion was
  added.
* No release blocker of the specification was hit. The gate failures listed under Tests were fixed and re-run before any
  production write, except the S-00 smoke check, which was a test defect.
* Feature status: deployed and monitoring, pending one real game session.

Active gameplay features and DM/Admin content management are deployed and monitoring.

Next actions:

1. Rotate the production database password. Also delete `C:\supabaseaccess.txt`, which the harness could not remove.
2. Verify one real character with active class and feat features in Play.
3. Remove one disposable, directly assigned feat and confirm that only its mechanics leave.
4. Run one real session and review the Supabase logs.
