-- =============================================================================
-- Generic class feature engine: features unlocked by class / subclass level, optional and replacement features, structured
-- choices, subclass selection, generic class resources with rest recovery, and feature-granted proficiencies, effects,
-- spells and attacks. Foundation only: no class content (the official catalog stays empty; synthetic test content lives in
-- supabase/tests/fixtures/class_feature_engine_fixture.sql and is never part of the seeds).
--
-- Source of truth: character_classes (class version + level + subclass version) + the feature catalog + the character's
-- stored choices and optional-feature selections  =>  active features, choices, effects and resources (resolved on read).
-- Only character decisions and runtime state are stored: choice values, optional features, resource expended counts.
-- Docs: docs/CLASS_FEATURE_ENGINE.md, CLASS_FEATURE_CHOICES.md, CLASS_RESOURCES.md, SUBCLASS_FOUNDATION.md.
-- Rollback: supabase/rollback/rollback_class_features.sql.
-- =============================================================================

-- ---- catalog scope: synthetic test content is marked and never presented as official -----------------------------
alter table public.classes
  add column content_scope text not null default 'official' check (content_scope in ('official', 'test'));
alter table public.class_versions
  add column content_scope text not null default 'official' check (content_scope in ('official', 'test')),
  add column subclass_level int check (subclass_level between 1 and 20);
comment on column public.class_versions.subclass_level is
  'Class level at which the subclass is chosen (Cleric 1, Wizard 2, most classes 3). A subclass version may override it.';

-- ---- subclasses ----------------------------------------------------------------------------------------------------
create table public.subclasses (
  id            text primary key check (id ~ '^[a-z0-9]+(-[a-z0-9]+)*$'),
  class_id      text not null references public.classes (id) on delete cascade,
  name          text not null,
  content_scope text not null default 'official' check (content_scope in ('official', 'test')),
  sort_order    int  not null default 0
);
alter table public.subclass_versions
  add column subclass_id            text references public.subclasses (id) on delete cascade,
  add column class_version_id       text references public.class_versions (id) on delete cascade,  -- null: any version of the class
  add column selection_level        int check (selection_level between 1 and 20),                 -- null: the class version's level
  add column setting                text,
  add column requires_dm_permission boolean not null default false,
  add column dm_permission_note     text check (length(dm_permission_note) <= 300),
  add column content_scope          text not null default 'official' check (content_scope in ('official', 'test')),
  add column notes                  text;
alter table public.subclass_versions drop constraint subclass_versions_implementation_status_check;
alter table public.subclass_versions add constraint subclass_versions_implementation_status_check
  check (implementation_status in ('level_only', 'progression_only', 'features_partial', 'partial', 'complete'));

-- ---- feature catalog -------------------------------------------------------------------------------------------------
-- canonical feature (identity) -> feature version (the rules implementation of one source) -> unlocks (class / subclass
-- version + level). Only project-authored summaries, structured mechanics and source links are stored, never rules prose.
create table public.class_features (
  id            text primary key check (id ~ '^[a-z0-9]+(-[a-z0-9]+)*$'),
  class_id      text not null references public.classes (id) on delete cascade,
  subclass_id   text references public.subclasses (id) on delete cascade,     -- set for subclass features
  name          text not null check (length(name) between 1 and 80),
  content_scope text not null default 'official' check (content_scope in ('official', 'test'))
);

create table public.class_feature_versions (
  id                       text primary key check (id ~ '^[a-z0-9]+(-[a-z0-9]+)*$'),
  feature_id               text not null references public.class_features (id) on delete cascade,
  name                     text not null check (length(name) between 1 and 80),
  summary                  text not null check (length(summary) between 1 and 600),
  source_book_id           text references public.source_books (id),
  source_label             text not null check (length(source_label) between 1 and 120),
  source_url               text check (source_url ~ '^https://'),
  source_status            text not null default 'official'
    check (source_status in ('official', 'optional_rule', 'playtest', 'test_fixture')),
  status                   text not null default 'current' check (status in ('current', 'legacy')),
  superseded_by_version_id text references public.class_feature_versions (id) on delete set null,
  automation               text not null check (automation in ('automated', 'partially_automated', 'informational', 'unresolved')),
  automation_notes         text check (length(automation_notes) <= 600),
  activation               text not null default 'passive'
    check (activation in ('passive', 'action', 'bonus_action', 'reaction', 'special')),
  repeatable               boolean not null default false,               -- may be unlocked more than once (ASI ...)
  notes                    text check (length(notes) <= 1000),
  created_at               timestamptz not null default now(),
  updated_at               timestamptz not null default now(),
  check (superseded_by_version_id is distinct from id)
);
create index class_feature_versions_feature on public.class_feature_versions (feature_id);

create table public.class_feature_unlocks (
  id                  text primary key check (id ~ '^[a-z0-9]+(-[a-z0-9]+)*$'),
  class_version_id    text references public.class_versions (id) on delete cascade,
  subclass_version_id text references public.subclass_versions (id) on delete cascade,
  level               int  not null check (level between 1 and 20),           -- class level (also for subclass features)
  feature_version_id  text not null references public.class_feature_versions (id) on delete cascade,
  is_optional         boolean not null default false,                         -- the player opts in (optional class features)
  replaces_unlock_id  text references public.class_feature_unlocks (id) on delete cascade,
  replacement_mode    text check (replacement_mode in ('replace', 'modify')), -- replace: the replaced feature is inactive
  prerequisites       jsonb not null default '{}'::jsonb check (jsonb_typeof(prerequisites) = 'object'),
  sort_order          int  not null default 0,
  check (num_nonnulls(class_version_id, subclass_version_id) = 1),
  check ((replaces_unlock_id is null) = (replacement_mode is null)),
  check (replaces_unlock_id is distinct from id)
);
create index class_feature_unlocks_class on public.class_feature_unlocks (class_version_id) where class_version_id is not null;
create index class_feature_unlocks_subclass on public.class_feature_unlocks (subclass_version_id) where subclass_version_id is not null;

-- level scaling of a feature: one row per scaled value, thresholds by class level
create table public.class_feature_scaling (
  feature_version_id text not null references public.class_feature_versions (id) on delete cascade,
  key                text not null check (key ~ '^[a-z0-9]+(_[a-z0-9]+)*$'),
  label              text not null,
  value_type         text not null default 'number' check (value_type in ('number', 'dice', 'text')),
  table_by_level     jsonb not null check (jsonb_typeof(table_by_level) = 'array'),   -- [[level, value], ...]
  level_basis        text not null default 'class' check (level_basis in ('class', 'total')),
  unit               text,
  primary key (feature_version_id, key)
);

-- ---- choices -----------------------------------------------------------------------------------------------------------
create table public.class_feature_choices (
  id                 text primary key check (id ~ '^[a-z0-9]+(-[a-z0-9]+)*$'),
  feature_version_id text not null references public.class_feature_versions (id) on delete cascade,
  kind               text not null check (kind in ('option', 'skill', 'language', 'tool', 'weapon', 'proficiency_group',
                                                   'ability', 'spell', 'expertise', 'asi', 'free_text', 'number', 'item', 'subclass')),
  label              text not null check (length(label) between 1 and 120),
  min_picks          int  not null default 1 check (min_picks between 0 and 20),
  max_picks          int  not null default 1 check (max_picks between 1 and 20),
  level              int  not null default 1 check (level between 1 and 20),   -- class level at which the choice opens
  parent_choice_id   text,
  parent_option_id   text,
  config             jsonb not null default '{}'::jsonb check (jsonb_typeof(config) = 'object'),
  allow_free_text    boolean not null default false,
  replaceable        boolean not null default false,                 -- the rules allow changing it later (Martial Versatility ...)
  applies_to         text not null default 'always' check (applies_to in ('always', 'primary_class', 'multiclass')),
  prerequisites      jsonb not null default '{}'::jsonb check (jsonb_typeof(prerequisites) = 'object'),
  sort_order         int  not null default 0,
  check (max_picks >= min_picks),
  constraint class_feature_choice_parent check ((parent_choice_id is null) = (parent_option_id is null))
);
create index class_feature_choices_version on public.class_feature_choices (feature_version_id);

create table public.class_feature_choice_options (
  choice_id     text not null references public.class_feature_choices (id) on delete cascade,
  option_id     text not null check (option_id ~ '^[a-z0-9]+([-_][a-z0-9]+)*$'),
  label         text not null check (length(label) between 1 and 120),
  summary       text not null default '' check (length(summary) <= 400),
  option_group  text,
  data          jsonb not null default '{}'::jsonb,
  prerequisites jsonb not null default '{}'::jsonb check (jsonb_typeof(prerequisites) = 'object'),
  sort_order    int  not null default 0,
  primary key (choice_id, option_id)
);
alter table public.class_feature_choices add constraint class_feature_choices_parent_option
  foreign key (parent_choice_id, parent_option_id) references public.class_feature_choice_options (choice_id, option_id) on delete cascade;

-- ---- effects, spell grants, attack grants (one table; effect_type decides) --------------------------------------------
create table public.class_feature_effects (
  feature_version_id text not null references public.class_feature_versions (id) on delete cascade,
  seq                int  not null check (seq > 0),
  effect_type        text not null check (effect_type in (
                       'proficiency', 'expertise', 'ability_bonus', 'ac_bonus', 'ac_formula', 'attack_bonus', 'damage_bonus',
                       'save_bonus', 'initiative_bonus', 'speed_bonus', 'resistance', 'immunity', 'skill_advantage',
                       'skill_disadvantage', 'carrying_capacity_bonus', 'spell', 'attack', 'extra_attack', 'critical_range',
                       'attunement_limit', 'ritual_casting', 'spellcasting_source', 'resource_modifier', 'informational')),
  target             text,
  value              numeric,
  value_text         text,
  spell_version_id   text references public.spell_versions (id) on delete set null,
  min_level          int  not null default 1 check (min_level between 1 and 20),
  choice_id          text references public.class_feature_choices (id) on delete cascade,  -- the value(s) come from this choice
  option_choice_id   text,                                                                 -- only while this option is chosen
  option_id          text,
  applies_to         text not null default 'always' check (applies_to in ('always', 'primary_class', 'multiclass')),
  conditions         jsonb not null default '{}'::jsonb check (jsonb_typeof(conditions) = 'object'),
  automation         text not null default 'automated' check (automation in ('automated', 'partially_automated', 'informational')),
  data               jsonb not null default '{}'::jsonb check (jsonb_typeof(data) = 'object'),
  notes              text check (length(notes) <= 400),
  primary key (feature_version_id, seq),
  constraint class_feature_effect_option check ((option_choice_id is null) = (option_id is null)),
  foreign key (option_choice_id, option_id) references public.class_feature_choice_options (choice_id, option_id) on delete cascade
);

-- ---- resources -----------------------------------------------------------------------------------------------------------
create table public.class_feature_resources (
  id                  text primary key check (id ~ '^[a-z0-9]+(-[a-z0-9]+)*$'),
  feature_version_id  text not null references public.class_feature_versions (id) on delete cascade,
  name                text not null check (length(name) between 1 and 80),
  resource_type       text not null default 'uses' check (resource_type in ('uses', 'points', 'dice', 'pool')),
  max_formula         jsonb check (max_formula is null or jsonb_typeof(max_formula) = 'object'),  -- null: not calculable
  die                 text check (die ~ '^d[0-9]+$'),
  die_by_level        jsonb check (die_by_level is null or jsonb_typeof(die_by_level) = 'array'),  -- [[level, "d8"], ...]
  recharge            text not null check (recharge in ('short_rest', 'long_rest', 'short_or_long_rest', 'dawn', 'manual', 'none')),
  short_rest_recovery jsonb check (short_rest_recovery is null or jsonb_typeof(short_rest_recovery) = 'object'),
  min_level           int  not null default 1 check (min_level between 1 and 20),
  option_choice_id    text,
  option_id           text,
  activation_note     text check (length(activation_note) <= 300),
  automation          text not null default 'automated' check (automation in ('automated', 'partially_automated', 'informational')),
  notes               text check (length(notes) <= 400),
  sort_order          int  not null default 0,
  constraint class_feature_resource_option check ((option_choice_id is null) = (option_id is null)),
  foreign key (option_choice_id, option_id) references public.class_feature_choice_options (choice_id, option_id) on delete cascade
);
create index class_feature_resources_version on public.class_feature_resources (feature_version_id);

