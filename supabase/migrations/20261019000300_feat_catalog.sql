-- =============================================================================
-- Versioned feat catalog and feat engine (docs/FEATS.md, FEAT_DATA_MODEL.md, FEAT_COVERAGE.md).
--
-- feats (canonical: "alert") -> feat_versions (one ruleset / source each: "alert-2014", "alert-2024"; never merged) ->
-- prerequisites, choices (+ options), effects, spell grants, resource grants, attack grants.
-- The old public.feats table of 20261017001200 held version rows; it is renamed to feat_versions (ids unchanged, so the
-- background Origin feat links keep working) and a new canonical public.feats is created.
--
-- A character gets a feat from a GRANT, identified by a grant key:
--   cf:<character_feats.id>                          direct (DM grant, campaign reward, approved request, import)
--   bg:<background version>                          the Origin feat of the selected background version
--   lin:<lineage choice>:<pick>                      a lineage feat choice (Variant Human, Custom Lineage) value feat:<version>
--   asi:<class row>:<unlock>:<choice>                an Ability Score Improvement choice value feat:<version>
-- Only the grant and the character's choices are stored. Effects are resolved on read (_character_feat_effects has the row
-- shape of _character_class_effects, so the derived stats, proficiencies, attacks and senses take feats like features).
-- Resources and spells are materialized into character_resources / character_spellcasting_sources by
-- _sync_character_feats (triggers on every grant source), so expending, rests and the spellbook work unchanged.
-- Removing a grant removes only what that grant gave; the same feat or spell from another source stays.
-- Rollback: supabase/rollback/rollback_feat_catalog.sql.
-- =============================================================================

-- ---- catalog -------------------------------------------------------------------------------------------------------------
alter table public.feats rename to feat_versions;
alter index public.feats_pkey rename to feat_versions_pkey;
alter policy "feats_read" on public.feat_versions rename to "feat_versions_read";
alter table public.feat_versions drop constraint feats_category_check, drop constraint feats_ruleset_check,
  drop constraint feats_status_check, drop constraint feats_summary_check;
alter table public.feat_versions rename constraint feats_id_check to feat_versions_id_check;
alter table public.feat_versions rename constraint feats_name_check to feat_versions_name_check;
alter table public.feat_versions rename constraint feats_automation_check to feat_versions_automation_check;

create table public.feats (
  id          text primary key check (id ~ '^[a-z][a-z0-9-]{1,60}$'),
  name        text not null check (length(name) between 1 and 80),
  owner_id    uuid references public.profiles (id) on delete restrict,   -- custom feats: the authoring DM
  campaign_id uuid references public.campaigns (id) on delete cascade,  -- custom feats: the campaign it is published to
  created_at  timestamptz not null default now(),
  check (owner_id is not null or campaign_id is null)
);
insert into public.feats (id, name)
select distinct on (regexp_replace(id, '-(2014|2024|ua)$', '')) regexp_replace(id, '-(2014|2024|ua)$', ''), name
from public.feat_versions order by regexp_replace(id, '-(2014|2024|ua)$', ''), id;

alter table public.feat_versions
  add column feat_id text references public.feats (id) on delete cascade,
  add column source_book_id text references public.source_books (id),
  add column source_label text,
  add column setting text,
  add column legacy boolean not null default false,
  add column min_level int check (min_level between 1 and 20),
  add column repeatable text not null default 'once' check (repeatable in ('once', 'repeatable', 'repeatable_distinct')),
  add column max_count int check (max_count between 1 and 20),
  add column distinct_choice_key text,
  add column prerequisite_text text check (length(prerequisite_text) <= 300),
  add column tags text[] not null default '{}',
  add column benefits text[] not null default '{}',
  add column replacement_version_id text references public.feat_versions (id) on delete set null,
  add column owner_id uuid references public.profiles (id) on delete restrict,
  add column campaign_id uuid references public.campaigns (id) on delete cascade,
  add column archived_at timestamptz,
  add column sort_order int not null default 0,
  add constraint feat_versions_category_check check (category in ('origin', 'general', 'fighting_style', 'epic_boon', 'other')),
  add constraint feat_versions_ruleset_check check (ruleset in ('2014', '2024', 'ua-2022')),
  add constraint feat_versions_status_check check (status in ('official', 'playtest', 'third_party', 'unverified', 'homebrew')),
  add constraint feat_versions_summary_check check (length(summary) <= 400),
  add constraint feat_versions_custom_owner check ((status = 'homebrew') = (owner_id is not null));
update public.feat_versions set feat_id = regexp_replace(id, '-(2014|2024|ua)$', '');
alter table public.feat_versions alter column feat_id set not null;
create index feat_versions_feat on public.feat_versions (feat_id);
create index feat_versions_campaign on public.feat_versions (campaign_id) where campaign_id is not null;

-- prerequisites: rows of one group are alternatives (OR), groups are all required (AND)
create table public.feat_prerequisites (
  version_id text not null references public.feat_versions (id) on delete cascade,
  seq        int not null,
  grp        int not null default 1,
  kind       text not null check (kind in ('character_level', 'class_level', 'class', 'subclass', 'ability', 'armor_proficiency',
                                           'weapon_proficiency', 'skill_proficiency', 'spellcasting', 'pact_magic', 'known_spell',
                                           'feat', 'background', 'lineage', 'size', 'feature', 'campaign_permission', 'text')),
  target     text,
  value      text,
  label      text not null check (length(label) between 1 and 200),
  primary key (version_id, seq)
);

create table public.feat_choices (
  id                text primary key,                 -- <version>:<key>
  version_id        text not null references public.feat_versions (id) on delete cascade,
  key               text not null check (key ~ '^[a-z][a-z0-9_]{0,30}$'),
  kind              text not null check (kind in ('ability_increase', 'asi_points', 'ability', 'skill', 'expertise', 'tool',
                                                  'skill_or_tool', 'language', 'spellcasting_ability', 'spell_list', 'spell',
                                                  'damage_type', 'weapon', 'option', 'free_text')),
  label             text not null,
  min_picks         int not null default 1 check (min_picks >= 0),
  max_picks         int not null default 1 check (max_picks >= 1),
  config            jsonb not null default '{}' check (jsonb_typeof(config) = 'object'),
  parent_choice_key text,
  parent_option_id  text,
  seq               int not null default 0,
  unique (version_id, key),
  check (min_picks <= max_picks)
);

create table public.feat_choice_options (
  choice_id text not null references public.feat_choices (id) on delete cascade,
  option_id text not null check (option_id ~ '^[a-z0-9][a-z0-9_-]{0,60}$'),
  label     text not null,
  summary   text,
  data      jsonb not null default '{}',
  seq       int not null default 0,
  primary key (choice_id, option_id)
);

create table public.feat_effects (
  version_id   text not null references public.feat_versions (id) on delete cascade,
  seq          int not null,
  effect_type  text not null check (effect_type ~ '^[a-z_]+$'),
  target       text,
  value        numeric,
  value_text   text,
  choice_key   text,              -- one effect row per value chosen in this choice (proficiency in the chosen skill ...)
  option_choice_key text,         -- only while this option is chosen ...
  option_id    text,              -- ... in that choice
  activation   text not null default 'passive' check (activation in ('passive', 'active', 'contextual')),
  automation   text not null default 'automated' check (automation in ('automated', 'partially_automated', 'informational')),
  conditions   jsonb not null default '{}',
  data         jsonb not null default '{}',
  label        text,
  primary key (version_id, seq)
);

create table public.feat_spell_grants (
  version_id          text not null references public.feat_versions (id) on delete cascade,
  seq                 int not null,
  spell_version_id    text references public.spell_versions (id),
  choice_key          text,             -- the spells chosen in this choice
  mode                text not null check (mode in ('known', 'innate', 'always_prepared')),
  ability             text check (ability in ('str', 'dex', 'con', 'int', 'wis', 'cha')),
  ability_choice_key  text,             -- the ability chosen in this choice (spellcasting_ability / ability_increase)
  ability_from_option text,             -- the data.ability of the option chosen in this choice (Magic Initiate 2014 class)
  uses                text not null default 'at_will' check (uses in ('at_will', 'long_rest_1', 'pb_long_rest')),
  uses_slots          boolean not null default false,
  label               text not null,
  primary key (version_id, seq),
  check (spell_version_id is not null or choice_key is not null)
);

create table public.feat_resource_grants (
  version_id  text not null references public.feat_versions (id) on delete cascade,
  key         text not null check (key ~ '^[a-z0-9]+(-[a-z0-9]+)*$'),
  name        text not null check (length(name) between 1 and 60),
  max_formula jsonb not null check (jsonb_typeof(max_formula) = 'object'),
  recharge    text not null default 'long_rest' check (recharge in ('short_rest', 'long_rest', 'short_or_long_rest', 'dawn', 'manual')),
  notes       text,
  primary key (version_id, key)
);

create table public.feat_attack_grants (
  version_id  text not null references public.feat_versions (id) on delete cascade,
  key         text not null,
  data        jsonb not null check (data ? 'name'),
  primary key (version_id, key)
);

-- ---- character data --------------------------------------------------------------------------------------------------------
create table public.character_feats (
  id                    uuid primary key default gen_random_uuid(),
  character_id          uuid not null references public.characters (id) on delete cascade,
  feat_version_id       text not null references public.feat_versions (id),
  source_type           text not null default 'direct'
                          check (source_type in ('direct', 'dm_grant', 'campaign_reward', 'approved_request', 'import')),
  source_note           text check (length(source_note) <= 300),
  notes                 text check (length(notes) <= 1000),
  prerequisite_override boolean not null default false,
  override_reason       text check (length(override_reason) <= 500),
  override_by           uuid references public.profiles (id) on delete set null,
  granted_by            uuid references public.profiles (id) on delete set null default auth.uid(),
  created_at            timestamptz not null default now(),
  check (not prerequisite_override or override_reason is not null)
);
create index character_feats_character on public.character_feats (character_id);

create table public.character_feat_choices (
  character_id uuid not null references public.characters (id) on delete cascade,
  grant_key    text not null check (length(grant_key) <= 200),
  choice_id    text not null references public.feat_choices (id) on delete cascade,
  pick         int not null check (pick between 1 and 20),
  value        text not null check (length(value) between 1 and 200),
  primary key (character_id, grant_key, choice_id, pick)
);

alter table public.character_spellcasting_sources add column feat_grant_key text;
create unique index character_spellcasting_sources_feat on public.character_spellcasting_sources (character_id, feat_grant_key)
  where feat_grant_key is not null;

-- ---- grants -----------------------------------------------------------------------------------------------------------------
create function public._character_feat_grants(p_character uuid)
returns table (grant_key text, source_type text, source_label text, feat_version_id text, character_feat_id uuid, parameter text,
               active boolean, inactive_reason text, ord int)
