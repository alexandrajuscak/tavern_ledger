-- One md5 over every class progression table. Used by the runners to prove that loading supabase/seed/classes.sql a
-- second time (and spells.sql in between) changes nothing.
select md5(string_agg(t || ':' || h, ',' order by t)) from (
  select 'classes' t, md5(coalesce(string_agg(x::text, '|' order by x::text), '')) h from public.classes x union all
  select 'class_versions', md5(coalesce(string_agg(x::text, '|' order by x::text), '')) from public.class_versions x union all
  select 'class_version_levels', md5(coalesce(string_agg(x::text, '|' order by x::text), '')) from public.class_version_levels x union all
  select 'subclass_versions', md5(coalesce(string_agg(x::text, '|' order by x::text), '')) from public.subclass_versions x union all
  select 'subclass_version_levels', md5(coalesce(string_agg(x::text, '|' order by x::text), '')) from public.subclass_version_levels x union all
  select 'spell_slot_progressions', md5(coalesce(string_agg(x::text, '|' order by x::text), '')) from public.spell_slot_progressions x union all
  select 'spell_slot_progression_levels', md5(coalesce(string_agg(x::text, '|' order by x::text), '')) from public.spell_slot_progression_levels x) s;
