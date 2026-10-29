# Catalog picker loading (incident 2026-10-23)

Code: `js/catalog-load.js`; used by `js/background-ui.js` (`loadIntoPicker`), `js/class-ui.js`, `js/class-setup.js`,
`js/spell-ui.js` (`catalogOrExplain`). Tests: `supabase/tests/browser/production_timeout_incident_test.py`.

## Root cause of "Background options do not load reliably"

The Background picker awaited `get_background_catalog` **before** it showed anything. A click showed nothing until the
whole catalog (470 KB, 30 versions with grants, choices, equipment and the feat list) arrived; on any error the player saw
one toast and no dialog. The SQL itself is fast (production idle 89-104 ms); during the incident it waited behind the
sheet's burst of derived-stats RPCs on a saturated database, so the click looked dead and sometimes failed.
Catalog rows are complete in production (30 versions, 29 enabled by default, same as the post-deployment validation).
Backgrounds have no campaign or custom-content variant, so campaign policy cannot reduce the list to zero.

## Picker state machine (Background)

```
open --> SHELL (search, filters, empty list with "Loading backgrounds…", role=status, aria-live=polite)
SHELL --load ok--> RESULTS (current search / filters applied) --search--> RESULTS | EMPTY ("No background matches.")
SHELL --error / 15 s--> ERROR (role=alert: reason + one Retry button)
ERROR --Retry (a second click while running does nothing)--> SHELL
any state --close--> CLOSED (a late answer is ignored; the shared catalog request finishes and fills the cache)
```

| Failure | Message (never SQL text) |
|---|---|
| 8 s statement timeout (57014), no answer within 15 s | "The backgrounds are taking too long to load. The server may be busy; try again in a moment." |
| expired session (401, PGRST301) | "Your session has expired. Sign in again to see the backgrounds." |
| permission (403, 42501) | "You cannot see these backgrounds. Your campaign or DM settings may restrict them." |
| network | "Could not reach the server to load the backgrounds. …" |

Timeout: 15 s, deliberately above the 8 s statement timeout of signed-in users, so the client never abandons a read the
server would still answer. The catalog request itself carries `AbortSignal.timeout(15 s)`: a request that never answers is
dropped from the per-page cache and Retry sends a new one. No automatic retry. Focus stays in the dialog; closing returns
focus to the opener (`data-focus-key`). The first click after a search works (the list is only rebuilt when it changes).

## Other pickers (audit)

| Picker | Before | After |
|---|---|---|
| Background | blocked before opening, toast only | shell first, final state, Retry |
| Class / multiclass (`openClassEditor`, `openAddClass`) | awaited the class catalog, **an error was an unhandled rejection (nothing happened)** | "Loading classes…" after 0.7 s, a clear message on failure, click again to retry; the catalog is normally already cached by the sheet |
| Spell (`openAddSpell`) | same as class | same as class |
| Lineage | dialog first, error inside the dialog | unchanged (already terminal) |
| Feat | dialog first, error in the count line | unchanged (already terminal) |
| Item catalog (Inventory) | paged with an `AbortController` per search | unchanged |
| Wild Shape / companion forms | dialog first, reads the creature catalog | unchanged |
| Subclass, custom-content assignment | inside the class editor / DM Space | covered by the class change / unchanged |

Not done on purpose: no rewrite of every picker; no automatic retries; no global cache of anything that depends on the
user, campaign or approval state.
