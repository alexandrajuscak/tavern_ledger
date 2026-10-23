# V6.2 error boundary review

What the player sees when something fails. V6 introduced `friendlyError`; this pass checks the remaining paths and adds two
central safety nets. Verified by `v62_adversarial_ui_test.py`: ERR1–ERR4, LINK1–LINK4 and ASSET1.

## Layers

| Layer | Where | Behaviour |
|---|---|---|
| Server messages | RPCs raise 22023 / P0001 / P0002 / TL… / explained 42501 | Written for players; shown as they are. |
| Domain mappers | `*-api.js` (`classError`, `spellError`, `lineageError`, `backgroundError`, `creatureError`, inventory `normalizeError`, DM / feat / governance) | Server messages stay. Technical texts go through `friendlyError`, with a per-domain fallback such as "The spells could not be changed. Nothing was changed." The raw error stays on `.raw` / `.code` for the console. |
| `friendlyError` (`js/utils.js`) | every mapper and the sign-in screen | Network, expired session, serialization / lock, timeout, RLS / permission, duplicate, constraint / invalid input, missing function / relation, and **(new)** PGRST116 "not found or no access" each become one sentence that says what happened and that nothing was changed. |
| **Error toasts (new)** | `toast(msg, 'bad')` | The last line of defence: whichever of the ~70 call sites raised it, an error toast is passed through `friendlyError`, so database wording cannot reach the screen. |
| **Unhandled promise failures (new)** | `window` `unhandledrejection` | Shown as an error toast in words, with the original in the console. Navigation aborts are ignored. |
| **Load failure screen (changed)** | `renderError` in `js/app.js` | Before: the raw error text was shown in a `<pre>`, e.g. "JSON object requested, multiple (or no) rows returned". Now: a friendly line, **Reload**, and **Back to your characters**. The raw error goes to the console. |
| Autosave | `js/store.js` | Unchanged since V6: transient failures retry with the status "Save failed — retrying" / "Offline — will sync", and permanent errors (22xxx, 23xxx, 42501, 42703, PGRST1xx/2xx) stop retrying and say so. |
| Import | `js/transfer.js` | **(new)** The core rows are all-or-nothing: on failure the partial character is removed and the toast says "Import failed: … Nothing was imported." |
| DM content validation | `_dm_try` (SQL) | **(new)** Foreign-key, not-null, check, unique and invalid-input failures become DM-readable sentences instead of constraint / column names. |

## Scenarios checked in the browser

| Id | Injected failure | Result |
|---|---|---|
| ERR1 | `get_character_derived_stats` answers 500 with "relation … does not exist" | The sheet renders (6 tabs, HP card) and no database text is on the page. |
| ERR2 | an action answers 401 `PGRST301 JWT expired` | The toast says "Your session has expired. Sign in again; nothing was changed." |
| ERR3 | an action answers a 23514 check-constraint text | The toast says "Some of the data is not valid. Nothing was changed." with no constraint or table name. |
| ERR4 | all of the above | No uncaught page error. |
| LINK1–3 | `#/c/<unknown uuid>`, `#/c/not-a-uuid'<script>`, `#/c/<someone else's character>` | The same "could not be loaded" screen for all three, so it does not reveal whether a character exists. No database wording; the way back works. |
| LINK4 | `#/campaigns` as a player | No admin data and no error. |
| ASSET1 | every icon (`.webp`, `.svg`) and font (`.woff2`) request aborted | The sheet still has its tabs and actions, and there are no page errors. A failed icon tries its fallback, then the generic icon, then stays an empty image; its label stays in the text or `aria-label` (icons.js). The fonts fall back to the system stack. |
| INT1 / OFF1 | autosave PATCH aborted / browser offline | The status says so, the edit is kept, and it saves after the network is back. |

## Remaining

- Messages from server functions are trusted to be player-facing. A future server message that includes internal names
  would be shown as written. Server functions are reviewed when they are added.
- The service worker / offline cache is not part of the app: a sheet that was never opened is not available offline. A
  cached sheet opens read-only with a toast.
