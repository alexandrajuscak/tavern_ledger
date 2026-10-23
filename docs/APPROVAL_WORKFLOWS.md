# Approval workflows (change requests)

When a campaign rule says `approval_required` (see [DM_GOVERNANCE.md](DM_GOVERNANCE.md)), the player's change is not applied;
it becomes a **change request** the DM reviews. Migration `20261019000200_change_requests.sql`; feat operations are added by
`20261019000300_feat_catalog.sql`. UI: `js/request-ui.js` (player) and the Approvals section of the DM Space
([DM_SPACE.md](DM_SPACE.md)).

## What a request is

A request belongs to one character and holds an ordered list of **operations**. Every operation is one call of an existing,
governed domain RPC registered in `change_request_ops` with a typed argument list (`"int!"` = required integer, `text`,
`jsonb`, `uuid`, and row references `class_row`, `source_row`, `spell_row`, `feat_row`, `char_inventory`). Nothing else can
be proposed: no free SQL, no direct table patch, no argument the RPC does not have. The character argument is always the
request's character, and every row reference is checked to belong to it. Symbolic references `$class:<class id>` and
`$class_source:<class id>` let one level-up request add a class and then make that class's choices.

| Op | Domain RPC | Action |
|---|---|---|
| Class and level | `set_character_class` | `build.class_level` |
| Remove a class | `remove_character_class` | `build.class_remove` |
| Subclass | `set_character_subclass` | `build.subclass` |
| Class feature choice | `set_character_feature_choice` | `choice.class_feature` |
| Optional feature | `set_character_optional_feature` | `choice.optional_feature` |
| Lineage / clear | `set_character_lineage`, `clear_character_lineage` | `build.lineage` |
| Background / clear / equipment | `set_character_background`, `clear_character_background`, `apply_background_equipment` | `build.background` |
| Class starting equipment | `apply_class_starting_equipment` | `inventory.add_mundane` |
| Proficiency | `set_character_proficiency` | `build.manual_proficiency` |
| Ability scores, max HP, manual values | `update_character_build` | `build.*` per field |
| Spell / remove a spell / source | `set_character_spell`, `remove_character_spell`, `save_character_spellcasting_source` | `spell.*` |
| Feat / remove / choices | `assign_character_feat`, `remove_character_feat`, `set_character_feat_choices` | `choice.feat` |
| Item | `add_inventory_item` | `inventory.add_magic` (or the item's action) |
| Companion | `add_character_companion` | `build.companion` |
| Seen Wild Shape forms | `set_seen_forms` | `runtime.mark_seen_form` |
| Long rest | `long_rest_character` | `runtime.long_rest` |

`update_character_build(character, patch)` exists so that the direct build fields of the sheet (abilities, max HP, speed,
manual bonuses) have one governed RPC a request can carry; the sheet's autosave uses it when a direct write is refused.

## Lifecycle

```
draft ──submit──▶ submitted ──approve──▶ approved ──apply──▶ applied
  ▲                 │   │                               └──▶ apply_failed ──retry──▶ applied
  └──── return ─────┘   ├──reject──▶ rejected
  returned_for_changes  └──cancel──▶ cancelled (player)        superseded (replaced by a newer request)
```

* **Draft / pending tray.** `add_change_request_op` appends an operation to the player's open draft for the character (one
  open draft per character and requester; the constraint is checked at commit so "Ask your DM" can send a separate request
  while a tray draft exists). `update_change_request` edits a draft or a returned request.
* **Submit** (`submit_change_request`, or `create_change_request(..., p_submit => true)`) runs a full **preview** first and
  refuses a request whose preview fails (with the domain RPC's own message).
* **Preview** (`preview_change_request`): the operations are applied inside a sub-transaction as the caller (with the GUC
  `tavern.gov_preview` set to the character, so `approval_required` gates pass only inside the preview), a review snapshot
  (`_cr_snapshot`) is taken before and after, the structured diff (`_cr_diff`) and warnings are returned, and the
  sub-transaction is rolled back (`TLPRV`). Nothing persists.
* **Stale detection.** At creation the request stores `_cr_baseline(character)` and its md5. Before a DM approves, the
  character row is locked and the baseline compared; a request whose character changed since (a DM correction, another
  approved request, a level change) is marked stale and cannot be approved until it is **refreshed**
  (`refresh_change_request`: re-based on the current character, with a new preview). Retry re-checks staleness as well.
* **Review** (`review_change_request(request, decision, note, expected_revision, edited_ops, private_note)`): `approve`,
  `reject` or `return`. Exactly one review succeeds (row lock + status + revision). With `allow_edit_and_approve` the DM can
  approve an edited version (`p_edited_ops`, needs a note; the player sees both versions). Reject and return always need a
  note for the player; `require_approval_note` makes a note mandatory for every approval too. `p_private_note` stores a
  DM-only note.
* **Apply** (`_cr_apply`): runs the approved operations, in order, through the same domain RPCs inside one sub-block with
  `tavern.gov_apply` set. A failure rolls the whole application back and marks the request `apply_failed` with the error;
  the DM fixes the cause and calls `retry_change_request`. A lock that blocks the action (set after the request was sent)
  makes the apply fail safely: the DM unlocks or rejects.
* **Idempotency.** `create_change_request(..., p_idempotency_key)` returns the existing request for the same requester and
  key (double clicks, retries after a network error).

## Visibility

* Players see requests of their own characters (`get_character_change_requests`), with the DM's public note. DM-only notes
  are in `change_request_private_notes` (never in a player read model, never in Realtime).
* DMs see the campaign inbox (`get_campaign_change_requests(campaign, statuses, character, ...)`).
* `change_request_events` is the history (created, edited, submitted, returned, resubmitted, approved, rejected, cancelled,
  superseded, applied, apply_failed, stale, refreshed). Permanent changes made outside requests (DM corrections, ungated
  player actions) are written to `campaign_audit_events` by the `_audit_build_change` triggers; `get_campaign_audit` reads it
  (players: their own characters, no DM-only events).
* Realtime publishes `change_requests` (row-level security applies), so the player's tray and the DM's inbox update live.

## Tests

`supabase/tests/classes/governance_tests.sql` (A1–A32: create, tray, preview, return, resubmit, approve, reject, stale, edit
and approve, apply failure rollback, lock during apply, idempotency, deferred one-draft rule),
`supabase/tests/governance_concurrency_test.sh` (two DMs approving at once, approve vs. DM correction, approve vs. lock),
`supabase/tests/api/governance_api_test.py`, `supabase/tests/browser/dm_space_ui_test.py` (DS17–DS29).
