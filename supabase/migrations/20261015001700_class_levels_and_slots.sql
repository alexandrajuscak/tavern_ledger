-- =============================================================================
-- Character class levels, spell slot progression, Pact Magic, resources and rests
-- (foundation only: no class features, no subclasses beyond the two one-third caster progressions)
--
-- Source of truth: character_classes (class version + level [+ subclass version]) + class_versions / class_version_levels
-- + spell_slot_progressions  =>  total level, proficiency bonus, effective caster level, slot maximums, limits (computed on
-- read). Only runtime state is stored: expended slots, temporary slots, expended resources, events.
-- characters.level is kept as a compatibility mirror (set by a trigger while class rows exist; legacy value otherwise).
-- Data: supabase/seed/classes.sql (generated from the class tables). See docs/CLASS_LEVELS.md, docs/SPELL_SLOTS.md.
-- =============================================================================

-- ---- class version metadata ----------------------------------------------------------------------------------------
alter table public.class_versions
  add column hit_die                  text check (hit_die in ('d6', 'd8', 'd10', 'd12')),
  add column rules_label              text,
  add column multiclass_contribution  text not null default 'none'
    check (multiclass_contribution in ('full', 'half_down', 'half_up', 'third_down', 'pact', 'none')),
  add column spellcasting_start_level int check (spellcasting_start_level between 1 and 20),
  add column prepared_formula         jsonb check (prepared_formula is null or jsonb_typeof(prepared_formula) = 'object'),
  add column is_pact_magic            boolean not null default false,
  add column multiclass_prerequisite  jsonb,
  add column implementation_status    text not null default 'progression_only'
    check (implementation_status in ('level_only', 'progression_only', 'partial', 'complete')),
  add column limitations              text[] not null default '{}';

comment on column public.class_versions.multiclass_contribution is
  'Standard multiclass slot contribution: full = class level, half_down / half_up = half rounded down / up, third_down = '
  'one third rounded down (only through a spellcasting subclass), pact = separate Pact Magic pool, none.';
comment on column public.class_versions.prepared_formula is
  '{"ability","level_divisor","rounding","minimum"}: prepared spells = max(minimum, ability modifier + class level / divisor).';

-- one-third casters (Eldritch Knight, Arcane Trickster): spellcasting progression only, no subclass features
create table public.subclass_versions (
  id                       text primary key check (id ~ '^[a-z0-9]+(-[a-z0-9]+)*$'),
  class_id                 text not null references public.classes (id) on delete cascade,
  name                     text not null,
  source_book_id           text references public.source_books (id),
  source_label             text not null,
  source_url               text not null check (source_url ~ '^https://'),
  status                   text not null default 'current' check (status in ('current', 'legacy')),
  superseded_by_version_id text references public.subclass_versions (id) on delete set null,
  spellcasting_ability     text check (spellcasting_ability in ('str', 'dex', 'con', 'int', 'wis', 'cha')),
  preparation_mode         text not null default 'known' check (preparation_mode in ('prepared', 'known', 'spellbook', 'none')),
  spell_list_id            text references public.class_spell_lists (id) on delete set null,
  multiclass_contribution  text not null default 'none' check (multiclass_contribution in ('third_down', 'none')),
  slot_progression_id      text references public.spell_slot_progressions (id),
  spellcasting_start_level int check (spellcasting_start_level between 1 and 20),
  implementation_status    text not null default 'progression_only'
    check (implementation_status in ('level_only', 'progression_only', 'partial', 'complete')),
  limitations              text[] not null default '{}'
);

-- per-level numbers from the class tables (no feature text)
create table public.class_version_levels (
  class_version_id  text not null references public.class_versions (id) on delete cascade,
  level             int  not null check (level between 1 and 20),
  proficiency_bonus int  not null check (proficiency_bonus between 2 and 6),
  cantrips_known    int  check (cantrips_known between 0 and 10),
  spells_known      int  check (spells_known between 0 and 30),
  max_spell_level   int  check (max_spell_level between 1 and 9),
  pact_slots        int  check (pact_slots between 1 and 4),
  pact_slot_level   int  check (pact_slot_level between 1 and 5),
  source_url        text not null,
  primary key (class_version_id, level),
  check ((pact_slots is null) = (pact_slot_level is null))
);
create table public.subclass_version_levels (
  subclass_version_id text not null references public.subclass_versions (id) on delete cascade,
  level               int  not null check (level between 1 and 20),     -- the class level (fighter / rogue level)
  cantrips_known      int  check (cantrips_known between 0 and 10),
  spells_known        int  check (spells_known between 0 and 30),
  max_spell_level     int  check (max_spell_level between 1 and 9),
  source_url          text not null,
  primary key (subclass_version_id, level)
);

-- ---- the character's classes ---------------------------------------------------------------------------------------
create table public.character_classes (
  id                  uuid primary key default gen_random_uuid(),
  character_id        uuid not null references public.characters (id) on delete cascade,
  class_id            text not null references public.classes (id),            -- set from the version (one row per class)
  class_version_id    text not null references public.class_versions (id),
  subclass_version_id text references public.subclass_versions (id),
  level               int  not null check (level between 1 and 20),
  is_primary          boolean not null default false,
  started_at_level    int  check (started_at_level between 1 and 20),
  notes               text check (length(notes) <= 500),
  created_by          uuid default auth.uid(),
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  unique (character_id, class_id),
  unique (id, character_id)
);
create unique index character_classes_one_primary on public.character_classes (character_id) where is_primary;

alter table public.character_spellcasting_sources
  add column character_class_id uuid references public.character_classes (id) on delete cascade;
create unique index character_spellcasting_sources_class on public.character_spellcasting_sources (character_class_id)
  where character_class_id is not null;

-- ---- runtime slot state (maximums are derived; only the expended count is stored) ----------------------------------
create table public.character_spell_slot_state (
  character_id uuid not null references public.characters (id) on delete cascade,
  pool         text not null check (pool in ('standard', 'pact')),
  slot_level   int  not null check (slot_level between 0 and 9),   -- standard: 1-9; pact: 0 (the level follows the Warlock level)
  expended     int  not null default 0 check (expended between 0 and 20),
  updated_at   timestamptz not null default now(),
  primary key (character_id, pool, slot_level),
  check ((pool = 'pact') = (slot_level = 0))
);

-- future: slots created by a feature (Font of Magic etc.); never mixed into the class-derived maximums
create table public.character_temporary_spell_slots (
  id           uuid primary key default gen_random_uuid(),
  character_id uuid not null references public.characters (id) on delete cascade,
  slot_level   int  not null check (slot_level between 1 and 9),
  quantity     int  not null default 1 check (quantity between 1 and 9),
  expended     int  not null default 0 check (expended >= 0),
  source_type  text not null default 'manual' check (source_type in ('feature', 'item', 'manual', 'other')),
  source_label text not null check (length(source_label) between 1 and 80),
  expires_on   text not null default 'long_rest' check (expires_on in ('short_rest', 'long_rest', 'manual')),
  created_by   uuid default auth.uid(),
  created_at   timestamptz not null default now(),
  check (expended <= quantity)
);

-- ---- generic resources (future class features, free casts, item charges) -------------------------------------------
create table public.character_resources (
  id                 uuid primary key default gen_random_uuid(),
  character_id       uuid not null references public.characters (id) on delete cascade,
  resource_key       text not null check (resource_key ~ '^[a-z0-9]+(-[a-z0-9]+)*$'),
  name               text not null check (length(name) between 1 and 80),
  source_type        text not null default 'manual' check (source_type in ('class', 'subclass', 'lineage', 'feat', 'item', 'manual', 'other')),
  source_id          text,
  character_class_id uuid references public.character_classes (id) on delete cascade,
  max_formula        jsonb not null default '{"fixed": 1}' check (jsonb_typeof(max_formula) = 'object'),
  minimum            int  not null default 0 check (minimum >= 0),
  die                text check (die ~ '^d[0-9]+$'),
  recharge           text not null default 'long_rest' check (recharge in ('short_rest', 'long_rest', 'short_or_long_rest', 'dawn', 'manual', 'none')),
  unlock_level       int  check (unlock_level between 1 and 20),
  spell_version_id   text references public.spell_versions (id),       -- free casts (Mystic Arcanum, Signature Spells, ...)
  cast_level         int  check (cast_level between 1 and 9),
  expended           int  not null default 0 check (expended >= 0),
  active             boolean not null default true,
  notes              text check (length(notes) <= 500),
  created_by         uuid default auth.uid(),
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  unique (character_id, resource_key)
);

