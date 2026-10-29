# Performance audit - character sheet RPC timeouts (read-only, 2026-10-27)

Status: **Phase 1 audit + Phase 2 root-cause report. Nothing was changed** (no code, no migration, no database object).
The only file written is this document. Measurements were taken on the LOCAL Supabase stack (PG 17.6, `supabase_db_tavern_ledger`),
using read-only queries; the few that created session-scoped temp tables (`track_functions` baselines) or ran inside `begin ... rollback/commit`
wrote nothing persistent. Session-level `track_functions` / `auto_explain` only; no `pg_stat_statements` reset. **Production was not touched.**

Repository facts that differ from the brief: the frontend is **vanilla ES modules (no React, no React Query, no Strict Mode)**.
There is no `refetchInterval`, no `setInterval`, no focus-refetch. "Single query key" therefore maps to a per-sheet sequence guard.

## 1. Executive summary

1. The brief's hypothesis is **partly confirmed**: one page open fires **~10 independent PostgREST RPCs that each recompute the complete
   derived stats** (`get_character_derived_stats` ≈ 105 ms warm, local, uncontended). They run in parallel, in separate backends.
2. The bigger finding is **not the weapon loop at `_derived_stats_core` line ~333**. That loop runs at most twice (main/off hand only).
   The measured dominant cost is a single statement in `_derived_stats_full` that **seq-scans the whole `items` catalog (1,150 rows) and
   runs the RLS predicate `_item_visible()` on every row** - 1,153 evaluations per derived-stats call. That statement alone takes
   ~46-48 ms of a ~105-130 ms call (**roughly 40 %**, measured by running the statement standalone, see 3.1). Cost grows with catalog size and is
   multiplied by every parallel RPC (8 of the 11 page-load RPCs run it; 9,224 `_item_visible` calls per page open).
3. `get_character_spell_slots` costs the same as a full derived-stats call (103 ms vs 105 ms) because `_character_mods` ->
   `get_character_derived_stats`. Slots only need six ability modifiers, but those modifiers are produced inside the core
   (items/feats/lineage/background can change scores), so the fix is to extract that part, not to read `characters` directly.
4. Retry-storm hypothesis is **mostly refuted**: SQLSTATE 57014 matches no retry rule on the client (`inventory-api.js:65`, kind `unknown`),
   sheet loaders have no retry, and they have sequence guards against stale responses. What *does* amplify load is (a) the burst of
   ~36 requests per open with no cancellation on navigation (known F-1), (b) Realtime events -> debounced re-reads of derived stats,
   (c) users re-opening a sheet after a timeout.
5. **Honest gap:** locally one derived call is ~105-130 ms and 20 parallel calls on a 16-CPU container finish in <= 0.73 s. That is nowhere near
   10-11 s. Local data explains a 2-10x inefficiency, **not** a 100x one. Something production-specific is missing (catalog size, cold cache,
   CPU credits of the Free compute, connection-pool queueing, Realtime load, or a character much bigger than my test characters).
   Whether Supabase Free is sufficient **cannot be answered yet**; the evidence needed is in section 14. Realtime is a strong candidate for the
   "RAM stays high while the page is open" symptom (3.5) and nothing the SQL fixes change touches it.

## 2. Frontend RPC / Supabase inventory (character page)

Exact line numbers are from the current working tree (`tavern_ledger/js`).

