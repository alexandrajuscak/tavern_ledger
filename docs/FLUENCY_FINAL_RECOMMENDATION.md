# Fluency and hosting: final recommendation (2026-10-30)

## Decision

**A. KEEP SUPABASE FREE AND REARCHITECT THE READ PATH** — with a measured gate to **B (Supabase Pro)** if the session-start
burst is still slow after the bundles and the user prefers paying to building the snapshot.

## Why the application is still not fluent

1. **Every open still runs the rules core ~10 times.** 35 requests in 5 dependent waves; 9 heavy RPCs each recompute derived
   stats. Production: one evaluation ≈ 260 ms of server time, one open of a level-2 character = **2.8-4.0 s** of database
   time. The incident fix removed the amplifiers (cross-character reloads, HP-triggered re-reads, uncancelled fast switches,
   stuck pickers), not this base cost.
2. Fired in parallel on a small shared CPU, that cost queues. On a production-like CPU the current request model reproduces the
   incident: **5 simultaneous opens → 14 s median, 19 statement timeouts**; the one-request view in the same conditions:
   4.5 s, **0 timeouts**; single open 2.9 s → 0.9 s.
3. The page assembles itself from 5 waves, so even fast data feels slow.
4. Not the cause: database size (30 MB of 500 MB), I/O (100 % cache hit), connections (31 of 60), indexes, frontend hosting
   (FCP 0.1 s warm), shared-compute jitter (±5 % at idle).

**Main issue: architecture (≈ 65-85 % of the delay); hosting capacity is a 2-3× multiplier that matters only after the
architecture is fixed** (`FLUENCY_BOTTLENECK_ANALYSIS.md`).

## Target architecture

One request per open (`view(char, tab)` = shell + active tab, one rules evaluation via the transaction memo), tab bundles
on tab change, shell prefetch on hover, picker list/detail, mutation responses + domain-scoped refresh, one Realtime binding
per sheet instead of 64; then a revisioned build snapshot so ordinary reads run no rules evaluation at all
(`FLUENT_READ_ARCHITECTURE.md`). Authorization stays in PostgreSQL (RLS unchanged).

| | Value |
|---|---|
| Host | **Supabase Free** (unchanged project), GitHub Pages (unchanged) |
| Expected cost | **€0/month**; €22.5/month only if gate G1 chooses Pro |
| Expected maintenance | ~15 min/month (check the nightly backup job, monthly restore test) |
| Migration difficulty | none (no hosting move); Phase 1 is ~1-1.5 weeks of evening work |

## Verdicts

**Supabase.**
- *Is the primary problem the Free plan?* No. *The read architecture?* Yes.
- *Would Pro make the current app fluent?* No: same request model, Micro is also "shared CPU", the data already fits in RAM.
- *Would Free become fluent after bundling and snapshot?* Bundles: opens yes (~0.5-0.9 s projected), bursts borderline;
  bundles + snapshot: yes (estimated 0.2-0.35 s opens).
- *Valuable:* Auth with Google (6 of 8 users), hosted PostgreSQL with zero administration, Realtime when used sparingly,
  logs/dashboard. *Adds complexity:* the PostgREST surface that invited 35-request pages; 64-binding Realtime; Free has
  **no backups** and pauses after 7 idle days.
- *Leaving:* schema/RLS portable in hours (proved); API ~2-3 weeks; Auth migration is the risky part. **Not worth it now.**
- **Free: KEEP. Pro: only via gate G1 or for managed backups. Leaving: NO (keep POC B as the rehearsed exit).**

**Azure: NOT RECOMMENDED.** €17-30/month for managed PostgreSQL + API after 12 free months, or ~€12/month for a VM the
user must administer; no durable free option; replaces one Supabase project with 3+ services and an Auth migration; no
advantage for this workload (`AZURE_HOSTING_REVIEW.md`).

**Raspberry Pi: NOT RECOMMENDED as the primary host.** Pi 5 8 GB + NVMe + PSU + cooling + UPS ≈ €250-330 at 2026 prices,
~1 h/month administration, down when the home is down, and per evaluation roughly as fast as Supabase Free (estimate).
If self-hosting is wanted anyway: **a used mini PC (8-16 GB, SSD) with Cloudflare Tunnel, PostgreSQL private, Supabase
Auth kept, off-site encrypted backups — recommended with conditions** (`SELF_HOSTING_RASPBERRY_PI_REVIEW.md`).

## Options (summary; full scorecard in `HOSTING_AND_ARCHITECTURE_SCORECARD.md`)

