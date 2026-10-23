-- =============================================================================
-- Creatures and transformations (generic engines):
--   * creatures: catalog of stat blocks (SRD 5.1, CC-BY-4.0; mechanics only, no descriptions), seeded by
--     supabase/seed/creatures.sql
--   * effect transform_form: a class feature lets the character take the shape of catalog creatures, paid from a resource
--     (data.resource, data.cost) and limited by creature type or a list of creatures (data.creature_types | data.creature_ids),
--     a challenge rating table by class level (data.max_cr_by_level) and movement limits (data.no_fly_below / no_swim_below).
--     Several rules for the same resource combine: a form is allowed when any rule allows it, at the lowest cost.
--   * character_transformations: the form a character is in (one at a time) with its own hit points; damage that drops
--     the form to 0 ends it and the excess carries over to the character's hit points
--   * character_companions: creature instances that belong to a character (familiar, steed, companion, custom), with
--     their own hit points and notes
--   * RPCs get_character_transformation, start_transformation, change_transformation_hp, end_transformation,
--     add_character_companion, update_character_companion, remove_character_companion (auth.uid(), RLS-checked, locked)
-- =============================================================================

create table public.creatures (
  id                    text primary key check (id ~ '^[a-z0-9]+(-[a-z0-9]+)*$'),
  name                  text not null check (length(name) between 1 and 120),
  size                  text not null check (size in ('Tiny', 'Small', 'Medium', 'Large', 'Huge', 'Gargantuan')),
  creature_type         text not null,
  subtype               text,
  alignment             text,
  armor_class           int not null check (armor_class between 0 and 40),
  armor_type            text,
  hit_points            int not null check (hit_points between 1 and 2000),
  hit_dice              text,
  speed                 jsonb not null default '{}'::jsonb check (jsonb_typeof(speed) = 'object'),
  abilities             jsonb not null check (jsonb_typeof(abilities) = 'object'),
  saving_throws         jsonb not null default '{}'::jsonb,
  skills                jsonb not null default '{}'::jsonb,
  senses                jsonb not null default '{}'::jsonb,
  languages             text,
  challenge_rating      numeric(5, 3) not null check (challenge_rating >= 0),
  xp                    int,
  proficiency_bonus     int,
  damage_vulnerabilities text[] not null default '{}',
  damage_resistances    text[] not null default '{}',
  damage_immunities     text[] not null default '{}',
  condition_immunities  text[] not null default '{}',
  traits                jsonb not null default '[]'::jsonb check (jsonb_typeof(traits) = 'array'),
  actions               jsonb not null default '[]'::jsonb check (jsonb_typeof(actions) = 'array'),
  reactions             jsonb not null default '[]'::jsonb check (jsonb_typeof(reactions) = 'array'),
  legendary             boolean not null default false,
  content_scope         text not null default 'official' check (content_scope in ('official', 'test')),
  source_label          text not null,
  source_url            text,
  license               text
);
create index creatures_type_cr on public.creatures (creature_type, challenge_rating);
alter table public.creatures enable row level security;
create policy "creatures_read" on public.creatures for select to anon, authenticated using (true);
revoke all on public.creatures from anon, authenticated;
grant select on public.creatures to anon, authenticated;

create table public.character_transformations (
  character_id        uuid primary key references public.characters (id) on delete cascade,
  character_class_id  uuid not null references public.character_classes (id) on delete cascade,
  resource_key        text not null,
  creature_id         text not null references public.creatures (id),
  cost                int not null default 1,
  hp_max              int not null check (hp_max > 0),
  hp_current          int not null check (hp_current between 0 and hp_max),
  started_at          timestamptz not null default now(),
  started_by          uuid references auth.users (id) on delete set null
);
alter table public.character_transformations enable row level security;
create policy "character_transformations_read" on public.character_transformations for select to authenticated
  using (public.can_access_character(character_id));
revoke all on public.character_transformations from anon, authenticated;
grant select on public.character_transformations to authenticated;

