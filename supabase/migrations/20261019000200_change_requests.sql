-- =============================================================================
-- Change requests: approval-ready character changes (docs/APPROVAL_WORKFLOWS.md).
--
-- A request holds a list of operations (ops). Every op is one call of an existing, governed domain RPC, registered in
-- change_request_ops with a typed argument list; nothing else can be proposed (no free SQL, no unsupported grant).
-- The character argument is always the request's character; row references (class row, spellcasting source, spell row,
-- inventory) are checked to belong to it, and may be symbolic ($class:<class id>, $class_source:<class id>) so one
-- level-up request can add a class and then fill that class's choices.
--
-- Preview: the ops are applied inside a sub-transaction as the caller (approval_required gates pass only inside the
-- preview), a review snapshot is taken before and after, then the sub-transaction is rolled back. Nothing persists.
-- Approve: the DM locks the request, the revision and the baseline (stale detection) are checked, then the ops run in
-- one sub-block through the same domain RPCs. A failure rolls the whole application back and marks apply_failed.
-- Statuses: draft, submitted, returned_for_changes, approved, rejected, cancelled, superseded, applied, apply_failed.
-- Rollback: supabase/rollback/rollback_change_requests.sql.
-- =============================================================================

create table public.change_request_ops (
  op              text primary key check (op ~ '^[a-z_]+$'),
  function_name   text not null,
  action_key      text not null references public.governance_actions (action_key),
  character_param text,                       -- null: the function has no character parameter (row arguments identify it)
  args            jsonb not null default '{}' check (jsonb_typeof(args) = 'object'),   -- {"p_x": "int!"}; "!" = required
  label           text not null,
  sort_order      int not null default 0
);

insert into public.change_request_ops (op, function_name, action_key, character_param, args, label, sort_order) values
  ('set_character_class', 'set_character_class', 'build.class_level', 'p_character',
   '{"p_class_version": "text!", "p_level": "int!", "p_subclass_version": "text", "p_is_primary": "bool", "p_character_class": "class_row", "p_notes": "text"}',
   'Class and level', 10),
  ('remove_character_class', 'remove_character_class', 'build.class_remove', null,
   '{"p_character_class": "class_row!", "p_confirm": "bool"}', 'Remove a class', 11),
  ('set_character_subclass', 'set_character_subclass', 'build.subclass', 'p_character',
   '{"p_character_class": "class_row!", "p_subclass_version": "text"}', 'Subclass', 12),
  ('set_character_feature_choice', 'set_character_feature_choice', 'choice.class_feature', 'p_character',
   '{"p_character_class": "class_row!", "p_unlock": "text!", "p_choice": "text!", "p_values": "text[]!", "p_manual_status": "text", "p_allow_partial": "bool"}',
   'Class feature choice', 13),
  ('set_character_optional_feature', 'set_character_optional_feature', 'choice.optional_feature', 'p_character',
   '{"p_character_class": "class_row!", "p_unlock": "text!", "p_enabled": "bool!"}', 'Optional feature', 14),
  ('set_character_lineage', 'set_character_lineage', 'build.lineage', 'p_character',
   '{"p_version": "text!", "p_subversion": "text", "p_choices": "jsonb", "p_ability_bonuses_included": "bool", "p_require_complete": "bool"}',
   'Lineage', 20),
  ('clear_character_lineage', 'clear_character_lineage', 'build.lineage', 'p_character', '{}', 'Clear the lineage', 21),
  ('set_character_background', 'set_character_background', 'build.background', 'p_character',
   '{"p_version": "text!", "p_ability": "jsonb", "p_choices": "jsonb", "p_replacements": "jsonb", "p_options": "jsonb"}', 'Background', 22),
  ('clear_character_background', 'clear_character_background', 'build.background', 'p_character', '{}', 'Clear the background', 23),
  ('apply_background_equipment', 'apply_background_equipment', 'build.background', 'p_character',
   '{"p_package": "text!", "p_picks": "jsonb"}', 'Background equipment', 24),
  ('apply_class_starting_equipment', 'apply_class_starting_equipment', 'inventory.add_mundane', 'p_character',
   '{"p_class_version": "text!", "p_selections": "jsonb!"}', 'Class starting equipment', 25),
  ('set_character_proficiency', 'set_character_proficiency', 'build.manual_proficiency', 'p_character',
   '{"p_group": "text", "p_item": "text", "p_enabled": "bool", "p_notes": "text"}', 'Proficiency', 30),
  ('update_character_build', 'update_character_build', 'build.ability_scores', 'p_character',
   '{"p_patch": "jsonb!"}', 'Ability scores, maximum HP and manual values', 31),
  ('set_character_spell', 'set_character_spell', 'spell.learn_known', 'p_character',
   '{"p_source": "source_row!", "p_spell_version": "text!", "p_known": "bool", "p_prepared": "bool", "p_always_prepared": "bool", "p_casting_ability": "text", "p_ritual_allowed": "bool", "p_notes": "text"}',
   'Spell', 40),
  ('remove_character_spell', 'remove_character_spell', 'spell.remove', null, '{"p_character_spell": "spell_row!"}', 'Remove a spell', 41),
  ('save_character_spellcasting_source', 'save_character_spellcasting_source', 'spell.change_source', 'p_character',
   '{"p_source": "jsonb!"}', 'Spellcasting source', 42),
  ('add_inventory_item', 'add_inventory_item', 'inventory.add_magic', null,
   '{"p_inventory": "char_inventory", "p_item": "text!", "p_quantity": "int", "p_custom_name": "text", "p_notes": "text"}', 'Item', 50),
  ('add_character_companion', 'add_character_companion', 'build.companion', 'p_character',
   '{"p_creature": "text!", "p_name": "text", "p_source": "text", "p_hp_max": "int"}', 'Companion', 60),
  ('set_seen_forms', 'set_seen_forms', 'runtime.mark_seen_form', 'p_character',
   '{"p_creatures": "text[]!", "p_seen": "bool", "p_source": "text", "p_note": "text"}', 'Seen Wild Shape forms', 61),
  ('long_rest_character', 'long_rest_character', 'runtime.long_rest', 'p_character', '{"p_rest_id": "uuid"}', 'Long rest', 70);

