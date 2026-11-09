-- Rollback of 20261109000200_active_feature_timing.sql: the table is new and only read by the Play presentation.
begin;
drop table if exists public.catalog_play_timing;
commit;