| # | Source | Call | Trigger | Initial load | After mutation | Realtime | Retry | Cleanup |
|---|---|---|---|---|---|---|---|---|
| 1 | `sheet.js:464 loadDerived` -> `inventory-api.js:364` | `get_character_derived_stats` + `get_character_proficiencies` (Promise.all) | mount (`sheet.js:3039`); `scheduleDerived` (300 ms debounce) | yes | yes (inventory rows change, saver "saved" when `derivedDirty`) | yes (via inventory `scheduleRefresh`) | none; seq guard `derivedSeq` | `derivedSeq++` on unmount, response dropped; **request not aborted** |
| 2 | `sheet.js:572 loadClasses` | `get_character_class_summary`, **`get_character_spell_slots`**, `get_character_class_features`, `get_character_resources`, `get_character_states`, catalog (Promise.all, 6), then `get_character_transformation`, companions, `get_character_infusions` (Promise.all, 3), then starting-equipment state (sequential) | mount; `scheduleClasses` 250 ms; feature handlers `onResources` | yes | yes | yes (`character_classes`, `character_resources`, ...) | none; `classSeq` guard | not aborted |
| 3 | `sheet.js:688 loadSlots` | `get_character_spell_slots` | slot events, `scheduleSlots` 250 ms | no | yes | yes (`character_spell_slot_state`, `character_temporary_spell_slots`) | none; `slotsSeq` + `slotEpoch` | not aborted |
| 4 | `sheet.js:555 loadSpellbook` | `get_character_spellbook` (+ spell reference once) | mount; `scheduleSpellbook` 300 ms | yes | yes | yes | none; `spellbookSeq` | not aborted |
| 5 | `sheet.js:501/520/482` | `get_character_lineage`, `get_character_background`, `get_character_feats` | mount; after changes | yes | yes | partly | none; per-loader seq | not aborted |
| 6 | `sheet.js:604 loadTransform` | `get_character_transformation` (again) | Realtime `character_transformations` | no | yes | yes | none | `tfEpoch` |
| 7 | `inventory-ui` mount (`sheet.js:3010`) | inventories/equipment/catalog via `from()`/RPC (`inventory-api.js`) | mount; `scheduleRefresh` | yes | yes | yes | `read()` retries **network/concurrent only**, 2x, linear 300 ms (`inventory-api.js:65-82`) | `AbortController` for catalog paging only |
| 8 | `governance-api` via `mountGovernance` | `get_character_governance`, `get_character_change_requests` | mount; Realtime on `change_requests`, `character_governance` | yes | yes | yes | none | `destroy()` |
| 9 | `store.js:352 subscribeCharacter` | Realtime, 1 channel | mount | - | - | - | resync on reconnect -> `ctx.reload()` (full bundle reload) | `removeChannel` on unmount (`sheet.js:3047`) |
| 10 | `store.js` saver | `from(table).update` | typing (600 ms queue/merge) | no | - | - | backoff `min(30 s, 1 s*2^n)`, permanent codes not retried (`store.js:230`) | `flush` on hidden/online/beforeunload |

Per-open request count (handover F-1, measured against hosted project): **~36 requests**, round trip 0.11-0.19 s.
Idle minute: **0 application-initiated requests** (no timers). Remaining idle traffic: Realtime heartbeat (supabase-js default 25 s) and
auth token refresh. Realtime *events* from other sessions (e.g. DM edits) do trigger re-reads.

Race / retry findings (frontend):
- Stale-response protection exists for every loader (`*Seq` guards, `C().id !== id` check). **Confirmed OK.**
- **No request cancellation** on character switch / unmount (F-1: ~57 requests still running after the last sheet was ready).
  Server keeps computing for sheets nobody sees. **P0 amplifier.**
- No single in-flight dedupe: `get_character_transformation`, `get_character_spell_slots` can be in flight twice (mount + Realtime).
- No central retry classifier; `inventory-api.js` has one, sheet loaders have none. 57014 is never auto-retried (verified by rule table).

## 3. Confirmed root causes (with evidence)

### 3.1 P0 - catalog seq-scan + per-row RLS inside `_derived_stats_full`
`supabase/migrations/20261019000300_feat_catalog.sql:1481-1488`:
```sql
from jsonb_array_elements(eff) x
left join public.proficiency_groups g on x ->> 'target' = 'group' and g.id = x ->> 'value_text'
left join public.items it on x ->> 'target' in ('weapon','armor','tool') and it.id = x ->> 'value_text'
```
Plan captured with `auto_explain` (one call, multiclass test character):
```
Hash Right Join  Hash Cond: (it.id = (x.value ->> 'value_text'))
  -> Seq Scan on items it  (actual rows=1150)   Filter: _item_visible(id, owner_id, campaign_id, secret)   Rows Removed by Filter: 1
  -> Hash -> Function Scan on jsonb_array_elements x (estimated rows=1, actual rows=12)
```
The planner estimates 1 row for `jsonb_array_elements`, so it hashes the whole table instead of 12 primary-key lookups, and the RLS policy
`items_read` (`_item_visible(...)`) is evaluated for each of the 1,150 rows (STABLE, SECURITY DEFINER, not leakproof, so it cannot be pushed
below the join). `pg_stat_user_functions` delta for ONE call: `can_view_owned` 1,153 calls, `_item_visible` 1,153, `can_access_character` 107.
Time: `_item_visible` total 48 ms (includes `can_view_owned` 37 ms) of a 132 ms call under `track_functions` (which itself adds overhead);
the statement run standalone under `role authenticated` takes **45-49 ms** (EXPLAIN ANALYZE, original and "lateral" forms) of ~105 ms => **about 40-45 %**.
(The 438 ms seen in the `auto_explain` capture is instrumentation overhead and is not used.)
Same pattern at `_derived_stats_full` tool-expertise subselect (`feat_catalog.sql:1451`, `select i.name from items i where i.id = ...`, per row; PK lookup, cheap).
Note: `items` grows with DM homebrew and catalog seeding, so this cost is O(catalog) per evaluation.

