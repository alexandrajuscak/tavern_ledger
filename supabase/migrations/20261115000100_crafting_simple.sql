-- =============================================================================
-- Simple crafting (T8, docs/CRAFTING_V1.md "Simple crafting (?v=42)"). Additive on top of 20261114001000_weapon_enhancement;
-- rollback supabase/rollback/rollback_crafting_simple.sql (exact previous bodies; it REFUSES, changing nothing, once an attempt
-- with more than one batch exists).
--  1. crafting_attempts.batches (1..20, default 1): one attempt crafts the recipe N times. Every existing row is 1, so every
--     existing attempt (also the production one) behaves exactly as before. _craft_apply reads it: every used-up line needs
--     N x quantity, a kept line (a tool, the enhancement base) once; the result is N x output_quantity (+ the critical bonus once:
--     one roll for the whole batch), a failure's junk result N x. All N or nothing (one transaction, one request id).
--     "Lose half" is computed per ingredient line (floor(line total / 2), across its stacks in selection order), not per stack, for
--     every attempt: the loss no longer depends on how a line is split over stacks.
--  2. start_craft_batch(character, recipe, selected, batches, roll, request_id, natural, note): a NEW function (the old
--     start_craft_attempt keeps its signature and body; an overload with a defaulted extra argument would make the old 7-argument
--     call ambiguous). Same checks and order as start_craft_attempt (knowledge first with the one fixed text, fit, quantity, free,
--     base, tool, one pending attempt per character and recipe, 4242 locks before the first write, idempotent on request_id),
--     plus: a roll is required only when the recipe has a DC (a tool without a DC only has to be carried); a natural 20 / 1 only
--     with a DC; an enhancement recipe one at a time.
--  3. "Items with their own charges are never used up": _craft_row_free (start, apply, learn) and the free flag of the player
--     read also exclude a row with charges (charges_max / charges_current > 0) or whose item has its own uses (a per-rest spell
--     grant, a weapon action with uses). Kept lines (tools, the base) are unchanged.
--  4. _craft_attempt_dm also lists batches (the DM sees "x N" in the queue).
-- No recipe, known-recipe or attempt row is changed; no column default of crafting_recipes is changed (new recipes default to
-- instant in the editor, not in the table). No new table, no cache / Realtime change (crafting_attempts keeps its bump trigger).
-- =============================================================================
set lock_timeout = '5s';

-- ---- 1. schema -----------------------------------------------------------------------------------------------------------------
alter table public.crafting_attempts add column if not exists batches int not null default 1;
alter table public.crafting_attempts drop constraint if exists crafting_attempts_batches_check;
alter table public.crafting_attempts add constraint crafting_attempts_batches_check check (batches between 1 and 20);

-- ---- 2. charges ----------------------------------------------------------------------------------------------------------------
-- does an item have its own uses (a spell it casts N times per rest, a weapon action with uses)? Such an item is never used up.
create or replace function public._craft_item_has_uses(p_item text)
returns boolean language sql stable security definer set search_path = public, pg_temp as $$
  select p_item is not null
     and (exists (select 1 from public.item_spell_grants g where g.item_id = p_item and g.casting = 'per_rest')
          or exists (select 1 from public.item_weapon_blocks b where b.item_id = p_item and b.uses is not null));
$$;

-- body of 20261113000100 + 20261115000100: never a row with charges or an item with its own uses
create or replace function public._craft_row_free(p_row uuid)
returns boolean
language sql stable security definer
set search_path = public, pg_temp
as $$
  select exists (select 1 from public.inventory_items ii where ii.id = p_row and not ii.is_attuned and not ii.is_quest_item
                   and coalesce(ii.charges_max, 0) <= 0 and coalesce(ii.charges_current, 0) <= 0
                   and not public._craft_item_has_uses(ii.item_id))
     and not exists (select 1 from public.character_equipment e where e.inventory_item_id = p_row)
     and not exists (select 1 from public.inventory_items c where c.container_item_id = p_row);
$$;

