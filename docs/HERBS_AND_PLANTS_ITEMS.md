# Herbs & Plants and Potions (2026-11-07)

Migration `20261107000300_items_herbs_icons_deletion.sql`; tests `items_herbs_icons_tests.sql` (48),
`combined_followup_ui_test.py` T1–T4.

## Herbs & Plants

Stable kind `herbs_plants`, shown as **Herbs & Plants**. Subtypes (categories, all optional): Herb `plant-herb`, Flower
`plant-flower`, Root `plant-root`, Fungus `plant-fungus`, Seed `plant-seed`, Leaf `plant-leaf`, Fruit or Berry
`plant-fruit-berry`, Bark `plant-bark`, Resin `plant-resin`, Plant Material `plant-material`, Other `plant-other`.

A herb needs only a name. It never needs armor, weapon, tool, potion-effect, charge or recipe fields. Defaults: stackable,
not consumable (a herb that is eaten or applied can be marked consumable and get a structured use effect).

Optional metadata (`items.details`, validated per kind): environment, region, harvesting notes, properties (alchemical,
medicinal, poisonous, edible), shelf life, and the crafting fields shared by every kind (ingredient tags, recipe references,
preparation notes). Nothing in these fields is automated.

No official herb content was added: there is no licensed herb source in the project. Test fixtures are synthetic homebrew.

## Potions

`potion` is the existing kind (46 catalog potions; key unchanged, no duplicate category). New:
- an Inventory filter **Potions** (shown when the character carries one) and the potion icons in the gallery;
- optional potion metadata: doses, use (action, bonus action, reaction, 1 minute or more, special), effect text, saving
  throw, duration, ingredients, plus the shared crafting fields.

A basic potion still needs only the ordinary fields; potions stay consumable (existing rule). A **structured** effect
(healing / damage dice) stays in "Use effect" (`consumable_effects`) and is the only part the app applies; the effect text
is a reminder.

## Where they appear

| Place | |
|---|---|
| Homebrew form (DMs) | Type "Herbs & Plants" shows only the herb section; "Potion" shows the potion section; the crafting notes and the icon gallery are available for every type. Values of a hidden section are not sent |
| DM Space item editor | same sections ("Herbs & Plants", "Potion details", "Crafting notes and icon"); only the chosen type's details are saved |
| Inventory | filters Potions and Herbs & Plants (hidden when empty), the item's own icon, the details list in the item dialog |

## Type switching

Only the selected type's mechanics and details are sent and stored; the server refuses stats or details of another type
(`_write_homebrew`, `_item_details`). A homebrew item never changes type in place (existing rule: create a new item); a DM
Space item changes type through a new version, and the published version stays as it was. Tested: Armor → Herbs & Plants
(stale armor stats refused), Herbs & Plants → Weapon (new version), weapon stats on a herb, armor stats on a potion,
Potion → Weapon with a stale use effect — all refused with a friendly message.

## Existing data

No existing item, inventory entry or icon changes. The new columns are NULL / `{}` for all existing rows.
