-- =============================================================================
-- Rollback of 20261017000500_hybrid_caster_extensions.sql ONLY: restores the previous definitions (trigger, recover_spell_slots and get_character_spellbook from
-- 20261017000300, derived wrapper from 20261017000100, set_character_spell from 20261015001600, _character_spell_grants and
-- set_character_feature_choice from 20261015001800), drops _expanded_spell and the three effect types.
-- Refuses while catalog effects use them (run rollback_class_catalog.sql first). No character data is touched.
-- =============================================================================
begin;

do $$
begin
  if exists (select 1 from public.class_feature_effects where effect_type in ('save_bonus_ability', 'condition_immunity', 'spell_list_addition')) then
    raise exception 'Official class content still uses the 20261017000500 extensions; run rollback_class_catalog.sql first';
  end if;
end $$;

alter table public.class_feature_effects drop constraint class_feature_effects_effect_type_check;
alter table public.class_feature_effects add constraint class_feature_effects_effect_type_check check (effect_type in (
  'proficiency', 'expertise', 'ability_bonus', 'ac_bonus', 'ac_formula', 'attack_bonus', 'damage_bonus',
  'save_bonus', 'initiative_bonus', 'speed_bonus', 'resistance', 'immunity', 'skill_advantage',
  'skill_disadvantage', 'carrying_capacity_bonus', 'spell', 'attack', 'extra_attack', 'critical_range',
  'attunement_limit', 'ritual_casting', 'spellcasting_source', 'resource_modifier', 'informational',
  'skill_half_proficiency', 'sense', 'attack_rider', 'save_advantage', 'check_advantage', 'ability_max'));