-- ---- 3. the player read: body of 20261114001000, the free flag also excludes charged rows ---------------------------------------
create or replace function public._craft_recipes_player(p_character uuid, p_recipe uuid default null)
returns table (recipe_id uuid, recipe_name text, j jsonb)
language sql stable security definer set search_path = public, pg_temp as $$
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
                    and not exists (select 1 from public.inventory_items c where c.container_item_id = ii.id)
                    -- 20261115000100: an item with its own charges / uses is never used up
                    and coalesce(ii.charges_max, 0) <= 0 and coalesce(ii.charges_current, 0) <= 0
                    and not public._craft_item_has_uses(ii.item_id), false) as free
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
$$;

-- ---- 4. apply: body of 20261114001000 + batches ---------------------------------------------------------------------------------
create or replace function public._craft_apply(p_attempt uuid, p_outcome text, p_failure_consumes text)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare a public.crafting_attempts; r public.crafting_recipes; g public.crafting_recipe_ingredients; s jsonb; ir public.inventory_items;
  inv_char uuid; inv_kind text; q int; mode text; consumed jsonb := '[]'; produced jsonb := '[]'; meta jsonb; out_item text; out_qty int;
  covered int; base_row uuid; why text; mname text; half jsonb := '{}';
begin
  select * into a from public.crafting_attempts where id = p_attempt;
  select * into r from public.crafting_recipes where id = a.recipe_id;
  -- 20261114000900: the per-item locks before any row lock (the callers took them before their first write already)
  perform public._craft_lock_items(a.selected, r.id);
  if not exists (select 1 from public.characters c where c.id = a.character_id and c.campaign_id = r.campaign_id) then
    raise exception 'The character is no longer in this campaign' using errcode = 'TLCRF';
  end if;
  if r.kind = 'enhancement' and a.batches <> 1 then
    raise exception 'The ingredients no longer fit the recipe (it was changed)' using errcode = 'TLCRF';
  end if;
  perform public._rpc_begin();
  perform 1 from public.inventory_items where id in (select (x ->> 'inventory_item_id')::uuid from jsonb_array_elements(a.selected) x)
    order by id for update;
  for g in select * from public.crafting_recipe_ingredients where recipe_id = r.id order by seq loop
    select coalesce(sum((x ->> 'quantity')::int), 0) into covered from jsonb_array_elements(a.selected) x where (x ->> 'seq')::int = g.seq;
    -- 20261115000100: a batch of N needs N times every used-up line; a kept line (a tool, the base) once
    if covered <> g.quantity * (case when g.consumed then a.batches else 1 end) then
      raise exception 'The ingredients no longer fit the recipe (it was changed)' using errcode = 'TLCRF';
    end if;
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
      raise exception 'An ingredient is equipped, attuned, a quest item, has charges or is a container with contents' using errcode = 'TLCRF';
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
  -- 20261115000100: "lose half" is per ingredient LINE: floor(the line's selected total / 2), taken from the line's stacks in the
  -- order of the selection, so the loss does not depend on how the line is split over stacks (six 1-stacks lose 3 like one 6-stack)
  if mode = 'lose_half' then
    select coalesce(jsonb_object_agg(t.seq, t.total / 2), '{}') into half
    from (select (x ->> 'seq') as seq, sum((x ->> 'quantity')::int) as total from jsonb_array_elements(a.selected) x group by 1) t;
  end if;
  for s in select x from jsonb_array_elements(a.selected) with ordinality e(x, ord)
           order by case when mode = 'lose_half' then (x ->> 'seq')::int else 0 end, case when mode = 'lose_half' then ord else 0 end,
                    (x ->> 'inventory_item_id') loop
    select * into g from public.crafting_recipe_ingredients where recipe_id = r.id and seq = (s ->> 'seq')::int;
    continue when not g.consumed;
    if mode = 'lose_half' then
      q := least((s ->> 'quantity')::int, coalesce((half ->> (s ->> 'seq'))::int, 0));
      half := jsonb_set(half, array[s ->> 'seq'], to_jsonb(coalesce((half ->> (s ->> 'seq'))::int, 0) - q));
    else
      q := case mode when 'lose_all' then (s ->> 'quantity')::int else 0 end;
    end if;
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
    -- 20261115000100: N batches make N results; the critical bonus is added once (one roll for the whole batch)
    out_qty := r.output_quantity * a.batches + case when p_outcome = 'critical_success' then r.crit_bonus_quantity else 0 end;
  else
    out_item := r.failure_output_item_id;
    out_qty := r.failure_output_quantity * a.batches;
  end if;
  if out_item is not null then
    produced := produced || jsonb_build_array(public._craft_produce(a.inventory_id, a.character_id, out_item, out_qty, r.output_identified, meta));
  end if;
  perform public._rpc_end();
  return jsonb_build_object('consumed', consumed, 'produced', produced);
end $$;

-- ---- 5. the simple start: body of start_craft_attempt (20261114001000) + batches, a roll only with a DC ---------------------------
create or replace function public.start_craft_batch(p_character uuid, p_recipe uuid, p_selected jsonb, p_batches int default 1,
                                         p_roll_total int default null, p_request_id uuid default null, p_natural text default null,
                                         p_note text default null)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare ch public.characters; rc public.crafting_recipes; a public.crafting_attempts; inv uuid; s jsonb; g public.crafting_recipe_ingredients;
  ir public.inventory_items; norm jsonb := '[]'; ids uuid[] := '{}'; covered int; res jsonb; inv_char uuid; inv_kind text; q int; why text;
begin
  if p_request_id is null then raise exception 'A request id is required' using errcode = '22023'; end if;
  ch := public._craft_player_gate(p_character);
  select * into a from public.crafting_attempts where character_id = ch.id and request_id = p_request_id;
  if a.id is not null then return public._craft_attempt_player(a) || jsonb_build_object('replayed', true, 'batches', a.batches); end if;
  if p_batches is null or p_batches not between 1 and 20 then raise exception 'Craft 1 to 20 at a time' using errcode = '22023'; end if;
  select * into rc from public.crafting_recipes where id = p_recipe;
  if not public._craft_recipe_visible(ch.id, p_recipe) then raise exception 'Recipe not found' using errcode = 'P0002'; end if;
  -- 20261114001000 (review m3): a natural 20 / 1 belongs to a roll; a recipe without a check has none (refused, never stored)
  -- 20261115000100: the simple flow asks for a roll only when the recipe has a DC (a tool without a DC is only needed in the bag)
  if p_natural is not null and rc.check_dc is null then raise exception 'This recipe has no roll' using errcode = '22023'; end if;
  if rc.kind = 'enhancement' and p_batches <> 1 then raise exception 'An enhancement is crafted one at a time' using errcode = '22023'; end if;
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
  -- knowledge FIRST, for every selected row (the base too), with one fixed message (it never says "matches" or "does not match")
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
      raise exception 'Equipped, attuned or quest items, items with charges and containers with contents cannot be used up' using errcode = '22023';
    end if;
    -- 20261114001000: the base of an enhancement (kept): a single item that can take the enhancement
    if g.is_base then
      why := public._craft_base_refusal(ir.id, rc.enhance_modifier_id);
      if why is not null then raise exception '%', why using errcode = '22023'; end if;
    end if;
  end loop;
  for g in select * from public.crafting_recipe_ingredients where recipe_id = rc.id order by seq loop
    select coalesce(sum((x ->> 'quantity')::int), 0) into covered from jsonb_array_elements(norm) x where (x ->> 'seq')::int = g.seq;
    if covered <> g.quantity * (case when g.consumed then p_batches else 1 end) then
      raise exception 'Choose exactly what the recipe needs for each ingredient' using errcode = '22023';
    end if;
  end loop;
  -- 20261114000900: the tool the check needs must be carried (a known row)
  if not public._craft_tool_ok(ch.id, rc.check_key) then
    raise exception 'You need % for this recipe', public._identify_check_label(rc.check_key) using errcode = '22023';
  end if;
  if rc.check_dc is not null and (p_roll_total is null or p_roll_total < -10 or p_roll_total > 60) then
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
                                          player_note, request_id, auto, batches)
    values (ch.id, rc.id, rc.revision, inv, norm, p_roll_total, p_natural, nullif(left(btrim(coalesce(p_note, '')), 500), ''), p_request_id,
            not rc.requires_dm_approval and rc.check_dc is null, p_batches)
    on conflict (character_id, request_id) do nothing
    returning * into a;
  exception when unique_violation then
    raise exception 'Your DM has not answered your last attempt at this recipe yet' using errcode = '55000';
  end;
  if a.id is null then
    select * into a from public.crafting_attempts where character_id = ch.id and request_id = p_request_id;
    return public._craft_attempt_player(a) || jsonb_build_object('replayed', true, 'batches', a.batches);
  end if;
  if a.auto then
    res := public._craft_apply(a.id, 'success', null);
    update public.crafting_attempts set status = 'applied', outcome = 'success', consumed = res -> 'consumed', produced = res -> 'produced',
           resolved_at = now(), revision = revision + 1 where id = a.id returning * into a;
  end if;
  perform public._craft_audit(a);
  perform public._identify_touch(ch.id);
  return public._craft_attempt_player(a) || jsonb_build_object('batches', a.batches);
