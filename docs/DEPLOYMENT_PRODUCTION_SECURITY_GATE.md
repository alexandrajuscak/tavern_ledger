# Deployment: pre-production security gate (status 2026-10-23, after Phases A and B)

Rule: any security-critical **FAIL** or **UNKNOWN** means **NO-GO**. Current overall result: **NO-GO**. That is expected at
this stage: production access, exports, backup and staging are not done yet.

| # | Gate item | Status | Evidence / what is missing |
|---|---|---|---|
| 1 | Target Supabase project identity (new production project) | UNKNOWN | not created; Strategy A recommended (docs/DEPLOYMENT_REBUILD_STRATEGY.md) |
| 2 | Target GitHub repository identity | PASS | `alexandrajuscak/tavern_ledger`, public, Pages from the `main` root |
| 3 | Target Pages URL | PASS | `https://alexandrajuscak.github.io/tavern_ledger/` |
| 4 | Service-role / secret key absent from the frontend | PASS | secret audit; start-up guard refuses privileged keys |
| 5 | Database password absent from the frontend | PASS | secret audit |
| 6 | Secret scan (tree + history) | PASS | docs/DEPLOYMENT_SECRET_AUDIT.md: no real secrets, nothing to rotate |
| 7 | RLS enabled | PASS (clean build) | 152 / 152 public tables, clean migrations + seeds (docs/DEPLOYMENT_PRODUCTION_SEEDS.md); re-check on staging |
| 8 | Hidden-data migration included | PASS | `20261023000100_v62_hardening.sql` among the 41 |
| 9 | Audit filtering included | PASS | `_audit_item_hidden` in the read policy and `get_campaign_audit` (SEC1–SEC7) |
| 10 | `hp_current >= 0` constraint included | PASS | same migration |
| 11 | Coin constraint included | PASS | same migration |
| 12 | SECURITY DEFINER functions pin `search_path` | PASS (clean build) | 0 unpinned |
| 13 | Anonymous access reviewed | PASS with risk | anon reads the **official catalog** by design (S46); no character, campaign or hidden data (AUTH2). Catalog exposure → licensing gate |
| 14 | Realtime publications reviewed | PASS (clean build) | 31 tables in `supabase_realtime`; RLS applies; DELETE ids unfiltered (ADV-FUTURE-015) |
| 15 | Storage reviewed | UNKNOWN | both the legacy `schema.sql` and the base migration create the `portraits` bucket, so the old project probably has uploaded portraits (count unknown → inventory query). The new project gets the bucket from the migrations; check its policies on staging |
| 16 | Auth redirect URLs planned | PASS (planned) | docs/DEPLOYMENT_PRODUCTION_RUNBOOK.md, Auth URLs |
| 17 | Backup verified | UNKNOWN | the old-project logical backup is not taken yet |
| 18 | Character exports verified | UNKNOWN | not exported yet (the validator is ready; dry run 12 / 12) |
| 19 | Recovery package verified | UNKNOWN | not assembled yet |
| 20 | Demo / test seeds excluded | PASS | the clean build has 0 users, characters, campaigns and content; forbidden list in the seed manifest |
| 21 | Rollback path documented | PASS | docs/DEPLOYMENT_ROLLBACK_RUNBOOK.md (frontend revert to `849d7f1`, old project untouched) |
| 22 | Frontend environment isolation | PASS | `deployment_environment_test.py` 13 / 13 (incl. key allowlist and static secret checks) |
| 23 | Staging sign-off | UNKNOWN | no staging project yet |
| 24 | Public sign-up policy | UNKNOWN | to be turned off after the accounts exist (decision) |

## Licensing gate

| Asset | Status | Private-table deployment | Publicly promoted release |
|---|---|---|---|
| Fonts (Inter, Cinzel, Alegreya) | SIL OFL 1.1, texts in `fonts/` | OK | OK |
| supabase-js 2.117.2 | MIT, `vendor/supabase-js/LICENSE` | OK | OK |
| Icons (`assets/icons`, 204) | **licences unknown** (docs/ICON_ASSET_INVENTORY.md) | documented risk (not resolved) | **BLOCKER** |
| Rules catalog (seeds: PHB, XGE, TCE, 2024 PHB and others; UA / playtest entries) | non-SRD content with source links; readable through the API with the public key | documented risk; keep the seeds out of the public repository | **BLOCKER** (SRD-only catalog or authenticated-only reads) |
| Project-written summaries and docs | own work | OK | OK |

**Recommendation:** deploy only as a **private-table deployment**. The URL is reachable, but the site is not announced or
promoted. Public sign-up is turned off, the seeds are not committed, and the icon and catalog risks are written down here
and **not** claimed as resolved. Nothing here is legal advice.
