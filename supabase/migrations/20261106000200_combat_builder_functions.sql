-- =============================================================================
-- Combat Builder, part 2: functions (docs/COMBAT_BUILDER_ARCHITECTURE.md, docs/COMBAT_INITIATIVE_RULES.md,
-- docs/COMBAT_EFFECTS_AND_CONDITIONS.md, docs/COMBAT_REALTIME.md, docs/COMBAT_HOMEBREW_CREATURES.md).
-- Needs 20261106000100_combat_builder_schema.sql. Rollback: supabase/rollback/rollback_combat_builder_functions.sql.
--
-- Changes to existing objects (both restored exactly by the rollback):
--   * public._dm_try: creature definitions written by the Combat Builder editor (definition.combat present) get the
--     conditional combat validation of _combat_creature_errors; every other definition is validated exactly as before.
--   * new public.apply_character_hp: the one atomic HP change of a character (the sheet's Damage / Heal / Temp buttons and
--     the Combat Builder). The direct column write of the sheet stays possible (typed values); nothing else changes.
-- Every RPC: SECURITY DEFINER, search_path = public, pg_temp, EXECUTE for authenticated only, role checked inside.
-- Lock order: see 20261106000100 (encounter -> participant -> character -> rest).
-- =============================================================================

-- =============================================================================================== 0. small helpers
create or replace function public._combat_label(n int)
returns text language sql immutable set search_path = public, pg_temp as $$
  select case when n <= 26 then chr(64 + n) else chr(64 + ((n - 1) / 26)) || chr(65 + ((n - 1) % 26)) end;
$$;

-- "3d6+2" -> a roll (server random); a plain number -> that number; anything else -> null
create or replace function public._combat_roll(p_formula text)
returns int language plpgsql volatile set search_path = public, pg_temp as $$
declare m text[]; n int; s int; k int := 0; t int := 0; i int;
begin
  if p_formula is null then return null; end if;
  if btrim(p_formula) ~ '^\d+$' then return btrim(p_formula)::int; end if;
  m := regexp_match(replace(replace(p_formula, ' ', ''), '−', '-'), '^(\d+)d(\d+)([+-]\d+)?$');
  if m is null then return null; end if;
  n := least(m[1]::int, 200); s := greatest(m[2]::int, 1); k := coalesce(m[3]::int, 0);
  for i in 1 .. n loop t := t + 1 + floor(random() * s)::int; end loop;
  return t + k;
end $$;

create or replace function public._combat_d20(p_mode text)
returns jsonb language plpgsql volatile set search_path = public, pg_temp as $$
declare a int := 1 + floor(random() * 20)::int; b int := 1 + floor(random() * 20)::int;
begin
  return case p_mode when 'advantage' then jsonb_build_object('rolls', jsonb_build_array(a, b), 'value', greatest(a, b), 'mode', p_mode)
                     when 'disadvantage' then jsonb_build_object('rolls', jsonb_build_array(a, b), 'value', least(a, b), 'mode', p_mode)
                     else jsonb_build_object('rolls', jsonb_build_array(a), 'value', a, 'mode', 'normal') end;
end $$;

-- the encounter after the role check; p_lock: 'update' (turns, structure), 'share' (HP, effects), 'none'
create or replace function public._combat_auth(p_encounter uuid, p_lock text default 'none')
returns public.combat_encounters language plpgsql security definer set search_path = public, pg_temp as $$
declare e public.combat_encounters; camp uuid;
begin
  if auth.uid() is null then raise exception 'Sign in first' using errcode = '42501'; end if;
  select campaign_id into camp from public.combat_encounters where id = p_encounter;
  if camp is null or not public._combat_can_run(camp) then
    raise exception 'Encounter not found, or you are not the DM of its campaign' using errcode = '42501';
  end if;
  if p_lock = 'update' then select * into e from public.combat_encounters where id = p_encounter for no key update;
  elsif p_lock = 'share' then select * into e from public.combat_encounters where id = p_encounter for share;
  else select * into e from public.combat_encounters where id = p_encounter; end if;
  return e;
end $$;

-- the participant (locked) and its encounter (locked as asked), after the role check
create or replace function public._combat_participant_auth(p_participant uuid, p_lock text default 'share')
returns public.combat_participants language plpgsql security definer set search_path = public, pg_temp as $$
declare p public.combat_participants; enc uuid;
begin
  select encounter_id into enc from public.combat_participants where id = p_participant;
  if enc is null then raise exception 'Combatant not found' using errcode = '42501'; end if;
  perform public._combat_auth(enc, p_lock);
  select * into p from public.combat_participants where id = p_participant for update;
  return p;
end $$;

-- the stored result of a request that was already accepted (a double click, a retry after a lost answer)
create or replace function public._combat_replay(p_encounter uuid, p_request uuid)
returns jsonb language sql stable security definer set search_path = public, pg_temp as $$
  select case when p_request is null then null else
    (select coalesce(x.result, '{}'::jsonb) || jsonb_build_object('replayed', true, 'event_id', x.id)
     from public.combat_events x where x.encounter_id = p_encounter and x.request_id = p_request) end;
$$;

create or replace function public._combat_event(p_encounter uuid, p_kind text, p_participant uuid, p_before jsonb, p_after jsonb,
  p_details jsonb, p_request uuid, p_undoable boolean, p_result jsonb default null)
returns bigint language plpgsql security definer set search_path = public, pg_temp as $$
declare i bigint;
begin
  insert into public.combat_events (encounter_id, kind, participant_id, round, request_id, before, after, details, undoable, result)
  values (p_encounter, p_kind, p_participant, (select round from public.combat_encounters where id = p_encounter), p_request, p_before, p_after,
          coalesce(p_details, '{}'), coalesce(p_undoable, false), p_result)
  returning id into i;
  return i;
end $$;

create or replace function public._combat_set_result(p_event bigint, p_result jsonb)
returns jsonb language sql security definer set search_path = public, pg_temp as $$
  update public.combat_events set result = p_result where id = p_event;
  select p_result;
$$;

-- Realtime log row (ids only). About 1 in 50 calls prunes rows older than 3 days (skip locked).
create or replace function public._combat_changed(p_encounter uuid, p_domain text, p_kind text, p_participant uuid default null,
  p_visible boolean default false)
returns bigint language plpgsql security definer set search_path = public, pg_temp as $$
declare i bigint;
begin
  insert into public.combat_changes (encounter_id, domain, kind, participant_id, player_visible)
  values (p_encounter, p_domain, p_kind, p_participant, coalesce(p_visible, false)) returning id into i;
  if random() < 0.02 then
    delete from public.combat_changes where id in (select id from public.combat_changes where changed_at < now() - interval '3 days'
                                                    order by id limit 200 for update skip locked);
  end if;
  return i;
end $$;

-- structure change of an encounter whose row the caller holds FOR NO KEY UPDATE
create or replace function public._combat_touch(p_encounter uuid)
returns void language sql security definer set search_path = public, pg_temp as $$
  update public.combat_encounters set rev = rev + 1, updated_at = now() where id = p_encounter;
$$;

-- campaign default ruleset: the only allowed one, else 2024 (docs/COMBAT_RULES_AND_LICENSING.md)
create or replace function public._combat_campaign_ruleset(p_campaign uuid)
returns text language sql stable security definer set search_path = public, pg_temp as $$
  select case when g.content_rulesets = array['2014'] then '2014' else '2024' end
  from (select coalesce((select content_rulesets from public.campaign_governance where campaign_id = p_campaign), array['2014', '2024']) as content_rulesets) g;
$$;

-- ================================================================================= 1. stat block snapshots (catalog -> instance)
create or replace function public._combat_entries(p jsonb)
returns jsonb language sql immutable set search_path = public, pg_temp as $$
  select coalesce(jsonb_agg(x || jsonb_build_object('text', coalesce(x ->> 'text', x ->> 'summary', ''))
                  || case when x -> 'save' ? 'ability' then jsonb_build_object('save', (x -> 'save') || jsonb_build_object('ability', lower(x -> 'save' ->> 'ability'))) else '{}' end), '[]')
  from jsonb_array_elements(coalesce(p, '[]')) x where jsonb_typeof(x) = 'object';
$$;

-- one normalized stat block (docs/COMBAT_DATA_MODEL.md "Stat block snapshot") from the SRD 5.2.1 catalog, the SRD 5.1
-- creatures or a published campaign creature. p_campaign limits campaign creatures to that campaign.
create or replace function public._combat_source(p_kind text, p_id text, p_campaign uuid)
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
declare m public.combat_monsters; c public.creatures; v public.dm_content_versions; d jsonb := '{}'; leg jsonb; dexmod int;
begin
  if p_kind = 'srd2024' then
    select * into m from public.combat_monsters where id = p_id and archived_at is null;
    if not found then raise exception 'Unknown monster "%"', p_id using errcode = '22023'; end if;
    return m.statblock || jsonb_build_object('source_kind', 'srd2024', 'source_id', m.id, 'source_version', 'srd-5.2.1', 'rules_version', '2024',
      'source_label', m.source_label, 'source_ref', m.source_ref, 'license', m.license, 'attribution_required', m.attribution_required,
      'homebrew', false, 'xp', m.xp, 'challenge_rating', m.challenge_rating,
      'initiative', jsonb_build_object('modifier', m.initiative_modifier, 'score', m.initiative_score));
  end if;
  if p_kind not in ('creature', 'homebrew') then raise exception 'Unknown monster source "%"', p_kind using errcode = '22023'; end if;
  select * into c from public.creatures where id = p_id;
  if not found then raise exception 'Unknown creature "%"', p_id using errcode = '22023'; end if;
  if c.content_scope = 'campaign' and c.campaign_id is distinct from p_campaign then
    raise exception '% belongs to another campaign' , c.name using errcode = '42501';
  end if;
  if c.content_scope = 'test' then raise exception '% is a test fixture, not a monster' , c.name using errcode = '22023'; end if;
  if c.archived_at is not null then raise exception '% is archived. Restore it in DM Space before adding it.', c.name using errcode = '22023'; end if;
  if c.content_version_id is not null then
    select * into v from public.dm_content_versions where id = c.content_version_id;
    d := coalesce(v.definition, '{}');
  end if;
  dexmod := floor((coalesce((c.abilities ->> 'dex')::int, 10) - 10) / 2.0)::int;
  select jsonb_build_object('uses', l.uses, 'uses_in_lair', null, 'actions', l.actions) into leg from public.creature_legendary_actions l where l.creature_id = c.id;
  if leg is null and coalesce((d -> 'legendary' ->> 'enabled')::boolean, false) then
    leg := jsonb_build_object('uses', coalesce((d -> 'legendary' ->> 'uses')::int, 3), 'uses_in_lair', null,
      'actions', (select coalesce(jsonb_agg(jsonb_build_object('name', x ->> 'name', 'cost', coalesce((x ->> 'cost')::int, 1),
                    'text', coalesce(x ->> 'summary', x ->> 'text', ''))), '[]') from jsonb_array_elements(coalesce(d -> 'legendary' -> 'actions', '[]')) x));
  end if;
  return jsonb_build_object(
    'name', c.name, 'size', c.size, 'size_text', c.size, 'creature_type', c.creature_type, 'subtype', c.subtype, 'alignment', c.alignment,
    'armor_class', c.armor_class, 'armor_type', c.armor_type, 'hit_points', c.hit_points, 'hit_dice', c.hit_dice,
    'initiative', jsonb_build_object('modifier', coalesce((d ->> 'initiative_bonus')::int, dexmod), 'score', null),
    'speed', c.speed, 'abilities', c.abilities, 'saving_throws', c.saving_throws, 'skills', c.skills, 'senses', c.senses, 'languages', c.languages,
    'challenge_rating', c.challenge_rating, 'xp', c.xp, 'proficiency_bonus', c.proficiency_bonus,
    'damage_resistances', to_jsonb(c.damage_resistances), 'damage_immunities', to_jsonb(c.damage_immunities),
    'damage_vulnerabilities', to_jsonb(c.damage_vulnerabilities), 'condition_immunities', to_jsonb(c.condition_immunities),
    'traits', public._combat_entries(c.traits), 'actions', public._combat_entries(c.actions),
    'bonus_actions', public._combat_entries(d -> 'bonus_actions'), 'reactions', public._combat_entries(c.reactions),
    'legendary', leg,
    'spellcasting', case when coalesce((d -> 'spellcasting' ->> 'enabled')::boolean, false) then d -> 'spellcasting' end,
    'source_kind', case when c.content_scope = 'campaign' then 'homebrew' else 'creature' end, 'source_id', c.id,
    'source_version', coalesce(c.content_version_id::text, 'srd-5.1'),
    'rules_version', case when c.content_scope = 'campaign' then v.ruleset else '2014' end,
    'source_label', c.source_label, 'source_ref', case when c.content_scope = 'campaign' then 'Campaign custom' else 'SRD 5.1: ' || c.name end,
    'license', c.license, 'attribution_required', c.content_scope <> 'campaign', 'homebrew', c.content_scope = 'campaign',
    'content_id', v.content_id, 'version_no', v.version_no, 'mechanics_status', c.mechanics_status, 'notes', nullif(d ->> 'dm_combat_notes', ''));
end $$;

-- the encounter's snapshot of a source (created once per encounter and version; later catalog edits never change it)
create or replace function public._combat_snapshot(p_encounter uuid, p_kind text, p_id text, p_campaign uuid)
returns public.combat_statblocks language plpgsql security definer set search_path = public, pg_temp as $$
declare s jsonb := public._combat_source(p_kind, p_id, p_campaign); r public.combat_statblocks;
begin
  select * into r from public.combat_statblocks where encounter_id = p_encounter and source_kind = s ->> 'source_kind'
    and source_id = s ->> 'source_id' and source_version = s ->> 'source_version';
  if found then return r; end if;
  insert into public.combat_statblocks (encounter_id, source_kind, source_id, source_version, rules_version, name, snapshot)
  values (p_encounter, s ->> 'source_kind', s ->> 'source_id', s ->> 'source_version', s ->> 'rules_version', s ->> 'name', s)
  returning * into r;
  return r;
end $$;

-- ================================================================================= 2. read models
create or replace function public._combat_pjson(p public.combat_participants)
returns jsonb language sql stable security definer set search_path = public, pg_temp as $$
  select jsonb_build_object('id', p.id, 'kind', p.kind, 'character_id', p.linked_character_id, 'statblock_id', p.statblock_id,
    'name', p.display_name, 'label', p.instance_label, 'player_label', p.player_label, 'group_key', p.group_key,
    'initiative', p.initiative, 'initiative_mod', p.initiative_mod, 'initiative_roll', p.initiative_roll, 'initiative_mode', p.initiative_mode,
    'tiebreak', p.initiative_tiebreak, 'order', p.initiative_order,
    'hp', case when p.kind = 'monster' then jsonb_build_object('current', p.hp_current, 'max', p.hp_max, 'temp', p.hp_temp)
          else (select jsonb_build_object('current', c.hp_current, 'max', (public._feat_hp_bonus(c.id) ->> 'max')::int, 'base_max', c.hp_max,
                  'temp', c.hp_temp, 'death_successes', c.death_successes, 'death_failures', c.death_failures)
                from public.characters c where c.id = p.linked_character_id) end,
    'form', case when p.kind = 'character' then (select jsonb_build_object('creature_id', t.creature_id, 'name', cr.name, 'hp_current', t.hp_current,
              'hp_max', t.hp_max, 'hp_temp', t.hp_temp, 'armor_class', cr.armor_class, 'speed', cr.speed, 'expires_at', t.expires_at)
              from public.character_transformations t join public.creatures cr on cr.id = t.creature_id where t.character_id = p.linked_character_id) end,
    'character', case when p.kind = 'character' then (select jsonb_build_object('name', c.name, 'portrait_url', c.portrait_url, 'level', c.level,
              'classes', (select string_agg(k.name || ' ' || cc.level, ' / ' order by cc.is_primary desc, k.name) from public.character_classes cc
                          join public.classes k on k.id = cc.class_id where cc.character_id = c.id),
              'class_name', c.class_name, 'dexterity', c.dexterity, 'conditions', c.conditions, 'updated_at', c.updated_at,
              'campaign_conditions', (select coalesce(jsonb_agg(jsonb_build_object('id', k.id, 'name', k.name, 'hidden', k.hidden) order by k.applied_at), '[]')
                                      from public.character_conditions k where k.character_id = c.id))
              from public.characters c where c.id = p.linked_character_id) end,
    'statblock', (select jsonb_build_object('name', s.name, 'rules_version', s.rules_version, 'source_kind', s.source_kind,
              'challenge_rating', s.snapshot -> 'challenge_rating', 'xp', s.snapshot -> 'xp', 'speed', s.snapshot -> 'speed', 'size', s.snapshot ->> 'size',
              'creature_type', s.snapshot ->> 'creature_type', 'passive_perception', s.snapshot -> 'senses' -> 'passive_perception',
              'legendary', s.snapshot -> 'legendary' is not null and s.snapshot -> 'legendary' <> 'null'::jsonb,
              'has_reactions', jsonb_array_length(coalesce(s.snapshot -> 'reactions', '[]')) > 0)
              from public.combat_statblocks s where s.id = p.statblock_id),
    'armor_class', p.armor_class, 'active', p.active, 'removed', p.removed_at is not null, 'hidden', p.hidden, 'joins_round', p.joins_round,
    'defeated', p.defeated, 'surprised', p.surprised, 'turns_taken', p.turns_taken, 'reaction_used', p.reaction_used,
    'legendary_max', p.legendary_max, 'legendary_left', p.legendary_left, 'notes', p.notes, 'rev', p.rev);
$$;

create or replace function public._combat_ejson(x public.combat_effects)
returns jsonb language sql stable security definer set search_path = public, pg_temp as $$
  select to_jsonb(x) - 'created_by' || jsonb_build_object('condition', (select jsonb_build_object('name', k.name, 'summary', k.summary, 'icon', k.icon,
           'incapacitating', k.incapacitating, 'source_ref', k.source_ref) from public.combat_conditions k
           join public.combat_encounters e on e.id = x.encounter_id where k.ruleset = e.ruleset and k.key = x.condition_key));
$$;

-- 2024 encounter difficulty (SRD 5.2.1 "XP Budget per Character"); 2014: not available in the SRD
create or replace function public._combat_difficulty(p_encounter uuid)
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
declare e public.combat_encounters; budget int[] := array[0, 0, 0]; lvl int; xp int := 0; uncounted int := 0; n int := 0; r record;
  t constant int[][] := array[[50,75,100],[100,150,200],[150,225,400],[250,375,500],[500,750,1100],[600,1000,1400],[750,1300,1700],
    [1000,1700,2100],[1300,2000,2600],[1600,2300,3100],[1900,2900,4100],[2200,3700,4700],[2600,4200,5400],[2900,4900,6200],
    [3300,5400,7800],[3800,6100,9800],[4500,7200,11700],[5000,8700,14200],[5500,10700,17200],[6400,13200,22000]];
begin
  select * into e from public.combat_encounters where id = p_encounter;
  if e.ruleset <> '2024' then
    return jsonb_build_object('available', false, 'ruleset', e.ruleset, 'reason', 'The 2014 SRD has no encounter difficulty guidance.');
  end if;
  for r in select p.*, c.level as clevel, (select sum(cc.level) from public.character_classes cc where cc.character_id = c.id) as clvl
           from public.combat_participants p left join public.characters c on c.id = p.linked_character_id
           where p.encounter_id = p_encounter and p.active and p.removed_at is null loop
    if r.kind = 'character' and r.linked_character_id is not null then
      lvl := greatest(1, least(20, coalesce(r.clvl, r.clevel, 1)::int)); n := n + 1;
      budget := array[budget[1] + t[lvl][1], budget[2] + t[lvl][2], budget[3] + t[lvl][3]];
    elsif r.kind = 'monster' then
      if (select s.snapshot ->> 'xp' from public.combat_statblocks s where s.id = r.statblock_id) is null then uncounted := uncounted + 1;
      else xp := xp + (select (s.snapshot ->> 'xp')::int from public.combat_statblocks s where s.id = r.statblock_id); end if;
    end if;
  end loop;
  return jsonb_build_object('available', n > 0, 'ruleset', '2024', 'party', n, 'xp', xp, 'uncounted', uncounted,
    'budget', jsonb_build_object('low', budget[1], 'moderate', budget[2], 'high', budget[3]),
    'rating', case when n = 0 then null when xp <= budget[1] then 'low' when xp <= budget[2] then 'moderate' when xp <= budget[3] then 'high' else 'above_high' end,
    'note', 'Estimate (2024 SRD guidance). Terrain, action economy and tactics matter more than the number.');
