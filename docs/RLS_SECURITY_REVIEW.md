# RLS and security review

Scope: migrations `20261015000100`–`20261015001100`. Verified on a local Supabase stack (Postgres 17.6, GoTrue, PostgREST)
with real JWTs (`supabase/tests/api/api_contract_test.py`) and in SQL (`supabase/tests/inventory_tests.sql`).

## Result

| | Before | After |
|---|---|---|
| Policies added by the inventory migrations | 64 | 42 |
| Policies in `public` in total | 84 | 61 |

How the count went down without losing anything: lookup and catalog tables are read-only (one policy each, no write policy);
homebrew typed stats and player tags are phase 2 (their write policies and grants are gone); `items`, `item_modifiers` and
`inventories` use one `FOR ALL` write policy instead of three; `character_equipment` is read-only (writes only through RPCs);
`tool_stats` and `item_effects` were removed.

## Findings and fixes

| # | Finding | Severity | Fix |
|---|---|---|---|
| 1 | Policies that looked the row up **by id** in a helper (`can_view_item(id)`, `can_read_inventory(id)`) rejected `INSERT … RETURNING` — exactly what PostgREST does with `return=representation`. Found only on the real Supabase stack: a DM could not create a party stash and a player could not create homebrew through the API. | high (broken feature) | Row-based helpers `can_view_owned(owner, campaign)`, `can_edit_owned(…)`, `can_read_inventory_row(kind, character, campaign, owner)`, `can_write_inventory_row(…)` evaluate the row's own columns. SQL regression tests O1–O3. |
| 2 | A DM could create homebrew with `owner_id` = a player (impersonated authorship). | medium | `items_before_write` / `item_modifiers_before_write`: new homebrew must be the caller's own; owner changes only by an admin (tests N1, N3, N4). |
| 3 | Clients could write `item_id`, `inventory_id`, `is_attuned`, `stack_key` directly (re-typing an item, bypassing events and rules). | medium | Column privileges: INSERT only the legacy column set, UPDATE only display/state columns (tests K1, K2; API test "item_id cannot be changed"). |
| 4 | Clients could write `character_equipment` directly (second write path besides the RPCs). | medium | SELECT only for clients (test C10, API test). |
| 5 | `inventory_of_item(uuid)` was SECURITY DEFINER and returned any row's inventory id. | low (information leak) | SECURITY INVOKER: it only sees rows the caller may read (test K5). |
| 6 | SECURITY DEFINER functions used `search_path = public` (temp schema implicitly first for relations). | low | All new functions use `set search_path = public, pg_temp`; all references are schema-qualified. The base schema's helpers (`is_admin` …) still use `public` only — recommended follow-up in `schema.sql`. |
| 7 | Homebrew was labelled `data_source_id = 'wikidot'`. | low (integrity) | forced to `homebrew` by the trigger (test N2). |
| 8 | `anon` kept Supabase's default grants on `inventory_items` (RLS returned no rows). | low | `revoke all … from anon` (test G10a). |
| 9 | `item_provenance` was readable by clients. | low | no policy, no grant: internal audit data (test K4). |

No dynamic SQL is used in any function (no `EXECUTE` with user input). No function accepts a user id as identity: all use `auth.uid()` from the JWT (verified: `inventory_events.actor_id` equals the caller's JWT `sub`).

## SECURITY DEFINER functions (new)

All have `set search_path = public, pg_temp`, do their own authorization and are granted only where needed:

| Function | Who can execute | Authorization inside |
|---|---|---|
| `add_inventory_item`, `remove_inventory_item`, `split_inventory_stack`, `merge_inventory_stacks`, `equip_item`, `unequip_item`, `attune_item`, `unattune_item`, `use_inventory_item`, `transfer_inventory_item` | authenticated | `can_write_inventory` / `can_deposit_inventory` on the locked row's inventory; `auth.uid()` required where relevant |
| `can_read_inventory(_row)`, `can_write_inventory(_row)`, `can_deposit_inventory`, `can_edit_item`, `can_edit_modifier`, `can_edit_owned` | authenticated | pure predicates (no writes) |
| `can_view_item`, `can_view_modifier`, `can_view_owned` | anon, authenticated | pure predicates; `auth.uid()` null → official rows only |
| `log_inventory_event`, `_lock_item`, `_split_off`, `_try_auto_merge`, `migrate_legacy_inventory`, trigger functions | nobody (revoked) | internal; called by other definer code / triggers |

## Policies by table (after)

| Table(s) | Roles | Policy | Requirement |
|---|---|---|---|
| 11 lookup tables (`item_kinds`, `item_categories`, `rarities`, `data_sources`, `source_books`, `currencies`, `damage_types`, `ammo_types`, `weapon_properties`, `equipment_slots`, `equipment_slot_rules`) | anon, authenticated | `*_read` SELECT `true` | public reference data; no write |
| `items` | anon, authenticated / authenticated | `items_read` (official or visible homebrew) · `items_homebrew_write` FOR ALL | catalog + homebrew (author, campaign DM, admin) |
| 11 per-item tables (`weapon_stats`, `weapon_property_links`, `firearm_stats`, `armor_stats`, `ammunition_stats`, `container_stats`, `mount_stats`, `vehicle_stats`, `consumable_effects`, `item_source_books`, `item_tag_links`) | anon, authenticated | `*_read` SELECT `can_view_item(item_id)` | visible with the item; read-only |
| `item_modifiers` | anon, authenticated / authenticated | read · `item_modifiers_homebrew_write` | official +N modifiers; homebrew modifiers |
| `item_modifier_categories`, `item_modifier_effects` | anon, authenticated / authenticated | read · write (`can_edit_modifier`) | define homebrew modifiers |
| `item_tags` | anon, authenticated | read | system tags |
| `inventories` | authenticated | read (row-based) · write FOR ALL (not `character`) | stash/shop/NPC by DM, personal stash by owner |
| `inventory_items` | authenticated | read `can_read_inventory(inventory_id)` · write `can_write_inventory(inventory_id)` + column privileges | owner / DM / admin; party stash read by members |
| `inventory_item_modifiers` | authenticated | read · write | apply/remove modifiers on own items |
| `character_equipment` | authenticated | read | equipment visible with the character; writes via RPC |
| `owned_assets` | authenticated | read · write | owner character / campaign DM |
| `inventory_events` | authenticated | read | audit visible with the inventory; no write |
| `legacy_inventory_review` | authenticated | read | owner / DM / admin see their review rows |

Overlaps: each table has at most one SELECT and one write policy; `FOR ALL` write policies also grant SELECT on rows the user may
edit, which is always a subset of the read policy — no escalation.

## Views

All 7 views are `security_invoker = true` (checked in the database). `v_item_catalog` is granted to anon; the others to
authenticated only. API test: another player gets `[]` from `v_inventory_detail`; anon gets 401.

## Index support for policies

`inventory_items (inventory_id)`, `inventory_events (inventory_id, created_at)`, `owned_assets (character_id / campaign_id)`,
`inventories (campaign_id)`, `legacy_inventory_review (character_id)`, the primary keys of `character_equipment` and
`inventory_item_modifiers`. Catalog policies run on tables that are too small to need one (docs/INDEX_STRATEGY.md).

## Accepted risks (game design, not security)

- A player may add any catalog item, apply any modifier to their own items and register any mount: there is no economy. The DM sees every change in `inventory_events`.
- Players can deposit into the party stash but not withdraw; only DMs move items out.
