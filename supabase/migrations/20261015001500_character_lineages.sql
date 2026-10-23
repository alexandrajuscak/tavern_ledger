-- =============================================================================
-- Character lineages (races): catalog, character selections, resolver and derived-stats integration.
-- Design: docs/LINEAGES_DESIGN.md. Catalog rows come from supabase/seed/lineages.sql (loaded after reference_data.sql).
-- This migration never depends on seeded rows: the only rows it inserts are its own lookups (categories, skills).
-- Rules: D&D 5e 2014 + the official supplements listed per version.
-- =============================================================================

-- ---- lookups the migration owns ----------------------------------------------------------------------------
create table public.lineage_categories (
  id         text primary key check (id ~ '^[a-z0-9]+(-[a-z0-9]+)*$'),
  name       text not null,
  sort_order int  not null default 0
);
insert into public.lineage_categories (id, name, sort_order) values
  ('standard', 'Standard Lineages', 10), ('custom', 'Custom Lineage', 20),
  ('exotic', 'Exotic Lineages', 30), ('monstrous', 'Monstrous Lineages', 40)
on conflict (id) do nothing;

create table public.skills (                 -- keys match characters.skill_proficiencies and js/dnd.js SKILLS
  id         text primary key check (id ~ '^[a-z]+(_[a-z]+)*$'),
  name       text not null unique,
  ability    text not null check (ability in ('str', 'dex', 'con', 'int', 'wis', 'cha')),
  sort_order int  not null default 0
);
insert into public.skills (id, name, ability, sort_order) values
  ('acrobatics', 'Acrobatics', 'dex', 1), ('animal_handling', 'Animal Handling', 'wis', 2), ('arcana', 'Arcana', 'int', 3),
  ('athletics', 'Athletics', 'str', 4), ('deception', 'Deception', 'cha', 5), ('history', 'History', 'int', 6),
  ('insight', 'Insight', 'wis', 7), ('intimidation', 'Intimidation', 'cha', 8), ('investigation', 'Investigation', 'int', 9),
  ('medicine', 'Medicine', 'wis', 10), ('nature', 'Nature', 'int', 11), ('perception', 'Perception', 'wis', 12),
  ('performance', 'Performance', 'cha', 13), ('persuasion', 'Persuasion', 'cha', 14), ('religion', 'Religion', 'int', 15),
  ('sleight_of_hand', 'Sleight of Hand', 'dex', 16), ('stealth', 'Stealth', 'dex', 17), ('survival', 'Survival', 'wis', 18)
on conflict (id) do nothing;

create table public.languages (               -- rows: supabase/seed/lineages.sql
  id         text primary key check (id ~ '^[a-z0-9]+(-[a-z0-9]+)*$'),
  name       text not null unique,
  kind       text not null check (kind in ('standard', 'exotic', 'other')),
  sort_order int  not null default 0
);

-- ---- catalog -------------------------------------------------------------------------------------------------
create table public.lineages (
  id          text primary key check (id ~ '^[a-z0-9]+(-[a-z0-9]+)*$'),
  category_id text not null references public.lineage_categories (id),
  name        text not null unique,
  source_url  text not null check (source_url ~ '^https://'),
  summary     text not null default '' check (length(summary) <= 500),
  sort_order  int  not null default 0
);

create table public.lineage_versions (
  id                         text primary key check (id ~ '^[a-z0-9]+(-[a-z0-9]+)*$'),
  lineage_id                 text not null references public.lineages (id) on delete cascade,
  parent_version_id          text,
  kind                       text not null check (kind in ('base', 'subrace', 'variant')),
  name                       text not null,
  source_book_id             text references public.source_books (id),
  source_label               text not null,
  source_url                 text not null check (source_url ~ '^https://'),
  status                     text not null check (status in ('current', 'legacy')),
  setting                    text check (setting in ('Eberron', 'Wildemount', 'Ravnica', 'Theros')),
  is_optional                boolean not null default false,
  superseded_by_version_id   text references public.lineage_versions (id) on delete set null,
  requires_child             boolean not null default false,
  replaces_all_parent_traits boolean not null default false,
  creature_type              text check (creature_type in ('humanoid', 'fey')),
  counts_as                  text,
  summary                    text not null default '' check (length(summary) <= 500),
  interpretation_note        text check (length(interpretation_note) <= 1000),
  sort_order                 int  not null default 0,
  unique (id, lineage_id),
  foreign key (parent_version_id, lineage_id) references public.lineage_versions (id, lineage_id) on delete cascade,
  constraint lineage_version_shape check ((kind = 'base') = (parent_version_id is null)),
  constraint lineage_version_child_flags check (kind <> 'base' or not replaces_all_parent_traits),
  constraint lineage_version_base_flags check (kind = 'base' or not requires_child)
);
create index lineage_versions_lineage on public.lineage_versions (lineage_id);
create index lineage_versions_parent on public.lineage_versions (parent_version_id) where parent_version_id is not null;

create table public.lineage_traits (
  id                  text primary key,
  version_id          text not null references public.lineage_versions (id) on delete cascade,
  name                text not null,
  summary             text not null check (length(summary) between 1 and 600),
  automation          text not null check (automation in ('automatic', 'partial', 'informational')),
  min_level           int  not null default 1 check (min_level between 1 and 20),
  uses                text check (uses ~ '^(pb|at_will|[1-9][0-9]?)$'),
  recharge            text check (recharge in ('short_rest', 'long_rest', 'short_or_long_rest', 'special')),
  interpretation_note text check (length(interpretation_note) <= 1000),
  sort_order          int  not null default 0
);
create index lineage_traits_version on public.lineage_traits (version_id);

