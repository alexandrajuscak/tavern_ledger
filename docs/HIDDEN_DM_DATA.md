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
`character_conditions_tests.sql` (CC1–CC20, LK1–LK19) and `browser/conditions_ui_test.py` cover the conditions and tags
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
  RLS-filtered). Nor does it invalidate the player's cached reads (`cache.hits` of `get_character_reads` would show it):
  `character_conditions`, `campaign_audit_events` (visibility `dm`) and `dm_character_notes` (unrevealed) bump the character
  counter only for changes a player can see (`tl_cache.bump_visible()`), and `character_condition_secrets` has a skip trigger
  (`tl_cache.skip()`). No cached read reads these tables. See docs/V6_KNOWN_LIMITATIONS.md for the hidden tables not covered.
- Deploy order: migration first, then the frontend (an older server is detected and the sheet keeps the old list). On a
  rollback, the previous frontend first, then `supabase/rollback/rollback_character_conditions_unified.sql`.

## Identifying items: Examine (Herbs & Plants, 20261112000300)

A disguised item (most often a herb) shows the player only its **decoy** until that **character** identifies it. The player
rolls a check at the table and enters the **total**; the server never rolls and never returns the DC.

**DM options** (DM-only columns of `item_secrets`): decoy name and description, `face_kind_id` (the type shown while
unidentified: herbs show Herbs & Plants by default, other items hide their type), `identify_dc` (null: cannot be examined),
`identify_checks` (skill ids such as `nature`, `medicine`, or tool ids such as `herbalism-kit`; empty: any check),
`identify_reveal` (`all`, or parts: `name`, `description`, `details`, `magic`, `rarity`, `attunement`, `curse`, property
keys), `identify_auto` (reveal on roll >= DC without the DM), `identify_retry` (`dm`: only after the DM allows it (default),
`once`, `per_long_rest`: after a long rest recorded in `character_resource_events`, `unlimited`), `fail_hint` (shown after a
failure, may be wrong but plausible). **One source of truth per item:** DM Content keeps them in its definition (Content
editor, "Identification by players", synced on publish; New version → change → Publish). Every version has its own catalog
row, and copies of earlier versions that players hold follow the identification options of the version published last (when
its definition has identification fields; the decoy, curse and properties stay per version). For DM Content the DM Space
button opens the Content editor at that section and `set_item_identify_options` refuses it (55000). Campaign homebrew (`hb-`,
e.g. herbs made with the Inventory homebrew form) is set in **DM Space → Hidden → Identification settings**.
A campaign item with a disguise or a DC leaves the players' catalog (`items.secret`); its rows' stored stack keys are
recomputed when `items.secret` flips (no merge, no quantity change). Official
catalog rows cannot get options; giving an official item unidentified works only through DM Content (behaviour unchanged).

**Knowledge is per character.** `character_item_knowledge (character, item)` is the record; the character's disguised
inventory rows (`inventory_item_knowledge`) follow it: name and description become the truth for the parts revealed.
A new copy of an item the character already identified arrives identified. Transfer applies the receiving character's
knowledge in the same write; a split copies the knowledge row; a disguised stack merges only with rows of the same name and
knowledge (stack keys of other items are unchanged). A party stash row keeps its own knowledge.

**Flow.** `examine_inventory_item(row, check, roll total, request id)` (owner of the character): validates the check and the
retry rule, records an attempt (`item_identify_attempts`, idempotent on the request id). Auto: success reveals at once,
a lower roll fails at once (hint). Otherwise the attempt is pending: **DM Space → Hidden → Examine requests** shows the true
name, the decoy, the check, the roll and the DC; `resolve_identify_attempt(attempt, success | null = by the roll, corrected
roll, DM note, allow retry, reveal)` answers it exactly once (a failed attempt can later get "Allow another try").
`dm_reveal_item(item, characters | null = every character of the campaign, reveal)` reveals manually; `dm_give_item(item,
characters, quantity, identified)` gives a campaign custom item (unidentified by default); `set_item_identify_options(item,
options)` stores the options; `get_campaign_identify_attempts(campaign, status)` is the DM inbox. Every visible change
(attempt, answer, reveal) writes a `character_revisions` row, so the player's open sheet refreshes; a hidden option change
writes none and does not touch the cache counters (`item_secrets` → `tl_cache.skip()`). A change of
`inventory_item_knowledge` bumps the cache counter of every character holding a row of that item, never the global counter
(`tl_cache.bump_item_knowledge()`: cached reads see `items` through RLS, which depends on the knowledge rows). A duplicate
examine request (same request id), also a concurrent one, replays the first attempt.
Known (T4b): an identified row deposited in a party stash keeps its own knowledge, so stash readers see its true name.

