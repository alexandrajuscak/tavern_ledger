"""Writes data/reports/index_audit.json: every explicit index of the first migration draft, with the decision.

Decisions: keep = has a real query / RLS / FK-action path; remove = duplicate, prefix of a PK/unique index,
or a lookup on a tiny reference table; defer = useful only once a planned feature or data volume exists.
Also checks that the kept indexes are exactly the ones created by the migrations.
"""
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CAT = "catalog table (~1.2k rows, loaded once and cached by the client): sequential scan is cheaper"
TINY = "reference/lookup table with tens of rows: sequential scan is cheaper; lookup rows are never deleted by clients"
I = [
    # name, table, columns, supports, overlap, mvp, decision, reason
    ("inventories_party_stash_uniq", "inventories", "(campaign_id) WHERE kind='party_stash'", "business rule: one party stash per campaign", "", True, "keep", "unique constraint, not a performance index"),
    ("equipment_slot_rules_uniq", "equipment_slot_rules", "(slot_id, kind, category, item)", "prevents duplicate slot rules", "", True, "keep", "unique constraint"),
    ("inventories_campaign_idx", "inventories", "(campaign_id) partial", "party stash/shop/NPC lookup; ON DELETE CASCADE from campaigns", "", True, "keep", "FK action + campaign-scoped inventories"),
    ("inventory_items_inventory_idx", "inventory_items", "(inventory_id)", "every inventory read; RLS can_read/can_write_inventory; auto-merge lookup", "", True, "keep", "main access path of the largest table"),
    ("inventory_items_item_idx", "inventory_items", "(item_id) partial", "ON DELETE RESTRICT check when a homebrew item is deleted", "", True, "keep", "FK check on the largest table"),
    ("inventory_items_container_idx", "inventory_items", "(container_item_id) partial", "ON DELETE SET NULL; v_container_contents / v_inventory_weight recursion", "", True, "keep", "FK action + container views"),
    ("inventory_events_inventory_idx", "inventory_events", "(inventory_id, created_at desc)", "event history per inventory (newest first); RLS filter; ON DELETE CASCADE", "", True, "keep", "history screen + RLS"),
    ("inventory_events_item_idx", "inventory_events", "(inventory_item_id) partial", "ON DELETE SET NULL on every hard delete (last potion used)", "", True, "keep", "otherwise every delete scans the event log"),
    ("owned_assets_character_idx", "owned_assets", "(character_id) partial", "RLS + ON DELETE CASCADE from characters", "", True, "keep", "owner relation"),
    ("owned_assets_campaign_idx", "owned_assets", "(campaign_id) partial", "RLS + ON DELETE CASCADE from campaigns", "", True, "keep", "owner relation"),
    ("items_name_trgm_idx", "items", "gin (name gin_trgm_ops)", "fuzzy server-side catalog search", "", False, "defer", "the client searches the cached catalog; also removes the pg_trgm dependency. Add when search moves to the server"),
    ("items_name_fts_idx", "items", "gin (to_tsvector(name))", "server-side full-text search", "", False, "defer", "same as trigram"),
    ("items_kind_idx", "items", "(kind_id)", "filter by kind", "", False, "defer", CAT + "; add above ~10k rows (e.g. lots of homebrew)"),
    ("items_category_idx", "items", "(category_id)", "filter by category", "", False, "defer", CAT + "; add above ~10k rows"),
    ("items_owner_idx", "items", "(owner_id) partial", "'my homebrew' list", "", False, "defer", "no homebrew UI yet"),
    ("items_campaign_idx", "items", "(campaign_id) partial", "campaign homebrew; ON DELETE CASCADE from campaigns", "", False, "defer", "few homebrew rows; add with the homebrew UI"),
    ("inventory_events_created_idx", "inventory_events", "(created_at)", "global retention/cleanup job", "covered per inventory by inventory_events_inventory_idx", False, "defer", "no retention job exists"),
    ("inventory_events_actor_idx", "inventory_events", "(actor_id) partial", "'what did this user do' audit screen", "", False, "defer", "no such screen"),
    ("items_rarity_idx", "items", "(rarity_id) partial", "filter by rarity", "", False, "remove", CAT),
    ("items_base_item_idx", "items", "(base_item_id) partial", "self FK ON DELETE SET NULL", "", False, "remove", CAT + "; base_item_id is null everywhere"),
    ("items_source_book_idx", "items", "(source_book_id) partial", "FK to source_books", "", False, "remove", TINY),
    ("items_data_source_idx", "items", "(data_source_id)", "FK to data_sources", "", False, "remove", TINY),
    ("items_cost_unit_idx", "items", "(cost_unit) partial", "FK to currencies", "", False, "remove", TINY),
    ("items_magic_idx", "items", "(rarity_id, name) WHERE is_magic", "magic item list", "", False, "remove", CAT),
    ("item_categories_kind_idx", "item_categories", "(kind_id)", "FK to item_kinds", "unique (kind_id, name) already starts with kind_id", False, "remove", "duplicate prefix of a unique index"),
    ("item_source_books_book_idx", "item_source_books", "(source_book_id)", "FK to source_books", "", False, "remove", TINY),
    ("weapon_stats_damage_type_idx", "weapon_stats", "(damage_type_id) partial", "FK to damage_types", "", False, "remove", TINY),
    ("weapon_stats_ammo_type_idx", "weapon_stats", "(ammo_type_id) partial", "FK to ammo_types", "", False, "remove", TINY),
    ("weapon_property_links_prop_idx", "weapon_property_links", "(property_id)", "FK to weapon_properties", "", False, "remove", TINY),
    ("ammunition_stats_type_idx", "ammunition_stats", "(ammo_type_id)", "FK to ammo_types", "", False, "remove", TINY),
    ("item_tag_links_tag_idx", "item_tag_links", "(tag_id)", "items by tag", "", False, "remove", TINY),
    ("item_tags_owner_idx", "item_tags", "(owner_id) partial", "player tags", "", False, "remove", "player tags are phase 2"),
    ("item_modifiers_kind_idx", "item_modifiers", "(applies_to_kind_id) partial", "FK", "", False, "remove", TINY),
    ("item_modifiers_rarity_idx", "item_modifiers", "(rarity_id) partial", "FK", "", False, "remove", TINY),
    ("item_modifiers_owner_idx", "item_modifiers", "(owner_id) partial", "homebrew modifiers", "", False, "remove", TINY),
    ("item_modifiers_campaign_idx", "item_modifiers", "(campaign_id) partial", "homebrew modifiers", "", False, "remove", TINY),
    ("item_modifier_categories_cat_idx", "item_modifier_categories", "(category_id)", "FK", "", False, "remove", TINY),
    ("equipment_slot_rules_slot_idx", "equipment_slot_rules", "(slot_id)", "equip trigger", "prefix of equipment_slot_rules_uniq", False, "remove", "duplicate prefix of a unique index; 34 rows"),
    ("equipment_slot_rules_item_idx", "equipment_slot_rules", "(item_id) partial", "FK", "", False, "remove", TINY),
    ("equipment_slot_rules_kind_idx", "equipment_slot_rules", "(kind_id, category_id)", "equip trigger", "", False, "remove", TINY),
    ("inventories_owner_idx", "inventories", "(owner_id) partial", "personal stash", "", False, "remove", "one row per character/stash; personal stashes are rare"),
    ("inventory_items_stack_idx", "inventory_items", "(stack_key) partial", "auto-merge lookup", "the lookup always filters by inventory_id first", False, "remove", "inventory_items_inventory_idx narrows to one inventory (tens of rows)"),
    ("inventory_items_attuned_idx", "inventory_items", "(inventory_id) WHERE is_attuned", "attunement count", "subset of inventory_items_inventory_idx", False, "remove", "covered by inventory_items_inventory_idx"),
    ("inventory_items_quest_idx", "inventory_items", "(inventory_id) WHERE is_quest_item", "quest item filter", "subset of inventory_items_inventory_idx", False, "remove", "no query pattern"),
    ("inventory_item_modifiers_item_idx", "inventory_item_modifiers", "(inventory_item_id)", "modifiers of a row; ON DELETE CASCADE", "prefix of the primary key (inventory_item_id, modifier_id)", False, "remove", "duplicate of the primary key"),
    ("inventory_item_modifiers_mod_idx", "inventory_item_modifiers", "(modifier_id)", "FK to item_modifiers", "", False, "remove", "modifiers are never deleted while applied (12 official rows)"),
    ("character_equipment_character_idx", "character_equipment", "(character_id)", "equipment of a character; RLS", "prefix of the primary key (character_id, slot_id)", False, "remove", "duplicate of the primary key"),
    ("character_equipment_item_idx", "character_equipment", "(inventory_item_id)", "ON DELETE CASCADE", "same column as the unique constraint", False, "remove", "exact duplicate of the unique index"),
    ("character_equipment_slot_idx", "character_equipment", "(slot_id)", "FK to equipment_slots", "", False, "remove", TINY),
    ("owned_assets_item_idx", "owned_assets", "(item_id)", "ON DELETE RESTRICT from items", "", False, "remove", "catalog items are not deleted; few assets"),
    ("inventory_events_catalog_idx", "inventory_events", "(item_id) partial", "ON DELETE SET NULL from items / 'history of an item'", "", False, "remove", "catalog items are not deleted; no query pattern"),
]
ADDED = [("legacy_inventory_review_character_idx", "legacy_inventory_review", "(character_id)", "RLS filter of the review table", "", True, "added", "new table in this review")]


