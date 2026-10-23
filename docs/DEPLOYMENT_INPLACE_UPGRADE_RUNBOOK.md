# In-place upgrade runbook: legacy production → V6.2 (rehearsed 2026-10-23)

**Strategy:** upgrade the **existing** Supabase project in place, keeping its 8 accounts (6 with Google sign-in), 2
campaigns, 7 characters and the storage bucket. This supersedes the "new project" plan in DEPLOYMENT_PACKAGE.md /
DEPLOYMENT_REBUILD_STRATEGY.md.

Production facts (pre-check, 2026-10-23):
- PostgreSQL 17.11, Free plan, `pgcrypto` in `extensions`, no migration history.
- Legacy fingerprint `f51346d2954b0aca49a2384c539fe6ad`. It differs from the clean baseline only by CRLF line endings
  in the 11 function bodies and by Supabase's `ensure_rls` event trigger with `rls_auto_enable()`.
- 8 users, 7 characters, 2 campaigns, 76 inventory rows (37 equipped), 6 external portrait links, 0 storage files.

## 1. Rehearsal results (local clone of production; production untouched)

The clone is a separate local Supabase CLI stack (`project_id = tl-rehearsal`, ports 553xx), restored from the production
backup. Its 249-line structure fingerprint was identical to production before the upgrade.

| Step | Result | Time |
|---|---|---|
| M1 `migration repair --status applied 20261015000000` | history = 1 row; schema untouched (11 tables) | <1 s |
| M2 `db push --dry-run` | exactly 40 migrations, `20261015000100` … `20261023000100` | <1 s |
| M3 `db push` | 40 applied, 0 errors; history 41 rows; 152 tables | **4 s** |
| 9 catalog seeds | all counts exact (items 1,146 · spells 574 · classes 13 · subclasses 118 · class features 246 · creatures 334 · lineages 133 · feats 408 · backgrounds 30 · source books 58) | **6 s** |
| `migrate_legacy_inventory()` | 44 linked by name, 4 equipped items moved to slots, **33 equipped items to manual review**; second run changes nothing | <1 s |
| Validation V1–V12 + extra checks | 14 / 14 OK (table below) | – |
| V13 anonymous key | characters / profiles / campaigns → `[]`; inventory, audit, hidden data → 401; catalog readable (by design) | – |
| App smoke (V6.2 frontend → clone) | admin sign-in; 7 / 7 characters open with 6 tabs and derived AC; every inventory shows exactly its stored rows (11+11+7+17+10+13+7 = 76); DM Space opens; no page errors | – |
| **Rollback R-A** (`rollback_v62_hardening.sql`, then `rollback_inventory.sql`) | fingerprint back to `f51346d2…`, 249 lines identical to production; 11 tables; 37 equipped flags; all data intact | **2 s** |
| Re-upgrade after rollback | dry-run 40 again; push, seeds and inventory conversion give the identical 14 / 14 | – |
| **Restore R-B** (wipe the clone, restore from backup) | fingerprint `f51346d2…`, 249 lines identical, SUMMARY 12 / 12 GO, 8 users / 6 Google / 7 characters / 2 campaigns / 76 items | ~1 min |

Validation targets (`scripts/deploy/postupgrade_validation.sql`; all OK on the clone):

| Check | Expected |
|---|---|
| users / profiles / Google users | 8 / 8 / 6 |
| characters / campaigns / members | 7 / 2 / 8 |
| inventory rows / without `inventory_id` | 76 / 0 |
| character inventories | 7 |
| campaign governance | `relaxed`: 2 |
| characters set up | 7 |
| public tables / without RLS / unpinned SECURITY DEFINER | 152 / 0 / 0 |
| policies / hash | 170 / `91bd4664f2167ec4ba8e3357538b7efc` |
| Realtime tables / storage policies | 31 / 3 |
| bucket | `portraits` public, 2 MB, jpeg / png / webp |
| legacy rows spells / attacks / features / trackers / notes | 36 / 21 / 73 / 9 / 35 |
| V6.2 constraints / admins / `ensure_rls` | 2 / 2 / 1 |

## 2. Findings from the rehearsal (now part of the procedure)

