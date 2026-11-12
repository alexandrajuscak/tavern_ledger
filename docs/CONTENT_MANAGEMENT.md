# DM / admin content management (2026-11-09)

Extends the custom content lifecycle (`docs/CUSTOM_CONTENT_LIFECYCLE.md`, migration `20261019000400`) with a usage report,
safe permanent delete of unused content of every type and "Duplicate official as homebrew". Migration
`20261109000300_content_management.sql` (additive: four new functions, one lock-order fix in `dm_assign_content`); rollback
`supabase/rollback/rollback_content_management.sql`. Frontend flag `CONTENT_MANAGEMENT` in `js/config.js` (`'off'` keeps the
earlier buttons; the database authorizes every action regardless of the flag).

## Content types

| Type | Managed in | Lifecycle | Notes |
|---|---|---|---|
| spell, item, feat, creature / Wild Shape form, companion template, background, lineage, condition | DM Space → Content Library (`dm_content`) | full (below) | materialized into the catalogs with ids `cc-<hash>-v<n>` |
| custom items of a character / campaign (Homebrew item form) | Inventory → custom item editor (`items` owned rows) | edit, archive / restore, delete unused (`delete_custom_item`, `docs/CUSTOM_ITEM_DELETION.md`) | unchanged in this release |
| custom combat monsters | Combat Builder encounter ("Add custom") | an encounter snapshot only (`combat_statblocks`), lives and dies with the encounter | unchanged |
| custom classes / subclasses | — | **not supported** by Tavern Ledger (no authoring model); not added | documented limitation |

## Lifecycle

```
DRAFT (edit in place) ─validate─▶ VALIDATED ─publish─▶ PUBLISHED VERSION (immutable, used by assignments)
   │                                                        │  ├─ new version ─▶ DRAFT v2 ─publish─▶ PUBLISHED v2 (v1 superseded, kept for its users)
   │                                                        │  └─ archive ─▶ ARCHIVED (no new picks; existing assignments keep working) ─restore─▶ PUBLISHED
   └──── delete permanently (only SAFE TO DELETE) ◀─────────┘
OFFICIAL CONTENT: never edited or deleted; "Duplicate as homebrew" creates a new campaign DRAFT with its own id.
```

Editing rules: a draft is edited in place; published content is never changed in place (`TLPUB`) — the editor offers **New
version** (characters keep their version; new assignments use the newly published one); an archived version stays readable and
can be restored or used as the base of a new version. Running and completed encounters keep their own snapshot of a creature.

## Usage report (`get_dm_content_usage`)

Counts only, never names. Every published version of the content is counted:

| Kind | Counted |
|---|---|
| spell | characters' spells, free-cast counters, feats granting it, class features granting it |
| item | inventory instances, equipped, attuned, inventory history, owned assets, background equipment, proficiencies, items based on it |
| feat | direct assignments, saved feat choices, lineage feat picks (`feat:<id>`), ASI feat picks, backgrounds granting it |
| creature / companion | Wild Shape forms known, form favourites, companions, active transformations, running / planned encounter snapshots |
| background / lineage | assignments, saved choices, background equipment |
| condition | applied conditions |
| all | pending change requests, other content naming it; history: completed encounter snapshots, character audit history, earlier assignments |

Classification: **SAFE TO DELETE** (nothing uses it, nothing remembers it) · **ARCHIVE RECOMMENDED** (unused now, but part of
the campaign history) · **DELETE BLOCKED** (in use) · **NEW VERSION REQUIRED** (published and in use: edit through a new
version). The report also says whether the caller may delete (`can_delete`) and archive.

Foreign keys that would CASCADE into player data if a catalog row were deleted — `character_feat_choices`,
`character_seen_forms`, `character_form_favorites`, `character_background_choices` — and references without any foreign key —
lineage / ASI feat picks, a background granting a custom feat, other content naming the id, combat snapshots, pending requests —
are all counted, so a delete can never silently remove them.

## Permanent delete (`delete_unused_dm_content(content, confirm_name)`)

* Who: campaign content — a DM of that campaign or an admin; private library — its author or an admin. Player, unrelated DM and
  anonymous: "Content not found" (no existence or campaign-name leak).
* The exact name must be typed.
* Lock order (the same in every content function): the `dm_content` row, then its catalog rows; then the dependency count is
  re-run **inside the transaction** (the UI preview is never trusted). Current use or history → `TLUSE` "Archive it instead;
  nothing was deleted".
* Deletes, per type, explicitly: spell versions + their class-list entries (+ the base spell when no version is left), items,
  feat versions (+ base), creatures, background versions (+ base), lineage versions (+ base), then the content row (its versions
  and events go with it). Only the definition's own child rows cascade. A foreign-key failure at this point rolls everything back
  with the same friendly message.
