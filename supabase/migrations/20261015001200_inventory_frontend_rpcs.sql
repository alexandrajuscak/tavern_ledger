-- =============================================================================
-- RPCs the inventory UI needs that did not exist yet (docs/FRONTEND_INVENTORY_IMPACT.md):
--   set_inventory_item_quantity  set an exact quantity (>= 1) instead of a raw column update
--   move_inventory_item          put an item into a container of the same inventory, or take it out
--   link_inventory_item          link a free-text (legacy) row to a catalog item, after the user confirmed it
-- All are SECURITY DEFINER, authorize the caller themselves and log an inventory event.
-- =============================================================================

alter table public.inventory_events drop constraint inventory_events_action_check;
alter table public.inventory_events add constraint inventory_events_action_check
  check (action in ('add', 'remove', 'use', 'transfer', 'split', 'merge', 'equip', 'unequip',
                    'attune', 'unattune', 'rename', 'apply_modifier', 'remove_modifier', 'move', 'link'));

-- Exact quantity. Decreasing to 0 is not possible here: removing the last piece is remove_inventory_item.
-- Non-stackable catalog items stay one piece per row (add more pieces with add_inventory_item).
create function public.set_inventory_item_quantity(p_item uuid, p_quantity int)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare r public.inventory_items; stk boolean; res jsonb;
begin
  perform public._rpc_begin();
  if p_quantity is null or p_quantity < 1 then
    raise exception 'Quantity must be at least 1 (remove the item instead)' using errcode = '22023';
  end if;
  r := public._lock_item(p_item);
  if not public.can_write_inventory(r.inventory_id) then raise exception 'Not allowed' using errcode = '42501'; end if;
  if r.item_id is not null and p_quantity > 1 then
    select stackable into stk from public.items where id = r.item_id;
    if not stk then raise exception 'This item does not stack; add separate pieces instead' using errcode = '22023'; end if;
  end if;
  if p_quantity <> r.quantity then
    update public.inventory_items set quantity = p_quantity where id = r.id;      -- the row trigger still enforces equip/attune rules
    perform public.log_inventory_event(r.inventory_id, r.id, case when p_quantity > r.quantity then 'add' else 'remove' end,
                                       p_quantity - r.quantity, r.item_id, jsonb_build_object('previous_quantity', r.quantity));
  end if;
  res := jsonb_build_object('inventory_item_id', r.id, 'previous_quantity', r.quantity, 'quantity', p_quantity);
  perform public._rpc_end(); return res;
end;
$$;

-- Put an item into a container (p_container) or take it out (p_container = null). The row trigger checks
-- same inventory, cycles and nesting depth. An identical stack in the target container absorbs the item.
create function public.move_inventory_item(p_item uuid, p_container uuid)
returns uuid
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare r public.inventory_items; res uuid;
begin
  perform public._rpc_begin();
  r := public._lock_item(p_item);
  if not public.can_write_inventory(r.inventory_id) then raise exception 'Not allowed' using errcode = '42501'; end if;
  if p_container is not null and exists (select 1 from public.character_equipment where inventory_item_id = p_item) then
    raise exception 'Unequip the item before putting it into a container' using errcode = '22023';
  end if;
  if p_container is not distinct from r.container_item_id then
    perform public._rpc_end(); return p_item;
  end if;
  update public.inventory_items set container_item_id = p_container where id = p_item;
  perform public.log_inventory_event(r.inventory_id, r.id, 'move', null, r.item_id,
                                     jsonb_build_object('from_container', r.container_item_id, 'to_container', p_container));
  res := public._try_auto_merge(p_item);
  perform public._rpc_end(); return res;
end;
$$;

-- Link a free-text row to a catalog item. The legacy name, weight and description stay on the row
-- (nothing is merged automatically, so no text is lost).
create function public.link_inventory_item(p_item uuid, p_catalog_item text)
returns uuid
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare r public.inventory_items;
begin
  perform public._rpc_begin();
  r := public._lock_item(p_item);
  if not public.can_write_inventory(r.inventory_id) then raise exception 'Not allowed' using errcode = '42501'; end if;
  if r.item_id is not null then raise exception 'This item is already linked to the catalog' using errcode = '22023'; end if;
  if not public.can_view_item(p_catalog_item) then raise exception 'Unknown catalog item' using errcode = 'P0002'; end if;
  if r.quantity < 1 then raise exception 'Set a quantity of at least 1 first' using errcode = '22023'; end if;
  update public.inventory_items set item_id = p_catalog_item where id = r.id;
  perform public.log_inventory_event(r.inventory_id, r.id, 'link', null, p_catalog_item,
                                     jsonb_build_object('legacy_name', r.name));
  perform public._rpc_end(); return r.id;
end;
$$;

revoke all on function public.set_inventory_item_quantity(uuid, int), public.move_inventory_item(uuid, uuid),
  public.link_inventory_item(uuid, text) from public, anon;
grant execute on function public.set_inventory_item_quantity(uuid, int), public.move_inventory_item(uuid, uuid),
  public.link_inventory_item(uuid, text) to authenticated;
