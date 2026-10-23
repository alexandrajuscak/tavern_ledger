-- =============================================================================
-- Rollback of the class feature engine (migration 20261015001800) ONLY.
-- Removes the feature catalog (features, versions, unlocks, scaling, choices, options, effects, resources), the canonical
-- subclasses table, and the character feature state: stored feature choices and their values, optional-feature
-- selections and class resource state rows (character_resources rows with a feature_resource_id). Synthetic test content
-- (content_scope = 'test') is deleted. Restores _character_effects, _proficiency_match, _character_spell_grants,
-- character_classes_before_write, _character_resource_rows and _rest exactly as 20261015001400 / 1500 / 1600 / 1700
-- defined them, and gives get_character_derived_stats, get_character_spellbook and get_character_class_summary their
-- 20261015001700 / 1600 functions back.
-- KEPT: characters, class rows (level, version, subclass), lineages, inventory, spell catalog, spells, spellcasting sources,
-- slot state, manual resources, trackers, events (their feature_resource_id column is dropped).
-- Refuses to run while a character uses synthetic test content (remove that class from the character first).
-- rollback_class_levels.sql refuses to run while this feature exists.
-- =============================================================================
begin;

do $$
begin
  if exists (select 1 from public.character_classes cc join public.class_versions v on v.id = cc.class_version_id
             where v.content_scope = 'test')
     or exists (select 1 from public.character_classes cc join public.subclass_versions s on s.id = cc.subclass_version_id
                where s.content_scope = 'test') then
    raise exception 'Characters still use the synthetic test class (content_scope = test); remove that class from them first';
  end if;
end $$;

drop function if exists public.get_character_class_features(uuid), public.get_character_resources(uuid),
  public.set_character_feature_choice(uuid, uuid, text, text, text[], text, boolean),
  public.set_character_optional_feature(uuid, uuid, text, boolean), public.set_character_subclass(uuid, uuid, text),
  public.expend_character_resource(uuid, text, int, text), public.restore_character_resource(uuid, text, int, text),
  public.set_character_resource_state(uuid, text, int, text, int, int),
  public._resource_change(uuid, text, text, int, int, int, int, text), public.preview_character_class_change(uuid, uuid, int, text),
  public._cf_diff(jsonb, jsonb, uuid, jsonb, jsonb, jsonb, jsonb), public.export_character_class_features(uuid),
  public.import_character_class_features(uuid, jsonb), public._cf_class_row(uuid, uuid) cascade;
drop function if exists public._cf_choice_error(uuid, uuid, text, public.class_feature_choices, text[], int, boolean) cascade;

-- the wrappers go; the functions they wrapped get their names back
drop function if exists public.get_character_derived_stats(uuid);
alter function public._derived_stats_levels(uuid) rename to get_character_derived_stats;
drop function if exists public.get_character_spellbook(uuid);
alter function public._spellbook_core(uuid) rename to get_character_spellbook;
drop function if exists public.get_character_class_summary(uuid);
alter function public._class_summary_core(uuid) rename to get_character_class_summary;

-- restored exactly as defined before 20261015001800
create or replace function public._character_effects(p_character uuid)
returns table (source_type text, source_id uuid, item_id text, source_name text, modifier_id text, seq int,
               effect_type text, value numeric, target text, activation text, stacking text, stack_group text,
               scope text, active boolean, inactive_reason text, applied boolean)
