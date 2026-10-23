-- =============================================================================
-- Spells tab and spellcaster review fixes (spellcaster phase UX review):
--  * set_character_class: a new class spellcasting source is named after the class; only a SPELLCASTING subclass
--    (Eldritch Knight, Arcane Trickster: multiclass_contribution <> 'none') names it. Before, choosing any subclass together
--    with the class (e.g. Wizard 5 + Evocation) labelled the Wizard source "Evocation". Existing labels are repaired.
--  * get_character_class_features: per class the spellcasting summary of the class row (highest spell level the class
--    can cast, cantrips known) and per spell choice the castable level when the choice is limited to it
--  * _character_feature_choice_rows: a spell choice limited to the castable level whose stored spell is above it (after a
--    level decrease) has the status "invalid" (needs review); nothing is removed
-- Rollback: supabase/rollback/rollback_spells_ux.sql.
-- =============================================================================

create or replace function public.set_character_class(p_character uuid, p_class_version text, p_level int,
                                           p_subclass_version text default null, p_is_primary boolean default null,
                                           p_character_class uuid default null, p_notes text default null)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare cv public.class_versions; sv public.subclass_versions; cc public.character_classes; existing public.character_classes;
  others int; casts boolean; src uuid;
begin
  if auth.uid() is null or not public.can_access_character(p_character) then
    raise exception 'Character not found' using errcode = '42501';
  end if;
  select * into cv from public.class_versions where id = p_class_version;
  if not found then raise exception 'Unknown class version "%"', p_class_version using errcode = '22023'; end if;
  if p_level is null or p_level not between 1 and 20 then
    raise exception 'A class level is between 1 and 20' using errcode = '22023';
  end if;
  if p_subclass_version is not null then
    select * into sv from public.subclass_versions where id = p_subclass_version;
    if not found or sv.class_id <> cv.class_id then
      raise exception 'Subclass "%" does not belong to %', p_subclass_version, cv.name using errcode = '22023';
    end if;
  end if;
  if length(p_notes) > 500 then raise exception 'Notes are too long' using errcode = '22023'; end if;
  perform 1 from public.characters where id = p_character for update;          -- one class change per character at a time

  if p_character_class is not null then
    select * into existing from public.character_classes where id = p_character_class and character_id = p_character;
    if not found then raise exception 'Character class not found' using errcode = '42501'; end if;
    if existing.class_id <> cv.class_id then
      raise exception 'A class row keeps its class; add % as a new class instead', cv.name using errcode = '22023';
    end if;
  else
    select * into existing from public.character_classes where character_id = p_character and class_id = cv.class_id;
    if found and existing.class_version_id <> cv.id then          -- a version change must name the class row explicitly
      raise exception 'This character already has % (%); change the version of that class instead', cv.name, existing.class_version_id
        using errcode = '22023';
    end if;
  end if;
  select coalesce(sum(level), 0) into others from public.character_classes
  where character_id = p_character and id is distinct from existing.id;
  if others + p_level > 20 then
    raise exception 'Class levels would add up to %; the total character level is at most 20', others + p_level using errcode = '22023';
  end if;

  if existing.id is null then
    insert into public.character_classes (character_id, class_id, class_version_id, subclass_version_id, level, is_primary,
                                          started_at_level, notes, created_by)
    values (p_character, cv.class_id, cv.id, p_subclass_version, p_level, false, others + 1, nullif(btrim(p_notes), ''), auth.uid())
    returning * into cc;
  else
    update public.character_classes set class_version_id = cv.id, subclass_version_id = p_subclass_version, level = p_level,
                                        notes = coalesce(nullif(btrim(p_notes), ''), notes)
    where id = existing.id returning * into cc;
  end if;
  if coalesce(p_is_primary, false) or not exists (select 1 from public.character_classes where character_id = p_character and is_primary) then
    update public.character_classes set is_primary = false where character_id = p_character and is_primary and id <> cc.id;
    update public.character_classes set is_primary = true where id = cc.id;
  end if;

  -- the class spellcasting source: linked to the class row; an unlinked preview source of the same class version is adopted
  casts := cv.multiclass_contribution <> 'none' or coalesce(sv.multiclass_contribution, 'none') <> 'none';
  select id into src from public.character_spellcasting_sources where character_class_id = cc.id;
  if casts and src is null then
    select id into src from public.character_spellcasting_sources
    where character_id = p_character and character_class_id is null and source_type = 'class'
      and class_version_id in (select id from public.class_versions where class_id = cv.class_id)
    order by created_at limit 1;
    if src is not null then
      update public.character_spellcasting_sources set character_class_id = cc.id, casting_ability = null, class_version_id = cv.id
      where id = src;
    else
      insert into public.character_spellcasting_sources (character_id, source_type, label, character_class_id, class_version_id,
                                                         enforce_spell_list, created_by)
      values (p_character, 'class', case when coalesce(sv.multiclass_contribution, 'none') <> 'none' then sv.name else cv.name end,
              cc.id, cv.id, true, auth.uid());
    end if;
  elsif src is not null then
    update public.character_spellcasting_sources set class_version_id = cv.id where id = src;   -- version change follows the class
  end if;
  return public.get_character_class_summary(p_character);