| Option | Cost/month | Fluency (with bundles) | Cold start | Auth | Realtime | Backups | Maintenance | Migration | Verdict |
|---|---|---|---|---|---|---|---|---|---|
| Supabase Free + redesign | €0 | good; bursts need snapshot | pause after 7 idle days | kept | kept (1 binding) | **DIY nightly dump** | lowest | none | **recommended** |
| Supabase Pro + redesign | ~€22.5 | good (Micro gain unmeasured) | none | kept | kept | daily, 7 days | lowest | none | **gate G1 / lowest maintenance** |
| Hybrid: Supabase Auth + API/PG on a €6-7 VPS | ~€7 | best per € (2 vCPU, 4 GB) | none | kept | SSE | DIY | ~1 h/month | 2-3 weeks | best low-cost if leaving |
| Neon + API | €0-17 | fair; scale-to-zero cold start on Free | yes | replace | SSE | provider | medium | 3-4 weeks | not preferred |
| Aiven Developer + API | ~€4.5 + host | fair (1 CPU) | none | replace | SSE | not verified | medium | 3-4 weeks | not preferred |
| Azure PG + API / Azure VM | €17-30 / ~€12 | good | Functions/ACA cold start | replace | SSE | managed / DIY | medium / high | 4+ weeks | **not recommended** |
| Raspberry Pi 5 / mini PC + Tunnel | ~€2 + €160-330 upfront | fair / good | none | kept or replace | SSE | DIY off-site | high | 2-3 weeks | **not recommended** / with conditions |
| Cloudflare Workers + managed PG | €0-17 | fair | low | replace | weak | provider | medium | 4+ weeks | not preferred |
| Current, incremental only | €0 | poor in bursts | — | kept | 64 bindings | none | low | none | not acceptable |

**Winners:** zero-monthly-cost → Supabase Free + redesign (+ nightly off-site dump); low-cost (≤ €10) → hybrid VPS with
Supabase Auth; lowest maintenance → Supabase Pro + redesign; **overall → Supabase Free + redesign, gate to Pro.**

## POCs (details `FLUENCY_POC_RESULTS.md`)

| | POC A (Supabase) | POC B (portable API) |
|---|---|---|
| Requests per open | 35 → **1** | 1 |
| Rules evaluations per open | 11 → **1-2** | 1-2 |
| DB time per open (3-class L9, local) | 1,270 → **184 ms** | 354 ms (DB capped at 2 CPUs) |
| Response | ~200 KB → 29 KB (Play) | 26.5 KB |
| Background picker | 459 KB → **9 KB** list + 4 KB detail | same, + ETag/304 |
| Tests | **989 / 0** equality + denial + memo isolation; **4 / 4** revision-based refresh; client dedupe not demonstrated | **51 / 0** auth/authz/hidden data/409/SSE; **210/210** equal to PostgREST |
| Memory | — | API 20 MB, PG 55 MB idle |
| Failure behaviour | unchanged SQL errors | 57014 → 503 retryable, foreign id → 404, stale → 409 |
| Key finding | memo is safe only with `current_user` in the key (definer calls) | **`jit=off` mandatory** (30-65× slower otherwise); restore needs a 1-file shim |

## Migration (only if ever chosen; `DATABASE_MIGRATION_PLAN.md`)

Fresh dump → shim + `jit=off` → load identities (id/email only) → `pg_restore -n public` (34 expected errors) → ANALYZE →
validate (row counts, catalog checksums, golden derived, authz suite) → write freeze → final delta via fresh dump →
switch `js/config.js` API base → smoke → keep Supabase 30 days; rollback = config revert. Auth kept on Supabase → no password
migration. Expected downtime 30-60 min.

## Roadmap (`FLUENCY_IMPLEMENTATION_ROADMAP.md`)

Phase 0 safety net (nightly off-site dump, password rotation, delete the connection file) → **Phase 1 bundles on Supabase**
→ gate G1 → Phase 1b snapshot (or Pro) → optional Phase 2 portability → Phase 3/4 only if leaving.

## NEXT ACTION (exactly one)

**Implement Phase 1.1 + 1.2: the Character Shell / tab bundles / view RPCs (memo) as a real migration on the current
Supabase, and switch the sheet's open, switch and tab paths to them.** Start from `supabase/poc/fluency_poc_a.sql`; keep the
989-check equality suite as its regression test.

Do not forget, independently of that task: Supabase Free has **no backups**; the nightly off-site dump (Phase 0.1) closes
the largest data-safety gap.

## Safety confirmation (this task)

- Production inspection was **read-only** (`default_transaction_read_only=on`, `BEGIN READ ONLY … ROLLBACK`, confirmed
  `transaction_read_only = on`); ~4 sheet-opens' worth of sequential reads; no load test.
- No production data, setting, migration, Realtime pool, compute, statement_timeout or max_connections changed;
  no catalog import; no `db push`, no migration repair; no `pg_stat_statements` reset.
- No signed-in production session (it would write auth tables).
- The connection string was never printed, logged, committed or copied into a file in the repository; host and project
  reference were masked in all output. The connection file was not modified.
- No commit, no push, no deployment.
- Local: POC A rolled back (function fingerprint identical to the pre-task value); POC B containers and volume removed;
  local Supabase data unchanged (2 users, 35 characters, 42 migrations).
- `poc/`, `supabase/poc/`, `scripts/architecture/` and the 15 docs are **untracked**. GitHub Pages serves the repository root,
  so if `poc/` is ever committed its files become public (no secrets in them, but keep it out of the Pages build or in a
  separate branch).
