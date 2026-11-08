-- Wild Shape damage and overflow (20261107000200_combat_initiative_wild_shape.sql; docs/WILD_SHAPE_DAMAGE.md). LOCAL ONLY;
-- run as supabase_admin; one transaction, rolled back (synthetic users, campaign, characters, encounter).
-- Usage: docker exec -i supabase_db_tavern_ledger psql -U supabase_admin -d postgres -qAt -v ON_ERROR_STOP=1 < supabase/tests/wild_shape_damage_tests.sql
-- Prints failed checks and a TOTAL line. Concurrent sessions: supabase/tests/wild_shape_damage_concurrency_test.sh.
begin;
create temp table ws (n serial, chk text, ok boolean, detail text) on commit drop;
grant all on ws to authenticated, anon;
grant all on sequence ws_n_seq to authenticated, anon;
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
  insert into ws (chk, ok, detail) values (c, coalesce(b, false), coalesce(d, ''));
$$;
create or replace function pg_temp.try(q text) returns text language plpgsql as $$
begin
  execute q;
  return 'ok';
exception when others then return sqlstate || ': ' || sqlerrm;
end $$;
create or replace function pg_temp.fu(k text) returns uuid language sql as $$ select v::uuid from fx where fx.k = $1 $$;
-- (re)set the druid: normal HP / temp and a form with HP / temp; expired = the wall-clock duration is over
create or replace function pg_temp.reset(hp int, temp int, fhp int, ftemp int default 0, expired boolean default false, fmax int default null) returns void language plpgsql as $$
declare ch uuid := pg_temp.fu('druid');
begin
  perform pg_temp.as_admin();
  delete from public.character_transformations where character_id = ch;
  update public.characters set hp_current = hp, hp_temp = temp, death_successes = 0, death_failures = 0 where id = ch;
  if fhp is not null then
    insert into public.character_transformations (character_id, character_class_id, resource_key, creature_id, cost, hp_max, hp_current, hp_temp,
      normal_hp_current, normal_hp_temp, max_duration_minutes, started_at, expires_at)
    values (ch, pg_temp.fu('cc'), 'wild-shape', 'brown-bear', 1, coalesce(fmax, fhp), fhp, ftemp, hp, temp, 60,
      case when expired then now() - interval '3 days' else now() end,
      case when expired then now() - interval '3 days' + interval '1 hour' else now() + interval '1 hour' end);
  end if;
end $$;
create or replace function pg_temp.hp() returns int language sql as $$ select hp_current from public.characters where id = pg_temp.fu('druid') $$;
create or replace function pg_temp.tmp() returns int language sql as $$ select hp_temp from public.characters where id = pg_temp.fu('druid') $$;
create or replace function pg_temp.fhp() returns int language sql as $$ select hp_current from public.character_transformations where character_id = pg_temp.fu('druid') $$;
create or replace function pg_temp.ftmp() returns int language sql as $$ select hp_temp from public.character_transformations where character_id = pg_temp.fu('druid') $$;
create or replace function pg_temp.inform() returns boolean language sql as $$ select exists (select 1 from public.character_transformations where character_id = pg_temp.fu('druid')) $$;
create or replace function pg_temp.dmg(n int) returns jsonb language plpgsql as $$
declare r jsonb;
begin
  perform pg_temp.as_user(pg_temp.fu('pl'));
  r := public.apply_character_hp(pg_temp.fu('druid'), 'damage', n, null);
  perform pg_temp.as_admin();
  return r;
end $$;

-- ------------------------------------------------------------------------------------------------------------- fixtures
do $$
declare dm uuid := gen_random_uuid(); pl uuid := gen_random_uuid(); other uuid := gen_random_uuid(); camp uuid := gen_random_uuid(); ch uuid; cc uuid;
begin
  insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at) values
    (dm, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'ws-dm-' || dm || '@example.test', now(), now()),
    (pl, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'ws-pl-' || pl || '@example.test', now(), now()),
    (other, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'ws-ot-' || other || '@example.test', now(), now());
  insert into public.campaigns (id, name, created_by) values (camp, 'WS damage test campaign', dm);
  insert into public.campaign_members (campaign_id, user_id, role) values (camp, dm, 'dm'), (camp, pl, 'player');
  insert into public.characters (owner_id, name, campaign_id, level, hp_max, hp_current, hp_temp, dexterity, constitution)
  values (pl, 'WS Druid', camp, 4, 30, 30, 0, 14, 10) returning id into ch;
  insert into public.character_classes (character_id, class_id, class_version_id, level, is_primary) values (ch, 'druid', 'druid-phb', 4, true) returning id into cc;
  insert into fx values ('dm', dm), ('pl', pl), ('other', other), ('camp', camp), ('druid', ch), ('cc', cc);
