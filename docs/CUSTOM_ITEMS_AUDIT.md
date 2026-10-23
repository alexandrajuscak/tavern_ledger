# Custom / manual / legacy items — audit (before the change)

State audited: migrations `20261015000100`–`001200`, `js/` as of the inventory MVP. Nothing was changed or deleted during the audit.

## Findings

| # | Where | Function | Behaviour before | Security risk | Data risk | Replacement |
|---|---|---|---|---|---|---|
| 1 | `js/inventory-api.js` | `addCustomItem` | `insert into inventory_items (character_id, name, quantity, weight, description)` → **new legacy row with `item_id = null`** | low (RLS limits it to own inventories) | new unstructured rows that can never be equipped, typed or validated; the legacy set keeps growing | removed; "Create homebrew item" → `create_homebrew_item` → `add_inventory_item` |
| 2 | `js/inventory-ui.js` | `openCustomItemForm`, button **+ Custom** | free-text form calling #1 | – | as #1 | removed; the Add item modal offers *Search catalog* / *Create homebrew item* |
| 3 | `js/transfer.js` | `importCharacter` | inserts every JSON inventory entry as a legacy row (`name, quantity, weight, equipped, description`) | low | every import created legacy rows; the `equipped` flag was ignored silently | `import_inventory_items` RPC: exact unique catalog match → catalog item (custom name/notes keep the original text); otherwise a private/campaign homebrew item |
| 4 | DB `…0900_inventory_rls.sql` | column grant `insert (character_id, name, quantity, weight, description, equipped, sort_order)` | any authenticated client can insert legacy rows directly through PostgREST, bypassing the RPCs | medium (bypass of the "catalog only" model) | as #1 | `revoke insert` — inventory rows are only created by SECURITY DEFINER RPCs |
| 5 | DB same file | column grant `update (name, quantity, weight, description, equipped, sort_order, custom_name, notes, container_item_id, is_quest_item, state, charges_*, durability, consumable_override)` | direct writes of legacy raw fields, quantity and container (trigger-validated but only partly audited) | low–medium | raw legacy data could be overwritten without a record | `revoke update`; instance fields via `update_inventory_item_details`, quantity via `set_inventory_item_quantity`, container via `move_inventory_item` |
| 6 | DB base schema grant | `delete` on `inventory_items` | direct delete (no event for legacy rows) | low | legacy rows deletable without audit | `revoke delete`; `remove_inventory_item` (also removes legacy quantity-0 rows when removing all) |
| 7 | DB `…0900` | `items_homebrew_write` policy + `insert/update/delete` grant on `items` | homebrew written directly: typed stats impossible (read-only), no validation of kind/category/stats, half-written items possible, hard delete of items in use blocked only by FK | medium | inconsistent homebrew (no stats, wrong flags), ids chosen by the client | revoked; `create_homebrew_item` / `update_homebrew_item` / `archive_homebrew_item` / `restore_homebrew_item` |
| 8 | `js/inventory-api.js` | `updateInventoryItemDetails` | direct `update` of `custom_name, notes` (catalog rows) and `name, weight, description, notes` (legacy rows) | low | legacy raw values overwritten | `update_inventory_item_details` RPC (instance fields only); legacy raw fields are read-only |
| 9 | `js/inventory-api.js` / `inventory-ui.js` | `linkInventoryItem`, `findCatalogMatches` | exact name match → link after a yes/no dialog; legacy description/weight differences not shown; legacy name kept in `name` | – | differences not visible to the user; equipment review not surfaced | `find_link_candidates` (exact / probable), `preview_link_inventory_item` (comparison), `link_inventory_item` returning preserved / changed fields, warnings and the equipment-review flag |
| 10 | DB `…0500` trigger | `equipped` projection | client writes ignored (already safe) | – | – | unchanged; with #5 the column is not client-writable at all |
| 11 | `js/inventory-ui.js` | quantity − / + and *Set to* on legacy rows | allowed | – | legacy rows were edited instead of migrated | legacy rows: read-only raw details, actions *Link*, *Convert to homebrew*, *Equipment review*, *Remove* |
| 12 | `../seed_characters.sql`, `../upgrade_v2_attacks.sql` | SQL editor scripts | insert legacy rows as `postgres` | none for clients | admin-only path | unchanged (explicit admin/migration path, documented) |
| 13 | UI wording | "Custom" badge | used for unlinked rows, while "custom name" means something else | – | user confusion | terms: **Official item**, **Homebrew item**, **Legacy item**, **Custom name**, **Personal notes**, **Quest item** |

## Three concepts (decided)

1. **Legacy item** — an old `inventory_items` row without `item_id`. Read-only raw data, kept for compatibility, never created again
   by clients. Can be linked to a catalog item or converted to homebrew; nothing is lost (audit + notes).
2. **Customized inventory instance** — a row with `item_id`; per-piece data only: `custom_name`, `notes`, `is_quest_item`,
   `durability`, `charges_*`, `state`, modifiers, attunement, container. Never creates a catalog item.
3. **Homebrew item** — a catalog row in `items` with `owner_id` (and optionally `campaign_id`), typed stats, `data_source_id = homebrew`,
   created/edited/archived only through RPCs, added to inventories exactly like official items.
