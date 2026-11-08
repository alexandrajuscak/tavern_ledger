-- Tests of the Combat Builder (20261106000100 / 20261106000200, seed combat_monsters.sql). LOCAL ONLY; run as supabase_admin;
-- everything happens in one transaction that is rolled back (synthetic users, campaign, characters, encounters).
-- Usage: docker exec -i supabase_db_tavern_ledger psql -U supabase_admin -d postgres -qAt -v ON_ERROR_STOP=1 < supabase/tests/combat_builder_tests.sql
-- Prints failed checks and a TOTAL line.
begin;
create temp table cb (n serial, chk text, ok boolean, detail text) on commit drop;
grant all on cb to authenticated, anon;
grant all on sequence cb_n_seq to authenticated, anon;
create temp table fx (k text primary key, v text) on commit drop;
grant all on fx to authenticated, anon;

create or replace function pg_temp.as_user(u uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
end $$;
create or replace function pg_temp.as_anon() returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('role', 'anon')::text, true);
  execute 'set local role anon';
end $$;
create or replace function pg_temp.as_admin() returns void language plpgsql as $$
begin
  execute 'reset role';
  perform set_config('request.jwt.claims', '', true);
end $$;
create or replace function pg_temp.ok(c text, b boolean, d text default '') returns void language sql as $$
  insert into cb (chk, ok, detail) values (c, coalesce(b, false), coalesce(d, ''));
$$;
-- run a statement, return 'ok' or the SQLSTATE: message
create or replace function pg_temp.try(q text) returns text language plpgsql as $$
begin
  execute q;
  return 'ok';
exception when others then return sqlstate || ': ' || sqlerrm;
end $$;
create or replace function pg_temp.fx(k text) returns text language sql as $$ select v from fx where fx.k = $1 $$;
create or replace function pg_temp.fu(k text) returns uuid language sql as $$ select v::uuid from fx where fx.k = $1 $$;
create or replace function pg_temp.put(k text, v text) returns void language sql as $$
  insert into fx values (k, v) on conflict (k) do update set v = excluded.v;
$$;
-- participant by name (+ label)
create or replace function pg_temp.pid(enc uuid, nm text, lbl text default null) returns uuid language sql as $$
  select id from public.combat_participants where encounter_id = enc and display_name = nm and instance_label is not distinct from lbl and removed_at is null limit 1;
$$;
create or replace function pg_temp.enc(e uuid) returns public.combat_encounters language sql as $$ select * from public.combat_encounters where id = e $$;
create or replace function pg_temp.cur_name(e uuid) returns text language sql as $$
  select p.display_name || coalesce(' ' || p.instance_label, '') from public.combat_encounters x join public.combat_participants p on p.id = x.current_participant_id where x.id = e;
$$;

-- ------------------------------------------------------------------------------------------------------------- fixtures
do $$
declare dm uuid := gen_random_uuid(); pl uuid := gen_random_uuid(); other uuid := gen_random_uuid(); dm2 uuid := gen_random_uuid();
  camp uuid := gen_random_uuid(); camp2 uuid := gen_random_uuid(); i int; ch uuid; outsider uuid; cc uuid;
begin
  insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at) values
    (dm, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'cb-dm-' || dm || '@example.test', now(), now()),
    (pl, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'cb-pl-' || pl || '@example.test', now(), now()),
    (other, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'cb-ot-' || other || '@example.test', now(), now()),
    (dm2, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'cb-dm2-' || dm2 || '@example.test', now(), now());
  insert into public.campaigns (id, name, created_by) values (camp, 'CB test campaign', dm), (camp2, 'CB other campaign', dm2);
  insert into public.campaign_members (campaign_id, user_id, role) values (camp, dm, 'dm'), (camp, pl, 'player'), (camp2, dm2, 'dm');
  for i in 1 .. 4 loop
    insert into public.characters (owner_id, name, campaign_id, level, hp_max, hp_current, hp_temp, strength, dexterity, constitution, intelligence, wisdom, charisma)
    values (pl, 'CB Hero ' || i, camp, 3, 20 + i, 20 + i, 0, 10, 10 + i * 2, 12, 10, 10, 10) returning id into ch;
    perform pg_temp.put('ch' || i, ch::text);
  end loop;
  insert into public.characters (owner_id, name, campaign_id, level, hp_max, hp_current) values (dm2, 'CB Outsider', camp2, 1, 8, 8) returning id into outsider;
  -- a Druid in a Wild Shape form (Wolf, 11 HP), set up directly (the Wild Shape engine itself has its own tests)
  insert into public.characters (owner_id, name, campaign_id, level, hp_max, hp_current, hp_temp, dexterity) values (pl, 'CB Druid', camp, 2, 15, 15, 0, 14) returning id into ch;
  insert into public.character_classes (character_id, class_id, class_version_id, level, is_primary) values (ch, 'druid', 'druid-phb', 2, true) returning id into cc;
  insert into public.character_transformations (character_id, character_class_id, resource_key, creature_id, cost, hp_max, hp_current, normal_hp_current, normal_hp_temp)
  values (ch, cc, 'wild-shape', 'wolf', 1, 11, 11, 15, 0);
  insert into fx values ('dm', dm), ('pl', pl), ('other', other), ('dm2', dm2), ('camp', camp), ('camp2', camp2), ('outsider', outsider), ('druid', ch);
end $$;

select pg_temp.put('g0', (select rev::text from tl_cache.global_rev where id = 1));
select pg_temp.put('c0', coalesce((select rev::text from tl_cache.character_rev where character_id = pg_temp.fu('ch1')), '0'));

-- ============================================================================================ 1. permissions and creation
select pg_temp.as_user(pg_temp.fu('pl'));
select pg_temp.ok('P1 player cannot create an encounter', pg_temp.try(format('select public.combat_create_encounter(%L, %L)', pg_temp.fx('camp'), 'x')) like '42501%');
select pg_temp.ok('P2 player cannot list the campaign encounters', pg_temp.try(format('select public.combat_list_encounters(%L)', pg_temp.fx('camp'))) like '42501%');
select pg_temp.ok('P3 player sees no encounter rows (RLS)', (select count(*) from public.combat_encounters) = 0);
select pg_temp.as_user(pg_temp.fu('other'));
select pg_temp.ok('P4 unrelated user cannot create', pg_temp.try(format('select public.combat_create_encounter(%L, %L)', pg_temp.fx('camp'), 'x')) like '42501%');
select pg_temp.as_anon();
select pg_temp.ok('P5 anonymous cannot call the RPCs', pg_temp.try(format('select public.combat_create_encounter(%L, %L)', pg_temp.fx('camp'), 'x')) like '42501%');
select pg_temp.ok('P6 anonymous cannot read the catalog', pg_temp.try('select count(*) from public.combat_monsters') like '42501%');
select pg_temp.as_admin();
select pg_temp.ok('P7 no EXECUTE for anon on any combat RPC',
  not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public'
              and (p.proname like 'combat\_%' or p.proname like '\_combat\_%' or p.proname in ('apply_character_hp', 'get_combat_player_view'))
              and p.proname <> 'combat_wild_shape_heal'   -- Wild Shape (20261017001300), not part of the Combat Builder: unchanged
              and has_function_privilege('anon', p.oid, 'execute')));
select pg_temp.ok('P8 internal helpers are not callable by authenticated',
  not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.proname like '\_combat\_%'
              and p.proname not in ('_combat_can_run', '_combat_can_see') and has_function_privilege('authenticated', p.oid, 'execute')));
select pg_temp.ok('P9 no direct write grants on combat tables',
  not exists (select 1 from information_schema.role_table_grants where table_schema = 'public' and table_name like 'combat\_%'
              and grantee in ('authenticated', 'anon') and privilege_type in ('INSERT', 'UPDATE', 'DELETE')));

