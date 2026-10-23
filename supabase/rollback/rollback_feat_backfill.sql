-- Rollback of 20261019000800_feat_backfill.sql ONLY. The backfill created feat resources / spell sources that the feat
-- engine of 20261019000300 manages anyway (they are removed with rollback_feat_catalog.sql), so only the migration record
-- is removed here.
begin;
do $$
begin
  if to_regclass('supabase_migrations.schema_migrations') is not null then
    delete from supabase_migrations.schema_migrations where version = '20261019000800';
  end if;
end $$;
commit;
