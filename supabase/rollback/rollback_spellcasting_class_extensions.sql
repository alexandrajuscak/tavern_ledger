-- =============================================================================
-- Rollback of 20261017000300_spellcasting_class_extensions.sql ONLY. Restores class_feature_definitions_before_write and
-- _cf_choice_error (20261017000100 definitions), _character_feature_resources and get_character_spellbook (20261015001800),
-- drops the new RPCs and columns (spellbook acquisition records are lost; spells themselves are kept). Temporary slots stay.
-- Refuses while catalog resources use config / recharge_by_level (run rollback_class_catalog.sql first).
-- =============================================================================
begin;

do $$
begin
  if exists (select 1 from public.class_feature_resources where config <> '{}'::jsonb or recharge_by_level is not null) then
    raise exception 'Official class content still uses the 20261017000300 extensions; run rollback_class_catalog.sql first';
  end if;
end $$;

drop function if exists public.set_character_spell_acquisition(uuid, text, int, text), public.recover_spell_slots(uuid, text, int[], text),
  public.convert_spell_slot(uuid, text, text, int, text), public.use_temporary_spell_slot(uuid, uuid),
  public.restore_temporary_spell_slot(uuid, uuid), public._temporary_slot_change(uuid, uuid, int);

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
           'min_level', m.min_level, 'recharge', m.recharge,
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
  from m
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
        if cfg ? 'max_spell_level' and sv.level > (cfg ->> 'max_spell_level')::int then
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

alter table public.class_feature_resources drop column if exists config, drop column if exists recharge_by_level;
alter table public.character_spells drop column if exists acquisition, drop column if exists acquired_at_level,
  drop column if exists acquisition_notes;

do $$
begin
  if to_regclass('supabase_migrations.schema_migrations') is not null then
    delete from supabase_migrations.schema_migrations where version = '20261017000300';
  end if;
end $$;

commit;