-- ---- character state ----------------------------------------------------------------------------------------------------
create table public.character_optional_features (
  character_id       uuid not null,
  character_class_id uuid not null,
  unlock_id          text not null references public.class_feature_unlocks (id) on delete cascade,
  created_by         uuid default auth.uid(),
  created_at         timestamptz not null default now(),
  primary key (character_class_id, unlock_id),
  foreign key (character_class_id, character_id) references public.character_classes (id, character_id) on delete cascade
);

create table public.character_feature_choices (
  id                 uuid primary key default gen_random_uuid(),
  character_id       uuid not null,
  character_class_id uuid not null,
  unlock_id          text not null references public.class_feature_unlocks (id) on delete cascade,
  choice_id          text not null references public.class_feature_choices (id) on delete cascade,
  manual_status      text check (manual_status in ('applied_manually', 'confirmed')),
  notes              text check (length(notes) <= 300),
  created_by         uuid default auth.uid(),
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  unique (character_class_id, unlock_id, choice_id),
  foreign key (character_class_id, character_id) references public.character_classes (id, character_id) on delete cascade
);
create index character_feature_choices_character on public.character_feature_choices (character_id);

create table public.character_feature_choice_values (
  character_choice_id uuid not null references public.character_feature_choices (id) on delete cascade,
  pick                int  not null check (pick between 1 and 20),
  value               text not null check (length(value) between 1 and 100),
  primary key (character_choice_id, pick)
);

-- class resource state reuses character_resources (maximum derived from the catalog; only the expended count is stored)
alter table public.character_resources
  add column feature_resource_id text references public.class_feature_resources (id) on delete cascade,
  add column temporary_bonus     int not null default 0 check (temporary_bonus between 0 and 99),
  add column max_adjustment      int not null default 0 check (max_adjustment between -20 and 20),
  add column last_recovered_at   timestamptz;
create unique index character_resources_feature on public.character_resources (character_class_id, feature_resource_id)
  where feature_resource_id is not null;
alter table public.character_resources add constraint character_resources_feature_class
  check (feature_resource_id is null or character_class_id is not null);
alter table public.character_resource_events add column feature_resource_id text;

-- ---- catalog integrity ----------------------------------------------------------------------------------------------------
create function public.class_feature_rows_touch()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;
create trigger class_feature_versions_touch before update on public.class_feature_versions
  for each row execute function public.class_feature_rows_touch();
create trigger character_feature_choices_touch before update on public.character_feature_choices
  for each row execute function public.class_feature_rows_touch();

-- a replaced feature belongs to the same class version, or to the parent class of the subclass; a subclass unlock belongs
-- to a subclass of the feature's class
create function public.class_feature_unlocks_before_write()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
declare r public.class_feature_unlocks; f_class text; u_class text;
begin
  select f.class_id into f_class from public.class_feature_versions v join public.class_features f on f.id = v.feature_id
  where v.id = new.feature_version_id;
  u_class := coalesce((select class_id from public.class_versions where id = new.class_version_id),
                      (select class_id from public.subclass_versions where id = new.subclass_version_id));
  if f_class is distinct from u_class then
    raise exception 'Unlock %: the feature belongs to another class', new.id using errcode = '22023';
  end if;
  if new.replaces_unlock_id is not null then
    select * into r from public.class_feature_unlocks where id = new.replaces_unlock_id;
    if not found then raise exception 'Unlock %: replaced unlock not found', new.id using errcode = '22023'; end if;
    if r.subclass_version_id is not null and r.subclass_version_id is distinct from new.subclass_version_id then
      raise exception 'Unlock %: can only replace a feature of its own subclass or of the class', new.id using errcode = '22023';
    end if;
    if r.class_version_id is not null and new.class_version_id is not null and r.class_version_id <> new.class_version_id then
      raise exception 'Unlock %: can only replace a feature of the same class version', new.id using errcode = '22023';
    end if;
    if r.class_version_id is not null and new.subclass_version_id is not null and not exists (
         select 1 from public.subclass_versions s join public.class_versions cv on cv.class_id = s.class_id
         where s.id = new.subclass_version_id and cv.id = r.class_version_id
           and (s.class_version_id is null or s.class_version_id = r.class_version_id)) then
      raise exception 'Unlock %: replaced feature belongs to another class', new.id using errcode = '22023';
    end if;
  end if;
  return new;
end;
$$;
create trigger class_feature_unlocks_before_write before insert or update on public.class_feature_unlocks
  for each row execute function public.class_feature_unlocks_before_write();

-- structured definitions only: resource formulas must be calculable (or null = informational), effect targets known
create function public.class_feature_definitions_before_write()
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
    when 'ability_bonus' then
      if not (v_kind = 'asi' or (new.target = any (abilities) and new.value between 1 and 4)) then
        raise exception 'ability_bonus needs an ability and a value, or an asi choice' using errcode = '22023'; end if;
    when 'ac_bonus', 'initiative_bonus', 'speed_bonus', 'carrying_capacity_bonus', 'extra_attack' then
      if new.value is null then raise exception '% needs a value', new.effect_type using errcode = '22023'; end if;
    when 'attack_bonus', 'damage_bonus' then
      if new.value is null then raise exception '% needs a value', new.effect_type using errcode = '22023'; end if;
      if coalesce(new.conditions ->> 'weapon', 'any') not in ('any', 'melee', 'ranged', 'one_handed_melee_only') then
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
create trigger class_feature_effects_before_write before insert or update on public.class_feature_effects
  for each row execute function public.class_feature_definitions_before_write();
create trigger class_feature_resources_before_write before insert or update on public.class_feature_resources
  for each row execute function public.class_feature_definitions_before_write();

-- ---- subclass selection rules (in addition to the 1700 checks) ------------------------------------------------------------
-- A newly chosen subclass must fit the class version and the class level. A subclass that was chosen earlier stays when the
-- level goes down or the version changes: it is then shown as inactive / needing review, never deleted.
create or replace function public.character_classes_before_write()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
declare cv public.class_versions; sv public.subclass_versions; lvl int;
begin
  select * into cv from public.class_versions where id = new.class_version_id;
  if not found then raise exception 'Unknown class version "%"', new.class_version_id using errcode = '22023'; end if;
  new.class_id := cv.class_id;
  if new.subclass_version_id is not null then
    select * into sv from public.subclass_versions where id = new.subclass_version_id;
    if not found or sv.class_id <> cv.class_id then
      raise exception 'Subclass "%" does not belong to %', new.subclass_version_id, cv.name using errcode = '22023';
    end if;
    if tg_op = 'INSERT' or new.subclass_version_id is distinct from old.subclass_version_id then
      lvl := coalesce(sv.selection_level, cv.subclass_level, 3);
      if new.level < lvl then
        raise exception '% can be chosen from % level %; this % is level %', sv.name, cv.name, lvl, cv.name, new.level
          using errcode = '22023';
      end if;
      if sv.class_version_id is not null and sv.class_version_id <> new.class_version_id then
        raise exception '% belongs to another version of %', sv.name, cv.name using errcode = '22023';
      end if;
    end if;
  end if;
  new.updated_at := now();
  return new;
end;
$$;

-- class resource state rows change only through the resource RPCs (or go with their class row)
create function public.character_resources_feature_guard()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  if coalesce(current_setting('tavern.resource_engine', true), '') = 'on' then
    return case when tg_op = 'DELETE' then old else new end;
  end if;
  if tg_op = 'INSERT' then
    if new.feature_resource_id is not null then
      raise exception 'Class resources are created by the class feature engine' using errcode = '22023';
    end if;
    return new;
  end if;
  if old.feature_resource_id is null then return case when tg_op = 'DELETE' then old else new end; end if;
  if tg_op = 'DELETE' and not exists (select 1 from public.character_classes where id = old.character_class_id) then
    return old;                                                        -- the class row is being removed
  end if;
  raise exception 'This resource comes from a class feature; use the resource actions instead' using errcode = '22023';
end;
$$;
create trigger character_resources_feature_guard before insert or update or delete on public.character_resources
  for each row execute function public.character_resources_feature_guard();

-- =============================================================================
-- Resolver (nothing resolved is stored)
-- =============================================================================

-- The character's class rows with their subclass state.
create function public._cf_class_rows(p_character uuid)
returns table (character_class_id uuid, class_id text, class_name text, class_version_id text, version_name text,
               class_level int, total_level int, is_primary boolean, subclass_version_id text, subclass_name text,
               subclass_level int, subclass_active boolean, subclass_status text, spellcasting_ability text, content_scope text)
language sql stable
set search_path = public, pg_temp
as $$
  select cc.id, cc.class_id, cl.name, cc.class_version_id, cv.name, cc.level,
         (select sum(x.level) from public.character_classes x where x.character_id = p_character)::int, cc.is_primary,
         cc.subclass_version_id, sv.name, coalesce(sv.selection_level, cv.subclass_level, 3),
         sv.id is not null and cc.level >= coalesce(sv.selection_level, cv.subclass_level, 3)
           and (sv.class_version_id is null or sv.class_version_id = cc.class_version_id),
         case when sv.id is null then 'none'
              when sv.class_version_id is not null and sv.class_version_id <> cc.class_version_id then 'incompatible'
              when cc.level < coalesce(sv.selection_level, cv.subclass_level, 3) then 'below_level'
              else 'active' end,
         coalesce(sv.spellcasting_ability, cv.spellcasting_ability), cv.content_scope
  from public.character_classes cc
  join public.class_versions cv on cv.id = cc.class_version_id
  join public.classes cl on cl.id = cc.class_id
  left join public.subclass_versions sv on sv.id = cc.subclass_version_id
  where cc.character_id = p_character;
$$;

