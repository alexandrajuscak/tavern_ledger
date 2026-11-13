-- =============================================================================
-- Rollback of 20261112000400_item_knowledge_reveal.sql (exact: the migration replaced no existing object; it only added the
-- objects dropped here). Run as postgres in ONE transaction:
--   psql -v ON_ERROR_STOP=1 -1 -f supabase/rollback/rollback_item_knowledge_reveal.sql
-- Data kept on purpose (T4 tables, read by the T4 code exactly as before): character_item_knowledge records created by the
-- backfill or by dm_set_item_knowledge, inventory_item_knowledge rows it gave to undisguised rows, the names / descriptions the
-- sync wrote, items.secret as set, the audit events. Lost: the reveal history (export it first if it matters:
--   select * from public.item_knowledge_events;).
-- Deploy order for a rollback: the previous frontend (?v=25) first, then this file.
-- =============================================================================
drop trigger if exists item_knowledge_log on public.character_item_knowledge;
drop function if exists public.dm_set_item_knowledge(text, uuid[], text[], text, uuid);
drop function if exists public.get_item_knowledge_overview(text, uuid);
drop function if exists public.get_campaign_knowledge_items(uuid);
drop function if exists public._item_knowledge_backfill();
drop function if exists public._ik_fingerprint(uuid, text);
drop function if exists public._ik_rank(text, text[]);
drop function if exists public._item_knowledge_log();
drop table if exists public.item_knowledge_events;
do $$
begin
  if to_regclass('supabase_migrations.schema_migrations') is not null then
    delete from supabase_migrations.schema_migrations where version = '20261112000400';
  end if;
end $$;
notify pgrst, 'reload schema';
