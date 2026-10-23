-- =============================================================================
-- Spellcasting class extensions (Wizard / Cleric / Bard / Sorcerer checkpoint). Reusable mechanics only:
--  * spellbook: how a spell entered the spellbook (starting, level up, copied, scroll, other), at which level, notes;
--    get_character_spellbook adds a spellbook summary per spellbook source (spells in the book, free spells expected by
--    the class level, copied spells) -- set_character_spell_acquisition records it
--  * class_feature_resources.config: slot_recovery {budget formula, max_slot_level, max_slots?, also_expend?: resource id}
--    (Arcane Recovery, Natural Recovery, Harness Divine Power)
--    and conversion {create_costs, max_created_level} (Font of Magic); recharge_by_level [[level, recharge], ...]
--    (Bardic Inspiration: long rest, then short or long rest from Font of Inspiration)
--  * spell choices: config.in_spellbook (the spell must be in this class's spellbook), config.max_spell_level = 'castable'
--    (the highest spell level THIS class can cast at its level; never the combined multiclass slots),
--    config.spell_lists [list, ...] (any of them)
--  * RPCs: recover_spell_slots (spend the feature use, restore expended slots within the budget, one transaction),
--    convert_spell_slot (slot -> points, points -> temporary slot), use_temporary_spell_slot / restore_temporary_spell_slot
-- Rollback: supabase/rollback/rollback_spellcasting_class_extensions.sql.
-- =============================================================================

alter table public.character_spells
  add column acquisition       text check (acquisition in ('starting', 'level_up', 'copied', 'scroll', 'feature', 'other')),
  add column acquired_at_level int  check (acquired_at_level between 1 and 20),
  add column acquisition_notes text check (length(acquisition_notes) <= 300);
comment on column public.character_spells.acquisition is
  'How the spell entered a spellbook (Wizard): starting (6 at level 1), level_up (2 per Wizard level), copied (found and copied: '
  '2 hours and 50 gp per spell level), scroll, feature, other. Display and review only; nothing is enforced.';

alter table public.class_feature_resources
  add column config            jsonb not null default '{}'::jsonb check (jsonb_typeof(config) = 'object'),
  add column recharge_by_level jsonb check (recharge_by_level is null or jsonb_typeof(recharge_by_level) = 'array');
comment on column public.class_feature_resources.config is
  'slot_recovery: {"budget": <resource formula>, "max_slot_level": n} (restore expended slots whose levels add up to the budget); '
  'conversion: {"create_costs": {"1": 2, ...}, "max_created_level": 5} (spell slot <-> points).';
comment on column public.class_feature_resources.recharge_by_level is '[[class level, recharge], ...]: the recharge rule from that level on.';

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

create or replace function public._character_feature_resources(p_character uuid, p_mods jsonb)
returns jsonb
language sql stable
set search_path = public, pg_temp
as $$
  with ul as (select * from public._character_feature_unlocks(p_character)),
  ch as (select * from public._character_feature_choice_rows(p_character)),
  li as (select public._character_level_info(p_character) as li),
  g as (
    select distinct on (ul.character_class_id, r.id) ul.character_class_id, ul.class_id, ul.class_name, ul.class_level, ul.unlock_id,
           ul.unlock_level, ul.feature_name, ul.origin, ul.active as feature_active, r.*
    from ul join public.class_feature_resources r on r.feature_version_id = ul.feature_version_id
    where r.option_choice_id is null
       or exists (select 1 from ch where ch.character_class_id = ul.character_class_id and ch.unlock_id = ul.unlock_id
                    and ch.choice_id = r.option_choice_id and ch.open and r.option_id = any (ch.vals))
    order by ul.character_class_id, r.id, ul.active desc, ul.unlock_level),
  m as (
    select g.*, s.id as state_id, coalesce(s.expended, 0) as expended, coalesce(s.temporary_bonus, 0) as temporary_bonus,
           coalesce(s.max_adjustment, 0) as max_adjustment, s.last_recovered_at,
           g.feature_active and g.class_level >= g.min_level as res_active,
           coalesce((select e ->> 1 from jsonb_array_elements(g.recharge_by_level) e where (e ->> 0)::int <= g.class_level
                     order by (e ->> 0)::int desc limit 1), g.recharge) as eff_recharge,
           case when g.max_formula is null then null else public._resource_max(g.max_formula, jsonb_build_object(
             'total_level', (li.li ->> 'total_level')::int, 'class_level', g.class_level,
             'proficiency_bonus', (li.li ->> 'proficiency_bonus')::int, 'mods', p_mods)) end as mx,
           case when g.short_rest_recovery is null then null else public._resource_max(g.short_rest_recovery, jsonb_build_object(
             'total_level', (li.li ->> 'total_level')::int, 'class_level', g.class_level,
             'proficiency_bonus', (li.li ->> 'proficiency_bonus')::int, 'mods', p_mods)) end as sr
    from g cross join li
    left join public.character_resources s on s.character_class_id = g.character_class_id and s.feature_resource_id = g.id)
  select coalesce(jsonb_agg(jsonb_build_object(
           'key', 'f:' || m.character_class_id || ':' || m.id, 'kind', 'feature', 'resource_id', m.id, 'name', m.name,
           'resource_type', m.resource_type, 'character_class_id', m.character_class_id, 'class_id', m.class_id,
           'class_name', m.class_name, 'class_level', m.class_level, 'unlock_id', m.unlock_id, 'origin', m.origin,
           'feature_version_id', m.feature_version_id, 'feature_name', m.feature_name, 'automation', m.automation,
           'active', m.res_active, 'inactive_reason', case when not m.feature_active then 'feature_inactive'
                                                           when m.class_level < m.min_level then 'level' end,
           'min_level', m.min_level, 'recharge', m.eff_recharge, 'base_recharge', m.recharge, 'recharge_by_level', m.recharge_by_level,
           'config', m.config,
           'slot_recovery_budget', case when m.config ? 'slot_recovery' then (public._resource_max(m.config -> 'slot_recovery' -> 'budget',
             jsonb_build_object('total_level', (li.li ->> 'total_level')::int, 'class_level', m.class_level,
               'proficiency_bonus', (li.li ->> 'proficiency_bonus')::int, 'mods', p_mods)) ->> 'max')::int end,
           'short_rest_recovery', case when m.sr is null then null else (m.sr ->> 'max')::int end,
           'die', coalesce((select e ->> 1 from jsonb_array_elements(m.die_by_level) e where (e ->> 0)::int <= m.class_level
                            order by (e ->> 0)::int desc limit 1), m.die),
           'max_formula', m.max_formula, 'max_known', m.mx is not null,
           'base_max', (m.mx ->> 'max')::int, 'unlimited', coalesce((m.mx ->> 'unlimited')::boolean, false),
           'max_adjustment', m.max_adjustment, 'temporary_bonus', m.temporary_bonus,
           'max', case when m.mx is null or (m.mx ->> 'unlimited')::boolean then null
                       else greatest((m.mx ->> 'max')::int + m.max_adjustment, 0) + m.temporary_bonus end,
           'expended', m.expended,
           'remaining', case when m.mx is null or (m.mx ->> 'unlimited')::boolean then null
                             else greatest(greatest((m.mx ->> 'max')::int + m.max_adjustment, 0) + m.temporary_bonus - m.expended, 0) end,
           'clamped', m.mx is not null and not (m.mx ->> 'unlimited')::boolean
                      and m.expended > greatest((m.mx ->> 'max')::int + m.max_adjustment, 0) + m.temporary_bonus,
           'state_id', m.state_id, 'last_recovered_at', m.last_recovered_at,
           'activation_note', m.activation_note, 'notes', m.notes)
           order by m.class_id, m.sort_order, m.name), '[]')
  from m cross join (select public._character_level_info(p_character) as li) li
  where m.res_active or m.state_id is not null;
$$;

create or replace function public._cf_choice_error(p_character uuid, p_character_class uuid, p_unlock text, p_choice public.class_feature_choices,
                                        p_values text[], p_max int, p_strict boolean)
returns text
language plpgsql stable
set search_path = public, pg_temp
as $$
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

-- ---- write path ----------------------------------------------------------------------------------------------------------------
-- How a spell entered a spellbook (display and review; nothing is enforced).
create function public.set_character_spell_acquisition(p_character_spell uuid, p_acquisition text, p_level int default null,
                                                       p_notes text default null)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare g public.character_spells;
begin
  select * into g from public.character_spells where id = p_character_spell;
  if not found or auth.uid() is null or not public.can_access_character(g.character_id) then
    raise exception 'Spell not found' using errcode = '42501';
  end if;
  if p_acquisition is not null and p_acquisition not in ('starting', 'level_up', 'copied', 'scroll', 'feature', 'other') then
    raise exception 'Unknown acquisition "%"', p_acquisition using errcode = '22023';
  end if;
  update public.character_spells set acquisition = p_acquisition, acquired_at_level = p_level,
         acquisition_notes = nullif(btrim(p_notes), ''), updated_at = now()
  where id = p_character_spell;
  return public.get_character_spellbook(g.character_id);
end;
$$;

-- Arcane Recovery / Natural Recovery: one use of the feature restores expended standard slots whose levels add up to at
-- most the budget, each at most max_slot_level. All or nothing, one transaction, the character row is locked.
create function public.recover_spell_slots(p_character uuid, p_resource_key text, p_slot_levels int[], p_reason text default null)
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

-- Font of Magic: spend a spell slot to regain points (up to the maximum), or spend points to create a temporary slot
-- (gone after a long rest). One transaction, the character row is locked.
create function public.convert_spell_slot(p_character uuid, p_resource_key text, p_direction text, p_slot_level int,
                                          p_pool text default 'standard')
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare me jsonb; cost int; gain int; pact jsonb;
begin
  if auth.uid() is null or not public.can_access_character(p_character) then
    raise exception 'Character not found' using errcode = '42501';
  end if;
  perform 1 from public.characters where id = p_character for update;
  select x into me from jsonb_array_elements(public._character_feature_resources(p_character, public._character_mods(p_character))) x
  where x ->> 'key' = p_resource_key;
  if me is null or not (me -> 'config') ? 'conversion' then
    raise exception 'This resource cannot be converted to or from spell slots' using errcode = '22023';
  end if;
  if not (me ->> 'active')::boolean then raise exception '% is not available', me ->> 'name' using errcode = '22023'; end if;
  if p_direction = 'points_to_slot' then
    if p_slot_level is null or p_slot_level < 1 or p_slot_level > (me -> 'config' -> 'conversion' ->> 'max_created_level')::int then
      raise exception 'You can create spell slots of level 1 to %', me -> 'config' -> 'conversion' ->> 'max_created_level' using errcode = '22023';
    end if;
    cost := (me -> 'config' -> 'conversion' -> 'create_costs' ->> p_slot_level::text)::int;
    if coalesce((me ->> 'remaining')::int, 0) < cost then
      raise exception 'A level % slot costs % %; % left', p_slot_level, cost, me ->> 'name', coalesce((me ->> 'remaining')::int, 0) using errcode = '22023';
    end if;
    perform public._resource_change(p_character, p_resource_key, 'expend', cost, null, null, null, format('Created a level %s spell slot', p_slot_level));
    insert into public.character_temporary_spell_slots (character_id, slot_level, quantity, source_type, source_label, expires_on, created_by)
    values (p_character, p_slot_level, 1, 'feature', left(me ->> 'feature_name', 80), 'long_rest', auth.uid());
    insert into public.character_resource_events (character_id, event_type, pool, slot_level, amount, reason, details)
    values (p_character, 'restore', 'temporary', p_slot_level, 1, format('%s: created from %s %s', me ->> 'feature_name', cost, me ->> 'name'),
            jsonb_build_object('resource_key', p_resource_key, 'cost', cost));
  elsif p_direction = 'slot_to_points' then
    if p_pool not in ('standard', 'pact') then raise exception 'Unknown slot pool "%"', p_pool using errcode = '22023'; end if;
    if p_pool = 'pact' then
      pact := public.get_character_spell_slots(p_character) -> 'pact_magic';
      p_slot_level := (pact ->> 'slot_level')::int;
    end if;
    gain := least(coalesce(p_slot_level, 0), coalesce((me ->> 'expended')::int, 0));
    if gain < 1 then raise exception '% is already full', me ->> 'name' using errcode = '22023'; end if;
    perform public._slot_change(p_character, p_pool, p_slot_level, 1, format('Converted to %s', me ->> 'name'));
    perform public._resource_change(p_character, p_resource_key, 'restore', gain, null, null, null,
                                    format('Gained from a level %s spell slot', p_slot_level));
  else
    raise exception 'Unknown direction "%" (slot_to_points or points_to_slot)', p_direction using errcode = '22023';
  end if;
  return jsonb_build_object('resource', (select x from jsonb_array_elements((public.get_character_resources(p_character)) -> 'resources') x
                                         where x ->> 'key' = p_resource_key),
                            'slots', public.get_character_spell_slots(p_character));
end;
$$;

-- Temporary slots (Font of Magic, items, manual): spend or give back one slot.
create function public._temporary_slot_change(p_character uuid, p_slot uuid, p_delta int)
returns jsonb
language plpgsql
set search_path = public, pg_temp
as $$
declare t public.character_temporary_spell_slots;
begin
  if auth.uid() is null or not public.can_access_character(p_character) then
    raise exception 'Character not found' using errcode = '42501';
  end if;
  perform 1 from public.characters where id = p_character for update;
  select * into t from public.character_temporary_spell_slots where id = p_slot and character_id = p_character for update;
  if not found then raise exception 'Temporary slot not found' using errcode = '42501'; end if;
  if p_delta > 0 and t.expended >= t.quantity then raise exception 'This temporary slot is already used' using errcode = '22023'; end if;
  if p_delta < 0 and t.expended <= 0 then raise exception 'Nothing to restore' using errcode = '22023'; end if;
  update public.character_temporary_spell_slots set expended = expended + p_delta where id = p_slot;
  insert into public.character_resource_events (character_id, event_type, pool, slot_level, amount, expended_before, expended_after, reason)
  values (p_character, case when p_delta > 0 then 'expend' else 'restore' end, 'temporary', t.slot_level, 1, t.expended, t.expended + p_delta, t.source_label);
  return public.get_character_spell_slots(p_character);
end;
$$;
create function public.use_temporary_spell_slot(p_character uuid, p_slot uuid)
returns jsonb language sql security definer set search_path = public, pg_temp
as $$ select public._temporary_slot_change(p_character, p_slot, 1) $$;
create function public.restore_temporary_spell_slot(p_character uuid, p_slot uuid)
returns jsonb language sql security definer set search_path = public, pg_temp
as $$ select public._temporary_slot_change(p_character, p_slot, -1) $$;

revoke all on function public.set_character_spell_acquisition(uuid, text, int, text), public.recover_spell_slots(uuid, text, int[], text),
  public.convert_spell_slot(uuid, text, text, int, text), public._temporary_slot_change(uuid, uuid, int),
  public.use_temporary_spell_slot(uuid, uuid), public.restore_temporary_spell_slot(uuid, uuid) from public, anon;
revoke all on function public._temporary_slot_change(uuid, uuid, int) from authenticated;
grant execute on function public.set_character_spell_acquisition(uuid, text, int, text), public.recover_spell_slots(uuid, text, int[], text),
  public.convert_spell_slot(uuid, text, text, int, text), public.use_temporary_spell_slot(uuid, uuid),
  public.restore_temporary_spell_slot(uuid, uuid) to authenticated;
