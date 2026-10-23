-- =============================================================================
-- Rollback of 20261017000800_creatures_and_transformations.sql ONLY: restores the effect trigger and type list of 20261017000700, drops the transformation and companion
-- RPCs and tables and the creature catalog. Refuses while catalog effects use transform_form (run rollback_class_catalog.sql
-- first). Characters' companions and active forms are dropped with their tables.
-- =============================================================================
begin;

do $$
begin
  if exists (select 1 from public.class_feature_effects where effect_type = 'transform_form') then
    raise exception 'Official class content still uses transform_form; run rollback_class_catalog.sql first';
  end if;
end $$;

alter table public.class_feature_effects drop constraint class_feature_effects_effect_type_check;
alter table public.class_feature_effects add constraint class_feature_effects_effect_type_check check (effect_type in (
  'proficiency', 'expertise', 'ability_bonus', 'ac_bonus', 'ac_formula', 'attack_bonus', 'damage_bonus',
  'save_bonus', 'initiative_bonus', 'speed_bonus', 'resistance', 'immunity', 'skill_advantage',
  'skill_disadvantage', 'carrying_capacity_bonus', 'spell', 'attack', 'extra_attack', 'critical_range',
  'attunement_limit', 'ritual_casting', 'spellcasting_source', 'resource_modifier', 'informational',
  'skill_half_proficiency', 'sense', 'attack_rider', 'save_advantage', 'check_advantage', 'ability_max',
  'save_bonus_ability', 'condition_immunity', 'spell_list_addition', 'save_dc'));
update public.class_feature_versions set category = 'utility' where category = 'transformation';
alter table public.class_feature_versions drop constraint class_feature_versions_category_check;
alter table public.class_feature_versions add constraint class_feature_versions_category_check check (category in (
  'combat', 'defense', 'resource', 'spellcasting', 'proficiency', 'exploration',
  'social', 'utility', 'choice', 'subclass', 'asi'));

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
    when 'save_bonus_ability' then
      if not coalesce(new.data ->> 'ability', '') = any (abilities) or (new.target is not null and not new.target = any (abilities)) then
        raise exception 'save_bonus_ability needs data.ability and an optional save (target)' using errcode = '22023'; end if;
    when 'save_dc' then
      if coalesce(new.data ->> 'name', '') = '' or not coalesce(new.target, '') = any (abilities) then
        raise exception 'save_dc needs data.name and an ability (target)' using errcode = '22023'; end if;
    when 'condition_immunity' then
      if new.target not in ('blinded', 'charmed', 'deafened', 'frightened', 'grappled', 'incapacitated', 'invisible', 'paralyzed', 'petrified', 'poisoned', 'prone', 'restrained', 'stunned', 'unconscious', 'exhaustion', 'disease') then
        raise exception 'Unknown condition "%"', new.target using errcode = '22023'; end if;
    when 'spell_list_addition' then
      if new.spell_version_id is null then raise exception 'spell_list_addition needs a spell version' using errcode = '22023'; end if;
    when 'ability_max' then
      if not new.target = any (abilities) or new.value is null or new.value not between 20 and 30 then
        raise exception 'ability_max needs an ability and a maximum 20-30' using errcode = '22023'; end if;
    when 'ability_bonus' then
      if not (v_kind = 'asi' or (new.target = any (abilities) and new.value between 1 and 4)) then
        raise exception 'ability_bonus needs an ability and a value, or an asi choice' using errcode = '22023'; end if;
    when 'ac_bonus', 'initiative_bonus', 'speed_bonus', 'carrying_capacity_bonus', 'extra_attack' then
      if new.value is null and not new.data ? 'scale' then raise exception '% needs a value', new.effect_type using errcode = '22023'; end if;
    when 'attack_bonus', 'damage_bonus' then
      if new.value is null and not new.data ? 'scale' then raise exception '% needs a value', new.effect_type using errcode = '22023'; end if;
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
    if not v_kind = any (array['armor', 'shield', 'weapon', 'state', 'ability']) then
      raise exception 'Unknown effect condition "%"', v_kind using errcode = '22023';
    end if;
  end loop;
  if new.conditions ? 'armor' and new.conditions ->> 'armor' not in ('worn', 'none', 'not_heavy') then
    raise exception 'armor condition must be worn, none or not_heavy' using errcode = '22023'; end if;
  if new.conditions ? 'shield' and new.conditions ->> 'shield' not in ('worn', 'none') then
    raise exception 'shield condition must be worn or none' using errcode = '22023'; end if;
  if new.conditions ? 'ability' and new.conditions ->> 'ability' not in ('str', 'dex', 'con', 'int', 'wis', 'cha') then
    raise exception 'ability condition must be an ability' using errcode = '22023'; end if;
  if new.conditions ? 'state' and not exists (select 1 from public.class_feature_states s where s.key = new.conditions ->> 'state') then
    raise exception 'Unknown state "%" (declare it in class_feature_states first)', new.conditions ->> 'state' using errcode = '22023'; end if;
  return new;
end;
$$;

drop function if exists public.remove_character_companion(uuid);
drop function if exists public.update_character_companion(uuid, jsonb);
drop function if exists public.add_character_companion(uuid, text, text, text, int);
drop function if exists public.end_transformation(uuid);
drop function if exists public.change_transformation_hp(uuid, int);
drop function if exists public.start_transformation(uuid, text);
drop function if exists public.get_character_transformation(uuid);
drop function if exists public._transform_refusal(jsonb, int, public.creatures);
drop function if exists public._character_transform_rules(uuid);
drop table if exists public.character_companions;
drop table if exists public.character_transformations;
drop table if exists public.creatures;

do $$
begin
  if to_regclass('supabase_migrations.schema_migrations') is not null then
    delete from supabase_migrations.schema_migrations where version = '20261017000800';
  end if;
end $$;

commit;
