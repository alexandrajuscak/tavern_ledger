# V6.2 adversarial hardening: audit (2026-10-23)

This pass tried to break the V6 product on purpose. It covered:
- hostile input and malformed numbers;
- forged and malformed files;
- authorization across six actors, and hidden DM data;
- duplicate and interrupted actions, and offline use;
- injected server failures and missing assets;
- deep links, browser storage, multiple sessions and Realtime;
- long sessions and catalog integrity.

Everything ran against the **local** stack only. All mutations were done by synthetic users inside the isolation harness
(docs/V62_TEST_ISOLATION.md).

Tools:
- `v62_adversarial_api_test.py` (20 checks) and `v62_adversarial_ui_test.py` (24)
- `v62_import_session_soak_test.py` (21) and `v62_test_isolation_test.py` (9)
- `supabase/tests/catalog_integrity_report.sql` (read only)
- the plain-PostgreSQL backend suite `run_local.sh` (migrations, all SQL suites, concurrency, rollback, reapply)

Severity: BLOCKER · SERIOUS · MODERATE · POLISH · FUTURE.

## Summary

| Severity | Found | Fixed | Documented / deferred |
|---|---|---|---|
| Blocker | 1 | 1 | – |
| Serious | 3 | 3 | – |
| Moderate | 9 | 9 | – |
| Polish | 3 | 2 | 1 (documented) |
| Future | 5 | – | 5 |

Not defects (checked and recorded as policy):
- A campaign DM may open a change request.
- A campaign player cannot read another player's sheet through the API.
- The audit RPC returns only the caller's own characters' events.
- A malformed `#/c/…` link opens the character list.

## Issues

