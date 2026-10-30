# Fluency proofs of concept: results (2026-10-30)

Both POCs are **local only**, never deployed, never connected to production. Data: the local development database
(35 test characters, 2 users) restored from `%USERPROFILE%\tavern-ledger-local-backups\fluency-poc-2026-10-30\before_fluency_poc.dump`
(sha256 `5d4d8f7c…`). Raw results: `…\fluency-poc-2026-10-30\bench\bench_cpu{2,1,0.5}.json`.

## 1. POC A — improved Supabase architecture (current local Supabase stack)

Files: `supabase/poc/fluency_poc_a.sql` (apply), `fluency_poc_a_rollback.sql` (exact restore of the one changed function +
drops), `fluency_poc_a_tests.sql`. Deliberately **outside `supabase/migrations/`** so `db push` cannot ship it.

| Element | Implementation |
|---|---|
| Character Shell | `get_character_shell(char)`: row, governance, derived summary, revision (`updated_at`, `derived_hash`) |
| Active-tab bundle | `get_character_tab_bundle(char, tab)` for all 6 tabs; `get_character_view(char, tab)` = shell + tab in one call |
| One evaluation per bundle | transaction-local memo inside `get_character_derived_stats`, keyed by token + character + `current_user` + `auth.uid()`; off outside bundles |
| Background list/detail | `get_background_list()` 9 KB, `get_background_detail(version)` 4 KB |
| Targeted refresh | **demonstrated server-side** (`fluency_poc_a_revision_tests.sql`, 4/4): an HP edit changes the edited character's `character_updated_at` but not its `derived_hash` (no derived refetch needed) and leaves another character's revision unchanged (no refetch); an ability edit changes `derived_hash`. The client policy is designed (`FLUENT_READ_ARCHITECTURE.md` §6) |
| Request dedupe | **not demonstrated in this POC** (client-side; designed in `FLUENT_READ_ARCHITECTURE.md` §8). With one request per open there is little left to dedupe; cancellation of superseded reads already exists in production (`js/read-control.js`) |

Tests (`fluency_poc_a_tests.sql`, everything rolled back): **989 passed, 0 failed** —
every section of every tab bundle equals the existing RPC for all 35 characters as their owner (RLS on), shell fields equal
derived stats / governance, view = tab bundle, memo is off after each bundle, outside a bundle 2 calls = 2 evaluations,
an unrelated user gets `42501` on all 6 views and the shell.

Rules-core evaluations and DB time (3-class level-9 character, local, in-transaction function statistics):

| Read | Requests | Core evaluations | DB time | Payload |
|---|---|---|---|---|
| Today: the 14 sheet RPCs of one open | 14 (+21 table reads) | **11** | ~1,270 ms | ~200 KB |
| `get_character_view(combat)` | **1** | **2** | 184 ms | 29 KB |
| `get_character_view(stats)` | 1 | 1 | 58 ms | 31 KB |
| `get_character_view(spells)` | 1 | 1 | 148 ms | 40 KB |
| `get_character_view(inventory)` | 1 | 1 | 82 ms | 8.5 KB |
| `get_character_view(features)` | 1 | 2 | 264 ms | 133 KB |
| `get_character_shell` | 1 | 1 | 51-55 ms | 7 KB |
| `get_background_list` vs `get_background_catalog` | 1 | 0 | 54 vs 60 ms | **9 KB vs 459 KB** |

Over HTTP through local PostgREST (7 runs): view(combat) median **184 ms**, shell **51 ms**.
Play and Build show 2 evaluations because SECURITY DEFINER RPCs inside them run as the function owner and correctly get
their own memo entry.

## 2. POC B — portable PostgreSQL API (no Supabase in the path)

Files: `poc/portable-api/` — `docker-compose.yml`, `Dockerfile`, `server.mjs` (Fastify 5 + pg), `db/00_portable_shim.sql`,
`db/10_authz_fixture.sql`, `run_poc_b.sh`, `backup.sh`, `test/poc_b_test.py`, `bench/bench.py`.