**What a player reads before a reveal.** `v_inventory_detail` (and the inventory bundle of `get_character_reads`) masks an
unidentified instance for a non-DM caller: `item_id`, `category_id`, `rarity_id`, `is_magic`, `requires_attunement` are null,
`kind_id` is the face type, `stackable` / `is_consumable` stay (Use and quantity controls), `knowledge_state` is appended.
The bundle's catalog part follows the masked rows. `get_character_item_knowledge` adds `kind_id`, `description`, revealed
`details` and `identify` (`enabled`, `checks` with labels, `can_examine`, `last` attempt with the hint after a failure).
`use_inventory_item` returns no effects, the face type and no item id for an unidentified item ("your DM tells you what
happens"). An unidentified add is INSERTED with the disguise, so the Realtime INSERT never carries the true name.

**Residual (documented, not closed).**
- The raw `inventory_items.item_id` is still readable: REST table select, the Realtime payload of `inventory_items`, and
  the `?fluent=0` bundle. The same holds for `inventory_events.item_id`, which history stamping of deleted content matches on.
  Herbs and DM Content have opaque ids (`hb-<uuid>`, `cc-<hex>`) whose catalog row and child tables (effects, stats) stay
  hidden. An official item assigned unidentified keeps its readable slug (L3, parked).
- The catalog row is hidden **per user**, not per character: once one of a player's characters (or the party stash) holds an
  identified copy, that user can read the catalog row through `items` / `v_item_catalog`. The sheet, the view rows, the
  bundle and the knowledge read stay per character.
- Auto reveal with unlimited retries lets a player find the DC by trial (the default retry rule is `dm`).
- Old decoy copies are snapshots: editing the decoy later does not rename copies already handed out.
- An old official stack of an item that was once assigned unidentified (`items.secret`) merges with new copies only after it
  is next written (its stored stack key predates the name component).

Tests: `supabase/tests/classes/herb_identification_tests.sql` (HI1–HI32: options, give, INSERT row images, masked view,
knowledge read, REST closure, `get_character_reads` miss and hit + `tl_cache` rows, use, examine validation, pending,
DM inbox, corrected roll, retry rules, exactly-once, per character, hidden change without signal, auto + partial reveal,
merge, split, transfer, stack keys, reveal to one and to all, DM Content path) and `browser/herb_identification_ui_test.py`
(DM Space settings and give, decoy + Herbs filter, Examine, DM confirm, live reveal, second player still disguised,
devtools Realtime subscription and network capture without the truth, `?fluent=0`).

## Revealing items to characters (20261112000400)

One model for hidden items, unidentified items and herbs: `character_item_knowledge (character, item)` is what a character
knows, in the vocabulary above (`revealed[]` facts; `all` = identified). Its `updated_by` / `updated_at` are "revealed by / at".
**DM Space → Hidden → Who knows what**: pick an item and see every character of the campaign: what they hold (and under which
name), what they know now and why (from the copies they hold, an undisguised copy, remembered without a copy, never learned,
item not hidden), and the history. Levels: Nothing (hidden), Name only, Name + description, Everything; any other fact set shows
as "custom" and is kept.

- `dm_set_item_knowledge(item, characters, reveal, mode, campaign)` (DM of the campaign or admin). The character list is always
  explicit: "Reveal to the whole party" sends every character. Mode `raise` only adds knowledge; `set` sets that exact level,
  which can take knowledge away again (undo, "Hide from selected"). A lower level also disguises the character's undisguised
  copies (they get a knowledge row first, then follow the record), and the item becomes `secret`. Official items can be revealed
  but not hidden (`22023`: copy them to campaign homebrew first). A character whose level does not change writes nothing.
  Hiding a player-created item warns that its creator can still look it up in the catalog. `raise` skips a character who
  holds only an undisguised copy (they already see everything; nothing is written, the result says `skipped`). The rows and
  the record are locked without waiting: while the player is examining the item, the DM gets "The player is examining this
  item right now, try again in a moment" (nothing changed) instead of a wait or a deadlock.
- `get_item_knowledge_overview(item, campaign)` and `get_campaign_knowledge_items(campaign)`: DM-only reads. Another user's
  personal homebrew (no campaign) is reachable through these and `dm_set_item_knowledge` only while a copy is held in the
  campaign; otherwise they answer "Item not found" (`P0002`), exactly as for an unknown id.
- Before "Set" / "Hide" takes knowledge away, DM Space says who will still see the real item (other characters whose copies
  show it, a party stash / shop copy that shows it: undisguised, or identified before it was deposited) and warns when a chosen character has the item equipped: the player's sheet stops
  counting it (equipped armour falls back to unarmoured AC; derived stats read the catalog row as the player), while the DM's
  view keeps the full numbers.
- `item_knowledge_events`: append-only history of every record change, from every path (examine, DM answer, reveal, set,
  `set_item_knowledge`, transfer). DM-only (no grants; read through the overview), not in Realtime.
- The player side is unchanged: a player sees only what their own character knows (masked view row, knowledge read). A
  change writes one `character_revisions` row for that character only, so the open sheet refreshes live. The cache counter
  of other holders of the item moves (a counter, no data); the global counter moves only the first time an item becomes secret.
- The "Hidden" tab shows the number of examine requests waiting for the DM (`get_campaign_pending_examine_count`, a count only).
- Parked (needs a decision, see the night design note): party stash rows (they keep their own knowledge), official items given
  unidentified through DM Content, per-user catalog visibility, derived stats of unidentified magic items, fully invisible items.

Tests: `supabase/tests/classes/item_reveal_tests.sql` (IR1–IR21: refusals, validation, A sees / B does not, partial levels,
idempotency, raise vs set, whole party, undo, hiding an undisguised copy, the DM reads, history, backfill, another user's
personal item, raise on an undisguised holder, the NOWAIT locks, equipped armour after a hide, the examine count) and
`browser/item_reveal_ui_test.py`. `scripts/fluent/item_visibility_snapshot.sql` is a read-only hash of what each character's
owner and each user (every profile and campaign member) sees (run it before and after a deploy; the outputs must be identical).

## Identification is shared with the party (20261114000300)

Owner decision (phase 2): once one character identifies an item, every character of the campaign knows it, also characters who
join later. A campaign rule, **DM Space → Campaign rules → Item identification**, ON by default (a campaign without a row in
`campaign_item_rules` shares). Off = exactly the per-character model above. Switching it on catches the campaign up once;
switching it off never takes knowledge away.

- **Copy on write, no read-path change.** The record (`character_item_knowledge`) stays per character and the character's
  disguised rows keep following it. Every raise goes through `_identify_apply` (successful examine, the DM's answer,
  `dm_reveal_item`, `dm_set_item_knowledge` mode `raise`, crafting); it now pushes the character's record (unless the character is
  held, see the hold rule) to the other characters
  of the campaign (`_party_share_from` → `_party_apply_to`, which reuses the old body `_identify_apply_one`). Their rows are renamed
  as by any reveal; each changed character gets one `character_revisions` row (open sheets refresh) and a player audit line
  "Your party learned something about an item: <name as they now know it>" with no actor and no hint who identified it.
  `v_inventory_detail`, `_item_visible`, the bundle and Realtime are unchanged (no slower read, no new payload).