create table public.lineage_trait_replacements (     -- a child version's trait replaces a trait of its parent
  trait_id          text not null references public.lineage_traits (id) on delete cascade,
  replaced_trait_id text not null references public.lineage_traits (id) on delete cascade,
  primary key (trait_id, replaced_trait_id)
);

create table public.lineage_choices (
  id               text primary key,
  version_id       text not null references public.lineage_versions (id) on delete cascade,
  trait_id         text references public.lineage_traits (id) on delete cascade,
  kind             text not null check (kind in ('ability_scores', 'size', 'skill', 'language', 'tool', 'weapon', 'skill_or_tool',
                                                 'spellcasting_ability', 'option', 'spell', 'feat')),
  label            text not null,
  pick_count       int  not null default 1 check (pick_count between 1 and 6),
  required         boolean not null default true,
  min_level        int  not null default 1 check (min_level between 1 and 20),
  parent_choice_id text,
  parent_option_id text,
  config           jsonb not null default '{}'::jsonb,   -- {"from": [...], "exclude": [...], "patterns": [[2,1],[1,1,1]], "category": "artisan-tools"}
  changeable       boolean not null default false,       -- the rules let the player change it later (e.g. after a long rest)
  sort_order       int  not null default 0,
  constraint lineage_choice_parent check ((parent_choice_id is null) = (parent_option_id is null))
);
create index lineage_choices_version on public.lineage_choices (version_id);

create table public.lineage_choice_options (
  choice_id  text not null references public.lineage_choices (id) on delete cascade,
  option_id  text not null check (option_id ~ '^[a-z0-9]+([-_][a-z0-9]+)*$'),
  label      text not null,
  summary    text not null default '' check (length(summary) <= 400),
  data       jsonb not null default '{}'::jsonb,
  sort_order int  not null default 0,
  primary key (choice_id, option_id)
);
alter table public.lineage_choices add constraint lineage_choices_parent_option
  foreign key (parent_choice_id, parent_option_id) references public.lineage_choice_options (choice_id, option_id) on delete cascade;

create table public.lineage_option_replacements (    -- choosing this option replaces a trait (SCAG variant tiefling ...)
  choice_id         text not null,
  option_id         text not null,
  replaced_trait_id text not null references public.lineage_traits (id) on delete cascade,
  primary key (choice_id, option_id, replaced_trait_id),
  foreign key (choice_id, option_id) references public.lineage_choice_options (choice_id, option_id) on delete cascade
);

create table public.lineage_trait_effects (
  trait_id         text not null references public.lineage_traits (id) on delete cascade,
  seq              int  not null check (seq > 0),
  effect_type      text not null check (effect_type in (
                     'ability_bonus', 'size', 'speed', 'ignore_heavy_armor_speed_penalty', 'sense', 'proficiency', 'language',
                     'resistance', 'immunity', 'condition_immunity', 'save_advantage', 'check_advantage', 'natural_armor',
                     'natural_weapon', 'spell', 'limited_use', 'initiative_bonus', 'hp_per_level', 'carrying_capacity')),
  target           text,
  value            numeric,
  value_text       text,
  min_level        int  not null default 1 check (min_level between 1 and 20),
  choice_id        text references public.lineage_choices (id) on delete cascade,  -- the value(s) come from this choice
  option_choice_id text,                                                           -- applies only when this option is chosen
  option_id        text,
  conditions       jsonb not null default '{}'::jsonb,                             -- {"not_armor": ["medium-armor", "heavy-armor"]}
  data             jsonb not null default '{}'::jsonb,
  primary key (trait_id, seq),
  constraint lineage_effect_option check ((option_choice_id is null) = (option_id is null)),
  foreign key (option_choice_id, option_id) references public.lineage_choice_options (choice_id, option_id) on delete cascade
);

-- ---- catalog integrity -----------------------------------------------------------------------------------------
create function public.lineage_versions_before_write()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  if new.parent_version_id is not null and exists (
       select 1 from public.lineage_versions p where p.id = new.parent_version_id and p.kind <> 'base') then
    raise exception 'A sub-lineage must belong to a base version (%)', new.id using errcode = '22023';
  end if;
  if new.superseded_by_version_id is not null and new.superseded_by_version_id = new.id then
    raise exception 'A version cannot supersede itself' using errcode = '22023';
  end if;
  return new;
end;
$$;
create trigger lineage_versions_before_write before insert or update on public.lineage_versions
  for each row execute function public.lineage_versions_before_write();

-- a replaced trait must belong to the parent version (child replacements) or to the version tree (option replacements)
create function public.lineage_replacements_before_write()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
declare v_child text; v_parent text; v_target text;
begin
  select version_id into v_target from public.lineage_traits where id = new.replaced_trait_id;
  if tg_table_name = 'lineage_trait_replacements' then
    select t.version_id, v.parent_version_id into v_child, v_parent
    from public.lineage_traits t join public.lineage_versions v on v.id = t.version_id where t.id = new.trait_id;
    if v_parent is null or v_target is distinct from v_parent then
      raise exception 'Trait % can only replace a trait of its parent version', new.trait_id using errcode = '22023';
    end if;
  else
    select c.version_id, v.parent_version_id into v_child, v_parent
    from public.lineage_choices c join public.lineage_versions v on v.id = c.version_id where c.id = new.choice_id;
    if v_target is distinct from v_child and v_target is distinct from v_parent then
      raise exception 'Option %/% can only replace a trait of its own version or its parent', new.choice_id, new.option_id
        using errcode = '22023';
    end if;
  end if;
  return new;
end;
$$;
create trigger lineage_trait_replacements_before_write before insert or update on public.lineage_trait_replacements
  for each row execute function public.lineage_replacements_before_write();
