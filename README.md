# ⚔ Tavern Ledger

A mobile-first **D&D 5e character sheet and campaign tool** for a small private table. The frontend is plain HTML, CSS
and JavaScript (no build step) and is served by GitHub Pages. Supabase provides PostgreSQL, Auth, the REST API and Realtime.

- **Character sheet** in six sections: Play, Abilities, Spells, Inventory, Build, Bio. Every edit saves automatically and
  syncs live to other devices.
- **Rules engines in the database**:
  - classes and subclasses with levels, features, choices, resources and spell slots (including Pact Magic);
  - lineages, backgrounds, feats and spellcasting sources;
  - an item catalog with equipment, attunement and containers;
  - Wild Shape and companions.

  Derived values (HP maximum, AC, bonuses, save DCs) are always calculated, never typed in.
- **Campaigns and DM Space**:
  - governance presets (relaxed / standard / strict / custom) and approval requests;
  - character locks and hidden DM data (unidentified items, curses, hidden conditions, DM notes);
  - custom content (spells, items, feats, creatures, lineages, backgrounds) with versioning;
  - an audit log.
- **Import / export** of whole characters as JSON (Bio → Download; home → Import file). Imports are all-or-nothing for
  the core sheet and never trust derived values.
- **Security**: Row Level Security on every table, SECURITY DEFINER functions with a pinned `search_path`, and no
  privileged key in the browser.

---

## Architecture

```
GitHub Pages (static files from the root of main)        Supabase project
  index.html, css/, js/, assets/, fonts/, vendor/  ──►   PostgreSQL + RLS (41 migrations)
  js/config.js: project URL + publishable key            Auth (email, optional Google)
  supabase-js 2.117.2 self-hosted in vendor/             REST API / RPC, Realtime
                                                         Storage bucket "portraits"
```

| Path | What |
|---|---|
| `index.html`, `css/`, `js/`, `assets/icons/`, `fonts/`, `vendor/supabase-js/` | the app (no external requests at runtime) |
| `js/config.js` | **production** Supabase URL and **publishable** key, and the hosts allowed to use them |
| `supabase/migrations/` | the complete database: schema, RLS, functions, Realtime publication, storage bucket |
| `supabase/rollback/` | per-migration rollback scripts (local testing) |
| `supabase/tests/` | SQL, API and browser test suites (local) |
| `scripts/` | local development and deployment helpers |
| `docs/` | design, data model, test and deployment documentation |

The official **rules catalog** (classes, spells, items, creatures, lineages, backgrounds and feats) is **not** part of
this repository. It is imported **once** into a new database from a private catalog package. After that the database is
the source of truth, and campaign-specific content is managed in the app's **DM Space**.

---

## Environments

The frontend chooses its database by where it is served from (`js/supabase.js`). It never falls back silently:

| Served from | Uses | Configuration |
|---|---|---|
| `localhost` / `127.0.0.1` | the local Supabase stack only | `js/config.local.js` (git-ignored, written by `scripts/start-local.ps1`) |
| `localhost` with `?env=staging` | a staging project only (red STAGING banner) | `js/config.staging.js` (git-ignored) |
| a host listed in `PRODUCTION_HOSTS` | the production project | `js/config.js` |
| anything else | nothing ("Unknown address") | – |

`js/config.js` may contain **only** the project URL and the **publishable** key (`sb_publishable_…`). Row Level Security
protects the data. The app refuses to start with a secret (`sb_secret_…`) or `service_role` key in any configuration, and
the test suite checks the committed file.

---

## Deploying a new production environment

Production is always built as a **new, empty Supabase project**:
1. migrations;
2. a one-time catalog import;
3. Auth settings;
4. the frontend on GitHub Pages.

The full step-by-step guide, including expected counts and verification queries, is in
[docs/DEPLOYMENT_PACKAGE.md](docs/DEPLOYMENT_PACKAGE.md) and
[docs/DEPLOYMENT_PRODUCTION_RUNBOOK.md](docs/DEPLOYMENT_PRODUCTION_RUNBOOK.md). In short:

### 1. Create the Supabase project

Create a new project in the Supabase Dashboard. Store the generated database password in a password manager.

### 2. Apply the migrations (Supabase CLI)

From the repository root, with the session-pooler connection string from Dashboard → Connect (enter the password at a
prompt; do not save it in a file):

```powershell
supabase db push --db-url "<session-pooler connection string>" --dry-run
supabase db push --db-url "<session-pooler connection string>"
```

This applies all 41 migrations in order and records them in the migration history. Use `--db-url` rather than
`supabase link`.

### 3. Import the catalog (once)

Run the nine catalog SQL files from the private catalog package with `psql`, in this order: `reference_data`,
`item_effects`, `spells`, `classes`, `class_features`, `creatures`, `lineages`, `feats`, `backgrounds`.

