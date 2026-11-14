-- =============================================================================
-- Crafting v2 (docs/CRAFTING_V1.md, now "Crafting v2"). Additive on top of 20261113000100_crafting_v1; rollback
-- supabase/rollback/rollback_crafting_v2.sql (exact previous function bodies; no row is changed by this file or by the rollback).
--  1. Faster player read: get_character_recipes builds the character's row set (known / free flags, trusted tag pairs) ONCE per
--     call (_craft_recipes_player, set-based) instead of per recipe x ingredient x row function calls. The knowledge rule is the
--     same predicate (_craft_row_known: no knowledge row or an identified one), the result for the v1 fields is identical.
--  2. Recipe items: crafting_recipe_teachers links a recipe to the items that teach it (a manual, a recipe scroll).
--     learn_recipe_from_item(row) teaches every published recipe of the character's campaign linked to the row's item, PERMANENTLY
--     (character_known_recipes.source = 'manual'); the row is used up when the link says so (default: an item of kind 'scroll' is
--     used up, anything else is kept). Unidentified rows never teach (one fixed refusal). The DM can still grant directly.
--  3. The player sees the DC of a recipe (owner decision 2026-11-13; herb examine DCs stay hidden) and the tool the check needs
--     (an official item of kind 'tool' as check_key): present / missing. Craft needs the tool too (start and apply, server-side).
--     The read also lists the tools and the recipe items the character carries (known rows only).
--  4. The DM's attempt view carries suggested_outcome (nat20 -> critical success, nat1 -> critical failure, else the roll against
--     the DC; success without a DC). The API default when the DM sends no outcome is unchanged (the roll against the DC).
--  5. Lock order (R-D4 follow-up): every crafting path that changes inventory rows takes the per-item advisory lock
--     pg_advisory_xact_lock(4242, hashtext(item id)) for every involved item (ingredients, results), in one fixed order, BEFORE
--     its first write (a crafting_attempts write bumps the character cache counter, which a transfer holding 4242 also wants).
-- Cache: crafting_recipe_teachers -> tl_cache.skip() (no cached read touches it). No Realtime change.
-- =============================================================================
set lock_timeout = '5s';

-- ---- 1. schema -----------------------------------------------------------------------------------------------------------------
create table if not exists public.crafting_recipe_teachers (
  recipe_id        uuid not null references public.crafting_recipes (id) on delete cascade,
  item_id          text not null references public.items (id) on delete cascade,   -- deleting an (unused) item only drops the link
  consume_on_learn boolean not null,
  created_at       timestamptz not null default now(),
  primary key (recipe_id, item_id)
);
create index if not exists crafting_recipe_teachers_item on public.crafting_recipe_teachers (item_id);
alter table public.crafting_recipe_teachers enable row level security;
revoke all on public.crafting_recipe_teachers from public, anon, authenticated;
drop trigger if exists tl_cache_rev on public.crafting_recipe_teachers;
create trigger tl_cache_rev after insert or update or delete on public.crafting_recipe_teachers
  for each row execute function tl_cache.skip();

-- a recipe learned from an item
alter table public.character_known_recipes drop constraint if exists character_known_recipes_source_check;
alter table public.character_known_recipes add constraint character_known_recipes_source_check
  check (source in ('dm', 'experiment', 'manual'));

-- ---- 2. helpers ----------------------------------------------------------------------------------------------------------------
-- the tool a check needs: the check key when it is an official item of kind 'tool' (and not a skill), else null
create or replace function public._craft_tool_item(p_key text)
returns text language sql stable security definer set search_path = public, pg_temp as $$
  select i.id from public.items i where i.id = p_key and i.kind_id = 'tool' and i.owner_id is null
     and not exists (select 1 from public.skills s where s.id = p_key);
$$;

-- does the character carry a KNOWN row of the recipe's tool (or need none)?
create or replace function public._craft_tool_ok(p_character uuid, p_check_key text)
returns boolean language sql stable security definer set search_path = public, pg_temp as $$
  select public._craft_tool_item(p_check_key) is null
      or exists (select 1 from public.inventory_items ii join public.inventories inv on inv.id = ii.inventory_id
                 where inv.character_id = p_character and inv.kind = 'character' and ii.item_id = public._craft_tool_item(p_check_key)
                   and public._craft_row_known(ii.id));
$$;

