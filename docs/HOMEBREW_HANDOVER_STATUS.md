# Homebrew / legacy items: handover status (2026-10-15)

Status after the final local review before a **new, empty Supabase staging project**. Local only: nothing was
deployed, committed or pushed; no Supabase project is linked (`supabase/.temp/project-ref` is absent).

**Decision: GO FOR A NEW EMPTY STAGING PROJECT.** This is not a production decision.

## Focus restoration
**Root cause.** `inventory-ui.js` `render()` replaces the list's `innerHTML` on every refresh. Refreshes are triggered
by `act()` after a modal action and by Realtime `scheduleRefresh()`. When the refresh landed after a modal closed,
focus went back to the opener, which the render then detached, so focus fell to `<body>`. The review found three
more races in `openModal`:
- The 50 ms initial-focus timer, and `confirmDialog`'s 60 ms timer, still fired after a quick close, so focus went
  into a modal that was fading out.
- A parent modal's timer could pull focus out of a child modal.
- After the "closing" marker was introduced, one Escape key press reached both stacked modals and closed both.

**Fix.**
- `js/utils.js`:
  - A modal remembers its opener's stable `data-focus-key`. On close it focuses the opener if it is still
    connected; otherwise it focuses the element with the same key. The key is also kept as a pending key that the
    next re-render takes over (`takePendingFocusKey()`).
  - A closing modal is marked `data-closing` and no longer counts as the top-most modal.
  - One Escape closes one modal: the handler sets `preventDefault`, and the parent's listener ignores a key press
    that is already handled.
  - The initial-focus timers run only while their modal is still the top-most one and focus is not already inside it.
  - `body.modal-open` is removed only when the last modal closes.
- `js/inventory-ui.js`:
  - Every action control gets a `data-focus-key` (`inventory-item:<id>:details`, `inventory-item:<id>:<action>`,
    `slot:<slot>:<action>`, `filter:<f>`, `add-item-button`; the heading is `inventory-heading`).
  - `render()` keeps focus on the same key across re-renders.
  - Fallback order: the same action, the item's main button, the Items heading, then Add item.
  - Focus is restored only when it was actually lost to `<body>`, so a refresh never takes focus away from another
    field.
- In the app, Create homebrew **replaces** the Add item picker rather than stacking on it, so closing the form
  returns focus to Add item. True nesting (a confirmation over the item detail) returns focus into the parent modal.

## Owner deletion
In migration `…1300`, `items.owner_id` has `on delete restrict`, and the check `items_homebrew_has_owner` requires
`data_source_id <> 'homebrew' or owner_id is not null`. Official seeded rows have no owner and are not
`homebrew`; private and campaign homebrew have an owner. Deleting a profile that owns homebrew fails with
`items_owner_id_fkey` (test Q27). The rollback drops `items`, so it leaves no stale constraint.

**Operational precondition:** a profile cannot be deleted while it owns homebrew items. Delete or transfer its items
first (an admin can change `owner_id`). There is no account-deletion or transfer workflow yet.

## Review results
- **Direct client writes.** No frontend code inserts or updates `items`, `inventory_items` or `character_equipment`,
  and none sets `owner_id` or a data source. All homebrew, legacy and instance changes use RPCs. The database
  enforces this as well: insert, update and delete are revoked for `anon` and `authenticated`, and the API tests
  confirm it. `store.js` still has generic `insertRow` / `deleteRow` helpers, but no call uses them for these tables;
  they serve the sheet's own tables.
- **Migrations.**
  - 14 files, timestamp-ordered; the base schema is `…0000`, and its sync is checked by `sync_base_migration.py --check`.
  - No absolute paths, secrets or project references.
  - SECURITY DEFINER functions without a fixed `search_path`: 0. All 7 views are `security_invoker`.
  - The Realtime publication is correct. The rollback covers `…0100`–`…1300`.
  - `supabase/migrations/README.md` now lists `…1200` / `…1300` and the deployment order.
- **Seed.**
  - The generated seed has 1146 items, no users, characters or profiles, and no credentials.
  - Every insert uses `on conflict … do update … where items.owner_id is null`, so homebrew is never overwritten
    and the seed can run again (verified).
  - The seed sets neither `owner_id` nor `archived_at`.
- **Frontend configuration.**
  - `js/config.js` holds the production URL and a **publishable** key, which is intended and safe.
  - `js/supabase.js` rejects `sb_secret_` and service_role JWTs.
  - The local override works only on localhost / 127.0.0.1, and only with an `http://127.0.0.1|localhost:<port>` URL.
  - The test scripts read keys from `supabase status` at run time and refuse non-local URLs; no key is stored in a file.
  - `.gitignore` covers real characters and `data/reports/private/`.