- **A failed or pending examine** writes nothing for anyone else.
- **DM choices win.** `dm_set_item_knowledge` mode `set` ("Set", "Hide from selected") and a lowering through the old per-copy
  editor mark the character **held back** for that item (`held_by_dm`): sharing skips it, and its record is never a source of the
  party level.
- **The hold rule (v31, owner decision).** A hold is lifted ONLY by `dm_release_item_knowledge_hold(item, characters, campaign)`
  ("let the party share", which also gives them the party level at once) or when the character's record ends up fully
  **identified** (their own full success, the DM's "reveal everything"). A **partial** raise never lifts it: the character's own
  partial examine success or the DM's partial answer (`_identify_apply`), the per-copy editor adding a fact,
  `dm_set_item_knowledge` mode `raise` with some parts, `dm_reveal_item` with some parts. Neither does a rule switch (off / on),
  a sync (sheet or DM), a joiner pull, or another character's reveal: party sharing never raises a held character, and a held
  character's partial facts never spread. Example (owner decision a): the DM hides an item from B, reveals only its name to B, and
  later A identifies it: B stays at "name only" until the DM releases B or reveals everything to B. In the DM's bulk calls the one
  party share at the end comes from the first raised character that is not held. "Set" is the DM's exact choice and always holds,
  also a "Set → Everything" (the character then simply is no source until a release).
- **The hold follows the character (m4).** It is stored per character and item, not per campaign: a character moved to another
  campaign stays held there for that (official) item until that campaign's DM releases it or reveals everything. Conservative and
  data-safe; homebrew items belong to one campaign, so this only concerns official items.
- **Joiners** (a new character in the campaign, or `campaign_id` changed) get the union of the non-held records of the other
  characters, for items of no campaign or of that campaign (trigger `characters_party_knowledge`).
- Skipped targets: a held character; a character who holds only undisguised copies (sees everything already). Party stash /
  shop rows keep their own knowledge (parked decision Q1). With the rule on, "Reveal to selected" also reaches the rest of the
  party; "Set" is the per-character tool.
- **History:** `item_knowledge_events.source = 'party_share'` and `source_character_id` (where it came from). "Who knows what"
  shows "known by the party (identified by X)", "held back by you" and "shared by the party, from X" in the history.
- RPCs (DM of the campaign or admin): `get_campaign_identification_sharing(campaign)`,
  `set_campaign_identification_sharing(campaign, on)`, `dm_release_item_knowledge_hold(item, characters, campaign)`,
  `dm_sync_party_knowledge(campaign)`; the character's owner, DM or an admin: `sync_party_knowledge(character)` (counts only).
  `dm_set_item_knowledge` also returns `party_share`, `shared_with` and per character `held`.
- **Data at deploy:** holds are derived by replaying the hold rule over the history (`_ik_derived_holds()`): a hold point is a
  DM audit line with mode `set` or ANY history event that took knowledge away; a lift is a later DM `release` line or a later
  event that reached `identified`; held = the latest hold point has no lift after it (so "hide, then a partial reveal" stays
  held, whatever the DM did last). Then every campaign is caught up (raise only, idempotent); a held character is never raised.
  Preview it read-only on production first: `scripts/fluent/party_share_preview.sql` (as postgres; a READ ONLY transaction,
  rolled back; ids and counts only, no item names): one `held` line per record that will be held and one `row` line per record
  the catch-up will change. Limit: before this release a "Hide" of a character who knew nothing yet changed nothing and wrote
  nothing, so such a hide cannot be derived; when the DM then revealed part of the item to that character, the catch-up gives it
  the party level. The preview marks those rows `DM-PARTIAL` (the DM's latest choice for that character was a partial reveal
  that the catch-up exceeds): review them before the deploy (the DM can hide the item from them again afterwards).
- **Locking (never wait on another character).** Inside the examiner's or the DM's transaction, a character that is not the
  transaction's own target is touched only in a subtransaction with a 200 ms `lock_timeout` (restored) and NOWAIT locks in the
  order of the existing RPCs: `characters` (key share) → `tl_cache.character_rev` → its rows (id order) → their row knowledge →
  its record. `tl_cache.bump_item_knowledge` takes other holders' counter rows NOWAIT: inside a party share a busy one defers
  that share; on the transaction's own target (an examine, the DM's answer or set) it falls back to one global bump (NOWAIT),
  and when that is busy too the call fails for that character ("busy"): a bump, and so a hide, is never skipped silently.
  Two-session test: `supabase/tests/party_knowledge_concurrency_test.sh` (7 cases; no 40P01, deadlock counter unchanged).
