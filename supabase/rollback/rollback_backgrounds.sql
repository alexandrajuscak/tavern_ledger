-- =============================================================================
-- Rollback of 20261017001200_backgrounds.sql ONLY: restores _derived_stats_core, _proficiency_match, _cf_choice_error,
-- get_character_class_features, get_character_derived_stats (all as before 20261017001200) and get_character_proficiencies
-- (20261017001100); drops the background tables and RPCs. Character backgrounds are dropped; equipment added from a
-- background stays in the inventory (it is ordinary inventory).
-- =============================================================================
begin;

CREATE OR REPLACE FUNCTION public._derived_stats_core(p_character uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  c public.characters;
  pb int;
  effects jsonb;
  abilities jsonb := '{}'; scores jsonb := '{}'; mods jsonb := '{}';
  k text; base_score int; override_score int; bonus int; score int;
  armor record; shield record; w record;
  dex_mod int; dex_part int; formula text; ac_parts jsonb := '[]'; ac_calc int; alternatives jsonb := '[]';
  armor_prof jsonb; shield_prof jsonb; nonprof_armor boolean := false; nonprof_shield boolean := false;
  stealth_sources jsonb := '[]'; str_unmet boolean := false; speed_parts jsonb; speed_val int;
  warnings jsonb := '[]'; weapons jsonb := '[]'; saves jsonb := '{}'; skills jsonb := '{}';
  ab text; ab_mod int; prof jsonb; atk_magic int; dmg_magic int; atk_total int; dmg_bonus int; atk_parts jsonb; dmg_parts jsonb;
  grp text; legacy_eq int; hidden jsonb;
  -- lineage layer (20261015001500)
  lsel public.character_lineages; leff jsonb := '[]'; lin_included boolean := false; lin_bonus int; after_lineage int;
  nat jsonb; nat_val int; armor_val int; worn boolean; use_nat boolean; armor_cat text; heavy_ignore jsonb;
  walk_eff jsonb; movement jsonb; mv text; best jsonb; any_mode jsonb; lin_skills jsonb; nat_weapons jsonb := '[]';
begin
  select * into c from public.characters where id = p_character;                 -- RLS: owner, campaign DM, admin
  if not found then raise exception 'Character not found' using errcode = '42501'; end if;

  pb := (greatest(c.level, 1) - 1) / 4 + 2;
  select coalesce(jsonb_agg(to_jsonb(e) order by e.effect_type, e.source_name, e.seq), '[]'::jsonb) into effects
  from public._character_effects(p_character) e;
  select * into lsel from public.character_lineages where character_id = p_character;
  if found then
    lin_included := lsel.ability_bonuses_included;
    select coalesce(jsonb_agg(to_jsonb(e)), '[]') into leff from public._lineage_effects(p_character) e;
  end if;

  -- abilities: base score, highest active override (never lowers the score), plus additive bonuses (max 30)
  foreach k in array array['str', 'dex', 'con', 'int', 'wis', 'cha'] loop
    base_score := (to_jsonb(c) ->> (case k when 'str' then 'strength' when 'dex' then 'dexterity' when 'con' then 'constitution'
                                          when 'int' then 'intelligence' when 'wis' then 'wisdom' else 'charisma' end))::int;
    select max((e ->> 'value')::int) into override_score from jsonb_array_elements(effects) e
    where (e ->> 'applied')::boolean and e ->> 'effect_type' = 'ability_override' and e ->> 'target' = k;
    bonus := public._effect_total(effects, 'ability_bonus', k);
    lin_bonus := coalesce((select sum((e ->> 'value')::int) from jsonb_array_elements(leff) e
                           where (e ->> 'active')::boolean and e ->> 'effect_type' = 'ability_bonus' and e ->> 'target' = k), 0);
    after_lineage := case when lin_included then base_score else greatest(base_score, least(20, base_score + lin_bonus)) end;
    score := least(30, greatest(after_lineage, coalesce(override_score, 0)) + bonus);
    scores := scores || jsonb_build_object(k, score);
    mods := mods || jsonb_build_object(k, public._ability_mod(score));
    abilities := abilities || jsonb_build_object(k, jsonb_build_object('base', base_score, 'score', score,
      'modifier', public._ability_mod(score), 'override', override_score, 'bonus', bonus,
      'lineage_bonus', lin_bonus, 'lineage_applied', after_lineage - base_score, 'lineage_included', lin_included,
      'lineage_sources', (select coalesce(jsonb_agg(jsonb_build_object('trait_id', e ->> 'trait_id', 'source_name', e ->> 'trait_name',
                                                                        'value', (e ->> 'value')::int)), '[]')
                          from jsonb_array_elements(leff) e
                          where (e ->> 'active')::boolean and e ->> 'effect_type' = 'ability_bonus' and e ->> 'target' = k),
      'sources', (select coalesce(jsonb_agg(e), '[]'::jsonb) from jsonb_array_elements(effects) e
                  where (e ->> 'applied')::boolean and e ->> 'effect_type' in ('ability_override', 'ability_bonus') and e ->> 'target' = k)));
  end loop;
  dex_mod := (mods ->> 'dex')::int;

  -- equipped armor and shield (stats of the item itself, or of its base item)
  select e.inventory_item_id, ii.item_id, coalesce(ii.custom_name, it.name) as name, it.id is not null as visible, it.category_id,
         it.base_item_id, st.base_ac, st.ac_bonus, st.dex_modifier_mode, st.dex_cap, st.strength_requirement, st.stealth_disadvantage, st.is_shield
  into armor
  from public.character_equipment e
  join public.inventory_items ii on ii.id = e.inventory_item_id
  left join public.items it on it.id = ii.item_id
  left join lateral (select s.* from public.armor_stats s where s.item_id in (it.id, it.base_item_id)
                     order by s.item_id = it.id desc limit 1) st on true
  where e.character_id = p_character and e.slot_id = 'armor';

  select e.inventory_item_id, ii.item_id, coalesce(ii.custom_name, it.name) as name, it.id is not null as visible, it.category_id,
         it.base_item_id, st.ac_bonus, st.is_shield
  into shield
  from public.character_equipment e
  join public.inventory_items ii on ii.id = e.inventory_item_id
  left join public.items it on it.id = ii.item_id
  left join lateral (select s.* from public.armor_stats s where s.item_id in (it.id, it.base_item_id)
                     order by s.item_id = it.id desc limit 1) st on true
  where e.character_id = p_character and e.slot_id = 'shield';

  -- ---- Armor Class: exactly one base formula, then additive bonuses --------------------------------------------
  -- candidates: unarmored (10 + DEX), worn armor, lineage natural armor ('best_of' competes with armor; 'replaces_armor'
  -- means worn armor gives no benefit). The best applicable one is used; the others are listed as alternatives.
  worn := armor.inventory_item_id is not null and armor.base_ac is not null and not armor.is_shield;
  if worn then
    armor_val := armor.base_ac + case armor.dex_modifier_mode when 'full' then dex_mod when 'capped' then least(dex_mod, armor.dex_cap) else 0 end;
  end if;
  select e into nat from jsonb_array_elements(leff) e
  where (e ->> 'active')::boolean and e ->> 'effect_type' = 'natural_armor'
  order by (e ->> 'value')::int + case when e -> 'data' ->> 'dex' = 'full' then dex_mod else 0 end desc limit 1;
  nat_val := (nat ->> 'value')::int + case when nat -> 'data' ->> 'dex' = 'full' then dex_mod else 0 end;
  use_nat := nat is not null and ((not worn and nat_val >= 10 + dex_mod)
                                  or (worn and nat -> 'data' ->> 'mode' = 'replaces_armor')
                                  or (worn and nat -> 'data' ->> 'mode' = 'best_of' and nat_val > armor_val));
  if use_nat then
    formula := 'natural_armor';
    ac_parts := ac_parts || jsonb_build_object('source_type', 'lineage', 'source_id', nat ->> 'trait_id', 'source_name', nat ->> 'trait_name',
                  'effect', 'base_ac', 'value', (nat ->> 'value')::int);
    ac_parts := ac_parts || jsonb_build_object('source_type', 'ability', 'source_id', 'dex', 'source_name', 'Dexterity',
                  'effect', 'ability_modifier', 'value', case when nat -> 'data' ->> 'dex' = 'full' then dex_mod else 0 end,
                  'modifier', dex_mod, 'mode', case when nat -> 'data' ->> 'dex' = 'full' then 'full' else 'none' end, 'cap', null,
                  'applied', nat -> 'data' ->> 'dex' = 'full');
    alternatives := alternatives || jsonb_build_object('formula', 'unarmored', 'value', 10 + dex_mod, 'used', false, 'reason', 'natural_armor_better');
    if worn then
      alternatives := alternatives || jsonb_build_object('formula', 'armor', 'value', armor_val, 'used', false,
        'reason', case when nat -> 'data' ->> 'mode' = 'replaces_armor' then 'natural_armor_replaces_armor' else 'natural_armor_better' end);
      if nat -> 'data' ->> 'mode' = 'replaces_armor' then
        warnings := warnings || jsonb_build_object('code', 'lineage_armor_no_benefit', 'severity', 'warning', 'source_type', 'armor',
                      'source_id', armor.inventory_item_id, 'item_id', armor.item_id, 'source_name', armor.name,
                      'trait_name', nat ->> 'trait_name');
      end if;
    end if;
  elsif worn then
    formula := case armor.dex_modifier_mode when 'full' then 'light_armor' when 'capped' then 'medium_armor' else 'heavy_armor' end;
    dex_part := case armor.dex_modifier_mode when 'full' then dex_mod when 'capped' then least(dex_mod, armor.dex_cap) else 0 end;
    ac_parts := ac_parts || jsonb_build_object('source_type', 'armor', 'source_id', armor.inventory_item_id, 'item_id', armor.item_id,
                  'source_name', armor.name, 'effect', 'base_ac', 'value', armor.base_ac);
    ac_parts := ac_parts || jsonb_build_object('source_type', 'ability', 'source_id', 'dex', 'source_name', 'Dexterity',
                  'effect', 'ability_modifier', 'value', dex_part, 'modifier', dex_mod, 'mode', armor.dex_modifier_mode,
                  'cap', armor.dex_cap, 'applied', armor.dex_modifier_mode <> 'none');
    alternatives := alternatives || jsonb_build_object('formula', 'unarmored', 'value', 10 + dex_mod, 'used', false,
                                                       'reason', 'armor_worn');
    if nat is not null then
      alternatives := alternatives || jsonb_build_object('formula', 'natural_armor', 'value', nat_val, 'used', false, 'reason', 'armor_better',
                                                         'source_name', nat ->> 'trait_name');
    end if;
  else
    formula := 'unarmored';
    ac_parts := ac_parts || jsonb_build_object('source_type', 'rule', 'source_id', 'unarmored', 'source_name', 'Unarmored',
                  'effect', 'base_ac', 'value', 10);
    ac_parts := ac_parts || jsonb_build_object('source_type', 'ability', 'source_id', 'dex', 'source_name', 'Dexterity',
                  'effect', 'ability_modifier', 'value', dex_mod, 'modifier', dex_mod, 'mode', 'full', 'cap', null, 'applied', true);
    if nat is not null then
      alternatives := alternatives || jsonb_build_object('formula', 'natural_armor', 'value', nat_val, 'used', false,
                                                         'reason', 'unarmored_better', 'source_name', nat ->> 'trait_name');
    end if;
  end if;
  if armor.inventory_item_id is not null and not worn then
    warnings := warnings || jsonb_build_object('code', case when armor.visible then 'armor_stats_unknown' else 'hidden_item' end,
                  'severity', 'warning', 'source_type', 'armor', 'source_id', armor.inventory_item_id, 'item_id', armor.item_id,
                  'source_name', armor.name);
  end if;
  if shield.inventory_item_id is not null then
    if shield.is_shield then
      ac_parts := ac_parts || jsonb_build_object('source_type', 'shield', 'source_id', shield.inventory_item_id, 'item_id', shield.item_id,
                    'source_name', shield.name, 'effect', 'ac_bonus', 'value', shield.ac_bonus);
    else
      warnings := warnings || jsonb_build_object('code', case when shield.visible then 'armor_stats_unknown' else 'hidden_item' end,
                    'severity', 'warning', 'source_type', 'shield', 'source_id', shield.inventory_item_id, 'item_id', shield.item_id,
                    'source_name', shield.name);
    end if;
  end if;
  ac_parts := ac_parts || coalesce((
    select jsonb_agg(jsonb_build_object('source_type', e ->> 'source_type', 'source_id', e ->> 'source_id', 'item_id', e ->> 'item_id',
             'modifier_id', e ->> 'modifier_id', 'source_name', e ->> 'source_name', 'effect', 'ac_bonus', 'value', (e ->> 'value')::int)
             order by e ->> 'source_name')
    from jsonb_array_elements(effects) e
    where (e ->> 'applied')::boolean and e ->> 'effect_type' = 'ac_bonus' and e ->> 'scope' = 'global'), '[]'::jsonb);
  select sum((p ->> 'value')::int) into ac_calc from jsonb_array_elements(ac_parts) p;

  -- ---- proficiency consequences of armor and shield ---------------------------------------------------------------
  armor_cat := coalesce(armor.category_id, (select category_id from public.items where id = armor.base_item_id));
  select e into heavy_ignore from jsonb_array_elements(leff) e
  where (e ->> 'active')::boolean and e ->> 'effect_type' = 'ignore_heavy_armor_speed_penalty' and armor_cat = 'heavy-armor' limit 1;
  if armor.inventory_item_id is not null and armor.visible then
    select id into grp from public.proficiency_groups
    where armor_category_id = coalesce(armor.category_id, (select category_id from public.items where id = armor.base_item_id));
    armor_prof := public._proficiency_match(p_character, armor.item_id, armor.base_item_id, grp);
    nonprof_armor := not (armor_prof ->> 'proficient')::boolean;
    if nonprof_armor then
      warnings := warnings || jsonb_build_object('code', 'nonproficient_armor', 'severity', 'warning', 'source_type', 'armor',
                    'source_id', armor.inventory_item_id, 'item_id', armor.item_id, 'source_name', armor.name,
                    'missing_group_id', armor_prof ->> 'missing_group_id', 'missing_group_name', armor_prof ->> 'missing_group_name');
    end if;
    if armor.stealth_disadvantage then
      stealth_sources := stealth_sources || jsonb_build_object('source_type', 'armor', 'source_id', armor.inventory_item_id,
                           'item_id', armor.item_id, 'source_name', armor.name);
      warnings := warnings || jsonb_build_object('code', 'stealth_disadvantage', 'severity', 'info', 'source_type', 'armor',
                    'source_id', armor.inventory_item_id, 'item_id', armor.item_id, 'source_name', armor.name);
    end if;
    if armor.strength_requirement is not null and (scores ->> 'str')::int < armor.strength_requirement then
      str_unmet := true;
      warnings := warnings || jsonb_build_object('code', 'strength_requirement_unmet', 'severity', 'warning', 'source_type', 'armor',
                    'source_id', armor.inventory_item_id, 'item_id', armor.item_id, 'source_name', armor.name,
                    'required', armor.strength_requirement, 'current', (scores ->> 'str')::int,
                    'speed_penalty', case when heavy_ignore is null then 10 else 0 end, 'speed_penalty_ignored_by', heavy_ignore ->> 'trait_name');
    end if;
  end if;
  if shield.inventory_item_id is not null and shield.visible then
    select id into grp from public.proficiency_groups where armor_category_id = 'shield';
    shield_prof := public._proficiency_match(p_character, shield.item_id, shield.base_item_id, grp);
    nonprof_shield := not (shield_prof ->> 'proficient')::boolean;
    if nonprof_shield then
      warnings := warnings || jsonb_build_object('code', 'nonproficient_shield', 'severity', 'warning', 'source_type', 'shield',
                    'source_id', shield.inventory_item_id, 'item_id', shield.item_id, 'source_name', shield.name,
                    'missing_group_id', shield_prof ->> 'missing_group_id', 'missing_group_name', shield_prof ->> 'missing_group_name');
    end if;
  end if;
  if nonprof_armor or nonprof_shield then
    warnings := warnings || jsonb_build_object('code', 'spellcasting_restricted', 'severity', 'warning', 'source_type', 'rule',
                  'source_id', case when nonprof_armor then armor.inventory_item_id else shield.inventory_item_id end,
                  'source_name', case when nonprof_armor then armor.name else shield.name end);
  end if;
  stealth_sources := stealth_sources || coalesce((select jsonb_agg(jsonb_build_object('source_type', e ->> 'source_type',
                       'source_id', e ->> 'source_id', 'item_id', e ->> 'item_id', 'source_name', e ->> 'source_name'))
                     from jsonb_array_elements(effects) e
                     where (e ->> 'applied')::boolean and e ->> 'effect_type' = 'skill_disadvantage' and e ->> 'target' = 'stealth'), '[]');

  -- ---- speed: stored base speed + permanent bonuses - equipment penalties (stored speed is never changed) ---------
  select e into walk_eff from jsonb_array_elements(leff) e
  where (e ->> 'active')::boolean and e ->> 'effect_type' = 'speed' and e ->> 'target' = 'walk' and e ->> 'value' is not null
  order by (e ->> 'value')::int desc limit 1;
  if walk_eff is not null then
    speed_parts := jsonb_build_array(jsonb_build_object('source_type', 'lineage', 'source_id', walk_eff ->> 'trait_id',
                     'source_name', walk_eff ->> 'trait_name', 'effect', 'base', 'value', (walk_eff ->> 'value')::int));
  else
    speed_parts := jsonb_build_array(jsonb_build_object('source_type', 'base', 'source_id', 'speed', 'source_name', 'Base speed',
                                                        'effect', 'base', 'value', c.speed));
  end if;
  if str_unmet and heavy_ignore is not null then
    speed_parts := speed_parts || jsonb_build_object('source_type', 'armor', 'source_id', armor.inventory_item_id, 'item_id', armor.item_id,
                     'source_name', armor.name, 'effect', 'strength_requirement', 'value', 0, 'ignored_by', heavy_ignore ->> 'trait_name',
                     'required', armor.strength_requirement, 'current', (scores ->> 'str')::int);
  elsif str_unmet then
    speed_parts := speed_parts || jsonb_build_object('source_type', 'armor', 'source_id', armor.inventory_item_id, 'item_id', armor.item_id,
                     'source_name', armor.name, 'effect', 'strength_requirement', 'value', -10,
                     'required', armor.strength_requirement, 'current', (scores ->> 'str')::int);
  end if;
  speed_parts := speed_parts || coalesce((select jsonb_agg(jsonb_build_object('source_type', e ->> 'source_type', 'source_id', e ->> 'source_id',
                     'item_id', e ->> 'item_id', 'source_name', e ->> 'source_name', 'effect', e ->> 'effect_type',
                     'value', case when e ->> 'effect_type' = 'speed_penalty' then -abs((e ->> 'value')::int) else (e ->> 'value')::int end))
                   from jsonb_array_elements(effects) e
                   where (e ->> 'applied')::boolean and e ->> 'effect_type' in ('speed_bonus', 'speed_penalty')), '[]');
  select greatest(0, sum((p ->> 'value')::int)) into speed_val from jsonb_array_elements(speed_parts) p;
  movement := jsonb_build_object('walk', jsonb_build_object('value', speed_val, 'active', true));
  foreach mv in array array['climb', 'swim', 'fly', 'burrow'] loop
    best := null; any_mode := null;
    select e || jsonb_build_object('resolved', case when e ->> 'value_text' = 'walk' then speed_val else (e ->> 'value')::int end,
                                   'blocked', coalesce(e -> 'conditions' -> 'not_armor' ? armor_cat, false) and worn)
    into any_mode
    from jsonb_array_elements(leff) e
    where (e ->> 'active')::boolean and e ->> 'effect_type' = 'speed' and e ->> 'target' = mv
    order by coalesce(e -> 'conditions' -> 'not_armor' ? armor_cat, false) and worn,
             case when e ->> 'value_text' = 'walk' then speed_val else (e ->> 'value')::int end desc
    limit 1;
    if any_mode is not null then
      movement := movement || jsonb_build_object(mv, jsonb_build_object(
        'value', (any_mode ->> 'resolved')::int, 'active', not (any_mode ->> 'blocked')::boolean,
        'inactive_reason', case when (any_mode ->> 'blocked')::boolean then 'armor' end,
        'equal_to_walk', any_mode ->> 'value_text' = 'walk', 'conditions', any_mode -> 'conditions',
        'source_name', any_mode ->> 'trait_name', 'trait_id', any_mode ->> 'trait_id'));
    end if;
  end loop;

  -- ---- saving throws and skills: only what equipment adds (proficiency is still calculated on the sheet) ---------
  foreach k in array array['str', 'dex', 'con', 'int', 'wis', 'cha'] loop
    saves := saves || jsonb_build_object(k, jsonb_build_object(
      'item_bonus', public._effect_total(effects, 'save_bonus', null) + public._effect_total(effects, 'save_bonus', k),
      'disadvantage', (nonprof_armor or nonprof_shield) and k in ('str', 'dex')));
  end loop;
  select coalesce(jsonb_object_agg(t.skill, t.v), '{}'::jsonb) into skills from (
    select s.skill, jsonb_build_object(
      'advantage', exists (select 1 from jsonb_array_elements(effects) e where (e ->> 'applied')::boolean
                           and e ->> 'effect_type' = 'skill_advantage' and e ->> 'target' = s.skill),
      'disadvantage', (s.skill = 'stealth' and jsonb_array_length(stealth_sources) > 0)
                      or exists (select 1 from jsonb_array_elements(effects) e where (e ->> 'applied')::boolean
                                 and e ->> 'effect_type' = 'skill_disadvantage' and e ->> 'target' = s.skill),
      'sources', case when s.skill = 'stealth' then stealth_sources else '[]'::jsonb end) as v
    from (select distinct e ->> 'target' as skill from jsonb_array_elements(effects) e
          where e ->> 'effect_type' in ('skill_advantage', 'skill_disadvantage') and (e ->> 'applied')::boolean
          union select 'stealth') s) t;

  select coalesce(jsonb_object_agg(s.k, s.src), '{}') into lin_skills from (
    select e ->> 'value_text' as k, jsonb_agg(jsonb_build_object('source_type', 'lineage', 'trait_id', e ->> 'trait_id',
                                                                   'source_name', e ->> 'trait_name')) as src
    from jsonb_array_elements(leff) e
    where (e ->> 'active')::boolean and e ->> 'effect_type' = 'proficiency' and e ->> 'target' = 'skill'
    group by 1) s;
  for k in select jsonb_object_keys(lin_skills) loop
    skills := skills || jsonb_build_object(k, coalesce(skills -> k, '{"advantage": false, "disadvantage": false, "sources": []}'::jsonb)
                                               || jsonb_build_object('lineage_proficient', true, 'proficiency_sources', lin_skills -> k));
  end loop;

  -- ---- natural weapons from the lineage (unarmed strikes: Strength, always proficient) ---------------------------
  select coalesce(jsonb_agg(jsonb_build_object(
           'trait_id', e ->> 'trait_id', 'source_name', e ->> 'trait_name', 'name', e ->> 'value_text',
           'damage_dice', e -> 'data' ->> 'damage_dice', 'damage_type', e -> 'data' ->> 'damage_type', 'ability', 'str',
           'ability_modifier', (mods ->> 'str')::int, 'proficient', true, 'proficiency_bonus', pb,
           'attack_bonus', (mods ->> 'str')::int + pb,
           'damage', (e -> 'data' ->> 'damage_dice') || case when (mods ->> 'str')::int > 0 then ' + ' || (mods ->> 'str')
                                                             when (mods ->> 'str')::int < 0 then ' - ' || abs((mods ->> 'str')::int) else '' end,
           'attack_disadvantage', nonprof_armor or nonprof_shield) order by e ->> 'trait_id', e ->> 'seq'), '[]')
  into nat_weapons
  from jsonb_array_elements(leff) e where (e ->> 'active')::boolean and e ->> 'effect_type' = 'natural_weapon';

  -- ---- equipped weapons -----------------------------------------------------------------------------------------
  for w in
    select e.slot_id, e.inventory_item_id, ii.item_id, coalesce(ii.custom_name, it.name) as name, it.base_item_id,
           ws.weapon_group, ws.damage_dice, ws.damage_type_id, ws.versatile_damage, ws.is_ranged, ws.range_normal, ws.range_max,
           exists (select 1 from public.weapon_property_links l where l.item_id = ws.item_id and l.property_id = 'finesse') as finesse,
           (select coalesce(array_agg(l.property_id order by l.property_id), '{}') from public.weapon_property_links l where l.item_id = ws.item_id) as properties
    from public.character_equipment e
    join public.inventory_items ii on ii.id = e.inventory_item_id
    join public.items it on it.id = ii.item_id
    join lateral (select s.* from public.weapon_stats s where s.item_id in (it.id, it.base_item_id)
                  order by s.item_id = it.id desc limit 1) ws on true
    where e.character_id = p_character and e.slot_id in ('main_hand', 'off_hand')
    order by e.slot_id
  loop
    if w.finesse then ab := case when (mods ->> 'dex')::int > (mods ->> 'str')::int then 'dex' else 'str' end;
    elsif w.is_ranged then ab := 'dex';
    else ab := 'str';
    end if;
    ab_mod := (mods ->> ab)::int;
    select id into grp from public.proficiency_groups where weapon_group = w.weapon_group;
    prof := public._proficiency_match(p_character, w.item_id, w.base_item_id, grp);
    atk_magic := public._effect_total(effects, 'attack_bonus', null, w.inventory_item_id) + public._effect_total(effects, 'attack_bonus', null);
    dmg_magic := public._effect_total(effects, 'damage_bonus', null, w.inventory_item_id) + public._effect_total(effects, 'damage_bonus', null);
    atk_total := ab_mod + case when (prof ->> 'proficient')::boolean then pb else 0 end + atk_magic;
    dmg_bonus := ab_mod + dmg_magic;
    atk_parts := jsonb_build_array(
      jsonb_build_object('source_type', 'ability', 'source_id', ab, 'effect', 'ability_modifier', 'value', ab_mod),
      jsonb_build_object('source_type', 'proficiency', 'source_id', 'proficiency_bonus', 'effect', 'proficiency_bonus',
                         'value', case when (prof ->> 'proficient')::boolean then pb else 0 end,
                         'applied', (prof ->> 'proficient')::boolean, 'proficiency_bonus', pb));
    atk_parts := atk_parts || coalesce((select jsonb_agg(jsonb_build_object('source_type', e ->> 'source_type', 'source_id', e ->> 'source_id',
                     'modifier_id', e ->> 'modifier_id', 'source_name', e ->> 'source_name', 'effect', 'attack_bonus', 'value', (e ->> 'value')::int))
                   from jsonb_array_elements(effects) e where (e ->> 'applied')::boolean and e ->> 'effect_type' = 'attack_bonus'
                     and (e ->> 'scope' = 'global' or (e ->> 'source_id')::uuid = w.inventory_item_id)), '[]');
    dmg_parts := jsonb_build_array(jsonb_build_object('source_type', 'ability', 'source_id', ab, 'effect', 'ability_modifier', 'value', ab_mod))
      || coalesce((select jsonb_agg(jsonb_build_object('source_type', e ->> 'source_type', 'source_id', e ->> 'source_id',
                     'modifier_id', e ->> 'modifier_id', 'source_name', e ->> 'source_name', 'effect', 'damage_bonus', 'value', (e ->> 'value')::int))
                   from jsonb_array_elements(effects) e where (e ->> 'applied')::boolean and e ->> 'effect_type' = 'damage_bonus'
                     and (e ->> 'scope' = 'global' or (e ->> 'source_id')::uuid = w.inventory_item_id)), '[]');
    weapons := weapons || jsonb_build_object(
      'inventory_item_id', w.inventory_item_id, 'item_id', w.item_id, 'name', w.name, 'slot_id', w.slot_id,
      'weapon_group', w.weapon_group, 'properties', to_jsonb(w.properties), 'is_ranged', w.is_ranged,
      'range_normal', w.range_normal, 'range_max', w.range_max,
      'ability', ab, 'ability_rule', case when w.finesse then 'finesse_best' when w.is_ranged then 'ranged_dex' else 'melee_str' end,
      'ability_modifier', ab_mod, 'proficient', (prof ->> 'proficient')::boolean, 'proficiency', prof,
      'proficiency_bonus', pb, 'proficiency_bonus_applied', (prof ->> 'proficient')::boolean,
      'magic_attack_bonus', atk_magic, 'attack_bonus', atk_total, 'attack_breakdown', atk_parts,
      'damage_dice', w.damage_dice, 'versatile_damage', w.versatile_damage, 'damage_type', w.damage_type_id,
      'magic_damage_bonus', dmg_magic, 'damage_bonus', dmg_bonus, 'damage_breakdown', dmg_parts,
      'damage', case when w.damage_dice is null then null
                     when w.damage_dice ~ '^[0-9]+$' then greatest(0, w.damage_dice::int + dmg_bonus)::text
                     when dmg_bonus = 0 then w.damage_dice
                     else w.damage_dice || case when dmg_bonus > 0 then ' + ' else ' - ' end || abs(dmg_bonus) end,
      'attack_disadvantage', nonprof_armor or nonprof_shield);
    if not (prof ->> 'proficient')::boolean then
      warnings := warnings || jsonb_build_object('code', 'nonproficient_weapon', 'severity', 'info', 'source_type', 'weapon',
                    'source_id', w.inventory_item_id, 'item_id', w.item_id, 'source_name', w.name,
                    'missing_group_id', prof ->> 'missing_group_id', 'missing_group_name', prof ->> 'missing_group_name');
    end if;
  end loop;

  -- ---- odds and ends --------------------------------------------------------------------------------------------
  select count(*) into legacy_eq from public.inventory_items ii join public.inventories inv on inv.id = ii.inventory_id
  where inv.character_id = p_character and ii.item_id is null and ii.equipped;
  if legacy_eq > 0 then
    warnings := warnings || jsonb_build_object('code', 'legacy_equipped_ignored', 'severity', 'info', 'source_type', 'legacy',
                  'source_id', null, 'count', legacy_eq);
  end if;
  select coalesce(jsonb_agg(jsonb_build_object('code', 'hidden_item', 'severity', 'warning', 'source_type', 'equipment',
           'source_id', e.inventory_item_id, 'slot_id', e.slot_id)), '[]') into hidden
  from public.character_equipment e join public.inventory_items ii on ii.id = e.inventory_item_id
  left join public.items it on it.id = ii.item_id
  where e.character_id = p_character and it.id is null and e.slot_id not in ('armor', 'shield');
  warnings := warnings || hidden;

  return jsonb_build_object(
    'character_id', c.id,
    'ruleset', 'dnd5e-2014',
    'proficiency_bonus', jsonb_build_object('value', pb, 'source', 'level', 'level', c.level),
    'abilities', abilities,
    'armor_class', jsonb_build_object(
      'value', coalesce(c.ac_override, ac_calc), 'calculated', ac_calc, 'override', c.ac_override,
      'source', case when c.ac_override is not null then 'override' else 'calculated' end,
      'legacy_stored', c.ac, 'base_formula', formula, 'breakdown', ac_parts, 'alternatives', alternatives,
      'inactive_effects', (select coalesce(jsonb_agg(e), '[]'::jsonb) from jsonb_array_elements(effects) e
                           where e ->> 'effect_type' = 'ac_bonus' and not (e ->> 'active')::boolean)),
    'speed', jsonb_build_object('base', c.speed, 'value', speed_val, 'breakdown', speed_parts,
                                'base_source', case when walk_eff is not null then 'lineage' else 'character' end,
                                'movement', movement),
    'armor', case when armor.inventory_item_id is null then null else jsonb_build_object(
      'inventory_item_id', armor.inventory_item_id, 'item_id', armor.item_id, 'name', armor.name,
      'base_ac', armor.base_ac, 'dex_modifier_mode', armor.dex_modifier_mode, 'dex_cap', armor.dex_cap,
      'strength_requirement', armor.strength_requirement, 'stealth_disadvantage', armor.stealth_disadvantage,
      'proficiency', armor_prof) end,
    'shield', case when shield.inventory_item_id is null then null else jsonb_build_object(
      'inventory_item_id', shield.inventory_item_id, 'item_id', shield.item_id, 'name', shield.name,
      'ac_bonus', shield.ac_bonus, 'proficiency', shield_prof) end,
    'armor_consequences', jsonb_build_object(
      'nonproficient_armor', nonprof_armor, 'nonproficient_shield', nonprof_shield,
      'ability_check_disadvantage', case when nonprof_armor or nonprof_shield then '["str","dex"]'::jsonb else '[]'::jsonb end,
      'saving_throw_disadvantage', case when nonprof_armor or nonprof_shield then '["str","dex"]'::jsonb else '[]'::jsonb end,
      'attack_disadvantage', case when nonprof_armor or nonprof_shield then '["str","dex"]'::jsonb else '[]'::jsonb end,
      'spellcasting_restricted', nonprof_armor or nonprof_shield,
      'stealth_disadvantage', jsonb_array_length(stealth_sources) > 0, 'stealth_sources', stealth_sources,
      'strength_requirement_unmet', str_unmet,
      'strength_requirement', armor.strength_requirement, 'strength_current', (scores ->> 'str')::int,
      'speed_penalty', case when str_unmet and heavy_ignore is null then 10 else 0 end,
      'speed_penalty_ignored_by', case when str_unmet then heavy_ignore ->> 'trait_name' end),
    'saving_throws', saves,
    'skills', skills,
    'equipped_weapon_attacks', weapons,
    'tools', (select coalesce(jsonb_agg(jsonb_build_object('inventory_item_id', ii.id, 'item_id', ii.item_id,
                'name', coalesce(ii.custom_name, it.name), 'category_id', it.category_id,
                'proficient', (public._proficiency_match(p_character, ii.item_id, it.base_item_id, null) ->> 'proficient')::boolean)
                order by it.name), '[]'::jsonb)
              from public.inventory_items ii join public.inventories inv on inv.id = ii.inventory_id
              join public.items it on it.id = ii.item_id
              where inv.character_id = p_character and it.kind_id = 'tool'),
    'proficiencies', (select coalesce(jsonb_agg(jsonb_build_object('id', p.id, 'proficiency_type', p.proficiency_type,
                        'group_id', p.group_id, 'item_id', p.item_id, 'name', coalesce(g.name, it.name, p.item_id),
                        'source_type', p.source_type, 'notes', p.notes) order by p.proficiency_type, coalesce(g.sort_order, 1000), coalesce(g.name, it.name)), '[]'::jsonb)
                      from public.character_proficiencies p
                      left join public.proficiency_groups g on g.id = p.group_id
                      left join public.items it on it.id = p.item_id
                      where p.character_id = p_character)
                     || (select coalesce(jsonb_agg(jsonb_build_object('id', null, 'proficiency_type',
                              case e ->> 'target' when 'group' then g.proficiency_type when 'armor' then
                                   case when it.category_id = 'shield' then 'shield' else 'armor' end else e ->> 'target' end,
                              'group_id', case when e ->> 'target' = 'group' then e ->> 'value_text' end,
                              'item_id', case when e ->> 'target' <> 'group' then e ->> 'value_text' end,
                              'name', coalesce(g.name, it.name, e ->> 'value_text'), 'source_type', 'lineage',
                              'notes', e ->> 'trait_name', 'trait_id', e ->> 'trait_id')
                              order by e ->> 'target', coalesce(g.name, it.name)), '[]')
                         from jsonb_array_elements(leff) e
                         left join public.proficiency_groups g on e ->> 'target' = 'group' and g.id = e ->> 'value_text'
                         left join public.items it on e ->> 'target' in ('weapon', 'armor', 'tool') and it.id = e ->> 'value_text'
                         where (e ->> 'active')::boolean and e ->> 'effect_type' = 'proficiency' and e ->> 'target' <> 'skill'),
    'other_effects', (select coalesce(jsonb_agg(e), '[]'::jsonb) from jsonb_array_elements(effects) e
                      where e ->> 'effect_type' in ('resistance', 'carrying_capacity_bonus') or e ->> 'effect_type' is null),
    'effects', effects,
    'warnings', warnings,
    -- lineage layer
    'lineage', case when lsel.character_id is null then null else jsonb_build_object(
        'lineage_id', lsel.lineage_id, 'version_id', lsel.version_id, 'subversion_id', lsel.subversion_id,
        'name', (select name from public.lineages where id = lsel.lineage_id),
        'version_name', (select name from public.lineage_versions where id = lsel.version_id),
        'subversion_name', (select name from public.lineage_versions where id = lsel.subversion_id),
        'ability_bonuses_included', lsel.ability_bonuses_included) end,
    'size', (select jsonb_build_object('value', e ->> 'value_text', 'source_name', e ->> 'trait_name', 'trait_id', e ->> 'trait_id')
             from jsonb_array_elements(leff) e where (e ->> 'active')::boolean and e ->> 'effect_type' = 'size'
             order by (e ->> 'min_level')::int desc limit 1),
    'creature_type', (select coalesce(s.creature_type, v.creature_type) from public.lineage_versions v
                      left join public.lineage_versions s on s.id = lsel.subversion_id where v.id = lsel.version_id),
    'senses', (select coalesce(jsonb_object_agg(t.target, jsonb_build_object('value', t.v, 'source_name', t.src)), '{}') from (
                 select distinct on (e ->> 'target') e ->> 'target' as target, (e ->> 'value')::int as v, e ->> 'trait_name' as src
                 from jsonb_array_elements(leff) e where (e ->> 'active')::boolean and e ->> 'effect_type' = 'sense'
                 order by e ->> 'target', (e ->> 'value')::int desc) t),
    'languages', (select coalesce(jsonb_agg(jsonb_build_object('id', t.id, 'name', coalesce(lg.name, t.id), 'sources', t.src)
                                            order by coalesce(lg.sort_order, 999), t.id), '[]') from (
                    select e ->> 'value_text' as id, jsonb_agg(distinct e ->> 'trait_name') as src
                    from jsonb_array_elements(leff) e where (e ->> 'active')::boolean and e ->> 'effect_type' = 'language'
                    group by 1) t left join public.languages lg on lg.id = t.id),
    'resistances', (select coalesce(jsonb_agg(jsonb_build_object('damage_type', t.dt, 'sources', t.src) order by t.dt), '[]') from (
                      select x.dt, jsonb_agg(distinct x.src) as src from (
                        select e ->> 'value_text' as dt, e ->> 'trait_name' as src from jsonb_array_elements(leff) e
                        where (e ->> 'active')::boolean and e ->> 'effect_type' = 'resistance'
                        union all
                        select e ->> 'target', e ->> 'source_name' from jsonb_array_elements(effects) e
                        where (e ->> 'applied')::boolean and e ->> 'effect_type' = 'resistance') x group by 1) t),
    'immunities', (select coalesce(jsonb_agg(distinct e ->> 'value_text'), '[]') from jsonb_array_elements(leff) e
                   where (e ->> 'active')::boolean and e ->> 'effect_type' = 'immunity'),
    'condition_immunities', (select coalesce(jsonb_agg(distinct e ->> 'value_text'), '[]') from jsonb_array_elements(leff) e
                             where (e ->> 'active')::boolean and e ->> 'effect_type' = 'condition_immunity'),
    'advantages', (select coalesce(jsonb_agg(jsonb_build_object('kind', e ->> 'effect_type', 'target', e ->> 'target',
                     'scope', e ->> 'value_text', 'source_name', e ->> 'trait_name', 'trait_id', e ->> 'trait_id')
                     order by e ->> 'effect_type', e ->> 'trait_id', (e ->> 'seq')::int), '[]')
                   from jsonb_array_elements(leff) e
                   where (e ->> 'active')::boolean and e ->> 'effect_type' in ('save_advantage', 'check_advantage')),
    'natural_weapons', nat_weapons,
    'lineage_spells', (select coalesce(jsonb_agg(jsonb_build_object(
                         'name', e ->> 'value_text', 'slug', e -> 'data' ->> 'slug', 'trait_id', e ->> 'trait_id',
                         'source_name', e ->> 'trait_name', 'min_level', (e ->> 'min_level')::int, 'unlocked', (e ->> 'active')::boolean,
                         'uses', e -> 'data' ->> 'uses', 'recharge', e -> 'data' ->> 'recharge', 'cast_level', e -> 'data' -> 'cast_level',
                         'ability', e -> 'data' ->> 'ability', 'ability_needed', e -> 'data' ? 'ability_choice' and not e -> 'data' ? 'ability',
                         'save_dc', case when e -> 'data' ? 'ability' then 8 + pb + (mods ->> (e -> 'data' ->> 'ability'))::int end,
                         'attack_bonus', case when e -> 'data' ? 'ability' then pb + (mods ->> (e -> 'data' ->> 'ability'))::int end,
                         'notes', e -> 'data' ->> 'notes')
                         order by (e ->> 'min_level')::int, e ->> 'trait_id', (e ->> 'seq')::int), '[]')
                       from jsonb_array_elements(leff) e where e ->> 'effect_type' = 'spell'),
    'lineage_actions', (select coalesce(jsonb_agg(jsonb_build_object(
                          'name', e ->> 'value_text', 'trait_id', e ->> 'trait_id', 'source_name', e ->> 'trait_name',
                          'min_level', (e ->> 'min_level')::int, 'unlocked', (e ->> 'active')::boolean,
                          'uses', case e -> 'data' ->> 'uses' when 'pb' then to_jsonb(pb) when null then null
                                      else to_jsonb(e -> 'data' ->> 'uses') end,
                          'recharge', e -> 'data' ->> 'recharge',
                          'save_dc', case when e -> 'data' ? 'dc_ability' then 8 + pb + (mods ->> (e -> 'data' ->> 'dc_ability'))::int end,
                          'save_ability', e -> 'data' ->> 'save_ability',
                          'dice', (select d2 ->> 1 from jsonb_array_elements(e -> 'data' -> 'dice_by_level') d2
                                   where (d2 ->> 0)::int <= c.level order by (d2 ->> 0)::int desc limit 1),
                          'damage_type', e -> 'data' ->> 'damage_type', 'notes', e -> 'data' ->> 'notes')
                          order by (e ->> 'min_level')::int, e ->> 'trait_id', (e ->> 'seq')::int), '[]')
                        from jsonb_array_elements(leff) e where e ->> 'effect_type' = 'limited_use'),
    'initiative', jsonb_build_object('bonus', coalesce((select sum(case when e ->> 'value_text' = 'pb' then pb else (e ->> 'value')::int end)
                                                       from jsonb_array_elements(leff) e
                                                       where (e ->> 'active')::boolean and e ->> 'effect_type' = 'initiative_bonus'), 0),
                                     'sources', (select coalesce(jsonb_agg(e ->> 'trait_name'), '[]') from jsonb_array_elements(leff) e
                                                 where (e ->> 'active')::boolean and e ->> 'effect_type' = 'initiative_bonus')),
    'hit_points', jsonb_build_object('lineage_bonus', coalesce((select sum((e ->> 'value')::int) * c.level from jsonb_array_elements(leff) e
                                                               where (e ->> 'active')::boolean and e ->> 'effect_type' = 'hp_per_level'), 0),
                                     'sources', (select coalesce(jsonb_agg(e ->> 'trait_name'), '[]') from jsonb_array_elements(leff) e
                                                 where (e ->> 'active')::boolean and e ->> 'effect_type' = 'hp_per_level')),
    'carrying_capacity', jsonb_build_object('size_steps', coalesce((select max((e ->> 'value')::int) from jsonb_array_elements(leff) e
                                                                    where (e ->> 'active')::boolean and e ->> 'effect_type' = 'carrying_capacity'), 0)));
end;
$function$;

CREATE OR REPLACE FUNCTION public._proficiency_match(p_character uuid, p_item text, p_base_item text, p_group text)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
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
    (select jsonb_build_object('proficient', true, 'matched_by', 'class_feature', 'source_type', 'class',
                               'character_class_id', e.character_class_id, 'feature_name', e.feature_name, 'class_name', e.class_name,
                               'group_id', case when e.target = 'group' then e.value_text end,
                               'item_id', case when e.target <> 'group' then e.value_text end)
     from public._character_class_effects(p_character) e
     where e.effect_type = 'proficiency' and e.active
       and ((e.target in ('weapon', 'armor', 'tool') and e.value_text in (p_item, p_base_item))
            or (e.target = 'group' and e.value_text = p_group))
     limit 1),
    jsonb_build_object('proficient', false, 'missing_group_id', p_group,
                       'missing_group_name', (select name from public.proficiency_groups where id = p_group)));
