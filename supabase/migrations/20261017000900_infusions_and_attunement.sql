-- =============================================================================
-- Infusions and attunement (generic engines on the inventory):
--   * a class feature option can carry an infusion block (class_feature_choice_options.data.infusion): which items it can go
--     into (kinds / categories / item ids / weapon properties), whether it needs attunement, the item modifiers it applies by
--     class level (official item_modifiers managed_by 'class_infusion'), a companion it creates or the magic items it can
--     replicate. The choice config infused_items_by_level limits how many items are infused at once.
--   * character_infusions: the active infusions of a character (one per item; RPC only)
--   * RPCs get_character_infusions, apply_infusion, remove_infusion, refresh_infusions
--   * managed item modifiers cannot be applied or removed directly (only through their RPC)
--   * attunement: the limit is 3 or the highest active class effect attunement_limit (Magic Item Adept ...); an item needs
--     attunement when the item or one of its modifiers requires it (an infused rod)
-- =============================================================================

alter table public.item_modifiers add column managed_by text check (managed_by in ('class_infusion'));

create function public._character_attunement_limit(p_character uuid)
returns int
language sql stable security definer
set search_path = public, pg_temp
as $$
  select greatest(3, coalesce((select max(x.value)::int from public._character_class_effects(p_character) x
                               where x.active and x.effect_type = 'attunement_limit'), 3));
$$;
revoke all on function public._character_attunement_limit(uuid) from public, anon;
grant execute on function public._character_attunement_limit(uuid) to authenticated;

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
    if new.item_id is not null and not (select requires_attunement from public.items where id = new.item_id)
       and not exists (select 1 from public.inventory_item_modifiers im join public.item_modifiers md on md.id = im.modifier_id
                       where im.inventory_item_id = new.id and md.requires_attunement_override) then
      raise exception 'This item does not require attunement';
    end if;
    if inv.kind = 'character' then
      perform pg_advisory_xact_lock(hashtext(new.inventory_id::text));
      select count(*) into n from public.inventory_items x
      where x.inventory_id = new.inventory_id and x.is_attuned and x.id <> new.id;
      if n >= public._character_attunement_limit(inv.character_id) then
        raise exception 'Attunement limit reached (%)', public._character_attunement_limit(inv.character_id);
      end if;
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
  if tg_op = 'DELETE' then
    if exists (select 1 from public.item_modifiers x where x.id = old.modifier_id and x.managed_by is not null)
       and coalesce(current_setting('tavern.managed_modifier', true), '') <> '1' then
      raise exception 'This modifier is managed by a class feature; end it there (Infuse Item)' using errcode = '42501';
    end if;
    return old;
  end if;
  select i.* into it from public.inventory_items ii join public.items i on i.id = ii.item_id where ii.id = new.inventory_item_id;
  if it.id is null then raise exception 'Modifiers can only be applied to catalog items'; end if;
  select * into m from public.item_modifiers where id = new.modifier_id;
  if m.managed_by is not null and coalesce(current_setting('tavern.managed_modifier', true), '') <> '1' then
    raise exception 'This modifier is applied by a class feature (Infuse Item), not directly' using errcode = '42501';
  end if;
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

create trigger inventory_item_modifiers_before_delete before delete on public.inventory_item_modifiers
  for each row execute function public.inventory_item_modifiers_before_write();

create or replace view public.v_character_attunement with (security_invoker = true) as
select c.id as character_id,
       count(ii.id) filter (where ii.is_attuned)::int as attuned_count,
       public._character_attunement_limit(c.id) as attunement_limit,
       public._character_attunement_limit(c.id) - count(ii.id) filter (where ii.is_attuned)::int as slots_free
from public.characters c
left join public.inventories inv on inv.character_id = c.id
left join public.inventory_items ii on ii.inventory_id = inv.id
group by c.id;

create table public.character_infusions (
  id                 uuid primary key default gen_random_uuid(),
  character_id       uuid not null references public.characters (id) on delete cascade,
  character_class_id uuid not null references public.character_classes (id) on delete cascade,
  infusion_id        text not null,
  choice_id          text not null,
  inventory_item_id  uuid unique references public.inventory_items (id) on delete cascade,
  modifier_id        text references public.item_modifiers (id),
  created_item       boolean not null default false,
  companion_id       uuid references public.character_companions (id) on delete set null,
  applied_at         timestamptz not null default now(),
  applied_by         uuid references auth.users (id) on delete set null
);
create index character_infusions_character on public.character_infusions (character_id);
alter table public.character_infusions enable row level security;
create policy "character_infusions_read" on public.character_infusions for select to authenticated
  using (public.can_access_character(character_id));
revoke all on public.character_infusions from anon, authenticated;
grant select on public.character_infusions to authenticated;

