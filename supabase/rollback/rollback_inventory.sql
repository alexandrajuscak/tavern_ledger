-- =============================================================================
-- Rollback of every migration after the base schema: the inventory migrations 20261015000100 ... 20261015001800 (incl.
-- derived stats, lineages, spells, class levels and the class feature engine) and the class catalog migrations 20261017*
-- (engine extensions, class page read model; their tables and columns go with the tables dropped below) and the 20261019*
-- governance / feat / DM content migrations.
-- Restores the base schema's inventory_items (columns, grants, policy) and the legacy `equipped` values.
-- DESTRUCTIVE for data that exists only in the new model (catalog, events, party stash / shop / NPC
-- inventories, owned assets, homebrew items). Legacy character inventory rows are kept.
-- Take a backup first. Review before use. With the Supabase CLI locally, `supabase db reset` is simpler.
-- =============================================================================
begin;

-- governance, requests, feats, DM content, hidden data, DM read models (20261019*): base-table triggers first (they would call
-- functions whose tables are gone), then the tables; the functions of the dropped tables go with the cascades below or stay
-- unused. The 11 base tables keep their data.
drop function if exists public.characters_governance(), public.character_children_governance(), public.campaigns_governance_default(),
  public._audit_build_change(), public._feat_sync_trigger(), public._dm_item_secrets_sync() cascade;
drop table if exists public.inventory_item_knowledge, public.item_secrets, public.character_condition_secrets, public.character_conditions,
  public.dm_character_notes, public.dm_content_events, public.dm_content_versions, public.dm_content, public.character_feat_choices,
  public.character_feats, public.feat_attack_grants, public.feat_resource_grants, public.feat_spell_grants, public.feat_effects,
  public.feat_choice_options, public.feat_choices, public.feat_prerequisites, public.feat_versions, public.change_request_private_notes,
  public.change_request_events, public.change_requests, public.change_request_ops, public.campaign_audit_events,
  public.governance_migration_report, public.character_governance, public.campaign_policy_overrides, public.campaign_governance,
  public.governance_actions cascade;
-- every function the 20261019* migrations create (none of these names existed before them), all overloads
do $$
declare f regprocedure;
begin
  for f in select p.oid::regprocedure from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname = any (array[
    '_audit', '_audit_build_change', '_campaign_governance_json', '_character_feat_choice_values',
    '_character_feat_effects', '_character_feat_grants', '_character_feat_placeholders', '_character_feature_effects',
    '_content_policy_reason', '_cr_apply', '_cr_baseline', '_cr_can_review', '_cr_diff', '_cr_event', '_cr_exec_op',
    '_cr_json', '_cr_mark_stale', '_cr_normalize_op', '_cr_normalize_ops', '_cr_resolve', '_cr_simulate',
    '_cr_snapshot', '_dm_add_item', '_dm_can_manage', '_dm_catalog_json', '_dm_content_json', '_dm_event',
    '_dm_hidden_gate', '_dm_item_secrets_sync', '_dm_materialize', '_dm_party_row', '_dm_set_catalog_archived',
    '_dm_short', '_dm_try', '_dm_usage', '_feat_choice_value_error', '_feat_hp_bonus', '_feat_layer',
    '_feat_pick_error', '_feat_prereq_ctx', '_feat_prereq_eval', '_feat_resource_key', '_feat_sync_trigger',
    '_feat_version_json', '_gov_content_check', '_gov_content_gate', '_gov_decide', '_gov_gate', '_gov_gate_add_item',
    '_gov_gate_background', '_gov_gate_class', '_gov_gate_class_row', '_gov_gate_companion',
    '_gov_gate_feature_choice', '_gov_gate_inventory', '_gov_gate_item', '_gov_gate_item_quantity',
    '_gov_gate_lineage', '_gov_gate_resource_row', '_gov_gate_source_row', '_gov_gate_spell', '_gov_gate_spell_row',
    '_gov_gate_wild_shape_settings', '_gov_lock_blocks', '_gov_policy', '_gov_rank', '_item_visible',
    '_store_feat_choices', '_sync_character_feats', 'add_change_request_op', 'apply_character_condition',
    'archive_dm_content', 'assign_character_feat', 'campaigns_governance_default', 'can_author_content',
    'can_view_background_version', 'can_view_feat_version', 'can_view_lineage_trait', 'can_view_lineage_version',
    'cancel_change_request', 'character_children_governance', 'characters_governance', 'create_change_request',
    'create_dm_content', 'delete_dm_content', 'delete_dm_note', 'dm_assign_content', 'duplicate_dm_content',
    'export_campaign_dm_backup', 'export_character_feats', 'get_campaign_audit', 'get_campaign_change_requests',
    'get_campaign_governance', 'get_character_change_requests', 'get_character_conditions', 'get_character_feats',
    'get_character_governance', 'get_character_item_knowledge', 'get_character_revealed_notes',
    'get_content_public_info', 'get_dm_character_hidden', 'get_dm_content', 'get_dm_content_library',
    'get_dm_overview', 'get_dm_party', 'get_feat_catalog', 'get_feat_detail', 'get_my_dm_campaigns',
    'import_character_feats', 'new_dm_content_version', 'preview_change_request', 'preview_dm_content',
    'publish_dm_content', 'refresh_change_request', 'remove_character_condition', 'remove_character_feat',
    'restore_dm_content', 'retry_change_request', 'reveal_character_condition', 'reveal_dm_note',
    'review_change_request', 'save_dm_content', 'save_dm_note', 'set_campaign_governance',
    'set_character_feat_choices', 'set_character_feat_notes', 'set_character_lock', 'set_character_setup_complete',
    'set_condition_dm_note', 'set_item_knowledge', 'set_item_secrets', 'submit_change_request',
    'update_change_request', 'update_character_build', 'validate_dm_content']) loop
    execute 'drop function if exists ' || f || ' cascade';
  end loop;