$function$;

CREATE OR REPLACE FUNCTION public._cf_choice_error(p_character uuid, p_character_class uuid, p_unlock text, p_choice class_feature_choices, p_values text[], p_max integer, p_strict boolean)
 RETURNS text
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v text; n int := coalesce(cardinality(p_values), 0); cfg jsonb := p_choice.config; man int; ok boolean; sv public.spell_versions;
  total int; c public.characters; d jsonb;
begin
  if n > p_max then return format('choose at most %s', p_max); end if;
  if n <> (select count(distinct x) from unnest(p_values) x) then return 'the same value was chosen twice'; end if;
  if p_choice.kind = 'subclass' then return 'choose the subclass with set_character_subclass'; end if;
  select * into c from public.characters where id = p_character;
  foreach v in array coalesce(p_values, '{}') loop
    if p_choice.allow_free_text and v ~ '^text:' then
      if length(btrim(substr(v, 6))) = 0 then return 'enter some text'; end if;
      continue;
    end if;
    case p_choice.kind
      when 'option' then
        if not exists (select 1 from public.class_feature_choice_options o where o.choice_id = p_choice.id and o.option_id = v) then
          return format('"%s" is not one of the options', v); end if;
      when 'skill' then
        if not exists (select 1 from public.skills where id = v) or (cfg ? 'from' and not cfg -> 'from' ? v) then
          return format('"%s" is not an allowed skill', v); end if;
      when 'expertise' then
        if coalesce(cfg -> 'tools' ? v, false) then
          if p_strict then
            d := public.get_character_derived_stats(p_character);
            if not exists (select 1 from jsonb_array_elements(coalesce(d -> 'proficiencies', '[]')) p where p ->> 'item_id' = v) then
              return format('Expertise needs proficiency with %s first', coalesce((select name from public.items where id = v), v));
            end if;
          end if;
          continue;
        end if;
        if not exists (select 1 from public.skills where id = v) or (cfg ? 'from' and not cfg -> 'from' ? v) then
          return format('"%s" is not an allowed skill', v); end if;
        if p_strict then
          man := public._skill_level(c.skill_proficiencies -> v);
          d := public.get_character_derived_stats(p_character);
          if not (man >= 1 or coalesce((d -> 'skills' -> v ->> 'lineage_proficient')::boolean, false)
                  or coalesce((d -> 'skills' -> v ->> 'class_proficient')::boolean, false)) then
            return format('Expertise needs proficiency in %s first', coalesce((select name from public.skills where id = v), v));
          end if;
          if man = 2 or exists (select 1 from public.character_feature_choices ch join public.character_feature_choice_values x on x.character_choice_id = ch.id
                                join public.class_feature_choices cf on cf.id = ch.choice_id
                                where ch.character_id = p_character and cf.kind = 'expertise' and x.value = v
                                  and not (ch.character_class_id = p_character_class and ch.unlock_id = p_unlock and ch.choice_id = p_choice.id)) then
            return format('%s already has expertise', coalesce((select name from public.skills where id = v), v));
          end if;
        end if;
      when 'language' then
        if not exists (select 1 from public.languages where id = v) or coalesce(cfg -> 'exclude' ? v, false) then
          return format('"%s" is not an allowed language', v); end if;
      when 'tool' then
        if not exists (select 1 from public.items i where i.id = v and i.kind_id = 'tool' and i.owner_id is null
                       and (not cfg ? 'category' or i.category_id = cfg ->> 'category')) or (cfg ? 'from' and not cfg -> 'from' ? v) then
          return format('"%s" is not an allowed tool', v); end if;
      when 'weapon', 'item' then
        if not exists (select 1 from public.items i where i.id = v and i.owner_id is null
                       and (p_choice.kind = 'item' or i.kind_id = 'weapon')
                       and (not cfg ? 'category' or i.category_id = cfg ->> 'category')) or (cfg ? 'from' and not cfg -> 'from' ? v) then
          return format('"%s" is not an allowed %s', v, p_choice.kind); end if;
      when 'proficiency_group' then
        if not exists (select 1 from public.proficiency_groups where id = v) or (cfg ? 'from' and not cfg -> 'from' ? v) then
          return format('"%s" is not an allowed proficiency', v); end if;
      when 'ability' then
        if v not in ('str', 'dex', 'con', 'int', 'wis', 'cha') or (cfg ? 'from' and not cfg -> 'from' ? v) then
          return format('"%s" is not an allowed ability', v); end if;
      when 'spell' then
        select * into sv from public.spell_versions where id = v;
        if sv.id is null or not public.can_view_spell(sv.spell_id) then return format('Unknown spell "%s"', v); end if;
        if cfg ? 'spell_list' and not exists (select 1 from public.class_spell_list_entries e
                                              where e.list_id = cfg ->> 'spell_list' and e.spell_version_id = v) then
          return format('%s is not on the allowed spell list', sv.name); end if;
        if cfg ? 'spell_lists' and not exists (select 1 from public.class_spell_list_entries e
                                               where e.list_id in (select jsonb_array_elements_text(cfg -> 'spell_lists')) and e.spell_version_id = v) then
          return format('%s is not on an allowed spell list', sv.name); end if;
        if cfg ->> 'max_spell_level' = 'castable' then
          total := (select lv.max_spell_level from public.character_classes cc
                    join public.class_version_levels lv on lv.class_version_id = cc.class_version_id and lv.level = cc.level
                    where cc.id = p_character_class);
          if sv.level > coalesce(total, 0) then
            return format('%s is level %s; at this class level you can cast spells up to level %s', sv.name, sv.level, coalesce(total, 0));
          end if;
        end if;
        if coalesce((cfg ->> 'in_spellbook')::boolean, false) and p_strict and not exists (
             select 1 from public.character_spells g join public.character_spellcasting_sources s on s.id = g.source_id
             where s.character_class_id = p_character_class and g.spell_version_id = v and g.known) then
          return format('%s is not in your spellbook', sv.name);
        end if;
        if cfg ? 'max_spell_level' and cfg ->> 'max_spell_level' <> 'castable' and sv.level > (cfg ->> 'max_spell_level')::int then
          return format('%s is level %s; at most level %s here', sv.name, sv.level, cfg ->> 'max_spell_level'); end if;
        if cfg ? 'spell_level' and sv.level <> (cfg ->> 'spell_level')::int then
          return format('%s is level %s; choose a level %s spell', sv.name, sv.level, cfg ->> 'spell_level'); end if;
      when 'asi' then
        if v ~ '^feat:' then
          if n > 1 then return 'a feat replaces the ability increases; choose one or the other'; end if;
          if length(btrim(substr(v, 6))) = 0 then return 'enter the feat name'; end if;
        elsif v !~ '^(str|dex|con|int|wis|cha):[1-2]$' then
          return format('"%s" is not an ability increase', v);
        end if;
      when 'number' then
        if v !~ '^[a-z0-9_-]+:[0-9]{1,2}$' or (cfg ? 'keys' and not cfg -> 'keys' ? split_part(v, ':', 1)) then
          return format('"%s" is not an allowed allocation', v); end if;
      when 'free_text' then
        if btrim(v) = '' then return 'enter some text'; end if;
      else null;
    end case;
  end loop;
  if p_choice.kind = 'asi' and n > 0 and not (n = 1 and p_values[1] ~ '^feat:') then
    if n <> (select count(distinct split_part(x, ':', 1)) from unnest(p_values) x) then return 'choose different abilities'; end if;
    select sum(split_part(x, ':', 2)::int) into total from unnest(p_values) x;
    if total > coalesce((cfg ->> 'points')::int, 2) then return format('at most %s points in total', coalesce((cfg ->> 'points')::int, 2)); end if;
  end if;
  -- an option of a distinct group (fighting styles ...) can be chosen only once per character, whichever feature offers it
  if cfg ? 'distinct_group' and n > 0 then
    select v2.value into v
    from public.character_feature_choices c2
    join public.character_feature_choice_values v2 on v2.character_choice_id = c2.id
    join public.class_feature_choices f2 on f2.id = c2.choice_id
    where c2.character_id = p_character and f2.config ->> 'distinct_group' = cfg ->> 'distinct_group' and v2.value = any (p_values)
      and not (c2.character_class_id = p_character_class and c2.unlock_id = p_unlock and c2.choice_id = p_choice.id)
    limit 1;
    if v is not null then
      return format('%s is already chosen (each option of this kind can be taken only once)',
                    coalesce((select o.label from public.class_feature_choice_options o where o.choice_id = p_choice.id and o.option_id = v), v));
    end if;
  end if;
  if p_choice.kind = 'number' and cfg ? 'total' and n > 0 then
    select sum(split_part(x, ':', 2)::int) into total from unnest(p_values) x;
    if total > (cfg ->> 'total')::int then return format('at most %s in total', cfg ->> 'total'); end if;
  end if;
  return null;
