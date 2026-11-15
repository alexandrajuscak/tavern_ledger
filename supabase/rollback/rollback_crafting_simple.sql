-- =============================================================================
-- Rollback of 20261115000100_crafting_simple.sql. Run as postgres in ONE transaction:
--   psql -v ON_ERROR_STOP=1 -1 -f supabase/rollback/rollback_crafting_simple.sql
-- Restores the exact previous bodies (pg_get_functiondef from the local database at 20261114001100) of the four replaced
-- functions (_craft_row_free, _craft_recipes_player, _craft_apply, _craft_attempt_dm), drops start_craft_batch and
-- _craft_item_has_uses, and drops crafting_attempts.batches with its check (the schema_migrations row of 20261115000100 is removed
-- by the operator, as for earlier rollbacks).
-- GUARD: it REFUSES (raises, nothing changed) once any attempt has batches <> 1: the restored _craft_apply would use up one batch
-- and produce one result for a pending N-batch attempt, and the history would lose N. No recipe, known-recipe or attempt row is
-- changed or deleted by this file; the operator decides (for example answer / reject the pending batch attempts first and keep
-- the migration). Without such attempts the dropped column holds only its default 1, so nothing is lost.
-- Deploy order for a rollback: the previous frontend (?v=41) first, then this file.
-- =============================================================================
set local lock_timeout = '5s';
do $$
declare found boolean := false;
begin
  -- dynamic: the column is gone after a first rollback (a second run is a no-op)
  if exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'crafting_attempts' and column_name = 'batches') then
    execute 'select exists (select 1 from public.crafting_attempts where batches <> 1)' into found;
  end if;
  if found then
    raise exception 'rollback_crafting_simple: attempts with several batches exist; nothing was changed (keep the migration, or decide per attempt)';
  end if;
end $$;
drop function if exists public.start_craft_batch(uuid, uuid, jsonb, int, int, uuid, text, text);