language sql stable security definer
set search_path = public, pg_temp
as $$
  select 'cf:' || cf.id, cf.source_type,
         case cf.source_type when 'dm_grant' then 'DM grant' when 'campaign_reward' then 'Campaign reward'
                             when 'approved_request' then 'Approved request' when 'import' then 'Imported' else 'Feat' end
           || coalesce(' (' || cf.source_note || ')', ''),
         cf.feat_version_id, cf.id, null::text, true, null::text, 40
  from public.character_feats cf where cf.character_id = p_character
  union all
  select 'bg:' || b.version_id, 'background', 'Background: ' || coalesce(bk.name, v.name), g.feat_id, null, g.parameter, true, null, 10
  from public.character_backgrounds b
  join public.background_versions v on v.id = b.version_id
  left join public.backgrounds bk on bk.id = v.background_id
  join public.background_feat_grants g on g.version_id = b.version_id
  where b.character_id = p_character
  union all
  select 'lin:' || lc.choice_id || ':' || lc.pick, 'lineage', 'Lineage: ' || coalesce(lv.name, c.label),
         substr(lc.value, 6), null, null,
         exists (select 1 from public.character_lineages cl where cl.character_id = p_character
                 and (cl.version_id = c.version_id or cl.subversion_id = c.version_id)),
         case when not exists (select 1 from public.character_lineages cl where cl.character_id = p_character
                               and (cl.version_id = c.version_id or cl.subversion_id = c.version_id)) then 'lineage_changed' end, 20
  from public.character_lineage_choices lc
  join public.lineage_choices c on c.id = lc.choice_id and c.kind = 'feat'
  left join public.lineage_versions lv on lv.id = c.version_id
  where lc.character_id = p_character and lc.value like 'feat:%'
    and exists (select 1 from public.feat_versions fv where fv.id = substr(lc.value, 6))
  union all
  select 'asi:' || ch.character_class_id || ':' || ch.unlock_id || ':' || ch.choice_id, 'class',
         coalesce(u.class_name || ': ', '') || coalesce(u.feature_name, 'Ability Score Improvement') || coalesce(' (level ' || u.unlock_level || ')', ''),
         substr(v.value, 6), null, null, coalesce(u.active, false),
         case when not coalesce(u.active, false) then 'feature_inactive' end, 30
  from public.character_feature_choices ch
  join public.class_feature_choices fc on fc.id = ch.choice_id and fc.kind = 'asi'
  join public.character_feature_choice_values v on v.character_choice_id = ch.id and v.value like 'feat:%'
  left join lateral (select x.class_name, x.feature_name, x.unlock_level, x.active from public._character_feature_unlocks(p_character) x
                     where x.character_class_id = ch.character_class_id and x.unlock_id = ch.unlock_id limit 1) u on true
  where ch.character_id = p_character and exists (select 1 from public.feat_versions fv where fv.id = substr(v.value, 6));
$$;

-- ASI / lineage feat values that name no catalog version (the old "feat:<name>" placeholders)
create function public._character_feat_placeholders(p_character uuid)
returns jsonb
language sql stable security definer
set search_path = public, pg_temp
as $$
  select coalesce(jsonb_agg(jsonb_build_object('source', s, 'value', val) order by s), '[]') from (
    select 'class' as s, substr(v.value, 6) as val from public.character_feature_choices ch
    join public.character_feature_choice_values v on v.character_choice_id = ch.id and v.value like 'feat:%'
    where ch.character_id = p_character and not exists (select 1 from public.feat_versions fv where fv.id = substr(v.value, 6))
    union all
    select 'lineage', lc.value from public.character_lineage_choices lc join public.lineage_choices c on c.id = lc.choice_id and c.kind = 'feat'
    where lc.character_id = p_character and not exists (select 1 from public.feat_versions fv where 'feat:' || fv.id = lc.value)) x;
$$;

-- ---- choices ---------------------------------------------------------------------------------------------------------------
-- every choice of every grant with its values: stored picks, or the fixed value a background gives (Magic Initiate list)
create function public._character_feat_choice_values(p_character uuid)
returns table (grant_key text, feat_version_id text, choice_id text, key text, kind text, label text, min_picks int, max_picks int,
               config jsonb, vals text[], fixed boolean, complete boolean, open boolean)
language sql stable security definer
set search_path = public, pg_temp
as $$
  with g as (select * from public._character_feat_grants(p_character)),
  base as (
    select g.grant_key, g.feat_version_id, c.id as choice_id, c.key, c.kind, c.label, c.min_picks, c.max_picks, c.config,
           c.parent_choice_key, c.parent_option_id,
           case when g.parameter is not null and c.config -> 'parameter_map' ? g.parameter
                then array[c.config -> 'parameter_map' ->> g.parameter] end as fixed_vals,
           (select array_agg(x.value order by x.pick) from public.character_feat_choices x
            where x.character_id = p_character and x.grant_key = g.grant_key and x.choice_id = c.id) as stored
    from g join public.feat_choices c on c.version_id = g.feat_version_id)
  select b.grant_key, b.feat_version_id, b.choice_id, b.key, b.kind, b.label, b.min_picks, b.max_picks, b.config,
         coalesce(b.fixed_vals, b.stored, '{}'), b.fixed_vals is not null,
         case when b.kind = 'asi_points' then
                coalesce((select sum(split_part(v, ':', 2)::int) from unnest(coalesce(b.stored, '{}')) v), 0) = coalesce((b.config ->> 'points')::int, 2)
              else cardinality(coalesce(b.fixed_vals, b.stored, '{}')) >= b.min_picks end,
         b.parent_choice_key is null or exists (select 1 from base p where p.grant_key = b.grant_key and p.key = b.parent_choice_key
                                                 and b.parent_option_id = any (coalesce(p.fixed_vals, p.stored, '{}')))
  from base b;
$$;

-- one value of a feat choice: null when valid, else the reason
create function public._feat_choice_value_error(p_choice public.feat_choices, p_value text, p_list text)
returns text
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
declare v public.spell_versions; k text;
begin
  case p_choice.kind
    when 'ability_increase', 'ability', 'spellcasting_ability' then
      if p_value not in ('str', 'dex', 'con', 'int', 'wis', 'cha') then return 'unknown ability ' || p_value; end if;
      if p_choice.config ? 'from' and not (p_choice.config -> 'from') ? p_value then return upper(p_value) || ' is not one of the options'; end if;
    when 'asi_points' then
      if p_value !~ '^(str|dex|con|int|wis|cha):[12]$' then return 'an increase is written like str:2 or dex:1'; end if;
    when 'skill', 'expertise' then
      if not exists (select 1 from public.skills where id = p_value) then return 'unknown skill ' || p_value; end if;
      if p_choice.config ? 'from' and not (p_choice.config -> 'from') ? p_value then return p_value || ' is not one of the options'; end if;
    when 'tool' then
      if not exists (select 1 from public.items where id = p_value and kind_id = 'tool' and owner_id is null) then return 'unknown tool ' || p_value; end if;
      if p_choice.config ? 'category' and not exists (select 1 from public.items where id = p_value and category_id = p_choice.config ->> 'category') then
        return p_value || ' is not in the allowed tool group';
      end if;
    when 'skill_or_tool' then
      k := split_part(p_value, ':', 1);
      if k = 'skill' and exists (select 1 from public.skills where id = split_part(p_value, ':', 2)) then null;
      elsif k = 'tool' and exists (select 1 from public.items where id = split_part(p_value, ':', 2) and kind_id = 'tool' and owner_id is null) then null;
      else return 'choose skill:<skill> or tool:<tool> (' || p_value || ')'; end if;
    when 'language' then
      if not exists (select 1 from public.languages where id = p_value) then return 'unknown language ' || p_value; end if;
    when 'damage_type' then
      if not exists (select 1 from public.damage_types where id = p_value) then return 'unknown damage type ' || p_value; end if;
      if p_choice.config ? 'from' and not (p_choice.config -> 'from') ? p_value then return p_value || ' is not one of the options'; end if;
    when 'weapon' then
      if not exists (select 1 from public.items where id = p_value and kind_id = 'weapon' and owner_id is null) then return 'unknown weapon ' || p_value; end if;
    when 'spell_list', 'option' then
      if not exists (select 1 from public.feat_choice_options where choice_id = p_choice.id and option_id = p_value) then
        return p_value || ' is not one of the options';
      end if;
    when 'spell' then
      select * into v from public.spell_versions where id = p_value;
      if v.id is null then return 'unknown spell ' || p_value; end if;
      if p_choice.config ? 'level' and v.level <> (p_choice.config ->> 'level')::int then
        return v.name || ' is not a ' || case when (p_choice.config ->> 'level')::int = 0 then 'cantrip' else 'level ' || (p_choice.config ->> 'level') || ' spell' end;
      end if;
      if p_choice.config ? 'schools' and not exists (select 1 from public.spell_schools s where s.id = v.school_id
                                                     and (p_choice.config -> 'schools') ? lower(s.id)) then
        return v.name || ' is not of the required school';
      end if;
      if p_list is not null and not exists (select 1 from public.class_spell_list_entries e where e.list_id = p_list and e.spell_version_id = v.id) then
        return v.name || ' is not on the chosen spell list';
      end if;
    when 'free_text' then null;
    else return 'unknown choice kind';
  end case;
  return null;
end;
$$;

-- ---- prerequisites --------------------------------------------------------------------------------------------------------
create function public._feat_prereq_ctx(p_character uuid)
returns jsonb
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
declare c public.characters; li jsonb; d jsonb; groups text[]; skills text[]; lin record;
begin
  select * into c from public.characters where id = p_character;
  li := public._character_level_info(p_character);
  d := public._derived_stats_full(p_character);
  select array_agg(distinct x) into groups from (
    select e ->> 'group_id' as x from jsonb_array_elements(coalesce(d -> 'proficiencies', '[]')) e where e ->> 'group_id' is not null
    union select p.group_id from public.character_proficiencies p where p.character_id = p_character and p.group_id is not null
    union select case k when 'light' then 'light-armor' when 'medium' then 'medium-armor' when 'heavy' then 'heavy-armor'
                        when 'shields' then 'shields' when 'simple' then 'simple-weapons' when 'martial' then 'martial-weapons'
                        when 'firearms' then 'firearms' end
          from jsonb_each_text(coalesce(c.equipment_proficiencies, '{}')) j(k, val) where val = 'true') g where x is not null;
  select array_agg(s.id) into skills from public.skills s
  where coalesce((d -> 'skills' -> s.id ->> 'class_proficient')::boolean, false) or coalesce((d -> 'skills' -> s.id ->> 'lineage_proficient')::boolean, false)
     or coalesce((d -> 'skills' -> s.id ->> 'background_proficient')::boolean, false) or public._skill_level(c.skill_proficiencies -> s.id) >= 1;
  select l.name as lineage_name, l.id as lineage_id, lv.name as version_name, sv.name as sub_name into lin
  from public.character_lineages cl join public.lineages l on l.id = cl.lineage_id
  left join public.lineage_versions lv on lv.id = cl.version_id left join public.lineage_versions sv on sv.id = cl.subversion_id
  where cl.character_id = p_character;
  return jsonb_build_object(
    'total_level', coalesce((li ->> 'total_level')::int, c.level),
    'class_levels', (select coalesce(jsonb_object_agg(cc.class_id, cc.level), '{}') from public.character_classes cc where cc.character_id = p_character),
    'subclasses', (select coalesce(jsonb_agg(cc.subclass_version_id), '[]') from public.character_classes cc where cc.character_id = p_character and cc.subclass_version_id is not null),
    'abilities', (select jsonb_object_agg(k, (d -> 'abilities' -> k ->> 'score')::int) from unnest(array['str','dex','con','int','wis','cha']) k),
    'groups', to_jsonb(coalesce(groups, '{}')), 'skills', to_jsonb(coalesce(skills, '{}')),
    'can_cast', exists (select 1 from public.character_spells s where s.character_id = p_character)
                or exists (select 1 from public.character_spellcasting_sources s where s.character_id = p_character and not s.is_preview),
    'pact_magic', exists (select 1 from public.character_classes cc join public.class_versions v on v.id = cc.class_version_id
                          where cc.character_id = p_character and v.is_pact_magic),
    'spells', (select coalesce(jsonb_agg(distinct sv.spell_id), '[]') from public.character_spells s join public.spell_versions sv on sv.id = s.spell_version_id
               where s.character_id = p_character),
    'feats', (select coalesce(jsonb_agg(distinct fv.feat_id), '[]') from public._character_feat_grants(p_character) g
              join public.feat_versions fv on fv.id = g.feat_version_id where g.active),
    'lineage', lower(coalesce(lin.lineage_name, '') || ' ' || coalesce(lin.version_name, '') || ' ' || coalesce(lin.sub_name, '')),
    'background', (select v.background_id from public.character_backgrounds b join public.background_versions v on v.id = b.version_id where b.character_id = p_character),
    'size', coalesce(d -> 'size' ->> 'value', case when jsonb_typeof(d -> 'size') = 'string' then d ->> 'size' end));
