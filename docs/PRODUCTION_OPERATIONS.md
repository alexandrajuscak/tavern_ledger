# Production operations

Project `pfgz…wlsc` (Free plan, PostgreSQL 17.11), frontend on GitHub Pages. No secrets in this file.

Deployed (as of 2026-11-10): frontend `7fa453d` (asset marker `?v=20`; `2ac52c7` adds only the release report), newest
migration `20261109000300` (55 migrations), released 2026-11-09. Flags: `FLUENT_READS = 'on'` (progressive fluent reads are
the default), `COMBAT_BUILDER = 'dm'`, `CONTENT_MANAGEMENT = 'on'`.
Rollback of the latest release: docs/ACTIVE_FEATURES_AND_CONTENT_MANAGEMENT_RELEASE_REPORT.md ("Backups"); of the Combat
Builder: docs/COMBAT_BUILDER_PRODUCTION_RELEASE_REPORT.md ("Migrations"); of the 2026-10-29 timeout fix:
docs/PRODUCTION_INCIDENT_REALTIME_TIMEOUTS.md §7.
Monitoring: both releases stay "deployed and monitoring" until one real multiplayer session has run and the Supabase Log
Explorer has been reviewed (not yet done: no access token on the release machine).
Open operational items (2026-11-10): the nightly backup below is not scheduled yet; confirm the database password rotation.

## Never

- re-run the catalog seeds / importer on production (DM custom content shares the catalog tables; docs/DEPLOYMENT_PRODUCTION_SEEDS.md R1);
- `supabase db reset`, `migration repair`, a blind `db push`, `pg_terminate_backend()`;
- raise `max_connections`, `statement_timeout` or the Realtime pool "to be safe";
- reset `pg_stat_statements` without a reason recorded in the incident log (it is the only history of slow statements).

## Read-only health check (5 minutes)

`scripts/incident/readonly_evidence.sql`: SELECT only, one JSON value, aggregates only. Run it in the Dashboard SQL Editor,
or from a shell that forces read-only (`default_transaction_read_only=on`, `BEGIN READ ONLY … ROLLBACK`). Compare with the
previous snapshot instead of resetting counters.

| Look at | Healthy | Investigate |
|---|---|---|
| `pgss_over_5s` (role authenticated) | empty after the fix | any `get_character_*` above 5 s |
| `pgss_top_by_total` | derived-stats RPCs dominate (expected) | a catalog RPC or view among the top |
| `connections_by_app_role_state` | ~15 with nobody online | `idle in transaction`, blocked > 0 |
| `realtime_subscriptions_total` | 4 per open sheet on the default fluent path (2 sheet + 2 request bar); 72 on the legacy path `?fluent=0` (70 + 2); +2 per open DM Space; 1-3 per open Combat Builder encounter | grows while nobody switches characters (leak) |
| Supabase Logs (Postgres) | no `57014` | a cluster of `57014` |
| Supabase Logs (Realtime) | no `IncreaseSubscriptionConnectionPool` | the same message again |

Free-plan logs are kept for a short time only; if an error is reported, read the logs the same day.

## Realtime database pool: recommendation (2026-10-29)

**Option F then A: no pool change now; monitor after the fix.**
Evidence: the Realtime errors came from Realtime's own statements timing out against a database saturated by the sheet's
RPC bursts (statements of `supabase_admin` up to 3-9 s in the same period). A larger pool would put more concurrent statements
on the same saturated CPU. With max_connections 60 and 15 connections when idle, there is connection headroom; the limit was
CPU time, not connection slots. Revisit only if `IncreaseSubscriptionConnectionPool` reappears **after** the fix while
`pgss_over_5s` stays empty: then a +1/+2 step of the Realtime pool, keeping at least 20 connections free, rollback value = the
current Dashboard value (record it first; Realtime restarts and clients reconnect on a change).

## Compute

Prefer a compute upgrade (Free -> Pro Micro/Small) over connection-limit changes if, after the fix, single sheet RPCs still
exceed ~2 s at normal play. Decide from `pgss_top_by_max` and Dashboard -> Reports -> CPU a week after the deployment.

## Backups (CRITICAL: Supabase Free has no automatic backups)

Script: `scripts/backup/nightly_backup.ps1` (tested in the 2026-10-30 release: it made the pre- and post-deployment backups).

1. Put the database URL (ideally of a read-only role) into `%USERPROFILE%\.tavern-ledger\backup-db-url.txt`; restrict the
   file to your user (`icacls <file> /inheritance:r /grant:r "%USERNAME%:R"`). Never inside the repository or OneDrive.
2. Task Scheduler → Create Task → daily 04:00 → Action `powershell -NoProfile -ExecutionPolicy Bypass -File
   "<repo>\scripts\backup\nightly_backup.ps1"`; on the 1st of each month a second task with `-Rehearse`.
3. Output: `%USERPROFILE%\tavern-ledger-production-exports\nightly\<UTC stamp>\` with roles.sql, schema.sql, data.sql,
   migration_history.txt, counts.txt, SHA256SUMS.txt, STATUS.txt. Retention: 14 daily + the first of each of 6 months;
   folders labelled `-pre-` / `-post-` are never deleted.
4. Failure: the script exits 1, writes `STATUS.txt` with the failed step and `..\LAST_FAILURE.txt`; Task Scheduler shows
   "Last Run Result" ≠ 0. Check weekly; a missing folder for today is a failure too.
5. Off-device: copy the newest folder weekly to an encrypted location (BitLocker-protected USB disk, or a cloud folder after
   `7z a -p` / `age` encryption). The PC disk is not a backup of itself.
6. Monthly restore rehearsal: `-Rehearse` restores into a throw-away Supabase Postgres container (public data; the Auth tables are created by the Auth service and are not part of the check) and compares the character count; the
   full restore procedure is docs/DEPLOYMENT_INPLACE_UPGRADE_RUNBOOK.md §5.

Before every migration: run it with `-Label pre-<name>` (kept forever).
