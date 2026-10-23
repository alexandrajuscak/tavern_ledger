-- =============================================================================
-- Proficiency resolver (docs/PROFICIENCY_RESOLUTION.md). One authoritative read model of every proficiency a character
-- has, with every active source, built on get_character_derived_stats (which already merges manual rows, lineage grants
-- and class grants, and drives the armor warnings through _proficiency_match). Nothing is copied into manual rows:
--   * manual sources: character_proficiencies rows (groups, items) and the characters.skill_proficiencies /
--     save_proficiencies columns; they stay editable
--   * derived sources: class (primary or multiclass grants), class features and feature choices, lineage; read only here
--   * effective = at least one active source; removing a source removes only its contribution
-- get_character_proficiencies(character) -> { groups, items, skills, saves, tools, languages, warnings }; each entry:
--   { type, id, name, effective, level (skills: 0 / 1 / 2), manual, manual_level, derived, editable, sources[] }
--   source: { kind: manual | import | class | feature | lineage | background | item, label, detail, character_class_id? }
-- Security invoker: row level security decides who may read the character (owner, campaign DM, admin).
-- =============================================================================

-- one source of a derived proficiency, in the words the sheet shows ("Fighter", "Feature: Bonus Proficiency",
-- "Mountain Dwarf", "Manual")
create function public._proficiency_source(p_type text, p_name text, p_extra jsonb, p_lineage text)
returns jsonb
language sql immutable
set search_path = public, pg_temp
as $$
  select case
    when p_type in ('manual', 'sheet') then jsonb_build_object('kind', 'manual', 'label', 'Manual', 'detail', nullif(p_name, ''))
    when p_type = 'import' then jsonb_build_object('kind', 'import', 'label', 'Imported', 'detail', nullif(p_name, ''))
    when p_type = 'class' then
      case when split_part(coalesce(p_name, ''), ': ', 2) in ('', 'Proficiencies')
           then jsonb_build_object('kind', 'class', 'label', split_part(coalesce(p_name, 'Class'), ': ', 1), 'detail', p_name)
           else jsonb_build_object('kind', 'feature', 'label', 'Feature: ' || substr(p_name, length(split_part(p_name, ': ', 1)) + 3),
                                   'detail', split_part(p_name, ': ', 1)) end
        || jsonb_strip_nulls(jsonb_build_object('character_class_id', p_extra ->> 'character_class_id'))
    when p_type in ('lineage', 'race') then jsonb_build_object('kind', 'lineage', 'label', coalesce(p_lineage, 'Lineage'), 'detail', p_name)
    when p_type = 'background' then jsonb_build_object('kind', 'background', 'label', coalesce(p_name, 'Background'), 'detail', p_extra ->> 'detail')
    else jsonb_build_object('kind', coalesce(p_type, 'other'), 'label', initcap(coalesce(p_type, 'other')), 'detail', p_name) end
    || case when p_extra ? 'trait_id' then jsonb_build_object('trait_id', p_extra ->> 'trait_id') else '{}' end;
$$;

create function public.get_character_proficiencies(p_character uuid)
returns jsonb
language plpgsql stable
set search_path = public, pg_temp
as $$
declare c public.characters; d jsonb; lin text; groups jsonb; items jsonb; skills jsonb; saves jsonb; tools jsonb; langs jsonb;
  warnings jsonb := '[]';