create table public.character_companions (
  id            uuid primary key default gen_random_uuid(),
  character_id  uuid not null references public.characters (id) on delete cascade,
  creature_id   text references public.creatures (id),
  name          text not null check (length(btrim(name)) between 1 and 80),
  source        text check (length(source) <= 120),
  hp_max        int not null check (hp_max between 1 and 2000),
  hp_current    int not null check (hp_current >= 0),
  notes         text check (length(notes) <= 2000),
  active        boolean not null default true,
  created_at    timestamptz not null default now(),
  created_by    uuid references auth.users (id) on delete set null,
  check (hp_current <= hp_max)
);
create index character_companions_character on public.character_companions (character_id);
alter table public.character_companions enable row level security;
create policy "character_companions_read" on public.character_companions for select to authenticated
  using (public.can_access_character(character_id));
revoke all on public.character_companions from anon, authenticated;
grant select on public.character_companions to authenticated;

alter table public.class_feature_effects drop constraint class_feature_effects_effect_type_check;
alter table public.class_feature_effects add constraint class_feature_effects_effect_type_check check (effect_type in (
  'proficiency', 'expertise', 'ability_bonus', 'ac_bonus', 'ac_formula', 'attack_bonus', 'damage_bonus',
  'save_bonus', 'initiative_bonus', 'speed_bonus', 'resistance', 'immunity', 'skill_advantage',
  'skill_disadvantage', 'carrying_capacity_bonus', 'spell', 'attack', 'extra_attack', 'critical_range',
  'attunement_limit', 'ritual_casting', 'spellcasting_source', 'resource_modifier', 'informational',
  'skill_half_proficiency', 'sense', 'attack_rider', 'save_advantage', 'check_advantage', 'ability_max',
  'save_bonus_ability', 'condition_immunity', 'spell_list_addition', 'save_dc',
  'transform_form'));

-- feature category 'transformation' (Wild Shape and its relatives get their own group on the class page)
alter table public.class_feature_versions drop constraint class_feature_versions_category_check;
alter table public.class_feature_versions add constraint class_feature_versions_category_check check (category in (
  'combat', 'defense', 'resource', 'spellcasting', 'proficiency', 'exploration',
  'social', 'utility', 'choice', 'subclass', 'asi', 'transformation'));

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
    when 'transform_form' then
      if coalesce((new.data ->> 'cost')::int, 0) < 1 or not exists (select 1 from public.class_feature_resources r where r.id = new.data ->> 'resource')
         or not (jsonb_typeof(new.data -> 'creature_types') = 'array' or jsonb_typeof(new.data -> 'creature_ids') = 'array')
         or (new.data ? 'max_cr_by_level' and jsonb_typeof(new.data -> 'max_cr_by_level') <> 'array') then
        raise exception 'transform_form needs data.resource (a class feature resource), data.cost >= 1, data.creature_types or data.creature_ids, optional data.max_cr_by_level'
          using errcode = '22023'; end if;
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

-- ---- transformation rules of a character and the forms they allow ------------------------------------------------------------
-- One row per active transform_form effect: the resource key, the class level and the rule.
create function public._character_transform_rules(p_character uuid)
returns table (character_class_id uuid, class_level int, resource_key text, resource_id text, feature_name text, rule jsonb)
language sql stable
set search_path = public, pg_temp
as $$
  select x.character_class_id, x.class_level, 'f:' || x.character_class_id || ':' || (x.data ->> 'resource'), x.data ->> 'resource',
         x.feature_name, x.data
  from public._character_class_effects(p_character) x
  where x.active and x.effect_type = 'transform_form';
$$;