end;
$$;

-- {status: satisfied | unsatisfied | unresolved, items: [{kind, label, status, reason}]}
create function public._feat_prereq_eval(p_version text, p_ctx jsonb)
returns jsonb
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
declare r public.feat_prerequisites; st text; items jsonb := '[]'; grp_status jsonb := '{}'; g text; overall text := 'satisfied'; reason text;
begin
  for r in select * from public.feat_prerequisites where version_id = p_version order by grp, seq loop
    reason := null;
    case r.kind
      when 'character_level' then st := case when (p_ctx ->> 'total_level')::int >= r.value::int then 'satisfied' else 'unsatisfied' end;
        reason := 'character level ' || (p_ctx ->> 'total_level');
      when 'class_level' then st := case when coalesce((p_ctx -> 'class_levels' ->> r.target)::int, 0) >= r.value::int then 'satisfied' else 'unsatisfied' end;
      when 'class' then st := case when p_ctx -> 'class_levels' ? r.target then 'satisfied' else 'unsatisfied' end;
      when 'subclass' then st := case when p_ctx -> 'subclasses' ? r.target then 'satisfied' else 'unsatisfied' end;
      when 'ability' then st := case when coalesce((p_ctx -> 'abilities' ->> r.target)::int, 0) >= r.value::int then 'satisfied' else 'unsatisfied' end;
        reason := upper(r.target) || ' is ' || coalesce(p_ctx -> 'abilities' ->> r.target, '?');
      when 'armor_proficiency', 'weapon_proficiency' then st := case when p_ctx -> 'groups' ? r.target then 'satisfied' else 'unsatisfied' end;
      when 'skill_proficiency' then st := case when p_ctx -> 'skills' ? r.target then 'satisfied' else 'unsatisfied' end;
      when 'spellcasting' then st := case when (p_ctx ->> 'can_cast')::boolean or (p_ctx ->> 'pact_magic')::boolean then 'satisfied' else 'unsatisfied' end;
      when 'pact_magic' then st := case when (p_ctx ->> 'pact_magic')::boolean then 'satisfied' else 'unsatisfied' end;
      when 'known_spell' then st := case when p_ctx -> 'spells' ? r.target then 'satisfied' else 'unsatisfied' end;
      when 'feat' then st := case when p_ctx -> 'feats' ? r.target then 'satisfied' else 'unsatisfied' end;
      when 'background' then st := case when p_ctx ->> 'background' = r.target then 'satisfied' else 'unsatisfied' end;
      when 'lineage' then st := case when coalesce(p_ctx ->> 'lineage', '') = '' then 'unsatisfied'
                                     when position(lower(r.target) in p_ctx ->> 'lineage') > 0 then 'satisfied' else 'unsatisfied' end;
      when 'size' then st := case when p_ctx ->> 'size' is null then 'unresolved' when lower(p_ctx ->> 'size') = any (string_to_array(lower(r.target), ',')) then 'satisfied' else 'unsatisfied' end;
      else st := 'unresolved'; reason := 'check with your DM';
    end case;
    items := items || jsonb_build_object('kind', r.kind, 'label', r.label, 'status', st, 'group', r.grp, 'reason', reason);
    g := r.grp::text;
    grp_status := grp_status || jsonb_build_object(g, case
      when grp_status ->> g = 'satisfied' or st = 'satisfied' then 'satisfied'
      when grp_status ->> g = 'unresolved' or st = 'unresolved' then 'unresolved' else 'unsatisfied' end);
  end loop;
  select case when bool_or(value = 'unsatisfied') then 'unsatisfied' when bool_or(value = 'unresolved') then 'unresolved' else 'satisfied' end
  into overall from jsonb_each_text(grp_status);
  return jsonb_build_object('status', coalesce(overall, 'satisfied'), 'items', items);
end;
$$;

-- ---- effects (row shape of _character_class_effects) -----------------------------------------------------------------------
create function public._character_feat_effects(p_character uuid)
returns table (character_class_id uuid, class_id text, class_name text, class_level integer, unlock_id text, feature_version_id text,
               feature_name text, origin text, seq integer, pick integer, effect_type text, target text, value numeric, value_text text,
               spell_version_id text, min_level integer, conditions jsonb, data jsonb, automation text, spellcasting_ability text,
               feature_active boolean, active boolean, inactive_reason text)
language sql stable security definer
set search_path = public, pg_temp
as $$
  with g as (select * from public._character_feat_grants(p_character)),
  ch as (select * from public._character_feat_choice_values(p_character)),
  lvl as (select coalesce((public._character_level_info(p_character) ->> 'total_level')::int,
                          (select level from public.characters where id = p_character)) as total),
  -- every effect of every granted version; an effect with a choice key yields one row per chosen value
  e as (
    select g.grant_key, g.active as grant_active, g.inactive_reason as grant_reason, fv.name as feat_name, fv.id as version_id,
           fe.seq, fe.effect_type, fe.target, fe.value, fe.value_text, fe.automation, fe.conditions, fe.data, fe.choice_key,
           fe.option_choice_key, fe.option_id, c.vals, c.complete as choice_complete, c.kind as choice_kind
    from g join public.feat_versions fv on fv.id = g.feat_version_id
    join public.feat_effects fe on fe.version_id = fv.id
    left join ch c on c.grant_key = g.grant_key and c.key = fe.choice_key
    where fe.option_choice_key is null
       or exists (select 1 from ch o where o.grant_key = g.grant_key and o.key = fe.option_choice_key and fe.option_id = any (o.vals))
    union all
    -- ability increases come from the choices themselves
    select g.grant_key, g.active, g.inactive_reason, fv.name, fv.id, 1000 + c.ord, 'ability_bonus', null, null, null, 'automated', '{}'::jsonb,
           jsonb_build_object('max', c.config -> 'max'), c.key, null, null, c.vals, c.complete, c.kind
    from g join public.feat_versions fv on fv.id = g.feat_version_id
    join (select x.*, row_number() over (partition by x.grant_key order by x.key)::int as ord from ch x
          where x.kind in ('ability_increase', 'asi_points')) c on c.grant_key = g.grant_key)
  select md5('feat:' || e.grant_key)::uuid, 'feat', 'Feat', l.total, e.grant_key, e.version_id, e.feat_name, 'feat', e.seq,
         case when e.choice_key is null then 0 else x.pick end,
         e.effect_type,
         case when e.choice_key is null then e.target
              when e.choice_kind = 'ability_increase' or e.choice_kind = 'asi_points' then split_part(x.val, ':', 1)
              when e.effect_type in ('proficiency', 'expertise') and e.choice_kind = 'skill_or_tool' then split_part(x.val, ':', 1)
              when e.effect_type in ('proficiency', 'expertise') and e.choice_kind in ('skill', 'expertise') then coalesce(e.target, 'skill')
              when e.effect_type = 'proficiency' and e.choice_kind = 'tool' then 'tool'
              when e.effect_type = 'proficiency' and e.choice_kind = 'weapon' then 'weapon'
              when e.effect_type = 'proficiency' and e.choice_kind = 'language' then 'language'
              when e.effect_type = 'resistance' then x.val
              else e.target end,
         case when e.choice_kind = 'asi_points' then split_part(x.val, ':', 2)::numeric
              when e.choice_kind = 'ability_increase' then coalesce((ch2.config ->> 'amount')::numeric, 1)
              else e.value end,
         case when e.choice_key is null then e.value_text
              when e.choice_kind = 'skill_or_tool' then split_part(x.val, ':', 2)
              when e.choice_kind in ('ability_increase', 'asi_points') then null
              when e.effect_type = 'resistance' then x.val
              else x.val end,
         null::text, 1, e.conditions, e.data || jsonb_build_object('grant_key', e.grant_key), e.automation, null::text,
         e.grant_active,
         e.grant_active and coalesce(e.choice_complete, true) and (e.choice_key is null or x.val is not null),
         case when not e.grant_active then coalesce(e.grant_reason, 'inactive')
              when not coalesce(e.choice_complete, true) then 'choice_incomplete' end
  from e
  cross join lvl l
  left join ch ch2 on ch2.grant_key = e.grant_key and ch2.key = e.choice_key
  left join lateral (select v as val, o::int as pick from unnest(coalesce(e.vals, '{}')) with ordinality u(v, o)) x on e.choice_key is not null
  where e.choice_key is null or x.val is not null or not coalesce(e.choice_complete, false);
$$;

-- class features and feats together: what the derived stats, proficiencies and attacks read
create function public._character_feature_effects(p_character uuid)
returns table (character_class_id uuid, class_id text, class_name text, class_level integer, unlock_id text, feature_version_id text,
               feature_name text, origin text, seq integer, pick integer, effect_type text, target text, value numeric, value_text text,
               spell_version_id text, min_level integer, conditions jsonb, data jsonb, automation text, spellcasting_ability text,
               feature_active boolean, active boolean, inactive_reason text)
language sql stable
set search_path = public, pg_temp
as $$
  select * from public._character_class_effects(p_character)
  union all
  select * from public._character_feat_effects(p_character)
  where not (effect_type = 'proficiency' and target = 'skill' and value_text = '*')
  union all   -- "proficiency in every skill" (Boon of Skill)
  select f.character_class_id, f.class_id, f.class_name, f.class_level, f.unlock_id, f.feature_version_id, f.feature_name, f.origin,
         f.seq, s.n::int, f.effect_type, f.target, f.value, s.id, f.spell_version_id, f.min_level, f.conditions, f.data, f.automation,
         f.spellcasting_ability, f.feature_active, f.active, f.inactive_reason
  from public._character_feat_effects(p_character) f
  cross join lateral (select id, row_number() over (order by id) as n from public.skills) s
  where f.effect_type = 'proficiency' and f.target = 'skill' and f.value_text = '*';
$$;

-- ---- materialization of feat resources and spells ---------------------------------------------------------------------------
create function public._feat_resource_key(p_grant text, p_key text)
returns text
language sql immutable
set search_path = public, pg_temp
as $$ select 'ft-' || substr(md5(p_grant), 1, 10) || '-' || p_key $$;

create function public._sync_character_feats(p_character uuid)
returns void
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare g record; rg public.feat_resource_grants; sg public.feat_spell_grants; src uuid; ab text; lst text; fv public.feat_versions;
  vals text[]; v text; keep_keys text[] := '{}'; keep_sources text[] := '{}'; complete boolean; hp_after int; hp_max_now int;
  engine_before text := coalesce(current_setting('tavern.resource_engine', true), '');