create table public.change_requests (
  id                 uuid primary key default gen_random_uuid(),
  campaign_id        uuid not null references public.campaigns (id) on delete cascade,
  character_id       uuid not null references public.characters (id) on delete cascade,
  requested_by       uuid not null references public.profiles (id) on delete cascade,
  category           text not null,
  action_type        text not null references public.governance_actions (action_key),
  title              text not null check (length(title) between 1 and 120),
  target_type        text,
  target_id          text,
  status             text not null default 'draft' check (status in ('draft', 'submitted', 'returned_for_changes', 'approved',
                       'rejected', 'cancelled', 'superseded', 'applied', 'apply_failed')),
  ops                jsonb not null default '[]' check (jsonb_typeof(ops) = 'array'),
  ops_version        int not null default 1,
  approved_ops       jsonb check (approved_ops is null or jsonb_typeof(approved_ops) = 'array'),
  edited_by_dm       boolean not null default false,
  preview            jsonb,                 -- the last structured diff (validated proposal)
  baseline           jsonb,                 -- character state the proposal was built on
  baseline_hash      text,
  stale              boolean not null default false,
  stale_details      jsonb,
  ruleset            text,
  reason             text check (length(reason) <= 1000),
  player_note        text check (length(player_note) <= 2000),
  review_note        text check (length(review_note) <= 2000),   -- the DM's message to the player
  apply_error        text,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  submitted_at       timestamptz,
  reviewed_at        timestamptz,
  reviewed_by        uuid references public.profiles (id) on delete set null,
  applied_at         timestamptz,
  expires_at         timestamptz,
  related_request_id uuid references public.change_requests (id) on delete set null,
  idempotency_key    uuid,
  revision           int not null default 1,
  unique (requested_by, idempotency_key)
);
create index change_requests_campaign on public.change_requests (campaign_id, status, submitted_at desc);
create index change_requests_character on public.change_requests (character_id, status);
-- one open draft (the pending tray) per character and requester; checked at commit, because create_change_request with
-- p_submit inserts a draft and submits it in the same transaction while the player may already have a tray draft
alter table public.change_requests add constraint change_requests_one_draft
  exclude using btree (character_id with =, requested_by with =) where (status = 'draft') deferrable initially deferred;

create table public.change_request_events (
  id         uuid primary key default gen_random_uuid(),
  request_id uuid not null references public.change_requests (id) on delete cascade,
  actor_id   uuid references public.profiles (id) on delete set null,
  event      text not null check (event in ('created', 'edited', 'submitted', 'returned', 'resubmitted', 'approved', 'rejected',
                                              'cancelled', 'superseded', 'applied', 'apply_failed', 'stale', 'refreshed')),
  note       text,
  detail     jsonb,
  created_at timestamptz not null default now()
);
create index change_request_events_request on public.change_request_events (request_id, created_at);

-- DM-only notes on a request (never in a player read model, never in Realtime)
create table public.change_request_private_notes (
  request_id uuid primary key references public.change_requests (id) on delete cascade,
  note       text not null check (length(note) <= 2000),
  updated_by uuid references public.profiles (id) on delete set null,
  updated_at timestamptz not null default now()
);

alter table public.campaign_audit_events
  add constraint campaign_audit_events_request_fkey foreign key (request_id) references public.change_requests (id) on delete set null;

