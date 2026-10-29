# Deployment: production smoke test results (2026-10-23)

Production upgraded **in place** to V6.2: release commit `9b810aa`, Supabase project `pfgz…wlsc`, Pages
`https://alexandrajuscak.github.io/tavern_ledger/`.

## Database validation (Phase 7, `scripts/deploy/postupgrade_validation.sql` + integrity report)

| Check | Result |
|---|---|
| users / profiles / Google users | 8 / 8 / 6 ✅ |
| characters / campaigns / members | 7 / 2 / 8 ✅ |
| inventory rows / without inventory_id; character inventories | 76 / 0; 7 ✅ |
| governance: campaigns `relaxed` / characters set up | 2 / 7 ✅ |
| tables / without RLS / unpinned SECURITY DEFINER | 152 / 0 / 0 ✅ |
| policies / hash | 170 / `91bd4664…` ✅ (identical to the tested build) |
| Realtime tables / storage policies / bucket | 31 / 3 / `portraits` ✅ |
| legacy rows, V6.2 constraints, admins, `ensure_rls` | all as expected ✅ |
| catalog integrity report | 14 / 14 = 0 ✅ |
| anonymous probe (public key only) | every player and DM table and the hidden-data RPC refused (401); only the official catalog is readable (by design) ✅ |

## Frontend (Phase 8)

| Check | Result |
|---|---|
| Pages build | `built`, commit `9b810aa` ✅ |
| new modules, supabase-js, fonts, icons | HTTP 200 ✅ |
| live files = release commit (index, app, supabase, config, sheet, styles) | identical ✅ |
| live `js/config.js` | existing project + publishable key, no secret ✅ |
| external hosts in index.html | none ✅ |

## Application smoke test (Phase 9, by the operator, private window)

| Item | Result |
|---|---|
| e-mail sign-in (admin), home lists the characters | ✅ |
| two characters: 6 tabs, HP and AC shown, inventory shown | ✅ |
| DM Space with both campaigns | ✅ |
| Google sign-in (player) | ✅ |
| Realtime HP change between two windows | ✅ |
| sign-out | ✅ |

**Observation:** switching quickly between characters loads slowly. The cause analysis and options are in
DEPLOYMENT_FINAL_HANDOVER.md (follow-up F-1). This is not a correctness problem.
