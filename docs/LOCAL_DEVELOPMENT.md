# Local development

Run the whole of Tavern Ledger on your own computer: the database, Auth, API, Realtime and Studio run in Docker,
and the app runs on `http://127.0.0.1:5173/`. Nothing here connects to the hosted Supabase project.

You don't need to remember Supabase CLI commands. Four scripts do everything:

| What | Double-click | Or, in PowerShell in the repository folder |
|---|---|---|
| Start | `start-local.bat` | `.\scripts\start-local.ps1` |
| Stop (keeps data) | `stop-local.bat` | `.\scripts\stop-local.ps1` |
| Status | `status-local.bat` | `.\scripts\status-local.ps1` |
| Clean reset (**deletes local data**) | `reset-local.bat` | `.\scripts\reset-local.ps1` |
| Demo accounts + items (optional) | | `.\scripts\seed-local-demo.ps1` |

## Requirements

- **Docker Desktop** for Windows. It must be running ("Engine running") before you start.
- **PowerShell**. Windows PowerShell 5.1 (built in) or PowerShell 7 both work. You don't need Administrator rights.
- **Python 3** (`python` on PATH). It serves the frontend. Only the standard library is used.
- **Supabase CLI 2.118.0** at `..\.tools\supabase-2.118.0\supabase.exe`, next to the repository folder:
  `<parent folder of the repository>\.tools\supabase-2.118.0\supabase.exe`.
  Another location works if you set the `SUPABASE_CLI` environment variable to the full path of `supabase.exe`.

## First-time setup

1. Start Docker Desktop and wait until it shows **Engine running**.
2. Double-click `start-local.bat` (or run `.\scripts\start-local.ps1`).
3. Wait. The first start creates the local database and applies all 18 migrations and the five seed files
   (`reference_data.sql`: 1,146 catalog items; `item_effects.sql`: permanent magic item effects; `spells.sql`: 574 spell versions,
   9 class spell lists; `classes.sql`: 12 classes, their level tables and slot progressions; `class_features.sql`: subclass levels, no class
   features yet; `lineages.sql`: 47 lineages).
   Order matters: spells, then classes, then lineages. This takes a few minutes, longer if Docker has to download images. Later starts take
   under a minute.
