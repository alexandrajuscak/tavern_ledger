-- Rollback of 20261030000100_fluent_read_architecture.sql. Restores get_character_derived_stats exactly (as of
-- 20261029000100) and removes everything the migration added. Character data is not touched; character_revisions holds only
-- change counters. After running it: supabase migration repair --status reverted 20261030000100 (separate approval), and switch
-- the frontend to the legacy read path (js/config.js FLUENT_READS = 'off') BEFORE or together with this rollback.
begin;
do $$
declare t text;
begin
  foreach t in array array['inventory_items', 'character_equipment', 'character_proficiencies', 'character_lineages',
    'character_lineage_choices', 'character_backgrounds', 'character_transformations', 'character_spellcasting_sources',
    'character_spells', 'character_classes', 'character_spell_slot_state', 'character_temporary_spell_slots', 'character_resources',
    'character_feature_choices', 'character_optional_features', 'notes', 'spell_slots', 'feature_trackers', 'features', 'attacks', 'spells']
  loop
    execute format('drop trigger if exists %I on public.%I', t || '_revision', t);
  end loop;
  if exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'character_revisions') then
    execute 'alter publication supabase_realtime drop table public.character_revisions';
  end if;
end $$;
drop function if exists public.get_character_view(uuid, text);
drop function if exists public.get_character_bundle(uuid, text);
drop function if exists public.get_character_reads(uuid, text[]);
drop function if exists public._character_read_set(text);
drop function if exists public._character_read(uuid, text);
drop function if exists public.get_background_list();
drop function if exists public.get_background_detail(text);
drop function if exists public._bump_character_revision() cascade;
drop table if exists public.character_revisions;
create or replace function public.get_character_derived_stats(p_character uuid)
returns jsonb language sql stable set search_path to 'public', 'pg_temp'
as $function$ select public._wild_shape_layer(p_character, public._feat_layer(p_character, public._derived_stats_full(p_character))) $function$;
create or replace function public._derived_stats_levels(p_character uuid)
 returns jsonb language plpgsql stable set search_path to 'public', 'pg_temp'
as $function$
declare d jsonb; li jsonb;
begin
  d := public._derived_stats_core(p_character);                      -- RLS: owner, campaign DM, admin
  li := public._character_level_info(p_character);
  return d || jsonb_build_object(
    'level', li,
    'proficiency_bonus', (d -> 'proficiency_bonus') || jsonb_build_object(
      'source', 'total_level', 'level', (li ->> 'total_level')::int, 'level_source', li ->> 'source',
      'fallback', (li ->> 'fallback')::boolean));
end;
$function$;
commit;
notify pgrst, 'reload schema';
