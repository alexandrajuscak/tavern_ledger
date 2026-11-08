-- Combat Builder follow-up: final-total Initiative for groups, and Wild Shape damage when the form's duration has run out
-- (docs/COMBAT_INITIATIVE_RULES.md, docs/WILD_SHAPE_DAMAGE.md). Rollback: supabase/rollback/rollback_combat_initiative_wild_shape.sql.
--
-- No table, column, index, policy or stored row is changed. Six functions are replaced with the same signatures and result
-- shapes (extra keys only), so grants are kept by CREATE OR REPLACE.
--
-- WILD SHAPE. The overflow formula was already right (form 20 HP, 21 damage: the form ends, 1 reaches normal HP). The defect
-- was the wall-clock duration: every Wild Shape change first ended a form whose expires_at had passed (_lock_for_wild_shape),
-- and apply_character_hp then sent the WHOLE amount to the normal HP. The sheet and the Combat Builder both still showed the
-- form with its HP, so the DM saw "Brown Bear 19 HP", applied 20, and normal HP fell 17 -> 0 instead of 17 -> 16. A heal or
-- a manual correction of the form fell through the same way to the normal HP. The sheet (which calls
-- damage_active_transformation directly) applied the damage nowhere, so the two screens differed.
-- One policy now, in the shared server functions:
--   * damage hits the form that is present: form temporary HP, then form HP; at 0 the form ends and only
--       excess = max(0, damage - form temporary HP - form HP before)
--     reaches the normal form (its temporary HP first). If the form survives but its duration is over, it ends right after
--     (reason 'expired'); the normal HP is untouched.
--   * heal / temporary HP / manual correction of a form whose duration is over: the form ends (as before) and NOTHING is
--     applied (result.applied = false, result.expired = true). Before, apply_character_hp applied it to the normal HP.
--   * apply_character_hp (sheet Damage / Heal, Combat Builder, API) and damage_active_transformation (sheet form buttons)
--     use the same code path; Combat history records the incoming damage, form HP used, the excess and the resulting HP.
--
-- INITIATIVE. Typed values were already stored as final totals (the modifier is never added). Now:
--   * combat_set_initiative: a value typed for a member of a shared group (group_key) is given to every active member of that
--     group in the same transaction, so the group never splits (a second DM window saw one member with a value and the
--     others without). Each value may carry "reason" (kept in the audit event; the UI asks for one after Start).
--   * combat_roll_initiative: rolling one member of a shared group rolls the whole group once.

-- ================================================================================================= Wild Shape
-- access check + the character lock that serializes every Wild Shape change, WITHOUT ending an expired form first
create or replace function public._ws_lock(p_character uuid)
returns void
language plpgsql
set search_path = public, pg_temp
as $$
begin
  if auth.uid() is null or not public.can_access_character(p_character) then
    raise exception 'Character not found' using errcode = '42501';
  end if;
  perform 1 from public.characters where id = p_character for update;
end;
$$;
revoke all on function public._ws_lock(uuid) from public, anon, authenticated;

CREATE OR REPLACE FUNCTION public.damage_active_transformation(p_character uuid, p_amount integer, p_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare t public.character_transformations; ch public.characters; temp_used int; left_dmg int; nv int; carry int := 0; ntemp int := 0; nhp int;
  result jsonb; was_expired boolean;
begin
  perform public._gov_gate(p_character, 'runtime.wild_shape');   -- campaign governance (20261019000100)
  if p_amount is null or p_amount < 1 or p_amount > 10000 then raise exception 'Give a damage amount (1 or more)' using errcode = '22023'; end if;
  perform public._ws_lock(p_character);   -- 20261107000200: the form that is present takes the damage, even if its duration is over
  select * into t from public.character_transformations where character_id = p_character for update;
  if not found then raise exception 'The character is not in Wild Shape' using errcode = '22023'; end if;
  was_expired := t.expires_at is not null and t.expires_at <= now();
  temp_used := least(t.hp_temp, p_amount);
  left_dmg := p_amount - temp_used;
  nv := t.hp_current - left_dmg;
  if nv > 0 then
    update public.character_transformations set hp_current = nv, hp_temp = hp_temp - temp_used where character_id = p_character;
    perform public._wild_shape_event(p_character, 'damaged', t.creature_id, jsonb_build_object('hp', t.hp_current, 'temp', t.hp_temp),
      jsonb_build_object('hp', nv, 'temp', t.hp_temp - temp_used), jsonb_build_object('amount', p_amount, 'note', p_note));
    result := jsonb_build_object('amount', p_amount, 'temp_absorbed', temp_used, 'form_hp_before', t.hp_current, 'form_hp_after', nv,
                                 'form_hp_used', left_dmg, 'ended', false, 'carryover', 0, 'applied', true);
    if was_expired then   -- the duration was over: the form ends now (its own event); normal HP stays as it is
      perform public._end_expired_form(p_character);
      result := result || jsonb_build_object('ended', true, 'reason', 'expired', 'expired', true, 'expired_at', t.expires_at);
    end if;
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
      'form_hp_used', t.hp_current, 'ended', true, 'reason', 'zero_hp', 'carryover', carry, 'normal_hp_before', ch.hp_current,
      'normal_hp_after', nhp, 'normal_temp_absorbed', ntemp, 'unconscious', nhp = 0, 'applied', true, 'expired', was_expired);
  end if;
  return public.get_character_transformation(p_character) || jsonb_build_object('result', result);
