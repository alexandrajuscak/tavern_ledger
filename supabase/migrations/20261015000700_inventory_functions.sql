-- =============================================================================
-- Permission helpers and transactional inventory RPCs
--
-- Every RPC is SECURITY DEFINER (it must write inventory_events, which clients cannot) and checks
-- authorization itself. Each call runs in one transaction; rows are locked FOR UPDATE, so two
-- concurrent calls (double use of a scroll, two equips of the same stack) are serialized and the
-- second one sees the result of the first.
--
-- Events: equip/unequip, attune/unattune, rename and modifier changes are logged by triggers (005, 006)
-- so direct writes are audited too. The RPCs set tavern.rpc = '1' to suppress the generic add/remove
-- trigger events and log add/remove/use/transfer/split/merge themselves.
-- =============================================================================

-- ---- permission helpers ------------------------------------------------------------------------------
-- Row-based helpers. Policies on items / item_modifiers / inventories evaluate the row's OWN columns with these,
-- never a lookup by id: during INSERT ... RETURNING (PostgREST return=representation) the new row is not yet
-- visible to a lookup, which would wrongly reject the insert.

-- official (owner_id null) is public; homebrew is visible to its author, admins and the campaign's members
create function public.can_view_owned(p_owner uuid, p_campaign uuid)
returns boolean
language sql stable security definer
set search_path = public, pg_temp
as $$
  select p_owner is null
      or (auth.uid() is not null
          and (p_owner = auth.uid() or public.is_admin()
               or (p_campaign is not null and public.is_campaign_member(p_campaign))));
$$;

-- homebrew is editable by its author, admins and the campaign's DMs; official rows by nobody (client side)
create function public.can_edit_owned(p_owner uuid, p_campaign uuid)
returns boolean
language sql stable security definer
set search_path = public, pg_temp
as $$
  select p_owner is not null and auth.uid() is not null
     and (p_owner = auth.uid() or public.is_admin()
          or (p_campaign is not null and public.is_campaign_dm(p_campaign)));
$$;

-- read: character inventories follow the character; stash/shop are visible to campaign members; NPC inventories to DMs
create function public.can_read_inventory_row(p_kind text, p_character uuid, p_campaign uuid, p_owner uuid)
returns boolean
language sql stable security definer
set search_path = public, pg_temp
as $$
  select public.is_admin()
      or (p_kind = 'character' and public.can_access_character(p_character))
      or (p_kind in ('party_stash', 'shop') and public.is_campaign_member(p_campaign))
      or (p_kind = 'npc' and public.is_campaign_dm(p_campaign))
      or (p_kind = 'stash' and (p_owner = auth.uid() or (p_campaign is not null and public.is_campaign_dm(p_campaign))));
$$;

-- write: owner / DM / admin of a character; DMs (and admins) for everything campaign-scoped; owner of a personal stash
create function public.can_write_inventory_row(p_kind text, p_character uuid, p_campaign uuid, p_owner uuid)
returns boolean
language sql stable security definer
set search_path = public, pg_temp
as $$
  select public.is_admin()
      or (p_kind = 'character' and public.can_access_character(p_character))
      or (p_kind in ('party_stash', 'shop', 'npc') and public.is_campaign_dm(p_campaign))
      or (p_kind = 'stash' and (p_owner = auth.uid() or (p_campaign is not null and public.is_campaign_dm(p_campaign))));
$$;

-- Id-based wrappers for child tables (the parent row already exists there).
create function public.can_view_item(p_item text)
returns boolean
language sql stable security definer
set search_path = public, pg_temp
as $$ select exists (select 1 from public.items i where i.id = p_item and public.can_view_owned(i.owner_id, i.campaign_id)); $$;

create function public.can_edit_item(p_item text)
returns boolean
language sql stable security definer
set search_path = public, pg_temp
as $$ select exists (select 1 from public.items i where i.id = p_item and public.can_edit_owned(i.owner_id, i.campaign_id)); $$;

create function public.can_view_modifier(p_mod text)
returns boolean
language sql stable security definer
set search_path = public, pg_temp
as $$ select exists (select 1 from public.item_modifiers m where m.id = p_mod and public.can_view_owned(m.owner_id, m.campaign_id)); $$;

