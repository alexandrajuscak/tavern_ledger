-- =============================================================================
-- Inventories
--  * inventories            generic owner of items: character, party stash, NPC, shop, stash
--  * inventory_items        EXISTING table (base schema), extended additively; legacy columns stay
--  * legacy_inventory_review snapshot of legacy rows that need a decision (equipped flags, quantity 0)
--  * inventory_item_modifiers, inventory_events, owned_assets
--
-- Equipped state: character_equipment (next migration) is the ONLY source of truth. The legacy column
-- inventory_items.equipped becomes a read-only projection: every write recomputes it from
-- character_equipment, so a client value is ignored and the column can never disagree with the slots.
-- The projection disappears together with the column (docs/EQUIPMENT_TRANSITION.md).
--
-- Stack identity (deterministic): inventory_items.stack_key = md5 of inventory_id | container_item_id |
--   item_id | custom_name | notes | is_quest_item | state | durability | charges_current | charges_max |
--   charges_recharge | is_attuned | consumable_override | sorted applied modifier ids.
-- NULL (never auto-merged) for free-text rows, non-stackable items and equipped rows. Not a unique key:
-- identical stacks MAY be merged, deliberate splits produce identical rows.
--
-- Last piece used/removed => the row is hard-deleted; inventory_events keeps item_id, the quantity change
-- and the previous quantity (docs/CONSUMABLE_EFFECTS.md, "Hard delete").
-- =============================================================================

create table public.inventories (
  id           uuid primary key default gen_random_uuid(),
  kind         text not null check (kind in ('character', 'party_stash', 'npc', 'shop', 'stash')),
  name         text not null default 'Inventory',
  character_id uuid unique references public.characters (id) on delete cascade,
  campaign_id  uuid references public.campaigns (id) on delete cascade,
  owner_id     uuid references public.profiles (id) on delete cascade,   -- personal 'stash'
  created_at   timestamptz not null default now(),
  constraint inventories_owner_shape check (case kind
    when 'character'   then character_id is not null and campaign_id is null and owner_id is null
    when 'party_stash' then character_id is null and campaign_id is not null
    when 'npc'         then character_id is null and campaign_id is not null
    when 'shop'        then character_id is null and campaign_id is not null
    when 'stash'       then character_id is null and (campaign_id is not null or owner_id is not null)
  end)
);
create unique index inventories_party_stash_uniq on public.inventories (campaign_id) where kind = 'party_stash';

create function public.create_character_inventory()
returns trigger
language plpgsql security definer
set search_path = public, pg_temp
as $$
begin
  insert into public.inventories (kind, name, character_id) values ('character', new.name, new.id)
  on conflict (character_id) do nothing;
  return new;
end;
$$;
revoke all on function public.create_character_inventory() from public, anon, authenticated;

create trigger characters_inventory after insert on public.characters
  for each row execute function public.create_character_inventory();

insert into public.inventories (kind, name, character_id)
select 'character', c.name, c.id from public.characters c;

-- ---- inventory_items: additive columns ----------------------------------------------------------
alter table public.inventory_items
  add column inventory_id        uuid references public.inventories (id) on delete cascade,
  add column item_id             text references public.items (id) on delete restrict,
  add column container_item_id   uuid references public.inventory_items (id) on delete set null,
  add column custom_name         text,
  add column notes               text,
  add column is_quest_item       boolean not null default false,
  add column is_attuned          boolean not null default false,
  add column attuned_at          timestamptz,
  add column charges_current     int,
  add column charges_max         int,
  add column charges_recharge    text,
  add column durability          int,
  add column state               jsonb not null default '{}'::jsonb,   -- spell/level of a scroll, loaded rounds, jam ...
  add column consumable_override boolean,                              -- null = catalog, false = never consumed, true = always
  add column acquired_at         timestamptz not null default now(),
  add column stack_key           text;

update public.inventory_items ii
set inventory_id = i.id
from public.inventories i
where i.character_id = ii.character_id;

alter table public.inventory_items alter column inventory_id set not null;
alter table public.inventory_items alter column character_id drop not null;   -- stash / shop rows have no character

alter table public.inventory_items
  add constraint inventory_items_linked_qty         check (item_id is null or quantity >= 1),
  add constraint inventory_items_charges_current    check (charges_current is null or charges_current >= 0),
  add constraint inventory_items_charges_max        check (charges_max is null or charges_max >= 0),
  add constraint inventory_items_charges_order      check (charges_current is null or charges_max is null or charges_current <= charges_max),
  add constraint inventory_items_durability         check (durability is null or durability >= 0),
  add constraint inventory_items_container_not_self check (container_item_id is distinct from id),
  add constraint inventory_items_attuned_single     check (not is_attuned or quantity = 1);

