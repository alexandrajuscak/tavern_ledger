-- =============================================================================
-- DM content: custom campaign content with a draft -> published -> archived lifecycle (docs/CUSTOM_CONTENT_LIFECYCLE.md,
-- DM_SPACE.md, CUSTOM_SPELLS.md, CUSTOM_ITEMS.md, CUSTOM_FEATS.md, CUSTOM_CREATURES.md, CUSTOM_COMPANIONS.md).
--
-- dm_content (identity, type, author DM, campaign or the DM's private library) -> dm_content_versions (the editable
-- document of one version: player-facing text, DM-only notes, the typed definition, validation) -> on publish the version
-- is MATERIALIZED into the existing typed catalog of its type, scoped to the campaign:
--   spell      catalog_spells + spell_versions + spell_effects + class list entries   (cc-<id>-v<n>)
--   item       items + typed stats via the homebrew writer (_write_homebrew)            (cc-<id>-v<n>)
--   feat       feats + feat_versions + choices / effects / spells / resources            (cc-<id>-v<n>)
--   creature   creatures (Wild Shape form only after a DM grant)                         (cc-<id>-v<n>)
--   companion  creatures (companion_eligible) + the template in the version definition
--   background backgrounds + background_versions + ability / feat / proficiency / feature / equipment rows
--   lineage    lineages + lineage_versions + traits + trait effects + choices
--   condition  stays in dm_content_versions (assigned through character conditions, 20261019000500)
-- Published versions are never edited: new mechanics = a new version (new catalog row); characters keep the version they
-- have. Archiving hides a version from new assignment; existing references stay valid. Only DMs (and admins) write here;
-- players never read these tables (they read the materialized catalog rows and get_content_public_info).
-- Rollback: supabase/rollback/rollback_dm_content.sql.
-- =============================================================================

-- ---- catalog extensions -----------------------------------------------------------------------------------------------
alter table public.creatures drop constraint creatures_content_scope_check;
alter table public.creatures add constraint creatures_content_scope_check check (content_scope in ('official', 'test', 'campaign'));
alter table public.creatures
  add column owner_id uuid references public.profiles (id) on delete restrict,
  add column campaign_id uuid references public.campaigns (id) on delete cascade,
  add column wild_shape_eligible boolean not null default true,
  add column companion_eligible boolean not null default false,
  add column archived_at timestamptz,
  add column content_version_id uuid;
alter table public.spell_versions alter column source_url drop not null;
alter table public.spell_versions drop constraint spell_versions_source_url_check;
alter table public.spell_versions add constraint spell_versions_source_url_check check (source_url is null or source_url ~ '^https://');
alter table public.spell_versions add column archived_at timestamptz, add column content_version_id uuid;
alter table public.items add column content_version_id uuid;
-- campaign spells may join class lists (provenance campaign_custom, no source page)
alter table public.class_spell_list_entries alter column source_url drop not null;
do $$
declare c text;
begin
  select conname into c from pg_constraint where conrelid = 'public.class_spell_list_entries'::regclass and contype = 'c' and pg_get_constraintdef(oid) like '%provenance%';
  execute format('alter table public.class_spell_list_entries drop constraint %I', c);
end $$;
alter table public.class_spell_list_entries add constraint class_spell_list_entries_provenance_check
  check (provenance in ('class_page', 'spell_page', 'both', 'campaign_custom'));
alter table public.feat_versions add column content_version_id uuid;
alter table public.backgrounds add column owner_id uuid references public.profiles (id) on delete restrict,
  add column campaign_id uuid references public.campaigns (id) on delete cascade;
alter table public.background_versions add column owner_id uuid references public.profiles (id) on delete restrict,
  add column campaign_id uuid references public.campaigns (id) on delete cascade, add column archived_at timestamptz, add column content_version_id uuid;
alter table public.background_versions alter column source_url drop not null;
alter table public.background_versions drop constraint background_versions_status_check;
alter table public.background_versions add constraint background_versions_status_check check (status in ('official', 'playtest', 'homebrew'));
-- campaign homebrew is published by the DM, so it needs no extra DM-permission flag (playtest versions still do)
alter table public.background_versions drop constraint background_versions_check;
alter table public.background_versions add constraint background_versions_check
  check (status in ('official', 'homebrew') or (dm_permission and not enabled_by_default));
alter table public.lineages add column owner_id uuid references public.profiles (id) on delete restrict,
  add column campaign_id uuid references public.campaigns (id) on delete cascade;
alter table public.lineages alter column source_url drop not null;
alter table public.lineages drop constraint lineages_source_url_check;
alter table public.lineages add constraint lineages_source_url_check check (source_url is null or source_url ~ '^https://');
alter table public.lineage_versions add column owner_id uuid references public.profiles (id) on delete restrict,
  add column campaign_id uuid references public.campaigns (id) on delete cascade, add column archived_at timestamptz, add column content_version_id uuid;
alter table public.lineage_versions alter column source_url drop not null;
alter table public.lineage_versions drop constraint lineage_versions_source_url_check;
alter table public.lineage_versions add constraint lineage_versions_source_url_check check (source_url is null or source_url ~ '^https://');
alter table public.character_companions add column template_version_id uuid;

-- visibility helpers of the catalogs that gain campaign rows
create function public.can_view_background_version(p_version text)
returns boolean language sql stable security definer set search_path = public, pg_temp
as $$ select exists (select 1 from public.background_versions v where v.id = p_version and (v.owner_id is null or public.can_view_owned(v.owner_id, v.campaign_id))); $$;
create function public.can_view_lineage_version(p_version text)
returns boolean language sql stable security definer set search_path = public, pg_temp
as $$ select exists (select 1 from public.lineage_versions v where v.id = p_version and (v.owner_id is null or public.can_view_owned(v.owner_id, v.campaign_id))); $$;
create function public.can_view_lineage_trait(p_trait text)
returns boolean language sql stable security definer set search_path = public, pg_temp
as $$ select exists (select 1 from public.lineage_traits t where t.id = p_trait and public.can_view_lineage_version(t.version_id)); $$;
grant execute on function public.can_view_background_version(text), public.can_view_lineage_version(text), public.can_view_lineage_trait(text) to anon, authenticated;

drop policy "creatures_read" on public.creatures;
create policy "creatures_read" on public.creatures for select to anon, authenticated using (owner_id is null or public.can_view_owned(owner_id, campaign_id));
drop policy "class_spell_list_entries_read" on public.class_spell_list_entries;
create policy "class_spell_list_entries_read" on public.class_spell_list_entries for select to anon, authenticated
  using (spell_version_id not like 'cc-%' or exists (select 1 from public.spell_versions v where v.id = spell_version_id and public.can_view_spell(v.spell_id)));
drop policy "backgrounds_read" on public.backgrounds;
create policy "backgrounds_read" on public.backgrounds for select to anon, authenticated using (owner_id is null or public.can_view_owned(owner_id, campaign_id));
drop policy "background_versions_read" on public.background_versions;
create policy "background_versions_read" on public.background_versions for select to anon, authenticated using (owner_id is null or public.can_view_owned(owner_id, campaign_id));
drop policy "lineages_read" on public.lineages;
create policy "lineages_read" on public.lineages for select to anon, authenticated using (owner_id is null or public.can_view_owned(owner_id, campaign_id));
drop policy "lineage_versions_read" on public.lineage_versions;
create policy "lineage_versions_read" on public.lineage_versions for select to anon, authenticated using (owner_id is null or public.can_view_owned(owner_id, campaign_id));
do $$
declare t text;
begin
  foreach t in array array['background_ability_options', 'background_feat_grants', 'background_proficiency_grants', 'background_features',
                           'background_equipment_packages'] loop
    execute format('drop policy "%1$s_read" on public.%1$I', t);
    execute format('create policy "%1$s_read" on public.%1$I for select to anon, authenticated using (version_id not like ''cc-%%'' or public.can_view_background_version(version_id))', t);
  end loop;
  foreach t in array array['lineage_traits', 'lineage_choices'] loop
    execute format('drop policy "%1$s_read" on public.%1$I', t);
    execute format('create policy "%1$s_read" on public.%1$I for select to anon, authenticated using (version_id not like ''cc-%%'' or public.can_view_lineage_version(version_id))', t);
  end loop;
end $$;
drop policy "lineage_trait_effects_read" on public.lineage_trait_effects;
create policy "lineage_trait_effects_read" on public.lineage_trait_effects for select to anon, authenticated
  using (trait_id not like 'cc-%' or public.can_view_lineage_trait(trait_id));
drop policy "background_equipment_entries_read" on public.background_equipment_entries;
create policy "background_equipment_entries_read" on public.background_equipment_entries for select to anon, authenticated
  using (package_id not like 'cc-%' or exists (select 1 from public.background_equipment_packages p where p.id = package_id and public.can_view_background_version(p.version_id)));

-- ---- registry ------------------------------------------------------------------------------------------------------------
create table public.dm_content (
  id                   uuid primary key default gen_random_uuid(),
  content_type         text not null check (content_type in ('spell', 'item', 'feat', 'creature', 'companion', 'background', 'lineage', 'condition')),
  author_id            uuid not null references public.profiles (id) on delete restrict,
  campaign_id          uuid references public.campaigns (id) on delete cascade,       -- null: the author's private library
  scope                text not null default 'campaign' check (scope in ('private', 'campaign', 'shared')),   -- shared: reserved
  name                 text not null check (length(name) between 1 and 80),
  status               text not null default 'draft'
                         check (status in ('draft', 'validation_failed', 'ready_for_review', 'published', 'revised', 'archived')),
  current_version_id   uuid,                 -- the version being edited (or the published one)
  published_version_id uuid,                 -- the newest published version
  icon                 text check (length(icon) <= 40),
  tags                 text[] not null default '{}',
  request_id           uuid,                 -- idempotency key of the create request
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now(),
  published_at         timestamptz,
  archived_at          timestamptz,
  unique (author_id, request_id),
  check ((campaign_id is null) = (scope = 'private'))
);
create index dm_content_campaign on public.dm_content (campaign_id, content_type);