create or replace function public.class_feature_definitions_before_write()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
declare abilities constant text[] := array['str', 'dex', 'con', 'int', 'wis', 'cha']; v_kind text;
begin
  if tg_table_name = 'class_feature_resources' then
    if new.max_formula is not null then
      perform public._resource_max(new.max_formula, '{"total_level": 1, "class_level": 1, "proficiency_bonus": 2, "mods": {}}');
    end if;
    if new.short_rest_recovery is not null then
      perform public._resource_max(new.short_rest_recovery, '{"total_level": 1, "class_level": 1, "proficiency_bonus": 2, "mods": {}}');
    end if;
    if new.max_formula is null and new.automation = 'automated' then
      raise exception 'Resource %: without a formula it cannot be automated', new.id using errcode = '22023';
    end if;
    if new.config ? 'slot_recovery' then
      perform public._resource_max(new.config -> 'slot_recovery' -> 'budget', '{"total_level": 1, "class_level": 1, "proficiency_bonus": 2, "mods": {}}');
      if new.config -> 'slot_recovery' ? 'also_expend' and not exists (select 1 from public.class_feature_resources r2
                                                                       where r2.id = new.config -> 'slot_recovery' ->> 'also_expend') then
        raise exception 'Resource %: slot_recovery.also_expend names an unknown resource', new.id using errcode = '22023'; end if;
      if coalesce((new.config -> 'slot_recovery' ->> 'max_slot_level')::int, 0) not between 1 and 9 then
        raise exception 'Resource %: slot_recovery.max_slot_level must be 1-9', new.id using errcode = '22023'; end if;
    end if;
    if new.config ? 'conversion' and (jsonb_typeof(new.config -> 'conversion' -> 'create_costs') <> 'object'
                                      or coalesce((new.config -> 'conversion' ->> 'max_created_level')::int, 0) not between 1 and 9) then
      raise exception 'Resource %: conversion needs create_costs and max_created_level', new.id using errcode = '22023';
    end if;
    if new.recharge_by_level is not null and exists (select 1 from jsonb_array_elements(new.recharge_by_level) e
        where e ->> 1 not in ('short_rest', 'long_rest', 'short_or_long_rest', 'dawn', 'manual', 'none') or (e ->> 0)::int not between 1 and 20) then
      raise exception 'Resource %: recharge_by_level needs [[level, recharge], ...]', new.id using errcode = '22023';
    end if;
    return new;
  end if;
  -- class_feature_effects
  if new.choice_id is not null then
    select kind into v_kind from public.class_feature_choices where id = new.choice_id and feature_version_id = new.feature_version_id;
    if v_kind is null then raise exception 'Effect %/%: the choice belongs to another feature', new.feature_version_id, new.seq
      using errcode = '22023'; end if;
  end if;
  case new.effect_type
    when 'proficiency' then
      if new.target not in ('skill', 'save', 'armor', 'weapon', 'tool', 'group', 'language') then
        raise exception 'proficiency target must be skill, save, armor, weapon, tool, group or language' using errcode = '22023';
      end if;
      if new.choice_id is null and new.value_text is null then
        raise exception 'proficiency needs a value or a choice' using errcode = '22023'; end if;
      if new.choice_id is null and new.target = 'skill' and not exists (select 1 from public.skills where id = new.value_text) then
        raise exception 'Unknown skill "%"', new.value_text using errcode = '22023'; end if;
      if new.choice_id is null and new.target = 'save' and not new.value_text = any (abilities) then
        raise exception 'Unknown saving throw "%"', new.value_text using errcode = '22023'; end if;
      if new.choice_id is null and new.target = 'group' and not exists (select 1 from public.proficiency_groups where id = new.value_text) then
        raise exception 'Unknown proficiency group "%"', new.value_text using errcode = '22023'; end if;
      if new.choice_id is null and new.target in ('armor', 'weapon', 'tool')
         and not exists (select 1 from public.items where id = new.value_text and owner_id is null) then
        raise exception 'Unknown % "%"', new.target, new.value_text using errcode = '22023'; end if;
    when 'expertise' then
      if new.choice_id is null or v_kind <> 'expertise' then
        raise exception 'expertise needs an expertise choice' using errcode = '22023'; end if;
    when 'skill_half_proficiency' then
      if coalesce(new.data ->> 'rounding', 'down') not in ('up', 'down')
         or (new.data ? 'abilities' and (jsonb_typeof(new.data -> 'abilities') <> 'array' or exists (
               select 1 from jsonb_array_elements_text(new.data -> 'abilities') a where not a = any (abilities)))) then
        raise exception 'skill_half_proficiency: data.rounding up|down, data.abilities a list of abilities' using errcode = '22023'; end if;
    when 'sense' then
      if new.target not in ('darkvision', 'blindsight', 'tremorsense', 'truesight', 'blindsense') or coalesce(new.value, 0) <= 0 then
        raise exception 'sense needs a target (darkvision, blindsight, tremorsense, truesight, blindsense) and a range' using errcode = '22023'; end if;
    when 'attack_rider' then
      if coalesce(new.data ->> 'name', '') = '' or not (new.data ? 'dice' or new.data ? 'scale' or new.data ? 'dice_by_slot') then
        raise exception 'attack_rider needs data.name and data.dice, data.scale or data.dice_by_slot' using errcode = '22023'; end if;
    when 'save_advantage', 'check_advantage' then
      if new.target is not null and not new.target = any (abilities) then
        raise exception '% target must be an ability or empty (all)', new.effect_type using errcode = '22023'; end if;
    when 'ability_max' then
      if not new.target = any (abilities) or new.value is null or new.value not between 20 and 30 then
        raise exception 'ability_max needs an ability and a maximum 20-30' using errcode = '22023'; end if;
    when 'ability_bonus' then
      if not (v_kind = 'asi' or (new.target = any (abilities) and new.value between 1 and 4)) then
        raise exception 'ability_bonus needs an ability and a value, or an asi choice' using errcode = '22023'; end if;
    when 'ac_bonus', 'initiative_bonus', 'speed_bonus', 'carrying_capacity_bonus', 'extra_attack' then
      if new.value is null and not new.data ? 'scale' then raise exception '% needs a value', new.effect_type using errcode = '22023'; end if;
    when 'attack_bonus', 'damage_bonus' then
      if new.value is null then raise exception '% needs a value', new.effect_type using errcode = '22023'; end if;
      if coalesce(new.conditions ->> 'weapon', 'any') not in ('any', 'melee', 'ranged', 'one_handed_melee_only', 'thrown') then
        raise exception 'Unknown weapon condition "%"', new.conditions ->> 'weapon' using errcode = '22023'; end if;
    when 'save_bonus' then
      if new.value is null or (new.target is not null and not new.target = any (abilities)) then
        raise exception 'save_bonus needs a value and an optional ability' using errcode = '22023'; end if;
    when 'critical_range' then
      if new.value is null or new.value not between 15 and 20 then
        raise exception 'critical_range needs a value 15-20' using errcode = '22023'; end if;
    when 'resistance', 'immunity' then
      if not exists (select 1 from public.damage_types where id = coalesce(new.target, new.value_text)) then
        raise exception 'Unknown damage type "%"', coalesce(new.target, new.value_text) using errcode = '22023'; end if;
    when 'skill_advantage', 'skill_disadvantage' then
      if not exists (select 1 from public.skills where id = new.target) then
        raise exception 'Unknown skill "%"', new.target using errcode = '22023'; end if;
    when 'spell' then
      if new.spell_version_id is null and (new.choice_id is null or v_kind <> 'spell') then
        raise exception 'spell needs a spell version or a spell choice' using errcode = '22023'; end if;
    when 'attack' then
      if coalesce(new.data ->> 'name', '') = '' or not (new.data ? 'damage_dice' or new.data ? 'dice_by_level')
         or coalesce(new.data ->> 'ability', 'str') not in ('str', 'dex', 'con', 'int', 'wis', 'cha', 'finesse', 'spell', 'none')
         or (new.data ? 'damage_type' and not exists (select 1 from public.damage_types where id = new.data ->> 'damage_type')) then
        raise exception 'attack needs data.name, data.damage_dice or data.dice_by_level, a known ability and damage type'
          using errcode = '22023'; end if;
    when 'ac_formula' then
      if new.value is null or jsonb_typeof(new.data -> 'abilities') <> 'array' then
        raise exception 'ac_formula needs a base value and data.abilities' using errcode = '22023'; end if;
    else null;
  end case;
  if new.data ? 'scale' and not exists (select 1 from public.class_feature_scaling s
                                         where s.feature_version_id = new.feature_version_id and s.key = new.data ->> 'scale') then
    raise exception 'Effect %/%: unknown scaling key "%"', new.feature_version_id, new.seq, new.data ->> 'scale' using errcode = '22023';
  end if;
  for v_kind in select jsonb_object_keys(new.conditions) loop
    if not v_kind = any (array['armor', 'shield', 'weapon']) then
      raise exception 'Unknown effect condition "%"', v_kind using errcode = '22023';
    end if;
  end loop;
  if new.conditions ? 'armor' and new.conditions ->> 'armor' not in ('worn', 'none', 'not_heavy') then
    raise exception 'armor condition must be worn, none or not_heavy' using errcode = '22023'; end if;
  if new.conditions ? 'shield' and new.conditions ->> 'shield' not in ('worn', 'none') then
    raise exception 'shield condition must be worn or none' using errcode = '22023'; end if;
  return new;
