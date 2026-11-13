-- =============================================================================
-- Rollback of 20261112000300_herb_identification.sql (exact: the replaced bodies are the pg_get_functiondef / pg_get_viewdef
-- text of the objects before the migration, CR-free). Run as postgres in ONE transaction:
--   psql -v ON_ERROR_STOP=1 -1 -f supabase/rollback/rollback_herb_identification.sql
-- Data kept on purpose: inventory rows keep the names / descriptions the new code wrote (a revealed name stays revealed),
-- items.secret stays as set (also by set_item_identify_options / _dm_item_secrets_sync), inventory_item_knowledge rows created
-- by the new split / transfer / add paths stay (the old code reads them as before), stored stack keys of secret items' rows keep
-- their name part until the row is next written (such a row only stops auto-merging until then). Lost: the DM identification options
-- (item_secrets columns), per-character knowledge and the examine attempts (export them first if they matter:
--   select * from public.character_item_knowledge; select * from public.item_identify_attempts;).
-- Deploy order for a rollback: the previous frontend (?v=24) first, then this file.
-- =============================================================================

-- ---- 1. the inventory read model of 20261015000800 (drop and recreate: the migration appended a column) --------------------
drop view public.v_character_equipment;
drop view public.v_inventory_detail;
create view public.v_inventory_detail with (security_invoker = true) as  SELECT ii.id,
    ii.inventory_id,
    inv.kind AS inventory_kind,
    inv.character_id,
    ii.item_id,
    i.kind_id,
    i.category_id,
    i.rarity_id,
    i.is_magic,
    i.requires_attunement,
    i.stackable,
    ii.name,
    ii.custom_name,
    COALESCE(NULLIF(ii.custom_name, ''::text), ii.name) AS display_name,
    ii.notes,
    ii.description,
    ii.quantity,
    COALESCE(i.weight_lb, ii.weight) AS unit_weight_lb,
    ii.container_item_id,
    ii.is_quest_item,
    ii.is_attuned,
    ii.attuned_at,
    ii.charges_current,
    ii.charges_max,
    ii.charges_recharge,
    ii.durability,
    ii.state,
    ii.consumable_override,
    COALESCE(ii.consumable_override, i.is_consumable, false) AS is_consumable,
    ii.stack_key,
    ii.sort_order,
    ii.acquired_at,
    ce.slot_id AS equipped_slot,
    (ce.slot_id IS NOT NULL) AS equipped,
    ( SELECT COALESCE(array_agg(m.modifier_id ORDER BY m.modifier_id), '{}'::text[]) AS "coalesce"
           FROM inventory_item_modifiers m
          WHERE (m.inventory_item_id = ii.id)) AS modifier_ids
   FROM (((inventory_items ii
     JOIN inventories inv ON ((inv.id = ii.inventory_id)))
     LEFT JOIN items i ON ((i.id = ii.item_id)))
     LEFT JOIN character_equipment ce ON ((ce.inventory_item_id = ii.id)));

create view public.v_character_equipment with (security_invoker = true) as  SELECT ce.slot_id,
    s.name AS slot_name,
    s.sort_order AS slot_order,
    ce.equipped_at,
    d.id,
    d.inventory_id,
    d.inventory_kind,
    d.character_id,
    d.item_id,
    d.kind_id,
    d.category_id,
    d.rarity_id,
    d.is_magic,
    d.requires_attunement,
    d.stackable,
    d.name,
    d.custom_name,
    d.display_name,
    d.notes,
    d.description,
    d.quantity,
    d.unit_weight_lb,
    d.container_item_id,
    d.is_quest_item,
    d.is_attuned,
    d.attuned_at,
    d.charges_current,
    d.charges_max,
    d.charges_recharge,
    d.durability,
    d.state,
    d.consumable_override,
    d.is_consumable,
    d.stack_key,
    d.sort_order,
    d.acquired_at,
    d.equipped_slot,
    d.equipped,
    d.modifier_ids
   FROM ((character_equipment ce
     JOIN equipment_slots s ON ((s.id = ce.slot_id)))
     JOIN v_inventory_detail d ON ((d.id = ce.inventory_item_id)));

revoke all on public.v_inventory_detail, public.v_character_equipment from anon, authenticated;
grant select on public.v_inventory_detail, public.v_character_equipment to authenticated;
grant all on public.v_inventory_detail, public.v_character_equipment to service_role;

