# Fluency implementation roadmap (2026-10-30)

Ordered, reversible, smallest path to a fluent result. **Hosting is not migrated before the read path is fixed**: moving
today's 35-request model to any host keeps the problem (`FLUENCY_POC_RESULTS.md` §3: the same model times out on a
production-like CPU). Every phase ends with tests green, a fresh backup, and an explicit approval before production.

## Phase 0 — safety net (½ day, before anything else)

| Item | Detail |
|---|---|
| 0.1 Scheduled off-site backup of production (Free has **no** backups) | nightly `pg_dump -Fc` (session pooler, read-only role ideally) from a GitHub Actions workflow or a Windows scheduled task on the user's PC → encrypted (`age`) → off-site folder; SHA-256; keep 14 daily / 8 weekly / 6 monthly; monthly restore test into the local stack (`poc/portable-api/backup.sh` pattern). The connection secret lives in the CI secret store or Windows Credential Manager, never in Git |
| 0.2 Rotate the database password | the connection string has been in local files twice (incident + this review) |
| 0.3 Delete `C:\Users\ajuscakova\supabaseaccess.txt` | after this task |
| 0.4 Decide public sign-up | ON today; invite-only fits a private table (Dashboard setting; separate approval) |

## Phase 1 — fluency on the current Supabase (the fix)

| Step | Work | Evidence it works | Effort |
|---|---|---|---|
| 1.1 | Migration with the **transaction memo** + `get_character_shell`, `get_character_tab_bundle`, `get_character_view` (from `supabase/poc/fluency_poc_a.sql`, with rollback) | POC A: 989/0 equality; core runs 11 → 1-2 | ½ day |
| 1.2 | Frontend: open = `view(char, activeTab)`; tab change = `tab_bundle`; Home hover/focus = prefetch `shell`; one in-flight cache with dedupe + abort (reuse `read-control.js`); paint header + tab in one step | bench: usable 0.9 → 0.5 s, burst 4.0 → 1.2 s, switch 3.3 → 0.45 s (2 CPU) | 2-3 days |
| 1.3 | Mutations return the new row/revision; refetch only affected domains (`FLUENT_READ_ARCHITECTURE.md` §6) | | 1 day |
| 1.4 | Background picker list/detail (`get_background_list` 9 KB / `get_background_detail`); same pattern for Feat/Lineage; Wild Shape options out of the Play bundle into the Wild Shape panel (75 KB) | 470 KB → 9 KB | 1 day |
| 1.5 | Realtime: replace 64 bindings with **one `character_events` binding per sheet** (trigger writes `{character_id, domains, revision}`), or revision polling every 10 s as a fallback | subscription rows 66 → 2 | 1-2 days |
| 1.6 | Lazy Build `class_features` (118 KB for a 3-class character) per class | | ½ day |
| 1.7 | Tests: browser suite + new bundle equality suite + incident probe; measure **on production** read-only (SQL timing of `get_character_view`) and with a test player the user signs in with | p50/p95 vs targets in `ARCHITECTURE_PRODUCT_REQUIREMENTS.md` §4 | 1 day |

**Gate G1 (after Phase 1 in production, one real session):** if character open p95 ≤ 1.2 s and the session-start burst stays
< 1.5 s → stay on **Free**, done. The benchmark predicts open will pass (~0.5-0.9 s) and the burst may not (~2-4.5 s on a
production-like CPU, `FLUENCY_POC_RESULTS.md` §3). If the burst fails, choose:
- **zero-cost path:** Phase 1b (snapshot) on Free; or
- **quick path:** Supabase Pro (~€22.5/month, reversible by downgrade) for one month and re-measure. Micro is "shared CPU,
  1 GB" — its gain is unmeasured, so this is a trial, not a promise. Pro is also the answer if the user would rather pay
  than run the nightly backup job.

## Phase 1b — revisioned build snapshot (zero-cost cure for bursts on Free)

`FLUENT_READ_ARCHITECTURE.md` §5: lazy refresh on revision mismatch; generated "every core input bumps the revision" test;
golden suite on snapshot reads. Removes the core from ordinary reads entirely (open ≈ row reads, estimated 0.2-0.35 s even
on Free). 3-5 days; highest correctness risk of the plan, hence after the bundles, which it builds on.

## Phase 2 — portability (optional insurance; not needed for fluency)

| Step | Work |
|---|---|
| 2.1 | Frontend data access behind one module (`js/data.js`): `view`, `shell`, `tab`, `catalog`, `mutate(name, args)`, `events(char)`; Supabase implementation first |
| 2.2 | Portable API from `poc/portable-api` (+ JWKS verification of Supabase Auth tokens, allowlisted mutation pass-through, rate limiting, CORS, access logs, cancel-on-abort) |
| 2.3 | Event abstraction: Supabase single-binding channel ↔ SSE |
| 2.4 | Environment config: `API_BASE`, `AUTH_URL` per environment (extends `js/config.js` allowlist) |
| 2.5 | CI: run the POC B suite + equality against both back ends |

## Phase 3 — hosting rehearsal (only if leaving Supabase is decided)

Selected target (recommended: small VPS or mini PC, Supabase Auth kept), restore from a fresh backup, `DATABASE_MIGRATION_PLAN.md`
M2-M6, benchmark with real RTT, security review (no 5432, tunnel/Caddy, firewall), backup + restore rehearsal, 2 weeks
of shadow reads.

## Phase 4 — cutover (not in scope of this task)

Fresh backup → write freeze → final dump/restore → validation → frontend config switch → smoke → keep Supabase 30 days →
rollback = config revert. Expected downtime 30-60 min.
