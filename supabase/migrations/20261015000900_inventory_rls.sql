-- =============================================================================
-- Row level security and grants (reviewed: docs/RLS_SECURITY_REVIEW.md)
--
--  * Reference data (lookups, official catalog, typed stats): readable by anon + authenticated, never
--    writable by a client (only the seed / service role).
--  * Homebrew: only the items row and modifiers are client-writable (author, campaign DM, admin).
--    Typed stats of homebrew items are phase 2 (no client write).
--  * Inventories follow the existing campaign model (admin / campaign DM / character owner).
--  * Structural inventory changes (catalog item, inventory, attunement, equipment) go through the RPCs:
--    column-level privileges keep the legacy frontend's columns writable and nothing else.
--  * inventory_events and character_equipment are read-only for clients.
-- Existing campaigns / campaign_members / characters and their helpers are reused.
-- =============================================================================

do $$
declare t text;
begin
  foreach t in array array[
    'item_kinds','item_categories','rarities','data_sources','source_books','currencies','damage_types','ammo_types',
    'weapon_properties','equipment_slots','equipment_slot_rules','items','item_source_books','item_provenance',
    'weapon_stats','weapon_property_links','firearm_stats','armor_stats','ammunition_stats','container_stats',
    'mount_stats','vehicle_stats','consumable_effects','item_modifiers','item_modifier_categories',
    'item_modifier_effects','item_tags','item_tag_links','inventories','inventory_item_modifiers','character_equipment',
    'owned_assets','inventory_events','legacy_inventory_review'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from anon, authenticated', t);
  end loop;
end $$;

-- ---- reference data: one read policy per table, no write ---------------------------------------------
do $$
declare t text;
begin
  foreach t in array array['item_kinds','item_categories','rarities','data_sources','source_books','currencies','damage_types',
                           'ammo_types','weapon_properties','equipment_slots','equipment_slot_rules'] loop
    execute format('create policy "%1$s_read" on public.%1$I for select to anon, authenticated using (true)', t);
    execute format('grant select on public.%I to anon, authenticated', t);
  end loop;
  -- per-item reference tables: visible when the item is visible (official items to everyone)
  foreach t in array array['item_source_books','weapon_stats','weapon_property_links','firearm_stats','armor_stats',
                           'ammunition_stats','container_stats','mount_stats','vehicle_stats','consumable_effects','item_tag_links'] loop
    execute format('create policy "%1$s_read" on public.%1$I for select to anon, authenticated using (public.can_view_item(item_id))', t);
    execute format('grant select on public.%I to anon, authenticated', t);
  end loop;
end $$;
-- item_provenance: RLS on, no policy, no grant -> internal audit data, not exposed to clients.

-- ---- items: official read for all, homebrew write ------------------------------------------------------
-- Policies evaluate the row's own columns (see can_view_owned): an id lookup would reject INSERT ... RETURNING.
create policy "items_read" on public.items for select to anon, authenticated using (public.can_view_owned(owner_id, campaign_id));
-- One write policy. A new row must be the caller's own (items_before_write); a DM may edit campaign homebrew
-- but never re-assign authorship (items_before_write blocks owner changes).
create policy "items_homebrew_write" on public.items for all to authenticated
  using (public.can_edit_owned(owner_id, campaign_id))
  with check (public.can_edit_owned(owner_id, campaign_id)
              and (campaign_id is null or public.is_admin() or public.is_campaign_member(campaign_id)));
grant select on public.items to anon, authenticated;
grant insert, update, delete on public.items to authenticated;

-- ---- modifiers -----------------------------------------------------------------------------------------
create policy "item_modifiers_read" on public.item_modifiers for select to anon, authenticated using (public.can_view_owned(owner_id, campaign_id));
create policy "item_modifiers_homebrew_write" on public.item_modifiers for all to authenticated
  using (public.can_edit_owned(owner_id, campaign_id))
  with check (public.can_edit_owned(owner_id, campaign_id)
              and (campaign_id is null or public.is_admin() or public.is_campaign_member(campaign_id)));
grant select on public.item_modifiers to anon, authenticated;
grant insert, update, delete on public.item_modifiers to authenticated;

do $$
declare t text;
begin
  foreach t in array array['item_modifier_categories','item_modifier_effects'] loop
    execute format('create policy "%1$s_read" on public.%1$I for select to anon, authenticated using (public.can_view_modifier(modifier_id))', t);
    execute format('create policy "%1$s_write" on public.%1$I for all to authenticated
                      using (public.can_edit_modifier(modifier_id)) with check (public.can_edit_modifier(modifier_id))', t);
    execute format('grant select on public.%I to anon, authenticated', t);
    execute format('grant insert, update, delete on public.%I to authenticated', t);
  end loop;
end $$;

-- ---- tags: read only (player tags are phase 2) ---------------------------------------------------------
create policy "item_tags_read" on public.item_tags for select to anon, authenticated
  using (owner_id is null or owner_id = auth.uid() or public.is_admin());
grant select on public.item_tags to anon, authenticated;

-- ---- inventories ---------------------------------------------------------------------------------------
create policy "inventories_read" on public.inventories for select to authenticated
  using (public.can_read_inventory_row(kind, character_id, campaign_id, owner_id));
-- character inventories are created by a trigger and never changed by clients;
-- DMs/admins manage party stash, NPC and shop inventories; a player may own a personal stash
create policy "inventories_write" on public.inventories for all to authenticated
  using (kind <> 'character' and public.can_write_inventory_row(kind, character_id, campaign_id, owner_id))
  with check (kind <> 'character'
              and (public.is_admin()
                   or (campaign_id is not null and public.is_campaign_dm(campaign_id))
                   or (kind = 'stash' and campaign_id is null and owner_id = auth.uid())));
grant select, insert, update, delete on public.inventories to authenticated;

-- ---- inventory_items: replaces the base schema's character-only policy ----------------------------------
drop policy "inventory_items_all" on public.inventory_items;
create policy "inventory_items_read" on public.inventory_items for select to authenticated
  using (public.can_read_inventory(inventory_id));
create policy "inventory_items_write" on public.inventory_items for all to authenticated
  using (public.can_write_inventory(inventory_id))
  with check (public.can_write_inventory(inventory_id));

-- Column privileges. INSERT keeps exactly what the legacy frontend sends (free-text rows); catalog items are
-- added with add_inventory_item. UPDATE excludes inventory_id, item_id, character_id, is_attuned, attuned_at,
-- stack_key: moving, re-typing and attuning only happen through RPCs. `equipped` stays writable so the legacy
-- checkbox does not error, but the value is ignored (it is recomputed from character_equipment).
revoke insert, update on public.inventory_items from anon, authenticated;
revoke all on public.inventory_items from anon;
grant insert (character_id, name, quantity, weight, description, equipped, sort_order) on public.inventory_items to authenticated;
grant update (name, quantity, weight, description, equipped, sort_order, custom_name, notes, container_item_id, is_quest_item,
              state, charges_current, charges_max, charges_recharge, durability, consumable_override) on public.inventory_items to authenticated;

create policy "inventory_item_modifiers_read" on public.inventory_item_modifiers for select to authenticated
  using (public.can_read_inventory(public.inventory_of_item(inventory_item_id)));
create policy "inventory_item_modifiers_write" on public.inventory_item_modifiers for all to authenticated
  using (public.can_write_inventory(public.inventory_of_item(inventory_item_id)))
  with check (public.can_write_inventory(public.inventory_of_item(inventory_item_id)));
grant select, insert, delete on public.inventory_item_modifiers to authenticated;

-- equipment: read-only for clients; equip_item / unequip_item are the only write path
create policy "character_equipment_read" on public.character_equipment for select to authenticated
  using (public.can_access_character(character_id));
grant select on public.character_equipment to authenticated;

create policy "owned_assets_read" on public.owned_assets for select to authenticated
  using (public.is_admin()
         or (character_id is not null and public.can_access_character(character_id))
         or (campaign_id is not null and public.is_campaign_member(campaign_id)));
create policy "owned_assets_write" on public.owned_assets for all to authenticated
  using (public.is_admin()
         or (character_id is not null and public.can_access_character(character_id))
         or (campaign_id is not null and public.is_campaign_dm(campaign_id)))
  with check (public.is_admin()
         or (character_id is not null and public.can_access_character(character_id))
         or (campaign_id is not null and public.is_campaign_dm(campaign_id)));
grant select, insert, update, delete on public.owned_assets to authenticated;

create policy "inventory_events_read" on public.inventory_events for select to authenticated
  using (public.can_read_inventory(inventory_id));
grant select on public.inventory_events to authenticated;    -- no INSERT/UPDATE/DELETE: events cannot be forged

create policy "legacy_inventory_review_read" on public.legacy_inventory_review for select to authenticated
  using (public.is_admin() or (character_id is not null and public.can_access_character(character_id)));
grant select on public.legacy_inventory_review to authenticated;

-- ---- views -----------------------------------------------------------------------------------------------
revoke all on public.v_item_catalog, public.v_inventory_detail, public.v_character_equipment, public.v_inventory_weight,
  public.v_container_contents, public.v_character_attunement, public.v_owned_assets_detail from public, anon, authenticated;
grant select on public.v_item_catalog to anon, authenticated;
grant select on public.v_inventory_detail, public.v_character_equipment, public.v_inventory_weight, public.v_container_contents,
  public.v_character_attunement, public.v_owned_assets_detail to authenticated;
