-- =============================================================================
-- Versioned background engine (docs/BACKGROUNDS.md). 2024 backgrounds and legacy (2014) backgrounds are separate versions
-- and never merged; Unearthed Arcana versions are playtest content that needs the DM's permission.
--   * catalog: backgrounds, background_versions (ruleset, status, source, relations), ability options (2024), fixed
--     proficiency grants, choices with expanded options, feat references (feats: a reference catalog, informational),
--     equipment packages and entries (catalog items; unresolved entries keep their label), features (short summaries),
--     characteristic tables (headings and short entry titles only)
--   * character: character_backgrounds (version, ability mode / allocation, "bonuses already included", characteristics,
--     notes), choices, duplicate replacements, applied equipment (RPC only; read through can_access_character)
--   * derived: 2024 ability increases after the lineage (both capped at 20), background skills / tools / languages join
--     the derived result and the proficiency resolver as source "background"; Expertise and choice checks accept them
--   * RPCs: get_background_catalog, get_character_background, set_character_background, clear_character_background,
--     preview_background_equipment, apply_background_equipment
-- Function copies (_derived_stats_core, _proficiency_match, _cf_choice_error, get_character_class_features,
-- get_character_derived_stats, get_character_proficiencies) are exact copies of the current definitions with the marked edits.
-- =============================================================================

-- =============================================================================
-- Catalog (read by everyone; written only by the seed supabase/seed/backgrounds.sql)
-- =============================================================================
create table public.backgrounds (
  id          text primary key check (id ~ '^[a-z][a-z0-9-]{1,60}$'),
  name        text not null check (length(name) between 1 and 80),
  sort_order  int not null default 0
);

create table public.feats (
  id                  text primary key check (id ~ '^[a-z][a-z0-9-]{1,60}$'),
  name                text not null check (length(name) between 1 and 80),
  category            text not null check (category in ('origin', 'general', 'fighting_style', 'epic_boon', 'other')),
  ruleset             text not null check (ruleset in ('2024', '2014', 'ua-2022')),
  status              text not null check (status in ('official', 'playtest')),
  summary             text not null default '' check (length(summary) <= 400),
  source_url          text,
  automation          text not null default 'informational' check (automation in ('informational', 'partially_automated', 'automated')),
  parameter_label     text,
  implementation_note text not null default 'Shown as a reference; the feat''s rules are not applied automatically yet.'
);

create table public.background_versions (
  id                 text primary key check (id ~ '^[a-z][a-z0-9-]{1,60}$'),
  background_id      text not null references public.backgrounds (id) on delete cascade,
  name               text not null check (length(name) between 1 and 80),
  ruleset            text not null check (ruleset in ('2024', '2014')),
  rules_label        text not null,
  status             text not null check (status in ('official', 'playtest')),
  legacy             boolean generated always as (ruleset = '2014') stored,
  setting            text,
  source_book_id     text references public.source_books (id),
  source_label       text not null,
  source_page        text,
  source_url         text not null,
  also_in            text[] not null default '{}',
  variant_of         text references public.background_versions (id),
  relation_note      text,
  requested_as       text,
  dm_permission      boolean not null default false,
  enabled_by_default boolean not null default true,
  duplicate_rule     text not null,
  sort_order         int not null default 0,
  check (status = 'official' or (dm_permission and not enabled_by_default))     -- playtest content never shows up by default
);
create index background_versions_background_idx on public.background_versions (background_id);

create table public.background_ability_options (
  version_id text not null references public.background_versions (id) on delete cascade,
  ability    text not null check (ability in ('str', 'dex', 'con', 'int', 'wis', 'cha')),
  primary key (version_id, ability)
);

create table public.background_proficiency_grants (
  version_id text not null references public.background_versions (id) on delete cascade,
  kind       text not null check (kind in ('skill', 'tool', 'language')),
  target_id  text not null,
  seq        int not null default 0,
  primary key (version_id, kind, target_id)
);

create table public.background_choices (
  id                 text primary key,
  version_id         text not null references public.background_versions (id) on delete cascade,
  key                text not null check (key ~ '^[a-z][a-z0-9-]{0,40}$'),
  kind               text not null check (kind in ('skill', 'tool', 'language', 'tool_or_language')),
  label              text not null,
  pick_count         int not null check (pick_count between 1 and 4),
  grants_proficiency boolean not null default true,
  config             jsonb not null default '{}',
  sort_order         int not null default 0,
  unique (version_id, key)
);

create table public.background_choice_options (
  choice_id   text not null references public.background_choices (id) on delete cascade,
  option_kind text not null check (option_kind in ('skill', 'tool', 'language')),
  option_id   text not null,
  primary key (choice_id, option_kind, option_id)
);

create table public.background_feat_grants (
  version_id text primary key references public.background_versions (id) on delete cascade,
  feat_id    text not null references public.feats (id),
  parameter  text,
  note       text
);

create table public.background_equipment_packages (
  id         text primary key,
  version_id text not null references public.background_versions (id) on delete cascade,
  key        text not null check (key in ('A', 'B', 'standard')),
  label      text not null,
  coins      jsonb not null default '{}',      -- {"gp": 14} or {"sp": 1}
  sort_order int not null default 0,
  unique (version_id, key)
);

create table public.background_equipment_entries (
  package_id  text not null references public.background_equipment_packages (id) on delete cascade,
  seq         int not null,
  item_id     text references public.items (id),                -- null: not in the catalog (kept as a label, never dropped)
  quantity    int not null default 1 check (quantity between 1 and 100),
  label       text not null,
  from_choice text,                                             -- the item chosen in this background choice (key)
  category_id text,                                             -- pick one item of this category when applying
  note        text,
  primary key (package_id, seq)
);

create table public.background_features (
  version_id text not null references public.background_versions (id) on delete cascade,
  key        text not null,
  name       text not null,
  summary    text not null check (length(summary) <= 400),
  automation text not null default 'informational' check (automation in ('informational', 'partially_automated', 'automated')),
  primary key (version_id, key)
);

create table public.background_characteristic_tables (
  version_id   text not null references public.background_versions (id) on delete cascade,
  key          text not null,
  label        text not null,
  die          text check (die ~ '^d[0-9]{1,2}$'),
  kind         text not null check (kind in ('personality', 'ideal', 'bond', 'flaw', 'special')),
  entry_labels text[],                                          -- short titles only (never the prose of the entries)
  sort_order   int not null default 0,
  primary key (version_id, key)
);