end;
$$;

create or replace function public.get_character_derived_stats(p_character uuid)
returns jsonb
language plpgsql stable
set search_path = public, pg_temp
as $$
declare d jsonb; eff jsonb; c public.characters; pb int; mods jsonb; k text; e jsonb; skills jsonb; saves jsonb; profs jsonb := '[]';
  weapons jsonb := '[]'; w jsonb; atk int; dmg int; parts_a jsonb; parts_d jsonb; one_weapon boolean; n_weapons int; attacks jsonb := '[]';
  ab text; ab_mod int; dice text; dbonus int; ac jsonb; cand jsonb; best_val int; base_now int; f_parts jsonb; extra jsonb; crit jsonb;
  init_parts jsonb; init_total int; langs jsonb; man int; applied jsonb := '[]'; info jsonb := '[]'; cond text;
  half jsonb; half_val int; senses jsonb; riders jsonb := '[]'; adv jsonb := '[]'; tool_exp jsonb := '[]'; notes jsonb;
  maxes jsonb := '{}'; unarmed boolean;
begin
  d := public._derived_stats_levels(p_character);                  -- RLS: owner, campaign DM, admin
  select coalesce(jsonb_agg(to_jsonb(x) order by x.class_id, x.unlock_id, x.seq, x.pick), '[]') into eff
  from public._character_class_effects(p_character) x where x.feature_active;
  if eff = '[]'::jsonb then
    return d || jsonb_build_object('class_features', jsonb_build_object('applied', '[]'::jsonb, 'informational', '[]'::jsonb),
                                   'attacks_per_action', jsonb_build_object('value', 1, 'sources', '[]'::jsonb),
                                   'critical_range', jsonb_build_object('value', 20, 'sources', '[]'::jsonb),
                                   'feature_attacks', '[]'::jsonb, 'attack_riders', '[]'::jsonb, 'check_half_proficiency', null,
                                   'situational_advantages', '[]'::jsonb, 'tool_expertise', '[]'::jsonb, 'ability_maximums', '{}'::jsonb);
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
    if man >= 1 or coalesce((skills -> k ->> 'lineage_proficient')::boolean, false) or coalesce((skills -> k ->> 'class_proficient')::boolean, false) then
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

  -- armor / weapon / tool / group proficiencies listed with their class source (matching is done by _proficiency_match)
  select coalesce(jsonb_agg(jsonb_build_object('id', null, 'proficiency_type',
           case x ->> 'target' when 'group' then g.proficiency_type when 'armor' then
                case when it.category_id = 'shield' then 'shield' else 'armor' end else x ->> 'target' end,
           'group_id', case when x ->> 'target' = 'group' then x ->> 'value_text' end,
           'item_id', case when x ->> 'target' in ('armor', 'weapon', 'tool') then x ->> 'value_text' end,
           'name', coalesce(g.name, it.name, x ->> 'value_text'), 'source_type', 'class',
           'notes', (x ->> 'class_name') || ': ' || (x ->> 'feature_name'), 'character_class_id', x ->> 'character_class_id')
           order by x ->> 'target', coalesce(g.name, it.name)), '[]')
  into profs
  from jsonb_array_elements(eff) x
  left join public.proficiency_groups g on x ->> 'target' = 'group' and g.id = x ->> 'value_text'
  left join public.items it on x ->> 'target' in ('weapon', 'armor', 'tool') and it.id = x ->> 'value_text'
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
    'ability_maximums', maxes,
    'initiative', jsonb_build_object('bonus', init_total, 'sources', init_parts),
    'immunities', coalesce(d -> 'immunities', '[]') || coalesce((select jsonb_agg(distinct coalesce(x ->> 'target', x ->> 'value_text'))
                    from jsonb_array_elements(eff) x where (x ->> 'active')::boolean and x ->> 'effect_type' = 'immunity'), '[]'),
    'class_features', jsonb_build_object('applied', applied, 'warnings', info,
      'resolution_order', jsonb_build_array('stored base data', 'class levels and proficiency bonus', 'lineage', 'items',
        'class feature effects', 'manual overrides')));
