# Deployment: release file manifest (Phase A, 2026-10-23)

The repository `alexandrajuscak/tavern_ledger` is **public**, and GitHub Pages publishes the **root of `main`** (legacy
branch build). So "commit" here means "publish to the internet": every committed file can be downloaded as
`https://alexandrajuscak.github.io/tavern_ledger/<path>`. Nothing was staged or committed in this phase.

## 1. Production required (served by Pages)

| Path | Notes |
|---|---|
| `index.html`, `.nojekyll` | entry point; `.nojekyll` keeps Pages from running Jekyll |
| `css/styles.css`, `css/fonts.css` | |
| `js/*.js`: the 40 modules, **not** `js/config.local.js` | `js/config.js` must hold the production URL and publishable key (docs/DEPLOYMENT_FRONTEND_CONFIGURATION.md) |
| `vendor/supabase-js/supabase-2.117.2.umd.js`, `vendor/supabase-js/LICENSE` | MIT; no CDN at runtime |
| `fonts/*` (Inter, Cinzel, Alegreya + OFL texts) | SIL OFL 1.1 |
| `assets/icons/**` (204 WebP) | **licences unknown**: accepted risk for a private table only (licensing gate) |

## 2. Database code (needed to deploy; harmless to publish)

| Path | Notes |
|---|---|
| `supabase/migrations/*.sql` (41) + `README.md` | schema, RLS, functions; 3 incidental source links, no catalog content |
| `supabase/rollback/*.sql` (28) | |
| `supabase/config.toml` | local stack configuration (local URLs only; no secrets) |

## 3. Licensing review required before publishing (keep local / private for now)

| Path | Why |
|---|---|
| `supabase/seed/*.sql` (9, 3.2 MB) | Structured rules data from the PHB, XGE, TCE, 2024 PHB and others (non-SRD), with names, mechanics, components and wikidot / fandom / dnd5eapi source links. Needed **in the database**, but not in a public repository or on Pages. They can be applied to Supabase directly from this machine. |
| `data/normalized/**`, `data/reports/**` (non-private), `data/*/` pipeline outputs | derived from the same sources |
| `scripts/data-migration/*` (fetch / extract scripts) | scraping tools for those sites; publishing them is a separate decision |

## 4. Local only (fine to keep untracked; harmless if published)

`start-local.bat`, `stop-local.bat`, `status-local.bat`, `reset-local.bat`, `scripts/*.ps1`, `scripts/local/*`
(the local server, demo seeder, icon tools). The demo seeder **must never be run against a hosted project**.

## 5. Test only (optional to publish; harmless code)

`supabase/tests/**` (SQL suites, API tests, browser suites, the isolation harness, the integrity report). Fixtures are
synthetic. Exclude `supabase/tests/browser/derived-desktop.png` (a test screenshot) and `__pycache__/`.

## 6. Must never deploy or commit

| Path / pattern | Status in `.gitignore` |
|---|---|
| `js/config.local.js` | ignored ✔ |
| `supabase/.temp/**` (local stack secrets, `project-ref`) | ignored ✔ (`supabase/.gitignore`) |
| `.env*`, `*.dump`, `*.backup`, `dumps/`, `.tools/` | ignored ✔ |
| `examples/`, `*.character.json` (real campaign characters) | ignored ✔ |
| `data/reports/private/` | ignored ✔ |
| `data/raw/spells_html/`, `data/raw/classes_html/` | ignored ✔ |
| `data/raw/` (all page caches and source snapshots) | ignored ✔ (added 2026-10-23) |
| `desktop.png`, `legacy.png`, `mobile.png` (root) | ignored ✔ |
| `supabase/tests/browser/*.png` | ignored ✔ (added 2026-10-23) |
| `.local/`, `*.log`, `__pycache__/` | ignored ✔ |
| Backups, fingerprints, mutation journals, screenshots, character exports | outside the repository (`%USERPROFILE%\tavern-ledger-local-backups\`, `…\tavern-ledger-production-exports\`) ✔ |

`.gitignore` gained `data/raw/`, `supabase/tests/browser/*.png` and `js/config.staging.js` (2026-10-23). Nothing was
staged or committed.

## Publication alternatives (decision for the user; see the pre-production report)

1. **Commit groups 1 + 2** (and optionally 4 and 5) to the public `main`, and keep group 3 local. This is the smallest
   change and keeps Pages as it is. The seeds are applied to the database from this machine.
2. **Make the source repository private** and publish only group 1 from a separate public Pages repository or an Actions
   artefact. Pages on a private repository needs a paid GitHub plan.
3. Publish everything. **Not recommended** (licensing of group 3).