CREATE OR REPLACE FUNCTION public._craft_row_free(p_row uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select exists (select 1 from public.inventory_items ii where ii.id = p_row and not ii.is_attuned and not ii.is_quest_item)
     and not exists (select 1 from public.character_equipment e where e.inventory_item_id = p_row)
     and not exists (select 1 from public.inventory_items c where c.container_item_id = p_row);
$function$
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
  lines as (select g.*, rc.enhance_modifier_id as emod from public.crafting_recipe_ingredients g join rc on rc.id = g.recipe_id),
  tag_pairs as (
    select distinct x.item_id, lower(btrim(t)) as tag
    from (select distinct w.item_id from rws w) x join public.items i on i.id = x.item_id
    cross join lateral jsonb_array_elements_text(case when jsonb_typeof(i.details -> 'ingredient_tags') = 'array'
                                                      then i.details -> 'ingredient_tags' else '[]'::jsonb end) t
    where exists (select 1 from lines l where l.ingredient_tag is not null)
      and public._craft_item_trusted(x.item_id, (select ch.campaign_id from ch))),
  cand as materialized (
    select g.id as gid, w.id, w.nm, w.quantity from lines g join rws w on w.item_id = g.item_id
     where g.item_id is not null and (not g.consumed or w.free) and (not g.is_base or public._craft_base_refusal(w.id, g.emod) is null)
    union all
    select g.id, w.id, w.nm, w.quantity from lines g join tag_pairs p on p.tag = g.ingredient_tag join rws w on w.item_id = p.item_id
     where g.item_id is null and (not g.consumed or w.free) and (not g.is_base or public._craft_base_refusal(w.id, g.emod) is null)),
  agg as materialized (
    select c.gid, sum(c.quantity)::int as have,
           jsonb_agg(jsonb_build_object('inventory_item_id', c.id, 'name', c.nm, 'quantity', c.quantity) order by c.nm, c.id) as list
    from cand c group by c.gid),
  known_items as materialized (
    select x.item_id, public._craft_item_known(p_character, x.item_id) as known
    from (select rc.output_item_id as item_id from rc where rc.output_item_id is not null
          union select l.item_id from lines l where l.item_id is not null) x),
  ings as materialized (
    select g.recipe_id, jsonb_agg(jsonb_build_object(
      'seq', g.seq, 'quantity', g.quantity, 'consumed', g.consumed, 'tag', g.ingredient_tag,
      'label', case when g.item_id is null then coalesce(nullif(btrim(g.label), ''), 'Any ingredient tagged “' || g.ingredient_tag || '”')
                    when ki.known then (select i.name from public.items i where i.id = g.item_id)
                    else coalesce(nullif(btrim(g.label), ''), 'An unknown ingredient') end,
      'item_id', case when g.item_id is not null and ki.known then g.item_id end,
      'have', coalesce(a.have, 0), 'candidates', coalesce(a.list, '[]'::jsonb))
      || case when g.is_base then '{"base": true}'::jsonb else '{}'::jsonb end order by g.seq) as list
    from lines g left join known_items ki on ki.item_id = g.item_id left join agg a on a.gid = g.id
    group by g.recipe_id)
  select rc.id, rc.name, jsonb_build_object(
    'recipe_id', rc.id, 'name', rc.name, 'description', rc.description, 'time_note', rc.time_note,
    'source', case when rc.learned then 'learned' else 'known' end,
    'new', rc.learned and rc.kn_seen is null,
    'output', case when rc.kind = 'enhancement' then
                jsonb_build_object('enhancement', true, 'quantity', 1, 'item_id', null, 'kind_id', null,
                                   'known', nullif(btrim(rc.output_label), '') is null,
                                   'name', coalesce(nullif(btrim(rc.output_label), ''), md.name),
                                   'description', case when nullif(btrim(rc.output_label), '') is null then md.description end,
                                   'effects', case when nullif(btrim(rc.output_label), '') is null then public._modifier_effects_json(md.id) else '[]'::jsonb end)
              else jsonb_build_object('name', case when ko.known then it.name
                                              else coalesce(nullif(btrim(rc.output_label), ''), (select d.name from public._item_decoy(rc.output_item_id) d)) end,
                                 'item_id', case when ko.known then it.id end, 'kind_id', case when ko.known then it.kind_id end,
                                 'quantity', rc.output_quantity, 'known', ko.known) end,
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
    || case when rc.kind = 'enhancement' then '{"kind": "enhancement"}'::jsonb else '{}'::jsonb end
  from rc
  left join public.items it on it.id = rc.output_item_id
  left join public.item_modifiers md on md.id = rc.enhance_modifier_id
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
  covered int; base_row uuid; why text; mname text;
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
    -- 20261114001000: the base of an enhancement
    if g.is_base then
      if r.kind <> 'enhancement' then raise exception 'The ingredients no longer fit the recipe (it was changed)' using errcode = 'TLCRF'; end if;
      why := public._craft_base_refusal(ir.id, r.enhance_modifier_id);
      if why is not null then raise exception '%', why using errcode = 'TLCRF'; end if;
      base_row := ir.id;
    end if;
  end loop;
  if r.kind = 'enhancement' and base_row is null then
    raise exception 'The ingredients no longer fit the recipe (it was changed)' using errcode = 'TLCRF';
  end if;
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
  if r.kind = 'enhancement' then
    -- success and critical success attach the enhancement to the base row itself (a critical success has success semantics)
    if p_outcome in ('success', 'critical_success') then
      select * into ir from public.inventory_items where id = base_row;
      select name into mname from public.item_modifiers where id = r.enhance_modifier_id;
      insert into public.inventory_item_modifiers (inventory_item_id, modifier_id) values (base_row, r.enhance_modifier_id);
      perform public.log_inventory_event(ir.inventory_id, ir.id, 'apply_modifier', null, ir.item_id,
        meta || jsonb_build_object('modifier_id', r.enhance_modifier_id, 'via', 'craft', 'name', coalesce(nullif(ir.custom_name, ''), ir.name)));
      produced := jsonb_build_array(jsonb_build_object('inventory_item_id', ir.id, 'item_id', ir.item_id,
        'name', coalesce(nullif(ir.custom_name, ''), ir.name) || ' (' || mname || ')', 'quantity', 1, 'identified', true,
        'enhanced', true, 'modifier_id', r.enhance_modifier_id));
    end if;
    out_item := case when p_outcome in ('success', 'critical_success') then null else r.failure_output_item_id end;
    out_qty := r.failure_output_quantity;
  elsif p_outcome in ('success', 'critical_success') then
    out_item := case when p_outcome = 'critical_success' then coalesce(r.crit_output_item_id, r.output_item_id) else r.output_item_id end;
    out_qty := r.output_quantity + case when p_outcome = 'critical_success' then r.crit_bonus_quantity else 0 end;
  else
    out_item := r.failure_output_item_id;
    out_qty := r.failure_output_quantity;
  end if;
  if out_item is not null then
    produced := produced || jsonb_build_array(public._craft_produce(a.inventory_id, a.character_id, out_item, out_qty, r.output_identified, meta));
  end if;
  perform public._rpc_end();
  return jsonb_build_object('consumed', consumed, 'produced', produced);
end $function$
;

CREATE OR REPLACE FUNCTION public._craft_attempt_dm(a crafting_attempts)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select public._craft_attempt_player(a) || jsonb_build_object(
    'character_id', a.character_id, 'character_name', ch.name, 'recipe_revision', a.recipe_revision, 'current_revision', r.revision,
    'check_key', r.check_key, 'check_label', case when r.check_key is not null then public._identify_check_label(r.check_key) end,
    'check_dc', r.check_dc, 'failure_mode', r.failure_mode, 'failure_consumes', a.failure_consumes, 'dm_private_note', a.dm_private_note,
    'apply_error', a.apply_error, 'consumed_detail', coalesce(a.consumed, '[]'), 'produced_detail', coalesce(a.produced, '[]'),
    'suggested_outcome', public._craft_suggest(coalesce(a.dm_roll_total, a.roll_total), a.natural_roll, r.check_dc),
    'tool_ok', public._craft_tool_ok(a.character_id, r.check_key),
    'selected', (select coalesce(jsonb_agg(jsonb_build_object('seq', (s ->> 'seq')::int, 'inventory_item_id', s ->> 'inventory_item_id',
                    'quantity', (s ->> 'quantity')::int, 'shown_name', coalesce(nullif(ii.custom_name, ''), ii.name),
                    'true_name', it.name, 'item_id', ii.item_id, 'have', ii.quantity, 'known', ii.id is not null and public._craft_row_known(ii.id))
                    order by (s ->> 'seq')::int, s ->> 'inventory_item_id'), '[]')
                 from jsonb_array_elements(a.selected) s
                 left join public.inventory_items ii on ii.id = (s ->> 'inventory_item_id')::uuid
                 left join public.items it on it.id = ii.item_id),
    'resolved_by_name', (select p.display_name from public.profiles p where p.id = a.resolved_by))
  from public.crafting_recipes r, public.characters ch where r.id = a.recipe_id and ch.id = a.character_id;
$function$
;

drop function if exists public._craft_item_has_uses(text);
alter table public.crafting_attempts drop constraint if exists crafting_attempts_batches_check;
alter table public.crafting_attempts drop column if exists batches;
