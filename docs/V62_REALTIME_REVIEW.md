# V6.2 Realtime review

Measured locally by `v62_import_session_soak_test.py` (MS1–MS5, RT1–RT3). The local Supabase Realtime runs in Docker on the
same machine, so the latencies are lower bounds for a hosted setup.

## Subscriptions

| Channel | Created by | Filter | Removed |
|---|---|---|---|
| `character-<id>-<rand>` | `subscribeCharacter` (`js/store.js`) when a sheet mounts | `characters` UPDATE by id; INSERT / UPDATE of 21 child tables by `character_id`; DELETE of those tables unfiltered (see below) | `unmountSheet` → `supabase.removeChannel` |
| `requests-<id>-<rand>` | `js/request-ui.js` (change requests of the open character) | by character | when the sheet unmounts or the character changes |
| `dm-<campaign>-<rand>` | `js/dm-space.js` | by campaign | when DM Space unmounts or the campaign changes |

The random suffix keeps a fast re-mount from reusing a channel that is still closing.

## Measurements

| Id | Scenario | Result |
|---|---|---|
| MS1 | HP edited in browser A, same player in browser B | B updated (≤ 15 s budget; observed under 1 s) |
| MS2 | HP edited by the DM's sheet | both player browsers updated |
| MS3 | two browsers type different HP at the same moment | last write wins (stored 25). All three screens converge to the stored value; neither screen keeps a value that was not stored. |
| MS4 | sign-out in browser A | A sends no further data requests |
| MS5 | the same player still open in browser B | B keeps saving. Sign-out is global, so B's refresh token is revoked and it must sign in again when its access token expires (about 1 h). |
| RT1 | 40 DM edits in a row (one at a time, waiting for each) | **40 / 40 delivered, 0 missed**: p50 **511 ms**, p95 **532 ms**, max **538 ms** |
| RT2 | 10 home ↔ sheet cycles by in-app navigation | **20 joins, 20 leaves**: 0 extra channels left open |
| RT3 | an edit after the churn | still delivered |
| RT4 | the server side closes the socket and the DM edits HP before the client has re-joined | after re-joining the sheet reloads its stored values and shows the edit, with "Connection restored — showing the latest values." (ADV-MODERATE-020) |

The latency is steady at about 0.5 s with almost no spread. The app has no debounce on incoming events and applies an event
as soon as it arrives, so the delay is most likely the delivery cadence of the local Realtime `postgres_changes`. This was
not profiled further.

A full page load (typing a URL, F5) closes the socket without `phx_leave`. Realtime cleans those up on the server side, and
they are not counted as a client leak.

## Conflict policy

- **Runtime fields** (HP, coins, slots, resources) are last-write-wins per field. The autosave sends only changed fields,
  so two players changing *different* fields do not overwrite each other.
- **Permanent changes** under governance (standard / strict presets) go through change requests. Requests carry an expected
  revision and stale detection, and approval is atomic and idempotent: ATOM1, ATOM2 and IDEM1 in
  `v62_adversarial_api_test.py`, plus `governance_concurrency_test.sh`.
- Server functions that change counters (resources, slots, Wild Shape) lock the row and are covered by the four
  concurrency scripts in `run_local.sh` (slots, class resources, Wild Shape, governance).

## Known limits

- DELETE events of the 21 child tables cannot be filtered per character, so every signed-in client receives the primary
  keys of deleted rows. The handler ignores unknown ids. Only ids are sent, no content (ADV-FUTURE-015).
- Reconnect: `postgres_changes` does not replay missed events. Since V6.2 the sheet watches its channel status: after an
  error or time-out followed by a new `SUBSCRIBED`, it saves its own pending edits, reloads the stored values and says so
  (RT4). DM Space and the change-request panel re-read on their next action; they do not resync on reconnect yet.