create function public.can_edit_modifier(p_mod text)
returns boolean
language sql stable security definer
set search_path = public, pg_temp
as $$ select exists (select 1 from public.item_modifiers m where m.id = p_mod and public.can_edit_owned(m.owner_id, m.campaign_id)); $$;

create function public.can_read_inventory(p_inv uuid)
returns boolean
language sql stable security definer
set search_path = public, pg_temp
as $$ select exists (select 1 from public.inventories i where i.id = p_inv
                     and public.can_read_inventory_row(i.kind, i.character_id, i.campaign_id, i.owner_id)); $$;

create function public.can_write_inventory(p_inv uuid)
returns boolean
language sql stable security definer
set search_path = public, pg_temp
as $$ select exists (select 1 from public.inventories i where i.id = p_inv
                     and public.can_write_inventory_row(i.kind, i.character_id, i.campaign_id, i.owner_id)); $$;

-- deposit: write access, or any campaign member into the party stash (players may contribute, only DMs withdraw)
create function public.can_deposit_inventory(p_inv uuid)
returns boolean
language sql stable security definer
set search_path = public, pg_temp
as $$
  select public.can_write_inventory(p_inv)
      or exists (select 1 from public.inventories i
                 where i.id = p_inv and i.kind = 'party_stash' and public.is_campaign_member(i.campaign_id));
$$;

-- used by the inventory_item_modifiers policies; SECURITY INVOKER on purpose: it only sees rows the caller may see
create function public.inventory_of_item(p_item uuid)
returns uuid
language sql stable
set search_path = public, pg_temp
as $$ select inventory_id from public.inventory_items where id = p_item; $$;

-- ---- internals (not granted to clients) -------------------------------------------------------------------
create function public._rpc_begin()
returns void
language sql
set search_path = public, pg_temp
as $$ select set_config('tavern.rpc', '1', true); $$;

create function public._rpc_end()
returns void
language sql
set search_path = public, pg_temp
as $$ select set_config('tavern.rpc', '', true); $$;

create function public._lock_item(p_id uuid)
returns public.inventory_items
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare r public.inventory_items;
begin
  select * into r from public.inventory_items where id = p_id for update;
  if r.id is null then raise exception 'Inventory item not found' using errcode = 'P0002'; end if;
  return r;
end;
$$;

-- split `p_qty` pieces off a stack into a new row (copies state and modifiers); returns the new row id
create function public._split_off(p_id uuid, p_qty int)
returns uuid
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare r public.inventory_items; new_id uuid;
begin
  select * into r from public.inventory_items where id = p_id for update;
  if p_qty < 1 or p_qty >= r.quantity then raise exception 'Cannot split % of %', p_qty, r.quantity; end if;
  if exists (select 1 from public.character_equipment where inventory_item_id = p_id) then
    raise exception 'An equipped item cannot be split';
  end if;
  update public.inventory_items set quantity = quantity - p_qty where id = p_id;
  insert into public.inventory_items
    (inventory_id, item_id, quantity, name, weight, description, sort_order, container_item_id, custom_name, notes,
     is_quest_item, charges_current, charges_max, charges_recharge, durability, state, consumable_override, acquired_at)
  values
    (r.inventory_id, r.item_id, p_qty, r.name, r.weight, r.description, r.sort_order, r.container_item_id, r.custom_name, r.notes,
     r.is_quest_item, r.charges_current, r.charges_max, r.charges_recharge, r.durability, r.state, r.consumable_override, r.acquired_at)
  returning id into new_id;
  insert into public.inventory_item_modifiers (inventory_item_id, modifier_id)
  select new_id, modifier_id from public.inventory_item_modifiers where inventory_item_id = p_id;
  return new_id;
end;
$$;

-- merge a row into an identical stack of the same inventory, if one exists and stack_max allows it
create function public._try_auto_merge(p_id uuid)
returns uuid
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare r public.inventory_items; o public.inventory_items; smax int;
begin
  select * into r from public.inventory_items where id = p_id for update;
  if r.id is null or r.stack_key is null then return p_id; end if;
  select x.* into o from public.inventory_items x
  where x.stack_key = r.stack_key and x.id <> r.id and x.inventory_id = r.inventory_id
  order by x.quantity desc, x.id limit 1 for update;
  if o.id is null then return p_id; end if;
  select stack_max into smax from public.items where id = r.item_id;
  if smax is not null and o.quantity + r.quantity > smax then return p_id; end if;
  update public.inventory_items set quantity = o.quantity + r.quantity where id = o.id;
  delete from public.inventory_items where id = r.id;
  perform public.log_inventory_event(o.inventory_id, o.id, 'merge', r.quantity, o.item_id,
                                     jsonb_build_object('merged_from', r.id, 'auto', true));
  return o.id;