begin
  perform set_config('tavern.resource_engine', 'on', true);   -- reset below: the bypass of the resource guard ends with this sync
  for g in select * from public._character_feat_grants(p_character) loop
    select * into fv from public.feat_versions where id = g.feat_version_id;
    select coalesce(bool_and(c.complete), true) into complete from public._character_feat_choice_values(p_character) c where c.grant_key = g.grant_key;
    -- resources (kept with their expended count while the grant is inactive)
    for rg in select * from public.feat_resource_grants where version_id = g.feat_version_id loop
      keep_keys := keep_keys || public._feat_resource_key(g.grant_key, rg.key);
      insert into public.character_resources (character_id, resource_key, name, source_type, source_id, max_formula, recharge, active, notes, created_by)
      values (p_character, public._feat_resource_key(g.grant_key, rg.key), left(rg.name, 80), 'feat', g.grant_key, rg.max_formula, rg.recharge,
              g.active, left(fv.name || ' (' || g.source_label || ')', 500), auth.uid())
      on conflict (character_id, resource_key) do update set active = excluded.active, max_formula = excluded.max_formula,
        recharge = excluded.recharge, name = excluded.name;
    end loop;
    -- spells: one spellcasting source per grant with spells, only while the grant is active and its choices complete
    if exists (select 1 from public.feat_spell_grants where version_id = g.feat_version_id) and g.active and complete then
      keep_sources := keep_sources || g.grant_key;
      select sg2.ability, sg2.ability_choice_key, sg2.ability_from_option into sg.ability, sg.ability_choice_key, sg.ability_from_option
      from public.feat_spell_grants sg2 where sg2.version_id = g.feat_version_id order by seq limit 1;
      ab := coalesce(sg.ability,
        (select c.vals[1] from public._character_feat_choice_values(p_character) c where c.grant_key = g.grant_key and c.key = sg.ability_choice_key),
        (select o.data ->> 'ability' from public._character_feat_choice_values(p_character) c
           join public.feat_choice_options o on o.choice_id = c.choice_id and o.option_id = c.vals[1]
         where c.grant_key = g.grant_key and c.key = sg.ability_from_option));
      lst := (select c.vals[1] from public._character_feat_choice_values(p_character) c where c.grant_key = g.grant_key and c.kind = 'spell_list' limit 1);
      select id into src from public.character_spellcasting_sources where character_id = p_character and feat_grant_key = g.grant_key;
      if src is null then
        insert into public.character_spellcasting_sources (character_id, source_type, label, spell_list_id, casting_ability, preparation_mode,
                                                           ritual_mode, uses_spell_slots, feat_grant_key, notes, created_by)
        values (p_character, 'feat', left(fv.name || ' (' || replace(g.source_label, 'Background: ', '') || ')', 80), lst, ab, 'innate', 'none',
                true, g.grant_key, 'Granted by a feat; removed with the feat.', auth.uid())
        returning id into src;
      else
        update public.character_spellcasting_sources set casting_ability = ab, spell_list_id = lst where id = src;
      end if;
      -- the spells of the grant (exact catalog versions; never copied)
      delete from public.character_spells cs where cs.source_id = src and cs.spell_version_id not in (
        select coalesce(x.spell_version_id, y.v) from public.feat_spell_grants x
        left join lateral (select unnest(c.vals) as v from public._character_feat_choice_values(p_character) c
                           where c.grant_key = g.grant_key and c.key = x.choice_key) y on x.choice_key is not null
        where x.version_id = g.feat_version_id and coalesce(x.spell_version_id, y.v) is not null);
      for sg in select * from public.feat_spell_grants where version_id = g.feat_version_id order by seq loop
        vals := case when sg.spell_version_id is not null then array[sg.spell_version_id]
                     else (select c.vals from public._character_feat_choice_values(p_character) c where c.grant_key = g.grant_key and c.key = sg.choice_key) end;
        foreach v in array coalesce(vals, '{}') loop
          insert into public.character_spells (character_id, source_id, spell_version_id, known, prepared, always_prepared,
                                               counts_against_known_limit, counts_against_prepared_limit, uses_spell_slot, casting_ability,
                                               acquisition, acquisition_notes)
          values (p_character, src, v, true, sg.mode = 'always_prepared', sg.mode = 'always_prepared', false, false, sg.uses_slots, ab,
                  'feature', left(sg.label, 300))
          on conflict (source_id, spell_version_id) do update set casting_ability = excluded.casting_ability, uses_spell_slot = excluded.uses_spell_slot;
          if sg.uses in ('long_rest_1', 'pb_long_rest') then
            keep_keys := keep_keys || public._feat_resource_key(g.grant_key, 'cast-' || replace(v, '_', '-'));
            insert into public.character_resources (character_id, resource_key, name, source_type, source_id, max_formula, recharge,
                                                    spell_version_id, active, notes, created_by)
            values (p_character, public._feat_resource_key(g.grant_key, 'cast-' || replace(v, '_', '-')),
                    left('Free cast: ' || coalesce((select name from public.spell_versions where id = v), v), 80), 'feat', g.grant_key,
                    case when sg.uses = 'pb_long_rest' then '{"terms": [{"of": "proficiency_bonus"}]}'::jsonb else '{"fixed": 1}'::jsonb end,
                    'long_rest', v, true, left(fv.name || ': cast once without a spell slot', 500), auth.uid())
            on conflict (character_id, resource_key) do update set active = true;
          end if;
        end loop;
      end loop;
    end if;
  end loop;
  -- grants that are gone: their spell sources are removed (other sources of the same spell stay), resources deactivated
  delete from public.character_spellcasting_sources s where s.character_id = p_character and s.feat_grant_key is not null
    and not s.feat_grant_key = any (keep_sources);
  update public.character_resources r set active = false where r.character_id = p_character and r.source_type = 'feat'
    and not r.resource_key = any (keep_keys) and r.active;
  -- maximum HP policy: if the resolved maximum dropped below the current HP (a feat like Tough removed), clamp current HP
  hp_max_now := (public._feat_hp_bonus(p_character) ->> 'max')::int;
  update public.characters set hp_current = hp_max_now where id = p_character and hp_current > hp_max_now;
  perform set_config('tavern.resource_engine', engine_before, true);
end;
$$;

-- maximum HP: the stored base + feat bonuses (lineage HP traits stay informational as before: older characters include them)
create function public._feat_hp_bonus(p_character uuid)
returns jsonb
language sql stable security definer
set search_path = public, pg_temp
as $$
  with f as (select * from public._character_feat_effects(p_character) where active and effect_type in ('hp_per_level', 'hp_flat')),
  t as (select coalesce(sum(case when effect_type = 'hp_per_level' then value * class_level else value end), 0)::int as bonus,
               coalesce(jsonb_agg(jsonb_build_object('source_name', 'Feat: ' || feature_name, 'value',
                 (case when effect_type = 'hp_per_level' then value * class_level else value end)::int)), '[]') as sources from f)
  select jsonb_build_object('base', c.hp_max, 'feat_bonus', t.bonus, 'max', c.hp_max + t.bonus, 'feat_sources', t.sources)
  from public.characters c cross join t where c.id = p_character;
$$;

-- triggers: every grant source re-syncs the character's feats (after the statement's changes)
create function public._feat_sync_trigger()
returns trigger
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare cid uuid;
begin
  cid := coalesce((to_jsonb(new) ->> 'character_id')::uuid, (to_jsonb(old) ->> 'character_id')::uuid);
  if tg_table_name = 'character_feature_choice_values' then
    select character_id into cid from public.character_feature_choices where id = coalesce(new.character_choice_id, old.character_choice_id);
  end if;
  if cid is not null and exists (select 1 from public.characters where id = cid)
     and coalesce(current_setting('tavern.feat_sync', true), '') <> 'off' then
    perform public._sync_character_feats(cid);
  end if;
  return coalesce(new, old);
end;
$$;
create trigger character_feats_sync after insert or update or delete on public.character_feats for each row execute function public._feat_sync_trigger();
create trigger character_feat_choices_sync after insert or update or delete on public.character_feat_choices for each row execute function public._feat_sync_trigger();
create trigger character_backgrounds_feat_sync after insert or update or delete on public.character_backgrounds for each row execute function public._feat_sync_trigger();
create trigger character_lineage_choices_feat_sync after insert or update or delete on public.character_lineage_choices for each row execute function public._feat_sync_trigger();
create trigger character_lineages_feat_sync after insert or update or delete on public.character_lineages for each row execute function public._feat_sync_trigger();
create trigger character_feature_choice_values_feat_sync after insert or update or delete on public.character_feature_choice_values for each row execute function public._feat_sync_trigger();
create trigger character_classes_feat_sync after insert or update or delete on public.character_classes for each row execute function public._feat_sync_trigger();

-- ---- validation of one feat pick (ASI, direct, lineage): null = allowed --------------------------------------------------------
create function public._feat_pick_error(p_character uuid, p_version text, p_grant_key text, p_override boolean default false)
returns text
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
declare fv public.feat_versions; pre jsonb; camp uuid; mode text; same int; dm boolean;
begin
  select * into fv from public.feat_versions where id = p_version;
  if fv.id is null then return null; end if;            -- a free-text placeholder (older data): allowed, reported as unresolved
  if fv.archived_at is not null and not exists (select 1 from public._character_feat_grants(p_character) g where g.grant_key = p_grant_key and g.feat_version_id = p_version) then
    return fv.name || ' is archived and no longer available';
  end if;
  if fv.campaign_id is not null and fv.campaign_id is distinct from (select campaign_id from public.characters where id = p_character) then
    return fv.name || ' belongs to another campaign';
  end if;
  -- repeatability
  select count(*) into same from public._character_feat_grants(p_character) g join public.feat_versions x on x.id = g.feat_version_id
  where x.feat_id = fv.feat_id and g.grant_key is distinct from p_grant_key and g.active;
  if same > 0 and fv.repeatable = 'once' then return fv.name || ' can be taken only once'; end if;
  if fv.max_count is not null and same >= fv.max_count then return fv.name || ' can be taken at most ' || fv.max_count || ' times'; end if;
  -- prerequisites
  pre := public._feat_prereq_eval(p_version, public._feat_prereq_ctx(p_character));
  if pre ->> 'status' = 'unsatisfied' and not p_override then
    select c.campaign_id into camp from public.characters c where c.id = p_character;
    dm := public.is_admin() or (camp is not null and public.is_campaign_dm(camp));
    select unmet_prerequisites into mode from public.campaign_governance where campaign_id = camp;
    if not dm and (camp is null or coalesce(mode, 'propose') <> 'propose' or current_setting('tavern.gov_preview', true) is distinct from p_character::text) then
      return fv.name || ': prerequisite not met (' || (select string_agg(i ->> 'label', ', ') from jsonb_array_elements(pre -> 'items') i
                                                       where i ->> 'status' = 'unsatisfied') || ')';
    end if;
  end if;
  return null;
end;
$$;