create table public.dm_content_versions (
  id                     uuid primary key default gen_random_uuid(),
  content_id             uuid not null references public.dm_content (id) on delete cascade,
  version_no             int not null check (version_no >= 1),
  status                 text not null default 'draft'
                           check (status in ('draft', 'validation_failed', 'ready_for_review', 'published', 'superseded', 'archived')),
  name                   text not null check (length(name) between 1 and 80),
  summary                text not null default '' check (length(summary) <= 400),     -- player-facing, concise
  player_text            text not null default '' check (length(player_text) <= 4000),
  dm_notes               text not null default '' check (length(dm_notes) <= 4000),    -- DM-only
  ruleset                text check (ruleset in ('2014', '2024')),
  definition             jsonb not null default '{}' check (jsonb_typeof(definition) = 'object'),
  validation             jsonb,
  catalog_ref            text,                                                         -- the materialized catalog id
  revision               int not null default 1,
  created_by             uuid references public.profiles (id) on delete set null,
  created_at             timestamptz not null default now(),
  updated_at             timestamptz not null default now(),
  published_at           timestamptz,
  published_by           uuid references public.profiles (id) on delete set null,
  archived_at            timestamptz,
  replacement_version_id uuid references public.dm_content_versions (id) on delete set null,
  unique (content_id, version_no)
);
alter table public.dm_content add constraint dm_content_current_fkey foreign key (current_version_id) references public.dm_content_versions (id) on delete set null,
  add constraint dm_content_published_fkey foreign key (published_version_id) references public.dm_content_versions (id) on delete set null;
alter table public.character_companions add constraint character_companions_template_fkey
  foreign key (template_version_id) references public.dm_content_versions (id) on delete restrict;

create table public.dm_content_events (
  id         uuid primary key default gen_random_uuid(),
  content_id uuid not null references public.dm_content (id) on delete cascade,
  version_id uuid references public.dm_content_versions (id) on delete set null,
  actor_id   uuid references public.profiles (id) on delete set null,
  event      text not null check (event in ('created', 'saved', 'validated', 'validation_failed', 'published', 'new_version', 'archived',
                                              'restored', 'duplicated', 'deleted', 'assigned', 'copied')),
  detail     jsonb,
  created_at timestamptz not null default now()
);

create function public._dm_can_manage(p_content uuid)
returns boolean
language sql stable security definer
set search_path = public, pg_temp
as $$
  select exists (select 1 from public.dm_content c where c.id = p_content and auth.uid() is not null
                 and (public.is_admin() or c.author_id = auth.uid() and (c.campaign_id is null or public.is_campaign_dm(c.campaign_id))
                      or (c.campaign_id is not null and public.is_campaign_dm(c.campaign_id))));
$$;

-- ---- definitions --------------------------------------------------------------------------------------------------------
create function public._dm_short(p_content uuid)
returns text language sql immutable set search_path = public, pg_temp
as $$ select 'cc-' || substr(replace(p_content::text, '-', ''), 1, 10) $$;

