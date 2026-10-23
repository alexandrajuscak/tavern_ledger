# Production deployment package (Strategy A: a new Supabase project), 2026-10-23

> **Superseded (2026-10-23):** production is upgraded **in place** (existing project, accounts and Google sign-in kept). Follow [DEPLOYMENT_INPLACE_UPGRADE_RUNBOOK.md](DEPLOYMENT_INPLACE_UPGRADE_RUNBOOK.md). This document describes the earlier new-project plan and is kept for reference (its seed, Auth and frontend details still apply).

Analysis only. No application file was changed, nothing was committed or pushed, and no remote project was contacted.
The current production project (`pfgz…wlsc`) and the live site (`849d7f1`) stay untouched as the rollback.

## 1. GO / NO-GO

| Area | Verdict | Why |
|---|---|---|
| Build the new database (migrations + seeds) | **GO** | 41 migrations + 9 seeds verified from zero on PostgreSQL 15 and on the local Supabase stack (PostgreSQL 17.6, same as new hosted projects): no errors, idempotent seeds, 0 demo rows, RLS 152/152, 0 unpinned SECURITY DEFINER, integrity report 0. Only extension: `pgcrypto`. No superuser-only statements, Edge Functions, cron, pg_net or vault. |
| Public release commit | **GO for review** (cleanup C1–C5 done 2026-10-23; C6 optional) | README rewritten, character names neutral, paths anonymized, `js/config.js` placeholders + key allowlist, seeds / data / scrapers ignored; the commit waits for approval of the file list and message |
| Secrets | **GO** | no real secret in tracked files, in the release set or in history; local-only keys are ignored |
| Overall | **NO-GO now → GO after C1–C6 and a staging run** | nothing technical blocks the database; the blockers are repository hygiene and the config switch |

### Remaining risks (accepted / documented, not blockers for a private table)

| Risk | Detail | Mitigation |
|---|---|---|
| Frontend and database switch together | the V6.2 frontend does not work against the old legacy database, and vice versa | `js/config.js` gets the new URL and key **in the same commit** as the V6.2 code |
| Seeds run once only | `spells.sql` / `lineages.sql` delete non-catalog rows in `class_spell_list_entries` and `lineage_traits`, which DM custom content also uses | run the 9 seeds once, on the empty database, **before** any DM content; never again in production |
| Catalog readable with the public key | anonymous reads of the official catalog are allowed by design | private table: documented risk; public promotion would need a change |
| `portraits` bucket is public | the migration creates it with `public = true`, so a portrait URL works without a sign-in (the paths contain unguessable character ids) | accept, or set the bucket to private in the Dashboard (the app would then need signed URLs: a later change) |
| Icon licences unknown | 204 WebP icons | documented; blocker only for a promoted public release |
| SQL Editor and large files | migrations up to 228 KB and seeds up to 721 KB | use the CLI / psql (below); the SQL Editor is a fallback |
| Test suites in a public clone | `run_local.sh` / `run_supabase_local.sh` need the seeds and `data/reports`, which stay local | expected: the suites run on this machine |

## 2. Repository cleanup (actions for the release commit)

### Commit (public)

| Path | Files | Note |
|---|---|---|
| `index.html`, `.nojekyll`, `README.md` | 3 | README must be rewritten first (C1) |
| `css/styles.css`, `css/fonts.css` | 2 | |
| `js/*.js` (all except `js/config.local.js`) | 40 | `js/config.js` with the **new** project values (C4) |
| `vendor/supabase-js/supabase-2.117.2.umd.js`, `vendor/supabase-js/LICENSE` | 2 | |
| `fonts/**` | 9 | OFL fonts + licence texts |
| `assets/icons/**` | 204 | licence risk documented |
| `supabase/migrations/*.sql` + `supabase/migrations/README.md` | 42 | |
| `supabase/rollback/*.sql` | 28 | |
| `supabase/config.toml`, `supabase/.gitignore` | 2 | local-stack configuration only |
| `supabase/schema.sql` | 1 (already tracked) | **keep**: legacy reference, used by `supabase/tests/run_local.sh` and `scripts/db/sync_base_migration.py` |
| `supabase/tests/**` (SQL, API and browser suites, isolation harness, integrity report) | – | synthetic fixtures only; `__pycache__` and `*.png` are ignored |
| `scripts/local/*`, `scripts/*.ps1`, `scripts/db/*`, `scripts/deploy/validate_exports.py`, `*-local.bat` | – | local tools; the demo seeder contains only the documented synthetic local password |
| `docs/**` | ~135 | after C2 (and optionally C3) |
| `.gitignore` | 1 | after C5 |

### Do not commit