def main():
    sql = "".join(p.read_text(encoding="utf-8") for p in sorted((ROOT / "supabase" / "migrations").glob("2026101500*.sql"))
                  if "base_schema" not in p.name)
    created = set(re.findall(r"create (?:unique )?index (\w+)", sql))
    expected = {i[0] for i in I if i[6] == "keep"} | {a[0] for a in ADDED}
    assert created == expected, (created ^ expected)
    rows = [dict(zip(("name", "table", "columns", "supports", "overlaps_with", "needed_for_mvp", "decision", "reason"), i)) for i in I + ADDED]
    summary = {"explicit_indexes_before": len(I), "kept": sum(i[6] == "keep" for i in I), "removed": sum(i[6] == "remove" for i in I),
               "deferred": sum(i[6] == "defer" for i in I), "added": len(ADDED), "explicit_indexes_after": len(expected),
               "all_indexes_added_by_inventory_migrations_before": 93, "all_indexes_added_by_inventory_migrations_after": 52,
               "note": "'all indexes' include primary keys and unique constraints; measured with pg_indexes on the local Supabase database"}
    out = ROOT / "data" / "reports" / "index_audit.json"
    out.write_text(json.dumps({"summary": summary, "indexes": rows}, indent=2) + "\n", encoding="utf-8", newline="\n")
    print("index audit ok:", summary)


if __name__ == "__main__":
    main()
