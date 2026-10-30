# Frontend read cache (`js/read-layer.js`, release 2026-10-30)

Small, explicit, vanilla. No framework, no persistence of character data.

## Pieces

| Piece | What it does |
|---|---|
| Feature flag | `js/config.js` `FLUENT_READS = 'on' | 'off'`. Per-browser override for controlled testing: `?fluent=1`, `?fluent=0`, `?fluent=default` (stored as `tl-flag:fluent-reads`). The flag selects the transport only; authorization is always the database's. |
| Automatic fallback | if a fluent function is missing or unusable (`PGRST202`, `42883`, …), `markFluentBroken` switches the page to the legacy path for the rest of the session; the current open is retried on the legacy path. Never a mix inside one sheet (`sheetFluent` is fixed at mount). |
| Debug info | `window.__tavernLedgerReadPath = { path, configured, override, fallback }`; `.sheet-root[data-read-path]`. No data, no secrets. |
| View fetch + dedupe | `fetchView(user, character, tab)`: one `get_character_view`; a prefetch or in-flight request for the same key is shared and consumed by the open. |
| Home prefetch | hover ≥ 150 ms, keyboard focus or pointer down on a card → `prefetchView`; newest hover aborts the previous one; ≤ 2 kept; 5 s lifetime; skipped with Save-Data / 2G; the view only (no mutation). |
| Scope + seeds | per mounted sheet (`beginReadScope` / `endReadScope`): the view's reads are seeded; each loader's existing RPC call is answered from its seed once (≤ 30 s), so loaders keep their own stale-response guards and sequencing. |
| Coalescing + in-flight dedupe | `get_character_*` reads of the open character issued in the same tick become one `get_character_reads`; the same read requested twice joins the pending batch. Different characters, writes and catalog reads are never intercepted. |
| Cancellation | the scope owns an `AbortController`; closing or switching the sheet aborts the view, pending batches and their callers (as `read-control.js` does for the legacy reads). |
| Per-character domain cache | the sheet's state (shell sections, spellbook, inventory panel) stays in memory while the sheet is mounted; revisiting a tab sends nothing; a revision event invalidates only its domain. |
| Catalog caches | session caches keyed by function (Background list/details, class/lineage/spell references) register `onUserCachesCleared`; cleared with the user's reads. |
| Sign-out / session end | `clearReadCaches()` (views, prefetches, seeds, picker caches) + `cacheClear()` on sign-out; on any session end (other tab, expiry) the user-data keys `list`, `bundle:*`, `cardstats:*` are removed as well. |
| No persisted character data | the fluent path never writes `bundle:<id>` (the legacy offline copy) and deletes existing ones at start; Home keeps its small per-version card stats (`cardstats:*`, max HP / AC / lineage name), cleared at session end. |

## Query keys (as implemented)

| Key | Lifetime |
|---|---|
| `view:<user>:<character>:<tab>` | prefetch 5 s; consumed by the open |
| seed `<read name>` in the scope of `<character>` | one use, 30 s, until the sheet closes |
| batch `<character>`: set of read names | one tick |
| revision `<character>:<source table>` | while the sheet is mounted |
| `background-list` / `background-detail:<version>` | session, cleared at sign-out |

## Tests

`supabase/tests/browser/fluent_read_ui_test.py` (31 checks): one request per open; no per-widget reads; 2 bindings; tab
bundles; cached tabs; A→B→C without stale render; prefetch reuse; Background list/detail; HP across sessions without a
derived re-read; revision-driven list refresh; reconnect = 1 reconciliation; no `bundle:*` in localStorage; unrelated player
denied; sign-out clears; `?fluent=0` legacy; automatic fallback when `get_character_view` is missing; no console errors.