-- ---- read models ---------------------------------------------------------------------------------------------------------
create function public._feat_version_json(p_version text)
returns jsonb
language sql stable security definer
set search_path = public, pg_temp
as $$
  select to_jsonb(v) - 'owner_id' || jsonb_build_object(
    'canonical_name', f.name,
    'source_book', (select name from public.source_books where id = v.source_book_id),
    'scope', case when v.owner_id is null then 'official' else 'campaign' end,
    'prerequisites', (select coalesce(jsonb_agg(to_jsonb(p) - 'version_id' order by p.grp, p.seq), '[]') from public.feat_prerequisites p where p.version_id = v.id),
    'choices', (select coalesce(jsonb_agg(to_jsonb(c) - 'version_id' || jsonb_build_object('options',
                  (select coalesce(jsonb_agg(to_jsonb(o) - 'choice_id' order by o.seq), '[]') from public.feat_choice_options o where o.choice_id = c.id))
                  order by c.seq), '[]') from public.feat_choices c where c.version_id = v.id),
    'effects', (select coalesce(jsonb_agg(to_jsonb(e) - 'version_id' order by e.seq), '[]') from public.feat_effects e where e.version_id = v.id),
    'spell_grants', (select coalesce(jsonb_agg(to_jsonb(s) - 'version_id' || jsonb_build_object('spell_name', (select name from public.spell_versions where id = s.spell_version_id))
                       order by s.seq), '[]') from public.feat_spell_grants s where s.version_id = v.id),
    'resources', (select coalesce(jsonb_agg(to_jsonb(r) - 'version_id'), '[]') from public.feat_resource_grants r where r.version_id = v.id),
    'attacks', (select coalesce(jsonb_agg(to_jsonb(a) - 'version_id'), '[]') from public.feat_attack_grants a where a.version_id = v.id),
    'ability_increase', (select jsonb_agg(jsonb_build_object('key', c.key, 'from', c.config -> 'from', 'amount', c.config -> 'amount', 'points', c.config -> 'points', 'max', c.config -> 'max'))
                         from public.feat_choices c where c.version_id = v.id and c.kind in ('ability_increase', 'asi_points')),
    'other_versions', (select coalesce(jsonb_agg(jsonb_build_object('id', o.id, 'ruleset', o.ruleset, 'status', o.status) order by o.ruleset), '[]')
                       from public.feat_versions o where o.feat_id = v.feat_id and o.id <> v.id))
  from public.feat_versions v join public.feats f on f.id = v.feat_id
  where v.id = p_version;
$$;

create function public.get_feat_detail(p_version text)
returns jsonb
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
declare fv public.feat_versions;
begin
  select * into fv from public.feat_versions where id = p_version;
  if fv.id is null or not public.can_view_owned(fv.owner_id, fv.campaign_id) then raise exception 'Unknown feat' using errcode = 'P0002'; end if;
  return public._feat_version_json(p_version);
end;
$$;

-- The picker: every visible version with its eligibility for the character (if given) and the campaign content policy.
create function public.get_feat_catalog(p_character uuid default null)
returns jsonb
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
declare ctx jsonb; camp uuid; have jsonb := '{}';
begin
  if p_character is not null then
    if auth.uid() is null or not public.can_access_character(p_character) then raise exception 'Character not found' using errcode = '42501'; end if;
    ctx := public._feat_prereq_ctx(p_character);
    select campaign_id into camp from public.characters where id = p_character;
    select coalesce(jsonb_object_agg(x.feat_id, x.n), '{}') into have from (
      select fv.feat_id, count(*) as n from public._character_feat_grants(p_character) g join public.feat_versions fv on fv.id = g.feat_version_id
      where g.active group by 1) x;
  end if;
  return (select coalesce(jsonb_agg(j order by j ->> 'name', j ->> 'ruleset'), '[]') from (
    select jsonb_build_object('id', v.id, 'feat_id', v.feat_id, 'name', v.name, 'category', v.category, 'ruleset', v.ruleset,
             'status', v.status, 'setting', v.setting, 'legacy', v.legacy, 'source_label', v.source_label, 'summary', v.summary,
             'automation', v.automation, 'repeatable', v.repeatable, 'tags', to_jsonb(v.tags), 'prerequisite_text', v.prerequisite_text,
             'min_level', v.min_level, 'scope', case when v.owner_id is null then 'official' else 'campaign' end, 'archived', v.archived_at is not null,
             'grants', jsonb_build_object(
               'ability', exists (select 1 from public.feat_choices c where c.version_id = v.id and c.kind in ('ability_increase', 'asi_points')),
               'spells', exists (select 1 from public.feat_spell_grants s where s.version_id = v.id),
               'proficiency', exists (select 1 from public.feat_effects e where e.version_id = v.id and e.effect_type in ('proficiency', 'expertise')),
               'resource', exists (select 1 from public.feat_resource_grants r where r.version_id = v.id)),
             'prerequisite', case when ctx is not null then public._feat_prereq_eval(v.id, ctx) end,
             'taken', coalesce((have ->> v.feat_id)::int, 0),
             'policy_reason', case when camp is not null then public._content_policy_reason(camp, case when v.ruleset in ('2014', '2024') then v.ruleset end,
                                v.legacy, v.status in ('playtest', 'third_party', 'unverified'), v.setting, v.owner_id is not null, v.source_book_id) end) as j
    from public.feat_versions v
    where public.can_view_owned(v.owner_id, v.campaign_id)
      and (v.archived_at is null or p_character is null)
      and (v.campaign_id is null or v.campaign_id = camp or p_character is null)) x);
end;
$$;

-- The authoritative read model of a character's feats.
create function public.get_character_feats(p_character uuid)
returns jsonb
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
declare ctx jsonb; out jsonb := '[]'; g record; fv jsonb; ch jsonb; eff jsonb; spells jsonb; res jsonb; warn jsonb := '[]'; dup jsonb;
begin
  if auth.uid() is null or not public.can_access_character(p_character) then raise exception 'Character not found' using errcode = '42501'; end if;
  ctx := public._feat_prereq_ctx(p_character);
  for g in select * from public._character_feat_grants(p_character) order by ord, grant_key loop
    fv := public._feat_version_json(g.feat_version_id);
    select coalesce(jsonb_agg(jsonb_build_object('choice_id', c.choice_id, 'key', c.key, 'kind', c.kind, 'label', c.label,
             'min', c.min_picks, 'max', c.max_picks, 'config', c.config, 'values', to_jsonb(c.vals), 'fixed', c.fixed,
             'status', case when c.fixed then 'fixed' when c.complete then 'complete' else 'incomplete' end,
             'value_labels', (select coalesce(jsonb_agg(coalesce(
                 (select o.label from public.feat_choice_options o where o.choice_id = c.choice_id and o.option_id = v),
                 (select name from public.spell_versions where id = v), (select name from public.skills where id = v),
                 (select name from public.items where id = v), (select name from public.languages where id = v),
                 (select name from public.skills where id = split_part(v, ':', 2)), (select name from public.items where id = split_part(v, ':', 2)),
                 v)), '[]') from unnest(c.vals) v)) order by c.key), '[]')
    into ch from public._character_feat_choice_values(p_character) c where c.grant_key = g.grant_key;
    select coalesce(jsonb_agg(jsonb_build_object('effect_type', e.effect_type, 'target', e.target, 'value', e.value, 'value_text', e.value_text,
             'active', e.active, 'inactive_reason', e.inactive_reason, 'automation', e.automation, 'label', fe.label, 'activation', fe.activation)
             order by e.seq, e.pick), '[]')
    into eff from public._character_feat_effects(p_character) e left join public.feat_effects fe on fe.version_id = e.feature_version_id and fe.seq = e.seq
    where e.unlock_id = g.grant_key;
    select coalesce(jsonb_agg(jsonb_build_object('character_spell_id', cs.id, 'spell_version_id', cs.spell_version_id,
             'name', (select name from public.spell_versions where id = cs.spell_version_id), 'casting_ability', cs.casting_ability,
             'always_prepared', cs.always_prepared, 'uses_spell_slot', cs.uses_spell_slot)), '[]')
    into spells from public.character_spellcasting_sources s join public.character_spells cs on cs.source_id = s.id
    where s.character_id = p_character and s.feat_grant_key = g.grant_key;
    select coalesce(jsonb_agg(jsonb_build_object('key', 'r:' || r.id, 'name', r.name, 'active', r.active, 'expended', r.expended,
             'max', (public._resource_max(r.max_formula, jsonb_build_object('total_level', (ctx ->> 'total_level')::int,
                      'proficiency_bonus', ((ctx ->> 'total_level')::int - 1) / 4 + 2, 'mods', '{}'::jsonb)) ->> 'max')::int,
             'recharge', r.recharge, 'spell_version_id', r.spell_version_id)), '[]')
    into res from public.character_resources r where r.character_id = p_character and r.source_type = 'feat' and r.source_id = g.grant_key;
    out := out || jsonb_build_array(jsonb_build_object(
      'grant_key', g.grant_key, 'source_type', g.source_type, 'source_label', g.source_label, 'character_feat_id', g.character_feat_id,
      'active', g.active, 'inactive_reason', g.inactive_reason, 'parameter', g.parameter,
      'feat', fv, 'prerequisite', public._feat_prereq_eval(g.feat_version_id, ctx),
      'prerequisite_override', (select jsonb_build_object('reason', override_reason, 'by', override_by) from public.character_feats
                                where id = g.character_feat_id and prerequisite_override),
      'notes', (select notes from public.character_feats where id = g.character_feat_id),
      'choices', ch, 'effects', eff, 'spells', spells, 'resources', res,
      'open_choices', (select count(*) from jsonb_array_elements(ch) c where c ->> 'status' = 'incomplete')));
  end loop;
  -- the same feat from two grants (allowed for repeatable feats only)
  select coalesce(jsonb_agg(jsonb_build_object('code', 'duplicate_feat', 'feat_id', x.feat_id, 'count', x.n)), '[]') into dup from (
    select fv2.feat_id, count(*) as n from public._character_feat_grants(p_character) g2 join public.feat_versions fv2 on fv2.id = g2.feat_version_id
    where g2.active and fv2.repeatable = 'once' group by 1 having count(*) > 1) x;
  warn := warn || dup;
  return jsonb_build_object('character_id', p_character, 'feats', out,
    'open_choices', (select coalesce(sum((f ->> 'open_choices')::int), 0) from jsonb_array_elements(out) f),
    'placeholders', public._character_feat_placeholders(p_character), 'warnings', warn,
    'hit_points', public._feat_hp_bonus(p_character));
end;
$$;