language sql stable
set search_path = public, pg_temp
as $$
  with owned as (
    select ii.id, ii.item_id, ii.is_attuned, coalesce(ii.custom_name, it.name) as name, it.kind_id, it.requires_attunement, e.slot_id
    from public.inventories inv
    join public.inventory_items ii on ii.inventory_id = inv.id
    join public.items it on it.id = ii.item_id                       -- RLS: effects of invisible items do not exist
    left join public.character_equipment e on e.inventory_item_id = ii.id and e.character_id = p_character
    where inv.character_id = p_character
  ),
  worn as (
    select coalesce(bool_or(slot_id = 'armor'), false) as has_armor, coalesce(bool_or(slot_id = 'shield'), false) as has_shield
    from public.character_equipment where character_id = p_character
  ),
  raw as (
    select 'item_effect'::text as source_type, o.id as source_id, o.item_id, o.name as source_name, null::text as modifier_id, ie.seq,
           ie.effect_type, ie.value, ie.target, ie.activation, ie.stacking, ie.stack_group, ie.priority,
           case when ie.effect_type in ('attack_bonus', 'damage_bonus') and o.kind_id = 'weapon' then 'self' else 'global' end as scope,
           coalesce(
             case ie.activation
               when 'equipped' then case when o.slot_id is null then 'not_equipped' end
               when 'attuned' then case when not o.is_attuned then 'not_attuned' end
               when 'equipped_and_attuned' then case when o.slot_id is null then 'not_equipped' when not o.is_attuned then 'not_attuned' end
             end,
             case when ie.conditions ->> 'no_armor' = 'true' and w.has_armor then 'wearing_armor'
                  when ie.conditions ->> 'no_shield' = 'true' and w.has_shield then 'using_shield' end) as inactive_reason
    from owned o
    join public.item_effects ie on ie.item_id = o.item_id
    cross join worn w
    union all
    select 'modifier', o.id, o.item_id, o.name || ' (' || md.name || ')', md.id, me.seq,
           me.effect_type, me.value, null,
           case when coalesce(md.requires_attunement_override, o.requires_attunement) then 'equipped_and_attuned' else 'equipped' end,
           'additive', null, 0,
           case when me.effect_type in ('attack_bonus', 'damage_bonus') then 'self' else 'global' end,
           case when o.slot_id is null then 'not_equipped'
                when coalesce(md.requires_attunement_override, o.requires_attunement) and not o.is_attuned then 'not_attuned' end
    from owned o
    join public.inventory_item_modifiers im on im.inventory_item_id = o.id
    join public.item_modifiers md on md.id = im.modifier_id
    join public.item_modifier_effects me on me.modifier_id = md.id
  ),
  ranked as (
    select r.*, r.inactive_reason is null as active,
           row_number() over (
             partition by r.inactive_reason is null, r.effect_type, coalesce(r.target, ''), r.scope,
                          case when r.scope = 'self' then r.source_id::text else '' end,
                          case r.stacking when 'additive' then r.source_type || r.source_id || coalesce(r.modifier_id, '') || r.seq
                                          when 'non_stacking_group' then 'group:' || r.stack_group
                                          else r.stacking end
             order by r.value desc nulls last, r.priority desc, r.source_id) as rn
    from raw r
  )
  select source_type, source_id, item_id, source_name, modifier_id, seq, effect_type, value, target, activation, stacking, stack_group,
         scope, active, inactive_reason, active and rn = 1 as applied
  from ranked;
$$;

create or replace function public._proficiency_match(p_character uuid, p_item text, p_base_item text, p_group text)
returns jsonb
language sql stable
set search_path = public, pg_temp
as $$
  select coalesce(
    (select jsonb_build_object('proficient', true, 'matched_by', 'item', 'proficiency_id', p.id, 'item_id', p.item_id,
                               'source_type', p.source_type)
     from public.character_proficiencies p
     where p.character_id = p_character and p.item_id is not null and p.item_id in (p_item, p_base_item) limit 1),
    (select jsonb_build_object('proficient', true, 'matched_by', 'group', 'proficiency_id', p.id, 'group_id', g.id,
                               'group_name', g.name, 'source_type', p.source_type)
     from public.character_proficiencies p join public.proficiency_groups g on g.id = p.group_id
     where p.character_id = p_character and p.group_id = p_group limit 1),
    (select jsonb_build_object('proficient', true, 'matched_by', 'lineage', 'source_type', 'lineage', 'trait_id', e.trait_id,
                               'trait_name', e.trait_name, 'group_id', case when e.target = 'group' then e.value_text end,
                               'item_id', case when e.target <> 'group' then e.value_text end)
     from public._lineage_effects(p_character) e
     where e.effect_type = 'proficiency' and e.active
       and ((e.target in ('weapon', 'armor', 'tool') and e.value_text in (p_item, p_base_item))
            or (e.target = 'group' and e.value_text = p_group))
     limit 1),
    jsonb_build_object('proficient', false, 'missing_group_id', p_group,
                       'missing_group_name', (select name from public.proficiency_groups where id = p_group)));