-- ---- what a character knows and has infused ---------------------------------------------------------------------------------
-- Infusion choices: open option choices whose options carry data.infusion (known = the stored values).
create function public._character_infusion_choices(p_character uuid)
returns table (character_class_id uuid, class_level int, choice_id text, unlock_id text, known text[], max_items int)
language sql stable
set search_path = public, pg_temp
as $$
  select ch.character_class_id, ch.class_level, ch.choice_id, ch.unlock_id, ch.vals,
         coalesce((select (e ->> 1)::int from jsonb_array_elements(ch.config -> 'infused_items_by_level') e
                   where (e ->> 0)::int <= ch.class_level order by (e ->> 0)::int desc limit 1), 0)
  from public._character_feature_choice_rows(p_character) ch
  where ch.open and ch.kind = 'option' and ch.config ? 'infused_items_by_level';
$$;

-- The modifier of an infusion at a class level (the highest variant reached).
create function public._infusion_modifier(p_inf jsonb, p_level int)
returns text
language sql immutable
as $$
  select m ->> 'id' from jsonb_array_elements(coalesce(p_inf -> 'modifiers', '[]')) m
  where (m ->> 'from_level')::int <= p_level order by (m ->> 'from_level')::int desc limit 1;
$$;

-- Why an inventory item cannot take an infusion (null = it can).
create function public._infusion_item_refusal(p_inf jsonb, p_item public.inventory_items)
returns text
language sql stable
set search_path = public, pg_temp
as $$
  select case
    when i.id is null then 'Only catalog items can be infused'
    when exists (select 1 from public.character_infusions ci where ci.inventory_item_id = p_item.id) then 'This item already holds an infusion'
    when i.is_magic or exists (select 1 from public.inventory_item_modifiers im where im.inventory_item_id = p_item.id)
      then 'Magic items cannot be infused'
    when r ? 'item_ids' and not r ? 'kinds' and not r -> 'item_ids' ? i.id then 'This infusion needs ' || coalesce(r ->> 'note', 'another item')
    when r ? 'kinds' and not (r -> 'kinds' ? i.kind_id or coalesce(r -> 'item_ids' ? i.id, false)) then 'This infusion needs ' || coalesce(r ->> 'note', 'another kind of item')
    when r ? 'categories' and not r -> 'categories' ? coalesce(i.category_id, '') then 'This infusion needs ' || coalesce(r ->> 'note', 'another kind of item')
    when r ? 'exclude_categories' and r -> 'exclude_categories' ? coalesce(i.category_id, '') then 'This infusion cannot go into this item'
    when r ? 'properties' and not exists (select 1 from public.weapon_property_links l
                                          where l.item_id = i.id and r -> 'properties' ? l.property_id) then 'This weapon lacks the property the infusion needs'
  end
  from (select p_inf -> 'item' as r) q left join public.items i on i.id = p_item.item_id;
$$;

create function public.get_character_infusions(p_character uuid)
returns jsonb
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
declare inv uuid;
begin
  if auth.uid() is null or not public.can_access_character(p_character) then
    raise exception 'Character not found' using errcode = '42501';
  end if;
  select id into inv from public.inventories where character_id = p_character and kind = 'character';
  return jsonb_build_object('character_id', p_character,
    'choices', coalesce((select jsonb_agg(jsonb_build_object('character_class_id', c.character_class_id, 'choice_id', c.choice_id,
                 'unlock_id', c.unlock_id, 'class_level', c.class_level, 'max_items', c.max_items,
                 'active_count', (select count(*) from public.character_infusions ci where ci.character_id = p_character and ci.choice_id = c.choice_id),
                 'known', (select coalesce(jsonb_agg(jsonb_build_object('id', o.option_id, 'label', o.label, 'summary', o.summary,
                                 'infusion', o.data -> 'infusion', 'modifier', public._infusion_modifier(o.data -> 'infusion', c.class_level),
                                 'replicable', (select coalesce(jsonb_agg(x), '[]') from jsonb_array_elements(o.data -> 'infusion' -> 'replicate') e,
                                                  jsonb_array_elements_text(e -> 1) x where (e ->> 0)::int <= c.class_level),
                                 'candidates', case when o.data -> 'infusion' -> 'item' ? 'none' then '[]'::jsonb else
                                   (select coalesce(jsonb_agg(jsonb_build_object('inventory_item_id', ii.id, 'name', coalesce(ii.custom_name, it.name),
                                              'refusal', public._infusion_item_refusal(o.data -> 'infusion', ii)) order by it.name), '[]')
                                    from public.inventory_items ii join public.items it on it.id = ii.item_id where ii.inventory_id = inv) end)
                               order by o.label), '[]')
                           from public.class_feature_choice_options o where o.choice_id = c.choice_id and o.option_id = any (c.known))))
               from public._character_infusion_choices(p_character) c), '[]'),
    'active', coalesce((select jsonb_agg(jsonb_build_object('id', ci.id, 'infusion_id', ci.infusion_id, 'label', o.label,
                 'inventory_item_id', ci.inventory_item_id, 'item_name', coalesce(ii.custom_name, it.name), 'modifier_id', ci.modifier_id,
                 'expected_modifier', public._infusion_modifier(o.data -> 'infusion', c.class_level),
                 'outdated', ci.modifier_id is distinct from public._infusion_modifier(o.data -> 'infusion', c.class_level),
                 'known', ci.infusion_id = any (c.known), 'created_item', ci.created_item, 'companion_id', ci.companion_id,
                 'attunement', coalesce((o.data -> 'infusion' ->> 'attunement')::boolean, false), 'attuned', coalesce(ii.is_attuned, false))
               order by ci.applied_at)
               from public.character_infusions ci
               join public.class_feature_choice_options o on o.choice_id = ci.choice_id and o.option_id = ci.infusion_id
               left join public._character_infusion_choices(p_character) c on c.choice_id = ci.choice_id and c.character_class_id = ci.character_class_id
               left join public.inventory_items ii on ii.id = ci.inventory_item_id
               left join public.items it on it.id = ii.item_id
               where ci.character_id = p_character), '[]'));
