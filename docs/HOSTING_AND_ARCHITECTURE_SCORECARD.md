# Hosting and architecture scorecard (2026-10-30)

Scores 1 (poor) – 5 (best) per criterion; weighted total out of 100. Every option except #12 **includes the bundled read path**
(Phase 1), because the benchmark shows that the request model dominates fluency on every host
(`docs/FLUENCY_POC_RESULTS.md` §3). Options 3-9 and 11 replace Supabase Auth (score 2); option 10 keeps it.
Inputs: `HOSTING_PROVIDER_COMPARISON.md`, `AZURE_HOSTING_REVIEW.md`, `SELF_HOSTING_RASPBERRY_PI_REVIEW.md`,
`SUPABASE_DEPENDENCY_INVENTORY.md`, `ARCHITECTURE_PRODUCT_REQUIREMENTS.md`.

## Weights (private-table priorities)

| Criterion | Weight | Why |
|---|---|---|
| Expected fluency | 22 | the reason for this work |
| Maintenance effort | 12 | one person, hobby time |
| Monthly cost | 12 | "as close to zero as practical", but not dominant |
| Initial migration effort | 10 | |
| Backup quality | 7 | campaign data loss is the worst outcome |
| Security | 7 | hidden DM data, owner isolation |
| Recovery difficulty, uptime, Auth | 5 each | |
| Cold start | 4 | first open after idle |
| Remote access, Realtime, RLS migration | 2 each | |
| Vendor lock-in | 1.5 | |
| PostgreSQL compat, test compat, future scaling | 1 each | |
| ARM compatibility | 0.5 | only matters for a Pi |

## Ranking

| Rank | Option | flu | cost | effort | maint | backup | recov | uptime | cold | remote | sec | auth | rt | pg | rls | tests | arm | lock | scale | **Score** |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 1 | 2 Supabase Pro + read-path redesign | 5* | 3 | 4 | 5 | 4 | 4 | 5 | 5 | 5 | 5 | 5 | 4 | 5 | 5 | 5 | 3 | 3 | 5 | **89.6** |
| 2 | 1 Supabase Free + read-path redesign (+ scheduled off-site dump) | 4 | 5 | 4 | 5 | 3 | 3 | 4 | 4 | 5 | 5 | 5 | 4 | 5 | 5 | 5 | 3 | 3 | 3 | **85.4** |
| 3 | 10 Hybrid: Supabase Auth + self-hosted API/DB (VPS) | 5 | 4 | 3 | 2 | 3 | 3 | 4 | 5 | 5 | 4 | 5 | 4 | 5 | 5 | 3 | 4 | 4 | 4 | **77.8** |
| 4 | 12 Current system, incremental optimization only | 2 | 5 | 5 | 4 | 2 | 3 | 3 | 4 | 5 | 5 | 5 | 3 | 5 | 5 | 5 | 3 | 3 | 1 | **73.0** |
| 5 | 7 Low-cost VPS (PostgreSQL + API) | 5 | 4 | 2 | 2 | 3 | 3 | 4 | 5 | 5 | 3 | 2 | 4 | 5 | 4 | 3 | 4 | 5 | 4 | **71.3** |
| 6 | 5 Azure PostgreSQL + Azure-hosted API | 4 | 2 | 1 | 3 | 5 | 4 | 5 | 3 | 5 | 4 | 2 | 3 | 5 | 4 | 3 | 3 | 3 | 5 | **66.2** |
| 7 | 4 Aiven Developer + portable API | 3 | 4 | 2 | 3 | 3 | 3 | 4 | 4 | 5 | 4 | 2 | 3 | 5 | 4 | 3 | 4 | 4 | 3 | **64.6** |
| 7 | 3 Neon + portable API | 3 | 4 | 2 | 3 | 4 | 3 | 4 | 2 | 5 | 4 | 2 | 3 | 5 | 4 | 3 | 4 | 4 | 4 | **64.6** |
| 9 | 6 Azure VM (PostgreSQL + API) | 4 | 3 | 2 | 2 | 3 | 3 | 4 | 5 | 5 | 3 | 2 | 4 | 5 | 4 | 3 | 4 | 4 | 4 | **64.2** |
| 10 | 9 Home mini PC + SSD + Cloudflare Tunnel | 4 | 4 | 2 | 2 | 2 | 2 | 2 | 5 | 4 | 3 | 2 | 4 | 5 | 4 | 3 | 5 | 5 | 3 | **62.0** |
| 11 | 11 Cloudflare Pages/Workers + managed PostgreSQL | 3 | 4 | 1 | 3 | 3 | 3 | 5 | 3 | 5 | 3 | 2 | 2 | 4 | 4 | 2 | 3 | 2 | 4 | **60.1** |
| 12 | 8 Raspberry Pi 5 + SSD + Cloudflare Tunnel | 3 | 4 | 2 | 1 | 2 | 2 | 2 | 5 | 4 | 3 | 2 | 4 | 5 | 4 | 3 | 4 | 5 | 2 | **54.9** |