end $$;

-- ============================================================================================ 1. form HP 20, normal HP 30
do $$
declare r jsonb;
begin
  perform pg_temp.reset(30, 0, 20); r := pg_temp.dmg(1);
  perform pg_temp.ok('D1 damage 1: form 19, normal 30', pg_temp.fhp() = 19 and pg_temp.hp() = 30, pg_temp.fhp() || '/' || pg_temp.hp());
  perform pg_temp.reset(30, 0, 20); r := pg_temp.dmg(19);
  perform pg_temp.ok('D2 damage 19: form 1, normal 30', pg_temp.fhp() = 1 and pg_temp.hp() = 30);
  perform pg_temp.reset(30, 0, 20); r := pg_temp.dmg(20);
  perform pg_temp.ok('D3 damage 20: the form ends, normal 30 (no excess)', not pg_temp.inform() and pg_temp.hp() = 30
    and (r -> 'wild_shape' -> 'result' ->> 'carryover')::int = 0 and (r -> 'wild_shape' -> 'result' ->> 'ended')::boolean, r::text);
  perform pg_temp.reset(30, 0, 20); r := pg_temp.dmg(21);
  perform pg_temp.ok('D4 damage 21: the form ends, exactly 1 reaches normal HP (30 -> 29)', not pg_temp.inform() and pg_temp.hp() = 29
    and (r -> 'wild_shape' -> 'result' ->> 'carryover')::int = 1 and (r -> 'wild_shape' -> 'result' ->> 'form_hp_used')::int = 20, pg_temp.hp()::text);
  perform pg_temp.reset(30, 0, 20); r := pg_temp.dmg(25);
  perform pg_temp.ok('D5 damage 25: normal loses 5', pg_temp.hp() = 25);
  perform pg_temp.reset(30, 0, 20); r := pg_temp.dmg(40);
  perform pg_temp.ok('D6 damage 40: normal loses 20', pg_temp.hp() = 10);
  perform pg_temp.reset(30, 0, 20); r := pg_temp.dmg(80);
  perform pg_temp.ok('D7 damage 80: normal HP never below 0, unconscious flagged', pg_temp.hp() = 0 and (r -> 'wild_shape' -> 'result' ->> 'unconscious')::boolean);
end $$;

-- ============================================================================================ 2. temporary HP
do $$
declare r jsonb;
begin
  perform pg_temp.reset(30, 4, 20); r := pg_temp.dmg(23);
  perform pg_temp.ok('T1 overflow 3 goes to the normal temporary HP first (temp 4 -> 1, HP 30)', pg_temp.hp() = 30 and pg_temp.tmp() = 1, pg_temp.hp() || '/' || pg_temp.tmp());
  perform pg_temp.reset(30, 2, 20); r := pg_temp.dmg(25);
  perform pg_temp.ok('T2 overflow 5: normal temp 2 used, then 3 from HP (27)', pg_temp.hp() = 27 and pg_temp.tmp() = 0);
  perform pg_temp.reset(30, 0, 20, 5); r := pg_temp.dmg(4);
  perform pg_temp.ok('T3 form temporary HP absorb first (form temp 5 -> 1, form 20)', pg_temp.ftmp() = 1 and pg_temp.fhp() = 20);
  perform pg_temp.reset(30, 0, 20, 5); r := pg_temp.dmg(26);
  perform pg_temp.ok('T4 order: form temp 5, form HP 20, then 1 excess (normal 29)', not pg_temp.inform() and pg_temp.hp() = 29
    and (r -> 'wild_shape' -> 'result' ->> 'carryover')::int = 1, r::text);