### 3.2 P0 - ~10 full derived-stats evaluations per page open
Static analysis of the latest definition of every function (378 functions, `scratchpad/graph.py`; superseded `create or replace` and `rename to` applied in order).
MEASURED per RPC call (`pg_stat_user_functions` delta, 3-class test character, local; replaces the earlier static call-site estimate, which
over-counted background/transformation):

| RPC | `_derived_stats_core` runs | `_item_visible` calls | `_character_feat_grants` runs | warm local ms |
|---|---|---|---|---|
| get_character_derived_stats | 1 | 1,153 | 6 | 105 |
| get_character_proficiencies | 1 | 1,153 | 6 | 116 |
| get_character_spell_slots | 1 | 1,153 | 6 | 103 |
| get_character_resources | 1 | 1,153 | 6 | 144 |
| get_character_class_features | 1 | 1,153 | 6 | 262 |
| get_character_class_summary | 1 | 1,153 | 6 | 100 |
| get_character_spellbook | **2** | **2,306** | 12 | 319 |
| get_character_states | 1 | 0 | 6 | 75 |
| get_character_transformation | 1 | 0 | 6 | 114 |
| get_character_feats | 1 | 0 | 8 | 51 |
| get_character_background | 0 | 0 | 0 | 2.4 |
| get_character_lineage / infusions / governance | 0 | 0 | 0 | 1-2 |

Per page open: **11 core runs, 8 passes through the items scan (9,224 `_item_visible` calls)**. States/transformation/feats run the core but not
`_derived_stats_full` (no items scan). Static analysis alone (call-site counting) is only an upper bound; trust this table.

Sum of the 12 reads sequentially: **~1.39 s** of DB time for one open on a 3-class test character; concurrent in production this is the
"two backends at the same time" the brief observed. The two stack traces in the brief match: derived-stats path and spell-slots path.
Because `_character_mods` was already fixed once (20261019000700: previously evaluated 7x) this is the second generation of the same problem.

### 3.3 P0 - `get_character_spell_slots` needs only six numbers
`get_character_spell_slots` -> `_class_progress(p_character, _character_mods(...))`. `_class_progress` uses `p_mods` only for prepared-limit formulas and
`ability_modifier` (`20261015001700:356-497`). It does not use attacks, AC, skills or saves. The full derived call is unnecessary work.

### 3.4 P1 - effects pipeline is rebuilt, re-sorted and re-expanded (not a cycle)
No call-graph cycles. `_character_effects` is invoked once per derived evaluation (good), but beneath it `_character_feature_effects`,
`_character_class_effects`, `_character_feat_effects`, `_character_feat_grants` are evaluated **multiple times per evaluation** (measured, one call:
`_character_feat_grants` 6, `_character_feat_effects` 5, `_character_class_effects` 2, `_character_feature_effects` 2, `_cf_class_rows` 8,
`_character_feature_unlocks` 4, `_cf_prereq` 300). `_derived_stats_full` calls `_character_feature_effects` again independently of `_character_effects`
(`feat_catalog.sql:1385`), so class/feat effects are computed twice, then `_feat_layer` calls `_character_feat_grants` a third time.
`_character_effects` result is aggregated to JSONB and then `jsonb_array_elements`-expanded at least 20 times inside `_derived_stats_core`
(`jsonb_array_elements(effects)` appears in the weapon loop, lineage/skills sections; `_effect_total` x7 call sites expand it again).
Weapon loop (`wild_shape_engine.sql:1268-1290`) is bounded to 2 iterations; per iteration 4 JSONB expansions + 4 `_effect_total` calls. It is wasteful
but not the dominant cost, and `(e ->> 'source_id')::uuid` is evaluated in an `or` with `scope = 'global'` without guaranteed order: a latent
cast-error risk if any applied attack_bonus has a non-UUID source_id (not observed; to be checked, not fixed here).

