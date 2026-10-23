-- =============================================================================
-- Removes the OFFICIAL class feature catalog content of supabase/seed/class_features.sql (no schema change): official
-- class features (with their versions, unlocks, scaling, choices, options, effects, resources), the official subclass
-- catalog except the two spellcasting subclasses of classes.sql, the starting equipment options and the class version
-- metadata columns' values. Synthetic test content (content_scope = 'test') is not touched.
-- DESTROYS CHARACTER STATE OF OFFICIAL FEATURES: stored choices, optional-feature selections and class resource state rows
-- of official features go with the catalog rows (cascade). Class rows, levels, spells, inventory and lineages are kept.
-- Refuses to run while a character uses a catalog subclass (other than Eldritch Knight / Arcane Trickster): change or
-- clear that subclass first. Run before rollback_class_engine_extensions.sql. Re-load with supabase/seed/class_features.sql.
-- =============================================================================
begin;

do $$
begin
  if exists (select 1 from public.character_classes cc join public.subclass_versions s on s.id = cc.subclass_version_id
             where s.content_scope = 'official' and s.implementation_status <> 'progression_only') then
    raise exception 'Characters still use a subclass of the official catalog; clear it first (or keep the catalog)';
  end if;
end $$;

-- infusion item modifiers (20261017000900): refused while an item holds one; removed with the catalog
do $$
begin
  if to_regclass('public.character_infusions') is not null and exists (select 1 from public.character_infusions) then
    raise exception 'Characters still have infused items; end the infusions first (or keep the catalog)';
  end if;
  if exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'item_modifiers' and column_name = 'managed_by') then
    execute 'delete from public.item_modifiers where managed_by is not null';
  end if;
end $$;

delete from public.class_features where content_scope = 'official';
delete from public.class_starting_equipment;
delete from public.subclass_versions where content_scope = 'official' and implementation_status <> 'progression_only';
delete from public.subclasses s where s.content_scope = 'official'
  and not exists (select 1 from public.subclass_versions v where v.subclass_id = s.id);
update public.class_versions set primary_abilities = '{}', saving_throws = '{}', skill_choice = null, multiclass_skill_choice = null,
  proficiency_lines = '{}', starting_gold = null, feature_status = 'not_started', feature_notes = null
where content_scope = 'official';
update public.subclass_versions set dependency_group = null, feature_notes = null, source_status = 'official'
where content_scope = 'official';

commit;
