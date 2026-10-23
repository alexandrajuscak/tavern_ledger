# Deployment: production runbook (Strategy A: a new project)

> **Superseded (2026-10-23):** production is upgraded **in place** (existing project, accounts and Google sign-in kept). Follow [DEPLOYMENT_INPLACE_UPGRADE_RUNBOOK.md](DEPLOYMENT_INPLACE_UPGRADE_RUNBOOK.md). This document describes the earlier new-project plan and is kept for reference (its seed, Auth and frontend details still apply).

**Nothing in this runbook runs before the exact approval phrase `PROCEED WITH PRODUCTION DEPLOYMENT`.** Staging uses the
same steps against the staging project, after `PROCEED WITH STAGING REHEARSAL`. Placeholders: `<ref>` is the project ref,
`<region>` the pooler region. Passwords and keys are typed at a prompt, never written into a file or a command line in
history.

## 0. Pre-flight (read-only; repeated immediately before execution)

1. The old project is unchanged since the export: the inventory query counts equal the manifest.
2. The export manifest is all valid and `SHA256SUMS.txt` verifies; the recovery package hashes verify.
3. `git status` shows only the reviewed release file set; the pre-commit secret grep is clean (step 6).
4. The local suites are green: `run_local.sh` and `run_browser_local.sh` (`PORT=5191`), plus the staging sign-off.
5. The target project is **empty**: 0 tables in `public`, 0 users (step 2 check).

## 1. Create the project (Dashboard, by the user)

New project `tavern-ledger-prod`. Choose the region close to the players. Use a **generated** database password and keep it
in the password manager. Record the masked ref and the region in docs/DEPLOYMENT_FINAL_HANDOVER.md.

## 2. Database: migrations (from this machine)

```powershell
$pw = Read-Host 'New production DB password' -AsSecureString
$env:SUPABASE_DB_URL = "postgresql://postgres.<ref>:" + [Net.NetworkCredential]::new('', $pw).Password + "@aws-0-<region>.pooler.supabase.com:5432/postgres"
# empty-target check (expect 0 / 0)
$env:DBURL = $env:SUPABASE_DB_URL
docker run --rm -e DBURL postgres:17 sh -c 'psql "$DBURL" -At -c "select count(*) from information_schema.tables where table_schema=''public''" -c "select count(*) from auth.users"'
# dry run, then apply (records supabase_migrations.schema_migrations; does NOT run seeds)
..\.tools\supabase-2.118.0\supabase.exe db push --db-url $env:SUPABASE_DB_URL --dry-run
..\.tools\supabase-2.118.0\supabase.exe db push --db-url $env:SUPABASE_DB_URL
```

Expected: 41 migrations applied, in order, without errors. (`db push --db-url` takes the URL as an argument, so the
password is visible in the local process list while the command runs. It is not written to shell history, because it
comes from the variable.) Stop on the first error (rollback runbook R2). `--db-url` avoids
`supabase link`, which would write `supabase/.temp/project-ref` into the repository.

## 3. Database: catalog seeds (exactly once, empty catalog)