create table public.character_resource_events (
  id              bigint generated always as identity primary key,
  character_id    uuid not null references public.characters (id) on delete cascade,
  event_type      text not null check (event_type in ('expend', 'restore', 'manual_set', 'short_rest', 'long_rest')),
  pool            text not null check (pool in ('standard', 'pact', 'temporary', 'resource', 'rest')),
  slot_level      int,
  resource_id     uuid,
  amount          int,
  expended_before int,
  expended_after  int,
  rest_id         uuid,
  reason          text check (length(reason) <= 300),
  details         jsonb,
  actor_id        uuid default auth.uid(),
  created_at      timestamptz not null default now()
);
create index character_resource_events_character on public.character_resource_events (character_id, created_at desc);
create unique index character_resource_events_rest on public.character_resource_events (character_id, rest_id)
  where rest_id is not null and event_type in ('short_rest', 'long_rest');

-- ---- integrity -------------------------------------------------------------------------------------------------------
create function public.character_classes_before_write()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
declare cv public.class_versions; sv public.subclass_versions;
begin
  select * into cv from public.class_versions where id = new.class_version_id;
  if not found then raise exception 'Unknown class version "%"', new.class_version_id using errcode = '22023'; end if;
  new.class_id := cv.class_id;
  if new.subclass_version_id is not null then
    select * into sv from public.subclass_versions where id = new.subclass_version_id;
    if not found or sv.class_id <> cv.class_id then
      raise exception 'Subclass "%" does not belong to %', new.subclass_version_id, cv.name using errcode = '22023';
    end if;
  end if;
  new.updated_at := now();
  return new;
end;
$$;
create trigger character_classes_before_write before insert or update on public.character_classes
  for each row execute function public.character_classes_before_write();

-- total level = sum of class levels (at most 20); mirrored into characters.level for every existing consumer
create function public.character_classes_after_write()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
declare cid uuid := coalesce(new.character_id, old.character_id); total int;
begin
  if not exists (select 1 from public.characters where id = cid) then return null; end if;   -- the character is being deleted
  select sum(level) into total from public.character_classes where character_id = cid;
  if total > 20 then
    raise exception 'Class levels add up to %; the total character level is at most 20', total using errcode = '22023';
  end if;
  if total is not null then
    perform set_config('tavern.level_sync', 'on', true);
    update public.characters set level = total where id = cid and level is distinct from total;
    perform set_config('tavern.level_sync', 'off', true);
  end if;
  return null;
end;
$$;
create trigger character_classes_after_write after insert or update or delete on public.character_classes
  for each row execute function public.character_classes_after_write();

create function public.characters_level_guard()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  if new.level is distinct from old.level and coalesce(current_setting('tavern.level_sync', true), '') <> 'on'
     and exists (select 1 from public.character_classes where character_id = new.id) then
    raise exception 'The level of % comes from its classes; change a class level instead', old.name using errcode = '22023';
  end if;
  return new;
end;
$$;
create trigger characters_level_guard before update of level on public.characters
  for each row execute function public.characters_level_guard();

-- a class source linked to a character class follows that class (version, ability, list, preparation); unlinked class
-- sources stay "Class Foundation Preview" exactly as in 20261015001600
create or replace function public.character_spellcasting_sources_before_write()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
declare cv public.class_versions; cc public.character_classes; sv public.subclass_versions;
begin
  if tg_op = 'UPDATE' and old.character_class_id is not null and new.character_class_id is null then
    new.character_class_id := old.character_class_id;                         -- the editor cannot unlink a class source
  end if;
  if new.character_class_id is not null then
    select * into cc from public.character_classes where id = new.character_class_id and character_id = new.character_id;
    if not found then raise exception 'Character class not found' using errcode = '22023'; end if;
    select * into cv from public.class_versions where id = cc.class_version_id;
    select * into sv from public.subclass_versions where id = cc.subclass_version_id;
    new.source_type := 'class';
    new.is_preview := false;
    new.class_version_id := cc.class_version_id;
    new.casting_ability := coalesce(new.casting_ability, sv.spellcasting_ability, cv.spellcasting_ability);
    new.spell_list_id := coalesce(sv.spell_list_id, cv.spell_list_id);
    new.preparation_mode := case when sv.id is not null and cv.multiclass_contribution = 'none' then sv.preparation_mode
                                 else cv.preparation_mode end;
    new.ritual_mode := case when sv.id is not null and cv.multiclass_contribution = 'none' then 'none' else cv.ritual_mode end;
    new.class_level := null;                    -- derived from character_classes, never stored on the source
    new.progression_id := null;
  else
    if new.class_version_id is not null then
      select * into cv from public.class_versions where id = new.class_version_id;
      new.casting_ability := coalesce(new.casting_ability, cv.spellcasting_ability);
      new.spell_list_id := coalesce(new.spell_list_id, cv.spell_list_id);
    end if;
    if new.source_type = 'class' then new.is_preview := true; end if;    -- not tied to a character class: preview
  end if;
  if exists (select 1 from unnest(new.allowed_abilities) a where a not in ('str', 'dex', 'con', 'int', 'wis', 'cha')) then
    raise exception 'Unknown ability in allowed_abilities' using errcode = '22023';
  end if;
  new.updated_at := now();
  return new;
end;
$$;

-- a class source is removed together with its class (remove_character_class), never on its own
create function public.character_spellcasting_sources_before_delete()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  if old.character_class_id is not null
     and exists (select 1 from public.character_classes where id = old.character_class_id)
     and exists (select 1 from public.characters where id = old.character_id) then
    raise exception 'This spellcasting source belongs to a class; remove or change the class instead' using errcode = '22023';
  end if;
  return old;
end;
$$;
create trigger character_spellcasting_sources_before_delete before delete on public.character_spellcasting_sources
  for each row execute function public.character_spellcasting_sources_before_delete();

create function public.character_class_rows_touch()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;
create trigger character_resources_touch before update on public.character_resources
  for each row execute function public.character_class_rows_touch();
create trigger character_spell_slot_state_touch before update on public.character_spell_slot_state
  for each row execute function public.character_class_rows_touch();

-- ---- calculation helpers -----------------------------------------------------------------------------------------------
-- Total level: sum of class levels when the character has classes, otherwise the legacy characters.level (fallback).
create function public._character_level_info(p_character uuid)
returns jsonb
language sql stable
set search_path = public, pg_temp
as $$
  select jsonb_build_object(
    'total_level', coalesce(x.total, c.level),
    'source', case when x.total is null then 'legacy' else 'classes' end,
    'fallback', x.total is null,
    'legacy_level', c.level,
    'class_count', coalesce(x.n, 0),
    'proficiency_bonus', (greatest(coalesce(x.total, c.level), 1) - 1) / 4 + 2)
  from public.characters c
  left join lateral (select sum(cc.level)::int as total, count(*)::int as n from public.character_classes cc where cc.character_id = c.id) x on true
  where c.id = p_character;
$$;

-- Standard slot maximums of one progression at one level: {"1": 4, "2": 3, ...}
create function public._progression_slots(p_progression text, p_level int)
returns jsonb
language sql stable
set search_path = public, pg_temp
as $$
  select coalesce(jsonb_object_agg(l.slot_level::text, l.slots order by l.slot_level), '{}')
  from public.spell_slot_progression_levels l
  where l.progression_id = p_progression and l.class_level = least(greatest(p_level, 1), 20) and l.slots > 0;
$$;

-- Prepared spells allowed by a formula: max(minimum, ability modifier + class level / divisor)
create function public._prepared_limit(p_formula jsonb, p_mods jsonb, p_level int)
returns int
language sql immutable
set search_path = public, pg_temp
as $$
  select case when p_formula is null then null else greatest(coalesce((p_formula ->> 'minimum')::int, 1),
    coalesce((p_mods ->> (p_formula ->> 'ability'))::int, 0)
    + case when coalesce(p_formula ->> 'rounding', 'down') = 'up'
           then ceil(p_level::numeric / coalesce((p_formula ->> 'level_divisor')::int, 1))::int
           else floor(p_level::numeric / coalesce((p_formula ->> 'level_divisor')::int, 1))::int end) end;
$$;