4. Tavern Ledger opens at `http://127.0.0.1:5173/`.
5. Create a local account: type an email such as `local-player@example.test` and any password of 6+ characters,
   then click **Create account**. You're signed in immediately.
   Or run `.\scripts\seed-local-demo.ps1` once to get ready-made demo accounts (see [Local login](#local-login)).

## Start

```powershell
.\scripts\start-local.ps1
```

Or double-click `start-local.bat`. It also opens the browser and keeps its window open so you can read the URLs.

The start script:

- checks that the folder isn't linked to a hosted project, that Docker Desktop is running, and that the
  Supabase CLI and Python are present;
- starts the local Supabase stack, or reuses it if it's already running. It never resets the database;
- waits until the local API answers, then prints the migration count, the catalog count and the number of local accounts;
- writes `js/config.local.js`, which holds the local API URL and the standard local *anon* key. The file is
  git-ignored and is never deployed;
- starts the frontend server on `127.0.0.1:5173` only, or reuses it, and stores its PID in `.local/frontend.json`.

If you added a new migration file, `.\scripts\start-local.ps1 -ApplyMigrations` applies it to your existing local
database and keeps your data.

## Stop

```powershell
.\scripts\stop-local.ps1
```

This stops the frontend server that start-local started and this project's Supabase containers. Nothing else is
stopped: other Docker containers keep running. The **local data is preserved** because the Docker volumes are kept.
It's safe to run when everything is already stopped.

## Reset (deletes LOCAL data)

```powershell
.\scripts\reset-local.ps1
```

> **Warning:** this deletes **all local** Tavern Ledger data on this computer: local accounts, characters,
> inventories, homebrew and demo data. The hosted Supabase project is **not** affected.

The reset script asks you to type `RESET`. Anything else cancels. It runs `supabase db reset --local`, which re-applies
all migrations and the five seed files, then checks that every migration file was applied and 1,146 catalog items are present.
`.\scripts\reset-local.ps1 -Force` skips the question. Afterwards, sign out in the browser (your old session no
longer exists) and create your account again, or run `seed-local-demo.ps1`.

## Status

```powershell
.\scripts\status-local.ps1
```

This is read-only. It shows whether Docker, local Supabase, the API, Studio, Mailpit and the frontend server are
running. It also shows stale PID files, migrations, the catalog count, and the number of local accounts and characters.

## Verified local addresses

| Service | URL |
|---|---|
| Tavern Ledger | http://127.0.0.1:5173/ |
| Supabase Studio (tables, SQL editor, Auth users) | http://127.0.0.1:54323 |
| Local API (Auth, PostgREST, Realtime, Storage) | http://127.0.0.1:54321 |
| Local email (Mailpit) | http://127.0.0.1:54324 |
| Local Postgres | `postgresql://postgres:postgres@127.0.0.1:54322/postgres` |

These ports come from `supabase/config.toml`. The frontend port 5173 is the same one the browser tests use.

Always open the app at the same address. A browser session is stored per address, so a sign-in on `127.0.0.1` is
separate from one on `localhost`.

## Local login

- **Your own account:** on the sign-in screen, type any email and a 6+ character password, then click
  **Create account**. Local email confirmation is **off** (`[auth.email] enable_confirmations = false` in
  `supabase/config.toml`, which only affects the local stack), so you're signed in right away. Use made-up addresses
  such as `you@example.test`.
- **Magic links:** "Email me a sign-in link" sends nothing to the internet. The email lands in Mailpit at
  http://127.0.0.1:54324. Open it there and click the link.
- **Demo data** (optional, synthetic, local only): run `.\scripts\seed-local-demo.ps1`. It creates two accounts:

  | Account | Password | Role |
  |---|---|---|
  | `local-player@example.test` | `local-dev-password` | player in "Local Demo Campaign", owns the demo characters |
  | `local-dm@example.test` | `local-dev-password` | DM of "Local Demo Campaign" |

  It also creates nine demo characters (Local Hero, Local Sidekick, Local Spellcaster, Local Wizard, Local Artificer,
  Local Paladin, Local Warlock, Local Multiclass), a private and a campaign homebrew item. What each one is for and the
  values you should see are in [LOCAL_TEST_CHARACTERS.md](LOCAL_TEST_CHARACTERS.md).
  Demo characters have stable ids. Running the seeder again creates only what is missing and leaves existing demo
  characters exactly as you changed them. `-Repair` resets the nine demo characters to their documented state. The ninth, Local Feature Tester, uses the
  SYNTHETIC Engine Test Class from `supabase/tests/fixtures/class_feature_engine_fixture.sql`, which the script loads
  first (test content, shown as "Test fixture"; never part of the seeds).
  Characters you created yourself, or with the same name but not made by the seeder, are never touched.
- **After a restart** you're usually still signed in. If not, sign in with the same email and password. Accounts
  live in the local database, which stop and start keep.
- **Admin:** to try the admin screens, open Studio, then **SQL Editor**, and run
  `update public.profiles set role = 'admin' where email = 'local-dm@example.test';`.

## Manual testing after feature development

1. Start Docker Desktop, then `start-local.bat` (or `.\scripts\start-local.ps1`). After pulling new migrations use
   `.\scripts\start-local.ps1 -ApplyMigrations`: it applies them and reloads the idempotent reference seeds if the catalog
   is incomplete (local data is kept).
2. `.\scripts\seed-local-demo.ps1` (once; again with `-Repair` to reset the demo characters).
3. Open http://127.0.0.1:5173/ and sign in as `local-player@example.test` / `local-dev-password` (local only).
4. Follow [LOCAL_MANUAL_TESTING.md](LOCAL_MANUAL_TESTING.md); expected values are in
   [LOCAL_TEST_CHARACTERS.md](LOCAL_TEST_CHARACTERS.md).
5. `.\scripts\status-local.ps1` shows services, migrations, the catalog counts (compared with `data/reports/*_seed_summary.json`)
   and whether the 9 demo characters exist.
6. `stop-local.bat` when done. Local data is kept.

- **Wild Shape**: the demo seeder adds eight `Wild Shape ...` Druid characters (Druid 2 / 4 / 8, Moon 2 / 6 / 10, Druid 20,
  Fighter 3 / Druid 4), each showing one part of the rules (see [LOCAL_TEST_CHARACTERS.md](LOCAL_TEST_CHARACTERS.md)). The
  focused checks are `supabase/tests/browser/wild_shape_ui_test.py` and `supabase/tests/api/wild_shape_api_test.py`.
- **Reset**: `reset-local.bat` deletes all local accounts and characters. Use it only for a broken or very old local
  database, then run the demo seeder again.
- **The complete automated runners** (`supabase/tests/run_supabase_local.sh`, `run_browser_local.sh`) start from an
  empty local volume and leave test data behind. Back up first (`docker exec supabase_db_tavern_ledger pg_dump -U
  supabase_admin -d postgres -Fc ...`) and restore afterwards, or run `reset-local` + the demo seeder. For a quick check of
  the demo data use the focused smoke test instead: `supabase/tests/browser/local_demo_smoke_test.py` (23 checks; then
  `seed-local-demo.ps1 -Repair`).
- **Local-only traffic**: in the browser's developer tools (Network) requests go only to `127.0.0.1` (plus the supabase-js
  CDN and Google Fonts). On localhost the app never falls back to the hosted project, and it refuses a service_role key.
- **Backups** made during development are in `%USERPROFILE%\tavern-ledger-local-backups` (outside Git).

## Normal daily workflow

1. Start Docker Desktop.
2. Double-click `start-local.bat`.
3. Tavern Ledger opens at http://127.0.0.1:5173/.
4. Develop and test. Edited JS and CSS take effect on reload because the local server sends `Cache-Control: no-store`.
5. Double-click `stop-local.bat` when you're done.
6. Next time, your local accounts and data are still there.

## Data persistence

- **stop-local** stops the containers and keeps the database volume.
- **start-local** reuses that volume. It doesn't reset anything and doesn't re-create demo data.
- **reset-local** deletes the local database and rebuilds it from migrations and the seed.
- **start-local -ApplyMigrations** applies new migration files but does **not** re-run the seed files. After pulling a
  change to `supabase/seed/item_effects.sql`, `supabase/seed/spells.sql`, `supabase/seed/classes.sql` or
  `supabase/seed/lineages.sql` (or a migration that needs them), load the file into the existing database (spells, then
  classes, then lineages), e.g.
  `Get-Content supabase\seed\lineages.sql -Raw | docker exec -i supabase_db_tavern_ledger psql -U postgres -q`
  (idempotent), or use reset-local. The lineage feature needs `lineages.sql` after its migration, otherwise the
  lineage picker is empty; the spell feature needs `spells.sql` and then `lineages.sql` again (to link lineage spells);
  the class level feature needs `classes.sql` (without it the class picker and the slot tables are empty); the class
  feature engine needs `class_features.sql` after `classes.sql` (subclass levels).
- **Warning:** the full automated test runner `supabase/tests/run_supabase_local.sh` starts from an empty volume
  (`supabase stop --no-backup`), so it **wipes your local development data** too. Run it only when you don't need
  that data. `run_browser_local.sh` deletes only its own `ui-*@example.test` users.

## Troubleshooting

| Problem | What to do |
|---|---|
| "Docker Desktop is not running" | Start Docker Desktop, wait for **Engine running**, then start again. |
| "Docker Desktop is starting but its engine is not ready yet" | Wait about 30 seconds and try again. |
| "Supabase CLI not found" | Put `supabase.exe` in `..\.tools\supabase-2.118.0\`, or set `SUPABASE_CLI` to its full path. |
| "Port 5173 is already used by …" | Another program, often an old `python -m http.server` from a test run, uses the port. Close it, or end the process the message names, then start again. |
| `supabase start` fails because a port (54321–54324) is in use | Another local Supabase project is running. Stop it with *its own* stop command, or run `stop-local` here, then start again. |
| The app opens but shows "Local Supabase is not configured" | `js/config.local.js` is missing. Run start-local, then reload. |
| The app opens but the API fails | Run `status-local`. If the API isn't responding, run `stop-local`, then `start-local`. |
| You're worried the browser uses the hosted project | It can't on localhost: `js/supabase.js` only uses the local config on `localhost`/`127.0.0.1` and has no fallback to the hosted project. To check, open DevTools → Network: every Supabase request goes to `127.0.0.1:54321`. |
| Old JS or CSS shows up | Hard reload with Ctrl+F5. Old copies can remain from before the no-cache server was used. |
| Signed in as a user who no longer exists (after a reset) | Click **Sign out**, or clear the site data in DevTools → Application. |
| Migration failure on start | Read the error printed above it. Fix the migration file, then run `start-local -ApplyMigrations`, or `reset-local` for a clean rebuild. |
| "reference catalog has N items (expected 1146)" | The seed didn't load completely. Run `reset-local`. |
| Stale PID file | start-local, stop-local and status-local detect it. start-local and stop-local remove it. You can also delete `.local\frontend.json` yourself. |
| Inspect data | Supabase Studio: http://127.0.0.1:54323 (Table Editor, SQL Editor, Authentication). |
| Stop safely | Always use `stop-local`. Don't use `supabase stop --no-backup` (it deletes data) or `docker stop $(docker ps -q)` (it stops everything). |

Logs from the frontend server are in `.local\frontend.log`.

## Safety

- Local development is completely separate from production. The scripts refuse to run if the folder is linked
  to a hosted project (`supabase\.temp\project-ref`). Their CLI wrapper only allows `start`, `stop`, `status`,
  `db reset --local` and `migration up/list --local`. It refuses `link`, `db push`, `--linked`, `--db-url`,
  `stop --no-backup` and `stop --all`.
- `supabase/config.toml` only configures the **local** stack. Its Auth URLs point at `127.0.0.1:5173`. Never run
  `supabase config push`.
- Don't expose the local stack publicly. The frontend server listens on `127.0.0.1` only. The Supabase containers
  are published by Docker Desktop on all network interfaces, so keep the Windows Firewall on and don't forward
  these ports. The local keys are public, well-known defaults.
- Never paste a production service-role or secret key into frontend code. The app refuses to start with one.
- Never commit database dumps, private reports, `.env` files or local secrets. `.gitignore` covers `.local/`,
  `js/config.local.js`, dumps, `.env*`, screenshots and Playwright artifacts.
- Local synthetic data is disposable. Use `@example.test` addresses, never real people's emails.
- Deploying to GitHub Pages or migrating the hosted database is a separate, deliberate operation. These scripts never do it.

## Future: a production-like local copy (not implemented)

If you ever need production-shaped data locally, do it as a separate, reviewed task:

1. Create a read-only dump of the production application tables, using a read-only role.
2. Keep the dump outside the repository, in a folder that git never sees.
3. Exclude Auth tokens, sessions, refresh tokens and identities completely.
4. Anonymize emails, display names and user IDs.
5. Create synthetic local Auth users and map the application rows to them.
6. Import only the application tables you need into the local database.
7. Run the migrations locally on top of that data.
8. Check legacy and homebrew items locally (legacy review, link candidates).
9. Delete the dump afterwards, or keep it encrypted and outside the repository.

## Optional: a desktop shortcut

1. In File Explorer, open the repository folder.
2. Right-click `start-local.bat`, then choose **Show more options → Send to → Desktop (create shortcut)**.
3. Rename the shortcut on the desktop to **Start Tavern Ledger Local**.
4. Optionally, do the same for `stop-local.bat` and name it **Stop Tavern Ledger Local**.

The shortcut keeps working from the OneDrive path, which contains spaces.

## Files

| File | Purpose |
|---|---|
| `start-local.bat`, `stop-local.bat`, `reset-local.bat`, `status-local.bat` | Double-click wrappers. They bypass the execution policy for that one PowerShell process only. |
| `scripts/start-local.ps1`, `stop-local.ps1`, `reset-local.ps1`, `status-local.ps1`, `seed-local-demo.ps1` | The workflows. |
| `scripts/local/common.ps1` | Shared helpers: paths, safety guards, the CLI allow-list. |
| `scripts/local/serve_frontend.py` | Static server: 127.0.0.1 only, no-cache, correct MIME types for ES modules. |
| `scripts/local/seed_local_demo.py` | Synthetic demo data, idempotent. |
| `supabase/tests/browser/local_dev_smoke_test.py` | Focused browser smoke test of this setup (Edge + Playwright). |
| `supabase/tests/browser/local_demo_smoke_test.py` | Smoke test of the demo characters. Since V6 it is deterministic and self-restoring: it snapshots the rows of the demo characters it touches, sets the state it checks, and restores the exact rows afterwards (no `-Repair` needed). |
| `supabase/tests/browser/v6_product_hardening_ui_test.py` | Cross-feature hardening suite (part of `run_browser_local.sh`). |
| `vendor/supabase-js/` | Self-hosted supabase-js 2.117.2 (MIT). The browser makes no external request. |
| `.local/` (git-ignored) | PID file and the frontend log. |
| `js/config.local.js` (git-ignored, generated) | Local API URL and local anon key. |

<!-- 20261019 governance/feats/content -->
## DM governance, feats and the DM Space (20261019)

* The local demo seeder adds four governance campaigns (Relaxed, Standard, Strict, Custom tables) with requests in every
  state, published / draft / archived custom content and feat scenarios (docs/LOCAL_TEST_CHARACTERS.md). Sign in as
  `local-dm@example.test` and open **DM Space** in the header.
* Only DMs author mechanical homebrew now: a fresh local account sees "Ask your DM" in the inventory until it DMs a campaign.
* Tests: `supabase/tests/classes/governance_tests.sql`, `feat_tests.sql`, `dm_content_tests.sql` (class harness),
  `supabase/tests/governance_concurrency_test.sh`, `supabase/tests/api/governance_api_test.py`,
  `supabase/tests/browser/dm_space_ui_test.py`; all registered in the runners.

## Fonts and icons are local files

The app loads its fonts from `fonts/` (Inter, Cinzel and Alegreya, SIL Open Font License, declared in `css/fonts.css`), its
icons from `assets/icons/` (WebP) and, since the V6 hardening pass, the supabase-js client library from
`vendor/supabase-js/supabase-2.117.2.umd.js` (the same version as before, MIT licence in `vendor/supabase-js/LICENSE`, loaded by
`index.html` as a classic script). The browser makes **no external request at all**. Design documentation:
`docs/UI_DESIGN_SYSTEM.md`. To update supabase-js, replace the vendored file with the `dist/umd/supabase.js` of the new version
and change its name in `index.html`.

The browser tests include `supabase/tests/browser/ux_redesign_ui_test.py` (typography, sections, bottom navigation, home
cards, icons, Build, Wild Shape vitals, DM "Needs you"). `run_browser_local.sh` accepts `PORT=…` to serve the app on
another port than 5173. Use that when your own frontend server is running.

## V6.2 hardening (20261023)

* Migration `supabase/migrations/20261023000100_v62_hardening.sql` (rollback `supabase/rollback/rollback_v62_hardening.sql`)
  was applied to the local database on 2026-10-23 and recorded in `supabase_migrations.schema_migrations`. It is additive:
  - functions;
  - the audit read policy;
  - two CHECK constraints (`hp_current >= 0`, non-negative coins), validated against the existing data.

  `supabase db reset` / a fresh `supabase start` applies it like every other migration.
* Validate backend changes with `bash supabase/tests/run_local.sh`. It uses a throwaway `tavern-ledger-pgtest` container
  and runs migrations, all SQL suites, concurrency, rollback and reapply, in about 45 minutes. Do **not** use
  `run_supabase_local.sh` on a database you want to keep: it starts from an empty volume.
* Browser suites: run `PORT=5191 bash supabase/tests/run_browser_local.sh` while your own server uses 5173. To stop a
  running suite, stop the whole process tree (the bash runner, its `python …_test.py` children and `serve_frontend.py`).
  Stopping only the outer shell leaves the runner going.
* The catalog integrity report is read only:
  `docker exec -i supabase_db_tavern_ledger psql -U postgres -qAt < supabase/tests/catalog_integrity_report.sql`
  Every check should be 0. The last line counts old audit rows that are now filtered on read.