begin
  select * into c from public.characters where id = p_character;
  if not found or auth.uid() is null then
    raise exception 'Character not found' using errcode = '42501';
  end if;
  d := public.get_character_derived_stats(p_character);
  lin := coalesce(d -> 'lineage' ->> 'subversion_name', d -> 'lineage' ->> 'name');

  -- every derived or manual group / item proficiency with its source, deduplicated per (kind, label)
  with p as (
    select x, coalesce(x ->> 'group_id', x ->> 'item_id') as target, x ->> 'group_id' is not null as is_group,
           public._proficiency_source(x ->> 'source_type', coalesce(x ->> 'notes', x ->> 'name'), x, lin) as src
    from jsonb_array_elements(coalesce(d -> 'proficiencies', '[]')) x),
  srcs as (select target, is_group, min(x ->> 'proficiency_type') as ptype, min(x ->> 'name') as name,
                  jsonb_agg(distinct src) as sources, bool_or(src ->> 'kind' in ('manual', 'import')) as manual,
                  bool_or(src ->> 'kind' not in ('manual', 'import')) as derived
           from p group by target, is_group)
  select coalesce(jsonb_agg(jsonb_build_object('type', g.proficiency_type, 'id', g.id, 'name', g.name,
           'effective', s.target is not null, 'level', case when s.target is not null then 1 else 0 end,
           'manual', coalesce(s.manual, false), 'manual_level', case when coalesce(s.manual, false) then 1 else 0 end,
           'derived', coalesce(s.derived, false), 'editable', true, 'sources', coalesce(s.sources, '[]'))
           order by g.sort_order), '[]'),
         (select coalesce(jsonb_agg(jsonb_build_object('type', s2.ptype, 'id', s2.target, 'name', s2.name, 'effective', true, 'level', 1,
                   'manual', s2.manual, 'manual_level', case when s2.manual then 1 else 0 end, 'derived', s2.derived,
                   'editable', true, 'sources', s2.sources) order by s2.ptype, s2.name), '[]')
          from srcs s2 where not s2.is_group)
  into groups, items
  from public.proficiency_groups g left join srcs s on s.is_group and s.target = g.id;

  -- skills: manual level (0 / 1 / 2) stored on the character; class, feature and lineage sources from the derived model
  select coalesce(jsonb_agg(jsonb_build_object('type', 'skill', 'id', sk.id, 'name', sk.name, 'ability', sk.ability,
           'effective', greatest(m.lvl, dv.lvl) > 0, 'level', greatest(m.lvl, dv.lvl), 'manual', m.lvl > 0, 'manual_level', m.lvl,
           'derived', dv.lvl > 0, 'expertise', greatest(m.lvl, dv.lvl) = 2, 'editable', true,
           'sources', (case when m.lvl > 0 then jsonb_build_array(jsonb_build_object('kind', 'manual', 'label', 'Manual',
                                                  'detail', case when m.lvl = 2 then 'Expertise' end)) else '[]' end) || dv.sources)
           order by sk.name), '[]')
  into skills
  from public.skills sk
  cross join lateral (select public._skill_level(c.skill_proficiencies -> sk.id) as lvl) m
  cross join lateral (
    select case when coalesce((d -> 'skills' -> sk.id ->> 'class_expertise')::boolean, false) then 2
                when coalesce((d -> 'skills' -> sk.id ->> 'class_proficient')::boolean, false)
                  or coalesce((d -> 'skills' -> sk.id ->> 'lineage_proficient')::boolean, false)
                  or coalesce((d -> 'skills' -> sk.id ->> 'background_proficient')::boolean, false) then 1 else 0 end as lvl,
           coalesce((select jsonb_agg(distinct public._proficiency_source(x ->> 'source_type', x ->> 'source_name', x, lin))
                     from jsonb_array_elements(coalesce(d -> 'skills' -> sk.id -> 'proficiency_sources', '[]')) x), '[]')
           || coalesce((select jsonb_agg(distinct public._proficiency_source(x ->> 'source_type', x ->> 'source_name', x, lin)
                                         || jsonb_build_object('expertise', true))
                        from jsonb_array_elements(coalesce(d -> 'skills' -> sk.id -> 'expertise_sources', '[]')) x), '[]') as sources) dv;

  -- saving throws: manual flag on the character, class grants (first class only) from the derived model
  select coalesce(jsonb_agg(jsonb_build_object('type', 'save', 'id', a.k, 'name', a.name,
           'effective', m.on or dv.on, 'level', case when m.on or dv.on then 1 else 0 end, 'manual', m.on,
           'manual_level', case when m.on then 1 else 0 end, 'derived', dv.on, 'editable', true,
           'sources', (case when m.on then '[{"kind": "manual", "label": "Manual"}]'::jsonb else '[]' end) || dv.sources)
           order by a.n), '[]')
  into saves
  from (values (1, 'str', 'Strength'), (2, 'dex', 'Dexterity'), (3, 'con', 'Constitution'), (4, 'int', 'Intelligence'),
               (5, 'wis', 'Wisdom'), (6, 'cha', 'Charisma')) a(n, k, name)
  cross join lateral (select coalesce((c.save_proficiencies ->> a.k)::boolean, false) as on) m
  cross join lateral (
    select coalesce((d -> 'saving_throws' -> a.k ->> 'class_proficient')::boolean, false)
             or jsonb_array_length(coalesce(d -> 'saving_throws' -> a.k -> 'background_sources', '[]')) > 0 as on,
           coalesce((select jsonb_agg(distinct public._proficiency_source('class', x #>> '{}', '{}', lin))
                     from jsonb_array_elements(coalesce(d -> 'saving_throws' -> a.k -> 'class_sources', '[]')) x), '[]') as sources) dv;

  -- tools: item proficiencies of type tool (any source) and tool expertise
  select coalesce(jsonb_agg(t || jsonb_build_object('expertise',
           exists (select 1 from jsonb_array_elements(coalesce(d -> 'tool_expertise', '[]')) e where e ->> 'item_id' = t ->> 'id'))), '[]')
  into tools
  from jsonb_array_elements(items) t where t ->> 'type' = 'tool';

  -- languages: lineage and class grants, merged per language (manual languages are free text on the sheet)
  select coalesce(jsonb_agg(jsonb_build_object('type', 'language', 'id', l.id, 'name', l.name, 'effective', true, 'level', 1,
           'manual', false, 'manual_level', 0, 'derived', true, 'editable', false, 'sources', l.sources) order by l.ord, l.name), '[]')
  into langs
  from (select x ->> 'id' as id, min(x ->> 'name') as name, min(coalesce(lg.sort_order, 999)) as ord,
               jsonb_agg(distinct case when s #>> '{}' like '%: %' then public._proficiency_source('class', s #>> '{}', '{}', lin)
                                       else public._proficiency_source('lineage', s #>> '{}', '{}', lin) end) as sources
        from jsonb_array_elements(coalesce(d -> 'languages', '[]')) x
        cross join lateral jsonb_array_elements(coalesce(x -> 'sources', '[]')) s
        left join public.languages lg on lg.id = x ->> 'id'
        group by x ->> 'id') l;

  -- a manual mark that a class / lineage also grants: kept (it survives removing the other source), only noted
  select coalesce(jsonb_agg(jsonb_build_object('code', 'manual_also_granted', 'type', e ->> 'type', 'id', e ->> 'id', 'name', e ->> 'name',
           'message', format('%s is also granted by %s; your manual mark is kept.', e ->> 'name',
             (select string_agg(s ->> 'label', ', ') from jsonb_array_elements(e -> 'sources') s where s ->> 'kind' not in ('manual', 'import'))))), '[]')
  into warnings
  from jsonb_array_elements(groups || items || skills || saves) e
  where (e ->> 'manual')::boolean and (e ->> 'derived')::boolean and (e ->> 'manual_level')::int >= (e ->> 'level')::int;

  return jsonb_build_object('character_id', p_character, 'groups', groups, 'items', items, 'skills', skills, 'saves', saves,
    'tools', tools, 'languages', langs, 'warnings', warnings,
    'armor', jsonb_build_object('nonproficient_armor', coalesce((d -> 'armor_consequences' ->> 'nonproficient_armor')::boolean, false),
                                'nonproficient_shield', coalesce((d -> 'armor_consequences' ->> 'nonproficient_shield')::boolean, false)));
end;
$$;

revoke all on function public._proficiency_source(text, text, jsonb, text) from public, anon;
revoke all on function public.get_character_proficiencies(uuid) from public, anon;
grant execute on function public._proficiency_source(text, text, jsonb, text) to authenticated;
grant execute on function public.get_character_proficiencies(uuid) to authenticated;