### 3.5 P1 - Realtime fan-out
`store.js:352-374`: **1 channel with 64 `postgres_changes` bindings** (characters + 21 child tables x INSERT/UPDATE/DELETE; DELETE unfiltered server-side).
Plus `request-ui.js:255` (2 bindings) and, for DMs, `dm-space.js:114` (2 bindings). Each binding makes the Realtime server run an RLS-authorized read per event
per subscriber. Channel names contain `Math.random()` (not stable) but are removed on unmount, switch (sheet remount calls `unmountSheet`) and `dm-space.js:58,106`.
Local evidence: `realtime.subscription` had 0 rows at measurement time (no sheet open, so no per-subscription numbers); `pg_stat_statements` (since 2026-10-23, includes test runs) shows Realtime's
`list_changes` poll at **13,672 calls, 115 s total, 8.4 ms mean** - comparable to the largest PostgREST RPC statements (120-240 s each) - plus the
`sub_tables` subscription query 19,942 calls / 10 s. The production equivalent is the first thing to read (query B in section 14).
Not verified (needs browser run): logout cleanup; whether `supabase.removeChannel` completes before a fast re-mount; singleton client (`js/supabase.js` exports one client - verified by import, not by runtime).
Write loops: no `useEffect`; rendering does not write; derived stats are never persisted (verified by grep: no `rpc`/`update` in render paths). The
`tavern:save-refused` event triggers `ctx.reload()` (full reload, bounded by governance codes).

### 3.6 P1 - a timed-out save is retried forever
`store.js:231` `PERMANENT = /^(22\w{3}|23\w{3}|42501|42703|PGRST(1|2)\d\d)$/` does not contain `57014`, so a statement timeout on a field save is re-queued with
`schedule(min(30000, 1000 * 2 ** failures))` and **has no attempt cap** (`store.js:297-305`). The loop ends only when the save succeeds or the tab closes.
Which writes can time out: only those that run a heavy trigger. The single trigger that reaches derived stats is `character_spells_class_rules`
(`pg_trigger`, via `_character_mods`: a full derived evaluation inside every `character_spells` write). Plain `characters` field saves have no such trigger. (Indirect trigger paths through other
functions were not enumerated.)

### 3.7 P2 - no optimistic-concurrency token on character writes
`store.js` saver merges patches by `table:id` and last-writer-wins (the `protectedFields` guard only protects against remote clobbering of in-flight local fields).
`characters` has an `updated_at` column but no version column. No `version`/`updated_at` check in updates (not verified server-side for every RPC; multi-table RPCs run inside one function = one transaction, that is OK).

## 4. Suspected / need more evidence
- Production catalog size and whether `items` is larger than local (1,151): required for the 3.1 projection. Query in section 14.
- Free-plan CPU credits / burst behavior: check Dashboard -> Reports (CPU, memory, swap) and `pg_stat_statements` on production.
- Whether PostgREST connection pool saturation (Free: small pool) turns 10 parallel RPCs into queueing before the 10 s timeout: need `pg_stat_activity` snapshot during an open.
- Realtime RLS authorization cost: check Realtime "replication slot lag" and `realtime.messages` volume.
- RAM growth "while a user keeps the app open": no timer exists, so growth must come from Realtime/connection state or from repeated Realtime-triggered re-reads; needs a 5-minute idle capture on production (4 queries below).

## 5. Duplicate-computation matrix (static; the measured numbers in 3.2 win over this)

| Value | derived | proficiencies | slots | resources | class_features | class_summary | spellbook | states | transformation | background |
|---|---|---|---|---|---|---|---|---|---|---|
| all character effects (`_character_effects`) | 1 | 1 | 1 | 1 | 1 | 1 | 2 | 1 | 2 | 2 |
| feat grants / feature effects | yes | yes | yes | yes | yes | yes | 2x | yes | 2x | 2x |
| modifiers / ability scores | yes | yes | yes | yes | yes | yes | 2x | yes | 2x | 2x |
| attacks, AC, saves, skills, inventory effects, movement, HP | yes (needed only by derived) | yes (not needed) | yes (not needed) | yes (not needed) | yes (not needed) | yes (not needed) | not needed | not needed | partly | not needed |
| spellcasting / slots | | | needed | | | | | | | |