-- ---- write RPCs ----------------------------------------------------------------------------------------------------------
-- Validate and store choices of one grant: p_choices {key: [values]}; missing keys keep their values.
create function public._store_feat_choices(p_character uuid, p_grant text, p_version text, p_choices jsonb, p_require_complete boolean)
returns void
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare c public.feat_choices; v_vals text[]; v text; err text; i int; lst text; total int; fixed boolean; par text;
begin
  if p_choices is not null and jsonb_typeof(p_choices) <> 'object' then raise exception 'Choices must be an object' using errcode = '22023'; end if;
  for c in select * from public.feat_choices where version_id = p_version order by seq loop
    select g.parameter into par from public._character_feat_grants(p_character) g where g.grant_key = p_grant;
    fixed := par is not null and c.config -> 'parameter_map' ? par;
    if p_choices ? c.key and not fixed then
      if jsonb_typeof(p_choices -> c.key) <> 'array' then raise exception '% must be a list', c.label using errcode = '22023'; end if;
      v_vals := array(select jsonb_array_elements_text(p_choices -> c.key));
      if cardinality(v_vals) > c.max_picks then raise exception '%: at most % choices', c.label, c.max_picks using errcode = '22023'; end if;
      if (select count(distinct x) from unnest(v_vals) x) <> cardinality(v_vals) then raise exception '%: the same value twice', c.label using errcode = '22023'; end if;
      lst := case when c.config ? 'list_from' then coalesce(
               (select (array(select jsonb_array_elements_text(p_choices -> (c.config ->> 'list_from'))))[1]),
               (select x.vals[1] from public._character_feat_choice_values(p_character) x where x.grant_key = p_grant and x.key = c.config ->> 'list_from')) end;
      foreach v in array v_vals loop
        err := public._feat_choice_value_error(c, v, lst);
        if err is not null then raise exception '%: %', c.label, err using errcode = '22023'; end if;
      end loop;
      if c.kind = 'asi_points' then
        select coalesce(sum(split_part(x, ':', 2)::int), 0) into total from unnest(v_vals) x;
        if total > coalesce((c.config ->> 'points')::int, 2) then raise exception '%: % points at most', c.label, c.config ->> 'points' using errcode = '22023'; end if;
      end if;
      if c.kind = 'expertise' then
        foreach v in array v_vals loop
          if not (public._feat_prereq_ctx(p_character) -> 'skills') ? v
             and not exists (select 1 from unnest(array(select jsonb_array_elements_text(coalesce(p_choices -> 'skill', '[]'))) || '{}') s where s = v) then
            raise exception 'Expertise needs proficiency in %', v using errcode = '22023';
          end if;
        end loop;
      end if;
      -- a feat repeatable only with a different option (Magic Initiate list, Elemental Adept type): no other grant of the same
      -- feat may hold the same value of the distinct choice
      if exists (select 1 from public.feat_versions fv where fv.id = p_version and fv.repeatable = 'repeatable_distinct' and fv.distinct_choice_key = c.key)
         and exists (select 1 from public._character_feat_choice_values(p_character) o
                     join public.feat_versions ov on ov.id = o.feat_version_id
                     where o.grant_key <> p_grant and o.key = c.key and ov.feat_id = (select feat_id from public.feat_versions where id = p_version)
                       and o.vals && v_vals) then
        raise exception '%: you already have this feat with that choice; pick a different one', c.label using errcode = '22023';
      end if;
      delete from public.character_feat_choices where character_id = p_character and grant_key = p_grant and choice_id = c.id;
      i := 0;
      foreach v in array v_vals loop
        i := i + 1;
        insert into public.character_feat_choices (character_id, grant_key, choice_id, pick, value) values (p_character, p_grant, c.id, i, v);
      end loop;
    end if;
  end loop;
  if p_require_complete and exists (select 1 from public._character_feat_choice_values(p_character) x where x.grant_key = p_grant and not x.complete) then
    raise exception 'Some choices of this feat are still open' using errcode = '22023';
  end if;
end;
$$;

