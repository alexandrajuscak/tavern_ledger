-- Runs migrate_legacy_inventory() on the fixture and checks every expected outcome. Raises on the first failure.
do $$
declare res jsonb; bad text;
begin
  res := public.migrate_legacy_inventory();
  raise warning 'migrate_legacy_inventory: %', res;
  -- the second run changes nothing (idempotent)
  if public.migrate_legacy_inventory() -> 'linked_by_name' <> '0'::jsonb then raise exception 'second run linked rows again'; end if;

  select string_agg(x, '; ') into bad from (
    select 'Quarterstaff not in main_hand' as x where not exists (select 1 from public.character_equipment e join public.inventory_items i on i.id = e.inventory_item_id
                                                                   where i.name = 'Quarterstaff' and e.slot_id = 'main_hand')
    union all select 'Shield not in shield slot' where not exists (select 1 from public.character_equipment e join public.inventory_items i on i.id = e.inventory_item_id
                                                                    where i.name = 'Shield' and e.slot_id = 'shield')
    union all select 'Leather Armor should be manual' where not exists (select 1 from public.legacy_inventory_review where legacy_name = 'Leather Armor' and category = 'equipped_manual')
    union all select 'Darts should be manual' where not exists (select 1 from public.legacy_inventory_review where legacy_name = 'Darts' and category = 'equipped_manual')
    union all select 'twin blades should both be manual' where (select count(*) from public.legacy_inventory_review where legacy_name in ('Longsword', 'Dagger') and category = 'equipped_manual') <> 2
    union all select 'Herbalism Kit not linked' where not exists (select 1 from public.inventory_items where name = 'Herbalism Kit' and item_id = 'herbalism-kit')
    union all select 'qty0 categories wrong' where (select string_agg(category, ',' order by category) from public.legacy_inventory_review where category like 'qty0%')
                                                  <> 'qty0_convertible,qty0_corrupted,qty0_empty_placeholder,qty0_manual'
    union all select 'qty0 rows changed' where (select count(*) from public.inventory_items where quantity = 0) <> 4
    union all select 'legacy values changed' where not exists (select 1 from public.inventory_items where name = 'Quarterstaff' and quantity = 1 and weight = 4 and description = 'worn smooth')
    union all select 'equipped column disagrees with character_equipment' where exists (
      select 1 from public.inventory_items ii where ii.equipped is distinct from exists (select 1 from public.character_equipment e where e.inventory_item_id = ii.id))
    union all select 'original equipped values lost' where (select count(*) from public.legacy_inventory_review where legacy_equipped and category like 'equipped%') <> 7
  ) f;
  if bad is not null then raise exception 'legacy migration: %', bad; end if;
  raise warning 'PASSED  legacy migration: 2 equipped rows moved to slots, 5 sent to manual review, 4 quantity-0 rows classified, values unchanged, equipped column consistent';
end $$;
