-- Rollback of 20261106000100_combat_builder_schema.sql (after rollback_combat_builder_functions.sql).
-- DELETES every encounter, participant, effect, reminder, combat history row, favorite and the combat catalog rows
-- (combat_monsters, creature_legendary_actions, combat_conditions). Nothing outside these tables is touched; public.creatures
-- and the Wild Shape tables are unchanged by the migration. Back up first if encounters must be kept.
begin;
do $$
begin
  if exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'combat_changes') then
    execute 'alter publication supabase_realtime drop table public.combat_changes';
  end if;
end $$;
alter table if exists public.combat_encounters drop constraint if exists combat_encounters_current_fk;
drop table if exists public.combat_changes, public.combat_events, public.combat_reminders, public.combat_effects, public.combat_participants,
  public.combat_statblocks, public.combat_encounters, public.combat_monster_favorites, public.combat_conditions, public.creature_legendary_actions,
  public.combat_monsters;
drop function if exists public._combat_can_see(uuid);
drop function if exists public._combat_can_run(uuid);
drop function if exists tl_cache.combat_skip();
commit;