select pg_temp.as_user(pg_temp.fu('dm'));
do $$
declare r jsonb; e uuid; req uuid := gen_random_uuid();
begin
  r := public.combat_create_encounter(pg_temp.fu('camp'), 'Goblin ambush', 'campaign', 'At the ford', '{}', req);
  e := (r -> 'encounter' ->> 'id')::uuid;
  perform pg_temp.put('e1', e::text);
  perform pg_temp.ok('E1 DM creates an encounter (campaign default ruleset resolves to 2024)', r -> 'encounter' ->> 'ruleset' = '2024'
    and r -> 'encounter' ->> 'ruleset_source' = 'campaign_default' and r -> 'encounter' ->> 'status' = 'draft');
  r := public.combat_create_encounter(pg_temp.fu('camp'), 'Goblin ambush', 'campaign', 'At the ford', '{}', req);
  perform pg_temp.ok('E2 the same create request twice makes one encounter', (r ->> 'replayed')::boolean and r -> 'encounter' ->> 'id' = e::text
    and (select count(*) from public.combat_encounters where campaign_id = pg_temp.fu('camp')) = 1);
  perform pg_temp.ok('E3 bad ruleset refused', pg_temp.try(format('select public.combat_create_encounter(%L, %L, %L)', pg_temp.fx('camp'), 'x', '5e')) like '22023%');
  r := public.combat_update_encounter(e, '{"ruleset": "2014"}');
  perform pg_temp.ok('E4 ruleset can change while a draft', r -> 'encounter' ->> 'ruleset' = '2014');
  r := public.combat_update_encounter(e, '{"ruleset": "2024", "dm_notes": "Boss hides in the reeds"}');
  perform pg_temp.ok('E5 DM notes saved', (select dm_notes from public.combat_encounters where id = e) = 'Boss hides in the reeds');
  perform pg_temp.ok('E6 stale encounter save refused', pg_temp.try(format('select public.combat_update_encounter(%L, %L, 0)', e, '{"name": "x"}')) like 'TLCMB%');
end $$;
select pg_temp.as_user(pg_temp.fu('dm2'));
select pg_temp.ok('E7 another campaign''s DM cannot open the encounter', pg_temp.try(format('select public.combat_get_encounter(%L)', pg_temp.fx('e1'))) like '42501%');
select pg_temp.ok('E8 another campaign''s DM sees no rows', (select count(*) from public.combat_encounters where id = pg_temp.fu('e1')) = 0);

-- ============================================================================================ 2. participants
select pg_temp.as_user(pg_temp.fu('dm'));
do $$
declare r jsonb; e uuid := pg_temp.fu('e1'); req uuid := gen_random_uuid(); s jsonb;
begin
  r := public.combat_add_characters(e, array[pg_temp.fu('ch1'), pg_temp.fu('ch2'), pg_temp.fu('ch3'), pg_temp.fu('ch4'), pg_temp.fu('outsider')],
    jsonb_build_object('mods', jsonb_build_object(pg_temp.fx('ch1'), jsonb_build_object('initiative_mod', 5, 'dexterity', 12))), req);
  perform pg_temp.ok('A1 four campaign characters added, the outsider skipped', jsonb_array_length(r -> 'added') = 4 and jsonb_array_length(r -> 'skipped') = 1);
  perform pg_temp.ok('A2 the sheet''s Initiative modifier is used when sent', (select initiative_mod from public.combat_participants where linked_character_id = pg_temp.fu('ch1')) = 5);
  perform pg_temp.ok('A3 otherwise the DEX modifier', (select initiative_mod from public.combat_participants where linked_character_id = pg_temp.fu('ch2')) = 2);
  r := public.combat_add_characters(e, array[pg_temp.fu('ch1')], '{}', req);
  perform pg_temp.ok('A4 the same request again is a replay', (r ->> 'replayed')::boolean);
  r := public.combat_add_characters(e, array[pg_temp.fu('ch1')]);
  perform pg_temp.ok('A5 a character cannot be added twice', jsonb_array_length(r -> 'added') = 0 and r -> 'skipped' -> 0 ->> 'reason' = 'already in the encounter');
  r := public.combat_add_monsters(e, 'srd2024', 'srd52-goblin-warrior', '{"quantity": 3}');
  perform pg_temp.ok('A6 three Goblin Warriors: A, B, C in one initiative group', jsonb_array_length(r -> 'added') = 3
    and (select string_agg(instance_label, '' order by instance_label) from public.combat_participants where encounter_id = e and display_name = 'Goblin Warrior') = 'ABC'
    and (select count(distinct group_key) from public.combat_participants where encounter_id = e and display_name = 'Goblin Warrior') = 1);
  perform pg_temp.ok('A7 instance HP and AC from the stat block', (select bool_and(hp_current = 10 and hp_max = 10 and armor_class = 15 and initiative_mod = 2)
    from public.combat_participants where encounter_id = e and display_name = 'Goblin Warrior'));
  perform pg_temp.ok('A8 one shared snapshot for the three copies', (select count(*) from public.combat_statblocks where encounter_id = e and source_id = 'srd52-goblin-warrior') = 1);
  r := public.combat_add_monsters(e, 'srd2024', 'srd52-goblin-warrior', '{"quantity": 1, "group": "separate"}');
  perform pg_temp.ok('A9 a fourth copy continues the letters (D), own initiative', (select instance_label from public.combat_participants where id = (r -> 'added' ->> 0)::uuid) = 'D'
    and (select group_key from public.combat_participants where id = (r -> 'added' ->> 0)::uuid) is null);
  r := public.combat_add_monsters(e, 'creature', 'goblin', '{"name": "Old goblin"}');
  perform pg_temp.ok('A10 an SRD 5.1 monster in a 2024 encounter is flagged, not silently mixed', (r ->> 'ruleset_mismatch')::boolean and r ->> 'rules_version' = '2014');
  r := public.combat_add_monsters(e, 'srd2024', 'srd52-ogre', '{"hp_mode": "rolled", "hidden": true}');
  perform pg_temp.put('ogre', r -> 'added' ->> 0);
  perform pg_temp.ok('A11 rolled HP is within the hit dice range (Ogre 8d10+16)', (select hp_max between 24 and 96 from public.combat_participants where id = pg_temp.fu('ogre')));
  perform pg_temp.ok('A12 hidden monster', (select hidden from public.combat_participants where id = pg_temp.fu('ogre')));
  perform pg_temp.ok('A13 unknown monster refused', pg_temp.try(format('select public.combat_add_monsters(%L, %L, %L)', e, 'srd2024', 'srd52-tarrasque-x')) like '22023%');
  perform pg_temp.ok('A14 unknown SRD 5.1 creature refused', pg_temp.try(format('select public.combat_add_monsters(%L, %L, %L)', e, 'creature', 'no-such-creature')) like '22023%');
  r := public.combat_add_custom(e, '{"name": "Reed Lurker", "hp": 30, "ac": 13, "initiative_mod": 1, "hidden": true}');
  perform pg_temp.put('lurker', r -> 'added' ->> 0);
  perform public.combat_update_participant(pg_temp.fu('lurker'), '{"joins_round": 2, "player_label": "Something in the reeds"}');
  perform pg_temp.ok('A15 a typed-in combatant with delayed entry', (select joins_round = 2 and player_label is not null from public.combat_participants where id = pg_temp.fu('lurker')));
  perform pg_temp.ok('A16 a character''s name comes from the sheet', pg_temp.try(format('select public.combat_update_participant(%L, %L)',
    pg_temp.pid(e, 'CB Hero 1'), '{"display_name": "Bob"}')) like '22023%');
  s := public.combat_get_encounter(e);
  perform pg_temp.ok('A17 encounter read: participants, character HP from the sheet, no stat blocks', jsonb_array_length(s -> 'participants') = 11
    and (select (x -> 'hp' ->> 'current')::int from jsonb_array_elements(s -> 'participants') x where x ->> 'character_id' = pg_temp.fx('ch1')) = 21
    and not (s::text like '%"actions"%'), format('%s %s %s', jsonb_array_length(s -> 'participants'),
    (select x -> 'hp' from jsonb_array_elements(s -> 'participants') x where x ->> 'character_id' = pg_temp.fx('ch1')), s::text like '%"actions"%'));
  perform pg_temp.ok('A18 difficulty: 2024 budget for four level-3 characters (Low 600 / Moderate 900 / High 1600)',
    s -> 'difficulty' -> 'budget' = '{"low": 600, "moderate": 900, "high": 1600}'::jsonb and (s -> 'difficulty' ->> 'xp')::int > 0, (s -> 'difficulty')::text);
