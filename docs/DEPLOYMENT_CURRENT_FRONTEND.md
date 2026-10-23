# Deployment: current production frontend (Phase B, read-only, 2026-10-23)

Method:
- static file download with `curl`, so no JavaScript was executed and no request reached the hosted Supabase;
- `gh api` for the public, read-only repository and Pages metadata.

Nothing was deployed, pushed or changed.

| Item | Value | Status |
|---|---|---|
| Repository | `alexandrajuscak/tavern_ledger`, **public**, default branch `main` | KNOWN |
| Remote URL | `https://github.com/alexandrajuscak/tavern_ledger.git` | KNOWN |
| Pages build type | `legacy` (branch build, workflow `pages-build-deployment`) | KNOWN |
| Pages source | branch `main`, folder `/` (repository root) | KNOWN |
| Public URL | `https://alexandrajuscak.github.io/tavern_ledger/` (HTTPS enforced, no custom domain) | KNOWN |
| Last modified | `Wed, 14 Oct 2026 12:26:47 GMT` (ETag `"6acf7507-62f"`) | KNOWN |
| Deployed revision | **HEAD `849d7f1`**: `index.html`, `js/config.js`, `js/supabase.js`, `js/app.js` and `css/styles.css` are byte-identical (CRLF-normalised SHA-256) to `git show HEAD:<file>` | KNOWN |
| New V1–V6.2 code on the live site | none: `js/inventory-api.js` and `vendor/supabase-js/…` answer 404 | KNOWN |
| Supabase project used | `https://pfgz…wlsc.supabase.co` with `sb_publishable_8pUE…` | KNOWN |
| supabase-js | loaded from **jsDelivr** (`@supabase/supabase-js@2.117.2/+esm`) | KNOWN (legacy) |
| Subpath handling | relative paths only; OAuth / magic-link redirect = `origin + pathname` | KNOWN |
| GitHub account for pushing | `gh` on the operator machine is signed in only to a GitHub Enterprise host, **not** to github.com as `alexandrajuscak` | REQUIRES USER INPUT (push credentials at deploy time) |

## Rollback point for the frontend

The previous production frontend is commit **`849d7f1`** on `main`. Reverting the release commit (or force-moving `main`
back, which is not recommended) restores it. Pages redeploys automatically on every push to `main`.

## Notes

- The legacy frontend reads and writes the legacy 11-table schema. Once the database moves to the 41-migration schema,
  the old frontend will **not** work against it, and vice versa. Frontend and database must switch together, or the new
  frontend must point to a new project (docs/DEPLOYMENT_REBUILD_STRATEGY.md).