create trigger lineage_option_replacements_before_write before insert or update on public.lineage_option_replacements
  for each row execute function public.lineage_replacements_before_write();

create function public.lineage_choices_before_write()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  if new.trait_id is not null and not exists (
       select 1 from public.lineage_traits t where t.id = new.trait_id and t.version_id = new.version_id) then
    raise exception 'Choice % belongs to a trait of another version', new.id using errcode = '22023';
  end if;
  if new.kind = 'ability_scores' and jsonb_typeof(new.config -> 'patterns') is distinct from 'array' then
    raise exception 'Ability score choice % needs "patterns"', new.id using errcode = '22023';
  end if;
  return new;
end;
$$;
create trigger lineage_choices_before_write before insert or update on public.lineage_choices
  for each row execute function public.lineage_choices_before_write();

-- effect targets are validated against the rule lookups (the seed runs after reference_data.sql)
create function public.lineage_trait_effects_before_write()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
declare v_kind text; v_version text; v_choice_version text;
  abilities constant text[] := array['str', 'dex', 'con', 'int', 'wis', 'cha'];
begin
  select version_id into v_version from public.lineage_traits where id = new.trait_id;
  if new.choice_id is not null then
    select kind, version_id into v_kind, v_choice_version from public.lineage_choices where id = new.choice_id;
    if v_choice_version is distinct from v_version then
      raise exception 'Effect %/% uses a choice of another version', new.trait_id, new.seq using errcode = '22023';
    end if;
  end if;
  case new.effect_type
    when 'ability_bonus' then
      if not ((new.choice_id is not null and v_kind = 'ability_scores') or (new.target = any (abilities) and new.value between 1 and 3)) then
        raise exception 'ability_bonus needs an ability and a value 1-3, or an ability_scores choice' using errcode = '22023';
      end if;
    when 'size' then
      if not ((new.choice_id is not null and v_kind = 'size') or new.value_text in ('tiny', 'small', 'medium', 'large')) then
        raise exception 'size needs tiny/small/medium/large or a size choice' using errcode = '22023';
      end if;
    when 'speed' then
      if new.target not in ('walk', 'climb', 'swim', 'fly', 'burrow') or not (new.value > 0 or new.value_text = 'walk') then
        raise exception 'speed needs a mode and a value (or "walk" for "equal to walking speed")' using errcode = '22023';
      end if;
    when 'sense' then
      if new.target not in ('darkvision', 'blindsight', 'tremorsense', 'truesight', 'telepathy') or not new.value > 0 then
        raise exception 'sense needs a known sense and a range' using errcode = '22023';
      end if;
    when 'proficiency' then
      if new.choice_id is not null then
        if v_kind not in ('skill', 'tool', 'weapon', 'skill_or_tool') then
          raise exception 'proficiency from a % choice is not supported', v_kind using errcode = '22023';
        end if;
      elsif new.target = 'skill' then
        if not exists (select 1 from public.skills where id = new.value_text) then
          raise exception 'Unknown skill "%"', new.value_text using errcode = '22023'; end if;
      elsif new.target in ('weapon', 'tool', 'armor') then
        if not exists (select 1 from public.items where id = new.value_text and owner_id is null and kind_id = new.target) then
          raise exception 'Unknown % "%"', new.target, new.value_text using errcode = '22023'; end if;
      elsif new.target = 'group' then
        if not exists (select 1 from public.proficiency_groups where id = new.value_text) then
          raise exception 'Unknown proficiency group "%"', new.value_text using errcode = '22023'; end if;
      else
        raise exception 'proficiency target must be skill, weapon, armor, tool or group' using errcode = '22023';
      end if;
    when 'language' then
      if not ((new.choice_id is not null and v_kind = 'language') or exists (select 1 from public.languages where id = new.value_text)) then
        raise exception 'Unknown language "%"', new.value_text using errcode = '22023';
      end if;
    when 'resistance', 'immunity' then
      if not exists (select 1 from public.damage_types where id = new.value_text) then
        raise exception 'Unknown damage type "%"', new.value_text using errcode = '22023';
      end if;
    when 'natural_armor' then
      if not (new.value between 10 and 20 and new.data ->> 'dex' in ('full', 'none')
              and new.data ->> 'mode' in ('best_of', 'replaces_armor')) then
        raise exception 'natural_armor needs a base AC, data.dex (full/none) and data.mode (best_of/replaces_armor)' using errcode = '22023';
      end if;
    when 'natural_weapon' then
      if new.value_text is null or new.data ->> 'damage_dice' !~ '^[1-9][0-9]*d[0-9]+$'
         or not exists (select 1 from public.damage_types where id = new.data ->> 'damage_type') then
        raise exception 'natural_weapon needs a name, data.damage_dice and a known data.damage_type' using errcode = '22023';
      end if;
    when 'spell' then
      if new.value_text is null or new.data ->> 'slug' !~ '^[a-z0-9]+(-[a-z0-9]+)*$' then
        raise exception 'spell needs a name and data.slug' using errcode = '22023';
      end if;
    else null;
  end case;
  return new;
end;
$$;
create trigger lineage_trait_effects_before_write before insert or update on public.lineage_trait_effects
  for each row execute function public.lineage_trait_effects_before_write();

-- ---- character selections ----------------------------------------------------------------------------------------
create table public.character_lineages (
  character_id             uuid primary key references public.characters (id) on delete cascade,
  lineage_id               text not null references public.lineages (id),
  version_id               text not null,
  subversion_id            text,
  ability_bonuses_included boolean not null default false,  -- the entered scores already include the lineage bonuses
  updated_at               timestamptz not null default now(),
  updated_by               uuid default auth.uid(),
  foreign key (version_id, lineage_id) references public.lineage_versions (id, lineage_id),
  foreign key (subversion_id, lineage_id) references public.lineage_versions (id, lineage_id)
);