end;
$$;

create or replace function public.set_character_spell(p_character uuid, p_source uuid, p_spell_version text, p_known boolean default true,
                                           p_prepared boolean default false, p_always_prepared boolean default false,
                                           p_casting_ability text default null, p_ritual_allowed boolean default null,
                                           p_notes text default null)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare s public.character_spellcasting_sources; v public.spell_versions; r public.character_spells;
begin
  if auth.uid() is null or not public.can_access_character(p_character) then
    raise exception 'Character not found' using errcode = '42501';
  end if;
  select * into s from public.character_spellcasting_sources where id = p_source and character_id = p_character;
  if not found then raise exception 'Spellcasting source not found' using errcode = '42501'; end if;
  select * into v from public.spell_versions where id = p_spell_version;
  if not found or not public.can_view_spell(v.spell_id) then
    raise exception 'Unknown spell "%"', p_spell_version using errcode = '22023';
  end if;
  if not (coalesce(p_known, false) or coalesce(p_prepared, false) or coalesce(p_always_prepared, false)) then
    raise exception 'A spell must be known, prepared or always prepared' using errcode = '22023';
  end if;
  if coalesce(p_always_prepared, false) and not s.always_prepared_allowed then
    raise exception '% cannot mark spells as always prepared', s.label using errcode = '22023';
  end if;
  if s.enforce_spell_list and s.spell_list_id is not null and not exists (
       select 1 from public.class_spell_list_entries e where e.list_id = s.spell_list_id and e.spell_version_id = v.id) then
    raise exception '% is not on the spell list of %', v.name, s.label using errcode = '22023';
  end if;
  if p_casting_ability is not null and not p_casting_ability = any (s.allowed_abilities) then
    raise exception 'This source does not let a spell use %', upper(p_casting_ability) using errcode = '22023';
  end if;
  if length(p_notes) > 500 then raise exception 'Notes are too long' using errcode = '22023'; end if;
  insert into public.character_spells (character_id, source_id, spell_version_id, known, prepared, always_prepared,
                                       counts_against_known_limit, counts_against_prepared_limit, uses_spell_slot, ritual_allowed,
                                       casting_ability, notes)
  values (p_character, s.id, v.id, coalesce(p_known, false), coalesce(p_prepared, false), coalesce(p_always_prepared, false),
          not coalesce(p_always_prepared, false), not coalesce(p_always_prepared, false), s.uses_spell_slots and v.level > 0,
          coalesce(p_ritual_allowed, false), p_casting_ability, nullif(btrim(p_notes), ''))
  on conflict (source_id, spell_version_id) do update set
    known = excluded.known, prepared = excluded.prepared, always_prepared = excluded.always_prepared,
    counts_against_known_limit = excluded.counts_against_known_limit, counts_against_prepared_limit = excluded.counts_against_prepared_limit,
    ritual_allowed = excluded.ritual_allowed, casting_ability = excluded.casting_ability, notes = excluded.notes
  returning * into r;
  return to_jsonb(r);