end $$;
do $$
begin
  if to_regclass('supabase_migrations.schema_migrations') is not null then
    delete from supabase_migrations.schema_migrations where version like '20261019%';
  end if;
end $$;

-- class catalog migrations (20261017*): their own tables and functions (columns on older tables go with those tables)
drop table if exists public.class_starting_equipment cascade;
drop table if exists public.character_transformation_events, public.character_form_favorites, public.character_seen_forms,
  public.character_wild_shape_settings cascade;
drop function if exists public.change_transformation_hp(uuid, int), public.set_transformation_equipment(uuid, uuid, text),
  public.set_wild_shape_settings(uuid, text, text, boolean), public.set_form_favorite(uuid, text, boolean),
  public.set_seen_forms(uuid, text[], boolean, text, text), public.use_form_ability(uuid, text, text, int),
  public.combat_wild_shape_heal(uuid, int, text, int), public.end_transformation(uuid, text), public.set_transformation_hp(uuid, int, int, text),
  public.heal_active_transformation(uuid, int, text), public.damage_active_transformation(uuid, int, text),
  public.start_transformation(uuid, text, jsonb), public._derived_stats_full(uuid), public._lock_for_wild_shape(uuid), public._end_expired_form(uuid),
  public._wild_shape_layer(uuid, jsonb), public._wild_shape_sheet(uuid, jsonb), public._form_options(uuid), public._cr_text(numeric),
  public._acts_as_dm(uuid), public._wild_shape_settings(uuid), public._wild_shape_event(uuid, text, text, jsonb, jsonb, jsonb),
  public._item_active_in_form(uuid, uuid), public._active_form(uuid) cascade;
drop table if exists public.character_background_equipment, public.character_background_replacements, public.character_background_choices,
  public.character_backgrounds, public.background_characteristic_tables, public.background_features, public.background_equipment_entries,
  public.background_equipment_packages, public.background_feat_grants, public.background_choice_options, public.background_choices,
  public.background_proficiency_grants, public.background_ability_options, public.background_versions, public.feats, public.backgrounds cascade;