| # | Finding | Consequence |
|---|---|---|
| F1 | `supabase db dump` does not include objects in Supabase-managed schemas: the 3 `portraits` storage policies, the `on_auth_user_created` trigger on `auth.users`, and the `ensure_rls` event trigger. All data is included. | A restore from this backup must recreate them (statements in §5). Without the auth trigger, new sign-ups would get no profile. |
| F2 | Restoring the dump needs a superuser locally (`supabase_admin`), because of `SET log_min_messages`. The event trigger must be created as `postgres`, because Supabase refuses a superuser-owned event trigger that calls a non-superuser function. | Use exactly the roles in §5. |
| F3 | A local clone needs `?sslmode=disable` in the CLI connection string. | Local only; production uses TLS through the pooler. |
| F4 | 33 of 37 equipped items cannot be placed automatically: 11 sets of several equipped weapons (main / off hand unknown), 11 names without a catalog match, 8 gear / tool items without an obvious slot, 3 equipped stacks. Nothing is lost; the items stay in the inventory. | **Every player re-equips once.** Until then AC and attacks can differ from the legacy sheet. Communicate before the upgrade. |
| F5 | After a rollback, `supabase_migrations.schema_migrations` keeps the baseline row (the pre-check shows "REVIEW: history table exists"). | Harmless: a later upgrade skips M1, and the dry run again shows 40. |
| F6 | Rollback order matters: `rollback_v62_hardening.sql` **before** `rollback_inventory.sql` (the latter predates the V6.2 constraints). | Encoded in §4. |
| F7 | The database steps are fast (migrations 4 s, seeds 6 s, rollback 2 s on the full data). | The window is dominated by checks and communication: about 30–45 min. |
| F8 | Supabase's `ensure_rls` event trigger stayed active during the upgrade and did not interfere (every new table enables RLS itself). | No action. |
| F9 | After the upgrade the anonymous key gets `200 []` instead of `401` on characters / profiles / campaigns (table grants changed; RLS still returns no rows). No data is exposed (V13). | No action; noted for security reviews. |
| F10 | Portraits are external image links (6). They keep working, but they load from third-party sites. | No action; players may re-upload into the `portraits` bucket later. |
| F11 | The backup folder is inside a OneDrive-synced folder and holds e-mail addresses and password hashes. | Move it to a non-synced folder. |

## 3. Final production checklist

Gate rule: stop at the first **NO-GO**. Nothing below runs before your explicit go-ahead for the window. Passwords are
typed at prompts.

### Before the window (day before)

- [ ] Rehearsal GO (§1).
- [ ] Tell the players:
  - the date and time of the window (about 45 min);
  - "don't use the app during the window";
  - after it, "re-equip your weapons and gear once, and complete Lineage / Class / Background on Build".
- [ ] Release commit prepared locally but **not pushed** (separate approval of file list and message):
  - cleanup C1–C5;
  - `js/config.js` with the **existing** project's URL and publishable key (the public values of commit `849d7f1`);
  - a final complete browser suite run.
- [ ] The backup folder has been moved out of OneDrive (F11).

### Window

| # | Step | Command / action | GO condition |
|---|---|---|---|
| 1 | Freeze | players notified; the last character change in the pre-check is older than the announcement | – |
| 2 | Pre-check | SQL Editor: `scripts/deploy/precheck_package.sql` **SUMMARY** + CHECK 7 | 12 / 12 GO; 7 characters, 76 inventory rows unchanged |
| 3 | Fresh backup | `supabase db dump` ×3 (roles, schema, data) into a **new** dated folder + SHA-256 | three non-empty files; data contains `auth.users` and `public.characters` |
| 4 | M1 | `supabase migration repair --db-url $env:PROD_DB_URL --status applied 20261015000000` | "Repaired migration history" |
| 5 | M2 | `supabase db push --db-url $env:PROD_DB_URL --dry-run` | exactly 40, `20261015000100` … `20261023000100` |
| 6 | M3 | `supabase db push --db-url $env:PROD_DB_URL` | 40 applied, no error (history 41) |
| 7 | Seeds | the 9 files with `psql -v ON_ERROR_STOP=1` (connection string as an environment variable) | each OK; catalog counts as in §1 |
| 8 | Inventory | `select public.migrate_legacy_inventory();` (save the JSON), then once more | first: 44 / 4 / 33 (± if players changed items); second: `linked_by_name` 0 |
| 9 | Validate | `scripts/deploy/postupgrade_validation.sql`, `catalog_integrity_report.sql`, anonymous probe | 14 / 14 OK; integrity all 0; anon `[]` / 401 |
| 10 | Frontend | push the approved release commit; wait for the Pages run | `curl …/js/inventory-api.js` → 200; `js/config.js` shows the existing project |
| 11 | Smoke | you sign in by e-mail, a player by **Google**; open characters, inventory, DM Space; HP change visible in a second browser | all work |
| 12 | Post-backup | `supabase db dump` ×3 into another dated folder + SHA-256 | three files |
| 13 | Close | `Remove-Item Env:PROD_DB_URL`; tell the players the app is back | – |

