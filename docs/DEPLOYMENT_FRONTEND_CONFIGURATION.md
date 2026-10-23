# Deployment: frontend environment configuration (2026-10-23)

The static frontend has no build step. The environment is chosen by **where the page is served from**, never by a fallback
(`js/supabase.js`):

| Served from | Environment | Configuration | Contains |
|---|---|---|---|
| `localhost` / `127.0.0.1` | `local` | `js/config.local.js` (git-ignored, written by `scripts/start-local.ps1`) or the test override in `localStorage` (accepted only for `http://127.0.0.1|localhost:<port>`) | local URL and local anon key |
| `localhost` / `127.0.0.1` with `?env=staging` | `staging` | `js/config.staging.js` (**git-ignored**, created by hand) | `STAGING_SUPABASE_URL` (`https://<ref>.supabase.co`) and `STAGING_SUPABASE_PUBLISHABLE_KEY` |
| a host in `PRODUCTION_HOSTS` (`alexandrajuscak.github.io`) | `production` | `js/config.js` (tracked, deployed) | `SUPABASE_URL` and `SUPABASE_PUBLISHABLE_KEY` |
| any other host | `unknown-host` | none: "Unknown address", no connection | – |

Guarantees (tested by `supabase/tests/browser/deployment_environment_test.py`, 13 checks, registered in
`run_browser_local.sh`):

- A local origin never contacts a hosted project, and there is no hosted fallback when the local configuration is
  missing (L1, L2).
- Staging is reachable **only** from a local origin, and only when the ignored file exists. Without the file the page says
  "Staging is not configured" and connects to nothing (S1). With the file it talks only to the staging project and shows a
  red **STAGING** banner and title on every screen (S2, S3).
- On the production host, `?env=staging` is ignored. The page talks only to the project in `js/config.js`, never to
  localhost or staging (P1–P3).
- Any other host, such as a mirror or a fork's Pages site, connects to nothing (U1).
- Keys are checked at start-up in every environment:
  - `sb_secret_…` and `service_role` JWTs are refused (existing blocklist);
  - since 2026-10-23 there is also an **allowlist**: only an `sb_publishable_…` key or a JWT with role `anon` is
    accepted, so an access token or an unknown secret format is refused too (K3).
- Static checks of the committable files (K1, K2):
  - `index.html` and every `js/*.js` except the two ignored configs contain no secret key, `service_role` JWT, access
    token, private key or database URL with a password;
  - `js/config.js` holds only a `https://<ref>.supabase.co` URL (or the placeholder) and a publishable key (or the
    placeholder).
- OAuth and magic links return to `origin + pathname`. Staging keeps `?env=staging`, so its links return to staging.

## Files

```js
// js/config.js (tracked; deployed). Browser-safe values only.
export const SUPABASE_ENV = 'production';
export const PRODUCTION_HOSTS = ['alexandrajuscak.github.io'];
export const SUPABASE_URL = 'https://<production-ref>.supabase.co';
export const SUPABASE_PUBLISHABLE_KEY = 'sb_publishable_…';

// js/config.staging.js (git-ignored; this machine only)
export const STAGING_SUPABASE_URL = 'https://<staging-ref>.supabase.co';
export const STAGING_SUPABASE_PUBLISHABLE_KEY = 'sb_publishable_…';
```

**Since cleanup C4 (2026-10-23), `js/config.js` holds placeholders** (`https://YOUR-PROJECT-REF.supabase.co`,
`sb_publishable_YOUR-KEY`). The old project's values were removed from the working copy; they remain in commit `849d7f1`,
which is the rollback. With placeholders, the production host shows the "Almost there" setup screen and connects to
nothing (P1), so an early push can never connect the V6.2 app to the legacy database. The release commit replaces the
two placeholders with the **new production** project's URL and publishable key. That is a deliberate two-line change,
made only after approval.

## Using staging

1. Create `js/config.staging.js` as above. Use the staging project's **publishable** key from Dashboard → Project
   Settings → API Keys, never the secret key.
2. Serve the working copy: `python scripts/local/serve_frontend.py . 5191`.
3. Open `http://127.0.0.1:5191/?env=staging`. The red STAGING banner confirms the target.
4. In the staging project's Auth settings, add the redirect URL `http://127.0.0.1:5191/?env=staging`
   (docs/DEPLOYMENT_PRODUCTION_RUNBOOK.md, Auth URLs).