-- Give a feat directly (DM grant, campaign reward, or the player's own pick where campaign policy allows / via a request).
create function public.assign_character_feat(p_character uuid, p_version text, p_choices jsonb default '{}', p_source_type text default 'direct',
                                             p_source_note text default null, p_override_reason text default null, p_notes text default null)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare fv public.feat_versions; camp uuid; dm boolean; err text; cid uuid; st text := coalesce(p_source_type, 'direct');
begin
  perform public._gov_gate(p_character, 'choice.feat');
  if auth.uid() is null or not public.can_access_character(p_character) then raise exception 'Character not found' using errcode = '42501'; end if;
  perform 1 from public.characters where id = p_character for update;
  select campaign_id into camp from public.characters where id = p_character;
  dm := public.is_admin() or (camp is not null and public.is_campaign_dm(camp));
  select * into fv from public.feat_versions where id = p_version;
  if fv.id is null or not public.can_view_owned(fv.owner_id, fv.campaign_id) then raise exception 'Unknown feat' using errcode = 'P0002'; end if;
  if st not in ('direct', 'dm_grant', 'campaign_reward', 'approved_request', 'import') then raise exception 'Unknown source' using errcode = '22023'; end if;
  if st in ('dm_grant', 'campaign_reward') and not dm then raise exception 'Only the DM can grant feats as rewards' using errcode = '42501'; end if;
  if nullif(btrim(coalesce(p_override_reason, '')), '') is not null then
    perform public._gov_gate(p_character, 'dm.prerequisite_override');
    if not dm and camp is not null then raise exception 'Only the DM can override a prerequisite' using errcode = 'TLDMO'; end if;
  end if;
  perform public._gov_content_check(p_character, public._content_policy_reason(camp, case when fv.ruleset in ('2014', '2024') then fv.ruleset end,
    fv.legacy, fv.status in ('playtest', 'third_party', 'unverified'), fv.setting, fv.owner_id is not null, fv.source_book_id));
  err := public._feat_pick_error(p_character, p_version, null, nullif(btrim(coalesce(p_override_reason, '')), '') is not null);
  if err is not null then raise exception '%', err using errcode = '22023'; end if;
  if current_setting('tavern.gov_apply', true) <> '' and st = 'direct' then st := 'approved_request'; end if;
  perform set_config('tavern.feat_sync', 'off', true);
  insert into public.character_feats (character_id, feat_version_id, source_type, source_note, notes, prerequisite_override, override_reason, override_by)
  values (p_character, p_version, st, nullif(left(btrim(coalesce(p_source_note, '')), 300), ''), nullif(left(p_notes, 1000), ''),
          nullif(btrim(coalesce(p_override_reason, '')), '') is not null, nullif(btrim(coalesce(p_override_reason, '')), ''),
          case when nullif(btrim(coalesce(p_override_reason, '')), '') is not null then auth.uid() end)
  returning id into cid;
  perform public._store_feat_choices(p_character, 'cf:' || cid, p_version, coalesce(p_choices, '{}'), false);
  perform set_config('tavern.feat_sync', '', true);
  perform public._sync_character_feats(p_character);
  if camp is not null then
    perform public._audit(camp, p_character, 'feat_added', 'Feat added: ' || fv.name || ' (' || fv.ruleset || ')', null,
      jsonb_build_object('feat_version_id', p_version, 'source_type', st), nullif(btrim(coalesce(p_override_reason, '')), ''),
      nullif(current_setting('tavern.gov_apply', true), '')::uuid, 'party');
    if nullif(btrim(coalesce(p_override_reason, '')), '') is not null then
      perform public._audit(camp, p_character, 'dm_override_used', 'Prerequisite override: ' || fv.name, null, null, p_override_reason, null, 'party');
    end if;
  end if;
  return public.get_character_feats(p_character) || jsonb_build_object('character_feat_id', cid);
end;
$$;

create function public.remove_character_feat(p_character_feat uuid, p_reason text default null)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare cf public.character_feats; camp uuid; nm text;
begin
  select * into cf from public.character_feats where id = p_character_feat;
  if cf.id is null then raise exception 'Feat not found' using errcode = 'P0002'; end if;
  perform public._gov_gate(cf.character_id, 'choice.feat');
  if auth.uid() is null or not public.can_access_character(cf.character_id) then raise exception 'Feat not found' using errcode = '42501'; end if;
  perform 1 from public.characters where id = cf.character_id for update;
  select campaign_id into camp from public.characters where id = cf.character_id;
  select name into nm from public.feat_versions where id = cf.feat_version_id;
  delete from public.character_feat_choices where character_id = cf.character_id and grant_key = 'cf:' || cf.id;
  delete from public.character_feats where id = cf.id;
  perform public._sync_character_feats(cf.character_id);
  if camp is not null then
    perform public._audit(camp, cf.character_id, 'feat_removed', 'Feat removed: ' || nm, jsonb_build_object('feat_version_id', cf.feat_version_id),
                          null, p_reason, nullif(current_setting('tavern.gov_apply', true), '')::uuid, 'party');
  end if;
  return public.get_character_feats(cf.character_id);
end;
$$;

-- choices of any grant (direct, background, lineage, ASI); the grant decides the governed action
create function public.set_character_feat_choices(p_character uuid, p_grant_key text, p_choices jsonb)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare g record;
begin
  select * into g from public._character_feat_grants(p_character) x where x.grant_key = p_grant_key;
  if g.grant_key is null then raise exception 'This feat is not granted to this character' using errcode = '22023'; end if;
  perform public._gov_gate(p_character, case g.source_type when 'background' then 'build.background' when 'lineage' then 'build.lineage' else 'choice.feat' end);
  if auth.uid() is null or not public.can_access_character(p_character) then raise exception 'Character not found' using errcode = '42501'; end if;
  perform 1 from public.characters where id = p_character for update;
  perform set_config('tavern.feat_sync', 'off', true);
  perform public._store_feat_choices(p_character, p_grant_key, g.feat_version_id, p_choices, false);
  perform set_config('tavern.feat_sync', '', true);
  perform public._sync_character_feats(p_character);
  return public.get_character_feats(p_character);
end;
$$;

-- player notes on a direct feat (free text, identity)
create function public.set_character_feat_notes(p_character_feat uuid, p_notes text)
returns void
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare cid uuid;
begin
  select character_id into cid from public.character_feats where id = p_character_feat;
  if cid is null then raise exception 'Feat not found' using errcode = 'P0002'; end if;
  perform public._gov_gate(cid, 'identity.notes');
  if auth.uid() is null or not public.can_access_character(cid) then raise exception 'Feat not found' using errcode = '42501'; end if;
  update public.character_feats set notes = nullif(left(btrim(coalesce(p_notes, '')), 1000), '') where id = p_character_feat;
end;
$$;

-- export (exact versions, sources, choices) and import (resolves versions, keeps unknown ones in the report)
create function public.export_character_feats(p_character uuid)
returns jsonb
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
begin
  if auth.uid() is null or not public.can_access_character(p_character) then raise exception 'Character not found' using errcode = '42501'; end if;
  return (select coalesce(jsonb_agg(jsonb_build_object(
            'grant_key', case when g.source_type in ('background', 'lineage', 'class') then g.grant_key end,
            'source_type', g.source_type, 'source_label', g.source_label,
            'feat_version_id', g.feat_version_id, 'feat_name', fv.name, 'ruleset', fv.ruleset,
            'custom', fv.owner_id is not null, 'notes', (select notes from public.character_feats where id = g.character_feat_id),
            'choices', (select coalesce(jsonb_object_agg(c.key, to_jsonb(c.vals)), '{}') from public._character_feat_choice_values(p_character) c
                        where c.grant_key = g.grant_key and not c.fixed))
          order by g.ord, g.grant_key), '[]')
          from public._character_feat_grants(p_character) g join public.feat_versions fv on fv.id = g.feat_version_id);
end;
$$;

-- Import: direct feats are assigned through assign_character_feat (governed); the choices of derived grants (background,
-- lineage, ASI) are applied when the grant exists after the rest of the import. Unknown versions are reported, never created.
create function public.import_character_feats(p_character uuid, p_feats jsonb)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare f jsonb; rep jsonb := '[]'; fv public.feat_versions; gk text;
begin
  if auth.uid() is null or not public.can_access_character(p_character) then raise exception 'Character not found' using errcode = '42501'; end if;
  if p_feats is null or jsonb_typeof(p_feats) <> 'array' then return jsonb_build_object('imported', 0, 'report', '[]'::jsonb); end if;
  for f in select x from jsonb_array_elements(p_feats) x loop
    select * into fv from public.feat_versions where id = f ->> 'feat_version_id' and public.can_view_owned(owner_id, campaign_id);
    if fv.id is null then
      rep := rep || jsonb_build_array(jsonb_build_object('feat', coalesce(f ->> 'feat_name', f ->> 'feat_version_id'), 'status', 'unresolved',
        'note', 'Unknown or not visible feat version; ask your DM (custom feats are never created by an import).'));
      continue;
    end if;
    begin
      if f ->> 'source_type' in ('background', 'lineage', 'class') then
        gk := f ->> 'grant_key';
        if exists (select 1 from public._character_feat_grants(p_character) g where g.grant_key = gk) then
          perform public.set_character_feat_choices(p_character, gk, coalesce(f -> 'choices', '{}'));
          rep := rep || jsonb_build_array(jsonb_build_object('feat', fv.name, 'status', 'choices_restored'));
        else
          rep := rep || jsonb_build_array(jsonb_build_object('feat', fv.name, 'status', 'skipped', 'note', 'Its source (background, lineage or ASI) is not on the character.'));
        end if;
      else
        perform public.assign_character_feat(p_character, fv.id, coalesce(f -> 'choices', '{}'), 'import', f ->> 'source_label', null, f ->> 'notes');
        rep := rep || jsonb_build_array(jsonb_build_object('feat', fv.name, 'status', 'imported'));
      end if;
    exception when others then
      rep := rep || jsonb_build_array(jsonb_build_object('feat', fv.name, 'status', case when sqlstate like 'TL%' then 'needs_dm' else 'failed' end, 'note', sqlerrm));
    end;
  end loop;
  return jsonb_build_object('imported', (select count(*) from jsonb_array_elements(rep) r where r ->> 'status' in ('imported', 'choices_restored')), 'report', rep);
end;
$$;

-- ---- requests: feat operations ------------------------------------------------------------------------------------------
insert into public.change_request_ops (op, function_name, action_key, character_param, args, label, sort_order) values
  ('assign_character_feat', 'assign_character_feat', 'choice.feat', 'p_character',
   '{"p_version": "text!", "p_choices": "jsonb", "p_source_note": "text", "p_override_reason": "text", "p_notes": "text"}', 'Feat', 45),
  ('remove_character_feat', 'remove_character_feat', 'choice.feat', null, '{"p_character_feat": "feat_row!", "p_reason": "text"}', 'Remove a feat', 46),
  ('set_character_feat_choices', 'set_character_feat_choices', 'choice.feat', 'p_character',
   '{"p_grant_key": "text!", "p_choices": "jsonb!"}', 'Feat choices', 47);


-- ---- derived stats: the feat layer (maximum HP with feat bonuses, feat summary) ---------------------------------------------
create function public._feat_layer(p_character uuid, d jsonb)
returns jsonb
language sql stable
set search_path = public, pg_temp
as $$
  select d || jsonb_build_object(
    'hit_points', coalesce(d -> 'hit_points', '{}'::jsonb) || public._feat_hp_bonus(p_character),
    'feats', (select coalesce(jsonb_agg(jsonb_build_object('feat_version_id', g.feat_version_id, 'name', fv.name, 'ruleset', fv.ruleset,
                'source_label', g.source_label, 'active', g.active, 'automation', fv.automation) order by g.ord, fv.name), '[]')
              from public._character_feat_grants(p_character) g join public.feat_versions fv on fv.id = g.feat_version_id));
$$;
grant execute on function public._feat_layer(uuid, jsonb) to authenticated;

-- ---- change requests: snapshot and baseline now include feats and the resolved maximum HP -----------------------------------
create or replace function public._cr_snapshot(p_character uuid)
returns jsonb
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
declare c public.characters; d jsonb; s jsonb; f jsonb; r jsonb; sl jsonb; b jsonb; sc jsonb; li jsonb; k text;
begin
  select * into c from public.characters where id = p_character;
  d := public._derived_stats_full(p_character);
  s := public.get_character_class_summary(p_character);
  f := public.get_character_class_features(p_character);
  r := public.get_character_resources(p_character);
  sl := public.get_character_spell_slots(p_character);
  b := public.get_character_spellbook(p_character);
  sc := jsonb_build_object(
    'Total level', coalesce((s ->> 'total_level')::int, c.level),
    'Proficiency bonus', (d -> 'proficiency_bonus' ->> 'value')::int,
    'Maximum HP', (public._feat_hp_bonus(p_character) ->> 'max')::int,
    'Armor Class', (d -> 'armor_class' ->> 'value')::int,
    'Speed', (d -> 'speed' ->> 'value')::int,
    'Initiative bonus', coalesce((d -> 'initiative' ->> 'bonus')::int, 0),
    'Lineage', d -> 'lineage' ->> 'name',
    'Background', d -> 'background' ->> 'name');
  foreach k in array array['str', 'dex', 'con', 'int', 'wis', 'cha'] loop
    sc := sc || jsonb_build_object(upper(k), (d -> 'abilities' -> k ->> 'score')::int);
  end loop;
  li := jsonb_build_object(
    'Classes', (select coalesce(jsonb_agg((x ->> 'class_name') || ' ' || (x ->> 'level')
                  || coalesce(' (' || coalesce(x ->> 'subclass_name', x -> 'subclass' ->> 'name') || ')', '') order by x ->> 'class_name'), '[]')
                from jsonb_array_elements(coalesce(s -> 'classes', '[]')) x),
    'Features', (select coalesce(jsonb_agg(distinct (k2 ->> 'class_name') || ': ' || (ft ->> 'name')), '[]')
                 from jsonb_array_elements(coalesce(f -> 'classes', '[]')) k2, jsonb_array_elements(coalesce(k2 -> 'features', '[]')) ft
                 where (ft ->> 'active')::boolean),
    'Resources', (select coalesce(jsonb_agg((x ->> 'name') || coalesce(' ' || (x ->> 'max'), '') order by x ->> 'name'), '[]')
                  from jsonb_array_elements(coalesce(r -> 'resources', '[]')) x where coalesce((x ->> 'active')::boolean, true)),
    'Spell slots', (select coalesce(jsonb_agg('Level ' || (x ->> 'slot_level') || ': ' || (x ->> 'max') order by (x ->> 'slot_level')::int), '[]')
                    from jsonb_array_elements(coalesce(sl -> 'standard', '[]')) x where (x ->> 'max')::int > 0)
                   || case when sl -> 'pact_magic' is not null and jsonb_typeof(sl -> 'pact_magic') = 'object'
                           then jsonb_build_array('Pact Magic: ' || coalesce(sl -> 'pact_magic' ->> 'max', '?') || ' × level '
                                                  || coalesce(sl -> 'pact_magic' ->> 'slot_level', '?')) else '[]'::jsonb end,
    'Spells', (select coalesce(jsonb_agg(distinct (x ->> 'name') || ' (' || (g ->> 'source_label') || ', '
                 || case when (g ->> 'always_prepared')::boolean then 'always prepared'
                         when g ->> 'preparation_mode' = 'spellbook' then 'spellbook'
                         when (g ->> 'innate')::boolean then 'innate' else 'known' end || ')'), '[]')
               from jsonb_array_elements(coalesce(b -> 'spells', '[]')) x, jsonb_array_elements(coalesce(x -> 'grants', '[]')) g
               where (g ->> 'known')::boolean or (g ->> 'always_prepared')::boolean or (g ->> 'innate')::boolean),
    'Skill proficiencies', (select coalesce(jsonb_agg(sk.name order by sk.name), '[]') from public.skills sk
                            where coalesce((d -> 'skills' -> sk.id ->> 'class_proficient')::boolean, false)
                               or coalesce((d -> 'skills' -> sk.id ->> 'lineage_proficient')::boolean, false)
                               or coalesce((d -> 'skills' -> sk.id ->> 'background_proficient')::boolean, false)
                               or public._skill_level(c.skill_proficiencies -> sk.id) >= 1),
    'Open choices', (select coalesce(jsonb_agg((x ->> 'class_name') || ': ' || (x ->> 'label')), '[]')
                     from jsonb_array_elements(coalesce(f -> 'incomplete_choices', '[]')) x),
    'Items', (select coalesce(jsonb_agg(coalesce(nullif(ii.custom_name, ''), ii.name) || case when ii.quantity > 1 then ' ×' || ii.quantity else '' end
                                        order by ii.name), '[]')
              from public.inventories inv join public.inventory_items ii on ii.inventory_id = inv.id
              where inv.character_id = p_character and inv.kind = 'character'),
    'Companions', (select coalesce(jsonb_agg(coalesce(nullif(cc.name, ''), cr.name) order by cc.name), '[]')
                   from public.character_companions cc left join public.creatures cr on cr.id = cc.creature_id where cc.character_id = p_character),
    'Feats', (select coalesce(jsonb_agg(fv.name || ' (' || fv.ruleset || ', ' || g.source_label || ')' order by fv.name), '[]')
              from public._character_feat_grants(p_character) g join public.feat_versions fv on fv.id = g.feat_version_id where g.active),
    'Open feat choices', (select coalesce(jsonb_agg(fv.name || ': ' || fc.label order by fv.name), '[]')
                          from public._character_feat_choice_values(p_character) fc join public.feat_versions fv on fv.id = fc.feat_version_id
                          join public._character_feat_grants(p_character) g on g.grant_key = fc.grant_key and g.active where not fc.complete and fc.open),
    'Seen forms', (select coalesce(jsonb_agg(cr.name order by cr.name), '[]')
                   from public.character_seen_forms sf join public.creatures cr on cr.id = sf.creature_id where sf.character_id = p_character));
  return jsonb_build_object('scalars', sc, 'lists', li);
end;
$$;

create or replace function public._cr_baseline(p_character uuid)
returns jsonb
language sql stable security definer
set search_path = public, pg_temp
as $$
  select jsonb_build_object(
    'classes', (select coalesce(jsonb_agg(cc.class_id || ':' || cc.class_version_id || ':' || cc.level || ':' || coalesce(cc.subclass_version_id, '-')
                                          order by cc.class_id), '[]') from public.character_classes cc where cc.character_id = p_character),
    'choices', (select count(*) from public.character_feature_choices x where x.character_id = p_character),
    'lineage', (select version_id || ':' || coalesce(subversion_id, '-') from public.character_lineages where character_id = p_character),
    'background', (select version_id from public.character_backgrounds where character_id = p_character),
    'abilities', (select jsonb_build_array(strength, dexterity, constitution, intelligence, wisdom, charisma) from public.characters where id = p_character),
    'hp_max', (select hp_max from public.characters where id = p_character),
    'known_spells', (select coalesce(jsonb_agg(cs.spell_version_id order by cs.spell_version_id), '[]') from public.character_spells cs
                     where cs.character_id = p_character and (cs.known or cs.always_prepared)),
    'proficiencies', (select count(*) from public.character_proficiencies p where p.character_id = p_character),
    'companions', (select count(*) from public.character_companions x where x.character_id = p_character),
    'feats', (select coalesce(jsonb_agg(g.grant_key || '=' || g.feat_version_id order by g.grant_key), '[]') from public._character_feat_grants(p_character) g),
    'feat_choices', (select count(*) from public.character_feat_choices x where x.character_id = p_character));
$$;

-- ---- RLS -------------------------------------------------------------------------------------------------------------------
create function public.can_view_feat_version(p_version text)
returns boolean
language sql stable security definer
set search_path = public, pg_temp
as $$ select exists (select 1 from public.feat_versions v where v.id = p_version and public.can_view_owned(v.owner_id, v.campaign_id)); $$;

drop policy "feat_versions_read" on public.feat_versions;
create policy "feat_versions_read" on public.feat_versions for select to anon, authenticated using (public.can_view_owned(owner_id, campaign_id));
alter table public.feats enable row level security;
create policy "feats_read" on public.feats for select to anon, authenticated using (public.can_view_owned(owner_id, campaign_id));
do $$
declare t text;
begin
  foreach t in array array['feat_prerequisites', 'feat_choices', 'feat_effects', 'feat_spell_grants', 'feat_resource_grants', 'feat_attack_grants'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from anon, authenticated', t);
    execute format('create policy "%1$s_read" on public.%1$I for select to anon, authenticated using (public.can_view_feat_version(version_id))', t);
    execute format('grant select on public.%I to anon, authenticated', t);
  end loop;
end $$;
alter table public.feat_choice_options enable row level security;
revoke all on public.feat_choice_options from anon, authenticated;
create policy "feat_choice_options_read" on public.feat_choice_options for select to anon, authenticated
  using (exists (select 1 from public.feat_choices c where c.id = choice_id and public.can_view_feat_version(c.version_id)));
grant select on public.feat_choice_options to anon, authenticated;
revoke all on public.feats, public.feat_versions from anon, authenticated;
grant select on public.feats, public.feat_versions to anon, authenticated;

alter table public.character_feats enable row level security;
alter table public.character_feat_choices enable row level security;
revoke all on public.character_feats, public.character_feat_choices from anon, authenticated;
create policy "character_feats_read" on public.character_feats for select to authenticated using (public.can_access_character(character_id));
create policy "character_feat_choices_read" on public.character_feat_choices for select to authenticated using (public.can_access_character(character_id));
grant select on public.character_feats, public.character_feat_choices to authenticated;
do $$
declare t text;
begin
  foreach t in array array['character_feats', 'character_feat_choices'] loop
    execute format('alter table public.%I replica identity full', t);
    if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t) then
      execute format('alter publication supabase_realtime add table public.%I', t);
    end if;
  end loop;
end $$;

revoke all on function public._character_feat_grants(uuid), public._character_feat_placeholders(uuid), public._character_feat_choice_values(uuid),
  public._feat_choice_value_error(public.feat_choices, text, text), public._feat_prereq_ctx(uuid), public._feat_prereq_eval(text, jsonb),
  public._character_feat_effects(uuid), public._feat_resource_key(text, text), public._sync_character_feats(uuid), public._feat_hp_bonus(uuid),
  public._feat_sync_trigger(), public._feat_pick_error(uuid, text, text, boolean), public._feat_version_json(text),
  public._store_feat_choices(uuid, text, text, jsonb, boolean)
  from public, anon, authenticated;
-- read by the (invoker) derived-stat functions on behalf of the reading user
grant execute on function public._character_feat_effects(uuid), public._character_feature_effects(uuid), public._feat_hp_bonus(uuid),
  public._character_feat_grants(uuid), public._character_feat_choice_values(uuid) to authenticated;
revoke all on function public.get_feat_detail(text), public.get_feat_catalog(uuid), public.get_character_feats(uuid),
  public.assign_character_feat(uuid, text, jsonb, text, text, text, text), public.remove_character_feat(uuid, text),
  public.set_character_feat_choices(uuid, text, jsonb), public.set_character_feat_notes(uuid, text),
  public.export_character_feats(uuid), public.import_character_feats(uuid, jsonb), public.can_view_feat_version(text)
  from public, anon;
grant execute on function public.get_feat_detail(text), public.get_feat_catalog(uuid), public.get_character_feats(uuid),
  public.assign_character_feat(uuid, text, jsonb, text, text, text, text), public.remove_character_feat(uuid, text),
  public.set_character_feat_choices(uuid, text, jsonb), public.set_character_feat_notes(uuid, text),
  public.export_character_feats(uuid), public.import_character_feats(uuid, jsonb), public.can_view_feat_version(text)
  to authenticated;
grant execute on function public.get_feat_detail(text), public.can_view_feat_version(text) to anon;

-- ---- rewritten functions (live definitions with exact replacements) ----------------------------------------

-- _background_version_json(text)
CREATE OR REPLACE FUNCTION public._background_version_json(p_version text)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select to_jsonb(v) || jsonb_build_object(
    'background_name', b.name,
    'source_book', (select name from public.source_books where id = v.source_book_id),
    'also_in_books', (select coalesce(jsonb_agg(name order by name), '[]') from public.source_books where id = any (v.also_in)),
    'abilities', (select coalesce(jsonb_agg(a.ability order by array_position(array['str','dex','con','int','wis','cha'], a.ability)), '[]')
                  from public.background_ability_options a where a.version_id = v.id),
    'grants', (select coalesce(jsonb_agg(jsonb_build_object('kind', g.kind, 'id', g.target_id,
                 'name', coalesce(sk.name, it.name, lg.name, g.target_id)) order by g.kind, g.seq), '[]')
               from public.background_proficiency_grants g
               left join public.skills sk on g.kind = 'skill' and sk.id = g.target_id
               left join public.items it on g.kind = 'tool' and it.id = g.target_id
               left join public.languages lg on g.kind = 'language' and lg.id = g.target_id
               where g.version_id = v.id),
    'choices', (select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'key', c.key, 'kind', c.kind, 'label', c.label, 'count', c.pick_count,
                  'grants_proficiency', c.grants_proficiency, 'config', c.config,
                  'options', (select coalesce(jsonb_agg(jsonb_build_object('kind', o.option_kind, 'id', o.option_id,
                                'name', coalesce(sk.name, it.name, lg.name, o.option_id)) order by o.option_kind, coalesce(sk.name, it.name, lg.name, o.option_id)), '[]')
                              from public.background_choice_options o
                              left join public.skills sk on o.option_kind = 'skill' and sk.id = o.option_id
                              left join public.items it on o.option_kind = 'tool' and it.id = o.option_id
                              left join public.languages lg on o.option_kind = 'language' and lg.id = o.option_id
                              where o.choice_id = c.id)) order by c.sort_order), '[]')
                from public.background_choices c where c.version_id = v.id),
    'feat', (select jsonb_build_object('id', f.id, 'name', f.name, 'parameter', fg.parameter, 'note', fg.note, 'category', f.category,
               'status', f.status, 'summary', f.summary, 'url', f.source_url, 'automation', f.automation, 'implementation_note', f.implementation_note)
             from public.background_feat_grants fg join public.feat_versions f on f.id = fg.feat_id where fg.version_id = v.id),
    'features', (select coalesce(jsonb_agg(jsonb_build_object('key', x.key, 'name', x.name, 'summary', x.summary, 'automation', x.automation)), '[]')
                 from public.background_features x where x.version_id = v.id),
    'equipment', (select coalesce(jsonb_agg(jsonb_build_object('key', p.key, 'label', p.label, 'coins', p.coins,
                    'entries', (select coalesce(jsonb_agg(jsonb_build_object('seq', e.seq, 'item_id', e.item_id, 'name', coalesce(it.name, e.label),
                                  'label', e.label, 'quantity', e.quantity, 'from_choice', e.from_choice, 'category_id', e.category_id, 'note', e.note,
                                  'resolved', e.item_id is not null or e.from_choice is not null or e.category_id is not null) order by e.seq), '[]')
                                from public.background_equipment_entries e left join public.items it on it.id = e.item_id where e.package_id = p.id))
                    order by p.sort_order), '[]')
                  from public.background_equipment_packages p where p.version_id = v.id),
    'characteristics', (select coalesce(jsonb_agg(jsonb_build_object('key', t.key, 'label', t.label, 'die', t.die, 'kind', t.kind,
                          'entry_labels', t.entry_labels) order by t.sort_order), '[]')
                        from public.background_characteristic_tables t where t.version_id = v.id))
  from public.background_versions v join public.backgrounds b on b.id = v.background_id
  where v.id = p_version;
