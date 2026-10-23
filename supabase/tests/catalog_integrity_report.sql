-- V6.2 catalog referential-integrity report (READ ONLY; docs/V62_ADVERSARIAL_HARDENING_REVIEW.md).
-- Covers the reference columns that have no foreign key (found with information_schema) plus a few semantic checks.
-- Every row prints "<check>|<dangling count>"; 0 everywhere is the expected result.
-- Usage: docker exec -i supabase_db_tavern_ledger psql -U postgres -qAt < supabase/tests/catalog_integrity_report.sql
begin transaction read only;
select 'items.content_version_id -> dm_content_versions', count(*) from public.items x
  where x.content_version_id is not null and not exists (select 1 from public.dm_content_versions v where v.id::text = x.content_version_id::text)
union all select 'spell_versions.content_version_id -> dm_content_versions', count(*) from public.spell_versions x
  where x.content_version_id is not null and not exists (select 1 from public.dm_content_versions v where v.id::text = x.content_version_id::text)
union all select 'feat_versions.content_version_id -> dm_content_versions', count(*) from public.feat_versions x
  where x.content_version_id is not null and not exists (select 1 from public.dm_content_versions v where v.id::text = x.content_version_id::text)
union all select 'creatures.content_version_id -> dm_content_versions', count(*) from public.creatures x
  where x.content_version_id is not null and not exists (select 1 from public.dm_content_versions v where v.id::text = x.content_version_id::text)
union all select 'lineage_versions.content_version_id -> dm_content_versions', count(*) from public.lineage_versions x
  where x.content_version_id is not null and not exists (select 1 from public.dm_content_versions v where v.id::text = x.content_version_id::text)
union all select 'background_versions.content_version_id -> dm_content_versions', count(*) from public.background_versions x
  where x.content_version_id is not null and not exists (select 1 from public.dm_content_versions v where v.id::text = x.content_version_id::text)
union all select 'published dm_content_versions.catalog_ref -> its catalog', count(*) from public.dm_content_versions v join public.dm_content c on c.id = v.content_id
  where v.catalog_ref is not null and not case c.content_type
    when 'item' then exists (select 1 from public.items i where i.id::text = v.catalog_ref)
    when 'spell' then exists (select 1 from public.spell_versions s where s.id::text = v.catalog_ref)
    when 'feat' then exists (select 1 from public.feat_versions f where f.id::text = v.catalog_ref)
    when 'creature' then exists (select 1 from public.creatures k where k.id::text = v.catalog_ref)
    else true end
union all select 'feat_effects.option_id -> feat_choice_options', count(*) from public.feat_effects x
  where x.option_id is not null and not exists (select 1 from public.feat_choice_options o where o.option_id::text = x.option_id::text)
union all select 'feat_choices.parent_option_id -> feat_choice_options', count(*) from public.feat_choices x
  where x.parent_option_id is not null and not exists (select 1 from public.feat_choice_options o where o.option_id::text = x.parent_option_id::text)
union all select 'feat_effects.effect_type known to the engine', count(*) from public.feat_effects x
  where x.effect_type not in ('speed_bonus', 'ac_bonus', 'initiative_bonus', 'hp_per_level', 'hp_flat', 'ability_bonus', 'save_bonus', 'attack_bonus',
                              'damage_bonus', 'resistance', 'proficiency', 'expertise', 'sense', 'informational', 'attack')
union all select 'background_equipment_entries.category_id -> item_categories', count(*) from public.background_equipment_entries x
  where x.category_id is not null and not exists (select 1 from public.item_categories o where o.id::text = x.category_id::text)
union all select 'character_active_states.feature_version_id -> class_feature_versions', count(*) from public.character_active_states x
  where x.feature_version_id is not null and not exists (select 1 from public.class_feature_versions o where o.id::text = x.feature_version_id::text)
union all select 'character_transformation_events.creature_id -> creatures (history may outlive a creature)', count(*) from public.character_transformation_events x
  where x.creature_id is not null and not exists (select 1 from public.creatures o where o.id::text = x.creature_id::text)
union all select 'unidentified items whose audit event names them to the party (pre-V6.2 rows, now filtered on read)', count(*)
  from public.campaign_audit_events e where e.event_type = 'item_assigned' and e.visibility <> 'dm' and public._audit_item_hidden(e.event_type, e.character_id, e.after);
rollback;
