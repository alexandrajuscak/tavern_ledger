-- =============================================================================
-- Class engine extensions for the official class catalog (Fighter / Rogue checkpoint and later classes).
-- Reusable mechanics only; no class names in runtime code. Content: supabase/seed/class_features.sql (generated from
-- data/classes/features/*.json by scripts/data-migration/generate_class_feature_seed.py).
--
--  * class version metadata: primary abilities, saving throws, skill choice, raw proficiency lines, starting gold,
--    feature implementation status; subclass catalog status (official / setting / playtest), dependency group,
--    implementation_status 'catalog_only' (the subclass can be chosen; its features are not in the catalog yet)
--  * class_starting_equipment: structured starting equipment options per class version (review flow; never applied
--    automatically to existing characters)
--  * class_feature_versions.category: the sheet groups features by it (combat, defense, resource, ...)
--  * new effect types: skill_half_proficiency (half the proficiency bonus on ability checks without proficiency; optional
--    ability filter, rounding, initiative), sense (blindsight / darkvision / tremorsense / truesight / blindsense),
--    attack_rider (extra damage the player applies when its conditions are met, e.g. once per turn; never added
--    automatically), save_advantage / check_advantage (with an optional situational condition), ability_max
--  * weapon condition "thrown": shown as a conditional bonus on thrown weapons, never added to the melee attack
--  * effect values from a scaling table of the same feature (data.scale = scaling key)
--  * choices: config.distinct_group (an option chosen once cannot be chosen again by another choice of the same group,
--    e.g. fighting styles), expertise in tools (config.tools)
-- Rollback: supabase/rollback/rollback_class_engine_extensions.sql (restores the 20261015001800 definitions).
-- =============================================================================

-- ---- catalog metadata --------------------------------------------------------------------------------------------------
alter table public.class_versions
  add column primary_abilities       text[] not null default '{}',
  add column saving_throws           text[] not null default '{}',
  add column skill_choice            jsonb check (skill_choice is null or jsonb_typeof(skill_choice) = 'object'),
  add column multiclass_skill_choice jsonb check (multiclass_skill_choice is null or jsonb_typeof(multiclass_skill_choice) = 'object'),
  add column proficiency_lines       jsonb not null default '{}'::jsonb check (jsonb_typeof(proficiency_lines) = 'object'),
  add column starting_gold           text check (length(starting_gold) <= 40),
  add column feature_status          text not null default 'not_started'
    check (feature_status in ('not_started', 'in_progress', 'complete')),
  add column feature_notes           text check (length(feature_notes) <= 1000);
comment on column public.class_versions.proficiency_lines is
  'Raw proficiency lines of the class page (armor, weapons, tools, saving throws, skills; multiclass_*). Display only: the '
  'granted proficiencies are class feature effects (applies_to always / primary_class / multiclass).';
comment on column public.class_versions.feature_status is
  'complete = every base feature of levels 1-20 is in the class feature catalog (see docs/CLASS_COVERAGE.md).';

alter table public.subclass_versions
  add column source_status    text not null default 'official'
    check (source_status in ('official', 'setting', 'playtest', 'test_fixture')),
  add column dependency_group text check (dependency_group in ('passive_numeric', 'spell_grant', 'resource_heavy', 'choice_heavy',
    'companion', 'transformation', 'random_table', 'inventory', 'psionic', 'setting')),
  add column feature_notes    text check (length(feature_notes) <= 1000);
alter table public.subclass_versions drop constraint subclass_versions_implementation_status_check;
alter table public.subclass_versions add constraint subclass_versions_implementation_status_check
  check (implementation_status in ('level_only', 'progression_only', 'catalog_only', 'features_partial', 'partial', 'complete'));
comment on column public.subclass_versions.implementation_status is
  'catalog_only: listed and selectable, features not in the catalog yet (tracked by hand); progression_only: spellcasting '
  'numbers only; complete: every subclass feature is in the catalog.';

alter table public.class_feature_versions
  add column category text check (category in ('combat', 'defense', 'resource', 'spellcasting', 'proficiency', 'exploration',
                                                'social', 'utility', 'choice', 'subclass', 'asi'));

-- ---- starting equipment ------------------------------------------------------------------------------------------------
-- One row per option of a choice ("(a) chain mail or (b) leather, longbow, and 20 arrows" = group 1, options a and b).
-- items: [{"item_id": "...", "quantity": n} | {"group": "martial-weapons", "quantity": n, "label": "..."} |
--         {"category": "...", "quantity": n, "label": "..."} | {"unresolved": "raw text"}]
create table public.class_starting_equipment (
  class_version_id text not null references public.class_versions (id) on delete cascade,
  choice_group     int  not null check (choice_group between 1 and 20),
  option_key       text not null check (option_key ~ '^[a-z]$'),
  label            text not null check (length(label) between 1 and 200),
  raw              text not null check (length(raw) between 1 and 400),
  items            jsonb not null default '[]'::jsonb check (jsonb_typeof(items) = 'array'),
  resolved         boolean not null default true,
  primary key (class_version_id, choice_group, option_key)
);
alter table public.class_starting_equipment enable row level security;
create policy "class_starting_equipment_read" on public.class_starting_equipment for select to anon, authenticated using (true);
revoke all on public.class_starting_equipment from anon, authenticated;
grant select on public.class_starting_equipment to anon, authenticated;

-- ---- effect types -----------------------------------------------------------------------------------------------------------
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

create or replace function public._character_class_effects(p_character uuid)
returns table (character_class_id uuid, class_id text, class_name text, class_level int, unlock_id text, feature_version_id text,
               feature_name text, origin text, seq int, pick int, effect_type text, target text, value numeric, value_text text,
               spell_version_id text, min_level int, conditions jsonb, data jsonb, automation text, spellcasting_ability text,
               feature_active boolean, active boolean, inactive_reason text)
language sql stable
set search_path = public, pg_temp
as $$
  with ul as (select * from public._character_feature_unlocks(p_character)),
  cr as (select * from public._cf_class_rows(p_character)),
  eq as (select * from public._cf_equipment(p_character)),
  ch as (select * from public._character_feature_choice_rows(p_character)),
  raw as (
    select ul.character_class_id, ul.class_id, ul.class_name, ul.class_level, ul.unlock_id, ul.feature_version_id, ul.feature_name,
           ul.origin, ul.active as feature_active, ul.is_primary, e.seq, e.effect_type, e.target, e.value, e.value_text,
           e.spell_version_id, e.min_level, e.choice_id, e.option_choice_id, e.option_id, e.applies_to, e.conditions, e.automation, e.data
    from ul join public.class_feature_effects e on e.feature_version_id = ul.feature_version_id
    where e.option_choice_id is null
       or exists (select 1 from ch where ch.character_class_id = ul.character_class_id and ch.unlock_id = ul.unlock_id
                    and ch.choice_id = e.option_choice_id and ch.open and e.option_id = any (ch.vals))),
  expanded as (
    select r.character_class_id, r.class_id, r.class_name, r.class_level, r.unlock_id, r.feature_version_id, r.feature_name, r.origin,
           r.seq, null::int as pick, r.effect_type, r.target, r.value, r.value_text, r.spell_version_id, r.min_level, r.conditions,
           r.data, r.automation, r.feature_active, r.is_primary, r.applies_to, null::text as manual_status
    from raw r where r.choice_id is null
    union all
    select r.character_class_id, r.class_id, r.class_name, r.class_level, r.unlock_id, r.feature_version_id, r.feature_name, r.origin,
           r.seq, v.ord::int,
           r.effect_type,
           case c.kind when 'asi' then split_part(v.val, ':', 1)
                       when 'number' then split_part(v.val, ':', 1)
                       when 'ability' then v.val
                       when 'skill' then 'skill'
                       when 'expertise' then case when exists (select 1 from public.skills s where s.id = v.val) then 'skill' else 'tool' end
                       when 'language' then 'language' when 'tool' then 'tool' when 'weapon' then 'weapon'
                       when 'proficiency_group' then 'group'
                       else r.target end,
           case when c.kind in ('asi', 'number') then nullif(split_part(v.val, ':', 2), '')::numeric else r.value end,
           case when c.kind in ('asi', 'number', 'ability', 'spell') then r.value_text else v.val end,
           case when c.kind = 'spell' then v.val else r.spell_version_id end,
           r.min_level, r.conditions, r.data || jsonb_build_object('choice_id', c.choice_id, 'choice_value', v.val),
           r.automation, r.feature_active and c.open, r.is_primary, r.applies_to, c.manual_status
    from raw r
    join ch c on c.character_class_id = r.character_class_id and c.unlock_id = r.unlock_id and c.choice_id = r.choice_id
    cross join lateral unnest(c.vals) with ordinality v(val, ord)
    where not (c.kind = 'asi' and v.val ~ '^feat:'))
  select x.character_class_id, x.class_id, x.class_name, x.class_level, x.unlock_id, x.feature_version_id, x.feature_name, x.origin,
         x.seq, x.pick, x.effect_type, x.target,
         coalesce(case when jsonb_typeof(sc.v) = 'number' then (sc.v #>> '{}')::numeric end, x.value),
         coalesce(case when jsonb_typeof(sc.v) = 'string' then sc.v #>> '{}' end, x.value_text),
         x.spell_version_id, x.min_level, x.conditions, x.data,
         x.automation, cr.spellcasting_ability, x.feature_active,
         x.feature_active and x.reason is null and x.automation <> 'informational' and x.effect_type <> 'informational',
         case when not x.feature_active then 'feature_inactive'
              when x.automation = 'informational' or x.effect_type = 'informational' then 'informational'
              else x.reason end
  from (
    select e.*,
           case when e.class_level < e.min_level then 'level'
                when e.applies_to = 'primary_class' and not e.is_primary then 'primary_class_only'
                when e.applies_to = 'multiclass' and e.is_primary then 'multiclass_only'
                when e.manual_status = 'applied_manually' and e.effect_type = 'ability_bonus' then 'included_in_scores'
                when e.conditions ->> 'armor' = 'worn' and not eq.armor_worn then 'not_wearing_armor'
                when e.conditions ->> 'armor' = 'none' and eq.armor_worn then 'wearing_armor'
                when e.conditions ->> 'armor' = 'not_heavy' and eq.armor_worn and eq.armor_category = 'heavy-armor' then 'wearing_heavy_armor'
                when e.conditions ->> 'shield' = 'none' and eq.shield then 'using_shield'
                when e.conditions ->> 'shield' = 'worn' and not eq.shield then 'no_shield'
           end as reason
    from expanded e cross join eq) x
  join cr on cr.character_class_id = x.character_class_id
  left join lateral (select public._cf_scale(s.table_by_level, case when s.level_basis = 'total' then cr.total_level else x.class_level end) -> 'value' as v
                     from public.class_feature_scaling s
                     where x.data ? 'scale' and s.feature_version_id = x.feature_version_id and s.key = x.data ->> 'scale') sc on true;
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

-- the replaced functions keep their grants (create or replace); the new helper table is read-only for clients