create table public.character_lineage_choices (
  character_id uuid not null references public.character_lineages (character_id) on delete cascade,
  choice_id    text not null references public.lineage_choices (id),
  pick         int  not null check (pick between 1 and 6),
  value        text not null check (length(value) between 1 and 100),
  primary key (character_id, choice_id, pick)
);

create function public.character_lineages_before_write()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
declare v public.lineage_versions; s public.lineage_versions;
begin
  select * into v from public.lineage_versions where id = new.version_id;
  if v.kind <> 'base' then
    raise exception 'Choose a base version first; "%" is a sub-lineage', v.name using errcode = '22023';
  end if;
  if new.subversion_id is not null then
    select * into s from public.lineage_versions where id = new.subversion_id;
    if s.parent_version_id is distinct from new.version_id then
      raise exception '"%" is not a sub-lineage of "%"', s.name, v.name using errcode = '22023';
    end if;
  elsif v.requires_child then
    raise exception '% needs a sub-lineage', v.name using errcode = '22023';
  end if;
  new.updated_at := now();
  return new;
end;
$$;
create trigger character_lineages_before_write before insert or update on public.character_lineages
  for each row execute function public.character_lineages_before_write();

-- =============================================================================
-- Resolver: selections -> effective traits, choices and effects (nothing resolved is stored)
-- =============================================================================

-- Effective traits: base traits minus replaced ones (by the child, or by a chosen option) plus the child's traits.
create function public._lineage_effective_traits(p_character uuid)
returns table (trait_id text, version_id text, origin text)
language sql stable
set search_path = public, pg_temp
as $$
  with sel as (select * from public.character_lineages where character_id = p_character),
  tree as (
    select sel.version_id as vid, 'base'::text as origin from sel
    union all select sel.subversion_id, 'child' from sel where sel.subversion_id is not null),
  chosen as (select choice_id, value from public.character_lineage_choices where character_id = p_character),
  replaced as (
    select r.replaced_trait_id from public.lineage_trait_replacements r
    join public.lineage_traits t on t.id = r.trait_id join sel on t.version_id = sel.subversion_id
    union
    select o.replaced_trait_id from public.lineage_option_replacements o
    join chosen ch on ch.choice_id = o.choice_id and ch.value = o.option_id
    join public.lineage_choices c on c.id = o.choice_id join tree on tree.vid = c.version_id),
  drop_parent as (
    select coalesce(bool_or(v.replaces_all_parent_traits), false) as d
    from sel join public.lineage_versions v on v.id = sel.subversion_id)
  select t.id, t.version_id, tree.origin
  from public.lineage_traits t join tree on tree.vid = t.version_id
  where t.id not in (select replaced_trait_id from replaced)
    and not (tree.origin = 'base' and (select d from drop_parent));
$$;

-- One row per applicable effect, with choice values substituted. Level gating is reported here; armor conditions are
-- evaluated by get_character_derived_stats (it knows the equipment).
create function public._lineage_effects(p_character uuid)
returns table (trait_id text, trait_name text, seq int, effect_type text, target text, value numeric, value_text text,
               min_level int, active boolean, inactive_reason text, conditions jsonb, data jsonb)
language sql stable
set search_path = public, pg_temp
as $$
  with lvl as (select level from public.characters where id = p_character),
  eff as (select * from public._lineage_effective_traits(p_character)),
  chosen as (select choice_id, value, pick from public.character_lineage_choices where character_id = p_character),
  raw as (
    select e.*, t.name as trait_name, greatest(t.min_level, e.min_level) as gate
    from public.lineage_trait_effects e
    join eff on eff.trait_id = e.trait_id
    join public.lineage_traits t on t.id = e.trait_id
    where e.option_choice_id is null
       or exists (select 1 from chosen ch where ch.choice_id = e.option_choice_id and ch.value = e.option_id)),
  expanded as (
    select r.trait_id, r.trait_name, r.seq, r.effect_type, r.target, r.value, r.value_text, r.gate, r.conditions, r.data
    from raw r where r.choice_id is null
    union all
    select r.trait_id, r.trait_name, r.seq, r.effect_type,
           case c.kind when 'ability_scores' then split_part(ch.value, ':', 1)
                       when 'skill_or_tool' then split_part(ch.value, ':', 1)
                       when 'size' then null when 'language' then null
                       else c.kind end,
           case c.kind when 'ability_scores' then split_part(ch.value, ':', 2)::numeric else r.value end,
           case c.kind when 'ability_scores' then null
                       when 'skill_or_tool' then split_part(ch.value, ':', 2)
                       else ch.value end,
           r.gate, r.conditions, r.data || jsonb_build_object('choice_id', c.id, 'pick', ch.pick)
    from raw r join public.lineage_choices c on c.id = r.choice_id
    join chosen ch on ch.choice_id = r.choice_id),
  -- data.ability_choice: the spellcasting ability comes from a choice; data.option_data_from: merge the chosen option's data
  enriched as (
    select x.*,
      x.data
      || coalesce((select jsonb_build_object('ability', ch.value) from chosen ch where ch.choice_id = x.data ->> 'ability_choice' limit 1), '{}')
      || coalesce((select o.data from chosen ch join public.lineage_choice_options o on o.choice_id = ch.choice_id and o.option_id = ch.value
                   where ch.choice_id = x.data ->> 'option_data_from' limit 1), '{}') as data2
    from expanded x)
  select e.trait_id, e.trait_name, e.seq, e.effect_type, e.target, e.value, e.value_text, e.gate,
         (select level from lvl) >= e.gate,
         case when (select level from lvl) < e.gate then 'level' end,
         e.conditions, e.data2
  from enriched e
  order by e.trait_id, e.seq, (e.data2 ->> 'pick')::int nulls first;
