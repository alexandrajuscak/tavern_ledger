-- =============================================================================
-- Spell catalog, minimal class foundation and character spellcasting (docs/SPELL_DATA_MODEL.md, docs/SPELLS.md).
-- Catalog rows come from supabase/seed/spells.sql (loaded before lineages.sql). The only rows this migration inserts are
-- its own lookups (spell schools). Nothing here casts spells, consumes slots or implements class progression.
-- =============================================================================

-- ---- lookups --------------------------------------------------------------------------------------------------
create table public.spell_schools (
  id          text primary key check (id ~ '^[a-z]+$'),
  name        text not null unique,
  description text not null default '',
  sort_order  int  not null default 0
);
insert into public.spell_schools (id, name, description, sort_order) values
  ('abjuration', 'Abjuration', 'Protective magic: barriers, wards, banishment.', 1),
  ('conjuration', 'Conjuration', 'Bringing creatures or objects, teleportation.', 2),
  ('divination', 'Divination', 'Revealing information.', 3),
  ('enchantment', 'Enchantment', 'Influencing minds.', 4),
  ('evocation', 'Evocation', 'Manipulating energy: damage and healing.', 5),
  ('illusion', 'Illusion', 'Deceiving the senses.', 6),
  ('necromancy', 'Necromancy', 'Life, death and undeath.', 7),
  ('transmutation', 'Transmutation', 'Changing properties of creatures or things.', 8)
on conflict (id) do nothing;

-- ---- canonical spells and their versions ------------------------------------------------------------------------
-- A canonical spell is the stable identity (and homebrew ownership); every published stat block is a version.
-- (named catalog_spells because public.spells is the existing per-character free-text table)
create table public.catalog_spells (
  id          text primary key check (id ~ '^[a-z0-9]+(-[a-z0-9]+)*$'),
  name        text not null,
  owner_id    uuid references public.profiles (id) on delete cascade,     -- null = official catalog row
  campaign_id uuid references public.campaigns (id) on delete set null,   -- homebrew shared with a campaign
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  constraint catalog_spell_campaign_needs_owner check (campaign_id is null or owner_id is not null)
);

create table public.spell_versions (
  id                       text primary key check (id ~ '^[a-z0-9]+(-[a-z0-9]+)*$'),
  spell_id                 text not null references public.catalog_spells (id) on delete cascade,
  name                     text not null,
  level                    int  not null check (level between 0 and 9),
  school_id                text not null references public.spell_schools (id),
  -- casting time
  casting_time_raw         text not null,
  casting_time_unit        text not null check (casting_time_unit in ('action', 'bonus_action', 'reaction', 'minute', 'hour', 'special')),
  casting_time_amount      numeric check (casting_time_amount > 0),
  reaction_trigger         text,
  -- range and area
  range_raw                text not null,
  range_type               text not null check (range_type in ('self', 'touch', 'sight', 'unlimited', 'distance', 'special')),
  range_distance           numeric check (range_distance > 0),
  range_unit               text check (range_unit in ('feet', 'miles')),
  area_shape               text check (area_shape in ('cone', 'cube', 'sphere', 'radius', 'line', 'cylinder', 'hemisphere', 'square', 'wall')),
  area_size                numeric check (area_size > 0),
  -- duration
  duration_raw             text not null,
  duration_type            text not null check (duration_type in ('instantaneous', 'timed', 'until_dispelled', 'permanent', 'special')),
  duration_amount          numeric check (duration_amount > 0),
  duration_unit            text check (duration_unit in ('round', 'minute', 'hour', 'day')),
  requires_concentration   boolean not null default false,
  is_ritual                boolean not null default false,
  -- components
  components_raw           text not null,
  has_verbal_component     boolean not null default false,
  has_somatic_component    boolean not null default false,
  has_material_component   boolean not null default false,
  material_text            text,
  material_cost_gp         numeric check (material_cost_gp > 0),
  material_consumed        boolean,
  components_parse_status  text not null default 'parsed' check (components_parse_status in ('parsed', 'uncertain')),
  -- mechanics summary (details in spell_effects)
  mechanism                text not null default 'none' check (mechanism in ('attack', 'save', 'automatic', 'check', 'multiple', 'none', 'unresolved')),
  attack_type              text check (attack_type in ('melee', 'ranged')),
  save_ability             text check (save_ability in ('str', 'dex', 'con', 'int', 'wis', 'cha')),
  has_higher_levels        boolean not null default false,
  automation               text not null check (automation in ('automated', 'partially_automated', 'informational', 'unresolved')),
  -- source and status
  source_book_id           text references public.source_books (id),
  source_label             text not null,
  source_url               text not null check (source_url ~ '^https://'),
  source_site              text not null default 'wikidot',
  status                   text not null default 'current' check (status in ('current', 'legacy')),
  rule_status              text not null default 'official' check (rule_status in ('official', 'playtest', 'homebrew')),
  source_marker            text check (source_marker in ('dunamancy', 'graviturgy', 'chronurgy', 'technomagic')),
  setting                  text,
  superseded_by_version_id text references public.spell_versions (id) on delete set null,
  parse_notes              text,
  created_at               timestamptz not null default now(),
  updated_at               timestamptz not null default now(),
  constraint spell_version_distance check ((range_type = 'distance') = (range_distance is not null)),
  constraint spell_version_material check (has_material_component or (material_text is null and material_cost_gp is null)),
  constraint spell_version_timed check (duration_type <> 'timed' or (duration_amount is not null and duration_unit is not null))
);
create index spell_versions_spell on public.spell_versions (spell_id);