end $$;

-- ============================================================================================ 3. healing
do $$
declare r jsonb;
begin
  perform pg_temp.reset(25, 0, 12, 0, false, 20);
  perform pg_temp.as_user(pg_temp.fu('pl')); r := public.apply_character_hp(pg_temp.fu('druid'), 'heal', 5, null); perform pg_temp.as_admin();
  perform pg_temp.ok('H1 healing an active form heals the form (12 -> 17), normal 25', pg_temp.fhp() = 17 and pg_temp.hp() = 25);
  perform pg_temp.as_user(pg_temp.fu('pl')); r := public.apply_character_hp(pg_temp.fu('druid'), 'heal', 50, null); perform pg_temp.as_admin();
  perform pg_temp.ok('H2 form healing stops at the form maximum (20)', pg_temp.fhp() = 20 and pg_temp.hp() = 25);
  perform pg_temp.reset(25, 0, null);
  perform pg_temp.as_user(pg_temp.fu('pl')); r := public.apply_character_hp(pg_temp.fu('druid'), 'heal', 3, null); perform pg_temp.as_admin();
  perform pg_temp.ok('H3 after the revert healing goes to the normal HP (25 -> 28)', pg_temp.hp() = 28);
end $$;

-- ============================================================================================ 4. the defect: a form past its duration
do $$
declare r jsonb; s text;
begin
  -- regression of 2026-11-07: the form shown with 19 HP, duration over by wall clock, 20 damage; before the fix normal HP 17 -> 0
  perform pg_temp.reset(17, 0, 19, 0, true); r := pg_temp.dmg(20);
  perform pg_temp.ok('X1 REGRESSION expired form 19 HP, 20 damage: only 1 reaches normal HP (17 -> 16)', pg_temp.hp() = 16 and not pg_temp.inform(), pg_temp.hp()::text);
  perform pg_temp.ok('X1b ... reported as applied, excess 1', (r ->> 'applied')::boolean and (r -> 'wild_shape' -> 'result' ->> 'carryover')::int = 1);
  perform pg_temp.reset(30, 0, 20, 0, true); r := pg_temp.dmg(21);
  perform pg_temp.ok('X2 expired form 20 HP, 21 damage: normal 29', pg_temp.hp() = 29);
  perform pg_temp.reset(30, 0, 20, 0, true); r := pg_temp.dmg(5);
  perform pg_temp.ok('X3 expired form survives 5 damage: the damage hits the form, then the form ends (duration); normal 30',
    pg_temp.hp() = 30 and not pg_temp.inform() and r -> 'wild_shape' -> 'result' ->> 'reason' = 'expired', r::text);
  perform pg_temp.ok('X3b ... the history has the damage and the expiry', (select count(*) from public.character_transformation_events
    where character_id = pg_temp.fu('druid') and event_type in ('damaged', 'reverted_expired') and created_at = now()) >= 2);
  perform pg_temp.reset(20, 0, 10, 0, true);
  perform pg_temp.as_user(pg_temp.fu('pl')); r := public.apply_character_hp(pg_temp.fu('druid'), 'heal', 5, null); perform pg_temp.as_admin();
  perform pg_temp.ok('X4 heal on an expired form: the form ends, NOTHING is applied (normal stays 20)', pg_temp.hp() = 20 and not pg_temp.inform()
    and not (r ->> 'applied')::boolean, r::text);
  perform pg_temp.reset(20, 0, 10, 0, true);
  perform pg_temp.as_user(pg_temp.fu('pl')); r := public.apply_character_hp(pg_temp.fu('druid'), 'set', 3, 'misread'); perform pg_temp.as_admin();
  perform pg_temp.ok('X5 manual form correction on an expired form never overwrites normal HP', pg_temp.hp() = 20 and not (r ->> 'applied')::boolean);
  perform pg_temp.reset(20, 0, 10, 0, true);
  perform pg_temp.as_user(pg_temp.fu('pl')); r := public.apply_character_hp(pg_temp.fu('druid'), 'temp', 6, null); perform pg_temp.as_admin();
  perform pg_temp.ok('X6 temporary HP on an expired form: nothing applied to the normal form', pg_temp.tmp() = 0 and not (r ->> 'applied')::boolean);
  -- the sheet's own form button (damage_active_transformation) has the same behaviour
  perform pg_temp.reset(17, 0, 19, 0, true);
  perform pg_temp.as_user(pg_temp.fu('pl')); r := public.damage_active_transformation(pg_temp.fu('druid'), 20, null); perform pg_temp.as_admin();
  perform pg_temp.ok('X7 sheet form Damage on an expired form: same result as the shared path (17 -> 16)', pg_temp.hp() = 16 and (r -> 'result' ->> 'carryover')::int = 1, r::text);
