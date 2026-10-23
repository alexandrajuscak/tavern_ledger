# Deployment: current hosted Supabase (Phase B, read-only, 2026-10-23)

Discovery so far used **only the public publishable key** that the live site already ships:
- `GET /auth/v1/settings`;
- `GET /rest/v1/<table>?limit=0` with `Prefer: count=exact`.

No sign-in, no service role, no write. Everything that needs an account, a Management-API token or the Dashboard is
marked accordingly.

| Field | Value | Status |
|---|---|---|
| Project URL | `https://pfgz…wlsc.supabase.co` (from tracked `js/config.js`) | KNOWN |
| Project ref | `pfgz…wlsc` | KNOWN (masked) |
| Is this the production project? | it is the project the live site uses; it must not be assumed to be the *only* or the intended future production project | REQUIRES USER INPUT (confirm) |
| Project exists / reachable | yes (Auth settings HTTP 200) | KNOWN |
| Region, plan, PostgreSQL version | – | REQUIRES DASHBOARD CHECK (or a Management-API token) |
| Backups available (daily / PITR) | – | REQUIRES DASHBOARD CHECK (Free plan: no downloadable daily backups; Pro: daily, PITR as an add-on) |
| Schema | the legacy `supabase/schema.sql` (11 tables). Probe: these 11 exist and answer **401 to the anonymous key** (no anon grant); `items` / `equipment` answer 404 | KNOWN (consistent with the deployed frontend) |
| Migration history (`supabase_migrations`) | probably none: schema.sql is run in the SQL editor | UNKNOWN (needs a DB connection) |
| Auth providers | **email** and **Google** enabled; all others off; anonymous users off | KNOWN |
| Public sign-up | **enabled** (`disable_signup: false`) | KNOWN: review (a private table should use invitations) |
| Email confirmation | required (`mailer_autoconfirm: false`) | KNOWN |
| SMTP | – | REQUIRES DASHBOARD CHECK (the default Supabase mailer is rate-limited) |
| Site URL / redirect URLs | – | REQUIRES DASHBOARD CHECK |
| Realtime publications | – | UNKNOWN (needs a DB connection) |
| Storage (portrait bucket, objects) | – | UNKNOWN (the legacy app stores portraits as URLs; the V6 app uploads to a `portraits` bucket) |
| Row counts (users, characters, campaigns …) | – | **BLOCKER until access is provided** (docs/DEPLOYMENT_EXISTING_DATA_INVENTORY.md) |

## Ways to complete discovery (choose one; all read-only)

1. **Dashboard (no credentials leave the browser):** you read region, plan, backups, Auth URLs and SMTP, and run the
   read-only count query from docs/DEPLOYMENT_EXISTING_DATA_INVENTORY.md in the SQL editor. You paste the numbers.
2. **Read-only database session from this machine:** you set `$env:PGPASSWORD` yourself in your own terminal. I then run
   `pg_dump` / `psql` with `default_transaction_read_only=on` against the session-pooler connection string. The string
   contains no password, and the password is never written to a file. This also produces the logical backup for Phase C.
3. **Management API token** (`supabase login` in your terminal): for region, plan and backups only. Never `supabase link`
   inside the repository folder (see docs/DEPLOYMENT_SECRET_AUDIT.md).
