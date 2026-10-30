# Supabase dependency inventory (2026-10-30)

How much of Tavern Ledger is tied to Supabase, measured on the code (`js/`, `supabase/`, `scripts/`) and on the local
database, and **proved** by POC B (the `public` schema restored onto ordinary PostgreSQL 17 and served by a portable API,
`docs/FLUENCY_POC_RESULTS.md`).

Classes: **P** pure PostgreSQL, portable · **PM** portable with minor changes · **S** Supabase-specific ·
**R** replacement required · **D** difficult · **SEC** security-sensitive.

## 1. Database

| Dependency | Where | Class | Evidence / migration note |
|---|---|---|---|
| 152 tables, 9 views, 379 functions (259 SECURITY DEFINER), 248 indexes, 1,043 constraints, 67 triggers | `public` | **P** | restored onto `postgres:17-alpine` with 0 errors for these objects |
| 167 RLS policies | `public` | **P** + SEC | policies use `auth.uid()` and app helpers only; all 51 POC B authorization/hidden-data checks pass on plain PostgreSQL |
| `auth.uid()` | 379 functions, policies, column defaults | **PM** + SEC | 3-line shim reading `request.jwt.claims` (`poc/portable-api/db/00_portable_shim.sql`), identical to Supabase's definition |
| FKs to `auth.users` | profiles, character_active_states, character_companions, character_infusions, character_starting_equipment, character_transformations | **PM** | shim table `auth.users(id, email, created_at)`; no function reads its columns |
| Trigger `on_auth_user_created` (creates profile) | `auth.users` | **PM** | move to the API's invite/sign-up path or keep the trigger on the shim table |
| Roles `anon`, `authenticated`, `service_role` | grants, policies | **PM** | created by the shim; the API login role `tl_api` can only `SET ROLE` to them |
| Grants to `supabase_admin` (3), publication `supabase_realtime` (31 tables) | restore | **S** | the only restore errors (34) on plain PostgreSQL; harmless; drop from a portable dump |
| Event trigger `ensure_rls` / `rls_auto_enable` | database | **S** | Supabase platform helper; not needed (migrations enable RLS explicitly) |
| Extensions pgcrypto, uuid-ossp | `extensions` schema | **P** | no public function calls them (defaults use core `gen_random_uuid()`) |
| supabase_vault | `vault` | **S** | not used by the app |
| `pg_stat_statements` | monitoring | **P** | |
| JIT | server setting | **PM** | **must be `jit=off`** on any target: with LLVM JIT the rules core ran 30-65× slower (POC B finding; Supabase prod: off) |
| Migration history `supabase_migrations.schema_migrations` | CLI | **S** | migrations are plain SQL files; any runner (or `psql -f` in order) works |

## 2. API layer

| Dependency | Where | Class | Note |
|---|---|---|---|
| PostgREST RPC: 150 distinct functions, 156 call sites | `js/*-api.js`, `js/store.js`, `js/sheet.js` | **R** (mechanical) | every RPC is a plain SQL function; a portable API calls the same functions (`select public.fn($1)`) |
| PostgREST table access: 55 tables/views, 110 call sites (`.from().select/insert/update/delete`, filters, order, `maybeSingle`) | same | **R** (largest frontend change) | the frontend builds queries; a portable API needs explicit endpoints per use, or a thin generic table endpoint limited by an allowlist |
| PostgREST error codes (`PGRST116`, `PGRST301`, `PGRST20x`), SQLSTATE mapping | `js/inventory-api.js`, `js/store.js`, `js/catalog-load.js` | **PM** | POC B maps SQLSTATE to stable API codes (`server.mjs` `mapPg`) |
| Request cancellation (PostgREST cancels the statement when the client aborts) | `js/read-control.js` | **PM** | node-postgres needs `pg_cancel_backend` on client abort to keep this property |
| Supabase JS client (`vendor/`), one client per page | `js/supabase.js` | **R** | replaced by `fetch` wrapper; ~19 modules import it |

## 3. Auth

| Dependency | Where | Class | Note |
|---|---|---|---|
| `signInWithPassword`, `signUp`, `signInWithOtp` (magic link), `signInWithOAuth` (**Google**), `signOut`, `getSession`, `onAuthStateChange` | `js/app.js` | **R** + **D** + SEC | 6 of 8 production identities are Google; leaving Supabase Auth needs a Google OAuth client and a re-link of every user |
| Session storage (localStorage tokens, refresh) | supabase-js | **R** | |
| Password reset e-mails, e-mail templates, SMTP | Supabase Auth | **R** | |
| Password hashes in `auth.users` (bcrypt) | Supabase Auth | **D** | do not copy without a target that explicitly verifies this format; prefer reset/invite |
| JWT verification | PostgREST / GoTrue | **PM** | POC B verifies HS256 tokens; hosted Supabase projects use asymmetric signing keys (JWKS) → verify with JWKS in production |
| Public sign-up toggle | Supabase setting | **S** | invite-only is simpler in a portable stack |

## 4. Realtime

| Dependency | Where | Class | Note |
|---|---|---|---|
| `postgres_changes` channel, 64 bindings per sheet | `js/store.js` | **R** | POC B replaces it with SSE + `pg_notify` (36 ms delivery), authorized at subscribe time |
| Request bar (2 bindings), DM Space (2 bindings) | `js/request-ui.js`, `js/dm-space.js` | **R** | same mechanism |
| Reconnect / resync logic | `js/sheet.js`, `js/store.js` | **PM** | keep the logic, change the transport |

## 5. Storage

| Dependency | Where | Class | Note |
|---|---|---|---|
| Bucket `portraits` (upload, public URL, remove) + 3 storage policies | `js/store.js:450-462` | **R** (small) | **0 objects in production**; replace with a file endpoint or keep URLs external |

## 6. Tooling and tests

| Dependency | Class | Note |
|---|---|---|
| Supabase CLI local stack (`supabase start`), `run_local.sh`, `run_supabase_local.sh` | **S** | POC B shows `docker compose` with plain PostgreSQL is enough for API tests |
| Browser suites (~990 tests) use the local Supabase URL, anon key, service role for fixtures | **PM** | fixtures need a different admin path (direct SQL) |
| SQL tests (`supabase/tests/*.sql`) | **P** | run with `psql` against any PostgreSQL |
| `db dump`, `db push`, migration repair | **S** | replaced by `pg_dump` and ordered `psql -f` |
| Service-role scripts (seed, demo, tests) | **PM** + SEC | never in the browser; keep server-side only |

## 7. Summary

| Layer | Effort to leave Supabase |
|---|---|
| Database schema, rules, RLS | **small**: shim + `jit=off` (proved) |
| Read path | **small once bundled**: shell + tab bundles are 3 endpoints (proved); today's 150 RPCs + 55 table paths are the large part |
| Writes | **medium**: ~100 mutation paths (RPCs and table updates) need endpoints |
| Realtime | **small-medium**: SSE/notify proved; frontend transport swap |
| Auth | **large + risky**: Google OAuth, e-mail flows, password reset, session handling, 8 users to re-link |
| Storage | trivial (unused) |

Valuable Supabase features: **Auth with Google**, managed backups (Pro), hosted PostgreSQL with zero administration,
dashboard/logs. Complexity it adds: 64-binding Realtime, a PostgREST surface that invites 35-request page loads, Free-plan
compute and no backups on Free.
