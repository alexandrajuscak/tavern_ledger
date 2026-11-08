-- Tests of 20261030000100_fluent_read_architecture.sql (local Supabase, run as supabase_admin; everything is rolled back).
-- Usage: docker exec -i supabase_db_tavern_ledger psql -U supabase_admin -d postgres -qAt -v ON_ERROR_STOP=1 < supabase/tests/fluent_read_tests.sql
-- Prints one line per check group and a TOTAL line (passed | failed).
begin;
set local track_functions = 'all';
create temp table fr (chk text, ok boolean, detail text) on commit drop;
grant all on fr to authenticated, anon;

-- 1. semantic equality: every read of the view / bundles equals the existing RPC or table query, as the owner AND as a
--    campaign DM of the character (RLS on), for every character.
do $$
declare c record; who record; v jsonb; b jsonb; n text; expect jsonb; got jsonb; i int := 0;
  rpcs constant text[] := array['get_character_derived_stats', 'get_character_proficiencies', 'get_character_lineage',
    'get_character_background', 'get_character_feats', 'get_character_class_summary', 'get_character_spell_slots',
    'get_character_class_features', 'get_character_resources', 'get_character_states', 'get_character_transformation',
    'get_character_infusions', 'get_character_governance', 'get_character_spellbook'];
begin
  for c in select id, owner_id, campaign_id from public.characters where owner_id is not null order by id loop
    for who in select c.owner_id as uid, 'owner' as kind
               union all select m.user_id, 'dm' from public.campaign_members m where m.campaign_id = c.campaign_id and m.role = 'dm' and m.user_id <> c.owner_id
    loop
      perform set_config('request.jwt.claims', json_build_object('sub', who.uid, 'role', 'authenticated')::text, true);
      execute 'set local role authenticated';
      v := public.get_character_view(c.id, 'spells');
      b := public.get_character_bundle(c.id, 'inventory');
      insert into fr values ('view has no read errors (' || who.kind || ')', v -> 'errors' = '{}'::jsonb, c.id::text || ' ' || (v -> 'errors')::text);
      insert into fr values ('memo off after view', coalesce(current_setting('tl_memo.token', true), '') = '', c.id::text);
      foreach n in array rpcs loop
        execute format('select public.%I($1)', n) into expect using c.id;
        insert into fr values ('eq ' || n || ' (' || who.kind || ')', (v -> 'reads' -> n) = expect, c.id::text);
      end loop;
      insert into fr values ('eq change_requests (' || who.kind || ')', (v -> 'reads' -> 'get_character_change_requests') = public.get_character_change_requests(c.id, false), c.id::text);
      insert into fr values ('eq characters row (' || who.kind || ')', (v -> 'reads' -> 'characters') = (select to_jsonb(x) from public.characters x where x.id = c.id), c.id::text);
      insert into fr values ('eq inventory_items order (' || who.kind || ')', (v -> 'reads' -> 'inventory_items') =
        (select coalesce(jsonb_agg(to_jsonb(x) order by x.sort_order, x.created_at), '[]') from public.inventory_items x where x.character_id = c.id), c.id::text);
      insert into fr values ('eq spells order (' || who.kind || ')', (v -> 'reads' -> 'spells') =
        (select coalesce(jsonb_agg(to_jsonb(x) order by x.level, x.sort_order, x.created_at), '[]') from public.spells x where x.character_id = c.id), c.id::text);
      insert into fr values ('eq companions count (' || who.kind || ')', jsonb_array_length(v -> 'reads' -> 'companions') =
        (select count(*) from public.character_companions x where x.character_id = c.id), c.id::text);
      insert into fr values ('eq inventory rows (' || who.kind || ')', (b -> 'reads' -> 'inventory_bundle' -> 'rows') =
        (select coalesce(jsonb_agg(to_jsonb(d) order by d.sort_order, d.acquired_at, d.id), '[]') from public.v_inventory_detail d
          where d.inventory_id = (b -> 'reads' -> 'inventory_bundle' ->> 'inventory_id')::uuid), c.id::text);
      -- the catalog rows the old path fetched: v_item_catalog for the rows' item ids, as this viewer (RLS decides visibility)
      insert into fr values ('inventory catalog == visible catalog rows (' || who.kind || ')',
        (select coalesce(jsonb_agg(ci ->> 'id' order by ci ->> 'id'), '[]') from jsonb_array_elements(b -> 'reads' -> 'inventory_bundle' -> 'catalog_items') ci)
        = (select coalesce(jsonb_agg(x.id order by x.id), '[]') from public.v_item_catalog x where x.id in (
            select r ->> 'item_id' from jsonb_array_elements(b -> 'reads' -> 'inventory_bundle' -> 'rows') r)), c.id::text);
      -- a batch of arbitrary reads (coalesced reloads) equals the same reads in the view
      got := public.get_character_reads(c.id, array['get_character_class_summary', 'get_character_resources', 'notes']);
      insert into fr values ('batch == view (' || who.kind || ')', (got -> 'reads' -> 'get_character_class_summary') = (v -> 'reads' -> 'get_character_class_summary')
        and (got -> 'reads' -> 'notes') = (v -> 'reads' -> 'notes') and (got -> 'reads' -> 'get_character_resources') = (v -> 'reads' -> 'get_character_resources'), c.id::text);
      execute 'reset role';
      i := i + 1;
    end loop;
  end loop;
  insert into fr values ('character x viewer combinations tested', i >= 35, i::text);