-- Prerequisites: {"all": [...]} or {"any": [...]}; items {"type": ..., ...}. Structural types (class_level, total_level,
-- subclass, choice) are always evaluated; ability / proficiency / spell / feature need p_ctx data and are "unknown"
-- without it; "text" needs a manual confirmation. Only "unmet" blocks; unknown and manual never block.
create function public._cf_prereq(p_prereq jsonb, p_ctx jsonb)
returns jsonb
language plpgsql stable
set search_path = public, pg_temp
as $$
declare items jsonb := '[]'; it jsonb; st text; lbl text; mode text; overall text; n_unmet int; n_met int; n_other int;
begin
  if p_prereq is null or p_prereq = '{}'::jsonb then return jsonb_build_object('status', 'met', 'items', '[]'::jsonb); end if;
  mode := case when p_prereq ? 'any' then 'any' else 'all' end;
  for it in select * from jsonb_array_elements(coalesce(p_prereq -> mode, '[]')) loop
    case it ->> 'type'
      when 'class_level' then
        lbl := format('class level %s', it ->> 'min');
        st := case when (p_ctx ->> 'class_level')::int >= (it ->> 'min')::int then 'met' else 'unmet' end;
      when 'total_level' then
        lbl := format('character level %s', it ->> 'min');
        st := case when (p_ctx ->> 'total_level')::int >= (it ->> 'min')::int then 'met' else 'unmet' end;
      when 'subclass' then
        lbl := coalesce((select name from public.subclass_versions where id = it ->> 'id'), it ->> 'id');
        st := case when p_ctx ->> 'subclass_version_id' = it ->> 'id' then 'met' else 'unmet' end;
      when 'choice' then
        lbl := coalesce((select o.label from public.class_feature_choice_options o
                         where o.choice_id = it ->> 'choice' and o.option_id = it ->> 'option'), it ->> 'option');
        st := case when coalesce(p_ctx -> 'chosen', '[]') ? ((it ->> 'choice') || ':' || (it ->> 'option')) then 'met' else 'unmet' end;
      when 'ability' then
        lbl := format('%s %s', upper(it ->> 'ability'), it ->> 'min');
        st := case when p_ctx -> 'abilities' is null then 'unknown'
                   when (p_ctx -> 'abilities' ->> (it ->> 'ability'))::int >= (it ->> 'min')::int then 'met' else 'unmet' end;
      when 'proficiency' then
        lbl := format('proficiency: %s', coalesce(it ->> 'skill', it ->> 'group', it ->> 'item'));
        st := case when p_ctx -> 'proficiencies' is null then 'unknown'
                   when p_ctx -> 'proficiencies' ? coalesce(it ->> 'skill', it ->> 'group', it ->> 'item') then 'met' else 'unmet' end;
      when 'spell' then
        lbl := format('knows %s', coalesce((select name from public.spell_versions where id = it ->> 'spell'), it ->> 'spell'));
        st := case when p_ctx -> 'spells' is null then 'unknown' when p_ctx -> 'spells' ? (it ->> 'spell') then 'met' else 'unmet' end;
      when 'feature' then
        lbl := format('feature: %s', coalesce((select name from public.class_features where id = it ->> 'feature'), it ->> 'feature'));
        st := case when p_ctx -> 'features' is null then 'unknown' when p_ctx -> 'features' ? (it ->> 'feature') then 'met' else 'unmet' end;
      when 'spellcasting' then
        lbl := 'the ability to cast at least one spell';
        st := case when p_ctx -> 'can_cast' is null then 'unknown' when (p_ctx ->> 'can_cast')::boolean then 'met' else 'unmet' end;
      when 'text' then
        lbl := coalesce(it ->> 'text', 'see the source');
        st := case when coalesce((p_ctx ->> 'confirmed')::boolean, false) then 'met' else 'manual' end;
      else
        lbl := coalesce(it ->> 'type', 'unknown'); st := 'unknown';
    end case;
    items := items || jsonb_build_object('type', it ->> 'type', 'label', lbl, 'status', st);
  end loop;
  select count(*) filter (where e ->> 'status' = 'unmet'), count(*) filter (where e ->> 'status' = 'met'),
         count(*) filter (where e ->> 'status' in ('unknown', 'manual'))
  into n_unmet, n_met, n_other from jsonb_array_elements(items) e;
  if mode = 'all' then
    overall := case when n_unmet > 0 then 'unmet' when n_other > 0 then
                 case when exists (select 1 from jsonb_array_elements(items) e where e ->> 'status' = 'manual') then 'manual' else 'unknown' end
               else 'met' end;
  else
    overall := case when n_met > 0 then 'met' when n_other > 0 then
                 case when exists (select 1 from jsonb_array_elements(items) e where e ->> 'status' = 'manual') then 'manual' else 'unknown' end
               else 'unmet' end;
  end if;
  return jsonb_build_object('status', overall, 'mode', mode, 'items', items);
end;
$$;

-- Every unlock of every class row (class version and selected subclass version) with its resolved status:
-- active | locked (level) | available (optional, not selected) | replaced | subclass_inactive | prerequisite_unmet.
create function public._character_feature_unlocks(p_character uuid)
returns table (character_class_id uuid, class_id text, class_name text, class_level int, unlock_id text, feature_version_id text,
               feature_id text, feature_name text, origin text, subclass_version_id text, unlock_level int, is_optional boolean,
               opted_in boolean, replaces_unlock_id text, replacement_mode text, replaced_by text, prerequisite jsonb,
               active boolean, status text, sort_order int, is_primary boolean)
language sql stable
set search_path = public, pg_temp
as $$
  with cr as (select * from public._cf_class_rows(p_character)),
  chosen as (
    select ch.character_class_id, jsonb_agg(ch.choice_id || ':' || v.value) as vals
    from public.character_feature_choices ch join public.character_feature_choice_values v on v.character_choice_id = ch.id
    where ch.character_id = p_character group by ch.character_class_id),
  u as (
    select cr.character_class_id, cr.class_id, cr.class_name, cr.class_level, cr.total_level, cr.is_primary,
           cr.subclass_version_id as row_subclass, cr.subclass_active, x.id as unlock_id, x.feature_version_id, x.level,
           x.is_optional, x.replaces_unlock_id, x.replacement_mode, x.prerequisites, x.sort_order,
           case when x.subclass_version_id is null then 'class' else 'subclass' end as origin, x.subclass_version_id
    from cr join public.class_feature_unlocks x
      on x.class_version_id = cr.class_version_id or x.subclass_version_id = cr.subclass_version_id),
  c1 as (
    select u.*, fv.feature_id, fv.name as feature_name,
           u.class_level >= u.level as level_ok,
           (not u.is_optional or exists (select 1 from public.character_optional_features o
                                         where o.character_class_id = u.character_class_id and o.unlock_id = u.unlock_id)) as opted,
           (u.origin = 'class' or u.subclass_active) as sub_ok,
           public._cf_prereq(u.prerequisites, jsonb_build_object('class_level', u.class_level, 'total_level', u.total_level,
             'subclass_version_id', u.row_subclass, 'chosen', coalesce(ch.vals, '[]'::jsonb))) as pre
    from u join public.class_feature_versions fv on fv.id = u.feature_version_id
    left join chosen ch on ch.character_class_id = u.character_class_id),
  c2 as (select c1.*, c1.level_ok and c1.opted and c1.sub_ok and c1.pre ->> 'status' <> 'unmet' as candidate from c1),
  c3 as (
    select c2.*, (select r.unlock_id from c2 r where r.character_class_id = c2.character_class_id and r.candidate
                    and r.replaces_unlock_id = c2.unlock_id and r.replacement_mode = 'replace'
                  order by r.sort_order, r.unlock_id limit 1) as replaced_by
    from c2)
  select c3.character_class_id, c3.class_id, c3.class_name, c3.class_level, c3.unlock_id, c3.feature_version_id, c3.feature_id,
         c3.feature_name, c3.origin, c3.subclass_version_id, c3.level, c3.is_optional, c3.opted, c3.replaces_unlock_id,
         c3.replacement_mode, c3.replaced_by, c3.pre,
         c3.candidate and c3.replaced_by is null,
         case when not c3.sub_ok then 'subclass_inactive'
              when not c3.level_ok then 'locked'
              when not c3.opted then 'available'
              when c3.pre ->> 'status' = 'unmet' then 'prerequisite_unmet'
              when c3.replaced_by is not null then 'replaced'
              else 'active' end,
         c3.sort_order, c3.is_primary
  from c3;
$$;

-- Every choice instance (unlock x choice) of the character with stored values and status:
-- complete | incomplete | over_selected | optional | locked | disabled (parent option not chosen) | not_applicable
-- | inactive_preserved (values kept while the feature or choice is inactive).
create function public._character_feature_choice_rows(p_character uuid)
returns table (character_class_id uuid, class_name text, class_level int, unlock_id text, unlock_level int, choice_id text,
               feature_version_id text, feature_name text, kind text, label text, min_picks int, max_picks int, choice_level int,
               parent_choice_id text, parent_option_id text, config jsonb, allow_free_text boolean, replaceable boolean,
               applies_to text, prerequisites jsonb, sort_order int, unlock_active boolean, unlock_status text, open boolean,
               enabled boolean, applicable boolean, character_choice_id uuid, vals text[], manual_status text, status text)
language sql stable
set search_path = public, pg_temp
as $$
  with ul as (select * from public._character_feature_unlocks(p_character)),
  cr as (select * from public._cf_class_rows(p_character)),
  stored as (
    select ch.id, ch.character_class_id, ch.unlock_id, ch.choice_id, ch.manual_status,
           coalesce(array_agg(v.value order by v.pick) filter (where v.value is not null), '{}') as vals
    from public.character_feature_choices ch left join public.character_feature_choice_values v on v.character_choice_id = ch.id
    where ch.character_id = p_character group by ch.id),
  base as (
    select ul.character_class_id, ul.class_name, ul.class_level, ul.unlock_id, ul.unlock_level, c.id as choice_id,
           c.feature_version_id, ul.feature_name, c.kind, c.label,
           coalesce((select (e ->> 1)::int from jsonb_array_elements(c.config -> 'picks_by_level') e
                     where (e ->> 0)::int <= ul.class_level order by (e ->> 0)::int desc limit 1), c.min_picks) as min_picks,
           coalesce((select (e ->> 1)::int from jsonb_array_elements(c.config -> 'picks_by_level') e
                     where (e ->> 0)::int <= ul.class_level order by (e ->> 0)::int desc limit 1), c.max_picks) as max_picks,
           greatest(c.level, ul.unlock_level) as choice_level, c.parent_choice_id, c.parent_option_id, c.config,
           c.allow_free_text, c.replaceable, c.applies_to, c.prerequisites, c.sort_order, ul.active as unlock_active,
           ul.status as unlock_status,
           case c.applies_to when 'always' then true when 'primary_class' then ul.is_primary else not ul.is_primary end as applicable,
           (c.parent_choice_id is null or exists (
              select 1 from stored p where p.character_class_id = ul.character_class_id and p.unlock_id = ul.unlock_id
                and p.choice_id = c.parent_choice_id and c.parent_option_id = any (p.vals))) as enabled,
           s.id as character_choice_id,
           case when c.kind = 'subclass' then
                  case when cr.subclass_version_id is null then '{}'::text[] else array[cr.subclass_version_id] end
                else coalesce(s.vals, '{}') end as vals,
           s.manual_status
    from ul join public.class_feature_choices c on c.feature_version_id = ul.feature_version_id
    join cr on cr.character_class_id = ul.character_class_id
    left join stored s on s.character_class_id = ul.character_class_id and s.unlock_id = ul.unlock_id and s.choice_id = c.id),
  b2 as (select base.*, base.unlock_active and base.class_level >= base.choice_level and base.applicable and base.enabled as open from base)
  select b2.character_class_id, b2.class_name, b2.class_level, b2.unlock_id, b2.unlock_level, b2.choice_id, b2.feature_version_id,
         b2.feature_name, b2.kind, b2.label, b2.min_picks, b2.max_picks, b2.choice_level, b2.parent_choice_id, b2.parent_option_id,
         b2.config, b2.allow_free_text, b2.replaceable, b2.applies_to, b2.prerequisites, b2.sort_order, b2.unlock_active,
         b2.unlock_status, b2.open, b2.enabled, b2.applicable, b2.character_choice_id, b2.vals, b2.manual_status,
         case when not b2.open and cardinality(b2.vals) > 0 and b2.kind <> 'subclass' then 'inactive_preserved'
              when not b2.open then case when not b2.applicable then 'not_applicable' when not b2.enabled then 'disabled' else 'locked' end
              when cardinality(b2.vals) > b2.max_picks then 'over_selected'
              when b2.kind = 'asi' and (b2.manual_status = 'applied_manually'
                     or (cardinality(b2.vals) = 1 and b2.vals[1] like 'feat:%')
                     or (select coalesce(sum(nullif(split_part(x, ':', 2), '')::int), 0) from unnest(b2.vals) x where x !~ '^feat:')
                        = coalesce((b2.config ->> 'points')::int, 2)) then 'complete'
              when b2.kind = 'asi' then 'incomplete'
              when b2.min_picks = 0 and cardinality(b2.vals) = 0 then 'optional'
              when cardinality(b2.vals) >= b2.min_picks then 'complete'
              else 'incomplete' end
  from b2;
$$;