create table public.spell_effects (
  version_id     text not null references public.spell_versions (id) on delete cascade,
  seq            int  not null check (seq > 0),
  category       text not null check (category in ('damage', 'healing', 'temp_hp', 'condition', 'movement', 'defense', 'summon',
                                                    'utility', 'information', 'control', 'other')),
  mechanism      text check (mechanism in ('attack', 'save', 'automatic')),
  timing         text not null default 'on_cast' check (timing in ('on_cast', 'on_hit', 'on_failed_save', 'ongoing', 'other')),
  dice           text check (dice ~ '^[1-9][0-9]*d[0-9]+$'),
  flat_modifier  int  not null default 0,
  adds_spell_mod boolean not null default false,
  damage_mode    text check (damage_mode in ('single', 'choice', 'simultaneous')),
  half_on_save   boolean,
  scaling_type   text not null default 'none' check (scaling_type in ('none', 'character_level', 'slot_level')),
  scaling_dice   text check (scaling_dice ~ '^[1-9][0-9]*d[0-9]+$'),
  scaling_base   int  check (scaling_base between 0 and 9),
  automation     text not null check (automation in ('automated', 'partially_automated', 'informational', 'unresolved')),
  notes          text,
  primary key (version_id, seq),
  constraint spell_effect_damage_mode check ((category = 'damage') = (damage_mode is not null))
);

create table public.spell_effect_damage_types (   -- one row per possible type of a damage effect
  version_id     text not null,
  seq            int  not null,
  damage_type_id text not null references public.damage_types (id),
  primary key (version_id, seq, damage_type_id),
  foreign key (version_id, seq) references public.spell_effects (version_id, seq) on delete cascade
);

create table public.spell_damage_type_links (     -- for filtering: can the spell deal this type, always or by choice?
  version_id     text not null references public.spell_versions (id) on delete cascade,
  damage_type_id text not null references public.damage_types (id),
  relation       text not null check (relation in ('always', 'choice')),
  primary key (version_id, damage_type_id)
);

-- ---- minimal class foundation ---------------------------------------------------------------------------------------
create table public.classes (
  id         text primary key check (id ~ '^[a-z]+(-[a-z]+)*$'),
  name       text not null unique,
  sort_order int  not null default 0
);

create table public.spell_slot_progressions (          -- future: full / half / third / pact progressions (not populated yet)
  id     text primary key check (id ~ '^[a-z0-9]+(-[a-z0-9]+)*$'),
  name   text not null,
  kind   text not null check (kind in ('full', 'half', 'third', 'pact', 'custom')),
  notes  text
);
create table public.spell_slot_progression_levels (
  progression_id text not null references public.spell_slot_progressions (id) on delete cascade,
  class_level    int  not null check (class_level between 1 and 20),
  slot_level     int  not null check (slot_level between 1 and 9),
  slots          int  not null check (slots between 0 and 9),
  primary key (progression_id, class_level, slot_level)
);

create table public.class_versions (
  id                       text primary key check (id ~ '^[a-z0-9]+(-[a-z0-9]+)*$'),
  class_id                 text not null references public.classes (id) on delete cascade,
  name                     text not null,
  source_book_id           text references public.source_books (id),
  source_label             text not null,
  source_url               text not null check (source_url ~ '^https://'),
  status                   text not null default 'current' check (status in ('current', 'legacy')),
  superseded_by_version_id text references public.class_versions (id) on delete set null,
  rules_edition            text not null default '2014',
  setting                  text,
  is_optional              boolean not null default false,
  spellcasting_ability     text check (spellcasting_ability in ('str', 'dex', 'con', 'int', 'wis', 'cha')),
  preparation_mode         text not null default 'none' check (preparation_mode in ('prepared', 'known', 'spellbook', 'none')),
  ritual_mode              text not null default 'none' check (ritual_mode in ('none', 'prepared', 'known', 'spellbook')),
  caster_type              text not null default 'none' check (caster_type in ('full', 'half', 'third', 'pact', 'none')),
  slot_progression_id      text references public.spell_slot_progressions (id),
  notes                    text
);

create table public.class_spell_lists (
  id               text primary key check (id ~ '^[a-z0-9]+(-[a-z0-9]+)*$'),
  class_version_id text references public.class_versions (id) on delete cascade,
  name             text not null,
  source_label     text not null,
  source_url       text not null check (source_url ~ '^https://'),
  notes            text
);
alter table public.class_versions add column spell_list_id text references public.class_spell_lists (id) on delete set null;

create table public.class_spell_list_entries (
  list_id          text not null references public.class_spell_lists (id) on delete cascade,
  spell_version_id text not null references public.spell_versions (id) on delete cascade,
  spell_level      int  not null check (spell_level between 0 and 9),
  is_optional      boolean not null default false,       -- e.g. an optional / expanded list feature
  provenance       text not null check (provenance in ('class_page', 'spell_page', 'both')),
  source_url       text not null,
  notes            text,
  primary key (list_id, spell_version_id)
);
create index class_spell_list_entries_version on public.class_spell_list_entries (spell_version_id);

