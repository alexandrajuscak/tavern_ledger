# Current production fluency baseline (after the 2026-10-29 incident fix)

Release on Pages: `10e5cc0` (fix `a568ab5`), module specifier `?v=12`. Measured 2026-10-30.

## Method and its limits (read first)

A signed-in production browser session **was not used**: signing in writes `auth.sessions`, refresh tokens and
`last_sign_in_at`, and the brief forbids production writes for measurement. The baseline therefore combines three sources;
each number is labelled:

| Label | Source |
|---|---|
| **[prod-anon]** | anonymous production measurements: GitHub Pages load (Playwright/Edge, cold and warm), REST round trips with the public key (`curl`), from the agent's machine |
| **[prod-sql]** | read-only SQL timing on production: each sheet RPC once, owner-impersonated, sequential (`docs/LIVE_DATABASE_ARCHITECTURE_EVIDENCE.md` §4) |
| **[local-probe]** | the deployed frontend code against the local Supabase stack with Chromium network emulation at 50/150/300 ms (`supabase/tests/browser/incident_probe.py`, post-fix runs of 2026-10-29: `%USERPROFILE%\tavern-ledger-production-exports\2026-10-29-incident\probe_after_*.json`); local PostgreSQL is 2.5-4× faster per evaluation than production |
| **[bench]** | the same request model replayed on POC B with CPU limits (`docs/FLUENCY_POC_RESULTS.md` §3), 0.5 CPU ≈ production single-query speed |

## 1. Static frontend and network [prod-anon]

| Metric | Cold | Warm |
|---|---|---|
| Static requests (all GitHub Pages) | 51 | 51 (cached) |
| Transferred | ~480 KB | ~0 |
| First contentful paint | 1.06 s | 0.10 s |
| Sign-in form ready (network idle) | 1.63 s | 0.61 s |
| Pages `index.html` TTFB | 0.24 s, `Cache-Control: max-age=600`, CDN `HIT` | |
| Supabase REST, trivial query, new TLS connection | 140-630 ms | |
| Supabase REST, trivial query, reused connection | **75-110 ms** | |
| Database round trip via session pooler | 42 ms | |

## 2. Home [local-probe + code]

`js/store.js:100-121`: `characters` list, then 4 parallel side reads (classes, transformations, governance, open
requests) → **2 waves, 5 requests**, plus campaigns/members/profiles at sign-in (3). Cards are correct after ~2 RTT
(~200-250 ms hosted). Home is not the problem.

## 3. Character open

| Metric | Value | Label |
|---|---|---|
| Requests per open | **35** (8 table reads → 13 calls → 9 calls → 1 → 1: five dependent waves) | local-probe |
| Heavy derived RPCs per open | **9** (each runs the full rules core) | local-probe |
| Rules-core evaluations per open | ~10-11 | local SQL (`pg_stat_xact_user_functions`) |
| Serial DB time of the 14 sheet RPCs, production | char #7 **2.81 s**, char #4 **4.04 s**, legacy char #2 1.17 s | prod-sql |
| Largest responses | transformation 75 KB, class_features 33 KB, spellbook 27 KB, derived 17 KB | prod-sql |
| Time to identity | after wave 1 (~1 RTT + render) | code |
| Time to vitals/AC ("usable") | 0.15 s @50 ms, 0.34 s @150, 0.66 s @300 | local-probe (fast local DB) |
| Same, with production-like CPU (heavier test characters) | **2.9 s median / 7.2 s p95** @150 ms; full load 4.6 s; 5 simultaneous opens 14 s median with 19 statement timeouts | bench (0.5 CPU) |
| Full eventual load | 5 waves + all heavy RPCs | |

## 4. Character switch [local-probe]

| Scenario | @50 ms | @150 ms | @300 ms |
|---|---|---|---|
| A → B → C 150 ms apart: C usable after last click | 0.52 s | 0.86 s | 1.48 s |
| Same at reading pace (700 ms apart) | 2.14 s | 2.17 s | 2.31 s |
| Heavy RPCs of A and B that still ran to completion (paced) | 18 of 18 | 10 of 17 | 0 of 16 (cancelled) |
| Realtime joins / leaves per A→B→C | 6/6 | 2/2 | 2/2 |
| Stale results rendered | 0 (sequence guards) | 0 | 0 |

Cancellation works when the switch is fast; at a reading pace A's and B's reads are mostly already running, so the
server still pays for them.

## 5. Tabs and lazy sections

Only **Spells** is lazy (spellbook loads with the section since the fix). Play, Abilities, Inventory, Build and Bio
data are all fetched on open regardless of the active tab; changing tab costs 0 requests but the open paid for all of them.

## 6. Pickers [local-probe + prod-sql]

Payloads measured on the local catalog with the frontend's exact column lists (local catalog ≈ production: 1,151 vs
1,146 items, 575 vs 574 spell versions):

| Picker | Behaviour | Load shape | Payload |
|---|---|---|---|
| Background | shell 0.05 s, results 0.16/0.26/0.38 s @50/150/300; Retry + final state since the fix | everything at once | `get_background_catalog` **470 KB** (359 KB of it: all 408 feats); prod 89-104 ms idle |
| Spell | catalog-or-explain with Retry | list + `get_spell_detail` on selection (split already) | list `v_spell_catalog` **429 KB** (575 rows, 31 columns incl. class lists) |
| Feat | full catalog per character | `get_feat_catalog` + `get_feat_detail` | **300 KB** |
| Class | catalog-or-explain with Retry | 3 table reads | 50 KB (15 class + 119 subclass versions) |
| Lineage | list + `get_lineage_detail` (split already) | | 21 KB (47 rows) |
| Wild Shape | creature list + options inside `get_character_transformation` | options are fetched on **every open** of a druid-capable character, even with the panel closed | creature list 72 KB (335); transformation up to **86 KB** locally, 75 KB in production |

List/detail candidates after Background: Spell (trim list columns), Feat, and Wild Shape options out of the open path.

## 7. Realtime [local-probe + prod]

| Metric | Value |
|---|---|
| Channels per sheet | 1 sheet channel (64 `postgres_changes` bindings, 21 unfiltered DELETE) + request bar (2) |
| Subscription rows per open sheet | **66** (production now: 66 with one sheet open) |
| Switch | leave + join (64 rows deleted, 64 created) |
| Reconnect (3 socket drops) | 102 requests, 27 heavy RPCs, 9 joins → **one full reload per drop** |
| Own HP edit | 1 request, 0 heavy re-reads in editor and viewer (fixed) |
| Foreign-character DELETE | 0 re-reads (fixed) |

## 8. Loading-state behaviour (perceived)

Identity appears after wave 1, but AC/derived values, Play cards, inventory and governance chips arrive from different
waves at different times: the "progressively assembled" feeling the user described. The fix improved the worst case
(no stuck pickers, no silent failures) but not the shape of the load.

## 9. Verdict on the incident

**Not fully resolved.** The worst amplifiers are gone (no cross-character reloads, no HP-triggered re-reads, cancelled
fast switches, bounded saves, picker states). The **base cost per open is unchanged**: 35 requests, ~10 rules evaluations,
2.8-4 s of production CPU for a level-2 character. A session-start burst still multiplies that cost; on a production-like CPU
the replay times out (`FLUENCY_POC_RESULTS.md` §3). Keep the monitoring dates (2026-11-05) and treat Phase 1 as the actual
resolution.