-- Equipment facts the feature conditions need (armor worn, its category, shield).
create function public._cf_equipment(p_character uuid)
returns table (armor_worn boolean, armor_category text, shield boolean)
language sql stable
set search_path = public, pg_temp
as $$
  select coalesce(bool_or(e.slot_id = 'armor' and st.base_ac is not null and not st.is_shield), false),
         max(case when e.slot_id = 'armor' then coalesce(it.category_id, (select b.category_id from public.items b where b.id = it.base_item_id)) end),
         coalesce(bool_or(e.slot_id = 'shield'), false)
  from public.character_equipment e
  join public.inventory_items ii on ii.id = e.inventory_item_id
  left join public.items it on it.id = ii.item_id
  left join lateral (select s.* from public.armor_stats s where s.item_id in (it.id, it.base_item_id)
                     order by s.item_id = it.id desc limit 1) st on true
  where e.character_id = p_character and e.slot_id in ('armor', 'shield');
$$;

-- One row per effect of every unlocked feature (choice values substituted), with its activation:
-- feature_active (the feature is active) and active (the effect applies now) + inactive_reason.
create function public._character_class_effects(p_character uuid)
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
                       when 'skill' then 'skill' when 'expertise' then 'skill'
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
         x.seq, x.pick, x.effect_type, x.target, x.value, x.value_text, x.spell_version_id, x.min_level, x.conditions, x.data,
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
  join cr on cr.character_class_id = x.character_class_id;
$$;

-- Current value of a scaling table at a level ([[level, value], ...]) and the next threshold.
create function public._cf_scale(p_table jsonb, p_level int)
returns jsonb
language sql immutable
set search_path = public, pg_temp
as $$
  select jsonb_build_object(
    'value', (select e -> 1 from jsonb_array_elements(p_table) e where (e ->> 0)::int <= p_level order by (e ->> 0)::int desc limit 1),
    'next_level', (select (e ->> 0)::int from jsonb_array_elements(p_table) e where (e ->> 0)::int > p_level order by (e ->> 0)::int limit 1),
    'next_value', (select e -> 1 from jsonb_array_elements(p_table) e where (e ->> 0)::int > p_level order by (e ->> 0)::int limit 1));
$$;

-- Class resources of the character: active grants plus inactive ones that still have stored state.
create function public._character_feature_resources(p_character uuid, p_mods jsonb)
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

-- =============================================================================
-- Integration with the existing layers (same signatures; with no class features every result is unchanged)
-- =============================================================================

-- item effects + class feature effects that the derived-stats core understands (ability, AC, saves, speed, resistance, skills)
create or replace function public._character_effects(p_character uuid)
returns table (source_type text, source_id uuid, item_id text, source_name text, modifier_id text, seq int,
               effect_type text, value numeric, target text, activation text, stacking text, stack_group text,
               scope text, active boolean, inactive_reason text, applied boolean)
language sql stable
set search_path = public, pg_temp
as $$
  with owned as (
    select ii.id, ii.item_id, ii.is_attuned, coalesce(ii.custom_name, it.name) as name, it.kind_id, it.requires_attunement, e.slot_id
    from public.inventories inv
    join public.inventory_items ii on ii.inventory_id = inv.id
    join public.items it on it.id = ii.item_id                       -- RLS: effects of invisible items do not exist
    left join public.character_equipment e on e.inventory_item_id = ii.id and e.character_id = p_character
    where inv.character_id = p_character
  ),
  worn as (
    select coalesce(bool_or(slot_id = 'armor'), false) as has_armor, coalesce(bool_or(slot_id = 'shield'), false) as has_shield
    from public.character_equipment where character_id = p_character
  ),
  raw as (
    select 'item_effect'::text as source_type, o.id as source_id, o.item_id, o.name as source_name, null::text as modifier_id, ie.seq,
           ie.effect_type, ie.value, ie.target, ie.activation, ie.stacking, ie.stack_group, ie.priority,
           case when ie.effect_type in ('attack_bonus', 'damage_bonus') and o.kind_id = 'weapon' then 'self' else 'global' end as scope,
           coalesce(
             case ie.activation
               when 'equipped' then case when o.slot_id is null then 'not_equipped' end
               when 'attuned' then case when not o.is_attuned then 'not_attuned' end
               when 'equipped_and_attuned' then case when o.slot_id is null then 'not_equipped' when not o.is_attuned then 'not_attuned' end
             end,
             case when ie.conditions ->> 'no_armor' = 'true' and w.has_armor then 'wearing_armor'
                  when ie.conditions ->> 'no_shield' = 'true' and w.has_shield then 'using_shield' end) as inactive_reason
    from owned o
    join public.item_effects ie on ie.item_id = o.item_id
    cross join worn w
    union all
    select 'modifier', o.id, o.item_id, o.name || ' (' || md.name || ')', md.id, me.seq,
           me.effect_type, me.value, null,
           case when coalesce(md.requires_attunement_override, o.requires_attunement) then 'equipped_and_attuned' else 'equipped' end,
           'additive', null, 0,
           case when me.effect_type in ('attack_bonus', 'damage_bonus') then 'self' else 'global' end,
           case when o.slot_id is null then 'not_equipped'
                when coalesce(md.requires_attunement_override, o.requires_attunement) and not o.is_attuned then 'not_attuned' end
    from owned o
    join public.inventory_item_modifiers im on im.inventory_item_id = o.id
    join public.item_modifiers md on md.id = im.modifier_id
    join public.item_modifier_effects me on me.modifier_id = md.id
    union all
    -- class feature effects (20261015001800); only active features, the effect's own conditions decide inactive_reason
    select 'class_feature', ce.character_class_id, null, ce.class_name || ': ' || ce.feature_name,
           ce.unlock_id || ':' || ce.seq || ':' || coalesce(ce.pick, 0), ce.seq,
           ce.effect_type, ce.value, case when ce.effect_type = 'resistance' then coalesce(ce.target, ce.value_text) else ce.target end,
           'owned', 'additive', null, 0, 'global',
           case when ce.active then null else coalesce(ce.inactive_reason, 'inactive') end
    from public._character_class_effects(p_character) ce
    where ce.feature_active and ce.automation <> 'informational'
      and ce.effect_type in ('ability_bonus', 'ac_bonus', 'save_bonus', 'speed_bonus', 'resistance', 'skill_advantage',
                             'skill_disadvantage', 'carrying_capacity_bonus')
  ),
  ranked as (
    select r.*, r.inactive_reason is null as active,
           row_number() over (
             partition by r.inactive_reason is null, r.effect_type, coalesce(r.target, ''), r.scope,
                          case when r.scope = 'self' then r.source_id::text else '' end,
                          case r.stacking when 'additive' then r.source_type || r.source_id || coalesce(r.modifier_id, '') || r.seq
                                          when 'non_stacking_group' then 'group:' || r.stack_group
                                          else r.stacking end
             order by r.value desc nulls last, r.priority desc, r.source_id) as rn
    from raw r
  )
  select source_type, source_id, item_id, source_name, modifier_id, seq, effect_type, value, target, activation, stacking, stack_group,
         scope, active, inactive_reason, active and rn = 1 as applied
  from ranked;
$$;

-- proficiency match: manual rows, then lineage, then class feature grants (20261015001800)
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
$$;

-- skill level stored on the character: {"proficient": bool, "expertise": bool} or 0 / 1 / 2
create function public._skill_level(p_value jsonb)
returns int
language sql immutable
set search_path = public, pg_temp
as $$
  select case jsonb_typeof(p_value)
           when 'number' then least(greatest(p_value::text::int, 0), 2)
           when 'object' then case when coalesce((p_value ->> 'expertise')::boolean, false) then 2
                                   when coalesce((p_value ->> 'proficient')::boolean, false) then 1 else 0 end
           when 'boolean' then case when p_value::text = 'true' then 1 else 0 end
           else 0 end;
$$;

-- ---- derived stats: the class feature layer on top of the 1700 result ----------------------------------------------------
-- Resolution order (docs/CLASS_FEATURE_ENGINE.md): stored base data -> class levels (PB) -> lineage -> items -> class
-- feature effects that are additive (via _character_effects, inside the core) -> class proficiencies (via
-- _proficiency_match, inside the core) -> this layer: skill / save proficiency and expertise, weapon-conditional attack
-- and damage bonuses, feature attacks, attack count, critical range, initiative, unarmored AC formulas -> manual overrides.
alter function public.get_character_derived_stats(uuid) rename to _derived_stats_levels;
create function public.get_character_derived_stats(p_character uuid)
returns jsonb
language plpgsql stable
set search_path = public, pg_temp
as $$
declare d jsonb; eff jsonb; c public.characters; pb int; mods jsonb; k text; e jsonb; skills jsonb; saves jsonb; profs jsonb := '[]';
  weapons jsonb := '[]'; w jsonb; atk int; dmg int; parts_a jsonb; parts_d jsonb; one_weapon boolean; n_weapons int; attacks jsonb := '[]';
  ab text; ab_mod int; dice text; dbonus int; ac jsonb; cand jsonb; best_val int; base_now int; f_parts jsonb; extra jsonb; crit jsonb;
  init_parts jsonb; init_total int; langs jsonb; man int; applied jsonb := '[]'; info jsonb := '[]'; cond text;
begin
  d := public._derived_stats_levels(p_character);                  -- RLS: owner, campaign DM, admin
  select coalesce(jsonb_agg(to_jsonb(x) order by x.class_id, x.unlock_id, x.seq, x.pick), '[]') into eff
  from public._character_class_effects(p_character) x where x.feature_active;
  if eff = '[]'::jsonb then
    return d || jsonb_build_object('class_features', jsonb_build_object('applied', '[]'::jsonb, 'informational', '[]'::jsonb),
                                   'attacks_per_action', jsonb_build_object('value', 1, 'sources', '[]'::jsonb),
                                   'critical_range', jsonb_build_object('value', 20, 'sources', '[]'::jsonb),
                                   'feature_attacks', '[]'::jsonb);
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
           where (x ->> 'active')::boolean and x ->> 'effect_type' = 'expertise' loop
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
  for e in select x from jsonb_array_elements(eff) x where (x ->> 'active')::boolean and x ->> 'effect_type' = 'attack' loop
    ab := coalesce(e -> 'data' ->> 'ability', 'str');
    ab := case ab when 'finesse' then case when (mods ->> 'dex')::int > (mods ->> 'str')::int then 'dex' else 'str' end
                  when 'spell' then coalesce(e ->> 'spellcasting_ability', 'int') else ab end;
    ab_mod := case when ab = 'none' then 0 else (mods ->> ab)::int end;
    dice := coalesce((select y ->> 1 from jsonb_array_elements(e -> 'data' -> 'dice_by_level') y
                      where (y ->> 0)::int <= (e ->> 'class_level')::int order by (y ->> 0)::int desc limit 1), e -> 'data' ->> 'damage_dice');
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

  -- initiative
  init_parts := coalesce(d -> 'initiative' -> 'sources', '[]');
  init_total := coalesce((d -> 'initiative' ->> 'bonus')::int, 0);
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
    'attacks_per_action', extra, 'critical_range', crit, 'armor_class', ac,
    'initiative', jsonb_build_object('bonus', init_total, 'sources', init_parts),
    'immunities', coalesce(d -> 'immunities', '[]') || coalesce((select jsonb_agg(distinct coalesce(x ->> 'target', x ->> 'value_text'))
                    from jsonb_array_elements(eff) x where (x ->> 'active')::boolean and x ->> 'effect_type' = 'immunity'), '[]'),
    'class_features', jsonb_build_object('applied', applied, 'warnings', info,
      'resolution_order', jsonb_build_array('stored base data', 'class levels and proficiency bonus', 'lineage', 'items',
        'class feature effects', 'manual overrides')));
end;
$$;

-- ---- spellbook: feature spell grants are their own source per class row ---------------------------------------------------
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

alter function public.get_character_spellbook(uuid) rename to _spellbook_core;
create function public.get_character_spellbook(p_character uuid)
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