-- The whole class / spellcasting picture of a character. p_mods: ability modifiers {"int": 3, ...} from derived stats.
create function public._class_progress(p_character uuid, p_mods jsonb)
returns jsonb
language plpgsql stable
set search_path = public, pg_temp
as $$
declare
  r record; lv record; kind text; start_lvl int; prog text; active boolean; raw numeric; rounded int;
  n_std int := 0; ecl int := 0; single_prog text; single_level int; mode text;
  classes jsonb := '[]'; breakdown jsonb := '[]'; std jsonb := '{}'; pact jsonb := null;
  cnt record; ability text; plimit int; info jsonb; warn jsonb := '[]'; max_lvl int; over jsonb;
begin
  for r in
    select cc.*, cl.name as class_name, cl.sort_order, cv.name as version_name, cv.rules_label, cv.source_label, cv.source_url, cv.status,
           cv.superseded_by_version_id, cv.hit_die, cv.multiclass_contribution as contrib, cv.spellcasting_start_level as start,
           cv.slot_progression_id as prog, cv.spellcasting_ability, cv.prepared_formula, cv.preparation_mode, cv.ritual_mode,
           cv.is_pact_magic, cv.limitations, cv.implementation_status, cv.spell_list_id, cv.multiclass_prerequisite,
           sv.name as subclass_name, sv.multiclass_contribution as s_contrib, sv.spellcasting_start_level as s_start,
           sv.slot_progression_id as s_prog, sv.spellcasting_ability as s_ability, sv.spell_list_id as s_list,
           sv.preparation_mode as s_prep, sv.limitations as s_limitations,
           s.id as source_id, s.casting_ability as source_ability
    from public.character_classes cc
    join public.class_versions cv on cv.id = cc.class_version_id
    join public.classes cl on cl.id = cv.class_id
    left join public.subclass_versions sv on sv.id = cc.subclass_version_id
    left join public.character_spellcasting_sources s on s.character_class_id = cc.id
    where cc.character_id = p_character
    order by cc.is_primary desc, cc.level desc, cl.sort_order
  loop
    if r.contrib in ('full', 'half_down', 'half_up', 'pact') then
      kind := r.contrib; start_lvl := r.start; prog := r.prog;
      select * into lv from public.class_version_levels where class_version_id = r.class_version_id and level = r.level;
    elsif r.s_contrib = 'third_down' then
      kind := 'third_down'; start_lvl := r.s_start; prog := r.s_prog;
      select l.cantrips_known, l.spells_known, l.max_spell_level, null::int as pact_slots, null::int as pact_slot_level into lv
      from public.subclass_version_levels l where l.subclass_version_id = r.subclass_version_id and l.level = r.level;
    else
      kind := 'none'; start_lvl := null; prog := null;
      select null::int as cantrips_known, null::int as spells_known, null::int as max_spell_level, null::int as pact_slots,
             null::int as pact_slot_level into lv;
    end if;
    active := kind <> 'none' and r.level >= coalesce(start_lvl, 1);
    raw := case kind when 'full' then r.level when 'half_down' then r.level / 2.0 when 'half_up' then r.level / 2.0
                     when 'third_down' then r.level / 3.0 else 0 end;
    rounded := case when not active then 0
                    when kind = 'full' then r.level when kind = 'half_down' then r.level / 2 when kind = 'half_up' then (r.level + 1) / 2
                    when kind = 'third_down' then r.level / 3 else 0 end;
    if active and kind <> 'pact' then
      n_std := n_std + 1; ecl := ecl + rounded; single_prog := prog; single_level := r.level;
    end if;
    breakdown := breakdown || jsonb_build_object(
      'character_class_id', r.id, 'class_id', r.class_id, 'class_version_id', r.class_version_id, 'class_level', r.level,
      'subclass_version_id', r.subclass_version_id, 'contribution_type', kind, 'raw_contribution', raw,
      'rounded_contribution', case when kind = 'pact' then 0 else rounded end, 'active', active,
      'reason', case when kind = 'none' then 'not a spellcasting class' || case when r.class_id in ('fighter', 'rogue')
                                                                           then ' (only a spellcasting subclass contributes)' else '' end
                     when kind = 'pact' then 'Pact Magic is a separate pool'
                     when not active then format('spellcasting starts at %s level %s', r.class_name, start_lvl)
                     else null end);
    if kind = 'pact' and active then
      pact := jsonb_build_object('character_class_id', r.id, 'warlock_level', r.level, 'slots', lv.pact_slots,
                                 'slot_level', lv.pact_slot_level, 'recovers', 'short_or_long_rest', 'progression_id', prog);
    end if;

    -- counts of the class source's spells (lineage, item, feat, manual spells are other sources and never counted)
    select count(*) filter (where v.level = 0) as cantrips,
           count(*) filter (where v.level > 0 and g.known and g.counts_against_known_limit and not g.always_prepared) as known,
           count(*) filter (where v.level > 0 and g.prepared and not g.always_prepared and g.counts_against_prepared_limit) as prepared,
           count(*) filter (where g.always_prepared) as always_prepared,
           coalesce(jsonb_agg(jsonb_build_object('character_spell_id', g.id, 'spell_version_id', v.id, 'name', v.name, 'level', v.level))
                    filter (where v.level > 0 and (lv.max_spell_level is null or not active or v.level > lv.max_spell_level)), '[]') as above_max
    into cnt
    from public.character_spells g join public.spell_versions v on v.id = g.spell_version_id
    where g.source_id = r.source_id;
    ability := coalesce(r.source_ability, r.s_ability, r.spellcasting_ability);
    plimit := case when active and kind <> 'third_down' then public._prepared_limit(r.prepared_formula, p_mods, r.level) end;
    max_lvl := case when active then lv.max_spell_level end;
    over := jsonb_build_object(
      'cantrips', lv.cantrips_known is not null and active and cnt.cantrips > lv.cantrips_known,
      'known', lv.spells_known is not null and active and cnt.known > lv.spells_known,
      'prepared', plimit is not null and cnt.prepared > plimit,
      'above_max_level', jsonb_array_length(cnt.above_max) > 0);
    if (over ->> 'cantrips')::boolean then
      warn := warn || jsonb_build_object('code', 'over_cantrips', 'class_id', r.class_id,
        'message', format('%s: %s cantrips chosen, %s allowed at level %s', r.class_name, cnt.cantrips, lv.cantrips_known, r.level));
    end if;
    if (over ->> 'known')::boolean then
      warn := warn || jsonb_build_object('code', 'over_known', 'class_id', r.class_id,
        'message', format('%s: %s spells known, %s allowed at level %s', r.class_name, cnt.known, lv.spells_known, r.level));
    end if;
    if (over ->> 'prepared')::boolean then
      warn := warn || jsonb_build_object('code', 'over_prepared', 'class_id', r.class_id,
        'message', format('%s: %s spells prepared, %s allowed; unprepare some before preparing more', r.class_name, cnt.prepared, plimit));
    end if;
    if (over ->> 'above_max_level')::boolean then
      warn := warn || jsonb_build_object('code', 'spell_above_class_level', 'class_id', r.class_id, 'spells', cnt.above_max,
        'message', format('%s: %s spell(s) are above the level a level %s %s can choose (%s); review them, nothing was removed',
                          r.class_name, jsonb_array_length(cnt.above_max), r.level, r.class_name,
                          coalesce('up to level ' || max_lvl, 'no spells yet')));
    end if;
    if r.status = 'legacy' then
      warn := warn || jsonb_build_object('code', 'legacy_class_version', 'class_id', r.class_id,
        'message', format('%s uses a legacy class version; it is never changed automatically', r.version_name));
    end if;

    classes := classes || jsonb_build_object(
      'id', r.id, 'class_id', r.class_id, 'class_name', r.class_name, 'class_version_id', r.class_version_id,
      'version_name', r.version_name, 'rules_label', r.rules_label, 'source_label', r.source_label, 'source_url', r.source_url,
      'status', r.status, 'superseded_by_version_id', r.superseded_by_version_id, 'level', r.level, 'is_primary', r.is_primary,
      'started_at_level', r.started_at_level, 'notes', r.notes, 'hit_die', r.hit_die,
      'subclass_version_id', r.subclass_version_id, 'subclass_name', r.subclass_name,
      'implementation_status', r.implementation_status,
      'limitations', to_jsonb(r.limitations) || coalesce(to_jsonb(r.s_limitations), '[]'),
      'multiclass_prerequisite', r.multiclass_prerequisite,
      'contribution', jsonb_build_object('type', kind, 'raw', raw, 'rounded', case when kind = 'pact' then 0 else rounded end, 'active', active),
      'spellcasting', case when kind = 'none' then null else jsonb_build_object(
        'source_id', r.source_id, 'ability', ability, 'ability_modifier', (p_mods ->> ability)::int,
        'spell_list_id', coalesce(r.s_list, r.spell_list_id),
        'preparation_mode', case when kind = 'third_down' then r.s_prep else r.preparation_mode end,
        'ritual_mode', case when kind = 'third_down' then 'none' else r.ritual_mode end,
        'start_level', start_lvl, 'active', active, 'max_spell_level', max_lvl,
        'cantrips_known', case when active then lv.cantrips_known end, 'spells_known', case when active then lv.spells_known end,
        'prepared_limit', plimit, 'prepared_formula', case when kind = 'third_down' then null else r.prepared_formula end,
        'pact_magic', kind = 'pact',
        'counts', jsonb_build_object('cantrips', cnt.cantrips, 'known', cnt.known, 'prepared', cnt.prepared,
                                     'always_prepared', cnt.always_prepared),
        'over_limit', over, 'spells_above_max_level', cnt.above_max) end);
  end loop;

  if n_std = 1 then
    mode := 'single_class'; std := public._progression_slots(single_prog, single_level);
  elsif n_std > 1 then
    mode := 'multiclass'; std := public._progression_slots('standard-caster', least(ecl, 20));
  else
    mode := case when pact is not null then 'pact_only' else 'none' end;
  end if;
  return jsonb_build_object('classes', classes, 'breakdown', breakdown, 'standard_caster_classes', n_std,
                            'effective_caster_level', least(ecl, 20), 'slot_mode', mode, 'standard_max', std, 'pact', pact,
                            'warnings', warn);