end $$;

create or replace function public._combat_encounter_json(e public.combat_encounters)
returns jsonb language sql stable security definer set search_path = public, pg_temp as $$
  select to_jsonb(e) - 'summary' || jsonb_build_object(
    'campaign_name', (select name from public.campaigns where id = e.campaign_id),
    'elapsed_seconds', e.active_seconds + case when e.status = 'active' and e.resumed_at is not null
                         then extract(epoch from now() - e.resumed_at)::int else 0 end,
    'last_change_id', (select max(id) from public.combat_changes where encounter_id = e.id),
    'counts', (select jsonb_build_object('characters', count(*) filter (where kind = 'character' and removed_at is null),
                 'monsters', count(*) filter (where kind = 'monster' and removed_at is null),
                 'defeated', count(*) filter (where defeated and removed_at is null)) from public.combat_participants where encounter_id = e.id));
$$;

-- Combat Home: the encounters of the campaigns the caller directs
create or replace function public.combat_list_encounters(p_campaign uuid default null, p_include_archived boolean default false)
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  if auth.uid() is null then raise exception 'Sign in first' using errcode = '42501'; end if;
  if p_campaign is not null and not public._combat_can_run(p_campaign) then
    raise exception 'Only a DM of this campaign can see its encounters' using errcode = '42501';
  end if;
  return jsonb_build_object(
    'campaigns', (select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'name', c.name, 'ruleset', public._combat_campaign_ruleset(c.id),
                    'rulesets', coalesce((select to_jsonb(g.content_rulesets) from public.campaign_governance g where g.campaign_id = c.id), '["2014","2024"]'))
                    order by c.name), '[]') from public.campaigns c where public._combat_can_run(c.id)),
    'encounters', (select coalesce(jsonb_agg(public._combat_encounter_json(e) order by e.updated_at desc), '[]') from public.combat_encounters e
                   where public._combat_can_run(e.campaign_id) and (p_campaign is null or e.campaign_id = p_campaign)
                     and (p_include_archived or e.archived_at is null)));
end $$;

-- the live encounter: shell + participants + active effects + reminders (no stat blocks, no history)
create or replace function public.combat_get_encounter(p_encounter uuid)
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
declare e public.combat_encounters := public._combat_auth(p_encounter, 'none');
begin
  return jsonb_build_object('encounter', public._combat_encounter_json(e),
    'participants', (select coalesce(jsonb_agg(public._combat_pjson(p) order by p.removed_at nulls first, p.initiative_order nulls last,
                       p.initiative desc nulls last, p.created_at), '[]') from public.combat_participants p where p.encounter_id = e.id),
    'effects', (select coalesce(jsonb_agg(public._combat_ejson(x) order by x.created_at), '[]') from public.combat_effects x
                where x.encounter_id = e.id and (x.active or (x.ended_at > now() - interval '2 minutes'))),
    'reminders', (select coalesce(jsonb_agg(to_jsonb(r) order by r.trigger_round nulls first, r.trigger_initiative desc nulls last), '[]')
                  from public.combat_reminders r where r.encounter_id = e.id),
    'difficulty', public._combat_difficulty(e.id),
    'conditions', (select coalesce(jsonb_agg(to_jsonb(k) order by k.sort_order), '[]') from public.combat_conditions k where k.ruleset = e.ruleset),
    'last_change_id', (select max(id) from public.combat_changes where encounter_id = e.id),
    'last_event', (select jsonb_build_object('id', x.id, 'kind', x.kind, 'undoable', x.undoable and x.undone_by is null, 'participant_id', x.participant_id,
                     'at', x.at) from public.combat_events x where x.encounter_id = e.id order by x.id desc limit 1));
end $$;

-- targeted refresh: one participant with its active effects
create or replace function public.combat_get_participant(p_participant uuid)
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
declare p public.combat_participants;
begin
  select * into p from public.combat_participants where id = p_participant;
  if not found then raise exception 'Combatant not found' using errcode = '42501'; end if;
  perform public._combat_auth(p.encounter_id, 'none');
  return jsonb_build_object('participant', public._combat_pjson(p),
    'effects', (select coalesce(jsonb_agg(public._combat_ejson(x) order by x.created_at), '[]') from public.combat_effects x
                where x.encounter_id = p.encounter_id and x.active and (x.target_participant_id = p.id or x.source_participant_id = p.id)));
end $$;

-- what changed since a change id (reconnect / missed Realtime): the domains and participants to reload
create or replace function public.combat_get_changes(p_encounter uuid, p_since bigint)
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
declare e public.combat_encounters := public._combat_auth(p_encounter, 'none');
begin
  return jsonb_build_object('last_change_id', (select max(id) from public.combat_changes where encounter_id = e.id),
    'turn_rev', e.turn_rev, 'rev', e.rev, 'status', e.status, 'round', e.round, 'current_participant_id', e.current_participant_id,
    'domains', (select coalesce(jsonb_agg(distinct domain), '[]') from public.combat_changes where encounter_id = e.id and id > coalesce(p_since, 0)),
    'participants', (select coalesce(jsonb_agg(distinct participant_id), '[]') from public.combat_changes where encounter_id = e.id
                     and id > coalesce(p_since, 0) and participant_id is not null),
    'too_many', (select count(*) > 200 from public.combat_changes where encounter_id = e.id and id > coalesce(p_since, 0)));
end $$;

create or replace function public.combat_get_statblock(p_statblock uuid)
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
declare s public.combat_statblocks;
begin
  select * into s from public.combat_statblocks where id = p_statblock;
  if not found then raise exception 'Stat block not found' using errcode = '42501'; end if;
  perform public._combat_auth(s.encounter_id, 'none');
  return to_jsonb(s);
end $$;

create or replace function public.combat_get_history(p_encounter uuid, p_before bigint default null, p_limit int default 50)
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
declare e public.combat_encounters := public._combat_auth(p_encounter, 'none');
begin
  return (select coalesce(jsonb_agg(jsonb_build_object('id', x.id, 'at', x.at, 'kind', x.kind, 'round', x.round, 'participant_id', x.participant_id,
            'participant', (select p.display_name || coalesce(' ' || p.instance_label, '') from public.combat_participants p where p.id = x.participant_id),
            'before', x.before, 'after', x.after, 'details', x.details, 'undoable', x.undoable and x.undone_by is null,
            'undone', x.undone_by is not null, 'undo_of', x.undo_of,
            'actor', (select coalesce(display_name, email) from public.profiles where id = x.actor)) order by x.id desc), '[]')
          from (select * from public.combat_events where encounter_id = e.id and (p_before is null or id < p_before)
                order by id desc limit least(greatest(coalesce(p_limit, 50), 1), 200)) x);
end $$;

-- =============================================================================================== 3. encounter lifecycle
create or replace function public.combat_create_encounter(p_campaign uuid, p_name text, p_ruleset text default 'campaign',
  p_description text default '', p_settings jsonb default '{}', p_request uuid default null)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare e public.combat_encounters; rs text; src text := 'explicit';
begin
  if auth.uid() is null or p_campaign is null or not public._combat_can_run(p_campaign) then
    raise exception 'Only a DM of this campaign can create encounters' using errcode = '42501';
  end if;
  if p_request is not null then
    select x.* into e from public.combat_encounters x join public.combat_events v on v.encounter_id = x.id
    where v.request_id = p_request and v.kind = 'encounter_created' and x.campaign_id = p_campaign;
    if found then return public.combat_get_encounter(e.id) || jsonb_build_object('replayed', true); end if;
  end if;
  if coalesce(btrim(p_name), '') = '' then raise exception 'Give the encounter a name' using errcode = '22023'; end if;
  if coalesce(p_ruleset, 'campaign') = 'campaign' then rs := public._combat_campaign_ruleset(p_campaign); src := 'campaign_default';
  elsif p_ruleset in ('2014', '2024') then rs := p_ruleset;
  else raise exception 'The ruleset is 2014, 2024 or the campaign default' using errcode = '22023'; end if;
  insert into public.combat_encounters (campaign_id, name, description, ruleset, ruleset_source, settings)
  values (p_campaign, left(btrim(p_name), 120), left(coalesce(p_description, ''), 4000), rs, src,
          jsonb_build_object('hp_mode', 'average', 'player_enemy_hp', 'state') || coalesce(p_settings, '{}'))
  returning * into e;
  perform public._combat_event(e.id, 'encounter_created', null, null, null, jsonb_build_object('ruleset', rs, 'ruleset_source', src), p_request, false);
  perform public._combat_changed(e.id, 'encounter', 'created');
  return public.combat_get_encounter(e.id);
end $$;

-- name, description, DM notes, settings, template flag; the ruleset only while it is a draft
create or replace function public.combat_update_encounter(p_encounter uuid, p_patch jsonb, p_expected_rev bigint default null)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare e public.combat_encounters := public._combat_auth(p_encounter, 'update'); k text;
begin
  if p_expected_rev is not null and p_expected_rev <> e.rev then
    raise exception 'This encounter was changed in another window. Your view is updated; check it and try again.' using errcode = 'TLCMB';
  end if;
  for k in select jsonb_object_keys(coalesce(p_patch, '{}')) loop
    if k not in ('name', 'description', 'dm_notes', 'settings', 'is_template', 'ruleset', 'finish_notes') then
      raise exception 'Unknown encounter field "%"', k using errcode = '22023';
    end if;
  end loop;
  if p_patch ? 'ruleset' and p_patch ->> 'ruleset' is distinct from e.ruleset then
    if e.status <> 'draft' then raise exception 'The ruleset can only change before combat starts' using errcode = '22023'; end if;
    if p_patch ->> 'ruleset' = 'campaign' then
      update public.combat_encounters set ruleset = public._combat_campaign_ruleset(campaign_id), ruleset_source = 'campaign_default' where id = e.id;
    elsif p_patch ->> 'ruleset' in ('2014', '2024') then
      update public.combat_encounters set ruleset = p_patch ->> 'ruleset', ruleset_source = 'explicit' where id = e.id;
    else raise exception 'The ruleset is 2014, 2024 or the campaign default' using errcode = '22023'; end if;
  end if;
  if p_patch ? 'name' and coalesce(btrim(p_patch ->> 'name'), '') = '' then raise exception 'Give the encounter a name' using errcode = '22023'; end if;
  update public.combat_encounters set
    name = coalesce(left(btrim(p_patch ->> 'name'), 120), name),
    description = coalesce(left(p_patch ->> 'description', 4000), description),
    dm_notes = coalesce(left(p_patch ->> 'dm_notes', 8000), dm_notes),
    finish_notes = coalesce(left(p_patch ->> 'finish_notes', 8000), finish_notes),
    is_template = coalesce((p_patch ->> 'is_template')::boolean, is_template),
    settings = case when p_patch ? 'settings' and jsonb_typeof(p_patch -> 'settings') = 'object' then settings || (p_patch -> 'settings') else settings end
  where id = e.id;
  perform public._combat_touch(e.id);
  perform public._combat_event(e.id, 'encounter_updated', null, null, null, jsonb_build_object('fields', (select jsonb_agg(k2) from jsonb_object_keys(p_patch) k2)), null, false);
  perform public._combat_changed(e.id, 'encounter', 'updated');
  return public.combat_get_encounter(e.id);
end $$;

create or replace function public.combat_archive_encounter(p_encounter uuid, p_archived boolean default true)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare e public.combat_encounters := public._combat_auth(p_encounter, 'update');
begin
  if p_archived and e.status in ('active', 'paused') then raise exception 'Finish the combat before archiving it' using errcode = '22023'; end if;
  update public.combat_encounters set archived_at = case when p_archived then now() end where id = e.id;
  perform public._combat_touch(e.id);
  perform public._combat_event(e.id, case when p_archived then 'encounter_archived' else 'encounter_restored' end, null, null, null, null, null, false);
  perform public._combat_changed(e.id, 'encounter', case when p_archived then 'archived' else 'restored' end);
  return public._combat_encounter_json((select x from public.combat_encounters x where x.id = e.id));
end $$;

-- a draft that never started can be deleted; everything else is archived instead (history stays)
create or replace function public.combat_delete_draft(p_encounter uuid)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare e public.combat_encounters := public._combat_auth(p_encounter, 'update');
begin
  if e.status <> 'draft' or e.started_at is not null then raise exception 'Only a draft that never started can be deleted. Archive it instead.' using errcode = '22023'; end if;
  update public.combat_encounters set current_participant_id = null where id = e.id;
  delete from public.combat_encounters where id = e.id;
  return jsonb_build_object('deleted', true, 'id', e.id);
end $$;

-- a new draft from any encounter (a prepared template, a finished fight): same participants and reminders, fresh state.
-- Monsters take the CURRENT published version of their source (a new encounter uses new versions); a source that is gone
-- or archived keeps the old snapshot.
create or replace function public.combat_duplicate_encounter(p_encounter uuid, p_name text default null, p_request uuid default null)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare e public.combat_encounters := public._combat_auth(p_encounter, 'share'); n public.combat_encounters; p record; sb public.combat_statblocks;
  latest text; sid uuid; done jsonb;
begin
  if p_request is not null then
    select x.* into n from public.combat_encounters x join public.combat_events v on v.encounter_id = x.id
    where v.request_id = p_request and v.kind = 'encounter_created';
    if found then return public.combat_get_encounter(n.id) || jsonb_build_object('replayed', true); end if;
  end if;
  insert into public.combat_encounters (campaign_id, name, description, dm_notes, ruleset, ruleset_source, settings, source_encounter_id, is_template)
  values (e.campaign_id, left(coalesce(nullif(btrim(p_name), ''), e.name || ' (copy)'), 120), e.description, e.dm_notes, e.ruleset, e.ruleset_source,
          e.settings - 'manual_order' - 'ties_confirmed', e.id, false)
  returning * into n;
  for p in select x.*, s.source_kind, s.source_id, s.snapshot from public.combat_participants x left join public.combat_statblocks s on s.id = x.statblock_id
           where x.encounter_id = e.id and x.removed_at is null order by x.initiative_order nulls last, x.created_at loop
    sid := null;
    if p.kind = 'monster' and p.source_kind in ('srd2024', 'creature', 'homebrew') then
      latest := p.source_id;
      if p.source_kind = 'homebrew' then   -- the current published version of the same DM content
        select cr.id into latest from public.creatures cr join public.dm_content_versions v on v.id = cr.content_version_id
        join public.dm_content dc on dc.id = v.content_id
        where dc.id = (select v2.content_id from public.dm_content_versions v2 join public.creatures c2 on c2.content_version_id = v2.id where c2.id = p.source_id)
          and dc.published_version_id = v.id and cr.archived_at is null;
        latest := coalesce(latest, p.source_id);
      end if;
      begin
        sb := public._combat_snapshot(n.id, p.source_kind, latest, e.campaign_id);
        sid := sb.id;
      exception when others then sid := null;
      end;
    end if;
    if p.kind = 'monster' and sid is null and p.snapshot is not null then
      insert into public.combat_statblocks (encounter_id, source_kind, source_id, source_version, rules_version, name, snapshot)
      select n.id, 'custom', s.source_id, s.source_version, s.rules_version, s.name, s.snapshot from public.combat_statblocks s where s.id = p.statblock_id
      returning id into sid;
    end if;
    if p.kind = 'character' and p.linked_character_id is null then continue; end if;
    insert into public.combat_participants (encounter_id, kind, linked_character_id, statblock_id, display_name, instance_label, player_label, group_key,
      initiative_mod, initiative_tiebreak, hp_current, hp_max, armor_class, hidden, joins_round, legendary_max, legendary_left, notes)
    select n.id, p.kind, p.linked_character_id, sid, p.display_name, p.instance_label, p.player_label, p.group_key, p.initiative_mod, p.initiative_tiebreak,
      case when p.kind = 'monster' then coalesce((select (s.snapshot ->> 'hit_points')::int from public.combat_statblocks s where s.id = sid), p.hp_max) end,
      case when p.kind = 'monster' then coalesce((select (s.snapshot ->> 'hit_points')::int from public.combat_statblocks s where s.id = sid), p.hp_max) end,
      case when p.kind = 'monster' then coalesce((select (s.snapshot ->> 'armor_class')::int from public.combat_statblocks s where s.id = sid), p.armor_class) end,
      p.hidden, p.joins_round, p.legendary_max, p.legendary_max, p.notes;
  end loop;
  insert into public.combat_reminders (encounter_id, kind, title, note, trigger_round, trigger_initiative, repeat_every, hidden, active)
  select n.id, kind, title, note, trigger_round, trigger_initiative, repeat_every, hidden, active from public.combat_reminders where encounter_id = e.id;
  perform public._combat_event(n.id, 'encounter_created', null, null, null, jsonb_build_object('duplicated_from', e.id), p_request, false);
  perform public._combat_changed(n.id, 'encounter', 'created');
  return public.combat_get_encounter(n.id);
end $$;

-- ================================================================================================ 4. participants
-- placement of a participant that joins a running combat: by Initiative, after equal values (renumbered in steps of 10)
create or replace function public._combat_place(p_encounter uuid, p_participant uuid)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare me public.combat_participants; pos int;
begin
  select * into me from public.combat_participants where id = p_participant;
  select coalesce(max(initiative_order), 0) into pos from public.combat_participants
  where encounter_id = p_encounter and id <> p_participant and initiative_order is not null
    and (initiative is null and me.initiative is null or coalesce(initiative, -99) >= coalesce(me.initiative, -99));
  update public.combat_participants set initiative_order = pos + 5 where id = p_participant;
  update public.combat_participants x set initiative_order = y.n * 10
  from (select id, row_number() over (order by initiative_order, created_at) as n from public.combat_participants
        where encounter_id = p_encounter and initiative_order is not null) y where y.id = x.id;
end $$;

-- p_options: {"mods": {"<character id>": {"initiative_mod": 3, "dexterity": 16}}}; the client sends the sheet's Initiative
-- modifier (derived stats); without it the stored DEX modifier + misc bonus is used.
create or replace function public.combat_add_characters(p_encounter uuid, p_characters uuid[], p_options jsonb default '{}', p_request uuid default null)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare e public.combat_encounters := public._combat_auth(p_encounter, 'update'); c public.characters; added jsonb := '[]'; skipped jsonb := '[]';
  pid uuid; m jsonb; r jsonb;
begin
  r := public._combat_replay(e.id, p_request); if r is not null then return r; end if;
  if e.status = 'completed' then raise exception 'This encounter is finished. Duplicate it to run it again.' using errcode = '22023'; end if;
  foreach pid in array coalesce(p_characters, '{}') loop
    select * into c from public.characters where id = pid;
    if not found or c.campaign_id is distinct from e.campaign_id then
      skipped := skipped || jsonb_build_object('id', pid, 'reason', 'not a character of this campaign'); continue;
    end if;
    if exists (select 1 from public.combat_participants where encounter_id = e.id and linked_character_id = pid and removed_at is null) then
      skipped := skipped || jsonb_build_object('id', pid, 'name', c.name, 'reason', 'already in the encounter'); continue;
    end if;
    m := coalesce(p_options -> 'mods' -> pid::text, '{}');
    insert into public.combat_participants (encounter_id, kind, linked_character_id, display_name, initiative_mod, initiative_tiebreak, joins_round)
    values (e.id, 'character', pid, c.name,
            greatest(-20, least(30, coalesce((m ->> 'initiative_mod')::int, floor((c.dexterity - 10) / 2.0)::int + c.initiative_bonus))),
            coalesce((m ->> 'dexterity')::int, c.dexterity),
            case when e.status in ('active', 'paused') and (p_options ->> 'joins_round') is not null then (p_options ->> 'joins_round')::int end)
    returning id into pid;
    if e.status in ('active', 'paused') then perform public._combat_place(e.id, pid); end if;
    added := added || jsonb_build_array(pid);
    perform public._combat_changed(e.id, 'participants', 'added', pid, true);
  end loop;
  perform public._combat_touch(e.id);
  r := jsonb_build_object('added', added, 'skipped', skipped);
  perform public._combat_event(e.id, 'participants_added', null, null, null, r, p_request, false, r);
  return r;
end $$;

-- p_options: {quantity, name, group: 'shared' | 'separate', group_key, hp_mode: 'average' | 'rolled', hidden, joins_round,
--             in_lair, initiative (running combat: a typed value; else rolled), player_label}
create or replace function public.combat_add_monsters(p_encounter uuid, p_source_kind text, p_source_id text, p_options jsonb default '{}',
  p_request uuid default null)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare e public.combat_encounters := public._combat_auth(p_encounter, 'update'); sb public.combat_statblocks; s jsonb; q int; base text;
  existing int; i int; hp int; mode text; gk text; pid uuid; added jsonb := '[]'; r jsonb; lmax int; ini int; roll jsonb;
