# Inventory UI (MVP)

Code: `js/inventory-ui.js` (screen) and `js/inventory-api.js` (all Supabase access, see [INVENTORY_FRONTEND_API.md](INVENTORY_FRONTEND_API.md)).
Mounted by `js/sheet.js` into the **Inventory** tab. No framework, no build step; ES modules and the existing CSS
(`css/styles.css`, section "Inventory").

## Layout

| Area | Desktop (≥ 900 px) | Mobile |
|---|---|---|
| Summary | 4 tiles: items (stacks + pieces), carried weight (`v_inventory_weight`), attunement `n / 3` (click = list), coins | 2 × 2 tiles |
| Equipment | left column, sticky; 13 slots from `equipment_slots` | collapsible section, closed by default |
| Items | right column: **+ Add item**, **+ Custom**, category chips, list | full width, cards under each other |
| Item detail, catalog picker, slot picker | modal | bottom sheet (existing modal style) |
| Coins | editable card below the inventory (unchanged character fields) | same |

Categories (chips with counts) are derived from structured fields, never from tags: All · Weapons (`kind_id = weapon`) ·
Armor (`armor`) · Consumables (`is_consumable`) · Magic (`is_magic`) · Ammunition (`ammunition`) · Tools (`tool`) ·
Gear (`gear`) · Containers (has capacity data or contents).

Each item card shows the name (custom name first), quantity, kind · category · weight per piece ("weight unknown" when
the catalog has none), and badges: Equipped · slot, Attuned / Attunement, rarity, Custom (not linked to the catalog),
Needs equipment review, Container, Weightless, Over capacity, Quest, modifiers (Weapon +1 …). Quick actions need no hover:
− / + for stackable items (🗑 on the last piece), Equip / Unequip, Use (consumables), Link… (custom items). Container contents
are nested under their container in "All".

## Behaviour

- **Source of truth is the server.** After every action the inventory is re-read (rows, equipment, attunement, weight,
  containers, review). The UI never simulates splits, merges or quantities, and never assumes an inventory row id survives
  an equip (a stack is split by `equip_item`).
- **Equipment** is read from `character_equipment`. The old equipped checkbox is gone; nothing writes
  `inventory_items.equipped`. Equip from a card or a slot: one compatible slot → equipped directly (with a replace
  confirmation if it is occupied); several (weapon: main/off hand, rings, wondrous items) → slot choice. An empty slot lists only
  compatible items from this character's inventory (`equipment_slot_rules`). An occupied slot offers Details, Replace, Unequip.
  Invalid combinations show the server's reason in plain words ("A two-handed weapon needs both hands…").
- **Quantity** is never sent as 0. − on the last piece asks for confirmation and removes the item. The detail has
  *Set to / Add / Remove* with validation (whole numbers ≥ 1). Non-stackable items are one piece per card; "Add" creates pieces.
- **Consumables**: Use is disabled while the request runs (double click safe; the database lock is authoritative). The result shows
  the structured effect ("Healing: 2d4 + 2"), the scroll's spell if known, and what is left. HP is never changed automatically
  (there is no dice roller in the app; the player rolls and applies healing on the combat bar).
- **Attunement**: separate from equipping. At 3 / 3 the explanation and the list of attuned items (with "End attunement") appear.
- **Ammunition**: a weapon card shows the compatible ammunition in the inventory (type from the catalog), a low-ammo warning
  below 10, a "Show" link to the stack, or a clear message when none is carried. No automatic consumption on attacks yet.
- **Containers**: "Contents: n items, x lb / capacity" with an over-capacity warning (never blocking). Items are moved with
  *Move to container / Not in a container* in the detail (`move_inventory_item`; the database blocks cycles and too-deep nesting).
- **Legacy (custom) items**: rows without a catalog link are shown with a dashed border and the "Custom" badge; their name,
  weight and description stay editable. The detail looks for catalog items with exactly the same name and offers **Link**
  (after confirmation) or "Choose a catalog item…". Legacy equipped rows that could not be migrated show
  "Needs equipment review" with the reason; after linking they can be equipped through the normal slot flow.
- **Custom items** (+ Custom) insert a free-text row (the legacy column set) for things that are not in the catalog.

## Derived stats

Equipped items change the character's calculated stats (see [DERIVED_CHARACTER_STATS.md](DERIVED_CHARACTER_STATS.md)).
In the Equipment column, an equipped armor, shield or weapon the character isn't proficient with gets a short
"Not proficient" note (`equipmentNotes` in `js/derived-ui.js`). Tools without proficiency get no note. After every
inventory refresh the Inventory tab calls back into `sheet.js`, which re-reads `get_character_derived_stats`, so AC,
speed, warnings and the Combat tab's "Equipped weapons" update after equip, unequip, attune and unattune.

## Loading, empty and error states

Spinner while loading; "This character has no items yet. Add an item from the catalog to get started."; "Select a slot to equip an
item from this character's inventory."; picker: "No items match the selected filters."; load errors with **Try again**; action
errors as toasts with specific messages (see the API doc).

## Realtime

`store.js` subscribes to `inventory_items`, `character_equipment` and `character_proficiencies` for the open character. `sheet.js` routes those events to
`scheduleRefresh()` (debounced 400 ms, coalesced with a running refresh), so remote changes (another device, the DM) appear
without duplicates. The subscription is removed with the sheet (`unmountSheet`). Verified locally end to end (browser test 16r).

## Compatibility

Existing characters keep all rows. Export/import (`js/transfer.js`) still works (imported quantity 0 becomes 1; imported
equipped flags are not applied — equip in the app). The cached bundle stores the new rows in the legacy shape.
**The frontend needs the inventory migrations**; deployed without them, the Inventory tab shows a load error (other tabs work).

## Known limits

Ammunition is not consumed by attacks; no drag and drop; no transfer UI between characters / party stash (the RPC exists);
modifiers (Weapon +1) can't be added from the UI (existing ones are applied to the derived AC and attacks); the catalog has no
item descriptions; the manual attack cards (Combat tab) are still separate from the derived "Equipped weapons" section.

## Local development

```
SUPABASE_CLI=../.tools/supabase-2.118.0/supabase.exe bash supabase/tests/run_supabase_local.sh --keep   # local stack + data
python -m http.server 5173 --bind 127.0.0.1                                                            # serve the app
```
Open `http://127.0.0.1:5173/`, and in the browser console point the app at the local stack (ignored on any other host):
`localStorage.setItem('tavern-ledger:local-supabase', JSON.stringify({url:'http://127.0.0.1:54321', key:'<ANON_KEY from supabase status>'}))`.
Create users with the local Auth admin API or the sign-up form. Never use the service-role key in the browser (the app refuses it).