-- the outcome the DM is offered (the server never rolls)
create or replace function public._craft_suggest(p_roll int, p_natural text, p_dc int)
returns text language sql immutable set search_path = public, pg_temp as $$
  select case when p_natural = 'nat20' then 'critical_success' when p_natural = 'nat1' then 'critical_failure'
              when p_dc is null then 'success' when p_roll is null then null
              when p_roll >= p_dc then 'success' else 'failure' end;
$$;

-- the per-item lock (4242, the space of transfer / set_item_knowledge / examine / resolve) for every item a craft touches:
-- the selected rows' items and the recipe's results, in one fixed order (lock key, then id). Re-entrant (xact advisory locks).
create or replace function public._craft_lock_items(p_selected jsonb, p_recipe uuid)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare k text;
begin
  -- fixed order by the lock key (hashtext), ties by id
  for k in
    select y.id from (
      select distinct x.id from (
        select ii.item_id as id from public.inventory_items ii
         where ii.id in (select (s ->> 'inventory_item_id')::uuid from jsonb_array_elements(coalesce(p_selected, '[]')) s
                          where coalesce(s ->> 'inventory_item_id', '') ~ '^[0-9a-fA-F-]{36}$')
        union all
        select unnest(array[r.output_item_id, r.crit_output_item_id, r.failure_output_item_id]) from public.crafting_recipes r where r.id = p_recipe) x
      where x.id is not null) y
    order by hashtext(y.id), y.id
  loop
    perform pg_advisory_xact_lock(4242, hashtext(k));
  end loop;
end $$;

-- is the recipe visible to the character (the visibility rule of the player read, without computing it)?
create or replace function public._craft_recipe_visible(p_character uuid, p_recipe uuid)
returns boolean language sql stable security definer set search_path = public, pg_temp as $$
  select exists (select 1 from public.characters ch join public.crafting_recipes r on r.campaign_id = ch.campaign_id
                 where ch.id = p_character and r.id = p_recipe and r.status = 'published'
                   and (r.visibility = 'known' or exists (select 1 from public.character_known_recipes k where k.character_id = ch.id and k.recipe_id = r.id)));
$$;

-- ---- 3. the set-based player read ----------------------------------------------------------------------------------------------
-- Every visible recipe (or only p_recipe) as the player of this character may see it. The character's rows are read ONCE:
-- known rows only (_craft_row_known), their free flag (_craft_row_free), and the trusted (item, tag) pairs (_craft_item_trusted);
-- an ingredient line's candidates are the known rows that match it (exact item or trusted tag) and, for a used-up line, are free.
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
$$;

-- v1 signature kept: one recipe (null when not visible to the character)
create or replace function public._craft_recipe_player(p_character uuid, p_recipe uuid)
returns jsonb language sql stable security definer set search_path = public, pg_temp as $$
  select x.j from public._craft_recipes_player(p_character, p_recipe) x;
$$;

-- recipe items the character carries (known rows only) and how many of their published recipes it has not learned yet
create or replace function public._craft_manuals(p_character uuid)
returns jsonb language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce(jsonb_agg(jsonb_build_object('inventory_item_id', m.id, 'name', m.nm, 'quantity', m.quantity, 'recipes', m.n,
                                               'unlearned', m.unlearned, 'consumed_on_learn', m.consumes) order by m.nm, m.id), '[]')
  from (
    select ii.id, coalesce(nullif(ii.custom_name, ''), ii.name) as nm, ii.quantity, count(*)::int as n,
           count(*) filter (where kn.character_id is null)::int as unlearned, bool_or(t.consume_on_learn) as consumes
    from public.characters ch
    join public.inventories inv on inv.character_id = ch.id and inv.kind = 'character'
    join public.inventory_items ii on ii.inventory_id = inv.id
    join public.crafting_recipe_teachers t on t.item_id = ii.item_id
    join public.crafting_recipes r on r.id = t.recipe_id and r.campaign_id = ch.campaign_id and r.status = 'published'
    left join public.character_known_recipes kn on kn.character_id = ch.id and kn.recipe_id = r.id
    where ch.id = p_character and public._craft_row_known(ii.id)
    group by ii.id) m;
$$;