begin
  r := public._combat_replay(e.id, p_request); if r is not null then return r; end if;
  if e.status = 'completed' then raise exception 'This encounter is finished. Duplicate it to run it again.' using errcode = '22023'; end if;
  q := coalesce((p_options ->> 'quantity')::int, 1);
  if q < 1 or q > 30 then raise exception 'Add between 1 and 30 copies at a time' using errcode = '22023'; end if;
  sb := public._combat_snapshot(e.id, p_source_kind, p_source_id, e.campaign_id);
  s := sb.snapshot;
  base := left(coalesce(nullif(btrim(p_options ->> 'name'), ''), s ->> 'name'), 100);
  mode := coalesce(p_options ->> 'hp_mode', e.settings ->> 'hp_mode', 'average');
  if mode not in ('average', 'rolled') then raise exception 'Hit points are average or rolled' using errcode = '22023'; end if;
  gk := case when coalesce(p_options ->> 'group', case when q > 1 then 'shared' else 'separate' end) = 'shared'
             then coalesce(nullif(p_options ->> 'group_key', ''), lower(regexp_replace(base, '[^A-Za-z0-9]+', '-', 'g')) || '-' || substr(md5(random()::text), 1, 4)) end;
  select count(*) into existing from public.combat_participants where encounter_id = e.id and kind = 'monster' and display_name = base;
  -- a single earlier copy without a letter becomes "A" when more of the same arrive
  if existing = 1 and q >= 1 then
    update public.combat_participants set instance_label = 'A', rev = rev + 1
    where encounter_id = e.id and kind = 'monster' and display_name = base and instance_label is null;
  end if;
  lmax := case when coalesce((p_options ->> 'in_lair')::boolean, false) then coalesce((s -> 'legendary' ->> 'uses_in_lair')::int, (s -> 'legendary' ->> 'uses')::int)
               else (s -> 'legendary' ->> 'uses')::int end;
  for i in 1 .. q loop
    hp := case when mode = 'rolled' then greatest(1, coalesce(public._combat_roll(s ->> 'hit_dice'), (s ->> 'hit_points')::int)) else (s ->> 'hit_points')::int end;
    insert into public.combat_participants (encounter_id, kind, statblock_id, display_name, instance_label, player_label, group_key, initiative_mod,
      initiative_tiebreak, hp_current, hp_max, armor_class, hidden, joins_round, legendary_max, legendary_left)
    values (e.id, 'monster', sb.id, base, case when existing + q > 1 then public._combat_label(existing + i) end, nullif(btrim(p_options ->> 'player_label'), ''), gk,
      coalesce((s -> 'initiative' ->> 'modifier')::int, floor((coalesce((s -> 'abilities' ->> 'dex')::int, 10) - 10) / 2.0)::int),
      coalesce((s -> 'abilities' ->> 'dex')::int, 10), hp, hp, (s ->> 'armor_class')::int,
      coalesce((p_options ->> 'hidden')::boolean, false), (p_options ->> 'joins_round')::int, lmax, lmax)
    returning id into pid;
    added := added || jsonb_build_array(pid);
  end loop;
  -- joining a running combat: an Initiative now (typed, the group's, or rolled), then a place in the order
  if e.status in ('active', 'paused') then
    ini := (p_options ->> 'initiative')::int;
    if ini is null and gk is not null then
      select initiative into ini from public.combat_participants where encounter_id = e.id and group_key = gk and initiative is not null and not (id = any (select jsonb_array_elements_text(added)::uuid)) limit 1;
    end if;
    if ini is null then
      roll := public._combat_d20('normal');
      ini := (roll ->> 'value')::int + coalesce((s -> 'initiative' ->> 'modifier')::int, 0);
    end if;
    update public.combat_participants set initiative = ini, initiative_roll = (roll ->> 'value')::int,
      initiative_mode = case when roll is null then 'manual' else 'rolled' end
    where id = any (select jsonb_array_elements_text(added)::uuid);
    for pid in select jsonb_array_elements_text(added)::uuid loop perform public._combat_place(e.id, pid); end loop;
  end if;
  perform public._combat_touch(e.id);
  perform public._combat_changed(e.id, 'participants', 'added', null, not coalesce((p_options ->> 'hidden')::boolean, false));
  r := jsonb_build_object('added', added, 'statblock_id', sb.id, 'name', base, 'rules_version', sb.rules_version,
    'ruleset_mismatch', sb.rules_version is not null and sb.rules_version <> e.ruleset);
  perform public._combat_event(e.id, 'participants_added', null, null, null, r || jsonb_build_object('source', p_source_kind || ':' || p_source_id, 'quantity', q, 'hp_mode', mode), p_request, false, r);
  return r;
end $$;

-- a combatant typed in on the spot (no catalog entry): name, HP, AC, Initiative modifier, optional notes
create or replace function public.combat_add_custom(p_encounter uuid, p_def jsonb, p_request uuid default null)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare e public.combat_encounters := public._combat_auth(p_encounter, 'update'); sid uuid; pid uuid; hp int; r jsonb; nm text;
begin
  r := public._combat_replay(e.id, p_request); if r is not null then return r; end if;
  nm := left(btrim(coalesce(p_def ->> 'name', '')), 100);
  hp := (p_def ->> 'hp')::int;
  if nm = '' then raise exception 'Give the combatant a name' using errcode = '22023'; end if;
  if hp is null or hp < 1 or hp > 5000 then raise exception 'Hit points are 1 to 5000' using errcode = '22023'; end if;
  if (p_def ->> 'ac') is null then raise exception 'Armor Class is required' using errcode = '22023'; end if;
  insert into public.combat_statblocks (encounter_id, source_kind, source_id, source_version, rules_version, name, snapshot)
  values (e.id, 'custom', null, null, null, nm, jsonb_build_object('name', nm, 'armor_class', (p_def ->> 'ac')::int, 'hit_points', hp,
    'initiative', jsonb_build_object('modifier', coalesce((p_def ->> 'initiative_mod')::int, 0)), 'speed', coalesce(p_def -> 'speed', '{"walk": 30}'),
    'traits', '[]'::jsonb, 'actions', '[]'::jsonb, 'bonus_actions', '[]'::jsonb, 'reactions', '[]'::jsonb, 'notes', p_def ->> 'notes',
    'source_kind', 'custom', 'source_label', 'Typed in this encounter', 'homebrew', true, 'xp', (p_def ->> 'xp')::int))
  returning id into sid;
  insert into public.combat_participants (encounter_id, kind, statblock_id, display_name, initiative_mod, hp_current, hp_max, armor_class, hidden, initiative, initiative_mode)
  values (e.id, 'monster', sid, nm, coalesce((p_def ->> 'initiative_mod')::int, 0), hp, hp, (p_def ->> 'ac')::int, coalesce((p_def ->> 'hidden')::boolean, false),
          (p_def ->> 'initiative')::int, case when (p_def ->> 'initiative') is not null then 'manual' end)
  returning id into pid;
  if e.status in ('active', 'paused') then
    if (p_def ->> 'initiative') is null then
      update public.combat_participants set initiative = (public._combat_d20('normal') ->> 'value')::int + initiative_mod, initiative_mode = 'rolled' where id = pid;
    end if;
    perform public._combat_place(e.id, pid);
  end if;
  perform public._combat_touch(e.id);
  perform public._combat_changed(e.id, 'participants', 'added', pid, not coalesce((p_def ->> 'hidden')::boolean, false));
  r := jsonb_build_object('added', jsonb_build_array(pid));
  perform public._combat_event(e.id, 'participants_added', pid, null, null, r || jsonb_build_object('custom', nm), p_request, false, r);
  return r;
end $$;

-- rename, letter, disguise, group, notes, hidden / revealed, delayed entry, lair uses, AC (monsters)
create or replace function public.combat_update_participant(p_participant uuid, p_patch jsonb, p_expected_rev bigint default null)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare p public.combat_participants := public._combat_participant_auth(p_participant, 'update'); k text; before jsonb;
begin
  if p_expected_rev is not null and p_expected_rev <> p.rev then
    raise exception 'This combatant was changed in another window. Your view is updated.' using errcode = 'TLCMB';
  end if;
  for k in select jsonb_object_keys(coalesce(p_patch, '{}')) loop
    if k not in ('display_name', 'instance_label', 'player_label', 'group_key', 'notes', 'hidden', 'joins_round', 'armor_class', 'legendary_max', 'initiative_mod', 'tiebreak', 'surprised') then
      raise exception 'Unknown combatant field "%"', k using errcode = '22023';
    end if;
  end loop;
  if p.kind = 'character' and (p_patch ? 'armor_class' or p_patch ? 'display_name') then
    raise exception 'A player character''s name and Armor Class come from the character sheet' using errcode = '22023';
  end if;
  before := jsonb_build_object('display_name', p.display_name, 'instance_label', p.instance_label, 'hidden', p.hidden, 'notes', p.notes, 'joins_round', p.joins_round);
  update public.combat_participants set
    display_name = coalesce(nullif(left(btrim(p_patch ->> 'display_name'), 120), ''), display_name),
    instance_label = case when p_patch ? 'instance_label' then nullif(left(btrim(p_patch ->> 'instance_label'), 12), '') else instance_label end,
    player_label = case when p_patch ? 'player_label' then nullif(left(btrim(p_patch ->> 'player_label'), 120), '') else player_label end,
    group_key = case when p_patch ? 'group_key' then nullif(left(btrim(p_patch ->> 'group_key'), 60), '') else group_key end,
    notes = coalesce(left(p_patch ->> 'notes', 4000), notes),
    hidden = coalesce((p_patch ->> 'hidden')::boolean, hidden),
    revealed_at = case when (p_patch ->> 'hidden')::boolean is false and hidden then now() else revealed_at end,
    joins_round = case when p_patch ? 'joins_round' then (p_patch ->> 'joins_round')::int else joins_round end,
    armor_class = coalesce((p_patch ->> 'armor_class')::int, armor_class),
    legendary_max = coalesce((p_patch ->> 'legendary_max')::int, legendary_max),
    legendary_left = least(coalesce((p_patch ->> 'legendary_max')::int, legendary_max), coalesce(legendary_left, legendary_max)),
    initiative_mod = coalesce((p_patch ->> 'initiative_mod')::int, initiative_mod),
    initiative_tiebreak = coalesce((p_patch ->> 'tiebreak')::int, initiative_tiebreak),
    surprised = coalesce((p_patch ->> 'surprised')::boolean, surprised),
    rev = rev + 1
  where id = p.id;
  perform public._combat_event(p.encounter_id, case when p_patch ? 'hidden' then case when (p_patch ->> 'hidden')::boolean then 'participant_hidden' else 'participant_revealed' end
                               else 'participant_updated' end, p.id, before, p_patch, null, null, false);
  perform public._combat_changed(p.encounter_id, 'participants', case when p_patch ? 'hidden' then 'visibility' else 'updated' end, p.id,
                                 not coalesce((p_patch ->> 'hidden')::boolean, p.hidden));
  return public.combat_get_participant(p.id);
end $$;

-- p_state: deactivate | activate | defeat | restore | remove. A draft deletes on remove; a running combat keeps the row
-- (inactive, history intact). Removing the participant whose turn it is moves the turn on only when asked (p_advance).
create or replace function public.combat_set_participant_state(p_participant uuid, p_state text, p_reason text default null, p_request uuid default null)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare p public.combat_participants := public._combat_participant_auth(p_participant, 'update'); e public.combat_encounters; r jsonb; before jsonb;
begin
  select * into e from public.combat_encounters where id = p.encounter_id;
  r := public._combat_replay(e.id, p_request); if r is not null then return r; end if;
  before := jsonb_build_object('active', p.active, 'defeated', p.defeated, 'removed', p.removed_at is not null);
  case p_state
  when 'remove' then
    if e.status = 'draft' and e.started_at is null then
      delete from public.combat_participants where id = p.id;
      perform public._combat_touch(e.id);
      perform public._combat_changed(e.id, 'participants', 'removed', p.id, not p.hidden);
      return jsonb_build_object('removed', true, 'deleted', true, 'id', p.id);
    end if;
    update public.combat_participants set active = false, removed_at = now(), rev = rev + 1 where id = p.id;
    -- concentration of a removed combatant ends; its effects on others end with it (source removed)
    update public.combat_effects set active = false, ended_at = now(), ended_reason = 'source_removed', rev = rev + 1
    where encounter_id = e.id and active and (target_participant_id = p.id or (effect_type = 'concentration' and source_participant_id = p.id)
          or concentration_id in (select id from public.combat_effects where effect_type = 'concentration' and source_participant_id = p.id));
  when 'deactivate' then update public.combat_participants set active = false, rev = rev + 1 where id = p.id;
  when 'activate' then update public.combat_participants set active = true, removed_at = null, rev = rev + 1 where id = p.id;
  when 'defeat' then update public.combat_participants set defeated = true, defeated_at = now(), rev = rev + 1 where id = p.id;
  when 'restore' then update public.combat_participants set defeated = false, defeated_at = null, active = true, removed_at = null, rev = rev + 1 where id = p.id;
  else raise exception 'Unknown state "%"', p_state using errcode = '22023';
  end case;
  if p_state in ('remove', 'activate', 'restore') then perform public._combat_touch(e.id); end if;
  perform public._combat_changed(e.id, 'participants', p_state, p.id, not p.hidden);
  if p_state = 'remove' then perform public._combat_changed(e.id, 'effects', 'ended', p.id, not p.hidden); end if;
  r := jsonb_build_object('participant', public._combat_pjson((select x from public.combat_participants x where x.id = p.id)),
         'is_current', e.current_participant_id = p.id);
  perform public._combat_event(e.id, 'participant_' || p_state, p.id, before, null, jsonb_build_object('reason', p_reason), p_request,
                               p_state in ('defeat', 'restore', 'deactivate', 'activate'), r);
  return r;
end $$;

-- ================================================================================================= 5. Initiative
-- the deterministic default order (docs/COMBAT_INITIATIVE_RULES.md): Initiative high to low; ties: higher Initiative
-- modifier, higher DEX score, player characters before monsters, then group, name and letter. A group stays together.
create or replace function public._combat_sorted(p_encounter uuid)
returns table (id uuid, n int) language sql stable security definer set search_path = public, pg_temp as $$
  select p.id, (row_number() over (order by p.initiative desc nulls last, p.initiative_mod desc, p.initiative_tiebreak desc,
      (p.kind = 'character') desc, coalesce(p.group_key, p.id::text), p.display_name, p.instance_label nulls first, p.created_at))::int
  from public.combat_participants p where p.encounter_id = p_encounter and p.removed_at is null;
$$;

-- tie groups the DM should look at: equal Initiative between different combatants (members of one group do not count)
create or replace function public._combat_ties(p_encounter uuid)
returns jsonb language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce(jsonb_agg(jsonb_build_object('initiative', t.initiative, 'participants', t.ids, 'kind', t.kind) order by t.initiative desc), '[]')
  from (select initiative, jsonb_agg(id order by initiative_order nulls last, created_at) as ids,
               case when bool_and(kind = 'character') then 'characters' when bool_and(kind = 'monster') then 'monsters' else 'mixed' end as kind
        from public.combat_participants where encounter_id = p_encounter and removed_at is null and active and initiative is not null
        group by initiative having count(distinct coalesce(group_key, id::text)) > 1) t;
$$;

create or replace function public._combat_apply_order(p_encounter uuid)
returns void language sql security definer set search_path = public, pg_temp as $$
  update public.combat_participants x set initiative_order = s.n * 10 from public._combat_sorted(p_encounter) s where s.id = x.id;
$$;

-- Initiative roll mode of a participant under the encounter's rules (2024: surprise / incapacitated -> Disadvantage,
-- Invisible -> Advantage; any ruleset: an "initiative" advantage state). Both -> normal.
create or replace function public._combat_init_mode(p public.combat_participants, p_ruleset text)
returns text language sql stable security definer set search_path = public, pg_temp as $$
  with f as (
    select (p_ruleset = '2024' and p.surprised)
             or (p_ruleset = '2024' and exists (select 1 from public.combat_effects x join public.combat_conditions k on k.ruleset = p_ruleset and k.key = x.condition_key
                   where x.target_participant_id = p.id and x.active and x.effect_type = 'condition' and k.initiative = 'disadvantage'))
             or exists (select 1 from public.combat_effects x where x.target_participant_id = p.id and x.active and x.effect_type = 'advantage'
                        and x.adv_scope = 'initiative' and x.adv_mode = 'disadvantage') as dis,
           (p_ruleset = '2024' and exists (select 1 from public.combat_effects x join public.combat_conditions k on k.ruleset = p_ruleset and k.key = x.condition_key
                   where x.target_participant_id = p.id and x.active and x.effect_type = 'condition' and k.initiative = 'advantage'))
             or exists (select 1 from public.combat_effects x where x.target_participant_id = p.id and x.active and x.effect_type = 'advantage'
                        and x.adv_scope = 'initiative' and x.adv_mode = 'advantage') as adv)
  select case when dis and adv then 'normal' when dis then 'disadvantage' when adv then 'advantage' else 'normal' end from f;
$$;

-- typed values: [{"id": "<participant>", "initiative": 17}] (null clears). In a running combat the participant moves to its
-- new place (audited).
create or replace function public.combat_set_initiative(p_encounter uuid, p_values jsonb, p_request uuid default null)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare e public.combat_encounters := public._combat_auth(p_encounter, 'update'); v jsonb; p public.combat_participants; before jsonb := '[]'; n int := 0; r jsonb;
begin
  r := public._combat_replay(e.id, p_request); if r is not null then return r; end if;
  if e.status = 'completed' then raise exception 'This encounter is finished' using errcode = '22023'; end if;
  for v in select x from jsonb_array_elements(coalesce(p_values, '[]')) x loop
    select * into p from public.combat_participants where id = (v ->> 'id')::uuid and encounter_id = e.id for update;
    if not found then raise exception 'Combatant not found in this encounter' using errcode = '22023'; end if;
    if (v ->> 'initiative') is not null and ((v ->> 'initiative')::int < -20 or (v ->> 'initiative')::int > 60) then
      raise exception 'Initiative is -20 to 60' using errcode = '22023';
    end if;
    before := before || jsonb_build_object('id', p.id, 'initiative', p.initiative, 'initiative_roll', p.initiative_roll, 'initiative_mode', p.initiative_mode, 'order', p.initiative_order);
    update public.combat_participants set initiative = (v ->> 'initiative')::int, initiative_roll = null,
      initiative_mode = case when (v ->> 'initiative') is null then null when p.kind = 'character' then 'player' else 'manual' end, rev = rev + 1
    where id = p.id;
    if e.status in ('active', 'paused') then perform public._combat_place(e.id, p.id); end if;
    n := n + 1;
  end loop;
  if e.status = 'draft' and not coalesce((e.settings ->> 'manual_order')::boolean, false) then perform public._combat_apply_order(e.id); end if;
  update public.combat_encounters set settings = settings - 'ties_confirmed' where id = e.id;
  perform public._combat_touch(e.id);
  perform public._combat_changed(e.id, 'participants', 'initiative', null, true);
  r := jsonb_build_object('updated', n, 'ties', public._combat_ties(e.id));
  perform public._combat_event(e.id, case when e.status = 'draft' then 'initiative_set' else 'initiative_changed' end, null, jsonb_build_object('values', before),
    jsonb_build_object('values', p_values), null, p_request, true, r);
  return r;
end $$;

-- server rolls. p_participants null = every active monster without an Initiative (p_options.reroll: all monsters).
-- p_options: {reroll, fixed (2024: the printed Initiative score instead of a roll), include_characters}
create or replace function public.combat_roll_initiative(p_encounter uuid, p_participants uuid[] default null, p_options jsonb default '{}', p_request uuid default null)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare e public.combat_encounters := public._combat_auth(p_encounter, 'update'); p public.combat_participants; before jsonb := '[]'; rolled jsonb := '[]';
  groups jsonb := '{}'; roll jsonb; md text; val int; fixed boolean := coalesce((p_options ->> 'fixed')::boolean, false); r jsonb; score int;