end;
$$;

revoke all on function public._rpc_begin(), public._rpc_end(), public._lock_item(uuid), public._split_off(uuid, int), public._try_auto_merge(uuid)
  from public, anon, authenticated;

-- ---- RPCs -----------------------------------------------------------------------------------------------

-- add_inventory_item: adds `p_quantity` pieces of a catalog item (merging into an identical stack when stackable)
create function public.add_inventory_item(
  p_inventory uuid, p_item text, p_quantity int default 1,
  p_custom_name text default null, p_notes text default null, p_state jsonb default '{}'::jsonb)
returns uuid
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare it public.items; remaining int := p_quantity; chunk int; rid uuid; last_id uuid;
begin
  perform public._rpc_begin();
  if auth.uid() is null then raise exception 'Not authenticated' using errcode = '42501'; end if;
  if p_quantity is null or p_quantity < 1 then raise exception 'Quantity must be at least 1'; end if;
  if not public.can_deposit_inventory(p_inventory) then raise exception 'Not allowed to add items to this inventory' using errcode = '42501'; end if;
  if not public.can_view_item(p_item) then raise exception 'Unknown item' using errcode = 'P0002'; end if;
  select * into it from public.items where id = p_item;

  while remaining > 0 loop
    chunk := case when it.stackable then least(remaining, coalesce(it.stack_max, remaining)) else 1 end;
    insert into public.inventory_items (inventory_id, item_id, quantity, custom_name, notes, state)
    values (p_inventory, p_item, chunk, p_custom_name, p_notes, coalesce(p_state, '{}'::jsonb))
    returning id into rid;
    last_id := public._try_auto_merge(rid);
    remaining := remaining - chunk;
  end loop;
  perform public.log_inventory_event(p_inventory, last_id, 'add', p_quantity, p_item, '{"via":"rpc"}');
  perform public._rpc_end(); return last_id;
end;
$$;

create function public.remove_inventory_item(p_item uuid, p_quantity int default null)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare r public.inventory_items; q int;
begin
  perform public._rpc_begin();
  r := public._lock_item(p_item);
  if not public.can_write_inventory(r.inventory_id) then raise exception 'Not allowed' using errcode = '42501'; end if;
  q := coalesce(p_quantity, r.quantity);
  if q < 1 or q > r.quantity then raise exception 'Invalid quantity % (have %)', q, r.quantity; end if;
  if q = r.quantity then
    delete from public.inventory_items where id = r.id;
  else
    update public.inventory_items set quantity = quantity - q where id = r.id;
  end if;
  perform public.log_inventory_event(r.inventory_id, case when q = r.quantity then null else r.id end, 'remove', -q, r.item_id,
                                     jsonb_build_object('previous_quantity', r.quantity, 'deleted', q = r.quantity, 'name', coalesce(r.custom_name, r.name)));
  perform public._rpc_end(); return jsonb_build_object('removed', q, 'remaining', r.quantity - q, 'deleted', q = r.quantity);
end;
$$;

create function public.split_inventory_stack(p_item uuid, p_quantity int default 1)
returns uuid
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare r public.inventory_items; nid uuid;
begin
  perform public._rpc_begin();
  r := public._lock_item(p_item);
  if not public.can_write_inventory(r.inventory_id) then raise exception 'Not allowed' using errcode = '42501'; end if;
  nid := public._split_off(p_item, p_quantity);
  perform public.log_inventory_event(r.inventory_id, nid, 'split', 0, r.item_id,
                                     jsonb_build_object('from', r.id, 'quantity', p_quantity));
  perform public._rpc_end(); return nid;
end;
$$;