-- ---- 2. the replaced function bodies (state of 20261112000200) -----------------------------------------------------------

CREATE OR REPLACE FUNCTION public.compute_stack_key(r inventory_items)
 RETURNS text
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
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
$function$;

CREATE OR REPLACE FUNCTION public._try_auto_merge(p_id uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
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
$function$;

CREATE OR REPLACE FUNCTION public._split_off(p_id uuid, p_qty integer)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
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
$function$;

CREATE OR REPLACE FUNCTION public.transfer_inventory_item(p_item uuid, p_to_inventory uuid, p_quantity integer DEFAULT NULL::integer)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare r public.inventory_items; q int; moving uuid; from_inv uuid; res uuid;
begin
  perform public._gov_gate_item(p_item, 'inventory.transfer'); perform public._gov_gate_inventory(p_to_inventory, 'inventory.transfer');   -- campaign governance (20261019000100)
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
$function$;

CREATE OR REPLACE FUNCTION public.use_inventory_item(p_item uuid, p_quantity integer DEFAULT 1)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare r public.inventory_items; it public.items; consumable boolean; remaining int; gone boolean := false; fx jsonb; res jsonb;
begin
  perform public._gov_gate_item(p_item, 'runtime.resources');   -- campaign governance (20261019000100)
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
$function$;

CREATE OR REPLACE FUNCTION public._dm_add_item(p_inventory uuid, p_item text, p_quantity integer, p_custom_name text, p_identified boolean, p_version uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare r uuid; s public.item_secrets; it public.items;
begin
  r := public.add_inventory_item(p_inventory, p_item, greatest(coalesce(p_quantity, 1), 1), p_custom_name);
  if not coalesce(p_identified, true) then
    select * into it from public.items where id = p_item;
    select * into s from public.item_secrets where item_id = p_item;
    insert into public.inventory_item_knowledge (inventory_item_id, state, true_name, updated_by) values (r, 'unidentified', it.name, auth.uid())
    on conflict (inventory_item_id) do update set state = 'unidentified', true_name = excluded.true_name, revealed = '{}', magic_known = false;
    update public.items set secret = true where id = p_item;
    update public.inventory_items set name = coalesce(s.unidentified_name, 'Unidentified ' || lower(coalesce((select name from public.item_kinds where id = it.kind_id), 'item'))),
      description = coalesce(s.unidentified_description, ''), custom_name = null where id = r;
  end if;
  return r;
end;
$function$;

CREATE OR REPLACE FUNCTION public.set_item_knowledge(p_inventory_item uuid, p_state text, p_revealed text[] DEFAULT NULL::text[], p_magic_known boolean DEFAULT NULL::boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare r public.inventory_items; it public.items; inv public.inventories; k public.inventory_item_knowledge; camp uuid; s public.item_secrets; old_state text;
begin
  select * into r from public.inventory_items where id = p_inventory_item for update;
  if r.id is null then raise exception 'Item not found' using errcode = 'P0002'; end if;
  select * into inv from public.inventories where id = r.inventory_id;
  select * into it from public.items where id = r.item_id;
  camp := coalesce(inv.campaign_id, (select campaign_id from public.characters where id = inv.character_id), it.campaign_id);
  if auth.uid() is null or not (public.is_admin() or (camp is not null and public.is_campaign_dm(camp))) then
    raise exception 'Only the DM can identify items or reveal their properties' using errcode = '42501';
  end if;
  if p_state not in ('unidentified', 'partially_identified', 'identified') then raise exception 'Unknown knowledge state' using errcode = '22023'; end if;
  select * into k from public.inventory_item_knowledge where inventory_item_id = r.id;
  old_state := coalesce(k.state, 'identified');
  select * into s from public.item_secrets where item_id = r.item_id;
  insert into public.inventory_item_knowledge (inventory_item_id, state, magic_known, revealed, true_name, updated_by)
  values (r.id, p_state, coalesce(p_magic_known, false), coalesce(p_revealed, '{}'), coalesce(k.true_name, it.name), auth.uid())
  on conflict (inventory_item_id) do update set state = excluded.state, magic_known = coalesce(p_magic_known, inventory_item_knowledge.magic_known),
    revealed = coalesce(p_revealed, inventory_item_knowledge.revealed), updated_by = excluded.updated_by, updated_at = now();
  if p_state = 'identified' then
    update public.inventory_items set name = coalesce(k.true_name, it.name), description = coalesce(it.description, '') where id = r.id;
  else
    update public.items set secret = true where id = r.item_id;
    update public.inventory_items set name = coalesce(s.unidentified_name, 'Unidentified item'), description = coalesce(s.unidentified_description, '')
    where id = r.id and old_state = 'identified';
  end if;
  if camp is not null then
    perform public._audit(camp, inv.character_id, 'item_revealed',
                          'Item knowledge: ' || replace(old_state, '_', ' ') || ' → ' || replace(p_state, '_', ' '),
                          null, jsonb_build_object('revealed', to_jsonb(coalesce(p_revealed, '{}'))), null, null, 'party');
  end if;
  return public.get_character_item_knowledge(inv.character_id);
end;
$function$;

CREATE OR REPLACE FUNCTION public.get_character_item_knowledge(p_character uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare camp uuid; dm boolean;
begin
  if auth.uid() is null or not public.can_access_character(p_character) then raise exception 'Character not found' using errcode = '42501'; end if;
  select campaign_id into camp from public.characters where id = p_character;
  dm := public.is_admin() or (camp is not null and public.is_campaign_dm(camp));
  return (select coalesce(jsonb_agg(jsonb_build_object(
             'inventory_item_id', ii.id, 'state', k.state, 'display_name', ii.name, 'magic_known', k.magic_known or 'magic' = any (k.revealed),
             'revealed', to_jsonb(k.revealed),
             'facts', jsonb_build_object(
               'magic', case when dm or 'magic' = any (k.revealed) or k.magic_known then it.is_magic end,
               'rarity', case when dm or 'rarity' = any (k.revealed) then it.rarity_id end,
               'attunement', case when dm or 'attunement' = any (k.revealed) then it.requires_attunement end),
             'properties', (select coalesce(jsonb_agg(p) filter (where dm or (p ->> 'key') = any (k.revealed)), '[]') from jsonb_array_elements(coalesce(s.properties, '[]')) p),
             'curse', case when dm or 'curse' = any (k.revealed) then s.curse end,
             'true_name', case when dm then coalesce(k.true_name, it.name) end, 'item_id', case when dm or k.state = 'identified' then it.id end)
           order by ii.name), '[]')
          from public.inventories inv join public.inventory_items ii on ii.inventory_id = inv.id
          join public.inventory_item_knowledge k on k.inventory_item_id = ii.id
          left join public.items it on it.id = ii.item_id
          left join public.item_secrets s on s.item_id = ii.item_id
          where inv.character_id = p_character);
end;
$function$;

CREATE OR REPLACE FUNCTION public._dm_item_secrets_sync()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare t text; h jsonb;
begin
  if new.status <> 'published' or new.catalog_ref is null or (tg_op = 'UPDATE' and old.status = 'published') then return new; end if;
  select content_type into t from public.dm_content where id = new.content_id;
  if t <> 'item' then return new; end if;
  h := coalesce(new.definition -> 'hidden', '{}');
  if h = '{}'::jsonb then return new; end if;
  insert into public.item_secrets (item_id, unidentified_name, unidentified_description, curse, properties, updated_by)
  values (new.catalog_ref, nullif(h ->> 'unidentified_name', ''), nullif(h ->> 'unidentified_description', ''), nullif(h ->> 'curse', ''),
          coalesce(h -> 'properties', '[]'), auth.uid())
  on conflict (item_id) do update set unidentified_name = excluded.unidentified_name, unidentified_description = excluded.unidentified_description,
    curse = excluded.curse, properties = excluded.properties, updated_by = excluded.updated_by, updated_at = now();
  return new;
end;
$function$;

CREATE OR REPLACE FUNCTION public._character_read(p_character uuid, p_name text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare inv uuid; r jsonb; v text;
begin
  case p_name
  when 'get_character_derived_stats' then return public.get_character_derived_stats(p_character);
  when 'get_character_proficiencies' then return public.get_character_proficiencies(p_character);
  when 'get_character_lineage' then return public.get_character_lineage(p_character);
  when 'get_character_background' then return public.get_character_background(p_character);
  when 'get_character_feats' then return public.get_character_feats(p_character);
  when 'get_character_class_summary' then return public.get_character_class_summary(p_character);
  when 'get_character_spell_slots' then return public.get_character_spell_slots(p_character);
  when 'get_character_class_features' then return public.get_character_class_features(p_character);
  when 'get_character_resources' then return public.get_character_resources(p_character);
  when 'get_character_states' then return public.get_character_states(p_character);
  when 'get_character_transformation' then return public.get_character_transformation(p_character);
  when 'get_character_infusions' then return public.get_character_infusions(p_character);
  when 'get_character_governance' then return public.get_character_governance(p_character);
  when 'get_character_change_requests' then return public.get_character_change_requests(p_character, false);
  when 'get_character_spellbook' then return public.get_character_spellbook(p_character);
  when 'get_character_conditions' then return public.get_character_conditions(p_character);   -- 20261112000200 (the caller's view)
  -- the stored rows of js/store.js loadBundle
  when 'characters' then
    select to_jsonb(c) into r from public.characters c where c.id = p_character;
    if r is null then raise exception 'Character not found' using errcode = '42501'; end if;
    return r;
  when 'inventory_items' then
    return (select coalesce(jsonb_agg(to_jsonb(x) order by x.sort_order, x.created_at), '[]') from public.inventory_items x where x.character_id = p_character);
  when 'notes' then
    return (select coalesce(jsonb_agg(to_jsonb(x) order by x.id), '[]') from public.notes x where x.character_id = p_character);
  when 'spell_slots' then
    return (select coalesce(jsonb_agg(to_jsonb(x) order by x.level), '[]') from public.spell_slots x where x.character_id = p_character);
  when 'feature_trackers' then
    return (select coalesce(jsonb_agg(to_jsonb(x) order by x.sort_order, x.created_at), '[]') from public.feature_trackers x where x.character_id = p_character);
  when 'features' then
    return (select coalesce(jsonb_agg(to_jsonb(x) order by x.sort_order, x.created_at), '[]') from public.features x where x.character_id = p_character);
  when 'attacks' then
    return (select coalesce(jsonb_agg(to_jsonb(x) order by x.sort_order, x.created_at), '[]') from public.attacks x where x.character_id = p_character);
  when 'spells' then
    return (select coalesce(jsonb_agg(to_jsonb(x) order by x.level, x.sort_order, x.created_at), '[]') from public.spells x where x.character_id = p_character);
  -- js/creature-api.js getCompanions (embedded creature, ordered by created_at)
  when 'companions' then
    return (select coalesce(jsonb_agg(jsonb_build_object('id', cc.id, 'name', cc.name, 'source', cc.source, 'hp_max', cc.hp_max,
        'hp_current', cc.hp_current, 'notes', cc.notes, 'active', cc.active, 'creature_id', cc.creature_id,
        'creature', (select jsonb_build_object('id', cr.id, 'name', cr.name, 'size', cr.size, 'creature_type', cr.creature_type,
            'challenge_rating', cr.challenge_rating, 'armor_class', cr.armor_class, 'speed', cr.speed, 'actions', cr.actions,
            'abilities', cr.abilities) from public.creatures cr where cr.id = cc.creature_id)) order by cc.created_at), '[]')
      from public.character_companions cc where cc.character_id = p_character);
  -- js/class-api.js getStartingEquipmentState: applied marker + the primary class's starting-equipment catalog
  when 'starting_equipment_applied' then
    return (select jsonb_build_object('class_version_id', s.class_version_id) from public.character_starting_equipment s where s.character_id = p_character);
  when 'primary_class_starting_equipment' then
    select k.class_version_id into v from public.character_classes k where k.character_id = p_character and k.is_primary limit 1;
    if v is null then return null; end if;
    return jsonb_build_object('class_version_id', v, 'equipment', public.get_class_starting_equipment(v));
  -- js/inventory-ui.js load(): one bundle instead of 7 requests + a catalog chunk
  when 'inventory_bundle' then
    select id into inv from public.inventories where character_id = p_character and kind = 'character';
    if inv is null then return null; end if;
    return jsonb_build_object(
      'inventory_id', inv,
      'rows', (select coalesce(jsonb_agg(to_jsonb(d) order by d.sort_order, d.acquired_at, d.id), '[]') from public.v_inventory_detail d where d.inventory_id = inv),
      'equipment', (select coalesce(jsonb_agg(jsonb_build_object('slot_id', e.slot_id, 'inventory_item_id', e.inventory_item_id, 'equipped_at', e.equipped_at) order by e.slot_id), '[]')
                    from public.character_equipment e where e.character_id = p_character),
      'attunement', (select to_jsonb(a) from public.v_character_attunement a where a.character_id = p_character),
      'weight', (select to_jsonb(w) from public.v_inventory_weight w where w.inventory_id = inv),
      'containers', (select coalesce(jsonb_agg(to_jsonb(c) order by c.container_item_id), '[]') from public.v_container_contents c where c.inventory_id = inv),
      'review', (select coalesce(jsonb_agg(jsonb_build_object('inventory_item_id', x.inventory_item_id, 'category', x.category, 'status', x.status, 'detail', x.detail) order by x.id), '[]')
                 from public.legacy_inventory_review x where x.character_id = p_character and x.status in ('pending', 'manual_review')),
      -- the columns of js/inventory-api.js CATALOG_COLUMNS
      'catalog_items', (select coalesce(jsonb_agg(to_jsonb(ci)), '[]') from (
          select id, name, kind_id, kind_name, category_id, category_name, rarity_id, is_magic, requires_attunement, is_consumable,
            stackable, weight_lb, cost_value, cost_unit, source_book_id, source_book_name, source_label, owner_id, campaign_id,
            visibility, is_mine, can_edit, archived_at, description, data_source_id, weapon_group, damage_dice, damage_type_id,
            versatile_damage, is_ranged, range_type, range_normal, range_max, weapon_ammo_type_id, reload, misfire, weapon_properties,
            base_ac, ac_bonus, dex_modifier_mode, dex_cap, strength_requirement, stealth_disadvantage, is_shield, ammo_type_id,
            pack_size, capacity_weight_lb, capacity_volume_cuft, weightless_contents, extradimensional, icon_key, details   -- 20261107000300
          from public.v_item_catalog
          where id in (select ii.item_id from public.inventory_items ii where ii.inventory_id = inv and ii.item_id is not null)) ci));
  when 'revisions' then   -- latest revision (log id) per source table
    return (select coalesce(jsonb_object_agg(x.source_table, x.rev), '{}') from (
      select r2.source_table, max(r2.id) as rev from public.character_revisions r2 where r2.character_id = p_character group by 1) x);
  else
    raise exception 'Unknown read %', p_name using errcode = '22023';
  end case;
end $function$;

-- ---- 3. new functions, tables, columns, cache trigger -------------------------------------------------------------------
drop function public.get_campaign_identify_attempts(uuid, text);
drop function public.dm_give_item(text, uuid[], int, boolean);
drop function public.set_item_identify_options(text, jsonb);
drop function public.dm_reveal_item(text, uuid[], text[], uuid);
drop function public.resolve_identify_attempt(uuid, boolean, int, text, boolean, text[]);
drop function public.examine_inventory_item(uuid, text, int, uuid);
drop function public._identify_attempt_dm(public.item_identify_attempts);
drop function public._identify_attempt_player(public.item_identify_attempts);
drop function public._identify_check_label(text);
drop function public._identify_retry_ok(text, public.item_identify_attempts);
drop function public._identify_apply(uuid, text, text[]);
drop function public._identify_sync_rows(uuid, text);
drop function public._identify_touch(uuid);
drop function public._item_decoy(text);
drop function public._inventory_face(uuid);
drop function public._inventory_knows_all(uuid);
drop table public.item_identify_attempts;
drop table public.character_item_knowledge;
drop trigger if exists tl_cache_rev on public.item_secrets;
create trigger tl_cache_rev after insert or update or delete on public.item_secrets for each row execute function tl_cache.bump('global');
drop trigger if exists tl_cache_rev on public.inventory_item_knowledge;
create trigger tl_cache_rev after insert or update or delete on public.inventory_item_knowledge for each row execute function tl_cache.bump('global');
drop function tl_cache.bump_item_knowledge();
drop trigger items_secret_stack_keys on public.items;
drop function public._items_secret_stack_keys();
alter table public.item_secrets
  drop column face_kind_id, drop column identify_dc, drop column identify_checks, drop column identify_reveal,
  drop column identify_auto, drop column identify_retry, drop column fail_hint;

notify pgrst, 'reload schema';