begin
  r := public._combat_replay(e.id, p_request); if r is not null then return r; end if;
  if e.status = 'completed' then raise exception 'This encounter is finished' using errcode = '22023'; end if;
  if fixed and e.ruleset <> '2024' then raise exception 'Fixed Initiative scores are a 2024 stat block option' using errcode = '22023'; end if;
  for p in select x.* from public.combat_participants x where x.encounter_id = e.id and x.removed_at is null and x.active
             and (case when p_participants is not null then x.id = any (p_participants)
                       else x.kind = 'monster' and (x.initiative is null or coalesce((p_options ->> 'reroll')::boolean, false)) end)
             and (x.kind = 'monster' or coalesce((p_options ->> 'include_characters')::boolean, p_participants is not null))
           order by x.group_key nulls last, x.created_at for update loop
    before := before || jsonb_build_object('id', p.id, 'initiative', p.initiative, 'initiative_roll', p.initiative_roll, 'initiative_mode', p.initiative_mode);
    md := public._combat_init_mode(p, e.ruleset);
    if p.group_key is not null and groups ? p.group_key then
      roll := groups -> p.group_key;
    else
      if fixed and p.kind = 'monster' then
        score := (select (s.snapshot -> 'initiative' ->> 'score')::int from public.combat_statblocks s where s.id = p.statblock_id);
        roll := jsonb_build_object('fixed', true, 'value', coalesce(score, 10 + p.initiative_mod) - p.initiative_mod, 'mode', 'fixed', 'rolls', '[]'::jsonb);
      else
        roll := public._combat_d20(md);
      end if;
      if p.group_key is not null then groups := groups || jsonb_build_object(p.group_key, roll); end if;
    end if;
    val := (roll ->> 'value')::int + p.initiative_mod;
    update public.combat_participants set initiative = greatest(-20, least(60, val)), initiative_roll = (roll ->> 'value')::int,
      initiative_mode = case when roll ? 'fixed' then 'fixed' else 'rolled' end, rev = rev + 1
    where id = p.id;
    if e.status in ('active', 'paused') then perform public._combat_place(e.id, p.id); end if;
    rolled := rolled || jsonb_build_object('id', p.id, 'name', p.display_name || coalesce(' ' || p.instance_label, ''), 'd20', roll -> 'rolls',
      'mode', roll ->> 'mode', 'modifier', p.initiative_mod, 'initiative', greatest(-20, least(60, val)), 'group', p.group_key);
  end loop;
  if e.status = 'draft' and not coalesce((e.settings ->> 'manual_order')::boolean, false) then perform public._combat_apply_order(e.id); end if;
  update public.combat_encounters set settings = settings - 'ties_confirmed' where id = e.id;
  perform public._combat_touch(e.id);
  perform public._combat_changed(e.id, 'participants', 'initiative', null, true);
  r := jsonb_build_object('rolled', rolled, 'ties', public._combat_ties(e.id));
  perform public._combat_event(e.id, 'initiative_rolled', null, jsonb_build_object('values', before), jsonb_build_object('values', rolled), null, p_request, true, r);
  return r;
end $$;

create or replace function public.combat_clear_initiative(p_encounter uuid, p_scope text default 'all')
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare e public.combat_encounters := public._combat_auth(p_encounter, 'update'); before jsonb;
begin
  if e.status <> 'draft' then raise exception 'Initiative can be cleared before combat starts' using errcode = '22023'; end if;
  if p_scope not in ('all', 'monsters') then raise exception 'Clear all or monsters' using errcode = '22023'; end if;
  select coalesce(jsonb_agg(jsonb_build_object('id', id, 'initiative', initiative, 'initiative_roll', initiative_roll, 'initiative_mode', initiative_mode)), '[]') into before
  from public.combat_participants where encounter_id = e.id and (p_scope = 'all' or kind = 'monster');
  update public.combat_participants set initiative = null, initiative_roll = null, initiative_mode = null, rev = rev + 1
  where encounter_id = e.id and (p_scope = 'all' or kind = 'monster');
  update public.combat_encounters set settings = settings - 'manual_order' - 'ties_confirmed' where id = e.id;
  perform public._combat_touch(e.id);
  perform public._combat_changed(e.id, 'participants', 'initiative', null, true);
  perform public._combat_event(e.id, 'initiative_cleared', null, jsonb_build_object('values', before), null, jsonb_build_object('scope', p_scope), null, true);
  return jsonb_build_object('cleared', p_scope);
end $$;

create or replace function public.combat_sort_initiative(p_encounter uuid)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare e public.combat_encounters := public._combat_auth(p_encounter, 'update');
begin
  if e.status <> 'draft' then raise exception 'The order is locked once combat starts. Move a combatant instead.' using errcode = '22023'; end if;
  perform public._combat_apply_order(e.id);
  update public.combat_encounters set settings = settings - 'manual_order' - 'ties_confirmed' where id = e.id;
  perform public._combat_touch(e.id);
  perform public._combat_changed(e.id, 'participants', 'order', null, true);
  return jsonb_build_object('ties', public._combat_ties(e.id));
end $$;

-- a manual order (ties, or a DM decision). In a running combat it is audited and needs the current turn revision.
create or replace function public.combat_reorder(p_encounter uuid, p_order uuid[], p_reason text default null, p_expected_turn_rev bigint default null,
  p_request uuid default null)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare e public.combat_encounters := public._combat_auth(p_encounter, 'update'); before jsonb; r jsonb; i int;
begin
  r := public._combat_replay(e.id, p_request); if r is not null then return r; end if;
  if e.status = 'completed' then raise exception 'This encounter is finished' using errcode = '22023'; end if;
  if e.status <> 'draft' and p_expected_turn_rev is not null and p_expected_turn_rev <> e.turn_rev then
    raise exception 'The turn moved meanwhile. Your view is updated; reorder again if needed.' using errcode = 'TLCMB';
  end if;
  if exists (select unnest(p_order) except select id from public.combat_participants where encounter_id = e.id) then
    raise exception 'The order lists a combatant of another encounter' using errcode = '22023';
  end if;
  select coalesce(jsonb_agg(id order by initiative_order nulls last, created_at), '[]') into before from public.combat_participants where encounter_id = e.id and removed_at is null;
  for i in 1 .. coalesce(array_length(p_order, 1), 0) loop
    update public.combat_participants set initiative_order = i * 10, rev = rev + 1 where id = p_order[i];
  end loop;
  -- combatants missing from the list keep their relative order after the listed ones
  update public.combat_participants x set initiative_order = (coalesce(array_length(p_order, 1), 0) + s.n) * 10
  from (select id, row_number() over (order by initiative_order nulls last, created_at) n from public.combat_participants
        where encounter_id = e.id and removed_at is null and not (id = any (p_order))) s where s.id = x.id;
  update public.combat_encounters set settings = (settings || '{"manual_order": true}'::jsonb) - 'ties_confirmed' where id = e.id;
  perform public._combat_touch(e.id);
  perform public._combat_changed(e.id, 'participants', 'order', null, true);
  r := jsonb_build_object('order', to_jsonb(p_order));
  perform public._combat_event(e.id, case when e.status = 'draft' then 'order_set' else 'order_changed' end, null, jsonb_build_object('order', before),
    jsonb_build_object('order', to_jsonb(p_order)), jsonb_build_object('reason', p_reason), p_request, false, r);
  return r;
end $$;

-- ================================================================================================= 6. turns and rounds
create or replace function public._combat_can_act(p public.combat_participants, p_round int)
returns boolean language sql immutable set search_path = public, pg_temp as $$
  select p.active and p.removed_at is null and not (p.kind = 'monster' and p.defeated) and (p.joins_round is null or p.joins_round <= p_round);
$$;

-- effect clocks at one turn boundary of one participant. Returns {effects: [{id, before, after}], notices: [...]}.
create or replace function public._combat_boundary(p_encounter uuid, p_participant uuid, p_when text)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare x public.combat_effects; y public.combat_effects; nr int; expire boolean; ch jsonb := '[]'; nt jsonb := '[]'; tname text;
begin
  for x in select * from public.combat_effects where encounter_id = p_encounter and active and anchor_participant_id = p_participant
             and ((duration_type = 'rounds' and expires_on = p_when) or (duration_type = 'until_turn_start' and p_when = 'turn_start')
                  or (duration_type = 'until_turn_end' and p_when = 'turn_end'))
           order by created_at for update loop
    if x.duration_type = 'rounds' then nr := greatest(coalesce(x.remaining_rounds, x.duration_rounds) - 1, 0); expire := nr = 0;
    elsif coalesce(x.remaining_rounds, 0) > 0 then nr := x.remaining_rounds - 1; expire := false;
    else nr := 0; expire := true; end if;
    update public.combat_effects set remaining_rounds = nr, active = not expire, ended_at = case when expire then now() end,
      ended_reason = case when expire then 'expired' end, rev = rev + 1 where id = x.id;
    ch := ch || jsonb_build_object('id', x.id, 'before', jsonb_build_object('active', x.active, 'remaining_rounds', x.remaining_rounds),
                                   'after', jsonb_build_object('active', not expire, 'remaining_rounds', nr));
    select display_name || coalesce(' ' || instance_label, '') into tname from public.combat_participants where id = x.target_participant_id;
    if expire then
      nt := nt || jsonb_build_object('kind', 'expired', 'effect_id', x.id, 'effect', x.display_name, 'target', tname, 'target_id', x.target_participant_id);
      if x.effect_type = 'concentration' then   -- a concentration that ran out ends what depends on it
        for y in select * from public.combat_effects where concentration_id = x.id and active for update loop
          update public.combat_effects set active = false, ended_at = now(), ended_reason = 'concentration_ended', rev = rev + 1 where id = y.id;
          ch := ch || jsonb_build_object('id', y.id, 'before', jsonb_build_object('active', true, 'remaining_rounds', y.remaining_rounds),
                                         'after', jsonb_build_object('active', false, 'remaining_rounds', y.remaining_rounds));
        end loop;
      end if;
    elsif x.duration_type = 'rounds' then
      nt := nt || jsonb_build_object('kind', 'tick', 'effect_id', x.id, 'effect', x.display_name, 'target', tname, 'remaining', nr);
    end if;
  end loop;
  -- "save ends" and other repeated saves: a reminder for the DM, never a roll
  for x in select * from public.combat_effects where encounter_id = p_encounter and active and target_participant_id = p_participant
             and save_ability is not null and coalesce(save_timing, 'turn_end') = p_when order by created_at loop
    nt := nt || jsonb_build_object('kind', 'save', 'effect_id', x.id, 'effect', x.display_name, 'ability', x.save_ability, 'dc', x.save_dc,
      'target', (select display_name || coalesce(' ' || instance_label, '') from public.combat_participants where id = p_participant), 'target_id', p_participant);
  end loop;
  return jsonb_build_object('effects', ch, 'notices', nt);
end $$;

-- reminders due when the turn moves from Initiative a (round ra) to Initiative b (round rb); p_start = combat start
create or replace function public._combat_reminders_due(p_encounter uuid, a int, ra int, b int, rb int, p_start boolean)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare rm public.combat_reminders; due int; fire boolean; out jsonb := '[]';
begin
  for rm in select * from public.combat_reminders where encounter_id = p_encounter and active order by created_at for update loop
    due := null;
    if rm.trigger_initiative is null then
      if p_start or rb > ra then due := rb; end if;                                     -- the start of a round
    elsif p_start then
      if rm.trigger_initiative > b then due := rb; end if;
    elsif rb = ra then
      if a >= rm.trigger_initiative and rm.trigger_initiative > b then due := rb; end if;
    else
      if a >= rm.trigger_initiative then due := ra;                                      -- the end of the old round
      elsif rm.trigger_initiative > b then due := rb; end if;                            -- the start of the new one
    end if;
    fire := due is not null and coalesce(rm.last_fired_round, 0) < due
      and (rm.trigger_round is null or (due >= rm.trigger_round and (case when rm.repeat_every is null then due = rm.trigger_round
                                                                        else (due - rm.trigger_round) % rm.repeat_every = 0 end)));
    if fire then
      update public.combat_reminders set last_fired_round = due, rev = rev + 1 where id = rm.id;
      out := out || jsonb_build_object('kind', 'reminder', 'reminder_id', rm.id, 'title', rm.title, 'note', rm.note, 'reminder_kind', rm.kind,
                                       'round', due, 'before_last_fired', rm.last_fired_round, 'hidden', rm.hidden);
    end if;
  end loop;
  return out;
end $$;

-- start of a participant's turn: Reaction back (2014 surprise: not until the end of its first turn), Legendary uses back
create or replace function public._combat_turn_start(p_encounter uuid, p_participant uuid, p_ruleset text)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare p public.combat_participants; ch jsonb; b jsonb; nt jsonb := '[]'; still boolean;
begin
  select * into p from public.combat_participants where id = p_participant for update;
  still := p_ruleset = '2014' and p.surprised and p.turns_taken = 0;
  ch := jsonb_build_object('id', p.id, 'before', jsonb_build_object('reaction_used', p.reaction_used, 'legendary_left', p.legendary_left,
          'surprised', p.surprised, 'turns_taken', p.turns_taken));
  update public.combat_participants set reaction_used = still, legendary_left = legendary_max, rev = rev + 1 where id = p.id;
  ch := ch || jsonb_build_object('after', jsonb_build_object('reaction_used', still, 'legendary_left', p.legendary_max,
          'surprised', p.surprised, 'turns_taken', p.turns_taken));
  if still then
    nt := nt || jsonb_build_object('kind', 'surprised', 'target', p.display_name || coalesce(' ' || p.instance_label, ''), 'target_id', p.id,
      'text', 'Surprised: no movement and no action this turn, no Reaction until the turn ends.');
  end if;
  if p.kind = 'monster' and p.legendary_max is not null and coalesce(p.legendary_left, 0) < p.legendary_max then
    nt := nt || jsonb_build_object('kind', 'legendary_reset', 'target', p.display_name || coalesce(' ' || p.instance_label, ''), 'target_id', p.id, 'uses', p.legendary_max);
  end if;
  b := public._combat_boundary(p_encounter, p.id, 'turn_start');
  return jsonb_build_object('participant', ch, 'effects', b -> 'effects', 'notices', nt || (b -> 'notices'));
end $$;

-- end of a participant's turn: its clocks, then the 2014 surprise ends
create or replace function public._combat_turn_end(p_encounter uuid, p_participant uuid, p_ruleset text)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare p public.combat_participants; ch jsonb; b jsonb; nreact boolean; nsurp boolean;
begin
  select * into p from public.combat_participants where id = p_participant for update;
  b := public._combat_boundary(p_encounter, p.id, 'turn_end');
  nreact := case when p_ruleset = '2014' and p.surprised then false else p.reaction_used end;
  nsurp := case when p_ruleset = '2014' then false else p.surprised end;
  ch := jsonb_build_object('id', p.id, 'before', jsonb_build_object('reaction_used', p.reaction_used, 'legendary_left', p.legendary_left,
          'surprised', p.surprised, 'turns_taken', p.turns_taken));
  update public.combat_participants set turns_taken = turns_taken + 1, surprised = nsurp, reaction_used = nreact, rev = rev + 1 where id = p.id;
  ch := ch || jsonb_build_object('after', jsonb_build_object('reaction_used', nreact, 'legendary_left', p.legendary_left, 'surprised', nsurp,
          'turns_taken', p.turns_taken + 1));
  return jsonb_build_object('participant', ch, 'effects', b -> 'effects', 'notices', b -> 'notices');
end $$;

-- what a turn change returns: the encounter shell, the touched participants and effects, the notices
create or replace function public._combat_turn_result(p_encounter uuid, p_participants uuid[], p_effects uuid[], p_notices jsonb, p_event bigint)
returns jsonb language sql stable security definer set search_path = public, pg_temp as $$
  select jsonb_build_object('encounter', public._combat_encounter_json(e),
    'participants', (select coalesce(jsonb_agg(public._combat_pjson(p)), '[]') from public.combat_participants p where p.id = any (p_participants)),
    'effects', (select coalesce(jsonb_agg(public._combat_ejson(x)), '[]') from public.combat_effects x where x.id = any (p_effects)),
    'notices', coalesce(p_notices, '[]'), 'event_id', p_event)
  from public.combat_encounters e where e.id = p_encounter;
$$;

create or replace function public._combat_ids(p jsonb, k text)
returns uuid[] language sql immutable set search_path = public, pg_temp as $$
  select coalesce(array_agg(distinct (x ->> k)::uuid), '{}') from jsonb_array_elements(coalesce(p, '[]')) x where x ->> k is not null;
$$;

-- Start: every active combatant needs an Initiative; ties are shown once for the DM to accept or reorder (p_accept_ties).
create or replace function public.combat_start(p_encounter uuid, p_accept_ties boolean default false, p_request uuid default null)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare e public.combat_encounters := public._combat_auth(p_encounter, 'update'); r jsonb; missing text; ties jsonb; first public.combat_participants;
  ts jsonb; rem jsonb; nt jsonb := '[]'; ev bigint; touched uuid[];
begin
  r := public._combat_replay(e.id, p_request); if r is not null then return r; end if;
  if e.status <> 'draft' then raise exception 'Combat already started' using errcode = '22023'; end if;
  if not exists (select 1 from public.combat_participants where encounter_id = e.id and removed_at is null and active) then
    raise exception 'Add combatants first' using errcode = '22023';
  end if;
  select string_agg(display_name || coalesce(' ' || instance_label, ''), ', ' order by created_at) into missing from public.combat_participants
  where encounter_id = e.id and removed_at is null and active and initiative is null and (joins_round is null or joins_round <= 1);
  if missing is not null then raise exception 'Set Initiative for: %', missing using errcode = '22023', hint = 'initiative'; end if;
  if coalesce((e.settings ->> 'manual_order')::boolean, false) then
    update public.combat_participants x set initiative_order = (1000 + s.n) * 10 from public._combat_sorted(e.id) s
    where s.id = x.id and x.initiative_order is null;
  else
    perform public._combat_apply_order(e.id);
  end if;
  ties := public._combat_ties(e.id);
  if jsonb_array_length(ties) > 0 and not coalesce(p_accept_ties, false) and not coalesce((e.settings ->> 'ties_confirmed')::boolean, false) then
    perform public._combat_touch(e.id);
    perform public._combat_changed(e.id, 'participants', 'order', null, false);
    return jsonb_build_object('needs_tie_review', true, 'ties', ties);
  end if;
  select * into first from public.combat_participants p where p.encounter_id = e.id and public._combat_can_act(p, 1)
  order by p.initiative_order nulls last, p.created_at limit 1;
  if first.id is null then raise exception 'No combatant can act in round 1' using errcode = '22023'; end if;
  update public.combat_encounters set status = 'active', round = 1, current_participant_id = first.id, started_at = now(), resumed_at = now(),
    paused_at = null, turn_rev = turn_rev + 1, rev = rev + 1, updated_at = now(), settings = settings || '{"ties_confirmed": true}' where id = e.id;
  update public.combat_participants set reaction_used = (e.ruleset = '2014' and surprised), turns_taken = 0, legendary_left = legendary_max, rev = rev + 1
  where encounter_id = e.id;
  ts := public._combat_turn_start(e.id, first.id, e.ruleset);
  rem := public._combat_reminders_due(e.id, null, 1, coalesce(first.initiative, -99), 1, true);
  nt := (ts -> 'notices') || rem;
  touched := array(select id from public.combat_participants where encounter_id = e.id);
  ev := public._combat_event(e.id, 'combat_started', first.id, null, jsonb_build_object('round', 1, 'current', first.id, 'turn_rev', e.turn_rev + 1),
    jsonb_build_object('ties', ties, 'notices', nt), p_request, false);
  perform public._combat_changed(e.id, 'turn', 'started', first.id, not first.hidden);
  r := public._combat_turn_result(e.id, touched, public._combat_ids(ts -> 'effects', 'id'), nt, ev);
  perform public._combat_set_result(ev, r - 'participants' - 'effects');
  return r;
end $$;

-- Next / End Turn / Skip. p_expected_turn_rev: the turn the client saw; a second click for the same turn gets the replay
-- (same request) or a friendly conflict (another window moved it).
create or replace function public.combat_next_turn(p_encounter uuid, p_expected_turn_rev bigint, p_mode text default 'next', p_request uuid default null)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare e public.combat_encounters := public._combat_auth(p_encounter, 'update'); r jsonb; cur public.combat_participants; nxt public.combat_participants;
  te jsonb := jsonb_build_object('effects', '[]'::jsonb, 'notices', '[]'::jsonb); ts jsonb; nr int; nt jsonb := '[]'; rem jsonb; ev bigint;
  pchanges jsonb := '[]'; echanges jsonb; leg jsonb; cur_init int;
