# Consumable effects (MVP)

## Model

`consumable_effects (item_id, seq, effect_type, dice_expression, flat_value, damage_type_id, duration, target_type, effect_data)`

- `effect_type`: `healing | damage | buff | condition | cast_spell | other`
- `dice_expression` (`2d4`) + `flat_value` (`2`) = "2d4 + 2"; healing/damage need at least one of them
- `effect_data jsonb` only for extensions
- no row = consumed without an automatic effect (most potions, Acid, Alchemist's Fire, Antitoxin …). Not every potion heals.

Seeded from the Potion of Healing page (`data/raw/source_html/wondrous-items_potion-of-healing.html`):

| Item | Effect |
|---|---|
| `potion-of-healing-common` | healing 2d4 + 2, self |
| `potion-of-healing-uncommon` (Greater) | healing 4d4 + 4, self |
| `potion-of-healing-rare` (Superior) | healing 8d4 + 8, self |
| `potion-of-healing-very-rare` (Supreme) | healing 10d4 + 20, self |

## `use_inventory_item(p_item, p_quantity default 1)`

1. locks the row `FOR UPDATE` (a concurrent second use waits, then sees the result);
2. checks the caller may write that inventory;
3. checks quantity ≥ 1 and that enough pieces exist;
4. reads the effects;
5. decreases the quantity (only if consumable: `coalesce(consumable_override, items.is_consumable)`);
6. deletes the row when it reaches 0;
7. logs a `use` event (`quantity_delta`, `previous_quantity`, `remaining`, `deleted`, `name`, `state`);
8. returns `{item_id, kind_id, name, consumed, quantity_used, previous_quantity, remaining, deleted, state, effects[]}`.

It **never changes character HP**. The frontend shows the effect / rolls the dice; a separate, confirmed "Apply healing"
action can be added later. A non-consumable item is not consumed (the use is still logged).

**Scrolls**: consumed like potions; the spell lives in `inventory_items.state` (e.g. `{"spell":"shield","level":1}`) and is
returned to the UI; nothing is cast automatically. `consumable_override = false` keeps an exceptional scroll; the catalog default
for scrolls stays consumable.

## Hard delete (decided)

The last piece deletes the `inventory_items` row. History stays in `inventory_events`: `item_id`, `quantity_delta`,
`previous_quantity`, the display name and the state; `inventory_item_id` becomes null. Rejected alternatives:
`quantity = 0` (not a valid state of the new model) and soft delete `removed_at` (every query and unique rule would need a filter,
for no MVP benefit). Undo is not implemented; it could replay the event in a later phase.

## Tests

M1 Potion of Healing effect + last piece · M2 event keeps item/previous quantity/name · M3 HP unchanged · M4 generic consumable ·
M5 non-consumable · M6 scroll · B7–B13 quantity never below zero, double use, override · concurrency: two psql sessions, and
8 parallel API calls on a stack of 3 (exactly 3 succeed).