-- known recipes with what is missing (computed from fully known rows only), recent attempts, the number still to discover,
-- the tools and the recipe items the character carries
create or replace function public.get_character_recipes(p_character uuid)
returns jsonb
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
declare ch public.characters; dm boolean;
begin
  if auth.uid() is null or not public.can_access_character(p_character) then raise exception 'Character not found' using errcode = '42501'; end if;
  select * into ch from public.characters where id = p_character;
  dm := public.is_admin() or (ch.campaign_id is not null and public.is_campaign_dm(ch.campaign_id));
  if not dm then perform public._craft_player_gate(p_character); end if;
  return jsonb_build_object(
    'character_id', ch.id,
    'recipes', (select coalesce(jsonb_agg(x.j order by x.recipe_name, x.recipe_id), '[]') from public._craft_recipes_player(ch.id) x),
    'undiscovered', (select count(*) from public.crafting_recipes rc where ch.campaign_id is not null and rc.campaign_id = ch.campaign_id
                     and rc.status = 'published' and rc.visibility = 'discoverable'
                     and not exists (select 1 from public.character_known_recipes k where k.character_id = ch.id and k.recipe_id = rc.id)),
    'attempts', (select coalesce(jsonb_agg(public._craft_attempt_player(a) order by a.created_at desc, a.id), '[]')
                 from (select x.* from public.crafting_attempts x join public.crafting_recipes r on r.id = x.recipe_id
                       where x.character_id = ch.id
                         and (not dm or public.is_admin() or r.campaign_id is not distinct from ch.campaign_id)
                       order by x.created_at desc, x.id limit 20) a),
    'tools', (select coalesce(jsonb_agg(jsonb_build_object('inventory_item_id', ii.id, 'item_id', ii.item_id,
                                 'name', coalesce(nullif(ii.custom_name, ''), ii.name), 'quantity', ii.quantity)
                                 order by coalesce(nullif(ii.custom_name, ''), ii.name), ii.id), '[]')
              from public.inventory_items ii join public.inventories inv on inv.id = ii.inventory_id
              join public.items i on i.id = ii.item_id
              where inv.character_id = ch.id and inv.kind = 'character' and i.kind_id = 'tool' and public._craft_row_known(ii.id)),
    'manuals', public._craft_manuals(ch.id));
end $$;

-- ---- 4. recipe items: learn ----------------------------------------------------------------------------------------------------
-- What a recipe item teaches, for the item's detail (counts only: a recipe's name is shown after it is learned)
create or replace function public.get_inventory_item_recipes(p_inventory_item uuid)
returns jsonb
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
declare ii public.inventory_items; cid uuid; kind text; ch public.characters; res jsonb;
begin
  if auth.uid() is null then raise exception 'Not authenticated' using errcode = '42501'; end if;
  select * into ii from public.inventory_items where id = p_inventory_item;
  select i.character_id, i.kind into cid, kind from public.inventories i where i.id = ii.inventory_id;
  if ii.id is null or cid is null or kind <> 'character' then raise exception 'Item not found' using errcode = 'P0002'; end if;
  ch := public._craft_player_gate(cid);
  if ii.item_id is null or not public._craft_row_known(ii.id) then
    return jsonb_build_object('inventory_item_id', ii.id, 'recipes', 0, 'unlearned', 0, 'consumed_on_learn', false);
  end if;
  select jsonb_build_object('inventory_item_id', ii.id, 'recipes', count(*)::int,
                            'unlearned', count(*) filter (where kn.character_id is null)::int,
                            'consumed_on_learn', coalesce(bool_or(t.consume_on_learn), false))
    into res
  from public.crafting_recipe_teachers t
  join public.crafting_recipes r on r.id = t.recipe_id and r.campaign_id = ch.campaign_id and r.status = 'published'
  left join public.character_known_recipes kn on kn.character_id = ch.id and kn.recipe_id = r.id
  where t.item_id = ii.item_id;
  return res;
end $$;

-- Read a recipe item: every published recipe of the character's campaign linked to the row's item is learned permanently
-- (source 'manual'). The row is used up (one piece) when a link says so and something new was learned. Lock order: the per-item
-- lock 4242, then the row (as transfer / examine), then the writes.
create or replace function public.learn_recipe_from_item(p_inventory_item uuid)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare ii public.inventory_items; cid uuid; kind text; ch public.characters; learned jsonb := '[]'; consumes boolean := false;
  nm text; rr record;