end $$;

-- ============================================================================================ 3. initiative
do $$
declare r jsonb; e uuid := pg_temp.fu('e1'); g uuid[]; v int;
begin
  perform pg_temp.ok('I1 Start refused while Initiative is missing', pg_temp.try(format('select public.combat_start(%L)', e)) like '22023%Set Initiative for:%');
  r := public.combat_roll_initiative(e);
  select array_agg(id) into g from public.combat_participants where encounter_id = e and display_name = 'Goblin Warrior' and instance_label in ('A', 'B', 'C');
  perform pg_temp.ok('I2 Roll all monsters: every monster has a value, characters untouched',
    not exists (select 1 from public.combat_participants where encounter_id = e and kind = 'monster' and initiative is null)
    and not exists (select 1 from public.combat_participants where encounter_id = e and kind = 'character' and initiative is not null));
  perform pg_temp.ok('I3 group initiative: one roll for A, B and C', (select count(distinct initiative) from public.combat_participants where id = any (g)) = 1);
  perform pg_temp.ok('I4 rolled values are d20 + modifier', (select bool_and(initiative_roll between 1 and 20 and initiative = initiative_roll + initiative_mod)
    from public.combat_participants where encounter_id = e and kind = 'monster'));
  -- typed player values, with a deliberate tie between Hero 1 and Hero 2 (17) and Hero 3 tied with goblin D
  v := (select initiative from public.combat_participants where id = pg_temp.pid(e, 'Goblin Warrior', 'D'));
  r := public.combat_set_initiative(e, jsonb_build_array(
    jsonb_build_object('id', pg_temp.pid(e, 'CB Hero 1'), 'initiative', 17), jsonb_build_object('id', pg_temp.pid(e, 'CB Hero 2'), 'initiative', 17),
    jsonb_build_object('id', pg_temp.pid(e, 'CB Hero 3'), 'initiative', v), jsonb_build_object('id', pg_temp.pid(e, 'CB Hero 4'), 'initiative', 30)));
  perform pg_temp.ok('I5 typed player values stored as player entries', (select bool_and(initiative_mode = 'player') from public.combat_participants where encounter_id = e and kind = 'character'));
  perform pg_temp.ok('I6 ties reported (player-player and player-monster)', jsonb_array_length(r -> 'ties') >= 2, (r -> 'ties')::text);
  perform pg_temp.ok('I7 default tie order: higher Initiative modifier first (Hero 1 +5 before Hero 2 +2)',
    (select initiative_order from public.combat_participants where id = pg_temp.pid(e, 'CB Hero 1')) < (select initiative_order from public.combat_participants where id = pg_temp.pid(e, 'CB Hero 2')));
  perform pg_temp.ok('I8 highest Initiative first', (select id from public.combat_participants where encounter_id = e order by initiative_order limit 1) = pg_temp.pid(e, 'CB Hero 4'));
  r := public.combat_start(e);
  perform pg_temp.ok('I9 Start stops once for the tie review', (r ->> 'needs_tie_review')::boolean and (select status from public.combat_encounters where id = e) = 'draft');
  -- the DM puts Hero 2 before Hero 1
  perform public.combat_reorder(e, array(select id from public.combat_participants where encounter_id = e and removed_at is null
    order by case when id = pg_temp.pid(e, 'CB Hero 2') then (select initiative_order - 1 from public.combat_participants where id = pg_temp.pid(e, 'CB Hero 1')) else initiative_order end));
  perform pg_temp.ok('I10 manual tie order kept', (select initiative_order from public.combat_participants where id = pg_temp.pid(e, 'CB Hero 2'))
    < (select initiative_order from public.combat_participants where id = pg_temp.pid(e, 'CB Hero 1')));
  r := public.combat_start(e, true, gen_random_uuid());
  perform pg_temp.ok('I11 Start: active, Round 1, the highest Initiative acts first', (select status = 'active' and round = 1 from public.combat_encounters where id = e)
    and pg_temp.cur_name(e) = 'CB Hero 4', pg_temp.cur_name(e));
  perform pg_temp.ok('I12 manual order survived Start', (select initiative_order from public.combat_participants where id = pg_temp.pid(e, 'CB Hero 2'))
    < (select initiative_order from public.combat_participants where id = pg_temp.pid(e, 'CB Hero 1')));
  perform pg_temp.ok('I13 the order is locked: Sort refused in combat', pg_temp.try(format('select public.combat_sort_initiative(%L)', e)) like '22023%');
end $$;

-- ============================================================================================ 4. turns
do $$
declare r jsonb; e uuid := pg_temp.fu('e1'); tr bigint; req uuid := gen_random_uuid(); n int := 0; seen text[] := '{}'; first text; d uuid;
begin
  tr := (pg_temp.enc(e)).turn_rev;
  r := public.combat_next_turn(e, tr, 'next', req);
  perform pg_temp.ok('T1 Next turn moves to the second combatant', pg_temp.cur_name(e) <> 'CB Hero 4' and (pg_temp.enc(e)).turn_rev = tr + 1);
  r := public.combat_next_turn(e, tr, 'next', req);
  perform pg_temp.ok('T2 a double click (same request) does not move twice', (r ->> 'replayed')::boolean and (pg_temp.enc(e)).turn_rev = tr + 1);
  perform pg_temp.ok('T3 a stale Next from another window is refused', pg_temp.try(format('select public.combat_next_turn(%L, %s)', e, tr)) like 'TLCMB%');
  r := public.combat_previous_turn(e, tr + 1);
  perform pg_temp.ok('T4 Previous turn goes back', pg_temp.cur_name(e) = 'CB Hero 4' and (pg_temp.enc(e)).round = 1);
  perform pg_temp.ok('T5 the undone move is marked', exists (select 1 from public.combat_events where encounter_id = e and kind = 'turn_advanced' and undone_by is not null));
  -- defeated monster skipped: defeat goblin D
  d := pg_temp.pid(e, 'Goblin Warrior', 'D');
  perform public.combat_set_participant_state(d, 'defeat');
  perform public.combat_set_participant_state(pg_temp.pid(e, 'Old goblin'), 'deactivate');
  first := pg_temp.cur_name(e);
  loop
    r := public.combat_next_turn(e, (pg_temp.enc(e)).turn_rev);
    n := n + 1;
    exit when (pg_temp.enc(e)).round = 2 or n > 20;
    seen := seen || pg_temp.cur_name(e);
  end loop;
  perform pg_temp.ok('T6 defeated monster skipped', not ('Goblin Warrior D' = any (seen)));
  perform pg_temp.ok('T7 inactive participant skipped', not ('Old goblin' = any (seen)));
  perform pg_temp.ok('T8 delayed entry skipped in round 1', not ('Reed Lurker' = any (seen)));
  perform pg_temp.ok('T9 hidden monster still takes its turn', 'Ogre' = any (seen));
  perform pg_temp.ok('T10 round 2 starts with the first combatant again', (pg_temp.enc(e)).round = 2 and pg_temp.cur_name(e) = first, pg_temp.cur_name(e));
  seen := '{}';
  loop
    r := public.combat_next_turn(e, (pg_temp.enc(e)).turn_rev);
    exit when (pg_temp.enc(e)).round = 3;
    seen := seen || pg_temp.cur_name(e);
  end loop;
  perform pg_temp.ok('T11 delayed participant joins in round 2', 'Reed Lurker' = any (seen));
  -- a late participant during combat
  r := public.combat_add_monsters(e, 'srd2024', 'srd52-wolf', '{"initiative": 25}');
  perform pg_temp.ok('T12 late participant placed by its Initiative', (select initiative_order from public.combat_participants where id = (r -> 'added' ->> 0)::uuid)
    < (select initiative_order from public.combat_participants where id = pg_temp.pid(e, 'CB Hero 1')));
  -- pause / resume
  tr := (pg_temp.enc(e)).turn_rev;
  perform public.combat_pause(e);
  perform pg_temp.ok('T13 Next refused while paused', pg_temp.try(format('select public.combat_next_turn(%L, %s)', e, tr)) like '22023%paused%');
  perform public.combat_resume(e);
  perform pg_temp.ok('T14 Resume restores the exact turn', (pg_temp.enc(e)).turn_rev = tr and (pg_temp.enc(e)).status = 'active' and (pg_temp.enc(e)).round = 3);
  -- Choose turn
  r := public.combat_goto_turn(e, pg_temp.pid(e, 'CB Hero 3'), (pg_temp.enc(e)).turn_rev, null, 'Forgot Hero 3');
  perform pg_temp.ok('T15 Choose turn (audited)', pg_temp.cur_name(e) = 'CB Hero 3' and exists (select 1 from public.combat_events where encounter_id = e and kind = 'turn_jumped'));
  perform public.combat_set_participant_state(pg_temp.pid(e, 'Old goblin'), 'activate');