```powershell
$env:DBURL = $env:SUPABASE_DB_URL
foreach ($s in 'reference_data','item_effects','spells','classes','class_features','creatures','lineages','feats','backgrounds') {
  # the connection string reaches the container as an environment variable, never as a command-line argument
  docker run --rm -e DBURL -e SEED=$s -v "${PWD}\supabase\seed:/seed:ro" postgres:17 `
    sh -c 'psql "$DBURL" -v ON_ERROR_STOP=1 -q -f "/seed/$SEED.sql"'
  if ($LASTEXITCODE) { throw "seed $s failed" }
}
```

Expected counts (docs/DEPLOYMENT_PRODUCTION_SEEDS.md):

| items | spell_versions | class_versions | subclass_versions | class_feature_versions | creatures | lineage_versions | feat_versions | background_versions | source_books |
|---|---|---|---|---|---|---|---|---|---|
| 1,146 | 574 | 13 | 118 | 246 | 334 | 133 | 408 | 30 | 58 |

Then run `supabase/tests/catalog_integrity_report.sql` (read only; all 0), plus these checks:
- RLS on every public table;
- SECURITY DEFINER functions pinned;
- 0 users, characters, campaigns and DM content;
- the `supabase_realtime` publication.

The queries are the same as the clean-build check. Finish with `Remove-Item Env:SUPABASE_DB_URL, Env:DBURL`.

**Never** run `scripts/local/seed_local_demo.py`, `scripts/seed-local-demo.ps1` or anything in `supabase/tests/` against
this database.

## 4. Auth configuration (Dashboard → Authentication)

| Setting | Production | Staging |
|---|---|---|
| Site URL | `https://alexandrajuscak.github.io/tavern_ledger/` | `http://127.0.0.1:5191/?env=staging` |
| Redirect URLs (exact, no wildcards) | `https://alexandrajuscak.github.io/tavern_ledger/` | `http://127.0.0.1:5191/?env=staging` |
| Local development URLs | **not** listed in production | – |
| Email provider | on; confirm email **on** | on |
| Google provider | on if wanted (the user enters the client ID / secret in the Dashboard; callback `https://<ref>.supabase.co/auth/v1/callback`) | optional |
| Public sign-up | on only while the table's accounts are created, then **off** | off (users created in the Dashboard) |
| SMTP | custom sender recommended (the default mailer is rate-limited) | default |
| Password reset / confirmation / invite redirect | the Site URL above | the Site URL above |

The DM account: sign up (or invite), confirm, then once in the SQL editor:
`update public.profiles set role = 'admin' where email = '<dm e-mail>';`
Use a strong unique password, and enable Dashboard MFA for the project owner.

## 5. Frontend: configuration

`js/config.js`: replace `SUPABASE_URL` with `https://<new-ref>.supabase.co` and `SUPABASE_PUBLISHABLE_KEY` with the **new**
project's publishable key (Dashboard → Project Settings → API Keys). Keep `PRODUCTION_HOSTS = ['alexandrajuscak.github.io']`.

## 6. Frontend: release commit (separate explicit approval of the file set and message)

```bash
git add <the reviewed file set: docs/DEPLOYMENT_FILE_MANIFEST.md groups 1, 2 (+4, 5 if chosen) and .gitignore>
git diff --cached --name-only | wc -l                    # equals the reviewed count
git diff --cached | grep -E 'eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}|sb_secret_|gh[pousr]_[A-Za-z0-9]{20,}|PRIVATE KEY|sbp_[A-Za-z0-9]{20}|postgres(ql)?://[^:@/ ]+:[^@/ ]+@'   # must print nothing
git diff --cached --name-only | grep -E '^(data/|supabase/seed/|examples/)|config\.(local|staging)\.js|\.dump$|\.png$'                         # must print nothing
git commit -m "<approved message>"
git push origin main
gh run list --repo alexandrajuscak/tavern_ledger --workflow pages-build-deployment --limit 1
```

Push credentials for github.com are entered by the user. `gh` is currently signed in only to an enterprise host.

## 7. Verification after the push

- `curl -s https://alexandrajuscak.github.io/tavern_ledger/js/config.js` shows the new project ref.
- `vendor/supabase-js/supabase-2.117.2.umd.js` and `js/inventory-api.js` answer 200.
- docs/DEPLOYMENT_PRODUCTION_SMOKE_RESULTS.md: the smoke test (player, DM, security, Realtime, network).
- Post-deploy logical backup (same `pg_dump` as the recovery package, against the new project), with its SHA-256.

## 8. Phase G: campaigns, users, pilot, remaining characters

See docs/DEPLOYMENT_CHARACTER_REIMPORT_PLAN.md (pilot first; bulk only after approval).