-- ---- class summary: the old resource list keeps manual resources only; class resources have their own read model ----------
create or replace function public._character_resource_rows(p_character uuid, p_mods jsonb)
returns jsonb
language sql stable
set search_path = public, pg_temp
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', r.id, 'resource_key', r.resource_key, 'name', r.name, 'source_type', r.source_type, 'source_id', r.source_id,
           'character_class_id', r.character_class_id, 'die', r.die, 'recharge', r.recharge, 'unlock_level', r.unlock_level,
           'spell_version_id', r.spell_version_id, 'cast_level', r.cast_level, 'active', r.active, 'notes', r.notes,
           'unlocked', r.unlock_level is null or coalesce(cc.level, (l.li ->> 'total_level')::int) >= r.unlock_level,
           'max', m ->> 'max', 'unlimited', (m ->> 'unlimited')::boolean, 'expended', r.expended,
           'remaining', case when (m ->> 'unlimited')::boolean then null else greatest((m ->> 'max')::int - r.expended, 0) end,
           'max_formula', r.max_formula) order by r.name), '[]')
  from public.character_resources r
  left join public.character_classes cc on cc.id = r.character_class_id
  cross join (select public._character_level_info(p_character) as li) l
  cross join lateral (select public._resource_max(r.max_formula, jsonb_build_object(
                        'total_level', (l.li ->> 'total_level')::int, 'class_level', cc.level,
                        'proficiency_bonus', (l.li ->> 'proficiency_bonus')::int, 'mods', p_mods)) as m) x
  where r.character_id = p_character and r.feature_resource_id is null;
$$;

alter function public.get_character_class_summary(uuid) rename to _class_summary_core;
create function public.get_character_class_summary(p_character uuid)
returns jsonb
language sql stable
set search_path = public, pg_temp
as $$
  select public._class_summary_core(p_character) || jsonb_build_object(
    'scope', 'Class and Spellcasting Foundation + Class Feature Engine',
    'limitations', jsonb_build_array(
      'Class features come from the class feature catalog; no official class content is in the catalog yet.',
      'Known and prepared limits are shown; only spell level and the prepared limit are enforced.',
      'Mystic Arcanum, Font of Magic, Arcane Recovery and Wild Shape are not implemented.',
      'Multiclass prerequisites are warnings only.'));
$$;

-- =============================================================================
-- Read models
-- =============================================================================

-- Every resource of the character: class resources (derived maximum) and manual resources (character_resources rows).
create function public.get_character_resources(p_character uuid)
returns jsonb
language plpgsql stable
set search_path = public, pg_temp
as $$
declare mods jsonb; manual jsonb;
begin
  perform 1 from public.characters where id = p_character;                    -- RLS: owner, campaign DM, admin
  if not found then raise exception 'Character not found' using errcode = '42501'; end if;
  mods := public._character_mods(p_character);
  select coalesce(jsonb_agg(r || jsonb_build_object('key', 'r:' || (r ->> 'id'), 'kind', 'manual', 'automation', 'manual',
           'feature_name', null, 'class_name', null, 'max_known', true, 'temporary_bonus', 0, 'max_adjustment', 0,
           'active', (r ->> 'active')::boolean and (r ->> 'unlocked')::boolean,
           'max', (r ->> 'max')::int)), '[]')
  into manual from jsonb_array_elements(public._character_resource_rows(p_character, mods)) r;
  return jsonb_build_object('character_id', p_character,
    'resources', public._character_feature_resources(p_character, mods) || manual,
    'recharge_labels', jsonb_build_object('short_rest', 'Recovers on a short rest', 'long_rest', 'Recovers on a long rest',
      'short_or_long_rest', 'Recovers on a short or long rest', 'dawn', 'Recovers at dawn (not automatic)',
      'manual', 'Recovers only when restored by hand', 'none', 'Does not recover'));
end;
$$;

-- Validation of choice values. Returns null when valid, otherwise a user-facing message.
-- p_strict = false (import): only structural checks (options exist, value format); proficiency-based checks are skipped.
create function public._cf_choice_error(p_character uuid, p_character_class uuid, p_unlock text, p_choice public.class_feature_choices,
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
  if p_choice.kind = 'number' and cfg ? 'total' and n > 0 then
    select sum(split_part(x, ':', 2)::int) into total from unnest(p_values) x;
    if total > (cfg ->> 'total')::int then return format('at most %s in total', cfg ->> 'total'); end if;
  end if;
  return null;
end;
$$;

-- The authoritative class feature read model for the sheet. Read only; RLS applies.
create function public.get_character_class_features(p_character uuid)
returns jsonb
language plpgsql stable
set search_path = public, pg_temp
as $$
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
                                 case when v ~ '^feat:' then 'Feat: ' || substr(v, 6) when v ~ '^text:' then substr(v, 6)
                                      when v ~ '^(str|dex|con|int|wis|cha):[0-9]+$' then upper(split_part(v, ':', 1)) || ' +' || split_part(v, ':', 2) end,
                                 v),
                                 'prerequisite', (select public._cf_prereq(o.prerequisites, ctx || jsonb_build_object('class_level', ch.class_level,
                                                    'total_level', (li ->> 'total_level')::int, 'subclass_version_id', cr.subclass_version_id,
                                                    'confirmed', ch.manual_status = 'confirmed'))
                                                  from public.class_feature_choice_options o where o.choice_id = ch.choice_id and o.option_id = v))
                                 order by ord), '[]') from unnest(ch.vals) with ordinality u(v, ord)),
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
             'activation', fv.activation, 'repeatable', fv.repeatable, 'prerequisite', u.prerequisite,
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
             'implementation_status', s.implementation_status,
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
$$;

-- =============================================================================
-- Write path
-- =============================================================================

-- The class row of a character, locked; raises when it does not belong to an accessible character.
create function public._cf_class_row(p_character uuid, p_character_class uuid)
returns public.character_classes
language plpgsql
set search_path = public, pg_temp
as $$
declare cc public.character_classes;
begin
  if auth.uid() is null or not public.can_access_character(p_character) then
    raise exception 'Character not found' using errcode = '42501';
  end if;
  perform 1 from public.characters where id = p_character for update;       -- one feature change per character at a time
  select * into cc from public.character_classes where id = p_character_class and character_id = p_character;
  if not found then raise exception 'Character class not found' using errcode = '42501'; end if;
  return cc;
end;
$$;