$$;

create or replace function public._character_spell_grants(p_character uuid, mods jsonb, pb int, lin_name text)
returns table (spell_version_id text, source_key text, grant_info jsonb)
language sql stable
set search_path = public, pg_temp
as $$
  select g.spell_version_id, s.id::text, jsonb_build_object(
           'source_key', s.id::text, 'source_type', s.source_type, 'source_label', s.label, 'character_spell_id', g.id,
           'preparation_mode', s.preparation_mode,
           'known', g.known, 'prepared', g.prepared, 'always_prepared', g.always_prepared, 'innate', false,
           'counts_against_known_limit', g.counts_against_known_limit, 'counts_against_prepared_limit', g.counts_against_prepared_limit,
           'uses_spell_slot', g.uses_spell_slot and s.uses_spell_slots,
           'ritual_allowed', g.ritual_allowed or (v.is_ritual and case s.ritual_mode
                                                                     when 'prepared' then g.prepared or g.always_prepared
                                                                     when 'known' then g.known or g.prepared or g.always_prepared
                                                                     when 'spellbook' then g.known
                                                                     else false end),
           'notes', g.notes, 'unlocked', true, 'min_level', 1,
           'on_source_list', case when s.spell_list_id is null then null
                                  else exists (select 1 from public.class_spell_list_entries e
                                               where e.list_id = s.spell_list_id and e.spell_version_id = g.spell_version_id) end,
           'casting_ability', coalesce(g.casting_ability, s.casting_ability), 'casting_ability_override', g.casting_ability,
           'stats', public._spell_stat(coalesce(g.casting_ability, s.casting_ability), mods, pb, s.fixed_dc, s.fixed_attack_bonus, s.dc_bonus, s.attack_bonus))
  from public.character_spells g join public.character_spellcasting_sources s on s.id = g.source_id
  join public.spell_versions v on v.id = g.spell_version_id
  where g.character_id = p_character
  union all
  select te.spell_version_id, 'lineage:' || coalesce(e.data ->> 'ability', 'none'), jsonb_build_object(
           'source_key', 'lineage:' || coalesce(e.data ->> 'ability', 'none'), 'source_type', 'lineage',
           'source_label', coalesce(lin_name, 'Lineage') || ': ' || e.trait_name, 'trait_id', e.trait_id,
           'known', true, 'prepared', false, 'always_prepared', false, 'innate', true,
           'counts_against_known_limit', false, 'counts_against_prepared_limit', false, 'uses_spell_slot', false,
           'ritual_allowed', false, 'notes', e.data ->> 'notes', 'unlocked', e.active, 'min_level', e.min_level,
           'uses', e.data ->> 'uses', 'recharge', e.data ->> 'recharge', 'cast_level', e.data -> 'cast_level',
           'casting_ability', e.data ->> 'ability', 'ability_needed', e.data ? 'ability_choice' and not e.data ? 'ability',
           'stats', public._spell_stat(e.data ->> 'ability', mods, pb))
  from public._lineage_effects(p_character) e
  join public.lineage_trait_effects te on te.trait_id = e.trait_id and te.seq = e.seq
  where e.effect_type = 'spell' and te.spell_version_id is not null;
$$;

