# Custom items

DM-authored items for a campaign (weapons, armor, magic items, gear, consumables), with optional secrets. Lifecycle:
[CUSTOM_CONTENT_LIFECYCLE.md](CUSTOM_CONTENT_LIFECYCLE.md); identification and curses: [HIDDEN_DM_DATA.md](HIDDEN_DM_DATA.md);
the item engine: [INVENTORY_DATABASE.md](INVENTORY_DATABASE.md).

## Two ways to author an item

1. **Content Library** (recommended): DM Space → Content Library → New → Item. Versioned, validated, previewed,
   published, archived like all custom content; can carry secrets.
2. **Homebrew editor in the inventory** (`create_homebrew_item`, the older path): still available, but **only to DMs**
   (`can_author_content`) since migration `20261019000100`. Players see "Ask your DM" instead of the create button. Items a
   player created before the change keep working on their characters and can still be archived or restored by their author,
   but changing their mechanics (`update_homebrew_item`) now needs a DM as well; they are not converted.

## Definition

| Part | Fields |
|---|---|
| `item` | `kind_id` (weapon, armor, gear, potion …), `category_id` (simple-melee, martial-ranged, light-armor, shield, ring, wand …), `rarity_id`, `is_magic`, `requires_attunement`, `is_consumable`, `stackable`, `weight_lb`, `cost_value` + `cost_unit`, `description` |
| `stats.weapon` | `weapon_group`, `damage_dice`, `damage_type_id`, `range_normal`, `range_max`, `properties` |
| `stats.armor` | `base_ac`, `ac_bonus` (shields), `dex_modifier_mode` (full / capped / none), `dex_cap`, `strength_requirement`, `stealth_disadvantage` |
| `hidden` (DM only) | `unidentified_name`, `unidentified_description`, `curse`, `properties` [{key, label, text}] |

Publishing writes the item through the same `_write_homebrew` routine as the homebrew editor (so weapon, armor and
modifier rows follow the inventory rules), with the campaign, `content_version_id` and source label *Campaign custom*.
The `hidden` part is copied to `item_secrets` (DM-only RLS) by the trigger `dm_content_versions_item_secrets`.

## How it behaves

* Campaign members see the item in the catalog with the **Campaign custom** badge; outsiders do not.
* A player adding it is governed by `inventory.assign_custom` (Standard / Strict: approval). The DM assigns it to a
  character's inventory or the party stash, identified or **unidentified** (the player then sees only the disguise).
* Equipping, attunement, AC and attack numbers come from the inventory and derived-stats engines.
* A new version is a new catalog row; existing inventory rows keep the version they hold. Archiving hides it from new
  picks; items already owned stay.

Tests: `dm_content_tests.sql` DC16–DC20, `governance_api_test.py` GA23–GA24, `dm_space_ui_test.py` DS14–DS16 and DS38,
`api_contract_test.py` (campaign homebrew by the DM; a player cannot author campaign homebrew), `homebrew_smoke_test.py`,
`local_dev_smoke_test.py` (homebrew steps as a DM).
