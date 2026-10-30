# Fluent read release: production deployment (2026-10-30)

Project `pfgz…` (masked), frontend `https://alexandrajuscak.github.io/tavern_ledger/`. Authorized by the operator for this
release (backup, additive migration, commit, push, `db push`, Pages deploy, signed-in smoke with synthetic accounts, forward
fix). No staging project. Reversible: frontend flag + rollback SQL; no data migration.

## Procedure

| # | Step | Gate |
|---|---|---|
| 1 | Local: SQL suite, fluent browser suite, full browser suite, plain-PostgreSQL migration suite, rollback / reapply | all green |
| 2 | Production identity: host, project ref (masked), migration count 42, last `20261029000100`; Pages serves `10e5cc0` | match |
| 3 | Pre-deployment backup (`scripts/backup/nightly_backup.ps1 -Label pre-fluent -Rehearse`) + catalog counts + golden before + frontend revision + config manifest | files non-empty, checksums, counts match, rehearsal restores the same number of characters |
| 4 | `supabase db push --dry-run`: exactly `20261030000100` | anything else → stop (no repair) |
| 5 | Release commit 1 (flag `FLUENT_READS = 'off'`): code, migration, rollback, tests, docs; secret scan; POC code excluded | scan clean |
| 6 | Push `main` → Pages build | live revision = commit 1 |
| 7 | `supabase db push` (one migration) | history 43; functions, grants, publication present |
| 8 | Golden after: direct reads == before; view == direct | identical |
| 9 | Synthetic smoke fixture (`scripts/fluent/smoke_users.sql`), smoke with `?fluent=1` (`production_fluent_smoke.py`) | all pass |
| 10 | Commit 2: `FLUENT_READS = 'on'`; push; Pages; smoke again with the site default | all pass |
| 11 | Smoke cleanup (`smoke_cleanup.sql`: left = 0); post-deployment backup (`-Label post-fluent`) | 0 left; backup OK |
| 12 | Delete the access file; operator rotates the database password | — |

## Rollback

| Situation | Action | Data effect |
|---|---|---|
| New path misbehaves | `js/config.js` `FLUENT_READS = 'off'` (one-line commit) — or per browser `?fluent=0` | none; the legacy path works against the new database (tested) |
| New database objects must go | `supabase/rollback/rollback_fluent_read_architecture.sql`, then `supabase migration repair --status reverted 20261030000100` (separate decision), frontend flag `'off'` first | drops counters and new functions only; restores the two functions exactly |
| Previous frontend | revert to `10e5cc0` (works with the new database: all old RPCs unchanged) | none |

## Results

Filled in by the deployment run (see the final report and the sections below).
