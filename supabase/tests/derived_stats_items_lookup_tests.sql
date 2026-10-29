-- =============================================================================
-- Incident 2026-10-23, migration 20261029000100_derived_stats_items_lookup: the class item proficiencies of the derived
-- stats are looked up by primary key (no scan of the whole items catalog with the RLS check on every row), with the same
-- result. One transaction, rolled back; synthetic fixtures only. Runs once, with every migration and seed applied.
-- =============================================================================
\set ON_ERROR_STOP on
\pset format unaligned
\pset tuples_only on
begin;
\o /dev/null
create schema tl_test;
grant usage on schema tl_test to public;
create table tl_test.results (n serial, name text, ok boolean, detail text);
create function tl_test.rec(p_name text, p_ok boolean, p_detail text default '') returns void language plpgsql as $$
begin insert into tl_test.results (name, ok, detail) values (p_name, coalesce(p_ok, false), p_detail); end $$;
grant all on all functions in schema tl_test to public;
grant all on tl_test.results to public;
grant all on sequence tl_test.results_n_seq to public;

insert into auth.users (id, email) values ('a1111111-1111-1111-1111-1111111111e1', 'lookup@test'), ('b2222222-2222-2222-2222-2222222222e2', 'outsider@test');
select set_config('request.jwt.claim.sub', 'a1111111-1111-1111-1111-1111111111e1', true);
set local role authenticated;
insert into public.characters (id, owner_id, name, level, hp_max, hp_current)
  values ('c0000000-0000-0000-0000-0000000000e1', 'a1111111-1111-1111-1111-1111111111e1', 'Lookup Rogue', 1, 9, 9);
select public.set_character_class('c0000000-0000-0000-0000-0000000000e1', 'rogue-phb', 1, null);

-- function calls of this transaction only (pg_stat_get_xact_function_calls): one derived evaluation
reset role;
set local track_functions = 'all';
select coalesce(pg_stat_get_xact_function_calls('public._item_visible'::regproc), 0) as v0 \gset
set local role authenticated;
select public.get_character_derived_stats('c0000000-0000-0000-0000-0000000000e1') as d \gset
reset role;
select coalesce(pg_stat_get_xact_function_calls('public._item_visible'::regproc), 0) - :v0 as calls \gset
select tl_test.rec('L1 one derived evaluation checks item visibility for the looked-up items only (' || :calls || ' calls; the catalog has '
  || (select count(*) from public.items) || ' items)', :calls < 100, :calls::text);

-- the tool proficiency of the class is listed with the catalog name of its item (the lookup still resolves names)
select tl_test.rec('L2 class tool proficiency resolved to its catalog name',
  exists (select 1 from jsonb_array_elements((:'d')::jsonb -> 'proficiencies') p
          join public.items i on i.id = p ->> 'item_id'
          where p ->> 'source_type' = 'class' and p ->> 'proficiency_type' = 'tool' and p ->> 'name' = i.name),
  left((:'d')::jsonb -> 'proficiencies' ->> 0, 200));

-- RLS still applies to the looked-up rows: an outsider cannot read this character's derived stats at all
create function tl_test.outsider_sees() returns boolean language plpgsql as $$
declare d jsonb;
begin
  perform set_config('request.jwt.claim.sub', 'b2222222-2222-2222-2222-2222222222e2', true);
  perform set_config('role', 'authenticated', true);
  d := public.get_character_derived_stats('c0000000-0000-0000-0000-0000000000e1');
  perform set_config('role', 'postgres', true);
  return d is not null and d <> '{}'::jsonb and jsonb_array_length(coalesce(d -> 'proficiencies', '[]')) > 0;
exception when others then
  perform set_config('role', 'postgres', true);
  return false;
end $$;
select tl_test.rec('L3 an outsider still gets nothing', not tl_test.outsider_sees());
\o
select case when ok then 'PASSED' else 'FAILED' end || '  ' || name || case when ok then '' else '   <-- ' || coalesce(detail, '') end
from tl_test.results order by n;
select format('%s passed, %s failed', count(*) filter (where ok), count(*) filter (where not ok)) from tl_test.results;
select 1 / (count(*) filter (where not ok) = 0)::int as all_checks_passed from tl_test.results;
rollback;