| ID | Area | Role | Before | Expected | Root cause | Files | Correction | Test | Status |
|---|---|---|---|---|---|---|---|---|---|
| ADV-BLOCKER-001 | Hidden DM data: audit log | player | When a DM assigned an **unidentified** item, the party audit event read "Assigned item: &lt;true name&gt;". The owner could read it through the API (`campaign_audit_events`, `get_campaign_audit`), for example from the browser's developer tools. No player screen shows the audit log. One existing local row leaked the same way: "Ring of the Ashen Oath", disguised as "Heavy iron ring". | The true name stays DM-only until the DM identifies the item. | `dm_assign_content` wrote one party-visible event with `v.name`. Neither the read policy nor the RPC knew about item knowledge. | `supabase/migrations/20261023000100_v62_hardening.sql` | New `_audit_item_hidden()` (STABLE SECURITY DEFINER, pinned search_path) is used in the read policy and in `get_campaign_audit`. New assignments write a disguised party event plus a DM-only event with the true name. Existing rows are filtered on read and **not modified**. | SEC1, SEC2, SEC4, SEC7 (demo data checked read-only in a rolled-back transaction) | Fixed |
| ADV-SERIOUS-002 | DM content: feats | DM | A feat with an unknown effect type (`teleport_everyone`) could be published. The derived-stat engine silently ignores it. | Refused with a message. | `_dm_try` did not validate effect types. | migration | Only the 15 effect types the engine understands are allowed. The message names the unknown type. All 409 official feat versions use only these types (integrity report). | VAL1 | Fixed |
| ADV-SERIOUS-003 | DM content: lineages | DM | A custom lineage without a short summary could not be published: "null value in column "summary" of relation "lineages" violates not-null constraint". | Publishes. | `_dm_materialize` wrote `nullif(summary, '')` into NOT NULL columns. | migration | `coalesce(summary, '')` | CC1 (lineage V1 and V2) | Fixed |
| ADV-SERIOUS-004 | Import | player | If an import failed after the character row was created (attacks, features, spells, notes or inventory), a half-imported character stayed behind. | All-or-nothing for the core rows. | Sequential inserts without compensation. | `js/transfer.js` | Any failure in the core phase deletes the new character (child rows cascade) and says "Import failed: … Nothing was imported." | IMP7 | Fixed |
| ADV-MODERATE-005 | DM content validation | DM | Refusals showed database texts (constraint, relation and column names). | Sentences a DM can act on. | `_dm_try` returned `sqlerrm`. | migration | Foreign-key, not-null, check, unique and invalid-input texts are translated. | VAL2 | Fixed |
| ADV-MODERATE-006 | Characters | any client | The API accepted negative current HP and negative coins. The UI clamps them, but other clients did not. | Refused by the database. | No CHECK constraints. | migration | `characters_hp_current_check` (≥ 0) and `characters_coins_check` (all coins ≥ 0), added NOT VALID and then validated. Existing data had 0 violations. | NUM1 (API), NUM2 / NUM3 (UI) | Fixed |
| ADV-MODERATE-007 | Load failure screen | all | "Something went wrong" showed the raw error, e.g. "JSON object requested, multiple (or no) rows returned". The only action was Reload. | Plain words and a way back. | `renderError` printed `err.message`. | `js/app.js`, `js/utils.js`, `css/styles.css` | The screen shows a friendly line (PGRST116 is now mapped to "not found or no access"), **Reload** and **Back to your characters**. The raw error goes to the console. | LINK1, LINK2, LINK3 | Fixed |
| ADV-MODERATE-008 | Load failure screen | all | After a failed character load, the previous character's name and HP stayed in the top bar. Its subscriptions also stayed open. | Nothing of the previous sheet remains. | The character route keeps the old sheet mounted while the next one loads, and the error path never unmounted it. | `js/app.js` | `unmountSheet()` before the error screen. | LINK1b | Fixed |
| ADV-MODERATE-009 | Import | player | A file with an out-of-range number (`pp: 1e12`) failed the whole import with an integer overflow. | The value is clamped. | `int()` had no bound. | `js/transfer.js` | Whole numbers are clamped to the 32-bit range, and the existing field bounds still apply. | IMP4 | Fixed |
| ADV-MODERATE-010 | Error mappers | player | The background, Wild Shape, lineage, spell and class wrappers passed technical texts through. The inventory mapper called an expired session "You are not allowed …". | Friendly text, with session expiry named as such. | Older per-domain mappers. | `js/background-api.js`, `js/creature-api.js`, `js/lineage-api.js`, `js/spell-api.js`, `js/class-api.js`, `js/inventory-api.js` | All use `friendlyError` with a per-domain fallback. The inventory mapper has a session rule. | ERR2 | Fixed |
| ADV-MODERATE-011 | Error toasts (all screens) | all | About 70 call sites show `err.message` in a toast, so any raw error could reach the screen. A promise rejection without a handler failed silently. | One central guarantee. | No central filter. | `js/utils.js` | Error toasts pass through `friendlyError`. An `unhandledrejection` handler shows a friendly toast and logs the original. | ERR3, ERR4, full suite | Fixed |
| ADV-MODERATE-020 | Realtime after a dropped connection | all | Events sent while the socket was down (laptop sleep, network loss) were lost: the sheet showed old values until it was reopened. | The sheet catches up after reconnecting. | `postgres_changes` does not replay, and the app ignored the channel status. | `js/store.js`, `js/sheet.js` | After `CHANNEL_ERROR` / `TIMED_OUT` and a later `SUBSCRIBED`, the sheet saves its own pending edits, reloads the stored values and says "Connection restored — showing the latest values." | RT4 (server-side socket close, DM edit inside the gap) | Fixed |
| ADV-MODERATE-021 | Test isolation | developer | `homebrew_smoke_test.py` left its `hb-smoke-*` user, character and homebrew item behind after every full run. Neither the runner's cleanup nor the harness knew that pattern. | Every synthetic account is covered. | Pattern list only had `ui-*`. | `supabase/tests/browser/isolation.py`, `supabase/tests/run_browser_local.sh` | `hb-smoke-*` and `local-smoke-*` are now synthetic patterns too. Found by the fingerprint comparison, removed, and verified identical to the task start. | fingerprints / row counts | Fixed |
| ADV-POLISH-012 | Sign-in | visitor | OAuth, magic-link and password errors showed the raw text (e.g. "Failed to fetch"). | Words. | `toast(error.message)` | `js/app.js` | `friendlyError(error, 'Sign-in failed. Please try again.')` | (manual) | Fixed |
| ADV-POLISH-013 | Import: portrait | player | Any portrait string was stored, e.g. `javascript:…`. It is inert in `<img>`, but it is not a URL. | `http(s)` or `data:image` only. | No scheme check. | `js/transfer.js` | Other schemes are dropped. | IMP4 | Fixed |
| ADV-POLISH-014 | Test runner | developer | `run_browser_local.sh` defaults to port 5173, which collides with a running dev server. | Clear guidance. | Default port. | `supabase/tests/run_browser_local.sh`, docs | A comment and the docs say to pass `PORT=5191`. | – | Documented |
| ADV-FUTURE-015 | Realtime | all | DELETE events cannot be filtered per character. Every signed-in client receives the primary keys of deleted child rows of any character; the handler ignores unknown ids. | Ids only, no content. Supabase Realtime sends only the old primary key of a deleted row on RLS tables (documented behaviour, not measured in this pass). | Supabase Realtime limitation | – | Keep. Revisit if Realtime adds filtered deletes or a broadcast-based design is adopted. | – | Documented |
| ADV-FUTURE-016 | Import | player | The enrichment phase (lineage, background, classes, spells, feats, Wild Shape, companions) is best effort. | Fully transactional import. | Needs one import RPC across about 15 domains: a new engine. | – | Out of scope. Everything not restored is reported. | – | Deferred |
| ADV-FUTURE-017 | Sessions | player | Sign-out is global (Supabase default). Another browser keeps working until its access token expires (about 1 h), then has to sign in again. | As designed. | – | – | Documented. MS5 measured "saves". | MS5 | Documented |
| ADV-FUTURE-018 | Import | player | Current HP from a file is not cut to the file's base maximum, because feats such as Tough raise the real maximum. | The sheet bounds it once the derived stats load. | – | – | Documented. | IMP4 | Documented |
| ADV-FUTURE-019 | Realtime latency | all | A DM edit reaches the player's sheet in about 0.5 s locally (p50 511 ms, p95 532 ms, 0 of 40 missed). | – | The poll cadence of the local Realtime `postgres_changes` | – | Re-measure on the target host. | RT1 | Documented |

## Catalog referential integrity (read-only report)

All checked reference columns without a foreign key have **0** dangling values:
- the `content_version_id` columns of 6 catalogs;
- published `catalog_ref`;
- feat option links;
- feat effect types;
- background equipment categories;
- active class states;
- transformation history.

The report's last row counts the one pre-V6.2 audit row that names an unidentified item. It is now filtered on read.

## Data safety during the audit

- Every mutation test ran inside `isolation.Isolated`. Journal: `tavern-ledger-local-backups/v62-adversarial-2026-10-23/mutation-journal.jsonl`.
- After every test: residue `{}` and **0 protected tables changed**, including the runs that failed (one during setup, several on test-side assertions that were then corrected).
- The migration was validated first in the throwaway `tavern-ledger-pgtest` container, then applied once to the local
  database. It is additive: functions, a policy and two CHECK constraints validated against existing data with 0
  violations.