end;
$$;

-- ability modifiers of a character as {"str": 0, ...} (from the derived stats: lineage bonuses included)
create function public._character_mods(p_character uuid)
returns jsonb
language sql stable
set search_path = public, pg_temp
as $$
  select jsonb_object_agg(k, (d -> 'abilities' -> k ->> 'modifier')::int)
  from (select public.get_character_derived_stats(p_character) as d) x, jsonb_object_keys(x.d -> 'abilities') k;
$$;

-- maximum of a resource: {"fixed": n} | {"table": [[level, value | null = unlimited], ...], "level": "class" | "total"}
-- | {"terms": [{"of": "fixed", "value": n} | {"of": "proficiency_bonus"} | {"of": "ability", "ability": "cha"}
--             | {"of": "class_level" | "total_level", "multiplier": m, "divisor": d}]}, plus optional "minimum"
create function public._resource_max(p_formula jsonb, p_ctx jsonb)
returns jsonb
language plpgsql immutable
set search_path = public, pg_temp
as $$
declare lvl int; v jsonb; total int := 0; t jsonb; part numeric;
begin
  lvl := case when coalesce(p_formula ->> 'level', 'class') = 'total' then (p_ctx ->> 'total_level')::int
              else coalesce((p_ctx ->> 'class_level')::int, (p_ctx ->> 'total_level')::int) end;
  if p_formula ? 'fixed' then
    total := (p_formula ->> 'fixed')::int;
  elsif p_formula ? 'table' then
    select e -> 1 into v from jsonb_array_elements(p_formula -> 'table') e
    where (e ->> 0)::int <= lvl order by (e ->> 0)::int desc limit 1;
    if v is null then return jsonb_build_object('max', 0, 'unlimited', false); end if;
    if jsonb_typeof(v) = 'null' then return jsonb_build_object('max', null, 'unlimited', true); end if;
    total := v::text::int;
  elsif p_formula ? 'terms' then
    for t in select * from jsonb_array_elements(p_formula -> 'terms') loop
      part := case t ->> 'of'
                when 'fixed' then (t ->> 'value')::int
                when 'proficiency_bonus' then (p_ctx ->> 'proficiency_bonus')::int
                when 'ability' then coalesce((p_ctx -> 'mods' ->> (t ->> 'ability'))::int, 0)
                when 'class_level' then coalesce((p_ctx ->> 'class_level')::int, (p_ctx ->> 'total_level')::int)
                when 'total_level' then (p_ctx ->> 'total_level')::int
                else null end;
      if part is null then raise exception 'Unknown resource formula term %', t using errcode = '22023'; end if;
      part := part * coalesce((t ->> 'multiplier')::numeric, 1) / coalesce((t ->> 'divisor')::numeric, 1);
      total := total + case when t ->> 'rounding' = 'up' then ceil(part) else floor(part) end;
    end loop;
  else
    raise exception 'A resource formula needs fixed, table or terms' using errcode = '22023';
  end if;
  return jsonb_build_object('max', greatest(total, coalesce((p_formula ->> 'minimum')::int, 0)), 'unlimited', false);
end;
$$;

-- every resource of a character with its derived maximum and remaining uses
create function public._character_resource_rows(p_character uuid, p_mods jsonb)
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
  where r.character_id = p_character;
$$;

-- ---- spell eligibility and prepared limits for class-linked sources (enforced here, so the 1600 RPCs stay as they are) ----
create function public.character_spells_class_rules()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
declare src public.character_spellcasting_sources; v public.spell_versions; prog jsonb; cls jsonb; sc jsonb; lim int; n int;
begin
  select * into src from public.character_spellcasting_sources where id = new.source_id;
  if src.character_class_id is null then return new; end if;                  -- manual, item, feat, lineage, preview: own rules
  select * into v from public.spell_versions where id = new.spell_version_id;
  prog := public._class_progress(new.character_id, public._character_mods(new.character_id));
  select e into cls from jsonb_array_elements(prog -> 'classes') e where e ->> 'id' = src.character_class_id::text;
  sc := cls -> 'spellcasting';
  if tg_op = 'INSERT' or new.spell_version_id is distinct from old.spell_version_id then
    if sc is null or jsonb_typeof(sc) = 'null' then
      raise exception '% does not cast spells', cls ->> 'class_name' using errcode = '22023';
    end if;
    if not (sc ->> 'active')::boolean then
      raise exception '% spellcasting starts at level %', cls ->> 'class_name', sc ->> 'start_level' using errcode = '22023';
    end if;
    if v.level = 0 and sc ->> 'cantrips_known' is null then
      raise exception '% does not learn cantrips', cls ->> 'class_name' using errcode = '22023';
    end if;
    if v.level > 0 and (sc ->> 'max_spell_level' is null or v.level > (sc ->> 'max_spell_level')::int) then
      raise exception '% is a level % spell; a level % % can choose %', v.name, v.level, cls ->> 'level', cls ->> 'class_name',
        coalesce('spells up to level ' || (sc ->> 'max_spell_level'), format('no spells before %s level %s', cls ->> 'class_name',
                 sc ->> 'start_level')) using errcode = '22023';
    end if;
  end if;
  lim := (sc ->> 'prepared_limit')::int;
  if lim is not null and v.level > 0 and new.prepared and not new.always_prepared and new.counts_against_prepared_limit
     and (tg_op = 'INSERT' or not old.prepared or old.always_prepared) then
    select count(*) into n from public.character_spells g join public.spell_versions x on x.id = g.spell_version_id
    where g.source_id = new.source_id and g.id <> new.id and x.level > 0 and g.prepared and not g.always_prepared
      and g.counts_against_prepared_limit;
    if n >= lim then
      raise exception '% can prepare % spells and has % prepared; unprepare one first', cls ->> 'class_name', lim, n
        using errcode = '22023';
    end if;
  end if;
  return new;
end;
$$;
create trigger character_spells_class_rules before insert or update on public.character_spells
  for each row execute function public.character_spells_class_rules();

-- ---- derived stats: the level now comes from the classes (the 1500 function is kept as the core) -----------------------
alter function public.get_character_derived_stats(uuid) rename to _derived_stats_core;
create function public.get_character_derived_stats(p_character uuid)
returns jsonb
language plpgsql stable
set search_path = public, pg_temp
as $$
declare d jsonb; li jsonb;
begin
  d := public._derived_stats_core(p_character);                      -- RLS: owner, campaign DM, admin
  li := public._character_level_info(p_character);
  return d || jsonb_build_object(
    'level', li,
    'proficiency_bonus', (d -> 'proficiency_bonus') || jsonb_build_object(
      'source', 'total_level', 'level', (li ->> 'total_level')::int, 'level_source', li ->> 'source',
      'fallback', (li ->> 'fallback')::boolean));