end;
$$;

-- Infuse an item (or create the replicated item / the companion). Known infusion, within the infused item limit, item rules,
-- one infusion per item; the modifier variant follows the class level.
create function public.apply_infusion(p_character uuid, p_infusion text, p_inventory_item uuid default null, p_replicate_item text default null)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare c record; o public.class_feature_choice_options; inf jsonb; inv uuid; ii public.inventory_items; why text; mid text;
  new_item uuid; comp uuid; hp int; mods jsonb; d jsonb;
begin
  if auth.uid() is null or not public.can_access_character(p_character) then
    raise exception 'Character not found' using errcode = '42501';
  end if;
  perform 1 from public.characters where id = p_character for update;                -- one infusion change at a time
  select x.* into c from public._character_infusion_choices(p_character) x where p_infusion = any (x.known) limit 1;
  if c.choice_id is null then raise exception 'You do not know this infusion' using errcode = '22023'; end if;
  select * into o from public.class_feature_choice_options where choice_id = c.choice_id and option_id = p_infusion;
  inf := o.data -> 'infusion';
  if (select count(*) from public.character_infusions where character_id = p_character and choice_id = c.choice_id) >= c.max_items then
    raise exception 'You already have % infused items; end an infusion first', c.max_items using errcode = '22023';
  end if;
  select id into inv from public.inventories where character_id = p_character and kind = 'character';
  mid := public._infusion_modifier(inf, c.class_level);
  perform set_config('tavern.managed_modifier', '1', true);

  if inf -> 'item' ? 'none' then                                                       -- Replicate Magic Item
    if p_replicate_item is null or not exists (select 1 from jsonb_array_elements(inf -> 'replicate') e, jsonb_array_elements_text(e -> 1) x
                                               where (e ->> 0)::int <= c.class_level and x = p_replicate_item) then
      raise exception 'Choose a magic item you can replicate at your level' using errcode = '22023';
    end if;
    new_item := public.add_inventory_item(inv, p_replicate_item, 1, null, format('Infused: %s', o.label), '{}'::jsonb);
    insert into public.character_infusions (character_id, character_class_id, infusion_id, choice_id, inventory_item_id, created_item, applied_by)
    values (p_character, c.character_class_id, p_infusion, c.choice_id, new_item, true, auth.uid());
  elsif inf ? 'companion' then                                                          -- Homunculus Servant
    d := public.get_character_derived_stats(p_character);
    select jsonb_object_agg(k, (d -> 'abilities' -> k ->> 'modifier')::int) into mods from jsonb_object_keys(d -> 'abilities') k;
    hp := greatest(1, (public._resource_max(inf -> 'companion' -> 'hp', jsonb_build_object('class_level', c.class_level,
            'total_level', c.class_level, 'proficiency_bonus', (d -> 'proficiency_bonus' ->> 'value')::int, 'mods', mods)) ->> 'max')::int);
    comp := public.add_character_companion(p_character, null, inf -> 'companion' ->> 'name', o.label, hp);
    if p_inventory_item is not null then
      select * into ii from public.inventory_items where id = p_inventory_item and inventory_id = inv;
      if ii.id is null then raise exception 'That item is not in this character''s inventory' using errcode = '22023'; end if;
    end if;
    insert into public.character_infusions (character_id, character_class_id, infusion_id, choice_id, inventory_item_id, companion_id, applied_by)
    values (p_character, c.character_class_id, p_infusion, c.choice_id, ii.id, comp, auth.uid());
  else
    select * into ii from public.inventory_items where id = p_inventory_item and inventory_id = inv for update;
    if ii.id is null then raise exception 'Choose an item from this character''s inventory' using errcode = '22023'; end if;
    why := public._infusion_item_refusal(inf, ii);
    if why is not null then raise exception '%', why using errcode = '22023'; end if;
    if ii.quantity > 1 then raise exception 'Split the stack first: only one item can hold the infusion' using errcode = '22023'; end if;
    insert into public.inventory_item_modifiers (inventory_item_id, modifier_id) values (ii.id, mid);
    insert into public.character_infusions (character_id, character_class_id, infusion_id, choice_id, inventory_item_id, modifier_id, applied_by)
    values (p_character, c.character_class_id, p_infusion, c.choice_id, ii.id, mid, auth.uid());
  end if;
  perform set_config('tavern.managed_modifier', '', true);
  return public.get_character_infusions(p_character);