-- ---- character spellcasting sources and spell grants -------------------------------------------------------------------
create table public.character_spellcasting_sources (
  id                      uuid primary key default gen_random_uuid(),
  character_id            uuid not null references public.characters (id) on delete cascade,
  source_type             text not null check (source_type in ('class', 'subclass', 'feat', 'item', 'manual', 'other')),
  label                   text not null check (length(label) between 1 and 80),
  class_version_id        text references public.class_versions (id),
  spell_list_id           text references public.class_spell_lists (id),
  casting_ability         text check (casting_ability in ('str', 'dex', 'con', 'int', 'wis', 'cha')),
  allowed_abilities       text[] not null default '{}',     -- abilities a spell grant of this source may choose instead
  fixed_dc                int  check (fixed_dc between 1 and 40),
  fixed_attack_bonus      int  check (fixed_attack_bonus between -5 and 20),
  dc_bonus                int  not null default 0 check (dc_bonus between -5 and 10),
  attack_bonus            int  not null default 0 check (attack_bonus between -5 and 10),
  preparation_mode        text not null default 'known' check (preparation_mode in ('prepared', 'known', 'spellbook', 'innate', 'none')),
  ritual_mode             text not null default 'none' check (ritual_mode in ('none', 'prepared', 'known', 'spellbook')),
  uses_spell_slots        boolean not null default true,
  class_level             int  check (class_level between 1 and 20),
  progression_id          text references public.spell_slot_progressions (id),
  enforce_spell_list      boolean not null default false,
  always_prepared_allowed boolean not null default false,
  is_preview              boolean not null default false,   -- "Class Foundation Preview": no class rules are enforced
  notes                   text check (length(notes) <= 500),
  created_by              uuid default auth.uid(),
  created_at              timestamptz not null default now(),
  updated_at              timestamptz not null default now(),
  unique (id, character_id)
);
create index character_spellcasting_sources_character on public.character_spellcasting_sources (character_id);

create table public.character_spells (
  id                            uuid primary key default gen_random_uuid(),
  character_id                  uuid not null,
  source_id                     uuid not null,
  spell_version_id              text not null references public.spell_versions (id),
  known                         boolean not null default true,
  prepared                      boolean not null default false,
  always_prepared               boolean not null default false,
  counts_against_known_limit    boolean not null default true,
  counts_against_prepared_limit boolean not null default true,
  uses_spell_slot               boolean not null default true,
  ritual_allowed                boolean not null default false,
  casting_ability               text check (casting_ability in ('str', 'dex', 'con', 'int', 'wis', 'cha')),
  notes                         text check (length(notes) <= 500),
  created_at                    timestamptz not null default now(),
  updated_at                    timestamptz not null default now(),
  foreign key (source_id, character_id) references public.character_spellcasting_sources (id, character_id) on delete cascade,
  unique (source_id, spell_version_id),
  constraint character_spell_has_access check (known or prepared or always_prepared)
);
create index character_spells_character on public.character_spells (character_id);

-- lineage spell grants reference the catalog (set by the lineage seed; the name/slug in the row stay for audit)
alter table public.lineage_trait_effects add column spell_version_id text references public.spell_versions (id) on delete set null;

-- ---- visibility of catalog rows (official, own homebrew, campaign homebrew) --------------------------------------------------
create function public.can_view_spell(p_spell text)
returns boolean
language sql stable security definer
set search_path = public, pg_temp
as $$
  select exists (
    select 1 from public.catalog_spells s
    where s.id = p_spell
      and (s.owner_id is null or s.owner_id = auth.uid() or public.is_admin()
           or (s.campaign_id is not null and exists (select 1 from public.campaign_members m
                                                      where m.campaign_id = s.campaign_id and m.user_id = auth.uid()))));
$$;

-- ---- integrity triggers -------------------------------------------------------------------------------------------
create function public.spell_rows_touch()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;
create trigger catalog_spells_touch before update on public.catalog_spells for each row execute function public.spell_rows_touch();
create trigger spell_versions_touch before update on public.spell_versions for each row execute function public.spell_rows_touch();
create trigger character_spells_touch before update on public.character_spells for each row execute function public.spell_rows_touch();

-- a class source takes its usual ability and spell list from the class version unless set explicitly
create function public.character_spellcasting_sources_before_write()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
declare cv public.class_versions;
begin
  if new.class_version_id is not null then
    select * into cv from public.class_versions where id = new.class_version_id;
    new.casting_ability := coalesce(new.casting_ability, cv.spellcasting_ability);
    new.spell_list_id := coalesce(new.spell_list_id, cv.spell_list_id);
  end if;
  if new.source_type = 'class' then new.is_preview := true; end if;    -- class rules are not implemented yet
  if exists (select 1 from unnest(new.allowed_abilities) a where a not in ('str', 'dex', 'con', 'int', 'wis', 'cha')) then
    raise exception 'Unknown ability in allowed_abilities' using errcode = '22023';
  end if;
  new.updated_at := now();
  return new;
end;
$$;
create trigger character_spellcasting_sources_before_write before insert or update on public.character_spellcasting_sources
  for each row execute function public.character_spellcasting_sources_before_write();