-- merge `p_source` into `p_target`; only rows with the same stack identity (same stack_key) can be merged
create function public.merge_inventory_stacks(p_target uuid, p_source uuid)
returns uuid
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare a public.inventory_items; b public.inventory_items; smax int;
begin
  perform public._rpc_begin();
  if p_target = p_source then raise exception 'Cannot merge a stack with itself'; end if;
  -- lock in id order to avoid deadlocks
  if p_target < p_source then a := public._lock_item(p_target); b := public._lock_item(p_source);
  else b := public._lock_item(p_source); a := public._lock_item(p_target); end if;
  if not public.can_write_inventory(a.inventory_id) or not public.can_write_inventory(b.inventory_id) then
    raise exception 'Not allowed' using errcode = '42501';
  end if;
  if a.inventory_id <> b.inventory_id then raise exception 'Stacks are in different inventories'; end if;
  if a.stack_key is null or a.stack_key is distinct from b.stack_key then
    raise exception 'These items are not identical and cannot be merged';
  end if;
  select stack_max into smax from public.items where id = a.item_id;
  if smax is not null and a.quantity + b.quantity > smax then raise exception 'Stack limit (%) exceeded', smax; end if;
  update public.inventory_items set quantity = a.quantity + b.quantity where id = a.id;
  delete from public.inventory_items where id = b.id;
  perform public.log_inventory_event(a.inventory_id, a.id, 'merge', b.quantity, a.item_id, jsonb_build_object('merged_from', b.id));
  perform public._rpc_end(); return a.id;
end;
$$;

-- equip_item: equips ONE piece. A stack with quantity > 1 is split first, so Javelin x5 becomes
-- Javelin x4 plus Javelin x1 (equipped). Returns the id of the equipped row.
create function public.equip_item(p_item uuid, p_slot text, p_replace boolean default false)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare r public.inventory_items; inv public.inventories; target uuid; occ uuid; split_from uuid;
begin
  perform public._rpc_begin();
  r := public._lock_item(p_item);
  select * into inv from public.inventories where id = r.inventory_id;
  if inv.kind <> 'character' then raise exception 'Only character inventories have equipment'; end if;
  if not public.can_write_inventory(r.inventory_id) then raise exception 'Not allowed' using errcode = '42501'; end if;
  if r.item_id is null then raise exception 'Only catalog items can be equipped'; end if;
  perform pg_advisory_xact_lock(hashtext(inv.character_id::text));

  select inventory_item_id into occ from public.character_equipment where character_id = inv.character_id and slot_id = p_slot;
  if occ is not null and occ <> p_item then
    if not p_replace then raise exception 'Slot % is already occupied', p_slot; end if;
    delete from public.character_equipment where character_id = inv.character_id and slot_id = p_slot;
    perform public._try_auto_merge(occ);
  end if;
  -- moving an already equipped single piece to another slot
  delete from public.character_equipment where inventory_item_id = p_item;

  if r.quantity > 1 then
    target := public._split_off(p_item, 1);
    split_from := p_item;
    perform public.log_inventory_event(r.inventory_id, target, 'split', 0, r.item_id,
                                       jsonb_build_object('from', p_item, 'quantity', 1, 'reason', 'equip'));
  else
    target := p_item;
  end if;
  insert into public.character_equipment (character_id, slot_id, inventory_item_id) values (inv.character_id, p_slot, target);
  perform public._rpc_end(); return jsonb_build_object('inventory_item_id', target, 'split_from', split_from, 'slot', p_slot);
end;
$$;

create function public.unequip_item(p_item uuid)
returns uuid
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare r public.inventory_items; res uuid;
begin
  perform public._rpc_begin();
  r := public._lock_item(p_item);
  if not public.can_write_inventory(r.inventory_id) then raise exception 'Not allowed' using errcode = '42501'; end if;
  if not exists (select 1 from public.character_equipment where inventory_item_id = p_item) then
    raise exception 'The item is not equipped';
  end if;
  delete from public.character_equipment where inventory_item_id = p_item;
  res := public._try_auto_merge(p_item);        -- the single piece rejoins an identical stack if there is one
  perform public._rpc_end(); return res;
end;
$$;