drop function if exists public.apply_background_equipment(uuid, text, jsonb), public.preview_background_equipment(uuid, text),
  public.get_character_background(uuid), public.clear_character_background(uuid),
  public.set_character_background(uuid, text, jsonb, jsonb, jsonb, jsonb), public.get_background_catalog(),
  public._background_version_json(text), public._background_layer(uuid, jsonb), public._character_background_abilities(uuid),
  public._character_background_grants(uuid) cascade;
drop table if exists public.character_infusions, public.character_companions, public.character_transformations, public.creatures,
  public.character_active_states, public.class_feature_states, public.character_starting_equipment cascade;
drop function if exists public.preview_character_class_add(uuid, text, int, text), public.apply_class_starting_equipment(uuid, text, jsonb),
  public.get_class_starting_equipment(text), public._starting_equipment_candidates(jsonb), public.get_character_states(uuid),
  public.start_character_state(uuid, text, boolean), public.end_character_state(uuid, text), public._end_states_on_rest(uuid),
  public._character_transform_rules(uuid), public.get_character_transformation(uuid), public.start_transformation(uuid, text),
  public.change_transformation_hp(uuid, int), public.end_transformation(uuid), public.add_character_companion(uuid, text, text, text, int),
  public.update_character_companion(uuid, jsonb), public.remove_character_companion(uuid), public._character_attunement_limit(uuid),
  public._character_infusion_choices(uuid), public._infusion_modifier(jsonb, int), public.get_character_infusions(uuid),
  public.apply_infusion(uuid, text, uuid, text), public.remove_infusion(uuid, uuid), public.refresh_infusions(uuid),
  public._infusion_item_refusal(jsonb, public.inventory_items), public._transform_refusal(jsonb, int, public.creatures),
  public.get_character_proficiencies(uuid), public._proficiency_source(text, text, jsonb, text) cascade;
drop function if exists public.set_character_spell_acquisition(uuid, text, int, text), public.recover_spell_slots(uuid, text, int[], text),
  public.convert_spell_slot(uuid, text, text, int, text), public.use_temporary_spell_slot(uuid, uuid),
  public.restore_temporary_spell_slot(uuid, uuid), public._temporary_slot_change(uuid, uuid, int), public._expanded_spell(uuid, text) cascade;

-- class feature engine (20261015001800): the objects of rollback_class_features.sql (no restore needed here, because the
-- functions it replaced are dropped below anyway)
drop function if exists public.get_character_class_features(uuid), public.get_character_resources(uuid),
  public.set_character_feature_choice(uuid, uuid, text, text, text[], text, boolean),
  public.set_character_optional_feature(uuid, uuid, text, boolean), public.set_character_subclass(uuid, uuid, text),
  public.expend_character_resource(uuid, text, int, text), public.restore_character_resource(uuid, text, int, text),
  public.set_character_resource_state(uuid, text, int, text, int, int),
  public._resource_change(uuid, text, text, int, int, int, int, text), public.preview_character_class_change(uuid, uuid, int, text),
  public._cf_diff(jsonb, jsonb, uuid, jsonb, jsonb, jsonb, jsonb), public.export_character_class_features(uuid),
  public.import_character_class_features(uuid, jsonb), public._cf_class_row(uuid, uuid),
  public._character_feature_resources(uuid, jsonb), public._cf_scale(jsonb, int), public._character_class_effects(uuid),
  public._cf_equipment(uuid), public._character_feature_choice_rows(uuid), public._character_feature_unlocks(uuid),
  public._cf_prereq(jsonb, jsonb), public._cf_class_rows(uuid), public._skill_level(jsonb),
  public._derived_stats_levels(uuid), public._spellbook_core(uuid), public._class_summary_core(uuid),
  public.character_resources_feature_guard(), public.class_feature_rows_touch(), public.class_feature_unlocks_before_write(),
  public.class_feature_definitions_before_write() cascade;
do $$
begin
  if to_regclass('public.class_feature_choices') is not null then
    execute 'drop function if exists public._cf_choice_error(uuid, uuid, text, public.class_feature_choices, text[], int, boolean) cascade';
  end if;
