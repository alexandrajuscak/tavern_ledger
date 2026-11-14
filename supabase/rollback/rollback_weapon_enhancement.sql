-- =============================================================================
-- Rollback of 20261114001000_weapon_enhancement.sql. Run as postgres in ONE transaction:
--   psql -v ON_ERROR_STOP=1 -1 -f supabase/rollback/rollback_weapon_enhancement.sql
-- Restores the exact previous bodies (pg_get_functiondef from the local database at 20261114000900) of the ten replaced functions
-- and the previous read policy of item_modifiers, drops the new functions, the new columns and constraints (the schema_migrations
-- row of 20261114001000 is removed by the operator, as for earlier rollbacks).
-- GUARD: it REFUSES (raises, nothing changed) once any recipe is an enhancement recipe (kind <> 'item', no result item) or has a
-- base line: the restored v2 bodies would use up ingredients and produce nothing. No recipe is changed or deleted by this file;
-- the operator decides (for example archive such recipes in the app and keep the migration).
-- Without such recipes the dropped columns hold only their defaults, so nothing is lost.
-- KEPT on purpose (no row is deleted): the DM's campaign modifiers ('cm-...' item_modifiers and their effects) and every
-- enhancement already attached to an item (inventory_item_modifiers): they keep working through the ordinary modifier path.
-- After the rollback campaign members can read campaign modifiers again (the previous policy) and a disguised copy's modifier
-- label shows the modifier name again (the 20261114000800 behaviour).
-- Deploy order for a rollback: the previous frontend (?v=37) first, then this file.
-- =============================================================================
set local lock_timeout = '5s';
do $$
begin
  if exists (select 1 from public.crafting_recipes where kind <> 'item' or output_item_id is null)
     or exists (select 1 from public.crafting_recipe_ingredients where is_base) then
    raise exception 'rollback_weapon_enhancement: enhancement recipes exist; nothing was changed (archive them and keep the migration, or decide per recipe)';
  end if;
end $$;
drop function if exists public.dm_save_campaign_modifier(uuid, jsonb);
CREATE OR REPLACE FUNCTION public._character_effects(p_character uuid)
 RETURNS TABLE(source_type text, source_id uuid, item_id text, source_name text, modifier_id text, seq integer, effect_type text, value numeric, target text, activation text, stacking text, stack_group text, scope text, active boolean, inactive_reason text, applied boolean)
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
  with owned as (
    -- 20261114000800 (review v35 F1): a copy the reader sees only disguised is labelled with its disguise and no item id
    select ii.id, case when mk.masked then null else ii.item_id end as item_id,
           ii.is_attuned and public._item_active_in_form(p_character, ii.id) as is_attuned,
           case when mk.masked then coalesce(nullif(ii.custom_name, ''), nullif(ii.name, ''), 'Unidentified item') else coalesce(ii.custom_name, it.name) end as name, it.kind_id, it.requires_attunement, e.slot_id
    from public.inventories inv
    join public.inventory_items ii on ii.inventory_id = inv.id
    join public.items it on it.id = ii.item_id                       -- RLS: modifiers of invisible items do not exist
    left join public.character_equipment e on e.inventory_item_id = ii.id and e.character_id = p_character
      and public._item_active_in_form(p_character, ii.id)              -- merged or dropped in Wild Shape: no effect
    cross join lateral (select public._inventory_item_masked(ii.id) as masked) mk
    where inv.character_id = p_character
      and exists (select 1 from public.inventory_item_modifiers im where im.inventory_item_id = ii.id)
  ),
  raw as (
    -- 20261114000500: item effects of every owned item (also unidentified ones, under their disguise) and permanent effects
    select x.source_type, x.source_id, x.item_id, x.source_name, null::text as modifier_id, x.seq,
           x.effect_type, x.value, x.target, x.activation, x.stacking, x.stack_group, x.priority,
           case when x.effect_type in ('attack_bonus', 'damage_bonus') and x.kind_id = 'weapon' then 'self' else 'global' end as scope,
           x.inactive_reason
    from public._character_item_effect_rows(p_character) x
    union all
    select 'modifier', o.id, o.item_id, o.name || ' (' || md.name || ')', md.id, me.seq,
           me.effect_type, me.value, null,
           case when coalesce(md.requires_attunement_override, o.requires_attunement) then 'equipped_and_attuned' else 'equipped' end,
           'additive', null, 0,
           case when me.effect_type in ('attack_bonus', 'damage_bonus') then 'self' else 'global' end,
           case when o.slot_id is null then 'not_equipped'
                when coalesce(md.requires_attunement_override, o.requires_attunement) and not o.is_attuned then 'not_attuned' end
    from owned o
    join public.inventory_item_modifiers im on im.inventory_item_id = o.id
    join public.item_modifiers md on md.id = im.modifier_id
    join public.item_modifier_effects me on me.modifier_id = md.id
    union all
    -- class feature effects (20261015001800); only active features, the effect's own conditions decide inactive_reason
    select 'class_feature', ce.character_class_id, null, ce.class_name || ': ' || ce.feature_name,
           ce.unlock_id || ':' || ce.seq || ':' || coalesce(ce.pick, 0), ce.seq,
           ce.effect_type, ce.value, case when ce.effect_type = 'resistance' then coalesce(ce.target, ce.value_text) else ce.target end,
           'owned', 'additive', null, 0, 'global',
           case when ce.active then null else coalesce(ce.inactive_reason, 'inactive') end
    from public._character_feature_effects(p_character) ce
    where ce.feature_active and ce.automation <> 'informational'
      and ce.effect_type in ('ability_bonus', 'ac_bonus', 'save_bonus', 'speed_bonus', 'resistance', 'skill_advantage',
                             'skill_disadvantage', 'carrying_capacity_bonus')
  ),
  ranked as (
    select r.*, r.inactive_reason is null as active,
           row_number() over (
             partition by r.inactive_reason is null, r.effect_type, coalesce(r.target, ''), r.scope,
                          case when r.scope = 'self' then r.source_id::text else '' end,
                          case r.stacking when 'additive' then r.source_type || r.source_id || coalesce(r.modifier_id, '') || r.seq
                                          when 'non_stacking_group' then 'group:' || r.stack_group
                                          else r.stacking end
             order by r.value desc nulls last, r.priority desc, r.source_id) as rn
    from raw r
  )
  select source_type, source_id, item_id, source_name, modifier_id, seq, effect_type, value, target, activation, stacking, stack_group,
         scope, active, inactive_reason, active and rn = 1 as applied
  from ranked;
