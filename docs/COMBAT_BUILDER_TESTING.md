# Combat Builder: testing

All tests are **local**. They use synthetic users and campaigns (`ui-*`, `cb-*`, `cbc-*`, `qp-*` @example.test). The SQL
suites roll back; the browser and API suites run inside the V6.2 isolation harness (`isolation.Isolated`), whose residue
and cleanup now include combat encounters and favorites.

## Combat Builder suites

| Suite | Checks | Result (2026-11-07) | Covers |
|---|---|---|---|
| `supabase/tests/combat_builder_tests.sql` | 179 | **179 / 0** | Permissions (P1–P9, E7–E8), creation (E1–E6), participants (A1–A18), Initiative (I1–I13), turns (T1–T15), HP (H1–H28, incl. Wild Shape, Undo, bulk), effects / advantage / concentration (C1–C25), legendary and reminders (L1–L11, a 2014 encounter), player-safe view (V1–V10), finish and summary (F1–F11), monster library (M1–M9), homebrew lifecycle and snapshot integrity (B1–B16), read-cache isolation (X1–X6) |
| `supabase/tests/api/combat_api_test.py` | 35 | **35 / 0** | The authorization matrix through PostgREST with JWTs (DM, player, unrelated, anonymous), RLS on all 7 runtime tables, no direct writes, player-safe view incl. disguise, change-log columns |
| `supabase/tests/browser/combat_builder_ui_test.py` | 89 | **89 / 0** (final standalone run; 85 / 0 in the full run, before the player / monster turn, error and loading checks were added) | Navigation, Home, builder, library and filters, ruleset mismatch badge, Initiative, tie review, turns (double click, keyboard), HP (preview, duplicate click, quick popover, Undo), sheet ⇄ tracker Realtime, conditions, advantage, concentration, two DM windows, legendary, reveal, pause / resume, responsive (1920 / 1366 / 1024 / 820 / 390 / 360), drawer, touch target, accessible names, offline banner, homebrew editor and publish, late joiner, history, help, finish with review, summary, duplicate, no console errors, no remote requests |
| `supabase/tests/combat_concurrency_test.sh` | 11 | **11 / 0** | 8 sessions × 40 operations on one encounter; 0 deadlocks; exact HP arithmetic on character, Wild Shape form and monster; one request id × 20 → applied once |
| `supabase/tests/browser/combat_perf_probe.py` | 9 | **9 / 0** | Timings per profile (below), request count, channels, 1 DM + 6 player sheets |
| `supabase/tests/combat_query_plans.sql` | timings + plans | ✓ | Server timings and plans of the hot paths ([COMBAT_DATA_MODEL.md](COMBAT_DATA_MODEL.md)) |
| Rollback / reapply | digest | **exact** | Schema digest (functions, tables, policies, triggers, publication, grants, `_dm_try`) before = after rollback; reapply identical; suite green after reapply |

### Required test list → where

| Area (task § 46) | Tests |
|---|---|
| Encounter creation 1–11 | SQL E1–E6, A1–A18, F8–F11; UI B1–B4, M5, F4, H7 |
| Initiative 12–22 | SQL I1–I13, L2, T12; UI I1–I8 |
| Turn flow 23–32 | SQL T1–T15, C14–C17; UI T1–T6, F1 |
| HP 33–45 | SQL H1–H28, C7–C8; UI H1–H6, S1–S4, U1; concurrency (two-session, rapid damage, duplicate) |
| Conditions 46–54 | SQL C1–C17, V4; UI C1–C4 |
| Advantage 55–60 | SQL C18–C21, C24 (Undo / removal); UI C2 |
| Concentration 61–67 | SQL C4–C11, L10; UI C3–C4 |
| Monsters 68–77 | SQL M1–M9, A6–A13, B11; UI M1–M13 |
| Homebrew 78–85 | SQL B1–B15; UI HB1–HB4 |
| Permissions 86–90 | SQL P1–P9, E7–E8, V1–V10, B16; API AP1–AP26; UI N1–N4 |