| Property | Result |
|---|---|
| Database | `postgres:17-alpine`, restored `public` schema: 152 tables, 167 policies, 390 functions; restore errors **34**, all Supabase-only (31 Realtime publication entries, 3 `supabase_admin` grants) |
| Supabase contract replaced by | 1 shim file (roles, `auth.users` with id/email only, `auth.uid()/role()/jwt()`) |
| **Critical finding** | the official image ships LLVM **JIT**; with `jit=on` the rules SQL ran **30-65× slower** (a combat view hit the 8 s timeout; `_character_class_effects` 1,654 ms vs 23 ms). `jit=off` fixes it; Supabase prod has `jit=off` and its image has no JIT library. Any migration must set it |
| Session | HS256 JWT (same format as local Supabase Auth); production design: verify Supabase Auth tokens via JWKS |
| Authorization | per request: `begin [read only]` → `request.jwt.claims` + `role=authenticated` → one statement → commit; RLS unchanged |
| Tests (`poc_b_test.py`) | **51 passed, 0 failed**: token checks (none/forged/`alg:none`/expired/`service_role` claim → 401), owner/DM/stranger on 6 views (200/200/404), Home list visibility, hidden condition, unrevealed DM note, secret item, HP edit 200, stale edit **409** with current revision, stranger edit 404, invalid/extra fields 400, SSE subscribe allowed/denied, **event delivered 36 ms** after commit, catalog list 9 KB + ETag 304, detail |
| Semantic equality | API view == Supabase PostgREST view for **210/210** character × tab combinations |
| Memory (idle) | API ~20 MB, PostgreSQL ~55 MB (amd64) |
| HTTP timing (DB capped at 2 CPUs) | view(combat) median 354 ms, shell 95 ms (slower than PostgREST above because the DB container is CPU-capped and musl-based, not because of the API) |
| Backup (`backup.sh`) | dump 2.2 MB in 2 s, SHA-256 verified, restore into scratch DB 6 s, **153 tables, identical row counts**, retention applied |
| Failure behaviour | statement timeout → 503 `{code: timeout, retryable: true}`; foreign id → 404 (no existence leak); DB down → `/health` fails, requests 500 generic |

### ARM64 compatibility (QEMU emulation on x86 — compatibility evidence only, not Pi performance)

| Check | Result |
|---|---|
| `docker buildx --platform linux/arm64` of the API | built in 34 s, 64 MB image |
| `postgres:17-alpine` arm64 | starts in 10 s (`uname -m` = aarch64), `jit=off` |
| Restore of the dump on arm64 | 12 s, same 34 expected errors, 35 characters |
| API arm64 | healthy in 10 s; owner view 200 and **byte-identical** to amd64; other user 404; no token 401 |
| Memory under emulation | PostgreSQL 95 MB, API 159 MB (includes QEMU overhead; native amd64 API is 20 MB) |
| Timing under emulation | 3.1 s for a view — **meaningless** (instruction emulation), not used anywhere |

## 3. Benchmark: request model × RTT × CPU (same database, same data)

Harness `poc/portable-api/bench/bench.py` against POC B with bench-only replay endpoints (`BENCH_LEGACY=1`, allowlisted,
RLS applied). Models: **current** = the deployed sheet's dependent waves (8 table reads → 13 → 9 → 1 = 31 requests; the 4
app-level reads are excluded); **view** = 1 request; **split** = shell + tab in parallel. Latency = sleep(RTT) before each
request (warm HTTP/2; TLS excluded). Usable = identity + vitals + AC. Characters: the 6 most complex local characters
(1-3 classes, up to level 20). N = 7 per cell. Database CPU limited with `docker update --cpus`.

CPU calibration: `get_background_catalog` server time — local 2 CPU 62-79 ms, 1 CPU 60-94 ms, **0.5 CPU 117-197 ms**;
production idle 89-104 ms. **0.5 CPU ≈ production Free single-query speed** (concurrency capacity of Free cannot be measured
without a load test, which was not allowed).

Usable time, median / p95 (ms):

| DB CPU | Model | RTT 0 | 50 | 150 | 300 | requests | DB ms/open* | KB |
|---|---|---|---|---|---|---|---|---|
| 2 | current | 617 / 1,788 | 821 / 1,942 | 896 / 1,963 | 1,190 / 2,235 | 31 | 4,847 | 160 |
| 2 | **view** | 409 / 601 | 430 / 705 | **546** / 766 | 676 / 910 | 1 | 374 | 94 |
| 2 | split (shell paints) | 153 / 337 | 210 / 322 | **283** / 446 | 444 / 581 | 2 | 500 | 94 |
| 1 | current | 1,211 / 3,144 | 1,386 / 3,152 | 1,491 / 3,769 | 1,724 / 3,807 | 31 | 9,634 | 160 |
| 1 | view | 401 / 653 | 434 / 681 | 520 / 810 | 706 / 940 | 1 | 362 | 94 |
| 1 | split | 248 / 533 | 278 / 565 | 368 / 694 | 566 / 835 | 2 | 659 | 94 |
| **0.5** | current | 3,085 / 6,667 | 2,804 / 6,701 | **2,929 / 7,209** | 3,351 / 7,062 | 31 | 22,417 | 160 |
| **0.5** | **view** | 781 / 1,205 | 820 / 1,315 | **896 / 1,365** | 1,120 / 1,408 | 1 | 740 | 94 |
| **0.5** | split | 563 / 1,278 | 509 / 1,179 | 671 / 1,209 | 770 / 1,475 | 2 | 1,442 | 94 |