"yes (not needed)" = computed, but the RPC only uses a small slice (ability modifiers or proficiencies).

## 6. SQL dependency graph (latest definitions)

```
get_character_derived_stats  [feat_catalog:1729, LANGUAGE sql]
 ├─ _derived_stats_full [feat_catalog:1369, 312 lines, plpgsql]
 │   ├─ _derived_stats_levels [class_levels_and_slots:619, 11 lines]
 │   │   ├─ _character_level_info
 │   │   └─ _derived_stats_core [wild_shape_engine:936, 516 lines]
 │   │       ├─ _character_effects [feat_catalog:1293] ─ _character_feature_effects, _item_active_in_form x2
 │   │       │    └─ _character_feature_effects [feat_catalog:491] ─ _character_class_effects (units: _character_feature_unlocks,
 │   │       │         _cf_class_rows, _cf_equipment, _character_feature_choice_rows, _cf_scale), _character_feat_effects x2
 │   │       │              └─ _character_feat_effects [429] ─ _character_feat_grants [197] ─ _character_feature_unlocks, _character_feat_choice_values, _character_level_info
 │   │       ├─ _lineage_effects, _active_form, _character_background_abilities, _background_layer
 │   │       ├─ _effect_total x7 call sites (each expands the effects JSON), _ability_mod x2, _proficiency_match x4
 │   ├─ _character_feature_effects (second, independent evaluation)   <-- repeated dependency
 │   └─ _skill_level
 ├─ _feat_layer [1056] ─ _character_feat_grants (third evaluation), _feat_hp_bonus
 └─ _wild_shape_layer [wild_shape_engine:404] ─ _wild_shape_sheet, _item_active_in_form

get_character_spell_slots [class_levels_and_slots:685] ─ _character_level_info, _class_progress, _character_mods
_character_mods [derived_stats_performance:9] ─ get_character_derived_stats   <-- the unnecessary full calculation
```
Cycles: none found (DFS depth 12 from the 4 roots). 70+ other functions (rests, slot changes, change requests, wild shape, DM party) also reach
`get_character_derived_stats`; the same fix applies to them (mostly via `_character_mods`).
Loops with SQL/JSONB expansion: the 8 `for ... in select ... from jsonb_array_elements(eff)` loops of `_derived_stats_full`
(`feat_catalog:1387-1470`), each doing a `skills := skills || jsonb_build_object(...)` rebuild (JSONB copy per iteration), and the 2-iteration weapon loop in the core.

## 7. Index audit (evidence-based only)

- `items`: the catalog scan is not an index problem (PK exists; planner chooses a hash join because of a bad row estimate). **No index proposed.**
  The fix is a query rewrite (section 9).
- `class_feature_versions` seq scan 1,080 rows x4 nodes, `subclass_versions` 952 rows x8, `class_feature_choices` 186 rows: small tables, ~ms.
  **No index justified by the current plans**; recheck on production data volume before proposing anything.
- No other index proposal: the brief requires query-plan evidence and none showed a missing-index scan on a large table.

## 8. Baseline measurements (local, warm, 3-class character, 1 equipped item)

| Item | Result |
|---|---|
| `get_character_derived_stats` | 245 ms cold, 112 / 115 / 112 ms warm (target <500 ms: **already met locally; production is the issue**) |
| `get_character_spell_slots` | 137 / 117 / 113 ms |
| 12 page-load reads, sequential | 1.39 s total (table in 3.2) |
| Function calls inside ONE derived call | `can_view_owned` 1,153; `_item_visible` 1,153; `can_access_character` 107; `_character_feat_grants` 6; `_cf_prereq` 300 |
| Seq scans in one call | items 1,150 rows; class_feature_versions 1,080; subclass_versions 952 |

