# Live database architecture evidence (production, read-only, 2026-10-30)

Project `pfgz…` (masked), Supabase Free (Nano compute), PostgreSQL 17.11, 42 migrations (last `20261029000100`).
Taken 2026-10-30 10:04-10:20 UTC while one player had a sheet open.

## How it was collected (safety)

- The operator supplied a connection-string file. It was read into a process environment variable and expanded only
  inside a throw-away `postgres:17` container (`psql`); it never appeared on a command line, in a file in the repository,
  or in output (host and project reference are masked by the runner).
- Every session: `set default_transaction_read_only = on; begin read only; set local statement_timeout = '6s'; … rollback`.
  The server confirmed `transaction_read_only = on`.
- Queries: `scripts/architecture/live_evidence.sql` (new, SELECT-only, aggregates only), `scripts/incident/readonly_evidence.sql`
  (existing), a `pg_stat_statements` per-RPC aggregate, and one **sequential** timing pass: each sheet RPC once for 3
  characters (owner-impersonated via `request.jwt.claims` + `set local role authenticated`, results reduced to byte sizes)
  plus 5 spaced `get_character_derived_stats` calls with `EXPLAIN (ANALYZE, TIMING OFF)`. That is about the load of 4 sheet
  opens, spread over ~1 minute. **No load test, no write, no setting changed, no statistics reset.**
