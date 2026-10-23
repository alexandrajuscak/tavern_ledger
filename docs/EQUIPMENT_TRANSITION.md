# Equipment: one source of truth

## Old model

`inventory_items.equipped boolean` — a checkbox per row in the inventory list (`js/sheet.js`, `inventoryItemHTML`).
It has no slot, works on a whole stack ("Darts ×10 equipped") and is written directly by the client.

## New model

`character_equipment (character_id, slot_id, inventory_item_id)` is the **only** source of truth.

- one slot holds at most one item (primary key), one item sits in at most one slot (unique `inventory_item_id`)
- only items from the character's own inventory; only compatible slots (`equipment_slot_rules`); two-handed weapons block `off_hand` and `shield`
- equipping one piece of a stack splits it first (`Javelin ×5` → `×4` + `×1 equipped`)
- equip and attunement are independent
- clients have **SELECT only** on `character_equipment`; `equip_item` / `unequip_item` are the only write path (they log `equip` / `unequip` events)

## The legacy column during the transition

`inventory_items.equipped` stays (the current frontend reads it with `select *`), but it is no longer data — it is a
**read-only projection**:

- every write to an inventory row recomputes it as `exists (character_equipment for this row)`; whatever the client sent is ignored
- equipping/unequipping updates the row in the same transaction, so the projection is refreshed atomically
- the column stays client-writable on purpose, so the legacy checkbox does not raise an error — the write simply has no effect
- new read code uses `v_inventory_detail.equipped` / `equipped_slot` (derived from `character_equipment`)

This is a one-way projection maintained by the existing row trigger, not a two-way sync: there is exactly one writer
(`character_equipment`) and no path that copies the legacy value back. It disappears with the column (phase 3).

Verified: SQL tests I1–I5 (plain PostgreSQL and Supabase) and the API test "writes to the legacy equipped column are ignored; it always matches character_equipment" (real PostgREST + JWT).

## Migration procedure (one time)

1. Apply the migrations. `20261015000500_inventories` snapshots every row with `equipped = true` into
   `legacy_inventory_review` (category `equipped_pending`) **before** any trigger exists, so the original value is never lost.
2. Load the reference seed.
3. Run `select public.migrate_legacy_inventory();` (service role / SQL editor; not callable by clients). It
   - links free-text rows to the catalog when the name matches exactly one official item (case-insensitive);
   - moves an equipped row into a slot only when the slot is unambiguous:
     armor → `armor`, shield → `shield`, the character's **only** equipped weapon → `main_hand`, the **only** ring → `ring_1`;
   - everything else becomes `equipped_manual` / `manual_review` with the reason (not linked, stack > 1, several weapons, several rings, no slot for that kind);
   - finally recomputes the legacy column for every row.
4. A DM/admin reviews `legacy_inventory_review where status = 'manual_review'` and equips through `equip_item`.

Synthetic test: of 7 legacy equipped rows, 2 were moved to slots and 5 sent to manual review (`03_legacy_migration_check.sql`).
The local character files have 52 equipped rows out of 122 (aggregate, `data/reports/legacy_inventory_impact.json`), most of them free-text
names or several weapons per character, so expect a large manual-review list on the live data.

## Compatibility period (phase 2)

| | Current frontend | New frontend |
|---|---|---|
| Read equipped | `inventory_items.equipped` (projection, always correct) | `v_inventory_detail.equipped_slot` |
| Write equipped | checkbox write is ignored | `equip_item` / `unequip_item` RPC |

Frontend impact: the checkbox no longer persists. After a reload it shows the real state. The UI should replace the
checkbox with a slot picker that calls the RPCs; until then, equip through the RPCs (or the DM fixes it in SQL).

## Removing the legacy column (phase 3)

Drop `inventory_items.equipped` when all of these hold:

1. no frontend code reads or writes `equipped` (grep `js/` and the JSON import/export in `js/transfer.js`);
2. `legacy_inventory_review` has no `equipped_manual` row in `manual_review`;
3. the character JSON schema exports equipment from `character_equipment`;
4. one release ran with the new UI.

Then: remove the projection line from `inventory_items_before_write`, revoke the column grant, drop the column.
