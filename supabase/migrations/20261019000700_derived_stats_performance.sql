-- =============================================================================
-- 20261019000700: _character_mods computes the derived stats ONCE.
-- The SQL version (20261015001700) is inlined by the planner, which then evaluated get_character_derived_stats once per
-- ability key (7 times per call). With the feat layer of 20261019000300 every evaluation reads the feat grants as well, so
-- get_character_resources / get_character_spell_slots took 1.3 s for a multiclass character. Same result, one evaluation.
-- Rollback: supabase/rollback/rollback_derived_stats_performance.sql
-- =============================================================================

create or replace function public._character_mods(p_character uuid)
returns jsonb
language plpgsql stable
set search_path = public, pg_temp
as $$
declare d jsonb := public.get_character_derived_stats(p_character);
begin
  return (select jsonb_object_agg(k, (d -> 'abilities' -> k ->> 'modifier')::int) from jsonb_object_keys(d -> 'abilities') k);
end;
$$;
