-- Final-total Initiative (20261107000200_combat_initiative_wild_shape.sql; docs/COMBAT_INITIATIVE_RULES.md). LOCAL ONLY;
-- run as supabase_admin; one transaction, rolled back (synthetic users, campaign, characters, encounters).
-- Usage: docker exec -i supabase_db_tavern_ledger psql -U supabase_admin -d postgres -qAt -v ON_ERROR_STOP=1 < supabase/tests/combat_initiative_tests.sql
begin;
create temp table it (n serial, chk text, ok boolean, detail text) on commit drop;
grant all on it to authenticated, anon;
grant all on sequence it_n_seq to authenticated, anon;
create temp table fx (k text primary key, v text) on commit drop;
grant all on fx to authenticated, anon;

create or replace function pg_temp.as_user(u uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
end $$;
create or replace function pg_temp.as_admin() returns void language plpgsql as $$
begin
  execute 'reset role';
  perform set_config('request.jwt.claims', '', true);
end $$;
create or replace function pg_temp.ok(c text, b boolean, d text default '') returns void language sql as $$
  insert into it (chk, ok, detail) values (c, coalesce(b, false), coalesce(d, ''));
$$;
create or replace function pg_temp.try(q text) returns text language plpgsql as $$
begin
  execute q;
  return 'ok';
exception when others then return sqlstate || ': ' || sqlerrm;
end $$;
create or replace function pg_temp.fu(k text) returns uuid language sql as $$ select v::uuid from fx where fx.k = $1 $$;
create or replace function pg_temp.put(k text, v text) returns void language sql as $$
  insert into fx values (k, v) on conflict (k) do update set v = excluded.v;
$$;
create or replace function pg_temp.pc(e uuid, nm text) returns uuid language sql as $$
  select id from public.combat_participants where encounter_id = e and display_name = nm and removed_at is null limit 1;
$$;
create or replace function pg_temp.ini(p uuid) returns int language sql as $$ select initiative from public.combat_participants where id = p $$;
create or replace function pg_temp.setv(e uuid, p uuid, v int, reason text default null) returns jsonb language sql as $$
  select public.combat_set_initiative(e, jsonb_build_array(jsonb_build_object('id', p, 'initiative', v) || case when reason is null then '{}'::jsonb else jsonb_build_object('reason', reason) end));
$$;

do $$
declare dm uuid := gen_random_uuid(); pl uuid := gen_random_uuid(); pl2 uuid := gen_random_uuid(); camp uuid := gen_random_uuid(); ch uuid;
begin
  insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at) values
    (dm, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'it-dm-' || dm || '@example.test', now(), now()),
    (pl, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'it-pl-' || pl || '@example.test', now(), now()),
    (pl2, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'it-p2-' || pl2 || '@example.test', now(), now());
  insert into public.campaigns (id, name, created_by) values (camp, 'IT test campaign', dm);
  insert into public.campaign_members (campaign_id, user_id, role) values (camp, dm, 'dm'), (camp, pl, 'player');
  -- Aria: DEX 16 (+3); Brom: DEX 8 (-1)
  insert into public.characters (owner_id, name, campaign_id, level, hp_max, hp_current, dexterity) values (pl, 'IT Aria', camp, 3, 20, 20, 16) returning id into ch;
  perform pg_temp.put('aria', ch::text);
  insert into public.characters (owner_id, name, campaign_id, level, hp_max, hp_current, dexterity) values (pl, 'IT Brom', camp, 3, 24, 24, 8) returning id into ch;
  perform pg_temp.put('brom', ch::text);
  perform pg_temp.put('dm', dm::text); perform pg_temp.put('pl', pl::text); perform pg_temp.put('pl2', pl2::text); perform pg_temp.put('camp', camp::text);
end $$;