end;
$function$;

-- Sheet Damage / Heal, Combat Builder and API: one atomic change. In Wild Shape the form takes it (above); a heal or correction
-- of a form whose duration is over ends the form and changes nothing else.
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
    -- 20261107000200: never redirect the amount to the normal HP. An expired form reported here was ended and nothing was applied.
    if coalesce((r -> 'result' ->> 'expired')::boolean, false) and r -> 'result' ->> 'applied' is null then
      r := jsonb_set(r, '{result}', (r -> 'result') || jsonb_build_object('applied', false, 'op', p_op, 'amount', p_amount, 'form_name', (select name from public.creatures where id = t.creature_id)));
    end if;
    return jsonb_build_object('character_id', p_character, 'form', true, 'op', p_op, 'amount', p_amount, 'wild_shape', r,
      'applied', coalesce((r -> 'result' ->> 'applied')::boolean, true), 'hp_max', (public._feat_hp_bonus(p_character) ->> 'max')::int);
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
    'down', nhp = 0, 'went_down', nhp = 0 and c.hp_current > 0, 'applied', true);
end $$;

-- one HP change of one participant (callers hold the encounter FOR SHARE and the participant FOR UPDATE)
create or replace function public._combat_hp_one(p public.combat_participants, e public.combat_encounters, p_op text, p_amount int, p_reason text, p_request uuid)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare before jsonb; after jsonb; res jsonb; absorbed int := 0; nhp int; ntemp int; ndef boolean; x public.combat_effects; chk jsonb; checks jsonb := '[]';
  ev bigint; kind text; r jsonb; dc int; ws jsonb;
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
    ws := res -> 'wild_shape' -> 'result';
    absorbed := coalesce((res ->> 'absorbed')::int, (ws ->> 'temp_absorbed')::int, 0);
    if not coalesce((res ->> 'applied')::boolean, true) then
      -- the form's duration was over: it ended, nothing was applied (no HP event to undo); the tracker re-reads the participant
      perform public._combat_changed(e.id, 'hp', 'form_expired', p.id, not p.hidden);
      return jsonb_build_object('participant', public._combat_pjson((select y from public.combat_participants y where y.id = p.id)), 'op', p_op,
        'amount', p_amount, 'applied', false, 'wild_shape', ws, 'before', before, 'after', after, 'concentration_checks', '[]'::jsonb, 'effects', '[]'::jsonb,
        'message', format('The Wild Shape form (%s) had reached the end of its duration and reverted. Nothing was changed: apply it again to the normal form if it still applies.',
                          coalesce(ws ->> 'form_name', 'form')));
    end if;
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
    'carryover', ws -> 'carryover', 'form_name', case when (before ->> 'form')::boolean then (select name from public.creatures where id = before ->> 'creature_id') end,
    'form_hp_used', ws -> 'form_hp_used', 'form_ended_reason', ws -> 'reason', 'normal_hp_after', after -> 'hp'), p_request, true);
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
    'absorbed', absorbed, 'before', before, 'after', after, 'concentration_checks', checks, 'event_id', ev, 'wild_shape', ws, 'applied', true,
    'effects', (select coalesce(jsonb_agg(public._combat_ejson(z)), '[]') from public.combat_effects z where z.id = any (public._combat_ids(checks, 'effect_id'))));
  perform public._combat_set_result(ev, r - 'participant' - 'effects');
  return r;
end $$;

-- ================================================================================================= Initiative
-- typed FINAL totals: [{"id": "<participant>", "initiative": 17, "reason": "optional"}] (null clears). The value is stored as
-- typed: the Initiative modifier is never added. A member of a shared group gives the value to its whole group. In a running
-- combat the participant moves to its new place (audited, with the reason).
create or replace function public.combat_set_initiative(p_encounter uuid, p_values jsonb, p_request uuid default null)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare e public.combat_encounters := public._combat_auth(p_encounter, 'update'); v jsonb; p public.combat_participants; m public.combat_participants;
  before jsonb := '[]'; n int := 0; r jsonb; done uuid[] := '{}'; reasons jsonb := '[]';