begin
  if auth.uid() is null then raise exception 'Not authenticated' using errcode = '42501'; end if;
  select * into ii from public.inventory_items where id = p_inventory_item;
  select i.character_id, i.kind into cid, kind from public.inventories i where i.id = ii.inventory_id;
  if ii.id is null or cid is null or kind <> 'character' then raise exception 'Item not found' using errcode = 'P0002'; end if;
  ch := public._craft_player_gate(cid);
  -- knowledge first, one fixed message (it never says whether the item teaches anything)
  if ii.item_id is null or not public._craft_row_known(ii.id) then
    raise exception 'You don''t know what this item is yet' using errcode = '22023';
  end if;
  if not exists (select 1 from public.crafting_recipe_teachers t join public.crafting_recipes r on r.id = t.recipe_id
                 where t.item_id = ii.item_id and r.campaign_id = ch.campaign_id and r.status = 'published') then
    raise exception 'There is no recipe to learn in this item' using errcode = '22023';
  end if;
  perform pg_advisory_xact_lock(4242, hashtext(ii.item_id));
  select * into ii from public.inventory_items where id = p_inventory_item for update;
  if ii.id is null or ii.inventory_id is distinct from (select i.id from public.inventories i where i.id = ii.inventory_id and i.character_id = cid)
     or ii.quantity < 1 or not public._craft_row_known(ii.id) then
    raise exception 'The item is no longer in the inventory' using errcode = '55000';
  end if;
  nm := coalesce(nullif(ii.custom_name, ''), ii.name);
  for rr in
    insert into public.character_known_recipes (character_id, recipe_id, source, granted_by)
    select ch.id, r.id, 'manual', auth.uid() from public.crafting_recipe_teachers t
      join public.crafting_recipes r on r.id = t.recipe_id
     where t.item_id = ii.item_id and r.campaign_id = ch.campaign_id and r.status = 'published'
    on conflict do nothing
    returning recipe_id
  loop
    learned := learned || jsonb_build_array(jsonb_build_object('recipe_id', rr.recipe_id,
                 'name', (select r.name from public.crafting_recipes r where r.id = rr.recipe_id)));
  end loop;
  if jsonb_array_length(learned) = 0 then
    return jsonb_build_object('learned', learned, 'consumed', false, 'message', 'You already know every recipe in it');
  end if;
  consumes := coalesce((select bool_or(t.consume_on_learn) from public.crafting_recipe_teachers t
                        where t.item_id = ii.item_id and t.recipe_id in (select (x ->> 'recipe_id')::uuid from jsonb_array_elements(learned) x)), false);
  if consumes then
    if not public._craft_row_free(ii.id) then
      raise exception 'Equipped, attuned or quest items and containers with contents cannot be used up' using errcode = '22023';
    end if;
    perform public._rpc_begin();
    if ii.quantity = 1 then delete from public.inventory_items where id = ii.id;
    else update public.inventory_items set quantity = quantity - 1 where id = ii.id; end if;
    perform public.log_inventory_event(ii.inventory_id, case when ii.quantity = 1 then null else ii.id end, 'use', -1, ii.item_id,
      jsonb_build_object('via', 'learn_recipe', 'name', nm, 'previous_quantity', ii.quantity, 'deleted', ii.quantity = 1,
                         'recipes', (select jsonb_agg(x -> 'recipe_id') from jsonb_array_elements(learned) x)));
    perform public._rpc_end();
  end if;
  perform public._audit(ch.campaign_id, ch.id, 'recipe_learned', 'New recipe learned: ' || (x ->> 'name') || ' (from ' || nm || ')',
                        null, null, null, null, 'party')
    from jsonb_array_elements(learned) x;
  perform public._identify_touch(ch.id);
  return jsonb_build_object('learned', learned, 'consumed', consumes);
end $$;

-- ---- 5. crafting paths with the 4242 lock and the tool rule ----------------------------------------------------------------------
-- body of 20261113000100 + 4242 (re-entrant; the caller already holds it) + a busy-lock note kept
create or replace function public._craft_produce(p_inventory uuid, p_character uuid, p_item text, p_quantity int, p_identified boolean, p_meta jsonb)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare it public.items; ck public.character_item_knowledge; d record; nm text; ds text; remaining int := greatest(coalesce(p_quantity, 1), 1);
  chunk int; rid uuid; last_id uuid; plain boolean;