$$;

-- Validation of one choice's values. Returns null when valid, otherwise a user-facing message.
create function public._lineage_choice_error(p_choice public.lineage_choices, p_values text[])
returns text
language plpgsql stable
set search_path = public, pg_temp
as $$
declare v text; n int := coalesce(cardinality(p_values), 0); cfg jsonb := p_choice.config; ok boolean;
begin
  if n > p_choice.pick_count then return format('choose at most %s', p_choice.pick_count); end if;
  if n <> (select count(distinct x) from unnest(p_values) x) then return 'the same value was chosen twice'; end if;
  foreach v in array coalesce(p_values, '{}') loop
    case p_choice.kind
      when 'ability_scores' then
        if v !~ '^(str|dex|con|int|wis|cha):[1-3]$' then return format('"%s" is not an ability increase', v); end if;
        if cfg -> 'exclude' ? split_part(v, ':', 1) then return format('%s cannot be chosen here', upper(split_part(v, ':', 1))); end if;
      when 'size', 'option', 'spellcasting_ability' then
        if not exists (select 1 from public.lineage_choice_options o where o.choice_id = p_choice.id and o.option_id = v) then
          return format('"%s" is not one of the options', v); end if;
      when 'skill' then
        if not exists (select 1 from public.skills where id = v) or (cfg ? 'from' and not cfg -> 'from' ? v) then
          return format('"%s" is not an allowed skill', v); end if;
      when 'language' then
        if not exists (select 1 from public.languages where id = v) or coalesce(cfg -> 'exclude' ? v, false) then
          return format('"%s" is not an allowed language', v); end if;
      when 'tool' then
        if not exists (select 1 from public.items i where i.id = v and i.kind_id = 'tool' and i.owner_id is null
                       and (not cfg ? 'category' or i.category_id = cfg ->> 'category'))
           or (cfg ? 'from' and not cfg -> 'from' ? v) then
          return format('"%s" is not an allowed tool', v); end if;
      when 'weapon' then
        if not exists (select 1 from public.items i join public.weapon_stats w on w.item_id = i.id
                       where i.id = v and i.owner_id is null
                         and (not cfg ? 'weapon_group' or w.weapon_group = cfg ->> 'weapon_group'))
           or (cfg ? 'from' and not cfg -> 'from' ? v) then
          return format('"%s" is not an allowed weapon', v); end if;
      when 'skill_or_tool' then
        if v ~ '^skill:' then ok := exists (select 1 from public.skills where id = substr(v, 7));
        elsif v ~ '^tool:' then ok := exists (select 1 from public.items where id = substr(v, 6) and kind_id = 'tool' and owner_id is null);
        else ok := false; end if;
        if not ok then return format('"%s" is not a skill or tool', v); end if;
      else   -- spell, feat: free text until catalogs exist
        if btrim(v) = '' or length(v) > 100 then return 'enter a name (up to 100 characters)'; end if;
    end case;
  end loop;
  if p_choice.kind = 'ability_scores' and n > 0 then
    if n <> (select count(distinct split_part(x, ':', 1)) from unnest(p_values) x) then return 'choose different abilities'; end if;
    -- the chosen amounts must fit at least one allowed pattern (a partial selection is fine)
    select bool_or(fits) into ok from (
      select (select bool_and((select count(*) from unnest(p_values) x where split_part(x, ':', 2)::int = a.amt)
                               <= (select count(*) from jsonb_array_elements_text(p.pat) y where y::int = a.amt))
              from (select distinct split_part(x, ':', 2)::int as amt from unnest(p_values) x) a) as fits
      from jsonb_array_elements(cfg -> 'patterns') p(pat)) s;
    if not coalesce(ok, false) then return 'these increases do not match an allowed pattern'; end if;
  end if;
  return null;
end;
$$;

create function public._lineage_choice_complete(p_choice public.lineage_choices, p_values text[])
returns boolean
language sql stable
set search_path = public, pg_temp
as $$
  select case when p_choice.kind = 'ability_scores' then
           exists (select 1 from jsonb_array_elements(p_choice.config -> 'patterns') p(pat)
                   where (select array_agg(y::int order by y::int) from jsonb_array_elements_text(p.pat) y)
                       = (select array_agg(split_part(x, ':', 2)::int order by split_part(x, ':', 2)::int) from unnest(p_values) x))
         else coalesce(cardinality(p_values), 0) = p_choice.pick_count end;
$$;