end $$;
drop table if exists public.character_feature_choice_values, public.character_feature_choices, public.character_optional_features,
  public.class_feature_resources, public.class_feature_effects, public.class_feature_choice_options, public.class_feature_choices,
  public.class_feature_scaling, public.class_feature_unlocks, public.class_feature_versions, public.class_features,
  public.subclasses cascade;

-- class levels, slots, resources, rests (20261015001700): the objects of rollback_class_levels.sql (no restore needed here,
-- because the derived-stats and spell functions are dropped below anyway)
drop function if exists public.set_character_class(uuid, text, int, text, boolean, uuid, text), public.remove_character_class(uuid, boolean),
  public.expend_standard_spell_slot(uuid, int, text), public.restore_standard_spell_slot(uuid, int, text),
  public.expend_pact_magic_slot(uuid, text), public.restore_pact_magic_slot(uuid, text),
  public.set_spell_slot_state(uuid, text, int, int, text), public.save_character_resource(uuid, jsonb),
  public.change_character_resource(uuid, int, text), public.delete_character_resource(uuid),
  public.short_rest_character(uuid, uuid), public.long_rest_character(uuid, uuid), public._rest(uuid, text, uuid),
  public._slot_change(uuid, text, int, int, text), public.get_character_class_summary(uuid), public.get_character_spell_slots(uuid),
  public._character_resource_rows(uuid, jsonb), public._resource_max(jsonb, jsonb), public._class_progress(uuid, jsonb),
  public._prepared_limit(jsonb, jsonb, int), public._progression_slots(text, int), public._character_mods(uuid),
  public._character_level_info(uuid), public._derived_stats_core(uuid) cascade;
drop trigger if exists characters_level_guard on public.characters;
drop function if exists public.characters_level_guard(), public.character_spells_class_rules(),
  public.character_spellcasting_sources_before_delete() cascade;
drop table if exists public.character_resource_events, public.character_resources, public.character_temporary_spell_slots,
  public.character_spell_slot_state, public.character_classes, public.subclass_version_levels, public.class_version_levels,
  public.subclass_versions cascade;
drop function if exists public.character_classes_before_write(), public.character_classes_after_write(),
  public.character_class_rows_touch() cascade;

-- spell catalog and class foundation (20261015001600): the same drops as rollback_spells.sql
drop view if exists public.v_spell_catalog;
drop function if exists public.get_character_spellbook(uuid), public._character_spell_grants(uuid, jsonb, int, text),
  public.save_character_spellcasting_source(uuid, jsonb), public.delete_character_spellcasting_source(uuid),
  public.set_character_spell(uuid, uuid, text, boolean, boolean, boolean, text, boolean, text),
  public.set_character_spell_prepared(uuid, boolean), public.remove_character_spell(uuid), public.get_spell_detail(text),
  public._spell_summary(text), public._spell_stat(text, jsonb, int, int, int, int, int), public.can_view_spell(text) cascade;
drop table if exists public.character_spells, public.character_spellcasting_sources, public.class_spell_list_entries,
  public.class_versions, public.class_spell_lists, public.classes, public.spell_slot_progression_levels, public.spell_slot_progressions,
  public.spell_damage_type_links, public.spell_effect_damage_types, public.spell_effects, public.spell_versions, public.catalog_spells,
  public.spell_schools cascade;
drop function if exists public.spell_rows_touch(), public.character_spellcasting_sources_before_write() cascade;

-- character lineages (20261015001500): the same objects as rollback_lineages.sql (whose function restore is not needed
-- here, because the derived-stats functions are dropped below anyway)
drop function if exists public._lineage_choice_error(public.lineage_choices, text[]),
  public._lineage_choice_complete(public.lineage_choices, text[]);
drop view if exists public.v_lineage_catalog;
drop table if exists public.character_lineage_choices, public.character_lineages, public.lineage_trait_effects,
  public.lineage_option_replacements, public.lineage_trait_replacements, public.lineage_choices, public.lineage_choice_options,
  public.lineage_traits, public.lineage_versions, public.lineages, public.languages, public.skills, public.lineage_categories cascade;