end $$;

-- ============================================================================================ 5. corrections and rules
do $$
declare r jsonb; s text;
begin
  perform pg_temp.reset(30, 0, 20);
  perform pg_temp.as_user(pg_temp.fu('pl')); r := public.apply_character_hp(pg_temp.fu('druid'), 'set', 7, 'misread the roll'); perform pg_temp.as_admin();
  perform pg_temp.ok('C1 manual correction sets the form HP (7), normal untouched', pg_temp.fhp() = 7 and pg_temp.hp() = 30);
  perform pg_temp.ok('C2 ... with its reason in the history', exists (select 1 from public.character_transformation_events where character_id = pg_temp.fu('druid')
    and event_type = 'manual_set' and metadata ->> 'reason' = 'misread the roll'));
  perform pg_temp.as_user(pg_temp.fu('pl'));
  s := pg_temp.try(format('select public.apply_character_hp(%L, %L, 5, null)', pg_temp.fu('druid'), 'set'));
  perform pg_temp.as_admin();
  perform pg_temp.ok('C3 a correction without a reason is refused (friendly 22023)', s like '22023%', s);
  perform pg_temp.reset(30, 0, null);
  perform pg_temp.as_user(pg_temp.fu('pl')); r := public.apply_character_hp(pg_temp.fu('druid'), 'set', 22, 'after the fight'); perform pg_temp.as_admin();
  perform pg_temp.ok('C4 manual normal-HP correction outside Wild Shape', pg_temp.hp() = 22);
  perform pg_temp.reset(30, 0, 20);
  perform pg_temp.as_user(pg_temp.fu('pl')); r := public.end_transformation(pg_temp.fu('druid'), 'manual'); perform pg_temp.as_admin();
  perform pg_temp.ok('R1 Revert: the form ends, normal HP unchanged (30)', not pg_temp.inform() and pg_temp.hp() = 30);
  perform pg_temp.reset(30, 0, 20);
  perform pg_temp.as_user(pg_temp.fu('other'));
  s := pg_temp.try(format('select public.apply_character_hp(%L, %L, 5, null)', pg_temp.fu('druid'), 'damage'));
  perform pg_temp.as_admin();
  perform pg_temp.ok('A1 an unrelated user cannot damage the form (42501), nothing changes', s like '42501%' and pg_temp.fhp() = 20, s);
  perform pg_temp.as_user(pg_temp.fu('pl'));
  s := pg_temp.try(format('select public.apply_character_hp(%L, %L, 0, null)', pg_temp.fu('druid'), 'damage'));
  perform pg_temp.as_admin();
  perform pg_temp.ok('A2 zero damage refused with a friendly message', s like '22023%', s);
  perform pg_temp.ok('V1 only the 2014 (PHB) Druid has a separate form HP pool in the catalog; no 2024 Druid version exists',
    not exists (select 1 from public.class_versions where class_id = 'druid' and id <> 'druid-phb' and id not like '%test%'), (select string_agg(id, ',') from public.class_versions where class_id = 'druid'));
end $$;