Contention test (local container, 16 CPUs, one `psql` per derived call, wall ms per client): 1 client 131; 5 clients 153-184; 10 clients 193-356;
20 clients 224-731. Mild; it does **not** reproduce multi-second timeouts. A shared 2-vCPU Free compute would stretch this by about the CPU ratio (<= 8x): 10 parallel
calls ~1.5-3 s, still below 10 s. Another factor is missing (see exec summary 5).

Not measured (needs production or a browser): idle five minutes, 5x character switching, saves, race/class/background change, equip/unequip, `pg_stat_statements`
totals (local counters are polluted by test runs), CPU/RAM/swap, p95/p99, connection counts. Section 14 lists the exact queries.

## 9. Minimal safe remediation plan (proposal, not applied)

Ordered by impact/risk. Each item keeps calculation output byte-identical (JSON key order normalized) and must pass golden tests first.

1. **R1 (SQL, P0, low risk):** rewrite the `profs` statement (`feat_catalog:1481`) so the ~12 items are PK lookups. **Verified on the local DB under `role authenticated`:**

   | form | plan | time |
   |---|---|---|
   | original (join on `jsonb_array_elements`) | Hash Left Join + Seq Scan `items`, 1,150 `_item_visible` | 48.5 ms |
   | `LEFT JOIN LATERAL (select ... from items where id = x->>'value_text')` | planner flattens it, **identical seq scan** | 45.3 ms |
   | MATERIALIZED CTE of ids, then join | **identical seq scan** | 49.9 ms |
   | `i.id = any($1::text[])` (array in a variable) | Bitmap Index Scan `items_pkey`, 12 rows | **1.0 ms** |
   | correlated scalar subselects `(select i.name from items i where i.id = x->>'value_text')` | Index Scan per row (loops=12) | **1.7 ms** |

   The lateral form proposed in the first draft of this report does **not** work (the join clause is not leakproof, so under RLS it cannot become an index qual for a join; a
   scalar subselect or a Param can). RLS still applies to the 12 rows, so visibility semantics are unchanged. Use the scalar-subselect form (the same shape as the existing
   tool-expertise line). Expected saving ~45 ms of ~105 ms (~40 %). Verification: re-run the delta (target `_item_visible` calls <= 20); golden diff.
2. **R2 (SQL, P0, medium risk):** `_character_ability_mods(p_character)` that returns the six modifiers, extracted from the core without the attack/AC/skills code, and
   point `_character_mods` at it. Checked: `_wild_shape_layer` and `_feat_layer` never rewrite `abilities` (the key is produced by the core; `_derived_stats_full` only reads it),
   so the six modifiers come from the core alone and the extraction is sound. The golden set must still include an actively transformed character (the layers do change AC/saves/skills). Output of `_character_mods` must equal the current one for all golden characters (test: compare for all 35 local characters
   and all 7 production characters). This removes the full derived evaluation from slots, resources, states, spellbook, transformation and ~60 write RPCs.
3. **R3 (SQL, P1):** evaluate `_character_feature_effects` once inside `_derived_stats_full` and pass/reuse it in `_feat_layer`; temp table or CTE within one statement (not
   JSONB round trip). Higher risk: do after R1+R2 measurement.
4. **R4 (frontend, P0 amplifier, low risk):** one `AbortController` per mounted sheet, aborted in `unmountSheet`/character switch, passed through the loaders to
   `supabase.rpc(...).abortSignal(signal)`; a central `classifyError` (never retry 57014/auth/validation; max 2 jittered retries for fetch errors / 502-504).
5. **R5 (frontend, P1):** do not call `get_character_derived_stats` from `loadClasses`' dependents: after R2 the derived call is the only heavy one. Merge
   `getTransformation` duplicate (mount + Realtime), keep `slotEpoch` logic.
6. **R6 (Realtime, P1):** stable channel name `character-${id}`; drop tables the sheet does not render live; feature flag `realtime_child_tables` to compare.
   Do not remove the resync (V6.2 safety).
7. **Later (P2/P3):** `get_character_sheet` aggregate, stored derived snapshot keyed by `(character_id, character_version, ruleset_version)` only after
   invalidation rules exist. Not recommended before R1/R2 because they remove the need.

Do **not** raise `statement_timeout`; none of the above weakens RLS, auth or validation.