\* **Sensitivity (decisive):** Pro's fluency 5 vs Free's 4 is an **assumption**. Micro is "shared CPU, 1 GB RAM" like Nano
with more RAM, and our working set already fits in RAM (100 % cache hit). It cannot be measured without upgrading, which
this task forbids. With equal fluency (4), Pro scores **85.2** vs Free **85.4**: a tie. Hence the recommendation is
**Free + redesign first, then a measured gate** to Pro (`FLUENCY_FINAL_RECOMMENDATION.md`), not an upgrade now.
Free's fluency 4 assumes the redesign **including the build snapshot** for bursts: with bundles only, the production-like
benchmark gives ~0.9 s opens but ~4.5 s for 5 simultaneous opens of heavy characters (`FLUENCY_POC_RESULTS.md` §3) → 3.

Other sensitivities: halving the cost weight moves Pro further ahead (more weight on backups/uptime); doubling maintenance
weight drops every self-hosted option below #12. No reasonable weighting puts Azure, Neon, Aiven or the Pi on top.

## Cost summary (EUR, estimates)

| Option | Upfront | Monthly | Annual | 3 years |
|---|---|---|---|---|
| 1 Supabase Free | 0 | 0 | 0 | 0 |
| 2 Supabase Pro | 0 | ~22.5 | ~270 | ~810 |
| 3 Neon (always-on 0.25 CU Launch) + API host | 0 | ~17 + 0-7 | ~210-290 | ~630-870 |
| 4 Aiven Developer + API host | 0 | ~4.5 + 0-7 | ~55-140 | ~160-410 |
| 5 Azure PG B1ms + API (after 12 free months) | 0 | ~17-30 | ~200-360 | ~400-900 (year 1 partly free) |
| 6 Azure VM B2pts v2 + disk + IP | 0 | ~11.5 | ~140 | ~410 |
| 7 VPS (Hetzner CAX11, + backups) | 0 | ~6.5-7.5 | ~80-90 | ~240-270 |
| 8 Raspberry Pi 5 kit + UPS | 250-330 | ~1 power + ~1 domain | ~22 | ~315-400 |
| 9 Used mini PC + UPS | 160-270 | ~2 power + ~1 domain | ~35 | ~265-375 |
| 10 Hybrid (VPS + Supabase Auth Free) | 0 | ~7 | ~85 | ~255 |
| 11 Cloudflare Workers Free + Aiven/Neon | 0 | ~4.5-17 | ~55-210 | ~160-630 |
| 12 Current | 0 | 0 | 0 | 0 |

Hidden cost of self-hosting (options 6-10): ~1 h/month routine administration plus incidents (`AZURE_HOSTING_REVIEW.md` §3).

## Winners

| Category | Winner | Why |
|---|---|---|
| **Zero monthly cost** | **Option 1: Supabase Free + read-path redesign (+ snapshot) + scheduled off-site dump** | €0; keeps Google Auth; fluency comes from the redesign (measured 1.6-7× depending on interaction); the real gaps (no backups, 7-day pause) are closed by a nightly `pg_dump` job and weekly use |
| **Low monthly cost (≤ ~€10)** | **Option 10: Hybrid — Supabase Auth (Free) + portable API + PostgreSQL on a small VPS** | most compute per euro, no cold start, Auth unchanged; costs ~1 h/month administration; POC B is its prototype |
| **Lowest maintenance** | **Option 2: Supabase Pro + read-path redesign** | daily backups, no pause, 7-day logs, nothing to administer; ~€22.5/month |
| **Overall** | **Option 1 (Supabase Free) now, with a measured gate to Option 2 (Supabase Pro)** | the table ranks Option 2 first only through the unmeasured Micro fluency score; Options 1 and 2 are a **tie decided by gate G1**, not by the table. Free's score of 4 is conditional on the snapshot; with bundles only it is 3 (≈ 81 points). See `FLUENCY_FINAL_RECOMMENDATION.md` |
