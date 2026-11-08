-- Rollback of 20261107000200_combat_initiative_wild_shape.sql: restores damage_active_transformation, apply_character_hp,
-- _combat_hp_one, combat_set_initiative and combat_roll_initiative exactly as they were before (definitions captured from the
-- local database on 2026-11-07; same signatures, so grants are kept) and drops _ws_lock. No data changes.
-- After a rollback the wall-clock expiry defect returns (an expired form's damage goes wholly to normal HP) and a typed group
-- Initiative reaches only the member it was typed for. Deploy the previous frontend first or together: the new frontend reads
-- result.applied / result.reason when present and works without them.
begin;
CREATE OR REPLACE FUNCTION public.damage_active_transformation(p_character uuid, p_amount integer, p_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare t public.character_transformations; ch public.characters; temp_used int; left_dmg int; nv int; carry int := 0; ntemp int := 0; nhp int;
  result jsonb;
begin
  perform public._gov_gate(p_character, 'runtime.wild_shape');   -- campaign governance (20261019000100)
  if p_amount is null or p_amount < 1 or p_amount > 10000 then raise exception 'Give a damage amount (1 or more)' using errcode = '22023'; end if;
  if public._lock_for_wild_shape(p_character) then return public.get_character_transformation(p_character) || jsonb_build_object('result', jsonb_build_object('expired', true, 'ended', true, 'reason', 'expired')); end if;
  select * into t from public.character_transformations where character_id = p_character for update;
  if not found then raise exception 'The character is not in Wild Shape' using errcode = '22023'; end if;
  temp_used := least(t.hp_temp, p_amount);
  left_dmg := p_amount - temp_used;
  nv := t.hp_current - left_dmg;
  if nv > 0 then
    update public.character_transformations set hp_current = nv, hp_temp = hp_temp - temp_used where character_id = p_character;
    perform public._wild_shape_event(p_character, 'damaged', t.creature_id, jsonb_build_object('hp', t.hp_current, 'temp', t.hp_temp),
      jsonb_build_object('hp', nv, 'temp', t.hp_temp - temp_used), jsonb_build_object('amount', p_amount, 'note', p_note));
    result := jsonb_build_object('amount', p_amount, 'temp_absorbed', temp_used, 'form_hp_before', t.hp_current, 'form_hp_after', nv,
                                 'ended', false, 'carryover', 0);
  else
    carry := -nv;
    delete from public.character_transformations where character_id = p_character;
    select * into ch from public.characters where id = p_character;
    ntemp := least(coalesce(ch.hp_temp, 0), carry);
    nhp := greatest(0, coalesce(ch.hp_current, 0) - (carry - ntemp));
    update public.characters set hp_temp = coalesce(hp_temp, 0) - ntemp, hp_current = nhp where id = p_character;
    perform public._wild_shape_event(p_character, 'reverted_zero_hp', t.creature_id, jsonb_build_object('hp', t.hp_current, 'temp', t.hp_temp),
      jsonb_build_object('hp', 0), jsonb_build_object('amount', p_amount, 'note', p_note));
    if carry > 0 then
      perform public._wild_shape_event(p_character, 'excess_damage', t.creature_id, jsonb_build_object('hp', ch.hp_current, 'temp', ch.hp_temp),
        jsonb_build_object('hp', nhp, 'temp', coalesce(ch.hp_temp, 0) - ntemp), jsonb_build_object('carryover', carry));
    end if;
    result := jsonb_build_object('amount', p_amount, 'temp_absorbed', temp_used, 'form_hp_before', t.hp_current, 'form_hp_after', 0,
      'ended', true, 'carryover', carry, 'normal_hp_before', ch.hp_current, 'normal_hp_after', nhp, 'normal_temp_absorbed', ntemp,
      'unconscious', nhp = 0);
  end if;
  return public.get_character_transformation(p_character) || jsonb_build_object('result', result);
end;
$function$
;


CREATE OR REPLACE FUNCTION public.apply_character_hp(p_character uuid, p_op text, p_amount integer, p_reason text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
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
end $function$
;


CREATE OR REPLACE FUNCTION public._combat_hp_one(p combat_participants, e combat_encounters, p_op text, p_amount integer, p_reason text, p_request uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
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
end $function$
;


CREATE OR REPLACE FUNCTION public.combat_set_initiative(p_encounter uuid, p_values jsonb, p_request uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
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
end $function$
;


CREATE OR REPLACE FUNCTION public.combat_roll_initiative(p_encounter uuid, p_participants uuid[] DEFAULT NULL::uuid[], p_options jsonb DEFAULT '{}'::jsonb, p_request uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
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
end $function$
;


drop function if exists public._ws_lock(uuid);
commit;