create or replace function public.character_classes_before_write()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
declare cv public.class_versions; sv public.subclass_versions;
begin
  select * into cv from public.class_versions where id = new.class_version_id;
  if not found then raise exception 'Unknown class version "%"', new.class_version_id using errcode = '22023'; end if;
  new.class_id := cv.class_id;
  if new.subclass_version_id is not null then
    select * into sv from public.subclass_versions where id = new.subclass_version_id;
    if not found or sv.class_id <> cv.class_id then
      raise exception 'Subclass "%" does not belong to %', new.subclass_version_id, cv.name using errcode = '22023';
    end if;
  end if;
  new.updated_at := now();
  return new;
end;
$$;

create or replace function public._character_resource_rows(p_character uuid, p_mods jsonb)
returns jsonb
language sql stable
set search_path = public, pg_temp
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', r.id, 'resource_key', r.resource_key, 'name', r.name, 'source_type', r.source_type, 'source_id', r.source_id,
           'character_class_id', r.character_class_id, 'die', r.die, 'recharge', r.recharge, 'unlock_level', r.unlock_level,
           'spell_version_id', r.spell_version_id, 'cast_level', r.cast_level, 'active', r.active, 'notes', r.notes,
           'unlocked', r.unlock_level is null or coalesce(cc.level, (l.li ->> 'total_level')::int) >= r.unlock_level,
           'max', m ->> 'max', 'unlimited', (m ->> 'unlimited')::boolean, 'expended', r.expended,
           'remaining', case when (m ->> 'unlimited')::boolean then null else greatest((m ->> 'max')::int - r.expended, 0) end,
           'max_formula', r.max_formula) order by r.name), '[]')
  from public.character_resources r
  left join public.character_classes cc on cc.id = r.character_class_id
  cross join (select public._character_level_info(p_character) as li) l
  cross join lateral (select public._resource_max(r.max_formula, jsonb_build_object(
                        'total_level', (l.li ->> 'total_level')::int, 'class_level', cc.level,
                        'proficiency_bonus', (l.li ->> 'proficiency_bonus')::int, 'mods', p_mods)) as m) x
  where r.character_id = p_character;
$$;

create or replace function public._rest(p_character uuid, p_kind text, p_rest_id uuid)
returns jsonb
language plpgsql
set search_path = public, pg_temp
as $$
declare std jsonb := '[]'; pact int := 0; res jsonb := '[]'; trk jsonb := '[]'; legacy int := 0; tmp int := 0; out jsonb; rid uuid;
  prev jsonb;
begin
  if auth.uid() is null or not public.can_access_character(p_character) then
    raise exception 'Character not found' using errcode = '42501';
  end if;
  perform 1 from public.characters where id = p_character for update;
  rid := coalesce(p_rest_id, gen_random_uuid());
  select details into prev from public.character_resource_events
  where character_id = p_character and rest_id = rid and event_type in ('short_rest', 'long_rest');
  if found then return prev || jsonb_build_object('already_applied', true); end if;

  if p_kind = 'long' then
    with u as (update public.character_spell_slot_state set expended = 0
               where character_id = p_character and pool = 'standard' and expended > 0 returning slot_level, expended)
    select coalesce(jsonb_agg(jsonb_build_object('slot_level', slot_level, 'restored', expended) order by slot_level), '[]') into std from u;
  end if;
  with u as (update public.character_spell_slot_state set expended = 0
             where character_id = p_character and pool = 'pact' and expended > 0 returning expended)
  select coalesce(sum(expended), 0) into pact from u;
  with u as (update public.character_resources set expended = 0
             where character_id = p_character and expended > 0
               and recharge in (case when p_kind = 'long' then 'long_rest' else 'short_rest' end, 'short_rest', 'short_or_long_rest')
             returning name)
  select coalesce(jsonb_agg(name order by name), '[]') into res from u;
  with u as (update public.feature_trackers set current = max
             where character_id = p_character and current <> max
               and (reset_on = 'short' or (p_kind = 'long' and reset_on = 'long'))
             returning name)
  select coalesce(jsonb_agg(name order by name), '[]') into trk from u;
  if p_kind = 'long' then
    with u as (update public.spell_slots set used = 0 where character_id = p_character and used > 0 returning 1)
    select count(*) into legacy from u;
  end if;
  with d as (delete from public.character_temporary_spell_slots
             where character_id = p_character and (expires_on = 'short_rest' or (p_kind = 'long' and expires_on = 'long_rest'))
             returning 1)
  select count(*) into tmp from d;

  out := jsonb_build_object('rest', p_kind, 'rest_id', rid, 'already_applied', false,
    'restored', jsonb_build_object('standard_slots', std, 'pact_slots', pact, 'resources', res, 'trackers', trk,
                                   'legacy_manual_slot_levels', legacy, 'temporary_slots_removed', tmp),
    'not_handled', case when p_kind = 'long'
                        then jsonb_build_array('hit points, temporary HP, death saves and hit dice (applied by the app as before)',
                                               'conditions', 'prepared spell changes (change them yourself)', 'dawn resources')
                        else jsonb_build_array('standard spell slots', 'hit dice spending', 'hit points') end);
  insert into public.character_resource_events (character_id, event_type, pool, rest_id, details)
  values (p_character, p_kind || '_rest', 'rest', rid, out);
  return out;
