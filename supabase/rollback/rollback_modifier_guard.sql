-- =============================================================================
-- Rollback of 20261114001100_modifier_guard.sql. Run as postgres in ONE transaction:
--   psql -v ON_ERROR_STOP=1 -1 -f supabase/rollback/rollback_modifier_guard.sql
-- Restores the exact previous body (pg_get_functiondef from the local database at 20261114001000) of the trigger function
-- inventory_item_modifiers_before_write. Nothing else was changed by the migration; no row is touched. The schema_migrations
-- row of 20261114001100 is removed by the operator, as for earlier rollbacks. Idempotent (a second run is a no-op).
-- After the rollback a campaign player can again attach an official modifier to, or remove one from, an own item through REST (M1).
-- =============================================================================
set local lock_timeout = '5s';
CREATE OR REPLACE FUNCTION public.inventory_item_modifiers_before_write()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
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
  -- 20261114001000: a campaign modifier (an enhancement) is attached by crafting (inside an RPC), the campaign DM or an admin
  if m.campaign_id is not null and m.owner_id is not null
     and coalesce(current_setting('tavern.rpc', true), '') <> '1' and coalesce(current_setting('tavern.managed_modifier', true), '') <> '1'
     and auth.uid() is not null and not public.is_admin() and not public.is_campaign_dm(m.campaign_id) then
    raise exception 'This enhancement is attached by crafting, not directly' using errcode = '42501';
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
$function$
;
