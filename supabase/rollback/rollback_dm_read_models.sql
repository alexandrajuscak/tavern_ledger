-- =============================================================================
-- Rollback of 20261019000600_dm_read_models.sql ONLY: the DM Space read models. No data is stored by that migration.
-- =============================================================================
begin;

drop function if exists public.get_dm_overview(uuid), public.get_dm_party(uuid, uuid[]), public._dm_party_row(uuid), public.get_my_dm_campaigns();

do $$
begin
  if to_regclass('supabase_migrations.schema_migrations') is not null then
    delete from supabase_migrations.schema_migrations where version = '20261019000600';
  end if;
end $$;

commit;
