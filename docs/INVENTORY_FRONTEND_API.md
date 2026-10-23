# Inventory frontend API (`js/inventory-api.js`)

The only module that talks to Supabase about inventory. It uses the existing client (`js/supabase.js`: project URL +
publishable/anon key only). RLS and the RPCs' own checks are authoritative; hiding a button is only UX.

## Reads (views and tables; RLS applies)

| Function | Source | Notes |
|---|---|---|
| `getLookups()` | `item_kinds`, `item_categories`, `rarities`, `source_books`, `ammo_types`, `equipment_slots`, `equipment_slot_rules` | cached for the session |
| `getCharacterInventoryId(characterId)` | `inventories` (kind `character`) | |
| `getInventoryRows(inventoryId)` / `getCharacterInventory(characterId)` | `v_inventory_detail` | paged in 500-row ranges; order `sort_order, acquired_at, id` |
| `getCharacterEquipment(characterId)` | `character_equipment` | source of truth for equipped state |
| `getAttunement(characterId)` | `v_character_attunement` | |
| `getInventoryWeight(inventoryId)` | `v_inventory_weight` | |
| `getContainerContents(inventoryId)` | `v_container_contents` | capacity / warnings |
| `getLegacyReview(characterId)` | `legacy_inventory_review` (status `manual_review`) | |
| `getCatalogItems(ids)` | `v_item_catalog` | cached per item id |
| `getCatalogPage(options)` / `searchCatalog(query, filters, page)` | `v_item_catalog` | see paging below |
| `findCatalogMatches(name)` | `v_item_catalog` (exact, case-insensitive) | link suggestions for custom items |

## Mutations

| Frontend function | Database | Mapping notes |
|---|---|---|
| `addInventoryItem(inventoryId, itemId, quantity, {customName, notes, state})` | `add_inventory_item` | merges into an identical stack |
| `removeInventoryItem(inventoryItemId, quantity \| null)` | `remove_inventory_item` | null = all; deletes at 0 |
| `setInventoryItemQuantity(inventoryItemId, quantity)` | `set_inventory_item_quantity` | ≥ 1; non-stackable catalog items stay 1 |
| `equipInventoryItem(inventoryItemId, slotId, {replace})` | `equip_item` | returns `{inventory_item_id, split_from, slot}` — the id may differ (stack split) |
| `unequipInventoryItem(inventoryItemId)` | `unequip_item` | the piece may rejoin a stack (new id) |
| `unequipInventorySlot(characterId, slotId)` | `character_equipment` read + `unequip_item` | slot → row mapping |
| `useInventoryItem(inventoryItemId)` | `use_inventory_item(p_quantity = 1)` | returns effect, `previous_quantity`, `remaining`, `deleted`, `state` |
| `attuneInventoryItem` / `unattuneInventoryItem` | `attune_item` / `unattune_item` | |
| `moveInventoryItem(inventoryItemId, containerId \| null)` | `move_inventory_item` | |
| `linkInventoryItem(inventoryItemId, catalogItemId)` | `link_inventory_item` | only after user confirmation |
| `addCustomItem(characterId, {name, quantity, weight, description})` | insert into `inventory_items` | the legacy free-text column set (allowed by column privileges) |
| `updateInventoryItemDetails(row, patch)` | update `inventory_items` | catalog rows: `custom_name`, `notes`; custom rows: `name`, `weight`, `description`, `notes` — nothing structural |

The spec names `equipInventoryItem(characterId, inventoryItemId, slotId)`; the database RPC identifies the character from the
row, so the frontend signature is `(inventoryItemId, slotId)`. Not used by the UI yet: `transfer_inventory_item`,
`split_inventory_stack`, `merge_inventory_stacks`.

Removed legacy operations: the equipped checkbox write, quantity/weight/name/description auto-save on inventory rows,
`insert` of "New item" rows from the sheet, direct `delete` of inventory rows.

## Derived stats and proficiencies

| Frontend function | Database | Notes |
|---|---|---|
| `getDerivedStats(characterId)` | `get_character_derived_stats` | read-only; AC, speed, armor consequences, equipped weapon attacks, tools, warnings ([DERIVED_CHARACTER_STATS.md](DERIVED_CHARACTER_STATS.md)) |
| `setCharacterProficiency(characterId, {group, item, enabled})` | `set_character_proficiency` | exactly one of `group` (`'martial-weapons'`) or `item` (`'longsword'`); idempotent, returns `changed` |
| `getProficiencyGroups()` | `proficiency_groups` | cached for the session |
| `searchProficiencyItems(kind, query)` | `items` | weapons / armor / tools by name, 20 results, archived items excluded |

The AC override is written like any other character field (`characters.ac_override`, `null` = calculated).

## Catalog paging

`getCatalogPage({search, kindId, categoryId, rarityId, magic, sourceBookId, offset, limit = 50, signal})`:
`select(…, {count: 'exact'})`, `order(name).order(id)` (stable), `range(offset, offset + limit - 1)`. The total comes from the
exact count; nothing assumes 1 000 rows (PostgREST `max_rows`). The picker: 50 per page, **Load more** appends and de-duplicates
by id, any filter or search change resets to page 1, search is debounced (300 ms), every request has a token and an
`AbortController` — an older response is ignored. Search uses `ilike` with `%`, `_` and `\` escaped (`*` removed).

## Errors

`normalizeError(err)` → `InventoryError {kind, message}`; kinds: `authorization`, `validation`, `conflict`, `not_found`,
`incompatible_slot`, `attunement_limit`, `insufficient_quantity`, `concurrent`, `network`, `unknown`. Messages are specific
("A two-handed weapon needs both hands: empty the off hand and the shield slot first.", "This character is already attuned to
3 items. End an attunement first.", "There are not enough pieces for that.", …); raw Postgres text is never shown. A short
technical line (`code`, `message`) goes to `console.warn`; tokens are never logged.

Retries: reads retry twice on network / serialization errors; mutations are **never** retried automatically (a lost response
could otherwise consume a potion twice). Aborted (stale) requests are not retried.
