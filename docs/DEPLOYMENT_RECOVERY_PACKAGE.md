# Deployment: recovery package (Phase C)

**Status: NOT STARTED** (it waits for production access). Under Strategy A the old project is never modified. It stays
online, unchanged, as the primary recovery point. The package below is the second, offline copy.

Location: `%USERPROFILE%\tavern-ledger-production-exports\2026-10-23-pre-v62-deployment\` (outside Git).

| Item | How | Status |
|---|---|---|
| Original character exports | legacy app, Bio → Download (docs/DEPLOYMENT_CHARACTER_EXPORT_MANIFEST.md) | pending |
| Converted exports | only if needed | pending |
| Export manifest + `SHA256SUMS.txt` | `scripts/deploy/validate_exports.py` | pending |
| Logical backup, data + schema (`old-prod-full.dump`) | `pg_dump -Fc` over the session pooler, read-only session (see below) | pending |
| Schema-only backup (`old-prod-schema.sql`) | `pg_dump --schema-only` | pending |
| Migration-history export | `select * from supabase_migrations.schema_migrations` (probably absent: legacy schema.sql) | pending |
| Row counts and Auth user count | the inventory query (docs/DEPLOYMENT_EXISTING_DATA_INVENTORY.md) | pending |
| Storage object inventory | `select bucket_id, name, metadata->>'size' from storage.objects` | pending |
| Current frontend revision | commit `849d7f1`; the live files are identical to it (docs/DEPLOYMENT_CURRENT_FRONTEND.md) | KNOWN |
| Previous frontend files | `git archive 849d7f1 -o frontend-849d7f1.zip` | pending (local, safe) |
| Configuration snapshot (masked) | Auth providers, Site URL, redirect URLs, SMTP sender (no secrets) | pending (Dashboard) |
| Restore instructions | docs/DEPLOYMENT_ROLLBACK_RUNBOOK.md | written |
| Package manifest | `PACKAGE.sha256` over every file above, then verified | pending |

## Logical backup command (the user runs it; the password never touches a file)

In the user's own PowerShell window (the `!` prefix in Claude Code runs it in this session, but **typing the password at
the prompt keeps it out of the transcript**):

```powershell
$env:PGPASSWORD = Read-Host 'Old production DB password' -MaskInput
docker run --rm -e PGPASSWORD -e PGOPTIONS='-c default_transaction_read_only=on' `
  -v "$env:USERPROFILE\tavern-ledger-production-exports\2026-10-23-pre-v62-deployment:/out" postgres:17 `
  pg_dump "host=aws-0-<region>.pooler.supabase.com port=5432 dbname=postgres user=postgres.pfgz…wlsc sslmode=require" `
  -Fc --no-owner -f /out/old-prod-full.dump
Remove-Item Env:PGPASSWORD
```

The host and the full user name come from Dashboard → Connect → Session pooler. `default_transaction_read_only=on` makes
the session unable to write. `pg_restore -l old-prod-full.dump` must list the tables, and the SHA-256 goes into the
package manifest.

A managed Supabase backup (Pro plan) is a plus. It does not replace this package.
