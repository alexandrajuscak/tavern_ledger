# Portable backend API design (2026-10-30)

Prototype: `poc/portable-api/` (POC B, local only, never deployed). Results: `docs/FLUENCY_POC_RESULTS.md` §2.
This is the **exit path** from Supabase and the backend-for-frontend for options C, F, G, H and I. It is not needed for
Phase 1 (`docs/FLUENCY_IMPLEMENTATION_ROADMAP.md`).

## 1. Technology choice

| Criterion | Choice | Why |
|---|---|---|
| Runtime | **Node.js 22 LTS** | same language as the frontend; one maintainer |
| HTTP | **Fastify 5** | JSON-schema request validation built in, low overhead, structured logging, mature; Hono/Express considered (Express lacks validation, Hono shines on edge runtimes we do not need) |
| PostgreSQL | **node-postgres (`pg`)** | the reference driver; pure JS → arm64 without native builds |
| Dependencies | 2 (fastify, pg) | small attack surface; `npm audit` trivial |
| Packaging | `node:22-alpine` image, non-root user, healthcheck, 128 MB heap | multi-arch (amd64/arm64 verified, §8) |
| Memory | measured **~20 MB idle**, PostgreSQL ~55 MB idle | fits a 1 GB VM or a Pi |

## 2. Request lifecycle (the security core)

```
Authorization: Bearer <JWT>  ->  verify (alg pinned, signature, exp, role=authenticated, sub=uuid)  ->  pool.connect()
BEGIN [READ ONLY]
  select set_config('request.jwt.claims', <claims json>, true), set_config('role', 'authenticated', true)
  <one SQL statement: select public.get_character_view($1, $2) | update ... | select ...>
COMMIT  ->  Server-Timing: db;dur=…;desc="qN"  ->  JSON
```

The API login role `tl_api` owns nothing and can only become `authenticated`/`anon` (`NOINHERIT`). Every read runs
`READ ONLY`. The database sees exactly what PostgREST gives it today, so **all 167 RLS policies, the 259
SECURITY DEFINER checks and the hidden-data filters apply unchanged**. The API never uses a privileged role for user
requests (no service-role shortcut).

## 3. Endpoints (POC B implements the bold ones)

| Endpoint | Purpose |
|---|---|
| **`GET /health`** | DB ping, pool and SSE counters (no auth, no data) |
| **`GET /api/characters`** | Home list (RLS decides visibility) |
| **`GET /api/characters/:id/view?tab=`** | shell + active tab, one round trip |
| **`GET /api/characters/:id/shell`**, **`/tabs/:tab`** | prefetch and tab change |
| **`GET /api/characters/:id/conditions`**, **`/dm-notes`** | hidden-data reads (RLS only) |
| **`GET /api/catalog/backgrounds`**, **`/:id`** | picker list/detail with ETag + `Cache-Control: private, max-age=300` |
| **`PATCH /api/characters/:id/vitals`** | HP/temp HP with `expected_updated_at` (optimistic concurrency → 409 + current revision) |
| **`GET /api/events?characters=`** | SSE change stream, authorized per character at subscribe time |
| `POST /api/rpc/:name` (Phase 2) | allowlisted pass-through for the ~100 mutation RPCs during migration |

## 4. Error contract

`{ "error": { "code", "message", "retryable" } }`. Mapping (`server.mjs` `mapPg`): `42501` → **404 not_found** (a foreign id
reveals nothing), `57014` → 503 retryable, `40001/40P01` → 409 retryable, `22023/22P02/23514` → 400, `P0001` (rule /
governance refusal) → 422, missing/invalid token → 401, schema violation (including unknown fields) → 400, else 500 (logged,
generic message).

## 5. Authorization matrix (POC B, all verified by `poc/portable-api/test/poc_b_test.py`)