## Performance (`combat_perf_probe.py`)

Fixture: 6 player characters, 12 goblins in 3 groups, a legendary dragon in its lair, a hidden ogre joining in round 3,
and 3 timed conditions. Edge headless; CDP CPU throttling and added latency.

| | local | 4× CPU + 50 ms | 4× CPU + 150 ms | 4× CPU + 300 ms |
|---|---|---|---|---|
| Combat Home | 43 ms | 139 | 255 | 392 |
| Encounter shell | 104 | 411 | 487 | 630 |
| Initiative list usable | 111 | 428 | 496 | 640 |
| Next Turn (click → current changed) | 94 | 279 | 353 | 483 |
| HP feedback (Enter → row updated) | 38 | 56 | 74 | 167 |
| Condition applied | 78 | 69 | 74 | 93 |
| Stat block on demand | 329 | 738 | 887 | 1163 |
| Library open / search | 42 / 246 | 201 / 384 | 269 / 465 | 377 / 619 |

- **Requests on open:** 1 `combat_get_encounter` + 1 cached `get_character_reads` per linked character (6), sent after
  first paint, three at a time.
- **Realtime:** 1 channel.
- **1 DM + 6 open player sheets:** every sheet showed the DM's HP change in 222–669 ms.
- **Second run** (after the popover fix; `perf_run2.log` in the backup folder): 9 / 0, the same profile (local list 116 ms, Next
  69 ms; 300 ms + 4× CPU list 644 ms, Next 465 ms; six sheets 225–455 ms).
- **Statement timeouts:** none. **Console errors:** none.

**Targets met:**
- list usable well under 1 s at 150 ms latency;
- Next Turn under 500 ms even at 300 ms latency + 4× CPU;
- HP feedback straight from the mutation's answer.

## Affected existing suites (regression)

| Suite | Result |
|---|---|
| Full browser runner `run_browser_local.sh` (37 suites, including the two Combat Builder suites) | **1177 passed, 0 failed** (exit 0). Includes Wild Shape, DM Space / governance / custom content, fluent read, production incident, V6 hardening, V6.2 adversarial API / UI / soak, gameplay polish, inventory, spells, classes, lineages, backgrounds, derived stats |
| `progressive_read_tests.sql` (read cache, counter-trigger coverage incl. the new tables) | **1283 / 0** |
| `fluent_read_tests.sql` | **1707 / 0** |
| `gameplay_polish_tests.sql` | **70 / 0** |
| `wild_shape_concurrency_test.sh` | passed (3 checks) |
| `cache_concurrency_test.sh` (the 2026-10-31 deadlock regression) | **2 / 0** |
| Plain PostgreSQL 15 `run_local.sh` (every migration from zero incl. the two Combat Builder migrations, seeds twice, all per-class SQL suites, concurrency, rollbacks newest first, full rollback to the 11-table base, re-apply) | **1923 passed, 0 failed, exit 0** (third run; the first two exposed the two runner gaps noted below, both fixed) |

The sheet's Damage / Heal now use `apply_character_hp`. The existing checks of their messages ("Took 10 damage",
`original_ui_test.py` V6 Damage; "Took 2 damage", `v6_product_hardening_ui_test.py` L3) pass unchanged.

## Notes

- **Revision-log pruning.** The first synthetic run after more than 3 days pruned old rows of `character_revisions`
  (designed housekeeping of the change log, 2 % chance per write). The isolation harness reports it as a changed table
  once; it is not user data.
- **Runners.** `run_local.sh` and `run_supabase_local.sh` now roll back the Combat Builder first (newest first), because
  `creature_legendary_actions` references `creatures`; `rollback_inventory.sql` (full return to base) drops it too.
  `run_supabase_local.sh` was edited but not run (it wipes the local volume).