-- materialize one version into its catalog (inside the caller's transaction); returns the catalog id
create function public._dm_materialize(p_version uuid)
returns text
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare v public.dm_content_versions; c public.dm_content; d jsonb; base text; ref text; e jsonb; n int; x text; owner uuid;
  camp uuid; pkg text; ch jsonb; chid text; s jsonb; r jsonb;
begin
  select * into v from public.dm_content_versions where id = p_version;
  select * into c from public.dm_content where id = v.content_id;
  d := v.definition; base := public._dm_short(c.id); ref := base || '-v' || v.version_no; owner := c.author_id; camp := c.campaign_id;
  if camp is null then raise exception 'Copy the content to a campaign before publishing it' using errcode = '22023'; end if;
  case c.content_type
  when 'spell' then
    insert into public.catalog_spells (id, name, owner_id, campaign_id) values (base, v.name, owner, camp)
    on conflict (id) do update set name = excluded.name;
    insert into public.spell_versions (id, spell_id, name, level, school_id, casting_time_raw, casting_time_unit, casting_time_amount,
      reaction_trigger, range_raw, range_type, range_distance, range_unit, area_shape, area_size, duration_raw, duration_type,
      duration_amount, duration_unit, requires_concentration, is_ritual, components_raw, has_verbal_component, has_somatic_component,
      has_material_component, material_text, material_cost_gp, material_consumed, components_parse_status, mechanism, attack_type,
      save_ability, has_higher_levels, automation, source_label, source_url, status, rule_status, parse_notes, content_version_id)
    values (ref, base, v.name, (d ->> 'level')::int, d ->> 'school',
      coalesce(d -> 'casting_time' ->> 'raw', coalesce(d -> 'casting_time' ->> 'amount', '1') || ' ' || replace(coalesce(d -> 'casting_time' ->> 'unit', 'action'), '_', ' ')),
      coalesce(d -> 'casting_time' ->> 'unit', 'action'), coalesce((d -> 'casting_time' ->> 'amount')::int, 1), d ->> 'reaction_trigger',
      coalesce(d -> 'range' ->> 'raw', case d -> 'range' ->> 'type' when 'distance' then (d -> 'range' ->> 'distance') || ' ' || coalesce(d -> 'range' ->> 'unit', 'feet')
                                         else initcap(coalesce(d -> 'range' ->> 'type', 'self')) end),
      coalesce(d -> 'range' ->> 'type', 'self'), (d -> 'range' ->> 'distance')::int, d -> 'range' ->> 'unit',
      d -> 'area' ->> 'shape', (d -> 'area' ->> 'size')::int,
      coalesce(d -> 'duration' ->> 'raw', case d -> 'duration' ->> 'type' when 'timed' then (d -> 'duration' ->> 'amount') || ' ' || (d -> 'duration' ->> 'unit') || 's'
                                             else initcap(replace(coalesce(d -> 'duration' ->> 'type', 'instantaneous'), '_', ' ')) end),
      coalesce(d -> 'duration' ->> 'type', 'instantaneous'), (d -> 'duration' ->> 'amount')::int, d -> 'duration' ->> 'unit',
      coalesce((d ->> 'concentration')::boolean, false), coalesce((d ->> 'ritual')::boolean, false),
      concat_ws(', ', case when coalesce((d -> 'components' ->> 'v')::boolean, false) then 'V' end,
                      case when coalesce((d -> 'components' ->> 's')::boolean, false) then 'S' end,
                      case when coalesce((d -> 'components' ->> 'm')::boolean, false) then 'M' || coalesce(' (' || (d -> 'components' ->> 'material') || ')', '') end),
      coalesce((d -> 'components' ->> 'v')::boolean, false), coalesce((d -> 'components' ->> 's')::boolean, false),
      coalesce((d -> 'components' ->> 'm')::boolean, false), d -> 'components' ->> 'material', (d -> 'components' ->> 'cost_gp')::numeric,
      coalesce((d -> 'components' ->> 'consumed')::boolean, false), 'parsed',
      case when d ->> 'attack_type' is not null then 'attack' when d ->> 'save_ability' is not null then 'save' else 'automatic' end,
      d ->> 'attack_type', d ->> 'save_ability', nullif(d ->> 'higher_levels', '') is not null,
      case when jsonb_array_length(coalesce(d -> 'effects', '[]')) > 0 then 'partially_automated' else 'informational' end,
      'Campaign custom', null, 'current', 'homebrew', nullif(d ->> 'higher_levels', ''), v.id);
    n := 0;
    for e in select x2 from jsonb_array_elements(coalesce(d -> 'effects', '[]')) x2 loop
      n := n + 1;
      insert into public.spell_effects (version_id, seq, category, mechanism, timing, dice, flat_modifier, adds_spell_mod, damage_mode,
        half_on_save, scaling_type, scaling_dice, scaling_base, automation, notes)
      values (ref, n, coalesce(e ->> 'category', 'damage'),
        case when d ->> 'attack_type' is not null then 'attack' when d ->> 'save_ability' is not null then 'save' else 'automatic' end,
        coalesce(e ->> 'timing', case when d ->> 'attack_type' is not null then 'on_hit' when d ->> 'save_ability' is not null then 'on_failed_save' else 'on_cast' end),
        e ->> 'dice', coalesce((e ->> 'flat')::int, 0), coalesce((e ->> 'adds_spell_mod')::boolean, false), 'single',
        coalesce((e ->> 'half_on_save')::boolean, false), coalesce(e -> 'scaling' ->> 'type', 'none'), e -> 'scaling' ->> 'dice',
        (e -> 'scaling' ->> 'base')::int, 'automated', e ->> 'notes');
      for x in select jsonb_array_elements_text(coalesce(e -> 'damage_types', '[]')) loop
        insert into public.spell_effect_damage_types (version_id, seq, damage_type_id) values (ref, n, x);
      end loop;
    end loop;
    for x in select jsonb_array_elements_text(coalesce(d -> 'class_lists', '[]')) loop
      insert into public.class_spell_list_entries (list_id, spell_version_id, spell_level, is_optional, provenance, notes)
      values (x, ref, (d ->> 'level')::int, false, 'campaign_custom', 'Added by the DM of ' || (select name from public.campaigns where id = camp));
    end loop;
  when 'item' then
    perform public._write_homebrew(ref, coalesce(d -> 'item', '{}') || jsonb_build_object('campaign_id', camp, 'name', v.name,
                                   'description', coalesce(nullif(v.player_text, ''), d -> 'item' ->> 'description')),
                                   coalesce(d -> 'stats', '{}'), true);
    update public.items set content_version_id = v.id, source_label = 'Campaign custom', owner_id = owner where id = ref;
  when 'feat' then
    insert into public.feats (id, name, owner_id, campaign_id) values (base, v.name, owner, camp) on conflict (id) do update set name = excluded.name;
    insert into public.feat_versions (id, feat_id, name, category, ruleset, status, summary, automation, implementation_note, source_label,
      min_level, repeatable, max_count, distinct_choice_key, prerequisite_text, tags, owner_id, campaign_id, content_version_id)
    values (ref, base, v.name, coalesce(d ->> 'category', 'general'), coalesce(v.ruleset, '2024'), 'homebrew', left(v.summary, 400),
      case when jsonb_array_length(coalesce(d -> 'effects', '[]')) + jsonb_array_length(coalesce(d -> 'choices', '[]')) = 0 then 'informational'
           when exists (select 1 from jsonb_array_elements(coalesce(d -> 'effects', '[]')) e2 where e2 ->> 'type' = 'informational') then 'partially_automated'
           else 'automated' end,
      'Campaign custom feat', 'Campaign custom', (d ->> 'min_level')::int, coalesce(d ->> 'repeatable', 'once'), (d ->> 'max_count')::int,
      d ->> 'distinct_choice', d ->> 'prerequisite_text', array(select jsonb_array_elements_text(coalesce(d -> 'tags', '[]'))), owner, camp, v.id);
    n := 0;
    for e in select x2 from jsonb_array_elements(coalesce(d -> 'prerequisites', '[]')) x2 loop
      n := n + 1;
      insert into public.feat_prerequisites (version_id, seq, grp, kind, target, value, label)
      values (ref, n, coalesce((e ->> 'group')::int, n), e ->> 'kind', e ->> 'target', e ->> 'value', coalesce(e ->> 'label', e ->> 'kind'));
    end loop;
    n := 0;
    for ch in select x2 from jsonb_array_elements(coalesce(d -> 'choices', '[]')) x2 loop
      n := n + 1; chid := ref || ':' || (ch ->> 'key');
      insert into public.feat_choices (id, version_id, key, kind, label, min_picks, max_picks, config, seq)
      values (chid, ref, ch ->> 'key', ch ->> 'kind', coalesce(ch ->> 'label', ch ->> 'key'), coalesce((ch ->> 'min')::int, 1),
              coalesce((ch ->> 'max')::int, 1), coalesce(ch -> 'config', '{}'), n);
      insert into public.feat_choice_options (choice_id, option_id, label, data, seq)
      select chid, o ->> 'id', coalesce(o ->> 'label', o ->> 'id'), coalesce(o -> 'data', '{}'), ord::int
      from jsonb_array_elements(coalesce(ch -> 'options', '[]')) with ordinality o2(o, ord);
    end loop;
    n := 0;
    for e in select x2 from jsonb_array_elements(coalesce(d -> 'effects', '[]')) x2 loop
      n := n + 1;
      insert into public.feat_effects (version_id, seq, effect_type, target, value, value_text, choice_key, activation, automation, conditions, data, label)
      values (ref, n, e ->> 'type', e ->> 'target', (e ->> 'value')::numeric, e ->> 'value_text', e ->> 'choice', coalesce(e ->> 'activation', 'passive'),
              case when e ->> 'type' = 'informational' then 'informational' else coalesce(e ->> 'automation', 'automated') end,
              coalesce(e -> 'conditions', '{}'), coalesce(e -> 'data', '{}'), e ->> 'label');
    end loop;
    n := 0;
    for s in select x2 from jsonb_array_elements(coalesce(d -> 'spells', '[]')) x2 loop
      n := n + 1;
      insert into public.feat_spell_grants (version_id, seq, spell_version_id, choice_key, mode, ability, ability_choice_key, uses, uses_slots, label)
      values (ref, n, s ->> 'spell', s ->> 'choice', coalesce(s ->> 'mode', 'known'), s ->> 'ability', s ->> 'ability_choice',
              coalesce(s ->> 'uses', 'at_will'), coalesce((s ->> 'uses_slots')::boolean, false), coalesce(s ->> 'label', v.name));
    end loop;
    for r in select x2 from jsonb_array_elements(coalesce(d -> 'resources', '[]')) x2 loop
      insert into public.feat_resource_grants (version_id, key, name, max_formula, recharge)
      values (ref, r ->> 'key', r ->> 'name', coalesce(r -> 'max', '{"fixed": 1}'), coalesce(r ->> 'recharge', 'long_rest'));
    end loop;
  when 'creature', 'companion' then
    s := case when c.content_type = 'companion' then coalesce(d -> 'creature', '{}') else d end;
    insert into public.creatures (id, name, size, creature_type, subtype, alignment, armor_class, armor_type, hit_points, hit_dice, speed,
      abilities, saving_throws, skills, senses, languages, challenge_rating, xp, proficiency_bonus, damage_vulnerabilities,
      damage_resistances, damage_immunities, condition_immunities, traits, actions, reactions, content_scope, source_label, license,
      mechanics_status, mechanics_notes, owner_id, campaign_id, wild_shape_eligible, companion_eligible, content_version_id)
    values (ref, v.name, coalesce(s ->> 'size', 'Medium'), coalesce(s ->> 'creature_type', 'beast'), s ->> 'subtype', s ->> 'alignment',
      (s ->> 'armor_class')::int, s ->> 'armor_type', (s ->> 'hit_points')::int, s ->> 'hit_dice', coalesce(s -> 'speed', '{"walk": 30}'),
      s -> 'abilities', coalesce(s -> 'saving_throws', '{}'), coalesce(s -> 'skills', '{}'), coalesce(s -> 'senses', '{}'), s ->> 'languages',
      coalesce((s ->> 'challenge_rating')::numeric, 0), (s ->> 'xp')::int,
      coalesce((s ->> 'proficiency_bonus')::int, greatest(2, (coalesce((s ->> 'challenge_rating')::numeric, 0)::int - 1) / 4 + 2)),
      array(select jsonb_array_elements_text(coalesce(s -> 'damage_vulnerabilities', '[]'))), array(select jsonb_array_elements_text(coalesce(s -> 'damage_resistances', '[]'))),
      array(select jsonb_array_elements_text(coalesce(s -> 'damage_immunities', '[]'))), array(select jsonb_array_elements_text(coalesce(s -> 'condition_immunities', '[]'))),
      coalesce(s -> 'traits', '[]'), coalesce(s -> 'actions', '[]'), coalesce(s -> 'reactions', '[]'),
      'campaign', 'Campaign custom', 'Campaign content', 'complete', nullif(v.summary, ''), owner, camp,
      c.content_type = 'creature' and coalesce((d ->> 'wild_shape_eligible')::boolean, true),
      c.content_type = 'companion' or coalesce((d ->> 'companion_eligible')::boolean, false), v.id);
  when 'background' then
    insert into public.backgrounds (id, name, sort_order, owner_id, campaign_id) values (base, v.name, 900, owner, camp)
    on conflict (id) do update set name = excluded.name;
    insert into public.background_versions (id, background_id, name, ruleset, rules_label, status, source_label, source_url,
      dm_permission, enabled_by_default, duplicate_rule, sort_order, owner_id, campaign_id, content_version_id)
    values (ref, base, v.name, coalesce(v.ruleset, '2024'), case when coalesce(v.ruleset, '2024') = '2024' then '2024 (Campaign custom)' else 'Legacy (Campaign custom)' end,
      'homebrew', 'Campaign custom', null, false, true,
      coalesce(d ->> 'duplicate_rule', (select x.duplicate_rule from public.background_versions x where x.ruleset = coalesce(v.ruleset, '2024') and x.status = 'official'
                                         order by x.id limit 1), 'A duplicate proficiency is kept.'), 900, owner, camp, v.id);
    for x in select jsonb_array_elements_text(coalesce(d -> 'abilities', '[]')) loop
      insert into public.background_ability_options (version_id, ability) values (ref, x);
    end loop;
    if d ? 'feat' then
      insert into public.background_feat_grants (version_id, feat_id, parameter) values (ref, d ->> 'feat', d ->> 'feat_parameter');
    end if;
    n := 0;
    for x in select jsonb_array_elements_text(coalesce(d -> 'skills', '[]')) loop
      n := n + 1; insert into public.background_proficiency_grants (version_id, kind, target_id, seq) values (ref, 'skill', x, n);
    end loop;
    for x in select jsonb_array_elements_text(coalesce(d -> 'tools', '[]')) loop
      n := n + 1; insert into public.background_proficiency_grants (version_id, kind, target_id, seq) values (ref, 'tool', x, n);
    end loop;
    for x in select jsonb_array_elements_text(coalesce(d -> 'languages', '[]')) loop
      n := n + 1; insert into public.background_proficiency_grants (version_id, kind, target_id, seq) values (ref, 'language', x, n);
    end loop;
    if d ? 'feature' then
      insert into public.background_features (version_id, key, name, summary, automation)
      values (ref, 'feature', d -> 'feature' ->> 'name', coalesce(d -> 'feature' ->> 'summary', ''), 'informational');
    end if;
    if jsonb_array_length(coalesce(d -> 'equipment', '[]')) > 0 or d ? 'gold' then
      pkg := ref || ':A';
      insert into public.background_equipment_packages (id, version_id, key, label, coins, sort_order)
      values (pkg, ref, 'A', 'Equipment', coalesce(d -> 'equipment_coins', '{}'), 1);
      n := 0;
      for e in select x2 from jsonb_array_elements(coalesce(d -> 'equipment', '[]')) x2 loop
        n := n + 1;
        insert into public.background_equipment_entries (package_id, seq, item_id, quantity, label)
        values (pkg, n, e ->> 'item_id', coalesce((e ->> 'quantity')::int, 1), coalesce(e ->> 'label', e ->> 'item_id'));
      end loop;
      if d ? 'gold' then
        insert into public.background_equipment_packages (id, version_id, key, label, coins, sort_order)
        values (ref || ':B', ref, 'B', (d ->> 'gold') || ' GP', jsonb_build_object('gp', (d ->> 'gold')::int), 2);
      end if;
    end if;
  when 'lineage' then
    insert into public.lineages (id, category_id, name, summary, sort_order, owner_id, campaign_id)
    values (base, 'exotic', v.name, nullif(v.summary, ''), 900, owner, camp) on conflict (id) do update set name = excluded.name;
    insert into public.lineage_versions (id, lineage_id, kind, name, source_label, source_url, status, creature_type, summary, sort_order,
                                         owner_id, campaign_id, content_version_id)
    values (ref, base, 'base', v.name, 'Campaign custom', null, 'current', coalesce(d ->> 'creature_type', 'humanoid'), nullif(v.summary, ''), 900,
            owner, camp, v.id);
    n := 0;
    for e in select x2 from jsonb_array_elements(coalesce(d -> 'traits', '[]')) x2 loop
      n := n + 1; x := ref || '-t' || n;
      insert into public.lineage_traits (id, version_id, name, summary, automation, min_level, sort_order)
      values (x, ref, e ->> 'name', coalesce(e ->> 'summary', ''), case when jsonb_array_length(coalesce(e -> 'effects', '[]')) > 0 then 'automatic' else 'informational' end,
              coalesce((e ->> 'min_level')::int, 1), n);
      insert into public.lineage_trait_effects (trait_id, seq, effect_type, target, value, value_text, min_level, data)
      select x, ord::int, f ->> 'type',
             case when f ->> 'type' in ('resistance', 'immunity', 'condition_immunity', 'language') then null else f ->> 'target' end,
             (f ->> 'value')::numeric,
             case when f ->> 'type' in ('resistance', 'immunity', 'condition_immunity', 'language') then coalesce(f ->> 'value_text', f ->> 'target') else f ->> 'value_text' end,
             coalesce((f ->> 'min_level')::int, 1), coalesce(f -> 'data', '{}')
      from jsonb_array_elements(coalesce(e -> 'effects', '[]')) with ordinality f2(f, ord);
    end loop;
    if d ? 'ability_patterns' then
      insert into public.lineage_choices (id, version_id, kind, label, pick_count, required, config, sort_order)
      values (ref || ':asi', ref, 'ability_scores', 'Ability Score Increases', coalesce((d ->> 'ability_picks')::int, 2), true,
              jsonb_build_object('patterns', d -> 'ability_patterns'), 1);
    end if;
    if coalesce((d ->> 'feat_choice')::boolean, false) then
      insert into public.lineage_choices (id, version_id, kind, label, pick_count, required, config, sort_order)
      values (ref || ':feat', ref, 'feat', 'Feat', 1, false, '{"hint": "A feat from the feat catalog."}', 2);
    end if;
  when 'condition' then
    ref := v.id::text;                 -- conditions are assigned by version id (20261019000500)
  end case;
  update public.dm_content_versions set catalog_ref = ref where id = p_version;
  return ref;
end;
$$;

-- the catalog read model of a materialized version (what a player will see)
create function public._dm_catalog_json(p_type text, p_ref text)
returns jsonb
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
begin
  return case p_type
    when 'spell' then public.get_spell_detail(p_ref)
    when 'item' then (select to_jsonb(i) from public.v_item_catalog i where i.id = p_ref)
    when 'feat' then public._feat_version_json(p_ref)
    when 'creature' then (select to_jsonb(c) - 'owner_id' from public.creatures c where c.id = p_ref)
    when 'companion' then (select to_jsonb(c) - 'owner_id' from public.creatures c where c.id = p_ref)
    when 'background' then public._background_version_json(p_ref)
    when 'lineage' then (select to_jsonb(v) - 'owner_id' || jsonb_build_object('traits', (select coalesce(jsonb_agg(to_jsonb(t) || jsonb_build_object('effects',
                           (select coalesce(jsonb_agg(to_jsonb(e)), '[]') from public.lineage_trait_effects e where e.trait_id = t.id)) order by t.sort_order), '[]')
                           from public.lineage_traits t where t.version_id = v.id)) from public.lineage_versions v where v.id = p_ref)
    else null end;
end;
$$;

-- validate (and preview) by materializing inside a sub-transaction that is always rolled back
create function public._dm_try(p_version uuid)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare ref text; prev jsonb; err text; t text; v public.dm_content_versions; errors jsonb := '[]'; warnings jsonb := '[]'; d jsonb;
begin
  select * into v from public.dm_content_versions where id = p_version;
  select content_type into t from public.dm_content where id = v.content_id;
  d := v.definition;
  -- structural checks with friendly messages (the catalog constraints catch the rest)
  if t = 'spell' then
    if (d ->> 'level') is null then errors := errors || '["Choose the spell level (0 for a cantrip)."]'; end if;
    if (d ->> 'school') is null then errors := errors || '["Choose the school of magic."]'; end if;
    if jsonb_array_length(coalesce(d -> 'class_lists', '[]')) = 0 then warnings := warnings || '["No class spell list: the spell can only be assigned directly."]'; end if;
  elsif t in ('creature', 'companion') then
    if coalesce((case when t = 'companion' then d -> 'creature' else d end) ->> 'armor_class', '') = '' then errors := errors || '["Armor Class is required."]'; end if;
    if coalesce((case when t = 'companion' then d -> 'creature' else d end) ->> 'hit_points', '') = '' then errors := errors || '["Hit points are required."]'; end if;
    if (case when t = 'companion' then d -> 'creature' else d end) -> 'abilities' is null then errors := errors || '["All six ability scores are required."]'; end if;
    if t = 'creature' and coalesce((d ->> 'wild_shape_eligible')::boolean, true) and jsonb_array_length(coalesce(d -> 'actions', '[]')) = 0 then
      warnings := warnings || '["A Wild Shape form without actions has no attacks in the form sheet."]';
    end if;
  elsif t = 'background' then
    if coalesce(v.ruleset, '2024') = '2024' and jsonb_array_length(coalesce(d -> 'abilities', '[]')) <> 3 then errors := errors || '["A 2024 background lists exactly three abilities."]'; end if;
    if coalesce(v.ruleset, '2024') = '2024' and not d ? 'feat' then errors := errors || '["A 2024 background grants an Origin feat."]'; end if;
    if coalesce(v.ruleset, '2024') = '2014' and (d ? 'abilities' or d ? 'feat') then errors := errors || '["Legacy (2014) backgrounds have no ability increases or Origin feat; use a 2024 background."]'; end if;
  elsif t = 'feat' then
    if exists (select 1 from jsonb_array_elements(coalesce(d -> 'choices', '[]')) c2 where coalesce(c2 ->> 'key', '') = '') then errors := errors || '["Every choice needs a key."]'; end if;
  elsif t = 'condition' then
    if coalesce(d ->> 'category', '') = '' then warnings := warnings || '["No category: shown under Other."]'; end if;
  end if;
  if jsonb_array_length(errors) > 0 then
    return jsonb_build_object('ok', false, 'errors', errors, 'warnings', warnings);
  end if;
  begin
    -- a version that was never published has no catalog row yet: materialize it under a temporary number
    ref := public._dm_materialize(p_version);
    prev := public._dm_catalog_json(t, ref);
    raise exception 'dm preview rollback' using errcode = 'TLPRV';
  exception
    when sqlstate 'TLPRV' then null;
    when others then err := sqlerrm;
  end;
  if err is not null then
    return jsonb_build_object('ok', false, 'errors', jsonb_build_array(err), 'warnings', warnings);
  end if;
  return jsonb_build_object('ok', true, 'errors', '[]'::jsonb, 'warnings', warnings, 'preview', prev, 'catalog_ref_preview', ref);
end;
$$;

-- ---- usage --------------------------------------------------------------------------------------------------------------
create function public._dm_usage(p_content uuid)
returns jsonb
language sql stable security definer
set search_path = public, pg_temp
as $$
  with refs as (select v.id, v.catalog_ref from public.dm_content_versions v where v.content_id = p_content and v.catalog_ref is not null),
  t as (select content_type from public.dm_content where id = p_content)
  select jsonb_build_object(
    'characters', (select count(distinct x.cid) from (
        select cs.character_id as cid from public.character_spells cs join refs on refs.catalog_ref = cs.spell_version_id
        union all select ii.character_id from public.inventory_items ii join refs on refs.catalog_ref = ii.item_id
        union all select inv.character_id from public.inventory_items ii join public.inventories inv on inv.id = ii.inventory_id join refs on refs.catalog_ref = ii.item_id
        union all select cf.character_id from public.character_feats cf join refs on refs.catalog_ref = cf.feat_version_id
        union all select ch.character_id from public.character_feature_choice_values fv join public.character_feature_choices ch on ch.id = fv.character_choice_id
                  join refs on 'feat:' || refs.catalog_ref = fv.value
        union all select lc.character_id from public.character_lineage_choices lc join refs on 'feat:' || refs.catalog_ref = lc.value
        union all select sf.character_id from public.character_seen_forms sf join refs on refs.catalog_ref = sf.creature_id
        union all select cc.character_id from public.character_companions cc join refs on refs.catalog_ref = cc.creature_id or refs.id = cc.template_version_id
        union all select ct.character_id from public.character_transformations ct join refs on refs.catalog_ref = ct.creature_id
        union all select cb.character_id from public.character_backgrounds cb join refs on refs.catalog_ref = cb.version_id
        union all select cl.character_id from public.character_lineages cl join refs on refs.catalog_ref = cl.version_id) x where x.cid is not null),
    'stash_items', (select count(*) from public.inventory_items ii join public.inventories inv on inv.id = ii.inventory_id join refs on refs.catalog_ref = ii.item_id
                    where inv.kind <> 'character'),
    'backgrounds_granting', (select count(*) from public.background_feat_grants g join refs on refs.catalog_ref = g.feat_id),
    'pending_requests', (select count(*) from public.change_requests r, refs where r.status in ('draft', 'submitted', 'returned_for_changes')
                         and r.ops::text like '%' || refs.catalog_ref || '%'),
    'by_version', (select coalesce(jsonb_object_agg(refs.catalog_ref, (
        (select count(*) from public.character_spells cs where cs.spell_version_id = refs.catalog_ref)
        + (select count(*) from public.inventory_items ii where ii.item_id = refs.catalog_ref)
        + (select count(*) from public.character_feats cf where cf.feat_version_id = refs.catalog_ref)
        + (select count(*) from public.character_seen_forms sf where sf.creature_id = refs.catalog_ref)
        + (select count(*) from public.character_companions cc where cc.creature_id = refs.catalog_ref)
        + (select count(*) from public.character_backgrounds cb where cb.version_id = refs.catalog_ref)
        + (select count(*) from public.character_lineages cl where cl.version_id = refs.catalog_ref))), '{}') from refs));
$$;

-- ---- lifecycle RPCs ------------------------------------------------------------------------------------------------------
create function public._dm_content_json(p_content uuid)
returns jsonb
language sql stable security definer
set search_path = public, pg_temp
as $$
  select to_jsonb(c) || jsonb_build_object(
    'campaign_name', (select name from public.campaigns where id = c.campaign_id),
    'author_name', (select coalesce(display_name, email) from public.profiles where id = c.author_id),
    'versions', (select coalesce(jsonb_agg(to_jsonb(v) order by v.version_no desc), '[]') from public.dm_content_versions v where v.content_id = c.id),
    'usage', public._dm_usage(c.id),
    'history', (select coalesce(jsonb_agg(jsonb_build_object('event', e.event, 'at', e.created_at, 'detail', e.detail,
                  'actor', (select coalesce(display_name, email) from public.profiles where id = e.actor_id)) order by e.created_at desc), '[]')
                from (select * from public.dm_content_events where content_id = c.id order by created_at desc limit 30) e))
  from public.dm_content c where c.id = p_content;
$$;

create function public._dm_event(p_content uuid, p_version uuid, p_event text, p_detail jsonb default null)
returns void language sql security definer set search_path = public, pg_temp
as $$ insert into public.dm_content_events (content_id, version_id, actor_id, event, detail) values (p_content, p_version, auth.uid(), p_event, p_detail); $$;

-- p_fields: name, summary, player_text, dm_notes, ruleset, definition, icon, tags
create function public.create_dm_content(p_type text, p_campaign uuid, p_fields jsonb, p_request_id uuid default null)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare cid uuid; vid uuid; existing uuid; nm text := btrim(coalesce(p_fields ->> 'name', ''));
begin
  if p_type not in ('spell', 'item', 'feat', 'creature', 'companion', 'background', 'lineage', 'condition') then
    raise exception 'Unknown content type' using errcode = '22023';
  end if;
  perform public._gov_content_gate(p_campaign, 'content.create_' || case p_type when 'creature' then 'creature' when 'companion' then 'companion' else p_type end);
  if auth.uid() is null then raise exception 'Not signed in' using errcode = '42501'; end if;
  if nm = '' then raise exception 'Give it a name' using errcode = '22023'; end if;
  if p_request_id is not null then
    select id into existing from public.dm_content where author_id = auth.uid() and request_id = p_request_id;
    if existing is not null then return public._dm_content_json(existing); end if;
  end if;
  insert into public.dm_content (content_type, author_id, campaign_id, scope, name, icon, tags, request_id)
  values (p_type, auth.uid(), p_campaign, case when p_campaign is null then 'private' else 'campaign' end, left(nm, 80), p_fields ->> 'icon',
          array(select jsonb_array_elements_text(coalesce(p_fields -> 'tags', '[]'))), p_request_id)
  returning id into cid;
  insert into public.dm_content_versions (content_id, version_no, name, summary, player_text, dm_notes, ruleset, definition, created_by)
  values (cid, 1, left(nm, 80), left(coalesce(p_fields ->> 'summary', ''), 400), left(coalesce(p_fields ->> 'player_text', ''), 4000),
          left(coalesce(p_fields ->> 'dm_notes', ''), 4000), p_fields ->> 'ruleset', coalesce(p_fields -> 'definition', '{}'), auth.uid())
  returning id into vid;
  update public.dm_content set current_version_id = vid where id = cid;
  perform public._dm_event(cid, vid, 'created');
  return public._dm_content_json(cid);
end;
$$;

-- save the editable version (draft / validation_failed / ready_for_review); a published version is never edited in place
create function public.save_dm_content(p_content uuid, p_fields jsonb, p_expected_revision int default null)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare c public.dm_content; v public.dm_content_versions;
begin
  if not public._dm_can_manage(p_content) then raise exception 'Only the DM who manages this content can change it' using errcode = '42501'; end if;
  select * into c from public.dm_content where id = p_content for update;
  select * into v from public.dm_content_versions where id = c.current_version_id for update;
  if v.status in ('published', 'superseded', 'archived') then
    raise exception 'Published content is not edited in place. Create a new version to change its mechanics.' using errcode = 'TLPUB';
  end if;
  if p_expected_revision is not null and p_expected_revision <> v.revision then
    raise exception 'Someone else saved this draft meanwhile. Reload it.' using errcode = '40001';
  end if;
  update public.dm_content_versions set
    name = coalesce(left(nullif(btrim(p_fields ->> 'name'), ''), 80), name),
    summary = coalesce(left(p_fields ->> 'summary', 400), summary),
    player_text = coalesce(left(p_fields ->> 'player_text', 4000), player_text),
    dm_notes = coalesce(left(p_fields ->> 'dm_notes', 4000), dm_notes),
    ruleset = case when p_fields ? 'ruleset' then p_fields ->> 'ruleset' else ruleset end,
    definition = coalesce(p_fields -> 'definition', definition),
    status = 'draft', validation = null, revision = revision + 1, updated_at = now()
  where id = v.id;
  update public.dm_content set name = (select name from public.dm_content_versions where id = v.id),
    status = case when status in ('published', 'revised') then 'revised' else 'draft' end,
    icon = coalesce(p_fields ->> 'icon', icon), updated_at = now() where id = p_content;
  perform public._dm_event(p_content, v.id, 'saved');
  return public._dm_content_json(p_content);
end;
$$;

create function public.validate_dm_content(p_content uuid)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare c public.dm_content; res jsonb;
begin
  if not public._dm_can_manage(p_content) then raise exception 'Content not found' using errcode = '42501'; end if;
  select * into c from public.dm_content where id = p_content for update;
  res := public._dm_try(c.current_version_id);
  update public.dm_content_versions set validation = res,
    status = case when status in ('published', 'superseded', 'archived') then status when (res ->> 'ok')::boolean then 'ready_for_review' else 'validation_failed' end
  where id = c.current_version_id;
  update public.dm_content set status = case when status in ('published', 'archived') then status
                                             when (res ->> 'ok')::boolean then 'ready_for_review' else 'validation_failed' end, updated_at = now()
  where id = p_content;
  perform public._dm_event(p_content, c.current_version_id, case when (res ->> 'ok')::boolean then 'validated' else 'validation_failed' end, res - 'preview');
  return public._dm_content_json(p_content) || jsonb_build_object('validation', res);
end;
$$;

-- publish the current version to the content's campaign (exactly once: the row lock serializes two publishes)
create function public.publish_dm_content(p_content uuid, p_expected_version uuid default null)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare c public.dm_content; v public.dm_content_versions; res jsonb; ref text; prev public.dm_content_versions;
begin
  if not public._dm_can_manage(p_content) then raise exception 'Content not found' using errcode = '42501'; end if;
  select * into c from public.dm_content where id = p_content for update;
  perform public._gov_content_gate(c.campaign_id, 'content.publish');
  if c.campaign_id is null then raise exception 'Copy this private content to a campaign to publish it' using errcode = '22023'; end if;
  select * into v from public.dm_content_versions where id = c.current_version_id for update;
  if p_expected_version is not null and p_expected_version <> v.id then
    raise exception 'A different version is current now. Reload.' using errcode = '40001';
  end if;
  if v.status = 'published' then raise exception 'This version is already published' using errcode = 'TLPUB'; end if;
  if v.status = 'archived' then raise exception 'This version is archived' using errcode = 'TLPUB'; end if;
  res := public._dm_try(v.id);
  if not (res ->> 'ok')::boolean then
    update public.dm_content_versions set validation = res, status = 'validation_failed' where id = v.id;
    raise exception 'Fix these problems before publishing: %', (select string_agg(x, ' ') from jsonb_array_elements_text(res -> 'errors') x)
      using errcode = '22023';
  end if;
  ref := public._dm_materialize(v.id);
  -- the previously published version stays for the characters that use it, hidden from new picks
  if c.published_version_id is not null then
    select * into prev from public.dm_content_versions where id = c.published_version_id;
    update public.dm_content_versions set status = 'superseded', replacement_version_id = v.id where id = prev.id;
    perform public._dm_set_catalog_archived(c.content_type, prev.catalog_ref, true, ref);
  end if;
  update public.dm_content_versions set status = 'published', validation = res - 'preview', published_at = now(), published_by = auth.uid()
  where id = v.id;
  update public.dm_content set status = 'published', published_version_id = v.id, published_at = now(), archived_at = null, updated_at = now()
  where id = p_content;
  perform public._dm_event(p_content, v.id, 'published', jsonb_build_object('catalog_ref', ref));
  perform public._audit(c.campaign_id, null, 'content_published', 'Published ' || c.content_type || ': ' || v.name || ' (version ' || v.version_no || ')',
                        null, jsonb_build_object('catalog_ref', ref), null, null, 'party');
  return public._dm_content_json(p_content);
end;
$$;

-- hide / show a catalog row for new picks (existing references keep working)
create function public._dm_set_catalog_archived(p_type text, p_ref text, p_archived boolean, p_replacement text default null)
returns void
language plpgsql security definer
set search_path = public, pg_temp
as $$
begin
  if p_ref is null then return; end if;
  case p_type
    when 'spell' then update public.spell_versions set archived_at = case when p_archived then now() end, superseded_by_version_id = coalesce(p_replacement, superseded_by_version_id) where id = p_ref;
    when 'item' then update public.items set archived_at = case when p_archived then now() end, archived_by = auth.uid() where id = p_ref;
    when 'feat' then update public.feat_versions set archived_at = case when p_archived then now() end, replacement_version_id = coalesce(p_replacement, replacement_version_id) where id = p_ref;
    when 'creature', 'companion' then update public.creatures set archived_at = case when p_archived then now() end where id = p_ref;
    when 'background' then update public.background_versions set archived_at = case when p_archived then now() end where id = p_ref;
    when 'lineage' then update public.lineage_versions set archived_at = case when p_archived then now() end, superseded_by_version_id = coalesce(p_replacement, superseded_by_version_id) where id = p_ref;
    else null;
  end case;
end;
$$;

-- a new draft version from the published (or current) one
create function public.new_dm_content_version(p_content uuid)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare c public.dm_content; v public.dm_content_versions; vid uuid;
begin
  if not public._dm_can_manage(p_content) then raise exception 'Content not found' using errcode = '42501'; end if;
  select * into c from public.dm_content where id = p_content for update;
  select * into v from public.dm_content_versions where id = c.current_version_id;
  if v.status not in ('published', 'superseded', 'archived') then
    raise exception 'The current version is still a draft; edit it directly' using errcode = '22023';
  end if;
  insert into public.dm_content_versions (content_id, version_no, name, summary, player_text, dm_notes, ruleset, definition, created_by)
  values (c.id, (select max(version_no) + 1 from public.dm_content_versions where content_id = c.id), v.name, v.summary, v.player_text, v.dm_notes,
          v.ruleset, v.definition, auth.uid())
  returning id into vid;
  update public.dm_content set current_version_id = vid, status = 'revised', updated_at = now() where id = p_content;
  perform public._dm_event(p_content, vid, 'new_version');
  return public._dm_content_json(p_content);
end;
$$;

create function public.archive_dm_content(p_content uuid, p_reason text default null)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare c public.dm_content; v public.dm_content_versions;
begin
  if not public._dm_can_manage(p_content) then raise exception 'Content not found' using errcode = '42501'; end if;
  select * into c from public.dm_content where id = p_content for update;
  perform public._gov_content_gate(c.campaign_id, 'content.archive');
  for v in select * from public.dm_content_versions where content_id = c.id and status in ('published', 'superseded') loop
    perform public._dm_set_catalog_archived(c.content_type, v.catalog_ref, true);
  end loop;
  update public.dm_content_versions set status = 'archived', archived_at = now() where content_id = c.id and status = 'published';
  update public.dm_content set status = 'archived', archived_at = now(), updated_at = now() where id = p_content;
  perform public._dm_event(p_content, c.published_version_id, 'archived', jsonb_build_object('reason', p_reason));
  if c.campaign_id is not null then
    perform public._audit(c.campaign_id, null, 'content_archived', 'Archived ' || c.content_type || ': ' || c.name, null, null, p_reason, null, 'party');
  end if;
  return public._dm_content_json(p_content);
end;
$$;

create function public.restore_dm_content(p_content uuid)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare c public.dm_content; v public.dm_content_versions;
begin
  if not public._dm_can_manage(p_content) then raise exception 'Content not found' using errcode = '42501'; end if;
  select * into c from public.dm_content where id = p_content for update;
  if c.status <> 'archived' then raise exception 'Only archived content can be restored' using errcode = '22023'; end if;
  select * into v from public.dm_content_versions where id = c.published_version_id;
  if v.id is not null then
    perform public._dm_set_catalog_archived(c.content_type, v.catalog_ref, false);
    update public.dm_content_versions set status = 'published', archived_at = null where id = v.id;
  end if;
  update public.dm_content set status = case when v.id is null then 'draft' else 'published' end, archived_at = null, updated_at = now() where id = p_content;
  perform public._dm_event(p_content, v.id, 'restored');
  return public._dm_content_json(p_content);
end;
$$;

-- duplicate as a new draft (optionally into a campaign: "copy my private content to Campaign A")
create function public.duplicate_dm_content(p_content uuid, p_campaign uuid default null, p_keep_campaign boolean default true)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare c public.dm_content; v public.dm_content_versions; camp uuid; nid uuid; nv uuid;
begin
  if not public._dm_can_manage(p_content) then raise exception 'Content not found' using errcode = '42501'; end if;
  select * into c from public.dm_content where id = p_content;
  select * into v from public.dm_content_versions where id = c.current_version_id;
  camp := case when p_campaign is not null then p_campaign when p_keep_campaign then c.campaign_id end;
  perform public._gov_content_gate(camp, 'content.create_' || c.content_type);
  insert into public.dm_content (content_type, author_id, campaign_id, scope, name, icon, tags)
  values (c.content_type, auth.uid(), camp, case when camp is null then 'private' else 'campaign' end,
          left(case when p_campaign is null then v.name || ' (copy)' else v.name end, 80), c.icon, c.tags)
  returning id into nid;
  insert into public.dm_content_versions (content_id, version_no, name, summary, player_text, dm_notes, ruleset, definition, created_by)
  values (nid, 1, left(case when p_campaign is null then v.name || ' (copy)' else v.name end, 80), v.summary, v.player_text, v.dm_notes, v.ruleset, v.definition, auth.uid())
  returning id into nv;
  update public.dm_content set current_version_id = nv where id = nid;
  perform public._dm_event(nid, nv, case when p_campaign is null then 'duplicated' else 'copied' end, jsonb_build_object('from', p_content));
  return public._dm_content_json(nid);
end;
$$;

-- only content that was never published and is referenced by nothing can be deleted
create function public.delete_dm_content(p_content uuid)
returns void
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare c public.dm_content;
begin
  if not public._dm_can_manage(p_content) then raise exception 'Content not found' using errcode = '42501'; end if;
  select * into c from public.dm_content where id = p_content for update;
  if c.author_id <> auth.uid() and not public.is_admin() then raise exception 'Only the author can delete a draft' using errcode = '42501'; end if;
  if exists (select 1 from public.dm_content_versions where content_id = p_content and catalog_ref is not null) then
    raise exception 'Published content is never deleted. Archive it instead.' using errcode = 'TLPUB';
  end if;
  delete from public.dm_content where id = p_content;
end;
$$;

create function public.get_dm_content(p_content uuid)
returns jsonb
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
begin
  if not public._dm_can_manage(p_content) then raise exception 'Content not found' using errcode = '42501'; end if;
  return public._dm_content_json(p_content);
end;
$$;

create function public.preview_dm_content(p_content uuid)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare c public.dm_content; v public.dm_content_versions;
begin
  if not public._dm_can_manage(p_content) then raise exception 'Content not found' using errcode = '42501'; end if;
  select * into c from public.dm_content where id = p_content;
  select * into v from public.dm_content_versions where id = c.current_version_id;
  if v.catalog_ref is not null then
    return jsonb_build_object('ok', true, 'errors', '[]'::jsonb, 'warnings', '[]'::jsonb, 'preview', public._dm_catalog_json(c.content_type, v.catalog_ref),
                              'player_view', jsonb_build_object('name', v.name, 'summary', v.summary, 'player_text', v.player_text));
  end if;
  return public._dm_try(v.id) || jsonb_build_object('player_view', jsonb_build_object('name', v.name, 'summary', v.summary, 'player_text', v.player_text));
end;
$$;

-- the DM library of a campaign (+ the caller's private library)
create function public.get_dm_content_library(p_campaign uuid default null, p_type text default null, p_include_archived boolean default true)
returns jsonb
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
begin
  if auth.uid() is null or not public.can_author_content(p_campaign) then raise exception 'Only a DM can open the content library' using errcode = '42501'; end if;
  return (select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'content_type', c.content_type, 'name', c.name, 'status', c.status,
             'scope', c.scope, 'campaign_id', c.campaign_id, 'icon', c.icon, 'tags', to_jsonb(c.tags), 'updated_at', c.updated_at,
             'published_at', c.published_at, 'archived_at', c.archived_at,
             'version_no', (select version_no from public.dm_content_versions where id = c.current_version_id),
             'published_version_no', (select version_no from public.dm_content_versions where id = c.published_version_id),
             'summary', (select summary from public.dm_content_versions where id = c.current_version_id),
             'catalog_ref', (select catalog_ref from public.dm_content_versions where id = c.published_version_id),
             'usage_characters', (public._dm_usage(c.id) ->> 'characters')::int,
             'mine', c.author_id = auth.uid()) order by c.content_type, lower(c.name)), '[]')
          from public.dm_content c
          where ((p_campaign is not null and c.campaign_id = p_campaign) or (c.campaign_id is null and c.author_id = auth.uid()))
            and (p_type is null or c.content_type = p_type) and (p_include_archived or c.status <> 'archived'));