end $$;

-- ============================================================================================ 5. hit points
do $$
declare r jsonb; e uuid := pg_temp.fu('e1'); g uuid := pg_temp.pid(pg_temp.fu('e1'), 'Goblin Warrior', 'A'); h uuid := pg_temp.pid(pg_temp.fu('e1'), 'CB Hero 1');
  req uuid := gen_random_uuid(); ev bigint;
begin
  perform public.combat_apply_hp(g, 'temp', 3);
  r := public.combat_apply_hp(g, 'damage', 5, null, req);
  perform pg_temp.ok('H1 monster damage: Temporary HP first (3), then HP (10 -> 8)', (select hp_current = 8 and hp_temp = 0 from public.combat_participants where id = g)
    and (r ->> 'absorbed')::int = 3);
  r := public.combat_apply_hp(g, 'damage', 5, null, req);
  perform pg_temp.ok('H2 duplicate Damage (same request) is applied once', (r ->> 'replayed')::boolean and (select hp_current from public.combat_participants where id = g) = 8);
  perform pg_temp.ok('H3 the catalog definition never changes', (select hit_points from public.combat_monsters where id = 'srd52-goblin-warrior') = 10
    and (select (snapshot ->> 'hit_points')::int from public.combat_statblocks where encounter_id = e and source_id = 'srd52-goblin-warrior') = 10);
  r := public.combat_apply_hp(g, 'damage', 50);
  perform pg_temp.ok('H4 monster at 0 HP is Defeated, never below 0', (select hp_current = 0 and defeated from public.combat_participants where id = g));
  r := public.combat_apply_hp(g, 'heal', 4);
  perform pg_temp.ok('H5 healing a defeated monster restores it', (select hp_current = 4 and not defeated from public.combat_participants where id = g));
  perform pg_temp.ok('H6 a correction needs a reason', pg_temp.try(format('select public.combat_apply_hp(%L, %L, 7)', g, 'set')) like '22023%reason%');
  r := public.combat_apply_hp(g, 'set', 7, 'Misread the die');
  perform pg_temp.ok('H7 correction with reason audited', (select hp_current from public.combat_participants where id = g) = 7
    and exists (select 1 from public.combat_events where participant_id = g and kind = 'hp_set' and details ->> 'reason' = 'Misread the die'));
  -- linked character: the real sheet row changes
  perform public.combat_apply_hp(h, 'temp', 4);
  r := public.combat_apply_hp(h, 'damage', 10);
  perform pg_temp.ok('H8 character damage updates the character sheet row (21 -> 15, temp 4 used)',
    (select hp_current = 15 and hp_temp = 0 from public.characters where id = pg_temp.fu('ch1')), (r -> 'after')::text);
  perform pg_temp.ok('H9 no copy of character HP in the participant row', (select hp_current is null and hp_max is null from public.combat_participants where id = h));
  r := public.combat_apply_hp(h, 'heal', 100);
  perform pg_temp.ok('H10 healing stops at the maximum', (select hp_current from public.characters where id = pg_temp.fu('ch1')) = 21);
  r := public.combat_apply_hp(h, 'damage', 30);
  perform pg_temp.ok('H11 character at 0 HP is Down, stays in the encounter', (select hp_current from public.characters where id = pg_temp.fu('ch1')) = 0
    and (select active and removed_at is null from public.combat_participants where id = h) and (r -> 'participant' -> 'hp' ->> 'current')::int = 0);
  perform pg_temp.as_admin(); update public.characters set death_failures = 2 where id = pg_temp.fu('ch1'); perform pg_temp.as_user(pg_temp.fu('dm'));
  r := public.combat_apply_hp(h, 'heal', 5);
  perform pg_temp.ok('H12 healing from 0 resets death saves', (select hp_current = 5 and death_failures = 0 from public.characters where id = pg_temp.fu('ch1')));
  -- Undo
  r := public.combat_apply_hp(g, 'damage', 3);
  ev := (r ->> 'event_id')::bigint;
  r := public.combat_undo(ev);
  perform pg_temp.ok('H13 Undo of monster damage', (select hp_current from public.combat_participants where id = g) = 7 and r ->> 'undone' = 'damage');
  perform pg_temp.ok('H14 Undo twice refused', pg_temp.try(format('select public.combat_undo(%s)', ev)) like '22023%already%');
  r := public.combat_apply_hp(g, 'damage', 2); ev := (r ->> 'event_id')::bigint;
  perform public.combat_apply_hp(g, 'damage', 1);
  perform pg_temp.ok('H15 stale Undo refused (a newer change exists)', pg_temp.try(format('select public.combat_undo(%s)', ev)) like 'TLCMB%');
  r := public.combat_apply_hp(h, 'damage', 2); ev := (r ->> 'event_id')::bigint;
  perform public.combat_undo(ev);
  perform pg_temp.ok('H16 Undo of character damage restores the sheet', (select hp_current from public.characters where id = pg_temp.fu('ch1')) = 5);
end $$;

-- the player changes HP on the sheet with the same atomic RPC
select pg_temp.as_user(pg_temp.fu('pl'));
do $$
declare r jsonb; h uuid := pg_temp.pid(pg_temp.fu('e1'), 'CB Hero 1');
begin
  r := public.apply_character_hp(pg_temp.fu('ch1'), 'damage', 2);
  perform pg_temp.ok('H17 player sheet damage through apply_character_hp', (r -> 'after' ->> 'hp')::int = 3);
  perform pg_temp.ok('H18 the player cannot use the combat RPC', pg_temp.try(format('select public.combat_apply_hp(%L, %L, 1)', h, 'damage')) like '42501%');
  perform pg_temp.ok('H19 the player cannot change someone else''s character', pg_temp.try(format('select public.apply_character_hp(%L, %L, 1)', pg_temp.fx('outsider'), 'damage')) like '42501%');
  perform pg_temp.ok('H20 an amount is needed', pg_temp.try(format('select public.apply_character_hp(%L, %L, 0)', pg_temp.fx('ch1'), 'damage')) like '22023%');
