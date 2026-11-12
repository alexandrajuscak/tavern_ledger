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
`character_conditions_tests.sql` (CC1–CC20, LK1–LK16) and `browser/conditions_ui_test.py` cover the conditions and tags
below, including the leak checks.

## Conditions and tags on the sheet (20261112000200)

`character_conditions` is the only store of a character's conditions. A row is an SRD condition (`kind = condition`,
`condition_key`), Exhaustion (`kind = exhaustion`, `level` 1–6, one per character and visibility) or a tag (`kind = tag`,
`tag_type` resistance / immunity / vulnerability with an optional `damage_type_id`, condition_immunity, blessing, curse,
other), with an optional `note`, `duration_text`, timer, `hidden` flag and DM note (`character_condition_secrets`).
`source` says who applied it: `dm`, `combat` (carried at Finish), `player` or `legacy_sheet` (copied from the old list).
They are **reminders only**: no derived value (AC, speed, saves) reads them. The reminder text is the SRD summary of
`combat_conditions` for the campaign's ruleset.

- RPCs: `apply_character_effect(character, spec)`, `update_character_effect(condition, patch)`,
  `remove_character_condition(condition)`, `get_character_conditions(character)` (the caller's view; also the read
  `get_character_conditions` of `get_character_reads`, never stored in `tl_cache`). The 6-argument
  `apply_character_condition` stays for DM Space and `dm_assign_content`.
- Rights: hidden rows and DM notes are the DM's only (a player gets "not found"). A player adds, changes and removes only his
  own visible rows (`player`, `legacy_sheet`); DM and combat rows need the DM (`42501`). Only the DM hides or reveals.
- `characters.conditions` is a mirror of the VISIBLE rows (home card, export, Wild Shape panel, combat, `?fluent=0`),
  rewritten by a trigger only when that list changes. A client that still writes the list directly (one release) is
  translated into its own rows; DM, combat and hidden rows are never touched by it.
- No side channel for hidden changes: they write no `character_revisions` row (three WHEN-guarded triggers) and never update
  the `characters` row, and `character_conditions` is not in the `supabase_realtime` publication (its DELETE events are not
  RLS-filtered). Residual, accepted: a hidden change still bumps the character's `tl_cache` counter (every table with a
  `character_id` does; hidden audit rows did already), so the next `get_character_reads` of any viewer reports cache misses.
