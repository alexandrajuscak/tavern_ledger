-- One md5 over every spell catalog / class foundation table. Used by the runners to prove that loading
-- supabase/seed/spells.sql a second time changes nothing.
select md5(string_agg(t || ':' || h, ',' order by t)) from (
  select 'catalog_spells' t, md5(coalesce(string_agg(x::text, '|' order by x::text), '')) h from (select id, name, owner_id, campaign_id from public.catalog_spells) x union all
  select 'spell_versions', md5(coalesce(string_agg(x::text, '|' order by x::text), '')) from (select v.id, v.name, v.level, v.school_id, v.casting_time_raw, v.range_raw, v.duration_raw,
    v.requires_concentration, v.is_ritual, v.components_raw, v.material_cost_gp, v.material_consumed, v.mechanism, v.automation, v.source_label,
    v.status, v.rule_status, v.source_marker, v.setting, v.superseded_by_version_id from public.spell_versions v) x union all
  select 'spell_effects', md5(coalesce(string_agg(x::text, '|' order by x::text), '')) from public.spell_effects x union all
  select 'spell_effect_damage_types', md5(coalesce(string_agg(x::text, '|' order by x::text), '')) from public.spell_effect_damage_types x union all
  select 'spell_damage_type_links', md5(coalesce(string_agg(x::text, '|' order by x::text), '')) from public.spell_damage_type_links x union all
  select 'classes', md5(coalesce(string_agg(x::text, '|' order by x::text), '')) from public.classes x union all
  select 'class_versions', md5(coalesce(string_agg(x::text, '|' order by x::text), '')) from public.class_versions x union all
  select 'class_spell_lists', md5(coalesce(string_agg(x::text, '|' order by x::text), '')) from public.class_spell_lists x union all
  select 'class_spell_list_entries', md5(coalesce(string_agg(x::text, '|' order by x::text), '')) from public.class_spell_list_entries x) s;
