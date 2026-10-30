# Fluency bottleneck analysis (2026-10-30)

Question: after the incident fix, where does the remaining delay of a character open / switch come from?
Evidence: `LIVE_DATABASE_ARCHITECTURE_EVIDENCE.md` (production), `CURRENT_PRODUCTION_FLUENCY_BASELINE.md`,
`FLUENCY_POC_RESULTS.md` (benchmark with production-like CPU). Ranges are deliberately wide; they describe a character open
on production Free at ~100-150 ms RTT, for today's characters.

## Decomposition of one open (today)

Production facts: 35 requests in 5 dependent waves; ~10 rules evaluations; the 14 sheet RPCs cost **2.8-4.0 s** of serial
database time for a level-2 character; one evaluation ≈ 260 ms server time; warm REST round trip 75-110 ms. With ~13 calls
fired together in wave 2, the open is CPU-bound for 1-3 s and network-bound for ~0.5 s (5 waves × ~100 ms).

| Category | Share of remaining delay | Evidence | Lever |
|---|---|---|---|
| **A. Database computation** (repeated rules core, effect expansion, JSON aggregation; not RLS, scans or indexes) | **45-60 %** | 11 core runs per open (local function stats), 2.8-4 s serial per open (prod), view model cuts DB time 6-30× (bench). RLS: the 144 ms item scan was fixed; remaining RLS cost is small (no seq-scan-heavy app table; 100 % cache hit) | one evaluation per bundle (memo) → snapshot |
| **B. Network round trips** (35 requests, 5 dependent waves, hosted RTT) | **15-25 %** | critical path ≥ 5 RTT ≈ 0.4-0.6 s; bench: current +300-570 ms from RTT 0→300, view +270-340 ms | 1 round trip per open; prefetch |
| **C. Frontend orchestration** (all tabs loaded on open, waves gated on each other, reconnect = full reload) | **5-12 %** | Play/Abilities/Inventory/Build/Bio data fetched regardless of tab; reconnect 34 requests per drop | tab bundles; domain-scoped refresh |
| **D. Response size** | **3-8 %** (open), **dominant for the Background picker** | 160 KB per open; transformation 75 KB, class_features 33-118 KB; Background catalog 470 KB (359 KB feats) | list/detail; lazy Wild Shape/feature lists |
| **E. Realtime** | **0-5 % on open; up to 10-15 % on switch/reconnect** | 64+2 bindings, leave/join of 64 per switch; Realtime admin statements 3-9 s during the incident | 1 binding per sheet or SSE |
| **F. Hosting capacity** (Free/Nano shared CPU) | **multiplier, ~15-25 %** of today's delay attributable to Free vs a small dedicated CPU | per-evaluation 2.5-4× slower than a laptop core; bench 0.5 vs 2 CPU: current 2.9 s vs 0.9 s usable, view 0.9 s vs 0.55 s; jitter at idle ±5 % (not the cause) | Pro/VPS only after A-C |
| **G. Perceived performance** (progressive assembly, late AC, cards popping in, blank switch) | not a time share; **large UX share** | identity after wave 1, derived after wave 2, inventory/governance later | one paint per view; cached shell on switch |

The categories overlap: F multiplies A, and C causes part of B. They sum to about 100 % only within the stated ranges.

## Answers

- **Architecture or hosting?** **Both, but mostly architecture.** On every CPU size tested, the request model is worth 1.6-7×.
  Hosting capacity is a 2-3× multiplier that only matters once the model is fixed.
- **Would eliminating repeated RPCs solve most of it?** Yes: on production-like CPU, usable 2.9 → 0.9 s, burst timeouts 19 → 0.
- **What remains after that on Free?** The single rules evaluation per open (~0.3-0.7 s on Free for production characters)
  and bursts. Two cures: the build snapshot (no evaluation on ordinary reads, €0) or more CPU (Pro/VPS).
- **Is the incident resolved?** No; the base cost per open is unchanged and the replay times out on a production-like CPU.