| Path | Action |
|---|---|
| `supabase/seed/` (9 catalog seeds, 3.2 MB) | add `supabase/seed/` to `.gitignore` (C5) |
| `data/` (raw page caches, normalized data, reports; 1,500+ files) | add `data/` to `.gitignore` (C5) |
| `scripts/data-migration/` (32 scraping / extraction / seed-generation scripts with source URLs) | add to `.gitignore` (C5): tooling for the catalog, not needed to run or deploy the app |
| `examples/`, `*.character.json` | already ignored ✔ |
| `js/config.local.js`, `js/config.staging.js` | already ignored ✔ |
| `supabase/.temp/` (local stack secrets) | already ignored ✔ |
| `.local/`, `*.log`, `*.dump`, `.env*`, `__pycache__/`, root screenshots, `supabase/tests/browser/*.png` | already ignored ✔ |
| Backups, fingerprints, mutation journals, exports | outside the repository ✔ |
| `supabase/snippets/` | empty folder; Git ignores it |

### Cleanup actions (to do in the next, approved step; not done now)

| # | File | Action |
|---|---|---|
| C1 | `README.md` | Replace "paste `supabase/schema.sql` in the SQL Editor" (setup, troubleshooting, "Updating an existing installation") with the migration-based setup from this package. Link docs/LOCAL_DEVELOPMENT.md. |
| C2 | `docs/DEPLOYMENT_CHARACTER_REIMPORT_PLAN.md` | Remove the real character names (pilot table). Your `.gitignore` keeps real characters private; use "character 1–6". |
| C3 | docs mentioning local machine paths (task logs, local / deployment docs) | Done: anonymized to `%USERPROFILE%\…` / `<repository folder>` (2026-10-23). |
| C4 | `js/config.js` | Set `SUPABASE_URL` and `SUPABASE_PUBLISHABLE_KEY` to the **new** production project (publishable key only). Keep `PRODUCTION_HOSTS`. |
| C5 | `.gitignore` | Add `supabase/seed/`, `data/`, `scripts/data-migration/` (`data/raw/`, `config.staging.js` and test PNGs are already added). |
| C6 | `js/app.js` | Optional wording: two error texts still say "Did you run the latest supabase/schema.sql?". This is an application change: do it later, with a test run. |

Verification before committing: `git add -n` (dry run) lists no path under `data/`, `supabase/seed/`,
`scripts/data-migration/` or `examples/`, and no `*.dump`, `*.png` or `config.local|staging.js`. Also run the
secret grep of docs/DEPLOYMENT_PRODUCTION_RUNBOOK.md §6.

## 3. Deployment manifest

| # | Item | Path | Purpose | Required | Order |
|---|---|---|---|---|---|
| 1 | Database migrations (41) | `supabase/migrations/20261015000000_base_schema.sql` … `20261023000100_v62_hardening.sql` (full list in §5) | schema, RLS, functions, triggers (`on_auth_user_created`), Realtime publication, `portraits` bucket and its policies | required | 1 (in filename order) |
| 2 | Required SQL: admin bootstrap | statement in §5, step U4 | gives the DM / admin account the `admin` role (only possible from the SQL Editor) | required | after the first sign-up |
| 2b | Verification SQL | `supabase/tests/catalog_integrity_report.sql` + the checks in §5 | proves counts, RLS, pinned functions, no demo rows | required (read only) | after the seeds |
| 3 | Catalog import (9) | `supabase/seed/reference_data.sql`, `item_effects.sql`, `spells.sql`, `classes.sql`, `class_features.sql`, `creatures.sql`, `lineages.sql`, `feats.sql`, `backgrounds.sql` | official catalog (items, spells, classes, features, creatures, lineages, feats, backgrounds) | required | 2 (exactly this order, once) |
| 4 | Storage | none to upload; bucket `portraits` (public, 2 MB, jpeg/png/webp) and 3 policies come from migration 1 | character portraits | automatic | with migration 1 |
| 5 | Authentication | Dashboard settings (§5, U3) | Site URL, redirects, email confirmation, providers, sign-up policy | required | after the migrations |
| 6 | Environment variables | **server: none.** Frontend: `js/config.js` (`SUPABASE_URL`, `SUPABASE_PUBLISHABLE_KEY`, `PRODUCTION_HOSTS`). Operator shell only: the database URL with password (never stored) | – | required | before the push |
| 7 | Edge Functions | none (`supabase/functions` does not exist) | – | – | – |
| 8 | Cron / scheduled jobs | none (no `pg_cron`, `pg_net` or vault use) | – | – | – |
| 9 | Manual configuration | Dashboard: project, region, password, Auth (U3), optional Google OAuth client, optional SMTP, MFA, backups / plan; app: the DM account, admin role, campaigns, players | – | required | see §4 |

