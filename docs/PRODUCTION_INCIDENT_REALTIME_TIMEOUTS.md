# Production incident: database timeouts and Realtime connection pressure (2026-10-23)

Status: **FIX DEPLOYED 2026-10-29 23:00 UTC; MONITORING** (section 9). The diagnosis used read-only sessions only.
Production project `pfgz…wlsc` (masked), frontend `https://alexandrajuscak.github.io/tavern_ledger/` at release `9b810aa`.
No secrets in this file. Related: docs/PERFORMANCE_AUDIT_2026-10-27.md (earlier read-only audit; its R1 is the SQL fix here).

## 1. State at the start of the investigation (2026-10-29)

| Item | Value | Source |
|---|---|---|
| Repository | `main`, HEAD `9b810aa` (= deployed release) | `git status` |
| Previous frontend | `849d7f1` (legacy app; incompatible with the upgraded database, no rollback target on its own) | handover |
| Production migrations | 41, last `20261023000100` | read-only query |
| Plan / PostgreSQL | Free; 17.11; compute size not read (Dashboard) | handover / query |
| max_connections / shared_buffers / work_mem | 60 / 224 MB / 2 MB | query |
| statement_timeout | `authenticated` 8 s, `anon` 3 s, others default | query |
| Realtime pool setting | not read (Dashboard only); **unchanged** | – |
| Latest backup | post-upgrade dump 2026-10-23 (`%USERPROFILE%\tavern-ledger-production-exports\2026-10-23-window\post-upgrade\`); a **fresh** dump is mandatory before Phase F | file system |
| Availability now | up; nobody online during the measurement (15 connections, 0 Realtime subscriptions) | query |
| User impact | slow sheets, Background options not loading, worse when switching characters | report |

Production access: the operator provided a connection string in a local file; the agent used it only through a
`psql` session forced to `default_transaction_read_only = on` inside `BEGIN READ ONLY … ROLLBACK` and never printed it.
**Recommendation:** delete the connection-string file now; for Phase F the operator sets `$env:PROD_DB_URL` in their own
window (as in the 2026-10-23 runbook); reset the database password after Phase F.

## 2. Timeline

| Time | Observation | Evidence | Hypothesis | Status |
|---|---|---|---|---|
| 2026-10-23 18:10 CEST | pre-upgrade backup | file times | – | – |
| 18:47 CEST | post-upgrade dump finished (last deployment step); players informed | file times, handover | – | – |
| 19:13-19:19 | `57014` clusters and Realtime `IncreaseSubscriptionConnectionPool: Too many database timeouts` | Supabase logs (operator) | first real player load after the upgrade | **after** all deployment work (whether CEST or UTC); deployment overlap excluded |
| same period | checkpoint logged | logs | – | not a cause (checkpoint stats normal: 19 requested since 2026-10-02, cache hit 100 %) |
| 2026-10-27 | local audit: 11 RPCs per open each recompute the derived stats; items seq scan | PERFORMANCE_AUDIT | – | confirmed locally |
| 2026-10-29 | production read-only evidence (section 3) | `readonly_evidence.sql`, EXPLAIN | – | confirmed |
| 2026-10-29 | local reproduction, fix, tests | probe, suites | – | done |

Free-plan logs of 2026-10-23 were not available to the agent; statement attribution comes from `pg_stat_statements`
(since 2026-10-14, i.e. the whole V6.2 period). Cancelled statements are not recorded there; their successful calls are.

## 3. Evidence

### 3.1 Which statements time out

| RPC (role authenticated) | calls | mean ms | **max ms** | total s |
|---|---|---|---|---|
| get_character_derived_stats | 205 | 1,127 | **7,968** | 231 |
| get_character_proficiencies | 152 | 1,326 | 7,818 | 202 |
| get_character_spellbook | 118 | 1,703 | 7,796 | 201 |
| get_character_class_summary | 48 | 2,772 | 7,920 | 133 |
| get_character_class_features | 44 | 2,908 | 7,778 | 128 |
| get_character_resources | 49 | 2,592 | 7,842 | 127 |
| get_character_spell_slots | 44 | 2,736 | 7,905 | 120 |
| get_character_states | 47 | 2,532 | 7,945 | 119 |
| get_character_feats | 43 | 2,255 | 7,525 | 97 |
| v_character_attunement | 85 | 1,007 | 6,633 | 86 |
| get_character_background | 38 | 837 | 7,044 | 32 |
| `characters` by primary key | 55 | 84 | 3,450 | 5 |

Every derived-stats RPC peaked just under the 8 s limit; the calls that crossed it were the 57014s. Idle production, each
RPC once, as the owner: 0.5-4.2 s per character for the 12 sheet RPCs together (one character: derived 433 ms, spellbook
928 ms). Alone, nothing approaches 8 s; together (about 10 in parallel per open, repeated per switch, several players,
plus Realtime-triggered re-reads) they queue until they do. A primary-key read reaching 3.45 s points to CPU queueing
(inferred; CPU graphs not available to the agent).

Root statement inside the derived core (production EXPLAIN ANALYZE as authenticated):
`_derived_stats_full` joins `public.items` on a `jsonb_array_elements()` set → **Seq Scan of 1,146 items with the RLS
function `_item_visible` per row: 144 ms**, in about 8 of the RPCs of every open (≈1.1 s CPU per open). The same lookup by
primary key: **3.6 ms**.

### 3.2 Realtime

| Statement (role supabase_admin) | calls | max ms | total s |
|---|---|---|---|
| WAL poll (`list_changes`) | 167,052 | 6,860 | 1,074 |
| subscription create (2 shapes) | 7,015 | 3,103 | 47 |
| replication slot create | 52 | 9,173 | 13 |
| partition create | 9 | 8,207 | 8 |

One sheet = one channel with **64 bindings** = 64 `realtime.subscription` rows (+2 for the request bar); every switch
deletes 64 and creates 64 (a fresh random channel name). The Realtime server's own statements ran 3-9 s against the
saturated database, which Realtime reports as `IncreaseSubscriptionConnectionPool: Too many database timeouts`.
Connections were not the limit (15 of 60 idle; 0 idle-in-transaction, 0 blocked).

Found locally (code + measurement, release 9b810aa):
- a DELETE cannot be filtered and its `old` holds only the key, so **every delete of any character** made every open sheet
  re-read derived stats (3 heavy RPCs per sheet per delete);
- every `characters` UPDATE (an HP tap) re-read derived stats in **every** session viewing that character (3 + 3);
- a reconnect remounted the sheet with a new channel (leave + join of 64 bindings) and a full reload per drop.
- one client and one WebSocket per page (verified: `__tavernLedgerClients` = 1, one socket): **no duplicate clients**.

### 3.3 Obsolete reads

No read had an AbortSignal. Paced A → B → C (700 ms): all 10 heavy RPCs of A and of B ran to completion (150 ms latency).
Verified locally: when the client aborts, PostgREST 14 cancels the statement (production runs 14.18), so cancelling saves
database time. Stale responses never rendered before either (sequence guards); the cost was the work.

### 3.4 Background picker

Catalog complete in production: 29 backgrounds, 30 versions (16 × 2024, 14 × 2014, 29 enabled by default), 25 choices,
391 options, 75 grants, 17 feat grants, 46 equipment packages: identical to the post-deployment validation. Backgrounds
have no campaign / custom variant, so policy cannot empty the list. `get_background_catalog`: 89-104 ms idle, 470 KB.
Cause: the picker awaited the catalog **before showing anything**, behind the sheet burst on a saturated database, with no
loading, timeout or Retry state (a toast at best). Class and spell pickers had the same pattern and failed silently.

### 3.5 Frontend release consistency

Pages served `9b810aa`; all modules are imported with the same `?v=10` specifier (no module loaded twice). No service
worker. Not a cause; the fix bumps every specifier to `?v=12` so the new release cannot mix with cached old modules.

## 4. Root cause (ranked)

1. **Server work per sheet open** on Free compute: ~9-10 RPCs that each run the full rules core, with a 144 ms items
   scan in 8 of them, fired in parallel → CPU saturation → statements over 8 s (57014).
2. **Amplifiers that multiplied that work:** obsolete reads never cancelled on switching; derived re-reads on every HP
   change in every viewing session; cross-character DELETE reloads in every open sheet; full remount per reconnect.
3. **Realtime pool errors = consequence** of 1-2 plus subscription churn (64 rows per switch), not a pool-size problem.
4. **Background picker:** no independent loading and no final state, so the saturation looked like a broken feature.

Not causes (checked): missing catalog rows, RLS defect, campaign policy, duplicate clients, mixed assets, deployment
overlap, connection exhaustion, the checkpoint.

## 5. Fix (local, tested)

| Change | Files |
|---|---|
| R1: items lookup by primary key (same result; RLS unchanged) | `supabase/migrations/20261029000100_derived_stats_items_lookup.sql`, rollback `supabase/rollback/rollback_derived_stats_items_lookup.sql` |
| Abort obsolete character reads (generation + AbortController; never writes) | `js/read-control.js` (new), `js/supabase.js`, `js/sheet.js`, `js/app.js`, `js/store.js` |
| Derived re-read only when a column the SQL reads changed | `js/sheet.js` |
| DELETE attribution (other characters' deletes dropped) | `js/store.js` |
| Channel kept on same-character reload; reconnect debounced to one reload | `js/sheet.js` |
| Spellbook loads with the Spells section | `js/sheet.js` |
| Save retries bounded (edits kept) | `js/store.js`, `js/app.js`, `css/styles.css` |
| Catalog pickers: shell first, final state, Retry, 15 s limit; class / spell no longer silent | `js/catalog-load.js` (new), `js/background-ui.js`, `js/background-api.js`, `js/class-ui.js`, `js/class-setup.js`, `js/spell-ui.js`, `css/styles.css` |
| Cache busting `?v=10/11` → `?v=12` | `index.html`, all `js/*.js`, 3 tests + 2 scripts that import modules |
| Tests / tools | `supabase/tests/browser/production_timeout_incident_test.py`, `incident_probe.py`, `supabase/tests/derived_stats_items_lookup_tests.sql`, runner lists, `scripts/incident/*.sql` |

Not changed: RLS, policies, grants, indexes (no index is missing; the planner estimate was the problem), statement_timeout,
max_connections, Realtime settings, catalog data, the visual design.

Measurements: docs/PRODUCTION_PERFORMANCE_BASELINE.md, docs/CHARACTER_LOADING_REQUEST_INVENTORY.md.
Design: docs/CHARACTER_LOAD_COORDINATOR.md, docs/CATALOG_PICKER_LOADING.md, docs/REALTIME_SUBSCRIPTION_ARCHITECTURE.md.
Pool / compute: docs/PRODUCTION_OPERATIONS.md (**no pool change**; monitor; compute upgrade only if still slow after the fix).

## 6. Validation

See the final report for exact counts: incident suite, related pickers, backend plain-PostgreSQL suite with the new
rollback in the rollback chain, migration up / rollback / reapply on the local stack, golden comparison (70/70 outputs equal
as multisets; 2 differ only in the order of tied proficiency entries), complete browser suite, isolation fingerprints.
Staging: **none exists**; the local stack has the same 41 + 1 migrations. `run_supabase_local.sh` was not run (it deletes
local development data).

## 7. Production plan (Option 2: frontend + SQL function fix)

Order: database first (the new function body is backward compatible with the old frontend: same signature and result),
then the frontend. Expected downtime: none. Each step has its own rollback.

0. Operator window; a fresh PowerShell with `$SB` (CLI) and `$env:PROD_DB_URL` (never pasted in chat).
1. **Backup** (window runbook Phase 2 commands) into `%USERPROFILE%\tavern-ledger-production-exports\<date>-incident-fix\pre`:
   `db dump --role-only`, schema, `--data-only`; `Get-FileHash … SHA256`; record migration count (41), catalog counts
   (`scripts/deploy/catalog_counts.sql`), character / campaign / custom-content counts.
2. **Golden before:** `scripts/incident/golden_derived.sql` (read-only) → save the NOTICE lines.
3. `& $SB db push --db-url $env:PROD_DB_URL --dry-run` → must list **exactly** `20261029000100_derived_stats_items_lookup.sql`.
4. `& $SB db push --db-url $env:PROD_DB_URL` → 42 history rows.
5. **Golden after:** same script → identical lines. EXPLAIN check: the items statement uses the index (optional).
6. Frontend: the approved commit pushed to `main` (operator); Pages rebuild; live `index.html` references `js/app.js?v=12`.
7. Smoke (player, DM, system) as listed in the final report; `readonly_evidence.sql` snapshot after 1 day and 1 week.

Rollback:
- frontend: `git revert --no-edit <fix commit>` + push (database unaffected);
- function (a **separate production change that needs its own approval**; preferred alternative: a forward fix):
  `psql $env:PROD_DB_URL -f supabase/rollback/rollback_derived_stats_items_lookup.sql`, then mark the migration reverted
  with the CLI as in the 2026-10-23 runbook, `& $SB migration repair --db-url $env:PROD_DB_URL --status reverted 20261029000100`
  (no direct edit of the history table; no data touched, no data lost);
- restore the backup only for severe corruption (not expected: the migration changes one function).

## 8. Gate

No production change has been made. Deployment starts only after the exact phrase:

**PROCEED WITH PRODUCTION INCIDENT FIX**

## 9. Deployment record (approved 2026-10-29: "PROCEED WITH PRODUCTION INCIDENT FIX")

| Step | Result |
|---|---|
| Safety check | repository `alexandrajuscak/tavern_ledger`, branch `main` = Pages source; config ref = target ref `pfgz…wlsc`; live frontend before `9b810aa`; 41 migrations; commit set 67 files, secret scan clean (no password, connection string, secret key, token, e-mail); `latency_probe.py` excluded |
| Pre-fix backup | `%USERPROFILE%\tavern-ledger-production-exports\2026-10-29-before-timeout-fix\`: roles / schema / data, migration history, counts, golden, manifest; SHA-256 roles `168a95a9…`, schema `c79bc5df…`, data `fceff241…` (verified) |
| Golden before | 7 characters, file hash `c7469cad…` |
| Commit / push | `a568ab5` "fix: reduce character-load pressure and picker timeouts", pushed `9b810aa..a568ab5` to `main` at 22:59:41 UTC |
| Migration | dry run listed exactly `20261029000100_derived_stats_items_lookup.sql` (no seeds, no roles); applied 23:00:01-23:00:03 UTC; 42 history rows |
| Verification | function: primary-key lookups active, SECURITY INVOKER, STABLE, search_path pinned, EXECUTE for authenticated unchanged; counts identical except the migration count; **golden after identical** (`c7469cad…`); the post-fix data dump is byte-identical to the pre-fix one (only pg_dump's random restrict key differs) |
| Frontend | Pages build `a568ab5` built; 44 served files identical to the commit; `index.html` loads `?v=12` only; no CDN, no placeholder in the config, no secret in served assets |
| Anonymous browser smoke | sign-in screen, environment production, 1 Supabase client, no HTTP or console error, no overflow at 390 px |
| Security smoke (read-only, RLS simulated per user) | 36 non-owner pairs refused, 0 derived-stats leaks; 13 non-owner views = campaign DM / admin by policy; anon denied on `characters`; no custom or hidden DM content exists in production yet (0 rows) |
| Idle timings after (one sample per character) | the two heaviest characters: 4.23 → 3.44 s and 2.54 → 1.79 s for the 12 sheet RPCs together |
| Post-fix backup | `…\2026-10-29-after-timeout-fix\`: SHA-256 roles `168a95a9…`, schema `d2aee694…`, data `7dacf4cd…` (verified) |
| Credentials | the connection-string file was overwritten and deleted after the last database step |
| Not changed | Realtime pool, max_connections, statement_timeout, compute, catalog, RLS |

Not done by the agent (no production player or DM credentials, no Supabase access token): the signed-in player, DM and
two-session Realtime smoke in the browser, and the Supabase log review. Operator checklist:
docs/DEPLOYMENT_PRODUCTION_SMOKE_RESULTS.md.

### Monitoring

| When | Check | Close the incident if |
|---|---|---|
| 2026-10-30 (24 h) | Supabase Logs since 2026-10-29 23:00 UTC: new `57014`, `IncreaseSubscriptionConnectionPool`, API 5xx; a `scripts/incident/readonly_evidence.sql` snapshot; player reports | – |
| 2026-11-05 (7 days) | the same; compare `pgss_top_by_max` with the 2026-10-29 snapshot by difference | no new timeout cluster |

If clusters return: collect the exact statements (`pgss_over_5s`), then assess compute (docs/PRODUCTION_OPERATIONS.md);
do not raise connection settings blindly. The next software step if needed is R2 (docs/PERFORMANCE_AUDIT_2026-10-27.md).
