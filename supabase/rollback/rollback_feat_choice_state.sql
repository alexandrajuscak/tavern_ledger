-- Rollback of 20261109000100_feat_choice_state.sql: restores the exact previous definitions (md5 of pg_get_functiondef:
-- get_character_feats dd145f0f, _sync_character_feats 5c5e26e6, _character_feat_effects e2ac0600) and drops the helper.
-- No data is changed.
begin;
CREATE OR REPLACE FUNCTION public.get_character_feats(p_character uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare ctx jsonb; out jsonb := '[]'; g record; fv jsonb; ch jsonb; eff jsonb; spells jsonb; res jsonb; warn jsonb := '[]'; dup jsonb;
begin
  if auth.uid() is null or not public.can_access_character(p_character) then raise exception 'Character not found' using errcode = '42501'; end if;
  ctx := public._feat_prereq_ctx(p_character);
  for g in select * from public._character_feat_grants(p_character) order by ord, grant_key loop
    fv := public._feat_version_json(g.feat_version_id);
    select coalesce(jsonb_agg(jsonb_build_object('choice_id', c.choice_id, 'key', c.key, 'kind', c.kind, 'label', c.label,
             'min', c.min_picks, 'max', c.max_picks, 'config', c.config, 'values', to_jsonb(c.vals), 'fixed', c.fixed,
             'status', case when c.fixed then 'fixed' when c.complete then 'complete' else 'incomplete' end,
             'value_labels', (select coalesce(jsonb_agg(coalesce(
                 (select o.label from public.feat_choice_options o where o.choice_id = c.choice_id and o.option_id = v),
                 (select name from public.spell_versions where id = v), (select name from public.skills where id = v),
                 (select name from public.items where id = v), (select name from public.languages where id = v),
                 (select name from public.skills where id = split_part(v, ':', 2)), (select name from public.items where id = split_part(v, ':', 2)),
                 v)), '[]') from unnest(c.vals) v)) order by c.key), '[]')
    into ch from public._character_feat_choice_values(p_character) c where c.grant_key = g.grant_key;
    select coalesce(jsonb_agg(jsonb_build_object('effect_type', e.effect_type, 'target', e.target, 'value', e.value, 'value_text', e.value_text,
             'active', e.active, 'inactive_reason', e.inactive_reason, 'automation', e.automation, 'label', fe.label, 'activation', fe.activation)
             order by e.seq, e.pick), '[]')
    into eff from public._character_feat_effects(p_character) e left join public.feat_effects fe on fe.version_id = e.feature_version_id and fe.seq = e.seq
    where e.unlock_id = g.grant_key;
    select coalesce(jsonb_agg(jsonb_build_object('character_spell_id', cs.id, 'spell_version_id', cs.spell_version_id,
             'name', (select name from public.spell_versions where id = cs.spell_version_id), 'casting_ability', cs.casting_ability,
             'always_prepared', cs.always_prepared, 'uses_spell_slot', cs.uses_spell_slot)), '[]')
    into spells from public.character_spellcasting_sources s join public.character_spells cs on cs.source_id = s.id
    where s.character_id = p_character and s.feat_grant_key = g.grant_key;
    select coalesce(jsonb_agg(jsonb_build_object('key', 'r:' || r.id, 'name', r.name, 'active', r.active, 'expended', r.expended,
             'max', (public._resource_max(r.max_formula, jsonb_build_object('total_level', (ctx ->> 'total_level')::int,
                      'proficiency_bonus', ((ctx ->> 'total_level')::int - 1) / 4 + 2, 'mods', '{}'::jsonb)) ->> 'max')::int,
             'recharge', r.recharge, 'spell_version_id', r.spell_version_id)), '[]')
    into res from public.character_resources r where r.character_id = p_character and r.source_type = 'feat' and r.source_id = g.grant_key;
    out := out || jsonb_build_array(jsonb_build_object(
      'grant_key', g.grant_key, 'source_type', g.source_type, 'source_label', g.source_label, 'character_feat_id', g.character_feat_id,
      'active', g.active, 'inactive_reason', g.inactive_reason, 'parameter', g.parameter,
      'feat', fv, 'prerequisite', public._feat_prereq_eval(g.feat_version_id, ctx),
      'prerequisite_override', (select jsonb_build_object('reason', override_reason, 'by', override_by) from public.character_feats
                                where id = g.character_feat_id and prerequisite_override),
      'notes', (select notes from public.character_feats where id = g.character_feat_id),
      'choices', ch, 'effects', eff, 'spells', spells, 'resources', res,
      'open_choices', (select count(*) from jsonb_array_elements(ch) c where c ->> 'status' = 'incomplete')));
  end loop;
  -- the same feat from two grants (allowed for repeatable feats only)
  select coalesce(jsonb_agg(jsonb_build_object('code', 'duplicate_feat', 'feat_id', x.feat_id, 'count', x.n)), '[]') into dup from (
    select fv2.feat_id, count(*) as n from public._character_feat_grants(p_character) g2 join public.feat_versions fv2 on fv2.id = g2.feat_version_id
    where g2.active and fv2.repeatable = 'once' group by 1 having count(*) > 1) x;
  warn := warn || dup;
  return jsonb_build_object('character_id', p_character, 'feats', out,
    'open_choices', (select coalesce(sum((f ->> 'open_choices')::int), 0) from jsonb_array_elements(out) f),
    'placeholders', public._character_feat_placeholders(p_character), 'warnings', warn,
    'hit_points', public._feat_hp_bonus(p_character));
end;
$function$;

CREATE OR REPLACE FUNCTION public._sync_character_feats(p_character uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare g record; rg public.feat_resource_grants; sg public.feat_spell_grants; src uuid; ab text; lst text; fv public.feat_versions;
  vals text[]; v text; keep_keys text[] := '{}'; keep_sources text[] := '{}'; complete boolean; hp_after int; hp_max_now int;
  engine_before text := coalesce(current_setting('tavern.resource_engine', true), '');
begin
  perform set_config('tavern.resource_engine', 'on', true);   -- reset below: the bypass of the resource guard ends with this sync
  for g in select * from public._character_feat_grants(p_character) loop
    select * into fv from public.feat_versions where id = g.feat_version_id;
    select coalesce(bool_and(c.complete), true) into complete from public._character_feat_choice_values(p_character) c where c.grant_key = g.grant_key;
    -- resources (kept with their expended count while the grant is inactive)
    for rg in select * from public.feat_resource_grants where version_id = g.feat_version_id loop
      keep_keys := keep_keys || public._feat_resource_key(g.grant_key, rg.key);
      insert into public.character_resources (character_id, resource_key, name, source_type, source_id, max_formula, recharge, active, notes, created_by)
      values (p_character, public._feat_resource_key(g.grant_key, rg.key), left(rg.name, 80), 'feat', g.grant_key, rg.max_formula, rg.recharge,
              g.active, left(fv.name || ' (' || g.source_label || ')', 500), auth.uid())
      on conflict (character_id, resource_key) do update set active = excluded.active, max_formula = excluded.max_formula,
        recharge = excluded.recharge, name = excluded.name;
    end loop;
    -- spells: one spellcasting source per grant with spells, only while the grant is active and its choices complete
    if exists (select 1 from public.feat_spell_grants where version_id = g.feat_version_id) and g.active and complete then
      keep_sources := keep_sources || g.grant_key;
      select sg2.ability, sg2.ability_choice_key, sg2.ability_from_option into sg.ability, sg.ability_choice_key, sg.ability_from_option
      from public.feat_spell_grants sg2 where sg2.version_id = g.feat_version_id order by seq limit 1;
      ab := coalesce(sg.ability,
        (select c.vals[1] from public._character_feat_choice_values(p_character) c where c.grant_key = g.grant_key and c.key = sg.ability_choice_key),
        (select o.data ->> 'ability' from public._character_feat_choice_values(p_character) c
           join public.feat_choice_options o on o.choice_id = c.choice_id and o.option_id = c.vals[1]
         where c.grant_key = g.grant_key and c.key = sg.ability_from_option));
      lst := (select c.vals[1] from public._character_feat_choice_values(p_character) c where c.grant_key = g.grant_key and c.kind = 'spell_list' limit 1);
      select id into src from public.character_spellcasting_sources where character_id = p_character and feat_grant_key = g.grant_key;
      if src is null then
        insert into public.character_spellcasting_sources (character_id, source_type, label, spell_list_id, casting_ability, preparation_mode,
                                                           ritual_mode, uses_spell_slots, feat_grant_key, notes, created_by)
        values (p_character, 'feat', left(fv.name || ' (' || replace(g.source_label, 'Background: ', '') || ')', 80), lst, ab, 'innate', 'none',
                true, g.grant_key, 'Granted by a feat; removed with the feat.', auth.uid())
        returning id into src;
      else
        update public.character_spellcasting_sources set casting_ability = ab, spell_list_id = lst where id = src;
      end if;
      -- the spells of the grant (exact catalog versions; never copied)
      delete from public.character_spells cs where cs.source_id = src and cs.spell_version_id not in (
        select coalesce(x.spell_version_id, y.v) from public.feat_spell_grants x
        left join lateral (select unnest(c.vals) as v from public._character_feat_choice_values(p_character) c
                           where c.grant_key = g.grant_key and c.key = x.choice_key) y on x.choice_key is not null
        where x.version_id = g.feat_version_id and coalesce(x.spell_version_id, y.v) is not null);
      for sg in select * from public.feat_spell_grants where version_id = g.feat_version_id order by seq loop
        vals := case when sg.spell_version_id is not null then array[sg.spell_version_id]
                     else (select c.vals from public._character_feat_choice_values(p_character) c where c.grant_key = g.grant_key and c.key = sg.choice_key) end;
        foreach v in array coalesce(vals, '{}') loop
          insert into public.character_spells (character_id, source_id, spell_version_id, known, prepared, always_prepared,
                                               counts_against_known_limit, counts_against_prepared_limit, uses_spell_slot, casting_ability,
                                               acquisition, acquisition_notes)
          values (p_character, src, v, true, sg.mode = 'always_prepared', sg.mode = 'always_prepared', false, false, sg.uses_slots, ab,
                  'feature', left(sg.label, 300))
          on conflict (source_id, spell_version_id) do update set casting_ability = excluded.casting_ability, uses_spell_slot = excluded.uses_spell_slot;
          if sg.uses in ('long_rest_1', 'pb_long_rest') then
            keep_keys := keep_keys || public._feat_resource_key(g.grant_key, 'cast-' || replace(v, '_', '-'));
            insert into public.character_resources (character_id, resource_key, name, source_type, source_id, max_formula, recharge,
                                                    spell_version_id, active, notes, created_by)
            values (p_character, public._feat_resource_key(g.grant_key, 'cast-' || replace(v, '_', '-')),
                    left('Free cast: ' || coalesce((select name from public.spell_versions where id = v), v), 80), 'feat', g.grant_key,
                    case when sg.uses = 'pb_long_rest' then '{"terms": [{"of": "proficiency_bonus"}]}'::jsonb else '{"fixed": 1}'::jsonb end,
                    'long_rest', v, true, left(fv.name || ': cast once without a spell slot', 500), auth.uid())
            on conflict (character_id, resource_key) do update set active = true;
          end if;
        end loop;
      end loop;
    end if;
  end loop;
  -- grants that are gone: their spell sources are removed (other sources of the same spell stay), resources deactivated
  delete from public.character_spellcasting_sources s where s.character_id = p_character and s.feat_grant_key is not null
    and not s.feat_grant_key = any (keep_sources);
  update public.character_resources r set active = false where r.character_id = p_character and r.source_type = 'feat'
    and not r.resource_key = any (keep_keys) and r.active;
  -- maximum HP policy: if the resolved maximum dropped below the current HP (a feat like Tough removed), clamp current HP
  hp_max_now := (public._feat_hp_bonus(p_character) ->> 'max')::int;
  update public.characters set hp_current = hp_max_now where id = p_character and hp_current > hp_max_now;
  perform set_config('tavern.resource_engine', engine_before, true);
end;
$function$;

CREATE OR REPLACE FUNCTION public._character_feat_effects(p_character uuid)
 RETURNS TABLE(character_class_id uuid, class_id text, class_name text, class_level integer, unlock_id text, feature_version_id text, feature_name text, origin text, seq integer, pick integer, effect_type text, target text, value numeric, value_text text, spell_version_id text, min_level integer, conditions jsonb, data jsonb, automation text, spellcasting_ability text, feature_active boolean, active boolean, inactive_reason text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  with g as (select * from public._character_feat_grants(p_character)),
  ch as (select * from public._character_feat_choice_values(p_character)),
  lvl as (select coalesce((public._character_level_info(p_character) ->> 'total_level')::int,
                          (select level from public.characters where id = p_character)) as total),
  -- every effect of every granted version; an effect with a choice key yields one row per chosen value
  e as (
    select g.grant_key, g.active as grant_active, g.inactive_reason as grant_reason, fv.name as feat_name, fv.id as version_id,
           fe.seq, fe.effect_type, fe.target, fe.value, fe.value_text, fe.automation, fe.conditions, fe.data, fe.choice_key,
           fe.option_choice_key, fe.option_id, c.vals, c.complete as choice_complete, c.kind as choice_kind
    from g join public.feat_versions fv on fv.id = g.feat_version_id
    join public.feat_effects fe on fe.version_id = fv.id
    left join ch c on c.grant_key = g.grant_key and c.key = fe.choice_key
    where fe.option_choice_key is null
       or exists (select 1 from ch o where o.grant_key = g.grant_key and o.key = fe.option_choice_key and fe.option_id = any (o.vals))
    union all
    -- ability increases come from the choices themselves
    select g.grant_key, g.active, g.inactive_reason, fv.name, fv.id, 1000 + c.ord, 'ability_bonus', null, null, null, 'automated', '{}'::jsonb,
           jsonb_build_object('max', c.config -> 'max'), c.key, null, null, c.vals, c.complete, c.kind
    from g join public.feat_versions fv on fv.id = g.feat_version_id
    join (select x.*, row_number() over (partition by x.grant_key order by x.key)::int as ord from ch x
          where x.kind in ('ability_increase', 'asi_points')) c on c.grant_key = g.grant_key)
  select md5('feat:' || e.grant_key)::uuid, 'feat', 'Feat', l.total, e.grant_key, e.version_id, e.feat_name, 'feat', e.seq,
         case when e.choice_key is null then 0 else x.pick end,
         e.effect_type,
         case when e.choice_key is null then e.target
              when e.choice_kind = 'ability_increase' or e.choice_kind = 'asi_points' then split_part(x.val, ':', 1)
              when e.effect_type in ('proficiency', 'expertise') and e.choice_kind = 'skill_or_tool' then split_part(x.val, ':', 1)
              when e.effect_type in ('proficiency', 'expertise') and e.choice_kind in ('skill', 'expertise') then coalesce(e.target, 'skill')
              when e.effect_type = 'proficiency' and e.choice_kind = 'tool' then 'tool'
              when e.effect_type = 'proficiency' and e.choice_kind = 'weapon' then 'weapon'
              when e.effect_type = 'proficiency' and e.choice_kind = 'language' then 'language'
              when e.effect_type = 'resistance' then x.val
              else e.target end,
         case when e.choice_kind = 'asi_points' then split_part(x.val, ':', 2)::numeric
              when e.choice_kind = 'ability_increase' then coalesce((ch2.config ->> 'amount')::numeric, 1)
              else e.value end,
         case when e.choice_key is null then e.value_text
              when e.choice_kind = 'skill_or_tool' then split_part(x.val, ':', 2)
              when e.choice_kind in ('ability_increase', 'asi_points') then null
              when e.effect_type = 'resistance' then x.val
              else x.val end,
         null::text, 1, e.conditions, e.data || jsonb_build_object('grant_key', e.grant_key), e.automation, null::text,
         e.grant_active,
         e.grant_active and coalesce(e.choice_complete, true) and (e.choice_key is null or x.val is not null),
         case when not e.grant_active then coalesce(e.grant_reason, 'inactive')
              when not coalesce(e.choice_complete, true) then 'choice_incomplete' end
  from e
  cross join lvl l
  left join ch ch2 on ch2.grant_key = e.grant_key and ch2.key = e.choice_key
  left join lateral (select v as val, o::int as pick from unnest(coalesce(e.vals, '{}')) with ordinality u(v, o)) x on e.choice_key is not null
  where e.choice_key is null or x.val is not null or not coalesce(e.choice_complete, false);
$function$;

drop function if exists public._feat_choice_issues(uuid);
update tl_cache.global_rev set rev = rev + 1 where id = 1;
commit;