-- attune_item: attunement is independent of equipping. A stack is split first; the attuned piece is single.
create function public.attune_item(p_item uuid)
returns uuid
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare r public.inventory_items; target uuid;
begin
  perform public._rpc_begin();
  r := public._lock_item(p_item);
  if not public.can_write_inventory(r.inventory_id) then raise exception 'Not allowed' using errcode = '42501'; end if;
  if r.item_id is null then raise exception 'Only catalog items can be attuned'; end if;
  if r.is_attuned then perform public._rpc_end(); return p_item; end if;
  if r.quantity > 1 then
    target := public._split_off(p_item, 1);
    perform public.log_inventory_event(r.inventory_id, target, 'split', 0, r.item_id,
                                       jsonb_build_object('from', p_item, 'quantity', 1, 'reason', 'attune'));
  else
    target := p_item;
  end if;
  update public.inventory_items set is_attuned = true where id = target;   -- trigger enforces the limit and logs 'attune'
  perform public._rpc_end(); return target;
end;
$$;

create function public.unattune_item(p_item uuid)
returns uuid
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare r public.inventory_items; res uuid;
begin
  perform public._rpc_begin();
  r := public._lock_item(p_item);
  if not public.can_write_inventory(r.inventory_id) then raise exception 'Not allowed' using errcode = '42501'; end if;
  if not r.is_attuned then perform public._rpc_end(); return p_item; end if;
  update public.inventory_items set is_attuned = false where id = p_item;   -- trigger logs 'unattune'
  res := public._try_auto_merge(p_item);
  perform public._rpc_end(); return res;
end;
$$;

-- use_inventory_item: consumes ONE piece by default (scroll, potion, ammunition ...).
--  * locks the row FOR UPDATE, so a concurrent second use waits and then sees the first one's result
--  * the quantity never goes below zero; the last piece deletes the row (hard delete, history in inventory_events)
--  * a non-consumable item (or consumable_override = false) is not consumed; the use is still logged
--  * it NEVER changes character HP: it returns the structured effects (dice, flat value ...) and the UI decides
-- Returns {item_id, kind_id, name, consumed, quantity_used, previous_quantity, remaining, deleted, state, effects}.
create function public.use_inventory_item(p_item uuid, p_quantity int default 1)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare r public.inventory_items; it public.items; consumable boolean; remaining int; gone boolean := false; fx jsonb; res jsonb;
begin
  perform public._rpc_begin();
  if p_quantity is null or p_quantity < 1 then raise exception 'Quantity must be at least 1'; end if;
  r := public._lock_item(p_item);
  if not public.can_write_inventory(r.inventory_id) then raise exception 'Not allowed' using errcode = '42501'; end if;
  if r.item_id is null then raise exception 'Only catalog items can be used'; end if;
  if r.quantity < 1 then raise exception 'Nothing left to use' using errcode = '22003'; end if;
  select * into it from public.items where id = r.item_id;
  consumable := coalesce(r.consumable_override, it.is_consumable);
  select coalesce(jsonb_agg(jsonb_build_object(
           'effect_type', e.effect_type, 'dice_expression', e.dice_expression, 'flat_value', e.flat_value,
           'damage_type_id', e.damage_type_id, 'duration', e.duration, 'target_type', e.target_type, 'effect_data', e.effect_data)
           order by e.seq), '[]'::jsonb) into fx
  from public.consumable_effects e where e.item_id = r.item_id;

  if not consumable then
    perform public.log_inventory_event(r.inventory_id, r.id, 'use', 0, r.item_id,
                                       jsonb_build_object('consumed', false, 'previous_quantity', r.quantity));
    res := jsonb_build_object('item_id', r.item_id, 'kind_id', it.kind_id, 'name', coalesce(r.custom_name, r.name), 'consumed', false,
                              'quantity_used', 0, 'previous_quantity', r.quantity, 'remaining', r.quantity, 'deleted', false,
                              'state', r.state, 'effects', fx);
    perform public._rpc_end(); return res;
  end if;
  if r.quantity < p_quantity then raise exception 'Not enough items (have %, need %)', r.quantity, p_quantity using errcode = '22003'; end if;
  remaining := r.quantity - p_quantity;
  if remaining = 0 then
    delete from public.inventory_items where id = r.id;
    gone := true;
  else
    update public.inventory_items set quantity = remaining where id = r.id;
  end if;
  perform public.log_inventory_event(r.inventory_id, case when gone then null else r.id end, 'use', -p_quantity, r.item_id,
    jsonb_build_object('consumed', true, 'previous_quantity', r.quantity, 'remaining', remaining, 'deleted', gone,
                       'name', coalesce(r.custom_name, r.name), 'state', r.state));
  res := jsonb_build_object('item_id', r.item_id, 'kind_id', it.kind_id, 'name', coalesce(r.custom_name, r.name), 'consumed', true,
                            'quantity_used', p_quantity, 'previous_quantity', r.quantity, 'remaining', remaining, 'deleted', gone,
                            'state', r.state, 'effects', fx);
  perform public._rpc_end(); return res;
