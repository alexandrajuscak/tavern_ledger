# Custom item editing and versioning (2026-11-07)

Two existing lifecycles, both kept; this release adds icons, Herbs & Plants, potion / crafting details and safe deletion.

| | Player / DM homebrew item (inventory "Create homebrew") | DM Space item (content library) |
|---|---|---|
| Who | DMs (governance `content.create_item`); author or campaign DM edits | the campaign DM / author |
| Edit | in place; the form warns "used by N inventory entries; your changes will affect all of them" and asks again when N > 1; every change is audited (`homebrew_item_events`) | drafts are edited; a **published version never changes in place**: "New version" creates a draft, characters keep the version they have |
| Type | fixed after creation (create a new item) | may change in a new version (only that type's stats / details are sent) |
| Archive / restore | yes (cannot be added again; existing entries keep working) | yes |
| Usage | `homebrew_usage_count`, `preview_item_deletion` | `_dm_usage` (characters, stash, requests, by version) |
| Duplicate | — | "Duplicate" / "Copy to this campaign" (official items are copied into homebrew through the form's "similar item" path) |
| Permanent delete | `delete_custom_item` when unused (see CUSTOM_ITEM_DELETION.md) | drafts: `delete_dm_content`; published but never used: `delete_unused_dm_item` |
| Icon | gallery (CUSTOM_ITEM_ICONS.md) | gallery field "Icon" |

The server stays authoritative (`_write_homebrew`, `_item_details`, `_item_icon_key`); the browser only hides irrelevant
sections and sends the selected type's fields.