begin
  r := public._combat_replay(e.id, p_request); if r is not null then return r; end if;
  if e.status = 'completed' then raise exception 'This encounter is finished' using errcode = '22023'; end if;
  for v in select x from jsonb_array_elements(coalesce(p_values, '[]')) x loop
    select * into p from public.combat_participants where id = (v ->> 'id')::uuid and encounter_id = e.id;
    if not found then raise exception 'Combatant not found in this encounter' using errcode = '22023'; end if;
    if (v ->> 'initiative') is not null and ((v ->> 'initiative')::int < -20 or (v ->> 'initiative')::int > 60) then
      raise exception 'Initiative is -20 to 60' using errcode = '22023';
    end if;
    if nullif(btrim(v ->> 'reason'), '') is not null then reasons := reasons || jsonb_build_object('id', p.id, 'reason', left(btrim(v ->> 'reason'), 200)); end if;
    for m in select x.* from public.combat_participants x
             where x.encounter_id = e.id and (x.id = p.id or (p.group_key is not null and x.group_key = p.group_key and x.removed_at is null and x.active))
             order by x.created_at for update loop
      if m.id = any (done) then continue; end if;
      done := done || m.id;
      before := before || jsonb_build_object('id', m.id, 'initiative', m.initiative, 'initiative_roll', m.initiative_roll, 'initiative_mode', m.initiative_mode, 'order', m.initiative_order);
      update public.combat_participants set initiative = (v ->> 'initiative')::int, initiative_roll = null,
        initiative_mode = case when (v ->> 'initiative') is null then null when m.kind = 'character' then 'player' else 'manual' end, rev = rev + 1
      where id = m.id;
      if e.status in ('active', 'paused') then perform public._combat_place(e.id, m.id); end if;
      n := n + 1;
    end loop;
  end loop;
  if e.status = 'draft' and not coalesce((e.settings ->> 'manual_order')::boolean, false) then perform public._combat_apply_order(e.id); end if;
  update public.combat_encounters set settings = settings - 'ties_confirmed' where id = e.id;
  perform public._combat_touch(e.id);
  perform public._combat_changed(e.id, 'participants', 'initiative', null, true);
  r := jsonb_build_object('updated', n, 'ties', public._combat_ties(e.id));
  perform public._combat_event(e.id, case when e.status = 'draft' then 'initiative_set' else 'initiative_changed' end, null, jsonb_build_object('values', before),
    jsonb_build_object('values', p_values), case when jsonb_array_length(reasons) > 0 then jsonb_build_object('reasons', reasons) end, p_request, true, r);
  return r;
end $$;

-- server rolls. p_participants null = every active monster without an Initiative (p_options.reroll: all monsters). A listed member
-- of a shared group brings its whole group (one roll). p_options: {reroll, fixed (2024: the printed Initiative score), include_characters}
create or replace function public.combat_roll_initiative(p_encounter uuid, p_participants uuid[] default null, p_options jsonb default '{}', p_request uuid default null)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare e public.combat_encounters := public._combat_auth(p_encounter, 'update'); p public.combat_participants; before jsonb := '[]'; rolled jsonb := '[]';
  groups jsonb := '{}'; roll jsonb; md text; val int; fixed boolean := coalesce((p_options ->> 'fixed')::boolean, false); r jsonb; score int; ids uuid[];
begin
  r := public._combat_replay(e.id, p_request); if r is not null then return r; end if;
  if e.status = 'completed' then raise exception 'This encounter is finished' using errcode = '22023'; end if;
  if fixed and e.ruleset <> '2024' then raise exception 'Fixed Initiative scores are a 2024 stat block option' using errcode = '22023'; end if;
  if p_participants is not null then   -- 20261107000200: the whole shared group of a listed member
    select array_agg(distinct x.id) into ids from public.combat_participants x
    where x.encounter_id = e.id and x.removed_at is null
      and (x.id = any (p_participants) or (x.group_key is not null and x.active and x.group_key in (
            select y.group_key from public.combat_participants y where y.encounter_id = e.id and y.id = any (p_participants) and y.group_key is not null)));
  end if;
  for p in select x.* from public.combat_participants x where x.encounter_id = e.id and x.removed_at is null and x.active
             and (case when p_participants is not null then x.id = any (ids)
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