### Rollback triggers and actions

| When | Trigger | Action |
|---|---|---|
| Steps 4–9 | any error, a validation DIFF, or a count change | **R-A** in SQL Editor or psql: `rollback_v62_hardening.sql`, then `rollback_inventory.sql`. Then the pre-check SUMMARY: fingerprint `f51346d2…`. The legacy site keeps working, because the frontend has not changed yet. |
| After step 10 | sign-in fails, characters broken, hidden-data leak | revert the release commit on `main` (Pages serves `849d7f1` again), then **R-A** |
| R-A fails | – | restore the step-3 backup per §5 into the same project's emptied `public` schema, **or** into a new project (re-enter Google OAuth there). Accounts survive: `auth.users` and `identities` are in `data.sql`. |

### After the window

- [ ] Players: re-equip (the 33 manual-review items), and complete Lineage / Class / Background / Spells on Build
  (docs/DEPLOYMENT_CHARACTER_REIMPORT_PLAN.md, steps 3–13, without the import).
- [ ] DM: review both campaigns in DM Space (preset `relaxed` = previous behaviour; change it if wanted).
- [ ] Never re-run the catalog seeds on production (docs/DEPLOYMENT_PRODUCTION_SEEDS.md, rule R1).
- [ ] Optional: turn public sign-up off (Dashboard → Authentication) once every player has an account.

## 4. Rollback R-A (exact)

```
psql "$PROD_DB_URL" -v ON_ERROR_STOP=1 -f supabase/rollback/rollback_v62_hardening.sql
psql "$PROD_DB_URL" -v ON_ERROR_STOP=1 -f supabase/rollback/rollback_inventory.sql
```

The rehearsal ran these as `postgres`, in 2 s. Afterwards: 11 public tables, `inventory_items` with 10 columns and its
original policy, all legacy "equipped" flags back. The migration history keeps the baseline row (F5).

## 5. Restore from backup (exact; rehearsed as R-B)

1. Restore `roles.sql` + `schema.sql` + `data.sql` in one transaction. Locally use the superuser `supabase_admin`. On a
   hosted target, run as `postgres` and remove or ignore `SET log_min_messages` lines if they are refused.
2. Recreate what the dump omits (F1), as the superuser locally, or as `postgres` hosted:

```sql
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();
create policy "portraits_select" on storage.objects for select to authenticated
  using (bucket_id = 'portraits' and public.can_access_character(public.try_uuid((storage.foldername(name))[1])));
create policy "portraits_insert" on storage.objects for insert to authenticated
  with check (bucket_id = 'portraits' and public.can_access_character(public.try_uuid((storage.foldername(name))[1])));
create policy "portraits_delete" on storage.objects for delete to authenticated
  using (bucket_id = 'portraits' and public.can_access_character(public.try_uuid((storage.foldername(name))[1])));
```

3. As `postgres` (F2):

```sql
create event trigger ensure_rls on ddl_command_end when tag in ('CREATE TABLE', 'CREATE TABLE AS', 'SELECT INTO')
  execute function public.rls_auto_enable();
```

4. Verify: pre-check fingerprint `f51346d2954b0aca49a2384c539fe6ad`, SUMMARY 12 / 12 GO, and the counts as in the header.

## 6. Rehearsal environment (to repeat it)

- Folder `%USERPROFILE%\tavern-ledger-rehearsal`: `supabase init`, then in `config.toml`:
  - `project_id = "tl-rehearsal"`;
  - every `543xx` port changed to `553xx`;
  - analytics, edge runtime, Studio and seeding turned off.
- `supabase start`, restore per §5, then the window steps 4–9 against
  `postgresql://postgres:postgres@127.0.0.1:55322/postgres?sslmode=disable`.
- Teardown: `supabase stop --no-backup` **in that folder** (removes only `tl-rehearsal` volumes; the clone holds personal
  data).