\* sum of per-request database wall time; for the parallel current model it includes CPU queueing, so it exceeds the CPU used.

Full eventual load (current) at 150 ms: 1,663 / 2,374 / **4,592** ms at 2 / 1 / 0.5 CPU; view = usable.

Bursts and switches (RTT 50 ms):

| DB CPU | Model | 5 players open at once: usable median / max | statement timeouts (503) | A→B→C, C usable after last click median / max | timeouts |
|---|---|---|---|---|---|
| 2 | current | 4,008 / 7,204 | 0 | 3,302 / 4,514 | 0 |
| 2 | **view** | **1,168 / 1,329** | 0 | **454 / 685** | 0 |
| 1 | current | 8,576 / 11,780 | 0 | 5,941 / 8,748 | 0 |
| 1 | view | 2,059 / 2,228 | 0 | 888 / 1,270 | 0 |
| **0.5** | current | 14,159 / 22,062 | **19** | 11,364 / 14,882 | **14** |
| **0.5** | **view** | 4,452 / 4,668 | **0** | 2,111 / 2,783 | **0** |

Reading the table:
1. **The request model is the dominant factor on every CPU size**: view is 1.6-3.3× faster to usable, 3.2-4.2× faster in bursts,
   5.4-7.3× faster in switches, with 1 request instead of 31 and 13-30× less database wall time (RTT 150 ms column / RTT 50 ms
   for bursts and switches).
2. On a production-like CPU (0.5) the **current model reproduces the incident** (19 statement timeouts in a 5-player burst,
   14 in a fast switch). The view model has **zero** timeouts in the same conditions.
3. On a production-like CPU even the view model misses the burst/switch targets (4.5 s / 2.1 s vs 1.5 s / 1.2 s) **for these
   heavy test characters**, because each open still runs the rules core. Removing the core from ordinary reads (build snapshot)
   or more CPU (2 CPUs: 1.2 s / 0.45 s) closes that gap.
4. RTT matters less than evaluations: from 0 to 300 ms RTT the view gets ~270-340 ms slower; the current model gets
   ~300-570 ms slower at fast CPUs, and the CPU cost dwarfs both.

## 4. Unlike conditions (stated)

- Local Supabase (POC A HTTP timings) runs uncapped on 16 cores with glibc; POC B's database was capped (2/1/0.5 CPU) and is
  Alpine/musl. Cross-POC absolute times are therefore not comparable; within the benchmark everything ran on POC B.
- Test characters (up to 3 classes, level 20) are heavier than production's (max 1 class, level 2): production per-open cost is
  lower than these numbers by roughly 1.5-3× (production derived 260 ms vs ~370 ms here at 0.5 CPU).
- Browser render time is not in the API benchmark; the browser probe (`CURRENT_PRODUCTION_FLUENCY_BASELINE.md` §3) shows render
  adds < 100 ms once data is present.

## 5. Projection to production (Supabase Free, hosted RTT ≈ 100 ms per warm request)

| Interaction (production characters) | Today | Bundles (Phase 1) | Bundles + snapshot (Phase 1b) | Bundles on 2 dedicated CPUs |
|---|---|---|---|---|
| Open usable p50 | ~1.5-3 s | **~0.5-0.9 s** | ~0.2-0.35 s (estimate) | ~0.35-0.55 s |
| Session-start burst (5) worst | timeouts possible | ~2-4.5 s | < 1 s (estimate) | ~1.3 s |
| Fast switch A→B→C | ~2-11 s | ~1-2 s | < 0.6 s (estimate) | ~0.5 s |
| Background picker | 470 KB | 9 KB list + 4 KB detail | same | same |

Projections combine measured production per-evaluation cost with the 0.5-CPU benchmark and are estimates; Phase 1 includes
measuring them for real (`FLUENCY_IMPLEMENTATION_ROADMAP.md` 1.7).

## 6. State left behind (local)

- POC A was **rolled back** on the local Supabase database with `supabase/poc/fluency_poc_a_rollback.sql`; the md5 of all
  public function definitions afterwards equals the pre-task fingerprint (`5709d520…`, `public_functions_md5.txt`). Re-apply
  `fluency_poc_a.sql` locally to repeat the tests.
- POC B containers (`docker compose -p tlpoc`) are stopped at the end of the task and their volume removed (`run_poc_b.sh down`);
  secrets lived only in the session scratchpad.
- The local Supabase stack's data is unchanged (all POC A tests roll back; POC B wrote only to its own disposable database).
