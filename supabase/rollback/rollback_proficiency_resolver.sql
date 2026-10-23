-- =============================================================================
-- Rollback of 20261017001100_proficiency_resolver.sql ONLY: drops the read model (no data, nothing else depends on it).
-- =============================================================================
begin;
drop function if exists public.get_character_proficiencies(uuid);
drop function if exists public._proficiency_source(text, text, jsonb, text);
do $$
begin
  if to_regclass('supabase_migrations.schema_migrations') is not null then
    delete from supabase_migrations.schema_migrations where version = '20261017001100';
  end if;
end $$;

commit;
