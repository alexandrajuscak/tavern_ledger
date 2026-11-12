-- Tests of 20261030000200_progressive_fluent_reads.sql (local Supabase, run as supabase_admin; everything is rolled back).
-- Usage: docker exec -i supabase_db_tavern_ledger psql -U supabase_admin -d postgres -qAt -v ON_ERROR_STOP=1 < supabase/tests/progressive_read_tests.sql
-- Prints failed checks, one line per check group and a TOTAL line (passed | failed).
begin;
set local track_functions = 'all';
create temp table pr (chk text, ok boolean, detail text) on commit drop;
grant all on pr to authenticated, anon;

create temp table cacheable (n text) on commit drop;
insert into cacheable values ('get_character_derived_stats'), ('get_character_proficiencies'), ('get_character_lineage'),
  ('get_character_background'), ('get_character_feats'), ('get_character_class_summary'), ('get_character_spell_slots'),
  ('get_character_class_features'), ('get_character_resources'), ('get_character_states'), ('get_character_infusions'),
  ('get_character_spellbook'), ('get_character_transformation');
grant select on cacheable to authenticated, anon;

-- direct (uncached) value of one read, as the current caller
create or replace function pg_temp.direct(p uuid, n text) returns jsonb language plpgsql as $$
declare v jsonb;
begin
  execute format('select public.%I($1)', n) into v using p;
  return v;
end $$;

-- 1. coverage: every public table carries the counter trigger (a future table without one would make the cache unsafe)
insert into pr select 'counter trigger on every public table', count(*) = 0,
  coalesce(string_agg(c.relname, ', '), '') from pg_class c
  where c.relnamespace = 'public'::regnamespace and c.relkind in ('r', 'p') and c.relname <> 'character_revisions'
    and not exists (select 1 from pg_trigger t where t.tgrelid = c.oid and t.tgname = 'tl_cache_rev');
insert into pr select 'trigger mode: character tables', count(*) = 0, coalesce(string_agg(c.relname, ', '), '') from pg_class c
  join pg_trigger t on t.tgrelid = c.oid and t.tgname = 'tl_cache_rev'
  where c.relnamespace = 'public'::regnamespace and c.relname <> 'characters'
    and exists (select 1 from pg_attribute a where a.attrelid = c.oid and a.attname = 'character_id' and not a.attisdropped)
    and encode(t.tgargs, 'escape') <> 'character\000';
-- allow-list (20261112000200): tables with DM-hidden rows count only visible changes (tl_cache.bump_visible, same mode argument)
insert into pr select 'trigger function: bump, or bump_visible on the hidden-row tables only', count(*) = 0, coalesce(string_agg(c.relname, ', '), '')
  from pg_class c join pg_trigger t on t.tgrelid = c.oid and t.tgname = 'tl_cache_rev'
  where c.relnamespace = 'public'::regnamespace and encode(t.tgargs, 'escape') = 'character\000'
    and t.tgfoid <> 'tl_cache.bump()'::regprocedure
    and not (c.relname in ('character_conditions', 'campaign_audit_events', 'dm_character_notes')
             and to_regprocedure('tl_cache.bump_visible()') is not null and t.tgfoid = 'tl_cache.bump_visible()'::regprocedure);

-- 2. equality and hits, as owner and as campaign DM, for every character: first call computes (and stores), second is served
--    from the cache; both equal the direct RPCs. Characters with a Wild Shape row are never cached.
do $$
declare c record; who record; a jsonb; b jsonb; n text; i int := 0; ws boolean;
begin
  for c in select id, owner_id, campaign_id from public.characters where owner_id is not null order by id loop
    ws := exists (select 1 from public.character_transformations t where t.character_id = c.id);
    for who in select c.owner_id as uid, 'owner' as kind
               union all select m.user_id, 'dm' from public.campaign_members m where m.campaign_id = c.campaign_id and m.role = 'dm' and m.user_id <> c.owner_id
    loop
      perform set_config('request.jwt.claims', json_build_object('sub', who.uid, 'role', 'authenticated')::text, true);
      execute 'set local role authenticated';
      a := public.get_character_reads(c.id, (select array_agg(cc.n) from cacheable cc));
      b := public.get_character_reads(c.id, (select array_agg(cc.n) from cacheable cc));
      insert into pr values ('no read errors (' || who.kind || ')', a -> 'errors' = '{}'::jsonb and b -> 'errors' = '{}'::jsonb, c.id::text || (a -> 'errors')::text);
      if ws then
        insert into pr values ('wild shape character: never cached', (b -> 'cache' ->> 'hits')::int = 0 and (a -> 'cache' ->> 'stored')::int = 0, c.id::text || (b -> 'cache')::text);
      else
        insert into pr values ('second call: all 13 from the cache (' || who.kind || ')', (b -> 'cache' ->> 'hits')::int = 13, c.id::text || (b -> 'cache')::text);
      end if;
      for n in select x.n from cacheable x loop
        insert into pr values ('cached == direct ' || n || ' (' || who.kind || ')', (b -> 'reads' -> n) = pg_temp.direct(c.id, n) and (a -> 'reads' -> n) = (b -> 'reads' -> n), c.id::text);
      end loop;
      execute 'reset role';
      i := i + 1;
    end loop;
  end loop;
  insert into pr values ('character x viewer combinations tested', i >= 35, i::text);
