# Database scope review

Before: 35 tables added by the inventory migrations. After: **34** (2 removed, 1 added). Counts in `public` incl. the
11 base tables: 46 → 45.

## Removed

| Table | Why |
|---|---|
| `tool_stats` | Only `item_id` (no columns with data). Nothing read it. Created for a hypothetical future. Re-add when tool data exists. |
| `item_effects` | Empty, no reader, no MVP use (passive magic effects). Phase 2. |

## Added

| Table | Why |
|---|---|
| `legacy_inventory_review` | migration compatibility: snapshot of legacy equipped / quantity-0 rows and the result of `migrate_legacy_inventory()` |

## Classification

| Table | Rows (seed) | Used by RPC / view | MVP frontend | Class |
|---|---|---|---|---|
| `item_kinds`, `item_categories`, `rarities`, `currencies`, `damage_types`, `weapon_properties`, `ammo_types`, `data_sources`, `source_books` | 10 / 22 / 8 / 5 / 13 / 11 / 11 / 2 / 47 | catalog view, constraints | yes (labels, filters) | MVP required |
| `items` | 1146 | everything | yes | MVP required |
| `weapon_stats`, `weapon_property_links`, `firearm_stats` | 47 / 83 / 7 | catalog view, equip rules (two-handed) | yes (attacks) | MVP required |
| `armor_stats` | 14 | catalog view | yes (AC) | MVP required |
| `ammunition_stats` | 11 | catalog view | yes (ammo) | MVP required |
| `container_stats` | 17 | container/weight views | yes (capacity warning) | MVP required |
| `consumable_effects` | 4 | `use_inventory_item` | yes (potion result) | MVP required |
| `mount_stats`, `vehicle_stats` | 8 / 27 | asset view | yes (owned assets) | MVP required |
| `item_modifiers`, `item_modifier_effects`, `item_modifier_categories` | 12 / 18 / 12 | stack identity, modifier trigger | yes (+1 weapons) | MVP required |
| `equipment_slots`, `equipment_slot_rules` | 13 / 79 | equip trigger | yes | MVP required |
| `inventories`, `inventory_items`, `inventory_item_modifiers`, `character_equipment`, `inventory_events` | – | all RPCs | yes | MVP required |
| `owned_assets` | – | asset view | yes (MVP-light: ownership) | MVP required |
| `legacy_inventory_review` | – | `migrate_legacy_inventory` | DM review list | migration compatibility (drop after the review) |
| `item_provenance` | 1193 | – (internal) | no | migration compatibility / audit (not exposed) |
| `item_source_books` | 910 | catalog detail | optional (source filter) | phase 2 use, kept because it has data |
| `item_tags`, `item_tag_links` | 2 / 7 | catalog view (`tag_ids`) | optional | phase 2 use, kept because it has data |

None of the remaining tables is unnecessary: each either has seeded data or is part of an RPC path.
The typed-stats model is kept on purpose (docs/master model): one catalog table plus one table per item type.