end;
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
  where e.effect_type = 'spell' and te.spell_version_id is not null
  union all
  -- class feature spell grants (20261015001800): one source per class row; gone when the feature is inactive
  select f.spell_version_id, 'feature:' || f.character_class_id, jsonb_build_object(
           'source_key', 'feature:' || f.character_class_id, 'source_type', 'class_feature',
           'source_label', f.class_name || ': ' || f.feature_name, 'character_class_id', f.character_class_id,
           'unlock_id', f.unlock_id, 'feature_version_id', f.feature_version_id,
           'known', true, 'prepared', coalesce((f.data ->> 'always_prepared')::boolean, false),
           'always_prepared', coalesce((f.data ->> 'always_prepared')::boolean, false), 'innate', false,
           'counts_against_known_limit', coalesce((f.data ->> 'counts_against_known_limit')::boolean, false),
           'counts_against_prepared_limit', coalesce((f.data ->> 'counts_against_prepared_limit')::boolean, false),
           'uses_spell_slot', coalesce((f.data ->> 'uses_spell_slots')::boolean, true) and v.level > 0,
           'ritual_allowed', coalesce((f.data ->> 'ritual')::boolean, false) and v.is_ritual,
           'notes', f.data ->> 'notes', 'unlocked', f.active, 'min_level', f.min_level,
           'uses', f.data ->> 'uses', 'recharge', f.data ->> 'recharge', 'cast_level', f.data -> 'cast_level',
           'casting_ability', coalesce(f.data ->> 'ability', f.spellcasting_ability),
           'ability_needed', coalesce(f.data ->> 'ability', f.spellcasting_ability) is null,
           'stats', public._spell_stat(coalesce(f.data ->> 'ability', f.spellcasting_ability), mods, pb))
  from public._character_class_effects(p_character) f
  join public.spell_versions v on v.id = f.spell_version_id
  where f.feature_active and f.effect_type = 'spell' and f.spell_version_id is not null and f.automation <> 'informational'
    and f.inactive_reason is distinct from 'primary_class_only' and f.inactive_reason is distinct from 'multiclass_only';
$$;