## 10. Proposed SQL diff for R1 (for review; not applied)
```diff
   select coalesce(jsonb_agg(jsonb_build_object('id', null, 'proficiency_type',
-           case x ->> 'target' when 'group' then g.proficiency_type when 'armor' then
-                case when it.category_id = 'shield' then 'shield' else 'armor' end else x ->> 'target' end,
+           case x ->> 'target' when 'group' then g.proficiency_type when 'armor' then
+                case when (select i.category_id from public.items i where i.id = x ->> 'value_text') = 'shield' then 'shield' else 'armor' end else x ->> 'target' end,
 ...
-           'name', coalesce(g.name, it.name, x ->> 'value_text'), ...
+           'name', coalesce(g.name, (select i.name from public.items i where x ->> 'target' in ('weapon','armor','tool') and i.id = x ->> 'value_text'), x ->> 'value_text'), ...
-           order by x ->> 'target', coalesce(g.name, it.name)), '[]')
+           order by x ->> 'target', coalesce(g.name, (select i.name from public.items i where x ->> 'target' in ('weapon','armor','tool') and i.id = x ->> 'value_text'))), '[]')
   into profs
   from jsonb_array_elements(eff) x
   left join public.proficiency_groups g on x ->> 'target' = 'group' and g.id = x ->> 'value_text'
-  left join public.items it on x ->> 'target' in ('weapon', 'armor', 'tool') and it.id = x ->> 'value_text'
   where (x ->> 'active')::boolean ...
```
Delivered as a new migration (`create or replace function public._derived_stats_full`, whole body); rollback = the body from `20261019000300`.
Open item: confirm the plan inside the real function with `EXPLAIN` after drafting (the standalone test used a synthetic `eff` with real item ids).

