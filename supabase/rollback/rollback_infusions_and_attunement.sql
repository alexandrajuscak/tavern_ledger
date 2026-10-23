-- =============================================================================
-- Rollback of 20261017000900_infusions_and_attunement.sql ONLY: drops the infusion RPCs and character_infusions (active infusion modifiers on items are removed with
-- them), restores the inventory triggers of 20261015000500 and the fixed attunement limit of 3. Refuses while catalog item
-- modifiers are managed by class infusions (run rollback_class_catalog.sql first).
-- =============================================================================
begin;

do $$
begin
  if exists (select 1 from public.item_modifiers where managed_by is not null) then
    raise exception 'Official class content still uses managed item modifiers; run rollback_class_catalog.sql first';
  end if;
end $$;

drop function if exists public.refresh_infusions(uuid);
drop function if exists public.remove_infusion(uuid, uuid);
drop function if exists public.apply_infusion(uuid, text, uuid, text);
drop function if exists public.get_character_infusions(uuid);
drop function if exists public._infusion_item_refusal(jsonb, public.inventory_items);
drop function if exists public._infusion_modifier(jsonb, int);
drop function if exists public._character_infusion_choices(uuid);
drop table if exists public.character_infusions;
drop trigger if exists inventory_item_modifiers_before_delete on public.inventory_item_modifiers;

create or replace function public.inventory_items_before_write()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
declare
  inv public.inventories; it public.items;
  cur uuid; nxt uuid; lvl int := 1; maxd int; below int; n int;
  max_depth constant int := 8;
begin
  -- keep legacy character_id and inventory_id in sync (legacy clients only send character_id)
  if new.inventory_id is null then
    select id into new.inventory_id from public.inventories where character_id = new.character_id and kind = 'character';
    if new.inventory_id is null then raise exception 'inventory_id or a character with an inventory is required'; end if;
  end if;
  select * into inv from public.inventories where id = new.inventory_id;
  new.character_id := inv.character_id;

  -- quantity: no NEW zero rows. Legacy rows that already have 0 may keep it until reviewed.
  if new.quantity < 1 and (tg_op = 'INSERT' or new.quantity is distinct from old.quantity) then
    raise exception 'Quantity must be at least 1 (remove the item instead)' using errcode = '23514';
  end if;

  if tg_op = 'INSERT' and new.item_id is not null then
    select * into it from public.items where id = new.item_id;
    if new.name is null or btrim(new.name) = '' or new.name = 'New item' then new.name := it.name; end if;
    if new.weight = 0 and it.weight_lb is not null then new.weight := it.weight_lb; end if;
  end if;

  -- equipped is a projection of character_equipment; whatever the client sent is ignored
  new.equipped := tg_op = 'UPDATE' and exists (select 1 from public.character_equipment e where e.inventory_item_id = new.id);

  if new.equipped then
    if new.quantity <> 1 then raise exception 'An equipped item must have quantity 1; unequip it or split the stack first'; end if;
    if new.inventory_id <> old.inventory_id then raise exception 'An equipped item cannot be moved to another inventory'; end if;
  end if;

  -- containers: same inventory, no cycles, bounded depth (global 8, or a container's own max_nested_depth)
  if new.container_item_id is not null then
    if not exists (select 1 from public.inventory_items c where c.id = new.container_item_id and c.inventory_id = new.inventory_id) then
      raise exception 'A container must be in the same inventory';
    end if;
    cur := new.container_item_id;
    while cur is not null loop
      if cur = new.id then raise exception 'Container cycle: an item cannot be inside itself'; end if;
      if lvl > max_depth then raise exception 'Containers can be nested at most % levels deep', max_depth; end if;
      select c.container_item_id, cs.max_nested_depth into nxt, maxd
      from public.inventory_items c left join public.container_stats cs on cs.item_id = c.item_id where c.id = cur;
      if maxd is not null and lvl > maxd then raise exception 'This container allows at most % nested level(s)', maxd; end if;
      cur := nxt;
      lvl := lvl + 1;
    end loop;
    if tg_op = 'UPDATE' then        -- the moved item may carry its own contents
      with recursive sub as (
        select id, 1 as d from public.inventory_items where container_item_id = new.id
        union all
        select x.id, s.d + 1 from sub s join public.inventory_items x on x.container_item_id = s.id where s.d <= max_depth
      ) select coalesce(max(d), 0) into below from sub;
      if (lvl - 1) + below > max_depth then raise exception 'Containers can be nested at most % levels deep', max_depth; end if;
    end if;
  end if;

  -- attunement: independent of equipping, at most 3 per character inventory (serialized per inventory)
  if new.is_attuned then
    if new.item_id is not null and not (select requires_attunement from public.items where id = new.item_id) then
      raise exception 'This item does not require attunement';
    end if;
    if inv.kind = 'character' then
      perform pg_advisory_xact_lock(hashtext(new.inventory_id::text));
      select count(*) into n from public.inventory_items x
      where x.inventory_id = new.inventory_id and x.is_attuned and x.id <> new.id;
      if n >= 3 then raise exception 'Attunement limit reached (3)'; end if;
    end if;
    if tg_op = 'INSERT' or not old.is_attuned then new.attuned_at := now(); end if;
  else
    new.attuned_at := null;
  end if;

  new.stack_key := public.compute_stack_key(new);
  return new;
end;
$$;

create or replace function public.inventory_item_modifiers_before_write()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
declare it public.items; m public.item_modifiers;
begin
  select i.* into it from public.inventory_items ii join public.items i on i.id = ii.item_id where ii.id = new.inventory_item_id;
  if it.id is null then raise exception 'Modifiers can only be applied to catalog items'; end if;
  select * into m from public.item_modifiers where id = new.modifier_id;
  if m.applies_to_kind_id is not null and m.applies_to_kind_id <> it.kind_id then
    raise exception 'Modifier % does not apply to items of kind %', m.id, it.kind_id;
  end if;
  if exists (select 1 from public.item_modifier_categories c where c.modifier_id = m.id)
     and not exists (select 1 from public.item_modifier_categories c where c.modifier_id = m.id and c.category_id = it.category_id) then
    raise exception 'Modifier % does not apply to category %', m.id, coalesce(it.category_id, '(none)');
  end if;
  return new;
end;
$$;

create or replace view public.v_character_attunement with (security_invoker = true) as
select c.id as character_id,
       count(ii.id) filter (where ii.is_attuned)::int as attuned_count,
       3 as attunement_limit,
       3 - count(ii.id) filter (where ii.is_attuned)::int as slots_free
from public.characters c
left join public.inventories inv on inv.character_id = c.id
left join public.inventory_items ii on ii.inventory_id = inv.id
group by c.id;

drop function if exists public._character_attunement_limit(uuid);
alter table public.item_modifiers drop column if exists managed_by;

do $$
begin
  if to_regclass('supabase_migrations.schema_migrations') is not null then
    delete from supabase_migrations.schema_migrations where version = '20261017000900';
  end if;
end $$;

commit;
