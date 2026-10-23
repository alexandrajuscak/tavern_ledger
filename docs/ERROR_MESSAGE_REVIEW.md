# Error message review (V6 hardening, 2026-10-22)

## How errors reach the player

| Path | Before | After |
|---|---|---|
| Inventory RPCs (`js/inventory-api.js` `normalizeError`) | Already mapped: validation, not found, permission, concurrency, conflict, network | Unchanged |
| Class and spell RPCs (`classError`, `spellError`) | Server messages shown; 42501 mapped; a raw `23505` constraint text could pass | `23505` goes through `friendlyError()` |
| Feats, DM Space, governance (`feat-api`, `dm-api`, `governance-api`) | `error.message` shown as it came (database and PostgREST texts included) | `friendlyError()` |
| Autosave of sheet fields (`store.js` saver) | Every non-governance failure retried forever: "Save failed — retrying" | A permanent refusal (SQLSTATE 22xxx, 23xxx, 42501, 42703, PGRST1xx/2xx) stops: toast "Not saved: …", the sheet reloads the stored values. Network and concurrency errors are still retried with backoff |
| Governance refusals (TLAPR, TLDMO, TLDIS, TLLCK) | "Ask your DM" dialog or refusal message | Unchanged |
| Slots (`friendlySlotError`) | Mapped ("Nothing was spent", "already full", network) | Unchanged |

## The rule (`friendlyError()` in `js/utils.js`)

The server's own functions raise messages written for players:
- SQLSTATE 22023 (812 raises in the migrations);
- P0001 (498 raises without an explicit code);
- P0002, the TL… codes, and most 42501 and 23505 raises.

These are shown as they are.

Technical texts are recognised by their wording and replaced:

| Technical text (examples) | Player message |
|---|---|
| `Failed to fetch`, `NetworkError`, `Load failed` | Could not reach the server. Nothing was changed; check the connection and try again. |
| `JWT expired`, `PGRST301` | Your session has expired. Sign in again; nothing was changed. |
| `could not serialize`, `deadlock detected`, 40001, 40P01, 55P03 | Someone else changed this at the same time. Nothing was changed; please try again. |
| `canceling statement due to statement timeout` (57014) | The server took too long. Nothing was changed; please try again. |
| `new row violates row-level security policy …`, `permission denied for table …` | You are not allowed to do that here. Nothing was changed. |
| `duplicate key value violates unique constraint "…"` | That already exists. Nothing was changed. |
| `violates check / foreign key / not-null constraint`, `invalid input syntax`, `out of range` | Some of the data is not valid. Nothing was changed. |
| `Could not find the function …`, `relation/column … does not exist`, PGRST20x | This action is not available on this server version. Nothing was changed. |

The original error (code, message, details) goes to the developer console as `[server] …`. Audit events are written by the
server and are not affected. No message reveals a table, column, constraint, function or policy name.

## Feedback timing

- Error toasts stay at least 6.5 s and are announced assertively (`role="alert"`). Other toasts are polite and last 3.2 s.
- An identical toast that is still visible is not added again, and at most three toasts are shown, so one operation gives
  one message.
- Messages near the action stay where they were (slot status lines, picker errors, form validation in the editors).

## Inventory of messages reviewed

| Area | Example | Verdict |
|---|---|---|
| HP | "Enter an amount first", "Took 10 damage: 26 / 44.", "Healed 5: …" | Clear |
| Slots | "No 3rd-level slot left. Nothing was spent." | Clear |
| Governance | "Your DM approves level-ups in this campaign …", "Only your DM changes levels in this campaign." | Clear |
| Locks | "Your DM has paused progression for this character." | Too generic for a build or full lock: now per lock mode |
| Save refusal | "Save failed — retrying" (forever) | Replaced (see above) |
| Network | "Could not reach the server …" | Clear |
| DM content validation | field-level messages from `validate_dm_content` | Clear (unchanged) |

Test: `v6_product_hardening_ui_test.py` Z7 and Z7b (a refused save shows plain words without the constraint name and is not
retried).
