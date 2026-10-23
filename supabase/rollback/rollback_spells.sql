-- =============================================================================
-- Rollback of the spell catalog / class foundation feature (migration 20261015001600) ONLY.
-- Drops every spell, class and character-spellcasting table, view, function, trigger and policy, and the
-- lineage_trait_effects.spell_version_id column. DESTRUCTIVE for character spellcasting sources and catalog spell grants;
-- the free-text per-character `spells` table, spell slots, lineages and all other data are untouched (no other function was
-- changed by the migration, so nothing has to be restored). Source books added by spells.sql stay (shared lookup).
-- rollback_inventory.sql runs the same drops first. After this, re-load lineages.sql only after re-applying the migration.
-- =============================================================================
begin;

do $$
begin
  if to_regclass('public.character_classes') is not null then
    raise exception 'The class level feature (20261015001700) depends on the spell tables: run rollback_class_levels.sql first';
  end if;
end $$;

drop view if exists public.v_spell_catalog;
drop function if exists public.get_character_spellbook(uuid), public._character_spell_grants(uuid, jsonb, int, text),
  public.save_character_spellcasting_source(uuid, jsonb), public.delete_character_spellcasting_source(uuid),
  public.set_character_spell(uuid, uuid, text, boolean, boolean, boolean, text, boolean, text),
  public.set_character_spell_prepared(uuid, boolean), public.remove_character_spell(uuid), public.get_spell_detail(text),
  public._spell_summary(text), public._spell_stat(text, jsonb, int, int, int, int, int), public.can_view_spell(text) cascade;
do $$
begin
  if to_regclass('public.lineage_trait_effects') is not null then
    alter table public.lineage_trait_effects drop column if exists spell_version_id;
  end if;
end $$;
drop table if exists public.character_spells, public.character_spellcasting_sources, public.class_spell_list_entries,
  public.class_versions, public.class_spell_lists, public.classes, public.spell_slot_progression_levels, public.spell_slot_progressions,
  public.spell_damage_type_links, public.spell_effect_damage_types, public.spell_effects, public.spell_versions, public.catalog_spells,
  public.spell_schools cascade;
drop function if exists public.spell_rows_touch(), public.character_spellcasting_sources_before_write() cascade;

do $$
begin
  if to_regclass('supabase_migrations.schema_migrations') is not null then
    delete from supabase_migrations.schema_migrations where version = '20261015001600';
  end if;
end $$;

commit;