-- Whether one rule allows one creature at a class level: null when allowed, otherwise the reason.
create function public._transform_refusal(p_rule jsonb, p_level int, c public.creatures)
returns text
language sql immutable
set search_path = public, pg_temp
as $$
  select case
    when not (coalesce(p_rule -> 'creature_types' ? c.creature_type, false) or coalesce(p_rule -> 'creature_ids' ? c.id, false)) then 'not_allowed_type'
    when p_rule ? 'max_cr_by_level' and c.challenge_rating > coalesce((select (e ->> 1)::numeric from jsonb_array_elements(p_rule -> 'max_cr_by_level') e
                                                                    where (e ->> 0)::int <= p_level order by (e ->> 0)::int desc limit 1), -1)
      then 'challenge_rating'
    when coalesce((c.speed ->> 'fly')::int, 0) > 0 and p_level < coalesce((p_rule ->> 'no_fly_below')::int, 0) then 'flying_speed'
    when coalesce((c.speed ->> 'swim')::int, 0) > 0 and p_level < coalesce((p_rule ->> 'no_swim_below')::int, 0) then 'swimming_speed'
  end;
$$;

create function public.get_character_transformation(p_character uuid)
returns jsonb
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
declare res jsonb; act jsonb;
begin
  if auth.uid() is null or not public.can_access_character(p_character) then
    raise exception 'Character not found' using errcode = '42501';
  end if;
  res := coalesce(public.get_character_resources(p_character) -> 'resources', '[]');
  select jsonb_build_object('creature_id', t.creature_id, 'name', c.name, 'hp_current', t.hp_current, 'hp_max', t.hp_max,
           'resource_key', t.resource_key, 'cost', t.cost, 'started_at', t.started_at, 'creature', to_jsonb(c))
  into act from public.character_transformations t join public.creatures c on c.id = t.creature_id where t.character_id = p_character;
  return jsonb_build_object('character_id', p_character, 'active', act,
    'resources', coalesce((select jsonb_agg(distinct r) from public._character_transform_rules(p_character) tr
                            join jsonb_array_elements(res) r on r ->> 'key' = tr.resource_key), '[]'),
    'rules', coalesce((select jsonb_agg(jsonb_build_object('resource_key', tr.resource_key, 'feature_name', tr.feature_name,
                         'class_level', tr.class_level, 'cost', (tr.rule ->> 'cost')::int,
                         'max_cr', (select (e ->> 1)::numeric from jsonb_array_elements(tr.rule -> 'max_cr_by_level') e
                                    where (e ->> 0)::int <= tr.class_level order by (e ->> 0)::int desc limit 1),
                         'creature_types', tr.rule -> 'creature_types', 'creature_ids', tr.rule -> 'creature_ids'))
                       from public._character_transform_rules(p_character) tr), '[]'),
    'options', coalesce((
      select jsonb_agg(o order by (o ->> 'challenge_rating')::numeric, o ->> 'name') from (
        select jsonb_build_object('id', c.id, 'name', c.name, 'size', c.size, 'creature_type', c.creature_type,
                 'challenge_rating', c.challenge_rating, 'armor_class', c.armor_class, 'hit_points', c.hit_points, 'speed', c.speed,
                 'allowed', bool_or(public._transform_refusal(tr.rule, tr.class_level, c) is null),
                 'cost', min((tr.rule ->> 'cost')::int) filter (where public._transform_refusal(tr.rule, tr.class_level, c) is null),
                 'resource_key', min(tr.resource_key) filter (where public._transform_refusal(tr.rule, tr.class_level, c) is null),
                 'reason', case when bool_or(public._transform_refusal(tr.rule, tr.class_level, c) is null) then null
                                else min(public._transform_refusal(tr.rule, tr.class_level, c)) end) as o
        from public.creatures c cross join public._character_transform_rules(p_character) tr
        where coalesce(tr.rule -> 'creature_types' ? c.creature_type, false) or coalesce(tr.rule -> 'creature_ids' ? c.id, false)
        group by c.id) q), '[]'));
end;
$$;