end;
$$;

-- what members of the campaign may read about a version (no DM notes, no hidden definition parts)
create function public.get_content_public_info(p_version uuid)
returns jsonb
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
declare v public.dm_content_versions; c public.dm_content;
begin
  select * into v from public.dm_content_versions where id = p_version;
  select * into c from public.dm_content where id = v.content_id;
  if v.id is null or auth.uid() is null or v.status not in ('published', 'superseded', 'archived')
     or not (public.is_admin() or public.is_campaign_member(c.campaign_id)) then
    raise exception 'Content not found' using errcode = 'P0002';
  end if;
  return jsonb_build_object('id', v.id, 'content_type', c.content_type, 'name', v.name, 'summary', v.summary, 'player_text', v.player_text,
    'version_no', v.version_no, 'archived', v.status <> 'published', 'catalog_ref', v.catalog_ref,
    'definition', case when c.content_type in ('condition', 'companion') then v.definition - 'hidden' - 'dm' else null end);
end;
$$;

-- ---- assignment -----------------------------------------------------------------------------------------------------------
-- One DM flow for every type. p_mode by type:
--   spell     known | spellbook | always_prepared | innate       (options.source_id: a spellcasting source of the character)
--   item      inventory | stash                                    (options.quantity, options.identified, options.custom_name)
--   feat      dm_grant | campaign_reward                           (options.choices)
--   creature  seen_form | companion                                (options.name)
--   companion companion                                            (options.name, options.hp_max)
--   background / lineage  direct                                   (options: the arguments of set_character_background / _lineage)
--   condition visible | hidden                                     (options.expires_at, options.note)  -> 20261019000500
-- Returns {results: [{character_id, ok, error}]}; every character is applied in its own sub-transaction.
create function public.dm_assign_content(p_content uuid, p_characters uuid[], p_mode text, p_options jsonb default '{}')
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare c public.dm_content; v public.dm_content_versions; ch uuid; out jsonb := '[]'; err text; src uuid; inv uuid; camp uuid; o jsonb := coalesce(p_options, '{}');
begin
  if not public._dm_can_manage(p_content) then raise exception 'Content not found' using errcode = '42501'; end if;
  select * into c from public.dm_content where id = p_content;
  if c.campaign_id is null then raise exception 'Private library content is assigned after copying it to a campaign' using errcode = '22023'; end if;
  if not public.is_campaign_dm(c.campaign_id) and not public.is_admin() then raise exception 'Only a DM of the campaign assigns its content' using errcode = '42501'; end if;
  select * into v from public.dm_content_versions where id = c.published_version_id for share;
  if v.id is null or c.status = 'archived' or v.status <> 'published' then
    raise exception 'Only published, not archived content can be assigned' using errcode = 'TLPUB';
  end if;
  foreach ch in array coalesce(p_characters, '{}') loop
    err := null;
    begin
      select campaign_id into camp from public.characters where id = ch;
      if camp is distinct from c.campaign_id then raise exception 'The character is not in this campaign'; end if;
      case c.content_type
        when 'spell' then
          src := nullif(o ->> 'source_id', '')::uuid;
          if src is null then
            select id into src from public.character_spellcasting_sources where character_id = ch and source_type = 'other' and label = 'Campaign gifts';
            if src is null and p_mode in ('innate', 'known') then
              insert into public.character_spellcasting_sources (character_id, source_type, label, casting_ability, preparation_mode, uses_spell_slots, notes, created_by)
              values (ch, 'other', 'Campaign gifts', coalesce(o ->> 'casting_ability', 'cha'), 'innate', true, 'Spells granted by the DM.', auth.uid())
              returning id into src;
            end if;
          end if;
          if src is null then raise exception 'Choose the spellcasting source for this spell'; end if;
          perform public.set_character_spell(ch, src, v.catalog_ref, true, p_mode = 'always_prepared', p_mode = 'always_prepared',
                                             o ->> 'casting_ability', null, 'Granted by the DM');
        when 'item' then
          if p_mode = 'stash' then
            select id into inv from public.inventories where campaign_id = c.campaign_id and kind = 'party_stash' order by created_at limit 1;
            if inv is null then raise exception 'This campaign has no party stash'; end if;
          else
            select id into inv from public.inventories where character_id = ch and kind = 'character' order by created_at limit 1;
          end if;
          perform public._dm_add_item(inv, v.catalog_ref, coalesce((o ->> 'quantity')::int, 1), o ->> 'custom_name',
                                      coalesce((o ->> 'identified')::boolean, true), v.id);
        when 'feat' then
          perform public.assign_character_feat(ch, v.catalog_ref, coalesce(o -> 'choices', '{}'),
                                               case when p_mode = 'campaign_reward' then 'campaign_reward' else 'dm_grant' end, o ->> 'note');
        when 'creature' then
          if p_mode = 'companion' then
            perform public.add_character_companion(ch, v.catalog_ref, o ->> 'name', 'dm_grant', (o ->> 'hp_max')::int);
          else
            perform public.set_seen_forms(ch, array[v.catalog_ref], true, 'dm_grant', coalesce(o ->> 'note', 'Granted by the DM'));
          end if;
        when 'companion' then
          perform public.add_character_companion(ch, v.catalog_ref, coalesce(o ->> 'name', v.name), 'dm_grant',
                                                 coalesce((o ->> 'hp_max')::int, (v.definition -> 'creature' ->> 'hit_points')::int));
          update public.character_companions set template_version_id = v.id
          where id = (select id from public.character_companions where character_id = ch and creature_id = v.catalog_ref order by created_at desc limit 1);
        when 'background' then
          perform public.set_character_background(ch, v.catalog_ref, o -> 'ability', coalesce(o -> 'choices', '{}'), '[]', '{}');
        when 'lineage' then
          perform public.set_character_lineage(ch, v.catalog_ref, null, coalesce(o -> 'choices', '{}'), false, false);
        when 'condition' then
          perform public.apply_character_condition(ch, v.id, null, p_mode = 'hidden', (o ->> 'expires_at')::timestamptz, o ->> 'note');
      end case;
      perform public._dm_event(p_content, v.id, 'assigned', jsonb_build_object('character_id', ch, 'mode', p_mode));
      perform public._audit(c.campaign_id, ch, case c.content_type when 'item' then 'item_assigned' when 'spell' then 'spell_learned'
                                                 when 'feat' then 'feat_added' else 'content_assigned' end,
                            'Assigned ' || c.content_type || ': ' || v.name, null, jsonb_build_object('catalog_ref', v.catalog_ref, 'mode', p_mode),
                            null, null, case when c.content_type = 'condition' and p_mode = 'hidden' then 'dm' else 'party' end);
    exception when others then
      err := sqlerrm;
    end;
    out := out || jsonb_build_array(jsonb_build_object('character_id', ch, 'ok', err is null, 'error', err));
  end loop;
  return jsonb_build_object('content_id', p_content, 'version_id', v.id, 'results', out);
