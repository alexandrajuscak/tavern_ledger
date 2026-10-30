# Deployment: final handover, V6.2 in-place upgrade (2026-10-23)

## Result: **DEPLOYED** (in place; users, Google sign-in, campaigns and characters kept)

| | |
|---|---|
| Frontend | `https://alexandrajuscak.github.io/tavern_ledger/`, release commit `9b810aa` (previous: `849d7f1`); incident fix `a568ab5` (2026-10-29) |
| Database | the existing Supabase project `pfgz…wlsc` (PostgreSQL 17.11, Free plan), 41 migrations (baseline marked as applied + 40 applied) |
| Window | 2026-10-23; phases 1–10 of docs/DEPLOYMENT_PRODUCTION_WINDOW_RUNBOOK.md, all GO |

## Backups (outside Git and outside OneDrive)

| Backup | Location | SHA-256 (first 16) |
|---|---|---|
| pre-upgrade (legacy schema) | `%USERPROFILE%\tavern-ledger-production-exports\2026-10-23-window\pre-upgrade\` | roles `168a95a9c745af5e` · schema `12e245c5b7bf0943` · data `3b0f6bd50a37a31a` |
| post-upgrade (V6.2) | `%USERPROFILE%\tavern-ledger-production-exports\2026-10-23-window\post-upgrade\` | `SHA256SUMS.txt` in the folder |
| earliest backup and the 7 character exports | the operator's backup folder (to be moved out of OneDrive) | – |

The pre-upgrade game data was byte-identical to the first backup. Restore procedure (including the four objects a CLI
dump omits): docs/DEPLOYMENT_INPLACE_UPGRADE_RUNBOOK.md §5. The post-upgrade data dump warns about circular foreign keys.
That is expected: the file starts with `SET session_replication_role = replica`, so it restores as rehearsed.

## What happened in each phase

| Phase | Result |
|---|---|
| 1 Freeze | SUMMARY 12 / 12 GO; 7 characters, 76 items, 37 equipped |
| 2 Backup | 3 files; data identical to the first backup |
| 3 Baseline | `20261015000000 => applied` |
| 4 Migrations | dry run: exactly 40 (identical to the repository); push: 40 applied, no error; then 41 history rows / 152 tables / 7 characters |
| 5 Catalog | 9 seeds, all counts exact (1,146 items · 574 spells · 13 classes · 118 subclasses · 246 class features · 334 creatures · 133 lineages · 408 feats · 30 backgrounds · 58 source books) |
| 6 Inventory | 44 linked · 4 placed in slots · 33 for manual review; second run 0 / 0 / 0 |
| 7 Validation | 14 / 14, integrity 14 × 0, anonymous probe clean |
| 8 Frontend | pushed `849d7f1..9b810aa`; Pages built; live files = commit |
| 9 Smoke | e-mail, Google, characters, inventory, DM Space, Realtime, sign-out all OK |
| 10 Post-backup | 3 files verified; password removed from the session; players informed |

Incidents: none. The CLI's confirmation menu printed two migration names twice; that is a display artefact (the
40 "Applying" lines were unique and in order).

## Players: one-time actions

- **Re-equip** weapons and gear on Inventory. 33 equipped items could not be placed automatically: several weapons
  (which hand?), names without a catalog match, gear without an obvious slot, or stacks. Until then, AC and attacks can
  differ from the old sheet.
- On **Build**:
  - choose **Lineage**, **Class** (with level), **Background** and catalog **Spells**;
  - then delete the old free-text spells;
  - resolve the reminders.

## Known limitations and follow-ups

| # | Item | Notes |
|---|---|---|
| F-1 | **Slow loading when switching characters quickly** (seen in the smoke test) | **Became the production incident of 2026-10-23 (57014 statement timeouts, Realtime `IncreaseSubscriptionConnectionPool`, Background picker not loading).** Diagnosed and fixed locally on 2026-10-29: docs/PRODUCTION_INCIDENT_REALTIME_TIMEOUTS.md (root cause, evidence, fix, production plan). **Fix deployed 2026-10-29 23:00 UTC** (frontend `a568ab5`, migration `20261029000100`, 42 migrations); monitoring until 2026-11-05. |
| F-2 | Public sign-up is still **on** | Turn it off (Dashboard → Authentication) once all players have accounts, and invite new players instead. |
| F-3 | The catalog seeds must never run again on production | DM custom content shares tables with them (docs/DEPLOYMENT_PRODUCTION_SEEDS.md, rule R1). A future catalog update first needs scoped deletes in the generators. |
| F-4 | Licensing | Icon licences are unknown, and the official catalog is readable with the public key. Accepted for a private table; blockers for a promoted public release (docs/DEPLOYMENT_PRODUCTION_SECURITY_GATE.md). |
| F-5 | Portraits are external links | They load from third-party sites; players may upload their own instead (portraits bucket). |
| F-6 | Free plan has no automatic backups | Take a `supabase db dump` (roles / schema / data, as in the window) regularly and before every future migration. |
| F-7 | The old backup folder is in OneDrive | Move it to a non-synced folder (it holds e-mail addresses and password hashes). |
| F-8 | This handover and the smoke results are local edits after `9b810aa` | Commit them in a small follow-up commit when convenient (approval as usual). |
| F-9 | **Fluent read path (2026-10-30) deployed behind the flag, not default** | Migration `20261030000100` (43 migrations) and frontend `?v=13` are live with `FLUENT_READS = 'off'`; per browser `?fluent=1`. The view is slower to first paint and runs past the 8 s timeout under concurrent opens (docs/FLUENCY_BENCHMARKS.md). Next: progressive first paint (docs/FLUENCY_PRODUCTION_DEPLOYMENT.md). |
| F-10 | Starting equipment prompt missing for some characters | Pre-existing: `authenticated` has no EXECUTE on `_starting_equipment_candidates` (docs/FLUENCY_PRODUCTION_DEPLOYMENT.md). Fix with a one-line grant migration after review. |
| F-11 | Nightly backup not scheduled yet | `scripts/backup/nightly_backup.ps1` (docs/PRODUCTION_OPERATIONS.md): create the URL file and the Task Scheduler entry. |

## Rollback (still available)

- **Frontend:** `git revert --no-edit 9b810aa` and push. Pages serves the old app.
- **Database:**
  - R-A (`rollback_v62_hardening.sql`, then `rollback_inventory.sql`; rehearsed): back to the legacy schema with all legacy
    data. Anything players entered in new features since the upgrade is lost.
  - Or restore the pre-upgrade backup per the in-place runbook §5.
- Both together only; never one without the other.