begin
  r := public._combat_replay(e.id, p_request); if r is not null then return r; end if;
  if p_mode not in ('next', 'skip') then raise exception 'Unknown turn move "%"', p_mode using errcode = '22023'; end if;
  if e.status = 'paused' then raise exception 'The combat is paused. Resume it first.' using errcode = '22023'; end if;
  if e.status <> 'active' then raise exception 'Start combat first' using errcode = '22023'; end if;
  if p_expected_turn_rev is not null and p_expected_turn_rev <> e.turn_rev then
    raise exception 'The turn already moved (another window or a second click). Your view is updated.' using errcode = 'TLCMB';
  end if;
  select * into cur from public.combat_participants where id = e.current_participant_id;
  cur_init := coalesce(cur.initiative, -99);
  -- 1-3: the end of the current turn
  if cur.id is not null then
    te := public._combat_turn_end(e.id, cur.id, e.ruleset);
    pchanges := pchanges || jsonb_build_array(te -> 'participant');
  end if;
  -- 4-6: the next combatant who can act (inactive, removed, defeated monsters and not-yet-joined are skipped)
  nr := e.round;
  select * into nxt from public.combat_participants p where p.encounter_id = e.id and public._combat_can_act(p, e.round)
    and p.initiative_order > coalesce(cur.initiative_order, -1) order by p.initiative_order, p.created_at limit 1;
  if nxt.id is null then
    nr := e.round + 1;
    select * into nxt from public.combat_participants p where p.encounter_id = e.id and public._combat_can_act(p, nr)
    order by p.initiative_order nulls last, p.created_at limit 1;
  end if;
  if nxt.id is null then raise exception 'No combatant can take a turn (all are defeated, inactive or not yet joined)' using errcode = '22023'; end if;
  -- Legendary Actions: available after another creature's turn
  select coalesce(jsonb_agg(jsonb_build_object('kind', 'legendary', 'target', p.display_name || coalesce(' ' || p.instance_label, ''), 'target_id', p.id,
           'left', p.legendary_left, 'max', p.legendary_max)), '[]') into leg
  from public.combat_participants p where p.encounter_id = e.id and p.id is distinct from cur.id and p.legendary_max is not null and coalesce(p.legendary_left, 0) > 0
    and public._combat_can_act(p, e.round) and p.id <> nxt.id;
  -- 7: reminders crossed on the way (round starts, Initiative counts such as a lair action at 20)
  rem := public._combat_reminders_due(e.id, cur_init, e.round, coalesce(nxt.initiative, -99), nr, false);
  -- 8-10: the start of the next turn
  ts := public._combat_turn_start(e.id, nxt.id, e.ruleset);
  pchanges := pchanges || jsonb_build_array(ts -> 'participant');
  echanges := (te -> 'effects') || (ts -> 'effects');
  nt := (te -> 'notices') || leg || (case when nr > e.round then jsonb_build_array(jsonb_build_object('kind', 'round', 'round', nr)) else '[]'::jsonb end) || rem || (ts -> 'notices');
  update public.combat_encounters set round = nr, current_participant_id = nxt.id, turn_rev = turn_rev + 1, rev = rev + 1, updated_at = now() where id = e.id;
  ev := public._combat_event(e.id, 'turn_advanced', nxt.id,
    jsonb_build_object('round', e.round, 'current', cur.id, 'turn_rev', e.turn_rev),
    jsonb_build_object('round', nr, 'current', nxt.id, 'turn_rev', e.turn_rev + 1),
    jsonb_build_object('mode', p_mode, 'effects', echanges, 'participants', pchanges, 'reminders', rem, 'notices', nt), p_request, true);
  perform public._combat_changed(e.id, 'turn', case when nr > e.round then 'round' else 'turn' end, nxt.id, not nxt.hidden);
  if jsonb_array_length(echanges) > 0 then perform public._combat_changed(e.id, 'effects', 'clock', null, true); end if;
  r := public._combat_turn_result(e.id, array_remove(array[cur.id, nxt.id], null), public._combat_ids(echanges, 'id'), nt, ev);
  perform public._combat_set_result(ev, r - 'participants' - 'effects');
  return r;
end $$;

-- Previous Turn: undo the latest turn move. Effect clocks and Reaction / Legendary state go back too when nothing changed
-- them since; anything that did change is listed for a manual check. p_confirm: needed when effect clocks would change.
create or replace function public.combat_previous_turn(p_encounter uuid, p_expected_turn_rev bigint, p_confirm boolean default false, p_request uuid default null)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare e public.combat_encounters := public._combat_auth(p_encounter, 'update'); r jsonb; ev public.combat_events; c jsonb; x public.combat_effects;
  p public.combat_participants; ok jsonb := '[]'; manual jsonb := '[]'; nev bigint; rm jsonb; ids_p uuid[] := '{}'; ids_e uuid[] := '{}';
begin
  r := public._combat_replay(e.id, p_request); if r is not null then return r; end if;
  if e.status not in ('active', 'paused') then raise exception 'There is no running combat' using errcode = '22023'; end if;
  if p_expected_turn_rev is not null and p_expected_turn_rev <> e.turn_rev then
    raise exception 'The turn moved meanwhile (another window). Your view is updated.' using errcode = 'TLCMB';
  end if;
  select * into ev from public.combat_events where encounter_id = e.id and kind in ('turn_advanced', 'turn_jumped') and undone_by is null
    and (after ->> 'turn_rev')::bigint = e.turn_rev order by id desc limit 1;
  if ev.id is null then
    raise exception 'This is the first turn of the combat, or the last move was already undone. Use "Choose turn" to pick a combatant.' using errcode = '22023';
  end if;
  for c in select y from jsonb_array_elements(coalesce(ev.details -> 'effects', '[]')) y loop
    select * into x from public.combat_effects where id = (c ->> 'id')::uuid for update;
    if x.id is not null and x.active = (c -> 'after' ->> 'active')::boolean and x.remaining_rounds is not distinct from (c -> 'after' ->> 'remaining_rounds')::int then
      ok := ok || jsonb_build_object('id', x.id, 'name', x.display_name, 'restore', c -> 'before');
    else manual := manual || jsonb_build_object('id', c ->> 'id', 'name', x.display_name, 'reason', 'changed since the turn moved'); end if;
  end loop;
  if jsonb_array_length(coalesce(ev.details -> 'effects', '[]')) > 0 and not coalesce(p_confirm, false) then
    return jsonb_build_object('needs_confirmation', true, 'effects', ok, 'manual', manual);
  end if;
  for c in select y from jsonb_array_elements(ok) y loop
    update public.combat_effects set active = (c -> 'restore' ->> 'active')::boolean, remaining_rounds = (c -> 'restore' ->> 'remaining_rounds')::int,
      ended_at = case when (c -> 'restore' ->> 'active')::boolean then null else ended_at end,
      ended_reason = case when (c -> 'restore' ->> 'active')::boolean then null else ended_reason end, rev = rev + 1
    where id = (c ->> 'id')::uuid;
    ids_e := ids_e || (c ->> 'id')::uuid;
  end loop;
  for c in select y from jsonb_array_elements(coalesce(ev.details -> 'participants', '[]')) y loop
    select * into p from public.combat_participants where id = (c ->> 'id')::uuid for update;
    if p.id is not null and p.reaction_used is not distinct from (c -> 'after' ->> 'reaction_used')::boolean
       and p.legendary_left is not distinct from (c -> 'after' ->> 'legendary_left')::int and p.surprised is not distinct from (c -> 'after' ->> 'surprised')::boolean
       and p.turns_taken is not distinct from (c -> 'after' ->> 'turns_taken')::int then
      update public.combat_participants set reaction_used = (c -> 'before' ->> 'reaction_used')::boolean, legendary_left = (c -> 'before' ->> 'legendary_left')::int,
        surprised = (c -> 'before' ->> 'surprised')::boolean, turns_taken = (c -> 'before' ->> 'turns_taken')::int, rev = rev + 1 where id = p.id;
    elsif p.id is not null then
      manual := manual || jsonb_build_object('id', p.id, 'name', p.display_name || coalesce(' ' || p.instance_label, ''), 'reason', 'Reaction or Legendary uses changed since');
    end if;
    ids_p := ids_p || (c ->> 'id')::uuid;
  end loop;
  for rm in select y from jsonb_array_elements(coalesce(ev.details -> 'reminders', '[]')) y loop
    update public.combat_reminders set last_fired_round = (rm ->> 'before_last_fired')::int, rev = rev + 1 where id = (rm ->> 'reminder_id')::uuid;
  end loop;
  update public.combat_encounters set round = (ev.before ->> 'round')::int, current_participant_id = (ev.before ->> 'current')::uuid,
    turn_rev = turn_rev + 1, rev = rev + 1, updated_at = now() where id = e.id;
  nev := public._combat_event(e.id, 'turn_reverted', (ev.before ->> 'current')::uuid, ev.after, ev.before || jsonb_build_object('turn_rev', e.turn_rev + 1),
    jsonb_build_object('restored', ok, 'manual', manual, 'undo_of', ev.id), p_request, false);
  update public.combat_events set undone_by = nev where id = ev.id;
  update public.combat_events set undo_of = ev.id where id = nev;
  perform public._combat_changed(e.id, 'turn', 'reverted', (ev.before ->> 'current')::uuid, true);
  if array_length(ids_e, 1) > 0 then perform public._combat_changed(e.id, 'effects', 'clock', null, true); end if;
  r := public._combat_turn_result(e.id, ids_p || array_remove(array[(ev.before ->> 'current')::uuid, (ev.after ->> 'current')::uuid], null), ids_e,
    jsonb_build_array(jsonb_build_object('kind', 'reverted', 'manual', manual)), nev) || jsonb_build_object('manual', manual);
  perform public._combat_set_result(nev, r - 'participants' - 'effects');
  return r;
end $$;

-- Choose turn: the DM points at a combatant (and optionally a round). Nothing expires or refreshes; audited.
create or replace function public.combat_goto_turn(p_encounter uuid, p_participant uuid, p_expected_turn_rev bigint, p_round int default null,
  p_reason text default null, p_request uuid default null)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare e public.combat_encounters := public._combat_auth(p_encounter, 'update'); r jsonb; p public.combat_participants; ev bigint;
begin
  r := public._combat_replay(e.id, p_request); if r is not null then return r; end if;
  if e.status not in ('active', 'paused') then raise exception 'There is no running combat' using errcode = '22023'; end if;
  if p_expected_turn_rev is not null and p_expected_turn_rev <> e.turn_rev then
    raise exception 'The turn moved meanwhile (another window). Your view is updated.' using errcode = 'TLCMB';
  end if;
  select * into p from public.combat_participants where id = p_participant and encounter_id = e.id and removed_at is null;
  if not found then raise exception 'Combatant not found in this encounter' using errcode = '22023'; end if;
  if p_round is not null and (p_round < 1 or p_round > 1000) then raise exception 'Round is 1 or more' using errcode = '22023'; end if;
  update public.combat_encounters set current_participant_id = p.id, round = coalesce(p_round, round), turn_rev = turn_rev + 1, rev = rev + 1, updated_at = now() where id = e.id;
  ev := public._combat_event(e.id, 'turn_jumped', p.id, jsonb_build_object('round', e.round, 'current', e.current_participant_id, 'turn_rev', e.turn_rev),
    jsonb_build_object('round', coalesce(p_round, e.round), 'current', p.id, 'turn_rev', e.turn_rev + 1),
    jsonb_build_object('reason', p_reason, 'note', 'Effect clocks, Reactions and Legendary uses were not changed.'), p_request, true);
  perform public._combat_changed(e.id, 'turn', 'jumped', p.id, not p.hidden);
  r := public._combat_turn_result(e.id, array_remove(array[e.current_participant_id, p.id], null), '{}', '[]', ev);
  perform public._combat_set_result(ev, r - 'participants' - 'effects');
  return r;
end $$;

create or replace function public.combat_pause(p_encounter uuid, p_request uuid default null)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare e public.combat_encounters := public._combat_auth(p_encounter, 'update'); r jsonb;
begin
  r := public._combat_replay(e.id, p_request); if r is not null then return r; end if;
  if e.status <> 'active' then raise exception 'Only a running combat can be paused' using errcode = '22023'; end if;
  update public.combat_encounters set status = 'paused', paused_at = now(),
    active_seconds = active_seconds + coalesce(extract(epoch from now() - resumed_at)::int, 0), rev = rev + 1, updated_at = now() where id = e.id;
  perform public._combat_event(e.id, 'combat_paused', null, null, null, null, p_request, false);
  perform public._combat_changed(e.id, 'encounter', 'paused', null, true);
  return jsonb_build_object('encounter', public._combat_encounter_json((select x from public.combat_encounters x where x.id = e.id)));
end $$;

-- Resume restores exactly: no reroll, no HP rebuild, no clock catch-up for real time that passed
create or replace function public.combat_resume(p_encounter uuid, p_request uuid default null)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare e public.combat_encounters := public._combat_auth(p_encounter, 'update'); r jsonb;
begin
  r := public._combat_replay(e.id, p_request); if r is not null then return r; end if;
  if e.status <> 'paused' then raise exception 'Only a paused combat can be resumed' using errcode = '22023'; end if;
  update public.combat_encounters set status = 'active', resumed_at = now(), rev = rev + 1, updated_at = now() where id = e.id;
  perform public._combat_event(e.id, 'combat_resumed', null, null, null, jsonb_build_object('paused_seconds', extract(epoch from now() - e.paused_at)::int), p_request, false);
  perform public._combat_changed(e.id, 'encounter', 'resumed', null, true);
  return jsonb_build_object('encounter', public._combat_encounter_json((select x from public.combat_encounters x where x.id = e.id)));
end $$;

-- effects that may outlast the fight (on player characters, longer than about a minute, or not timed): reviewed at Finish
create or replace function public._combat_lasting_effects(p_encounter uuid)
returns jsonb language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', x.id, 'name', x.display_name, 'type', x.effect_type, 'visibility', x.visibility,
           'target', p.display_name, 'character_id', p.linked_character_id, 'duration_type', x.duration_type, 'remaining_rounds', x.remaining_rounds,
           'can_carry', p.linked_character_id is not null and x.effect_type in ('condition', 'custom')) order by p.display_name, x.created_at), '[]')
  from public.combat_effects x join public.combat_participants p on p.id = x.target_participant_id
  where x.encounter_id = p_encounter and x.active and p.kind = 'character'
    and (x.duration_type in ('indefinite', 'minutes', 'save_ends') or (x.duration_type = 'rounds' and coalesce(x.remaining_rounds, 0) > 10)
         or x.effect_type = 'concentration');
$$;

-- Finish: p_decisions {"<effect id>": "end" | "keep" | "carry"} for the lasting effects (carry = a condition on the character
-- sheet, hidden when the effect was DM-only). Without decisions the lasting effects are returned for review first;
-- p_confirm keeps the undecided ones. HP and resources stay as they are (rests are a separate workflow).
create or replace function public.combat_finish(p_encounter uuid, p_notes text default null, p_decisions jsonb default '{}', p_confirm boolean default false,
  p_request uuid default null)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare e public.combat_encounters := public._combat_auth(p_encounter, 'update'); r jsonb; lasting jsonb; l jsonb; d text; kept jsonb := '[]'; carried jsonb := '[]';
  summ jsonb; secs int; ev bigint;
begin
  r := public._combat_replay(e.id, p_request); if r is not null then return r; end if;
  if e.status not in ('active', 'paused') then raise exception 'Only a running or paused combat can be finished' using errcode = '22023'; end if;
  lasting := public._combat_lasting_effects(e.id);
  if jsonb_array_length(lasting) > 0 and not coalesce(p_confirm, false)
     and exists (select 1 from jsonb_array_elements(lasting) y where not coalesce(p_decisions, '{}') ? (y ->> 'id')) then
    return jsonb_build_object('needs_review', true, 'effects', lasting);
  end if;
  for l in select y from jsonb_array_elements(lasting) y loop
    d := coalesce(p_decisions ->> (l ->> 'id'), 'keep');
    if d = 'carry' and (l ->> 'can_carry')::boolean then
      perform public.apply_character_condition((l ->> 'character_id')::uuid, null, l ->> 'name', l ->> 'visibility' = 'dm', null,
        'From the encounter "' || e.name || '"');
      update public.combat_effects set active = false, ended_at = now(), ended_reason = 'carried_to_sheet', rev = rev + 1 where id = (l ->> 'id')::uuid;
      carried := carried || l;
    elsif d = 'end' then
      update public.combat_effects set active = false, ended_at = now(), ended_reason = 'encounter_finished', rev = rev + 1 where id = (l ->> 'id')::uuid;
    else kept := kept || l; end if;
  end loop;
  -- every other effect is a combat effect: it ends with the fight
  update public.combat_effects set active = false, ended_at = now(), ended_reason = 'encounter_finished', rev = rev + 1
  where encounter_id = e.id and active and not (id = any (public._combat_ids(kept, 'id')));
  secs := e.active_seconds + case when e.status = 'active' and e.resumed_at is not null then extract(epoch from now() - e.resumed_at)::int else 0 end;
  summ := jsonb_build_object('duration_seconds', secs, 'rounds', e.round, 'ruleset', e.ruleset,
    'participants', (select coalesce(jsonb_agg(jsonb_build_object('id', p.id, 'name', p.display_name || coalesce(' ' || p.instance_label, ''), 'kind', p.kind,
        'hp', case when p.kind = 'monster' then p.hp_current else (select c.hp_current from public.characters c where c.id = p.linked_character_id) end,
        'max', case when p.kind = 'monster' then p.hp_max else (select (public._feat_hp_bonus(c.id) ->> 'max')::int from public.characters c where c.id = p.linked_character_id) end,
        'defeated', p.defeated, 'removed', p.removed_at is not null, 'hidden', p.hidden,
        'down', p.kind = 'character' and coalesce((select c.hp_current from public.characters c where c.id = p.linked_character_id), 1) <= 0)
        order by p.initiative_order nulls last), '[]') from public.combat_participants p where p.encounter_id = e.id),
    'effects_applied', (select count(*) from public.combat_effects where encounter_id = e.id),
    'conditions', (select coalesce(jsonb_agg(distinct display_name), '[]') from public.combat_effects where encounter_id = e.id and effect_type = 'condition'),
    'kept_effects', kept, 'carried_effects', carried,
    'damage_total', (select coalesce(sum((details ->> 'amount')::int), 0) from public.combat_events where encounter_id = e.id and kind = 'damage' and undone_by is null),
    'healing_total', (select coalesce(sum((details ->> 'amount')::int), 0) from public.combat_events where encounter_id = e.id and kind = 'heal' and undone_by is null),
    'major_events', (select coalesce(jsonb_agg(jsonb_build_object('kind', z.kind, 'round', z.round, 'participant', (select display_name || coalesce(' ' || instance_label, '')
                       from public.combat_participants where id = z.participant_id), 'amount', z.details -> 'amount') order by z.id), '[]')
                     from (select * from public.combat_events where encounter_id = e.id and undone_by is null
                           and kind in ('participant_defeat', 'concentration_failed', 'participant_revealed', 'participants_added', 'damage')
                           and (kind <> 'damage' or coalesce((details ->> 'amount')::int, 0) >= 10)
                           and (kind <> 'participants_added' or coalesce(round, 0) > 0)   -- joins during the fight, not the preparation
                           order by id desc limit 20) z));
  update public.combat_encounters set status = 'completed', completed_at = now(), active_seconds = secs, summary = summ,
    finish_notes = coalesce(left(p_notes, 8000), finish_notes), turn_rev = turn_rev + 1, rev = rev + 1, updated_at = now() where id = e.id;
  ev := public._combat_event(e.id, 'combat_finished', null, null, null, jsonb_build_object('kept', kept, 'carried', carried), p_request, false);
  perform public._combat_changed(e.id, 'encounter', 'finished', null, true);
  r := jsonb_build_object('encounter', public._combat_encounter_json((select x from public.combat_encounters x where x.id = e.id)), 'summary', summ);
  perform public._combat_set_result(ev, r);
  return r;
end $$;

create or replace function public.combat_get_summary(p_encounter uuid)
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
declare e public.combat_encounters := public._combat_auth(p_encounter, 'none');
begin
  return jsonb_build_object('encounter', public._combat_encounter_json(e), 'summary', e.summary,
    'history', public.combat_get_history(e.id, null, 100));
end $$;

