-- Checksum of the background catalog (the seed must be idempotent: running backgrounds.sql again keeps it unchanged).
select md5(string_agg(t, '|' order by t)) from (
  select 'v' || to_jsonb(v)::text as t from public.background_versions v
  union all select 'a' || to_jsonb(x)::text from public.background_ability_options x
  union all select 'g' || to_jsonb(x)::text from public.background_proficiency_grants x
  union all select 'c' || to_jsonb(x)::text from public.background_choices x
  union all select 'o' || to_jsonb(x)::text from public.background_choice_options x
  union all select 'f' || to_jsonb(x)::text from public.background_feat_grants x
  union all select 'p' || to_jsonb(x)::text from public.background_equipment_packages x
  union all select 'e' || to_jsonb(x)::text from public.background_equipment_entries x
  union all select 'r' || to_jsonb(x)::text from public.background_features x
  union all select 't' || to_jsonb(x)::text from public.background_characteristic_tables x
  union all select 'k' || to_jsonb(x)::text from public.feats x) s;
