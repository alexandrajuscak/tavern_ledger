-- Rollback of 20261030000200_progressive_fluent_reads.sql. Set js/config.js FLUENT_READS = 'off' (or ship the previous
-- frontend) first: the progressive client calls get_character_shell. Removes the read cache (schema tl_cache, its counter
-- trigger on every public table), get_character_shell and the starting-equipment candidate grant, and restores
-- get_character_reads / _character_read_set exactly as 20261030000100 defined them. No player data is touched.
-- Then (separate decision, never to hide a mismatch): supabase migration repair --status reverted 20261030000200
begin;
drop function if exists public.get_character_shell(uuid);
drop schema if exists tl_cache cascade;   -- the tl_cache_rev triggers depend on tl_cache.bump and go with it
revoke execute on function public._starting_equipment_candidates(jsonb) from authenticated;

create or replace function public.get_character_reads(p_character uuid, p_reads text[])
returns jsonb language plpgsql volatile set search_path = public, pg_temp as $$
declare n text; ok jsonb := '{}'; err jsonb := '{}'; started timestamptz := clock_timestamp();
begin
  if p_character is null or auth.uid() is null or not public.can_access_character(p_character) then
    raise exception 'Character not found' using errcode = '42501';
  end if;
  if coalesce(cardinality(p_reads), 0) = 0 or cardinality(p_reads) > 40 then
    raise exception 'Between 1 and 40 reads' using errcode = '22023';
  end if;
  perform set_config('tl_memo.token', md5(random()::text || clock_timestamp()::text), true);
  for n in select distinct x from unnest(p_reads) x loop
    begin
      ok := ok || jsonb_build_object(n, public._character_read(p_character, n));
    exception
      when query_canceled then raise;   -- a statement timeout ends the whole request, never only one part
      when others then err := err || jsonb_build_object(n, jsonb_build_object('code', sqlstate, 'message', sqlerrm));
    end;
  end loop;
  perform set_config('tl_memo.token', '', true);
  return jsonb_build_object('character_id', p_character, 'reads', ok, 'errors', err,
    'server_ms', round(extract(epoch from clock_timestamp() - started) * 1000));
end $$;

-- the reads every mounted sheet needs (header, vitals, Play, Abilities, Build, Bio); Spells and Inventory are domains of their own
create or replace function public._character_read_set(p_domain text)
returns text[] language sql immutable as $$
  select case p_domain
    when 'shell' then array['characters', 'inventory_items', 'notes', 'spell_slots', 'feature_trackers', 'features', 'attacks', 'spells',
      'get_character_derived_stats', 'get_character_proficiencies', 'get_character_lineage', 'get_character_background',
      'get_character_feats', 'get_character_class_summary', 'get_character_spell_slots', 'get_character_class_features',
      'get_character_resources', 'get_character_states', 'get_character_transformation', 'companions', 'get_character_infusions',
      'starting_equipment_applied', 'primary_class_starting_equipment', 'get_character_governance', 'get_character_change_requests',
      'revisions']
    when 'spells' then array['get_character_spellbook']
    when 'inventory' then array['inventory_bundle']
  end $$;

notify pgrst, 'reload schema';
commit;
