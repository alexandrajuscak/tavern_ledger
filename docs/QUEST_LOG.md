# Quest log

A quest log for the party: quests everyone shares, and quests of one character. Migration
`20261114000400_quest_log.sql` (rollback `supabase/rollback/rollback_quest_log.sql`), frontend `js/quests.js` (asset
marker `?v=32`).

## For the DM: DM Space → Quests

- **+ New quest**: a title, a description (players see it), who sees it, the status, objectives and DM notes.
- **Who sees it**
  - **Party**: every character of the campaign.
  - **Individual (party sees it)**: the quest belongs to one character (choose it), and the rest of the party sees it too,
    labelled with that character's name ("Yours" for its owner).
  - **Private (DM and one player)**: only you and the player of the chosen character. Other players never receive it.
- **Status**: Active, Completed or Failed. Players see active quests first, then completed, then failed.
- **Order**: ▲ / ▼ move a quest within its status. Players see the same order.
- **Objectives**: tick them in the list, or in the editor. **Only the DM ticks objectives** (default decision for this
  release: players read the ticks but cannot change them; a player who finished something tells the DM at the table).
  Removing an objective in the editor archives it; it is never deleted.
- **DM notes**: hidden. They are never sent to a player, not even on the DM's own view of a character sheet.
- **Archive**: hides a quest from players. Nothing is deleted: tick **Show archived** and click **Restore** to bring it back.
- If a character leaves the campaign, its individual quests stay in this campaign (shown "left the campaign" in DM Space)
  and the rest of the party no longer sees them; if it comes back, it sees them again. If a character is deleted, its
  individual and private quests stay, visible to you only ("character deleted"); edit them to give them to someone else.

## For the player: the Quests tab

The sheet has a **Quests** section (bottom bar on a phone). It lists the quests the character may see, grouped by status,
each with its status badge, who it belongs to (Party, Yours, another character's name, Private) and the objective progress
(for example 1/2). Tap a quest for its description and objectives (✓ = done).

The tab reads when it is shown, so it is never part of opening the sheet. There is no live push: switching back to the tab
(or **Refresh**) shows the DM's latest changes. A character sees the quests of its **current** campaign only.

## How it works (for maintainers)

| Table | Content | Player access |
|---|---|---|
| `quests` | campaign, title, description, status, visibility (`party` / `individual` / `private`), `target_character_id`, `sort_order`, `archived_at`, `revision` | none (no grants; RLS on) |
| `quest_objectives` | quest, order, text, done (+ when / by whom), `archived_at` | none |
| `quest_dm_notes` | the DM notes of a quest | none |

- **Reads.** `get_character_quests(character)`: one request, security definer, allowed for whoever may open the character
  (owner, the campaign's DM, admin) and always the **player view of that character**: quests of the character's current
  campaign, not archived, that are `party`, `individual` (target still in that campaign) or `private` with exactly this
  character as target. It never reads `quest_dm_notes`. A player removed from the campaign (whose character still points at it)
  gets an empty list; moving a character into a campaign its owner is not a member of is refused already (governance / the
  characters update policy). `get_campaign_quests(campaign, include_archived)`: DM / admin only,
  with notes and the campaign's characters.
- **Writes** (DM of the quest's campaign or admin, `42501` otherwise): `dm_save_quest(campaign, quest, expected revision)`
  (create / edit, objectives as the full ordered list, `40001` on a stale revision), `dm_set_quest_status`,
  `dm_set_quest_objective`, `dm_archive_quest(quest, archived)`, `dm_reorder_quests(campaign, ids)`. Every function has a
  fixed `search_path`; anon and PUBLIC cannot execute them.
- **No side channel.** The tables are not in the `supabase_realtime` publication and have no grants (no REST, no Realtime
  payload). The player read is not in `tl_cache` (`get_character_reads` never reads it); quest data lives only in the
  `js/quests.js` module's memory (never in `localStorage` or the legacy bundle cache).
- **Cache counters.** `tl_cache_rev` = `tl_cache.skip()` on all three tables: no cached read depends on them, so a DM quest edit
  never invalidates any character's cached reads (and never bumps the global counter). The target column is deliberately not
  named `character_id` (the coverage rule would then force `tl_cache.bump('character')`, and a party quest without a target
  would bump the global counter).
- **Why no live push.** A quest change could write a `character_revisions` row, but a sheet of `?v=31` would throw on an
  unknown source table (`onRemote`), and the reconcile loop would stop before other domains. `?v=32` ignores unknown sources,
  so a later release can add a live refresh once every open sheet is `?v=32` or newer.
- **`?fluent=0`** uses the same RPC.
- **Deploy order:** migration first, then the frontend. Rollback: the previous frontend (`?v=31`) first, then
  `rollback_quest_log.sql` (drops the three tables: export them first if they matter).

## Tests

`supabase/tests/classes/quest_log_tests.sql` (QL1–QL25: DM, owning player, other player of the party, player of another campaign
and anon; DM notes never in a player read; REST refused; not in Realtime; RLS and grants; security definer and search_path;
tick; ordering; objectives archived; validation and stale revision; archive / restore; campaign move both ways; cache counters
untouched; a deleted character's private quest stays DM-only; membership: no move into a foreign campaign, a removed player
sees nothing) and `supabase/tests/browser/quest_log_ui_test.py` (QU1–QU10: the DM
creates a party, an individual and a private quest in DM Space; player A sees all three, player B the party quest and A's
individual quest only; neither session receives a DM note, B never receives A's private quest (REST, websocket, DOM,
storage); one lazy request; a ticked objective shows for the player; `?fluent=0`; phone width; no console errors).