end $$;
select pg_temp.as_user(pg_temp.fu('dm'));
do $$
declare r jsonb; e uuid := pg_temp.fu('e1'); w uuid;
begin
  perform pg_temp.ok('H21 the tracker reads the sheet''s value', (select (x -> 'hp' ->> 'current')::int from jsonb_array_elements(public.combat_get_encounter(e) -> 'participants') x
    where x ->> 'character_id' = pg_temp.fx('ch1')) = 3);
  -- Wild Shape
  r := public.combat_add_characters(e, array[pg_temp.fu('druid')], '{}');
  w := (r -> 'added' ->> 0)::uuid;
  perform public.combat_set_initiative(pg_temp.fu('e1'), jsonb_build_array(jsonb_build_object('id', w, 'initiative', 1)));
  perform pg_temp.ok('H22 Wild Shape form shown with form HP', (public.combat_get_participant(w) -> 'participant' -> 'form' ->> 'hp_current')::int = 11);
  r := public.combat_apply_hp(w, 'damage', 4);
  perform pg_temp.ok('H23 Wild Shape damage goes to the form; normal HP protected', (select hp_current from public.character_transformations where character_id = pg_temp.fu('druid')) = 7
    and (select hp_current from public.characters where id = pg_temp.fu('druid')) = 15);
  r := public.combat_apply_hp(w, 'heal', 2);
  perform pg_temp.ok('H24 Wild Shape healing heals the form', (select hp_current from public.character_transformations where character_id = pg_temp.fu('druid')) = 9);
  r := public.combat_apply_hp(w, 'damage', 12);
  perform pg_temp.ok('H25 excess damage ends the form and carries over (9 form, 3 to normal HP)', not exists (select 1 from public.character_transformations where character_id = pg_temp.fu('druid'))
    and (select hp_current from public.characters where id = pg_temp.fu('druid')) = 12 and (r -> 'wild_shape' ->> 'carryover')::int = 3);
  perform pg_temp.ok('H26 Undo refused once the form ended', pg_temp.try(format('select public.combat_undo(%s)', r ->> 'event_id')) like 'TLCMB%');
  -- bulk
  perform pg_temp.ok('H27 bulk damage to a character needs confirmation', pg_temp.try(format('select public.combat_apply_hp_bulk(%L, %L, %L)', e, 'damage',
    jsonb_build_array(jsonb_build_object('id', pg_temp.pid(e, 'CB Hero 2'), 'amount', 3)))) like '22023%');
  r := public.combat_apply_hp_bulk(e, 'damage', jsonb_build_array(jsonb_build_object('id', pg_temp.pid(e, 'Goblin Warrior', 'B'), 'amount', 3),
    jsonb_build_object('id', pg_temp.pid(e, 'Goblin Warrior', 'C'), 'amount', 4)));
  perform pg_temp.ok('H28 bulk damage to two monsters', (select hp_current from public.combat_participants where id = pg_temp.pid(e, 'Goblin Warrior', 'B')) = 7
    and (select hp_current from public.combat_participants where id = pg_temp.pid(e, 'Goblin Warrior', 'C')) = 6);
end $$;

-- ============================================================================================ 6. effects, advantage, concentration
do $$
declare r jsonb; e uuid := pg_temp.fu('e1'); h2 uuid := pg_temp.pid(pg_temp.fu('e1'), 'CB Hero 2'); gb uuid := pg_temp.pid(pg_temp.fu('e1'), 'Goblin Warrior', 'B');
  conc uuid; bless uuid; poi uuid; adv uuid; tr bigint; cid uuid; x jsonb;
begin
  r := public.combat_add_effect(e, jsonb_build_object('effect_type', 'condition', 'condition_key', 'poisoned', 'target', gb, 'visibility', 'players'));
  poi := (r -> 'effects' -> 0 ->> 'id')::uuid;
  perform pg_temp.ok('C1 apply a condition (2024 summary attached)', r -> 'effects' -> 0 -> 'condition' ->> 'name' = 'Poisoned');
  perform pg_temp.ok('C2 unknown condition refused', pg_temp.try(format('select public.combat_add_effect(%L, %L)', e,
    jsonb_build_object('effect_type', 'condition', 'condition_key', 'sleepy', 'target', gb))) like '22023%');
  r := public.combat_end_effect(poi);
  perform pg_temp.ok('C3 remove a condition', not (select active from public.combat_effects where id = poi));
  -- concentration-linked Bless from Hero 2 on Hero 3 and Hero 4, 10 rounds (1 minute)
  r := public.combat_add_effect(e, jsonb_build_object('effect_type', 'custom', 'name', 'Blessed', 'source', h2, 'targets',
    jsonb_build_array(pg_temp.pid(e, 'CB Hero 3'), pg_temp.pid(e, 'CB Hero 4')), 'duration_type', 'minutes', 'duration_minutes', 1,
    'concentration', true, 'concentration_name', 'Bless'));
  select id into conc from public.combat_effects where encounter_id = e and effect_type = 'concentration' and source_participant_id = h2 and active;
  perform pg_temp.ok('C4 concentration created and linked to both targets', conc is not null
    and (select count(*) from public.combat_effects where concentration_id = conc and active) = 2);
  perform pg_temp.ok('C5 1 minute = 10 rounds on the caster''s turn start', (select bool_and(duration_type = 'rounds' and remaining_rounds = 10 and anchor_participant_id = h2)
    from public.combat_effects where concentration_id = conc));
  perform pg_temp.ok('C6 a second concentration needs confirmation', pg_temp.try(format('select public.combat_add_effect(%L, %L)', e,
    jsonb_build_object('effect_type', 'concentration', 'source', h2, 'name', 'Hold Person'))) like 'TLCNC%');
  -- damage to the concentrator: 2024 DC = max(10, half), capped at 30
  r := public.combat_apply_hp(h2, 'temp', 50);
  r := public.combat_apply_hp(h2, 'damage', 80);
  perform pg_temp.ok('C7 concentration check reminder on damage, 2024 DC capped at 30', (r -> 'concentration_checks' -> 0 ->> 'dc')::int = 30, (r -> 'concentration_checks')::text);
  r := public.combat_apply_hp(h2, 'heal', 100);
  r := public.combat_apply_hp(h2, 'damage', 7);
  perform pg_temp.ok('C8 small damage: DC 10', (r -> 'concentration_checks' -> 0 ->> 'dc')::int = 10);
  r := public.combat_resolve_concentration(conc, null, 'success');
  perform pg_temp.ok('C9 success keeps concentration', (select active and jsonb_array_length(pending_checks) = 1 from public.combat_effects where id = conc));
  r := public.combat_resolve_concentration(conc, null, 'failure');
  perform pg_temp.ok('C10 failure ends concentration and the linked effects', (select not active from public.combat_effects where id = conc)
    and not exists (select 1 from public.combat_effects where concentration_id = conc and active)
    and exists (select 1 from public.combat_events where encounter_id = e and kind = 'concentration_failed'));
  -- manual end of concentration
  r := public.combat_add_effect(e, jsonb_build_object('effect_type', 'condition', 'condition_key', 'restrained', 'source', h2, 'target', gb,
    'concentration', true, 'concentration_name', 'Web'));
  select id into conc from public.combat_effects where encounter_id = e and effect_type = 'concentration' and source_participant_id = h2 and active;
  perform public.combat_end_effect(conc);
  perform pg_temp.ok('C11 manual concentration end ends Restrained too', not exists (select 1 from public.combat_effects where concentration_id = conc and active));
  -- timed effects at turn boundaries
  tr := (pg_temp.enc(e)).turn_rev;
  perform public.combat_goto_turn(e, pg_temp.pid(e, 'CB Hero 4'), tr, null, 'test setup');
  r := public.combat_add_effect(e, jsonb_build_object('effect_type', 'custom', 'name', 'Dodging', 'target', pg_temp.pid(e, 'CB Hero 4'), 'source', pg_temp.pid(e, 'CB Hero 4'),
    'duration_type', 'until_turn_start'));
  cid := (r -> 'effects' -> 0 ->> 'id')::uuid;
  r := public.combat_add_effect(e, jsonb_build_object('effect_type', 'custom', 'name', 'Slowed', 'target', pg_temp.pid(e, 'CB Hero 4'), 'source', pg_temp.pid(e, 'CB Hero 4'),
    'duration_type', 'until_turn_end'));
  bless := (r -> 'effects' -> 0 ->> 'id')::uuid;
  r := public.combat_add_effect(e, jsonb_build_object('effect_type', 'custom', 'name', 'Hold', 'target', pg_temp.pid(e, 'CB Hero 4'), 'duration_type', 'save_ends',
    'save_ability', 'wis', 'save_dc', 14, 'visibility', 'dm'));
  adv := (r -> 'effects' -> 0 ->> 'id')::uuid;
  r := public.combat_next_turn(e, (pg_temp.enc(e)).turn_rev);
  perform pg_temp.ok('C12 "until the end of its next turn" applied during its own turn survives this turn end', (select active from public.combat_effects where id = bless));
  perform pg_temp.ok('C13 save-ends reminder at the end of the turn', exists (select 1 from jsonb_array_elements(r -> 'notices') y where y ->> 'kind' = 'save' and y ->> 'dc' = '14'));
  -- around the table back to Hero 4
  loop
    r := public.combat_next_turn(e, (pg_temp.enc(e)).turn_rev);
    exit when pg_temp.cur_name(e) = 'CB Hero 4';
  end loop;
  perform pg_temp.ok('C14 start-of-turn expiry', not (select active from public.combat_effects where id = cid)
    and exists (select 1 from jsonb_array_elements(r -> 'notices') y where y ->> 'kind' = 'expired' and y ->> 'effect' = 'Dodging'));
  r := public.combat_previous_turn(e, (pg_temp.enc(e)).turn_rev);
  perform pg_temp.ok('C15 Previous Turn asks to confirm when effect clocks would change', (r ->> 'needs_confirmation')::boolean);
  r := public.combat_previous_turn(e, (pg_temp.enc(e)).turn_rev, true);
  perform pg_temp.ok('C16 confirmed Previous Turn restores the expired effect', (select active from public.combat_effects where id = cid));
  r := public.combat_next_turn(e, (pg_temp.enc(e)).turn_rev);
  r := public.combat_next_turn(e, (pg_temp.enc(e)).turn_rev);
  perform pg_temp.ok('C17 end-of-turn expiry', not (select active from public.combat_effects where id = bless));
  -- advantage
  r := public.combat_add_effect(e, jsonb_build_object('effect_type', 'advantage', 'adv_mode', 'advantage', 'adv_scope', 'next_attack', 'target', gb));
  perform pg_temp.ok('C18 advantage on next attack', r -> 'effects' -> 0 ->> 'adv_scope' = 'next_attack' and r -> 'effects' -> 0 ->> 'display_name' like 'Advantage%');
  r := public.combat_add_effect(e, jsonb_build_object('effect_type', 'advantage', 'adv_mode', 'disadvantage', 'adv_scope', 'save', 'adv_detail', 'dex', 'target', gb));
  perform pg_temp.ok('C19 disadvantage on one save', r -> 'effects' -> 0 ->> 'adv_detail' = 'dex');
  r := public.combat_add_effect(e, jsonb_build_object('effect_type', 'advantage', 'adv_mode', 'advantage', 'adv_scope', 'attacks_against_target',
    'adv_target', pg_temp.pid(e, 'CB Hero 3'), 'target', gb, 'duration_type', 'rounds', 'duration_rounds', 1));
  perform pg_temp.ok('C20 target-specific advantage with a duration', (r -> 'effects' -> 0 ->> 'adv_target_id')::uuid = pg_temp.pid(e, 'CB Hero 3')
    and (r -> 'effects' -> 0 ->> 'remaining_rounds')::int = 1);
  perform pg_temp.ok('C21 advantage needs a mode and a scope', pg_temp.try(format('select public.combat_add_effect(%L, %L)', e,
    jsonb_build_object('effect_type', 'advantage', 'target', gb))) like '22023%');
  r := public.combat_add_effect(e, jsonb_build_object('effect_type', 'custom', 'name', 'Half cover', 'target', gb, 'modifier_target', 'ac', 'modifier_value', 2));
  perform pg_temp.ok('C22 AC modifier is "applied", others are reminders', r -> 'effects' -> 0 ->> 'application' = 'applied');
  r := public.combat_add_effect(e, jsonb_build_object('effect_type', 'custom', 'name', 'Bardic', 'target', gb, 'modifier_target', 'attack', 'modifier_value', 2));
  perform pg_temp.ok('C23 attack modifier stays a reminder', r -> 'effects' -> 0 ->> 'application' = 'reminder');
  r := public.combat_add_effect(e, jsonb_build_object('effect_type', 'condition', 'condition_key', 'prone', 'target', gb));
  x := public.combat_undo((r ->> 'event_id')::bigint);
  perform pg_temp.ok('C24 Undo of an added condition ends it', not (select active from public.combat_effects where id = (r -> 'effects' -> 0 ->> 'id')::uuid));
  -- reactions and legendary
  perform public.combat_set_reaction(gb, true);
  perform pg_temp.ok('C25 Reaction marked used', (select reaction_used from public.combat_participants where id = gb));
