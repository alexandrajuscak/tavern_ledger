-- =============================================================================
-- Class setup flow: guided Add Class (preview without storing: features, proficiencies, choices, spellcasting and slots,
-- multiclass prerequisites of every class) and the starting equipment review (options per group, item candidates, applying
-- the chosen items to the character inventory once, for the first class only). Generic: everything comes from the catalog.
--   * preview_character_class_add(character, class version, level, subclass version)
--   * get_class_starting_equipment(class version): groups, options, items with catalog candidates
--   * apply_class_starting_equipment(character, class version, selections): adds the items, records the application
--   * character_starting_equipment: one row per character (applied once; RPC only)
-- =============================================================================

-- ---- applied starting equipment (one per character) ---------------------------------------------------------------------
create table public.character_starting_equipment (
  character_id     uuid primary key references public.characters (id) on delete cascade,
  class_version_id text not null references public.class_versions (id),
  selections       jsonb not null default '{}'::jsonb check (jsonb_typeof(selections) = 'object'),
  added            jsonb not null default '[]'::jsonb check (jsonb_typeof(added) = 'array'),
  skipped          jsonb not null default '[]'::jsonb check (jsonb_typeof(skipped) = 'array'),
  applied_at       timestamptz not null default now(),
  applied_by       uuid references auth.users (id) on delete set null
);
alter table public.character_starting_equipment enable row level security;
create policy "character_starting_equipment_read" on public.character_starting_equipment for select to authenticated
  using (public.can_access_character(character_id));
revoke all on public.character_starting_equipment from anon, authenticated;
grant select on public.character_starting_equipment to authenticated;

-- ---- catalog candidates of one equipment entry --------------------------------------------------------------------------
-- {"item_id"} -> that item; {"group": proficiency group} -> official weapons of the group; {"category"} -> official items of
-- the category; {"one_of": [...]} -> those items. Homebrew and archived items are never candidates.
create function public._starting_equipment_candidates(p_entry jsonb)
returns jsonb
language sql stable
set search_path = public, pg_temp
as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', i.id, 'name', i.name) order by i.name), '[]')
  from public.items i
  where i.owner_id is null and i.campaign_id is null and i.archived_at is null and (
       (p_entry ? 'group' and exists (select 1 from public.weapon_stats w join public.proficiency_groups g on g.weapon_group = w.weapon_group
                                      where w.item_id = i.id and g.id = p_entry ->> 'group' and not i.is_magic))
    or (p_entry ? 'category' and i.category_id = p_entry ->> 'category' and not i.is_magic)
    or (p_entry ? 'one_of' and i.id in (select jsonb_array_elements_text(p_entry -> 'one_of'))));
$$;

create function public.get_class_starting_equipment(p_class_version text)
returns jsonb
language sql stable
set search_path = public, pg_temp
as $$
  select jsonb_build_object('class_version_id', p_class_version,
    'starting_gold', (select starting_gold from public.class_versions where id = p_class_version),
    'groups', coalesce((select jsonb_agg(g order by (g ->> 'group')::int) from (
      select jsonb_build_object('group', e.choice_group, 'options', jsonb_agg(jsonb_build_object(
               'key', e.option_key, 'label', e.label, 'raw', e.raw, 'resolved', e.resolved,
               'items', (select coalesce(jsonb_agg(x || case when x ? 'item_id'
                                                          then jsonb_build_object('name', (select name from public.items where id = x ->> 'item_id'))
                                                          when x ? 'unresolved' then '{}'::jsonb
                                                          else jsonb_build_object('candidates', public._starting_equipment_candidates(x)) end
                                                   order by n), '[]')
                         from jsonb_array_elements(e.items) with ordinality t(x, n)))
             order by e.option_key)) g
      from public.class_starting_equipment e where e.class_version_id = p_class_version group by e.choice_group) q), '[]'));
$$;
revoke all on function public.get_class_starting_equipment(text) from public;
grant execute on function public.get_class_starting_equipment(text) to anon, authenticated;
revoke all on function public._starting_equipment_candidates(jsonb) from public;