| Action | Owner | Campaign DM | Other player | No / bad / expired / `alg:none` / service_role token |
|---|---|---|---|---|
| Home list | own characters | + campaign characters | own only (HERO absent ✔) | 401 ✔ |
| View/shell/tab (6 tabs) | 200 ✔ | 200 ✔ | **404** ✔ | 401 ✔ |
| Visible condition | ✔ | ✔ | none ✔ | 401 |
| Hidden condition | **hidden** ✔ | ✔ | none ✔ | 401 |
| DM note unrevealed / revealed | revealed only ✔ | both ✔ | none | 401 |
| Secret campaign item | 404 ✔ | 200 ✔ | 404 ✔ | 401 |
| HP edit | 200 ✔, stale → 409 ✔ | (governance rules) | 404 ✔ | 401 |
| Mass assignment (e.g. `owner_id` in body) | 400 ✔ | | | |
| Event stream | ✔ | ✔ receives owner's change ✔ | **404** ✔ | 401 |
| Custom-content visibility, audit filtering, governance | unchanged SQL (RLS / `_gov_decide`) | | | |

Defence in depth: API (identity, validation, allowlists) **and** database (RLS, definer checks). Neither alone.

## 6. Auth options

| Option | Free | Google | E-mail/password + reset | Invite flow | MFA | User migration | Maintenance | Verdict |
|---|---|---|---|---|---|---|---|---|
| **Keep Supabase Auth; API verifies its JWT (JWKS)** | yes (50k MAU Free) | **yes, unchanged** | yes | via dashboard / admin API | yes (TOTP) | **none** | none | **recommended for any hybrid** |
| Auth.js (in the API) | yes | yes (own Google client) | adapters; reset is DIY | DIY | no built-in | re-link 8 users | medium | possible, more code |
| Keycloak / Zitadel / Authentik | self-hosted free | yes | yes | yes | yes | import or reset | high (another service, Java/Go, 0.5-1 GB RAM) | overkill for 8 users |
| Azure Entra External ID | small free tier (not verified) | via federation | yes | yes | yes | reset | medium | not justified (`AZURE_HOSTING_REVIEW.md`) |
| Cloudflare Access (≤ 50 users free) | yes | yes (IdP) | one-time PIN | e-mail allowlist | via IdP | none (allowlist) | low | **good extra gate** for a home server, not the app identity |
| Custom invite-only sessions | yes | no (unless OAuth added) | must build: argon2id, reset tokens, rate limiting, CSRF, revocation | yes | no | reset | medium + security risk | only with vetted libraries; not recommended |

Passwords: Supabase stores bcrypt hashes; copying them is safe only into a target that explicitly verifies that format.
Prefer keeping Supabase Auth; otherwise a password-reset / invite e-mail to all 8 users.

## 7. Events

SSE (`text/event-stream`), heartbeat 25 s, `retry: 3000`. Source: `pg_notify('tl_events', {c, d, r})` inside the mutation
transaction (delivered only on commit), one LISTEN connection per API process fanning out to subscribers whose character
set contains `c`. Authorization at subscribe time with `can_access_character` as the user; the stream closes at token
expiry (`event: reauth`) so a revoked membership cannot keep listening beyond the token lifetime. Payload carries no data,
only domains + revision. Measured delivery 36 ms (local).

Production hardening (not in POC): access tokens are passed in the `Authorization` header (EventSource needs a
fetch-based client or a short-lived stream ticket; the POC's `access_token` query fallback must not be used in production
because URLs get logged), per-user stream limit, client abort → `pg_cancel_backend` to keep today's cancellation property.

## 8. Packaging and ARM

`docker compose` (`poc/portable-api/docker-compose.yml`): PostgreSQL **not published**, API bound to 127.0.0.1 (behind
Caddy or Cloudflare Tunnel in a real deployment), CPU/memory limits, health checks, `restart: unless-stopped`.
Required PostgreSQL settings: **`jit=off`**, `shared_preload_libraries=pg_stat_statements`, `statement_timeout=8000`.
Backup: `poc/portable-api/backup.sh` (dump + SHA-256 + verified restore + retention).

## 9. What the POC does not do (yet)

Mutations other than HP, the request bar/DM Space events, catalog endpoints other than backgrounds, rate limiting, CORS
policy, JWKS verification, structured access logs, migrations runner, and the frontend switch. Each is listed with an
estimate in `docs/FLUENCY_IMPLEMENTATION_ROADMAP.md` Phase 2.