-- ---- calculation helpers -----------------------------------------------------------------------------------------------
-- Spell save DC and spell attack bonus for one casting ability (or fixed values), with a breakdown.
create function public._spell_stat(p_ability text, p_mods jsonb, p_pb int, p_fixed_dc int default null, p_fixed_attack int default null,
                                   p_dc_bonus int default 0, p_attack_bonus int default 0)
returns jsonb
language sql immutable
set search_path = public, pg_temp
as $$
  select jsonb_build_object(
    'ability', p_ability,
    'ability_modifier', (p_mods ->> p_ability)::int,
    'proficiency_bonus', p_pb,
    'fixed_dc', p_fixed_dc, 'fixed_attack_bonus', p_fixed_attack,
    'save_dc', case when p_fixed_dc is not null then p_fixed_dc
                    when p_ability is not null then 8 + p_pb + (p_mods ->> p_ability)::int + coalesce(p_dc_bonus, 0) end,
    'attack_bonus', case when p_fixed_attack is not null then p_fixed_attack
                         when p_ability is not null then p_pb + (p_mods ->> p_ability)::int + coalesce(p_attack_bonus, 0) end,
    'dc_breakdown', case when p_fixed_dc is not null then jsonb_build_array(jsonb_build_object('part', 'fixed', 'value', p_fixed_dc))
                         when p_ability is not null then jsonb_build_array(
                           jsonb_build_object('part', 'base', 'value', 8),
                           jsonb_build_object('part', 'proficiency_bonus', 'value', p_pb),
                           jsonb_build_object('part', 'ability_modifier', 'ability', p_ability, 'value', (p_mods ->> p_ability)::int))
                           || case when coalesce(p_dc_bonus, 0) <> 0 then jsonb_build_array(jsonb_build_object('part', 'bonus', 'value', p_dc_bonus)) else '[]'::jsonb end
                         else '[]'::jsonb end,
    'attack_breakdown', case when p_fixed_attack is not null then jsonb_build_array(jsonb_build_object('part', 'fixed', 'value', p_fixed_attack))
                             when p_ability is not null then jsonb_build_array(
                               jsonb_build_object('part', 'proficiency_bonus', 'value', p_pb),
                               jsonb_build_object('part', 'ability_modifier', 'ability', p_ability, 'value', (p_mods ->> p_ability)::int))
                               || case when coalesce(p_attack_bonus, 0) <> 0 then jsonb_build_array(jsonb_build_object('part', 'bonus', 'value', p_attack_bonus)) else '[]'::jsonb end
                             else '[]'::jsonb end);
$$;

-- Catalog data of one spell version (what a spell card needs; no rules prose is stored).
create function public._spell_summary(p_version text)
returns jsonb
language sql stable
set search_path = public, pg_temp
as $$
  select jsonb_build_object(
    'id', v.id, 'spell_id', v.spell_id, 'name', v.name, 'level', v.level, 'school_id', v.school_id, 'school', sc.name,
    'casting_time', v.casting_time_raw, 'casting_time_unit', v.casting_time_unit, 'casting_time_amount', v.casting_time_amount,
    'reaction_trigger', v.reaction_trigger, 'range', v.range_raw, 'range_type', v.range_type, 'range_distance', v.range_distance,
    'range_unit', v.range_unit, 'area_shape', v.area_shape, 'area_size', v.area_size,
    'duration', v.duration_raw, 'duration_type', v.duration_type, 'duration_amount', v.duration_amount, 'duration_unit', v.duration_unit,
    'concentration', v.requires_concentration, 'ritual', v.is_ritual,
    'components', v.components_raw, 'verbal', v.has_verbal_component, 'somatic', v.has_somatic_component,
    'material', v.has_material_component, 'material_text', v.material_text, 'material_cost_gp', v.material_cost_gp,
    'material_consumed', v.material_consumed, 'mechanism', v.mechanism, 'attack_type', v.attack_type, 'save_ability', v.save_ability,
    'has_higher_levels', v.has_higher_levels, 'automation', v.automation,
    'source_label', v.source_label, 'source_url', v.source_url, 'status', v.status, 'rule_status', v.rule_status,
    'source_marker', v.source_marker, 'setting', v.setting, 'superseded_by_version_id', v.superseded_by_version_id,
    'scope', case when s.owner_id is null then 'official' when s.campaign_id is not null then 'campaign' else 'private' end,
    'damage_types', (select coalesce(jsonb_agg(jsonb_build_object('id', l.damage_type_id, 'relation', l.relation) order by l.damage_type_id), '[]')
                     from public.spell_damage_type_links l where l.version_id = v.id),
    'effects', (select coalesce(jsonb_agg(jsonb_build_object(
                  'seq', e.seq, 'category', e.category, 'mechanism', e.mechanism, 'timing', e.timing, 'dice', e.dice,
                  'flat_modifier', e.flat_modifier, 'adds_spell_mod', e.adds_spell_mod, 'damage_mode', e.damage_mode, 'half_on_save', e.half_on_save,
                  'scaling_type', e.scaling_type, 'scaling_dice', e.scaling_dice, 'scaling_base', e.scaling_base, 'automation', e.automation,
                  'notes', e.notes,
                  'damage_types', (select coalesce(jsonb_agg(t.damage_type_id order by t.damage_type_id), '[]')
                                   from public.spell_effect_damage_types t where t.version_id = e.version_id and t.seq = e.seq))
                  order by e.seq), '[]') from public.spell_effects e where e.version_id = v.id),
    'class_lists', (select coalesce(jsonb_agg(jsonb_build_object('list_id', x.list_id, 'class_id', cv.class_id, 'class', cl.name,
                       'class_version_id', cv.id, 'optional', x.is_optional, 'provenance', x.provenance) order by cl.sort_order, x.list_id), '[]')
                    from public.class_spell_list_entries x join public.class_spell_lists sl on sl.id = x.list_id
                    left join public.class_versions cv on cv.id = sl.class_version_id left join public.classes cl on cl.id = cv.class_id
                    where x.spell_version_id = v.id))
  from public.spell_versions v join public.catalog_spells s on s.id = v.spell_id join public.spell_schools sc on sc.id = v.school_id
  where v.id = p_version;