## Tests run (this session)
| Layer | Result |
|---|---|
| Clean local Supabase: 14 migrations, seed of 1146 items, seed re-run | PASSED |
| Legacy data path (base schema, legacy fixture, `migration up`, legacy check) | PASSED |
| SQL suite on Supabase Postgres 17.6 | PASSED 200/200 (incl. Q27 owner deletion) |
| Concurrency (two sessions), Realtime publication, security_invoker views | PASSED |
| API + RLS with real GoTrue JWTs | PASSED 78/78 |
| Rollback script, then `db reset --local` | PASSED |
| Browser `inventory_ui_test.py` (Edge) | PASSED 38/38 |
| Browser `homebrew_smoke_test.py`, incl. focus regression F1–F6 | PASSED 28/28 |

**How the browser runs went.**
- The full runner ran once. Its browser stage gave 38/38 and 24/28.
- The four focus failures were application bugs, described above, and were fixed in `js/utils.js`.
- After the fix, only the two browser layers were rerun on the same local stack.
- The database layers were not rerun because only browser JavaScript changed.
- One test-only change: `inventory_ui_test.py` step 2d now uses the new Compare… → Link flow.

## Not run
- The dataset pipeline (no data changes this session; last result 56/56).
- In the browser: homebrew edit, convert-to-homebrew, campaign homebrew, the duplicate-name warning, and network-retry
  idempotency. Each of these is covered by SQL and API tests only.
- Realtime delivery after the homebrew changes, apart from the existing realtime check in `inventory_ui_test.py`.
- Any real phone (the mobile results come from an emulated 390 px viewport).

## Files changed (this session)
- `js/utils.js`, `js/inventory-ui.js` (focus restoration); asset version `?v=10` in `index.html` and `js/*.js`;
  references updated in `README.md` and `docs/DATA_MODEL.md`.
- `supabase/tests/browser/homebrew_smoke_test.py` (focus checks F1–F6), `supabase/tests/browser/inventory_ui_test.py`
  (step 2d), `supabase/tests/run_browser_local.sh` (now also runs the smoke test).
- `supabase/migrations/README.md` (migrations `…1200` / `…1300`, deployment order, owner precondition).
- Previous session: migration `…1300` (owner FK and check), `supabase/tests/inventory_tests.sql` (Q27).

## Remaining before production
1. Browser coverage for homebrew edit, convert, campaign homebrew, duplicate warning and network retry.
2. Legacy classification reports: a private report (git-ignored) and an aggregate report, run on a copy of the real data.
3. Documentation:
   - new: HOMEBREW_ITEMS, LEGACY_ITEM_MIGRATION_UI;
   - to update: INVENTORY_FRONTEND_API, INVENTORY_UI, INVENTORY_TEST_PLAN, RLS_SECURITY_REVIEW, DATA_MODEL,
     INVENTORY_DATABASE.
4. An account-deletion or homebrew-transfer workflow (today deletion is blocked).
5. A production plan: record `…0000` as applied without running it, after comparing the schema;
   `migrate_legacy_inventory()`; a backup; a check on a real phone.

## Staging plan (not executed)
1. Create a **new, separate** Supabase project for staging in the dashboard. Note its project ref apart from
   production. Production ref seen in `js/config.js`: `pfgzbzzouvwvobftwlsc`; never link that ref here.
2. Dashboard → Database: check the Postgres version (local runs used 17.6; `config.toml` has major version 17).
   No extensions beyond the defaults are needed (`pg_trgm` is not used).
3. Link only staging, and check the link before every remote command:
   ```bash
   SB=../.tools/supabase-2.118.0/supabase.exe
   $SB link --project-ref <STAGING_REF>
   cat supabase/.temp/project-ref   # must print <STAGING_REF>, never the production ref
   $SB migration list               # remote column empty on a new project
   ```
4. Apply the migrations in order: `$SB db push --dry-run`, then `$SB db push`. The new project applies `…0000` normally.
5. Load the seed once. Use the staging connection string from the dashboard; never commit it:
   `psql "<STAGING_DB_URL>" -f supabase/seed/reference_data.sql`. Run it a second time to confirm it is re-runnable.
   Expect `select count(*) from items` = 1146.
6. Create only synthetic users and characters (`@example.test`). Never copy production secrets or personal data.
7. Point the API and browser tests at staging. They currently refuse non-local URLs on purpose. Add an explicit
   staging allow-list for the staging ref only, then run the API / RLS tests and the browser smoke test.
8. Check Realtime: an item added by a second user appears without a reload.
9. Read the Postgres and API logs (dashboard → Logs) for errors and permission denials.
10. Test the frontend against staging through a separate config, never by editing `js/config.js` for production.
11. Do **not** run `migration repair` or anything else against production at this stage. Unlink when done:
    `$SB unlink`.