$function$
;
CREATE OR REPLACE FUNCTION public.inventory_item_modifiers_before_write()
 RETURNS trigger
 LANGUAGE plpgsql
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
CREATE OR REPLACE FUNCTION public.can_view_modifier(p_mod text)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$ select exists (select 1 from public.item_modifiers m where m.id = p_mod and public.can_view_owned(m.owner_id, m.campaign_id)); $function$
;
CREATE OR REPLACE FUNCTION public._craft_recipes_player(p_character uuid, p_recipe uuid DEFAULT NULL::uuid)
 RETURNS TABLE(recipe_id uuid, recipe_name text, j jsonb)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  with ch as (select c.id, c.campaign_id from public.characters c where c.id = p_character and c.campaign_id is not null),
  rc as (
    select r.*, kn.character_id is not null as learned, kn.seen_at as kn_seen
    from ch join public.crafting_recipes r on r.campaign_id = ch.campaign_id and r.status = 'published'
    left join public.character_known_recipes kn on kn.character_id = ch.id and kn.recipe_id = r.id
    where (p_recipe is null or r.id = p_recipe) and (r.visibility = 'known' or kn.character_id is not null)),
  rws as (
    select ii.id, ii.item_id, ii.quantity, coalesce(nullif(ii.custom_name, ''), ii.name) as nm,
           coalesce(not ii.is_attuned and not ii.is_quest_item
                    and not exists (select 1 from public.character_equipment e where e.inventory_item_id = ii.id)
                    and not exists (select 1 from public.inventory_items c where c.container_item_id = ii.id), false) as free
    from public.inventory_items ii join public.inventories inv on inv.id = ii.inventory_id
    where inv.character_id = p_character and inv.kind = 'character' and ii.item_id is not null
      and not exists (select 1 from public.inventory_item_knowledge k where k.inventory_item_id = ii.id and k.state <> 'identified')
      and exists (select 1 from rc)),
  lines as (select g.* from public.crafting_recipe_ingredients g join rc on rc.id = g.recipe_id),
  tag_pairs as (
    select distinct x.item_id, lower(btrim(t)) as tag
    from (select distinct w.item_id from rws w) x join public.items i on i.id = x.item_id
    cross join lateral jsonb_array_elements_text(case when jsonb_typeof(i.details -> 'ingredient_tags') = 'array'
                                                      then i.details -> 'ingredient_tags' else '[]'::jsonb end) t
    where exists (select 1 from lines l where l.ingredient_tag is not null)
      and public._craft_item_trusted(x.item_id, (select ch.campaign_id from ch))),
  cand as materialized (
    select g.id as gid, w.id, w.nm, w.quantity from lines g join rws w on w.item_id = g.item_id
     where g.item_id is not null and (not g.consumed or w.free)
    union all
    select g.id, w.id, w.nm, w.quantity from lines g join tag_pairs p on p.tag = g.ingredient_tag join rws w on w.item_id = p.item_id
     where g.item_id is null and (not g.consumed or w.free)),
  agg as materialized (
    select c.gid, sum(c.quantity)::int as have,
           jsonb_agg(jsonb_build_object('inventory_item_id', c.id, 'name', c.nm, 'quantity', c.quantity) order by c.nm, c.id) as list
    from cand c group by c.gid),
  known_items as materialized (
    select x.item_id, public._craft_item_known(p_character, x.item_id) as known
    from (select rc.output_item_id as item_id from rc union select l.item_id from lines l where l.item_id is not null) x),
  ings as materialized (
    select g.recipe_id, jsonb_agg(jsonb_build_object(
      'seq', g.seq, 'quantity', g.quantity, 'consumed', g.consumed, 'tag', g.ingredient_tag,
      'label', case when g.item_id is null then coalesce(nullif(btrim(g.label), ''), 'Any ingredient tagged “' || g.ingredient_tag || '”')
                    when ki.known then (select i.name from public.items i where i.id = g.item_id)
                    else coalesce(nullif(btrim(g.label), ''), 'An unknown ingredient') end,
      'item_id', case when g.item_id is not null and ki.known then g.item_id end,
      'have', coalesce(a.have, 0), 'candidates', coalesce(a.list, '[]'::jsonb)) order by g.seq) as list
    from lines g left join known_items ki on ki.item_id = g.item_id left join agg a on a.gid = g.id
    group by g.recipe_id)
  select rc.id, rc.name, jsonb_build_object(
    'recipe_id', rc.id, 'name', rc.name, 'description', rc.description, 'time_note', rc.time_note,
    'source', case when rc.learned then 'learned' else 'known' end,
    'new', rc.learned and rc.kn_seen is null,
    'output', jsonb_build_object('name', case when ko.known then it.name
                                              else coalesce(nullif(btrim(rc.output_label), ''), (select d.name from public._item_decoy(rc.output_item_id) d)) end,
                                 'item_id', case when ko.known then it.id end, 'kind_id', case when ko.known then it.kind_id end,
                                 'quantity', rc.output_quantity, 'known', ko.known),
    'check', case when rc.check_key is not null then jsonb_build_object('key', rc.check_key, 'label', public._identify_check_label(rc.check_key),
                                                                         'dc', rc.check_dc) end,
    'tool', case when tl.tool is not null then jsonb_build_object('item_id', tl.tool, 'name', public._identify_check_label(tl.tool),
                                                                  'have', exists (select 1 from rws w where w.item_id = tl.tool)) end,
    'dm_confirms', rc.requires_dm_approval,
    'ingredients', coalesce(ig.list, '[]'::jsonb),
    'missing', (select coalesce(jsonb_agg(jsonb_build_object('seq', (e ->> 'seq')::int, 'label', e ->> 'label',
                                 'need', (e ->> 'quantity')::int - (e ->> 'have')::int) order by (e ->> 'seq')::int), '[]')
                from jsonb_array_elements(coalesce(ig.list, '[]'::jsonb)) e where (e ->> 'have')::int < (e ->> 'quantity')::int),
    'can_craft', not exists (select 1 from jsonb_array_elements(coalesce(ig.list, '[]'::jsonb)) e where (e ->> 'have')::int < (e ->> 'quantity')::int)
                 and (tl.tool is null or exists (select 1 from rws w where w.item_id = tl.tool)),
    'pending_attempt_id', (select a.id from public.crafting_attempts a where a.character_id = p_character and a.recipe_id = rc.id and a.status = 'pending'))
  from rc
  left join public.items it on it.id = rc.output_item_id
  left join known_items ko on ko.item_id = rc.output_item_id
  left join ings ig on ig.recipe_id = rc.id
  cross join lateral (select public._craft_tool_item(rc.check_key) as tool) tl;