Run them **exactly once, on the empty database, before any DM content exists**: a second run would remove parts of
campaign custom content. Then run `supabase/tests/catalog_integrity_report.sql` (read only; every line must be `0`).

### 4. Configure Auth (Dashboard → Authentication)

- **Site URL** and **Redirect URLs**: the exact Pages URL, e.g. `https://<user>.github.io/<repo>/`.
- **Email**: on, with "Confirm email" on. **Google**: optional (your OAuth client; callback
  `https://<project-ref>.supabase.co/auth/v1/callback`).
- **Sign-ups**: allow them while the table's accounts are created, then turn them **off** (invite new players instead).

### 5. Create the admin / DM account

Sign up in the app and confirm the e-mail. Then, once, in the SQL Editor:

```sql
update public.profiles set role = 'admin' where email = 'you@example.com';
```

### 6. Deploy the frontend (GitHub Pages)

1. Put the new project's URL and **publishable** key into `js/config.js`, and the Pages host into `PRODUCTION_HOSTS`.
2. Commit and push to `main`.
3. Repository **Settings → Pages → Deploy from a branch → `main` / `(root)`**. Every push to `main` redeploys.

### 7. Smoke test, then the table

Sign in as the DM and as a player. Create the campaign in DM Space, add the players, and import the characters
(home → Import file), one at a time. Each imported character is completed on **Build** (lineage, class, background,
spells). See [docs/DEPLOYMENT_CHARACTER_REIMPORT_PLAN.md](docs/DEPLOYMENT_CHARACTER_REIMPORT_PLAN.md).

**Rollback:** revert the release commit on `main`. Pages serves the previous frontend again, and a previous project stays
untouched ([docs/DEPLOYMENT_ROLLBACK_RUNBOOK.md](docs/DEPLOYMENT_ROLLBACK_RUNBOOK.md)).

---

## Updating an existing installation

> The current production project still runs the legacy single-file schema. Its one-time upgrade to the migration-based
> schema (keeping accounts, Google sign-in, campaigns and characters) is described in
> [docs/DEPLOYMENT_INPLACE_UPGRADE_RUNBOOK.md](docs/DEPLOYMENT_INPLACE_UPGRADE_RUNBOOK.md).

- **Database changes** are new files in `supabase/migrations/`. Test them locally (`bash supabase/tests/run_local.sh`
  runs every migration, test suite, rollback and reapply in a throwaway container). Then apply them with
  `supabase db push --db-url …` **before** pushing the frontend that needs them.
- **Never** re-run the catalog import on a database that already holds campaign content.
- **Browser caches**: every script and stylesheet link carries a version tag (`?v=10`). Bump it everywhere when the
  code changes, so devices load the new files: `sed -i "s/?v=10/?v=11/g" index.html js/*.js`

---

## Local development

The whole stack (Supabase in Docker plus the app) runs on your computer: `start-local.bat` / `stop-local.bat`. See
[docs/LOCAL_DEVELOPMENT.md](docs/LOCAL_DEVELOPMENT.md) and [docs/LOCAL_MANUAL_TESTING.md](docs/LOCAL_MANUAL_TESTING.md).

Tests (local only):

| Command | What |
|---|---|
| `bash supabase/tests/run_local.sh` | all migrations, SQL suites, concurrency, rollback and reapply (throwaway PostgreSQL container) |
| `PORT=5191 bash supabase/tests/run_browser_local.sh` | the browser suites against the local stack (use a free port if your own server uses 5173) |

The test runners need the catalog SQL files in `supabase/seed/`, which is git-ignored and comes from the private catalog
package.

---

## How it works

- **Auto-save.** Each edit updates the screen at once and goes into a save queue. It is written about 0.6 s after you
  stop typing and retried on failure. The top bar shows *Editing… / Saving… / Saved ✓ / Offline — will sync*.
- **Sync between devices.** The open sheet subscribes to Supabase Realtime. After a lost connection it reloads the
  stored values ("Connection restored").
- **Local storage** is only a cache (last list, last sheet, selected tab). Supabase is always the source of truth. It is
  cleared on sign-out.

## Troubleshooting

| Problem | Fix |
|---|---|
| "Almost there" screen | `js/config.js` still has placeholder values. |
| "Unknown address" screen | The page is served from a host that is not in `PRODUCTION_HOSTS` in `js/config.js`. |
| "Could not load your profile or campaigns" | The migrations have not been applied to this project, or the frontend points at another project. |
| Sign-in returns to the wrong page | The Pages URL is missing from Supabase **Redirect URLs**. |
| Empty catalog (no items, spells or classes) | The one-time catalog import has not been run on this project. |