end;
$$;


-- ---- items and conditions: plain versions (20261019000500 replaces both with the hidden-data aware ones) ------------------
create function public._dm_add_item(p_inventory uuid, p_item text, p_quantity int, p_custom_name text, p_identified boolean, p_version uuid)
returns uuid
language plpgsql security definer
set search_path = public, pg_temp
as $$ begin return public.add_inventory_item(p_inventory, p_item, greatest(coalesce(p_quantity, 1), 1), p_custom_name); end; $$;

create function public.apply_character_condition(p_character uuid, p_version uuid, p_name text, p_hidden boolean, p_expires timestamptz, p_note text)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$ begin raise exception 'Character conditions need migration 20261019000500' using errcode = '0A000'; end; $$;
revoke all on function public._dm_add_item(uuid, text, int, text, boolean, uuid) from public, anon, authenticated;
revoke all on function public.apply_character_condition(uuid, uuid, text, boolean, timestamptz, text) from public, anon;

-- ---- gate helpers: archived catalog rows are not assignable any more (existing references stay valid) -----------------------
create or replace function public._gov_gate_spell(p_character uuid, p_source uuid, p_spell_version text, p_known boolean,
                                       p_prepared boolean, p_always_prepared boolean, p_casting_ability text,
                                       p_ritual_allowed boolean)