- Output files (aggregates, no personal data): `%USERPROFILE%\tavern-ledger-production-exports\2026-10-30-architecture\`
  (`live_evidence.json`, `incident_evidence_now.json`, `rpc_stats_now.json`, `rpc_serial_timing.txt`, `pages_anon_probe.json`).
- Characters are referred to by position (#1-#7, ordered by id), never by name.

## 1. Size and shape

| Metric | Value |
|---|---|
| Database size | **30.2 MB** (Free limit 500 MB → **6 %**) |
| Schemas | pg_catalog 16.7 MB, public 10.8 MB, auth 1.6 MB, supabase_migrations 0.7 MB, realtime 0.5 MB, storage 0.3 MB |
| public: tables / views / functions / SECURITY DEFINER / policies | 152 / 9 / 379 / 259 / 167 |
| public index size | 4.6 MB; 17 non-unique indexes never scanned (not changed; candidates for a later review only) |
| Largest tables | creatures 568 KB (334 rows), items 440 KB (1,146), class_spell_list_entries 384 KB (1,543), spell_versions 352 KB (574), feat_versions 288 KB (408), item_provenance 288 KB, lineage_traits 264 KB (839), realtime.subscription 288 KB (66), auth.users 256 KB (8) |
| Extensions | pg_stat_statements, pgcrypto, plpgsql, supabase_vault, uuid-ossp |
| Player data | 8 users, 2 campaigns, 8 memberships, 7 characters (5 legacy, 2 with one class at level 2), 92 inventory rows, 8 character spells, 0 custom items, 0 change requests, 0 storage objects |
| Auth | identities: google 6, email 3; 10 sessions; 0 MFA factors; all 8 users signed in within 30 days |
| Audit-like tables | campaign_audit_events 20, inventory_events 37, character_resource_events 7, others 0 → negligible |

**Conclusion:** size is not a constraint for any provider, including every free tier.

## 2. Settings and capacity

| Setting | Value |
|---|---|
| max_connections | 60 (Free/Nano) |
| shared_buffers / effective_cache_size / work_mem | 224 MB / 480 MB / 2 MB |
| max_worker_processes / max_parallel_workers | 6 / 2 |
| statement_timeout | authenticated 8 s, authenticator 8 s, anon 3 s |
| jit | **off** (relevant for any migration: see `docs/FLUENCY_POC_RESULTS.md` §4) |
| track_functions | none (no per-function statistics in prod) |
| Connections now | 31 total: authenticator 11 idle, supabase_admin 8 idle + 1 active, pgbouncer 2, background 5; 0 idle-in-transaction, 0 blocked |
| Cache hit | **100.0 %** heap, 99.98 % index (blks_read 1,981 vs 426 M hits since 2026-10-02) → the whole working set is in RAM |
| Dead tuples | small tables only (characters 47 dead / 7 live, spell_slots 53 / 63); autovacuum handles them; no bloat issue at this size |
| Temp files | 17,957 / 72 GB since 2026-10-02 — **not the app**: top temp writers are Studio / pg-meta introspection and these diagnostic queries (app RPCs wrote 0 temp blocks) |
| Checkpoints | 4,641 timed, 20 requested since 2026-10-02 → normal |

## 3. Statement statistics (pg_stat_statements since 2026-10-14)

| Role | calls | total s |
|---|---|---|
| authenticated (app) | 15,039 | 1,989 |
| supabase_admin (Realtime, platform) | 191,880 | 1,279 |
| authenticator | 7,663 | 87 |
| postgres | 9,238 | 71 |

Top app statements by total time (cumulative, includes the pre-fix incident period):

| RPC | calls | mean ms | max ms |
|---|---|---|---|
| get_character_derived_stats | 217 | 1,152 | 7,968 |
| get_character_spellbook | 125 | 1,732 | 7,796 |
| get_character_proficiencies | 154 | 1,350 | 7,818 |
| get_character_spell_slots | 64 | 2,601 | 7,905 |
| get_character_class_summary | 57 | 2,768 | 7,920 |
| get_character_class_features | 50 | 3,144 | 7,778 |
| get_character_states | 56 | 2,586 | 7,945 |
| get_character_resources | 54 | 2,596 | 7,842 |
| get_character_feats | 46 | 2,297 | 7,525 |
| v_character_attunement | 89 | 976 | 6,633 |

20 statements have a max above 5 s. **Post-fix window:** since the 2026-10-29 18:36 snapshot there were 79 more calls of
these 11 RPCs (195 s total, ~2.5 s mean). That window also contains the incident task's own pre-deployment diagnostics
(owner-impersonated calls before the 23:00 deploy), so it **cannot be attributed to post-fix player traffic**.
`pg_stat_statements` cannot isolate the post-fix period without a reset, and resetting is not allowed. The direct timing
in §4 is the clean post-fix evidence.

## 4. Direct post-fix timing (sequential, idle database)

Round trip agent → session pooler: `select 1` = **42 ms** (5 × 42.1-42.5 ms). Times below include that RTT.

| RPC | char #7 (1 class, L2, 8 spells) | char #4 (1 class, L2) | char #2 (legacy) |
|---|---|---|---|
| get_character_derived_stats | 377 ms (16.7 KB) | 364 ms | 90 ms |
| get_character_proficiencies | 178 | 349 | 90 |
| get_character_spellbook | 549 (27.5 KB) | 769 | 203 |
| get_character_class_summary | 179 | 332 | 87 |
| get_character_spell_slots | 171 | 332 | 88 |
| get_character_class_features | 282 (33 KB) | 406 (33 KB) | 97 |
| get_character_resources | 172 | 340 | 88 |
| get_character_states | 151 | 199 | 81 |
| get_character_feats | 134 | 226 | 77 |
| get_character_transformation | 202 (**75.6 KB**) | 231 | 85 |
| get_character_lineage / background / infusions / governance | 61 / 233 / 56 / 67 | 56 / 337 / 49 / 50 | 43 / 44 / 46 / 50 |
| **Sum of 14 sheet RPCs** | **2.81 s** | **4.04 s** | **1.17 s** |

`get_character_derived_stats` on #4, 5 calls 3 s apart, server-side `Execution Time`: **258, 258, 263, 265, 282 ms**
(client 301-323 ms). Variance at idle is small (±5 %), so **shared-compute jitter is not what users feel when the database is
quiet**; what they feel is the steady cost × the number of evaluations × concurrency.

Same work locally (16-core laptop, Supabase image): derived stats of a 3-class level-9 character 105-183 ms; the
production core is roughly **2.5-4× slower per evaluation** for much simpler characters.

## 5. Realtime

| Metric | Value |
|---|---|
| Publication `supabase_realtime` | 31 public tables |
| Subscriptions now | 66, consistent with 1 open sheet (64 bindings + 2 request bar; stale rows cannot be excluded); 21 unfiltered (DELETE bindings) |
| Replication slots | 2 active (wal2json, pgoutput), lag 0 |
| Realtime/platform statements | 191,880 calls, 1,279 s since 2026-10-14: the WAL poll runs continuously even when idle |

One open sheet costs 66 subscription rows; every switch deletes and recreates them (unchanged by the incident fix, which
only keeps the channel on a same-character reload).

## 6. Dependencies visible in the database

Functions and policies in `public` reference only `auth.uid()` from Supabase schemas; 6 tables have a foreign key to
`auth.users`; one trigger (`on_auth_user_created`) lives on `auth.users`; column defaults use only `auth.uid()`,
`gen_random_uuid()` (core) and `now()`. Full inventory: `docs/SUPABASE_DEPENDENCY_INVENTORY.md`.

## 7. What this evidence says

1. The database is **tiny, fully cached and not I/O-bound**. Disk, RAM size, bloat and indexes are not the problem.
2. The cost is **CPU in the rules core**, repeated: one open of a level-2 character costs 2.8-4.0 s of serial database
   time today (14 RPCs, ~10 core evaluations), on a compute that evaluates the core in ~260 ms.
3. Connection count is not a limit (31 of 60, mostly idle).
4. Realtime keeps a permanent background cost and 66 subscription rows per open sheet.
5. The incident cannot be declared resolved from statistics alone: the timing shows the per-open cost is still
   **seconds of CPU**, so a session-start burst can still queue toward the 8 s timeout (measured locally in
   `docs/FLUENCY_POC_RESULTS.md` §3: 7.2 s max for 5 simultaneous opens even at 2 dedicated CPUs).
