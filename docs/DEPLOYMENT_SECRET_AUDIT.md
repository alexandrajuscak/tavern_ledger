# Deployment: secret audit (Phase A, 2026-10-23)

Nothing in this document is a usable secret: values are masked to their first characters.

## Method

- **Working tree:** recursive grep, excluding `.tools/`, `data/raw/` and `__pycache__`. Patterns covered:
  - JWTs (`eyJ….…`), `sb_secret_`, `sb_publishable_`, `sbp_` (Supabase access tokens);
  - `service_role` / `SERVICE_ROLE_KEY`, `JWT_SECRET`, `SMTP_PASS`;
  - GitHub tokens (`ghp_`/`gho_`/`ghu_`/`ghs_`/`ghr_`, `github_pat_`), private-key headers, AWS keys;
  - `postgres://user:password@` URLs.
- **Files by name:** `.env*`, `*.dump`, `*.pem`, `*.key`, `*access-token*` (none in the repository).
- **Git history:** `git log --all -p` over all 10 commits, with the same patterns.

## Findings

| Location | Finding (masked) | Classification | Action |
|---|---|---|---|
| `js/config.js` (tracked, deployed) | `sb_publishable_8pUE…` | **safe public browser value** (publishable key, protected by RLS) | keep; it identifies the *current* production project |
| `js/config.local.js` (git-ignored) | `eyJhbGciOi…` (iss `supabase-demo`, role `anon`) | local test value (the standard local Supabase anon key) | must never deploy; already ignored |
| `supabase/.temp/start-secrets/…/docker.env` (ignored via `supabase/.gitignore`) | local anon and service-role JWTs, `sb_secret_N7…`, `JWT_SECRET`, `postgresql://postgres:***@` | **local test values** of the Supabase CLI stack (well-known local defaults; not valid for any hosted project) | must never deploy; already ignored |
| `docs/LOCAL_DEVELOPMENT.md` | `postgresql://postgres:***@127.0.0.1:54322/postgres` | local test value (documented local default) | acceptable; local only |
| `js/supabase.js`, `scripts/local/*`, `scripts/seed-local-demo.ps1`, `supabase/config.toml`, `supabase/tests/**`, docs | the words `service_role` / `SERVICE_ROLE_KEY` | **false positive**: variable names, comments and the start-up guard that refuses privileged keys | none |
| Git history (`79032fa`, `e048ac0`) | the text `sb_secret_...` in a warning comment / README | **false positive** (documentation) | none |
| Git history | `sb_publishable_8pUE…` | safe public browser value | none |

**Result:** there are no real privileged secrets in tracked files, in the release candidate set or in Git history.
**Nothing needs rotation.** There is no Git-history remediation to do, and the secret gate does **not** block deployment.

## Rules for the deployment phases

- The production service-role / secret key and the database password are needed only for the backup and export phase
  and for applying migrations. They are entered by the user as environment variables in their own shell (for example
  `$env:SUPABASE_ACCESS_TOKEN`, `$env:PGPASSWORD`) or in an interactive prompt. They are never written to a file in the
  repository, never echoed, and never placed in `js/`.
- Do **not** `supabase link` inside this repository folder without care. Linking writes `supabase/.temp/project-ref`, and
  the local test runners abort when that file exists (a safety feature). Linking also makes remote targets the CLI
  default. Prefer an explicit `--db-url` / `--project-ref`, run from a separate working folder.
- A pre-commit check (`git diff --cached` grep with the patterns above) is part of the release runbook
  (docs/DEPLOYMENT_PRODUCTION_RUNBOOK.md).