## 11. Test and rollback plan (summary)
- Golden: capture `get_character_derived_stats`, `_character_mods`, `get_character_spell_slots` for all 35 local characters (+ production's 7 via export) before any change; compare with key-order normalization.
- Existing suites in `supabase/tests` (API/UI/soak/iso) must stay green; add: `_item_visible` call-count assertion, `_character_mods` equivalence test.
- Concurrency: existing browser suite covers rapid switching; add an abort test (requests cancelled on navigation).
- Rollback: each migration ships a rollback file in `supabase/rollback/` (existing convention); production rollout in the staged order (local -> rehearsal clone -> production window) as in the 2026-10-23 runbook. No production deploy without approval.

## 12. Acceptance criteria
Derived stats < 500 ms (target) / < 1 s (acceptable) on production data; no 57014 on open; page open = <= 1 full derived evaluation per RPC set (after R2: derived + proficiencies + class_features/class_summary only);
zero application requests while idle; channel count constant after repeated navigation.

## 13. Feature-flag plan
SQL changes are drop-in (same signatures): no flag needed, rollback by migration. Frontend abort/retry classifier ships behind `localStorage`/config flag `perf_abort_v1`. Realtime reduction behind `realtime_child_tables`.

## 14. Information still required (exact queries / sources)
Production (read-only, SQL editor):
```sql
-- A. catalog size (3.1 projection)
select (select count(*) from public.items) items, (select count(*) from public.characters) chars;
-- B. what is actually slow in production
select queryid, calls, round(total_exec_time) total_ms, round(mean_exec_time) mean_ms, round(max_exec_time) max_ms, rows, left(query,120)
from pg_stat_statements where query ilike '%get_character_%' or query ilike '%_character_effects%' order by total_exec_time desc limit 20;
-- C. connections during an open
select state, wait_event_type, count(*) from pg_stat_activity where datname = current_database() group by 1,2;
-- D. function plans: run EXPLAIN (ANALYZE, BUFFERS) select public.get_character_derived_stats('<uuid>') inside a role/claims transaction as the owner
```
Plus the Dashboard Reports (CPU, RAM, swap, connections) for the 5-minute idle window and a browser Network capture of one open (count and timing of requests).
Do not reset `pg_stat_statements` without approval.

## 15. Findings by priority
- **P0:** 3.1 (items scan + RLS per row), 3.2 (10 full evaluations per open), 3.3 (slots need only 6 numbers), no request cancellation on navigation (F-1).
- **P1:** 3.4 repeated feature/feat effects evaluation, 3.5 Realtime 64 bindings, missing central retry classifier in sheet loaders.
- **P2:** 3.6 no version token on single-table writes, random channel names, JSONB-concatenation loops in `_derived_stats_full`.
- **P3:** aggregate `get_character_sheet`, derived snapshot table.

Waiting for review before any patch is applied.

## 16. Remaining proposals (sketches for review; not applied)

**16.1 Per-binding Realtime table (`store.js:343-377`; one channel per open sheet, ~64 bindings, filter `character_id=eq.<id>`; DELETE unfiltered):**
`characters` (UPDATE only, `id=eq`), then INSERT + UPDATE + DELETE each for: `inventory_items`, `character_equipment`, `character_proficiencies`, `character_lineages`,
`character_lineage_choices`, `character_backgrounds`, `character_transformations`, `character_spellcasting_sources`, `character_spells`, `character_classes`,
`character_spell_slot_state`, `character_temporary_spell_slots`, `character_resources`, `character_feature_choices`, `character_optional_features`, `notes`, `spell_slots`,
`feature_trackers`, `features`, `attacks`, `spells` (21 tables). Handler `sheet.js:2900-2940` patches rows in place; inventory/equipment -> `inventory.scheduleRefresh()` -> `onRows` -> `scheduleDerived`.
Other channels: `request-ui.js:255` (2 bindings), `dm-space.js:114` (2 bindings, DM only). Proposal: stable name `character-<id>`; drop legacy tables (`spell_slots`, `attacks`,
`spells`, `features`, `feature_trackers`) if no longer rendered live (needs product confirmation); a feature flag to compare.

**16.2 Frontend stabilization diff (sketch).** About eleven `*-api.js` modules each define their own `rpc(fn, args)` (background, class, creature, dm, feat, governance, infusion-ui,
inventory, lineage, spell, plus direct calls in `transfer.js`). Add `js/rpc.js` and import it from all of them:
```js
// js/rpc.js - one wrapper: abort per sheet, one classifier
let sheetCtl = new AbortController();
export const abortSheetRequests = () => { sheetCtl.abort(); sheetCtl = new AbortController(); };   // call from unmountSheet()
export const rpc = (fn, args) => supabase.rpc(fn, args).abortSignal(sheetCtl.signal);
export const isRetryable = (e) => /failed to fetch|network|load failed/i.test(e?.message || '') || [502, 503, 504].includes(e?.status);   // never 57014 / auth / validation
```
`unmountSheet()` calls `abortSheetRequests()`; loaders treat `AbortError` as ignored (the `*Seq` guards already drop stale responses). Add `57014` to `PERMANENT` at `store.js:231` with a toast
("The server was too slow; your change was not saved - try again") and cap save attempts (e.g. 5). Files: `js/rpc.js` (new), the `*-api.js` modules, `sheet.js` (`unmountSheet`), `store.js:231`.
Caveat: aborting on the client does not stop a statement already running in PostgreSQL unless PostgREST detects the closed connection; it stops queued work, not running work.

**16.3 R2 design (no diff: the core is a 516-line function).** New `public._character_ability_mods(uuid) returns jsonb` producing the six modifiers from the same inputs the core uses
for `abilities` (base scores, lineage/background increases, item and feat `ability_score` effects, `_ability_mod`). Order: (1) copy the ability block out of the core, (2) make the core call
it (single source of truth), (3) point `_character_mods` at it, (4) golden test that `_character_mods` equals the old value for every character. Removes one full evaluation from
slots/resources/states/spellbook (1 of 2)/transformation and ~60 write RPCs.

**16.4 `get_character_sheet(p_character)` sketch.** Not recommended before R1/R2/R4: today it would still call the existing functions (multiple core runs). It pays off only when the core runs
once and shares a typed temp relation (effects, levels, inventory) with class summary, resources, slots and spellbook through internal `_*_from(tmp)` variants; authorize once; return
`{version, derived, proficiencies, class_summary, slots, resources, features, spellbook}`. Version = newest `updated_at` of dependent rows, or a trigger-maintained `characters.sheet_version`.

**16.5 Version token for writes.** `characters.updated_at` exists. Minimal: RPC `save_character_fields(p_id, p_patch, p_expected_updated_at)` returning `{ok:false, conflict:true, current}`
when `updated_at <> expected`. Multi-table operations are already single-function transactions. Child-table field saves would need their own column; decide after measuring whether lost updates occur.