create function public.set_character_feature_choice(p_character uuid, p_character_class uuid, p_unlock text, p_choice text,
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

create function public.set_character_optional_feature(p_character uuid, p_character_class uuid, p_unlock text, p_enabled boolean)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare cc public.character_classes; u public.class_feature_unlocks;
begin
  cc := public._cf_class_row(p_character, p_character_class);
  select * into u from public.class_feature_unlocks where id = p_unlock;
  if not found or not (u.class_version_id = cc.class_version_id or u.subclass_version_id = cc.subclass_version_id) then
    raise exception 'This feature does not belong to this class' using errcode = '22023';
  end if;
  if not u.is_optional then raise exception 'This feature is not optional' using errcode = '22023'; end if;
  if coalesce(p_enabled, false) then
    if cc.level < u.level then
      raise exception 'This optional feature opens at class level %', u.level using errcode = '22023';
    end if;
    insert into public.character_optional_features (character_id, character_class_id, unlock_id, created_by)
    values (p_character, p_character_class, p_unlock, auth.uid()) on conflict do nothing;
  else
    delete from public.character_optional_features where character_class_id = p_character_class and unlock_id = p_unlock;
  end if;
  return public.get_character_class_features(p_character);
end;
$$;

-- Subclass selection goes through set_character_class (it also creates / updates the subclass spellcasting source).
create function public.set_character_subclass(p_character uuid, p_character_class uuid, p_subclass_version text)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare cc public.character_classes;
begin
  cc := public._cf_class_row(p_character, p_character_class);
  perform public.set_character_class(p_character, cc.class_version_id, cc.level, nullif(btrim(p_subclass_version), ''), null, cc.id);
  return public.get_character_class_features(p_character);
end;
$$;

-- Resources: one change path for class and manual resources. Keys: "f:<character class id>:<resource id>" | "r:<resource uuid>".
create function public._resource_change(p_character uuid, p_key text, p_mode text, p_amount int, p_expended int,
                                        p_temporary_bonus int, p_max_adjustment int, p_reason text)
returns jsonb
language plpgsql
set search_path = public, pg_temp
as $$
declare me jsonb; st public.character_resources; before int; after int; cap int; ccid uuid; rid text; mods jsonb; out jsonb; uid uuid;
begin
  if auth.uid() is null or not public.can_access_character(p_character) then
    raise exception 'Character not found' using errcode = '42501';
  end if;
  if p_mode in ('expend', 'restore') and (p_amount is null or p_amount < 1 or p_amount > 99) then
    raise exception 'The amount is between 1 and 99' using errcode = '22023';
  end if;
  if p_mode = 'set' and coalesce(btrim(p_reason), '') = '' then
    raise exception 'A manual correction needs a reason' using errcode = '22023';
  end if;
  perform 1 from public.characters where id = p_character for update;         -- serializes resource changes of this character
  mods := public._character_mods(p_character);
  perform set_config('tavern.resource_engine', 'on', true);

  if p_key ~ '^f:[0-9a-f-]{36}:[a-z0-9-]+$' then
    ccid := split_part(p_key, ':', 2)::uuid; rid := split_part(p_key, ':', 3);
    select x into me from jsonb_array_elements(public._character_feature_resources(p_character, mods)) x where x ->> 'key' = p_key;
    if me is null then raise exception 'This resource is not granted to this character' using errcode = '22023'; end if;
    if p_mode = 'expend' and not (me ->> 'active')::boolean then
      raise exception '% is not available (%)', me ->> 'name', coalesce(me ->> 'inactive_reason', 'inactive') using errcode = '22023';
    end if;
    insert into public.character_resources (character_id, resource_key, name, source_type, source_id, character_class_id,
                                            feature_resource_id, recharge, max_formula, created_by)
    values (p_character, 'cf-' || rid, me ->> 'name', case when me ->> 'origin' = 'subclass' then 'subclass' else 'class' end,
            me ->> 'feature_version_id', ccid, rid,
            case when me ->> 'recharge' in ('short_rest', 'long_rest', 'short_or_long_rest', 'dawn', 'manual', 'none') then me ->> 'recharge' else 'none' end,
            coalesce(me -> 'max_formula', '{"fixed": 0}'::jsonb), auth.uid())
    on conflict (character_class_id, feature_resource_id) where feature_resource_id is not null do nothing;
    select * into st from public.character_resources where character_class_id = ccid and feature_resource_id = rid for update;
  elsif p_key ~ '^r:[0-9a-f-]{36}$' then
    select * into st from public.character_resources where id = substr(p_key, 3)::uuid and character_id = p_character for update;
    if st.id is null or st.feature_resource_id is not null then raise exception 'Resource not found' using errcode = '42501'; end if;
    select x into me from jsonb_array_elements(public._character_resource_rows(p_character, mods)) x where x ->> 'id' = st.id::text;
    me := me || jsonb_build_object('active', (me ->> 'active')::boolean and (me ->> 'unlocked')::boolean, 'temporary_bonus', 0,
                                   'max_adjustment', 0, 'max_known', true);
    if p_mode = 'expend' and not (me ->> 'active')::boolean then
      raise exception '% is not available', st.name using errcode = '22023';
    end if;
  else
    raise exception 'Unknown resource key "%"', p_key using errcode = '22023';
  end if;

  before := st.expended;
  cap := case when (me ->> 'unlimited')::boolean or not coalesce((me ->> 'max_known')::boolean, true) then null
              when st.feature_resource_id is not null then (me ->> 'max')::int
              else (me ->> 'max')::int end;
  if p_mode = 'expend' then
    if cap is not null and before + p_amount > cap then
      raise exception 'Not enough % left (% of %)', me ->> 'name', greatest(cap - before, 0), cap using errcode = '22023';
    end if;
    after := case when (me ->> 'unlimited')::boolean then 0 else before + p_amount end;
  elsif p_mode = 'restore' then
    if before - p_amount < 0 then raise exception 'Nothing of % to restore', me ->> 'name' using errcode = '22023'; end if;
    after := before - p_amount;
  else
    if p_temporary_bonus is not null and st.feature_resource_id is not null then
      update public.character_resources set temporary_bonus = p_temporary_bonus where id = st.id;
    end if;
    if p_max_adjustment is not null and st.feature_resource_id is not null then
      update public.character_resources set max_adjustment = p_max_adjustment where id = st.id;
    end if;
    if st.feature_resource_id is not null and (p_temporary_bonus is not null or p_max_adjustment is not null) then
      select x into me from jsonb_array_elements(public._character_feature_resources(p_character, mods)) x where x ->> 'key' = p_key;
      cap := case when (me ->> 'unlimited')::boolean or not (me ->> 'max_known')::boolean then null else (me ->> 'max')::int end;
    end if;
    after := coalesce(p_expended, before);
    if after < 0 or (cap is not null and after > cap) then
      raise exception 'Used must be between 0 and %', coalesce(cap::text, 'the maximum') using errcode = '22023';
    end if;
  end if;
  update public.character_resources set expended = after where id = st.id;
  insert into public.character_resource_events (character_id, event_type, pool, resource_id, feature_resource_id, amount,
                                                expended_before, expended_after, reason, details)
  values (p_character, case p_mode when 'expend' then 'expend' when 'restore' then 'restore' else 'manual_set' end, 'resource',
          st.id, st.feature_resource_id, case when p_mode = 'set' then null else p_amount end, before, after,
          nullif(btrim(p_reason), ''), jsonb_build_object('key', p_key, 'temporary_bonus', p_temporary_bonus, 'max_adjustment', p_max_adjustment));
  perform set_config('tavern.resource_engine', 'off', true);
  select x into out from jsonb_array_elements((public.get_character_resources(p_character)) -> 'resources') x where x ->> 'key' = p_key;
  return out;
end;
$$;

create function public.expend_character_resource(p_character uuid, p_resource_key text, p_amount int default 1, p_reason text default null)
returns jsonb language sql security definer set search_path = public, pg_temp
as $$ select public._resource_change(p_character, p_resource_key, 'expend', p_amount, null, null, null, p_reason) $$;
create function public.restore_character_resource(p_character uuid, p_resource_key text, p_amount int default 1, p_reason text default null)
returns jsonb language sql security definer set search_path = public, pg_temp
as $$ select public._resource_change(p_character, p_resource_key, 'restore', p_amount, null, null, null, p_reason) $$;
-- authorized manual correction (distinct event type, reason required); also sets a temporary bonus or a maximum adjustment
create function public.set_character_resource_state(p_character uuid, p_resource_key text, p_expended int, p_reason text,
                                                    p_temporary_bonus int default null, p_max_adjustment int default null)
returns jsonb language sql security definer set search_path = public, pg_temp
as $$ select public._resource_change(p_character, p_resource_key, 'set', null, p_expended, p_temporary_bonus, p_max_adjustment, p_reason) $$;

-- ---- rests: class resources join the existing rest engine (same keys as before + a breakdown) -----------------------------
-- Short rest: Pact Magic slots, short-rest resources (and the short-rest part of long-rest resources), short-rest trackers.
-- Long rest: standard and Pact slots, all short / long / short-or-long resources, all trackers, manual slots; temporary
-- slots and temporary resource bonuses end. Dawn, manual and non-recovering resources are listed as not restored.
create or replace function public._rest(p_character uuid, p_kind text, p_rest_id uuid)
returns jsonb
language plpgsql
set search_path = public, pg_temp
as $$
declare std jsonb := '[]'; pact int := 0; res jsonb := '[]'; trk jsonb := '[]'; legacy int := 0; tmp int := 0; out jsonb; rid uuid;
  prev jsonb; mods jsonb; r jsonb; amt int; restored jsonb := '[]'; not_restored jsonb := '[]'; std_total int; m record;
begin
  if auth.uid() is null or not public.can_access_character(p_character) then
    raise exception 'Character not found' using errcode = '42501';
  end if;
  perform 1 from public.characters where id = p_character for update;
  rid := coalesce(p_rest_id, gen_random_uuid());
  select details into prev from public.character_resource_events
  where character_id = p_character and rest_id = rid and event_type in ('short_rest', 'long_rest');
  if found then return prev || jsonb_build_object('already_applied', true); end if;
  mods := public._character_mods(p_character);
  perform set_config('tavern.resource_engine', 'on', true);

  if p_kind = 'long' then
    with u as (update public.character_spell_slot_state set expended = 0
               where character_id = p_character and pool = 'standard' and expended > 0 returning slot_level, expended)
    select coalesce(jsonb_agg(jsonb_build_object('slot_level', slot_level, 'restored', expended) order by slot_level), '[]') into std from u;
  end if;
  with u as (update public.character_spell_slot_state set expended = 0
             where character_id = p_character and pool = 'pact' and expended > 0 returning expended)
  select coalesce(sum(expended), 0) into pact from u;

  -- class resources (catalog recharge rules)
  for r in select x from jsonb_array_elements(public._character_feature_resources(p_character, mods)) x loop
    if not (r ->> 'active')::boolean then
      if (r ->> 'expended')::int > 0 then
        not_restored := not_restored || jsonb_build_object('name', r ->> 'name', 'reason', 'inactive');
      end if;
      continue;
    end if;
    if r ->> 'recharge' = 'short_or_long_rest' or (p_kind = 'short' and r ->> 'recharge' = 'short_rest')
       or (p_kind = 'long' and r ->> 'recharge' in ('short_rest', 'long_rest')) then
      amt := (r ->> 'expended')::int;
    elsif p_kind = 'short' and r ->> 'recharge' = 'long_rest' and r ->> 'short_rest_recovery' is not null then
      amt := least((r ->> 'expended')::int, (r ->> 'short_rest_recovery')::int);
    else
      not_restored := not_restored || jsonb_build_object('name', r ->> 'name', 'reason', r ->> 'recharge');
      continue;
    end if;
    if amt > 0 then
      update public.character_resources set expended = expended - amt, last_recovered_at = now() where id = (r ->> 'state_id')::uuid;
      restored := restored || jsonb_build_object('kind', 'resource', 'name', r ->> 'name', 'amount', amt, 'key', r ->> 'key',
                                                 'partial', (r ->> 'expended')::int > amt);
      res := res || to_jsonb(r ->> 'name');
    end if;
  end loop;
  if p_kind = 'long' then
    update public.character_resources set temporary_bonus = 0
    where character_id = p_character and feature_resource_id is not null and temporary_bonus > 0;
  end if;

  -- manual resources (their own recharge column, as in 20261015001700)
  with b as (select id, name, expended from public.character_resources
             where character_id = p_character and feature_resource_id is null and expended > 0
               and recharge in (case when p_kind = 'long' then 'long_rest' else 'short_rest' end, 'short_rest', 'short_or_long_rest')),
  u as (update public.character_resources x set expended = 0, last_recovered_at = now() from b where x.id = b.id returning b.name, b.expended)
  select restored || coalesce(jsonb_agg(jsonb_build_object('kind', 'resource', 'name', u.name, 'amount', u.expended, 'manual', true)
                                        order by u.name), '[]'),
         res || coalesce(jsonb_agg(to_jsonb(u.name) order by u.name), '[]')
  into restored, res from u;
  select not_restored || coalesce(jsonb_agg(jsonb_build_object('name', r.name, 'reason', r.recharge) order by r.name), '[]')
  into not_restored
  from public.character_resources r
  where r.character_id = p_character and r.feature_resource_id is null and r.expended > 0
    and r.recharge not in (case when p_kind = 'long' then 'long_rest' else 'short_rest' end, 'short_rest', 'short_or_long_rest');

  with u as (update public.feature_trackers set current = max
             where character_id = p_character and current <> max
               and (reset_on = 'short' or (p_kind = 'long' and reset_on = 'long'))
             returning name)
  select coalesce(jsonb_agg(name order by name), '[]') into trk from u;
  if p_kind = 'long' then
    with u as (update public.spell_slots set used = 0 where character_id = p_character and used > 0 returning 1)
    select count(*) into legacy from u;
  else
    select coalesce(sum(expended), 0) into std_total from public.character_spell_slot_state
    where character_id = p_character and pool = 'standard' and expended > 0;
    if std_total > 0 then
      not_restored := jsonb_build_array(jsonb_build_object('name', 'Standard spell slots', 'reason', 'long_rest', 'amount', std_total))
                      || not_restored;
    end if;
  end if;
  with d as (delete from public.character_temporary_spell_slots
             where character_id = p_character and (expires_on = 'short_rest' or (p_kind = 'long' and expires_on = 'long_rest'))
             returning 1)
  select count(*) into tmp from d;
  perform set_config('tavern.resource_engine', 'off', true);

  if pact > 0 then
    restored := jsonb_build_array(jsonb_build_object('kind', 'pact', 'name', 'Pact Magic', 'amount', pact, 'unit', 'slots')) || restored;
  end if;
  if jsonb_array_length(std) > 0 then
    restored := jsonb_build_array(jsonb_build_object('kind', 'standard', 'name', 'Spell slots',
                  'amount', (select sum((x ->> 'restored')::int) from jsonb_array_elements(std) x), 'unit', 'slots', 'levels', std)) || restored;
  end if;
  restored := restored || coalesce((select jsonb_agg(jsonb_build_object('kind', 'tracker', 'name', x)) from jsonb_array_elements_text(trk) x), '[]');

  out := jsonb_build_object('rest', p_kind, 'rest_id', rid, 'already_applied', false,
    'restored', jsonb_build_object('standard_slots', std, 'pact_slots', pact, 'resources', res, 'trackers', trk,
                                   'legacy_manual_slot_levels', legacy, 'temporary_slots_removed', tmp),
    'breakdown', jsonb_build_object('restored', restored, 'not_restored', not_restored),
    'not_handled', case when p_kind = 'long'
                        then jsonb_build_array('hit points, temporary HP, death saves and hit dice (applied by the app as before)',
                                               'conditions', 'prepared spell changes (change them yourself)', 'dawn resources')
                        else jsonb_build_array('standard spell slots', 'hit dice spending', 'hit points') end);
  insert into public.character_resource_events (character_id, event_type, pool, rest_id, details)
  values (p_character, p_kind || '_rest', 'rest', rid, out);
  return out;
end;
$$;

-- =============================================================================
-- Level change and class version change review (read only: computed in a rolled-back savepoint)
-- =============================================================================
create function public._cf_diff(p_before jsonb, p_after jsonb, p_class uuid, p_slots_before jsonb, p_slots_after jsonb,
                                p_sum_before jsonb, p_sum_after jsonb)
returns jsonb
language sql stable
set search_path = public, pg_temp
as $$
  with kb as (select k from jsonb_array_elements(p_before -> 'classes') k where k ->> 'id' = p_class::text),
       ka as (select k from jsonb_array_elements(p_after -> 'classes') k where k ->> 'id' = p_class::text),
       fb as (select f from kb, jsonb_array_elements(kb.k -> 'features') f),
       fa as (select f from ka, jsonb_array_elements(ka.k -> 'features') f),
       cb as (select c from kb, jsonb_array_elements(kb.k -> 'choices') c),
       ca as (select c from ka, jsonb_array_elements(ka.k -> 'choices') c),
       rb as (select r from jsonb_array_elements(p_before -> 'resources') r where r ->> 'character_class_id' = p_class::text),
       ra as (select r from jsonb_array_elements(p_after -> 'resources') r where r ->> 'character_class_id' = p_class::text),
       sb as (select s from jsonb_array_elements(p_sum_before -> 'classes') s where s ->> 'id' = p_class::text),
       sa as (select s from jsonb_array_elements(p_sum_after -> 'classes') s where s ->> 'id' = p_class::text)
  select jsonb_build_object(
    'level', jsonb_build_object('from', (select (k ->> 'level')::int from kb), 'to', (select (k ->> 'level')::int from ka)),
    'class_version', jsonb_build_object('from', (select k ->> 'class_version_id' from kb), 'to', (select k ->> 'class_version_id' from ka),
                                        'from_name', (select k ->> 'version_name' from kb), 'to_name', (select k ->> 'version_name' from ka)),
    'total_level', jsonb_build_object('from', (p_before ->> 'total_level')::int, 'to', (p_after ->> 'total_level')::int),
    'proficiency_bonus', jsonb_build_object('from', (p_before ->> 'proficiency_bonus')::int, 'to', (p_after ->> 'proficiency_bonus')::int),
    'features_activated', coalesce((select jsonb_agg(jsonb_build_object('name', fa.f ->> 'name', 'level', (fa.f ->> 'level')::int,
                             'automation', fa.f ->> 'automation', 'origin', fa.f ->> 'origin'))
                           from fa where (fa.f ->> 'active')::boolean
                             and not exists (select 1 from fb where fb.f ->> 'unlock_id' = fa.f ->> 'unlock_id' and (fb.f ->> 'active')::boolean)), '[]'),
    'features_deactivated', coalesce((select jsonb_agg(jsonb_build_object('name', fb.f ->> 'name', 'level', (fb.f ->> 'level')::int,
                               'origin', fb.f ->> 'origin'))
                             from fb where (fb.f ->> 'active')::boolean
                               and not exists (select 1 from fa where fa.f ->> 'unlock_id' = fb.f ->> 'unlock_id' and (fa.f ->> 'active')::boolean)), '[]'),
    'choices_added', coalesce((select jsonb_agg(jsonb_build_object('label', ca.c ->> 'label', 'feature', ca.c ->> 'feature_name',
                        'kind', ca.c ->> 'kind'))
                      from ca where (ca.c ->> 'open')::boolean
                        and not exists (select 1 from cb where cb.c ->> 'key' = ca.c ->> 'key' and (cb.c ->> 'open')::boolean)), '[]'),
    'choices_inactive', coalesce((select jsonb_agg(jsonb_build_object('label', cb.c ->> 'label', 'feature', cb.c ->> 'feature_name',
                           'values', cb.c -> 'values'))
                         from cb where (cb.c ->> 'open')::boolean and jsonb_array_length(cb.c -> 'values') > 0
                           and not exists (select 1 from ca where ca.c ->> 'key' = cb.c ->> 'key' and (ca.c ->> 'open')::boolean)), '[]'),
    'resources', coalesce((select jsonb_agg(jsonb_build_object('name', coalesce(ra.r ->> 'name', rb.r ->> 'name'),
                    'max_from', case when (rb.r ->> 'active')::boolean then rb.r -> 'max' end,
                    'max_to', case when (ra.r ->> 'active')::boolean then ra.r -> 'max' end,
                    'die_from', rb.r ->> 'die', 'die_to', ra.r ->> 'die',
                    'active_from', coalesce((rb.r ->> 'active')::boolean, false), 'active_to', coalesce((ra.r ->> 'active')::boolean, false)))
                  from rb full join ra on ra.r ->> 'key' = rb.r ->> 'key'
                  where (rb.r -> 'max') is distinct from (ra.r -> 'max') or (rb.r ->> 'active') is distinct from (ra.r ->> 'active')
                     or (rb.r ->> 'die') is distinct from (ra.r ->> 'die')), '[]'),
    'standard_slots', jsonb_build_object('from', (select coalesce(jsonb_object_agg(s ->> 'slot_level', (s ->> 'max')::int), '{}')
                                                 from jsonb_array_elements(p_slots_before -> 'standard') s),
                                         'to', (select coalesce(jsonb_object_agg(s ->> 'slot_level', (s ->> 'max')::int), '{}')
                                               from jsonb_array_elements(p_slots_after -> 'standard') s)),
    'pact_magic', jsonb_build_object('from', case when jsonb_typeof(p_slots_before -> 'pact_magic') = 'object' then jsonb_build_object(
                                       'slots', p_slots_before -> 'pact_magic' -> 'max', 'slot_level', p_slots_before -> 'pact_magic' -> 'slot_level') end,
                                     'to', case when jsonb_typeof(p_slots_after -> 'pact_magic') = 'object' then jsonb_build_object(
                                       'slots', p_slots_after -> 'pact_magic' -> 'max', 'slot_level', p_slots_after -> 'pact_magic' -> 'slot_level') end),
    'spellcasting', jsonb_build_object('from', (select s -> 'spellcasting' from sb), 'to', (select s -> 'spellcasting' from sa)),
    'subclass', jsonb_build_object('from', (select k -> 'subclass' ->> 'status' from kb), 'to', (select k -> 'subclass' ->> 'status' from ka),
                                   'name', (select k -> 'subclass' -> 'selected' ->> 'name' from ka)),
    'proficiencies', jsonb_build_object(
      'added', coalesce((select jsonb_agg(a) from jsonb_array_elements(p_after -> 'grants' -> 'proficiencies') a
                         where a ->> 'character_class_id' = p_class::text
                           and not exists (select 1 from jsonb_array_elements(p_before -> 'grants' -> 'proficiencies') b
                                           where b ->> 'character_class_id' = p_class::text and b ->> 'value' = a ->> 'value'
                                             and b ->> 'target' = a ->> 'target')), '[]'),
      'removed', coalesce((select jsonb_agg(b) from jsonb_array_elements(p_before -> 'grants' -> 'proficiencies') b
                           where b ->> 'character_class_id' = p_class::text
                             and not exists (select 1 from jsonb_array_elements(p_after -> 'grants' -> 'proficiencies') a
                                             where a ->> 'character_class_id' = p_class::text and a ->> 'value' = b ->> 'value'
                                               and a ->> 'target' = b ->> 'target')), '[]')),
    'warnings', coalesce((select jsonb_agg(w) from jsonb_array_elements((p_after -> 'warnings') || coalesce(p_sum_after -> 'warnings', '[]')) w
                          where not exists (select 1 from jsonb_array_elements((p_before -> 'warnings') || coalesce(p_sum_before -> 'warnings', '[]')) v
                                            where v ->> 'message' = w ->> 'message')), '[]'),
    'review_items', coalesce((select k -> 'review_items' from ka), '[]'));
$$;

-- What would change if this class row had another level and / or class version. Nothing is stored: the change is made in
-- a savepoint, everything is read back, and the savepoint is rolled back.
create function public.preview_character_class_change(p_character uuid, p_character_class uuid, p_level int default null,
                                                      p_class_version text default null)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare cc public.character_classes; fb jsonb; fa jsonb; sb jsonb; sa jsonb; mb jsonb; ma jsonb; err text;
begin
  if auth.uid() is null or not public.can_access_character(p_character) then
    raise exception 'Character not found' using errcode = '42501';
  end if;
  select * into cc from public.character_classes where id = p_character_class and character_id = p_character;
  if not found then raise exception 'Character class not found' using errcode = '42501'; end if;
  if p_class_version is not null and not exists (select 1 from public.class_versions v where v.id = p_class_version and v.class_id = cc.class_id) then
    raise exception 'Unknown version of this class' using errcode = '22023';
  end if;
  if p_level is not null and p_level not between 1 and 20 then
    raise exception 'A class level is between 1 and 20' using errcode = '22023';
  end if;
  fb := public.get_character_class_features(p_character); sb := public.get_character_spell_slots(p_character);
  mb := public.get_character_class_summary(p_character);
  begin
    update public.character_classes set level = coalesce(p_level, level), class_version_id = coalesce(p_class_version, class_version_id)
    where id = p_character_class;
    fa := public.get_character_class_features(p_character); sa := public.get_character_spell_slots(p_character);
    ma := public.get_character_class_summary(p_character);
    raise exception using errcode = 'P0001', message = 'tavern-preview-rollback';
  exception when others then
    if sqlerrm <> 'tavern-preview-rollback' then err := sqlerrm; end if;
  end;
  if err is not null then
    return jsonb_build_object('possible', false, 'error', err, 'character_class_id', p_character_class);
  end if;
  return jsonb_build_object('possible', true, 'character_class_id', p_character_class, 'stored', false)
         || public._cf_diff(fb, fa, p_character_class, sb, sa, mb, ma);
end;
$$;

-- =============================================================================
-- JSON export / import of the character-specific feature state (stable catalog references, never the catalog)
-- =============================================================================
create function public.export_character_class_features(p_character uuid)
returns jsonb
language plpgsql stable
set search_path = public, pg_temp
as $$
begin
  perform 1 from public.characters where id = p_character;                    -- RLS
  if not found then raise exception 'Character not found' using errcode = '42501'; end if;
  return jsonb_build_object('format', 'tavern-ledger/class-features', 'version', 1,
    'choices', (select coalesce(jsonb_agg(jsonb_build_object('classKey', ch.character_class_id, 'classVersion', cc.class_version_id,
                  'subclassVersion', cc.subclass_version_id, 'unlock', ch.unlock_id, 'choice', ch.choice_id,
                  'values', (select coalesce(jsonb_agg(v.value order by v.pick), '[]') from public.character_feature_choice_values v
                             where v.character_choice_id = ch.id),
                  'manualStatus', ch.manual_status) order by cc.class_id, ch.unlock_id, ch.choice_id), '[]')
                from public.character_feature_choices ch join public.character_classes cc on cc.id = ch.character_class_id
                where ch.character_id = p_character),
    'optionalFeatures', (select coalesce(jsonb_agg(jsonb_build_object('classKey', o.character_class_id, 'classVersion', cc.class_version_id,
                           'unlock', o.unlock_id) order by o.unlock_id), '[]')
                         from public.character_optional_features o join public.character_classes cc on cc.id = o.character_class_id
                         where o.character_id = p_character),
    'resources', (select coalesce(jsonb_agg(jsonb_build_object('classKey', r.character_class_id, 'classVersion', cc.class_version_id,
                    'resource', r.feature_resource_id, 'expended', r.expended, 'temporaryBonus', r.temporary_bonus,
                    'maxAdjustment', r.max_adjustment) order by r.feature_resource_id), '[]')
                  from public.character_resources r join public.character_classes cc on cc.id = r.character_class_id
                  where r.character_id = p_character and r.feature_resource_id is not null));
end;
$$;

-- p_payload = export_character_class_features() output + "classRows": {"<exported classKey>": "<new character class id>"}.
-- Resolves stable ids, keeps inactive selections, clamps resource state, never deletes anything; returns a report.
create function public.import_character_class_features(p_character uuid, p_payload jsonb)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare e jsonb; cc public.character_classes; cf public.class_feature_choices; vals text[]; err text; cid uuid; ccid uuid;
  applied_c int := 0; applied_o int := 0; applied_r int := 0; unresolved jsonb := '[]'; warnings jsonb := '[]'; me jsonb;
  mods jsonb; exp int; cap int; rid text;
begin
  if auth.uid() is null or not public.can_access_character(p_character) then
    raise exception 'Character not found' using errcode = '42501';
  end if;
  if jsonb_typeof(p_payload) <> 'object' then raise exception 'The class feature data must be an object' using errcode = '22023'; end if;
  perform 1 from public.characters where id = p_character for update;

  -- optional features first (a replacement decides which features are active)
  for e in select * from jsonb_array_elements(coalesce(p_payload -> 'optionalFeatures', '[]')) loop
    cc := null;
    ccid := case when p_payload -> 'classRows' ->> (e ->> 'classKey') ~ '^[0-9a-f-]{36}$'
                 then (p_payload -> 'classRows' ->> (e ->> 'classKey'))::uuid end;
    select * into cc from public.character_classes where id = ccid and character_id = p_character;
    if cc.id is null or not exists (select 1 from public.class_feature_unlocks u where u.id = e ->> 'unlock' and u.is_optional
                                      and (u.class_version_id = cc.class_version_id or u.subclass_version_id = cc.subclass_version_id)) then
      unresolved := unresolved || jsonb_build_object('kind', 'optional_feature', 'entry', e, 'reason', 'unknown class row or feature');
      continue;
    end if;
    insert into public.character_optional_features (character_id, character_class_id, unlock_id, created_by)
    values (p_character, cc.id, e ->> 'unlock', auth.uid()) on conflict do nothing;
    applied_o := applied_o + 1;
  end loop;

  for e in select * from jsonb_array_elements(coalesce(p_payload -> 'choices', '[]')) loop
    cc := null; cf := null;
    ccid := case when p_payload -> 'classRows' ->> (e ->> 'classKey') ~ '^[0-9a-f-]{36}$'
                 then (p_payload -> 'classRows' ->> (e ->> 'classKey'))::uuid end;
    select * into cc from public.character_classes where id = ccid and character_id = p_character;
    select c.* into cf from public.class_feature_choices c join public.class_feature_unlocks u on u.feature_version_id = c.feature_version_id
    where c.id = e ->> 'choice' and u.id = e ->> 'unlock'
      and (u.class_version_id = cc.class_version_id or u.subclass_version_id = cc.subclass_version_id);
    if cc.id is null or cf.id is null then
      unresolved := unresolved || jsonb_build_object('kind', 'choice', 'entry', e, 'reason', 'unknown class row, feature or choice');
      continue;
    end if;
    continue when cf.kind = 'subclass';                                          -- the subclass comes with the class row
    vals := coalesce((select array_agg(x) from jsonb_array_elements_text(coalesce(e -> 'values', '[]')) x where btrim(x) <> ''), '{}');
    err := public._cf_choice_error(p_character, cc.id, e ->> 'unlock', cf, vals, 20, false);
    if err is null and e ->> 'manualStatus' is not null and e ->> 'manualStatus' not in ('applied_manually', 'confirmed') then
      err := 'unknown manual status';
    end if;
    if err is not null then
      unresolved := unresolved || jsonb_build_object('kind', 'choice', 'entry', e, 'reason', err);
      continue;
    end if;
    if cardinality(vals) > cf.max_picks then
      warnings := warnings || jsonb_build_object('code', 'over_selected', 'message', format('%s: %s values imported, %s allowed (kept for review)',
                                                  cf.label, cardinality(vals), cf.max_picks));
    end if;
    insert into public.character_feature_choices (character_id, character_class_id, unlock_id, choice_id, manual_status, created_by)
    values (p_character, cc.id, e ->> 'unlock', cf.id, e ->> 'manualStatus', auth.uid())
    on conflict (character_class_id, unlock_id, choice_id) do update set manual_status = excluded.manual_status
    returning id into cid;
    delete from public.character_feature_choice_values where character_choice_id = cid;
    insert into public.character_feature_choice_values (character_choice_id, pick, value)
    select cid, ord, v from unnest(vals) with ordinality u(v, ord);
    applied_c := applied_c + 1;
  end loop;

  mods := public._character_mods(p_character);
  perform set_config('tavern.resource_engine', 'on', true);
  for e in select * from jsonb_array_elements(coalesce(p_payload -> 'resources', '[]')) loop
    me := null;
    ccid := case when p_payload -> 'classRows' ->> (e ->> 'classKey') ~ '^[0-9a-f-]{36}$'
                 then (p_payload -> 'classRows' ->> (e ->> 'classKey'))::uuid end;
    rid := e ->> 'resource';
    select x into me from jsonb_array_elements(public._character_feature_resources(p_character, mods)) x
    where x ->> 'character_class_id' = ccid::text and x ->> 'resource_id' = rid;
    if me is null then
      unresolved := unresolved || jsonb_build_object('kind', 'resource', 'entry', e, 'reason', 'this class does not grant the resource now');
      continue;
    end if;
    exp := coalesce((e ->> 'expended')::int, 0);
    cap := case when (me ->> 'unlimited')::boolean or not (me ->> 'max_known')::boolean then null
                else greatest(coalesce((me ->> 'base_max')::int, 0) + least(greatest(coalesce((e ->> 'maxAdjustment')::int, 0), -20), 20), 0)
                     + least(greatest(coalesce((e ->> 'temporaryBonus')::int, 0), 0), 99) end;
    if exp < 0 or (cap is not null and exp > cap) then
      warnings := warnings || jsonb_build_object('code', 'resource_clamped', 'resource', rid,
        'message', format('%s: %s used was adjusted to %s (maximum %s)', me ->> 'name', exp,
                          least(greatest(exp, 0), coalesce(cap, 99)), coalesce(cap::text, '?')));
      exp := least(greatest(exp, 0), coalesce(cap, 99));
    end if;
    insert into public.character_resources (character_id, resource_key, name, source_type, source_id, character_class_id,
                                            feature_resource_id, recharge, created_by)
    values (p_character, 'cf-' || rid, me ->> 'name', case when me ->> 'origin' = 'subclass' then 'subclass' else 'class' end,
            me ->> 'feature_version_id', ccid, rid, me ->> 'recharge', auth.uid())
    on conflict (character_class_id, feature_resource_id) where feature_resource_id is not null do nothing;
    update public.character_resources set expended = exp,
           temporary_bonus = least(greatest(coalesce((e ->> 'temporaryBonus')::int, 0), 0), 99),
           max_adjustment = least(greatest(coalesce((e ->> 'maxAdjustment')::int, 0), -20), 20)
    where character_class_id = ccid and feature_resource_id = rid;
    insert into public.character_resource_events (character_id, event_type, pool, feature_resource_id, expended_after, reason)
    values (p_character, 'manual_set', 'resource', rid, exp, 'Imported from JSON');
    applied_r := applied_r + 1;
  end loop;
  perform set_config('tavern.resource_engine', 'off', true);
  return jsonb_build_object('applied', jsonb_build_object('choices', applied_c, 'optional_features', applied_o, 'resources', applied_r),
                            'unresolved', unresolved, 'warnings', warnings);
end;
$$;

-- =============================================================================
-- RLS, grants, Realtime
-- =============================================================================
alter table public.subclasses enable row level security;
alter table public.class_features enable row level security;
alter table public.class_feature_versions enable row level security;
alter table public.class_feature_unlocks enable row level security;
alter table public.class_feature_scaling enable row level security;
alter table public.class_feature_choices enable row level security;
alter table public.class_feature_choice_options enable row level security;
alter table public.class_feature_effects enable row level security;
alter table public.class_feature_resources enable row level security;
alter table public.character_optional_features enable row level security;
alter table public.character_feature_choices enable row level security;
alter table public.character_feature_choice_values enable row level security;

create policy "subclasses_read" on public.subclasses for select to anon, authenticated using (true);
create policy "class_features_read" on public.class_features for select to anon, authenticated using (true);
create policy "class_feature_versions_read" on public.class_feature_versions for select to anon, authenticated using (true);
create policy "class_feature_unlocks_read" on public.class_feature_unlocks for select to anon, authenticated using (true);
create policy "class_feature_scaling_read" on public.class_feature_scaling for select to anon, authenticated using (true);
create policy "class_feature_choices_read" on public.class_feature_choices for select to anon, authenticated using (true);
create policy "class_feature_choice_options_read" on public.class_feature_choice_options for select to anon, authenticated using (true);
create policy "class_feature_effects_read" on public.class_feature_effects for select to anon, authenticated using (true);
create policy "class_feature_resources_read" on public.class_feature_resources for select to anon, authenticated using (true);
create policy "character_optional_features_read" on public.character_optional_features for select to authenticated
  using (public.can_access_character(character_id));
create policy "character_feature_choices_read" on public.character_feature_choices for select to authenticated
  using (public.can_access_character(character_id));
create policy "character_feature_choice_values_read" on public.character_feature_choice_values for select to authenticated
  using (exists (select 1 from public.character_feature_choices c where c.id = character_choice_id and public.can_access_character(c.character_id)));

revoke all on public.subclasses, public.class_features, public.class_feature_versions, public.class_feature_unlocks,
  public.class_feature_scaling, public.class_feature_choices, public.class_feature_choice_options, public.class_feature_effects,
  public.class_feature_resources, public.character_optional_features, public.character_feature_choices,
  public.character_feature_choice_values from anon, authenticated;
grant select on public.subclasses, public.class_features, public.class_feature_versions, public.class_feature_unlocks,
  public.class_feature_scaling, public.class_feature_choices, public.class_feature_choice_options, public.class_feature_effects,
  public.class_feature_resources to anon, authenticated;
grant select on public.character_optional_features, public.character_feature_choices, public.character_feature_choice_values
  to authenticated;                                                                              -- writes: RPCs only

revoke all on function public.class_feature_rows_touch(), public.class_feature_unlocks_before_write(),
  public.class_feature_definitions_before_write(), public.character_resources_feature_guard() from public, anon, authenticated;
revoke all on function public._cf_class_rows(uuid), public._cf_prereq(jsonb, jsonb), public._character_feature_unlocks(uuid),
  public._character_feature_choice_rows(uuid), public._cf_equipment(uuid), public._character_class_effects(uuid),
  public._cf_scale(jsonb, int), public._character_feature_resources(uuid, jsonb), public._skill_level(jsonb),
  public._derived_stats_levels(uuid), public._spellbook_core(uuid), public._class_summary_core(uuid),
  public.get_character_spellbook(uuid), public.get_character_class_summary(uuid), public.get_character_derived_stats(uuid),
  public.get_character_resources(uuid),
  public._cf_choice_error(uuid, uuid, text, public.class_feature_choices, text[], int, boolean),
  public.get_character_class_features(uuid), public._cf_class_row(uuid, uuid),
  public.set_character_feature_choice(uuid, uuid, text, text, text[], text, boolean),
  public.set_character_optional_feature(uuid, uuid, text, boolean), public.set_character_subclass(uuid, uuid, text),
  public._resource_change(uuid, text, text, int, int, int, int, text),
  public.expend_character_resource(uuid, text, int, text), public.restore_character_resource(uuid, text, int, text),
  public.set_character_resource_state(uuid, text, int, text, int, int),
  public._cf_diff(jsonb, jsonb, uuid, jsonb, jsonb, jsonb, jsonb), public.preview_character_class_change(uuid, uuid, int, text),
  public.export_character_class_features(uuid), public.import_character_class_features(uuid, jsonb) from public, anon;
revoke all on function public._cf_class_row(uuid, uuid), public._resource_change(uuid, text, text, int, int, int, int, text)
  from authenticated;                                                                            -- wrappers only
grant execute on function public._cf_class_rows(uuid), public._cf_prereq(jsonb, jsonb), public._character_feature_unlocks(uuid),
  public._character_feature_choice_rows(uuid), public._cf_equipment(uuid), public._character_class_effects(uuid),
  public._cf_scale(jsonb, int), public._character_feature_resources(uuid, jsonb), public._skill_level(jsonb),
  public._derived_stats_levels(uuid), public._spellbook_core(uuid), public._class_summary_core(uuid),
  public.get_character_spellbook(uuid), public.get_character_class_summary(uuid), public.get_character_derived_stats(uuid),
  public.get_character_resources(uuid),
  public._cf_choice_error(uuid, uuid, text, public.class_feature_choices, text[], int, boolean),
  public.get_character_class_features(uuid),
  public.set_character_feature_choice(uuid, uuid, text, text, text[], text, boolean),
  public.set_character_optional_feature(uuid, uuid, text, boolean), public.set_character_subclass(uuid, uuid, text),
  public.expend_character_resource(uuid, text, int, text), public.restore_character_resource(uuid, text, int, text),
  public.set_character_resource_state(uuid, text, int, text, int, int),
  public._cf_diff(jsonb, jsonb, uuid, jsonb, jsonb, jsonb, jsonb), public.preview_character_class_change(uuid, uuid, int, text),
  public.export_character_class_features(uuid), public.import_character_class_features(uuid, jsonb) to authenticated;

do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    alter publication supabase_realtime add table public.character_feature_choices, public.character_optional_features;
  end if;
end $$;