-- ---- legacy review: snapshot taken NOW, before any trigger can touch the legacy values --------------
create table public.legacy_inventory_review (
  id                bigint generated always as identity primary key,
  inventory_item_id uuid references public.inventory_items (id) on delete cascade,
  character_id      uuid references public.characters (id) on delete cascade,
  legacy_name       text,
  legacy_quantity   int,
  legacy_equipped   boolean,
  category          text not null check (category in (
                      'equipped_pending', 'equipped_migrated', 'equipped_manual',
                      'qty0_empty_placeholder', 'qty0_corrupted', 'qty0_convertible', 'qty0_manual', 'linked_by_name')),
  status            text not null default 'pending' check (status in ('pending', 'done', 'manual_review', 'resolved')),
  detail            jsonb not null default '{}'::jsonb,
  created_at        timestamptz not null default now(),
  resolved_at       timestamptz
);

insert into public.legacy_inventory_review (inventory_item_id, character_id, legacy_name, legacy_quantity, legacy_equipped, category)
select id, character_id, name, quantity, equipped, 'equipped_pending'
from public.inventory_items where equipped;

insert into public.legacy_inventory_review (inventory_item_id, character_id, legacy_name, legacy_quantity, legacy_equipped, category, status)
select id, character_id, name, quantity, equipped,
       case when btrim(coalesce(name, '')) = '' then 'qty0_corrupted'                                   -- nothing identifies the row
            when equipped then 'qty0_convertible'                                                       -- in use, so at least one exists
            when name = 'New item' and coalesce(description, '') = '' and weight = 0 then 'qty0_empty_placeholder'  -- untouched "+ Add item" row
            else 'qty0_manual' end,
       'manual_review'
from public.inventory_items where quantity = 0;

-- ---- applied modifiers -------------------------------------------------------------------------
create table public.inventory_item_modifiers (
  inventory_item_id uuid not null references public.inventory_items (id) on delete cascade,
  modifier_id       text not null references public.item_modifiers (id),
  applied_by        uuid default auth.uid(),
  applied_at        timestamptz not null default now(),
  primary key (inventory_item_id, modifier_id)
);

-- ---- events ------------------------------------------------------------------------------------
create table public.inventory_events (
  id                uuid primary key default gen_random_uuid(),
  inventory_id      uuid not null references public.inventories (id) on delete cascade,
  inventory_item_id uuid references public.inventory_items (id) on delete set null,
  actor_id          uuid,
  action            text not null check (action in ('add', 'remove', 'use', 'transfer', 'split', 'merge', 'equip', 'unequip',
                                                    'attune', 'unattune', 'rename', 'apply_modifier', 'remove_modifier')),
  quantity_delta    int,
  item_id           text references public.items (id) on delete set null,
  metadata          jsonb not null default '{}'::jsonb,
  created_at        timestamptz not null default now()
);

-- Only SECURITY DEFINER code writes events (clients have no INSERT grant).
create function public.log_inventory_event(
  p_inventory uuid, p_inventory_item uuid, p_action text, p_delta int, p_item text, p_meta jsonb default '{}'::jsonb)
returns void
language sql security definer
set search_path = public, pg_temp
as $$
  insert into public.inventory_events (inventory_id, inventory_item_id, actor_id, action, quantity_delta, item_id, metadata)
  values (p_inventory, p_inventory_item, auth.uid(), p_action, p_delta, p_item, coalesce(p_meta, '{}'::jsonb));
$$;
revoke all on function public.log_inventory_event(uuid, uuid, text, int, text, jsonb) from public, anon, authenticated;

-- ---- stack identity ------------------------------------------------------------------------------
create function public.compute_stack_key(r public.inventory_items)
returns text
language plpgsql stable
set search_path = public, pg_temp
as $$
declare stk boolean; mods text;
begin
  if r.item_id is null then return null; end if;
  select stackable into stk from public.items where id = r.item_id;
  if not coalesce(stk, false) then return null; end if;
  if exists (select 1 from public.character_equipment e where e.inventory_item_id = r.id) then return null; end if;
  select coalesce(string_agg(modifier_id, ',' order by modifier_id), '') into mods
  from public.inventory_item_modifiers where inventory_item_id = r.id;
  return md5(concat_ws('|', r.inventory_id::text, coalesce(r.container_item_id::text, ''), r.item_id,
                       coalesce(r.custom_name, ''), coalesce(r.notes, ''), r.is_quest_item::text, r.state::text,
                       coalesce(r.durability::text, ''), coalesce(r.charges_current::text, ''), coalesce(r.charges_max::text, ''),
                       coalesce(r.charges_recharge, ''), r.is_attuned::text, coalesce(r.consumable_override::text, ''), mods));
end;
$$;

-- ---- row invariants (every write path, including direct client writes) -----------------------------
create function public.inventory_items_before_write()
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

create trigger inventory_items_before_write before insert or update on public.inventory_items
  for each row execute function public.inventory_items_before_write();

