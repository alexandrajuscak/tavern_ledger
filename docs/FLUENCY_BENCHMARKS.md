# Fluency benchmarks: legacy vs fluent read path (2026-10-30)

Release `20261030000100` / frontend `?v=13`. Outcome: **the fluent path stays behind the flag (`FLUENT_READS = 'off'`,
per-browser `?fluent=1`)**. It does less work in total, but its first usable paint is later, and under a concurrent
session-start burst on production it exceeds the 8 s statement timeout (§3). The next change is a progressive first paint (§5).

## 1. Production, single character (read-only, as each owner, nobody else online)

Server time of one `get_character_view` (shell, Play tab) against the 13 legacy RPCs it replaces; steady state (2 repeat
runs; the first run right after the migration had one cold outlier of 4.2 s for character 4).

| Character | Legacy `derived_stats` (first paint) | Legacy 13 reads, sum | Legacy largest single read | View | View size |
|---|---|---|---|---|---|
| 1 | 99-118 ms | 1,045-1,054 ms | 178 ms | 276-279 ms | 54 KB |
| 2 | 41-47 | 391-401 | 51 | 152-154 | 51 KB |
| 3 | 54-65 | 513-518 | 63 | 175-207 | 39 KB |
| 4 | 290-344 | 2,593-2,662 | 364 | 693-704 | 121 KB |
| 5 | 47-49 | 435-452 | 58 | 157-163 | 45 KB |
| 6 | 55-59 | 536-560 | 68 | 181-192 | 46 KB |
| 7 | 113-116 | 1,323-1,347 | 200 | 453-463 | 189 KB |

The view costs 26-35 % of the database time of the legacy reads (one rules evaluation instead of ~11), but 2-4× the
largest single legacy read, and all of it arrives at once. All views ≤ 300 KB.

## 2. Production smoke (real site, synthetic accounts, fresh browser contexts)

| Measure | Legacy (`?fluent=0`) | Fluent (`?fluent=1`) |
|---|---|---|
| Open: time to usable (name + AC) | **278 ms** | 572 ms |
| Open: requests | 46 | **10** (1 character request) |
| Rapid switch A→B→C: C usable | **612 ms** | 905 ms |
| Session total requests (smoke script) | 198 | **70** |
| Realtime bindings per sheet join | 2 / 64 | **2** |
| Tabs revisited | 0 requests | 0 requests |
| First Spells / Inventory open | 5 / 0 (legacy loads inventory with the open) | 5 / 11 (1 character read + session reference tables) |
| Background picker | 1 catalog request | list 379 ms + detail 251 ms |
| 5xx / console errors | 0 / 0 | 0 / 0 |

## 3. Production concurrency (read-only, 7 parallel sessions, one per real character)

| Round | Call | Per-session time | Wall |
|---|---|---|---|
| 1 | `get_character_derived_stats` | 0.28-1.12 s | 4.4 s |
| 2 | `get_character_view` | **15.2-22.9 s** | 26.8 s |
| 3 | `get_character_derived_stats` | 10.6-15.7 s | 18.7 s |
| 4 | `get_character_view` | **14.4-17.6 s** | 21.1 s |

Statement timeout of `authenticated` on production: **8 s** (`anon` 3 s). Seven concurrent views need ~3 s of CPU in total
when run one by one, but took 15-23 s each. Round 3 shows the instance stayed slow after the burst (the Free compute's CPU
was saturated or throttled). Afterwards single calls were back under 1.2 s. The tests ran with a 60 s session timeout, so no
statement was cancelled. Through the API, every one of these views would have hit `57014`.

Conclusion: a session start of the whole party (5-7 players opening at once) would push every fluent open past the timeout.
The release's fallback (`57014` → legacy open of that sheet) would then add the legacy reads on top. Legacy's small reads
each stay under the timeout and paint progressively.

## 4. Local benchmark (`supabase/tests/browser/fluency_benchmark.py`, real frontend, N = 5)

DB container at 16 CPUs and at 0.5 CPU (`docker update --cpus 0.5`). Medians.

| Measure | Legacy 16 CPU | Fluent 16 CPU | Legacy 0.5 CPU | Fluent 0.5 CPU |
|---|---|---|---|---|
| Open: whole sheet loaded (`full`) | 605-654 ms | **485-531 ms** | 1,911-2,245 ms | **952-1,064 ms** |
| Open: requests | 34-35 | **4** | 34-35 | **4** |
| Switch A→B→C: C usable | **488 ms** | 807 ms | **868 ms** | 2,926 ms |
| Switch requests | 65 | **12** | 65 | **12** |
| 5 simultaneous opens: usable median / max | **501 / 611 ms** | 865 / 958 ms | **741 / 2,433 ms** | 7,337 / 7,351 ms |
| 5 simultaneous opens: requests | 195 | **50** | 197 | **52** |
| Failed requests | 0 | 0 | 0 | 0 |
| Realtime bindings per join | 2 / 64 | **2** | 2 / 64 | **2** |

Not valid as data, so not reported:

- **The latency columns (0/50/150/300 ms).** The Chromium network emulation had no measurable effect: the 300 ms results
  equal the 0 ms ones. The values above are effectively at local latency.
- **Legacy single-open "identity" and "vitals" times** (21-183 ms). The benchmark reopens the same characters in one page,
  so legacy paints its offline `bundle:` copy first. The production smoke (§2, fresh contexts) is the clean comparison.

## 5. Reading

| | Fluent better | Fluent worse |
|---|---|---|
| Volume | 4 vs 34 requests per open, 12 vs 65 per switch, 2 vs 64 Realtime bindings | — |
| Database work | ~3× less per open (one rules evaluation) | all of it in one statement, against an 8 s timeout |
| Time | whole sheet complete sooner (1.0 vs 2.0 s at 0.5 CPU) | first usable paint later (production 572 vs 278 ms); switch later; concurrent burst far later |

Next change (not in this release): **progressive first paint.** Fetch the vitals part (stored rows, derived stats,
governance, revisions) in one small `get_character_reads`, and the rest of the shell in a second one. Make Build's class
features (33-118 KB) and Wild Shape options (up to 86 KB) lazy. Run the §3 burst and the 0.5 CPU switch/burst again as the
gate before setting `FLUENT_READS = 'on'`.