$$;

create function public.get_spell_detail(p_version text)
returns jsonb
language sql stable
set search_path = public, pg_temp
as $$ select public._spell_summary(p_version) $$;

-- Every spell grant of a character: stored grants (class/subclass/feat/item/manual/other sources) and catalog-linked
-- lineage grants, each with its source key, flags and the DC / attack bonus of its casting ability.
create function public._character_spell_grants(p_character uuid, mods jsonb, pb int, lin_name text)
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
  where e.effect_type = 'spell' and te.spell_version_id is not null;
$$;

-- ---- the resolved spellbook --------------------------------------------------------------------------------------------
-- All sources (stored class/subclass/feat/item/manual sources + lineage grants), all spells merged per spell version with
-- every grant kept, per-source Spell Save DC and Spell Attack Bonus, free-text spells, slots. Read only; RLS applies.
create function public.get_character_spellbook(p_character uuid)
returns jsonb
language plpgsql stable
set search_path = public, pg_temp
as $$
declare lvl int; d jsonb; pb int; mods jsonb; lin_name text; sources jsonb; spells jsonb; unresolved jsonb; free_text jsonb;
  manual_slots jsonb; prog jsonb;
begin
  select level into lvl from public.characters where id = p_character;                 -- RLS: owner, campaign DM, admin
  if not found then raise exception 'Character not found' using errcode = '42501'; end if;
  d := public.get_character_derived_stats(p_character);
  pb := (d -> 'proficiency_bonus' ->> 'value')::int;
  select jsonb_object_agg(k, (d -> 'abilities' -> k ->> 'modifier')::int) into mods from jsonb_object_keys(d -> 'abilities') k;
  lin_name := d -> 'lineage' ->> 'name';

  -- lineage grants whose spell is not in the catalog (kept visible, never dropped)
  select coalesce(jsonb_agg(jsonb_build_object('source_type', 'lineage', 'name', e.value_text, 'slug', e.data ->> 'slug',
           'trait_id', e.trait_id, 'min_level', e.min_level, 'unlocked', e.active) order by e.value_text), '[]')
  into unresolved
  from public._lineage_effects(p_character) e
  join public.lineage_trait_effects te on te.trait_id = e.trait_id and te.seq = e.seq
  where e.effect_type = 'spell' and te.spell_version_id is null;

  -- sources with their statistics and counters
  select coalesce(jsonb_agg(x.src order by x.ord, x.label), '[]') into sources from (
    select 1 as ord, s.label, jsonb_build_object(
             'key', s.id::text, 'id', s.id, 'source_type', s.source_type, 'label', s.label, 'is_preview', s.is_preview,
             'class_version_id', s.class_version_id, 'class_version_name', cv.name, 'spell_list_id', s.spell_list_id,
             'preparation_mode', s.preparation_mode, 'ritual_mode', s.ritual_mode, 'uses_spell_slots', s.uses_spell_slots,
             'class_level', s.class_level, 'progression_id', s.progression_id, 'enforce_spell_list', s.enforce_spell_list,
             'always_prepared_allowed', s.always_prepared_allowed, 'allowed_abilities', to_jsonb(s.allowed_abilities),
             'casting_ability', s.casting_ability, 'dc_bonus', s.dc_bonus, 'attack_bonus', s.attack_bonus, 'notes', s.notes,
             'stats', public._spell_stat(s.casting_ability, mods, pb, s.fixed_dc, s.fixed_attack_bonus, s.dc_bonus, s.attack_bonus),
             'counts', jsonb_build_object(
               'known', (select count(*) from public.character_spells g where g.source_id = s.id and g.known and g.counts_against_known_limit),
               'prepared', (select count(*) from public.character_spells g where g.source_id = s.id and g.prepared and not g.always_prepared
                                                                               and g.counts_against_prepared_limit),
               'always_prepared', (select count(*) from public.character_spells g where g.source_id = s.id and g.always_prepared),
               'total', (select count(*) from public.character_spells g where g.source_id = s.id))) as src
    from public.character_spellcasting_sources s left join public.class_versions cv on cv.id = s.class_version_id
    where s.character_id = p_character
    union all
    select 2, g.source_key, jsonb_build_object(
             'key', g.source_key, 'id', null, 'source_type', 'lineage', 'label', coalesce(lin_name, 'Lineage') || ' (lineage)',
             'casting_ability', min(g.grant_info ->> 'casting_ability'), 'preparation_mode', 'innate', 'uses_spell_slots', false,
             'stats', public._spell_stat(min(g.grant_info ->> 'casting_ability'), mods, pb),
             'counts', jsonb_build_object('known', count(*), 'prepared', 0, 'always_prepared', 0, 'total', count(*)))
    from public._character_spell_grants(p_character, mods, pb, lin_name) g where g.source_key like 'lineage:%' group by g.source_key) x;

  -- spells merged per version; every grant kept
  select coalesce(jsonb_agg(sp order by (sp ->> 'level')::int, sp ->> 'name', sp ->> 'id'), '[]') into spells from (
    select public._spell_summary(g.spell_version_id) || jsonb_build_object(
             'grants', jsonb_agg(g.grant_info order by g.grant_info ->> 'source_type', g.source_key),
             'source_count', count(distinct g.source_key),
             'known', bool_or((g.grant_info ->> 'known')::boolean),
             'prepared', bool_or((g.grant_info ->> 'prepared')::boolean),
             'always_prepared', bool_or((g.grant_info ->> 'always_prepared')::boolean),
             'innate', bool_or((g.grant_info ->> 'innate')::boolean),
             'unlocked', bool_or((g.grant_info ->> 'unlocked')::boolean),
             'ritual_castable', bool_or((g.grant_info ->> 'ritual_allowed')::boolean)) as sp
    from public._character_spell_grants(p_character, mods, pb, lin_name) g group by g.spell_version_id) t;

  select coalesce(jsonb_agg(jsonb_build_object('id', s.id, 'name', s.name, 'level', s.level, 'school', s.school, 'source', s.source,
           'prepared', s.prepared, 'catalog_match', (select v.id from public.spell_versions v join public.catalog_spells c on c.id = v.spell_id
                                                     where lower(v.name) = lower(btrim(s.name)) and c.owner_id is null
                                                     order by v.status, v.rule_status, v.id limit 1))
           order by s.level, s.name), '[]')
  into free_text from public.spells s where s.character_id = p_character;

  select coalesce(jsonb_agg(jsonb_build_object('level', sl.level, 'total', sl.total, 'used', sl.used) order by sl.level), '[]')
  into manual_slots from public.spell_slots sl where sl.character_id = p_character and sl.total > 0;

  select jsonb_build_object('source_key', s.id::text, 'progression_id', s.progression_id, 'class_level', s.class_level,
           'slots', (select coalesce(jsonb_agg(jsonb_build_object('level', l.slot_level, 'total', l.slots) order by l.slot_level), '[]')
                     from public.spell_slot_progression_levels l
                     where l.progression_id = s.progression_id and l.class_level = s.class_level and l.slots > 0))
  into prog
  from public.character_spellcasting_sources s
  where s.character_id = p_character and s.progression_id is not null and s.class_level is not null
  order by s.created_at limit 1;

  return jsonb_build_object(
    'character_id', p_character, 'level', lvl, 'proficiency_bonus', pb,
    'sources', sources, 'spells', spells, 'unresolved_grants', unresolved, 'free_text_spells', free_text,
    'slots', jsonb_build_object('manual', manual_slots, 'progression', prog,
                                'note', 'Slots are shown, not consumed; class progressions are not populated yet.'));
