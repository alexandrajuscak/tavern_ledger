-- =============================================================================
-- Modifier guard (R-E2.1; review finding M1 of R-E2). Additive on top of 20261114001000_weapon_enhancement;
-- rollback supabase/rollback/rollback_modifier_guard.sql (the exact previous body of the one replaced function).
-- Before: a campaign player could INSERT any official modifier (for example 'weapon-plus-3') on an item of their own character
-- through plain REST (grant insert/delete + policy inventory_item_modifiers_write / can_write_inventory, 20261015000900), and
-- DELETE modifier rows from it (for example a DM-given negative modifier). R-E2 refused this for campaign ('cm-') modifiers only.
-- Now every direct insert or delete of an inventory_item_modifiers row is allowed only on a managed path:
--   * inside a SECURITY DEFINER inventory RPC (tavern.rpc: _split_off copies, crafting / enhancement) or a class-feature path
--     (tavern.managed_modifier: infusions),
--   * the DM of the item's campaign (the campaign of the character holding it, or of the stash / party stash / shop / npc
--     inventory), or an admin,
--   * no signed-in user (postgres / service_role maintenance),
--   * a DELETE cascaded from deleting the item itself (item, merge, character, campaign delete): the parent row is already gone.
-- An item with no campaign (a character outside any campaign, a personal stash) has no DM: only the managed paths and an admin.
-- The grants stay (the campaign DM keeps attaching / removing modifiers directly; there is no DM RPC for that); the rule is in
-- the before-write trigger. The earlier checks (class-feature managed modifiers, campaign modifiers) run first, unchanged.
-- No table, grant, policy, governance or data change.
-- =============================================================================
set lock_timeout = '5s';

create or replace function public.inventory_item_modifiers_before_write()
returns trigger
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare it public.items; m public.item_modifiers; camp uuid; iid uuid; parent_exists boolean;
begin
  if tg_op = 'DELETE' then
    if exists (select 1 from public.item_modifiers x where x.id = old.modifier_id and x.managed_by is not null)
       and coalesce(current_setting('tavern.managed_modifier', true), '') <> '1' then
      raise exception 'This modifier is managed by a class feature; end it there (Infuse Item)' using errcode = '42501';
    end if;
  else
    select i.* into it from public.inventory_items ii join public.items i on i.id = ii.item_id where ii.id = new.inventory_item_id;
    if it.id is null then raise exception 'Modifiers can only be applied to catalog items'; end if;
    select * into m from public.item_modifiers where id = new.modifier_id;
    if m.managed_by is not null and coalesce(current_setting('tavern.managed_modifier', true), '') <> '1' then
      raise exception 'This modifier is applied by a class feature (Infuse Item), not directly' using errcode = '42501';
    end if;
    -- 20261114001000: a campaign modifier (an enhancement) is attached by crafting (inside an RPC), the campaign DM or an admin
    if m.campaign_id is not null and m.owner_id is not null
       and coalesce(current_setting('tavern.rpc', true), '') <> '1' and coalesce(current_setting('tavern.managed_modifier', true), '') <> '1'
       and auth.uid() is not null and not public.is_admin() and not public.is_campaign_dm(m.campaign_id) then
      raise exception 'This enhancement is attached by crafting, not directly' using errcode = '42501';
    end if;
  end if;
  -- 20261114001100: any other direct insert / delete only on a managed path, by the DM of the item's campaign or an admin
  iid := case when tg_op = 'DELETE' then old.inventory_item_id else new.inventory_item_id end;
  if coalesce(current_setting('tavern.rpc', true), '') <> '1' and coalesce(current_setting('tavern.managed_modifier', true), '') <> '1'
     and auth.uid() is not null and not public.is_admin() then
    select true, coalesce(inv.campaign_id, ch.campaign_id) into parent_exists, camp
    from public.inventory_items ii
    join public.inventories inv on inv.id = ii.inventory_id
    left join public.characters ch on ch.id = inv.character_id
    where ii.id = iid;
    if tg_op = 'DELETE' and parent_exists is null then
      return old;                                              -- cascaded from deleting the item itself
    end if;
    if camp is null or not public.is_campaign_dm(camp) then
      raise exception 'Item modifiers are changed by the campaign DM or by the game (crafting, infusions), not directly'
        using errcode = '42501';
    end if;
  end if;
  if tg_op = 'DELETE' then return old; end if;
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

reset lock_timeout;