returns void
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
declare r public.character_spells; s public.character_spellcasting_sources; v public.spell_versions; cs public.catalog_spells;
begin
  select * into s from public.character_spellcasting_sources where id = p_source and character_id = p_character;
  select * into r from public.character_spells where source_id = p_source and spell_version_id = p_spell_version;
  select * into v from public.spell_versions where id = p_spell_version;
  select * into cs from public.catalog_spells where id = v.spell_id;
  if r.id is null then
    if v.archived_at is not null then raise exception '% is archived and no longer available for new characters', v.name using errcode = 'TLPUB'; end if;
    if cs.owner_id is not null then perform public._gov_gate(p_character, 'spell.assign_custom'); end if;
    if coalesce(p_always_prepared, false) then perform public._gov_gate(p_character, 'spell.always_prepared');
    elsif s.preparation_mode = 'spellbook' then perform public._gov_gate(p_character, 'spell.spellbook_add');
    elsif s.source_type in ('manual', 'other') then perform public._gov_gate(p_character, 'spell.add_manual');
    elsif coalesce(p_known, true) and s.preparation_mode <> 'prepared' then perform public._gov_gate(p_character, 'spell.learn_known');
    else perform public._gov_gate(p_character, 'spell.prepare');
    end if;
    if v.id is not null then
      perform public._gov_content_check(p_character, public._content_policy_reason(
        (select campaign_id from public.characters where id = p_character), null, v.status = 'legacy',
        v.rule_status = 'playtest', v.setting, cs.owner_id is not null, v.source_book_id));
    end if;
  else
    if p_always_prepared is not null and p_always_prepared is distinct from r.always_prepared then
      perform public._gov_gate(p_character, 'spell.always_prepared');
    end if;
    if p_known is not null and p_known is distinct from r.known then
      perform public._gov_gate(p_character, case when p_known then 'spell.learn_known' else 'spell.remove' end);
    end if;
    if p_prepared is not null and p_prepared is distinct from r.prepared then perform public._gov_gate(p_character, 'spell.prepare'); end if;
    if (p_casting_ability is not null and p_casting_ability is distinct from r.casting_ability)
       or (p_ritual_allowed is not null and p_ritual_allowed is distinct from r.ritual_allowed) then
      perform public._gov_gate(p_character, 'spell.change_source');
    end if;
  end if;
