# Fluent read release: security review (2026-10-30)

Scope: migration `20261030000100_fluent_read_architecture.sql`, `js/read-layer.js` and the frontend changes that use it.
Result: **no new exposure found**; every new read is an existing RLS-filtered read run as the caller.

## New database objects

| Object | Security | Grants | Authorization |
|---|---|---|---|
| `get_character_view`, `get_character_bundle`, `get_character_reads` | INVOKER, `search_path = public, pg_temp` | `authenticated`, `service_role`; revoked from `anon`, `public` | `auth.uid()` required and `can_access_character(p_character)` before any read (`42501`); ≤ 40 reads (`22023`) |
| `_character_read` | INVOKER, pinned | same | allowlist of read names (`22023` otherwise); each read is an existing RPC (its own checks) or an RLS-filtered table/view query |
| `_character_read_set` | immutable list | same | — |
| `get_background_list`, `get_background_detail` | INVOKER, pinned | `authenticated` only (catalog was anon-readable via `get_background_catalog`; unchanged) | RLS on `background_versions` |
| `character_revisions` (append-only change log) | RLS on; SELECT policy `can_access_character` | SELECT to `authenticated`; no INSERT/UPDATE/DELETE | — |
| `_bump_character_revision` (trigger) | DEFINER, pinned | revoked from everyone; runs only as a trigger | inserts change-log rows only (table name, character id); ignores characters that no longer exist; prunes rows older than 3 days |
| memo in `get_character_derived_stats`, `_derived_stats_levels` | unchanged security (INVOKER) | unchanged | key includes `current_user` and `auth.uid()`: a SECURITY DEFINER caller (owner, RLS bypassed) never shares a cached result with an invoker caller, and one viewer never with another; the token exists only inside one bundle call and one transaction |

No service-role path for ordinary reads; no change to any RLS policy, grant of existing objects, or existing function's
security mode.

## Hidden data

| Data | Why it cannot leak through the new path |
|---|---|
| Hidden conditions, unrevealed DM notes | not part of any shell read; their tables are not revisioned (a player cannot even learn *when* they changed) |
| Secret / unidentified items | `inventory_bundle` uses `v_inventory_detail` and `v_item_catalog` as the caller (same RLS / `_item_visible` as before); catalog rows only for items in the caller-visible rows |
| Derived values from hidden effects | computed by the same functions, in the same security context as the direct RPC (memo key) |
| Audit, change requests | `get_character_change_requests(p, false)` as before; audit not in the shell |
| Revisions | table name + counter of a character the caller can read |

Verified by: `fluent_read_tests.sql` (owner and campaign DM equality for every character, unrelated user and anonymous denied,
revisions invisible to others); POC B hidden-data checks (earlier task); production smoke (synthetic hidden condition + DM
note absent from every player response, present for the DM).

## Client

- The flag and `?fluent=` override change only the transport; a forged flag cannot read anything the database refuses.
- No character payload in localStorage on the fluent path; existing `bundle:*` copies are deleted at start; user-data keys
  are deleted at every session end; in-memory views, seeds and picker caches are cleared at sign-out / session end and when the
  signed-in user changes (`fetchView` keys by user).
- Seeds are bound to one sheet scope and one character, one-shot, ≤ 30 s; a reply for another character is never applied.
- Debug info (`window.__tavernLedgerReadPath`) holds no data or identifiers.
- Writes never go through the read layer (only `get_character_*` reads with exactly `{ p_character }` are intercepted).

## Residual risks

| Risk | Rating | Note |
|---|---|---|
| A bug in a future read added to `_character_read` | low | must be an RLS-filtered read; the equality test pattern applies |
| Revision trigger failure hides a change notification | low | writes never fail; the next event or a reconnect reconciles |
| Prefetch on shared devices | low | memory only, 5 s, same user |

## Test counts

See `docs/FLUENCY_PRODUCTION_DEPLOYMENT.md` §Results for the final numbers of every suite run for this release.
