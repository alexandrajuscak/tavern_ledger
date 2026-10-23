-- One md5 over every lineage catalog table (and source_books, which the lineage seed extends). Used by the runners to
-- prove that loading supabase/seed/lineages.sql a second time changes nothing.
select md5(string_agg(t || ':' || h, ',' order by t)) from (
  select 'languages' t, md5(coalesce(string_agg(x::text, '|' order by x::text), '')) h from public.languages x union all
  select 'lineages', md5(coalesce(string_agg(x::text, '|' order by x::text), '')) from public.lineages x union all
  select 'versions', md5(coalesce(string_agg(x::text, '|' order by x::text), '')) from public.lineage_versions x union all
  select 'traits', md5(coalesce(string_agg(x::text, '|' order by x::text), '')) from public.lineage_traits x union all
  select 'trait_replacements', md5(coalesce(string_agg(x::text, '|' order by x::text), '')) from public.lineage_trait_replacements x union all
  select 'choices', md5(coalesce(string_agg(x::text, '|' order by x::text), '')) from public.lineage_choices x union all
  select 'options', md5(coalesce(string_agg(x::text, '|' order by x::text), '')) from public.lineage_choice_options x union all
  select 'option_replacements', md5(coalesce(string_agg(x::text, '|' order by x::text), '')) from public.lineage_option_replacements x union all
  select 'effects', md5(coalesce(string_agg(x::text, '|' order by x::text), '')) from public.lineage_trait_effects x union all
  select 'source_books', md5(coalesce(string_agg(x::text, '|' order by x::text), '')) from public.source_books x) s;