end;
$$;

create or replace function public._gov_gate_add_item(p_inventory uuid, p_item text)
returns void
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
declare inv public.inventories; it public.items;
begin
  select * into inv from public.inventories where id = p_inventory;
  if inv.kind <> 'character' or inv.character_id is null then return; end if;
  select * into it from public.items where id = p_item;
  if it.archived_at is not null then raise exception '% is archived and no longer available', it.name using errcode = 'TLPUB'; end if;
  if it.owner_id is not null then perform public._gov_gate(inv.character_id, 'inventory.assign_custom');
  elsif coalesce(it.is_magic, false) then perform public._gov_gate(inv.character_id, 'inventory.add_magic');
  else perform public._gov_gate(inv.character_id, 'inventory.add_mundane');
  end if;
  if it.id is not null then
    perform public._gov_content_check(inv.character_id, public._content_policy_reason(
      (select campaign_id from public.characters where id = inv.character_id), null, false, false, null,
      it.owner_id is not null, it.source_book_id));
  end if;
end;
$$;

create or replace function public._gov_gate_background(p_character uuid, p_version text)
returns void
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
declare v public.background_versions;
begin
  perform public._gov_gate(p_character, 'build.background');
  select * into v from public.background_versions where id = p_version;
  if v.archived_at is not null and not exists (select 1 from public.character_backgrounds where character_id = p_character and version_id = p_version) then
    raise exception '% is archived and no longer available', v.name using errcode = 'TLPUB';
  end if;
  if v.id is not null and not exists (select 1 from public.character_backgrounds where character_id = p_character and version_id = p_version) then
    perform public._gov_content_check(p_character, public._content_policy_reason(
      (select campaign_id from public.characters where id = p_character), v.ruleset, v.legacy, v.status = 'playtest', v.setting,
      false, v.source_book_id));
  end if;
end;
$$;

create or replace function public._gov_gate_lineage(p_character uuid, p_version text)
returns void
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
declare v public.lineage_versions;
begin
  perform public._gov_gate(p_character, 'build.lineage');
  select * into v from public.lineage_versions where id = p_version;
  if v.archived_at is not null and not exists (select 1 from public.character_lineages where character_id = p_character and version_id = p_version) then
    raise exception '% is archived and no longer available', v.name using errcode = 'TLPUB';
  end if;
  if v.id is not null and not exists (select 1 from public.character_lineages where character_id = p_character and version_id = p_version) then
    perform public._gov_content_check(p_character, public._content_policy_reason(
      (select campaign_id from public.characters where id = p_character), null, v.status = 'legacy', false, v.setting,
      false, v.source_book_id));
  end if;
end;
$$;