- **Pending party shares (the only thing ever queued).** A party share that finds its target busy is kept in
  `party_share_pending`: one row per character and item (merged: union of facts, the higher level), plain ids, no foreign keys,
  no grants. It is applied in the target's own context, with no actor and the usual history / audit line: the target's next
  `_identify_apply`, `sync_party_knowledge(character)` (the sheet calls it on open and after an inventory refresh, at most every
  20 s; one indexed lookup when nothing waits; m2: kept as one small POST per sheet open, because nothing the open already reads
  can tell whether a share waits: `party_share_pending` feeds no cached bundle on purpose, so a flag there would go stale) and **DM Space → Campaign rules → Sync party knowledge**. It is dropped, never
  applied, when the target is held back, left the campaign or was deleted (also removed by the join / leave / delete trigger),
  the rule is off, or a DM wrote that character's knowledge of the item after the row was made. Every DM write of a (character,
  item) deletes that pair's pending shares (without waiting: a row another transaction holds is skipped and dropped at apply). A pending share never lifts a hold and never lowers anything.
- **DM decisions are never queued.** In `dm_set_item_knowledge` (reveal, set, hide), `dm_reveal_item` and
  `dm_release_item_knowledge_hold`, a busy character is NOT changed: the call succeeds for the others and names it in
  `busy_names`; DM Space says "… were busy and were NOT changed. Try again." The DM's bulk calls share once at the end (O(N)
  guarded writes for N characters).
