-- =============================================================================
-- Class page read model (UX review of the martial phase). get_character_class_features gains display fields only; the
-- resolution itself is unchanged:
--  * per class: version label (rules label, source), hit die, primary abilities, saving throws, feature implementation
--    status, subclass label (the name of the subclass choice feature, e.g. "Martial Archetype")
--  * per feature: category (combat, defense, resource, ...) used to group the page
--  * per subclass option: source status (official / setting / playtest), setting, DM note, implementation status,
--    dependency group and notes (catalog-only subclasses can be chosen; their features are tracked by hand)
--  * per choice option and value: the option's data (source, status) is already there; tool labels for expertise picks
-- Rollback: supabase/rollback/rollback_class_page_read_model.sql (restores the 20261015001800 definition).
-- =============================================================================

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
