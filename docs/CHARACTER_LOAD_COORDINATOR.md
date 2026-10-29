# Character load coordinator (incident 2026-10-23)

Code: `js/read-control.js`, `js/supabase.js` (RPC wrapper), `js/sheet.js` (`mountSheet` / `unmountSheet`, the loaders),
`js/app.js` (`openCharacter`, `route`, `handleSession`), `js/store.js` (`loadBundle`).

## Request lifecycle

1. `route()` (hash change) increments `routeToken` and aborts `bundleReads` (the previous character's stored rows).
2. `openCharacter(id)` creates a new `bundleReads` controller, shows the cached copy read-only (or unmounts the previous
   sheet and shows a spinner), and reads the bundle with that signal.
3. When the bundle arrives and `routeToken` is still the same, `mountSheet()` runs:
   `unmountSheet()` for the previous sheet -> `beginSheetReads(characterId)` = new generation + new `AbortController`.
4. The loaders (`loadDerived`, `loadClasses`, …) call the api modules. Every `supabase.rpc('get_character_*', {p_character})`
   for the open character gets the sheet's `AbortSignal` in the central wrapper (`readSignalFor`).
5. Every loader keeps its sequence guard (`derivedSeq`, `classSeq`, …) and checks `C().id === id` before rendering.
   `loadClasses` checks it between its stages too, so a superseded load does not start its next group of reads.
6. `unmountSheet()` (other character, leaving the sheet, sign-out, deep link) calls `endSheetReads()`: every in-flight
   character read is aborted; the sequence counters are bumped, so a response that still arrives is dropped.

## Cancellation rules

| | Aborted on switch / leave / sign-out | Why |
|---|---|---|
| `get_character_*` RPCs of the open character | yes | they only feed the closed sheet |
| bundle reads (`characters`, legacy lists) | yes (`bundleReads`) | same |
| inventory reads (`read()` in `inventory-api.js`) | yes, by the inventory controller's own `AbortController` | existing |
| shared catalogs and references (class, lineage, spell, background, feat) | **no** | cached per page and reused by the next sheet; aborting would only repeat the work |
| `get_character_*` for another character (DM party, transfer target) | no | not part of the open sheet |
| **every write** (HP, slots, resources, equip, attune, approvals, publish, import, Wild Shape) | **never** | writes complete or fail on the server; their response is applied to the original character only |

Verified locally on PostgREST 14 (production runs 14.18): when the client aborts, PostgREST cancels the statement
(a lock-blocked RPC disappeared from `pg_stat_activity` within 1.5 s of the abort). Aborting therefore saves database time,
not only bandwidth. A statement already finishing may still complete; its response is then dropped by the sequence guard.

## Writes during a switch

`openCharacter` awaits `saver.flush()` before reading the next character, so queued field edits of A are sent first.
An RPC write started on A (damage, slot use) is not aborted; its `.then` renders through the loaders, whose guards
(`C().id === id`) drop it when B is open. Realtime and the next read of A reconcile A. Test: incident suite check 9.

## Errors

A cancelled read is not an error: `isAbortError()` recognises it; loaders only log when their sequence is still current
(it never is after an abort), pickers ignore it, `openCharacter` returns silently when its signal was aborted.
A failed **current** read keeps the previous behaviour (console warning, the section keeps its last state).

## Save retries

`store.js` saver: failed field saves are retried with backoff (2, 4, 8, 16, 30 s). After 6 failed attempts the edits stay
queued (nothing is lost) and the status shows "Not saved yet — retries on your next edit"; the next edit, the browser
coming online, hiding or closing the tab send them again. Before the fix a statement timeout (57014) was retried every
30 s for as long as the tab stayed open.
