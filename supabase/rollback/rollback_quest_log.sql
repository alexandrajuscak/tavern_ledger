-- =============================================================================
-- Rollback of 20261114000400_quest_log.sql. Run as postgres in ONE transaction:
--   psql -v ON_ERROR_STOP=1 -1 -f supabase/rollback/rollback_quest_log.sql
-- Drops the quest RPCs and helpers and KEEPS every quest row: the three tables are RENAMED (not dropped) to
--   quests_rb_20261114, quest_objectives_rb_20261114, quest_dm_notes_rb_20261114
-- (with their primary keys and indexes, so a later reapply of the migration creates fresh tables without a name clash). They
-- stay inert: RLS on, no grants for anon / authenticated, not in the Realtime publication, no function reads them; their
-- tl_cache_rev triggers stay tl_cache.skip(). If a *_rb_20261114 table already exists (a second rollback), the suffix gets a
-- timestamp: _rb_20261114_<YYYYMMDDHH24MISS>. No existing object or row is changed (the migration replaced no function).
-- RESTORE after reapplying 20261114000400 (as postgres, one transaction; same column order, ids kept):
--   insert into public.quests select * from public.quests_rb_20261114;
--   insert into public.quest_objectives select * from public.quest_objectives_rb_20261114;
--   insert into public.quest_dm_notes select * from public.quest_dm_notes_rb_20261114;
-- then check the counts and only afterwards drop the three *_rb_20261114 tables by hand. The renamed tables keep their
-- foreign keys (a deleted campaign still removes its quests; a deleted target character still sets target_character_id null),
-- so the copied rows are consistent with the live data.
-- Deploy order for a rollback: the previous frontend (?v=31) first, then this file.
-- =============================================================================
set local lock_timeout = '5s';

drop function if exists public.get_character_quests(uuid);
drop function if exists public.get_campaign_quests(uuid, boolean);
drop function if exists public.dm_save_quest(uuid, jsonb, int);
drop function if exists public.dm_set_quest_status(uuid, text);
drop function if exists public.dm_set_quest_objective(uuid, boolean);
drop function if exists public.dm_archive_quest(uuid, boolean);
drop function if exists public.dm_reorder_quests(uuid, uuid[]);
drop function if exists public._quest_dm_json(uuid);
drop function if exists public._quest_objectives_json(uuid);
drop function if exists public._quest_status_rank(text);
drop function if exists public._quest_dm_gate(uuid);

do $$
declare sfx text := '_rb_20261114'; t text; r record;
begin
  if to_regclass('public.quests_rb_20261114') is not null or to_regclass('public.quest_objectives_rb_20261114') is not null
     or to_regclass('public.quest_dm_notes_rb_20261114') is not null then
    sfx := sfx || '_' || to_char(clock_timestamp(), 'YYYYMMDDHH24MISS');
  end if;
  foreach t in array array['quests', 'quest_objectives', 'quest_dm_notes'] loop
    if to_regclass('public.' || t) is null then continue; end if;
    -- every index of the table (primary key included) gets the suffix too: index names are unique per schema
    for r in select ic.relname from pg_index i join pg_class ic on ic.oid = i.indexrelid where i.indrelid = ('public.' || t)::regclass loop
      execute format('alter index public.%I rename to %I', r.relname, r.relname || sfx);
    end loop;
    execute format('alter table public.%I rename to %I', t, t || sfx);
  end loop;
end $$;

notify pgrst, 'reload schema';