end $$;

-- 4. viewers never share a cached value; nobody but a server function reads the cache
do $$
declare c record; stranger uuid; e text;
begin
  select ch.id, ch.owner_id, m.user_id as dm into c from public.characters ch
    join public.campaign_members m on m.campaign_id = ch.campaign_id and m.role = 'dm' and m.user_id <> ch.owner_id
  where not exists (select 1 from public.character_transformations t where t.character_id = ch.id) order by ch.id limit 1;
  insert into pr values ('cache rows are per viewer (owner and DM have their own)',
    (select count(distinct viewer) from tl_cache.character_reads where character_id = c.id) >= 2, c.id::text);
  select p.id into stranger from public.profiles p where p.id <> c.owner_id and p.id <> c.dm
    and not exists (select 1 from public.campaign_members m where m.user_id = p.id and m.campaign_id = (select campaign_id from public.characters where id = c.id))
    and not exists (select 1 from public.profiles q where q.id = p.id and coalesce((to_jsonb(q) ->> 'is_admin')::boolean, false)) limit 1;
  perform set_config('request.jwt.claims', json_build_object('sub', stranger, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  begin perform public.get_character_shell(c.id); e := 'no error'; exception when others then e := sqlstate; end;
  insert into pr values ('unrelated player: shell denied (42501)', e = '42501', e);
  begin perform public.get_character_reads(c.id, array['get_character_derived_stats']); e := 'no error'; exception when others then e := sqlstate; end;
  insert into pr values ('unrelated player: cached reads denied (42501)', e = '42501', e);
  insert into pr values ('unrelated player: tl_cache.get returns nothing of others',
    tl_cache.get(c.id, 'get_character_derived_stats', tl_cache.key(c.id, 'authenticated')) is null, '');
  begin perform count(*) from tl_cache.character_reads; e := 'no error'; exception when others then e := sqlstate; end;
  insert into pr values ('authenticated cannot read the cache table', e = '42501', e);
  begin update tl_cache.character_rev set rev = 0; e := 'no error'; exception when others then e := sqlstate; end;
  insert into pr values ('authenticated cannot write the counters', e = '42501', e);
  execute 'reset role';
  perform set_config('request.jwt.claims', '{"role":"anon"}', true);
  execute 'set local role anon';
  begin perform public.get_character_shell(c.id); e := 'no error'; exception when others then e := sqlstate; end;
  insert into pr values ('anonymous: shell denied', e in ('42501', '42883'), e);
  begin perform tl_cache.key(c.id, 'anon'); e := 'no error'; exception when others then e := sqlstate; end;
  insert into pr values ('anonymous: no access to tl_cache', e = '42501', e);
  execute 'reset role';
  -- service role / owner sessions never cache
  insert into pr values ('non-API roles never cached', not (tl_cache.key(c.id, 'postgres') ->> 'ok')::boolean, '');
end $$;

-- 5. Character Shell: exactly the core reads, equal to the direct reads, smaller than the full view; and the rules are not
--    evaluated again when the derived stats come from the cache
do $$
declare c record; s jsonb; v jsonb; n text; core_before bigint; core_after bigint;
begin
  for c in select ch.id, ch.owner_id from public.characters ch where ch.owner_id is not null order by ch.id loop
    perform set_config('request.jwt.claims', json_build_object('sub', c.owner_id, 'role', 'authenticated')::text, true);
    execute 'set local role authenticated';
    s := public.get_character_shell(c.id);
    v := public.get_character_view(c.id, 'combat');
    insert into pr values ('shell: core reads only, no errors', (select array_agg(k order by k) from jsonb_object_keys(s -> 'reads') k)
      = (select array_agg(k order by k) from unnest(public._character_read_set('core')) k) and s -> 'errors' = '{}'::jsonb, c.id::text || (s -> 'errors')::text);
    insert into pr values ('shell smaller than the view', length((s -> 'reads')::text) < length((v -> 'reads')::text), length((s -> 'reads')::text) || ' < ' || length((v -> 'reads')::text));
    foreach n in array array['get_character_derived_stats', 'get_character_governance'] loop
      insert into pr values ('shell == direct ' || n, (s -> 'reads' -> n) = pg_temp.direct(c.id, n), c.id::text);
    end loop;
    insert into pr values ('shell == direct characters row', (s -> 'reads' -> 'characters') = (select to_jsonb(x) from public.characters x where x.id = c.id), c.id::text);
    if not exists (select 1 from public.character_transformations t where t.character_id = c.id) then
      execute 'reset role';
      select coalesce(sum(calls), 0) into core_before from pg_stat_xact_user_functions where funcname = '_derived_stats_core';
      perform set_config('request.jwt.claims', json_build_object('sub', c.owner_id, 'role', 'authenticated')::text, true);
      execute 'set local role authenticated';
      perform public.get_character_reads(c.id, array['get_character_derived_stats', 'get_character_class_summary', 'get_character_spell_slots',
        'get_character_resources', 'get_character_class_features', 'get_character_spellbook']);
      execute 'reset role';
      select coalesce(sum(calls), 0) into core_after from pg_stat_xact_user_functions where funcname = '_derived_stats_core';
      insert into pr values ('warm batch: no invoker rules evaluation', core_after - core_before <= 1, (core_after - core_before)::text);
    end if;
    execute 'reset role';
  end loop;
end $$;

-- 6. starting equipment: authorized readers get the candidates; anonymous does not; nothing character-specific in them
do $$
declare cv text; c record; e text; eq jsonb; stranger uuid;
begin
  select e2.class_version_id into cv from public.class_starting_equipment e2, jsonb_array_elements(e2.items) x
  where x ? 'group' or x ? 'category' or x ? 'one_of' limit 1;
  select ch.id, ch.owner_id into c from public.characters ch where ch.owner_id is not null order by ch.id limit 1;
  perform set_config('request.jwt.claims', json_build_object('sub', c.owner_id, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  begin eq := public.get_class_starting_equipment(cv); e := 'ok'; exception when others then e := sqlstate; end;
  insert into pr values ('owner: starting equipment with placeholder candidates loads', e = 'ok' and eq is not null, e || ' ' || coalesce(cv, 'no class'));
  insert into pr values ('candidates are official catalog items only', not exists (
    select 1 from jsonb_array_elements(eq -> 'groups') g, jsonb_array_elements(g -> 'options') o, jsonb_array_elements(o -> 'items') it,
      jsonb_array_elements(coalesce(it -> 'candidates', '[]')) cand
    join public.items i on i.id = cand ->> 'id' where i.owner_id is not null or i.campaign_id is not null or i.archived_at is not null), '');
  execute 'reset role';
  perform set_config('request.jwt.claims', '{"role":"anon"}', true);
  execute 'set local role anon';
  begin perform public._starting_equipment_candidates('{"category":"simple-melee"}'); e := 'no error'; exception when others then e := sqlstate; end;
  insert into pr values ('anonymous: candidates denied', e = '42501', e);
  execute 'reset role';
  insert into pr values ('authenticated has EXECUTE on candidates only (no other new grant)',
    has_function_privilege('authenticated', 'public._starting_equipment_candidates(jsonb)', 'execute')
    and not has_function_privilege('anon', 'public._starting_equipment_candidates(jsonb)', 'execute'), '');
end $$;

-- 7. invalidation (last: it writes) on a character without a Wild Shape row. Writes run as the database owner (no API user,
--    so no governance gate); reads run as the character's owner.
create or replace function pg_temp.as_owner(u uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
end $$;
create or replace function pg_temp.crev(c uuid) returns bigint language sql security definer as $$
  select rev from tl_cache.character_rev where character_id = c $$;
create or replace function pg_temp.grev() returns bigint language sql security definer as $$ select rev from tl_cache.global_rev $$;
grant execute on function pg_temp.crev(uuid), pg_temp.grev() to authenticated;
create or replace function pg_temp.as_admin() returns void language plpgsql as $$
begin
  execute 'reset role';
  perform set_config('request.jwt.claims', '', true);
end $$;
do $$
declare c record; r0 bigint; r1 bigint; g0 bigint; x jsonb; d0 jsonb; inv uuid;
begin
  select ch.id, ch.owner_id into c from public.characters ch
  where ch.owner_id is not null and not exists (select 1 from public.character_transformations t where t.character_id = ch.id)
  order by ch.id limit 1;
  perform set_config('request.jwt.claims', json_build_object('sub', c.owner_id, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  perform public.get_character_reads(c.id, (select array_agg(cc.n) from cacheable cc));
  r0 := pg_temp.crev(c.id);
  -- runtime only: HP, temp HP, inspiration, coins -> counter unchanged, cache still served, still equal to direct
  perform pg_temp.as_admin();
  update public.characters set hp_current = greatest(0, coalesce(hp_current, 0) - 1), hp_temp = coalesce(hp_temp, 0) + 3,
    inspiration = not coalesce(inspiration, false), gp = coalesce(gp, 0) + 1 where id = c.id;
  perform pg_temp.as_owner(c.owner_id);
  insert into pr values ('HP / temp HP / inspiration / coins: counter unchanged', pg_temp.crev(c.id) = r0, r0::text);
  x := public.get_character_reads(c.id, (select array_agg(cc.n) from cacheable cc));
  insert into pr values ('HP change: reads still served from the cache', (x -> 'cache' ->> 'hits')::int = 13, (x -> 'cache')::text);
  insert into pr values ('HP change: cached transformation == direct', (x -> 'reads' -> 'get_character_transformation') = public.get_character_transformation(c.id), '');
  insert into pr values ('HP change: cached derived == direct', (x -> 'reads' -> 'get_character_derived_stats') = public.get_character_derived_stats(c.id), '');
  -- build change on the row (ability score) -> counter bumped, cache missed, new value equals direct and differs from before
  d0 := x -> 'reads' -> 'get_character_derived_stats';
  perform pg_temp.as_admin();
  update public.characters set strength = coalesce(strength, 10) + 2 where id = c.id;
  perform pg_temp.as_owner(c.owner_id);
  r1 := pg_temp.crev(c.id);
  insert into pr values ('ability score change bumps the counter', r1 > r0, r0 || ' -> ' || r1);
  x := public.get_character_reads(c.id, array['get_character_derived_stats']);
  insert into pr values ('ability score change: derived recomputed', (x -> 'cache' ->> 'hits')::int = 0 and (x -> 'reads' -> 'get_character_derived_stats') = public.get_character_derived_stats(c.id)
    and (x -> 'reads' -> 'get_character_derived_stats') is distinct from d0, (x -> 'cache')::text);
  -- one counter bump per transaction even for several writes
  r0 := pg_temp.crev(c.id);
  perform pg_temp.as_admin();
  update public.characters set dexterity = coalesce(dexterity, 10) + 1 where id = c.id;
  update public.characters set dexterity = dexterity - 1, wisdom = coalesce(wisdom, 10) + 1 where id = c.id;
  insert into pr values ('several writes in one transaction: one bump', pg_temp.crev(c.id) = r0, '');
  -- child table (character_id column)
  r0 := pg_temp.crev(c.id);
  perform set_config('tl_cache.c' || md5(c.id::text || txid_current()::text), '', true);   -- new "transaction" for the dedupe marker
  update public.notes set content = content || ' ' where character_id = c.id and id = (select id from public.notes where character_id = c.id order by id limit 1);
  insert into pr values ('child table write bumps the counter', pg_temp.crev(c.id) > r0 or not exists (select 1 from public.notes where character_id = c.id), '');
  -- inventory_id table (inventory_events) -> the inventory's character
  select id into inv from public.inventories where character_id = c.id and kind = 'character';
  if inv is not null then
    r0 := pg_temp.crev(c.id);
    perform set_config('tl_cache.c' || md5(c.id::text || txid_current()::text), '', true);
    insert into public.inventory_events (inventory_id, action, metadata)
    select inv, (select action from public.inventory_events limit 1), '{}'::jsonb
    where exists (select 1 from public.inventory_events);
    insert into pr values ('inventory_id table write bumps the inventory''s character',
      not exists (select 1 from public.inventory_events) or pg_temp.crev(c.id) > r0, '');
  end if;
  -- global table (catalog): any real change bumps the global counter; a no-op update does not
  g0 := pg_temp.grev();
  perform set_config('tl_cache.g' || md5(txid_current()::text), '', true);
  update public.languages set name = name where id = (select min(id) from public.languages);
  insert into pr values ('no-op catalog update: global counter unchanged', pg_temp.grev() = g0, '');
  update public.languages set name = name || ' ' where id = (select min(id) from public.languages);
  insert into pr values ('catalog change bumps the global counter', pg_temp.grev() > g0, '');
  perform pg_temp.as_owner(c.owner_id);
  x := public.get_character_reads(c.id, (select array_agg(cc.n) from cacheable cc));
  insert into pr values ('catalog change: every read recomputed', (x -> 'cache' ->> 'hits')::int = 0, (x -> 'cache')::text);
  execute 'reset role';
end $$;

select chk || '  <-- ' || coalesce(detail, '') from pr where not ok;
select g || ': ' || count(*) filter (where ok) || ' passed, ' || count(*) filter (where not ok) || ' failed'
from (select regexp_replace(chk, ' \(.*\)$', '') g, ok from pr) x group by g order by g;
select 'TOTAL: ' || count(*) filter (where ok) || ' passed, ' || count(*) filter (where not ok) || ' failed' from pr;
rollback;