-- ============================================================================================ 6. Combat Builder (same function)
do $$
declare e uuid; p uuid; r jsonb; req uuid := gen_random_uuid(); ev public.combat_events; s text;
begin
  perform pg_temp.reset(30, 0, 20);
  perform pg_temp.as_user(pg_temp.fu('dm'));
  r := public.combat_create_encounter(pg_temp.fu('camp'), 'WS ambush', 'campaign'); e := (r -> 'encounter' ->> 'id')::uuid;
  perform public.combat_add_characters(e, array[pg_temp.fu('druid')], '{}');
  select id into p from public.combat_participants where encounter_id = e and linked_character_id = pg_temp.fu('druid');
  r := public.combat_apply_hp(p, 'damage', 21, null, req);
  perform pg_temp.as_admin();
  perform pg_temp.ok('B1 Combat Builder damage 21 on a 20 HP form: normal 30 -> 29', pg_temp.hp() = 29 and not pg_temp.inform(), pg_temp.hp()::text);
  select * into ev from public.combat_events where encounter_id = e and kind = 'damage' order by id desc limit 1;
  perform pg_temp.ok('B2 history: incoming 21, form HP used 20, excess 1, form ended, resulting HP 29, form name',
    (ev.details ->> 'amount')::int = 21 and (ev.details ->> 'form_hp_used')::int = 20 and (ev.details ->> 'carryover')::int = 1
    and (ev.details ->> 'form_ended')::boolean and (ev.details ->> 'normal_hp_after')::int = 29 and ev.details ->> 'form_name' = 'Brown Bear', ev.details::text);
  perform pg_temp.as_user(pg_temp.fu('dm'));
  r := public.combat_apply_hp(p, 'damage', 21, null, req);
  perform pg_temp.as_admin();
  perform pg_temp.ok('B3 the same request again (duplicate) changes nothing', pg_temp.hp() = 29
    and (select count(*) from public.combat_events where encounter_id = e and kind = 'damage') = 1);
  perform pg_temp.as_user(pg_temp.fu('dm'));
  s := pg_temp.try(format('select public.combat_undo(%s)', ev.id));
  perform pg_temp.as_admin();
  perform pg_temp.ok('B4 Undo of a damage that ended the form is refused (form changed), nothing undone', s like 'TLCMB%' and pg_temp.hp() = 29, s);
  -- expired form in combat: damage goes to the form, then the duration ends it
  perform pg_temp.reset(17, 0, 19, 0, true);
  perform pg_temp.as_user(pg_temp.fu('dm'));
  r := public.combat_apply_hp(p, 'damage', 20, null, gen_random_uuid());
  perform pg_temp.as_admin();
  perform pg_temp.ok('B5 REGRESSION in combat: expired 19 HP form, 20 damage, normal 17 -> 16', pg_temp.hp() = 16, pg_temp.hp()::text);
  select * into ev from public.combat_events where encounter_id = e and kind = 'damage' order by id desc limit 1;
  perform pg_temp.ok('B6 ... and the history now records the excess (was carryover null)', (ev.details ->> 'carryover')::int = 1, ev.details::text);
  perform pg_temp.reset(17, 0, 10, 0, true);
  perform pg_temp.as_user(pg_temp.fu('dm'));
  r := public.combat_apply_hp(p, 'heal', 4, null, gen_random_uuid());
  perform pg_temp.as_admin();
  perform pg_temp.ok('B7 combat heal on an expired form: not applied, clear message, no HP event, normal 17', not (r ->> 'applied')::boolean
    and r ->> 'message' like '%reached the end of its duration%' and pg_temp.hp() = 17
    and (select count(*) from public.combat_events where encounter_id = e and kind = 'heal') = 0, r ->> 'message');
  -- a damage that the form survives can be undone exactly
  perform pg_temp.reset(30, 0, 20);
  perform pg_temp.as_user(pg_temp.fu('dm'));
  r := public.combat_apply_hp(p, 'damage', 6, null, gen_random_uuid());
  r := public.combat_undo((r ->> 'event_id')::bigint);
  perform pg_temp.as_admin();
  perform pg_temp.ok('B8 Undo of form damage restores the form HP (20)', pg_temp.fhp() = 20 and pg_temp.hp() = 30);
end $$;

-- ------------------------------------------------------------------------------------------------------------- report
select 'FAILED ' || chk || coalesce('  <-- ' || nullif(detail, ''), '') from ws where not ok order by n;
select 'TOTAL ' || count(*) || ' checks, ' || count(*) filter (where not ok) || ' failed' from ws;
rollback;
