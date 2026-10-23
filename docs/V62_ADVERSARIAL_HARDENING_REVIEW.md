# V6.2 adversarial hardening: review (2026-10-23)

What was attacked, what broke, what changed, and how it was verified. Issue details are in
docs/V62_ADVERSARIAL_HARDENING_AUDIT.md.

## Scope

**LOCAL ONLY.** No hosted Supabase, no deploy, no commit. The V6 visual language is unchanged, and no new gameplay engine
was added.

## Attack areas and results

| Area | How | Result |
|---|---|---|
| Hidden DM data | Unique markers in an unidentified item (true name, curse), DM notes and a hidden condition. Every readable table and view (159) plus 7 read models were swept as the owner and as another player, before and after a reveal. | **1 blocker found and fixed** (true name in the audit log), plus a read-only check of the existing demo leak row. |
| Authorization | 6 actors × 12 actions, 72 cells (docs/V62_AUTHORIZATION_MATRIX.md) | all "must" cells hold; policy choices recorded |
| Approval atomicity | composite request with a failing second op; 4 parallel approvals; repeated idempotency key | nothing partial; granted once; one request |
| Custom content | 8 content types through V1, V2, archive and assignment; 7 invalid drafts | 2 serious defects fixed (unknown feat effect published; lineage without summary could not publish) and validation texts translated |
| Numbers | ability scores 0 / 31 / -4 / abc / 1e9 / 20 digits; negative HP and coins (UI and API); levels; slots | bounded on screen; database CHECK constraints added |
| Injection | 7 payloads (img onerror, script, svg onload, javascript: links, iframe srcdoc, template syntax) in names, notes, features, attacks, items, resources and conditions | inert on home and all six tabs; shown as text |
| Interruption / offline | aborted autosave PATCH; browser offline | the status says so, the edit is kept, it syncs afterwards |
| Duplicate actions | double-click on a resource "Use"; double-click on Import | one use; one character |
| Error boundaries | injected 500, 401 (JWT expired), 23514; missing icons and fonts | friendly words, no database text, no page errors |
| Deep links | unknown, malformed and foreign character ids; admin route as a player | the same screen for unknown and foreign ids (no existence leak), a way back, no stale header (fixed) |
| Browser storage | after sign-out | no token, no cached character data; the anon key reads nothing |
| Import / export | 4 malformed files, a forged / hostile file, prototype keys, a round trip, a failure half-way | refused / clamped / ignored / identical / **atomic (fixed)** |
| Multi-session / Realtime | 3 browsers (player ×2, DM); 40-event soak; 10 navigation cycles; a dropped socket | delivered 40/40, channels balanced, **resync after reconnect (fixed)** |
| Long session | 300 tab switches in-page | heap 6.6 → 6.7 MB, DOM 1,999 → 1,998 nodes (final run) |
| Catalog integrity | 14 read-only checks on reference columns without a foreign key | 0 dangling |
| Test isolation | harness with digests of 152 tables, a journal, and an interrupted-cleanup test | found a leaking smoke test (fixed); caught an overlapping runner |

## Changes

- **Database:** `20261023000100_v62_hardening.sql` plus its rollback, generated from the live definitions by a builder kept
  with the local backups.
  - `_audit_item_hidden()`, the audit read policy, `get_campaign_audit` and `dm_assign_content`;
  - `_dm_materialize` (lineage summary) and `_dm_try` (effect types, friendly messages);
  - CHECK constraints on HP and coins.
- **Frontend:**
  - central error toasts and an unhandled-rejection handler (`js/utils.js`);
  - the load error screen, which now unmounts the previous sheet (`js/app.js`, `css/styles.css`);
  - domain error mappers (`js/*-api.js`);
  - atomic import, integer clamping and the portrait scheme filter (`js/transfer.js`);
  - Realtime resync after reconnect (`js/store.js`, `js/sheet.js`).
- **Tests:**
  - `isolation.py`;
  - 4 V6.2 suites;
  - `catalog_integrity_report.sql`;
  - runner registration and cleanup;
  - V6.2 rollback in both backend runners;
  - a stale UX22 comment fixed.

## Verification (final runs, after the last change)

| Run | Result |
|---|---|
| `run_local.sh` (plain PostgreSQL, throwaway container: migrations, all SQL suites, concurrency, rollback incl. V6.2, reapply) | exit 0: 3,429 suite checks + 596 named checks, **0 failed** |
| complete browser suite `run_browser_local.sh` (29 suites + cleanup step) | exit 0: **918 passed, 0 failed** |
| V6.2 suites inside it | isolation 9/9, API 20/20, UI 24/24, import / sessions / soak 21/21 |
| protected data | all 42 fingerprint rows and 189 row counts identical to the task start (auth session / audit tables excluded by design) |
| persistence | a synthetic fixture survived `supabase stop` / `start` with volumes kept; logins 200; fixture removed; fingerprints identical |

## Not run

- `run_supabase_local.sh`, because it wipes the local volume. Its role was covered by `run_local.sh` and by the browser
  suites against the live local stack.
- `local_demo_smoke_test.py`, because it mutates the seeded demo characters (with snapshot and restore). It was not
  needed to verify this pass, and the user's demo data was left untouched. The demo data was checked read-only instead
  (SEC7).