end;
$$;

-- End an infusion: its modifier goes (the item is unattuned if only the infusion needed attunement); a replicated item
-- vanishes; a created companion goes.
create function public.remove_infusion(p_character uuid, p_infusion_row uuid)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare r public.character_infusions;
begin
  if auth.uid() is null or not public.can_access_character(p_character) then
    raise exception 'Character not found' using errcode = '42501';
  end if;
  perform 1 from public.characters where id = p_character for update;
  select * into r from public.character_infusions where id = p_infusion_row and character_id = p_character;
  if not found then raise exception 'Infusion not found' using errcode = '22023'; end if;
  perform set_config('tavern.managed_modifier', '1', true);
  if r.modifier_id is not null then
    -- unattune first when only this infusion needed attunement (the item is re-checked when its modifier goes)
    update public.inventory_items ii set is_attuned = false
    where ii.id = r.inventory_item_id and ii.is_attuned
      and not coalesce((select requires_attunement from public.items where id = ii.item_id), false)
      and not exists (select 1 from public.inventory_item_modifiers im join public.item_modifiers md on md.id = im.modifier_id
                      where im.inventory_item_id = ii.id and md.requires_attunement_override and im.modifier_id <> r.modifier_id);
    delete from public.inventory_item_modifiers where inventory_item_id = r.inventory_item_id and modifier_id = r.modifier_id;
  end if;
  delete from public.character_infusions where id = r.id;
  if r.created_item then delete from public.inventory_items where id = r.inventory_item_id; end if;
  if r.companion_id is not null then delete from public.character_companions where id = r.companion_id; end if;
  perform set_config('tavern.managed_modifier', '', true);
  return public.get_character_infusions(p_character);
end;
$$;

-- After a level change: swap every active infusion modifier to the variant of the current level (+1 -> +2 at level 10).
create function public.refresh_infusions(p_character uuid)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare r record;
begin
  if auth.uid() is null or not public.can_access_character(p_character) then
    raise exception 'Character not found' using errcode = '42501';
  end if;
  perform 1 from public.characters where id = p_character for update;
  perform set_config('tavern.managed_modifier', '1', true);
  for r in select ci.id, ci.inventory_item_id, ci.modifier_id, public._infusion_modifier(o.data -> 'infusion', c.class_level) as want
           from public.character_infusions ci
           join public.class_feature_choice_options o on o.choice_id = ci.choice_id and o.option_id = ci.infusion_id
           join public._character_infusion_choices(p_character) c on c.choice_id = ci.choice_id and c.character_class_id = ci.character_class_id
           where ci.character_id = p_character and ci.modifier_id is not null loop
    if r.want is not null and r.want <> r.modifier_id then
      delete from public.inventory_item_modifiers where inventory_item_id = r.inventory_item_id and modifier_id = r.modifier_id;
      insert into public.inventory_item_modifiers (inventory_item_id, modifier_id) values (r.inventory_item_id, r.want);
      update public.character_infusions set modifier_id = r.want where id = r.id;
    end if;
  end loop;
  perform set_config('tavern.managed_modifier', '', true);
  return public.get_character_infusions(p_character);
end;
$$;

revoke all on function public._character_infusion_choices(uuid) from public, anon, authenticated;
revoke all on function public._infusion_modifier(jsonb, int) from public, anon;
revoke all on function public._infusion_item_refusal(jsonb, public.inventory_items) from public, anon, authenticated;
revoke all on function public.get_character_infusions(uuid) from public, anon;
revoke all on function public.apply_infusion(uuid, text, uuid, text) from public, anon;
revoke all on function public.remove_infusion(uuid, uuid) from public, anon;
revoke all on function public.refresh_infusions(uuid) from public, anon;
grant execute on function public.get_character_infusions(uuid) to authenticated;
grant execute on function public.apply_infusion(uuid, text, uuid, text) to authenticated;
grant execute on function public.remove_infusion(uuid, uuid) to authenticated;
grant execute on function public.refresh_infusions(uuid) to authenticated;
