-- =============================================================================
-- Equipment (character_equipment is the single source of truth for equipped state)
-- Equipment is a slot table, not a boolean on the stack:
--   * one slot holds at most one inventory item (PK character_id + slot_id)
--   * one inventory item sits in at most one slot (unique inventory_item_id)
--   * only items from the character's own inventory (checked in the trigger)
--   * equipping and attunement are independent
--   * two-handed weapons block off_hand and shield
-- Equipping one piece of a stack splits it first (see equip_item in 007).
-- inventory_items.equipped is only a read-only projection of this table (see the inventories migration).
-- Clients cannot write this table directly; equip_item / unequip_item are the only write path.
-- =============================================================================

-- Which items fit which slot. A rule is either a kind (+ optional category) or one specific item.
create table public.equipment_slot_rules (
  id          int generated always as identity primary key,
  slot_id     text not null references public.equipment_slots (id) on delete cascade,
  kind_id     text references public.item_kinds (id),
  category_id text references public.item_categories (id),
  item_id     text references public.items (id) on delete cascade,
  constraint slot_rule_shape check (
    (item_id is not null and kind_id is null and category_id is null)
    or (item_id is null and kind_id is not null))
);
create unique index equipment_slot_rules_uniq
  on public.equipment_slot_rules (slot_id, coalesce(kind_id, ''), coalesce(category_id, ''), coalesce(item_id, ''));

create table public.character_equipment (
  character_id      uuid not null references public.characters (id) on delete cascade,
  slot_id           text not null references public.equipment_slots (id),
  inventory_item_id uuid not null unique references public.inventory_items (id) on delete cascade,
  equipped_at       timestamptz not null default now(),
  primary key (character_id, slot_id)
);

create function public.character_equipment_before_write()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
declare ii public.inventory_items; inv public.inventories; it public.items; two boolean;
begin
  perform pg_advisory_xact_lock(hashtext(new.character_id::text));
  select * into ii from public.inventory_items where id = new.inventory_item_id;
  if ii.item_id is null then raise exception 'Only catalog items can be equipped'; end if;
  select * into inv from public.inventories where id = ii.inventory_id;
  if inv.character_id is distinct from new.character_id then
    raise exception 'The item does not belong to this character''s inventory';
  end if;
  if ii.quantity <> 1 then raise exception 'Split the stack before equipping (quantity must be 1)'; end if;
  select * into it from public.items where id = ii.item_id;

  if not exists (
    select 1 from public.equipment_slot_rules r
    where r.slot_id = new.slot_id
      and (r.item_id = it.id
           or (r.item_id is null and r.kind_id = it.kind_id and (r.category_id is null or r.category_id = it.category_id)))
  ) then
    raise exception 'Item % cannot be equipped in slot %', it.id, new.slot_id;
  end if;

  two := exists (select 1 from public.weapon_property_links l where l.item_id = it.id and l.property_id = 'two-handed');
  if two and new.slot_id = 'off_hand' then
    raise exception 'A two-handed weapon cannot be held in the off hand';
  end if;
  if two and new.slot_id = 'main_hand' and exists (
       select 1 from public.character_equipment e
       where e.character_id = new.character_id and e.slot_id in ('off_hand', 'shield') and e.inventory_item_id <> new.inventory_item_id) then
    raise exception 'A two-handed weapon needs the off hand and shield slots to be empty';
  end if;
  if new.slot_id in ('off_hand', 'shield') and exists (
       select 1 from public.character_equipment e
       join public.inventory_items x on x.id = e.inventory_item_id
       join public.weapon_property_links l on l.item_id = x.item_id and l.property_id = 'two-handed'
       where e.character_id = new.character_id and e.slot_id = 'main_hand') then
    raise exception 'The main hand holds a two-handed weapon';
  end if;
  return new;
end;
$$;

create trigger character_equipment_before_write before insert or update on public.character_equipment
  for each row execute function public.character_equipment_before_write();

-- after (un)equipping: refresh the stack key (equipped rows are never merged) and write the event
create function public.character_equipment_after_write()
returns trigger
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare iid uuid := coalesce(new.inventory_item_id, old.inventory_item_id); r public.inventory_items;
begin
  select * into r from public.inventory_items where id = iid;
  if r.id is not null then
    update public.inventory_items set stack_key = public.compute_stack_key(r) where id = iid;
    perform public.log_inventory_event(r.inventory_id, r.id, case tg_op when 'DELETE' then 'unequip' else 'equip' end, null, r.item_id,
      jsonb_build_object('slot', coalesce(new.slot_id, old.slot_id)));
  end if;
  return null;
end;
$$;

revoke all on function public.character_equipment_after_write() from public, anon, authenticated;

create trigger character_equipment_after_write after insert or update or delete on public.character_equipment
  for each row execute function public.character_equipment_after_write();

do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    alter publication supabase_realtime add table public.character_equipment;
  end if;
end $$;