end;
$$;

-- ---- read models ---------------------------------------------------------------------------------------------------------
create function public.get_character_class_summary(p_character uuid)
returns jsonb
language plpgsql stable
set search_path = public, pg_temp
as $$
declare li jsonb; d jsonb; mods jsonb; prog jsonb; prereq jsonb := '[]'; r record; ok boolean;
begin
  perform 1 from public.characters where id = p_character;                    -- RLS: owner, campaign DM, admin
  if not found then raise exception 'Character not found' using errcode = '42501'; end if;
  li := public._character_level_info(p_character);
  d := public.get_character_derived_stats(p_character);
  select jsonb_object_agg(k, (d -> 'abilities' -> k ->> 'modifier')::int) into mods from jsonb_object_keys(d -> 'abilities') k;
  prog := public._class_progress(p_character, mods);
  -- multiclass prerequisites: warnings only (the full multiclass rules are not implemented)
  if (li ->> 'class_count')::int > 1 then
    for r in select e from jsonb_array_elements(prog -> 'classes') e where e -> 'multiclass_prerequisite' is not null
                                                                      and jsonb_typeof(e -> 'multiclass_prerequisite') = 'object' loop
      select case when r.e -> 'multiclass_prerequisite' ? 'any'
                  then bool_or(coalesce((d -> 'abilities' -> (x ->> 'ability') ->> 'score')::int, 0) >= (x ->> 'min')::int)
                  else bool_and(coalesce((d -> 'abilities' -> (x ->> 'ability') ->> 'score')::int, 0) >= (x ->> 'min')::int) end
      into ok
      from jsonb_array_elements(coalesce(r.e -> 'multiclass_prerequisite' -> 'all', r.e -> 'multiclass_prerequisite' -> 'any')) x;
      if not coalesce(ok, true) then
        prereq := prereq || jsonb_build_object('code', 'multiclass_prerequisite', 'class_id', r.e ->> 'class_id',
          'message', format('%s multiclassing usually needs %s (warning only; not enforced)', r.e ->> 'class_name',
            (select string_agg(upper(x ->> 'ability') || ' ' || (x ->> 'min'),
                               case when r.e -> 'multiclass_prerequisite' ? 'any' then ' or ' else ' and ' end)
             from jsonb_array_elements(coalesce(r.e -> 'multiclass_prerequisite' -> 'all', r.e -> 'multiclass_prerequisite' -> 'any')) x)));
      end if;
    end loop;
  end if;
  return jsonb_build_object(
    'character_id', p_character, 'scope', 'Class and Spellcasting Foundation',
    'total_level', (li ->> 'total_level')::int, 'level_source', li ->> 'source', 'fallback', (li ->> 'fallback')::boolean,
    'legacy_level', (li ->> 'legacy_level')::int, 'proficiency_bonus', (li ->> 'proficiency_bonus')::int,
    'classes', prog -> 'classes', 'breakdown', prog -> 'breakdown',
    'effective_caster_level', (prog ->> 'effective_caster_level')::int, 'slot_mode', prog ->> 'slot_mode',
    'standard_slots_max', prog -> 'standard_max', 'pact_magic', prog -> 'pact',
    'resources', public._character_resource_rows(p_character, mods),
    'warnings', (prog -> 'warnings') || prereq,
    'limitations', jsonb_build_array(
      'Class features, subclass features and subclass spell lists are not implemented.',
      'Known and prepared limits are shown; only spell level and the prepared limit are enforced.',
      'Mystic Arcanum, Font of Magic, Arcane Recovery and Wild Shape are not implemented.',
      'Multiclass prerequisites are warnings only.'));
end;
$$;

create function public.get_character_spell_slots(p_character uuid)
returns jsonb
language plpgsql stable
set search_path = public, pg_temp
as $$
declare prog jsonb; li jsonb; std jsonb; pact jsonb := null; pexp int; opts jsonb := '[]'; lvl int; temp jsonb; legacy jsonb;
begin
  perform 1 from public.characters where id = p_character;                    -- RLS: owner, campaign DM, admin
  if not found then raise exception 'Character not found' using errcode = '42501'; end if;
  li := public._character_level_info(p_character);
  prog := public._class_progress(p_character, public._character_mods(p_character));

  select coalesce(jsonb_agg(jsonb_build_object('slot_level', l, 'max', mx, 'expended', least(coalesce(st.expended, 0), mx),
                                               'expended_stored', coalesce(st.expended, 0),
                                               'remaining', greatest(mx - coalesce(st.expended, 0), 0)) order by l), '[]')
  into std
  from (select k::int as l, (prog -> 'standard_max' ->> k)::int as mx from jsonb_object_keys(prog -> 'standard_max') k) m
  left join public.character_spell_slot_state st on st.character_id = p_character and st.pool = 'standard' and st.slot_level = m.l;

  if prog -> 'pact' is not null and jsonb_typeof(prog -> 'pact') = 'object' then
    select coalesce(expended, 0) into pexp from public.character_spell_slot_state
    where character_id = p_character and pool = 'pact' and slot_level = 0;
    pexp := coalesce(pexp, 0);
    pact := (prog -> 'pact') || jsonb_build_object('max', (prog -> 'pact' ->> 'slots')::int,
              'expended', least(pexp, (prog -> 'pact' ->> 'slots')::int), 'expended_stored', pexp,
              'remaining', greatest((prog -> 'pact' ->> 'slots')::int - pexp, 0));
  end if;

  select coalesce(jsonb_agg(jsonb_build_object('id', t.id, 'slot_level', t.slot_level, 'quantity', t.quantity, 'expended', t.expended,
                                               'remaining', t.quantity - t.expended, 'source_type', t.source_type,
                                               'source_label', t.source_label, 'expires_on', t.expires_on) order by t.slot_level, t.created_at), '[]')
  into temp from public.character_temporary_spell_slots t where t.character_id = p_character;

  select coalesce(jsonb_agg(jsonb_build_object('id', s.id, 'level', s.level, 'total', s.total, 'used', s.used) order by s.level), '[]')
  into legacy from public.spell_slots s where s.character_id = p_character and s.total > 0;

  -- which slots could pay for a spell of each level (cantrips never use a slot; nothing is cast here)
  for lvl in 1..9 loop
    opts := opts || jsonb_build_object('spell_level', lvl,
      'standard_slot_levels', (select coalesce(jsonb_agg((e ->> 'slot_level')::int order by (e ->> 'slot_level')::int), '[]')
                               from jsonb_array_elements(std) e where (e ->> 'slot_level')::int >= lvl and (e ->> 'remaining')::int > 0),
      'pact_slot', pact is not null and (pact ->> 'remaining')::int > 0 and (pact ->> 'slot_level')::int >= lvl,
      'temporary_slot_levels', (select coalesce(jsonb_agg(distinct (e ->> 'slot_level')::int), '[]')
                                from jsonb_array_elements(temp) e where (e ->> 'slot_level')::int >= lvl and (e ->> 'remaining')::int > 0));
  end loop;

  return jsonb_build_object(
    'character_id', p_character, 'total_level', (li ->> 'total_level')::int, 'level_source', li ->> 'source',
    'slot_mode', prog ->> 'slot_mode', 'effective_caster_level', (prog ->> 'effective_caster_level')::int,
    'breakdown', prog -> 'breakdown', 'standard', std, 'pact_magic', pact, 'temporary', temp,
    'legacy_manual', legacy, 'legacy_manual_active', jsonb_array_length(std) = 0 and pact is null,
    'casting_options', opts,
    'rests', jsonb_build_object(
      'short', 'Restores Pact Magic slots and resources that recharge on a short rest; standard slots are not restored.',
      'long', 'Restores standard and Pact Magic slots, long-rest resources and trackers; removes temporary slots.'));
end;
$$;

-- ---- write path: classes -------------------------------------------------------------------------------------------------
create function public.set_character_class(p_character uuid, p_class_version text, p_level int,
                                           p_subclass_version text default null, p_is_primary boolean default null,
                                           p_character_class uuid default null, p_notes text default null)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare cv public.class_versions; sv public.subclass_versions; cc public.character_classes; existing public.character_classes;
  others int; casts boolean; src uuid;