end;
$$;

-- ---- write path (the only one) ---------------------------------------------------------------------------------------
create function public.save_character_spellcasting_source(p_character uuid, p_source jsonb)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare v_id uuid; r public.character_spellcasting_sources; k text;
  allowed constant text[] := array['id', 'source_type', 'label', 'class_version_id', 'spell_list_id', 'casting_ability', 'allowed_abilities',
    'fixed_dc', 'fixed_attack_bonus', 'dc_bonus', 'attack_bonus', 'preparation_mode', 'ritual_mode', 'uses_spell_slots', 'class_level',
    'progression_id', 'enforce_spell_list', 'always_prepared_allowed', 'notes'];
begin
  if auth.uid() is null or not public.can_access_character(p_character) then
    raise exception 'Character not found' using errcode = '42501';
  end if;
  if jsonb_typeof(p_source) <> 'object' then raise exception 'The source must be an object' using errcode = '22023'; end if;
  for k in select jsonb_object_keys(p_source) loop
    if not k = any (allowed) then raise exception 'Field "%" cannot be set on a spellcasting source', k using errcode = '22023'; end if;
  end loop;
  if coalesce(p_source ->> 'source_type', '') not in ('class', 'subclass', 'feat', 'item', 'manual', 'other') then
    raise exception 'Unknown source type "%"', p_source ->> 'source_type' using errcode = '22023';
  end if;
  if coalesce(btrim(p_source ->> 'label'), '') = '' then raise exception 'Give the source a name' using errcode = '22023'; end if;
  if p_source ? 'class_version_id' and p_source ->> 'class_version_id' is not null
     and not exists (select 1 from public.class_versions where id = p_source ->> 'class_version_id') then
    raise exception 'Unknown class version "%"', p_source ->> 'class_version_id' using errcode = '22023';
  end if;
  if p_source ->> 'spell_list_id' is not null and not exists (select 1 from public.class_spell_lists where id = p_source ->> 'spell_list_id') then
    raise exception 'Unknown spell list "%"', p_source ->> 'spell_list_id' using errcode = '22023';
  end if;
  if p_source ->> 'progression_id' is not null and not exists (select 1 from public.spell_slot_progressions where id = p_source ->> 'progression_id') then
    raise exception 'Unknown slot progression "%"', p_source ->> 'progression_id' using errcode = '22023';
  end if;
  v_id := nullif(p_source ->> 'id', '')::uuid;
  if v_id is not null and not exists (select 1 from public.character_spellcasting_sources where id = v_id and character_id = p_character) then
    raise exception 'Spellcasting source not found' using errcode = '42501';
  end if;
  begin
    if v_id is null then
      insert into public.character_spellcasting_sources (character_id, source_type, label, created_by) values
        (p_character, p_source ->> 'source_type', btrim(p_source ->> 'label'), auth.uid()) returning id into v_id;
    end if;
    update public.character_spellcasting_sources set
      source_type = p_source ->> 'source_type', label = btrim(p_source ->> 'label'),
      class_version_id = p_source ->> 'class_version_id', spell_list_id = p_source ->> 'spell_list_id',
      casting_ability = p_source ->> 'casting_ability',
      allowed_abilities = coalesce((select array_agg(x) from jsonb_array_elements_text(p_source -> 'allowed_abilities') x), '{}'),
      fixed_dc = (p_source ->> 'fixed_dc')::int, fixed_attack_bonus = (p_source ->> 'fixed_attack_bonus')::int,
      dc_bonus = coalesce((p_source ->> 'dc_bonus')::int, 0), attack_bonus = coalesce((p_source ->> 'attack_bonus')::int, 0),
      preparation_mode = coalesce(p_source ->> 'preparation_mode', (select preparation_mode from public.class_versions
                                                                     where id = p_source ->> 'class_version_id'), 'known'),
      ritual_mode = coalesce(p_source ->> 'ritual_mode', (select ritual_mode from public.class_versions
                                                         where id = p_source ->> 'class_version_id'), 'none'),
      uses_spell_slots = coalesce((p_source ->> 'uses_spell_slots')::boolean, true), class_level = (p_source ->> 'class_level')::int,
      progression_id = p_source ->> 'progression_id', enforce_spell_list = coalesce((p_source ->> 'enforce_spell_list')::boolean, false),
      always_prepared_allowed = coalesce((p_source ->> 'always_prepared_allowed')::boolean, false), notes = nullif(btrim(p_source ->> 'notes'), '')
    where id = v_id
    returning * into r;
  exception
    when check_violation or invalid_text_representation or numeric_value_out_of_range then
      raise exception 'Invalid spellcasting source: %', sqlerrm using errcode = '22023';
  end;
  return to_jsonb(r) - 'created_by';