begin
  select * into it from public.items where id = p_item;
  if it.id is null or it.archived_at is not null then
    raise exception 'The result of this recipe is no longer available' using errcode = 'TLCRF';
  end if;
  -- 20261114000900: the per-item lock (held already by _craft_lock_items, taken before any write; re-entrant)
  perform pg_advisory_xact_lock(4242, hashtext(p_item));
  begin
    perform 1 from public.inventory_items ii join public.inventories inv on inv.id = ii.inventory_id
     where inv.character_id = p_character and ii.item_id = p_item order by ii.id for update of ii nowait;
    perform 1 from public.character_item_knowledge where character_id = p_character and item_id = p_item for update nowait;
  exception when lock_not_available then
    raise exception 'The player is busy with this item right now (examining it); try again in a moment' using errcode = 'TLCRF';
  end;
  select * into ck from public.character_item_knowledge where character_id = p_character and item_id = p_item;
  plain := coalesce(p_identified, true) or coalesce(ck.state = 'identified', false) or it.owner_id is null;
  if plain then
    if it.secret and ((ck.character_id is not null and ck.state <> 'identified')
                      or exists (select 1 from public.inventory_items ii join public.inventories inv on inv.id = ii.inventory_id
                                 join public.inventory_item_knowledge k on k.inventory_item_id = ii.id
                                 where inv.character_id = p_character and ii.item_id = p_item and k.state <> 'identified')) then
      perform public._identify_apply(p_character, p_item, '{all}');
    end if;
    while remaining > 0 loop
      chunk := case when it.stackable then least(remaining, coalesce(it.stack_max, remaining)) else 1 end;
      insert into public.inventory_items (inventory_id, item_id, quantity) values (p_inventory, p_item, chunk) returning id into rid;
      last_id := public._try_auto_merge(rid);
      remaining := remaining - chunk;
    end loop;
    nm := it.name;
  else
    update public.items set secret = true where id = p_item and not secret;
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
end $$;

-- body of 20261113000100 + 4242 first (re-entrant) + the tool rule
create or replace function public._craft_apply(p_attempt uuid, p_outcome text, p_failure_consumes text)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
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
end $$;

-- body of 20261113000100 + the cheap visibility check + the tool rule + 4242 before the auto path's first write
create or replace function public.start_craft_attempt(p_character uuid, p_recipe uuid, p_selected jsonb, p_roll_total int default null,
                                           p_request_id uuid default null, p_natural text default null, p_note text default null)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
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
end $$;

-- body of 20261113000100 + 4242 before the first write of an approval
create or replace function public.dm_resolve_craft_attempt(p_attempt uuid, p_decision text, p_outcome text default null, p_dm_roll_total int default null,
                                                p_reply text default null, p_private_note text default null,
                                                p_failure_consumes text default null, p_expected_revision int default null)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare a public.crafting_attempts; r public.crafting_recipes; outc text; res jsonb; err text; roll int;
begin
  if auth.uid() is null then raise exception 'Not authenticated' using errcode = '42501'; end if;
  select * into a from public.crafting_attempts where id = p_attempt for update;
  if a.id is null then raise exception 'Attempt not found' using errcode = 'P0002'; end if;
  select * into r from public.crafting_recipes where id = a.recipe_id;
  perform public._craft_dm_gate(r.campaign_id);
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
  -- 20261114000900: an approval changes inventory rows -> the per-item locks before the first write (the attempt update below
  -- bumps the character cache counter)
  if p_decision = 'approve' then perform public._craft_lock_items(a.selected, r.id); end if;
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
      err := sqlerrm;
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
end $$;

-- ---- 6. DM views ---------------------------------------------------------------------------------------------------------------
-- body of 20261113000100 + suggested_outcome, tool_ok
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

-- body of 20261113000100 + teachers, the learn source, the tool
create or replace function public._craft_recipe_dm(p_recipe uuid)
returns jsonb
language sql stable security definer
set search_path = public, pg_temp
as $$
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
$$;

-- body of 20261113000100 + the recipe items that teach it (p_recipe.teachers: [{item_id, consumed: true | false | null}]; null =
-- the default: an item of kind 'scroll' is used up when read, anything else is kept). Replaced as a set only when the key is sent.
create or replace function public.dm_save_recipe(p_campaign uuid, p_recipe jsonb, p_expected_revision int default null)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
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
end $$;

-- ---- 7. grants -------------------------------------------------------------------------------------------------------------------
revoke all on function public._craft_tool_item(text), public._craft_tool_ok(uuid, text), public._craft_suggest(int, text, int),
  public._craft_lock_items(jsonb, uuid), public._craft_recipe_visible(uuid, uuid), public._craft_recipes_player(uuid, uuid),
  public._craft_manuals(uuid) from public, anon, authenticated;
revoke all on function public.get_inventory_item_recipes(uuid), public.learn_recipe_from_item(uuid) from public, anon;
grant execute on function public.get_inventory_item_recipes(uuid), public.learn_recipe_from_item(uuid) to authenticated, service_role;

reset lock_timeout;
