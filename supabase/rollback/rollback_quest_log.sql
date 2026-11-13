-- =============================================================================
-- Rollback of 20261114000400_quest_log.sql. Run as postgres in ONE transaction:
--   psql -v ON_ERROR_STOP=1 -1 -f supabase/rollback/rollback_quest_log.sql
-- Drops the quest RPCs, helpers and the three quest tables. No existing object or row is changed (the migration replaced no
-- function and touched no existing table).
-- Data LOST on purpose (it only exists because of this feature; export it first if it matters):
--   select * from public.quests; select * from public.quest_objectives; select * from public.quest_dm_notes;
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

drop table if exists public.quest_dm_notes;
drop table if exists public.quest_objectives;
drop table if exists public.quests;

notify pgrst, 'reload schema';
