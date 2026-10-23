# Deployment: staging rehearsal results (Phase D)

**Status: NOT STARTED.** No staging project exists yet. Remote staging writes need the phrase `PROCEED WITH STAGING
REHEARSAL` after the target and commands are shown. The steps are the production runbook (docs/DEPLOYMENT_PRODUCTION_RUNBOOK.md)
against the staging project, followed by the 30-step rehearsal checklist of the deployment brief.

## Already rehearsed locally (no remote project)

| Step | Local evidence (2026-10-23) |
|---|---|
| All 41 migrations from zero, then 9 seeds | clean throwaway database: no errors; counts as in docs/DEPLOYMENT_PRODUCTION_SEEDS.md |
| Seeds idempotent, no demo fixtures | second run: counts unchanged; 0 users, characters, campaigns, content |
| RLS / SECURITY DEFINER / Realtime publication | 152/152 RLS, 0 unpinned, 31 published tables |
| Import of legacy exports | 6 / 6 level-2 legacy files imported through the UI (`legacy_import_pilot_test.py`) |
| Export validation | 12 / 12 legacy files valid (`scripts/deploy/validate_exports.py`) |
| Staging frontend selection | `deployment_environment_test.py` 13 / 13 |
| Hidden item, approvals, Wild Shape, export round trip, Realtime with two browsers, sign-out | V6.2 suites (full browser suite) |

## To fill in during the rehearsal

Project ref (masked), region, plan, migration result, seed counts, RLS / SECURITY DEFINER / publication checks, Auth URLs,
the synthetic staging DM and player, campaign, legacy import, choices, custom content, hidden item, approval, Wild Shape,
export round trip, Realtime (2 browsers), sign-out, restart / recovery, no demo fixtures, sign-off.