- **Only what was learned in this campaign is shared.** A character's shareable level in a campaign is the union of the facts its
  `item_knowledge_events` of THIS campaign added (`new_revealed − old_revealed`), and "identified" only when such an event
  reached it, capped by what its record knows NOW (knowledge the DM took back is never shared: identified only while the record
  is identified, otherwise only facts still in its revealed[]). A character moved to another campaign keeps what it knows, but only what it learns there spreads there, and
  coming back does not bring the other campaign's facts along (joiners, switch-on catch-up, sync, release, preview).
- A share never lowers a copy (the target's row knowledge is part of the union) and closes the target's pending examine attempts
  as "Learned from the party" (no resolver). A joiner gets one summary audit line; the joiner trigger never aborts the insert or
  the join (an error is only a warning, busy items stay pending).
- **Monitoring after the deploy (m3).** `tl_cache.bump_item_knowledge` takes other holders' cache counters NOWAIT; outside a
  party share, a busy one falls back to ONE global cache bump (`tl_cache.global_rev`), which invalidates every cached bundle (each
  character's next read recomputes it). Rare (only a short lock window), but a global bump is the pattern behind the earlier
  statement-timeout incident: watch `tl_cache.global_rev` for a few days after the deploy (it should move rarely).
- Rollback: `supabase/rollback/rollback_party_item_knowledge.sql` (keeps what characters learned; drops the rule, the holds and
  the history source). Tests: `supabase/tests/classes/party_knowledge_tests.sql` (PK1–PK31 and the reviewer's RV1–RV6; PK31
  checks that the deploy-time derivation finds exactly the live holds). `herb_identification_tests` and
  `item_reveal_tests` switch the rule off for their campaign: they cover the per-character model.

## Crafting (20261113000100)

DM-only in crafting ([CRAFTING_V1.md](CRAFTING_V1.md)): a recipe's DC (`check_dc`), the DM's recipe notes (`dm_notes`), the
critical-success and failure results, and an attempt's private DM note (`dm_private_note`). The four crafting tables have no
grants for players. Their only reads are RPCs, and the player read (`get_character_recipes`, the attempt answers) never
contains these fields.

A secret item the character does not know is shown as the DM's label, never its name or id. Only rows the character fully
knows (no knowledge row, or an identified one) count as ingredients. The player read is identical with or without an
unidentified matching row, and any unidentified selected row gets one fixed refusal. A result made "unidentified" is inserted
already disguised.

Tests: `supabase/tests/classes/crafting_tests.sql` (CR9, CR10, CR12) and `browser/crafting_ui_test.py` (CF-13 to CF-16: REST /
RPC bodies, websocket frames, DOM and storage of the player's page).