-- ---- argument validation and resolution ---------------------------------------------------------------------------------
-- Validates one op (keys, types, references) and returns it normalized: {"op": ..., "args": {...}}.
create function public._cr_normalize_op(p_character uuid, p_op jsonb)
returns jsonb
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
declare spec public.change_request_ops; k text; t text; v jsonb; req boolean; base text; out jsonb := '{}'; ref text;
begin
  if p_op is null or jsonb_typeof(p_op) <> 'object' or jsonb_typeof(p_op -> 'op') <> 'string' then
    raise exception 'Each change needs an "op"' using errcode = '22023';
  end if;
  select * into spec from public.change_request_ops where op = p_op ->> 'op';
  if spec.op is null then raise exception 'This kind of change cannot be requested: %', p_op ->> 'op' using errcode = '22023'; end if;
  if p_op ? 'args' and jsonb_typeof(p_op -> 'args') <> 'object' then raise exception 'args must be an object' using errcode = '22023'; end if;
  for k in select jsonb_object_keys(coalesce(p_op -> 'args', '{}')) loop
    if not spec.args ? k then raise exception '"%" is not an argument of %', k, spec.label using errcode = '22023'; end if;
  end loop;
  for k, t in select * from jsonb_each_text(spec.args) loop
    req := t like '%!'; base := rtrim(t, '!');
    v := p_op -> 'args' -> k;
    if base = 'char_inventory' then
      out := out || jsonb_build_object(k, '$inventory');   -- always the character's own inventory
      continue;
    end if;
    if v is null or jsonb_typeof(v) = 'null' then
      if req then raise exception '% needs "%"', spec.label, k using errcode = '22023'; end if;
      continue;
    end if;
    case base
      when 'text' then if jsonb_typeof(v) <> 'string' or length(v #>> '{}') > 200 then raise exception '% must be a short text', k using errcode = '22023'; end if;
      when 'int' then if jsonb_typeof(v) <> 'number' or (v #>> '{}')::numeric <> trunc((v #>> '{}')::numeric) then raise exception '% must be a whole number', k using errcode = '22023'; end if;
      when 'bool' then if jsonb_typeof(v) <> 'boolean' then raise exception '% must be true or false', k using errcode = '22023'; end if;
      when 'uuid' then if public.try_uuid(v #>> '{}') is null then raise exception '% must be an id', k using errcode = '22023'; end if;
      when 'jsonb' then if length(v::text) > 20000 then raise exception '% is too large', k using errcode = '22023'; end if;
      when 'text[]' then
        if jsonb_typeof(v) <> 'array' or jsonb_array_length(v) > 50
           or exists (select 1 from jsonb_array_elements(v) e where jsonb_typeof(e) <> 'string' or length(e #>> '{}') > 200) then
          raise exception '% must be a list of texts', k using errcode = '22023';
        end if;
      when 'class_row' then
        ref := v #>> '{}';
        if ref like '$class:%' then null;
        elsif public.try_uuid(ref) is null or not exists (select 1 from public.character_classes where id = ref::uuid and character_id = p_character) then
          raise exception 'The class row of % does not belong to this character', spec.label using errcode = '22023';
        end if;
      when 'source_row' then
        ref := v #>> '{}';
        if ref like '$class_source:%' or ref like '$feat_source:%' then null;
        elsif public.try_uuid(ref) is null or not exists (select 1 from public.character_spellcasting_sources where id = ref::uuid and character_id = p_character) then
          raise exception 'The spellcasting source does not belong to this character' using errcode = '22023';
        end if;
      when 'spell_row' then
        ref := v #>> '{}';
        if public.try_uuid(ref) is null or not exists (select 1 from public.character_spells where id = ref::uuid and character_id = p_character) then
          raise exception 'The spell does not belong to this character' using errcode = '22023';
        end if;
      when 'feat_row' then
        ref := v #>> '{}';
        if public.try_uuid(ref) is null or not exists (select 1 from public.character_feats where id = ref::uuid and character_id = p_character) then
          raise exception 'The feat does not belong to this character' using errcode = '22023';   -- character_feats: 20261019000300
        end if;
      else raise exception 'Unknown argument type %', base using errcode = '22023';
    end case;
    out := out || jsonb_build_object(k, v);
  end loop;
  return jsonb_build_object('op', spec.op, 'args', out);
end;
$$;

create function public._cr_normalize_ops(p_character uuid, p_ops jsonb)
returns jsonb
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
declare o jsonb; out jsonb := '[]';
begin
  if p_ops is null or jsonb_typeof(p_ops) <> 'array' then raise exception 'The changes must be a list' using errcode = '22023'; end if;
  if jsonb_array_length(p_ops) > 40 then raise exception 'A request holds at most 40 changes' using errcode = '22023'; end if;
  for o in select x from jsonb_array_elements(p_ops) x loop
    out := out || jsonb_build_array(public._cr_normalize_op(p_character, o));
  end loop;
  return out;
end;
$$;

-- symbolic references -> ids at the time of execution
create function public._cr_resolve(p_character uuid, p_type text, p_value text)
returns text
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
declare r uuid;
begin
  if p_type = 'class_row' and p_value like '$class:%' then
    select id into r from public.character_classes where character_id = p_character and class_id = substr(p_value, 8);
    if r is null then raise exception 'The character has no % class (yet)', substr(p_value, 8) using errcode = '22023'; end if;
    return r::text;
  elsif p_type = 'source_row' and p_value like '$class_source:%' then
    select s.id into r from public.character_spellcasting_sources s join public.character_classes cc on cc.id = s.character_class_id
    where s.character_id = p_character and cc.class_id = substr(p_value, 15);
    if r is null then raise exception 'The character has no spellcasting source of the % class', substr(p_value, 15) using errcode = '22023'; end if;
    return r::text;
  elsif p_type = 'char_inventory' then
    select id into r from public.inventories where character_id = p_character and kind = 'character' order by created_at limit 1;
    return r::text;
  end if;
  return p_value;
end;
$$;

-- execute one normalized op through its domain RPC (function names and argument names come from the registry only)
create function public._cr_exec_op(p_character uuid, p_op jsonb)
returns void
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare spec public.change_request_ops; k text; t text; base text; parts text[] := '{}'; args jsonb := '{}'; v jsonb;
begin
  select * into spec from public.change_request_ops where op = p_op ->> 'op';
  if spec.op is null then raise exception 'Unknown change %', p_op ->> 'op' using errcode = '22023'; end if;
  for k, t in select * from jsonb_each_text(spec.args) loop
    base := rtrim(t, '!');
    v := p_op -> 'args' -> k;
    if v is null then continue; end if;
    if base in ('class_row', 'source_row', 'char_inventory') then
      v := to_jsonb(public._cr_resolve(p_character, base, v #>> '{}'));
    end if;
    args := args || jsonb_build_object(k, v);
    parts := parts || format('%I => %s', k, case base
      when 'text' then format('($2 ->> %L)', k)
      when 'int' then format('($2 ->> %L)::int', k)
      when 'bool' then format('($2 ->> %L)::boolean', k)
      when 'jsonb' then format('($2 -> %L)', k)
      when 'text[]' then format('array(select jsonb_array_elements_text($2 -> %L))', k)
      else format('($2 ->> %L)::uuid', k) end);
  end loop;
  if spec.character_param is not null then parts := format('%I => $1', spec.character_param) || parts; end if;
  execute format('select public.%I(%s)', spec.function_name, array_to_string(parts, ', ')) using p_character, args;
end;
$$;

-- ---- review snapshot, baseline, diff -------------------------------------------------------------------------------------
-- Scalars and lists a reviewer reads; redefined by later migrations that add layers (feats).
create function public._cr_snapshot(p_character uuid)
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
    'Maximum HP', c.hp_max,
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
    'Seen forms', (select coalesce(jsonb_agg(cr.name order by cr.name), '[]')
                   from public.character_seen_forms sf join public.creatures cr on cr.id = sf.creature_id where sf.character_id = p_character));
  return jsonb_build_object('scalars', sc, 'lists', li);
end;
$$;

-- what a proposal assumes about the character (stale detection); redefined by later layers
create function public._cr_baseline(p_character uuid)
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
    'companions', (select count(*) from public.character_companions x where x.character_id = p_character));
$$;

create function public._cr_diff(p_before jsonb, p_after jsonb)
returns jsonb
language sql immutable
set search_path = public, pg_temp
as $$
  select coalesce((select jsonb_agg(jsonb_build_object('label', k, 'kind', 'changed', 'before', p_before -> 'scalars' -> k,
                                                       'after', p_after -> 'scalars' -> k) order by k)
                   from jsonb_object_keys(coalesce(p_after -> 'scalars', '{}')) k
                   where (p_before -> 'scalars' -> k) is distinct from (p_after -> 'scalars' -> k)), '[]')
      || coalesce((select jsonb_agg(jsonb_build_object('label', k, 'kind', 'list',
                     'added', (select coalesce(jsonb_agg(a), '[]') from jsonb_array_elements(p_after -> 'lists' -> k) a
                               where not coalesce(p_before -> 'lists' -> k, '[]') @> jsonb_build_array(a)),
                     'removed', (select coalesce(jsonb_agg(b), '[]') from jsonb_array_elements(coalesce(p_before -> 'lists' -> k, '[]')) b
                                 where not (p_after -> 'lists' -> k) @> jsonb_build_array(b))) order by k)
                   from jsonb_object_keys(coalesce(p_after -> 'lists', '{}')) k
                   where (p_before -> 'lists' -> k) is distinct from (p_after -> 'lists' -> k)), '[]');
$$;

-- Apply the ops in a sub-transaction and roll it back: {ok, error, code, diff, before, after, warnings}.
create function public._cr_simulate(p_character uuid, p_ops jsonb)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare before jsonb; after jsonb; o jsonb; n int := 0; err text; code text; failed_op text;
begin
  before := public._cr_snapshot(p_character);
  begin
    perform set_config('tavern.gov_preview', p_character::text, true);
    for o in select x from jsonb_array_elements(p_ops) x loop
      n := n + 1; failed_op := o ->> 'op';
      perform public._cr_exec_op(p_character, o);
    end loop;
    after := public._cr_snapshot(p_character);
    raise exception 'preview rollback' using errcode = 'TLPRV';
  exception
    when sqlstate 'TLPRV' then null;
    when others then err := sqlerrm; code := sqlstate;
  end;
  if err is not null then
    return jsonb_build_object('ok', false, 'error', err, 'code', code, 'failed_step', n, 'failed_op', failed_op,
                              'before', before, 'diff', '[]'::jsonb);
  end if;
  return jsonb_build_object('ok', true, 'before', before, 'after', after, 'diff', public._cr_diff(before, after),
    'warnings', (select coalesce(jsonb_agg(x), '[]') from jsonb_array_elements(coalesce(after -> 'lists' -> 'Open choices', '[]')) x
                 where not coalesce(before -> 'lists' -> 'Open choices', '[]') @> jsonb_build_array(x)));
end;
$$;

-- ---- read models ---------------------------------------------------------------------------------------------------------
create function public._cr_json(p_request uuid, p_dm boolean)
returns jsonb
language sql stable security definer
set search_path = public, pg_temp
as $$
  select to_jsonb(r) - 'baseline' - 'baseline_hash'
    || jsonb_build_object(
      'character_name', ch.name, 'requested_by_name', coalesce(p.display_name, p.email),
      'reviewed_by_name', (select coalesce(display_name, email) from public.profiles where id = r.reviewed_by),
      'action_label', a.label, 'category_label', a.category,
      'steps', (select coalesce(jsonb_agg(jsonb_build_object('op', o ->> 'op', 'label', s.label, 'args', o -> 'args')), '[]')
                from jsonb_array_elements(coalesce(r.approved_ops, r.ops)) o left join public.change_request_ops s on s.op = o ->> 'op'),
      'history', (select coalesce(jsonb_agg(jsonb_build_object('event', e.event, 'note', e.note, 'at', e.created_at,
                    'actor', (select coalesce(display_name, email) from public.profiles where id = e.actor_id)) order by e.created_at), '[]')
                  from public.change_request_events e where e.request_id = r.id),
      'private_note', case when p_dm then (select note from public.change_request_private_notes where request_id = r.id) end)
  from public.change_requests r
  join public.characters ch on ch.id = r.character_id
  join public.governance_actions a on a.action_key = r.action_type
  left join public.profiles p on p.id = r.requested_by
  where r.id = p_request;
$$;

create function public._cr_can_review(p_campaign uuid)
returns boolean
language sql stable security definer
set search_path = public, pg_temp
as $$ select auth.uid() is not null and (public.is_admin() or public.is_campaign_dm(p_campaign)); $$;

create function public._cr_event(p_request uuid, p_event text, p_note text default null, p_detail jsonb default null)
returns void
language sql security definer
set search_path = public, pg_temp
as $$
  insert into public.change_request_events (request_id, actor_id, event, note, detail) values (p_request, auth.uid(), p_event, p_note, p_detail);
$$;

-- ---- player operations ---------------------------------------------------------------------------------------------------
-- Create a request (draft, or submitted at once). Idempotent per (requester, p_idempotency_key).
create function public.create_change_request(p_character uuid, p_ops jsonb, p_title text default null, p_reason text default null,
                                             p_player_note text default null, p_submit boolean default true,
                                             p_idempotency_key uuid default null, p_related_request uuid default null)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare ch record; v_ops jsonb; main public.change_request_ops; a public.governance_actions; rid uuid; existing uuid;
begin
  if auth.uid() is null then raise exception 'Not signed in' using errcode = '42501'; end if;
  select c.id, c.owner_id, c.campaign_id, c.name into ch from public.characters c where c.id = p_character;
  if ch.id is null or not public.can_access_character(p_character) then raise exception 'Character not found' using errcode = '42501'; end if;
  if ch.campaign_id is null then raise exception 'Only characters in a campaign need approval' using errcode = '22023'; end if;
  if ch.owner_id is distinct from auth.uid() and not public._cr_can_review(ch.campaign_id) then
    raise exception 'Only the character''s player can request changes' using errcode = '42501';
  end if;
  if p_idempotency_key is not null then
    select id into existing from public.change_requests where requested_by = auth.uid() and idempotency_key = p_idempotency_key;
    if existing is not null then return public._cr_json(existing, public._cr_can_review(ch.campaign_id)); end if;
  end if;
  v_ops := public._cr_normalize_ops(p_character, p_ops);
  if jsonb_array_length(v_ops) = 0 then raise exception 'The request has no changes' using errcode = '22023'; end if;
  select * into main from public.change_request_ops where op = v_ops -> 0 ->> 'op';
  select * into a from public.governance_actions where action_key = main.action_key;
  if p_related_request is not null and not exists (select 1 from public.change_requests where id = p_related_request and character_id = p_character) then
    raise exception 'Unknown related request' using errcode = '22023';
  end if;
  insert into public.change_requests (campaign_id, character_id, requested_by, category, action_type, title, status, ops, reason,
                                      player_note, idempotency_key, related_request_id, baseline, baseline_hash)
  values (ch.campaign_id, p_character, auth.uid(), a.category, a.action_key,
          left(coalesce(nullif(btrim(p_title), ''), main.label || ' for ' || ch.name), 120), 'draft', v_ops,
          nullif(btrim(coalesce(p_reason, '')), ''), nullif(btrim(coalesce(p_player_note, '')), ''), p_idempotency_key, p_related_request,
          public._cr_baseline(p_character), md5(public._cr_baseline(p_character)::text))
  returning id into rid;
  perform public._cr_event(rid, 'created');
  if coalesce(p_submit, true) then
    return public.submit_change_request(rid, 1);
  end if;
  return public._cr_json(rid, public._cr_can_review(ch.campaign_id));
end;
$$;

-- Add one op to the character's open draft (created when missing): the "pending changes" tray of the sheet.
create function public.add_change_request_op(p_character uuid, p_op jsonb, p_title text default null)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare r public.change_requests; v_op jsonb;
begin
  select * into r from public.change_requests where character_id = p_character and requested_by = auth.uid() and status = 'draft' for update;
  if r.id is null then
    return public.create_change_request(p_character, jsonb_build_array(p_op), p_title, null, null, false, null, null);
  end if;
  v_op := public._cr_normalize_op(p_character, p_op);
  if jsonb_array_length(r.ops) >= 40 then raise exception 'A request holds at most 40 changes' using errcode = '22023'; end if;
  update public.change_requests set ops = r.ops || jsonb_build_array(v_op), revision = r.revision + 1, updated_at = now(),
    title = case when p_title is not null and jsonb_array_length(r.ops) = 0 then left(p_title, 120) else title end
  where id = r.id;
  perform public._cr_event(r.id, 'edited', 'Added: ' || (select s.label from public.change_request_ops s where s.op = v_op ->> 'op'));
  return public._cr_json(r.id, false);
end;
$$;

-- edit a draft or a returned request (requester only)
create function public.update_change_request(p_request uuid, p_ops jsonb default null, p_title text default null, p_reason text default null,
                                             p_player_note text default null, p_expected_revision int default null)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare r public.change_requests; v_ops jsonb;
begin
  select * into r from public.change_requests where id = p_request for update;
  if r.id is null or r.requested_by is distinct from auth.uid() then raise exception 'Request not found' using errcode = '42501'; end if;
  if r.status not in ('draft', 'returned_for_changes') then
    raise exception 'Only a draft or a request returned for changes can be edited' using errcode = '22023';
  end if;
  if p_expected_revision is not null and p_expected_revision <> r.revision then
    raise exception 'This request changed meanwhile. Reload it.' using errcode = '40001';
  end if;
  v_ops := case when p_ops is null then r.ops else public._cr_normalize_ops(r.character_id, p_ops) end;
  update public.change_requests set ops = v_ops,
    title = coalesce(left(nullif(btrim(p_title), ''), 120), title),
    reason = case when p_reason is null then reason else nullif(btrim(p_reason), '') end,
    player_note = case when p_player_note is null then player_note else nullif(btrim(p_player_note), '') end,
    revision = revision + 1, updated_at = now(), stale = false, stale_details = null,
    baseline = public._cr_baseline(r.character_id), baseline_hash = md5(public._cr_baseline(r.character_id)::text)
  where id = p_request;
  perform public._cr_event(p_request, 'edited');
  return public._cr_json(p_request, false);
end;
$$;

-- Submit (or resubmit after "return for changes"): validated by a full preview; refused when the preview fails.
create function public.submit_change_request(p_request uuid, p_expected_revision int default null)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare r public.change_requests; sim jsonb; resub boolean;
begin
  select * into r from public.change_requests where id = p_request for update;
  if r.id is null or r.requested_by is distinct from auth.uid() then raise exception 'Request not found' using errcode = '42501'; end if;
  if r.status not in ('draft', 'returned_for_changes') then raise exception 'This request was already sent' using errcode = '22023'; end if;
  if p_expected_revision is not null and p_expected_revision <> r.revision then
    raise exception 'This request changed meanwhile. Reload it.' using errcode = '40001';
  end if;
  if jsonb_array_length(r.ops) = 0 then raise exception 'The request has no changes' using errcode = '22023'; end if;
  sim := public._cr_simulate(r.character_id, r.ops);
  if not (sim ->> 'ok')::boolean then
    raise exception 'This request cannot be sent: %', sim ->> 'error' using errcode = '22023', detail = coalesce(sim ->> 'code', '');
  end if;
  resub := r.status = 'returned_for_changes';
  update public.change_requests set status = 'submitted', submitted_at = now(), updated_at = now(), revision = revision + 1,
    preview = sim - 'before' - 'after', stale = false, stale_details = null,
    baseline = public._cr_baseline(r.character_id), baseline_hash = md5(public._cr_baseline(r.character_id)::text)
  where id = p_request;
  perform public._cr_event(p_request, case when resub then 'resubmitted' else 'submitted' end);
  perform public._audit(r.campaign_id, r.character_id, 'request_submitted', 'Request: ' || r.title, null, null, r.reason, p_request, 'party');
  return public._cr_json(p_request, false);
end;
$$;

create function public.cancel_change_request(p_request uuid, p_reason text default null)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare r public.change_requests; dm boolean;
begin
  select * into r from public.change_requests where id = p_request for update;
  if r.id is null then raise exception 'Request not found' using errcode = '42501'; end if;
  dm := public._cr_can_review(r.campaign_id);
  if r.requested_by is distinct from auth.uid() and not dm then raise exception 'Request not found' using errcode = '42501'; end if;
  if r.status not in ('draft', 'submitted', 'returned_for_changes', 'apply_failed') then
    raise exception 'This request is already %', replace(r.status, '_', ' ') using errcode = '22023';
  end if;
  update public.change_requests set status = 'cancelled', updated_at = now(), revision = revision + 1 where id = p_request;
  perform public._cr_event(p_request, 'cancelled', p_reason);
  return public._cr_json(p_request, dm);
end;
$$;

-- Current preview with stale detection (requester or DM). Does not change the request.
create function public.preview_change_request(p_request uuid)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare r public.change_requests; dm boolean; now_base jsonb; sim jsonb; changed jsonb;
begin
  select * into r from public.change_requests where id = p_request;
  if r.id is null then raise exception 'Request not found' using errcode = '42501'; end if;
  dm := public._cr_can_review(r.campaign_id);
  if r.requested_by is distinct from auth.uid() and not dm then raise exception 'Request not found' using errcode = '42501'; end if;
  now_base := public._cr_baseline(r.character_id);
  select coalesce(jsonb_agg(jsonb_build_object('key', k, 'then', r.baseline -> k, 'now', now_base -> k)), '[]') into changed
  from jsonb_object_keys(now_base) k where (r.baseline -> k) is distinct from (now_base -> k);
  sim := public._cr_simulate(r.character_id, coalesce(r.approved_ops, r.ops));
  return jsonb_build_object('request', public._cr_json(p_request, dm), 'preview', sim,
    'stale', r.status in ('submitted', 'returned_for_changes', 'apply_failed', 'draft') and md5(now_base::text) is distinct from r.baseline_hash,
    'changed_assumptions', changed,
    'policy', (select jsonb_agg(jsonb_build_object('action', s.action_key, 'label', a.label,
                 'decision', public._gov_policy(r.campaign_id, s.action_key)))
               from (select distinct c.action_key from jsonb_array_elements(r.ops) o join public.change_request_ops c on c.op = o ->> 'op') s
               join public.governance_actions a on a.action_key = s.action_key));
end;
$$;

-- re-base a stale request on the current character (requester for drafts / returned, DM for submitted)
create function public.refresh_change_request(p_request uuid)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare r public.change_requests; dm boolean; sim jsonb;
begin
  select * into r from public.change_requests where id = p_request for update;
  if r.id is null then raise exception 'Request not found' using errcode = '42501'; end if;
  dm := public._cr_can_review(r.campaign_id);
  if not (dm or (r.requested_by = auth.uid() and r.status in ('draft', 'returned_for_changes'))) then
    raise exception 'Request not found' using errcode = '42501';
  end if;
  if r.status not in ('draft', 'submitted', 'returned_for_changes', 'apply_failed') then
    raise exception 'This request is already %', replace(r.status, '_', ' ') using errcode = '22023';
  end if;
  sim := public._cr_simulate(r.character_id, coalesce(r.approved_ops, r.ops));
  update public.change_requests set baseline = public._cr_baseline(r.character_id), baseline_hash = md5(public._cr_baseline(r.character_id)::text),
    stale = false, stale_details = null, preview = sim - 'before' - 'after', revision = revision + 1, updated_at = now()
  where id = p_request;
  perform public._cr_event(p_request, 'refreshed', null, jsonb_build_object('preview_ok', sim -> 'ok'));
  return public.preview_change_request(p_request);
end;
$$;

-- true (and the request marked stale) when the character no longer matches the proposal's baseline
create function public._cr_mark_stale(p_request uuid)
returns boolean
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare r public.change_requests; now_base jsonb; changed jsonb;
begin
  select * into r from public.change_requests where id = p_request;
  now_base := public._cr_baseline(r.character_id);
  if md5(now_base::text) is not distinct from r.baseline_hash then return false; end if;
  select coalesce(jsonb_agg(jsonb_build_object('key', k, 'then', r.baseline -> k, 'now', now_base -> k)), '[]') into changed
  from jsonb_object_keys(now_base) k where (r.baseline -> k) is distinct from (now_base -> k);
  update public.change_requests set stale = true, stale_details = changed, updated_at = now() where id = p_request;
  perform public._cr_event(p_request, 'stale', null, changed);
  return true;
end;
$$;

-- ---- DM review ---------------------------------------------------------------------------------------------------------
-- p_decision: approve | reject | return. approve applies at once. p_edited_ops (approve only): the DM's edited version
-- (needs a note). A stale request is refused until refreshed. Exactly one review succeeds (row lock + status + revision).
create function public.review_change_request(p_request uuid, p_decision text, p_note text default null,
                                             p_expected_revision int default null, p_edited_ops jsonb default null,
                                             p_private_note text default null)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare r public.change_requests; g public.campaign_governance; v_ops jsonb; v_note text := nullif(btrim(coalesce(p_note, '')), '');
begin
  select * into r from public.change_requests where id = p_request for update;
  if r.id is null or not public._cr_can_review(r.campaign_id) then raise exception 'Request not found' using errcode = '42501'; end if;
  if r.requested_by = auth.uid() and not public.is_admin() then
    raise exception 'You cannot review your own request' using errcode = '42501';
  end if;
  if p_decision not in ('approve', 'reject', 'return') then raise exception 'Unknown decision' using errcode = '22023'; end if;
  if r.status <> 'submitted' then
    raise exception 'This request is % and cannot be reviewed now', replace(r.status, '_', ' ') using errcode = 'TLRVW';
  end if;
  if p_expected_revision is not null and p_expected_revision <> r.revision then
    raise exception 'The request changed while you were reviewing it. Reload it.' using errcode = '40001';
  end if;
  select * into g from public.campaign_governance where campaign_id = r.campaign_id;
  if p_private_note is not null then
    insert into public.change_request_private_notes (request_id, note, updated_by) values (p_request, left(p_private_note, 2000), auth.uid())
    on conflict (request_id) do update set note = excluded.note, updated_by = excluded.updated_by, updated_at = now();
  end if;
  if p_decision in ('reject', 'return') then
    if v_note is null then raise exception 'Tell the player why (a note is required)' using errcode = '22023'; end if;
    update public.change_requests set status = case when p_decision = 'reject' then 'rejected' else 'returned_for_changes' end,
      review_note = v_note, reviewed_at = now(), reviewed_by = auth.uid(), revision = revision + 1, updated_at = now()
    where id = p_request;
    perform public._cr_event(p_request, case when p_decision = 'reject' then 'rejected' else 'returned' end, v_note);
    perform public._audit(r.campaign_id, r.character_id, case when p_decision = 'reject' then 'request_rejected' else 'request_returned' end,
                          case when p_decision = 'reject' then 'Rejected: ' else 'Returned for changes: ' end || r.title, null, null, v_note, p_request, 'party');
    return public._cr_json(p_request, true);
  end if;
  -- approve
  if p_edited_ops is not null then
    if not coalesce(g.allow_edit_and_approve, true) then raise exception 'Edit and approve is turned off in this campaign' using errcode = '22023'; end if;
    if v_note is null then raise exception 'Explain your edit to the player (a note is required)' using errcode = '22023'; end if;
    v_ops := public._cr_normalize_ops(r.character_id, p_edited_ops);
  else
    v_ops := r.ops;
    if coalesce(g.require_approval_note, false) and v_note is null then raise exception 'This campaign requires a note on every approval' using errcode = '22023'; end if;
  end if;
  -- wait for any change of the character in flight (domain RPCs lock this row), then compare with the proposal's baseline
  perform 1 from public.characters where id = r.character_id for update;
  if public._cr_mark_stale(p_request) then
    return public._cr_json(p_request, true) || jsonb_build_object('refused', 'stale',
      'message', 'The character changed after this request was made. Check the new preview, then approve again.');
  end if;
  update public.change_requests set status = 'approved', approved_ops = case when p_edited_ops is not null then v_ops end,
    edited_by_dm = p_edited_ops is not null, review_note = v_note, reviewed_at = now(), reviewed_by = auth.uid(),
    revision = revision + 1, updated_at = now()
  where id = p_request;
  perform public._cr_event(p_request, 'approved', v_note, case when p_edited_ops is not null then jsonb_build_object('edited', true) end);
  perform public._audit(r.campaign_id, r.character_id, 'request_approved', 'Approved: ' || r.title, null, null, v_note, p_request, 'party');
  return public._cr_apply(p_request);
end;
$$;

-- apply an approved (or failed) request; all ops or nothing
create function public._cr_apply(p_request uuid)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare r public.change_requests; before jsonb; after jsonb; o jsonb; err text; n int := 0;
begin
  select * into r from public.change_requests where id = p_request for update;
  if r.status not in ('approved', 'apply_failed') then raise exception 'Only an approved request can be applied' using errcode = '22023'; end if;
  before := public._cr_snapshot(r.character_id);
  begin
    perform set_config('tavern.gov_apply', p_request::text, true);
    perform 1 from public.characters where id = r.character_id for update;
    for o in select x from jsonb_array_elements(coalesce(r.approved_ops, r.ops)) x loop
      n := n + 1;
      perform public._cr_exec_op(r.character_id, o);
    end loop;
    perform set_config('tavern.gov_apply', '', true);
  exception when others then
    err := sqlerrm;
  end;
  perform set_config('tavern.gov_apply', '', true);
  if err is not null then
    update public.change_requests set status = 'apply_failed', apply_error = left('Step ' || n || ': ' || err, 1000), updated_at = now(),
      revision = revision + 1 where id = p_request;
    perform public._cr_event(p_request, 'apply_failed', left(err, 500));
    perform public._audit(r.campaign_id, r.character_id, 'request_apply_failed', 'Could not apply: ' || r.title, null, null, left(err, 1000), p_request, 'dm');
    return public._cr_json(p_request, true);
  end if;
  after := public._cr_snapshot(r.character_id);
  update public.change_requests set status = 'applied', applied_at = now(), apply_error = null, updated_at = now(), revision = revision + 1,
    preview = jsonb_build_object('ok', true, 'diff', public._cr_diff(before, after), 'applied', true)
  where id = p_request;
  perform public._cr_event(p_request, 'applied');
  perform public._audit(r.campaign_id, r.character_id, 'request_applied', 'Applied: ' || r.title,
                        jsonb_build_object('diff', public._cr_diff(before, after)), null, null, p_request, 'party');
  return public._cr_json(p_request, true);
end;
$$;

-- DM retry after correcting the cause of apply_failed
create function public.retry_change_request(p_request uuid)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare r public.change_requests;
begin
  select * into r from public.change_requests where id = p_request for update;
  if r.id is null or not public._cr_can_review(r.campaign_id) then raise exception 'Request not found' using errcode = '42501'; end if;
  if r.status <> 'apply_failed' then raise exception 'Only a failed request can be retried' using errcode = 'TLRVW'; end if;
  perform 1 from public.characters where id = r.character_id for update;
  if public._cr_mark_stale(p_request) then
    return public._cr_json(p_request, true) || jsonb_build_object('refused', 'stale',
      'message', 'The character changed since the approval. Refresh the request, check the preview, then retry.');
  end if;
  return public._cr_apply(p_request);
end;
$$;

-- the player's / DM's list for one character (no private notes for players)
create function public.get_character_change_requests(p_character uuid, p_include_closed boolean default false)
returns jsonb
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
declare camp uuid; dm boolean;
begin
  if auth.uid() is null or not public.can_access_character(p_character) then raise exception 'Character not found' using errcode = '42501'; end if;
  select campaign_id into camp from public.characters where id = p_character;
  dm := camp is not null and public._cr_can_review(camp);
  return (select coalesce(jsonb_agg(public._cr_json(r.id, dm) order by r.created_at desc), '[]')
          from public.change_requests r
          where r.character_id = p_character
            and (dm or r.requested_by = auth.uid() or exists (select 1 from public.characters c where c.id = r.character_id and c.owner_id = auth.uid()))
            and (p_include_closed or r.status in ('draft', 'submitted', 'returned_for_changes', 'apply_failed')
                 or r.updated_at > now() - interval '14 days'));
end;
$$;

-- DM inbox
create function public.get_campaign_change_requests(p_campaign uuid, p_statuses text[] default null, p_character uuid default null,
                                                    p_action text default null, p_limit int default 100)
returns jsonb
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
begin
  if not public._cr_can_review(p_campaign) then raise exception 'Only a DM of this campaign can read its requests' using errcode = '42501'; end if;
  return (select coalesce(jsonb_agg(x.j order by x.ord), '[]') from (
    select public._cr_json(r.id, true) as j,
           row_number() over (order by case r.status when 'submitted' then 0 when 'apply_failed' then 1 when 'returned_for_changes' then 2 else 3 end,
                                       coalesce(r.submitted_at, r.created_at) desc) as ord
    from public.change_requests r
    where r.campaign_id = p_campaign and r.status <> 'draft'
      and (p_statuses is null or r.status = any (p_statuses))
      and (p_character is null or r.character_id = p_character)
      and (p_action is null or r.action_type = p_action or r.category = p_action)
    order by ord limit greatest(1, least(coalesce(p_limit, 100), 500))) x);
end;
$$;

-- ---- direct build fields (abilities, max HP, manual values) through one governed RPC -------------------------------------
create function public.update_character_build(p_character uuid, p_patch jsonb)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare k text; c public.characters; acts text[] := '{}'; a text;
  allowed constant text[] := array['strength', 'dexterity', 'constitution', 'intelligence', 'wisdom', 'charisma', 'hp_max', 'ac_override',
                                   'speed', 'initiative_bonus', 'hit_die'];
begin
  if auth.uid() is null or not public.can_access_character(p_character) then raise exception 'Character not found' using errcode = '42501'; end if;
  if p_patch is null or jsonb_typeof(p_patch) <> 'object' or p_patch = '{}'::jsonb then raise exception 'Nothing to change' using errcode = '22023'; end if;
  for k in select jsonb_object_keys(p_patch) loop
    if not k = any (allowed) then raise exception 'Field "%" cannot be changed here', k using errcode = '22023'; end if;
    acts := acts || case when k in ('strength', 'dexterity', 'constitution', 'intelligence', 'wisdom', 'charisma') then 'build.ability_scores'
                         when k = 'hp_max' then 'build.hp_max' else 'build.manual_stats' end;
  end loop;
  foreach a in array (select array_agg(distinct x) from unnest(acts) x) loop perform public._gov_gate(p_character, a); end loop;
  select * into c from public.characters where id = p_character for update;
  c := jsonb_populate_record(c, p_patch);
  update public.characters set strength = c.strength, dexterity = c.dexterity, constitution = c.constitution,
    intelligence = c.intelligence, wisdom = c.wisdom, charisma = c.charisma, hp_max = c.hp_max, ac_override = c.ac_override,
    speed = c.speed, initiative_bonus = c.initiative_bonus, hit_die = c.hit_die
  where id = p_character;
  return (select to_jsonb(x) from public.characters x where x.id = p_character);
end;
$$;

-- ---- audit of permanent changes made outside requests (DM corrections, ungated player actions) ---------------------------
create function public._audit_build_change()
returns trigger
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare cid uuid; camp uuid; s text; b jsonb; a jsonb;
begin
  cid := coalesce((to_jsonb(new) ->> 'character_id')::uuid, (to_jsonb(old) ->> 'character_id')::uuid);
  select campaign_id into camp from public.characters where id = cid;
  if camp is null then return coalesce(new, old); end if;
  if tg_table_name = 'character_classes' then
    if tg_op = 'INSERT' then s := 'Class added: ' || new.class_id || ' ' || new.level;
    elsif tg_op = 'DELETE' then s := 'Class removed: ' || old.class_id;
    elsif new.level is distinct from old.level or new.subclass_version_id is distinct from old.subclass_version_id
          or new.class_version_id is distinct from old.class_version_id then
      s := 'Level changed: ' || new.class_id || ' ' || old.level || ' → ' || new.level
           || case when new.subclass_version_id is distinct from old.subclass_version_id then ' (subclass ' || coalesce(new.subclass_version_id, 'none') || ')' else '' end;
    else return new; end if;
    b := case when tg_op <> 'INSERT' then jsonb_build_object('class', old.class_id, 'level', old.level, 'subclass', old.subclass_version_id) end;
    a := case when tg_op <> 'DELETE' then jsonb_build_object('class', new.class_id, 'level', new.level, 'subclass', new.subclass_version_id) end;
    perform public._audit(camp, cid, 'level_changed', s, b, a, null, nullif(current_setting('tavern.gov_apply', true), '')::uuid, 'party');
  elsif tg_table_name = 'character_spells' then
    if tg_op = 'INSERT' and (new.known or new.always_prepared) then
      perform public._audit(camp, cid, 'spell_learned', 'Spell added: ' || coalesce((select name from public.spell_versions where id = new.spell_version_id), new.spell_version_id),
                            null, jsonb_build_object('spell', new.spell_version_id), null, nullif(current_setting('tavern.gov_apply', true), '')::uuid, 'party');
    elsif tg_op = 'DELETE' and (old.known or old.always_prepared) then
      perform public._audit(camp, cid, 'spell_removed', 'Spell removed: ' || coalesce((select name from public.spell_versions where id = old.spell_version_id), old.spell_version_id),
                            jsonb_build_object('spell', old.spell_version_id), null, null, nullif(current_setting('tavern.gov_apply', true), '')::uuid, 'party');
    end if;
  elsif tg_table_name = 'character_lineages' then
    perform public._audit(camp, cid, 'lineage_changed', 'Lineage: ' || coalesce(case when tg_op <> 'DELETE' then new.version_id end, 'cleared'),
                          case when tg_op <> 'INSERT' then jsonb_build_object('version', old.version_id) end,
                          case when tg_op <> 'DELETE' then jsonb_build_object('version', new.version_id) end, null,
                          nullif(current_setting('tavern.gov_apply', true), '')::uuid, 'party');
  elsif tg_table_name = 'character_backgrounds' then
    if tg_op = 'UPDATE' and new.version_id = old.version_id then return new; end if;
    perform public._audit(camp, cid, 'background_changed', 'Background: ' || coalesce(case when tg_op <> 'DELETE' then new.version_id end, 'cleared'),
                          case when tg_op <> 'INSERT' then jsonb_build_object('version', old.version_id) end,
                          case when tg_op <> 'DELETE' then jsonb_build_object('version', new.version_id) end, null,
                          nullif(current_setting('tavern.gov_apply', true), '')::uuid, 'party');
  elsif tg_table_name = 'character_companions' and tg_op in ('INSERT', 'DELETE') then
    perform public._audit(camp, cid, 'companion_changed', case when tg_op = 'INSERT' then 'Companion added: ' || coalesce(new.name, new.creature_id)
                                                              else 'Companion removed: ' || coalesce(old.name, old.creature_id) end,
                          null, null, null, nullif(current_setting('tavern.gov_apply', true), '')::uuid, 'party');
  elsif tg_table_name = 'character_seen_forms' and tg_op = 'INSERT' then
    perform public._audit(camp, cid, 'seen_form_granted', 'Seen form: ' || coalesce((select name from public.creatures where id = new.creature_id), new.creature_id),
                          null, null, null, nullif(current_setting('tavern.gov_apply', true), '')::uuid, 'party');
  end if;
  return coalesce(new, old);
end;
$$;
revoke all on function public._audit_build_change() from public, anon, authenticated;
create trigger character_classes_audit after insert or update or delete on public.character_classes for each row execute function public._audit_build_change();
create trigger character_spells_audit after insert or delete on public.character_spells for each row execute function public._audit_build_change();
create trigger character_lineages_audit after insert or update or delete on public.character_lineages for each row execute function public._audit_build_change();
create trigger character_backgrounds_audit after insert or update or delete on public.character_backgrounds for each row execute function public._audit_build_change();
create trigger character_companions_audit after insert or delete on public.character_companions for each row execute function public._audit_build_change();
create trigger character_seen_forms_audit after insert on public.character_seen_forms for each row execute function public._audit_build_change();

-- ---- campaign audit read model -------------------------------------------------------------------------------------------
create function public.get_campaign_audit(p_campaign uuid, p_character uuid default null, p_types text[] default null,
                                          p_limit int default 200, p_before timestamptz default null)
returns jsonb
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
declare dm boolean;
begin
  if auth.uid() is null or not (public.is_admin() or public.is_campaign_member(p_campaign)) then
    raise exception 'Campaign not found' using errcode = '42501';
  end if;
  dm := public.is_admin() or public.is_campaign_dm(p_campaign);
  return (select coalesce(jsonb_agg(j order by created_at desc), '[]') from (
    select jsonb_build_object('id', e.id, 'event_type', e.event_type, 'summary', e.summary, 'before', e.before, 'after', e.after,
             'reason', e.reason, 'request_id', e.request_id, 'visibility', case when dm then e.visibility end, 'created_at', e.created_at,
             'character_id', e.character_id, 'character_name', ch.name,
             'actor_name', (select coalesce(display_name, email) from public.profiles where id = e.actor_id)) as j, e.created_at
    from public.campaign_audit_events e left join public.characters ch on ch.id = e.character_id
    where e.campaign_id = p_campaign
      and (dm or (e.visibility <> 'dm' and ch.owner_id = auth.uid()))
      and (p_character is null or e.character_id = p_character)
      and (p_types is null or e.event_type = any (p_types))
      and (p_before is null or e.created_at < p_before)
    order by e.created_at desc limit greatest(1, least(coalesce(p_limit, 200), 1000))) x);
end;
$$;

-- ---- RLS, grants, Realtime -----------------------------------------------------------------------------------------------
alter table public.change_request_ops enable row level security;
alter table public.change_requests enable row level security;
alter table public.change_request_events enable row level security;
alter table public.change_request_private_notes enable row level security;
revoke all on public.change_request_ops, public.change_requests, public.change_request_events, public.change_request_private_notes
  from anon, authenticated;
create policy "change_request_ops_read" on public.change_request_ops for select to authenticated using (true);
create policy "change_requests_read" on public.change_requests for select to authenticated
  using (requested_by = auth.uid() or public._cr_can_review(campaign_id)
         or exists (select 1 from public.characters c where c.id = character_id and c.owner_id = auth.uid()));
create policy "change_request_events_read" on public.change_request_events for select to authenticated
  using (exists (select 1 from public.change_requests r where r.id = request_id
                 and (r.requested_by = auth.uid() or public._cr_can_review(r.campaign_id))));
create policy "change_request_private_notes_read" on public.change_request_private_notes for select to authenticated
  using (exists (select 1 from public.change_requests r where r.id = request_id and public._cr_can_review(r.campaign_id)));
grant select on public.change_request_ops, public.change_requests, public.change_request_events, public.change_request_private_notes to authenticated;

alter table public.change_requests replica identity full;
do $$
begin
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'change_requests') then
    alter publication supabase_realtime add table public.change_requests;
  end if;
end $$;

revoke all on function public._cr_normalize_op(uuid, jsonb), public._cr_normalize_ops(uuid, jsonb), public._cr_resolve(uuid, text, text),
  public._cr_exec_op(uuid, jsonb), public._cr_snapshot(uuid), public._cr_baseline(uuid), public._cr_diff(jsonb, jsonb),
  public._cr_simulate(uuid, jsonb), public._cr_json(uuid, boolean), public._cr_event(uuid, text, text, jsonb), public._cr_apply(uuid),
  public._cr_mark_stale(uuid)
  from public, anon, authenticated;
revoke all on function public._cr_can_review(uuid) from public, anon;
grant execute on function public._cr_can_review(uuid) to authenticated;
revoke all on function public.create_change_request(uuid, jsonb, text, text, text, boolean, uuid, uuid), public.add_change_request_op(uuid, jsonb, text),
  public.update_change_request(uuid, jsonb, text, text, text, int), public.submit_change_request(uuid, int),
  public.cancel_change_request(uuid, text), public.preview_change_request(uuid), public.refresh_change_request(uuid),
  public.review_change_request(uuid, text, text, int, jsonb, text), public.retry_change_request(uuid),
  public.get_character_change_requests(uuid, boolean), public.get_campaign_change_requests(uuid, text[], uuid, text, int),
  public.update_character_build(uuid, jsonb), public.get_campaign_audit(uuid, uuid, text[], int, timestamptz)
  from public, anon;
grant execute on function public.create_change_request(uuid, jsonb, text, text, text, boolean, uuid, uuid), public.add_change_request_op(uuid, jsonb, text),
  public.update_change_request(uuid, jsonb, text, text, text, int), public.submit_change_request(uuid, int),
  public.cancel_change_request(uuid, text), public.preview_change_request(uuid), public.refresh_change_request(uuid),
  public.review_change_request(uuid, text, text, int, jsonb, text), public.retry_change_request(uuid),
  public.get_character_change_requests(uuid, boolean), public.get_campaign_change_requests(uuid, text[], uuid, text, int),
  public.update_character_build(uuid, jsonb), public.get_campaign_audit(uuid, uuid, text[], int, timestamptz)
  to authenticated;