end;
$function$;

CREATE OR REPLACE FUNCTION public.get_character_class_features(p_character uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
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
$function$;

CREATE OR REPLACE FUNCTION public.get_character_derived_stats(p_character uuid)
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
  from public._character_class_effects(p_character) x where x.feature_active;
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

create or replace function public.get_character_proficiencies(p_character uuid)
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
do $$
begin
  if exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'character_backgrounds') then
    alter publication supabase_realtime drop table public.character_backgrounds;
  end if;
end $$;
drop function if exists public.apply_background_equipment(uuid, text, jsonb), public.preview_background_equipment(uuid, text),
  public.get_character_background(uuid), public.clear_character_background(uuid),
  public.set_character_background(uuid, text, jsonb, jsonb, jsonb, jsonb), public.get_background_catalog(),
  public._background_version_json(text), public._background_layer(uuid, jsonb), public._character_background_abilities(uuid),
  public._character_background_grants(uuid);
drop table if exists public.character_background_equipment, public.character_background_replacements, public.character_background_choices,
  public.character_backgrounds, public.background_characteristic_tables, public.background_features, public.background_equipment_entries,
  public.background_equipment_packages, public.background_feat_grants, public.background_choice_options, public.background_choices,
  public.background_proficiency_grants, public.background_ability_options, public.background_versions, public.feats, public.backgrounds;
delete from public.source_books where id in ('phb-2024', 'ua-2022-wotm');

do $$
begin
  if to_regclass('supabase_migrations.schema_migrations') is not null then
    delete from supabase_migrations.schema_migrations where version = '20261017001200';
  end if;
end $$;

commit;
