-- =============================================================================
-- Rollback of 20261017000600_class_setup_flow.sql ONLY: drops the Add Class preview, the starting equipment functions and
-- the record of applied starting equipment. Items already added to inventories stay (ordinary inventory rows).
-- =============================================================================
begin;
drop function if exists public.preview_character_class_add(uuid, text, int, text);
drop function if exists public.apply_class_starting_equipment(uuid, text, jsonb);
drop function if exists public.get_class_starting_equipment(text);
drop function if exists public._starting_equipment_candidates(jsonb);
drop table if exists public.character_starting_equipment;
do $$
begin
  if to_regclass('supabase_migrations.schema_migrations') is not null then
    delete from supabase_migrations.schema_migrations where version = '20261017000600';
  end if;
end $$;

commit;
