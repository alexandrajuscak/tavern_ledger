-- Rollback of 20261019000700_derived_stats_performance.sql ONLY: the SQL _character_mods of 20261015001700.
begin;
create or replace function public._character_mods(p_character uuid)
returns jsonb
language sql stable
set search_path = public, pg_temp
as $$
  select jsonb_object_agg(k, (d -> 'abilities' -> k ->> 'modifier')::int)
  from (select public.get_character_derived_stats(p_character) as d) x, jsonb_object_keys(x.d -> 'abilities') k;
$$;
do $$
begin
  if to_regclass('supabase_migrations.schema_migrations') is not null then
    delete from supabase_migrations.schema_migrations where version = '20261019000700';
  end if;
end $$;
commit;