end;
$$;

-- transfer_inventory_item: move (part of) a stack to another inventory. Equipped items must be unequipped first.
create function public.transfer_inventory_item(p_item uuid, p_to_inventory uuid, p_quantity int default null)
returns uuid
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare r public.inventory_items; q int; moving uuid; from_inv uuid; res uuid;
begin
  perform public._rpc_begin();
  r := public._lock_item(p_item);
  from_inv := r.inventory_id;
  if from_inv = p_to_inventory then raise exception 'Source and target inventory are the same'; end if;
  if not public.can_write_inventory(from_inv) then raise exception 'Not allowed to take items from this inventory' using errcode = '42501'; end if;
  if not public.can_deposit_inventory(p_to_inventory) then raise exception 'Not allowed to add items to the target inventory' using errcode = '42501'; end if;
  if exists (select 1 from public.character_equipment where inventory_item_id = p_item) then
    raise exception 'Unequip the item before transferring it';
  end if;
  if exists (select 1 from public.inventory_items where container_item_id = p_item) then
    raise exception 'The container is not empty';
  end if;
  q := coalesce(p_quantity, r.quantity);
  if q < 1 or q > r.quantity then raise exception 'Invalid quantity % (have %)', q, r.quantity; end if;
  if q < r.quantity then moving := public._split_off(p_item, q); else moving := p_item; end if;

  update public.inventory_items
  set inventory_id = p_to_inventory, container_item_id = null, is_attuned = false, sort_order = 0
  where id = moving;
  perform public.log_inventory_event(from_inv, null, 'transfer', -q, r.item_id, jsonb_build_object('to', p_to_inventory));
  perform public.log_inventory_event(p_to_inventory, moving, 'transfer', q, r.item_id, jsonb_build_object('from', from_inv));
  res := public._try_auto_merge(moving);
  perform public._rpc_end(); return res;
end;
$$;

-- ---- privileges --------------------------------------------------------------------------------------------
revoke all on function
  public.add_inventory_item(uuid, text, int, text, text, jsonb), public.remove_inventory_item(uuid, int),
  public.split_inventory_stack(uuid, int), public.merge_inventory_stacks(uuid, uuid),
  public.equip_item(uuid, text, boolean), public.unequip_item(uuid), public.attune_item(uuid), public.unattune_item(uuid),
  public.use_inventory_item(uuid, int), public.transfer_inventory_item(uuid, uuid, int)
  from public, anon;
grant execute on function
  public.add_inventory_item(uuid, text, int, text, text, jsonb), public.remove_inventory_item(uuid, int),
  public.split_inventory_stack(uuid, int), public.merge_inventory_stacks(uuid, uuid),
  public.equip_item(uuid, text, boolean), public.unequip_item(uuid), public.attune_item(uuid), public.unattune_item(uuid),
  public.use_inventory_item(uuid, int), public.transfer_inventory_item(uuid, uuid, int)
  to authenticated;

revoke all on function public.can_read_inventory(uuid), public.can_write_inventory(uuid), public.can_deposit_inventory(uuid),
  public.can_read_inventory_row(text, uuid, uuid, uuid), public.can_write_inventory_row(text, uuid, uuid, uuid),
  public.can_edit_item(text), public.can_edit_modifier(text), public.can_edit_owned(uuid, uuid) from public, anon;
grant execute on function public.can_read_inventory(uuid), public.can_write_inventory(uuid), public.can_deposit_inventory(uuid),
  public.can_read_inventory_row(text, uuid, uuid, uuid), public.can_write_inventory_row(text, uuid, uuid, uuid),
  public.can_edit_item(text), public.can_edit_modifier(text), public.can_edit_owned(uuid, uuid) to authenticated;
-- visibility helpers are also needed by anon policies (official catalog only)
revoke all on function public.can_view_item(text), public.can_view_modifier(text), public.can_view_owned(uuid, uuid) from public;
grant execute on function public.can_view_item(text), public.can_view_modifier(text), public.can_view_owned(uuid, uuid) to anon, authenticated;
