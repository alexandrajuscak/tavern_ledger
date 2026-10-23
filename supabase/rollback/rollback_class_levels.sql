-- =============================================================================
-- Rollback of the class level / spell slot / Pact Magic / resource / rest feature (migration 20261015001700) ONLY.
-- Drops character classes, slot state, temporary slots, resources and their events, the class / subclass level tables and
-- every function and trigger of the feature; removes the class_versions columns it added, the Fighter / Monk / Rogue rows
-- and the seeded slot progressions; restores character_spellcasting_sources_before_write and get_character_derived_stats
-- exactly as 20261015001600 / 20261015001500 defined them. characters.level keeps its last (mirrored) value; class
-- spellcasting sources become "Class Foundation Preview" sources again (their spells are kept). DESTRUCTIVE for class rows,
-- slot usage and resources: take a backup first. rollback_spells.sql refuses to run while this feature exists;
-- this script refuses to run while the class feature engine (20261015001800) exists.
-- =============================================================================
begin;

do $$
begin
  if to_regclass('public.class_feature_versions') is not null then
    raise exception 'The class feature engine (20261015001800) depends on the class level tables: run rollback_class_features.sql first';
  end if;
end $$;

drop function if exists public.set_character_class(uuid, text, int, text, boolean, uuid, text), public.remove_character_class(uuid, boolean),
  public.expend_standard_spell_slot(uuid, int, text), public.restore_standard_spell_slot(uuid, int, text),
  public.expend_pact_magic_slot(uuid, text), public.restore_pact_magic_slot(uuid, text),
  public.set_spell_slot_state(uuid, text, int, int, text), public.save_character_resource(uuid, jsonb),
  public.change_character_resource(uuid, int, text), public.delete_character_resource(uuid),
  public.short_rest_character(uuid, uuid), public.long_rest_character(uuid, uuid), public._rest(uuid, text, uuid),
  public._slot_change(uuid, text, int, int, text), public.get_character_class_summary(uuid), public.get_character_spell_slots(uuid),
  public._character_resource_rows(uuid, jsonb), public._resource_max(jsonb, jsonb), public._class_progress(uuid, jsonb),
  public._prepared_limit(jsonb, jsonb, int), public._progression_slots(text, int) cascade;

drop trigger if exists characters_level_guard on public.characters;
drop trigger if exists character_spells_class_rules on public.character_spells;
drop trigger if exists character_spellcasting_sources_before_delete on public.character_spellcasting_sources;
drop function if exists public.characters_level_guard(), public.character_spells_class_rules(),
  public.character_spellcasting_sources_before_delete() cascade;

-- class sources lose their class link and become previews again (their spells stay)
update public.character_spellcasting_sources set is_preview = true where character_class_id is not null;
alter table public.character_spellcasting_sources drop column if exists character_class_id;

drop table if exists public.character_resource_events, public.character_resources, public.character_temporary_spell_slots,
  public.character_spell_slot_state, public.character_classes, public.subclass_version_levels, public.class_version_levels,
  public.subclass_versions cascade;
drop function if exists public.character_classes_before_write(), public.character_classes_after_write(),
  public.character_class_rows_touch() cascade;

-- derived stats: drop the wrapper, give the 1500 function its name back
drop function if exists public.get_character_derived_stats(uuid);
drop function if exists public._character_mods(uuid), public._character_level_info(uuid);
alter function public._derived_stats_core(uuid) rename to get_character_derived_stats;
grant execute on function public.get_character_derived_stats(uuid) to authenticated;

-- class data added by the feature
update public.class_versions set slot_progression_id = null where slot_progression_id is not null;
delete from public.spell_slot_progression_levels
  where progression_id in ('standard-caster', 'half-caster', 'artificer-tce-slots', 'third-caster', 'pact-magic');
delete from public.spell_slot_progressions where id in ('standard-caster', 'half-caster', 'artificer-tce-slots', 'third-caster', 'pact-magic');
update public.character_spellcasting_sources set class_version_id = null where class_version_id in ('fighter-phb', 'monk-phb', 'rogue-phb');
delete from public.class_versions where id in ('fighter-phb', 'monk-phb', 'rogue-phb');
delete from public.classes where id in ('barbarian', 'fighter', 'monk', 'rogue');   -- classes without a spell list (added by classes.sql)
alter table public.class_versions drop column if exists hit_die, drop column if exists rules_label,
  drop column if exists multiclass_contribution, drop column if exists spellcasting_start_level, drop column if exists prepared_formula,
  drop column if exists is_pact_magic, drop column if exists multiclass_prerequisite, drop column if exists implementation_status,
  drop column if exists limitations;

-- the 20261015001600 source trigger function, unchanged
create or replace function public.character_spellcasting_sources_before_write()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
declare cv public.class_versions;
begin
  if new.class_version_id is not null then
    select * into cv from public.class_versions where id = new.class_version_id;
    new.casting_ability := coalesce(new.casting_ability, cv.spellcasting_ability);
    new.spell_list_id := coalesce(new.spell_list_id, cv.spell_list_id);
  end if;
  if new.source_type = 'class' then new.is_preview := true; end if;    -- class rules are not implemented yet
  if exists (select 1 from unnest(new.allowed_abilities) a where a not in ('str', 'dex', 'con', 'int', 'wis', 'cha')) then
    raise exception 'Unknown ability in allowed_abilities' using errcode = '22023';
  end if;
  new.updated_at := now();
  return new;
end;
$$;

do $$
begin
  if to_regclass('supabase_migrations.schema_migrations') is not null then
    delete from supabase_migrations.schema_migrations where version = '20261015001700';
  end if;
end $$;

commit;