drop function if exists public.get_character_lineage(uuid), public.set_character_lineage(uuid, text, text, jsonb, boolean, boolean),
  public.clear_character_lineage(uuid), public.get_lineage_detail(text), public._lineage_effective_traits(uuid),
  public._lineage_effects(uuid), public.lineage_versions_before_write(), public.lineage_replacements_before_write(),
  public.lineage_choices_before_write(), public.lineage_trait_effects_before_write(), public.character_lineages_before_write() cascade;

-- derived character stats (20261015001400): proficiencies, item effects, manual AC override.
-- The legacy characters.equipment_proficiencies flags were kept in sync by the migration, so nothing is lost there.
drop trigger if exists characters_sync_proficiency_rows on public.characters;
drop table if exists public.character_proficiencies, public.item_effects, public.proficiency_groups cascade;
drop function if exists public.get_character_derived_stats(uuid), public.set_character_proficiency(uuid, text, text, boolean, text),
  public._character_effects(uuid), public._proficiency_match(uuid, text, text, text), public._effect_total(jsonb, text, text, uuid),
  public._ability_mod(int), public._proficiency_type_of_item(text), public._equipment_proficiency_flags(uuid),
  public.character_proficiencies_before_write(), public.character_proficiencies_sync_flags(), public.characters_sync_proficiency_rows(),
  public.item_effects_before_write() cascade;
alter table public.characters drop column if exists ac_override;
comment on column public.characters.ac is null;

drop view if exists public.v_owned_assets_detail, public.v_character_attunement, public.v_inventory_weight, public.v_container_contents,
  public.v_character_equipment, public.v_inventory_detail, public.v_item_catalog cascade;

-- triggers that maintain the new columns (dropped first so the restore below is not recomputed)
drop trigger if exists inventory_items_before_write on public.inventory_items;
drop trigger if exists inventory_items_after_write on public.inventory_items;
drop trigger if exists characters_inventory on public.characters;
drop trigger if exists inventory_items_item_visibility_check on public.inventory_items;
drop function if exists public.inventory_items_item_visibility_check() cascade;

-- legacy `equipped`: true if equipped in the new model or if it was true before the migration
update public.inventory_items ii
set equipped = exists (select 1 from public.character_equipment e where e.inventory_item_id = ii.id)
            or exists (select 1 from public.legacy_inventory_review l where l.inventory_item_id = ii.id and l.legacy_equipped);

-- rows that only exist in the new model (party stash / shop / NPC / stash inventories)
delete from public.inventory_items where character_id is null;

-- policies that depend on the new columns; restore the original policy and table grants
drop policy if exists "inventory_items_read" on public.inventory_items;
drop policy if exists "inventory_items_write" on public.inventory_items;
create policy "inventory_items_all" on public.inventory_items for all to authenticated
  using (public.can_access_character(character_id)) with check (public.can_access_character(character_id));
grant select, insert, update, delete on public.inventory_items to authenticated;

drop table if exists public.inventory_events, public.character_equipment, public.equipment_slot_rules,
  public.inventory_item_modifiers, public.owned_assets, public.legacy_inventory_review cascade;

alter table public.inventory_items
  drop constraint if exists inventory_items_linked_qty, drop constraint if exists inventory_items_charges_current,
  drop constraint if exists inventory_items_charges_max, drop constraint if exists inventory_items_charges_order,
  drop constraint if exists inventory_items_durability, drop constraint if exists inventory_items_container_not_self,
  drop constraint if exists inventory_items_attuned_single;
alter table public.inventory_items
  drop column if exists container_item_id, drop column if exists stack_key, drop column if exists consumable_override,
  drop column if exists acquired_at, drop column if exists state, drop column if exists durability,
  drop column if exists charges_recharge, drop column if exists charges_max, drop column if exists charges_current,
  drop column if exists attuned_at, drop column if exists is_attuned, drop column if exists is_quest_item,
  drop column if exists notes, drop column if exists custom_name, drop column if exists item_id, drop column if exists inventory_id;