do $$
declare t text;
begin
  foreach t in array array['backgrounds', 'feats', 'background_versions', 'background_ability_options', 'background_proficiency_grants',
                           'background_choices', 'background_choice_options', 'background_feat_grants', 'background_equipment_packages',
                           'background_equipment_entries', 'background_features', 'background_characteristic_tables'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('create policy %I on public.%I for select using (true)', t || '_read', t);
    execute format('revoke all on public.%I from anon, authenticated', t);
    execute format('grant select on public.%I to anon, authenticated', t);
  end loop;
end $$;

-- =============================================================================
-- Character state (RPC only)
-- =============================================================================
create table public.character_backgrounds (
  character_id       uuid primary key references public.characters (id) on delete cascade,
  version_id         text not null references public.background_versions (id),
  ability_mode       text check (ability_mode in ('plus2_plus1', 'plus1_x3')),
  ability_allocation jsonb not null default '{}',             -- {"str": 2, "con": 1}
  bonuses_included   boolean not null default false,          -- the stored scores already contain these increases
  characteristics    jsonb not null default '{}',             -- the player's own text or a chosen short label per table
  notes              text not null default '' check (length(notes) <= 2000),
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now()
);
create index character_backgrounds_version_idx on public.character_backgrounds (version_id);

create table public.character_background_choices (
  character_id uuid not null references public.character_backgrounds (character_id) on delete cascade,
  choice_id    text not null references public.background_choices (id) on delete cascade,
  pick         int not null check (pick between 1 and 4),
  option_kind  text not null check (option_kind in ('skill', 'tool', 'language')),
  option_id    text not null,
  primary key (character_id, choice_id, pick),
  unique (character_id, choice_id, option_kind, option_id)
);

-- a duplicate grant replaced by another proficiency of the same kind (2014: Player's Handbook rule; 2024: table rule)
create table public.character_background_replacements (
  character_id   uuid not null references public.character_backgrounds (character_id) on delete cascade,
  kind           text not null check (kind in ('skill', 'tool')),
  original_id    text not null,
  replacement_id text not null,
  primary key (character_id, kind, original_id)
);

-- what a background equipment application added (never removed automatically: items may be used, moved or changed)
create table public.character_background_equipment (
  id                 uuid primary key default gen_random_uuid(),
  character_id       uuid not null references public.characters (id) on delete cascade,
  version_id         text not null references public.background_versions (id),
  package_key        text not null,
  inventory_item_ids uuid[] not null default '{}',
  coins              jsonb not null default '{}',
  noted              jsonb not null default '[]',               -- entries that are not in the catalog (labels)
  applied_by         uuid,
  applied_at         timestamptz not null default now(),
  unique (character_id, version_id)
);

do $$
declare t text;
begin
  foreach t in array array['character_backgrounds', 'character_background_choices', 'character_background_replacements',
                           'character_background_equipment'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('create policy %I on public.%I for select using (public.can_access_character(character_id))', t || '_read', t);
    execute format('revoke all on public.%I from anon, authenticated', t);
    execute format('grant select on public.%I to authenticated', t);
  end loop;
end $$;

create trigger character_backgrounds_touch before update on public.character_backgrounds
  for each row execute function public.character_class_rows_touch();

-- Realtime: the sheet refreshes when the background changes in another session
do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    alter publication supabase_realtime add table public.character_backgrounds;
  end if;
end $$;

-- =============================================================================
-- Resolution helpers
-- =============================================================================

-- every proficiency the background gives the character: fixed grants, chosen options, replacements (a replaced grant is gone)
create function public._character_background_grants(p_character uuid)
returns table (kind text, target_id text, origin text, choice_id text, original_id text)
language sql stable
set search_path = public, pg_temp
as $$
  with cb as (select * from public.character_backgrounds where character_id = p_character),
  raw as (
    select g.kind, g.target_id, 'fixed'::text as origin, null::text as choice_id
    from cb join public.background_proficiency_grants g on g.version_id = cb.version_id
    union all
    select x.option_kind, x.option_id, 'choice', x.choice_id
    from cb join public.character_background_choices x on x.character_id = cb.character_id
    join public.background_choices c on c.id = x.choice_id and c.version_id = cb.version_id
    where c.grants_proficiency
  )
  select r.kind, coalesce(rp.replacement_id, r.target_id), case when rp.replacement_id is null then r.origin else 'replacement' end,
         r.choice_id, case when rp.replacement_id is not null then r.target_id end
  from raw r
  left join cb on true
  left join public.character_background_replacements rp on rp.character_id = cb.character_id and rp.kind = r.kind and rp.original_id = r.target_id;
$$;

-- ability increases of the 2024 package (none when the stored scores already include them, or for a legacy background)
create function public._character_background_abilities(p_character uuid)
returns jsonb
language sql stable
set search_path = public, pg_temp
as $$
  select coalesce((select case when cb.bonuses_included or v.ruleset <> '2024' then '{}'::jsonb else cb.ability_allocation end
                   from public.character_backgrounds cb join public.background_versions v on v.id = cb.version_id
                   where cb.character_id = p_character), '{}'::jsonb);
$$;

-- the derived layer: background skills, tools and languages join the derived result as their own source ("Soldier")
create function public._background_layer(p_character uuid, d jsonb)
returns jsonb
language plpgsql stable
set search_path = public, pg_temp
as $$
declare bg record; g record; skills jsonb; profs jsonb; langs jsonb; src text; i int;
begin
  select cb.*, v.name as version_name, v.ruleset, v.background_id into bg
  from public.character_backgrounds cb join public.background_versions v on v.id = cb.version_id where cb.character_id = p_character;
  if not found then return d || jsonb_build_object('background', null); end if;
  src := (select name from public.backgrounds where id = bg.background_id);
  skills := coalesce(d -> 'skills', '{}');
  profs := coalesce(d -> 'proficiencies', '[]');
  langs := coalesce(d -> 'languages', '[]');
  for g in select * from public._character_background_grants(p_character) loop
    if g.kind = 'skill' then
      skills := skills || jsonb_build_object(g.target_id, coalesce(skills -> g.target_id, '{"advantage": false, "disadvantage": false, "sources": []}'::jsonb)
        || jsonb_build_object('background_proficient', true, 'proficiency_sources',
             coalesce(skills -> g.target_id -> 'proficiency_sources', '[]') || jsonb_build_array(jsonb_build_object(
               'source_type', 'background', 'source_name', src, 'version_id', bg.version_id, 'origin', g.origin))));
    elsif g.kind = 'tool' then
      profs := profs || jsonb_build_array(jsonb_build_object('id', null, 'proficiency_type', 'tool', 'group_id', null, 'item_id', g.target_id,
        'name', coalesce((select name from public.items where id = g.target_id), g.target_id), 'source_type', 'background', 'notes', src,
        'version_id', bg.version_id));
    elsif g.kind = 'language' then
      select ord - 1 into i from jsonb_array_elements(langs) with ordinality x(l, ord) where l ->> 'id' = g.target_id;
      if i is null then
        langs := langs || jsonb_build_array(jsonb_build_object('id', g.target_id,
          'name', coalesce((select name from public.languages where id = g.target_id), g.target_id), 'sources', jsonb_build_array('Background: ' || src)));
      else
        langs := jsonb_set(langs, array[i::text, 'sources'], coalesce(langs -> i -> 'sources', '[]') || jsonb_build_array('Background: ' || src));
      end if;
      i := null;
    end if;
  end loop;
  return d || jsonb_build_object('skills', skills, 'proficiencies', profs, 'languages', langs,
    'background', jsonb_build_object('version_id', bg.version_id, 'name', src, 'version_name', bg.version_name, 'ruleset', bg.ruleset,
                                     'bonuses_included', bg.bonuses_included));
end;
$$;

-- =============================================================================
-- Catalog read model (picker)
-- =============================================================================
create function public._background_version_json(p_version text)
returns jsonb
language sql stable
set search_path = public, pg_temp
as $$
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
             from public.background_feat_grants fg join public.feats f on f.id = fg.feat_id where fg.version_id = v.id),
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
$$;

create function public.get_background_catalog()
returns jsonb
language sql stable
set search_path = public, pg_temp
as $$
  select jsonb_build_object(
    'versions', coalesce((select jsonb_agg(public._background_version_json(v.id) order by v.ruleset desc, b.sort_order, v.sort_order)
                          from public.background_versions v join public.backgrounds b on b.id = v.background_id), '[]'),
    'feats', coalesce((select jsonb_agg(to_jsonb(f) order by f.name) from public.feats f), '[]'));
$$;

-- =============================================================================
-- Character background: write
-- =============================================================================

-- p_ability:  {"mode": "plus2_plus1", "allocation": {"str": 2, "con": 1}} | {"mode": "plus1_x3", ...} | null (2014)
-- p_choices:  {"<choice key>": ["option id" | "tool:option" | "language:option", ...]}
-- p_replacements: [{"kind": "skill", "original": "athletics", "replacement": "survival"}]
-- p_options:  {"bonuses_included": bool, "allow_playtest": bool, "characteristics": {...}, "notes": "..."}
create function public.set_character_background(p_character uuid, p_version text, p_ability jsonb default null,
                                                p_choices jsonb default '{}'::jsonb, p_replacements jsonb default '[]'::jsonb,
                                                p_options jsonb default '{}'::jsonb)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare v public.background_versions; c public.background_choices; vals text[]; val text; okind text; oid text; n int; mode text;
  alloc jsonb := '{}'; k text; opt_count int; picked text[]; r jsonb; prev text; chars jsonb;
begin
  if auth.uid() is null or not public.can_access_character(p_character) then
    raise exception 'Character not found' using errcode = '42501';
  end if;
  perform 1 from public.characters where id = p_character for update;
  select * into v from public.background_versions where id = p_version;
  if not found then raise exception 'Unknown background version "%"', p_version using errcode = '22023'; end if;
  if v.dm_permission and not coalesce((p_options ->> 'allow_playtest')::boolean, false) then
    raise exception '% is % content: confirm that your DM allows it', v.name, case when v.status = 'playtest' then 'playtest (Unearthed Arcana)' else 'restricted' end
      using errcode = '22023';
  end if;

  -- ability increases: only the 2024 package, only the three listed abilities, +2 / +1 to different ones or +1 to all three
  mode := nullif(p_ability ->> 'mode', '');
  if v.ruleset = '2014' then
    if mode is not null or coalesce(p_ability -> 'allocation', '{}') <> '{}' then
      raise exception 'A legacy background has no ability score increases (they come from the lineage)' using errcode = '22023';
    end if;
  elsif mode is not null then
    for k in select jsonb_object_keys(coalesce(p_ability -> 'allocation', '{}')) loop
      if not exists (select 1 from public.background_ability_options where version_id = v.id and ability = k) then
        raise exception '% can only increase %', v.name,
          (select string_agg(upper(ability), ', ') from public.background_ability_options where version_id = v.id) using errcode = '22023';
      end if;
      if (p_ability -> 'allocation' ->> k) !~ '^[12]$' then raise exception 'An increase is +1 or +2' using errcode = '22023'; end if;
      alloc := alloc || jsonb_build_object(k, (p_ability -> 'allocation' ->> k)::int);
    end loop;
    if mode = 'plus2_plus1' then
      if not (jsonb_typeof(alloc) = 'object' and (select count(*) from jsonb_object_keys(alloc)) = 2
              and (select array_agg(x::int order by x::int) from jsonb_each_text(alloc) e(ak, x)) = array[1, 2]) then
        raise exception 'Choose +2 for one listed ability and +1 for a different one' using errcode = '22023';
      end if;
    elsif mode = 'plus1_x3' then
      if not ((select count(*) from jsonb_object_keys(alloc)) = 3 and (select bool_and(x::int = 1) from jsonb_each_text(alloc) e(ak, x))) then
        raise exception 'Choose +1 for each of the three listed abilities' using errcode = '22023';
      end if;
    else
      raise exception 'Unknown ability mode "%"', mode using errcode = '22023';
    end if;
  end if;

  chars := coalesce(p_options -> 'characteristics', '{}');
  if jsonb_typeof(chars) <> 'object' or length(chars::text) > 6000 then
    raise exception 'Characteristics must be short texts' using errcode = '22023';
  end if;

  select version_id into prev from public.character_backgrounds where character_id = p_character;
  insert into public.character_backgrounds as cb (character_id, version_id, ability_mode, ability_allocation, bonuses_included, characteristics, notes)
  values (p_character, v.id, mode, alloc, coalesce((p_options ->> 'bonuses_included')::boolean, false), chars, coalesce(p_options ->> 'notes', ''))
  on conflict (character_id) do update set version_id = excluded.version_id, ability_mode = excluded.ability_mode,
    ability_allocation = excluded.ability_allocation, bonuses_included = excluded.bonuses_included,
    characteristics = excluded.characteristics, notes = excluded.notes;
  delete from public.character_background_choices where character_id = p_character;
  delete from public.character_background_replacements where character_id = p_character;

  -- choices: every value must be an option of that choice; a choice may stay open (fewer picks), never exceed its count
  for k in select jsonb_object_keys(coalesce(p_choices, '{}')) loop
    select * into c from public.background_choices where version_id = v.id and key = k;
    if not found then raise exception '% has no choice "%"', v.name, k using errcode = '22023'; end if;
    select array_agg(x) into vals from jsonb_array_elements_text(p_choices -> k) x;
    vals := coalesce(vals, '{}');
    if cardinality(vals) > c.pick_count then
      raise exception '%: choose at most %', c.label, c.pick_count using errcode = '22023';
    end if;
    n := 0;
    foreach val in array vals loop
      n := n + 1;
      okind := case when val like '%:%' then split_part(val, ':', 1) end;
      oid := case when val like '%:%' then split_part(val, ':', 2) else val end;
      select o.option_kind into okind from public.background_choice_options o
      where o.choice_id = c.id and o.option_id = oid and (okind is null or o.option_kind = okind) limit 1;
      if not found then raise exception '%: "%" is not one of the options', c.label, oid using errcode = '22023'; end if;
      begin
        insert into public.character_background_choices (character_id, choice_id, pick, option_kind, option_id) values (p_character, c.id, n, okind, oid);
      exception when unique_violation then
        raise exception '%: "%" is chosen twice', c.label, oid using errcode = '22023';
      end;
    end loop;
  end loop;

  -- replacements of duplicated grants (same kind; the original must be a grant of this background)
  for r in select x from jsonb_array_elements(coalesce(p_replacements, '[]')) x loop
    if r ->> 'kind' not in ('skill', 'tool') then raise exception 'Only skill or tool proficiencies can be replaced' using errcode = '22023'; end if;
    if not exists (select 1 from public._character_background_grants(p_character) g where g.kind = r ->> 'kind' and g.target_id = r ->> 'original') then
      raise exception '"%" is not a % this background gives', r ->> 'original', r ->> 'kind' using errcode = '22023';
    end if;
    if (r ->> 'kind' = 'skill' and not exists (select 1 from public.skills where id = r ->> 'replacement'))
       or (r ->> 'kind' = 'tool' and not exists (select 1 from public.items where id = r ->> 'replacement' and kind_id = 'tool' and owner_id is null)) then
      raise exception '"%" is not a % proficiency', r ->> 'replacement', r ->> 'kind' using errcode = '22023';
    end if;
    if exists (select 1 from public._character_background_grants(p_character) g where g.kind = r ->> 'kind' and g.target_id = r ->> 'replacement') then
      raise exception 'The background already gives "%"', r ->> 'replacement' using errcode = '22023';
    end if;
    insert into public.character_background_replacements (character_id, kind, original_id, replacement_id)
    values (p_character, r ->> 'kind', r ->> 'original', r ->> 'replacement');
  end loop;

  return public.get_character_background(p_character);
end;
$$;

create function public.clear_character_background(p_character uuid)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
begin
  if auth.uid() is null or not public.can_access_character(p_character) then
    raise exception 'Character not found' using errcode = '42501';
  end if;
  perform 1 from public.characters where id = p_character for update;
  delete from public.character_backgrounds where character_id = p_character;     -- choices and replacements go with it
  return public.get_character_background(p_character);                           -- equipment already added stays in the inventory
end;
$$;

-- =============================================================================
-- Character background: read model
-- =============================================================================
create function public.get_character_background(p_character uuid)
returns jsonb
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
declare cb public.character_backgrounds; v jsonb; profs jsonb; choices jsonb := '[]'; c record; sel jsonb; warnings jsonb := '[]';
  grants jsonb; eff jsonb := '{}'; d jsonb; k text; open_n int := 0; equip jsonb; dup jsonb; feat jsonb;
begin
  if auth.uid() is null or not public.can_access_character(p_character) then
    raise exception 'Character not found' using errcode = '42501';
  end if;
  select * into cb from public.character_backgrounds where character_id = p_character;
  equip := (select coalesce(jsonb_agg(jsonb_build_object('version_id', e.version_id, 'package_key', e.package_key, 'applied_at', e.applied_at,
              'items', cardinality(e.inventory_item_ids), 'coins', e.coins, 'noted', e.noted) order by e.applied_at), '[]')
            from public.character_background_equipment e where e.character_id = p_character);
  if cb.character_id is null then
    return jsonb_build_object('character_id', p_character, 'selected', false, 'equipment_applied', equip,
      'note', case when jsonb_array_length(equip) > 0 then 'Equipment from an earlier background stays in the inventory.' end);
  end if;
  v := public._background_version_json(cb.version_id);
  d := public.get_character_derived_stats(p_character);
  profs := public.get_character_proficiencies(p_character);

  -- choices with what is selected and whether they are still open
  for c in select * from public.background_choices where version_id = cb.version_id order by sort_order loop
    select coalesce(jsonb_agg(jsonb_build_object('kind', x.option_kind, 'id', x.option_id,
             'name', coalesce(sk.name, it.name, lg.name, x.option_id)) order by x.pick), '[]') into sel
    from public.character_background_choices x
    left join public.skills sk on x.option_kind = 'skill' and sk.id = x.option_id
    left join public.items it on x.option_kind = 'tool' and it.id = x.option_id
    left join public.languages lg on x.option_kind = 'language' and lg.id = x.option_id
    where x.character_id = p_character and x.choice_id = c.id;
    choices := choices || jsonb_build_array(jsonb_build_object('id', c.id, 'key', c.key, 'kind', c.kind, 'label', c.label, 'count', c.pick_count,
      'selected', sel, 'open', jsonb_array_length(sel) < c.pick_count,
      'config_ok', not (c.config ? 'must_include_one_of' and jsonb_array_length(sel) = c.pick_count
                        and not exists (select 1 from jsonb_array_elements(sel) s where c.config -> 'must_include_one_of' ? (s ->> 'id')))));
    if jsonb_array_length(sel) < c.pick_count then open_n := open_n + 1; end if;
    if c.config ? 'must_include_one_of' and jsonb_array_length(sel) = c.pick_count
       and not exists (select 1 from jsonb_array_elements(sel) s where c.config -> 'must_include_one_of' ? (s ->> 'id')) then
      warnings := warnings || jsonb_build_object('code', 'choice_rule', 'choice', c.key,
        'message', format('%s: at least one must be %s', c.label, (select string_agg(initcap(replace(x, '-', ' ')), ', ')
                                                                  from jsonb_array_elements_text(c.config -> 'must_include_one_of') x)));
    end if;
  end loop;

  -- the grants with their duplicates (another source gives the same proficiency: the grant adds nothing)
  select coalesce(jsonb_agg(jsonb_build_object('kind', g.kind, 'id', g.target_id, 'origin', g.origin, 'choice_id', g.choice_id,
           'original_id', g.original_id, 'name', coalesce(sk.name, it.name, lg.name, g.target_id),
           'also_from', (select coalesce(jsonb_agg(s ->> 'label'), '[]') from jsonb_array_elements(
                           (select e -> 'sources' from jsonb_array_elements(profs -> (case g.kind when 'skill' then 'skills' when 'tool' then 'items' else 'languages' end)) e
                            where e ->> 'id' = g.target_id)) s where s ->> 'kind' <> 'background'))
           order by g.kind, coalesce(sk.name, it.name, lg.name, g.target_id)), '[]')
  into grants
  from public._character_background_grants(p_character) g
  left join public.skills sk on g.kind = 'skill' and sk.id = g.target_id
  left join public.items it on g.kind = 'tool' and it.id = g.target_id
  left join public.languages lg on g.kind = 'language' and lg.id = g.target_id;
  select coalesce(jsonb_agg(x), '[]') into dup from jsonb_array_elements(grants) x where jsonb_array_length(x -> 'also_from') > 0 and x ->> 'kind' <> 'language';
  if jsonb_array_length(dup) > 0 then
    warnings := warnings || jsonb_build_object('code', 'duplicate_grant', 'items', dup, 'rule', v ->> 'duplicate_rule',
      'replacement_allowed', true, 'dm_approval', v ->> 'ruleset' = '2024',
      'message', format('Already proficient from another source: %s.', (select string_agg(x ->> 'name', ', ') from jsonb_array_elements(dup) x)));
  end if;

  -- ability increases as applied by the derived stats (capped at 20 together with the lineage)
  for k in select unnest(array['str', 'dex', 'con', 'int', 'wis', 'cha']) loop
    if (cb.ability_allocation ->> k) is not null then
      eff := eff || jsonb_build_object(k, jsonb_build_object('bonus', (cb.ability_allocation ->> k)::int,
        'applied', coalesce((d -> 'abilities' -> k ->> 'background_applied')::int, 0), 'score', (d -> 'abilities' -> k ->> 'score')::int));
      if not cb.bonuses_included and coalesce((d -> 'abilities' -> k ->> 'background_applied')::int, 0) < (cb.ability_allocation ->> k)::int then
        warnings := warnings || jsonb_build_object('code', 'ability_capped', 'ability', k,
          'message', format('%s: the increase is limited by the maximum of 20.', upper(k)));
      end if;
    end if;
  end loop;
  if v ->> 'ruleset' = '2024' and cb.ability_mode is null and not cb.bonuses_included then
    open_n := open_n + 1;
    warnings := warnings || jsonb_build_object('code', 'ability_open', 'message', 'Choose how to apply the ability score increases.');
  end if;
  if (v ->> 'dm_permission')::boolean then
    warnings := warnings || jsonb_build_object('code', 'dm_permission', 'message',
      format('%s is %s: use it only with your DM''s permission.', v ->> 'name', case when v ->> 'status' = 'playtest' then 'playtest material (Unearthed Arcana)' else 'restricted' end));
  end if;
  feat := v -> 'feat';

  return jsonb_build_object('character_id', p_character, 'selected', true, 'version', v,
    'ruleset', v ->> 'ruleset', 'status', v ->> 'status', 'legacy', (v ->> 'legacy')::boolean,
    'source', jsonb_build_object('book', v ->> 'source_book', 'label', v ->> 'source_label', 'page', v ->> 'source_page', 'url', v ->> 'source_url',
                                 'also_in', v -> 'also_in_books'),
    'ability', jsonb_build_object('mode', cb.ability_mode, 'allocation', cb.ability_allocation, 'options', v -> 'abilities',
                                  'bonuses_included', cb.bonuses_included, 'effective', eff,
                                  'compatibility_mode', cb.bonuses_included),
    'grants', grants,
    'skills', (select coalesce(jsonb_agg(x), '[]') from jsonb_array_elements(grants) x where x ->> 'kind' = 'skill'),
    'tools', (select coalesce(jsonb_agg(x), '[]') from jsonb_array_elements(grants) x where x ->> 'kind' = 'tool'),
    'languages', (select coalesce(jsonb_agg(x), '[]') from jsonb_array_elements(grants) x where x ->> 'kind' = 'language'),
    'replacements', (select coalesce(jsonb_agg(jsonb_build_object('kind', r.kind, 'original', r.original_id, 'replacement', r.replacement_id)), '[]')
                     from public.character_background_replacements r where r.character_id = p_character),
    'feat', feat, 'features', v -> 'features', 'choices', choices, 'open_choices', open_n,
    'characteristics', cb.characteristics, 'characteristic_tables', v -> 'characteristics', 'notes', cb.notes,
    'equipment', v -> 'equipment', 'equipment_applied', equip,
    'equipment_applied_here', exists (select 1 from public.character_background_equipment e where e.character_id = p_character and e.version_id = cb.version_id),
    'warnings', warnings, 'duplicate_rule', v ->> 'duplicate_rule');
end;
$$;

-- =============================================================================
-- Equipment review and application (once per character and background version)
-- =============================================================================
create function public.preview_background_equipment(p_character uuid, p_package text)
returns jsonb
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
declare cb public.character_backgrounds; p public.background_equipment_packages; out jsonb := '[]'; e record; chosen text; inv uuid;
begin
  if auth.uid() is null or not public.can_access_character(p_character) then
    raise exception 'Character not found' using errcode = '42501';
  end if;
  select * into cb from public.character_backgrounds where character_id = p_character;
  if not found then raise exception 'Choose a background first' using errcode = '22023'; end if;
  select * into p from public.background_equipment_packages where version_id = cb.version_id and key = p_package;
  if not found then raise exception 'This background has no equipment option "%"', p_package using errcode = '22023'; end if;
  select id into inv from public.inventories where character_id = p_character and kind = 'character';
  for e in select x.*, it.name as item_name from public.background_equipment_entries x left join public.items it on it.id = x.item_id
           where x.package_id = p.id order by x.seq loop
    chosen := null;
    if e.from_choice is not null then
      select x.option_id into chosen from public.character_background_choices x
      join public.background_choices c on c.id = x.choice_id where x.character_id = p_character and c.version_id = cb.version_id and c.key = e.from_choice
      order by x.pick limit 1;
    end if;
    out := out || jsonb_build_object('seq', e.seq, 'label', e.label, 'quantity', e.quantity, 'note', e.note,
      'item_id', coalesce(e.item_id, chosen), 'name', coalesce(e.item_name, (select name from public.items where id = chosen), e.label),
      'status', case when e.item_id is not null or chosen is not null then 'resolved'
                     when e.from_choice is not null then 'needs_choice'
                     when e.category_id is not null then 'pick'
                     else 'not_in_catalog' end,
      'category_id', e.category_id,
      'pick_options', case when e.category_id is not null then (select coalesce(jsonb_agg(jsonb_build_object('id', i.id, 'name', i.name) order by i.name), '[]')
                                                              from public.items i where i.category_id = e.category_id and i.owner_id is null) end,
      'owned', (select coalesce(sum(ii.quantity), 0) from public.inventory_items ii where ii.inventory_id = inv and ii.item_id = coalesce(e.item_id, chosen)));
  end loop;
  return jsonb_build_object('package', p.key, 'label', p.label, 'coins', p.coins, 'entries', out,
    'already_applied', exists (select 1 from public.character_background_equipment x where x.character_id = p_character and x.version_id = cb.version_id),
    'note', 'Items are added to the inventory once. Changing or removing the background later never removes them.');
end;
$$;

-- p_picks: {"<seq>": "<item id>"} for entries where an item of a category is picked (Wayfarer: any gaming set)
create function public.apply_background_equipment(p_character uuid, p_package text, p_picks jsonb default '{}'::jsonb)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare cb public.character_backgrounds; pv jsonb; e jsonb; inv uuid; ids uuid[] := '{}'; noted jsonb := '[]'; item text; coins jsonb; b text; name text;
begin
  if auth.uid() is null or not public.can_access_character(p_character) then
    raise exception 'Character not found' using errcode = '42501';
  end if;
  perform 1 from public.characters where id = p_character for update;            -- one application at a time
  select * into cb from public.character_backgrounds where character_id = p_character;
  if not found then raise exception 'Choose a background first' using errcode = '22023'; end if;
  if exists (select 1 from public.character_background_equipment where character_id = p_character and version_id = cb.version_id) then
    raise exception 'The equipment of this background was already added' using errcode = '23505';
  end if;
  pv := public.preview_background_equipment(p_character, p_package);
  select id into inv from public.inventories where character_id = p_character and kind = 'character';
  name := (select b2.name from public.background_versions v2 join public.backgrounds b2 on b2.id = v2.background_id where v2.id = cb.version_id);
  for e in select x from jsonb_array_elements(pv -> 'entries') x loop
    item := case e ->> 'status' when 'resolved' then e ->> 'item_id'
                                when 'pick' then p_picks ->> (e ->> 'seq') end;
    if e ->> 'status' = 'needs_choice' then
      raise exception '%: make the background choice first', e ->> 'label' using errcode = '22023';
    end if;
    if e ->> 'status' = 'pick' then
      if item is null or not exists (select 1 from jsonb_array_elements(e -> 'pick_options') o where o ->> 'id' = item) then
        raise exception '%: pick one of the listed items', e ->> 'label' using errcode = '22023';
      end if;
    end if;
    if item is null then
      noted := noted || jsonb_build_array(jsonb_build_object('label', e ->> 'label', 'quantity', (e ->> 'quantity')::int, 'note', e ->> 'note'));
    else
      ids := ids || public.add_inventory_item(inv, item, (e ->> 'quantity')::int, null, format('Background equipment (%s)', name), '{}'::jsonb);
    end if;
  end loop;
  coins := pv -> 'coins';
  for b in select jsonb_object_keys(coins) loop
    if b not in ('cp', 'sp', 'ep', 'gp', 'pp') then raise exception 'Unknown coin "%"', b using errcode = '22023'; end if;
    execute format('update public.characters set %I = %I + $1 where id = $2', b, b) using (coins ->> b)::int, p_character;
  end loop;
  insert into public.character_background_equipment (character_id, version_id, package_key, inventory_item_ids, coins, noted, applied_by)
  values (p_character, cb.version_id, p_package, ids, coins, noted, auth.uid());
  return jsonb_build_object('added', cardinality(ids), 'coins', coins, 'noted', noted);
end;
$$;

revoke all on function public._character_background_grants(uuid), public._character_background_abilities(uuid),
  public._background_layer(uuid, jsonb), public._background_version_json(text), public.get_background_catalog(),
  public.set_character_background(uuid, text, jsonb, jsonb, jsonb, jsonb), public.clear_character_background(uuid),
  public.get_character_background(uuid), public.preview_background_equipment(uuid, text),
  public.apply_background_equipment(uuid, text, jsonb) from public, anon;
grant execute on function public._character_background_grants(uuid), public._character_background_abilities(uuid),
  public._background_layer(uuid, jsonb), public._background_version_json(text), public.get_background_catalog(),
  public.set_character_background(uuid, text, jsonb, jsonb, jsonb, jsonb), public.clear_character_background(uuid),
  public.get_character_background(uuid), public.preview_background_equipment(uuid, text),
  public.apply_background_equipment(uuid, text, jsonb) to authenticated;
grant execute on function public.get_background_catalog(), public._background_version_json(text) to anon;

-- ---- edited copies of existing functions (privileges are kept by create or replace) ----

CREATE OR REPLACE FUNCTION public._derived_stats_core(p_character uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
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
  bg_alloc jsonb := '{}'; bg_bonus int; lin_after int;
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

  bg_alloc := public._character_background_abilities(p_character);         -- 2024 background increases (20261017001200)
  -- abilities: base score, highest active override (never lowers the score), plus additive bonuses (max 30)
  foreach k in array array['str', 'dex', 'con', 'int', 'wis', 'cha'] loop
    base_score := (to_jsonb(c) ->> (case k when 'str' then 'strength' when 'dex' then 'dexterity' when 'con' then 'constitution'
                                          when 'int' then 'intelligence' when 'wis' then 'wisdom' else 'charisma' end))::int;
    select max((e ->> 'value')::int) into override_score from jsonb_array_elements(effects) e
    where (e ->> 'applied')::boolean and e ->> 'effect_type' = 'ability_override' and e ->> 'target' = k;
    bonus := public._effect_total(effects, 'ability_bonus', k);
    lin_bonus := coalesce((select sum((e ->> 'value')::int) from jsonb_array_elements(leff) e
                           where (e ->> 'active')::boolean and e ->> 'effect_type' = 'ability_bonus' and e ->> 'target' = k), 0);
    lin_after := case when lin_included then base_score else greatest(base_score, least(20, base_score + lin_bonus)) end;
    bg_bonus := coalesce((bg_alloc ->> k)::int, 0);
    after_lineage := greatest(lin_after, least(20, lin_after + bg_bonus));      -- background after the lineage, both up to 20
    score := least(30, greatest(after_lineage, coalesce(override_score, 0)) + bonus);
    scores := scores || jsonb_build_object(k, score);
    mods := mods || jsonb_build_object(k, public._ability_mod(score));
    abilities := abilities || jsonb_build_object(k, jsonb_build_object('base', base_score, 'score', score,
      'modifier', public._ability_mod(score), 'override', override_score, 'bonus', bonus,
      'lineage_bonus', lin_bonus, 'lineage_applied', lin_after - base_score, 'lineage_included', lin_included,
      'background_bonus', bg_bonus, 'background_applied', after_lineage - lin_after,
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

  return public._background_layer(p_character, jsonb_build_object(
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
                                                                    where (e ->> 'active')::boolean and e ->> 'effect_type' = 'carrying_capacity'), 0))));
end;
$function$;

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
     from public._character_class_effects(p_character) e
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

CREATE OR REPLACE FUNCTION public.get_character_class_features(p_character uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
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
          where (coalesce((d -> 'skills' -> k ->> 'lineage_proficient')::boolean, false) or coalesce((d -> 'skills' -> k ->> 'background_proficient')::boolean, false)) or coalesce((d -> 'skills' -> k ->> 'class_proficient')::boolean, false)
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
             'castable_level', case when ch.config ->> 'max_spell_level' = 'castable' then
                                 (select coalesce(lv.max_spell_level, 0) from public.class_version_levels lv
                                  where lv.class_version_id = cr.class_version_id and lv.level = cr.class_level) end,
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
                                 (select i.name from public.items i where i.id = v and i.owner_id is null and i.kind_id = 'tool'),
                                 case when v ~ '^feat:' then 'Feat: ' || substr(v, 6) when v ~ '^text:' then substr(v, 6)
                                      when v ~ '^(str|dex|con|int|wis|cha):[0-9]+$' then upper(split_part(v, ':', 1)) || ' +' || split_part(v, ':', 2) end,
                                 v),
                                 'prerequisite', (select public._cf_prereq(o.prerequisites, ctx || jsonb_build_object('class_level', ch.class_level,
                                                    'total_level', (li ->> 'total_level')::int, 'subclass_version_id', cr.subclass_version_id,
                                                    'confirmed', ch.manual_status = 'confirmed'))
                                                  from public.class_feature_choice_options o where o.choice_id = ch.choice_id and o.option_id = v))
                                 order by ord), '[]') from unnest(ch.vals) with ordinality u(v, ord)),
             'tool_options', (select coalesce(jsonb_agg(jsonb_build_object('id', i.id, 'label', i.name) order by i.name), '[]')
                              from public.items i where ch.kind = 'expertise' and ch.config ? 'tools' and ch.config -> 'tools' ? i.id),
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
             'activation', fv.activation, 'repeatable', fv.repeatable, 'prerequisite', u.prerequisite, 'category', fv.category,
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
             'implementation_status', s.implementation_status, 'source_status', s.source_status, 'setting', s.setting,
             'dm_permission_note', s.dm_permission_note, 'dependency_group', s.dependency_group, 'feature_notes', s.feature_notes,
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
      'spellcasting', (select jsonb_build_object('max_spell_level', lv.max_spell_level, 'cantrips_known', lv.cantrips_known,
                         'spells_known', lv.spells_known, 'pact_slot_level', lv.pact_slot_level)
                       from public.class_version_levels lv where lv.class_version_id = cr.class_version_id and lv.level = cr.class_level),
      'version', (select jsonb_build_object('rules_label', v.rules_label, 'source_label', v.source_label, 'source_url', v.source_url,
                    'hit_die', v.hit_die, 'primary_abilities', to_jsonb(v.primary_abilities), 'saving_throws', to_jsonb(v.saving_throws),
                    'feature_status', v.feature_status, 'feature_notes', v.feature_notes, 'status', v.status)
                  from public.class_versions v where v.id = cr.class_version_id),
      'subclass_label', (select fv.name from public.class_feature_unlocks u join public.class_feature_choices ch on ch.feature_version_id = u.feature_version_id
                         join public.class_feature_versions fv on fv.id = u.feature_version_id
                         where u.class_version_id = cr.class_version_id and ch.kind = 'subclass' limit 1),
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
$function$;