do $$
declare r jsonb; e uuid; e2 uuid; a uuid; b uuid; g uuid[]; s text; v int; w uuid; o uuid; ev public.combat_events; d uuid;
begin
  perform pg_temp.as_user(pg_temp.fu('dm'));
  r := public.combat_create_encounter(pg_temp.fu('camp'), 'IT fight', '2024'); e := (r -> 'encounter' ->> 'id')::uuid; perform pg_temp.put('e', e::text);
  perform public.combat_add_characters(e, array[pg_temp.fu('aria'), pg_temp.fu('brom')],
    jsonb_build_object('modifiers', jsonb_build_object(pg_temp.fu('aria'), jsonb_build_object('initiative_mod', 3, 'dexterity', 16),
                                                      pg_temp.fu('brom'), jsonb_build_object('initiative_mod', -1, 'dexterity', 8))));
  a := pg_temp.pc(e, 'IT Aria'); b := pg_temp.pc(e, 'IT Brom');
  perform public.combat_update_participant(a, '{"initiative_mod": 3}'); perform public.combat_update_participant(b, '{"initiative_mod": -1}');
  perform pg_temp.ok('N0 fixture: modifiers +3 / -1', (select initiative_mod from public.combat_participants where id = a) = 3 and (select initiative_mod from public.combat_participants where id = b) = -1);

  r := pg_temp.setv(e, a, 17);
  perform pg_temp.ok('N1 modifier +3, DM enters 17: stored 17 (modifier not added)', pg_temp.ini(a) = 17, pg_temp.ini(a)::text);
  r := pg_temp.setv(e, b, 8);
  perform pg_temp.ok('N2 modifier -1, DM enters 8: stored 8', pg_temp.ini(b) = 8);
  perform pg_temp.ok('N2b player entries: no d20 is recorded, mode player', (select bool_and(initiative_roll is null and initiative_mode = 'player') from public.combat_participants where id in (a, b)));
  r := pg_temp.setv(e, b, 0);
  perform pg_temp.ok('N3 final Initiative 0 allowed', pg_temp.ini(b) = 0);
  r := pg_temp.setv(e, b, -3);
  perform pg_temp.ok('N4 negative final Initiative allowed (-3)', pg_temp.ini(b) = -3);
  r := pg_temp.setv(e, a, 41);
  perform pg_temp.ok('N4b an unusually high valid total (41)', pg_temp.ini(a) = 41);
  s := pg_temp.try(format('select pg_temp.setv(%L, %L, 61)', e, a));
  perform pg_temp.ok('N4c out of range (61) refused with a friendly message, value kept', s like '22023%' and pg_temp.ini(a) = 41, s);
  r := pg_temp.setv(e, a, 17); r := pg_temp.setv(e, a, 17);
  perform pg_temp.ok('N5 no double modifier after repeated entry (17 stays 17)', pg_temp.ini(a) = 17);
  r := pg_temp.setv(e, b, 12);
  perform pg_temp.ok('N7 edit before Start (Brom -3 -> 12)', pg_temp.ini(b) = 12);

  -- monsters
  r := public.combat_add_monsters(e, 'srd2024', 'srd52-goblin-warrior', '{"quantity": 3}');
  select array_agg(id order by instance_label) into g from public.combat_participants where encounter_id = e and display_name = 'Goblin Warrior';
  r := public.combat_add_monsters(e, 'srd2024', 'srd52-goblin-warrior', '{"quantity": 1, "group": "separate", "name": "Goblin Scout"}');
  w := pg_temp.pc(e, 'Goblin Scout');
  r := public.combat_add_monsters(e, 'srd2024', 'srd52-ogre', '{"quantity": 1}');
  o := pg_temp.pc(e, 'Ogre');
  r := public.combat_roll_initiative(e, null, '{}', gen_random_uuid());
  perform pg_temp.ok('N9 automatic monster roll: d20 + modifier for every monster', (select bool_and(initiative_roll between 1 and 20 and initiative = initiative_roll + initiative_mod and initiative_mode = 'rolled')
    from public.combat_participants where encounter_id = e and kind = 'monster'));
  perform pg_temp.ok('N9b players untouched by Roll all monsters', pg_temp.ini(a) = 17 and pg_temp.ini(b) = 12);
  perform pg_temp.ok('N12 group automatic Initiative: one value for the 3 goblins', (select count(distinct initiative) from public.combat_participants where id = any (g)) = 1);
  r := pg_temp.setv(e, g[2], 14);
  perform pg_temp.ok('N13 group manual final total: typed for one member, the whole group gets 14 (no modifier added)',
    (select bool_and(initiative = 14 and initiative_mode = 'manual' and initiative_roll is null) from public.combat_participants where id = any (g)), (select string_agg(initiative::text, ',') from public.combat_participants where id = any (g)));
  r := pg_temp.setv(e, o, 9);
  perform pg_temp.ok('N10 manual monster total (Ogre 9)', pg_temp.ini(o) = 9 and (select initiative_mode from public.combat_participants where id = o) = 'manual');
  r := public.combat_roll_initiative(e, array[w], '{}', gen_random_uuid());
  perform pg_temp.ok('N14 individual monster roll leaves the group alone', (select bool_and(initiative = 14) from public.combat_participants where id = any (g))
    and (select initiative_mode from public.combat_participants where id = w) = 'rolled');
  r := public.combat_roll_initiative(e, array[g[1]], '{}', gen_random_uuid());
  perform pg_temp.ok('N16 switch manual -> automatic: rolling one member re-rolls the whole group once',
    (select count(distinct initiative) = 1 and bool_and(initiative_mode = 'rolled') from public.combat_participants where id = any (g)));
  v := pg_temp.ini(g[1]);
  r := pg_temp.setv(e, g[3], v);
  perform pg_temp.ok('N15 switch automatic -> manual keeps the same final total (no reinterpretation)', (select bool_and(initiative = v) from public.combat_participants where id = any (g)));
  r := public.combat_roll_initiative(e, array[a], '{"include_characters": true}', gen_random_uuid());
  -- the UI never rolls for players any more; the RPC still can when asked explicitly (documented); undo it
  r := pg_temp.setv(e, a, 17);
  -- fixed score (2024 option)
  r := public.combat_roll_initiative(e, array[o], '{"fixed": true}', gen_random_uuid());
  perform pg_temp.ok('N11 fixed monster score (2024): Ogre gets its printed Initiative score',
    pg_temp.ini(o) = coalesce((select initiative_score from public.combat_monsters where id = 'srd52-ogre'), 10 + (select initiative_modifier from public.combat_monsters where id = 'srd52-ogre'))
    and (select initiative_mode from public.combat_participants where id = o) = 'fixed', pg_temp.ini(o)::text);
  -- sort order and ties on the FINAL total
  r := pg_temp.setv(e, a, 30); r := pg_temp.setv(e, b, 30);
  perform pg_temp.ok('N6 sort order: highest final total first; tie of 30 default order by modifier (+3 Aria before -1 Brom)',
    (select id from public.combat_participants where encounter_id = e and removed_at is null order by initiative_order limit 1) = a
    and (select initiative_order from public.combat_participants where id = a) < (select initiative_order from public.combat_participants where id = b));
  perform pg_temp.ok('N17 tie review reports the 30 tie on final totals', (r -> 'ties') @> '[{"initiative": 30}]', (r -> 'ties')::text);
  r := public.combat_start(e);
  perform pg_temp.ok('N17b Start stops for the tie review', (r ->> 'needs_tie_review')::boolean);
  perform public.combat_reorder(e, array(select id from public.combat_participants where encounter_id = e and removed_at is null
    order by case when id = b then (select initiative_order - 1 from public.combat_participants where id = a) else initiative_order end));
  perform pg_temp.ok('N18 manual tie order (Brom before Aria) kept; totals unchanged', (select initiative_order from public.combat_participants where id = b)
    < (select initiative_order from public.combat_participants where id = a) and pg_temp.ini(a) = 30 and pg_temp.ini(b) = 30);
  -- hidden and delayed
  perform public.combat_update_participant(w, '{"hidden": true, "joins_round": 2}');
  r := pg_temp.setv(e, w, 5);
  perform pg_temp.ok('N19/N20 a hidden, delayed monster accepts a final total', pg_temp.ini(w) = 5);
  r := public.combat_start(e, true, gen_random_uuid());
  perform pg_temp.ok('N8a combat started', (select status from public.combat_encounters where id = e) = 'active');
  r := pg_temp.setv(e, o, 25, 'misheard the total');
  perform pg_temp.ok('N8 correction after Start: stored as typed (25), the Ogre moves', pg_temp.ini(o) = 25);
  select * into ev from public.combat_events where encounter_id = e and kind = 'initiative_changed' order by id desc limit 1;
  perform pg_temp.ok('N29 audit event with before value and the reason', ev.id is not null and ev.details -> 'reasons' @> '[{"reason": "misheard the total"}]'
    and ev.before -> 'values' -> 0 ->> 'initiative' is not null, coalesce(ev.details::text, 'none'));
  r := public.combat_undo(ev.id);
  perform pg_temp.ok('N29b the correction can be undone (Ogre back to its fixed score)', (select initiative_mode from public.combat_participants where id = o) = 'fixed');
  -- duplicate request protection
  d := gen_random_uuid();
  r := public.combat_set_initiative(e, jsonb_build_array(jsonb_build_object('id', a, 'initiative', 22)), d);
  r := public.combat_set_initiative(e, jsonb_build_array(jsonb_build_object('id', a, 'initiative', 22)), d);
  perform pg_temp.ok('N26 the same request twice: one change, one audit event', (select count(*) from public.combat_events where encounter_id = e and request_id = d) = 1 and pg_temp.ini(a) = 22);
  -- permissions: no raw error
  perform pg_temp.as_user(pg_temp.fu('pl'));
  s := pg_temp.try(format('select pg_temp.setv(%L, %L, 3)', e, a));
  perform pg_temp.ok('N28 a player cannot set Initiative in the DM tool (42501, friendly)', s like '42501%' and s not like '%violates%', s);
  perform pg_temp.as_user(pg_temp.fu('pl2'));
  s := pg_temp.try(format('select public.combat_roll_initiative(%L)', e));
  perform pg_temp.ok('N28b an unrelated user cannot roll', s like '42501%', s);
  perform pg_temp.as_user(pg_temp.fu('dm'));
  -- ruleset-aware: fixed scores are a 2024 option
  r := public.combat_create_encounter(pg_temp.fu('camp'), 'IT 2014 fight', '2014'); e2 := (r -> 'encounter' ->> 'id')::uuid;
  perform public.combat_add_monsters(e2, 'creature', 'goblin', '{}');
  s := pg_temp.try(format('select public.combat_roll_initiative(%L, null, %L)', e2, '{"fixed": true}'));
  perform pg_temp.ok('N30 2014 encounter: the fixed-score option is refused, auto roll works', s like '22023%'
    and pg_temp.try(format('select public.combat_roll_initiative(%L)', e2)) = 'ok', s);
  perform pg_temp.as_admin();
end $$;

select 'FAILED ' || chk || coalesce('  <-- ' || nullif(detail, ''), '') from it where not ok order by n;
select 'TOTAL ' || count(*) || ' checks, ' || count(*) filter (where not ok) || ' failed' from it;
rollback;