-- event trail for direct (non-RPC) writes; RPCs set tavern.rpc = '1' and log their own events
create function public.inventory_items_after_write()
returns trigger
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare via_rpc boolean := coalesce(current_setting('tavern.rpc', true), '') = '1';
begin
  if tg_op = 'INSERT' then
    if new.item_id is not null and not via_rpc then
      perform public.log_inventory_event(new.inventory_id, new.id, 'add', new.quantity, new.item_id,
                                         jsonb_build_object('via', 'direct', 'previous_quantity', 0));
    end if;
  elsif tg_op = 'UPDATE' then
    if new.custom_name is distinct from old.custom_name then
      perform public.log_inventory_event(new.inventory_id, new.id, 'rename', null, new.item_id,
                                         jsonb_build_object('from', old.custom_name, 'to', new.custom_name));
    end if;
    if new.is_attuned is distinct from old.is_attuned then
      perform public.log_inventory_event(new.inventory_id, new.id, case when new.is_attuned then 'attune' else 'unattune' end,
                                         null, new.item_id, '{}');
    end if;
    if new.item_id is not null and new.quantity <> old.quantity and not via_rpc then
      perform public.log_inventory_event(new.inventory_id, new.id, case when new.quantity > old.quantity then 'add' else 'remove' end,
                                         new.quantity - old.quantity, new.item_id,
                                         jsonb_build_object('via', 'direct', 'previous_quantity', old.quantity));
    end if;
  elsif tg_op = 'DELETE' then
    if old.item_id is not null and not via_rpc and exists (select 1 from public.inventories where id = old.inventory_id) then
      perform public.log_inventory_event(old.inventory_id, null, 'remove', -old.quantity, old.item_id,
                                         jsonb_build_object('via', 'direct', 'previous_quantity', old.quantity, 'name', old.name));
    end if;
  end if;
  return null;
end;
$$;
revoke all on function public.inventory_items_after_write() from public, anon, authenticated;

create trigger inventory_items_after_write after insert or update or delete on public.inventory_items
  for each row execute function public.inventory_items_after_write();

-- ---- modifier rules ----------------------------------------------------------------------------
create function public.inventory_item_modifiers_before_write()
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

create trigger inventory_item_modifiers_before_write before insert on public.inventory_item_modifiers
  for each row execute function public.inventory_item_modifiers_before_write();

create function public.inventory_item_modifiers_after_write()
returns trigger
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare iid uuid := coalesce(new.inventory_item_id, old.inventory_item_id); mid text := coalesce(new.modifier_id, old.modifier_id);
        r public.inventory_items;
begin
  select * into r from public.inventory_items where id = iid;
  if r.id is not null then
    update public.inventory_items set stack_key = public.compute_stack_key(r) where id = iid;
    if coalesce(current_setting('tavern.rpc', true), '') <> '1' then      -- copies made by a split are not new modifiers
      perform public.log_inventory_event(r.inventory_id, r.id, case tg_op when 'INSERT' then 'apply_modifier' else 'remove_modifier' end,
                                         null, r.item_id, jsonb_build_object('modifier_id', mid));
    end if;
  end if;
  return null;
end;
$$;
revoke all on function public.inventory_item_modifiers_after_write() from public, anon, authenticated;

create trigger inventory_item_modifiers_after_write after insert or delete on public.inventory_item_modifiers
  for each row execute function public.inventory_item_modifiers_after_write();

-- ---- owned mounts and vehicles (neutral name: a wagon is not a companion) ---------------------------
create table public.owned_assets (
  id                 uuid primary key default gen_random_uuid(),
  item_id            text not null references public.items (id) on delete restrict,
  character_id       uuid references public.characters (id) on delete cascade,
  campaign_id        uuid references public.campaigns (id) on delete cascade,
  custom_name        text,
  notes              text,
  current_hp         int check (current_hp is null or current_hp >= 0),
  cargo_inventory_id uuid unique references public.inventories (id) on delete set null,
  acquired_at        timestamptz not null default now(),
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  constraint owned_assets_one_owner check (num_nonnulls(character_id, campaign_id) = 1)
);

create function public.owned_assets_before_write()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  if not exists (select 1 from public.items where id = new.item_id and kind_id in ('mount', 'vehicle')) then
    raise exception 'owned_assets accept only mounts and vehicles';
  end if;
  new.updated_at := now();
  return new;
end;
$$;

create trigger owned_assets_before_write before insert or update on public.owned_assets
  for each row execute function public.owned_assets_before_write();

-- Realtime (only where the publication exists, i.e. on Supabase)
do $$
declare t text;
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    foreach t in array array['inventories', 'inventory_item_modifiers', 'owned_assets'] loop
      execute format('alter publication supabase_realtime add table public.%I', t);
    end loop;
  end if;
end $$;