* One `campaign_audit_events` row (`content_deleted`, visibility dm) with id, type, name, version and catalog ids.
* A repeated or concurrent delete gets "Content not found": one final result, one audit event.

## History no longer blocks deletion (2026-11-12, `20261112000100_content_deletion_history.sql`)

* **Current use blocks** (`TLUSE`, unchanged): inventory / stash / NPC / shop entries, equipped, attuned, owned assets,
  starting equipment, proficiencies, items based on it, every assignment, running or planned encounters, a submitted /
  returned / apply_failed change request that is not stale, and the **published version of other, non-archived content** that
  names it. `inventory_items.item_id ON DELETE RESTRICT` stays the backstop.
* **History is kept and does not block**: inventory events, character audit lines, earlier assignments, player draft or stale
  requests (`request_history`), archived / draft / superseded versions of other content (`other_content_history`). New
  classification **DELETABLE, HISTORY KEPT** (`delete_keeps_history`, `can_delete = true`). Exception: a creature in a
  **completed encounter** stays ARCHIVE RECOMMENDED (encounter history).
* Before the delete, `inventory_events` rows of the item get `metadata.deleted_item = {id, name, content_id, deleted_at}` (the FK
  then nulls `item_id`; a secret item keeps its disguise there, players can read these rows). The `content_deleted` audit
  event (DM only) lists the earlier assignments (`before.assignments`), because the `dm_content_events` cascade removes them.
  The legacy `delete_unused_dm_item` stamps the same way and now writes that audit event too.
* Text references match exactly (`"<ref>"` or `":<ref>"` followed by a quote): no LIKE wildcards, `-v1` no longer matches `-v10`.
* `get_dm_content_usage_detail(content)` (same gate as the usage report; player / unrelated DM / anonymous: "Content not found"):
  **where** it is used — character inventories, party stash / NPC / shop / stash (name), per-character uses, approvable requests
  (title, status, character), encounters, other published content. Rows in campaigns the caller does not run are only counted.
* UI: the Usage dialog splits *In use (blocks delete)* from *History (kept)*, lists *Where it is used* with links (character,
  request, encounter) and the next step; an archived item is never told to "archive it"; the editor header uses the usage
  report's numbers; Delete permanently of a never-published draft shows at once.
* Permissions differ on purpose: `delete_unused_dm_content` = any DM of the campaign / admin; legacy `delete_unused_dm_item`
  (content management off) = author / admin.
* Rollback: `supabase/rollback/rollback_content_deletion_history.sql` (exact previous bodies; stamps already written stay).

## Duplicate official as homebrew (`duplicate_official_as_homebrew(type, ref, campaign)`)

Reads one official catalog row (spell, item, feat, creature, background, lineage) and creates a **draft** in the campaign through
the normal `create_dm_content` path: name "<name> (homebrew)", DM note naming the source, mechanics copied into the editor's
definition format. When published it gets its own `cc-…` id and source "Campaign custom" — no official id is reused and the
official row is unchanged (CM4). What a custom definition cannot express is left out (lineage trait effects that depend on a
player choice; spell text, which the catalog does not store) — the DM reviews it and the authoritative validation runs before
publishing.

## UI (DM Space → Content Library)

* **Duplicate official…**: search an official spell, item, feat, creature, background or lineage by name; the duplicate opens in
  the editor.
* Per row **Usage** and in the editor **View usage…**: classification chip, counts, advice; **Archive instead** when it is
  published; **Delete permanently…** only when the server says it is safe.
* The editor shows only the actions valid for the state: Save draft / Validate (draft), Publish, New version (published),
  Assign, Duplicate, Restore (archived), Archive (published), Delete permanently (safe only).
* Errors are friendly (`TLUSE`, `42501`, `22023`); no SQL or constraint names.

## Concurrency

`supabase/tests/content_deletion_concurrency_test.sh`: delete vs. assignment (both orders forced, exactly one winner, never a
deleted row still referenced), double delete (one result, one audit event), publish vs. archive (one consistent state), **0
deadlocks**. The test found a real deadlock: `dm_assign_content` took the version and catalog locks before touching the
`dm_content` row; it now takes a share lock on the `dm_content` row first, like every other content function.

## Tests

`supabase/tests/classes/content_management_tests.sql` (26 checks: duplicate per type, validation, official protection, usage
counts and classification, refusal for used content incl. a text-only lineage feat pick, permissions for player / unrelated DM /
anonymous, typed name, delete per type with catalog rows, one audit event, repeat safety, archive / restore / new version),
`classes/dm_content_tests.sql` (37, the earlier lifecycle), `content_deletion_concurrency_test.sh` (8),
`browser/active_features_ui_test.py` (M1–M5).