begin
  if auth.uid() is null or not public.can_access_character(p_character) then
    raise exception 'Character not found' using errcode = '42501';
  end if;
  select * into cv from public.class_versions where id = p_class_version;
  if not found then raise exception 'Unknown class version "%"', p_class_version using errcode = '22023'; end if;
  if p_level is null or p_level not between 1 and 20 then
    raise exception 'A class level is between 1 and 20' using errcode = '22023';
  end if;
  if p_subclass_version is not null then
    select * into sv from public.subclass_versions where id = p_subclass_version;
    if not found or sv.class_id <> cv.class_id then
      raise exception 'Subclass "%" does not belong to %', p_subclass_version, cv.name using errcode = '22023';
    end if;
  end if;
  if length(p_notes) > 500 then raise exception 'Notes are too long' using errcode = '22023'; end if;
  perform 1 from public.characters where id = p_character for update;          -- one class change per character at a time

  if p_character_class is not null then
    select * into existing from public.character_classes where id = p_character_class and character_id = p_character;
    if not found then raise exception 'Character class not found' using errcode = '42501'; end if;
    if existing.class_id <> cv.class_id then
      raise exception 'A class row keeps its class; add % as a new class instead', cv.name using errcode = '22023';
    end if;
  else
    select * into existing from public.character_classes where character_id = p_character and class_id = cv.class_id;
    if found and existing.class_version_id <> cv.id then          -- a version change must name the class row explicitly
      raise exception 'This character already has % (%); change the version of that class instead', cv.name, existing.class_version_id
        using errcode = '22023';
    end if;
  end if;
  select coalesce(sum(level), 0) into others from public.character_classes
  where character_id = p_character and id is distinct from existing.id;
  if others + p_level > 20 then
    raise exception 'Class levels would add up to %; the total character level is at most 20', others + p_level using errcode = '22023';
  end if;

  if existing.id is null then
    insert into public.character_classes (character_id, class_id, class_version_id, subclass_version_id, level, is_primary,
                                          started_at_level, notes, created_by)
    values (p_character, cv.class_id, cv.id, p_subclass_version, p_level, false, others + 1, nullif(btrim(p_notes), ''), auth.uid())
    returning * into cc;
  else
    update public.character_classes set class_version_id = cv.id, subclass_version_id = p_subclass_version, level = p_level,
                                        notes = coalesce(nullif(btrim(p_notes), ''), notes)
    where id = existing.id returning * into cc;
  end if;
  if coalesce(p_is_primary, false) or not exists (select 1 from public.character_classes where character_id = p_character and is_primary) then
    update public.character_classes set is_primary = false where character_id = p_character and is_primary and id <> cc.id;
    update public.character_classes set is_primary = true where id = cc.id;
  end if;

  -- the class spellcasting source: linked to the class row; an unlinked preview source of the same class version is adopted
  casts := cv.multiclass_contribution <> 'none' or coalesce(sv.multiclass_contribution, 'none') <> 'none';
  select id into src from public.character_spellcasting_sources where character_class_id = cc.id;
  if casts and src is null then
    select id into src from public.character_spellcasting_sources
    where character_id = p_character and character_class_id is null and source_type = 'class'
      and class_version_id in (select id from public.class_versions where class_id = cv.class_id)
    order by created_at limit 1;
    if src is not null then
      update public.character_spellcasting_sources set character_class_id = cc.id, casting_ability = null, class_version_id = cv.id
      where id = src;
    else
      insert into public.character_spellcasting_sources (character_id, source_type, label, character_class_id, class_version_id,
                                                         enforce_spell_list, created_by)
      values (p_character, 'class', coalesce(sv.name, cv.name), cc.id, cv.id, true, auth.uid());
    end if;
  elsif src is not null then
    update public.character_spellcasting_sources set class_version_id = cv.id where id = src;   -- version change follows the class
  end if;
  return public.get_character_class_summary(p_character);
end;
$$;

create function public.remove_character_class(p_character_class uuid, p_confirm boolean default false)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare cc public.character_classes; n int; cname text;
begin
  select * into cc from public.character_classes where id = p_character_class;
  if auth.uid() is null or cc.id is null or not public.can_access_character(cc.character_id) then
    raise exception 'Character class not found' using errcode = '42501';
  end if;
  perform 1 from public.characters where id = cc.character_id for update;
  select name into cname from public.classes where id = cc.class_id;
  select count(*) into n from public.character_spells g join public.character_spellcasting_sources s on s.id = g.source_id
  where s.character_class_id = cc.id;
  if n > 0 and not coalesce(p_confirm, false) then
    raise exception 'Removing % also removes its spellcasting source and % spell(s); confirm to continue', cname, n
      using errcode = '22023', hint = 'confirm_required';
  end if;
  delete from public.character_classes where id = cc.id;              -- its source, spells and resources go with it
  if cc.is_primary then
    update public.character_classes set is_primary = true
    where id = (select id from public.character_classes where character_id = cc.character_id order by level desc, created_at limit 1);
  end if;
  return public.get_character_class_summary(cc.character_id);
end;
$$;

-- ---- write path: slots ---------------------------------------------------------------------------------------------------
create function public._slot_change(p_character uuid, p_pool text, p_slot_level int, p_delta int, p_reason text)
returns jsonb
language plpgsql
set search_path = public, pg_temp
as $$
declare prog jsonb; mx int; before int; after int; lvl int := case when p_pool = 'pact' then 0 else p_slot_level end; plevel int;
begin
  if auth.uid() is null or not public.can_access_character(p_character) then
    raise exception 'Character not found' using errcode = '42501';
  end if;
  perform 1 from public.characters where id = p_character for update;           -- serializes slot changes of this character
  prog := public._class_progress(p_character, public._character_mods(p_character));
  if p_pool = 'pact' then
    if prog -> 'pact' is null or jsonb_typeof(prog -> 'pact') <> 'object' then
      raise exception 'This character has no Pact Magic slots' using errcode = '22023';
    end if;
    mx := (prog -> 'pact' ->> 'slots')::int; plevel := (prog -> 'pact' ->> 'slot_level')::int;
  else
    if p_slot_level is null or p_slot_level not between 1 and 9 then
      raise exception 'A spell slot level is between 1 and 9' using errcode = '22023';
    end if;
    mx := (prog -> 'standard_max' ->> p_slot_level::text)::int;
    if mx is null then raise exception 'This character has no level % spell slots', p_slot_level using errcode = '22023'; end if;
  end if;
  insert into public.character_spell_slot_state (character_id, pool, slot_level) values (p_character, p_pool, lvl)
  on conflict do nothing;
  select expended into before from public.character_spell_slot_state
  where character_id = p_character and pool = p_pool and slot_level = lvl for update;
  if p_delta > 0 and before >= mx then
    raise exception 'No % slot left', case when p_pool = 'pact' then format('Pact Magic (level %s)', plevel)
                                            else format('level %s', p_slot_level) end using errcode = '22023';
  end if;
  if p_delta < 0 and before <= 0 then
    raise exception 'No expended % slot to restore', case when p_pool = 'pact' then 'Pact Magic' else format('level %s', p_slot_level) end
      using errcode = '22023';
  end if;
  after := least(greatest(before, 0) + p_delta, greatest(mx, 0));
  after := greatest(after, 0);
  update public.character_spell_slot_state set expended = after where character_id = p_character and pool = p_pool and slot_level = lvl;
  insert into public.character_resource_events (character_id, event_type, pool, slot_level, amount, expended_before, expended_after, reason, details)
  values (p_character, case when p_delta > 0 then 'expend' else 'restore' end, p_pool, coalesce(plevel, p_slot_level), abs(p_delta),
          before, after, nullif(btrim(p_reason), ''), case when p_pool = 'pact' then jsonb_build_object('pact_slot_level', plevel) end);
  return public.get_character_spell_slots(p_character);
end;
$$;

create function public.expend_standard_spell_slot(p_character uuid, p_slot_level int, p_reason text default null)
returns jsonb language sql security definer set search_path = public, pg_temp
as $$ select public._slot_change(p_character, 'standard', p_slot_level, 1, p_reason) $$;
create function public.restore_standard_spell_slot(p_character uuid, p_slot_level int, p_reason text default null)
returns jsonb language sql security definer set search_path = public, pg_temp
as $$ select public._slot_change(p_character, 'standard', p_slot_level, -1, p_reason) $$;
create function public.expend_pact_magic_slot(p_character uuid, p_reason text default null)
returns jsonb language sql security definer set search_path = public, pg_temp
as $$ select public._slot_change(p_character, 'pact', null, 1, p_reason) $$;
create function public.restore_pact_magic_slot(p_character uuid, p_reason text default null)
returns jsonb language sql security definer set search_path = public, pg_temp
as $$ select public._slot_change(p_character, 'pact', null, -1, p_reason) $$;

