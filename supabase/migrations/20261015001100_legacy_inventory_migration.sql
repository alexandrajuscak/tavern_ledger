-- =============================================================================
-- One-time legacy data migration (docs/LEGACY_INVENTORY_MIGRATION.md, docs/EQUIPMENT_TRANSITION.md)
--
-- migrate_legacy_inventory() needs the catalog, so it runs AFTER the reference seed:
--     select public.migrate_legacy_inventory();
-- It is idempotent (works only on 'pending' review rows and unlinked rows) and is not callable by clients.
--
--  1. links free-text rows to the catalog when the name matches exactly one official item (case-insensitive);
--  2. moves legacy equipped rows into character_equipment when the slot is unambiguous, otherwise marks them
--     'equipped_manual' / 'manual_review' (the original value stays in legacy_inventory_review);
--  3. recomputes the legacy equipped column for every row, so it equals character_equipment.
-- Rows with quantity 0 are only classified (by the inventories migration); nothing is changed for them.
-- =============================================================================

create function public.migrate_legacy_inventory()
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  r record; it public.items; slot text; weapons int; rings int; linked int := 0; moved int := 0; manual int := 0;
begin
  -- 1. exact, unambiguous name links (quantity >= 1 only; a linked row must satisfy quantity >= 1)
  for r in
    select ii.id, ii.character_id, ii.name, ii.quantity, ii.equipped, min(i.id) as item_id
    from public.inventory_items ii
    join public.items i on lower(i.name) = lower(btrim(ii.name)) and i.owner_id is null
    where ii.item_id is null and ii.quantity >= 1
    group by ii.id, ii.character_id, ii.name, ii.quantity, ii.equipped
    having count(*) = 1
  loop
    update public.inventory_items set item_id = r.item_id where id = r.id;
    insert into public.legacy_inventory_review (inventory_item_id, character_id, legacy_name, legacy_quantity, legacy_equipped, category, status, detail)
    values (r.id, r.character_id, r.name, r.quantity, r.equipped, 'linked_by_name', 'done', jsonb_build_object('item_id', r.item_id));
    linked := linked + 1;
  end loop;

  -- 2. legacy equipped flags -> slots
  for r in
    select lr.id as review_id, lr.inventory_item_id, lr.character_id, ii.item_id, ii.quantity
    from public.legacy_inventory_review lr
    join public.inventory_items ii on ii.id = lr.inventory_item_id
    where lr.category = 'equipped_pending' and lr.status = 'pending'
    order by lr.character_id, ii.sort_order, ii.created_at
  loop
    slot := null;
    if r.item_id is null then
      update public.legacy_inventory_review set category = 'equipped_manual', status = 'manual_review',
             detail = detail || '{"reason":"not linked to a catalog item"}' where id = r.review_id;
      manual := manual + 1; continue;
    end if;
    if r.quantity <> 1 then
      update public.legacy_inventory_review set category = 'equipped_manual', status = 'manual_review',
             detail = detail || jsonb_build_object('reason', 'equipped stack of ' || r.quantity || ' (which piece?)') where id = r.review_id;
      manual := manual + 1; continue;
    end if;
    select * into it from public.items where id = r.item_id;
    select count(*) into weapons from public.legacy_inventory_review x join public.inventory_items y on y.id = x.inventory_item_id
      join public.items z on z.id = y.item_id
      where x.character_id = r.character_id and x.category in ('equipped_pending', 'equipped_migrated', 'equipped_manual') and z.kind_id = 'weapon';
    select count(*) into rings from public.legacy_inventory_review x join public.inventory_items y on y.id = x.inventory_item_id
      join public.items z on z.id = y.item_id
      where x.character_id = r.character_id and x.category in ('equipped_pending', 'equipped_migrated', 'equipped_manual') and z.category_id = 'ring';
    slot := case
      when it.kind_id = 'armor' and it.category_id = 'shield' then 'shield'
      when it.kind_id = 'armor' then 'armor'
      when it.kind_id = 'weapon' and weapons = 1 then 'main_hand'
      when it.category_id = 'ring' and rings = 1 then 'ring_1'
      else null end;
    if slot is null then
      update public.legacy_inventory_review set category = 'equipped_manual', status = 'manual_review',
             detail = detail || jsonb_build_object('reason', case when it.kind_id = 'weapon' then 'several equipped weapons: main/off hand unknown'
                                                                  when it.category_id = 'ring' then 'several rings: slot unknown'
                                                                  else 'no unambiguous slot for kind ' || it.kind_id end) where id = r.review_id;
      manual := manual + 1; continue;
    end if;
    begin
      insert into public.character_equipment (character_id, slot_id, inventory_item_id) values (r.character_id, slot, r.inventory_item_id);
      update public.legacy_inventory_review set category = 'equipped_migrated', status = 'done',
             detail = detail || jsonb_build_object('slot', slot) where id = r.review_id;
      moved := moved + 1;
    exception when others then
      update public.legacy_inventory_review set category = 'equipped_manual', status = 'manual_review',
             detail = detail || jsonb_build_object('reason', sqlerrm, 'slot_tried', slot) where id = r.review_id;
      manual := manual + 1;
    end;
  end loop;

  -- 3. the legacy column becomes the projection of character_equipment for every row
  update public.inventory_items ii set equipped = ii.equipped
  where ii.equipped is distinct from exists (select 1 from public.character_equipment e where e.inventory_item_id = ii.id);

  return jsonb_build_object(
    'linked_by_name', linked, 'equipped_migrated', moved, 'equipped_manual', manual,
    'review', (select coalesce(jsonb_object_agg(k, n), '{}'::jsonb)
               from (select category || '/' || status as k, count(*) as n from public.legacy_inventory_review group by 1) s));
end;
$$;
revoke all on function public.migrate_legacy_inventory() from public, anon, authenticated;