end;
$$;

drop function if exists public._character_feature_resources(uuid, jsonb), public._cf_scale(jsonb, int),
  public._character_class_effects(uuid), public._cf_equipment(uuid), public._character_feature_choice_rows(uuid),
  public._character_feature_unlocks(uuid), public._cf_prereq(jsonb, jsonb), public._cf_class_rows(uuid),
  public._skill_level(jsonb) cascade;

-- character feature state
drop trigger if exists character_resources_feature_guard on public.character_resources;
drop function if exists public.character_resources_feature_guard() cascade;
delete from public.character_resources where feature_resource_id is not null;
alter table public.character_resources drop constraint if exists character_resources_feature_class;
drop index if exists public.character_resources_feature;
alter table public.character_resources drop column if exists feature_resource_id, drop column if exists temporary_bonus,
  drop column if exists max_adjustment, drop column if exists last_recovered_at;
alter table public.character_resource_events drop column if exists feature_resource_id;
drop table if exists public.character_feature_choice_values, public.character_feature_choices,
  public.character_optional_features cascade;

-- feature catalog
drop table if exists public.class_feature_resources, public.class_feature_effects, public.class_feature_choice_options,
  public.class_feature_choices, public.class_feature_scaling, public.class_feature_unlocks, public.class_feature_versions,
  public.class_features cascade;
drop function if exists public.class_feature_rows_touch(), public.class_feature_unlocks_before_write(),
  public.class_feature_definitions_before_write() cascade;

-- synthetic test content and the subclass / scope columns
delete from public.subclass_versions where content_scope = 'test';
delete from public.class_versions where content_scope = 'test';
delete from public.classes where content_scope = 'test';
alter table public.subclass_versions drop constraint if exists subclass_versions_implementation_status_check;
update public.subclass_versions set implementation_status = 'partial' where implementation_status = 'features_partial';
alter table public.subclass_versions add constraint subclass_versions_implementation_status_check
  check (implementation_status in ('level_only', 'progression_only', 'partial', 'complete'));
alter table public.subclass_versions drop column if exists subclass_id, drop column if exists class_version_id,
  drop column if exists selection_level, drop column if exists setting, drop column if exists requires_dm_permission,
  drop column if exists dm_permission_note, drop column if exists content_scope, drop column if exists notes;
drop table if exists public.subclasses cascade;
alter table public.class_versions drop column if exists content_scope, drop column if exists subclass_level;
alter table public.classes drop column if exists content_scope;

do $$
begin
  if to_regclass('supabase_migrations.schema_migrations') is not null then
    delete from supabase_migrations.schema_migrations where version = '20261015001800';
  end if;
end $$;

commit;