create or replace function public.get_character_spellbook(p_character uuid)
returns jsonb
language plpgsql stable
set search_path = public, pg_temp
as $$
declare b jsonb; mods jsonb; pb int; fsrc jsonb;
begin
  b := public._spellbook_core(p_character);                          -- RLS: owner, campaign DM, admin
  -- spellbook sources (Wizard): what is in the book, how it got there, free spells expected by the class level
  b := b || jsonb_build_object('sources', (select coalesce(jsonb_agg(case when s ->> 'preparation_mode' = 'spellbook' and s ->> 'id' is not null
      then s || jsonb_build_object('spellbook', (select jsonb_build_object(
             'spells', count(*) filter (where v.level > 0 and g.known),
             'cantrips', count(*) filter (where v.level = 0),
             'free_expected', (select 6 + 2 * (cc.level - 1) from public.character_spellcasting_sources s2
                               join public.character_classes cc on cc.id = s2.character_class_id where s2.id = (s ->> 'id')::uuid),
             'by_acquisition', (select coalesce(jsonb_object_agg(a, n), '{}') from (
                                  select coalesce(g2.acquisition, 'unrecorded') a, count(*) n from public.character_spells g2
                                  join public.spell_versions v2 on v2.id = g2.spell_version_id
                                  where g2.source_id = (s ->> 'id')::uuid and v2.level > 0 and g2.known group by 1) x),
             'prepared', count(*) filter (where v.level > 0 and g.prepared))
           from public.character_spells g join public.spell_versions v on v.id = g.spell_version_id
           where g.source_id = (s ->> 'id')::uuid))
      else s end), '[]') from jsonb_array_elements(b -> 'sources') s));
  if not exists (select 1 from public.class_feature_effects e join public.class_feature_unlocks u on u.feature_version_id = e.feature_version_id
                 join public.character_classes cc on cc.character_id = p_character
                   and (u.class_version_id = cc.class_version_id or u.subclass_version_id = cc.subclass_version_id)
                 where e.effect_type = 'spell') then
    return b;
  end if;
  pb := (b ->> 'proficiency_bonus')::int;
  mods := public._character_mods(p_character);
  select coalesce(jsonb_agg(jsonb_build_object(
           'key', x.source_key, 'id', null, 'source_type', 'class_feature', 'label', x.label, 'character_class_id', x.ccid,
           'casting_ability', x.ability, 'preparation_mode', 'feature', 'uses_spell_slots', x.slots,
           'stats', public._spell_stat(x.ability, mods, pb),
           'counts', jsonb_build_object('known', x.n, 'prepared', 0, 'always_prepared', x.ap, 'total', x.n)) order by x.label), '[]')
  into fsrc
  from (select g.source_key, min(g.grant_info ->> 'character_class_id') as ccid,
               min(split_part(g.grant_info ->> 'source_label', ':', 1)) || ' features' as label,
               min(g.grant_info ->> 'casting_ability') as ability, bool_or((g.grant_info ->> 'uses_spell_slot')::boolean) as slots,
               count(*) as n, count(*) filter (where (g.grant_info ->> 'always_prepared')::boolean) as ap
        from public._character_spell_grants(p_character, mods, pb, null) g
        where g.source_key like 'feature:%' group by g.source_key) x;
  return b || jsonb_build_object('sources', (b -> 'sources') || fsrc);
end;
$$;

create or replace function public.set_character_feature_choice(p_character uuid, p_character_class uuid, p_unlock text, p_choice text,
                                                    p_values text[] default '{}', p_manual_status text default null,
                                                    p_allow_partial boolean default false)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare cc public.character_classes; ch record; cf public.class_feature_choices; err text; n int; vals text[]; cid uuid;
  pre jsonb; full_state jsonb; opt record;
