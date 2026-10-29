-- Incident 2026-10-23 (docs/PRODUCTION_INCIDENT_REALTIME_TIMEOUTS.md, docs/PERFORMANCE_AUDIT_2026-10-27.md R1).
-- _derived_stats_full listed the armor / weapon / tool proficiencies by joining public.items on a jsonb_array_elements() set.
-- The planner estimates 1 row for that set, hashes the whole items catalog and evaluates the items RLS policy
-- (_item_visible) on every catalog row: production 144 ms per evaluation (EXPLAIN ANALYZE as authenticated, 2026-10-29),
-- and it runs in about 8 of the RPCs of every sheet open. The same lookups as scalar subselects use the primary key:
-- 3.6 ms. RLS still applies to every looked-up row (an item the player may not see yields NULL, exactly as the outer join
-- did), and the result is identical (verified for every local character, golden comparison).
-- Only this one statement changes; the rest of the function body is the current definition (20261019000300_feat_catalog).
-- Rollback: supabase/rollback/rollback_derived_stats_items_lookup.sql
begin;

CREATE OR REPLACE FUNCTION public._derived_stats_full(p_character uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare d jsonb; eff jsonb; c public.characters; pb int; mods jsonb; k text; e jsonb; skills jsonb; saves jsonb; profs jsonb := '[]';
  weapons jsonb := '[]'; w jsonb; atk int; dmg int; parts_a jsonb; parts_d jsonb; one_weapon boolean; n_weapons int; attacks jsonb := '[]';
  ab text; ab_mod int; dice text; dbonus int; ac jsonb; cand jsonb; best_val int; base_now int; f_parts jsonb; extra jsonb; crit jsonb;
  init_parts jsonb; init_total int; langs jsonb; man int; applied jsonb := '[]'; info jsonb := '[]'; cond text;
  half jsonb; half_val int; senses jsonb; riders jsonb := '[]'; adv jsonb := '[]'; tool_exp jsonb := '[]'; notes jsonb;
  maxes jsonb := '{}'; unarmed boolean; cimm jsonb := '[]'; bonus int;
begin
  d := public._derived_stats_levels(p_character);                  -- RLS: owner, campaign DM, admin
  select coalesce(jsonb_agg(to_jsonb(x) order by x.class_id, x.unlock_id, x.seq, x.pick), '[]') into eff
  from public._character_feature_effects(p_character) x where x.feature_active;
  if eff = '[]'::jsonb then
    return d || jsonb_build_object('class_features', jsonb_build_object('applied', '[]'::jsonb, 'informational', '[]'::jsonb),
                                   'attacks_per_action', jsonb_build_object('value', 1, 'sources', '[]'::jsonb),
                                   'critical_range', jsonb_build_object('value', 20, 'sources', '[]'::jsonb),
                                   'feature_attacks', '[]'::jsonb, 'attack_riders', '[]'::jsonb, 'check_half_proficiency', null,
                                   'situational_advantages', '[]'::jsonb, 'tool_expertise', '[]'::jsonb, 'ability_maximums', '{}'::jsonb,
                                   'condition_immunity_sources', '[]'::jsonb);
  end if;
  select * into c from public.characters where id = p_character;
  pb := (d -> 'proficiency_bonus' ->> 'value')::int;
  select jsonb_object_agg(x, (d -> 'abilities' -> x ->> 'modifier')::int) into mods from jsonb_object_keys(d -> 'abilities') x;

  -- skills: class proficiency, then expertise (only for a skill the character is proficient in from any source)
  skills := coalesce(d -> 'skills', '{}');
  for e in select x from jsonb_array_elements(eff) x
           where (x ->> 'active')::boolean and x ->> 'effect_type' = 'proficiency' and x ->> 'target' = 'skill' loop
    k := e ->> 'value_text';
    skills := skills || jsonb_build_object(k, coalesce(skills -> k, '{"advantage": false, "disadvantage": false, "sources": []}'::jsonb)
      || jsonb_build_object('class_proficient', true, 'proficiency_sources',
           coalesce(skills -> k -> 'proficiency_sources', '[]') || jsonb_build_array(jsonb_build_object('source_type', 'class',
             'source_name', (e ->> 'class_name') || ': ' || (e ->> 'feature_name'), 'character_class_id', e ->> 'character_class_id'))));
  end loop;
  for e in select x from jsonb_array_elements(eff) x
           where (x ->> 'active')::boolean and x ->> 'effect_type' = 'expertise' and x ->> 'target' = 'skill' loop
    k := e ->> 'value_text';
    man := public._skill_level(c.skill_proficiencies -> k);
    if man >= 1 or (coalesce((skills -> k ->> 'lineage_proficient')::boolean, false) or coalesce((skills -> k ->> 'background_proficient')::boolean, false)) or coalesce((skills -> k ->> 'class_proficient')::boolean, false) then
      skills := skills || jsonb_build_object(k, coalesce(skills -> k, '{"advantage": false, "disadvantage": false, "sources": []}'::jsonb)
        || jsonb_build_object('class_expertise', true, 'expertise_sources',
             coalesce(skills -> k -> 'expertise_sources', '[]') || jsonb_build_array(jsonb_build_object('source_type', 'class',
               'source_name', (e ->> 'class_name') || ': ' || (e ->> 'feature_name')))));
    else
      info := info || jsonb_build_object('code', 'expertise_without_proficiency', 'skill', k, 'feature_name', e ->> 'feature_name');
    end if;
  end loop;

  -- expertise in tools (Rogue Expertise with thieves' tools ...): listed; tool checks are made by the player
  select coalesce(jsonb_agg(jsonb_build_object('item_id', x ->> 'value_text',
           'name', coalesce((select i.name from public.items i where i.id = x ->> 'value_text'), x ->> 'value_text'),
           'source_name', (x ->> 'class_name') || ': ' || (x ->> 'feature_name'))), '[]')
  into tool_exp from jsonb_array_elements(eff) x
  where (x ->> 'active')::boolean and x ->> 'effect_type' = 'expertise' and x ->> 'target' = 'tool';

  -- half proficiency on ability checks without proficiency (the best source counts; the sheet adds it only to a skill that
  -- has no proficiency from any source). The amount is the proficiency bonus halved with the effect's rounding.
  select x into half from jsonb_array_elements(eff) x
  where (x ->> 'active')::boolean and x ->> 'effect_type' = 'skill_half_proficiency'
  order by case when x -> 'data' ->> 'rounding' = 'up' then (pb + 1) / 2 else pb / 2 end desc,
           jsonb_array_length(coalesce(x -> 'data' -> 'abilities', '["str","dex","con","int","wis","cha"]')) desc limit 1;
  if half is not null then
    half_val := case when half -> 'data' ->> 'rounding' = 'up' then (pb + 1) / 2 else pb / 2 end;
    for k in select s.id from public.skills s
             where not half -> 'data' ? 'abilities' or half -> 'data' -> 'abilities' ? s.ability loop
      skills := skills || jsonb_build_object(k, coalesce(skills -> k, '{"advantage": false, "disadvantage": false, "sources": []}'::jsonb)
        || jsonb_build_object('half_proficiency', jsonb_build_object('value', half_val,
             'source_name', (half ->> 'class_name') || ': ' || (half ->> 'feature_name'))));
    end loop;
    half := jsonb_build_object('value', half_val, 'abilities', coalesce(half -> 'data' -> 'abilities', '["str","dex","con","int","wis","cha"]'),
                               'rounding', coalesce(half -> 'data' ->> 'rounding', 'down'),
                               'includes_initiative', coalesce((half -> 'data' ->> 'initiative')::boolean, false),
                               'source_name', (half ->> 'class_name') || ': ' || (half ->> 'feature_name'));
  end if;

  -- saving throws: class proficiency (the starting proficiencies of the primary class)
  saves := coalesce(d -> 'saving_throws', '{}');
  for e in select x from jsonb_array_elements(eff) x
           where (x ->> 'active')::boolean and x ->> 'effect_type' = 'proficiency' and x ->> 'target' = 'save' loop
    k := e ->> 'value_text';
    saves := saves || jsonb_build_object(k, coalesce(saves -> k, '{}'::jsonb) || jsonb_build_object('class_proficient', true,
      'class_sources', coalesce(saves -> k -> 'class_sources', '[]') || to_jsonb((e ->> 'class_name') || ': ' || (e ->> 'feature_name'))));
  end loop;

  -- saving throw bonus equal to an ability modifier (an aura that protects you): class_bonus per save (the best source)
  for e in select x from jsonb_array_elements(eff) x where (x ->> 'active')::boolean and x ->> 'effect_type' = 'save_bonus_ability' loop
    bonus := greatest(coalesce((mods ->> (e -> 'data' ->> 'ability'))::int, 0), coalesce((e -> 'data' ->> 'minimum')::int, -99));
    for k in select a from jsonb_array_elements_text('["str","dex","con","int","wis","cha"]') a where e ->> 'target' is null or a = e ->> 'target' loop
      if bonus > coalesce((saves -> k ->> 'class_bonus')::int, 0) then
        saves := saves || jsonb_build_object(k, coalesce(saves -> k, '{}'::jsonb) || jsonb_build_object('class_bonus', bonus,
          'class_bonus_sources', jsonb_build_array((e ->> 'class_name') || ': ' || (e ->> 'feature_name'))));
      end if;
    end loop;
  end loop;
  -- immunity to conditions
  select coalesce(jsonb_agg(jsonb_build_object('condition', t, 'sources', s) order by t), '[]') into cimm from (
    select x ->> 'target' as t, jsonb_agg(distinct (x ->> 'class_name') || ': ' || (x ->> 'feature_name')) as s
    from jsonb_array_elements(eff) x where (x ->> 'active')::boolean and x ->> 'effect_type' = 'condition_immunity' group by 1) c;

  -- armor / weapon / tool / group proficiencies listed with their class source (matching is done by _proficiency_match)
  select coalesce(jsonb_agg(jsonb_build_object('id', null, 'proficiency_type',
           case x ->> 'target' when 'group' then g.proficiency_type when 'armor' then
                case when (select i.category_id from public.items i where i.id = x ->> 'value_text') = 'shield' then 'shield' else 'armor' end else x ->> 'target' end,
           'group_id', case when x ->> 'target' = 'group' then x ->> 'value_text' end,
           'item_id', case when x ->> 'target' in ('armor', 'weapon', 'tool') then x ->> 'value_text' end,
           'name', coalesce(g.name, (select i.name from public.items i where x ->> 'target' in ('weapon', 'armor', 'tool') and i.id = x ->> 'value_text'), x ->> 'value_text'), 'source_type', 'class',
           'notes', (x ->> 'class_name') || ': ' || (x ->> 'feature_name'), 'character_class_id', x ->> 'character_class_id')
           order by x ->> 'target', coalesce(g.name, (select i.name from public.items i where x ->> 'target' in ('weapon', 'armor', 'tool') and i.id = x ->> 'value_text'))), '[]')
  into profs
  from jsonb_array_elements(eff) x
  left join public.proficiency_groups g on x ->> 'target' = 'group' and g.id = x ->> 'value_text'
  where (x ->> 'active')::boolean and x ->> 'effect_type' = 'proficiency' and x ->> 'target' in ('armor', 'weapon', 'tool', 'group');

  -- languages granted by class features
  langs := coalesce(d -> 'languages', '[]');
  for e in select x from jsonb_array_elements(eff) x
           where (x ->> 'active')::boolean and x ->> 'effect_type' = 'proficiency' and x ->> 'target' = 'language' loop
    langs := langs || jsonb_build_array(jsonb_build_object('id', e ->> 'value_text',
      'name', coalesce((select name from public.languages where id = e ->> 'value_text'), e ->> 'value_text'),
      'sources', jsonb_build_array((e ->> 'class_name') || ': ' || (e ->> 'feature_name'))));
  end loop;

  -- equipped weapons: class attack / damage bonuses with weapon conditions (Archery: ranged; Dueling: one melee weapon only)
  select count(*) into n_weapons from jsonb_array_elements(coalesce(d -> 'equipped_weapon_attacks', '[]'));
  for w in select x from jsonb_array_elements(coalesce(d -> 'equipped_weapon_attacks', '[]')) x loop
    atk := 0; dmg := 0; parts_a := '[]'; parts_d := '[]';
    one_weapon := n_weapons = 1 and not coalesce((w ->> 'is_ranged')::boolean, false) and not coalesce(w -> 'properties' ? 'two-handed', false);
    for e in select x from jsonb_array_elements(eff) x
             where (x ->> 'active')::boolean and x ->> 'effect_type' in ('attack_bonus', 'damage_bonus') loop
      cond := coalesce(e -> 'conditions' ->> 'weapon', 'any');
      continue when cond = 'thrown';
      continue when cond = 'ranged' and not coalesce((w ->> 'is_ranged')::boolean, false);
      continue when cond = 'melee' and coalesce((w ->> 'is_ranged')::boolean, false);
      continue when cond = 'one_handed_melee_only' and not one_weapon;
      continue when e -> 'conditions' ? 'ability' and w ->> 'ability' is distinct from e -> 'conditions' ->> 'ability';
      if e ->> 'effect_type' = 'attack_bonus' then
        atk := atk + (e ->> 'value')::int;
        parts_a := parts_a || jsonb_build_object('source_type', 'class', 'source_name', (e ->> 'class_name') || ': ' || (e ->> 'feature_name'),
                                                 'effect', 'attack_bonus', 'value', (e ->> 'value')::int, 'condition', cond);
      else
        dmg := dmg + (e ->> 'value')::int;
        parts_d := parts_d || jsonb_build_object('source_type', 'class', 'source_name', (e ->> 'class_name') || ': ' || (e ->> 'feature_name'),
                                                 'effect', 'damage_bonus', 'value', (e ->> 'value')::int, 'condition', cond);
      end if;
    end loop;
    -- conditional bonuses (thrown: only when the weapon is thrown) are shown next to the weapon, never added
    select coalesce(jsonb_agg(jsonb_build_object('effect', x ->> 'effect_type', 'value', (x ->> 'value')::int, 'condition', 'thrown',
             'source_name', (x ->> 'class_name') || ': ' || (x ->> 'feature_name'))), '[]')
    into notes from jsonb_array_elements(eff) x
    where (x ->> 'active')::boolean and x ->> 'effect_type' in ('attack_bonus', 'damage_bonus') and x -> 'conditions' ->> 'weapon' = 'thrown'
      and coalesce(w -> 'properties' ? 'thrown', false);
    if jsonb_array_length(notes) > 0 then w := w || jsonb_build_object('conditional_bonuses', notes); end if;
    if atk <> 0 or dmg <> 0 then
      dbonus := (w ->> 'damage_bonus')::int + dmg;
      w := w || jsonb_build_object('attack_bonus', (w ->> 'attack_bonus')::int + atk, 'class_attack_bonus', atk,
        'attack_breakdown', (w -> 'attack_breakdown') || parts_a, 'damage_bonus', dbonus, 'class_damage_bonus', dmg,
        'damage_breakdown', (w -> 'damage_breakdown') || parts_d,
        'damage', case when w ->> 'damage_dice' is null then null
                       when w ->> 'damage_dice' ~ '^[0-9]+$' then greatest(0, (w ->> 'damage_dice')::int + dbonus)::text
                       when dbonus = 0 then w ->> 'damage_dice'
                       else (w ->> 'damage_dice') || case when dbonus > 0 then ' + ' else ' - ' end || abs(dbonus) end);
    end if;
    weapons := weapons || w;
  end loop;

  -- attacks granted by features (always available; contextual use is up to the player)
  unarmed := n_weapons = 0 and not exists (select 1 from public.character_equipment q where q.character_id = p_character and q.slot_id = 'shield');
  for e in select x from jsonb_array_elements(eff) x where (x ->> 'active')::boolean and x ->> 'effect_type' = 'attack' loop
    ab := coalesce(e -> 'data' ->> 'ability', 'str');
    ab := case ab when 'finesse' then case when (mods ->> 'dex')::int > (mods ->> 'str')::int then 'dex' else 'str' end
                  when 'spell' then coalesce(e ->> 'spellcasting_ability', 'int') else ab end;
    ab_mod := case when ab = 'none' then 0 else (mods ->> ab)::int end;
    dice := coalesce(case when unarmed then e -> 'data' ->> 'damage_dice_unarmed' end,
                     (select y ->> 1 from jsonb_array_elements(e -> 'data' -> 'dice_by_level') y
                      where (y ->> 0)::int <= (e ->> 'class_level')::int order by (y ->> 0)::int desc limit 1),
                     e ->> 'value_text', e -> 'data' ->> 'damage_dice');
    dbonus := case when coalesce((e -> 'data' ->> 'add_modifier')::boolean, true) then ab_mod else 0 end;
    attacks := attacks || jsonb_build_object(
      'name', e -> 'data' ->> 'name', 'source_name', (e ->> 'class_name') || ': ' || (e ->> 'feature_name'),
      'character_class_id', e ->> 'character_class_id', 'unlock_id', e ->> 'unlock_id', 'feature_version_id', e ->> 'feature_version_id',
      'ability', ab, 'ability_modifier', ab_mod, 'proficient', coalesce((e -> 'data' ->> 'proficient')::boolean, true),
      'proficiency_bonus', pb,
      'attack_bonus', ab_mod + case when coalesce((e -> 'data' ->> 'proficient')::boolean, true) then pb else 0 end,
      'damage_dice', dice, 'damage_type', e -> 'data' ->> 'damage_type', 'range', e -> 'data' ->> 'range',
      'damage', dice || case when dbonus > 0 then ' + ' || dbonus when dbonus < 0 then ' - ' || abs(dbonus) else '' end,
      'scaling', e -> 'data' -> 'dice_by_level', 'automation', e ->> 'automation', 'notes', e -> 'data' ->> 'notes');
  end loop;

  -- attacks per Attack action (Extra Attack does not stack between classes: the highest counts)
  select jsonb_build_object('value', 1 + coalesce(max((x ->> 'value')::int), 0),
           'sources', coalesce(jsonb_agg(jsonb_build_object('source_name', (x ->> 'class_name') || ': ' || (x ->> 'feature_name'),
                                                            'extra', (x ->> 'value')::int)), '[]'))
  into extra from jsonb_array_elements(eff) x where (x ->> 'active')::boolean and x ->> 'effect_type' = 'extra_attack';
  select jsonb_build_object('value', least(20, coalesce(min((x ->> 'value')::int), 20)),
           'sources', coalesce(jsonb_agg(jsonb_build_object('source_name', (x ->> 'class_name') || ': ' || (x ->> 'feature_name'),
                                                            'value', (x ->> 'value')::int)), '[]'))
  into crit from jsonb_array_elements(eff) x where (x ->> 'active')::boolean and x ->> 'effect_type' = 'critical_range';

  -- attack riders: extra damage the player adds when the conditions are met (never added to an attack automatically)
  select coalesce(jsonb_agg(jsonb_build_object('name', x -> 'data' ->> 'name',
           'dice', coalesce(x ->> 'value_text', x -> 'data' ->> 'dice'), 'dice_by_slot', x -> 'data' -> 'dice_by_slot',
           'uses_slot', coalesce((x -> 'data' ->> 'uses_slot')::boolean, false), 'slot_pool', coalesce(x -> 'data' ->> 'slot_pool', 'standard'),
           'once_per_turn', coalesce((x -> 'data' ->> 'once_per_turn')::boolean, false), 'condition', x -> 'data' ->> 'condition',
           'damage_type', x -> 'data' ->> 'damage_type', 'resource', x -> 'data' ->> 'resource',
           'source_name', (x ->> 'class_name') || ': ' || (x ->> 'feature_name'), 'unlock_id', x ->> 'unlock_id',
           'automation', x ->> 'automation') order by x ->> 'class_name', x -> 'data' ->> 'name'), '[]')
  into riders from jsonb_array_elements(eff) x
  where (x ->> 'feature_active')::boolean and x ->> 'effect_type' = 'attack_rider' and (x ->> 'class_level')::int >= (x ->> 'min_level')::int;

  -- advantage on saves / checks: unconditional ones mark the save or the skills of the ability; situational ones are listed
  for e in select x from jsonb_array_elements(eff) x
           where (x ->> 'feature_active')::boolean and x ->> 'effect_type' in ('save_advantage', 'check_advantage')
             and (x ->> 'class_level')::int >= (x ->> 'min_level')::int loop
    if e -> 'data' ->> 'condition' is not null or e ->> 'automation' = 'informational' or not (e ->> 'active')::boolean then
      adv := adv || jsonb_build_object('kind', case when e ->> 'effect_type' = 'save_advantage' then 'save' else 'check' end,
                                       'ability', e ->> 'target', 'condition', e -> 'data' ->> 'condition',
                                       'source_name', (e ->> 'class_name') || ': ' || (e ->> 'feature_name'));
    elsif e ->> 'effect_type' = 'save_advantage' then
      for k in select a from jsonb_array_elements_text('["str","dex","con","int","wis","cha"]') a
               where e ->> 'target' is null or a = e ->> 'target' loop
        saves := saves || jsonb_build_object(k, coalesce(saves -> k, '{}'::jsonb) || jsonb_build_object('advantage', true,
          'advantage_sources', coalesce(saves -> k -> 'advantage_sources', '[]') || to_jsonb((e ->> 'class_name') || ': ' || (e ->> 'feature_name'))));
      end loop;
    else
      for k in select s.id from public.skills s where e ->> 'target' is null or s.ability = e ->> 'target' loop
        skills := skills || jsonb_build_object(k, coalesce(skills -> k, '{"advantage": false, "disadvantage": false, "sources": []}'::jsonb)
          || jsonb_build_object('advantage', true, 'class_advantage_sources',
               coalesce(skills -> k -> 'class_advantage_sources', '[]') || to_jsonb((e ->> 'class_name') || ': ' || (e ->> 'feature_name'))));
      end loop;
    end if;
  end loop;

  -- senses from class features join the lineage senses (the longest range counts)
  senses := coalesce(d -> 'senses', '{}');
  for e in select x from jsonb_array_elements(eff) x where (x ->> 'active')::boolean and x ->> 'effect_type' = 'sense' loop
    if coalesce((senses -> (e ->> 'target') ->> 'value')::int, 0) < (e ->> 'value')::int then
      senses := senses || jsonb_build_object(e ->> 'target', jsonb_build_object('value', (e ->> 'value')::int,
                  'source_name', (e ->> 'class_name') || ': ' || (e ->> 'feature_name')));
    end if;
  end loop;

  -- ability maximums raised by class features (scores above 20 are allowed up to this value)
  select coalesce(jsonb_object_agg(t, m), '{}') into maxes from (
    select x ->> 'target' as t, max((x ->> 'value')::int) as m from jsonb_array_elements(eff) x
    where (x ->> 'active')::boolean and x ->> 'effect_type' = 'ability_max' group by 1) s;

  -- initiative
  init_parts := coalesce(d -> 'initiative' -> 'sources', '[]');
  init_total := coalesce((d -> 'initiative' ->> 'bonus')::int, 0);
  if half is not null and (half ->> 'includes_initiative')::boolean and half -> 'abilities' ? 'dex' then
    init_total := init_total + (half ->> 'value')::int;
    init_parts := init_parts || to_jsonb((half ->> 'source_name') || ' (half proficiency)');
  end if;
  for e in select x from jsonb_array_elements(eff) x where (x ->> 'active')::boolean and x ->> 'effect_type' = 'initiative_bonus' loop
    init_total := init_total + case when e ->> 'value_text' = 'pb' then pb else (e ->> 'value')::int end;
    init_parts := init_parts || to_jsonb((e ->> 'class_name') || ': ' || (e ->> 'feature_name'));
  end loop;

  -- unarmored AC formulas (base + ability modifiers) compete with the plain unarmored formula only
  ac := d -> 'armor_class';
  if ac ->> 'base_formula' = 'unarmored' then
    best_val := null;
    for e in select x from jsonb_array_elements(eff) x where (x ->> 'active')::boolean and x ->> 'effect_type' = 'ac_formula' loop
      base_now := (e ->> 'value')::int + (select coalesce(sum((mods ->> a)::int), 0) from jsonb_array_elements_text(e -> 'data' -> 'abilities') a);
      if best_val is null or base_now > best_val then best_val := base_now; cand := e; end if;
    end loop;
    if cand is not null and best_val > 10 + (mods ->> 'dex')::int then
      f_parts := jsonb_build_array(jsonb_build_object('source_type', 'class', 'source_id', cand ->> 'unlock_id',
                   'source_name', (cand ->> 'class_name') || ': ' || (cand ->> 'feature_name'), 'effect', 'base_ac', 'value', (cand ->> 'value')::int))
        || (select jsonb_agg(jsonb_build_object('source_type', 'ability', 'source_id', a, 'source_name', upper(a), 'effect', 'ability_modifier',
                                                'value', (mods ->> a)::int, 'modifier', (mods ->> a)::int, 'mode', 'full', 'applied', true))
            from jsonb_array_elements_text(cand -> 'data' -> 'abilities') a)
        || coalesce((select jsonb_agg(p) from jsonb_array_elements(ac -> 'breakdown') p
                     where not (p ->> 'effect' = 'base_ac' and p ->> 'source_id' = 'unarmored')
                       and not (p ->> 'source_type' = 'ability' and p ->> 'source_id' = 'dex')), '[]');
      base_now := (select sum((p ->> 'value')::int) from jsonb_array_elements(f_parts) p);
      ac := ac || jsonb_build_object('base_formula', 'class_feature', 'breakdown', f_parts, 'calculated', base_now,
        'value', coalesce((ac ->> 'override')::int, base_now),
        'alternatives', (ac -> 'alternatives') || jsonb_build_array(jsonb_build_object('formula', 'unarmored',
           'value', 10 + (mods ->> 'dex')::int, 'used', false, 'reason', 'class_formula_better')));
    end if;
  end if;

  select coalesce(jsonb_agg(jsonb_build_object('effect_type', x ->> 'effect_type', 'target', x ->> 'target', 'value', x -> 'value',
           'value_text', x ->> 'value_text', 'source_name', (x ->> 'class_name') || ': ' || (x ->> 'feature_name'),
           'active', (x ->> 'active')::boolean, 'inactive_reason', x ->> 'inactive_reason', 'automation', x ->> 'automation')), '[]')
  into applied from jsonb_array_elements(eff) x;

  return d || jsonb_build_object(
    'skills', skills, 'saving_throws', saves, 'proficiencies', coalesce(d -> 'proficiencies', '[]') || profs,
    'languages', langs, 'equipped_weapon_attacks', weapons, 'feature_attacks', attacks,
    'attacks_per_action', extra, 'critical_range', crit, 'armor_class', ac, 'attack_riders', riders,
    'check_half_proficiency', half, 'situational_advantages', adv, 'senses', senses, 'tool_expertise', tool_exp,
    'ability_maximums', maxes, 'condition_immunity_sources', cimm,
    'active_states', (select coalesce(jsonb_agg(a.state_key order by a.state_key), '[]') from public.character_active_states a
                      where a.character_id = p_character),
    -- feature save DCs (Ki, Stunning Strike): 8 + proficiency bonus + the ability modifier
    'feature_dcs', (select coalesce(jsonb_agg(jsonb_build_object('name', x -> 'data' ->> 'name', 'ability', x ->> 'target',
                      'dc', 8 + pb + coalesce((mods ->> (x ->> 'target'))::int, 0),
                      'source_name', (x ->> 'class_name') || ': ' || (x ->> 'feature_name')) order by x -> 'data' ->> 'name'), '[]')
                    from jsonb_array_elements(eff) x where (x ->> 'active')::boolean and x ->> 'effect_type' = 'save_dc'),
    -- condition_immunities stays a list of names (lineage + class); the class sources are in condition_immunity_sources
    'condition_immunities', (select coalesce(jsonb_agg(distinct v order by v), '[]') from (
        select jsonb_array_elements_text(coalesce(d -> 'condition_immunities', '[]')) v
        union select ci ->> 'condition' from jsonb_array_elements(cimm) ci) u),
    'initiative', jsonb_build_object('bonus', init_total, 'sources', init_parts),
    'immunities', coalesce(d -> 'immunities', '[]') || coalesce((select jsonb_agg(distinct coalesce(x ->> 'target', x ->> 'value_text'))
                    from jsonb_array_elements(eff) x where (x ->> 'active')::boolean and x ->> 'effect_type' = 'immunity'), '[]'),
    'class_features', jsonb_build_object('applied', applied, 'warnings', info,
      'resolution_order', jsonb_build_array('stored base data', 'class levels and proficiency bonus', 'lineage', 'items',
        'class feature effects', 'manual overrides')));
end;
$function$;

commit;
