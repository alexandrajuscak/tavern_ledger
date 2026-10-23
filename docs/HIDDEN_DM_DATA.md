# Hidden DM data

Information the DM knows and the player must not: secret notes, hidden conditions and timers, unidentified items, curses
and undisclosed item properties, DM notes on custom content and on requests. Migration `20261019000500_hidden_dm_data.sql`
(DM notes on content and requests are in `20261019000400` / `20261019000200`). UI: **DM Space → Hidden** ([DM_SPACE.md](DM_SPACE.md)).

## The rule

Hidden data lives **in rows a player's row-level security never returns**, not in columns the frontend promises not to
show. Player read models (RPCs) and Realtime cannot carry it either: Supabase Realtime evaluates the table's select policy
per subscriber, and the RPCs build their output from what the caller may read. The player's character JSON export never
includes hidden data; `export_campaign_dm_backup` (DM only) does.

## Tables

| Table | Player sees | DM sees |
|---|---|---|
| `dm_character_notes` | only notes the DM revealed (`revealed_at`, with the reveal text), via `get_character_revealed_notes` | all notes of characters in their campaign |
| `character_conditions` | visible conditions (`hidden = false`) of their characters | all, including hidden ones and timers (`expires_at`) |
| `character_condition_secrets` | nothing | the DM note of any condition |
| `item_secrets` | nothing | unidentified name / description, curse, hidden properties of a campaign item |
| `inventory_item_knowledge` | state (`unidentified`, `partially_identified`, `identified`), `magic_known`, `revealed` facts – never `true_name` (column grant) | everything |
| `items.secret` + `_item_visible` | the catalog row of an item that has an unidentified instance is hidden unless the player holds an identified instance | the item |
| `dm_content.dm_notes`, `dm_content_versions` hidden parts | nothing (players read published content through the catalog and `get_content_public_info`) | everything |
| `change_request_private_notes` | nothing | notes on a request |

An unidentified item instance carries only the disguise the DM chose (its custom name and description); the real item
row is invisible to the player until identified (`set_item_knowledge(inventory item, 'identified')` restores the true
name). Partial identification reveals chosen facts (`magic`, `rarity`, `attunement`, `curse`, or a property key).

## RPCs (DM of the character's campaign, or admin)

| RPC | Purpose |
|---|---|
| `save_dm_note(character, title, body, note, reveal_note)` / `delete_dm_note(note)` / `reveal_dm_note(note)` | secret notes; revealing shows the reveal text (or the body) to the player |
| `apply_character_condition(character, version, name, hidden, expires, note)` | a visible condition (players may apply visible ones: `runtime.conditions`) or a hidden one (DM only); optional custom condition definition and timer |
| `remove_character_condition`, `reveal_character_condition`, `set_condition_dm_note` | manage conditions |
| `get_character_conditions(character)` | what the caller may see (players: visible only, DMs: all with DM notes) |
| `set_item_knowledge(inventory item, state, revealed, magic_known)` | identification state of one instance |
| `set_item_secrets(item, secrets)` | secrets of a campaign item (also synced from a published custom item's `hidden` definition) |
| `get_character_item_knowledge(character)` | the caller's view (players: disguise and revealed facts) |
| `get_dm_character_hidden(character)` | the DM view of everything hidden on one character |
| `export_campaign_dm_backup(campaign)` | DM-only backup of the campaign's hidden data |

`_dm_hidden_gate` refuses everyone but the campaign's DM and admins (`42501`, "Only the DM of the character's campaign can
see or change hidden information").

## Tests

`supabase/tests/classes/dm_content_tests.sql` DC16–DC23, DC35 (item secrets, disguise, partial and full identification,
hidden conditions and notes through tables, read models and audit, reveal, DM backup), `governance_api_test.py` GA12, GA15,
GA19, GA23, GA32 (the same through PostgREST with the player's JWT), `dm_space_ui_test.py` DS14–DS16 (an unidentified ring
shows only its disguise to the player; after identification the true name, the curse stays hidden).