begin
  cc := public._cf_class_row(p_character, p_character_class);
  select * into ch from public._character_feature_choice_rows(p_character) x
  where x.character_class_id = p_character_class and x.unlock_id = p_unlock and x.choice_id = p_choice;
  if not found then raise exception 'This choice does not belong to this class' using errcode = '22023'; end if;
  select * into cf from public.class_feature_choices where id = p_choice;
  if p_manual_status is not null and p_manual_status not in ('applied_manually', 'confirmed') then
    raise exception 'Unknown manual status "%"', p_manual_status using errcode = '22023';
  end if;
  if p_manual_status = 'applied_manually' and cf.kind <> 'asi' then
    raise exception 'Only an ability score improvement can be marked as already applied' using errcode = '22023';
  end if;
  vals := coalesce((select array_agg(btrim(v)) from unnest(p_values) v where btrim(v) <> ''), '{}');
  n := cardinality(vals);
  if n > 0 or p_manual_status is not null then
    if not ch.unlock_active then
      raise exception '% is not active for this character (%)', ch.feature_name, ch.unlock_status using errcode = '22023';
    end if;
    if not ch.applicable then
      raise exception '% applies only to the % class', ch.label, case when ch.applies_to = 'primary_class' then 'primary' else 'non-primary' end
        using errcode = '22023';
    end if;
    if not ch.enabled then raise exception '% depends on another choice; make that choice first', ch.label using errcode = '22023'; end if;
    if ch.class_level < ch.choice_level then
      raise exception '% opens at % level %', ch.label, ch.class_name, ch.choice_level using errcode = '22023';
    end if;
    err := public._cf_choice_error(p_character, p_character_class, p_unlock, cf, vals, ch.max_picks, true);
    if err is not null then raise exception '%: %', ch.label, err using errcode = '22023'; end if;
    if n < ch.min_picks and not coalesce(p_allow_partial, false) and not (cf.kind = 'asi' and p_manual_status = 'applied_manually') then
      raise exception '%: choose at least %', ch.label, ch.min_picks using errcode = '22023';
    end if;
    -- option prerequisites: an evaluable unmet prerequisite blocks; text prerequisites need a confirmation (warning)
    for opt in select o.* from public.class_feature_choice_options o where o.choice_id = p_choice and o.option_id = any (vals) loop
      pre := public._cf_prereq(opt.prerequisites, jsonb_build_object('class_level', cc.level,
               'total_level', (select sum(level) from public.character_classes where character_id = p_character),
               'subclass_version_id', cc.subclass_version_id,
               'chosen', (select coalesce(jsonb_agg(c2.choice_id || ':' || v2.value), '[]') from public.character_feature_choices c2
                          join public.character_feature_choice_values v2 on v2.character_choice_id = c2.id
                          where c2.character_class_id = p_character_class),
               'abilities', (select jsonb_object_agg(k, (d -> 'abilities' -> k ->> 'score')::int)
                             from (select public.get_character_derived_stats(p_character) as d) dd, jsonb_object_keys(dd.d -> 'abilities') k),
               'confirmed', p_manual_status = 'confirmed'));
      if pre ->> 'status' = 'unmet' then
        raise exception '% needs %', opt.label, (select string_agg(i ->> 'label', ', ') from jsonb_array_elements(pre -> 'items') i
                                                 where i ->> 'status' = 'unmet') using errcode = '22023';
      end if;
    end loop;
  end if;

  if n = 0 and p_manual_status is null then
    delete from public.character_feature_choices where character_class_id = p_character_class and unlock_id = p_unlock and choice_id = p_choice;
  else
    insert into public.character_feature_choices (character_id, character_class_id, unlock_id, choice_id, manual_status, created_by)
    values (p_character, p_character_class, p_unlock, p_choice, p_manual_status, auth.uid())
    on conflict (character_class_id, unlock_id, choice_id) do update set manual_status = excluded.manual_status, updated_at = now()
    returning id into cid;
    delete from public.character_feature_choice_values where character_choice_id = cid;
    insert into public.character_feature_choice_values (character_choice_id, pick, value)
    select cid, ord, v from unnest(vals) with ordinality u(v, ord);
  end if;
  return public.get_character_class_features(p_character);
end;
$$;

