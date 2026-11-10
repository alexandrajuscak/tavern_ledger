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

Filled in by the deployment run.

### Run of 2026-10-30

| # | Result |
|---|---|
| 1 | SQL `fluent_read_tests.sql` 1,707/0; browser suite 1,019/0 (flag on), fluent UI 32/0; flag off: inventory 38/0, background 20/0, incident 57/0; plain-PostgreSQL suite green after fixing `rollback_inventory.sql` (it did not drop `character_revisions`); rollback/reapply exact (functions md5 restored) |
| 2 | 42 migrations, last `20261029000100`, no fluent objects, 0 Realtime subscriptions; Pages served `?v=12` |
| 3 | Backup `…\2026-10-30-fluent-release\2026-10-30T152856Z-pre-fluent` OK, rehearsal 7/7 characters (Supabase Postgres image; public data only, auth tables are created by the Auth service and are not part of the check). First attempt in a plain `postgres:17` image failed (`…T152536Z-pre-fluent`, kept); the script now uses the Supabase image. Catalog counts unchanged (items 1,146, spells 574, feats 408, backgrounds 30, …) |
| 4 | dry run: exactly `20261030000100` |
| 5-6 | commit `fa1d87b` (flag `'off'`), secret scan clean, pushed; Pages `?v=13` live |
| 7 | applied 16:38:55-16:38:59 UTC; history 43; 7 functions, 21 triggers, publication entry, RLS on, `anon` no EXECUTE |
| 8 | direct reads before == after (98 hashes); view == direct (98 pairs, 0 differences); inventory bundle == direct (7/7) |
| 9 | smoke `?fluent=1` 28/0; `?fluent=0` 25/0 (after two wait fixes in the smoke script) |
| 10 | **flag not switched on**: `docs/FLUENCY_BENCHMARKS.md` §3. Under 7 concurrent opens the view runs 15-23 s against the 8 s statement timeout. Commit 2 ships the `57014` → legacy fallback and the docs, with `FLUENT_READS = 'off'` |
| 11-12 | see the final report |

Pre-existing finding (not caused by this release, not changed): `get_class_starting_equipment` fails with `42501` for
characters whose class has placeholder equipment entries, on both paths (2 of 7 production characters). Since migration
`20261017000600`, `authenticated` has had no EXECUTE on `_starting_equipment_candidates`. The UI ignores the error (no
starting-equipment prompt for those characters).

## Progressive release (migration 20261030000200, frontend `?v=14`)

| # | Step | Gate |
|---|---|---|
| 1 | Local: `progressive_read_tests.sql`, `fluent_read_tests.sql`, fluent UI suite, full browser suite (flag on), plain-PostgreSQL suite, rollback exact (`rollback_progressive_fluent_reads.sql`) + reapply | all green |
| 2 | Identity: ref of the access file = ref of `js/config.js`; 43 migrations; nobody active | match |
| 3 | Backup `-Label pre-progressive -Rehearse`; catalog counts; golden before; live frontend revision | OK, rehearsal 7/7 |
| 4 | Dry run: exactly `20261030000200` | anything else → stop |
| 5 | Commit `feat: add progressive fluent character loading` with `FLUENT_READS = 'off'`; secret scan; push; Pages serves `?v=14` | one coherent revision |
| 6 | `db push`; golden after (direct == before, view == direct); grants; trigger coverage; counts unchanged | identical |
| 7 | Controlled concurrency (`scripts/fluent/controlled_concurrency.sh "1 2 3 5"`): real characters as their owners, API timeout 8 s, levels 1 → 2 → 3 → 5, health check between levels; stops at any error or a request over 6 s | all levels pass |
| 8 | Synthetic smoke fixture; `production_fluent_smoke.py` with `FLAG=1` and `FLAG=0` | all pass |
| 9 | Commit `FLUENT_READS = 'on'`; push; smoke with the site default (`FLAG=''`) | all pass |
| 10 | Cleanup (left 0), post backup, delete the access file, password rotation | — |

Rollback: `FLUENT_READS = 'off'` (one line) or `?fluent=0` per browser; the database objects can stay (additive).
`rollback_progressive_fluent_reads.sql` only for a confirmed database defect.
**Correction (2026-11-10):** the database objects were used only by the fluent path when this was written. Since the Combat
Builder release (2026-11-08) they are used regardless of the flag: the Combat Builder always calls `get_character_reads`
(`js/combat-api.js`) and binds `character_revisions`. The flag rollback is unaffected. `rollback_progressive_fluent_reads.sql`
keeps `get_character_reads` (without the cache) but drops the `tl_cache` schema, which the later migrations' `tl_cache_rev`
triggers and `tl_cache.combat_skip()` depend on; `rollback_fluent_read_architecture.sql` drops `get_character_reads` and
`character_revisions` and would break the Combat Builder. Neither script may be run alone any more: the later migrations
must be rolled back first, in reverse order. The legacy Realtime channel now has 70 bindings (64 at the time of the figures below).

### Run of the progressive release (2026-10-30, 19:39-21:45 UTC)

| # | Result |
|---|---|
| 1 | `progressive_read_tests.sql` 1,283/0; `fluent_read_tests.sql` 1,707/0; fluent UI 34/0; full browser suite (flag on) 1,022/0 in 34 suites; plain-PostgreSQL suite 3,432/0 incl. whole-schema rollback + reapply; progressive rollback exact (function hash restored, reapply identical) |
| 2 | access-file ref = frontend ref; 43 migrations; 8 users, 7 characters, 2 campaigns, 0 custom content; nobody active |
| 3 | backup `…\2026-10-30-progressive-release\2026-10-30T193946Z-pre-progressive` OK, rehearsal 7/7; golden before == the previous release's golden after |
| 4 | dry run: exactly `20261030000200` |
| 5 | `e2d4473` (flag `'off'`, `?v=14`) pushed; Pages served one coherent revision |
| 6 | applied 21:27:50-21:27:54 UTC; 44 migrations; trigger on 152/152 tables; grants as designed; counts and catalog unchanged; golden: direct before == after (98), view == direct (98/0), bundle 7/7, **view errors none for all 7 characters** (starting equipment fixed) |
| 7 | concurrency levels 1, 2, 3, 5: passed (worst 710 ms); **5 cold at once: worst shell 1.13 s, domain 0.93 s**; repeat after the fixture had invalidated the cache: worst 1.76 s; 0 errors, database idle between levels |
| 8 | smoke `?fluent=1` 28/0, `?fluent=0` 25/0 |
| 9 | `f9eb28c` (`FLUENT_READS = 'on'`, `?v=15`) pushed; smoke site default 28/0 (twice), `?fluent=0` 25/0; `pg_stat_statements` after a reset: 0 API statements over 6 s, worst 2.7 s, 0 deadlocks |
| 10 | smoke data removed (left 0); backup `…T214417Z-post-progressive` OK, rehearsal 7/7; access file deleted |

Production open (signed-in smoke, site default): usable 309 ms (shell 262 ms / 11 KB, domain 147 ms / 12 KB), A→B→C 494 ms,
2 Realtime bindings, reconnect 1 request; legacy on the same day: 260 ms, A→B→C 1,360 ms, 2 / 64 bindings, reconnect = full reload.
Status: **fixed and monitoring** until a real multi-player session has run without a timeout cluster.