-- ================================================================================================= 7. hit points
-- The one atomic HP change of a character: the sheet's Damage / Heal / Temp buttons and the Combat Builder use it, so a
-- change made in one place can never be overwritten by a stale value from the other. Owner or campaign DM; the campaign
-- rules for runtime.hp apply (the governance trigger skips SECURITY DEFINER writes, so the gate is called here).
-- In Wild Shape the form takes damage and healing through the existing Wild Shape functions (normal HP stays protected).
-- p_op: damage | heal | temp (set Temporary HP to the amount) | set (correction: needs a reason)
create or replace function public.apply_character_hp(p_character uuid, p_op text, p_amount int, p_reason text default null)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare c public.characters; t public.character_transformations; mx int; nhp int; ntemp int; absorbed int := 0; ds int; df int; r jsonb;
begin
  if auth.uid() is null or p_character is null or not public.can_access_character(p_character) then
    raise exception 'Character not found' using errcode = '42501';
  end if;
  if p_op not in ('damage', 'heal', 'temp', 'set') then raise exception 'Unknown hit point change "%"', p_op using errcode = '22023'; end if;
  if p_amount is null or p_amount < 0 or p_amount > 10000 then raise exception 'Give an amount from 0 to 10000' using errcode = '22023'; end if;
  if p_op in ('damage', 'heal') and p_amount < 1 then raise exception 'Enter an amount first (1 or more)' using errcode = '22023'; end if;
  if p_op = 'set' and coalesce(btrim(p_reason), '') = '' then raise exception 'A manual correction needs a reason' using errcode = '22023'; end if;
  perform public._gov_gate(p_character, 'runtime.hp');
  select * into c from public.characters where id = p_character for update;
  select * into t from public.character_transformations where character_id = p_character;
  if t.character_id is not null then
    r := case p_op
      when 'damage' then public.damage_active_transformation(p_character, p_amount, p_reason)
      when 'heal' then public.heal_active_transformation(p_character, p_amount, p_reason)
      when 'temp' then public.set_transformation_hp(p_character, t.hp_current, p_amount, coalesce(p_reason, 'Temporary HP'))
      else public.set_transformation_hp(p_character, p_amount, null, p_reason) end;
    if not coalesce((r -> 'result' ->> 'expired')::boolean, false) then
      return jsonb_build_object('character_id', p_character, 'form', true, 'op', p_op, 'amount', p_amount, 'wild_shape', r,
        'hp_max', (public._feat_hp_bonus(p_character) ->> 'max')::int);
    end if;
    select * into c from public.characters where id = p_character;   -- the form had run out: the change goes to the character
  end if;
  mx := (public._feat_hp_bonus(p_character) ->> 'max')::int;
  ntemp := c.hp_temp; nhp := c.hp_current; ds := c.death_successes; df := c.death_failures;
  case p_op
  when 'damage' then absorbed := least(c.hp_temp, p_amount); ntemp := c.hp_temp - absorbed; nhp := greatest(0, c.hp_current - (p_amount - absorbed));
  when 'heal' then nhp := case when c.hp_current >= mx then c.hp_current else least(mx, c.hp_current + p_amount) end;
  when 'temp' then ntemp := least(p_amount, 5000);
  else nhp := least(greatest(p_amount, 0), mx);
  end case;
  if c.hp_current <= 0 and nhp > 0 then ds := 0; df := 0; end if;
  update public.characters set hp_current = nhp, hp_temp = ntemp, death_successes = ds, death_failures = df where id = p_character;
  return jsonb_build_object('character_id', p_character, 'form', false, 'op', p_op, 'amount', p_amount, 'absorbed', absorbed, 'hp_max', mx,
    'before', jsonb_build_object('hp', c.hp_current, 'temp', c.hp_temp, 'death_successes', c.death_successes, 'death_failures', c.death_failures),
    'after', jsonb_build_object('hp', nhp, 'temp', ntemp, 'death_successes', ds, 'death_failures', df),
    'down', nhp = 0, 'went_down', nhp = 0 and c.hp_current > 0);
end $$;

-- state of a linked character for HP history / Undo (normal HP and the form, if any)
create or replace function public._combat_char_state(p_character uuid)
returns jsonb language sql stable security definer set search_path = public, pg_temp as $$
  select jsonb_build_object('hp', c.hp_current, 'temp', c.hp_temp, 'death_successes', c.death_successes, 'death_failures', c.death_failures,
    'form', t.character_id is not null, 'form_hp', t.hp_current, 'form_temp', t.hp_temp, 'creature_id', t.creature_id)
  from public.characters c left join public.character_transformations t on t.character_id = c.id where c.id = p_character;
$$;

create or replace function public._combat_hp_state(p_cur int, p_max int)
returns text language sql immutable set search_path = public, pg_temp as $$
  select case when p_cur <= 0 then 'down' when p_cur * 100 <= greatest(p_max, 1) * 25 then 'critical'
              when p_cur * 100 <= greatest(p_max, 1) * 50 then 'bloodied' else 'healthy' end;
$$;

-- one HP change of one participant (callers hold the encounter FOR SHARE and the participant FOR UPDATE)
create or replace function public._combat_hp_one(p public.combat_participants, e public.combat_encounters, p_op text, p_amount int, p_reason text, p_request uuid)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare before jsonb; after jsonb; res jsonb; absorbed int := 0; nhp int; ntemp int; ndef boolean; x public.combat_effects; chk jsonb; checks jsonb := '[]';
  ev bigint; kind text; r jsonb; dc int;
begin
  if p.removed_at is not null then raise exception 'This combatant was removed from the encounter' using errcode = '22023'; end if;
  if p_op not in ('damage', 'heal', 'temp', 'set') then raise exception 'Unknown hit point change "%"', p_op using errcode = '22023'; end if;
  if p_amount is null or p_amount < 0 or p_amount > 10000 then raise exception 'Give an amount from 0 to 10000' using errcode = '22023'; end if;
  if p_op in ('damage', 'heal') and p_amount < 1 then raise exception 'Enter an amount first (1 or more)' using errcode = '22023'; end if;
  if p_op = 'set' and coalesce(btrim(p_reason), '') = '' then raise exception 'A manual correction needs a reason' using errcode = '22023'; end if;
  if p.kind = 'character' then
    if p.linked_character_id is null then raise exception 'This character no longer exists' using errcode = '22023'; end if;
    perform 1 from public.characters where id = p.linked_character_id for update;
    before := public._combat_char_state(p.linked_character_id);
    res := public.apply_character_hp(p.linked_character_id, p_op, p_amount, p_reason);
    after := public._combat_char_state(p.linked_character_id);
    absorbed := coalesce((res ->> 'absorbed')::int, (res -> 'wild_shape' -> 'result' ->> 'temp_absorbed')::int, 0);
  else
    nhp := p.hp_current; ntemp := p.hp_temp; ndef := p.defeated;
    case p_op
    when 'damage' then absorbed := least(p.hp_temp, p_amount); ntemp := p.hp_temp - absorbed; nhp := greatest(0, p.hp_current - (p_amount - absorbed));
      ndef := ndef or nhp = 0;
    when 'heal' then nhp := case when p.hp_current >= p.hp_max then p.hp_current else least(p.hp_max, p.hp_current + p_amount) end; ndef := ndef and nhp = 0;
    when 'temp' then ntemp := least(p_amount, 5000);
    else nhp := least(greatest(p_amount, 0), p.hp_max); ndef := nhp = 0;
    end case;
    before := jsonb_build_object('hp', p.hp_current, 'temp', p.hp_temp, 'defeated', p.defeated);
    after := jsonb_build_object('hp', nhp, 'temp', ntemp, 'defeated', ndef);
    update public.combat_participants set hp_current = nhp, hp_temp = ntemp, defeated = ndef,
      defeated_at = case when ndef and not p.defeated then now() when not ndef then null else defeated_at end, rev = rev + 1 where id = p.id;
  end if;
  kind := case p_op when 'damage' then 'damage' when 'heal' then 'heal' when 'temp' then 'temp_hp' else 'hp_set' end;
  ev := public._combat_event(e.id, kind, p.id, before, after, jsonb_build_object('amount', p_amount, 'reason', p_reason, 'absorbed', absorbed,
    'form', coalesce((before ->> 'form')::boolean, false), 'form_ended', coalesce((before ->> 'form')::boolean, false) and not coalesce((after ->> 'form')::boolean, false),
    'carryover', res -> 'wild_shape' -> 'result' -> 'carryover'), p_request, true);
  -- taking damage while concentrating: a Constitution save reminder with the ruleset's DC (the DM marks the result)
  if p_op = 'damage' and p_amount > 0 then
    for x in select * from public.combat_effects where encounter_id = e.id and active and effect_type = 'concentration' and source_participant_id = p.id for update loop
      dc := case when e.ruleset = '2024' then least(30, greatest(10, p_amount / 2)) else greatest(10, p_amount / 2) end;
      chk := jsonb_build_object('id', gen_random_uuid(), 'dc', dc, 'damage', p_amount, 'event_id', ev, 'at', now());
      update public.combat_effects set pending_checks = pending_checks || jsonb_build_array(chk), rev = rev + 1 where id = x.id;
      checks := checks || (chk || jsonb_build_object('effect_id', x.id, 'effect', x.display_name));
    end loop;
  end if;
  perform public._combat_changed(e.id, 'hp', kind, p.id, not p.hidden);
  if jsonb_array_length(checks) > 0 then perform public._combat_changed(e.id, 'effects', 'concentration_check', p.id, not p.hidden); end if;
  r := jsonb_build_object('participant', public._combat_pjson((select y from public.combat_participants y where y.id = p.id)), 'op', p_op, 'amount', p_amount,
    'absorbed', absorbed, 'before', before, 'after', after, 'concentration_checks', checks, 'event_id', ev, 'wild_shape', res -> 'wild_shape' -> 'result',
    'effects', (select coalesce(jsonb_agg(public._combat_ejson(z)), '[]') from public.combat_effects z where z.id = any (public._combat_ids(checks, 'effect_id'))));
  perform public._combat_set_result(ev, r - 'participant' - 'effects');
  return r;
end $$;

create or replace function public.combat_apply_hp(p_participant uuid, p_op text, p_amount int, p_reason text default null, p_request uuid default null)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare p public.combat_participants := public._combat_participant_auth(p_participant, 'share'); e public.combat_encounters; r jsonb;
begin
  select * into e from public.combat_encounters where id = p.encounter_id;
  r := public._combat_replay(e.id, p_request);
  if r is not null then return r || jsonb_build_object('participant', public._combat_pjson(p)); end if;
  if e.status = 'completed' then raise exception 'This encounter is finished. Change hit points on the character sheet.' using errcode = '22023'; end if;
  return public._combat_hp_one(p, e, p_op, p_amount, p_reason, p_request);
end $$;

-- several monsters at once (an area spell): reviewed by the DM before sending; player characters only with p_include_characters
create or replace function public.combat_apply_hp_bulk(p_encounter uuid, p_op text, p_items jsonb, p_include_characters boolean default false,
  p_reason text default null, p_request uuid default null)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare e public.combat_encounters := public._combat_auth(p_encounter, 'share'); r jsonb; it jsonb; p public.combat_participants; out jsonb := '[]';
begin
  r := public._combat_replay(e.id, p_request); if r is not null then return r; end if;
  if e.status = 'completed' then raise exception 'This encounter is finished' using errcode = '22023'; end if;
  if p_op not in ('damage', 'heal') then raise exception 'Bulk changes are damage or healing' using errcode = '22023'; end if;
  if jsonb_array_length(coalesce(p_items, '[]')) = 0 or jsonb_array_length(p_items) > 40 then raise exception 'Choose 1 to 40 combatants' using errcode = '22023'; end if;
  for it in select y from jsonb_array_elements(p_items) y order by y ->> 'id' loop    -- id order: a fixed lock order
    select * into p from public.combat_participants where id = (it ->> 'id')::uuid and encounter_id = e.id for update;
    if not found then raise exception 'Combatant not found in this encounter' using errcode = '22023'; end if;
    if p.kind = 'character' and not coalesce(p_include_characters, false) then
      raise exception 'Bulk damage to player characters needs your explicit confirmation' using errcode = '22023';
    end if;
    out := out || jsonb_build_array(public._combat_hp_one(p, e, p_op, (it ->> 'amount')::int, p_reason, null));
  end loop;
  r := jsonb_build_object('results', out);
  perform public._combat_event(e.id, 'bulk_' || p_op, null, null, null, jsonb_build_object('count', jsonb_array_length(out)), p_request, false,
    jsonb_build_object('results', (select jsonb_agg(z - 'participant' - 'effects') from jsonb_array_elements(out) z)));
  return r;
end $$;

