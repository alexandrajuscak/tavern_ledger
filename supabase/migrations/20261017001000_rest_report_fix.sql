-- =============================================================================
-- Rest result fix. short_rest_character / long_rest_character restored Pact Magic and standard slots correctly but reported
-- them as 0 ("Nothing to restore"): `update ... returning expended` returns the value after the update. _rest now reports the
-- expended count read before the update, and lists a class resource under not_restored only when some of it is spent (with
-- the amount). Behaviour (what a rest restores) is unchanged; only the result is corrected.
-- _rest is otherwise exactly as in 20261015001800.
-- =============================================================================

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
    -- RETURNING shows the new value (0): report the value before the update
    with b as (select slot_level, expended from public.character_spell_slot_state
               where character_id = p_character and pool = 'standard' and expended > 0 for update),
    u as (update public.character_spell_slot_state x set expended = 0 from b
          where x.character_id = p_character and x.pool = 'standard' and x.slot_level = b.slot_level returning b.slot_level, b.expended)
    select coalesce(jsonb_agg(jsonb_build_object('slot_level', slot_level, 'restored', expended) order by slot_level), '[]') into std from u;
  end if;
  with b as (select slot_level, expended from public.character_spell_slot_state
             where character_id = p_character and pool = 'pact' and expended > 0 for update),
  u as (update public.character_spell_slot_state x set expended = 0 from b
        where x.character_id = p_character and x.pool = 'pact' and x.slot_level = b.slot_level returning b.expended)
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
      if (r ->> 'expended')::int > 0 then                              -- only what is actually still spent
        not_restored := not_restored || jsonb_build_object('name', r ->> 'name', 'reason', r ->> 'recharge', 'amount', (r ->> 'expended')::int);
      end if;
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