-- Full resolution for the sheet: lineage, versions, traits (with automation status), choices (with status), effects.
create function public.get_character_lineage(p_character uuid)
returns jsonb
language plpgsql stable
set search_path = public, pg_temp
as $$
declare sel public.character_lineages; lvl int; res jsonb; choices jsonb; traits jsonb; replaced jsonb;
begin
  select level into lvl from public.characters where id = p_character;                    -- RLS
  if not found then raise exception 'Character not found' using errcode = '42501'; end if;
  select * into sel from public.character_lineages where character_id = p_character;
  if not found then
    return jsonb_build_object('character_id', p_character, 'selected', false);
  end if;

  with tree as (select sel.version_id as vid union all select sel.subversion_id where sel.subversion_id is not null),
  eff as (select * from public._lineage_effective_traits(p_character)),
  chosen as (select choice_id, array_agg(value order by pick) as vals from public.character_lineage_choices
             where character_id = p_character group by choice_id),
  all_chosen as (select choice_id, value from public.character_lineage_choices where character_id = p_character),
  c as (
    select ch as rec, ch.*, coalesce(cs.vals, '{}') as vals,
           (ch.trait_id is null or ch.trait_id in (select trait_id from eff))
           and (ch.parent_choice_id is null or exists (select 1 from all_chosen a
                                                       where a.choice_id = ch.parent_choice_id and a.value = ch.parent_option_id)) as enabled
    from public.lineage_choices ch join tree on tree.vid = ch.version_id
    left join chosen cs on cs.choice_id = ch.id),
  c2 as (select c.*, public._lineage_choice_complete(c.rec, c.vals) as done from c)
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', c2.id, 'version_id', c2.version_id, 'trait_id', c2.trait_id, 'kind', c2.kind, 'label', c2.label,
           'pick_count', c2.pick_count, 'required', c2.required, 'min_level', c2.min_level, 'config', c2.config,
           'changeable', c2.changeable, 'parent_choice_id', c2.parent_choice_id, 'parent_option_id', c2.parent_option_id,
           'values', to_jsonb(c2.vals), 'enabled', c2.enabled, 'complete', c2.done,
           'status', case when not c2.enabled then 'disabled'
                          when c2.done then 'complete'
                          when lvl < c2.min_level then 'later'
                          when not c2.required then 'optional'
                          else 'missing' end,
           'options', (select coalesce(jsonb_agg(jsonb_build_object('id', o.option_id, 'label', o.label, 'summary', o.summary,
                                                                     'data', o.data) order by o.sort_order, o.option_id), '[]')
                       from public.lineage_choice_options o where o.choice_id = c2.id))
         order by c2.sort_order, c2.id), '[]') into choices
  from c2;

  select coalesce(jsonb_agg(jsonb_build_object(
           'id', t.id, 'version_id', t.version_id, 'origin', eff.origin, 'name', t.name, 'summary', t.summary,
           'automation', t.automation, 'min_level', t.min_level, 'uses', t.uses, 'recharge', t.recharge,
           'interpretation_note', t.interpretation_note,
           'status', case when lvl < t.min_level then 'locked'
                          when exists (select 1 from jsonb_array_elements(choices) ch
                                       where ch ->> 'trait_id' = t.id and ch ->> 'status' = 'missing') then 'unresolved'
                          else 'active' end)
         order by eff.origin, t.sort_order, t.id), '[]') into traits
  from public._lineage_effective_traits(p_character) eff join public.lineage_traits t on t.id = eff.trait_id;

  select coalesce(jsonb_agg(jsonb_build_object('id', t.id, 'name', t.name, 'version_id', t.version_id) order by t.sort_order, t.id), '[]')
  into replaced
  from public.lineage_traits t
  where t.version_id in (sel.version_id, sel.subversion_id)
    and t.id not in (select trait_id from public._lineage_effective_traits(p_character));

  select jsonb_build_object(
    'character_id', p_character, 'selected', true, 'level', lvl,
    'ability_bonuses_included', sel.ability_bonuses_included,
    'lineage', (select jsonb_build_object('id', l.id, 'name', l.name, 'category_id', l.category_id, 'source_url', l.source_url)
                from public.lineages l where l.id = sel.lineage_id),
    'version', (select jsonb_build_object('id', v.id, 'name', v.name, 'source_label', v.source_label, 'source_url', v.source_url,
                       'status', v.status, 'setting', v.setting, 'is_optional', v.is_optional, 'creature_type', v.creature_type,
                       'counts_as', v.counts_as, 'superseded_by_version_id', v.superseded_by_version_id)
                from public.lineage_versions v where v.id = sel.version_id),
    'subversion', (select jsonb_build_object('id', v.id, 'name', v.name, 'kind', v.kind, 'source_label', v.source_label,
                          'source_url', v.source_url, 'status', v.status, 'setting', v.setting,
                          'replaces_all_parent_traits', v.replaces_all_parent_traits, 'interpretation_note', v.interpretation_note)
                   from public.lineage_versions v where v.id = sel.subversion_id),
    'traits', traits, 'replaced_traits', replaced, 'choices', choices,
    'unresolved', (select count(*) from jsonb_array_elements(choices) ch where ch ->> 'status' = 'missing'),
    'effects', (select coalesce(jsonb_agg(to_jsonb(e)), '[]') from public._lineage_effects(p_character) e))
  into res;
  return res;
end;
$$;

-- =============================================================================
-- Write path (the only one): replace the whole selection atomically
-- =============================================================================
create function public.set_character_lineage(p_character uuid, p_version text, p_subversion text default null,
                                             p_choices jsonb default '{}'::jsonb, p_ability_bonuses_included boolean default false,
                                             p_require_complete boolean default false)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare v public.lineage_versions; s public.lineage_versions; ch public.lineage_choices; k text; vals text[]; err text;
  res jsonb; missing text;