-- Take a form: allowed by an active rule (lowest cost), paid from the rule's resource, one form at a time.
create function public.start_transformation(p_character uuid, p_creature text)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare c public.creatures; best record;
begin
  if auth.uid() is null or not public.can_access_character(p_character) then
    raise exception 'Character not found' using errcode = '42501';
  end if;
  perform 1 from public.characters where id = p_character for update;
  if exists (select 1 from public.character_transformations where character_id = p_character) then
    raise exception 'End the current form first' using errcode = '22023';
  end if;
  select * into c from public.creatures where id = p_creature;
  if not found then raise exception 'Unknown creature "%"', p_creature using errcode = '22023'; end if;
  select tr.*, (tr.rule ->> 'cost')::int as cost into best from public._character_transform_rules(p_character) tr
  where public._transform_refusal(tr.rule, tr.class_level, c) is null order by (tr.rule ->> 'cost')::int limit 1;
  if best.resource_key is null then
    raise exception '% is not a form you can take: %', c.name,
      coalesce((select case min(public._transform_refusal(tr.rule, tr.class_level, c))
                         when 'challenge_rating' then 'its challenge rating is too high for your level'
                         when 'flying_speed' then 'forms with a flying speed are not allowed at your level'
                         when 'swimming_speed' then 'forms with a swimming speed are not allowed at your level'
                         else 'it is not a kind of creature you can become' end
                from public._character_transform_rules(p_character) tr),
               'you have no feature that lets you change shape') using errcode = '22023';
  end if;
  perform public.expend_character_resource(p_character, best.resource_key, best.cost);
  insert into public.character_transformations (character_id, character_class_id, resource_key, creature_id, cost, hp_max, hp_current, started_by)
  values (p_character, best.character_class_id, best.resource_key, c.id, best.cost, c.hit_points, c.hit_points, auth.uid());
  return public.get_character_transformation(p_character);
end;
$$;

-- Damage (negative) or healing (positive) of the form. At 0 the form ends and the rest of the damage carries over to the
-- character's hit points (never below 0).
create function public.change_transformation_hp(p_character uuid, p_delta int)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare t public.character_transformations; nv int; carry int := 0; ended boolean := false;
begin
  if auth.uid() is null or not public.can_access_character(p_character) then
    raise exception 'Character not found' using errcode = '42501';
  end if;
  if p_delta is null or p_delta = 0 or abs(p_delta) > 10000 then raise exception 'Give a damage or healing amount' using errcode = '22023'; end if;
  select * into t from public.character_transformations where character_id = p_character for update;
  if not found then raise exception 'The character is not transformed' using errcode = '22023'; end if;
  nv := t.hp_current + p_delta;
  if nv <= 0 then
    carry := -nv; ended := true;
    delete from public.character_transformations where character_id = p_character;
    update public.characters set hp_current = greatest(0, coalesce(hp_current, 0) - carry) where id = p_character;
  else
    update public.character_transformations set hp_current = least(nv, hp_max) where character_id = p_character;
  end if;
  return public.get_character_transformation(p_character) || jsonb_build_object('ended', ended, 'carryover', carry);
end;
$$;

create function public.end_transformation(p_character uuid)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
begin
  if auth.uid() is null or not public.can_access_character(p_character) then
    raise exception 'Character not found' using errcode = '42501';
  end if;
  delete from public.character_transformations where character_id = p_character;
  if not found then raise exception 'The character is not transformed' using errcode = '22023'; end if;
  return public.get_character_transformation(p_character);
end;
$$;

-- ---- companions ---------------------------------------------------------------------------------------------------------------
create function public.add_character_companion(p_character uuid, p_creature text default null, p_name text default null,
                                               p_source text default null, p_hp_max int default null)