end;
$$;

create function public.delete_character_spellcasting_source(p_source uuid)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare cid uuid;
begin
  select character_id into cid from public.character_spellcasting_sources where id = p_source;
  if auth.uid() is null or cid is null or not public.can_access_character(cid) then
    raise exception 'Spellcasting source not found' using errcode = '42501';
  end if;
  delete from public.character_spellcasting_sources where id = p_source;   -- its spell grants go with it
  return jsonb_build_object('deleted', true, 'id', p_source);
end;
$$;

create function public.set_character_spell(p_character uuid, p_source uuid, p_spell_version text, p_known boolean default true,
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

create function public.set_character_spell_prepared(p_character_spell uuid, p_prepared boolean)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare r public.character_spells;
begin
  select * into r from public.character_spells where id = p_character_spell;
  if auth.uid() is null or r.id is null or not public.can_access_character(r.character_id) then
    raise exception 'Spell not found' using errcode = '42501';
  end if;
  if not coalesce(p_prepared, false) and not r.known and not r.always_prepared then
    raise exception 'This spell is only prepared; remove it instead' using errcode = '22023';
  end if;
  update public.character_spells set prepared = coalesce(p_prepared, false) where id = p_character_spell returning * into r;
  return to_jsonb(r);
end;
$$;

create function public.remove_character_spell(p_character_spell uuid)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare cid uuid;
begin
  select character_id into cid from public.character_spells where id = p_character_spell;
  if auth.uid() is null or cid is null or not public.can_access_character(cid) then
    raise exception 'Spell not found' using errcode = '42501';
  end if;
  delete from public.character_spells where id = p_character_spell;
  return jsonb_build_object('deleted', true, 'id', p_character_spell);
end;
$$;

-- ---- catalog read model -----------------------------------------------------------------------------------------------
create view public.v_spell_catalog with (security_invoker = true) as
select v.id, v.spell_id, v.name, v.level, v.school_id, sc.name as school, v.casting_time_raw as casting_time, v.casting_time_unit,
       v.range_raw as range, v.range_type, v.duration_raw as duration, v.duration_type, v.requires_concentration as concentration,
       v.is_ritual as ritual, v.has_verbal_component as verbal, v.has_somatic_component as somatic, v.has_material_component as material,
       v.material_cost_gp, v.material_consumed, v.mechanism, v.save_ability, v.attack_type, v.automation, v.source_label, v.source_book_id,
       v.status, v.rule_status, v.source_marker, v.setting,
       case when s.owner_id is null then 'official' when s.campaign_id is not null then 'campaign' else 'private' end as scope,
       coalesce((select array_agg(l.damage_type_id order by l.damage_type_id) from public.spell_damage_type_links l where l.version_id = v.id), '{}') as damage_types,
       exists (select 1 from public.spell_damage_type_links l where l.version_id = v.id and l.relation = 'choice') as damage_choice,
       coalesce((select array_agg(e.list_id order by e.list_id) from public.class_spell_list_entries e where e.spell_version_id = v.id), '{}') as class_lists,
       lower(v.name) as search_text
from public.spell_versions v join public.catalog_spells s on s.id = v.spell_id join public.spell_schools sc on sc.id = v.school_id;

-- ---- RLS, grants, Realtime --------------------------------------------------------------------------------------------
alter table public.spell_schools enable row level security;
alter table public.catalog_spells enable row level security;
alter table public.spell_versions enable row level security;
alter table public.spell_effects enable row level security;
alter table public.spell_effect_damage_types enable row level security;
alter table public.spell_damage_type_links enable row level security;
alter table public.classes enable row level security;
alter table public.class_versions enable row level security;
alter table public.class_spell_lists enable row level security;
alter table public.class_spell_list_entries enable row level security;
alter table public.spell_slot_progressions enable row level security;
alter table public.spell_slot_progression_levels enable row level security;
alter table public.character_spellcasting_sources enable row level security;
alter table public.character_spells enable row level security;

create policy "spell_schools_read" on public.spell_schools for select to anon, authenticated using (true);
create policy "catalog_spells_read" on public.catalog_spells for select to anon, authenticated using (public.can_view_spell(id));
create policy "spell_versions_read" on public.spell_versions for select to anon, authenticated using (public.can_view_spell(spell_id));
create policy "spell_effects_read" on public.spell_effects for select to anon, authenticated
  using (exists (select 1 from public.spell_versions v where v.id = version_id and public.can_view_spell(v.spell_id)));
create policy "spell_effect_damage_types_read" on public.spell_effect_damage_types for select to anon, authenticated
  using (exists (select 1 from public.spell_versions v where v.id = version_id and public.can_view_spell(v.spell_id)));
create policy "spell_damage_type_links_read" on public.spell_damage_type_links for select to anon, authenticated
  using (exists (select 1 from public.spell_versions v where v.id = version_id and public.can_view_spell(v.spell_id)));
create policy "classes_read" on public.classes for select to anon, authenticated using (true);
create policy "class_versions_read" on public.class_versions for select to anon, authenticated using (true);
create policy "class_spell_lists_read" on public.class_spell_lists for select to anon, authenticated using (true);
create policy "class_spell_list_entries_read" on public.class_spell_list_entries for select to anon, authenticated using (true);
create policy "spell_slot_progressions_read" on public.spell_slot_progressions for select to anon, authenticated using (true);
create policy "spell_slot_progression_levels_read" on public.spell_slot_progression_levels for select to anon, authenticated using (true);
create policy "character_spellcasting_sources_read" on public.character_spellcasting_sources for select to authenticated
  using (public.can_access_character(character_id));
create policy "character_spells_read" on public.character_spells for select to authenticated
  using (public.can_access_character(character_id));

revoke all on public.spell_schools, public.catalog_spells, public.spell_versions, public.spell_effects, public.spell_effect_damage_types,
  public.spell_damage_type_links, public.classes, public.class_versions, public.class_spell_lists, public.class_spell_list_entries,
  public.spell_slot_progressions, public.spell_slot_progression_levels, public.character_spellcasting_sources, public.character_spells,
  public.v_spell_catalog from anon, authenticated;
grant select on public.spell_schools, public.catalog_spells, public.spell_versions, public.spell_effects, public.spell_effect_damage_types,
  public.spell_damage_type_links, public.classes, public.class_versions, public.class_spell_lists, public.class_spell_list_entries,
  public.spell_slot_progressions, public.spell_slot_progression_levels, public.v_spell_catalog to anon, authenticated;
grant select on public.character_spellcasting_sources, public.character_spells to authenticated;     -- writes: RPCs only

revoke all on function public.spell_rows_touch(), public.character_spellcasting_sources_before_write() from public, anon, authenticated;
revoke all on function public.can_view_spell(text), public._spell_stat(text, jsonb, int, int, int, int, int), public._spell_summary(text),
  public.get_spell_detail(text), public.get_character_spellbook(uuid), public._character_spell_grants(uuid, jsonb, int, text), public.save_character_spellcasting_source(uuid, jsonb),
  public.delete_character_spellcasting_source(uuid),
  public.set_character_spell(uuid, uuid, text, boolean, boolean, boolean, text, boolean, text),
  public.set_character_spell_prepared(uuid, boolean), public.remove_character_spell(uuid) from public, anon;
grant execute on function public.can_view_spell(text), public._spell_stat(text, jsonb, int, int, int, int, int), public._spell_summary(text),
  public.get_spell_detail(text) to anon, authenticated;
grant execute on function public.get_character_spellbook(uuid), public._character_spell_grants(uuid, jsonb, int, text), public.save_character_spellcasting_source(uuid, jsonb),
  public.delete_character_spellcasting_source(uuid),
  public.set_character_spell(uuid, uuid, text, boolean, boolean, boolean, text, boolean, text),
  public.set_character_spell_prepared(uuid, boolean), public.remove_character_spell(uuid) to authenticated;

do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    alter publication supabase_realtime add table public.character_spellcasting_sources, public.character_spells;
  end if;
end $$;