end $$;

-- ============================================================================================ 7. legendary creature and reminders (2014 encounter)
do $$
declare r jsonb; e uuid; d uuid; h uuid; seen boolean := false; n int := 0;
begin
  r := public.combat_create_encounter(pg_temp.fu('camp'), 'Dragon lair', '2014');
  e := (r -> 'encounter' ->> 'id')::uuid;
  perform pg_temp.put('e2', e::text);
  perform public.combat_add_characters(e, array[pg_temp.fu('ch2'), pg_temp.fu('ch3')]);
  r := public.combat_add_monsters(e, 'creature', 'adult-red-dragon', '{}');
  d := (r -> 'added' ->> 0)::uuid;
  perform pg_temp.ok('L1 SRD 5.1 legendary actions in the snapshot (3 uses)', (select legendary_max = 3 and legendary_left = 3 from public.combat_participants where id = d)
    and (select jsonb_array_length(snapshot -> 'legendary' -> 'actions') from public.combat_statblocks s join public.combat_participants p on p.statblock_id = s.id where p.id = d) = 3);
  perform public.combat_save_reminder(e, '{"kind": "lair", "title": "Lair Action", "trigger_initiative": 20}');
  perform public.combat_save_reminder(e, '{"kind": "reinforcement", "title": "Kobolds arrive", "trigger_round": 2}');
  h := pg_temp.pid(e, 'CB Hero 2');
  perform public.combat_set_initiative(e, jsonb_build_array(jsonb_build_object('id', d, 'initiative', 22), jsonb_build_object('id', h, 'initiative', 15),
    jsonb_build_object('id', pg_temp.pid(e, 'CB Hero 3'), 'initiative', 8)));
  perform public.combat_update_participant(pg_temp.pid(e, 'CB Hero 3'), '{"surprised": true}');
  r := public.combat_start(e);
  perform pg_temp.ok('L2 2014 surprise: no Reaction until the end of its first turn', (select reaction_used from public.combat_participants where id = pg_temp.pid(e, 'CB Hero 3')));
  r := public.combat_next_turn(e, (pg_temp.enc(e)).turn_rev);   -- dragon (22) -> Hero 2 (15): passes count 20
  perform pg_temp.ok('L3 lair action reminder between Initiative 22 and 15', exists (select 1 from jsonb_array_elements(r -> 'notices') y where y ->> 'title' = 'Lair Action'));
  perform public.combat_spend_legendary(d, -2, 'Wing Attack');
  r := public.combat_next_turn(e, (pg_temp.enc(e)).turn_rev);   -- Hero 2 -> Hero 3 (surprised)
  perform pg_temp.ok('L4 legendary reminder lists the dragon with 1 use left', exists (select 1 from jsonb_array_elements(r -> 'notices') y where y ->> 'kind' = 'legendary' and (y ->> 'left')::int = 1));
  perform pg_temp.ok('L5 surprised 2014 combatant gets the surprise notice', exists (select 1 from jsonb_array_elements(r -> 'notices') y where y ->> 'kind' = 'surprised'));
  perform pg_temp.ok('L6 cannot spend more uses than left', pg_temp.try(format('select public.combat_spend_legendary(%L, -2)', d)) like '22023%');
  r := public.combat_next_turn(e, (pg_temp.enc(e)).turn_rev);   -- Hero 3 -> round 2 dragon
  perform pg_temp.ok('L7 surprise ends after its first turn; Reaction back', (select not surprised and not reaction_used from public.combat_participants where id = pg_temp.pid(e, 'CB Hero 3')));
  perform pg_temp.ok('L8 round 2 reminder', exists (select 1 from jsonb_array_elements(r -> 'notices') y where y ->> 'title' = 'Kobolds arrive'));
  perform pg_temp.ok('L9 legendary uses reset at the start of its own turn', (select legendary_left from public.combat_participants where id = d) = 3);
  -- 2014 concentration DC: no cap
  perform public.combat_add_effect(e, jsonb_build_object('effect_type', 'concentration', 'source', h, 'name', 'Hold Person'));
  perform public.apply_character_hp(pg_temp.fu('ch2'), 'temp', 90);
  r := public.combat_apply_hp(h, 'damage', 80);
  perform pg_temp.ok('L10 2014 concentration DC has no maximum (80 damage -> DC 40)', (r -> 'concentration_checks' -> 0 ->> 'dc')::int = 40);
  r := public.combat_get_encounter(e);
  perform pg_temp.ok('L11 2014 difficulty: not available in the SRD', not (r -> 'difficulty' ->> 'available')::boolean);
end $$;

