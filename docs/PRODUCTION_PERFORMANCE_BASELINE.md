# Production performance baseline (incident 2026-10-23, measured 2026-10-29)

## Production, read-only (2026-10-29 18:36 UTC; pg_stat_statements since 2026-10-14)

| Measure | Value |
|---|---|
| statement_timeout | authenticated 8 s, anon 3 s |
| max_connections / connections idle | 60 / 15 |
| derived-stats family (9 RPCs), role authenticated | mean 1.1-2.9 s, max 7.5-7.97 s (just under the 8 s limit; cancelled calls are not recorded) |
| sum of the 12 sheet RPCs per character, idle, one at a time | 0.52-4.23 s (median 0.70 s) |
| `_derived_stats_full` items statement | 144 ms (seq scan 1,146 rows + RLS per row) -> 3.6 ms with the fix |
| `get_background_catalog` | 89-104 ms idle, 469,726 bytes |
| Realtime `list_changes` | 167,052 calls, 1,074 s total |
| Realtime subscription create / slot create | max 3.1 s / 9.2 s |

Snapshot (aggregates only): `%USERPROFILE%\tavern-ledger-production-exports\2026-10-29-incident\evidence_1_before_diagnostics.json`.
Later counters include the diagnostic timing calls of 2026-10-29 18:36-19:10 UTC (7 characters x 12 RPCs, 3 catalog calls, 2 EXPLAINs).

## Local SQL (35 characters, as owner)

| | before R1 | after R1 |
|---|---|---|
| `get_character_derived_stats` + `get_character_spell_slots`, average per character | 349 / 341 ms | 205 / 208 ms (−41 %) |
| `_item_visible` calls per derived evaluation | 1,151 | 10 |

## Browser (local stack, Chromium latency emulation, synthetic characters)

Release `9b810aa` vs the fix; files `probe_before_*ms.json`, `probe_after_*ms.json` in the incident export folder.

| Latency | Open: requests / heavy | Fast A->B->C: C usable | Paced A->B->C: heavy reads of A / B completed | Background dialog shown | HP edit heavy (editor + viewer) | Foreign delete heavy (steady) | Reconnect x3 heavy / joins |
|---|---|---|---|---|---|---|---|
| 50 ms before / after | 36/10 → 35/9 | 0.64 → 0.52 s | 10/10 → 9/9 | 0.13 → 0.05 s | 3+3 → 0+0 | 3 → 0 | 30/12 → 27/9 |
| 150 ms | 36/10 → 35/9 | 1.00 → 0.86 s | 10/10 → 8/2 | 0.28 → 0.05 s | 3+3 → 0+0 | 3 → 0 | 30/12 → 27/9 |
| 300 ms | 36/10 → 35/9 | 1.91 → 1.48 s | 10/0 → 0/0 | 0.86 → 0.06 s | 3+3 → 0+0 | 3 → 0 | 30/12 → 27/9 |

Local timings understate production (local SQL is 10-25x faster). The comparable results are the counts: fewer heavy RPCs
per open and per interaction, obsolete reads cancelled, no cross-character reloads, and the picker dialog independent of the
sheet's reads.

## Regression thresholds (production_timeout_incident_test.py)

- one open <= 35 requests and <= 9 heavy RPCs;
- no A/B heavy read completes after C is usable; A/B reads are cancelled;
- HP edit: 0 heavy RPCs in the editing and a viewing session; foreign delete (steady state): 0;
- two quick reconnects: 1 bundle reload; subscriptions return to 66 per sheet;
- an idle sheet sends 0 requests in 5 s;
- Background dialog < 1.5 s, results while Inventory and spellbook are held back, a final state within 15 s.

## Production after the fix (2026-10-29 23:00 UTC, idle, one sample)

| Character | derived before → after | spellbook before → after | 12 sheet RPCs before → after |
|---|---|---|---|
| 4 (heaviest) | 433 → 305 ms | 928 → 730 ms | 4,230 → 3,436 ms |
| 7 | 222 → 124 ms | 656 → 450 ms | 2,543 → 1,789 ms |
| 1 | 276 → 140 ms | 219 → 202 ms | 1,638 → 1,411 ms |
| 2, 3, 5, 6 | 48-71 → 49-77 ms | 68-159 → 69-163 ms | 520-697 → 524-1,014 ms (noise right after the function replacement) |

In the browser the spellbook is no longer read on open, obsolete reads are cancelled, and HP or foreign-delete events no
longer cause derived reads, so the parallel load per open and per interaction drops more than these per-RPC numbers show.

## After deployment (to measure on production)

Repeat `scripts/incident/readonly_evidence.sql` one week after the deployment and compare by snapshot difference: expect the
derived-stats family's mean well below 1 s, no statement above 5 s for role authenticated, and no 57014 /
IncreaseSubscriptionConnectionPool in the logs.
