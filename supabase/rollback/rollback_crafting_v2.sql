-- =============================================================================
-- Rollback of 20261114000900_crafting_v2.sql. Run as postgres in ONE transaction:
--   psql -v ON_ERROR_STOP=1 -1 -f supabase/rollback/rollback_crafting_v2.sql
-- Restores the exact previous bodies (pg_get_functiondef from the local database at 20261114000800) of the nine replaced
-- functions and drops the new functions (the schema_migrations row of 20261114000900 is removed by the operator, as for earlier rollbacks).
-- No row is changed or deleted:
-- * KEPT on purpose: the table crafting_recipe_teachers (the DM's recipe-item links; unused by the v1 functions, RLS on, no grants;
--   the migration re-creates it with "if not exists") and the widened CHECK of character_known_recipes.source ('manual' allowed):
--   recipes learned from items stay learned (v1 reads them like a DM grant). Re-applying the migration is safe.
-- * KEPT: inventory changes of learned / crafted items (ordinary rows and inventory_events).
-- Deploy order for a rollback: the previous frontend (?v=36) first, then this file.
-- =============================================================================
set local lock_timeout = '5s';
drop function if exists public.learn_recipe_from_item(uuid);
drop function if exists public.get_inventory_item_recipes(uuid);
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
  if not exists (select 1 from public.characters c where c.id = a.character_id and c.campaign_id = r.campaign_id) then
    raise exception 'The character is no longer in this campaign' using errcode = 'TLCRF';
  end if;
  perform public._rpc_begin();
  perform 1 from public.inventory_items where id in (select (x ->> 'inventory_item_id')::uuid from jsonb_array_elements(a.selected) x)
    order by id for update;
  -- every ingredient line still covered by the selection, every selected row still there, known, fitting and free
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

  mode := case when p_outcome in ('success', 'critical_success') then 'lose_all'
               when p_outcome = 'critical_failure' then 'lose_all'
               else coalesce(p_failure_consumes, r.failure_mode) end;
  meta := jsonb_build_object('craft_attempt', a.id, 'recipe', r.id, 'outcome', p_outcome);
  -- consume (rows in id order)
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
  -- produce
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
CREATE OR REPLACE FUNCTION public._craft_produce(p_inventory uuid, p_character uuid, p_item text, p_quantity integer, p_identified boolean, p_meta jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare it public.items; ck public.character_item_knowledge; d record; nm text; ds text; remaining int := greatest(coalesce(p_quantity, 1), 1);
  chunk int; rid uuid; last_id uuid; plain boolean;
begin
  select * into it from public.items where id = p_item;
  if it.id is null or it.archived_at is not null then
    raise exception 'The result of this recipe is no longer available' using errcode = 'TLCRF';
  end if;
  -- lock order: the caller holds the ingredient rows; examine holds a row, then the character, the record, the other rows. Taking
  -- the character's rows of the result and its record WITHOUT waiting means a crossing examine can never deadlock with an
  -- approval: a busy lock raises TLCRF (the caller's savepoint rolls back every partial write -> apply_failed, the DM retries).
  begin
    perform 1 from public.inventory_items ii join public.inventories inv on inv.id = ii.inventory_id
     where inv.character_id = p_character and ii.item_id = p_item order by ii.id for update of ii nowait;
    perform 1 from public.character_item_knowledge where character_id = p_character and item_id = p_item for update nowait;
  exception when lock_not_available then
    raise exception 'The player is busy with this item right now (examining it); try again in a moment' using errcode = 'TLCRF';
  end;
  select * into ck from public.character_item_knowledge where character_id = p_character and item_id = p_item;
  plain := coalesce(p_identified, true) or coalesce(ck.state = 'identified', false) or it.owner_id is null;   -- official rows are never disguised
  if plain then
    if it.secret and ((ck.character_id is not null and ck.state <> 'identified')
                      or exists (select 1 from public.inventory_items ii join public.inventories inv on inv.id = ii.inventory_id
                                 join public.inventory_item_knowledge k on k.inventory_item_id = ii.id
                                 where inv.character_id = p_character and ii.item_id = p_item and k.state <> 'identified')) then
      perform public._identify_apply(p_character, p_item, '{all}');   -- they made it: they know it (record + other copies)
    end if;
    while remaining > 0 loop
      chunk := case when it.stackable then least(remaining, coalesce(it.stack_max, remaining)) else 1 end;
      insert into public.inventory_items (inventory_id, item_id, quantity) values (p_inventory, p_item, chunk) returning id into rid;
      last_id := public._try_auto_merge(rid);
      remaining := remaining - chunk;
    end loop;
    nm := it.name;
  else
    update public.items set secret = true where id = p_item and not secret;   -- as _dm_add_item (campaign items only, see above)
    select * into d from public._item_decoy(p_item);
    nm := case when 'name' = any (coalesce(ck.revealed, '{}')) then it.name else d.name end;
    ds := case when 'description' = any (coalesce(ck.revealed, '{}')) then coalesce(it.description, '') else d.description end;
    while remaining > 0 loop
      chunk := case when it.stackable then least(remaining, coalesce(it.stack_max, remaining)) else 1 end;
      insert into public.inventory_items (inventory_id, item_id, quantity, name, description) values (p_inventory, p_item, chunk, nm, ds)
      returning id into rid;
      insert into public.inventory_item_knowledge (inventory_item_id, state, revealed, true_name, updated_by)
      values (rid, coalesce(ck.state, 'unidentified'), coalesce(ck.revealed, '{}'), it.name, auth.uid());
      last_id := public._try_auto_merge(rid);
      remaining := remaining - chunk;
    end loop;
    insert into public.character_item_knowledge (character_id, item_id, state, revealed, updated_by)
    values (p_character, p_item, 'unidentified', '{}', auth.uid()) on conflict (character_id, item_id) do nothing;
  end if;
  perform public.log_inventory_event(p_inventory, last_id, 'add', greatest(coalesce(p_quantity, 1), 1), p_item,
    coalesce(p_meta, '{}') || jsonb_build_object('via', 'craft', 'name', nm, 'unidentified', not plain));
  return jsonb_build_object('inventory_item_id', last_id, 'item_id', p_item, 'name', nm, 'quantity', greatest(coalesce(p_quantity, 1), 1), 'identified', plain);
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
    'ingredients', (select coalesce(jsonb_agg(jsonb_build_object('seq', g.seq, 'item_id', g.item_id, 'item_name', i.name, 'item_secret', i.secret,
                       'tag', g.ingredient_tag, 'label', g.label, 'quantity', g.quantity, 'consumed', g.consumed) order by g.seq), '[]')
                    from public.crafting_recipe_ingredients g left join public.items i on i.id = g.item_id where g.recipe_id = r.id),
    'known_by', (select coalesce(jsonb_agg(jsonb_build_object('character_id', k.character_id, 'name', c.name, 'seen', k.seen_at is not null) order by c.name), '[]')
                 from public.character_known_recipes k join public.characters c on c.id = k.character_id where k.recipe_id = r.id),
    'pending', (select count(*) from public.crafting_attempts a where a.recipe_id = r.id and a.status in ('pending', 'apply_failed')),
    'attempts', (select count(*) from public.crafting_attempts a where a.recipe_id = r.id))
  from public.crafting_recipes r where r.id = p_recipe;
$function$
;
CREATE OR REPLACE FUNCTION public._craft_recipe_player(p_character uuid, p_recipe uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare rc public.crafting_recipes; ch public.characters; kn public.character_known_recipes; it public.items; known boolean;
  ings jsonb; d record;
begin
  select * into ch from public.characters where id = p_character;
  select * into rc from public.crafting_recipes where id = p_recipe;
  if rc.id is null or ch.campaign_id is null or rc.campaign_id <> ch.campaign_id or rc.status <> 'published' then return null; end if;
  select * into kn from public.character_known_recipes where character_id = p_character and recipe_id = p_recipe;
  if rc.visibility <> 'known' and kn.character_id is null then return null; end if;
  select * into it from public.items where id = rc.output_item_id;
  known := public._craft_item_known(p_character, rc.output_item_id);
  select * into d from public._item_decoy(rc.output_item_id);
  select coalesce(jsonb_agg(x.j order by x.seq), '[]') into ings from (
    select g.seq, jsonb_build_object(
      'seq', g.seq, 'quantity', g.quantity, 'consumed', g.consumed, 'tag', g.ingredient_tag,
      'label', case when g.item_id is null then coalesce(nullif(btrim(g.label), ''), 'Any ingredient tagged “' || g.ingredient_tag || '”')
                    when gk.known then (select i.name from public.items i where i.id = g.item_id)
                    else coalesce(nullif(btrim(g.label), ''), 'An unknown ingredient') end,
      'item_id', case when g.item_id is not null and gk.known then g.item_id end,
      'have', coalesce(c.have, 0), 'candidates', coalesce(c.list, '[]')) as j
    from public.crafting_recipe_ingredients g
    cross join lateral (select g.item_id is null or public._craft_item_known(p_character, g.item_id) as known) gk
    left join lateral (
      select sum(ii.quantity)::int as have,
             jsonb_agg(jsonb_build_object('inventory_item_id', ii.id, 'name', coalesce(nullif(ii.custom_name, ''), ii.name), 'quantity', ii.quantity)
                       order by coalesce(nullif(ii.custom_name, ''), ii.name), ii.id) as list
      from public.inventory_items ii join public.inventories inv on inv.id = ii.inventory_id
      where inv.character_id = p_character and inv.kind = 'character'
        and public._craft_row_known(ii.id) and public._craft_row_matches(ii.item_id, g)
        and (not g.consumed or public._craft_row_free(ii.id))) c on true
    where g.recipe_id = rc.id) x;
  return jsonb_build_object(
    'recipe_id', rc.id, 'name', rc.name, 'description', rc.description, 'time_note', rc.time_note,
    'source', case when kn.character_id is not null then 'learned' else 'known' end,
    'new', kn.character_id is not null and kn.seen_at is null,
    'output', jsonb_build_object('name', case when known then it.name else coalesce(nullif(btrim(rc.output_label), ''), d.name) end,
                                 'item_id', case when known then it.id end, 'kind_id', case when known then it.kind_id end,
                                 'quantity', rc.output_quantity, 'known', known),
    'check', case when rc.check_key is not null then jsonb_build_object('key', rc.check_key, 'label', public._identify_check_label(rc.check_key)) end,
    'dm_confirms', rc.requires_dm_approval,
    'ingredients', ings,
    'missing', (select coalesce(jsonb_agg(jsonb_build_object('seq', (e ->> 'seq')::int, 'label', e ->> 'label',
                                 'need', (e ->> 'quantity')::int - (e ->> 'have')::int) order by (e ->> 'seq')::int), '[]')
                from jsonb_array_elements(ings) e where (e ->> 'have')::int < (e ->> 'quantity')::int),
    'can_craft', not exists (select 1 from jsonb_array_elements(ings) e where (e ->> 'have')::int < (e ->> 'quantity')::int),
    'pending_attempt_id', (select a.id from public.crafting_attempts a where a.character_id = p_character and a.recipe_id = rc.id and a.status = 'pending'));
end $function$
;
CREATE OR REPLACE FUNCTION public.dm_resolve_craft_attempt(p_attempt uuid, p_decision text, p_outcome text DEFAULT NULL::text, p_dm_roll_total integer DEFAULT NULL::integer, p_reply text DEFAULT NULL::text, p_private_note text DEFAULT NULL::text, p_failure_consumes text DEFAULT NULL::text, p_expected_revision integer DEFAULT NULL::integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare a public.crafting_attempts; r public.crafting_recipes; outc text; res jsonb; err text; roll int;
begin
  if auth.uid() is null then raise exception 'Not authenticated' using errcode = '42501'; end if;
  select * into a from public.crafting_attempts where id = p_attempt for update;
  if a.id is null then raise exception 'Attempt not found' using errcode = 'P0002'; end if;
  select * into r from public.crafting_recipes where id = a.recipe_id;
  perform public._craft_dm_gate(r.campaign_id);
  -- the DM of the recipe's campaign answers only while the character is still in it (the player can still cancel)
  if not exists (select 1 from public.characters c where c.id = a.character_id and c.campaign_id = r.campaign_id) then
    raise exception 'The character is no longer in this campaign' using errcode = '55000';
  end if;
  if p_expected_revision is not null and p_expected_revision <> a.revision then
    raise exception 'Someone else answered this attempt meanwhile. Reload and try again.' using errcode = '40001';
  end if;
  if a.status not in ('pending', 'apply_failed') then raise exception 'This attempt was already answered' using errcode = '55000'; end if;
  if p_decision not in ('approve', 'reject') then raise exception 'Approve or reject' using errcode = '22023'; end if;
  if p_dm_roll_total is not null and (p_dm_roll_total < -10 or p_dm_roll_total > 60) then raise exception 'Roll out of range' using errcode = '22023'; end if;
  if p_outcome is not null and p_outcome not in ('success', 'failure', 'critical_success', 'critical_failure') then
    raise exception 'Unknown outcome' using errcode = '22023';
  end if;
  if p_failure_consumes is not null and p_failure_consumes not in ('keep', 'lose_all', 'lose_half') then
    raise exception 'Unknown failure rule' using errcode = '22023';
  end if;
  update public.crafting_attempts set dm_reply = coalesce(nullif(left(btrim(coalesce(p_reply, '')), 500), ''), dm_reply),
         dm_private_note = coalesce(nullif(left(btrim(coalesce(p_private_note, '')), 500), ''), dm_private_note),
         dm_roll_total = coalesce(p_dm_roll_total, dm_roll_total)
   where id = a.id returning * into a;
  if p_decision = 'reject' then
    update public.crafting_attempts set status = 'rejected', resolved_at = now(), resolved_by = auth.uid(), revision = revision + 1
     where id = a.id returning * into a;
  else
    roll := coalesce(a.dm_roll_total, a.roll_total);
    outc := coalesce(p_outcome, a.outcome, case when r.check_dc is null then 'success' when roll is null then null
                                                when roll >= r.check_dc then 'success' else 'failure' end);
    if outc is null then raise exception 'Choose the outcome (no roll was entered)' using errcode = '22023'; end if;
    update public.crafting_attempts set outcome = outc, failure_consumes = coalesce(p_failure_consumes, failure_consumes) where id = a.id
    returning * into a;
    begin
      res := public._craft_apply(a.id, outc, a.failure_consumes);
    exception when sqlstate 'TLCRF' then
      err := sqlerrm;   -- every partial write of the apply is rolled back with this block's savepoint
    end;
    if err is null then
      update public.crafting_attempts set status = 'applied', consumed = res -> 'consumed', produced = res -> 'produced', apply_error = null,
             resolved_at = now(), resolved_by = auth.uid(), revision = revision + 1 where id = a.id returning * into a;
    else
      update public.crafting_attempts set status = 'apply_failed', apply_error = left(err, 300), resolved_by = auth.uid(), revision = revision + 1
       where id = a.id returning * into a;
    end if;
  end if;
  perform public._craft_audit(a);
  perform public._identify_touch(a.character_id);
  return public._craft_attempt_dm(a);
end $function$
;
CREATE OR REPLACE FUNCTION public.dm_save_recipe(p_campaign uuid, p_recipe jsonb, p_expected_revision integer DEFAULT NULL::integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare o jsonb := coalesce(p_recipe, '{}'); r public.crafting_recipes; rid uuid; g jsonb; n int := 0; dc int; key text; out_item text;
  crit text; fail text; ident boolean; ing_item text; ing_tag text; qty int;
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
  -- the main result only: an official critical / failure result simply arrives identified (_craft_produce)
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
  if r.status = 'published' and not r.output_identified then   -- see dm_set_recipe_status
    update public.items set secret = true where id in (r.output_item_id, r.crit_output_item_id, r.failure_output_item_id)
      and owner_id is not null and not secret;
  end if;
  return public._craft_recipe_dm(r.id);
end $function$
;
CREATE OR REPLACE FUNCTION public.get_character_recipes(p_character uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare ch public.characters; dm boolean;
begin
  if auth.uid() is null or not public.can_access_character(p_character) then raise exception 'Character not found' using errcode = '42501'; end if;
  select * into ch from public.characters where id = p_character;
  dm := public.is_admin() or (ch.campaign_id is not null and public.is_campaign_dm(ch.campaign_id));
  if not dm then perform public._craft_player_gate(p_character); end if;
  return jsonb_build_object(
    'character_id', ch.id,
    'recipes', (select coalesce(jsonb_agg(x.j order by x.nm, x.id), '[]') from (
                 select rc.name as nm, rc.id, public._craft_recipe_player(ch.id, rc.id) as j
                 from public.crafting_recipes rc
                 where ch.campaign_id is not null and rc.campaign_id = ch.campaign_id and rc.status = 'published'
                   and (rc.visibility = 'known' or exists (select 1 from public.character_known_recipes k where k.character_id = ch.id and k.recipe_id = rc.id))) x),
    'undiscovered', (select count(*) from public.crafting_recipes rc where ch.campaign_id is not null and rc.campaign_id = ch.campaign_id
                     and rc.status = 'published' and rc.visibility = 'discoverable'
                     and not exists (select 1 from public.character_known_recipes k where k.character_id = ch.id and k.recipe_id = rc.id)),
    'attempts', (select coalesce(jsonb_agg(public._craft_attempt_player(a) order by a.created_at desc, a.id), '[]')
                 from (select x.* from public.crafting_attempts x join public.crafting_recipes r on r.id = x.recipe_id
                       where x.character_id = ch.id
                         -- a DM sees only the attempts of their campaign's recipes (not the history of a campaign the character left)
                         and (not dm or public.is_admin() or r.campaign_id is not distinct from ch.campaign_id)
                       order by x.created_at desc, x.id limit 20) a));
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
  if public._craft_recipe_player(ch.id, p_recipe) is null then raise exception 'Recipe not found' using errcode = 'P0002'; end if;
  -- no character row lock: the auto path locks inventory rows (_craft_apply) and examine locks a row, then the character.
  -- Duplicates are caught by the unique keys below (same request id: replay; a second pending attempt: 55000).
  select id into inv from public.inventories where character_id = ch.id and kind = 'character' order by created_at limit 1;
  if inv is null then raise exception 'The character has no inventory' using errcode = '22023'; end if;

  -- the selection: shape and ownership
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
  -- only now: does the selection fit the recipe?
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
  if rc.check_key is not null and (p_roll_total is null or p_roll_total < -10 or p_roll_total > 60) then
    raise exception 'Enter the total of your roll (-10 to 60)' using errcode = '22023';
  end if;
  if p_roll_total is not null and (p_roll_total < -10 or p_roll_total > 60) then raise exception 'Roll out of range' using errcode = '22023'; end if;
  if p_natural is not null and p_natural not in ('nat20', 'nat1') then raise exception 'Natural roll: nat20 or nat1' using errcode = '22023'; end if;
  if exists (select 1 from public.crafting_attempts x where x.character_id = ch.id and x.recipe_id = rc.id and x.status = 'pending') then
    raise exception 'Your DM has not answered your last attempt at this recipe yet' using errcode = '55000';
  end if;

  begin
    insert into public.crafting_attempts (character_id, recipe_id, recipe_revision, inventory_id, selected, roll_total, natural_roll,
                                          player_note, request_id, auto)
    values (ch.id, rc.id, rc.revision, inv, norm, p_roll_total, p_natural, nullif(left(btrim(coalesce(p_note, '')), 500), ''), p_request_id,
            not rc.requires_dm_approval and rc.check_dc is null)
    on conflict (character_id, request_id) do nothing
    returning * into a;
  exception when unique_violation then   -- a concurrent second pending attempt at the same recipe (crafting_attempts_one_pending)
    raise exception 'Your DM has not answered your last attempt at this recipe yet' using errcode = '55000';
  end;
  if a.id is null then
    select * into a from public.crafting_attempts where character_id = ch.id and request_id = p_request_id;
    return public._craft_attempt_player(a) || jsonb_build_object('replayed', true);
  end if;
  if a.auto then
    -- auto path: consumed and produced now (an error rolls the whole start back: nothing is recorded or changed)
    res := public._craft_apply(a.id, 'success', null);
    update public.crafting_attempts set status = 'applied', outcome = 'success', consumed = res -> 'consumed', produced = res -> 'produced',
           resolved_at = now(), revision = revision + 1 where id = a.id returning * into a;
  end if;
  perform public._craft_audit(a);
  perform public._identify_touch(ch.id);
  return public._craft_attempt_player(a);
end $function$
;
-- helpers of 20261114000900 (after the v1 bodies no longer call them)
drop function if exists public._craft_manuals(uuid);
drop function if exists public._craft_recipes_player(uuid, uuid);
drop function if exists public._craft_recipe_visible(uuid, uuid);
drop function if exists public._craft_lock_items(jsonb, uuid);
drop function if exists public._craft_suggest(int, text, int);
drop function if exists public._craft_tool_ok(uuid, text);
drop function if exists public._craft_tool_item(text);