-- ---- apply ---------------------------------------------------------------------------------------------------------------
-- p_selections: {"options": {"<group>": "<option key>"}, "picks": {"<group>:<option>:<item index>": "<item id>" | ["<id>", ...]}}
-- Every group needs an option (a group with one option is taken as is). A placeholder (group / category / one_of) needs a pick
-- among its candidates: one id (gets the entry's quantity) or a list of exactly "quantity" ids. Unresolved entries are skipped
-- and reported. Only for the primary class, once per character (starting equipment of a multiclass is not granted).
create function public.apply_class_starting_equipment(p_character uuid, p_class_version text, p_selections jsonb)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare inv uuid; grp record; opt public.class_starting_equipment; key text; x jsonb; n int; pick jsonb; ids text[]; cands jsonb;
  added jsonb := '[]'; skipped jsonb := '[]'; cname text; iid text;
begin
  if auth.uid() is null or not public.can_access_character(p_character) then
    raise exception 'Character not found' using errcode = '42501';
  end if;
  if jsonb_typeof(p_selections) is distinct from 'object' then raise exception 'Selections must be an object' using errcode = '22023'; end if;
  perform 1 from public.characters where id = p_character for update;          -- one application at a time
  if not exists (select 1 from public.character_classes where character_id = p_character and class_version_id = p_class_version and is_primary) then
    raise exception 'Starting equipment comes with the first (primary) class only' using errcode = '22023';
  end if;
  if exists (select 1 from public.character_starting_equipment where character_id = p_character) then
    raise exception 'Starting equipment was already added to this character' using errcode = '23505';
  end if;
  select i.id into inv from public.inventories i where i.character_id = p_character and i.kind = 'character';
  if inv is null then raise exception 'This character has no inventory' using errcode = '22023'; end if;
  select name into cname from public.class_versions where id = p_class_version;

  for grp in select choice_group, count(*) as n_opt from public.class_starting_equipment where class_version_id = p_class_version
             group by 1 order by 1 loop
    key := p_selections -> 'options' ->> grp.choice_group::text;
    if key is null and grp.n_opt = 1 then
      select option_key into key from public.class_starting_equipment where class_version_id = p_class_version and choice_group = grp.choice_group;
    end if;
    select * into opt from public.class_starting_equipment
    where class_version_id = p_class_version and choice_group = grp.choice_group and option_key = key;
    if not found then raise exception 'Choose an option for starting equipment group %', grp.choice_group using errcode = '22023'; end if;
    for x, n in select t.x, t.n from jsonb_array_elements(opt.items) with ordinality t(x, n) loop
      if x ? 'unresolved' then
        skipped := skipped || jsonb_build_object('group', grp.choice_group, 'option', key, 'text', x ->> 'unresolved');
        continue;
      end if;
      if x ? 'item_id' then
        perform public.add_inventory_item(inv, x ->> 'item_id', coalesce((x ->> 'quantity')::int, 1), null,
                                          format('Starting equipment (%s)', cname), '{}'::jsonb);
        added := added || jsonb_build_object('item_id', x ->> 'item_id', 'quantity', coalesce((x ->> 'quantity')::int, 1));
        continue;
      end if;
      pick := p_selections -> 'picks' -> format('%s:%s:%s', grp.choice_group, key, n - 1);
      ids := case jsonb_typeof(pick) when 'string' then array_fill(pick #>> '{}', array[coalesce((x ->> 'quantity')::int, 1)])
                                     when 'array' then array(select jsonb_array_elements_text(pick)) end;
      if ids is null or cardinality(ids) <> coalesce((x ->> 'quantity')::int, 1) then
        raise exception 'Choose % for "%"', coalesce((x ->> 'quantity')::int, 1), coalesce(x ->> 'label', opt.label) using errcode = '22023';
      end if;
      cands := public._starting_equipment_candidates(x);
      foreach iid in array ids loop
        if not exists (select 1 from jsonb_array_elements(cands) c where c ->> 'id' = iid) then
          raise exception '"%" is not a choice for "%"', iid, coalesce(x ->> 'label', opt.label) using errcode = '22023';
        end if;
        perform public.add_inventory_item(inv, iid, 1, null, format('Starting equipment (%s)', cname), '{}'::jsonb);
        added := added || jsonb_build_object('item_id', iid, 'quantity', 1);
      end loop;
    end loop;
  end loop;

  insert into public.character_starting_equipment (character_id, class_version_id, selections, added, skipped, applied_by)
  values (p_character, p_class_version, p_selections, added, skipped, auth.uid());
  return jsonb_build_object('class_version_id', p_class_version, 'added', added, 'skipped', skipped);
end;
$$;
revoke all on function public.apply_class_starting_equipment(uuid, text, jsonb) from public, anon;
grant execute on function public.apply_class_starting_equipment(uuid, text, jsonb) to authenticated;

-- ---- guided Add Class preview ----------------------------------------------------------------------------------------------
-- The class is added in a savepoint (set_character_class: every rule it checks applies), read back, and rolled back.
create function public.preview_character_class_add(p_character uuid, p_class_version text, p_level int default 1,
                                                   p_subclass_version text default null)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare cv public.class_versions; fb jsonb; fa jsonb; sb jsonb; sa jsonb; mb jsonb; ma jsonb; d jsonb; err text; row_id uuid;
  first boolean; prereq jsonb := '[]'; e jsonb; ok boolean;
begin
  if auth.uid() is null or not public.can_access_character(p_character) then
    raise exception 'Character not found' using errcode = '42501';
  end if;
  select * into cv from public.class_versions where id = p_class_version;
  if not found then raise exception 'Unknown class version "%"', p_class_version using errcode = '22023'; end if;
  if exists (select 1 from public.character_classes where character_id = p_character and class_id = cv.class_id) then
    return jsonb_build_object('possible', false, 'error', format('This character already has %s', cv.name));
  end if;
  first := not exists (select 1 from public.character_classes where character_id = p_character);
  fb := public.get_character_class_features(p_character); sb := public.get_character_spell_slots(p_character);
  mb := public.get_character_class_summary(p_character);
  d := public.get_character_derived_stats(p_character);
  begin
    perform public.set_character_class(p_character, p_class_version, coalesce(p_level, 1), p_subclass_version);
    select id into row_id from public.character_classes where character_id = p_character and class_id = cv.class_id;
    fa := public.get_character_class_features(p_character); sa := public.get_character_spell_slots(p_character);
    ma := public.get_character_class_summary(p_character);
    raise exception using errcode = 'P0001', message = 'tavern-preview-rollback';
  exception when others then
    if sqlerrm <> 'tavern-preview-rollback' then err := sqlerrm; end if;
  end;
  if err is not null then return jsonb_build_object('possible', false, 'error', err); end if;

  -- multiclass prerequisites of every class (after the change), with the scores they are checked against
  for e in select k from jsonb_array_elements(ma -> 'classes') k where jsonb_typeof(k -> 'multiclass_prerequisite') = 'object' loop
    select case when e -> 'multiclass_prerequisite' ? 'any'
                then bool_or(coalesce((d -> 'abilities' -> (x ->> 'ability') ->> 'score')::int, 0) >= (x ->> 'min')::int)
                else bool_and(coalesce((d -> 'abilities' -> (x ->> 'ability') ->> 'score')::int, 0) >= (x ->> 'min')::int) end
    into ok from jsonb_array_elements(coalesce(e -> 'multiclass_prerequisite' -> 'all', e -> 'multiclass_prerequisite' -> 'any')) x;
    prereq := prereq || jsonb_build_object('class_id', e ->> 'class_id', 'class_name', e ->> 'class_name', 'met', coalesce(ok, true),
      'new_class', e ->> 'class_id' = cv.class_id,
      'requirement', (select string_agg(upper(x ->> 'ability') || ' ' || (x ->> 'min'),
                                        case when e -> 'multiclass_prerequisite' ? 'any' then ' or ' else ' and ' end)
                      from jsonb_array_elements(coalesce(e -> 'multiclass_prerequisite' -> 'all', e -> 'multiclass_prerequisite' -> 'any')) x),
      'scores', (select jsonb_object_agg(x ->> 'ability', (d -> 'abilities' -> (x ->> 'ability') ->> 'score')::int)
                 from jsonb_array_elements(coalesce(e -> 'multiclass_prerequisite' -> 'all', e -> 'multiclass_prerequisite' -> 'any')) x));
  end loop;

  return jsonb_build_object('possible', true, 'stored', false, 'class_id', cv.class_id, 'class_name', cv.name,
           'class_version_id', cv.id, 'hit_die', cv.hit_die, 'first_class', first,
           'prerequisites', case when first then '[]'::jsonb else prereq end,
           'prerequisites_met', first or not exists (select 1 from jsonb_array_elements(prereq) p where not (p ->> 'met')::boolean),
           'starting_equipment', case when first then public.get_class_starting_equipment(cv.id) end,
           'starting_equipment_note', case when first then 'Starting equipment comes with your first class; review it after adding the class.'
                                           else 'A class gained by multiclassing grants no starting equipment.' end)
         || public._cf_diff(fb, fa, row_id, sb, sa, mb, ma);
end;
$$;
revoke all on function public.preview_character_class_add(uuid, text, int, text) from public, anon;
grant execute on function public.preview_character_class_add(uuid, text, int, text) to authenticated;
