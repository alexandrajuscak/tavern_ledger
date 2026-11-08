# Combat Builder: Realtime, revisions, reconnect and concurrency

## One channel per open encounter

`js/combat-api.js` `subscribeEncounter` opens **one** channel (`combat-<encounter>-<random>`) with three bindings:

| Binding | Filter | Why |
|---|---|---|
| `combat_changes` INSERT | `encounter_id=eq.<id>` | Every committed combat change of the encounter (another DM window, Undo, a turn) |
| `characters` UPDATE | `id=in.(<linked character ids>)` | HP changed on a player's sheet (or by this or another DM window): patched from the payload, no read |
| `character_revisions` INSERT | `character_id=in.(<linked character ids>)` | A Wild Shape form started, ended or changed: that one combatant is re-read |

The tracker never subscribes per table or per row. The perf probe counts one channel per DM window. The character sheet
keeps its own existing two bindings, and the HP RPC writes the same `characters` row they already listen to. There is no
event loop: a mutation's own answer patches the view, and the Realtime echo of the same values changes nothing (patching
is idempotent).

## What a change row carries

`combat_changes`: `id`, `encounter_id`, `domain` (`encounter`, `turn`, `participants`, `hp`, `effects`, `reminders`), `kind`,
`participant_id`, `player_visible`, `changed_at`. **No names, HP, notes or effect text.** Realtime applies the table's
select policy per subscriber (`_combat_can_see`), so players and unrelated users receive nothing.

The `player_visible` flag is for the future player view: it is false for changes about hidden combatants and DM-only
effects. That view must still re-read through `get_combat_player_view`, never trust the flag alone.

## Targeted refresh

| Incoming | Action |
|---|---|
| `hp` with a participant id | `combat_get_participant` (one row + its effects) |
| anything else (turn, participants, effects, encounter, reminders) | `combat_get_encounter` (light rows, about 28 ms server time) |
| several within 180 ms | coalesced into one refresh |
| `characters` UPDATE | the HP / Temp HP / death saves of that combatant are patched in place |
| `character_revisions` from `character_transformations` | `combat_get_participant` for that combatant |

Stat blocks, history and the monster library are never part of a refresh. They load on demand.

## Revisions

| Revision | Where | Used for |
|---|---|---|
| `combat_encounters.turn_rev` | every turn move | expected value of Next / Previous / Choose turn / reorder during combat; a stale move is the friendly conflict TLCMB |
| `combat_encounters.rev` | structure changes | optimistic check of `combat_update_encounter` |
| `combat_participants.rev`, `combat_effects.rev` | every row change | optimistic checks of `combat_update_participant` / `combat_update_effect` |
| `combat_changes.id` | every committed change | the client's `lastChange`; the reconnect summary |
| `combat_events.request_id` | every mutation | duplicate protection: a repeated request returns the stored answer |
| Linked character | `characters` row + `character_revisions` | the sheet's existing model |

Combat writes never touch the read-cache counters (`tl_cache_rev` → `tl_cache.combat_skip`). A turn or a monster's HP
invalidates nothing; see [COMBAT_DATA_MODEL.md](COMBAT_DATA_MODEL.md).

## Persistence, offline and reconnect

- **The encounter lives in the database.** A refresh, sign-out and sign-in, a Docker restart or another device resumes
  exactly (round, turn, Initiative, HP, effects, hidden state, Reactions, notes). Pause / Resume never rerolls,
  rebuilds HP, or applies real time that passed.
- **Nothing hidden in the browser.** Only the chosen campaign and the "show archived" toggle are in `localStorage`
  (`tavern-ledger:combat-*`); no encounter payload is stored. The view is memory only and is dropped on sign-out
  (`unmountCombat`).
- **Offline.**
  - The browser's `offline` event, or a channel error, turns the view read-only: a banner ("Connection lost. The
    encounter is read-only…"), Retry, and the dock / HP / quick buttons marked disabled.
  - `mutate()` refuses to send ("No connection… Nothing was changed."). No mutation is queued silently, no turn moves
    offline, and no HP is shown as applied before the server confirmed it.
- **Reconnect.** When the channel is subscribed again, `combat_get_changes(since lastChange)` returns the changed
  domains, participants and turn revision, and the view reloads only if something changed.

## Concurrency and lock order

Every combat mutation takes locks in this order (no trigger anywhere reverses it):

1. `combat_encounters` row:
   - `FOR NO KEY UPDATE` for turns and structure;
   - `FOR SHARE` for HP, effects, reactions and reminders, so HP changes on different combatants run in parallel but
     never during a turn move.
2. `combat_participants` row(s): `FOR UPDATE`; several in id order (bulk damage).
3. The linked `characters` row: `FOR UPDATE`, taken by `apply_character_hp`. The Wild Shape functions take the same
   row lock first.
4. `character_transformations`, `tl_cache`, `character_revisions`: written by existing functions and triggers.
5. `combat_effects`, `combat_events`, `combat_changes`: inserts and updates last.

The sheet's path (`apply_character_hp` from the sheet) takes only lock 3, then 4. No path takes a character lock and
then a combat lock, so the two cannot deadlock.

`supabase/tests/combat_concurrency_test.sh` (11 checks) runs eight sessions × 40 operations on one encounter at the same
time:
- combat HP and sheet HP on one character;
- combat and sheet HP on a character in Wild Shape;
- monster HP;
- Next, Previous, and effect add/end.

**Result:**
- 0 deadlocks;
- no unexpected errors (turn conflicts are the friendly TLCMB);
- exact arithmetic on every HP pool;
- one request id sent 20 times in parallel is applied once.

The deadlocks reported in production on 2026-10-30 were in `tl_cache.put`, fixed by 20261031000200 (`put` never waits).
No combat RPC writes the read cache. The only cache writes the Combat Builder causes come from the DM's
`get_character_reads` summary calls, which use that fixed `put`.

## Multi-session tests

`supabase/tests/browser/combat_builder_ui_test.py`:
- S1–S4: the tracker's damage reaches the open sheet, and the sheet's Damage reaches the tracker, without reloads;
- RT1–RT2: a second DM window follows the turn; two windows clicking Next together never double-move;
- O1–O3: offline banner, nothing sent, recovery.

`combat_perf_probe.py`: one DM and six open player sheets; every sheet received the DM's HP change (222–669 ms
locally).
