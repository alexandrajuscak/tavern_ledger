# Frontend inventory impact (analysis before the change)

## Files analysed

`index.html`, `css/styles.css`, `js/app.js`, `js/sheet.js`, `js/store.js`, `js/transfer.js`, `js/utils.js`, `js/config.js`,
`js/supabase.js`, `js/dnd.js`, `js/levelup.js`.

## Existing data flow

| Step | Where | What |
|---|---|---|
| Route | `app.js` `route()` on `hashchange`; `#/c/<id>` opens a character | `openCharacter` renders the cached bundle read-only, then `loadBundle(id)` |
| Load | `store.js` `loadBundle` | `from('inventory_items').select('*').eq('character_id', id).order('sort_order').order('created_at')` (no paging) |
| Render | `sheet.js` `inventoryHTML` / `inventoryListHTML` / `inventoryItemHTML` | one card per row: equipped checkbox, name, quantity (`min="0"`), weight, description — all bound to table columns |
| Write | `sheet.js` `commitField` → `store.js` `saver.queue` → `update(patch).eq('id')` | debounced auto-save; **failed writes are retried forever with backoff** |
| Add | `sheet.js` `addItem` | `insert({character_id, name:'New item', sort_order})` |
| Delete | `sheet.js` `removeRow` → `deleteRow` | `delete().eq('id')` |
| Derived | `sheet.js` `deriveValue('weight')` | `sum(weight × quantity)` over the loaded rows |
| Realtime | `store.js` `subscribeCharacter` + `sheet.js` `onRemote` | `inventory_items` INSERT/UPDATE filtered by `character_id`, DELETE unfiltered; patches rows in place |
| Export / import | `transfer.js` | export `{name, quantity, weight, equipped, description}`; import inserts the same columns with `quantity = max(0, …)` |
| Cache | `utils.js` `cacheSet('bundle:<id>')` | the whole bundle in `localStorage` (never the source of truth) |

UI building blocks that are reused: `openModal`, `confirmDialog`, `toast`, `esc`, `debounce`, `.card`, `.btn*`, `.badge`,
`.section-head`, `.empty`, `.spinner`, `.coins`, the bottom-sheet modal on small screens. There is no dice roller and no test framework.

## Legacy operations and their replacement

| Legacy operation | Problem with the new database | Replacement |
|---|---|---|
| checkbox writes `inventory_items.equipped` | value is ignored (projection of `character_equipment`); checkbox would silently "snap back" | slot UI → `equip_item` / `unequip_item` RPC |
| quantity input `min="0"` + auto-save | `quantity < 1` is rejected → the auto-saver would retry the failing write forever | − / + / Set quantity → `remove_inventory_item`, new `set_inventory_item_quantity` RPC; never sends 0 |
| `insert` of a "New item" row | still allowed (free-text row) | kept as "Add custom item"; catalog items via `add_inventory_item` |
| delete by id | allowed, but bypasses the RPC audit trail | `remove_inventory_item` RPC |
| weight typed per row | catalog rows use `items.weight_lb` | catalog weight shown; legacy rows keep their own weight |
| client-side weight sum | ignores containers / weightless bags | `v_inventory_weight` |
| no container moves | – | new `move_inventory_item` RPC (no RPC existed; a direct column update would not be audited) |
| no catalog link for legacy rows | `item_id` is not client-writable | new `link_inventory_item` RPC (explicit user confirmation) |
| JSON import with `quantity = 0` rows | rejected by the database | import clamps quantity to at least 1 |

## Breaking changes (user visible)

1. The equipped checkbox is replaced by equipment slots.
2. Quantity can no longer be set to 0 (− on the last piece removes the item after confirmation).
3. Catalog rows' weight comes from the catalog; their base name is not editable (a custom name is).
4. Imported quantity-0 items become quantity 1.

## Implementation plan (followed)

1. Database: one forward migration with the three missing RPCs (`set_inventory_item_quantity`, `move_inventory_item`, `link_inventory_item`) + tests.
2. `js/inventory-api.js`: the only module that talks to Supabase for inventory (views, RPCs, paging, error mapping, stale-request guard).
3. `js/inventory-ui.js`: summary, equipment slots, inventory list, detail modal, catalog picker; mounted into the Inventory tab.
4. `js/sheet.js`: remove the legacy inventory rendering/writes, mount the new UI, route realtime events to it.
5. `js/store.js` (realtime list), `js/transfer.js` (import clamp), `js/supabase.js` (local-only development override).
6. Tests: SQL + API for the new RPCs, browser test against the local Supabase stack, manual checklist.
