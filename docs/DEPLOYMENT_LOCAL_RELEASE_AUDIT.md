# Deployment: local release audit (Phase A, 2026-10-23)

Local inspection only. Nothing was staged, committed, reset or pushed.

## Repository

| Item | Value |
|---|---|
| Root | `<repository folder>` |
| Branch | `main` |
| HEAD | `849d7f10d4b8e436b1cee182fd4b3be77aed2a32` ("Keep character files local: stop tracking examples/"); 10 commits in total |
| Remote | `origin` → `https://github.com/alexandrajuscak/tavern_ledger.git` (**public** repository) |
| Tracked files | **17**: the legacy app (`index.html`, `css/styles.css`, 9 files in `js/`, `supabase/schema.sql`, `docs/DATA_MODEL.md`, `docs/character.schema.json`, `README.md`, `.gitignore`, `.nojekyll`) |
| Modified tracked files | 14 (5,949 insertions, 710 deletions) |
| Untracked | 159 top-level entries = **1,526 files** (all of V1–V6.2: migrations, seeds, tests, 41 new JS modules, fonts, icons, vendor, docs, data pipeline) |
| Staged | none |
| `git diff --check` | clean (0 lines) |

**Consequence:** the deployed app (HEAD) is the legacy single-schema version. Every V1–V6.2 change exists only in this
working copy and its local backups. A release therefore needs a deliberate first commit of the release file set
(docs/DEPLOYMENT_FILE_MANIFEST.md). It is the first time this work becomes public, because the repository is public.

## Database artefacts

| Item | Count | Notes |
|---|---|---|
| Migrations `supabase/migrations/2*.sql` | **41** | `20261015000000_base_schema` … `20261023000100_v62_hardening` |
| Rollback scripts `supabase/rollback/*.sql` | **28** | Some cover several migrations. The pairing is enforced by `run_supabase_local.sh` (CATALOG_RB count check) and was exercised by `run_local.sh` (exit 0). |
| Catalog seeds `supabase/seed/*.sql` | **9** | reference_data, item_effects, spells, classes, class_features, creatures, lineages, feats, backgrounds (docs/DEPLOYMENT_PRODUCTION_SEEDS.md) |
| Demo / fixture seeders | separate | `scripts/local/seed_local_demo.py`, `scripts/seed-local-demo.ps1` (local only; **never** remote) |
| Legacy schema | `supabase/schema.sql` (tracked) | What production runs today (11 tables) |

`supabase/config.toml` `[db.seed]` lists only the 9 catalog seeds. They run only on `supabase db reset` (local); a remote
`db push` does not run seeds unless `--include-seed` is passed.

## Frontend artefacts (sizes)

| Folder | Files | Size |
|---|---|---|
| `js/` | 41 (40 modules + the ignored `config.local.js`) | 1.0 MB |
| `css/` | 2 | 0.2 MB |
| `assets/` (icons, WebP) | 204 | 1.0 MB |
| `fonts/` | 9 | 0.3 MB |
| `vendor/` (supabase-js 2.117.2 UMD + MIT licence) | 2 | 0.2 MB |

Asset check: all 44 frontend files were scanned. Every relative reference resolves; there are no absolute `/…` paths (so
the GitHub Pages `/tavern_ledger/` subpath works) and no external URLs. The 3 hits for `form` in `css/styles.css` are a
false positive of the scanner. Icons load from the relative base `assets/icons`.

## Configuration

- `js/config.js` (tracked): the hosted project URL `https://pfgz…wlsc.supabase.co` and a `sb_publishable_…` key. These
  are browser-safe values by design.
- `js/config.local.js` (git-ignored): the local URL and local anon key, written by `scripts/start-local.ps1`.
- `js/supabase.js`: on `localhost` / `127.0.0.1` the app uses **only** the local stack (no fallback to hosted). On any
  other host it uses `js/config.js`. It refuses `sb_secret_…` and `service_role` keys at start-up.
- **Gap:** there is no explicit staging/production selection yet. Any non-local host uses the one hosted project in
  `js/config.js` (docs/DEPLOYMENT_FRONTEND_CONFIGURATION.md).

## Secret findings

No real privileged secret in the working-tree release set or in Git history. Details are in
docs/DEPLOYMENT_SECRET_AUDIT.md.

## Release blockers found in Phase A

| # | Blocker | Type |
|---|---|---|
| A1 | The repository is public and Pages publishes the `main` root. Every committed file becomes downloadable from `alexandrajuscak.github.io/tavern_ledger/…`. Rules-derived catalog seeds (3.2 MB, non-SRD sources, wikidot links) and the `data/` pipeline (31 MB of page caches) must not be committed as they are. | publication / licensing decision |
| A2 | Icon licences are unknown (docs/ICON_ASSET_INVENTORY.md). | licensing (risk for a private table, blocker for a promoted release) |
| A3 | No staging/production selection in the frontend configuration. | code (small, local) |
| A4 | `data/raw/feats_html`, `data/raw/backgrounds_html` and `data/raw/creatures_srd` are **not** git-ignored, unlike `spells_html` / `classes_html`. | `.gitignore` gap |
| A5 | All V1–V6.2 work is uncommitted. The first release commit needs an approved file set and message. | process |
| A6 | Production runs the legacy schema; the 41 migrations have never been applied remotely. | expected (strategy) |
