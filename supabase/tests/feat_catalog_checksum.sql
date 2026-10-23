-- Checksum of the official feat catalog (feat_versions + typed child rows); a second run of feats.sql must not change it.
select md5(string_agg(x, '|' order by x)) from (
  select 'v' || to_jsonb(v)::text as x from public.feat_versions v where v.owner_id is null
  union all select 'f' || to_jsonb(f)::text from public.feats f where f.owner_id is null
  union all select 'p' || to_jsonb(p)::text from public.feat_prerequisites p
  union all select 'c' || to_jsonb(c)::text from public.feat_choices c
  union all select 'o' || to_jsonb(o)::text from public.feat_choice_options o
  union all select 'e' || to_jsonb(e)::text from public.feat_effects e
  union all select 's' || to_jsonb(s)::text from public.feat_spell_grants s
  union all select 'r' || to_jsonb(r)::text from public.feat_resource_grants r) t;
