# Migration review

The first draft (`001_…`–`011_…`) had never been deployed anywhere, so it was **corrected in place** instead of adding
corrective migrations. Every file was renamed and rewritten; the old names no longer exist.

## Naming and bootstrap

| Old | New | Change |
|---|---|---|
| – | `20261015000000_base_schema.sql` | **new**: generated copy of `supabase/schema.sql` (`scripts/db/sync_base_migration.py`, drift check in both test runners) |
| `001_item_lookups.sql` | `20261015000100_item_lookups.sql` | forward-only `create table` |
| `002_item_catalog.sql` | `20261015000200_item_catalog.sql` | homebrew data source + ownership rules in the trigger |
| `003_item_typed_stats.sql` | `20261015000300_item_typed_stats.sql` | `tool_stats`, `item_effects` removed; `container_stats` + `consumable_effects` extended |
| `004_item_modifiers_and_tags.sql` | `20261015000400_item_modifiers_and_tags.sql` | modifier ownership trigger |
| `005_inventories.sql` | `20261015000500_inventories.sql` | equipped projection, quantity rule, depth limit, legacy snapshot, direct-change events |
| `006_equipment.sql` | `20261015000600_equipment.sql` | read-only for clients |
| `007_inventory_functions.sql` | `20261015000700_inventory_functions.sql` | row-based permission helpers, `pg_temp` search_path, richer `use` result/events |
| `008_inventory_views.sql` | `20261015000800_inventory_views.sql` | derived `equipped`, `v_container_contents`, cargo capacity |
| `009_inventory_rls.sql` | `20261015000900_inventory_rls.sql` | 64 → 42 policies, column privileges, owner fixes |
| `010_inventory_indexes.sql` | `20261015001000_inventory_indexes.sql` | 51 → 11 explicit indexes, no `pg_trgm` |
| `011_seed_reference_data.sql` | `supabase/seed/reference_data.sql` | **moved out of the migrations**: re-runnable seed (`[db.seed]` in `config.toml`) |
| – | `20261015001100_legacy_inventory_migration.sql` | **new**: `migrate_legacy_inventory()` |
| `rollback/rollback_001_011.sql` | `rollback/rollback_inventory.sql` | covers the new objects, restores legacy `equipped` and grants |

The Supabase CLI requires `<timestamp>_name.sql`; numeric `001_` would have been read as version `001` and sorted before any
future timestamped migration. `README.md` in the folder is skipped by the CLI (it prints a notice).

`schema.sql` was a prerequisite **outside** any migration history. It is now also the baseline migration, so a new local or test
project is built with `supabase db reset` (base → inventory migrations → seed), never by pasting SQL. On the live project the
baseline is already applied by hand: record it with `supabase migration repair --status applied 20261015000000` before the first
`db push` (not done; requires linking, which is out of scope). Rule from now on: base-schema changes go into new migrations, and
`schema.sql` is regenerated from them or retired.

**Migrations vs seed**: migrations run once (CLI history); they are forward-only and fail loudly if an object already exists
(no `if not exists` that could silently skip a needed change). The seed is idempotent (`insert … on conflict do update`),
re-runnable, contains no credentials, and never overwrites homebrew rows. `migrate_legacy_inventory()` is idempotent too.

## Line-by-line findings

| Area | Finding | Resolution |
|---|---|---|
| `if not exists` everywhere | could silently skip a changed table on a half-migrated database | removed from migrations (kept only in the base schema, which is idempotent by design) |
| transaction boundaries | the seed had `begin/commit` inside; the CLI runs each migration and the seed in its own transaction | removed; the CLI applies each migration and the seed atomically. If a file is ever run by hand in the SQL editor, wrap it in `begin; … commit;` |
| default grants | Supabase grants new tables/functions to `anon`/`authenticated`; the draft relied on RLS alone for some tables | every new table: `revoke all` then explicit grants; internal functions revoked from `public, anon, authenticated` |
| ownership | objects are created by the migration role (`postgres` on Supabase, not a superuser locally) | verified on the local stack; no `alter … owner` needed |
| SECURITY DEFINER | `search_path = public` | `public, pg_temp` on all new functions; base-schema helpers noted for follow-up |
| RLS on INSERT … RETURNING | id-lookup helpers rejected PostgREST inserts | row-based helpers (docs/RLS_SECURITY_REVIEW.md #1) |
| FK `ON DELETE` | reviewed every FK: inventory rows cascade with inventory/character; `container_item_id` set null; events keep history (`set null` on item and row); catalog items `restrict` while owned | unchanged, now indexed where the action scans a large table |
| check constraints | `quantity >= 0` allowed new zero rows | trigger blocks new zero rows; CHECK `item_id is null or quantity >= 1`; global CHECK planned after cleanup |
| generated columns | none (stack_key is trigger-maintained because it depends on another table) | – |
| views | security_invoker on all 7; `v_inventory_detail` no longer exposes the raw legacy column | – |
| function volatility | permission helpers `STABLE`; `compute_stack_key` `STABLE`; RPCs `VOLATILE` | correct |
| race conditions | double use, concurrent equips, attunement limit, merge deadlocks | `FOR UPDATE` row locks, advisory locks per character/inventory, id-ordered locking in merge; tested with two sessions and 8 parallel API calls |
| RPC flag `tavern.rpc` | stayed set for the rest of a transaction | reset before every return; merge results computed before the reset (no duplicate events) |
| rollback | did not restore legacy `equipped` or table grants | restores both; tested on plain PostgreSQL and Supabase |

## Rollout order (when approved)

1. Backup. 2. `supabase migration repair --status applied 20261015000000` (baseline). 3. Apply `20261015000100…001100`.
4. Run `supabase/seed/reference_data.sql`. 5. `select public.migrate_legacy_inventory();` and keep the JSON summary.
6. Review `legacy_inventory_review` (manual items). 7. Frontend phase 2. None of this has been executed against a remote project.