CREATE OR REPLACE FUNCTION public.get_character_derived_stats(p_character uuid)
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
  from public._character_class_effects(p_character) x where x.feature_active;
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

create or replace function public.get_character_proficiencies(p_character uuid)
returns jsonb
language plpgsql stable
set search_path = public, pg_temp
as $$
declare c public.characters; d jsonb; lin text; groups jsonb; items jsonb; skills jsonb; saves jsonb; tools jsonb; langs jsonb;
  warnings jsonb := '[]';
begin
  select * into c from public.characters where id = p_character;
  if not found or auth.uid() is null then
    raise exception 'Character not found' using errcode = '42501';
  end if;
  d := public.get_character_derived_stats(p_character);
  lin := coalesce(d -> 'lineage' ->> 'subversion_name', d -> 'lineage' ->> 'name');

  -- every derived or manual group / item proficiency with its source, deduplicated per (kind, label)
  with p as (
    select x, coalesce(x ->> 'group_id', x ->> 'item_id') as target, x ->> 'group_id' is not null as is_group,
           public._proficiency_source(x ->> 'source_type', coalesce(x ->> 'notes', x ->> 'name'), x, lin) as src
    from jsonb_array_elements(coalesce(d -> 'proficiencies', '[]')) x),
  srcs as (select target, is_group, min(x ->> 'proficiency_type') as ptype, min(x ->> 'name') as name,
                  jsonb_agg(distinct src) as sources, bool_or(src ->> 'kind' in ('manual', 'import')) as manual,
                  bool_or(src ->> 'kind' not in ('manual', 'import')) as derived
           from p group by target, is_group)
  select coalesce(jsonb_agg(jsonb_build_object('type', g.proficiency_type, 'id', g.id, 'name', g.name,
           'effective', s.target is not null, 'level', case when s.target is not null then 1 else 0 end,
           'manual', coalesce(s.manual, false), 'manual_level', case when coalesce(s.manual, false) then 1 else 0 end,
           'derived', coalesce(s.derived, false), 'editable', true, 'sources', coalesce(s.sources, '[]'))
           order by g.sort_order), '[]'),
         (select coalesce(jsonb_agg(jsonb_build_object('type', s2.ptype, 'id', s2.target, 'name', s2.name, 'effective', true, 'level', 1,
                   'manual', s2.manual, 'manual_level', case when s2.manual then 1 else 0 end, 'derived', s2.derived,
                   'editable', true, 'sources', s2.sources) order by s2.ptype, s2.name), '[]')
          from srcs s2 where not s2.is_group)
  into groups, items
  from public.proficiency_groups g left join srcs s on s.is_group and s.target = g.id;

  -- skills: manual level (0 / 1 / 2) stored on the character; class, feature and lineage sources from the derived model
  select coalesce(jsonb_agg(jsonb_build_object('type', 'skill', 'id', sk.id, 'name', sk.name, 'ability', sk.ability,
           'effective', greatest(m.lvl, dv.lvl) > 0, 'level', greatest(m.lvl, dv.lvl), 'manual', m.lvl > 0, 'manual_level', m.lvl,
           'derived', dv.lvl > 0, 'expertise', greatest(m.lvl, dv.lvl) = 2, 'editable', true,
           'sources', (case when m.lvl > 0 then jsonb_build_array(jsonb_build_object('kind', 'manual', 'label', 'Manual',
                                                  'detail', case when m.lvl = 2 then 'Expertise' end)) else '[]' end) || dv.sources)
           order by sk.name), '[]')
  into skills
  from public.skills sk
  cross join lateral (select public._skill_level(c.skill_proficiencies -> sk.id) as lvl) m
  cross join lateral (
    select case when coalesce((d -> 'skills' -> sk.id ->> 'class_expertise')::boolean, false) then 2
                when coalesce((d -> 'skills' -> sk.id ->> 'class_proficient')::boolean, false)
                  or coalesce((d -> 'skills' -> sk.id ->> 'lineage_proficient')::boolean, false)
                  or coalesce((d -> 'skills' -> sk.id ->> 'background_proficient')::boolean, false) then 1 else 0 end as lvl,
           coalesce((select jsonb_agg(distinct public._proficiency_source(x ->> 'source_type', x ->> 'source_name', x, lin))
                     from jsonb_array_elements(coalesce(d -> 'skills' -> sk.id -> 'proficiency_sources', '[]')) x), '[]')
           || coalesce((select jsonb_agg(distinct public._proficiency_source(x ->> 'source_type', x ->> 'source_name', x, lin)
                                         || jsonb_build_object('expertise', true))
                        from jsonb_array_elements(coalesce(d -> 'skills' -> sk.id -> 'expertise_sources', '[]')) x), '[]') as sources) dv;

  -- saving throws: manual flag on the character, class grants (first class only) from the derived model
  select coalesce(jsonb_agg(jsonb_build_object('type', 'save', 'id', a.k, 'name', a.name,
           'effective', m.on or dv.on, 'level', case when m.on or dv.on then 1 else 0 end, 'manual', m.on,
           'manual_level', case when m.on then 1 else 0 end, 'derived', dv.on, 'editable', true,
           'sources', (case when m.on then '[{"kind": "manual", "label": "Manual"}]'::jsonb else '[]' end) || dv.sources)
           order by a.n), '[]')
  into saves
  from (values (1, 'str', 'Strength'), (2, 'dex', 'Dexterity'), (3, 'con', 'Constitution'), (4, 'int', 'Intelligence'),
               (5, 'wis', 'Wisdom'), (6, 'cha', 'Charisma')) a(n, k, name)
  cross join lateral (select coalesce((c.save_proficiencies ->> a.k)::boolean, false) as on) m
  cross join lateral (
    select coalesce((d -> 'saving_throws' -> a.k ->> 'class_proficient')::boolean, false)
             or jsonb_array_length(coalesce(d -> 'saving_throws' -> a.k -> 'background_sources', '[]')) > 0 as on,
           coalesce((select jsonb_agg(distinct public._proficiency_source('class', x #>> '{}', '{}', lin))
                     from jsonb_array_elements(coalesce(d -> 'saving_throws' -> a.k -> 'class_sources', '[]')) x), '[]') as sources) dv;

  -- tools: item proficiencies of type tool (any source) and tool expertise
  select coalesce(jsonb_agg(t || jsonb_build_object('expertise',
           exists (select 1 from jsonb_array_elements(coalesce(d -> 'tool_expertise', '[]')) e where e ->> 'item_id' = t ->> 'id'))), '[]')
  into tools
  from jsonb_array_elements(items) t where t ->> 'type' = 'tool';

  -- languages: lineage and class grants, merged per language (manual languages are free text on the sheet)
  select coalesce(jsonb_agg(jsonb_build_object('type', 'language', 'id', l.id, 'name', l.name, 'effective', true, 'level', 1,
           'manual', false, 'manual_level', 0, 'derived', true, 'editable', false, 'sources', l.sources) order by l.ord, l.name), '[]')
  into langs
  from (select x ->> 'id' as id, min(x ->> 'name') as name, min(coalesce(lg.sort_order, 999)) as ord,
               jsonb_agg(distinct case when s #>> '{}' like 'Background: %' then public._proficiency_source('background', substr(s #>> '{}', 13), '{}', lin)
                                       when s #>> '{}' like '%: %' then public._proficiency_source('class', s #>> '{}', '{}', lin)
                                       else public._proficiency_source('lineage', s #>> '{}', '{}', lin) end) as sources
        from jsonb_array_elements(coalesce(d -> 'languages', '[]')) x
        cross join lateral jsonb_array_elements(coalesce(x -> 'sources', '[]')) s
        left join public.languages lg on lg.id = x ->> 'id'
        group by x ->> 'id') l;

  -- a manual mark that a class / lineage also grants: kept (it survives removing the other source), only noted
  select coalesce(jsonb_agg(jsonb_build_object('code', 'manual_also_granted', 'type', e ->> 'type', 'id', e ->> 'id', 'name', e ->> 'name',
           'message', format('%s is also granted by %s; your manual mark is kept.', e ->> 'name',
             (select string_agg(s ->> 'label', ', ') from jsonb_array_elements(e -> 'sources') s where s ->> 'kind' not in ('manual', 'import'))))), '[]')
  into warnings
  from jsonb_array_elements(groups || items || skills || saves) e
  where (e ->> 'manual')::boolean and (e ->> 'derived')::boolean and (e ->> 'manual_level')::int >= (e ->> 'level')::int;

  return jsonb_build_object('character_id', p_character, 'groups', groups, 'items', items, 'skills', skills, 'saves', saves,
    'tools', tools, 'languages', langs, 'warnings', warnings,
    'armor', jsonb_build_object('nonproficient_armor', coalesce((d -> 'armor_consequences' ->> 'nonproficient_armor')::boolean, false),
                                'nonproficient_shield', coalesce((d -> 'armor_consequences' ->> 'nonproficient_shield')::boolean, false)));
end;
$$;