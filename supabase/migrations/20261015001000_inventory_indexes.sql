-- =============================================================================
-- Indexes after the audit (data/reports/index_audit.json, docs/INDEX_STRATEGY.md).
-- Only indexes with a real query, RLS or foreign-key-action path. Primary keys and unique constraints
-- already cover: character_equipment (character_id, ...) and (inventory_item_id), inventory_item_modifiers
-- (inventory_item_id, ...), weapon_property_links (item_id, ...), inventories (character_id).
-- Catalog tables (~1.2k rows, cached by the client) get no secondary indexes; pg_trgm / full-text search
-- are deferred until server-side catalog search exists.
-- =============================================================================

-- inventory lookups and RLS (can_read_inventory / can_write_inventory filter by inventory_id)
create index inventory_items_inventory_idx on public.inventory_items (inventory_id);
-- ON DELETE SET NULL of container_item_id and the container views walk this column
create index inventory_items_container_idx on public.inventory_items (container_item_id) where container_item_id is not null;
-- ON DELETE RESTRICT check when a (homebrew) catalog item is deleted; inventory_items is the large table
create index inventory_items_item_idx on public.inventory_items (item_id) where item_id is not null;

-- event history per inventory (newest first) and the RLS filter on inventory_events
create index inventory_events_inventory_idx on public.inventory_events (inventory_id, created_at desc);
-- ON DELETE SET NULL: every hard delete of an inventory row (last potion used) touches this column
create index inventory_events_item_idx on public.inventory_events (inventory_item_id) where inventory_item_id is not null;

-- campaign-scoped inventories (party stash / shop / NPC) and ON DELETE CASCADE from campaigns
create index inventories_campaign_idx on public.inventories (campaign_id) where campaign_id is not null;

-- owned assets by owner (RLS + ON DELETE CASCADE from characters / campaigns)
create index owned_assets_character_idx on public.owned_assets (character_id) where character_id is not null;
create index owned_assets_campaign_idx  on public.owned_assets (campaign_id) where campaign_id is not null;

-- legacy review by character (RLS)
create index legacy_inventory_review_character_idx on public.legacy_inventory_review (character_id);