returns uuid
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare c public.creatures; hp int; nid uuid;
begin
  if auth.uid() is null or not public.can_access_character(p_character) then
    raise exception 'Character not found' using errcode = '42501';
  end if;
  if p_creature is not null then
    select * into c from public.creatures where id = p_creature;
    if not found then raise exception 'Unknown creature "%"', p_creature using errcode = '22023'; end if;
  elsif coalesce(btrim(p_name), '') = '' or p_hp_max is null then
    raise exception 'A custom companion needs a name and hit points' using errcode = '22023';
  end if;
  hp := coalesce(p_hp_max, c.hit_points);
  if hp not between 1 and 2000 then raise exception 'Hit points must be 1-2000' using errcode = '22023'; end if;
  if (select count(*) from public.character_companions where character_id = p_character) >= 50 then
    raise exception 'A character can have at most 50 companions' using errcode = '22023';
  end if;
  insert into public.character_companions (character_id, creature_id, name, source, hp_max, hp_current, created_by)
  values (p_character, c.id, coalesce(nullif(btrim(p_name), ''), c.name), nullif(btrim(p_source), ''), hp, hp, auth.uid())
  returning id into nid;
  return nid;
end;
$$;

-- p_patch: {"name", "notes", "hp_current", "hp_max", "active"} (any subset); hit points are clamped to 0 .. maximum.
create function public.update_character_companion(p_companion uuid, p_patch jsonb)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare x public.character_companions;
begin
  select * into x from public.character_companions where id = p_companion for update;
  if not found or auth.uid() is null or not public.can_access_character(x.character_id) then
    raise exception 'Companion not found' using errcode = '42501';
  end if;
  if jsonb_typeof(p_patch) is distinct from 'object' then raise exception 'Changes must be an object' using errcode = '22023'; end if;
  if p_patch ? 'hp_max' and coalesce((p_patch ->> 'hp_max')::int, 0) not between 1 and 2000 then
    raise exception 'Hit points must be 1-2000' using errcode = '22023'; end if;
  if p_patch ? 'name' and coalesce(btrim(p_patch ->> 'name'), '') = '' then raise exception 'A companion needs a name' using errcode = '22023'; end if;
  update public.character_companions set
    name = coalesce(nullif(btrim(p_patch ->> 'name'), ''), name),
    notes = case when p_patch ? 'notes' then nullif(btrim(p_patch ->> 'notes'), '') else notes end,
    hp_max = coalesce((p_patch ->> 'hp_max')::int, hp_max),
    hp_current = least(greatest(coalesce((p_patch ->> 'hp_current')::int, hp_current), 0), coalesce((p_patch ->> 'hp_max')::int, hp_max)),
    active = coalesce((p_patch ->> 'active')::boolean, active)
  where id = p_companion returning * into x;
  return to_jsonb(x);
end;
$$;

create function public.remove_character_companion(p_companion uuid)
returns void
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare cid uuid;
begin
  select character_id into cid from public.character_companions where id = p_companion for update;
  if cid is null or auth.uid() is null or not public.can_access_character(cid) then
    raise exception 'Companion not found' using errcode = '42501';
  end if;
  delete from public.character_companions where id = p_companion;
end;
$$;

revoke all on function public._character_transform_rules(uuid) from public, anon, authenticated;
revoke all on function public._transform_refusal(jsonb, int, public.creatures) from public, anon, authenticated;
revoke all on function public.get_character_transformation(uuid) from public, anon;
revoke all on function public.start_transformation(uuid, text) from public, anon;
revoke all on function public.change_transformation_hp(uuid, int) from public, anon;
revoke all on function public.end_transformation(uuid) from public, anon;
revoke all on function public.add_character_companion(uuid, text, text, text, int) from public, anon;
revoke all on function public.update_character_companion(uuid, jsonb) from public, anon;
revoke all on function public.remove_character_companion(uuid) from public, anon;
grant execute on function public.get_character_transformation(uuid) to authenticated;
grant execute on function public.start_transformation(uuid, text) to authenticated;
grant execute on function public.change_transformation_hp(uuid, int) to authenticated;
grant execute on function public.end_transformation(uuid) to authenticated;
grant execute on function public.add_character_companion(uuid, text, text, text, int) to authenticated;
grant execute on function public.update_character_companion(uuid, jsonb) to authenticated;
grant execute on function public.remove_character_companion(uuid) to authenticated;