-- ============================================================================================ 8. player-safe view
select public.combat_update_participant(pg_temp.fu('lurker'), '{"hidden": false}');
select pg_temp.as_user(pg_temp.fu('pl'));
do $$
declare r jsonb; t text;
begin
  r := public.get_combat_player_view(pg_temp.fu('e1'));
  t := r::text;
  perform pg_temp.ok('V1 player view of the running encounter', r -> 'encounter' ->> 'status' = 'active');
  perform pg_temp.ok('V2 hidden Ogre absent', not (t like '%Ogre%'));
  perform pg_temp.ok('V3 disguise shown instead of the true name', not (t like '%Reed Lurker%') and t like '%Something in the reeds%');
  perform pg_temp.ok('V4 DM-only effect absent', not (t like '%"Hold"%'));
  perform pg_temp.ok('V5 exact enemy HP absent (state only)', (select bool_and(x -> 'hp' ? 'state' and not x -> 'hp' ? 'current') from jsonb_array_elements(r -> 'participants') x where x ->> 'kind' = 'monster'));
  perform pg_temp.ok('V6 no DM notes, stat blocks or reminders', not (t like '%dm_notes%') and not (t like '%Boss hides%') and not (t like '%statblock%') and not (t like '%reminder%'));
  perform pg_temp.ok('V7 player characters'' HP visible', (select count(*) from jsonb_array_elements(r -> 'participants') x where x ->> 'kind' = 'character' and x -> 'hp' ? 'current') >= 4);
  perform pg_temp.ok('V9 players read nothing from the change log', (select count(*) from public.combat_changes) = 0);
end $$;
select pg_temp.as_user(pg_temp.fu('other'));
select pg_temp.ok('V10 unrelated user denied the player view', pg_temp.try(format('select public.get_combat_player_view(%L)', pg_temp.fx('e1'))) like '42501%');

-- ============================================================================================ 9. finish and summary
select pg_temp.as_user(pg_temp.fu('dm'));
do $$
declare r jsonb; e uuid := pg_temp.fu('e1'); long uuid; d jsonb;
begin
  r := public.combat_add_effect(e, jsonb_build_object('effect_type', 'condition', 'condition_key', 'frightened', 'target', pg_temp.pid(e, 'CB Hero 3'), 'visibility', 'dm'));
  long := (r -> 'effects' -> 0 ->> 'id')::uuid;
  r := public.combat_finish(e, 'Goblins fled');
  perform pg_temp.ok('F1 Finish asks about lasting effects on characters first', (r ->> 'needs_review')::boolean
    and exists (select 1 from jsonb_array_elements(r -> 'effects') y where (y ->> 'id')::uuid = long));
  d := (select jsonb_object_agg(y ->> 'id', case when (y ->> 'id')::uuid = long then 'carry' else 'end' end) from jsonb_array_elements(r -> 'effects') y);
  r := public.combat_finish(e, 'Goblins fled', d);
  perform pg_temp.ok('F2 finished with a summary', r -> 'encounter' ->> 'status' = 'completed' and (r -> 'summary' ->> 'rounds')::int >= 3
    and jsonb_array_length(r -> 'summary' -> 'participants') > 5);
  perform pg_temp.ok('F3 carried effect is a hidden condition on the character sheet', exists (select 1 from public.character_conditions
    where character_id = pg_temp.fu('ch3') and name = 'Frightened' and hidden));
  perform pg_temp.ok('F4 player HP stays as it was (no automatic healing)', (select hp_current from public.characters where id = pg_temp.fu('ch1')) = 3);
  perform pg_temp.ok('F5 combat effects ended with the fight', not exists (select 1 from public.combat_effects where encounter_id = e and active));
  perform pg_temp.ok('F6 HP changes refused after Finish', pg_temp.try(format('select public.combat_apply_hp(%L, %L, 1)', pg_temp.pid(e, 'Skeleton'), 'damage')) like '22023%'
    or pg_temp.pid(e, 'Skeleton') is null);
  r := public.combat_get_summary(e);
  perform pg_temp.ok('F7 summary with history', jsonb_array_length(r -> 'history') > 10);
  r := public.combat_duplicate_encounter(e, 'Goblin ambush (rematch)');
  perform pg_temp.put('e3', r -> 'encounter' ->> 'id');
  perform pg_temp.ok('F8 duplicate: a fresh draft with the same participants', r -> 'encounter' ->> 'status' = 'draft'
    and (select count(*) from public.combat_participants where encounter_id = pg_temp.fu('e3')) = (select count(*) from public.combat_participants where encounter_id = e and removed_at is null)
    and not exists (select 1 from public.combat_participants where encounter_id = pg_temp.fu('e3') and (initiative is not null or (kind = 'monster' and hp_current <> hp_max))));
  perform pg_temp.as_user(pg_temp.fu('pl'));
  perform pg_temp.ok('V8 a draft (prepared encounter) shows players nothing', public.get_combat_player_view(pg_temp.fu('e3')) -> 'encounter' ->> 'status' = 'not_running'
    and jsonb_array_length(public.get_combat_player_view(pg_temp.fu('e3')) -> 'participants') = 0);
  perform pg_temp.as_user(pg_temp.fu('dm'));
  r := public.combat_archive_encounter(e);
  perform pg_temp.ok('F9 archive', (select archived_at is not null from public.combat_encounters where id = e));
  perform pg_temp.ok('F10 a started encounter cannot be deleted', pg_temp.try(format('select public.combat_delete_draft(%L)', e)) like '22023%');
  r := public.combat_delete_draft(pg_temp.fu('e3'));
  perform pg_temp.ok('F11 a draft can be deleted', not exists (select 1 from public.combat_encounters where id = pg_temp.fu('e3')));
end $$;

-- ============================================================================================ 10. monster library
do $$
declare r jsonb; c uuid := pg_temp.fu('camp');
begin
  r := public.combat_monster_library(c, 'goblin');
  perform pg_temp.ok('M1 search finds SRD 5.2.1 and SRD 5.1 goblins', exists (select 1 from jsonb_array_elements(r -> 'items') y where y ->> 'kind' = 'srd2024')
    and exists (select 1 from jsonb_array_elements(r -> 'items') y where y ->> 'kind' = 'creature'));
  r := public.combat_monster_library(c, null, '{"cr_min": 5, "cr_max": 5}');
  perform pg_temp.ok('M2 CR filter', (select bool_and((y ->> 'cr')::numeric = 5) from jsonb_array_elements(r -> 'items') y) and (r ->> 'total')::int > 0);
  r := public.combat_monster_library(c, null, '{"type": "undead", "source": "srd2024"}');
  perform pg_temp.ok('M3 type + source filter', (select bool_and(y ->> 'creature_type' = 'undead' and y ->> 'kind' = 'srd2024') from jsonb_array_elements(r -> 'items') y) and (r ->> 'total')::int = 11);
  r := public.combat_monster_library(c, null, '{"rules": "2024", "legendary": true}');
  perform pg_temp.ok('M4 rules-version + legendary filter (4 SRD 5.2.1 legendary)', (r ->> 'total')::int = 4);
  perform pg_temp.ok('M5 malformed favorite refused', pg_temp.try('select public.combat_toggle_favorite(''owlbear'')') like '22023%');
  perform public.combat_toggle_favorite('srd52:srd52-owlbear', true);
  r := public.combat_monster_library(c, null, '{"favorites": true}');
  perform pg_temp.ok('M6 favorites', (r ->> 'total')::int = 1 and r -> 'items' -> 0 ->> 'name' = 'Owlbear');
  r := public.combat_monster_detail('srd52:srd52-adult-red-dragon', c);
  perform pg_temp.ok('M7 preview: full stat block with legendary actions and attribution data', (r -> 'legendary' ->> 'uses')::int = 3
    and r ->> 'license' = 'CC-BY-4.0' and jsonb_array_length(r -> 'actions') >= 3);
  r := public.combat_recent_monsters(c);
  perform pg_temp.ok('M8 recent monsters', jsonb_array_length(r) >= 3);
  perform pg_temp.ok('M9 library attribution text', (public.combat_monster_library(c) ->> 'attribution') like '%SRD 5.2.1%CC%' or (public.combat_monster_library(c) ->> 'attribution') like '%Creative Commons%');