begin
  if auth.uid() is null or not public.can_access_character(p_character) then
    raise exception 'Character not found' using errcode = '42501';
  end if;
  select * into v from public.lineage_versions where id = p_version;
  if not found then raise exception 'Unknown lineage version "%"', p_version using errcode = '22023'; end if;
  if v.kind <> 'base' then raise exception '"%" is a sub-lineage; choose its parent version first', v.name using errcode = '22023'; end if;
  if p_subversion is not null then
    select * into s from public.lineage_versions where id = p_subversion;
    if not found or s.parent_version_id is distinct from v.id then
      raise exception '"%" is not a sub-lineage of %', p_subversion, v.name using errcode = '22023';
    end if;
  elsif v.requires_child then
    raise exception '% needs a sub-lineage', v.name using errcode = '22023';
  end if;
  if jsonb_typeof(coalesce(p_choices, '{}')) <> 'object' then
    raise exception 'Choices must be an object {choice_id: [values]}' using errcode = '22023';
  end if;
  perform pg_advisory_xact_lock(hashtext('lineage:' || p_character::text));

  for k in select jsonb_object_keys(coalesce(p_choices, '{}')) loop
    select * into ch from public.lineage_choices where id = k and version_id in (v.id, p_subversion);
    if not found then raise exception 'Choice "%" does not belong to this lineage', k using errcode = '22023'; end if;
    if jsonb_typeof(p_choices -> k) <> 'array' then
      raise exception '%: values must be a list', ch.label using errcode = '22023';
    end if;
    select coalesce(array_agg(x), '{}') into vals from jsonb_array_elements_text(p_choices -> k) x;
    err := public._lineage_choice_error(ch, vals);
    if err is not null then raise exception '%: %', ch.label, err using errcode = '22023'; end if;
  end loop;

  insert into public.character_lineages (character_id, lineage_id, version_id, subversion_id, ability_bonuses_included, updated_by)
  values (p_character, v.lineage_id, v.id, p_subversion, coalesce(p_ability_bonuses_included, false), auth.uid())
  on conflict (character_id) do update set lineage_id = excluded.lineage_id, version_id = excluded.version_id,
    subversion_id = excluded.subversion_id, ability_bonuses_included = excluded.ability_bonuses_included,
    updated_by = excluded.updated_by;
  delete from public.character_lineage_choices where character_id = p_character;
  insert into public.character_lineage_choices (character_id, choice_id, pick, value)
  select p_character, kv.key, x.ord, x.val
  from jsonb_each(coalesce(p_choices, '{}')) kv, jsonb_array_elements_text(kv.value) with ordinality x(val, ord);

  -- drop values of choices the final selection disables (a replaced trait, an option that was not chosen)
  res := public.get_character_lineage(p_character);
  delete from public.character_lineage_choices
  where character_id = p_character
    and choice_id in (select c ->> 'id' from jsonb_array_elements(res -> 'choices') c where c ->> 'status' = 'disabled');
  if found then res := public.get_character_lineage(p_character); end if;

  if p_require_complete then
    select string_agg(c ->> 'label', ', ') into missing from jsonb_array_elements(res -> 'choices') c where c ->> 'status' = 'missing';
    if missing is not null then raise exception 'Incomplete lineage choices: %', missing using errcode = '22023'; end if;
  end if;
  return res;
end;
$$;

create function public.clear_character_lineage(p_character uuid)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
begin
  if auth.uid() is null or not public.can_access_character(p_character) then
    raise exception 'Character not found' using errcode = '42501';
  end if;
  delete from public.character_lineages where character_id = p_character;
  return jsonb_build_object('character_id', p_character, 'cleared', found);
end;
$$;

-- =============================================================================
-- Catalog reads
-- =============================================================================
create view public.v_lineage_catalog with (security_invoker = true) as
select l.id, l.name, l.category_id, cat.name as category_name, cat.sort_order as category_sort, l.summary, l.source_url, l.sort_order,
       (select count(*) from public.lineage_versions v where v.lineage_id = l.id and v.kind = 'base') as version_count,
       (select count(*) from public.lineage_versions v where v.lineage_id = l.id and v.kind <> 'base') as child_count,
       (select array_agg(distinct v.source_label order by v.source_label) from public.lineage_versions v where v.lineage_id = l.id) as sources,
       l.name || ' ' || coalesce((select string_agg(v.name, ' ' order by v.id) from public.lineage_versions v where v.lineage_id = l.id), '')
         as search_text
from public.lineages l join public.lineage_categories cat on cat.id = l.category_id;

create function public.get_lineage_detail(p_lineage text)
returns jsonb
language sql stable
set search_path = public, pg_temp
as $$
  select jsonb_build_object(
    'id', l.id, 'name', l.name, 'category_id', l.category_id, 'summary', l.summary, 'source_url', l.source_url,
    'versions', (select coalesce(jsonb_agg(jsonb_build_object(
        'id', v.id, 'parent_version_id', v.parent_version_id, 'kind', v.kind, 'name', v.name,
        'source_label', v.source_label, 'source_url', v.source_url, 'status', v.status, 'setting', v.setting,
        'is_optional', v.is_optional, 'superseded_by_version_id', v.superseded_by_version_id, 'requires_child', v.requires_child,
        'replaces_all_parent_traits', v.replaces_all_parent_traits, 'creature_type', v.creature_type, 'counts_as', v.counts_as,
        'summary', v.summary, 'interpretation_note', v.interpretation_note,
        'traits', (select coalesce(jsonb_agg(jsonb_build_object(
            'id', t.id, 'name', t.name, 'summary', t.summary, 'automation', t.automation, 'min_level', t.min_level,
            'uses', t.uses, 'recharge', t.recharge, 'interpretation_note', t.interpretation_note,
            'replaces', (select coalesce(jsonb_agg(r.replaced_trait_id order by r.replaced_trait_id), '[]')
                         from public.lineage_trait_replacements r where r.trait_id = t.id),
            'effects', (select coalesce(jsonb_agg(jsonb_build_object('seq', e.seq, 'effect_type', e.effect_type, 'target', e.target,
                          'value', e.value, 'value_text', e.value_text, 'min_level', e.min_level, 'choice_id', e.choice_id,
                          'option_choice_id', e.option_choice_id, 'option_id', e.option_id, 'conditions', e.conditions, 'data', e.data)
                          order by e.seq), '[]') from public.lineage_trait_effects e where e.trait_id = t.id))
            order by t.sort_order, t.id), '[]') from public.lineage_traits t where t.version_id = v.id),
        'choices', (select coalesce(jsonb_agg(jsonb_build_object(
            'id', c.id, 'trait_id', c.trait_id, 'kind', c.kind, 'label', c.label, 'pick_count', c.pick_count,
            'required', c.required, 'min_level', c.min_level, 'config', c.config, 'changeable', c.changeable,
            'parent_choice_id', c.parent_choice_id, 'parent_option_id', c.parent_option_id,
            'options', (select coalesce(jsonb_agg(jsonb_build_object('id', o.option_id, 'label', o.label, 'summary', o.summary, 'data', o.data,
                          'replaces', (select coalesce(jsonb_agg(r.replaced_trait_id order by r.replaced_trait_id), '[]')
                                       from public.lineage_option_replacements r
                                       where r.choice_id = o.choice_id and r.option_id = o.option_id))
                          order by o.sort_order, o.option_id), '[]') from public.lineage_choice_options o where o.choice_id = c.id))
            order by c.sort_order, c.id), '[]') from public.lineage_choices c where c.version_id = v.id))
      order by v.kind <> 'base', v.status <> 'current', v.sort_order, v.id), '[]')
      from public.lineage_versions v where v.lineage_id = l.id))
  from public.lineages l where l.id = p_lineage;
