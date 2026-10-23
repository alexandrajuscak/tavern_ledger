-- One md5 over the class feature catalog (official and test rows, including updated_at). Used by the runners to prove that
-- loading supabase/seed/class_features.sql a second time (and classes.sql / spells.sql in between) changes nothing.
select md5(string_agg(t || ':' || h, ',' order by t)) from (
  select 'subclasses' t, md5(coalesce(string_agg(x::text, '|' order by x::text), '')) h from public.subclasses x union all
  select 'subclass_versions', md5(coalesce(string_agg(x::text, '|' order by x::text), '')) from public.subclass_versions x union all
  select 'class_versions', md5(coalesce(string_agg(x::text, '|' order by x::text), '')) from public.class_versions x union all
  select 'class_features', md5(coalesce(string_agg(x::text, '|' order by x::text), '')) from public.class_features x union all
  select 'class_feature_versions', md5(coalesce(string_agg(x::text, '|' order by x::text), '')) from public.class_feature_versions x union all
  select 'class_feature_unlocks', md5(coalesce(string_agg(x::text, '|' order by x::text), '')) from public.class_feature_unlocks x union all
  select 'class_feature_scaling', md5(coalesce(string_agg(x::text, '|' order by x::text), '')) from public.class_feature_scaling x union all
  select 'class_feature_choices', md5(coalesce(string_agg(x::text, '|' order by x::text), '')) from public.class_feature_choices x union all
  select 'class_feature_choice_options', md5(coalesce(string_agg(x::text, '|' order by x::text), '')) from public.class_feature_choice_options x union all
  select 'class_feature_effects', md5(coalesce(string_agg(x::text, '|' order by x::text), '')) from public.class_feature_effects x union all
  select 'class_feature_resources', md5(coalesce(string_agg(x::text, '|' order by x::text), '')) from public.class_feature_resources x union all
  select 'class_starting_equipment', md5(coalesce(string_agg(x::text, '|' order by x::text), '')) from public.class_starting_equipment x union all
  select 'languages', md5(coalesce(string_agg(x::text, '|' order by x::text), '')) from public.languages x) s;