Not to run on the new project: `supabase/schema.sql` (legacy), anything in `supabase/tests/`, `scripts/local/seed_local_demo.py`, `scripts/seed-local-demo.ps1`.

## 4. Deployment sequence

| Step | What | Where | Result |
|---|---|---|---|
| 0 | Pre-flight: exports and backup of the old project done; local suites green; cleanup C1–C5 prepared (not pushed) | this machine | ready |
| 1 | Create the new project `tavern-ledger-prod` (region near the players; generated DB password in a password manager) | Dashboard | an empty project; note the ref (masked) |
| 2 | Empty check, then `db push --dry-run`, then `db push` (41 migrations) | CLI from the repository root | 41 applied; `supabase_migrations.schema_migrations` = 41 rows |
| 3 | Import the 9 catalog seeds, in order, once | psql (Docker) or SQL Editor | counts as in §5 U2 |
| 4 | Verify: counts, integrity report, RLS, pinned functions, publication, 0 users / characters / campaigns | SQL Editor | all as expected |
| 5 | Configure Auth (Site URL, redirect, email confirmation, providers; sign-up **on** temporarily) | Dashboard | settings saved |
| 6 | Create the DM account (sign up through the **local** frontend pointed at the new project via staging mode, or by Dashboard invite), confirm the email, run the admin bootstrap | Dashboard + SQL Editor | DM is `admin` |
| 7 | Frontend: `js/config.js` → the new project; release commit (cleanup C1–C5); push to `main` | Git | Pages redeploys the V6.2 app against the new project |
| 8 | Smoke test (player / DM / security / Realtime / network) | browser | docs/DEPLOYMENT_PRODUCTION_SMOKE_RESULTS.md |
| 9 | DM creates the campaign(s) and preset; players are invited / sign up and are added | app (DM Space) | members in place |
| 10 | **Turn public sign-up off** once every account exists | Dashboard | no strangers |
| 11 | Pilot import: one exported character, completed in Build, re-exported, compared | app | one character done |
| 12 | Remaining characters, one at a time | app | all characters done |
| 13 | Post-deploy logical backup + SHA-256 | `pg_dump` (read-only) | stored outside Git |

Rollback at any point: revert the release commit (the old site and old project are untouched).

## 5. Files I Must Upload To Supabase

You upload **50 files** (41 migrations + 9 seeds) and run **2 SQL snippets** (verification + admin bootstrap). Nothing
goes to Storage, and there are no Edge Functions. `js/config.js` goes to GitHub, not to Supabase.

### U1. The 41 migrations: Supabase CLI (recommended)

Method: `supabase db push --db-url <session-pooler URL>` from the repository root (it applies the whole folder in order
and records the history). The URL comes from Dashboard → Connect → Session pooler. Type the password at a prompt
(docs/DEPLOYMENT_PRODUCTION_RUNBOOK.md §2). Do **not** `supabase link`. The fallback is the SQL Editor, one file at a
time in this exact order. Each must say "Success. No rows returned". In that case no migration history is recorded,
which is acceptable but makes later `db push` runs unaware of what was applied.

| Order | File (`supabase/migrations/`) | Expected |
|---|---|---|
| 1 | `20261015000000_base_schema.sql` | profiles, characters …, auth trigger, `portraits` bucket and policies |
| 2 | `20261015000100_item_lookups.sql` | item lookup tables |
| 3 | `20261015000200_item_catalog.sql` | items |
| 4 | `20261015000300_item_typed_stats.sql` | weapon / armor / … stats |
| 5 | `20261015000400_item_modifiers_and_tags.sql` | modifiers, tags |
| 6 | `20261015000500_inventories.sql` | inventories |
| 7 | `20261015000600_equipment.sql` | equipment slots |
| 8 | `20261015000700_inventory_functions.sql` | inventory RPCs |
| 9 | `20261015000800_inventory_views.sql` | views |
| 10 | `20261015000900_inventory_rls.sql` | RLS |
| 11 | `20261015001000_inventory_indexes.sql` | indexes |
| 12 | `20261015001100_legacy_inventory_migration.sql` | no-op on an empty database |
| 13 | `20261015001200_inventory_frontend_rpcs.sql` | RPCs |
| 14 | `20261015001300_homebrew_and_legacy_items.sql` | homebrew |
| 15 | `20261015001400_derived_character_stats.sql` | derived stats |
| 16 | `20261015001500_character_lineages.sql` | lineages |
| 17 | `20261015001600_spell_catalog.sql` | spells |
| 18 | `20261015001700_class_levels_and_slots.sql` | classes, slots |
| 19 | `20261015001800_class_feature_engine.sql` | class features |
| 20 | `20261017000100_class_engine_extensions.sql` | |
| 21 | `20261017000200_class_page_read_model.sql` | |
| 22 | `20261017000300_spellcasting_class_extensions.sql` | |
| 23 | `20261017000400_spells_ux.sql` | |
| 24 | `20261017000500_hybrid_caster_extensions.sql` | |
| 25 | `20261017000600_class_setup_flow.sql` | |
| 26 | `20261017000700_martial_engine_extensions.sql` | |
| 27 | `20261017000800_creatures_and_transformations.sql` | creatures, companions |
| 28 | `20261017000900_infusions_and_attunement.sql` | |
| 29 | `20261017001000_rest_report_fix.sql` | |
| 30 | `20261017001100_proficiency_resolver.sql` | |
| 31 | `20261017001200_backgrounds.sql` | backgrounds |
| 32 | `20261017001300_wild_shape_engine.sql` | Wild Shape |
| 33 | `20261019000100_campaign_governance.sql` | governance, audit |
| 34 | `20261019000200_change_requests.sql` | approvals |
| 35 | `20261019000300_feat_catalog.sql` | feats |
| 36 | `20261019000400_dm_content.sql` | DM content |
| 37 | `20261019000500_hidden_dm_data.sql` | hidden data |
| 38 | `20261019000600_dm_read_models.sql` | DM read models |
| 39 | `20261019000700_derived_stats_performance.sql` | |
| 40 | `20261019000800_feat_backfill.sql` | no-op on an empty database |
| 41 | `20261023000100_v62_hardening.sql` | audit filtering, validation, HP / coin constraints |