end $$;

-- ---- 6. the DM's view of an attempt: body of 20261114000900 + batches -------------------------------------------------------------
create or replace function public._craft_attempt_dm(a public.crafting_attempts)
returns jsonb
language sql stable security definer
set search_path = public, pg_temp
as $$
  select public._craft_attempt_player(a) || jsonb_build_object(
    'character_id', a.character_id, 'character_name', ch.name, 'recipe_revision', a.recipe_revision, 'current_revision', r.revision,
    'check_key', r.check_key, 'check_label', case when r.check_key is not null then public._identify_check_label(r.check_key) end,
    'check_dc', r.check_dc, 'failure_mode', r.failure_mode, 'failure_consumes', a.failure_consumes, 'dm_private_note', a.dm_private_note,
    'apply_error', a.apply_error, 'consumed_detail', coalesce(a.consumed, '[]'), 'produced_detail', coalesce(a.produced, '[]'),
    'suggested_outcome', public._craft_suggest(coalesce(a.dm_roll_total, a.roll_total), a.natural_roll, r.check_dc),
    'tool_ok', public._craft_tool_ok(a.character_id, r.check_key),
    'batches', a.batches,   -- 20261115000100
    'selected', (select coalesce(jsonb_agg(jsonb_build_object('seq', (s ->> 'seq')::int, 'inventory_item_id', s ->> 'inventory_item_id',
                    'quantity', (s ->> 'quantity')::int, 'shown_name', coalesce(nullif(ii.custom_name, ''), ii.name),
                    'true_name', it.name, 'item_id', ii.item_id, 'have', ii.quantity, 'known', ii.id is not null and public._craft_row_known(ii.id))
                    order by (s ->> 'seq')::int, s ->> 'inventory_item_id'), '[]')
                 from jsonb_array_elements(a.selected) s
                 left join public.inventory_items ii on ii.id = (s ->> 'inventory_item_id')::uuid
                 left join public.items it on it.id = ii.item_id),
    'resolved_by_name', (select p.display_name from public.profiles p where p.id = a.resolved_by))
  from public.crafting_recipes r, public.characters ch where r.id = a.recipe_id and ch.id = a.character_id;
$$;

-- ---- 7. grants -----------------------------------------------------------------------------------------------------------------
revoke all on function public._craft_item_has_uses(text) from public, anon, authenticated;
revoke all on function public.start_craft_batch(uuid, uuid, jsonb, int, int, uuid, text, text) from public, anon;
grant execute on function public.start_craft_batch(uuid, uuid, jsonb, int, int, uuid, text, text) to authenticated, service_role;

reset lock_timeout;