-- ---- RLS ------------------------------------------------------------------------------------------------------------------
alter table public.dm_content enable row level security;
alter table public.dm_content_versions enable row level security;
alter table public.dm_content_events enable row level security;
revoke all on public.dm_content, public.dm_content_versions, public.dm_content_events from anon, authenticated;
create policy "dm_content_read" on public.dm_content for select to authenticated using (public._dm_can_manage(id));
create policy "dm_content_versions_read" on public.dm_content_versions for select to authenticated using (public._dm_can_manage(content_id));
create policy "dm_content_events_read" on public.dm_content_events for select to authenticated using (public._dm_can_manage(content_id));
grant select on public.dm_content, public.dm_content_versions, public.dm_content_events to authenticated;

revoke all on function public._dm_can_manage(uuid), public._dm_short(uuid), public._dm_materialize(uuid), public._dm_catalog_json(text, text),
  public._dm_try(uuid), public._dm_usage(uuid), public._dm_content_json(uuid), public._dm_event(uuid, uuid, text, jsonb),
  public._dm_set_catalog_archived(text, text, boolean, text)
  from public, anon, authenticated;
grant execute on function public._dm_can_manage(uuid) to authenticated;
revoke all on function public.create_dm_content(text, uuid, jsonb, uuid), public.save_dm_content(uuid, jsonb, int), public.validate_dm_content(uuid),
  public.publish_dm_content(uuid, uuid), public.new_dm_content_version(uuid), public.archive_dm_content(uuid, text), public.restore_dm_content(uuid),
  public.duplicate_dm_content(uuid, uuid, boolean), public.delete_dm_content(uuid), public.get_dm_content(uuid), public.preview_dm_content(uuid),
  public.get_dm_content_library(uuid, text, boolean), public.get_content_public_info(uuid), public.dm_assign_content(uuid, uuid[], text, jsonb)
  from public, anon;
grant execute on function public.create_dm_content(text, uuid, jsonb, uuid), public.save_dm_content(uuid, jsonb, int), public.validate_dm_content(uuid),
  public.publish_dm_content(uuid, uuid), public.new_dm_content_version(uuid), public.archive_dm_content(uuid, text), public.restore_dm_content(uuid),
  public.duplicate_dm_content(uuid, uuid, boolean), public.delete_dm_content(uuid), public.get_dm_content(uuid), public.preview_dm_content(uuid),
  public.get_dm_content_library(uuid, text, boolean), public.get_content_public_info(uuid), public.dm_assign_content(uuid, uuid[], text, jsonb)
  to authenticated;

-- ---- rewritten functions (live definitions with exact replacements) ----------------------------------------

-- _form_options(uuid)
CREATE OR REPLACE FUNCTION public._form_options(p_character uuid)
 RETURNS TABLE(creature_id text, rule_resource text, character_class_id uuid, class_level integer, cost integer, elemental boolean, max_cr numeric, type_ok boolean, cr_ok boolean, fly_ok boolean, swim_ok boolean, mechanical boolean, seen text, allowed boolean, status text, reasons text[], duration_minutes integer)
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
  with rules as (
    select tr.*, (tr.rule ->> 'cost')::int as rcost,
           (select (e ->> 1)::numeric from jsonb_array_elements(tr.rule -> 'max_cr_by_level') e
            where (e ->> 0)::int <= tr.class_level order by (e ->> 0)::int desc limit 1) as rmax,
           tr.rule ? 'creature_ids' as relemental
    from public._character_transform_rules(p_character) tr),
  pairs as (
    select c.id, c.challenge_rating, c.speed, r.*,
           coalesce(r.rule -> 'creature_types' ? c.creature_type, false) or coalesce(r.rule -> 'creature_ids' ? c.id, false) as t_ok,
           not (r.rule ? 'max_cr_by_level') or c.challenge_rating <= coalesce(r.rmax, -1) as c_ok,
           coalesce((c.speed ->> 'fly')::int, 0) = 0 or r.class_level >= coalesce((r.rule ->> 'no_fly_below')::int, 0) as f_ok,
           coalesce((c.speed ->> 'swim')::int, 0) = 0 or r.class_level >= coalesce((r.rule ->> 'no_swim_below')::int, 0) as s_ok
    from public.creatures c join rules r
      on coalesce(r.rule -> 'creature_types' ? c.creature_type, false) or coalesce(r.rule -> 'creature_ids' ? c.id, false)
    where (c.content_scope = 'official' or c.content_scope = 'test'
           or (c.content_scope = 'campaign' and c.wild_shape_eligible and exists (select 1 from public.character_seen_forms g
               where g.character_id = p_character and g.creature_id = c.id and g.source = 'dm_grant')))
      and (c.archived_at is null or exists (select 1 from public.character_seen_forms g2 where g2.character_id = p_character and g2.creature_id = c.id))),   -- DM content (20261019000400)
  best as (   -- per creature: the allowed rule with the lowest cost, else the closest refusal (fewest reasons)
    select distinct on (p.id) p.*, (p.t_ok and p.c_ok and p.f_ok and p.s_ok) as mech
    from pairs p
    order by p.id, (p.t_ok and p.c_ok and p.f_ok and p.s_ok) desc, p.rcost,
             (not p.c_ok)::int + (not p.f_ok)::int + (not p.s_ok)::int),
  st as (select public._wild_shape_settings(p_character) as s)
  select b.id, b.resource_key, b.character_class_id, b.class_level, b.rcost, b.relemental, b.rmax, b.t_ok, b.c_ok, b.f_ok, b.s_ok, b.mech,
         sf.source,
         (b.mech and (sf.source is not null or (st.s).seen_mode <> 'enforce')) or coalesce(sf.source = 'dm_grant', false),
         case when sf.source = 'dm_grant' and not b.mech then 'dm_granted'
              when not b.mech then 'ineligible'
              when sf.source is not null then 'eligible_seen'
              when (st.s).seen_mode = 'unrestricted' then 'eligible_unrestricted'
              when (st.s).seen_mode = 'warn' then 'eligible_unseen'
              else 'unseen_locked' end,
         array_remove(array[
           case when not b.c_ok then format('challenge rating %s is above your maximum %s (Druid level %s)',
                                            public._cr_text(b.challenge_rating), public._cr_text(b.rmax), b.class_level) end,
           case when not b.f_ok then format('flying forms need Druid level %s', b.rule ->> 'no_fly_below') end,
           case when not b.s_ok then format('swimming forms need Druid level %s', b.rule ->> 'no_swim_below') end,
           case when b.mech and sf.source is null and (st.s).seen_mode = 'enforce' then 'you have not seen this beast (mark it as seen)' end], null),
         case when b.rule ? 'duration_hours' then greatest(1, b.class_level / 2) * 60 end
  from best b cross join st
  left join public.character_seen_forms sf on sf.character_id = p_character and sf.creature_id = b.id;
$function$;

-- set_seen_forms(uuid,text[],boolean,text,text)
CREATE OR REPLACE FUNCTION public.set_seen_forms(p_character uuid, p_creatures text[], p_seen boolean DEFAULT true, p_source text DEFAULT 'seen'::text, p_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare x text;
begin
  perform public._gov_gate(p_character, 'runtime.mark_seen_form');   -- campaign governance (20261019000100)
  perform public._lock_for_wild_shape(p_character);
  if p_source not in ('seen', 'dm_grant') then raise exception 'Source is seen or dm_grant' using errcode = '22023'; end if;
  if p_source = 'dm_grant' and not public._acts_as_dm(p_character) then
    raise exception 'Only the DM can grant a form exception' using errcode = '42501';
  end if;
  foreach x in array coalesce(p_creatures, '{}') loop
    if not exists (select 1 from public.creatures where id = x) then raise exception 'Unknown creature "%"', x using errcode = '22023'; end if;
    if exists (select 1 from public.creatures where id = x and content_scope = 'campaign') and not public._acts_as_dm(p_character) then
      raise exception 'Only the DM can grant a campaign creature as a Wild Shape form' using errcode = 'TLDMO';   -- DM content (20261019000400)
    end if;
    if p_seen then
      if exists (select 1 from public.character_seen_forms where character_id = p_character and creature_id = x and source = 'dm_grant')
         and p_source <> 'dm_grant' and not public._acts_as_dm(p_character) then
        continue;                                                   -- a DM grant is not downgraded by the player
      end if;
      insert into public.character_seen_forms (character_id, creature_id, source, note, created_by)
      values (p_character, x, p_source, nullif(left(p_note, 300), ''), auth.uid())
      on conflict (character_id, creature_id) do update set source = excluded.source, note = coalesce(excluded.note, character_seen_forms.note);
      perform public._wild_shape_event(p_character, 'seen_added', x, null, null, jsonb_build_object('source', p_source, 'note', p_note));
    else
      if exists (select 1 from public.character_seen_forms where character_id = p_character and creature_id = x and source = 'dm_grant')
         and not public._acts_as_dm(p_character) then
        raise exception 'Only the DM can remove a DM grant' using errcode = '42501';
      end if;
      delete from public.character_seen_forms where character_id = p_character and creature_id = x;
      if found then perform public._wild_shape_event(p_character, 'seen_removed', x, null, null, '{}'); end if;
    end if;
  end loop;
  return public.get_character_transformation(p_character);
end;
$function$;

-- add_character_companion(uuid,text,text,text,integer)
CREATE OR REPLACE FUNCTION public.add_character_companion(p_character uuid, p_creature text DEFAULT NULL::text, p_name text DEFAULT NULL::text, p_source text DEFAULT NULL::text, p_hp_max integer DEFAULT NULL::integer)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare c public.creatures; hp int; nid uuid;
begin
  perform public._gov_gate(p_character, 'build.companion');   -- campaign governance (20261019000100)
  if auth.uid() is null or not public.can_access_character(p_character) then
    raise exception 'Character not found' using errcode = '42501';
  end if;
  if p_creature is not null then
    select * into c from public.creatures where id = p_creature;
    if not found then raise exception 'Unknown creature "%"', p_creature using errcode = '22023'; end if;
    if c.content_scope = 'campaign' and not public._acts_as_dm(p_character) then
      raise exception 'Only the DM can assign a campaign companion' using errcode = 'TLDMO';   -- DM content (20261019000400)
    end if;
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
$function$;