end;
$$;

-- repair: class sources that carry the name of a subclass that does not cast spells
update public.character_spellcasting_sources s set label = cv.name
from public.character_classes cc
join public.class_versions cv on cv.id = cc.class_version_id
join public.subclass_versions sv on sv.id = cc.subclass_version_id
where s.character_class_id = cc.id and s.source_type = 'class' and s.label = sv.name and sv.multiclass_contribution = 'none';

create or replace function public._character_feature_choice_rows(p_character uuid)
returns table (character_class_id uuid, class_name text, class_level int, unlock_id text, unlock_level int, choice_id text,
               feature_version_id text, feature_name text, kind text, label text, min_picks int, max_picks int, choice_level int,
               parent_choice_id text, parent_option_id text, config jsonb, allow_free_text boolean, replaceable boolean,
               applies_to text, prerequisites jsonb, sort_order int, unlock_active boolean, unlock_status text, open boolean,
               enabled boolean, applicable boolean, character_choice_id uuid, vals text[], manual_status text, status text)
language sql stable
set search_path = public, pg_temp
as $$
  with ul as (select * from public._character_feature_unlocks(p_character)),
  cr as (select * from public._cf_class_rows(p_character)),
  stored as (
    select ch.id, ch.character_class_id, ch.unlock_id, ch.choice_id, ch.manual_status,
           coalesce(array_agg(v.value order by v.pick) filter (where v.value is not null), '{}') as vals
    from public.character_feature_choices ch left join public.character_feature_choice_values v on v.character_choice_id = ch.id
    where ch.character_id = p_character group by ch.id),
  base as (
    select ul.character_class_id, ul.class_name, ul.class_level, ul.unlock_id, ul.unlock_level, c.id as choice_id,
           c.feature_version_id, ul.feature_name, c.kind, c.label,
           coalesce((select (e ->> 1)::int from jsonb_array_elements(c.config -> 'picks_by_level') e
                     where (e ->> 0)::int <= ul.class_level order by (e ->> 0)::int desc limit 1), c.min_picks) as min_picks,
           coalesce((select (e ->> 1)::int from jsonb_array_elements(c.config -> 'picks_by_level') e
                     where (e ->> 0)::int <= ul.class_level order by (e ->> 0)::int desc limit 1), c.max_picks) as max_picks,
           greatest(c.level, ul.unlock_level) as choice_level, c.parent_choice_id, c.parent_option_id, c.config,
           c.allow_free_text, c.replaceable, c.applies_to, c.prerequisites, c.sort_order, ul.active as unlock_active,
           ul.status as unlock_status,
           case c.applies_to when 'always' then true when 'primary_class' then ul.is_primary else not ul.is_primary end as applicable,
           (c.parent_choice_id is null or exists (
              select 1 from stored p where p.character_class_id = ul.character_class_id and p.unlock_id = ul.unlock_id
                and p.choice_id = c.parent_choice_id and c.parent_option_id = any (p.vals))) as enabled,
           s.id as character_choice_id,
           case when c.kind = 'subclass' then
                  case when cr.subclass_version_id is null then '{}'::text[] else array[cr.subclass_version_id] end
                else coalesce(s.vals, '{}') end as vals,
           s.manual_status
    from ul join public.class_feature_choices c on c.feature_version_id = ul.feature_version_id
    join cr on cr.character_class_id = ul.character_class_id
    left join stored s on s.character_class_id = ul.character_class_id and s.unlock_id = ul.unlock_id and s.choice_id = c.id),
  b2 as (select base.*, base.unlock_active and base.class_level >= base.choice_level and base.applicable and base.enabled as open from base)
  select b2.character_class_id, b2.class_name, b2.class_level, b2.unlock_id, b2.unlock_level, b2.choice_id, b2.feature_version_id,
         b2.feature_name, b2.kind, b2.label, b2.min_picks, b2.max_picks, b2.choice_level, b2.parent_choice_id, b2.parent_option_id,
         b2.config, b2.allow_free_text, b2.replaceable, b2.applies_to, b2.prerequisites, b2.sort_order, b2.unlock_active,
         b2.unlock_status, b2.open, b2.enabled, b2.applicable, b2.character_choice_id, b2.vals, b2.manual_status,
         case when not b2.open and cardinality(b2.vals) > 0 and b2.kind <> 'subclass' then 'inactive_preserved'
              when b2.open and b2.kind = 'spell' and b2.config ->> 'max_spell_level' = 'castable' and exists (
                     select 1 from unnest(b2.vals) x join public.spell_versions sv on sv.id = x
                     where sv.level > coalesce((select lv.max_spell_level from public.character_classes cc
                                                join public.class_version_levels lv on lv.class_version_id = cc.class_version_id and lv.level = cc.level
                                                where cc.id = b2.character_class_id), 0)) then 'invalid'
              when not b2.open then case when not b2.applicable then 'not_applicable' when not b2.enabled then 'disabled' else 'locked' end
              when cardinality(b2.vals) > b2.max_picks then 'over_selected'
              when b2.kind = 'asi' and (b2.manual_status = 'applied_manually'
                     or (cardinality(b2.vals) = 1 and b2.vals[1] like 'feat:%')
                     or (select coalesce(sum(nullif(split_part(x, ':', 2), '')::int), 0) from unnest(b2.vals) x where x !~ '^feat:')
                        = coalesce((b2.config ->> 'points')::int, 2)) then 'complete'
              when b2.kind = 'asi' then 'incomplete'
              when b2.min_picks = 0 and cardinality(b2.vals) = 0 then 'optional'
              when cardinality(b2.vals) >= b2.min_picks then 'complete'
              else 'incomplete' end
  from b2;