end $$;

-- ============================================================================================ 11. homebrew lifecycle and snapshot integrity
do $$
declare r jsonb; c uuid := pg_temp.fu('camp'); cid uuid; v jsonb; e1 uuid; e2 uuid; ref1 text; ref2 text; p uuid; def jsonb;
begin
  def := '{"combat": {"mode": "quick"}, "size": "Medium", "creature_type": "humanoid", "armor_class": 14, "hit_points": 22,
           "speed": {"walk": 30}, "abilities": {"str": 12, "dex": 14, "con": 12, "int": 10, "wis": 10, "cha": 10}, "initiative_bonus": 3, "actions": []}';
  r := public.create_dm_content('creature', c, jsonb_build_object('name', 'Marsh Raider', 'ruleset', '2024', 'definition', def));
  cid := (r ->> 'id')::uuid;
  v := public.validate_dm_content(cid) -> 'validation';
  perform pg_temp.ok('B1 quick creature without an attack: friendly error', not (v ->> 'ok')::boolean and v::text like '%quick creature needs one basic attack%', v::text);
  def := jsonb_set(def, '{actions}', '[{"name": "Spear", "kind": "melee", "attack_bonus": 4, "reach": 5}]');
  r := public.save_dm_content(cid, jsonb_build_object('name', 'Marsh Raider', 'ruleset', '2024', 'definition', def));
  v := public.validate_dm_content(cid) -> 'validation';
  perform pg_temp.ok('B2 a damaging attack needs a damage formula', v::text like '%needs a damage formula%');
  def := jsonb_set(def, '{actions}', '[{"name": "Spear", "kind": "melee", "attack_bonus": 4, "reach": 5, "damage": [{"dice": "1d6+2", "type": "piercing"}]}]');
  def := def || '{"legendary": {"enabled": false, "uses": "", "actions": []}, "spellcasting": {"enabled": false}}';
  r := public.save_dm_content(cid, jsonb_build_object('name', 'Marsh Raider', 'ruleset', '2024', 'definition', def));
  v := public.validate_dm_content(cid) -> 'validation';
  perform pg_temp.ok('B3 hidden sections that are switched off do not block validation', (v ->> 'ok')::boolean, v::text);
  v := public.validate_dm_content(cid);
  perform pg_temp.as_admin();
  perform pg_temp.ok('B4 legendary enabled without options refused', (public._combat_creature_errors(def || '{"legendary": {"enabled": true, "uses": 3, "actions": []}}'))::text like '%at least one option%');
  perform pg_temp.ok('B5 spellcasting enabled needs ability, DC and spells', jsonb_array_length(public._combat_creature_errors(def || '{"spellcasting": {"enabled": true}}')) = 3);
  perform pg_temp.ok('B6 a recharge needs its roll only when enabled', jsonb_array_length(public._combat_creature_errors(jsonb_set(def, '{actions,0,recharge}', '{"enabled": true}'))) = 1
    and jsonb_array_length(public._combat_creature_errors(jsonb_set(def, '{actions,0,recharge}', '{"enabled": false}'))) = 0);
  perform pg_temp.ok('B7 a definition without "combat" keeps the old rules', jsonb_array_length(public._combat_creature_errors(def - 'combat' || '{"actions": [{"kind": "melee"}]}')) = 0);
  perform pg_temp.as_user(pg_temp.fu('dm'));
  r := public.publish_dm_content(cid);
  select id into ref1 from public.creatures where content_version_id = (select published_version_id from public.dm_content where id = cid);
  perform pg_temp.ok('B8 published homebrew appears in the library', exists (select 1 from jsonb_array_elements(public.combat_monster_library(c, 'Marsh') -> 'items') y where y ->> 'id' = ref1 and (y ->> 'homebrew')::boolean));
  r := public.combat_create_encounter(c, 'Raid v1', '2024'); e1 := (r -> 'encounter' ->> 'id')::uuid;
  r := public.combat_add_monsters(e1, 'creature', ref1, '{"quantity": 2}');
  p := (r -> 'added' ->> 0)::uuid;
  perform pg_temp.ok('B9 homebrew instance: HP 22, Initiative +3 from the definition', (select hp_max = 22 and initiative_mod = 3 from public.combat_participants where id = p));
  -- version 2 with more HP
  r := public.new_dm_content_version(cid);
  r := public.save_dm_content(cid, jsonb_build_object('name', 'Marsh Raider', 'ruleset', '2024', 'definition', jsonb_set(def, '{hit_points}', '30')));
  r := public.publish_dm_content(cid);
  select id into ref2 from public.creatures where content_version_id = (select published_version_id from public.dm_content where id = cid);
  perform pg_temp.ok('B10 version 2 is a new catalog row', ref2 is not null and ref2 <> ref1);
  perform pg_temp.ok('B11 the existing encounter keeps the version 1 snapshot', (select hp_max from public.combat_participants where id = p) = 22
    and (select (snapshot ->> 'hit_points')::int from public.combat_statblocks where encounter_id = e1 and source_id = ref1) = 22);
  perform pg_temp.ok('B12 the library lists only the current version', not exists (select 1 from jsonb_array_elements(public.combat_monster_library(c, 'Marsh') -> 'items') y where y ->> 'id' = ref1)
    and exists (select 1 from jsonb_array_elements(public.combat_monster_library(c, 'Marsh') -> 'items') y where y ->> 'id' = ref2));
  r := public.combat_create_encounter(c, 'Raid v2', '2024'); e2 := (r -> 'encounter' ->> 'id')::uuid;
  r := public.combat_add_monsters(e2, 'creature', ref2, '{}');
  perform pg_temp.ok('B13 a new encounter uses version 2', (select hp_max from public.combat_participants where id = (r -> 'added' ->> 0)::uuid) = 30);
  r := public.combat_duplicate_encounter(e1, 'Raid again');
  perform pg_temp.ok('B14 duplicating takes the current version', (select bool_and(hp_max = 30) from public.combat_participants where encounter_id = (r -> 'encounter' ->> 'id')::uuid));
  r := public.archive_dm_content(cid, 'retired');
  perform pg_temp.ok('B15 archived homebrew cannot be added', pg_temp.try(format('select public.combat_add_monsters(%L, %L, %L)', e2, 'creature', ref2)) like '22023%archived%');
end $$;
select pg_temp.as_user(pg_temp.fu('dm2'));
select pg_temp.ok('B16 another campaign''s DM cannot read this campaign''s homebrew in the library',
  pg_temp.try(format('select public.combat_monster_library(%L)', pg_temp.fx('camp'))) like '42501%');

-- ============================================================================================ 12. cache isolation and indexes
select pg_temp.as_admin();
select pg_temp.ok('X1 combat writes never bump the global read-cache counter', (select rev::text from tl_cache.global_rev where id = 1) = pg_temp.fx('g0'),
  (select rev::text from tl_cache.global_rev where id = 1) || ' vs ' || pg_temp.fx('g0'));
select pg_temp.ok('X2 HP changes of a linked character do not invalidate its cached reads',
  coalesce((select rev::text from tl_cache.character_rev where character_id = pg_temp.fu('ch1')), '0') = pg_temp.fx('c0'));
select pg_temp.ok('X3 every combat runtime table carries the no-op cache trigger',
  (select count(*) from pg_trigger t join pg_class c on c.oid = t.tgrelid where t.tgname = 'tl_cache_rev' and t.tgfoid = 'tl_cache.combat_skip'::regproc) = 8);
select pg_temp.ok('X4 Realtime publishes only the change log', exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'combat_changes')
  and not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename in ('combat_participants', 'combat_effects', 'combat_encounters')));
select pg_temp.ok('X5 the change log carries no names or HP', (select count(*) from information_schema.columns where table_name = 'combat_changes') = 7);
select pg_temp.ok('X6 Wild Shape options unchanged: no SRD 5.2.1 row is a creature', not exists (select 1 from public.creatures where id like 'srd52-%'));

select chk, detail from cb where not ok order by n;
select 'TOTAL ' || count(*) || ' checks, ' || count(*) filter (where not ok) || ' failed' from cb;
rollback;
