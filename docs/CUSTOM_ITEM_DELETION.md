# Custom item deletion (2026-11-07)

Used items are **archived**, never deleted. A permanent delete is only for a custom definition that nothing uses, and the
server rechecks that inside the transaction, under the item row lock.

## Functions

| Function | Who | Does |
|---|---|---|
| `preview_item_deletion(item)` | anyone who can see the item; editors get the details | `deletable`, the dependency counts, readable reasons, advice ("Archive it instead …"); official items: `deletable = false, official = true`; DM Space items: `dm_content_id` (delete them there) |
| `delete_custom_item(item, confirm_name)` | author / campaign DM (access is checked before governance, so strangers get "Unknown item", never a campaign text) | locks the item `FOR UPDATE`, refuses DM Space items, requires the exact name, recounts dependencies, deletes (definition rows cascade: stats, tags, provenance, secrets, its own lifecycle events, slot rules) |
| `delete_unused_dm_item(content, confirm_name)` | author / admin of a DM Space **item** | locks the content and every published version's item; all must be unused (and no campaign condition uses the content); deletes the item rows and the content with its versions |
| `delete_dm_content(content)` | unchanged | drafts only |

## What counts as "used" (`_item_dependencies`)

character inventories, other inventories (stash, party), owned assets, background starting equipment, character
proficiencies, items based on it, submitted / returned change requests that mention it (not stale), other DM content versions.
**Since 2026-11-12 history does not block** (`20261112000100`): inventory history and draft / stale requests are listed as
`history` (kept); before the delete the events get `metadata.deleted_item` with the name, and the FK nulls only the link. Equipped / attuned / in-container entries are already inventory entries (listed for information).
Combat has no item references. A foreign-key RESTRICT is the last line of defence and is mapped to the same friendly
"in use, archive it" error (SQLSTATE `TLUSE`, hint `archive`).

## Concurrency

`item_deletion_concurrency_test.sh`: delete and "add to inventory" at the same moment, 15 rounds → exactly one winner each
round (either the item is gone and nothing references it, or the item and the new entry exist and the delete was refused);
the same delete twice deletes once; no deadlock; the delete never shows a raw error. The losing "add" gets "That item
definition was just deleted or changed. The list was refreshed; nothing was added."

## UI

- Inventory > Add item: own custom items have **Delete…**. Unused → a dialog that needs the exact item name ("Delete for
  good" stays disabled until it matches). Used → "It cannot be deleted. Archive it instead?" with the reasons.
- DM Space item editor: "Delete (unused)…" on a published item with no character or stash usage; the server still decides.