$$;

create or replace function public.get_character_class_features(p_character uuid)
returns jsonb
language plpgsql stable
set search_path = public, pg_temp
as $$
declare li jsonb; d jsonb; mods jsonb; c public.characters; ctx jsonb; profs jsonb; spells jsonb; feats jsonb; res jsonb;
  classes jsonb := '[]'; r record; feats_out jsonb; nxt jsonb; warnings jsonb := '[]'; incomplete jsonb := '[]'; review jsonb;
  coverage jsonb; grants jsonb; cr record; choice_rows jsonb; eff jsonb; ul jsonb; sub_opts jsonb; asi_points jsonb;
begin
  select * into c from public.characters where id = p_character;            -- RLS: owner, campaign DM, admin
  if not found then raise exception 'Character not found' using errcode = '42501'; end if;
  li := public._character_level_info(p_character);
  d := public.get_character_derived_stats(p_character);
  select jsonb_object_agg(k, (d -> 'abilities' -> k ->> 'modifier')::int) into mods from jsonb_object_keys(d -> 'abilities') k;
  res := public._character_feature_resources(p_character, mods);

  -- context for deferred prerequisites: scores, proficiencies, known spells, active features
  select coalesce(jsonb_agg(distinct x), '[]') into profs from (
    select k as x from jsonb_object_keys(coalesce(c.skill_proficiencies, '{}')) k where public._skill_level(c.skill_proficiencies -> k) >= 1
    union select k from jsonb_object_keys(coalesce(d -> 'skills', '{}')) k
          where coalesce((d -> 'skills' -> k ->> 'lineage_proficient')::boolean, false) or coalesce((d -> 'skills' -> k ->> 'class_proficient')::boolean, false)
    union select coalesce(p ->> 'group_id', p ->> 'item_id') from jsonb_array_elements(coalesce(d -> 'proficiencies', '[]')) p
          where coalesce(p ->> 'group_id', p ->> 'item_id') is not null) s;
  select coalesce(jsonb_agg(distinct g.spell_version_id), '[]') into spells from public.character_spells g where g.character_id = p_character;
  select coalesce(jsonb_agg(distinct u.feature_id), '[]') into feats from public._character_feature_unlocks(p_character) u where u.active;
  ctx := jsonb_build_object('abilities', (select jsonb_object_agg(k, (d -> 'abilities' -> k ->> 'score')::int) from jsonb_object_keys(d -> 'abilities') k),
                            'proficiencies', profs, 'spells', spells, 'features', feats,
                            'can_cast', exists (select 1 from public.character_spells g where g.character_id = p_character));

  for cr in select * from public._cf_class_rows(p_character) order by is_primary desc, class_level desc, class_name loop
    -- choices of this class row (all instances), with deferred prerequisite checks on chosen options
    select coalesce(jsonb_agg(jsonb_build_object(
             'key', ch.unlock_id || ':' || ch.choice_id, 'unlock_id', ch.unlock_id, 'choice_id', ch.choice_id, 'kind', ch.kind,
             'label', ch.label, 'feature_name', ch.feature_name, 'min', ch.min_picks, 'max', ch.max_picks, 'level', ch.choice_level,
             'parent_choice_id', ch.parent_choice_id, 'parent_option_id', ch.parent_option_id, 'config', ch.config,
             'allow_free_text', ch.allow_free_text, 'replaceable', ch.replaceable, 'applies_to', ch.applies_to,
             'open', ch.open, 'enabled', ch.enabled, 'values', to_jsonb(ch.vals), 'manual_status', ch.manual_status,
             'castable_level', case when ch.config ->> 'max_spell_level' = 'castable' then
                                 (select coalesce(lv.max_spell_level, 0) from public.class_version_levels lv
                                  where lv.class_version_id = cr.class_version_id and lv.level = cr.class_level) end,
             'status', case when ch.status = 'complete' and ch.kind = 'expertise' and exists (
                              select 1 from unnest(ch.vals) v where not profs ? v) then 'invalid'
                            else ch.status end,
             'prerequisite', public._cf_prereq(ch.prerequisites, ctx || jsonb_build_object('class_level', ch.class_level,
               'total_level', (li ->> 'total_level')::int, 'subclass_version_id', cr.subclass_version_id,
               'confirmed', ch.manual_status = 'confirmed')),
             'value_labels', (select coalesce(jsonb_agg(jsonb_build_object('value', v, 'label', coalesce(
                                 (select o.label from public.class_feature_choice_options o where o.choice_id = ch.choice_id and o.option_id = v),
                                 (select s.name from public.skills s where s.id = v),
                                 (select l.name from public.languages l where l.id = v),
                                 (select sv.name from public.spell_versions sv where sv.id = v),
                                 (select sv.name from public.subclass_versions sv where sv.id = v),
                                 (select g.name from public.proficiency_groups g where g.id = v),
                                 (select i.name from public.items i where i.id = v and i.owner_id is null),
                                 (select i.name from public.items i where i.id = v and i.owner_id is null and i.kind_id = 'tool'),
                                 case when v ~ '^feat:' then 'Feat: ' || substr(v, 6) when v ~ '^text:' then substr(v, 6)
                                      when v ~ '^(str|dex|con|int|wis|cha):[0-9]+$' then upper(split_part(v, ':', 1)) || ' +' || split_part(v, ':', 2) end,
                                 v),
                                 'prerequisite', (select public._cf_prereq(o.prerequisites, ctx || jsonb_build_object('class_level', ch.class_level,
                                                    'total_level', (li ->> 'total_level')::int, 'subclass_version_id', cr.subclass_version_id,
                                                    'confirmed', ch.manual_status = 'confirmed'))
                                                  from public.class_feature_choice_options o where o.choice_id = ch.choice_id and o.option_id = v))
                                 order by ord), '[]') from unnest(ch.vals) with ordinality u(v, ord)),
             'tool_options', (select coalesce(jsonb_agg(jsonb_build_object('id', i.id, 'label', i.name) order by i.name), '[]')
                              from public.items i where ch.kind = 'expertise' and ch.config ? 'tools' and ch.config -> 'tools' ? i.id),
             'options', (select coalesce(jsonb_agg(jsonb_build_object('id', o.option_id, 'label', o.label, 'summary', o.summary,
                           'group', o.option_group, 'data', o.data,
                           'prerequisite', public._cf_prereq(o.prerequisites, ctx || jsonb_build_object('class_level', ch.class_level,
                             'total_level', (li ->> 'total_level')::int, 'subclass_version_id', cr.subclass_version_id)))
                           order by o.sort_order, o.option_id), '[]')
                         from public.class_feature_choice_options o where o.choice_id = ch.choice_id))
             order by ch.unlock_level, ch.sort_order, ch.choice_id), '[]')
    into choice_rows
    from public._character_feature_choice_rows(p_character) ch where ch.character_class_id = cr.character_class_id;

    select coalesce(jsonb_agg(to_jsonb(x)), '[]') into eff from public._character_class_effects(p_character) x
    where x.character_class_id = cr.character_class_id;

    -- features up to the current level (and preserved inactive ones); later ones go to the next-level preview
    select coalesce(jsonb_agg(jsonb_build_object(
             'unlock_id', u.unlock_id, 'feature_version_id', u.feature_version_id, 'feature_id', u.feature_id, 'name', u.feature_name,
             'summary', fv.summary, 'source_label', fv.source_label, 'source_url', fv.source_url, 'source_status', fv.source_status,
             'version_status', fv.status, 'superseded_by_version_id', fv.superseded_by_version_id,
             'level', u.unlock_level, 'origin', u.origin, 'is_optional', u.is_optional, 'opted_in', u.opted_in,
             'status', u.status, 'active', u.active, 'automation', fv.automation, 'automation_notes', fv.automation_notes,
             'activation', fv.activation, 'repeatable', fv.repeatable, 'prerequisite', u.prerequisite, 'category', fv.category,
             'replaces', case when u.replaces_unlock_id is null then null else jsonb_build_object('unlock_id', u.replaces_unlock_id,
                           'mode', u.replacement_mode, 'name', (select v2.name from public.class_feature_unlocks u2
                                                               join public.class_feature_versions v2 on v2.id = u2.feature_version_id
                                                               where u2.id = u.replaces_unlock_id)) end,
             'replaced_by', case when u.replaced_by is null then null else jsonb_build_object('unlock_id', u.replaced_by,
                              'name', (select v2.name from public.class_feature_unlocks u2 join public.class_feature_versions v2 on v2.id = u2.feature_version_id
                                       where u2.id = u.replaced_by)) end,
             'scaling', (select coalesce(jsonb_agg(jsonb_build_object('key', s.key, 'label', s.label, 'value_type', s.value_type, 'unit', s.unit)
                           || public._cf_scale(s.table_by_level, case when s.level_basis = 'total' then (li ->> 'total_level')::int else u.class_level end)
                           order by s.key), '[]')
                         from public.class_feature_scaling s where s.feature_version_id = u.feature_version_id),
             'choices', (select coalesce(jsonb_agg(x ->> 'key'), '[]') from jsonb_array_elements(choice_rows) x where x ->> 'unlock_id' = u.unlock_id),
             'resources', (select coalesce(jsonb_agg(x ->> 'key'), '[]') from jsonb_array_elements(res) x
                           where x ->> 'unlock_id' = u.unlock_id and x ->> 'character_class_id' = cr.character_class_id::text),
             'effects', (select coalesce(jsonb_agg(jsonb_build_object('effect_type', x ->> 'effect_type', 'target', x ->> 'target',
                           'value', x -> 'value', 'value_text', x ->> 'value_text', 'spell_version_id', x ->> 'spell_version_id',
                           'spell_name', (select sv.name from public.spell_versions sv where sv.id = x ->> 'spell_version_id'),
                           'conditions', x -> 'conditions', 'data', x -> 'data', 'min_level', (x ->> 'min_level')::int,
                           'automation', x ->> 'automation', 'active', (x ->> 'active')::boolean, 'inactive_reason', x ->> 'inactive_reason')
                           order by (x ->> 'seq')::int, (x ->> 'pick')::int), '[]')
                         from jsonb_array_elements(eff) x where x ->> 'unlock_id' = u.unlock_id))
             order by u.unlock_level, u.origin, u.sort_order, u.unlock_id), '[]')
    into feats_out
    from public._character_feature_unlocks(p_character) u
    join public.class_feature_versions fv on fv.id = u.feature_version_id
    where u.character_class_id = cr.character_class_id
      and (u.unlock_level <= cr.class_level
           or exists (select 1 from public.character_feature_choices x where x.character_class_id = u.character_class_id and x.unlock_id = u.unlock_id)
           or exists (select 1 from public.character_optional_features x where x.character_class_id = u.character_class_id and x.unlock_id = u.unlock_id));

    -- next class level (read only; the full diff is preview_character_class_change)
    select jsonb_build_object('level', cr.class_level + 1, 'possible', cr.class_level < 20 and cr.total_level < 20,
             'proficiency_bonus', (least(cr.total_level + 1, 20) - 1) / 4 + 2,
             'subclass_unlock', cr.subclass_version_id is null and cr.class_level + 1 = cr.subclass_level,
             'features', coalesce((select jsonb_agg(jsonb_build_object('unlock_id', u.id, 'name', fv.name, 'automation', fv.automation,
                            'is_optional', u.is_optional, 'origin', case when u.subclass_version_id is null then 'class' else 'subclass' end,
                            'choices', (select coalesce(jsonb_agg(ch.label order by ch.sort_order), '[]') from public.class_feature_choices ch
                                        where ch.feature_version_id = u.feature_version_id),
                            'asi', exists (select 1 from public.class_feature_choices ch where ch.feature_version_id = u.feature_version_id and ch.kind = 'asi'))
                            order by u.sort_order, u.id)
                          from public.class_feature_unlocks u join public.class_feature_versions fv on fv.id = u.feature_version_id
                          where u.level = cr.class_level + 1
                            and (u.class_version_id = cr.class_version_id or (u.subclass_version_id = cr.subclass_version_id and cr.subclass_status in ('active', 'below_level')))), '[]'),
             'scaling', coalesce((select jsonb_agg(jsonb_build_object('feature', fv.name, 'label', s.label,
                            'from', public._cf_scale(s.table_by_level, cr.class_level) -> 'value', 'to', public._cf_scale(s.table_by_level, cr.class_level + 1) -> 'value'))
                          from public._character_feature_unlocks(p_character) u
                          join public.class_feature_versions fv on fv.id = u.feature_version_id
                          join public.class_feature_scaling s on s.feature_version_id = u.feature_version_id and s.level_basis = 'class'
                          where u.character_class_id = cr.character_class_id and u.active
                            and public._cf_scale(s.table_by_level, cr.class_level) -> 'value' is distinct from public._cf_scale(s.table_by_level, cr.class_level + 1) -> 'value'), '[]'))
    into nxt;

    -- subclass options of the class (official and test content of the same scope as the class version)
    select coalesce(jsonb_agg(jsonb_build_object('id', s.id, 'name', s.name, 'source_label', s.source_label, 'source_url', s.source_url,
             'status', s.status, 'selection_level', coalesce(s.selection_level, cv.subclass_level, 3),
             'requires_dm_permission', s.requires_dm_permission, 'content_scope', s.content_scope,
             'implementation_status', s.implementation_status, 'source_status', s.source_status, 'setting', s.setting,
             'dm_permission_note', s.dm_permission_note, 'dependency_group', s.dependency_group, 'feature_notes', s.feature_notes,
             'compatible', s.class_version_id is null or s.class_version_id = cr.class_version_id) order by s.status, s.name), '[]')
    into sub_opts
    from public.subclass_versions s join public.class_versions cv on cv.id = cr.class_version_id
    where s.class_id = cr.class_id and (s.class_version_id is null or s.class_version_id = cr.class_version_id or s.id = cr.subclass_version_id);

    -- stored selections that do not belong to the current class version / subclass any more (kept for review)
    select coalesce(jsonb_agg(jsonb_build_object('kind', x.kind, 'unlock_id', x.unlock_id, 'name', x.name, 'detail', x.detail)), '[]')
    into review from (
      select 'choice' as kind, ch.unlock_id, cf.label as name,
             (select string_agg(v.value, ', ' order by v.pick) from public.character_feature_choice_values v where v.character_choice_id = ch.id) as detail
      from public.character_feature_choices ch join public.class_feature_choices cf on cf.id = ch.choice_id
      where ch.character_class_id = cr.character_class_id
        and ch.unlock_id not in (select u.unlock_id from public._character_feature_unlocks(p_character) u where u.character_class_id = cr.character_class_id)
      union all
      select 'optional_feature', o.unlock_id, fv.name, null
      from public.character_optional_features o join public.class_feature_unlocks u on u.id = o.unlock_id
      join public.class_feature_versions fv on fv.id = u.feature_version_id
      where o.character_class_id = cr.character_class_id
        and o.unlock_id not in (select u2.unlock_id from public._character_feature_unlocks(p_character) u2 where u2.character_class_id = cr.character_class_id)
      union all
      select 'resource', null, s.name, format('%s used', s.expended)
      from public.character_resources s
      where s.character_class_id = cr.character_class_id and s.feature_resource_id is not null
        and not exists (select 1 from jsonb_array_elements(res) x where x ->> 'resource_id' = s.feature_resource_id
                                                                     and x ->> 'character_class_id' = cr.character_class_id::text)) x;

    classes := classes || jsonb_build_object(
      'id', cr.character_class_id, 'class_id', cr.class_id, 'class_name', cr.class_name, 'class_version_id', cr.class_version_id,
      'version_name', cr.version_name, 'level', cr.class_level, 'is_primary', cr.is_primary, 'content_scope', cr.content_scope,
      'spellcasting', (select jsonb_build_object('max_spell_level', lv.max_spell_level, 'cantrips_known', lv.cantrips_known,
                         'spells_known', lv.spells_known, 'pact_slot_level', lv.pact_slot_level)
                       from public.class_version_levels lv where lv.class_version_id = cr.class_version_id and lv.level = cr.class_level),
      'version', (select jsonb_build_object('rules_label', v.rules_label, 'source_label', v.source_label, 'source_url', v.source_url,
                    'hit_die', v.hit_die, 'primary_abilities', to_jsonb(v.primary_abilities), 'saving_throws', to_jsonb(v.saving_throws),
                    'feature_status', v.feature_status, 'feature_notes', v.feature_notes, 'status', v.status)
                  from public.class_versions v where v.id = cr.class_version_id),
      'subclass_label', (select fv.name from public.class_feature_unlocks u join public.class_feature_choices ch on ch.feature_version_id = u.feature_version_id
                         join public.class_feature_versions fv on fv.id = u.feature_version_id
                         where u.class_version_id = cr.class_version_id and ch.kind = 'subclass' limit 1),
      'subclass', jsonb_build_object('selected', case when cr.subclass_version_id is null then null else jsonb_build_object(
                     'id', cr.subclass_version_id, 'name', cr.subclass_name) end,
                   'selection_level', cr.subclass_level, 'status', case when cr.subclass_version_id is null then
                     case when cr.class_level >= cr.subclass_level then 'available' else 'not_yet' end else cr.subclass_status end,
                   'active', cr.subclass_active, 'options', sub_opts),
      'features', feats_out, 'choices', choice_rows, 'next_level', nxt, 'review_items', review,
      'resources', (select coalesce(jsonb_agg(x), '[]') from jsonb_array_elements(res) x where x ->> 'character_class_id' = cr.character_class_id::text));

    -- warnings of this class row
    if cr.subclass_status = 'incompatible' then
      warnings := warnings || jsonb_build_object('code', 'subclass_incompatible', 'class_id', cr.class_id,
        'message', format('%s does not belong to this version of %s; its features are inactive (kept for review)', cr.subclass_name, cr.class_name));
    elsif cr.subclass_status = 'below_level' then
      warnings := warnings || jsonb_build_object('code', 'subclass_below_level', 'class_id', cr.class_id,
        'message', format('%s needs %s level %s; it is kept but inactive', cr.subclass_name, cr.class_name, cr.subclass_level));
    elsif cr.subclass_version_id is null and cr.class_level >= cr.subclass_level
          and exists (select 1 from public.subclass_versions s where s.class_id = cr.class_id
                        and (s.class_version_id is null or s.class_version_id = cr.class_version_id))
          and exists (select 1 from public.class_feature_unlocks u where u.class_version_id = cr.class_version_id) then
      warnings := warnings || jsonb_build_object('code', 'subclass_not_chosen', 'class_id', cr.class_id,
        'message', format('%s level %s: choose a subclass', cr.class_name, cr.class_level));
    end if;
    if jsonb_array_length(review) > 0 then
      warnings := warnings || jsonb_build_object('code', 'review_items', 'class_id', cr.class_id,
        'message', format('%s: %s stored selection(s) no longer match the class version or subclass; they are kept for review',
                          cr.class_name, jsonb_array_length(review)));
    end if;
  end loop;

  select coalesce(jsonb_agg(jsonb_build_object('character_class_id', x.ccid, 'class_name', x.cname, 'key', x.ch ->> 'key',
           'feature_name', x.ch ->> 'feature_name', 'label', x.ch ->> 'label', 'status', x.ch ->> 'status', 'kind', x.ch ->> 'kind')), '[]')
  into incomplete
  from (select k ->> 'id' as ccid, k ->> 'class_name' as cname, ch from jsonb_array_elements(classes) k, jsonb_array_elements(k -> 'choices') ch) x
  where (x.ch ->> 'open')::boolean and x.ch ->> 'status' in ('incomplete', 'over_selected', 'invalid');

  -- choice-level warnings: preserved inactive values, prerequisites to check or confirm, invalid expertise, ASI above 20
  select warnings || coalesce(jsonb_agg(w), '[]') into warnings from (
    select jsonb_build_object('code', 'choice_inactive_preserved', 'class_id', k ->> 'class_id', 'choice', ch ->> 'key',
             'message', format('%s: %s is kept but inactive (%s)', k ->> 'class_name', ch ->> 'label', ch ->> 'feature_name')) as w
    from jsonb_array_elements(classes) k, jsonb_array_elements(k -> 'choices') ch where ch ->> 'status' = 'inactive_preserved'
    union all
    select jsonb_build_object('code', case when vl -> 'prerequisite' ->> 'status' = 'manual' then 'prerequisite_confirm' else 'prerequisite_unmet' end,
             'class_id', k ->> 'class_id', 'choice', ch ->> 'key',
             'message', format('%s: %s needs %s%s', k ->> 'class_name', vl ->> 'label',
                               (select string_agg(i ->> 'label', ', ') from jsonb_array_elements(vl -> 'prerequisite' -> 'items') i where i ->> 'status' <> 'met'),
                               case when vl -> 'prerequisite' ->> 'status' = 'manual' then ' (confirm with your DM)' else ' (warning only)' end))
    from jsonb_array_elements(classes) k, jsonb_array_elements(k -> 'choices') ch, jsonb_array_elements(ch -> 'value_labels') vl
    where (ch ->> 'open')::boolean and vl -> 'prerequisite' ->> 'status' in ('unmet', 'manual')
    union all
    select jsonb_build_object('code', case when ch -> 'prerequisite' ->> 'status' = 'manual' then 'prerequisite_confirm' else 'prerequisite_unmet' end,
             'class_id', k ->> 'class_id', 'choice', ch ->> 'key',
             'message', format('%s: %s needs %s%s', k ->> 'class_name', ch ->> 'label',
                               (select string_agg(i ->> 'label', ', ') from jsonb_array_elements(ch -> 'prerequisite' -> 'items') i where i ->> 'status' <> 'met'),
                               case when ch -> 'prerequisite' ->> 'status' = 'manual' then ' (confirm with your DM)' else ' (warning only)' end))
    from jsonb_array_elements(classes) k, jsonb_array_elements(k -> 'choices') ch
    where (ch ->> 'open')::boolean and ch -> 'prerequisite' ->> 'status' in ('unmet', 'manual')
    union all
    select jsonb_build_object('code', 'expertise_without_proficiency', 'class_id', k ->> 'class_id', 'choice', ch ->> 'key',
             'message', format('%s: %s needs proficiency in the chosen skill; expertise is not applied', k ->> 'class_name', ch ->> 'label'))
    from jsonb_array_elements(classes) k, jsonb_array_elements(k -> 'choices') ch where ch ->> 'status' = 'invalid'
    union all
    select jsonb_build_object('code', 'ability_above_20', 'ability', a,
             'message', format('%s is %s; an Ability Score Improvement cannot raise a score above 20 (check your choices)', upper(a),
                               d -> 'abilities' -> a ->> 'score'))
    from jsonb_object_keys(d -> 'abilities') a
    where (d -> 'abilities' -> a ->> 'score')::int > 20
      and exists (select 1 from jsonb_array_elements(d -> 'abilities' -> a -> 'sources') s where s ->> 'source_type' = 'class_feature')
    union all
    select jsonb_build_object('code', 'resource_max_unknown', 'resource', x ->> 'key',
             'message', format('%s: the maximum cannot be calculated yet; track it by hand', x ->> 'name'))
    from jsonb_array_elements(res) x where not (x ->> 'max_known')::boolean
    union all
    select jsonb_build_object('code', 'primary_class_review',
             'message', 'The primary class decides the starting proficiencies (saving throws); check that the right class is marked primary')
    where (select count(*) from public.character_classes where character_id = p_character) > 1
      and exists (select 1 from public.character_classes where character_id = p_character and is_primary and coalesce(started_at_level, 1) <> 1)
  ) s;

  select jsonb_build_object(
           'automated', count(*) filter (where f ->> 'automation' = 'automated'),
           'partially_automated', count(*) filter (where f ->> 'automation' = 'partially_automated'),
           'informational', count(*) filter (where f ->> 'automation' = 'informational'),
           'unresolved', count(*) filter (where f ->> 'automation' = 'unresolved'))
  into coverage
  from jsonb_array_elements(classes) k, jsonb_array_elements(k -> 'features') f where (f ->> 'active')::boolean;

  select jsonb_build_object(
    'proficiencies', coalesce((select jsonb_agg(jsonb_build_object('target', x.target, 'value', x.value_text,
                       'source', x.class_name || ': ' || x.feature_name, 'character_class_id', x.character_class_id)
                       order by x.target, x.value_text)
                     from public._character_class_effects(p_character) x where x.active and x.effect_type in ('proficiency', 'expertise')), '[]'),
    'spells', coalesce((select jsonb_agg(jsonb_build_object('spell_version_id', x.spell_version_id,
                       'name', (select sv.name from public.spell_versions sv where sv.id = x.spell_version_id),
                       'always_prepared', coalesce((x.data ->> 'always_prepared')::boolean, false), 'unlocked', x.active,
                       'source', x.class_name || ': ' || x.feature_name))
                     from public._character_class_effects(p_character) x
                     where x.feature_active and x.effect_type = 'spell' and x.spell_version_id is not null), '[]'),
    'attacks', coalesce(d -> 'feature_attacks', '[]'),
    'attacks_per_action', d -> 'attacks_per_action', 'critical_range', d -> 'critical_range',
    'effects', coalesce(d -> 'class_features' -> 'applied', '[]'))
  into grants;

  return jsonb_build_object(
    'character_id', p_character, 'total_level', (li ->> 'total_level')::int, 'proficiency_bonus', (li ->> 'proficiency_bonus')::int,
    'level_source', li ->> 'source', 'classes', classes, 'resources', res, 'incomplete_choices', incomplete, 'warnings', warnings,
    'automation_coverage', coverage, 'grants', grants,
    'resolution_order', jsonb_build_array(
      'stored character data', 'class versions and class levels (total level, proficiency bonus)', 'primary class rules',
      'subclass selection', 'class feature unlocks', 'optional and replacement features', 'feature choices', 'subclass feature unlocks',
      'class and subclass proficiencies', 'class and subclass spell grants', 'active feature effects', 'class resources',
      'lineage effects', 'equipment and item effects', 'manual overrides'),
    'limitations', jsonb_build_array(
      'Temporary features (stances, Rage, concentration effects) are informational: nothing is switched on automatically.',
      'Contextual attack rules (Sneak Attack eligibility, once per turn, advantage) are informational.',
      'Feat choices are a placeholder until a feat catalog exists.',
      'Changing a class version keeps old choices for review; nothing is migrated automatically.'));
end;
$$;