end $$;

-- 2. one rules evaluation per security context inside a view (core runs counted in this transaction)
do $$
declare c uuid; o uuid; n0 bigint; n1 bigint; n2 bigint;
begin
  select k.character_id, ch.owner_id into c, o from public.character_classes k join public.characters ch on ch.id = k.character_id
  group by 1, 2 order by count(*) desc limit 1;
  perform set_config('request.jwt.claims', json_build_object('sub', o, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  select coalesce(sum(calls), 0) into n0 from pg_stat_xact_user_functions where funcname = '_derived_stats_core';
  perform public.get_character_view(c, 'combat');
  select coalesce(sum(calls), 0) into n1 from pg_stat_xact_user_functions where funcname = '_derived_stats_core';
  perform public.get_character_derived_stats(c); perform public.get_character_derived_stats(c);
  select coalesce(sum(calls), 0) into n2 from pg_stat_xact_user_functions where funcname = '_derived_stats_core';
  execute 'reset role';
  insert into fr values ('view: at most 2 rules evaluations (invoker + definer; 0 when served from the read cache)', n1 - n0 between 0 and 2, (n1 - n0)::text);
  insert into fr values ('outside a bundle: 2 calls = 2 evaluations (memo off)', n2 - n1 = 2, (n2 - n1)::text);
end $$;

-- 3. denial: unrelated user, anonymous, unknown read, too many reads
do $$
declare cid uuid; other uuid := gen_random_uuid(); ok boolean;
begin
  insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at)
  values (other, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'fr-deny-' || other || '@example.test', now(), now());
  select id into cid from public.characters where owner_id is not null order by id limit 1;
  perform set_config('request.jwt.claims', json_build_object('sub', other, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  ok := false; begin perform public.get_character_view(cid, 'combat'); exception when others then ok := sqlstate = '42501'; end;
  insert into fr values ('deny unrelated: view 42501', ok, null);
  ok := false; begin perform public.get_character_bundle(cid, 'inventory'); exception when others then ok := sqlstate = '42501'; end;
  insert into fr values ('deny unrelated: inventory bundle 42501', ok, null);
  ok := false; begin perform public.get_character_reads(cid, array['notes']); exception when others then ok := sqlstate = '42501'; end;
  insert into fr values ('deny unrelated: reads 42501', ok, null);
  insert into fr values ('deny unrelated: revisions invisible', not exists (select 1 from public.character_revisions where character_id = cid), null);
  execute 'reset role';
  perform set_config('request.jwt.claims', '', true);
  execute 'set local role anon';
  ok := false; begin perform public.get_character_view(cid, 'combat'); exception when others then ok := sqlstate = '42501'; end;
  insert into fr values ('deny anonymous: view (no execute grant)', ok, null);
  ok := false; begin perform public.get_background_list(); exception when others then ok := sqlstate = '42501'; end;
  insert into fr values ('deny anonymous: background list (no execute grant)', ok, null);
  execute 'reset role';
  select owner_id into other from public.characters where id = cid;
  perform set_config('request.jwt.claims', json_build_object('sub', other, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  insert into fr values ('unknown read -> per-read error 22023', (public.get_character_reads(cid, array['notes', 'auth_users']) -> 'errors' -> 'auth_users' ->> 'code') = '22023', null);
  ok := false; begin perform public.get_character_reads(cid, array_fill('notes'::text, array[41])); exception when others then ok := sqlstate = '22023'; end;
  insert into fr values ('more than 40 reads -> 22023', ok, null);
  ok := false; begin perform public.get_character_view(cid, 'admin'); exception when others then ok := sqlstate = '22023'; end;
  insert into fr values ('unknown tab -> 22023', ok, null);
  execute 'reset role';
end $$;

-- 4. Background list / detail == catalog
do $$
declare cat jsonb := public.get_background_catalog(); lst jsonb := public.get_background_list(); v jsonb; bad int := 0;
begin
  insert into fr values ('background list has every catalog version', jsonb_array_length(lst -> 'versions') = jsonb_array_length(cat -> 'versions'), null);
  insert into fr values ('background list in catalog order', (select jsonb_agg(x ->> 'id') from jsonb_array_elements(lst -> 'versions') x)
    = (select jsonb_agg(x ->> 'id') from jsonb_array_elements(cat -> 'versions') x), null);
  for v in select x from jsonb_array_elements(cat -> 'versions') x loop
    if public.get_background_detail(v ->> 'id') is distinct from v then bad := bad + 1; end if;
  end loop;
  insert into fr values ('background detail == catalog version (all)', bad = 0, bad::text);
  insert into fr values ('background list < 10 % of catalog bytes', octet_length(lst::text) * 10 < octet_length(cat::text),
    octet_length(lst::text) || ' vs ' || octet_length(cat::text));
  insert into fr values ('background list has tools', jsonb_array_length(lst -> 'tools') > 0, null);
  insert into fr values ('unknown background detail -> null', public.get_background_detail('no-such-version') is null, null);
end $$;

-- 5. revisions: one log row per transaction and table, invisible to others; never breaks a write; DDL after DML still works
do $$
declare c uuid; o uuid; r0 bigint; r1 bigint; m0 bigint; m1 bigint; ok boolean := true;
begin
  select id, owner_id into c, o from public.characters where owner_id is not null order by id limit 1;
  select count(*), coalesce(max(id), 0) into r0, m0 from public.character_revisions where character_id = c and source_table = 'notes';
  update public.notes set content = coalesce(content, '') where character_id = c;     -- several rows, one statement
  update public.notes set content = coalesce(content, '') where character_id = c;     -- second statement, same transaction
  select count(*), coalesce(max(id), 0) into r1, m1 from public.character_revisions where character_id = c and source_table = 'notes';
  insert into fr values ('revision: exactly one log row per transaction', r1 = r0 + 1, r0 || ' -> ' || r1);
  insert into fr values ('revision: the new id is higher than every earlier one', m1 > m0, m0 || ' -> ' || m1);
  begin execute 'alter table public.notes enable trigger notes_revision'; exception when others then ok := false; end;
  insert into fr values ('DDL after DML in the same transaction works (no pending trigger events)', ok, null);
end $$;

-- a deleted character leaves no revision row and the delete succeeds (child rows cascade and fire the trigger)
do $$
declare o uuid; c uuid; ok boolean := true;
begin
  select owner_id into o from public.characters where owner_id is not null limit 1;
  insert into public.characters (owner_id, name) values (o, 'FR revision probe') returning id into c;
  update public.notes set content = 'probe' where character_id = c;   -- rows created by the characters_seed trigger
  begin delete from public.characters where id = c; exception when others then ok := false; end;
  insert into fr values ('character delete succeeds with revision triggers', ok, null);
  insert into fr values ('no orphan revision rows', not exists (select 1 from public.character_revisions r where not exists (select 1 from public.characters x where x.id = r.character_id)), null);
end $$;

insert into fr values ('character_revisions in the Realtime publication',
  exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'character_revisions'), null);
-- 21 + character_feats_revision and character_feat_choices_revision (20261107000100_feat_removal.sql)
insert into fr values ('23 revision triggers', (select count(*) from pg_trigger where tgname like '%\_revision' and not tgisinternal) = 23, null);
insert into fr values ('character_revisions: no write grant for authenticated',
  not has_table_privilege('authenticated', 'public.character_revisions', 'insert') and not has_table_privilege('authenticated', 'public.character_revisions', 'update'), null);
insert into fr values ('new functions: pinned search_path', not exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace
  and proname in ('get_character_reads', 'get_character_view', 'get_character_bundle', '_character_read', 'get_background_list', 'get_background_detail', '_bump_character_revision')
  and not exists (select 1 from unnest(proconfig) x where x like 'search_path=%')), null);

select chk, count(*) filter (where ok) as passed, count(*) filter (where not ok or ok is null) as failed,
  string_agg(distinct detail, ' | ') filter (where not ok or ok is null) as failing
from fr group by chk order by (count(*) filter (where not ok or ok is null)) desc, chk;
select 'TOTAL', count(*) filter (where ok), count(*) filter (where not ok or ok is null) from fr;
rollback;