-- authorized manual correction (distinct event type, reason required)
create function public.set_spell_slot_state(p_character uuid, p_pool text, p_slot_level int, p_expended int, p_reason text)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare prog jsonb; mx int; before int; lvl int := case when p_pool = 'pact' then 0 else p_slot_level end;
begin
  if auth.uid() is null or not public.can_access_character(p_character) then
    raise exception 'Character not found' using errcode = '42501';
  end if;
  if p_pool not in ('standard', 'pact') then raise exception 'Unknown slot pool "%"', p_pool using errcode = '22023'; end if;
  if coalesce(btrim(p_reason), '') = '' then raise exception 'A manual correction needs a reason' using errcode = '22023'; end if;
  perform 1 from public.characters where id = p_character for update;
  prog := public._class_progress(p_character, public._character_mods(p_character));
  mx := case when p_pool = 'pact' then (prog -> 'pact' ->> 'slots')::int else (prog -> 'standard_max' ->> p_slot_level::text)::int end;
  if mx is null then raise exception 'This character has no such spell slots' using errcode = '22023'; end if;
  if p_expended is null or p_expended < 0 or p_expended > mx then
    raise exception 'Expended slots must be between 0 and %', mx using errcode = '22023';
  end if;
  insert into public.character_spell_slot_state (character_id, pool, slot_level) values (p_character, p_pool, lvl) on conflict do nothing;
  select expended into before from public.character_spell_slot_state where character_id = p_character and pool = p_pool and slot_level = lvl for update;
  if before is distinct from p_expended then                      -- a correction that changes nothing is not logged
    update public.character_spell_slot_state set expended = p_expended where character_id = p_character and pool = p_pool and slot_level = lvl;
    insert into public.character_resource_events (character_id, event_type, pool, slot_level, expended_before, expended_after, reason)
    values (p_character, 'manual_set', p_pool, p_slot_level, before, p_expended, btrim(p_reason));
  end if;
  return public.get_character_spell_slots(p_character);
end;
$$;

-- ---- write path: resources -----------------------------------------------------------------------------------------------
create function public.save_character_resource(p_character uuid, p_resource jsonb)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare k text; r public.character_resources; v_id uuid;
  allowed constant text[] := array['id', 'resource_key', 'name', 'source_type', 'source_id', 'character_class_id', 'max_formula', 'minimum',
    'die', 'recharge', 'unlock_level', 'spell_version_id', 'cast_level', 'active', 'notes'];
begin
  if auth.uid() is null or not public.can_access_character(p_character) then
    raise exception 'Character not found' using errcode = '42501';
  end if;
  if jsonb_typeof(p_resource) <> 'object' then raise exception 'The resource must be an object' using errcode = '22023'; end if;
  for k in select jsonb_object_keys(p_resource) loop
    if not k = any (allowed) then raise exception 'Field "%" cannot be set on a resource', k using errcode = '22023'; end if;
  end loop;
  if p_resource ? 'max_formula' then
    perform public._resource_max(p_resource -> 'max_formula', '{"total_level": 1, "class_level": 1, "proficiency_bonus": 2, "mods": {}}');
  end if;
  if p_resource ->> 'character_class_id' is not null and not exists (
       select 1 from public.character_classes where id = (p_resource ->> 'character_class_id')::uuid and character_id = p_character) then
    raise exception 'Character class not found' using errcode = '22023';
  end if;
  v_id := nullif(p_resource ->> 'id', '')::uuid;
  if v_id is not null and not exists (select 1 from public.character_resources where id = v_id and character_id = p_character) then
    raise exception 'Resource not found' using errcode = '42501';
  end if;
  begin
    if v_id is null then
      insert into public.character_resources (character_id, resource_key, name, created_by)
      values (p_character, p_resource ->> 'resource_key', btrim(p_resource ->> 'name'), auth.uid()) returning id into v_id;
    end if;
    update public.character_resources set
      resource_key = coalesce(p_resource ->> 'resource_key', resource_key), name = coalesce(btrim(p_resource ->> 'name'), name),
      source_type = coalesce(p_resource ->> 'source_type', source_type), source_id = coalesce(p_resource ->> 'source_id', source_id),
      character_class_id = coalesce((p_resource ->> 'character_class_id')::uuid, character_class_id),
      max_formula = coalesce(p_resource -> 'max_formula', max_formula), minimum = coalesce((p_resource ->> 'minimum')::int, minimum),
      die = coalesce(p_resource ->> 'die', die), recharge = coalesce(p_resource ->> 'recharge', recharge),
      unlock_level = coalesce((p_resource ->> 'unlock_level')::int, unlock_level),
      spell_version_id = coalesce(p_resource ->> 'spell_version_id', spell_version_id),
      cast_level = coalesce((p_resource ->> 'cast_level')::int, cast_level),
      active = coalesce((p_resource ->> 'active')::boolean, active), notes = coalesce(nullif(btrim(p_resource ->> 'notes'), ''), notes)
    where id = v_id returning * into r;
  exception
    when check_violation or not_null_violation or invalid_text_representation or foreign_key_violation or unique_violation then
      raise exception 'Invalid resource: %', sqlerrm using errcode = '22023';
  end;
  return to_jsonb(r) - 'created_by';
end;
$$;

create function public.change_character_resource(p_resource uuid, p_delta int, p_reason text default null)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare r public.character_resources; rows jsonb; me jsonb; before int; after int;
begin
  select * into r from public.character_resources where id = p_resource;
  if auth.uid() is null or r.id is null or not public.can_access_character(r.character_id) then
    raise exception 'Resource not found' using errcode = '42501';
  end if;
  if p_delta is null or p_delta = 0 then raise exception 'Nothing to change' using errcode = '22023'; end if;
  perform 1 from public.characters where id = r.character_id for update;
  select * into r from public.character_resources where id = p_resource for update;
  rows := public._character_resource_rows(r.character_id, public._character_mods(r.character_id));
  select e into me from jsonb_array_elements(rows) e where e ->> 'id' = p_resource::text;
  if not (me ->> 'active')::boolean or not (me ->> 'unlocked')::boolean then
    raise exception '% is not available', r.name using errcode = '22023';
  end if;
  before := r.expended;
  if p_delta > 0 and not (me ->> 'unlimited')::boolean and before + p_delta > (me ->> 'max')::int then
    raise exception 'Not enough % left (% of %)', r.name, greatest((me ->> 'max')::int - before, 0), me ->> 'max' using errcode = '22023';
  end if;
  if p_delta < 0 and before + p_delta < 0 then raise exception 'Nothing of % to restore', r.name using errcode = '22023'; end if;
  after := case when (me ->> 'unlimited')::boolean then 0 else before + p_delta end;
  update public.character_resources set expended = after where id = p_resource;
  insert into public.character_resource_events (character_id, event_type, pool, resource_id, amount, expended_before, expended_after, reason)
  values (r.character_id, case when p_delta > 0 then 'expend' else 'restore' end, 'resource', p_resource, abs(p_delta), before, after,
          nullif(btrim(p_reason), ''));
  select e into me from jsonb_array_elements(public._character_resource_rows(r.character_id, public._character_mods(r.character_id))) e
  where e ->> 'id' = p_resource::text;
  return me;
end;
$$;

create function public.delete_character_resource(p_resource uuid)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare cid uuid;
begin
  select character_id into cid from public.character_resources where id = p_resource;
  if auth.uid() is null or cid is null or not public.can_access_character(cid) then
    raise exception 'Resource not found' using errcode = '42501';
  end if;
  delete from public.character_resources where id = p_resource;
  return jsonb_build_object('deleted', true, 'id', p_resource);
end;
$$;