$function$
;
CREATE OR REPLACE FUNCTION public._craft_apply(p_attempt uuid, p_outcome text, p_failure_consumes text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare a public.crafting_attempts; r public.crafting_recipes; g public.crafting_recipe_ingredients; s jsonb; ir public.inventory_items;
  inv_char uuid; inv_kind text; q int; mode text; consumed jsonb := '[]'; produced jsonb := '[]'; meta jsonb; out_item text; out_qty int;
  covered int;
begin
  select * into a from public.crafting_attempts where id = p_attempt;
  select * into r from public.crafting_recipes where id = a.recipe_id;
  -- 20261114000900: the per-item locks before any row lock (the callers took them before their first write already)
  perform public._craft_lock_items(a.selected, r.id);
  if not exists (select 1 from public.characters c where c.id = a.character_id and c.campaign_id = r.campaign_id) then
    raise exception 'The character is no longer in this campaign' using errcode = 'TLCRF';
  end if;
  perform public._rpc_begin();
  perform 1 from public.inventory_items where id in (select (x ->> 'inventory_item_id')::uuid from jsonb_array_elements(a.selected) x)
    order by id for update;
  for g in select * from public.crafting_recipe_ingredients where recipe_id = r.id order by seq loop
    select coalesce(sum((x ->> 'quantity')::int), 0) into covered from jsonb_array_elements(a.selected) x where (x ->> 'seq')::int = g.seq;
    if covered <> g.quantity then raise exception 'The ingredients no longer fit the recipe (it was changed)' using errcode = 'TLCRF'; end if;
  end loop;
  for s in select x from jsonb_array_elements(a.selected) x loop
    select * into g from public.crafting_recipe_ingredients where recipe_id = r.id and seq = (s ->> 'seq')::int;
    select * into ir from public.inventory_items where id = (s ->> 'inventory_item_id')::uuid;
    select i.character_id, i.kind into inv_char, inv_kind from public.inventories i where i.id = ir.inventory_id;
    if g.id is null then raise exception 'The ingredients no longer fit the recipe (it was changed)' using errcode = 'TLCRF'; end if;
    if ir.id is null or inv_char is distinct from a.character_id or inv_kind <> 'character' or ir.quantity < (s ->> 'quantity')::int then
      raise exception 'Some ingredients are no longer in the inventory' using errcode = 'TLCRF';
    end if;
    if not public._craft_row_known(ir.id) or not public._craft_row_matches(ir.item_id, g) then
      raise exception 'Some ingredients changed since the attempt' using errcode = 'TLCRF';
    end if;
    if g.consumed and not public._craft_row_free(ir.id) then
      raise exception 'An ingredient is equipped, attuned, a quest item or a container with contents' using errcode = 'TLCRF';
    end if;
  end loop;
  if not public._craft_tool_ok(a.character_id, r.check_key) then
    raise exception 'The tool for this recipe is no longer in the inventory' using errcode = 'TLCRF';
  end if;

  mode := case when p_outcome in ('success', 'critical_success') then 'lose_all'
               when p_outcome = 'critical_failure' then 'lose_all'
               else coalesce(p_failure_consumes, r.failure_mode) end;
  meta := jsonb_build_object('craft_attempt', a.id, 'recipe', r.id, 'outcome', p_outcome);
  for s in select x from jsonb_array_elements(a.selected) x order by (x ->> 'inventory_item_id') loop
    select * into g from public.crafting_recipe_ingredients where recipe_id = r.id and seq = (s ->> 'seq')::int;
    continue when not g.consumed;
    q := case mode when 'lose_all' then (s ->> 'quantity')::int when 'lose_half' then (s ->> 'quantity')::int / 2 else 0 end;
    continue when q < 1;
    select * into ir from public.inventory_items where id = (s ->> 'inventory_item_id')::uuid;
    if q = ir.quantity then delete from public.inventory_items where id = ir.id;
    else update public.inventory_items set quantity = quantity - q where id = ir.id; end if;
    perform public.log_inventory_event(ir.inventory_id, case when q = ir.quantity then null else ir.id end, 'remove', -q, ir.item_id,
      meta || jsonb_build_object('previous_quantity', ir.quantity, 'deleted', q = ir.quantity, 'name', coalesce(nullif(ir.custom_name, ''), ir.name)));
    consumed := consumed || jsonb_build_array(jsonb_build_object('inventory_item_id', ir.id, 'item_id', ir.item_id,
      'name', coalesce(nullif(ir.custom_name, ''), ir.name), 'quantity', q));
  end loop;
  if p_outcome in ('success', 'critical_success') then
    out_item := case when p_outcome = 'critical_success' then coalesce(r.crit_output_item_id, r.output_item_id) else r.output_item_id end;
    out_qty := r.output_quantity + case when p_outcome = 'critical_success' then r.crit_bonus_quantity else 0 end;
  else
    out_item := r.failure_output_item_id;
    out_qty := r.failure_output_quantity;
  end if;
  if out_item is not null then
    produced := jsonb_build_array(public._craft_produce(a.inventory_id, a.character_id, out_item, out_qty, r.output_identified, meta));
  end if;
  perform public._rpc_end();
  return jsonb_build_object('consumed', consumed, 'produced', produced);
end $function$
;
CREATE OR REPLACE FUNCTION public.start_craft_attempt(p_character uuid, p_recipe uuid, p_selected jsonb, p_roll_total integer DEFAULT NULL::integer, p_request_id uuid DEFAULT NULL::uuid, p_natural text DEFAULT NULL::text, p_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare ch public.characters; rc public.crafting_recipes; a public.crafting_attempts; inv uuid; s jsonb; g public.crafting_recipe_ingredients;
  ir public.inventory_items; norm jsonb := '[]'; ids uuid[] := '{}'; covered int; res jsonb; inv_char uuid; inv_kind text; q int;
begin
  if p_request_id is null then raise exception 'A request id is required' using errcode = '22023'; end if;
  ch := public._craft_player_gate(p_character);
  select * into a from public.crafting_attempts where character_id = ch.id and request_id = p_request_id;
  if a.id is not null then return public._craft_attempt_player(a) || jsonb_build_object('replayed', true); end if;
  select * into rc from public.crafting_recipes where id = p_recipe;
  if not public._craft_recipe_visible(ch.id, p_recipe) then raise exception 'Recipe not found' using errcode = 'P0002'; end if;
  select id into inv from public.inventories where character_id = ch.id and kind = 'character' order by created_at limit 1;
  if inv is null then raise exception 'The character has no inventory' using errcode = '22023'; end if;

  if p_selected is null or jsonb_typeof(p_selected) <> 'array' or jsonb_array_length(p_selected) = 0 or jsonb_array_length(p_selected) > 40 then
    raise exception 'Choose the items to use' using errcode = '22023';
  end if;
  for s in select x from jsonb_array_elements(p_selected) x loop
    if jsonb_typeof(s) <> 'object' or coalesce(s ->> 'seq', '') !~ '^\d{1,2}$' or coalesce(s ->> 'quantity', '') !~ '^\d{1,3}$'
       or coalesce(s ->> 'inventory_item_id', '') !~ '^[0-9a-fA-F-]{36}$' or (s ->> 'quantity')::int < 1 then
      raise exception 'Choose the items to use' using errcode = '22023';
    end if;
    select * into ir from public.inventory_items where id = (s ->> 'inventory_item_id')::uuid;
    select i.character_id, i.kind into inv_char, inv_kind from public.inventories i where i.id = ir.inventory_id;
    if ir.id is null or inv_char is distinct from ch.id or inv_kind <> 'character' then
      raise exception 'Choose items from this character''s inventory' using errcode = '22023';
    end if;
    if ir.id = any (ids) then raise exception 'Use each stack for one ingredient only' using errcode = '22023'; end if;
    ids := ids || ir.id;
    norm := norm || jsonb_build_array(jsonb_build_object('seq', (s ->> 'seq')::int, 'inventory_item_id', ir.id, 'quantity', (s ->> 'quantity')::int));
  end loop;
  -- knowledge FIRST, for every selected row, with one fixed message (it never says "matches" or "does not match")
  if exists (select 1 from unnest(ids) x where not public._craft_row_known(x)) then
    raise exception 'You don''t know what this ingredient is yet' using errcode = '22023';
  end if;
  for s in select x from jsonb_array_elements(norm) x loop
    select * into g from public.crafting_recipe_ingredients where recipe_id = rc.id and seq = (s ->> 'seq')::int;
    select * into ir from public.inventory_items where id = (s ->> 'inventory_item_id')::uuid;
    q := (s ->> 'quantity')::int;
    if g.id is null or not public._craft_row_matches(ir.item_id, g) then raise exception 'This item does not fit that ingredient' using errcode = '22023'; end if;
    if q > ir.quantity then raise exception 'Not enough items in that stack' using errcode = '22023'; end if;
    if g.consumed and not public._craft_row_free(ir.id) then
      raise exception 'Equipped, attuned or quest items and containers with contents cannot be used up' using errcode = '22023';
    end if;
  end loop;
  for g in select * from public.crafting_recipe_ingredients where recipe_id = rc.id order by seq loop
    select coalesce(sum((x ->> 'quantity')::int), 0) into covered from jsonb_array_elements(norm) x where (x ->> 'seq')::int = g.seq;
    if covered <> g.quantity then raise exception 'Choose exactly what the recipe needs for each ingredient' using errcode = '22023'; end if;
  end loop;
  -- 20261114000900: the tool the check needs must be carried (a known row)
  if not public._craft_tool_ok(ch.id, rc.check_key) then
    raise exception 'You need % for this recipe', public._identify_check_label(rc.check_key) using errcode = '22023';
  end if;
  if rc.check_key is not null and (p_roll_total is null or p_roll_total < -10 or p_roll_total > 60) then
    raise exception 'Enter the total of your roll (-10 to 60)' using errcode = '22023';
  end if;
  if p_roll_total is not null and (p_roll_total < -10 or p_roll_total > 60) then raise exception 'Roll out of range' using errcode = '22023'; end if;
  if p_natural is not null and p_natural not in ('nat20', 'nat1') then raise exception 'Natural roll: nat20 or nat1' using errcode = '22023'; end if;
  if exists (select 1 from public.crafting_attempts x where x.character_id = ch.id and x.recipe_id = rc.id and x.status = 'pending') then
    raise exception 'Your DM has not answered your last attempt at this recipe yet' using errcode = '55000';
  end if;
  -- 20261114000900: the auto path changes inventory rows -> the per-item locks before the first write (the insert below bumps the
  -- character cache counter, which a transfer holding 4242 also wants)
  if not rc.requires_dm_approval and rc.check_dc is null then
    perform public._craft_lock_items(norm, rc.id);
  end if;

  begin
    insert into public.crafting_attempts (character_id, recipe_id, recipe_revision, inventory_id, selected, roll_total, natural_roll,
                                          player_note, request_id, auto)
    values (ch.id, rc.id, rc.revision, inv, norm, p_roll_total, p_natural, nullif(left(btrim(coalesce(p_note, '')), 500), ''), p_request_id,
            not rc.requires_dm_approval and rc.check_dc is null)
    on conflict (character_id, request_id) do nothing
    returning * into a;
  exception when unique_violation then
    raise exception 'Your DM has not answered your last attempt at this recipe yet' using errcode = '55000';
  end;
  if a.id is null then
    select * into a from public.crafting_attempts where character_id = ch.id and request_id = p_request_id;
    return public._craft_attempt_player(a) || jsonb_build_object('replayed', true);
  end if;
  if a.auto then
    res := public._craft_apply(a.id, 'success', null);
    update public.crafting_attempts set status = 'applied', outcome = 'success', consumed = res -> 'consumed', produced = res -> 'produced',
           resolved_at = now(), revision = revision + 1 where id = a.id returning * into a;
  end if;
  perform public._craft_audit(a);
  perform public._identify_touch(ch.id);
  return public._craft_attempt_player(a);
end $function$
;
CREATE OR REPLACE FUNCTION public._craft_recipe_dm(p_recipe uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select to_jsonb(r) || jsonb_build_object(
    'output_name', (select name from public.items where id = r.output_item_id),
    'output_secret', (select secret from public.items where id = r.output_item_id),
    'crit_output_name', (select name from public.items where id = r.crit_output_item_id),
    'failure_output_name', (select name from public.items where id = r.failure_output_item_id),
    'check_label', case when r.check_key is not null then public._identify_check_label(r.check_key) end,
    'tool_item_id', public._craft_tool_item(r.check_key),
    'ingredients', (select coalesce(jsonb_agg(jsonb_build_object('seq', g.seq, 'item_id', g.item_id, 'item_name', i.name, 'item_secret', i.secret,
                       'tag', g.ingredient_tag, 'label', g.label, 'quantity', g.quantity, 'consumed', g.consumed) order by g.seq), '[]')
                    from public.crafting_recipe_ingredients g left join public.items i on i.id = g.item_id where g.recipe_id = r.id),
    'teachers', (select coalesce(jsonb_agg(jsonb_build_object('item_id', t.item_id, 'item_name', i.name, 'kind_id', i.kind_id,
                       'consume_on_learn', t.consume_on_learn) order by i.name, t.item_id), '[]')
                 from public.crafting_recipe_teachers t join public.items i on i.id = t.item_id where t.recipe_id = r.id),
    'known_by', (select coalesce(jsonb_agg(jsonb_build_object('character_id', k.character_id, 'name', c.name, 'seen', k.seen_at is not null,
                       'source', k.source) order by c.name), '[]')
                 from public.character_known_recipes k join public.characters c on c.id = k.character_id where k.recipe_id = r.id),
    'pending', (select count(*) from public.crafting_attempts a where a.recipe_id = r.id and a.status in ('pending', 'apply_failed')),
    'attempts', (select count(*) from public.crafting_attempts a where a.recipe_id = r.id))
  from public.crafting_recipes r where r.id = p_recipe;
$function$
;
CREATE OR REPLACE FUNCTION public.get_campaign_recipes(p_campaign uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
begin
  perform public._craft_dm_gate(p_campaign);
  return jsonb_build_object(
    'campaign_id', p_campaign,
    'enabled', public._gov_policy(p_campaign, 'inventory.craft'),
    'recipes', (select coalesce(jsonb_agg(public._craft_recipe_dm(r.id) order by (r.status = 'archived'), r.name, r.id), '[]')
                from public.crafting_recipes r where r.campaign_id = p_campaign),
    'characters', (select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'name', c.name) order by c.name, c.id), '[]')
                   from public.characters c where c.campaign_id = p_campaign));
end $function$
;
CREATE OR REPLACE FUNCTION public.dm_set_recipe_status(p_recipe uuid, p_status text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare r public.crafting_recipes;
begin
  select * into r from public.crafting_recipes where id = p_recipe for update;
  if r.id is null then raise exception 'Recipe not found' using errcode = 'P0002'; end if;
  perform public._craft_dm_gate(r.campaign_id);
  if p_status not in ('draft', 'published', 'archived') then raise exception 'Unknown status' using errcode = '22023'; end if;
  if p_status = 'published' and (not public._craft_item_ok(r.output_item_id, r.campaign_id)
      or exists (select 1 from public.crafting_recipe_ingredients g where g.recipe_id = r.id and g.item_id is not null
                 and not public._craft_item_ok(g.item_id, r.campaign_id))) then
    raise exception 'An item of this recipe is archived or not available in the campaign' using errcode = '22023';
  end if;
  -- results that arrive unidentified leave the players' catalog now (a DM action), never at a player's first craft
  if p_status = 'published' and not r.output_identified then
    update public.items set secret = true where id in (r.output_item_id, r.crit_output_item_id, r.failure_output_item_id)
      and owner_id is not null and not secret;
  end if;
  if r.status <> p_status then
    update public.crafting_recipes set status = p_status, revision = revision + 1, updated_by = auth.uid(), updated_at = now() where id = r.id;
    perform public._audit(r.campaign_id, null, 'recipe_changed', 'Crafting recipe ' || r.name || ': ' || p_status, null,
                          jsonb_build_object('recipe_id', r.id, 'status', p_status), null, null, 'dm');
  end if;
  return public._craft_recipe_dm(r.id);
end $function$
;
CREATE OR REPLACE FUNCTION public.dm_save_recipe(p_campaign uuid, p_recipe jsonb, p_expected_revision integer DEFAULT NULL::integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare o jsonb := coalesce(p_recipe, '{}'); r public.crafting_recipes; rid uuid; g jsonb; n int := 0; dc int; key text; out_item text;
  crit text; fail text; ident boolean; ing_item text; ing_tag text; qty int; t_item text;
begin
  perform public._craft_dm_gate(p_campaign);
  if jsonb_typeof(o) <> 'object' then raise exception 'The recipe must be an object' using errcode = '22023'; end if;
  if nullif(o ->> 'id', '') is not null then
    select * into r from public.crafting_recipes where id = (o ->> 'id')::uuid for update;
    if r.id is null or r.campaign_id <> p_campaign then raise exception 'Recipe not found' using errcode = 'P0002'; end if;
    if r.status = 'archived' then raise exception 'Restore the recipe before changing it' using errcode = '55000'; end if;
    if p_expected_revision is not null and p_expected_revision <> r.revision then
      raise exception 'Someone else changed this recipe meanwhile. Reload and try again.' using errcode = '40001';
    end if;
  end if;
  if length(btrim(coalesce(o ->> 'name', ''))) not between 1 and 120 then raise exception 'Give the recipe a name (up to 120 characters)' using errcode = '22023'; end if;
  out_item := nullif(btrim(coalesce(o ->> 'output_item_id', '')), '');
  crit := nullif(btrim(coalesce(o ->> 'crit_output_item_id', '')), '');
  fail := nullif(btrim(coalesce(o ->> 'failure_output_item_id', '')), '');
  if out_item is null then raise exception 'Choose what the recipe makes' using errcode = '22023'; end if;
  if not public._craft_item_ok(out_item, p_campaign) or (crit is not null and not public._craft_item_ok(crit, p_campaign))
     or (fail is not null and not public._craft_item_ok(fail, p_campaign)) then
    raise exception 'Choose an official item or an item of this campaign (not archived)' using errcode = '22023';
  end if;
  ident := coalesce((o ->> 'output_identified')::boolean, true);
  if not ident and exists (select 1 from public.items i where i.id = out_item and i.owner_id is null) then
    raise exception 'Copy an official item to campaign homebrew before its result can arrive unidentified' using errcode = '22023';
  end if;
  key := nullif(lower(btrim(coalesce(o ->> 'check_key', ''))), '');
  if key is not null and length(key) > 60 then raise exception 'Check name too long' using errcode = '22023'; end if;
  if jsonb_typeof(o -> 'check_dc') = 'number' then dc := (o ->> 'check_dc')::numeric::int;
  elsif nullif(o ->> 'check_dc', '') is not null then raise exception 'The DC must be a number from 1 to 40' using errcode = '22023'; end if;
  if dc is not null and dc not between 1 and 40 then raise exception 'The DC must be a number from 1 to 40' using errcode = '22023'; end if;
  if dc is not null and key is null then raise exception 'A DC needs a skill or tool to roll' using errcode = '22023'; end if;
  if dc is not null and not coalesce((o ->> 'requires_dm_approval')::boolean, true) then
    raise exception 'A recipe with a DC always needs your approval' using errcode = '22023';
  end if;
  if coalesce(o ->> 'visibility', 'known') not in ('known', 'discoverable', 'secret') then raise exception 'Unknown visibility' using errcode = '22023'; end if;
  if coalesce(o ->> 'failure_mode', 'keep') not in ('keep', 'lose_all', 'lose_half') then raise exception 'Unknown failure rule' using errcode = '22023'; end if;
  if jsonb_typeof(o -> 'ingredients') <> 'array' or jsonb_array_length(o -> 'ingredients') not between 1 and 20 then
    raise exception 'A recipe needs 1 to 20 ingredients' using errcode = '22023';
  end if;
  for g in select x from jsonb_array_elements(o -> 'ingredients') x loop
    ing_item := nullif(btrim(coalesce(g ->> 'item_id', '')), '');
    ing_tag := nullif(lower(btrim(coalesce(g ->> 'tag', ''))), '');
    if num_nonnulls(ing_item, ing_tag) <> 1 then raise exception 'Each ingredient is an item or a tag' using errcode = '22023'; end if;
    if ing_item is not null and not public._craft_item_ok(ing_item, p_campaign) then
      raise exception 'Choose an official item or an item of this campaign (not archived)' using errcode = '22023';
    end if;
    if ing_tag is not null and ing_tag !~ '^[a-z0-9][a-z0-9 _-]{0,39}$' then raise exception 'Tags use letters, digits, spaces, - and _ (up to 40)' using errcode = '22023'; end if;
    if coalesce(g ->> 'quantity', '1') !~ '^\d{1,2}$' or coalesce((g ->> 'quantity')::int, 1) not between 1 and 99 then
      raise exception 'Ingredient quantity 1 to 99' using errcode = '22023';
    end if;
  end loop;
  -- 20261114000900: recipe items
  if o ? 'teachers' then
    if jsonb_typeof(o -> 'teachers') <> 'array' or jsonb_array_length(o -> 'teachers') > 10 then
      raise exception 'Up to 10 recipe items' using errcode = '22023';
    end if;
    for g in select x from jsonb_array_elements(o -> 'teachers') x loop
      t_item := nullif(btrim(coalesce(g ->> 'item_id', '')), '');
      if t_item is null or not public._craft_item_ok(t_item, p_campaign) then
        raise exception 'A recipe item must be an official item or an item of this campaign (not archived)' using errcode = '22023';
      end if;
      if jsonb_typeof(g -> 'consumed') not in ('boolean', 'null') and g ? 'consumed' then
        raise exception 'Used up when read: true, false or empty' using errcode = '22023';
      end if;
    end loop;
  end if;

  if r.id is null then
    insert into public.crafting_recipes (campaign_id, name, output_item_id, updated_by) values (p_campaign, btrim(o ->> 'name'), out_item, auth.uid())
    returning * into r;
  end if;
  update public.crafting_recipes set
    name = btrim(o ->> 'name'), description = left(coalesce(o ->> 'description', ''), 2000),
    dm_notes = nullif(left(coalesce(o ->> 'dm_notes', ''), 2000), ''),
    visibility = coalesce(o ->> 'visibility', 'known'), output_item_id = out_item,
    output_quantity = least(greatest(coalesce((o ->> 'output_quantity')::int, 1), 1), 99),
    output_label = nullif(left(btrim(coalesce(o ->> 'output_label', '')), 120), ''), output_identified = ident,
    crit_output_item_id = crit, crit_bonus_quantity = least(greatest(coalesce((o ->> 'crit_bonus_quantity')::int, 0), 0), 99),
    failure_mode = coalesce(o ->> 'failure_mode', 'keep'), failure_output_item_id = fail,
    failure_output_quantity = least(greatest(coalesce((o ->> 'failure_output_quantity')::int, 1), 1), 99),
    check_key = key, check_dc = dc, requires_dm_approval = dc is not null or coalesce((o ->> 'requires_dm_approval')::boolean, true),
    time_note = nullif(left(btrim(coalesce(o ->> 'time_note', '')), 200), ''),
    revision = case when nullif(o ->> 'id', '') is null then 1 else revision + 1 end, updated_by = auth.uid(), updated_at = now()
  where id = r.id returning * into r;
  delete from public.crafting_recipe_ingredients where recipe_id = r.id;
  for g in select x from jsonb_array_elements(o -> 'ingredients') x loop
    n := n + 1;
    qty := coalesce((g ->> 'quantity')::int, 1);
    insert into public.crafting_recipe_ingredients (recipe_id, seq, item_id, ingredient_tag, label, quantity, consumed)
    values (r.id, n, nullif(btrim(coalesce(g ->> 'item_id', '')), ''), nullif(lower(btrim(coalesce(g ->> 'tag', ''))), ''),
            nullif(left(btrim(coalesce(g ->> 'label', '')), 120), ''), qty, coalesce((g ->> 'consumed')::boolean, true));
  end loop;
  if o ? 'teachers' then
    delete from public.crafting_recipe_teachers where recipe_id = r.id;   -- links only (DM data of this recipe; no item, no row)
    insert into public.crafting_recipe_teachers (recipe_id, item_id, consume_on_learn)
    select distinct on (btrim(x ->> 'item_id')) r.id, btrim(x ->> 'item_id'),
           coalesce(case when jsonb_typeof(x -> 'consumed') = 'boolean' then (x ->> 'consumed')::boolean end,
                    (select i.kind_id = 'scroll' from public.items i where i.id = btrim(x ->> 'item_id')), false)
    from jsonb_array_elements(o -> 'teachers') x;
  end if;
  if r.status = 'published' and not r.output_identified then
    update public.items set secret = true where id in (r.output_item_id, r.crit_output_item_id, r.failure_output_item_id)
      and owner_id is not null and not secret;
  end if;
  return public._craft_recipe_dm(r.id);
end $function$
;
-- the previous read policy of item_modifiers (20261015000900)
drop policy if exists "item_modifiers_read" on public.item_modifiers;
create policy "item_modifiers_read" on public.item_modifiers for select to anon, authenticated using (public.can_view_owned(owner_id, campaign_id));
-- helpers of 20261114001000 (after the restored bodies no longer call them)
drop function if exists public._character_modifier_effect_rows(uuid);
drop function if exists public._modifier_visible(text, uuid, uuid);
drop function if exists public._craft_modifier_dm(text);
drop function if exists public._modifier_effects_json(text);
drop function if exists public._craft_modifier_ok(text, uuid);
drop function if exists public._craft_base_refusal(uuid, text);
drop function if exists public._craft_teacher_ok(text, uuid);
-- schema (only defaults are held here, see the guard)
drop index if exists public.crafting_recipe_ingredients_one_base;
alter table public.crafting_recipe_ingredients drop constraint if exists crafting_recipe_ingredients_base_check;
alter table public.crafting_recipe_ingredients drop column if exists is_base;
alter table public.crafting_recipes drop constraint if exists crafting_recipes_kind_check;
drop index if exists public.crafting_recipes_modifier;
alter table public.crafting_recipes drop column if exists enhance_modifier_id;
alter table public.crafting_recipes drop column if exists kind;
alter table public.crafting_recipes alter column output_item_id set not null;