alter table public.inventory_items alter column character_id set not null;

drop table if exists public.inventories cascade;

drop table if exists public.homebrew_item_events cascade;
drop table if exists public.item_tag_links, public.item_tags, public.item_modifier_effects, public.item_modifier_categories,
  public.item_modifiers, public.consumable_effects, public.vehicle_stats, public.mount_stats, public.container_stats,
  public.ammunition_stats, public.armor_stats, public.firearm_stats, public.weapon_property_links, public.weapon_stats,
  public.item_provenance, public.item_source_books, public.items cascade;
drop table if exists public.equipment_slots, public.weapon_properties, public.ammo_types, public.damage_types, public.currencies,
  public.source_books, public.data_sources, public.rarities, public.item_categories, public.item_kinds cascade;

drop function if exists public.add_inventory_item(uuid, text, int, text, text, jsonb), public.remove_inventory_item(uuid, int),
  public.split_inventory_stack(uuid, int), public.merge_inventory_stacks(uuid, uuid), public.equip_item(uuid, text, boolean),
  public.unequip_item(uuid), public.attune_item(uuid), public.unattune_item(uuid), public.use_inventory_item(uuid, int),
  public.transfer_inventory_item(uuid, uuid, int), public._try_auto_merge(uuid), public._split_off(uuid, int),
  public._lock_item(uuid), public._rpc_begin(), public._rpc_end(), public.inventory_of_item(uuid),
  public.can_read_inventory(uuid), public.can_write_inventory(uuid), public.can_deposit_inventory(uuid),
  public.can_view_item(text), public.can_edit_item(text), public.can_view_modifier(text), public.can_edit_modifier(text),
  public.log_inventory_event(uuid, uuid, text, int, text, jsonb), public.migrate_legacy_inventory(),
  public.set_inventory_item_quantity(uuid, int), public.move_inventory_item(uuid, uuid), public.link_inventory_item(uuid, text),
  public.create_homebrew_item(uuid, jsonb, jsonb), public.update_homebrew_item(text, jsonb, jsonb), public.archive_homebrew_item(text),
  public.restore_homebrew_item(text), public.homebrew_usage_count(text), public.update_inventory_item_details(uuid, jsonb),
  public.find_link_candidates(uuid), public.preview_link_inventory_item(uuid, text),
  public.convert_legacy_item_to_homebrew(uuid, uuid, jsonb, jsonb), public.resolve_equipment_review(uuid), public.import_inventory_items(uuid, jsonb),
  public._write_homebrew(text, jsonb, jsonb, boolean), public._homebrew_json(text), public._lock_homebrew(text),
  public._link_plan(public.inventory_items, public.items), public._legacy_row_for_link(uuid), public._apply_link(public.inventory_items, public.items, text),
  public._norm_name(text), public._j_text(jsonb, text, int, text), public._j_num(jsonb, text, numeric, numeric, text),
  public._j_int(jsonb, text, int, int, text), public._j_bool(jsonb, text, boolean), public.item_visibility(uuid, uuid),
  public.can_view_owned(uuid, uuid), public.can_edit_owned(uuid, uuid),
  public.can_read_inventory_row(text, uuid, uuid, uuid), public.can_write_inventory_row(text, uuid, uuid, uuid) cascade;
drop function if exists public.compute_stack_key(public.inventory_items) cascade;
drop function if exists public.inventory_items_before_write(), public.inventory_items_after_write(),
  public.inventory_item_modifiers_before_write(), public.inventory_item_modifiers_after_write(),
  public.character_equipment_before_write(), public.character_equipment_after_write(), public.owned_assets_before_write(),
  public.items_before_write(), public.item_modifiers_before_write(), public.create_character_inventory() cascade;

-- Supabase CLI history: if these versions were recorded, remove them too
do $$
begin
  if to_regclass('supabase_migrations.schema_migrations') is not null then
    delete from supabase_migrations.schema_migrations where version > '20261015000000';
  end if;
end $$;

commit;