### U2. The 9 catalog seeds: psql in Docker (recommended) or SQL Editor

Method: docs/DEPLOYMENT_PRODUCTION_RUNBOOK.md §3 (`psql -v ON_ERROR_STOP=1 -f`; the connection string is passed as an
environment variable). The SQL Editor fallback is to paste each file whole, in order. The large files (up to 721 KB) may
hit the editor's request limit. If one does, stop and use psql: never paste half a file. **Run once, on the empty
catalog, before any DM content.**

| Order | File (`supabase/seed/`) | Size | Expected after it (cumulative) |
|---|---|---|---|
| 1 | `reference_data.sql` | 422 KB | source_books 58, damage_types 13, items 1,146 |
| 2 | `item_effects.sql` | 1 KB | item effects |
| 3 | `spells.sql` | 721 KB | spell_versions 574, class_spell_list_entries 1,543 |
| 4 | `classes.sql` | 68 KB | class_versions 13, subclass_versions 118 |
| 5 | `class_features.sql` | 614 KB | class_feature_versions 246 |
| 6 | `creatures.sql` | 410 KB | creatures 334 |
| 7 | `lineages.sql` | 495 KB | lineage_versions 133 |
| 8 | `feats.sql` | 315 KB | feat_versions 408 |
| 9 | `backgrounds.sql` | 181 KB | background_versions 30 |

### U3. Authentication: Dashboard (no file)

| Setting | Value |
|---|---|
| Authentication → URL Configuration → Site URL | `https://alexandrajuscak.github.io/tavern_ledger/` |
| Redirect URLs | `https://alexandrajuscak.github.io/tavern_ledger/` (exact; add `http://127.0.0.1:5191/?env=staging` only if you use local staging mode against this project during set-up, and remove it afterwards) |
| Email provider | on, "Confirm email" on |
| Google provider | optional: your OAuth client ID / secret; callback `https://<new-ref>.supabase.co/auth/v1/callback` |
| Allow new users to sign up | on during set-up, **off** after all players exist |
| SMTP | optional custom sender (the default mailer is rate-limited) |
| MFA | enable for your Supabase account (Dashboard) |

### U4. SQL snippets: SQL Editor

| Order | Snippet | Expected |
|---|---|---|
| after U2 | `supabase/tests/catalog_integrity_report.sql` (read only) | 14 rows, all `0` |
| after U2 | `select count(*) from pg_tables where schemaname='public' and not rowsecurity;` | `0` |
| after U2 | `select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.prosecdef and not exists (select 1 from unnest(coalesce(p.proconfig,'{}')) c where c like 'search_path=%');` | `0` |
| after U2 | `select (select count(*) from auth.users), (select count(*) from public.characters), (select count(*) from public.campaigns), (select count(*) from public.dm_content);` | `0 0 0 0` |
| after the DM's first sign-up and email confirmation | `update public.profiles set role = 'admin' where email = '<your DM e-mail>';` | `UPDATE 1` |

### Not uploaded to Supabase

- `js/config.js` (new URL + publishable key): goes to GitHub with the release commit.
- Character exports: imported later through the app (home → Import file), one at a time.