-- ---- rests -------------------------------------------------------------------------------------------------------------------
-- Short rest: Pact Magic slots, short-rest resources and trackers, short-rest temporary slots. Standard slots are NOT restored.
-- Long rest: standard and Pact Magic slots, long- and short-rest resources, all trackers, manual (legacy) slots, temporary
-- slots. HP, hit dice and conditions are not touched here (the app keeps its existing long-rest HP / hit dice step).
-- p_rest_id makes a retry safe: the same id is applied once.
create function public._rest(p_character uuid, p_kind text, p_rest_id uuid)
returns jsonb
language plpgsql
set search_path = public, pg_temp
as $$
declare std jsonb := '[]'; pact int := 0; res jsonb := '[]'; trk jsonb := '[]'; legacy int := 0; tmp int := 0; out jsonb; rid uuid;
  prev jsonb;
begin
  if auth.uid() is null or not public.can_access_character(p_character) then
    raise exception 'Character not found' using errcode = '42501';
  end if;
  perform 1 from public.characters where id = p_character for update;
  rid := coalesce(p_rest_id, gen_random_uuid());
  select details into prev from public.character_resource_events
  where character_id = p_character and rest_id = rid and event_type in ('short_rest', 'long_rest');
  if found then return prev || jsonb_build_object('already_applied', true); end if;

  if p_kind = 'long' then
    with u as (update public.character_spell_slot_state set expended = 0
               where character_id = p_character and pool = 'standard' and expended > 0 returning slot_level, expended)
    select coalesce(jsonb_agg(jsonb_build_object('slot_level', slot_level, 'restored', expended) order by slot_level), '[]') into std from u;
  end if;
  with u as (update public.character_spell_slot_state set expended = 0
             where character_id = p_character and pool = 'pact' and expended > 0 returning expended)
  select coalesce(sum(expended), 0) into pact from u;
  with u as (update public.character_resources set expended = 0
             where character_id = p_character and expended > 0
               and recharge in (case when p_kind = 'long' then 'long_rest' else 'short_rest' end, 'short_rest', 'short_or_long_rest')
             returning name)
  select coalesce(jsonb_agg(name order by name), '[]') into res from u;
  with u as (update public.feature_trackers set current = max
             where character_id = p_character and current <> max
               and (reset_on = 'short' or (p_kind = 'long' and reset_on = 'long'))
             returning name)
  select coalesce(jsonb_agg(name order by name), '[]') into trk from u;
  if p_kind = 'long' then
    with u as (update public.spell_slots set used = 0 where character_id = p_character and used > 0 returning 1)
    select count(*) into legacy from u;
  end if;
  with d as (delete from public.character_temporary_spell_slots
             where character_id = p_character and (expires_on = 'short_rest' or (p_kind = 'long' and expires_on = 'long_rest'))
             returning 1)
  select count(*) into tmp from d;

  out := jsonb_build_object('rest', p_kind, 'rest_id', rid, 'already_applied', false,
    'restored', jsonb_build_object('standard_slots', std, 'pact_slots', pact, 'resources', res, 'trackers', trk,
                                   'legacy_manual_slot_levels', legacy, 'temporary_slots_removed', tmp),
    'not_handled', case when p_kind = 'long'
                        then jsonb_build_array('hit points, temporary HP, death saves and hit dice (applied by the app as before)',
                                               'conditions', 'prepared spell changes (change them yourself)', 'dawn resources')
                        else jsonb_build_array('standard spell slots', 'hit dice spending', 'hit points') end);
  insert into public.character_resource_events (character_id, event_type, pool, rest_id, details)
  values (p_character, p_kind || '_rest', 'rest', rid, out);
  return out;
end;
$$;

create function public.short_rest_character(p_character uuid, p_rest_id uuid default null)
returns jsonb language sql security definer set search_path = public, pg_temp
as $$ select public._rest(p_character, 'short', p_rest_id) $$;
create function public.long_rest_character(p_character uuid, p_rest_id uuid default null)
returns jsonb language sql security definer set search_path = public, pg_temp
as $$ select public._rest(p_character, 'long', p_rest_id) $$;

-- ---- RLS, grants, Realtime ----------------------------------------------------------------------------------------------
alter table public.subclass_versions enable row level security;
alter table public.class_version_levels enable row level security;
alter table public.subclass_version_levels enable row level security;
alter table public.character_classes enable row level security;
alter table public.character_spell_slot_state enable row level security;
alter table public.character_temporary_spell_slots enable row level security;
alter table public.character_resources enable row level security;
alter table public.character_resource_events enable row level security;

create policy "subclass_versions_read" on public.subclass_versions for select to anon, authenticated using (true);
create policy "class_version_levels_read" on public.class_version_levels for select to anon, authenticated using (true);
create policy "subclass_version_levels_read" on public.subclass_version_levels for select to anon, authenticated using (true);
create policy "character_classes_read" on public.character_classes for select to authenticated using (public.can_access_character(character_id));
create policy "character_spell_slot_state_read" on public.character_spell_slot_state for select to authenticated
  using (public.can_access_character(character_id));
create policy "character_temporary_spell_slots_read" on public.character_temporary_spell_slots for select to authenticated
  using (public.can_access_character(character_id));
create policy "character_resources_read" on public.character_resources for select to authenticated using (public.can_access_character(character_id));
create policy "character_resource_events_read" on public.character_resource_events for select to authenticated
  using (public.can_access_character(character_id));

revoke all on public.subclass_versions, public.class_version_levels, public.subclass_version_levels, public.character_classes,
  public.character_spell_slot_state, public.character_temporary_spell_slots, public.character_resources, public.character_resource_events
  from anon, authenticated;
grant select on public.subclass_versions, public.class_version_levels, public.subclass_version_levels to anon, authenticated;
grant select on public.character_classes, public.character_spell_slot_state, public.character_temporary_spell_slots,
  public.character_resources, public.character_resource_events to authenticated;                 -- writes: RPCs only

revoke all on function public.character_classes_before_write(), public.character_classes_after_write(), public.characters_level_guard(),
  public.character_spellcasting_sources_before_delete(), public.character_class_rows_touch(), public.character_spells_class_rules()
  from public, anon, authenticated;
revoke all on function public._character_level_info(uuid), public._progression_slots(text, int), public._prepared_limit(jsonb, jsonb, int),
  public._class_progress(uuid, jsonb), public._character_mods(uuid), public._resource_max(jsonb, jsonb),
  public._character_resource_rows(uuid, jsonb), public._slot_change(uuid, text, int, int, text), public._rest(uuid, text, uuid),
  public.get_character_class_summary(uuid), public.get_character_spell_slots(uuid),
  public.set_character_class(uuid, text, int, text, boolean, uuid, text), public.remove_character_class(uuid, boolean),
  public.expend_standard_spell_slot(uuid, int, text), public.restore_standard_spell_slot(uuid, int, text),
  public.expend_pact_magic_slot(uuid, text), public.restore_pact_magic_slot(uuid, text),
  public.set_spell_slot_state(uuid, text, int, int, text), public.save_character_resource(uuid, jsonb),
  public.change_character_resource(uuid, int, text), public.delete_character_resource(uuid),
  public.short_rest_character(uuid, uuid), public.long_rest_character(uuid, uuid),
  public.get_character_derived_stats(uuid), public._derived_stats_core(uuid) from public, anon;
revoke all on function public._slot_change(uuid, text, int, int, text), public._rest(uuid, text, uuid) from authenticated;   -- wrappers only
grant execute on function public._character_level_info(uuid), public._progression_slots(text, int), public._prepared_limit(jsonb, jsonb, int),
  public._class_progress(uuid, jsonb), public._character_mods(uuid), public._resource_max(jsonb, jsonb),
  public._character_resource_rows(uuid, jsonb),
  public.get_character_class_summary(uuid), public.get_character_spell_slots(uuid),
  public.set_character_class(uuid, text, int, text, boolean, uuid, text), public.remove_character_class(uuid, boolean),
  public.expend_standard_spell_slot(uuid, int, text), public.restore_standard_spell_slot(uuid, int, text),
  public.expend_pact_magic_slot(uuid, text), public.restore_pact_magic_slot(uuid, text),
  public.set_spell_slot_state(uuid, text, int, int, text), public.save_character_resource(uuid, jsonb),
  public.change_character_resource(uuid, int, text), public.delete_character_resource(uuid),
  public.short_rest_character(uuid, uuid), public.long_rest_character(uuid, uuid),
  public.get_character_derived_stats(uuid), public._derived_stats_core(uuid) to authenticated;

do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    alter publication supabase_realtime add table public.character_classes, public.character_spell_slot_state,
      public.character_temporary_spell_slots, public.character_resources;
  end if;
end $$;