$$;

-- =============================================================================
-- RLS, grants, Realtime
-- =============================================================================
alter table public.lineage_categories enable row level security;
alter table public.skills enable row level security;
alter table public.languages enable row level security;
alter table public.lineages enable row level security;
alter table public.lineage_versions enable row level security;
alter table public.lineage_traits enable row level security;
alter table public.lineage_trait_replacements enable row level security;
alter table public.lineage_choices enable row level security;
alter table public.lineage_choice_options enable row level security;
alter table public.lineage_option_replacements enable row level security;
alter table public.lineage_trait_effects enable row level security;
alter table public.character_lineages enable row level security;
alter table public.character_lineage_choices enable row level security;

create policy "lineage_categories_read" on public.lineage_categories for select to anon, authenticated using (true);
create policy "skills_read" on public.skills for select to anon, authenticated using (true);
create policy "languages_read" on public.languages for select to anon, authenticated using (true);
create policy "lineages_read" on public.lineages for select to anon, authenticated using (true);
create policy "lineage_versions_read" on public.lineage_versions for select to anon, authenticated using (true);
create policy "lineage_traits_read" on public.lineage_traits for select to anon, authenticated using (true);
create policy "lineage_trait_replacements_read" on public.lineage_trait_replacements for select to anon, authenticated using (true);
create policy "lineage_choices_read" on public.lineage_choices for select to anon, authenticated using (true);
create policy "lineage_choice_options_read" on public.lineage_choice_options for select to anon, authenticated using (true);
create policy "lineage_option_replacements_read" on public.lineage_option_replacements for select to anon, authenticated using (true);
create policy "lineage_trait_effects_read" on public.lineage_trait_effects for select to anon, authenticated using (true);
create policy "character_lineages_read" on public.character_lineages for select to authenticated
  using (public.can_access_character(character_id));
create policy "character_lineage_choices_read" on public.character_lineage_choices for select to authenticated
  using (public.can_access_character(character_id));

revoke all on public.lineage_categories, public.skills, public.languages, public.lineages, public.lineage_versions,
  public.lineage_traits, public.lineage_trait_replacements, public.lineage_choices, public.lineage_choice_options,
  public.lineage_option_replacements, public.lineage_trait_effects, public.character_lineages, public.character_lineage_choices,
  public.v_lineage_catalog from anon, authenticated;
grant select on public.lineage_categories, public.skills, public.languages, public.lineages, public.lineage_versions,
  public.lineage_traits, public.lineage_trait_replacements, public.lineage_choices, public.lineage_choice_options,
  public.lineage_option_replacements, public.lineage_trait_effects, public.v_lineage_catalog to anon, authenticated;
grant select on public.character_lineages, public.character_lineage_choices to authenticated;   -- writes: the RPCs only

revoke all on function public.lineage_versions_before_write(), public.lineage_replacements_before_write(),
  public.lineage_choices_before_write(), public.lineage_trait_effects_before_write(), public.character_lineages_before_write()
  from public, anon, authenticated;
revoke all on function public._lineage_effective_traits(uuid), public._lineage_effects(uuid),
  public._lineage_choice_error(public.lineage_choices, text[]), public._lineage_choice_complete(public.lineage_choices, text[]),
  public.get_character_lineage(uuid), public.set_character_lineage(uuid, text, text, jsonb, boolean, boolean),
  public.clear_character_lineage(uuid), public.get_lineage_detail(text) from public, anon;
grant execute on function public._lineage_effective_traits(uuid), public._lineage_effects(uuid),
  public._lineage_choice_error(public.lineage_choices, text[]), public._lineage_choice_complete(public.lineage_choices, text[]),
  public.get_character_lineage(uuid), public.set_character_lineage(uuid, text, text, jsonb, boolean, boolean),
  public.clear_character_lineage(uuid) to authenticated;
grant execute on function public.get_lineage_detail(text) to anon, authenticated;

do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    alter publication supabase_realtime add table public.character_lineages, public.character_lineage_choices;
  end if;
end $$;

-- =============================================================================
-- Derived stats: the lineage layer (docs/LINEAGES_DESIGN.md section 8). Same function, new layers; with no lineage
-- selected every value is exactly what 20261015001400 returned.
-- =============================================================================
create or replace function public._proficiency_match(p_character uuid, p_item text, p_base_item text, p_group text)
returns jsonb
language sql stable
set search_path = public, pg_temp
as $$
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
    jsonb_build_object('proficient', false, 'missing_group_id', p_group,
                       'missing_group_name', (select name from public.proficiency_groups where id = p_group)));
$$;

create or replace function public.get_character_derived_stats(p_character uuid)
returns jsonb
language plpgsql stable
set search_path = public, pg_temp
as $$
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
$$;