$function$;

-- get_background_catalog()
CREATE OR REPLACE FUNCTION public.get_background_catalog()
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select jsonb_build_object(
    'versions', coalesce((select jsonb_agg(public._background_version_json(v.id) order by v.ruleset desc, b.sort_order, v.sort_order)
                          from public.background_versions v join public.backgrounds b on b.id = v.background_id), '[]'),
    'feats', coalesce((select jsonb_agg(to_jsonb(f) order by f.name) from public.feat_versions f where f.owner_id is null), '[]'));
$function$;

-- _character_effects(uuid)
CREATE OR REPLACE FUNCTION public._character_effects(p_character uuid)
 RETURNS TABLE(source_type text, source_id uuid, item_id text, source_name text, modifier_id text, seq integer, effect_type text, value numeric, target text, activation text, stacking text, stack_group text, scope text, active boolean, inactive_reason text, applied boolean)
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
  with owned as (
    select ii.id, ii.item_id, ii.is_attuned and public._item_active_in_form(p_character, ii.id) as is_attuned,
           coalesce(ii.custom_name, it.name) as name, it.kind_id, it.requires_attunement, e.slot_id
    from public.inventories inv
    join public.inventory_items ii on ii.inventory_id = inv.id
    join public.items it on it.id = ii.item_id                       -- RLS: effects of invisible items do not exist
    left join public.character_equipment e on e.inventory_item_id = ii.id and e.character_id = p_character
      and public._item_active_in_form(p_character, ii.id)              -- merged or dropped in Wild Shape: no effect
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
    from public._character_feature_effects(p_character) ce
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
$function$;

-- _derived_stats_full(uuid)
CREATE OR REPLACE FUNCTION public._derived_stats_full(p_character uuid)
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
  from public._character_feature_effects(p_character) x where x.feature_active;
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
    if man >= 1 or (coalesce((skills -> k ->> 'lineage_proficient')::boolean, false) or coalesce((skills -> k ->> 'background_proficient')::boolean, false)) or coalesce((skills -> k ->> 'class_proficient')::boolean, false) then
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

-- _proficiency_match(uuid,text,text,text)
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
     from public._character_feature_effects(p_character) e
     where e.effect_type = 'proficiency' and e.active
       and ((e.target in ('weapon', 'armor', 'tool') and e.value_text in (p_item, p_base_item))
            or (e.target = 'group' and e.value_text = p_group))
     limit 1),
    (select jsonb_build_object('proficient', true, 'matched_by', 'background', 'source_type', 'background', 'item_id', g.target_id)
     from public._character_background_grants(p_character) g
     where g.kind = 'tool' and g.target_id in (p_item, p_base_item) limit 1),
    jsonb_build_object('proficient', false, 'missing_group_id', p_group,
                       'missing_group_name', (select name from public.proficiency_groups where id = p_group)));
$function$;

-- get_character_derived_stats(uuid)
CREATE OR REPLACE FUNCTION public.get_character_derived_stats(p_character uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$ select public._wild_shape_layer(p_character, public._feat_layer(p_character, public._derived_stats_full(p_character))) $function$;

-- _cf_choice_error(uuid,uuid,text,class_feature_choices,text[],integer,boolean)
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
          if not (man >= 1 or (coalesce((d -> 'skills' -> v ->> 'lineage_proficient')::boolean, false) or coalesce((d -> 'skills' -> v ->> 'background_proficient')::boolean, false))
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
          if public._feat_pick_error(p_character, substr(v, 6), 'asi:' || p_character_class || ':' || p_unlock || ':' || p_choice.id) is not null then
            return public._feat_pick_error(p_character, substr(v, 6), 'asi:' || p_character_class || ':' || p_unlock || ':' || p_choice.id);
          end if;   -- feat catalog (20261019000300)
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