create or replace function public.recover_spell_slots(p_character uuid, p_resource_key text, p_slot_levels int[], p_reason text default null)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare me jsonb; budget int; maxl int; total int; l int; need record; have int; other text; om jsonb;
begin
  if auth.uid() is null or not public.can_access_character(p_character) then
    raise exception 'Character not found' using errcode = '42501';
  end if;
  perform 1 from public.characters where id = p_character for update;
  select x into me from jsonb_array_elements(public._character_feature_resources(p_character, public._character_mods(p_character))) x
  where x ->> 'key' = p_resource_key;
  if me is null or not (me -> 'config') ? 'slot_recovery' then
    raise exception 'This resource does not recover spell slots' using errcode = '22023';
  end if;
  if not (me ->> 'active')::boolean then raise exception '% is not available', me ->> 'name' using errcode = '22023'; end if;
  if coalesce((me ->> 'remaining')::int, 0) < 1 then raise exception '% is already used', me ->> 'name' using errcode = '22023'; end if;
  if coalesce(cardinality(p_slot_levels), 0) = 0 then raise exception 'Choose at least one expended slot to recover' using errcode = '22023'; end if;
  budget := (me ->> 'slot_recovery_budget')::int;
  maxl := (me -> 'config' -> 'slot_recovery' ->> 'max_slot_level')::int;
  select sum(x) into total from unnest(p_slot_levels) x;
  if exists (select 1 from unnest(p_slot_levels) x where x is null or x < 1 or x > maxl) then
    raise exception '% recovers slots of level 1 to % only', me ->> 'name', maxl using errcode = '22023';
  end if;
  if total > budget then
    raise exception 'The slot levels add up to %; % recovers at most % levels of slots', total, me ->> 'name', budget using errcode = '22023';
  end if;
  if (me -> 'config' -> 'slot_recovery') ? 'max_slots' and cardinality(p_slot_levels) > (me -> 'config' -> 'slot_recovery' ->> 'max_slots')::int then
    raise exception '% recovers % slot(s) at a time', me ->> 'name', me -> 'config' -> 'slot_recovery' ->> 'max_slots' using errcode = '22023';
  end if;
  -- a second resource of the same class row that the recovery also spends (Harness Divine Power: a Channel Divinity use)
  other := me -> 'config' -> 'slot_recovery' ->> 'also_expend';
  if other is not null then
    select x into om from jsonb_array_elements(public._character_feature_resources(p_character, public._character_mods(p_character))) x
    where x ->> 'resource_id' = other and x ->> 'character_class_id' = me ->> 'character_class_id';
    if om is null or not (om ->> 'active')::boolean or coalesce((om ->> 'remaining')::int, 0) < 1 then
      raise exception '% also needs one use of %, and none is left', me ->> 'name', coalesce(om ->> 'name', other) using errcode = '22023';
    end if;
  end if;
  for need in select x as lvl, count(*) as n from unnest(p_slot_levels) x group by x loop
    select coalesce(expended, 0) into have from public.character_spell_slot_state
    where character_id = p_character and pool = 'standard' and slot_level = need.lvl;
    if coalesce(have, 0) < need.n then
      raise exception 'Only % expended level % slot(s) to recover', coalesce(have, 0), need.lvl using errcode = '22023';
    end if;
  end loop;
  perform public._resource_change(p_character, p_resource_key, 'expend', 1, null, null, null,
                                  coalesce(nullif(btrim(p_reason), ''), format('%s: slot levels %s', me ->> 'name', array_to_string(p_slot_levels, ', '))));
  if other is not null then
    perform public._resource_change(p_character, om ->> 'key', 'expend', 1, null, null, null, format('Spent by %s', me ->> 'name'));
  end if;
  foreach l in array p_slot_levels loop
    perform public._slot_change(p_character, 'standard', l, -1, format('%s', me ->> 'name'));
  end loop;
  return jsonb_build_object('resource', (select x from jsonb_array_elements((public.get_character_resources(p_character)) -> 'resources') x
                                         where x ->> 'key' = p_resource_key),
                            'recovered', to_jsonb(p_slot_levels), 'budget', budget, 'slots', public.get_character_spell_slots(p_character));
end;
$$;

drop function if exists public._expanded_spell(uuid, text);

do $$
begin
  if to_regclass('supabase_migrations.schema_migrations') is not null then
    delete from supabase_migrations.schema_migrations where version = '20261017000500';
  end if;
end $$;

commit;