-- ================================================================================================= 8. effects
-- p_effect: {targets: [ids] | target, source, effect_type (condition | custom | advantage | concentration), condition_key, exhaustion_level,
--   name, description, notes, visibility (players | dm), duration_type (indefinite | rounds | minutes | until_turn_start | until_turn_end | save_ends),
--   duration_rounds, duration_minutes, expires_on (turn_start | turn_end), anchor (source | target), this_turn, save_ability, save_dc, save_timing,
--   concentration (link to the source's concentration), concentration_name, replace_concentration,
--   adv_mode, adv_scope, adv_detail, adv_target, modifier_target, modifier_value, defense_kind, defense_type}
create or replace function public.combat_add_effect(p_encounter uuid, p_effect jsonb, p_request uuid default null)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare e public.combat_encounters := public._combat_auth(p_encounter, 'share'); r jsonb; et text; src uuid; tg uuid; targets uuid[]; k public.combat_conditions;
  nm text; dt text; dr int; dm int; eo text; app text; conc uuid; cx public.combat_effects; cname text; ids uuid[] := '{}'; ended uuid[] := '{}';
  anchor uuid; rem int; nid uuid; nt jsonb := '[]'; tp public.combat_participants; srcp public.combat_participants; vis text; ev bigint;
begin
  r := public._combat_replay(e.id, p_request); if r is not null then return r; end if;
  if e.status = 'completed' then raise exception 'This encounter is finished' using errcode = '22023'; end if;
  et := coalesce(p_effect ->> 'effect_type', 'custom');
  if et not in ('condition', 'custom', 'advantage', 'concentration') then raise exception 'Unknown effect type "%"', et using errcode = '22023'; end if;
  src := nullif(p_effect ->> 'source', '')::uuid;
  if src is not null then
    select * into srcp from public.combat_participants where id = src and encounter_id = e.id and removed_at is null;
    if not found then raise exception 'The source is not a combatant of this encounter' using errcode = '22023'; end if;
  end if;
  targets := coalesce((select array_agg(y::uuid) from jsonb_array_elements_text(case when jsonb_typeof(p_effect -> 'targets') = 'array' then p_effect -> 'targets' else '[]' end) y), '{}');
  if p_effect ? 'target' and p_effect ->> 'target' is not null then targets := targets || (p_effect ->> 'target')::uuid; end if;
  if et = 'concentration' then
    if src is null then raise exception 'Choose who is concentrating' using errcode = '22023'; end if;
    targets := array[src];
  end if;
  if coalesce(array_length(targets, 1), 0) = 0 then raise exception 'Choose a target' using errcode = '22023'; end if;
  if et = 'condition' then
    select * into k from public.combat_conditions where ruleset = e.ruleset and key = p_effect ->> 'condition_key';
    if not found then raise exception 'Unknown condition "%" for the % rules', p_effect ->> 'condition_key', e.ruleset using errcode = '22023'; end if;
  end if;
  if et = 'advantage' and (coalesce(p_effect ->> 'adv_mode', '') not in ('advantage', 'disadvantage') or coalesce(p_effect ->> 'adv_scope', '') = '') then
    raise exception 'Choose Advantage or Disadvantage and what it applies to' using errcode = '22023';
  end if;
  nm := left(coalesce(nullif(btrim(p_effect ->> 'name'), ''), k.name,
    case when et = 'advantage' then initcap(p_effect ->> 'adv_mode') || ': ' || replace(p_effect ->> 'adv_scope', '_', ' ') end,
    case when et = 'concentration' then nullif(btrim(p_effect ->> 'concentration_name'), '') end), 120);
  if coalesce(nm, '') = '' then raise exception 'Give the effect a name' using errcode = '22023'; end if;
  dt := coalesce(p_effect ->> 'duration_type', 'indefinite');
  if dt not in ('indefinite', 'rounds', 'minutes', 'until_turn_start', 'until_turn_end', 'save_ends') then raise exception 'Unknown duration "%"', dt using errcode = '22023'; end if;
  dr := (p_effect ->> 'duration_rounds')::int; dm := (p_effect ->> 'duration_minutes')::int; eo := p_effect ->> 'expires_on';
  if dt = 'minutes' then
    if dm is null or dm < 1 then raise exception 'Give the duration in minutes' using errcode = '22023'; end if;
    dt := 'rounds'; dr := dm * 10;                       -- 1 minute = 10 rounds of 6 seconds
  end if;
  if dt = 'rounds' then
    if dr is null or dr < 1 or dr > 1000 then raise exception 'Give the number of rounds (1 to 1000)' using errcode = '22023'; end if;
    eo := coalesce(eo, 'turn_start');
  end if;
  if dt = 'save_ends' and (p_effect ->> 'save_ability' is null or p_effect ->> 'save_dc' is null) then
    raise exception '"Save ends" needs the saving throw ability and DC' using errcode = '22023';
  end if;
  app := case when p_effect ->> 'modifier_target' in ('ac', 'speed') and (p_effect ->> 'modifier_value') is not null and coalesce(p_effect ->> 'application', 'applied') = 'applied'
              then 'applied' else 'reminder' end;
  vis := case when p_effect ->> 'visibility' = 'dm' then 'dm' else 'players' end;
  -- concentration: one per caster; starting another one ends the old one (after the DM confirms: replace_concentration)
  if et = 'concentration' or coalesce((p_effect ->> 'concentration')::boolean, false) then
    if src is null then raise exception 'Concentration needs a source (the caster)' using errcode = '22023'; end if;
    cname := left(coalesce(nullif(btrim(p_effect ->> 'concentration_name'), ''), nm), 120);
    select * into cx from public.combat_effects where encounter_id = e.id and source_participant_id = src and effect_type = 'concentration' and active for update;
    if cx.id is not null and (et = 'concentration' or cx.display_name <> cname) then
      if not coalesce((p_effect ->> 'replace_concentration')::boolean, false) then
        raise exception '% is already concentrating on %. Replace it?', srcp.display_name, cx.display_name using errcode = 'TLCNC';
      end if;
      update public.combat_effects set active = false, ended_at = now(), ended_reason = 'concentration_ended', rev = rev + 1
      where active and (id = cx.id or concentration_id = cx.id);
      ended := ended || array(select id from public.combat_effects where id = cx.id or concentration_id = cx.id);
      cx := null;
    end if;
    if cx.id is null then
      insert into public.combat_effects (encounter_id, target_participant_id, source_participant_id, effect_type, display_name, description, visibility,
        applied_round, applied_participant_id, duration_type, duration_rounds, remaining_rounds, duration_minutes, anchor_participant_id, expires_on, notes)
      values (e.id, src, src, 'concentration', cname, coalesce(p_effect ->> 'description', ''), vis, e.round, e.current_participant_id,
        case when et = 'concentration' then dt else 'indefinite' end, case when et = 'concentration' then dr end, case when et = 'concentration' then dr end,
        dm, src, case when et = 'concentration' then eo end, left(coalesce(p_effect ->> 'notes', ''), 2000))
      returning id into conc;
      ids := ids || conc;
    else conc := cx.id; end if;
  end if;
  if et <> 'concentration' then
    foreach tg in array targets loop
      select * into tp from public.combat_participants where id = tg and encounter_id = e.id and removed_at is null;
      if not found then raise exception 'The target is not a combatant of this encounter' using errcode = '22023'; end if;
      anchor := case when p_effect ->> 'anchor' = 'target' then tg else coalesce(src, tg) end;
      rem := case when dt = 'rounds' then dr
                  when dt = 'until_turn_end' then case when anchor = e.current_participant_id and e.status = 'active' and not coalesce((p_effect ->> 'this_turn')::boolean, false) then 1 else 0 end
                  when dt = 'until_turn_start' then 0 end;
      insert into public.combat_effects (encounter_id, target_participant_id, source_participant_id, effect_type, condition_key, exhaustion_level, display_name,
        description, visibility, application, applied_round, applied_participant_id, duration_type, duration_rounds, remaining_rounds, duration_minutes,
        anchor_participant_id, expires_on, save_ability, save_dc, save_timing, concentration_id, adv_mode, adv_scope, adv_detail, adv_target_id,
        modifier_target, modifier_value, defense_kind, defense_type, notes)
      values (e.id, tg, src, et, case when et = 'condition' then k.key end,
        case when k.leveled then greatest(1, least(6, coalesce((p_effect ->> 'exhaustion_level')::int, 1))) end, nm,
        left(coalesce(p_effect ->> 'description', ''), 2000), vis, app, e.round, e.current_participant_id,
        case when dt in ('rounds', 'until_turn_start', 'until_turn_end', 'save_ends') then dt else 'indefinite' end, dr, rem, dm,
        case when dt in ('rounds', 'until_turn_start', 'until_turn_end') then anchor end, eo,
        p_effect ->> 'save_ability', (p_effect ->> 'save_dc')::int, case when p_effect ->> 'save_ability' is not null then coalesce(p_effect ->> 'save_timing', 'turn_end') end,
        conc, p_effect ->> 'adv_mode', p_effect ->> 'adv_scope', nullif(left(p_effect ->> 'adv_detail', 60), ''), nullif(p_effect ->> 'adv_target', '')::uuid,
        p_effect ->> 'modifier_target', (p_effect ->> 'modifier_value')::int, p_effect ->> 'defense_kind', nullif(left(p_effect ->> 'defense_type', 40), ''),
        left(coalesce(p_effect ->> 'notes', ''), 2000))
      returning id into nid;
      ids := ids || nid;
      -- an Incapacitated-type condition on a concentrating combatant: the DM is asked to end that concentration
      if et = 'condition' and k.incapacitating then
        nt := nt || coalesce((select jsonb_agg(jsonb_build_object('kind', 'concentration_at_risk', 'effect_id', z.id, 'effect', z.display_name,
                     'target', tp.display_name || coalesce(' ' || tp.instance_label, ''), 'condition', k.name))
                   from public.combat_effects z where z.encounter_id = e.id and z.active and z.effect_type = 'concentration' and z.source_participant_id = tg), '[]');
      end if;
      if et = 'condition' and exists (select 1 from public.combat_statblocks s where s.id = tp.statblock_id
                                      and coalesce(s.snapshot -> 'condition_immunities', '[]') ? k.key) then
        nt := nt || jsonb_build_object('kind', 'immune', 'effect_id', nid, 'effect', k.name, 'target', tp.display_name || coalesce(' ' || tp.instance_label, ''));
      end if;
    end loop;
  end if;
  ev := public._combat_event(e.id, 'effect_added', case when array_length(targets, 1) = 1 then targets[1] end, null, null,
    jsonb_build_object('ids', to_jsonb(ids), 'ended', to_jsonb(ended), 'name', nm, 'effect_type', et), p_request, true);
  perform public._combat_changed(e.id, 'effects', 'added', case when array_length(targets, 1) = 1 then targets[1] end, vis = 'players');
  r := jsonb_build_object('effects', (select coalesce(jsonb_agg(public._combat_ejson(z)), '[]') from public.combat_effects z where z.id = any (ids || ended)),
    'notices', nt, 'event_id', ev);
  perform public._combat_set_result(ev, r);
  return r;
end $$;

create or replace function public.combat_update_effect(p_effect uuid, p_patch jsonb, p_expected_rev bigint default null)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare x public.combat_effects; k text;
begin
  select * into x from public.combat_effects where id = p_effect;
  if not found then raise exception 'Effect not found' using errcode = '42501'; end if;
  perform public._combat_auth(x.encounter_id, 'share');
  select * into x from public.combat_effects where id = p_effect for update;
  if p_expected_rev is not null and p_expected_rev <> x.rev then
    raise exception 'This effect was changed in another window. Your view is updated.' using errcode = 'TLCMB';
  end if;
  for k in select jsonb_object_keys(coalesce(p_patch, '{}')) loop
    if k not in ('display_name', 'description', 'notes', 'visibility', 'remaining_rounds', 'save_dc', 'save_ability', 'exhaustion_level', 'adv_mode', 'modifier_value') then
      raise exception 'Unknown effect field "%"', k using errcode = '22023';
    end if;
  end loop;
  update public.combat_effects set
    display_name = coalesce(nullif(left(btrim(p_patch ->> 'display_name'), 120), ''), display_name),
    description = coalesce(left(p_patch ->> 'description', 2000), description), notes = coalesce(left(p_patch ->> 'notes', 2000), notes),
    visibility = case when p_patch ->> 'visibility' in ('players', 'dm') then p_patch ->> 'visibility' else visibility end,
    remaining_rounds = coalesce((p_patch ->> 'remaining_rounds')::int, remaining_rounds), save_dc = coalesce((p_patch ->> 'save_dc')::int, save_dc),
    save_ability = coalesce(p_patch ->> 'save_ability', save_ability),
    exhaustion_level = case when exhaustion_level is not null then coalesce((p_patch ->> 'exhaustion_level')::int, exhaustion_level) end,
    adv_mode = case when effect_type = 'advantage' then coalesce(p_patch ->> 'adv_mode', adv_mode) else adv_mode end,
    modifier_value = coalesce((p_patch ->> 'modifier_value')::int, modifier_value), rev = rev + 1
  where id = x.id;
  perform public._combat_event(x.encounter_id, 'effect_updated', x.target_participant_id, to_jsonb(x) - 'created_by', p_patch, null, null, false);
  perform public._combat_changed(x.encounter_id, 'effects', 'updated', x.target_participant_id, coalesce(p_patch ->> 'visibility', x.visibility) = 'players');
  return public._combat_ejson((select z from public.combat_effects z where z.id = x.id));
end $$;

-- end one effect; a concentration ends everything linked to it
create or replace function public.combat_end_effect(p_effect uuid, p_reason text default 'removed', p_request uuid default null)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare x public.combat_effects; r jsonb; ids uuid[]; rs text; ev bigint;
begin
  select * into x from public.combat_effects where id = p_effect;
  if not found then raise exception 'Effect not found' using errcode = '42501'; end if;
  perform public._combat_auth(x.encounter_id, 'share');
  r := public._combat_replay(x.encounter_id, p_request); if r is not null then return r; end if;
  select * into x from public.combat_effects where id = p_effect for update;
  if not x.active then return jsonb_build_object('already_ended', true, 'effects', jsonb_build_array(public._combat_ejson(x))); end if;
  rs := case when p_reason in ('removed', 'expired', 'concentration_ended', 'save_succeeded') then p_reason else 'removed' end;
  ids := array[x.id] || case when x.effect_type = 'concentration' then array(select id from public.combat_effects where concentration_id = x.id and active) else '{}' end;
  update public.combat_effects set active = false, ended_at = now(),
    ended_reason = case when id = x.id then rs else 'concentration_ended' end, rev = rev + 1 where id = any (ids);
  ev := public._combat_event(x.encounter_id, case when x.effect_type = 'concentration' then 'concentration_ended' else 'effect_ended' end, x.target_participant_id,
    null, null, jsonb_build_object('ids', to_jsonb(ids), 'reason', rs, 'name', x.display_name), p_request, true);
  perform public._combat_changed(x.encounter_id, 'effects', 'ended', x.target_participant_id, x.visibility = 'players');
  r := jsonb_build_object('effects', (select coalesce(jsonb_agg(public._combat_ejson(z)), '[]') from public.combat_effects z where z.id = any (ids)), 'event_id', ev);
  perform public._combat_set_result(ev, r);
  return r;
end $$;

-- the DM's verdict on a concentration save (p_check: the pending check id, null = the oldest)
create or replace function public.combat_resolve_concentration(p_effect uuid, p_check uuid, p_result text, p_request uuid default null)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare x public.combat_effects; r jsonb; chk jsonb; ids uuid[] := '{}'; ev bigint;
begin
  select * into x from public.combat_effects where id = p_effect;
  if not found or x.effect_type <> 'concentration' then raise exception 'Concentration not found' using errcode = '42501'; end if;
  perform public._combat_auth(x.encounter_id, 'share');
  r := public._combat_replay(x.encounter_id, p_request); if r is not null then return r; end if;
  if p_result not in ('success', 'failure') then raise exception 'The result is success or failure' using errcode = '22023'; end if;
  select * into x from public.combat_effects where id = p_effect for update;
  select y into chk from jsonb_array_elements(x.pending_checks) y where p_check is null or (y ->> 'id')::uuid = p_check limit 1;
  update public.combat_effects set pending_checks = coalesce((select jsonb_agg(y) from jsonb_array_elements(x.pending_checks) y
    where chk is null or y ->> 'id' <> chk ->> 'id'), '[]'), rev = rev + 1 where id = x.id;
  if p_result = 'failure' and x.active then
    ids := array[x.id] || array(select id from public.combat_effects where concentration_id = x.id and active);
    update public.combat_effects set active = false, ended_at = now(), ended_reason = 'concentration_ended', rev = rev + 1 where id = any (ids);
  end if;
  ev := public._combat_event(x.encounter_id, case when p_result = 'failure' then 'concentration_failed' else 'concentration_kept' end, x.source_participant_id,
    null, null, jsonb_build_object('check', chk, 'ids', to_jsonb(ids), 'name', x.display_name), p_request, p_result = 'failure');
  perform public._combat_changed(x.encounter_id, 'effects', 'concentration_' || p_result, x.source_participant_id, x.visibility = 'players');
  r := jsonb_build_object('result', p_result, 'check', chk,
    'effects', (select coalesce(jsonb_agg(public._combat_ejson(z)), '[]') from public.combat_effects z where z.id = any (ids || x.id)), 'event_id', ev);
  perform public._combat_set_result(ev, r);
  return r;
end $$;

create or replace function public.combat_set_reaction(p_participant uuid, p_used boolean, p_request uuid default null)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare p public.combat_participants := public._combat_participant_auth(p_participant, 'share'); r jsonb;
begin
  r := public._combat_replay(p.encounter_id, p_request); if r is not null then return r; end if;
  update public.combat_participants set reaction_used = coalesce(p_used, true), rev = rev + 1 where id = p.id;
  perform public._combat_event(p.encounter_id, 'reaction', p.id, jsonb_build_object('used', p.reaction_used), jsonb_build_object('used', coalesce(p_used, true)), null, p_request, true);
  perform public._combat_changed(p.encounter_id, 'participants', 'reaction', p.id, not p.hidden);
  return jsonb_build_object('participant', public._combat_pjson((select y from public.combat_participants y where y.id = p.id)));
end $$;

-- p_delta: -cost to spend Legendary Action uses, +n to give back; p_action: the option taken (history)
create or replace function public.combat_spend_legendary(p_participant uuid, p_delta int, p_action text default null, p_request uuid default null)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare p public.combat_participants := public._combat_participant_auth(p_participant, 'share'); r jsonb; nl int;
begin
  r := public._combat_replay(p.encounter_id, p_request); if r is not null then return r; end if;
  if p.legendary_max is null then raise exception '% has no Legendary Actions', p.display_name using errcode = '22023'; end if;
  if coalesce(p_delta, 0) = 0 then raise exception 'Spend or give back at least 1 use' using errcode = '22023'; end if;
  if p_delta < 0 and coalesce(p.legendary_left, 0) + p_delta < 0 then
    raise exception '% has only % Legendary Action uses left', p.display_name, coalesce(p.legendary_left, 0) using errcode = '22023';
  end if;
  nl := greatest(0, least(p.legendary_max, coalesce(p.legendary_left, 0) + p_delta));
  update public.combat_participants set legendary_left = nl, rev = rev + 1 where id = p.id;
  perform public._combat_event(p.encounter_id, 'legendary', p.id, jsonb_build_object('left', p.legendary_left), jsonb_build_object('left', nl),
    jsonb_build_object('delta', p_delta, 'action', p_action), p_request, true);
  perform public._combat_changed(p.encounter_id, 'participants', 'legendary', p.id, not p.hidden);
  return jsonb_build_object('participant', public._combat_pjson((select y from public.combat_participants y where y.id = p.id)));
end $$;

-- ================================================================================================= 9. reminders
-- p_reminder: {id (update), kind, title, note, trigger_round, trigger_initiative, repeat_every, hidden, active}
create or replace function public.combat_save_reminder(p_encounter uuid, p_reminder jsonb)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare e public.combat_encounters := public._combat_auth(p_encounter, 'share'); rid uuid := nullif(p_reminder ->> 'id', '')::uuid; rm public.combat_reminders;
begin
  if coalesce(btrim(p_reminder ->> 'title'), '') = '' then raise exception 'Give the reminder a title' using errcode = '22023'; end if;
  if (p_reminder ->> 'trigger_round') is null and (p_reminder ->> 'trigger_initiative') is null then
    raise exception 'Choose a round, an Initiative count, or both' using errcode = '22023';
  end if;
  if coalesce(p_reminder ->> 'kind', 'custom') not in ('lair', 'hazard', 'reinforcement', 'environment', 'custom') then
    raise exception 'Unknown reminder kind' using errcode = '22023';
  end if;
  if rid is null then
    insert into public.combat_reminders (encounter_id, kind, title, note, trigger_round, trigger_initiative, repeat_every, hidden, active)
    values (e.id, coalesce(p_reminder ->> 'kind', 'custom'), left(btrim(p_reminder ->> 'title'), 120), left(coalesce(p_reminder ->> 'note', ''), 2000),
      (p_reminder ->> 'trigger_round')::int, (p_reminder ->> 'trigger_initiative')::int, (p_reminder ->> 'repeat_every')::int,
      coalesce((p_reminder ->> 'hidden')::boolean, true), coalesce((p_reminder ->> 'active')::boolean, true))
    returning * into rm;
  else
    update public.combat_reminders set kind = coalesce(p_reminder ->> 'kind', kind), title = left(btrim(p_reminder ->> 'title'), 120),
      note = coalesce(left(p_reminder ->> 'note', 2000), note), trigger_round = (p_reminder ->> 'trigger_round')::int,
      trigger_initiative = (p_reminder ->> 'trigger_initiative')::int, repeat_every = (p_reminder ->> 'repeat_every')::int,
      hidden = coalesce((p_reminder ->> 'hidden')::boolean, hidden), active = coalesce((p_reminder ->> 'active')::boolean, active), rev = rev + 1
    where id = rid and encounter_id = e.id returning * into rm;
    if rm.id is null then raise exception 'Reminder not found' using errcode = '22023'; end if;
  end if;
  perform public._combat_event(e.id, 'reminder_saved', null, null, to_jsonb(rm), null, null, false);
  perform public._combat_changed(e.id, 'reminders', 'saved');
  return to_jsonb(rm);
end $$;

create or replace function public.combat_delete_reminder(p_reminder uuid)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare rm public.combat_reminders;
begin
  select * into rm from public.combat_reminders where id = p_reminder;
  if not found then raise exception 'Reminder not found' using errcode = '42501'; end if;
  perform public._combat_auth(rm.encounter_id, 'share');
  delete from public.combat_reminders where id = rm.id;
  perform public._combat_event(rm.encounter_id, 'reminder_deleted', null, to_jsonb(rm), null, null, null, false);
  perform public._combat_changed(rm.encounter_id, 'reminders', 'deleted');
  return jsonb_build_object('deleted', true, 'id', rm.id);
end $$;

create or replace function public.combat_ack_reminder(p_reminder uuid)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare rm public.combat_reminders; e public.combat_encounters;
begin
  select * into rm from public.combat_reminders where id = p_reminder;
  if not found then raise exception 'Reminder not found' using errcode = '42501'; end if;
  e := public._combat_auth(rm.encounter_id, 'share');
  update public.combat_reminders set acknowledged_round = e.round, rev = rev + 1 where id = rm.id returning * into rm;
  perform public._combat_changed(rm.encounter_id, 'reminders', 'acknowledged');
  return to_jsonb(rm);
end $$;

-- ================================================================================================= 10. Undo
-- Undo of one recent change. Refused when the state changed since (a newer change is never overwritten); audited.
create or replace function public.combat_undo(p_event bigint, p_request uuid default null)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare ev public.combat_events; e public.combat_encounters; p public.combat_participants; r jsonb; nev bigint; cur jsonb; v jsonb; x public.combat_effects;
  stale constant text := 'This changed again since. Correct it by hand (nothing was undone).';
begin
  select * into ev from public.combat_events where id = p_event;
  if not found then raise exception 'Change not found' using errcode = '42501'; end if;
  e := public._combat_auth(ev.encounter_id, 'update');
  r := public._combat_replay(e.id, p_request); if r is not null then return r; end if;
  select * into ev from public.combat_events where id = p_event for update;
  if ev.undone_by is not null then raise exception 'This change was already undone' using errcode = '22023'; end if;
  if not ev.undoable then raise exception 'This change cannot be undone' using errcode = '22023'; end if;
  if ev.kind in ('turn_advanced', 'turn_jumped') then
    return public.combat_previous_turn(e.id, null, true, p_request);
  end if;
  if ev.participant_id is not null then select * into p from public.combat_participants where id = ev.participant_id for update; end if;
  case
  when ev.kind in ('damage', 'heal', 'temp_hp', 'hp_set') then
    if p.kind = 'monster' then
      if p.hp_current <> (ev.after ->> 'hp')::int or p.hp_temp <> (ev.after ->> 'temp')::int then raise exception '%', stale using errcode = 'TLCMB'; end if;
      update public.combat_participants set hp_current = (ev.before ->> 'hp')::int, hp_temp = (ev.before ->> 'temp')::int,
        defeated = (ev.before ->> 'defeated')::boolean, defeated_at = case when (ev.before ->> 'defeated')::boolean then defeated_at end, rev = rev + 1 where id = p.id;
    else
      if p.linked_character_id is null then raise exception 'This character no longer exists' using errcode = '22023'; end if;
      perform 1 from public.characters where id = p.linked_character_id for update;
      cur := public._combat_char_state(p.linked_character_id);
      if (ev.before ->> 'form')::boolean or (ev.after ->> 'form')::boolean then
        if not ((ev.before ->> 'form')::boolean and (cur ->> 'form')::boolean and cur ->> 'form_hp' = ev.after ->> 'form_hp' and cur ->> 'form_temp' = ev.after ->> 'form_temp'
                and cur ->> 'hp' = ev.after ->> 'hp') then
          raise exception 'The Wild Shape form changed or ended since. Correct it by hand (nothing was undone).' using errcode = 'TLCMB';
        end if;
        perform public.set_transformation_hp(p.linked_character_id, (ev.before ->> 'form_hp')::int, (ev.before ->> 'form_temp')::int, 'Undo in the Combat Builder');
      else
        if cur ->> 'hp' <> ev.after ->> 'hp' or cur ->> 'temp' <> ev.after ->> 'temp' or (cur ->> 'form')::boolean then raise exception '%', stale using errcode = 'TLCMB'; end if;
        update public.characters set hp_current = (ev.before ->> 'hp')::int, hp_temp = (ev.before ->> 'temp')::int,
          death_successes = (ev.before ->> 'death_successes')::int, death_failures = (ev.before ->> 'death_failures')::int where id = p.linked_character_id;
      end if;
    end if;
    -- a concentration reminder this damage created and the DM has not answered yet goes away with it
    update public.combat_effects z set pending_checks = coalesce((select jsonb_agg(y) from jsonb_array_elements(z.pending_checks) y where (y ->> 'event_id')::bigint <> ev.id), '[]'), rev = rev + 1
    where z.encounter_id = e.id and z.effect_type = 'concentration' and z.source_participant_id = p.id and z.pending_checks @> jsonb_build_array(jsonb_build_object('event_id', ev.id));
    perform public._combat_changed(e.id, 'hp', 'undo', p.id, not p.hidden);
  when ev.kind = 'effect_added' then
    update public.combat_effects set active = false, ended_at = now(), ended_reason = 'undo', rev = rev + 1
    where id = any (public._combat_ids((select jsonb_agg(jsonb_build_object('id', y)) from jsonb_array_elements_text(ev.details -> 'ids') y), 'id')) and active;
    update public.combat_effects set active = true, ended_at = null, ended_reason = null, rev = rev + 1
    where id = any (public._combat_ids((select jsonb_agg(jsonb_build_object('id', y)) from jsonb_array_elements_text(coalesce(ev.details -> 'ended', '[]')) y), 'id'))
      and not active and ended_reason = 'concentration_ended';
    perform public._combat_changed(e.id, 'effects', 'undo', ev.participant_id, true);
  when ev.kind in ('effect_ended', 'concentration_ended', 'concentration_failed') then
    for x in select * from public.combat_effects where id = any (public._combat_ids((select jsonb_agg(jsonb_build_object('id', y))
               from jsonb_array_elements_text(ev.details -> 'ids') y), 'id')) for update loop
      if x.active then raise exception '%', stale using errcode = 'TLCMB'; end if;
    end loop;
    update public.combat_effects set active = true, ended_at = null, ended_reason = null, rev = rev + 1
    where id = any (public._combat_ids((select jsonb_agg(jsonb_build_object('id', y)) from jsonb_array_elements_text(ev.details -> 'ids') y), 'id'));
    perform public._combat_changed(e.id, 'effects', 'undo', ev.participant_id, true);
  when ev.kind in ('initiative_set', 'initiative_rolled', 'initiative_changed', 'initiative_cleared') then
    for v in select y from jsonb_array_elements(coalesce(ev.before -> 'values', '[]')) y loop
      update public.combat_participants set initiative = (v ->> 'initiative')::int, initiative_roll = (v ->> 'initiative_roll')::int,
        initiative_mode = v ->> 'initiative_mode', rev = rev + 1 where id = (v ->> 'id')::uuid and encounter_id = e.id;
      if e.status in ('active', 'paused') then perform public._combat_place(e.id, (v ->> 'id')::uuid); end if;
    end loop;
    if e.status = 'draft' and not coalesce((e.settings ->> 'manual_order')::boolean, false) then perform public._combat_apply_order(e.id); end if;
    perform public._combat_changed(e.id, 'participants', 'initiative', null, true);
  when ev.kind = 'reaction' then
    if p.reaction_used is distinct from (ev.after ->> 'used')::boolean then raise exception '%', stale using errcode = 'TLCMB'; end if;
    update public.combat_participants set reaction_used = (ev.before ->> 'used')::boolean, rev = rev + 1 where id = p.id;
    perform public._combat_changed(e.id, 'participants', 'reaction', p.id, not p.hidden);
  when ev.kind = 'legendary' then
    if p.legendary_left is distinct from (ev.after ->> 'left')::int then raise exception '%', stale using errcode = 'TLCMB'; end if;
    update public.combat_participants set legendary_left = (ev.before ->> 'left')::int, rev = rev + 1 where id = p.id;
    perform public._combat_changed(e.id, 'participants', 'legendary', p.id, not p.hidden);
  when ev.kind in ('participant_defeat', 'participant_restore', 'participant_deactivate', 'participant_activate') then
    update public.combat_participants set active = (ev.before ->> 'active')::boolean, defeated = (ev.before ->> 'defeated')::boolean, rev = rev + 1 where id = p.id;
    perform public._combat_changed(e.id, 'participants', 'undo', p.id, not p.hidden);
  else
    raise exception 'This change cannot be undone' using errcode = '22023';
  end case;
  nev := public._combat_event(e.id, 'undo', ev.participant_id, null, null, jsonb_build_object('undo_of', ev.id, 'kind', ev.kind), p_request, false);
  update public.combat_events set undone_by = nev where id = ev.id;
  update public.combat_events set undo_of = ev.id where id = nev;
  r := jsonb_build_object('undone', ev.kind, 'event_id', ev.id, 'undo_event_id', nev);
  perform public._combat_set_result(nev, r);
  return r || public.combat_get_encounter(e.id);
end $$;

-- ================================================================================================= 11. monster library
-- SRD 5.2.1 (2024), SRD 5.1 (2014) and the campaign's published homebrew. Light rows; the stat block is loaded on demand.
-- p_filters: {cr_min, cr_max, type, size, source (srd2024 | srd2014 | homebrew), rules (2014 | 2024), favorites, legendary}
create or replace function public.combat_monster_library(p_campaign uuid, p_query text default null, p_filters jsonb default '{}', p_limit int default 60,
  p_offset int default 0)
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
declare q text := nullif(btrim(coalesce(p_query, '')), ''); f jsonb := coalesce(p_filters, '{}');
begin
  if not public._combat_can_run(p_campaign) then raise exception 'Only a DM of this campaign can open its monster library' using errcode = '42501'; end if;
  return (with lib as (
      select 'srd52:' || m.id as ref, 'srd2024' as kind, m.id, m.name, m.size, m.creature_type, m.challenge_rating as cr, m.xp, m.armor_class as ac,
        m.hit_points as hp, '2024'::text as rules, m.source_label as source, m.legendary_uses is not null as legendary, false as homebrew, null::uuid as content_id
      from public.combat_monsters m where m.archived_at is null
      union all
      select 'creature:' || c.id, case when c.content_scope = 'campaign' then 'homebrew' else 'creature' end, c.id, c.name, c.size, c.creature_type,
        c.challenge_rating, c.xp, c.armor_class, c.hit_points, case when c.content_scope = 'campaign' then v.ruleset else '2014' end, c.source_label,
        c.legendary or exists (select 1 from public.creature_legendary_actions l where l.creature_id = c.id), c.content_scope = 'campaign', v.content_id
      from public.creatures c left join public.dm_content_versions v on v.id = c.content_version_id left join public.dm_content d on d.id = v.content_id
      where c.archived_at is null and (c.content_scope = 'official'
            or (c.content_scope = 'campaign' and c.campaign_id = p_campaign and d.published_version_id = v.id))),
    fl as (select l.*, exists (select 1 from public.combat_monster_favorites fv where fv.user_id = auth.uid() and fv.monster_ref = l.ref) as favorite
      from lib l
      where (q is null or l.name ilike '%' || q || '%' or l.creature_type ilike q || '%')
        and (f ->> 'cr_min' is null or l.cr >= (f ->> 'cr_min')::numeric) and (f ->> 'cr_max' is null or l.cr <= (f ->> 'cr_max')::numeric)
        and (f ->> 'type' is null or l.creature_type = f ->> 'type') and (f ->> 'size' is null or l.size = f ->> 'size')
        and (f ->> 'source' is null or (f ->> 'source' = 'srd2024' and l.kind = 'srd2024') or (f ->> 'source' = 'srd2014' and l.kind = 'creature')
             or (f ->> 'source' = 'homebrew' and l.kind = 'homebrew'))
        and (f ->> 'rules' is null or l.rules = f ->> 'rules')
        and (not coalesce((f ->> 'legendary')::boolean, false) or l.legendary)),
    fl2 as (select * from fl where not coalesce((f ->> 'favorites')::boolean, false) or favorite)
    select jsonb_build_object('total', (select count(*) from fl2),
      'types', (select coalesce(jsonb_agg(distinct creature_type), '[]') from lib),
      'items', (select coalesce(jsonb_agg(to_jsonb(z) order by z.favorite desc, z.name, z.rules desc), '[]') from
                (select * from fl2 order by favorite desc, name, rules desc limit least(greatest(coalesce(p_limit, 60), 1), 200) offset greatest(coalesce(p_offset, 0), 0)) z),
      'attribution', 'This work includes material from the System Reference Document 5.2.1 ("SRD 5.2.1") by Wizards of the Coast LLC, available at https://www.dndbeyond.com/srd. The SRD 5.2.1 is licensed under the Creative Commons Attribution 4.0 International License, available at https://creativecommons.org/licenses/by/4.0/legalcode.'));
end $$;

create or replace function public.combat_monster_detail(p_ref text, p_campaign uuid)
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  if not public._combat_can_run(p_campaign) then raise exception 'Only a DM of this campaign can open its monster library' using errcode = '42501'; end if;
  if p_ref like 'srd52:%' then return public._combat_source('srd2024', substr(p_ref, 7), p_campaign); end if;
  if p_ref like 'creature:%' then return public._combat_source('creature', substr(p_ref, 10), p_campaign); end if;
  raise exception 'Unknown monster "%"', p_ref using errcode = '22023';
end $$;

create or replace function public.combat_toggle_favorite(p_ref text, p_on boolean default true)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if auth.uid() is null then raise exception 'Sign in first' using errcode = '42501'; end if;
  if p_ref !~ '^(srd52|creature):[a-z0-9-]+$' then raise exception 'Unknown monster "%"', p_ref using errcode = '22023'; end if;
  if p_on then insert into public.combat_monster_favorites (user_id, monster_ref) values (auth.uid(), p_ref) on conflict do nothing;
  else delete from public.combat_monster_favorites where user_id = auth.uid() and monster_ref = p_ref; end if;
  return jsonb_build_object('ref', p_ref, 'favorite', p_on);
end $$;

-- monsters this DM added to encounters lately (newest first)
create or replace function public.combat_recent_monsters(p_campaign uuid, p_limit int default 12)
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  if not public._combat_can_run(p_campaign) then raise exception 'Only a DM of this campaign can open its monster library' using errcode = '42501'; end if;
  return (select coalesce(jsonb_agg(jsonb_build_object('ref', z.ref, 'name', z.name, 'rules', z.rules_version, 'kind', z.source_kind) order by z.at desc), '[]')
          from (select case when s.source_kind = 'srd2024' then 'srd52:' else 'creature:' end || s.source_id as ref, s.source_kind,
                       max(s.name) as name, max(s.rules_version) as rules_version, max(s.created_at) as at
                from public.combat_statblocks s join public.combat_encounters e on e.id = s.encounter_id
                where e.campaign_id = p_campaign and s.source_kind <> 'custom' and s.source_id is not null
                group by 1, 2 order by max(s.created_at) desc limit least(greatest(coalesce(p_limit, 12), 1), 50)) z);
end $$;

-- ================================================================================================= 12. player-safe read model
-- For a future player combat view (not used by the first release's UI). Members of the campaign only; running encounters
-- only. Never returns: hidden or not-yet-joined combatants, true names behind a disguise, exact monster HP (unless the DM
-- set player_enemy_hp = exact), DM-only effects, notes, reminders, stat blocks, history.
create or replace function public.get_combat_player_view(p_encounter uuid)
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
declare e public.combat_encounters; hpmode text; cur uuid;
begin
  select * into e from public.combat_encounters where id = p_encounter;
  if auth.uid() is null or e.id is null or not (public._combat_can_run(e.campaign_id)
     or exists (select 1 from public.campaign_members m where m.campaign_id = e.campaign_id and m.user_id = auth.uid())) then
    raise exception 'Encounter not found' using errcode = '42501';
  end if;
  if e.status not in ('active', 'paused') then
    return jsonb_build_object('encounter', jsonb_build_object('id', e.id, 'status', 'not_running'), 'participants', '[]'::jsonb);
  end if;
  hpmode := coalesce(e.settings ->> 'player_enemy_hp', 'state');
  select p.id into cur from public.combat_participants p where p.id = e.current_participant_id and not p.hidden and p.active and p.removed_at is null;
  return jsonb_build_object(
    'encounter', jsonb_build_object('id', e.id, 'name', e.name, 'status', e.status, 'round', e.round, 'ruleset', e.ruleset, 'current_participant_id', cur),
    'participants', (select coalesce(jsonb_agg(jsonb_build_object('id', p.id, 'kind', p.kind,
        'name', case when p.kind = 'character' then p.display_name else coalesce(p.player_label, p.display_name) end,
        'label', case when p.player_label is null then p.instance_label end, 'initiative', p.initiative, 'current', p.id = cur, 'defeated', p.defeated,
        'hp', case when p.kind = 'character' then (select jsonb_build_object('current', c.hp_current, 'max', (public._feat_hp_bonus(c.id) ->> 'max')::int, 'temp', c.hp_temp)
                                                   from public.characters c where c.id = p.linked_character_id)
                   when hpmode = 'exact' then jsonb_build_object('current', p.hp_current, 'max', p.hp_max)
                   when hpmode = 'state' then jsonb_build_object('state', public._combat_hp_state(p.hp_current, p.hp_max)) end,
        'effects', (select coalesce(jsonb_agg(jsonb_build_object('name', x.display_name, 'condition', x.condition_key, 'remaining_rounds', x.remaining_rounds,
                      'type', x.effect_type) order by x.created_at), '[]')
                    from public.combat_effects x where x.target_participant_id = p.id and x.active and x.visibility = 'players'))
        order by p.initiative_order nulls last, p.created_at), '[]')
      from public.combat_participants p where p.encounter_id = e.id and p.active and p.removed_at is null and not p.hidden
        and (p.joins_round is null or p.joins_round <= e.round)));
end $$;

-- ================================================================================================= 13. homebrew creature validation
-- Conditional rules for creature definitions written by the Combat Builder editor (definition.combat = {mode: quick | advanced}).
-- Only what is relevant is required: a to-hit bonus for attacks, a damage formula for damaging attacks, a range for ranged
-- attacks, ability + DC for saving throw effects, a recharge roll only for rechargeable actions, Legendary Actions only when
-- enabled, spellcasting data only when enabled. Other creature definitions (DM Space editor) are validated as before.
create or replace function public._combat_creature_errors(d jsonb)
returns jsonb language plpgsql immutable set search_path = public, pg_temp as $$
declare errs jsonb := '[]'; a jsonb; nm text; k text; sect text; dice text; attacks int := 0; la jsonb;
begin
  if d is null or not d ? 'combat' then return errs; end if;
  if coalesce(btrim(d ->> 'size'), '') = '' then errs := errs || '["Choose a size."]'; end if;
  if coalesce(btrim(d ->> 'creature_type'), '') = '' then errs := errs || '["Choose a creature type."]'; end if;
  if not exists (select 1 from jsonb_each_text(coalesce(d -> 'speed', '{}')) s where s.key in ('walk', 'climb', 'swim', 'fly', 'burrow') and s.value ~ '^\d+$') then
    errs := errs || '["Give a Speed (walking or another movement, in feet)."]';
  end if;
  if d ->> 'initiative_bonus' is not null and (d ->> 'initiative_bonus' !~ '^-?\d+$' or (d ->> 'initiative_bonus')::int not between -10 and 20) then
    errs := errs || '["The Initiative modifier is -10 to +20."]';
  end if;
  foreach sect in array array['actions', 'bonus_actions', 'reactions'] loop
    for a in select y from jsonb_array_elements(coalesce(d -> sect, '[]')) y loop
      nm := coalesce(nullif(btrim(a ->> 'name'), ''), '(unnamed)');
      if coalesce(btrim(a ->> 'name'), '') = '' then errs := errs || jsonb_build_array('Every ' || replace(rtrim(sect, 's'), '_', ' ') || ' needs a name.'); end if;
      k := coalesce(a ->> 'kind', 'other');
      dice := btrim(coalesce(a -> 'damage' -> 0 ->> 'dice', ''));
      if dice <> '' and replace(dice, ' ', '') !~ '^\d+(d\d+([+-]\d+)?)?$' then
        errs := errs || jsonb_build_array(format('"%s": the damage formula looks like 1d6+2.', nm));
      end if;
      if k in ('melee', 'ranged') then
        if coalesce(a ->> 'attack_bonus', '') !~ '^-?\d+$' then errs := errs || jsonb_build_array(format('"%s": an attack needs a to-hit bonus.', nm));
        else attacks := attacks + 1; end if;
        if not coalesce((a ->> 'no_damage')::boolean, false) and dice = '' then
          errs := errs || jsonb_build_array(format('"%s": a damaging attack needs a damage formula (e.g. 1d6+2).', nm));
        end if;
        if k = 'ranged' and coalesce(a ->> 'range', a ->> 'reach', '') = '' then errs := errs || jsonb_build_array(format('"%s": a ranged attack needs a range.', nm)); end if;
      elsif k = 'save' then
        if coalesce(a -> 'save' ->> 'ability', '') = '' or coalesce(a -> 'save' ->> 'dc', '') !~ '^\d+$' then
          errs := errs || jsonb_build_array(format('"%s": a saving throw effect needs the ability and the DC.', nm));
        end if;
      end if;
      if coalesce((a -> 'recharge' ->> 'enabled')::boolean, false) and coalesce(a -> 'recharge' ->> 'min', '') !~ '^[2-6]$' then
        errs := errs || jsonb_build_array(format('"%s": choose the recharge roll (2 to 6).', nm));
      end if;
    end loop;
  end loop;
  if d -> 'combat' ->> 'mode' = 'quick' and attacks = 0 then errs := errs || '["A quick creature needs one basic attack (name, to-hit and damage)."]'; end if;
  if coalesce((d -> 'legendary' ->> 'enabled')::boolean, false) then
    if coalesce(d -> 'legendary' ->> 'uses', '') !~ '^[1-5]$' then errs := errs || '["Legendary Actions: give the uses per round (1 to 5)."]'; end if;
    if jsonb_array_length(coalesce(d -> 'legendary' -> 'actions', '[]')) = 0 then errs := errs || '["Legendary Actions: add at least one option."]'; end if;
    for la in select y from jsonb_array_elements(coalesce(d -> 'legendary' -> 'actions', '[]')) y loop
      if coalesce(btrim(la ->> 'name'), '') = '' then errs := errs || '["Every Legendary Action needs a name."]'; end if;
      if coalesce(la ->> 'cost', '1') !~ '^[1-3]$' then errs := errs || jsonb_build_array(format('Legendary Action "%s": the cost is 1 to 3.', coalesce(la ->> 'name', ''))); end if;
    end loop;
  end if;
  if coalesce((d -> 'spellcasting' ->> 'enabled')::boolean, false) then
    if coalesce(d -> 'spellcasting' ->> 'ability', '') not in ('int', 'wis', 'cha') then errs := errs || '["Spellcasting: choose the spellcasting ability."]'; end if;
    if coalesce(d -> 'spellcasting' ->> 'save_dc', '') !~ '^\d+$' and coalesce(d -> 'spellcasting' ->> 'attack_bonus', '') !~ '^-?\d+$' then
      errs := errs || '["Spellcasting: give the spell save DC or the spell attack bonus."]';
    end if;
    if coalesce(btrim(d -> 'spellcasting' ->> 'spells'), '') = '' then errs := errs || '["Spellcasting: list the spells."]'; end if;
  end if;
  return errs;
end $$;

-- _dm_try: one added line in the creature branch (the exact previous definition is in the rollback)
do $$
declare src text := pg_get_functiondef('public._dm_try(uuid)'::regprocedure); anchor constant text := '  elsif t = ''background'' then';
begin
  if position('_combat_creature_errors' in src) > 0 then return; end if;
  if position(anchor in src) = 0 then raise exception '_dm_try is not the expected version (anchor missing): review before applying'; end if;
  src := replace(src, anchor, '    if t = ''creature'' then errors := errors || public._combat_creature_errors(d); end if;' || chr(10) || anchor);
  execute src;
end $$;

-- ================================================================================================= 14. grants
do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig, p.proname from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname = any (array['_combat_apply_order', '_combat_auth', '_combat_boundary', '_combat_campaign_ruleset', '_combat_can_act', '_combat_changed', '_combat_char_state', '_combat_creature_errors', '_combat_d20', '_combat_difficulty', '_combat_ejson', '_combat_encounter_json', '_combat_entries', '_combat_event', '_combat_hp_one', '_combat_hp_state', '_combat_ids', '_combat_init_mode', '_combat_label', '_combat_lasting_effects', '_combat_participant_auth', '_combat_pjson', '_combat_place', '_combat_reminders_due', '_combat_replay', '_combat_roll', '_combat_set_result', '_combat_snapshot', '_combat_sorted', '_combat_source', '_combat_ties', '_combat_touch', '_combat_turn_end', '_combat_turn_result', '_combat_turn_start', 'apply_character_hp', 'combat_ack_reminder', 'combat_add_characters', 'combat_add_custom', 'combat_add_effect', 'combat_add_monsters', 'combat_apply_hp', 'combat_apply_hp_bulk', 'combat_archive_encounter', 'combat_clear_initiative', 'combat_create_encounter', 'combat_delete_draft', 'combat_delete_reminder', 'combat_duplicate_encounter', 'combat_end_effect', 'combat_finish', 'combat_get_changes', 'combat_get_encounter', 'combat_get_history', 'combat_get_participant', 'combat_get_statblock', 'combat_get_summary', 'combat_goto_turn', 'combat_list_encounters', 'combat_monster_detail', 'combat_monster_library', 'combat_next_turn', 'combat_pause', 'combat_previous_turn', 'combat_recent_monsters', 'combat_reorder', 'combat_resolve_concentration', 'combat_resume', 'combat_roll_initiative', 'combat_save_reminder', 'combat_set_initiative', 'combat_set_participant_state', 'combat_set_reaction', 'combat_sort_initiative', 'combat_spend_legendary', 'combat_start', 'combat_toggle_favorite', 'combat_undo', 'combat_update_effect', 'combat_update_encounter', 'combat_update_participant', 'get_combat_player_view']) loop   -- this migration's functions only (never e.g. combat_wild_shape_heal)
    execute format('revoke all on function %s from public, anon', f.sig);
    if f.proname like '\_combat\_%' and f.proname not in ('_combat_can_run', '_combat_can_see') then
      execute format('revoke all on function %s from authenticated', f.sig);
    else
      execute format('grant execute on function %s to authenticated', f.sig);
    end if;
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
