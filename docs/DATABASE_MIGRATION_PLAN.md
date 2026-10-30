# Database migration plan (contingency, 2026-10-30)

**Status: not recommended now** (`docs/FLUENCY_FINAL_RECOMMENDATION.md`). This plan exists so that leaving Supabase stays a
rehearsed, reversible option. Nothing here was executed against production. POC B executed steps M2-M4 against the
**local** development dump only.

Target assumed: hybrid option I — **Supabase Auth kept** (Google + e-mail, no user migration), PostgreSQL + portable API on a
VPS or home mini PC. A full exit (Auth too) adds §6.

## 1. Preserve / map / replace

| Object | Action | Proved by POC B |
|---|---|---|
| `public` schema (152 tables, 379 functions, 167 policies, triggers, indexes) | restore as-is | yes (0 errors for these objects) |
| Versioned catalog, custom content, hidden DM data, approvals, inventory, spells, resources, Wild Shape | part of `public` data | yes (row counts identical in the backup round trip) |
| Audit/history tables | restore (tiny: < 100 rows) | yes |
| `auth.users` | **copy `id`, `email`, `created_at` only** into the shim table (no hashes, no tokens) | yes |
| `auth.uid()`, roles anon/authenticated/service_role | shim (`poc/portable-api/db/00_portable_shim.sql`) | yes |
| `on_auth_user_created` trigger | API creates the profile on first sign-in instead | design |
| PostgREST grants | kept (roles exist); API uses `SET ROLE authenticated` | yes |
| Realtime publication (31 tables) | drop; SSE + `pg_notify` | yes |
| Storage bucket `portraits` | 0 objects in prod → nothing to move | n/a |
| `supabase_admin` grants, `ensure_rls` event trigger, vault | drop | yes (the only restore errors) |
| Extensions pgcrypto, uuid-ossp, pg_stat_statements | create on target | yes |
| Server setting | **`jit=off`** (mandatory: 30-65× slowdown otherwise) | yes |
| Export/import (JSON) | unchanged (browser) | n/a |

## 2. Steps

| # | Step | Command / check | Time |
|---|---|---|---|
| M0 | Freeze decision, announce window (no session that day) | | |
| M1 | Fresh production backup (as in the 2026-10-23 runbook: roles, schema, data, + `pg_dump -Fc` of `public`) | SHA-256 recorded | 10 min |
| M2 | Target: PostgreSQL 17 with `jit=off`, shim applied | `00_portable_shim.sql` | 5 min |
| M3 | Load identities: `copy (select id, email, created_at from auth.users)` → shim table | count = 8 | 1 min |
| M4 | `pg_restore --no-owner -n public` | expected errors: 31 publication + 3 `supabase_admin` grants, nothing else | 2 min |
| M5 | `ANALYZE` | | 1 min |
| M6 | Validate: row counts per table (`backup.sh` method), catalog checksums (`supabase/tests/*_catalog_checksum.sql`), golden derived stats for all characters (`scripts/incident/golden_derived.sql`), authorization suite (POC B test, extended) | all identical | 15 min |
| M7 | Dual read (optional): staging frontend (feature flag `?api=portable`) reads from the target while production writes to Supabase; compare views with `poc_b_test.py` equality check | 210/210 style equality | days |
| M8 | Cutover: write freeze (maintenance banner, Supabase project set read-only for `authenticated` by revoking write grants **only after approval**), final fresh dump, repeat M2-M6 on the final dump | | 30-45 min |
| M9 | Switch frontend config (`js/config.js`: API base URL; Auth URL unchanged), deploy Pages | | 5 min |
| M10 | Smoke: sign in (Google + e-mail), open each character, HP edit, DM view of hidden data, event delivery | checklist | 15 min |
| M11 | Keep the Supabase project intact and paused-from-writes for ≥ 30 days; decommission only after a written decision | | |

Expected downtime: **30-60 minutes** (write freeze to smoke done). Data volume (30 MB) makes every step fast.

## 3. Rollback

Until M9: nothing changed for users. After M9: revert `js/config.js` (one commit) → the frontend talks to Supabase again;
writes made on the target during the new period must be replayed or exported (keep the window short; do the cutover
right after a session, not before one). Supabase remains the source of truth until the 30-day mark.

## 4. Validation queries

- row counts: `poc/portable-api/backup.sh` (`COUNTS` query) on source and target;
- catalog: the existing `*_catalog_checksum.sql` files;
- rules: `golden_derived.sql` output identical for all characters (the incident task used this for 7 production characters);
- security: unrelated-player denial, hidden condition, unrevealed DM note, secret item, governance lock (`poc_b_test.py`).

## 5. Password handling

Not needed in the recommended hybrid (Supabase Auth stays). Never copy `auth.users.encrypted_password` into a custom
store.

## 6. Full exit including Auth (only if required)

1. Create a Google OAuth client for the new Auth; configure e-mail delivery.
2. Map users by verified e-mail; keep the same `id` so all foreign keys hold (`profiles.id = auth.users.id`).
3. Send every user a sign-in / set-password invite; Google users simply sign in with Google again (matched by e-mail).
4. Keep both Auth systems accepting tokens for a transition week (API verifies either issuer).
5. Effort ≈ 1-2 weekends; risk concentrated in e-mail delivery and account linking.
