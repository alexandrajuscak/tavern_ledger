-- Combat Builder: server timings and query plans of the hot paths on a realistic fixture (docs/COMBAT_DATA_MODEL.md "Indexes").
-- LOCAL ONLY; one transaction, rolled back. Fixture: 40 encounters of other campaigns (noise), one LARGE encounter
-- (6 characters, 13 monsters, 30 effects, 300 history rows).
-- Usage: docker exec -i supabase_db_tavern_ledger psql -U supabase_admin -d postgres -qAt < supabase/tests/combat_query_plans.sql
begin;
create temp table t (step text, ms numeric) on commit drop;
grant all on t to authenticated;
do $$
declare dm uuid := gen_random_uuid(); pl uuid := gen_random_uuid(); camp uuid; e uuid; i int; ch uuid; ids uuid[] := '{}'; t0 timestamptz; p uuid; r jsonb; k int;
begin
  insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at) values
    (dm, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'qp-dm-' || dm || '@example.test', now(), now()),
    (pl, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'qp-pl-' || pl || '@example.test', now(), now());
  perform set_config('request.jwt.claims', json_build_object('sub', dm, 'role', 'authenticated')::text, true);
  -- noise: 40 other campaigns with an encounter each
  for k in 1 .. 40 loop
    insert into public.campaigns (name, created_by) values ('QP noise ' || k, dm) returning id into camp;
    insert into public.campaign_members (campaign_id, user_id, role) values (camp, dm, 'dm');
    r := public.combat_create_encounter(camp, 'Noise ' || k, '2024');
    perform public.combat_add_monsters((r -> 'encounter' ->> 'id')::uuid, 'srd2024', 'srd52-goblin-warrior', '{"quantity": 6}');
  end loop;
  insert into public.campaigns (name, created_by) values ('QP main', dm) returning id into camp;
  insert into public.campaign_members (campaign_id, user_id, role) values (camp, dm, 'dm'), (camp, pl, 'player');
  for i in 1 .. 6 loop
    insert into public.characters (owner_id, name, campaign_id, level, hp_max, hp_current) values (pl, 'QP Hero ' || i, camp, 5, 60, 60) returning id into ch;
    ids := ids || ch;
  end loop;
  r := public.combat_create_encounter(camp, 'QP large', '2024'); e := (r -> 'encounter' ->> 'id')::uuid;
  perform public.combat_add_characters(e, ids);
  perform public.combat_add_monsters(e, 'srd2024', 'srd52-goblin-warrior', '{"quantity": 12}');
  perform public.combat_add_monsters(e, 'srd2024', 'srd52-adult-red-dragon', '{}');
  perform public.combat_roll_initiative(e, null, '{}');
  perform public.combat_set_initiative(e, (select jsonb_agg(jsonb_build_object('id', id, 'initiative', 10)) from public.combat_participants where encounter_id = e and kind = 'character'));
  perform public.combat_start(e, true);
  for i in 1 .. 30 loop
    p := (select id from public.combat_participants where encounter_id = e order by random() limit 1);
    perform public.combat_add_effect(e, jsonb_build_object('effect_type', 'condition', 'condition_key', 'poisoned', 'target', p, 'duration_type', 'rounds', 'duration_rounds', 50));
  end loop;
  for i in 1 .. 150 loop
    perform public.combat_apply_hp((select id from public.combat_participants where encounter_id = e and kind = 'monster' and display_name = 'Adult Red Dragon'), 'damage', 1);
    perform public.combat_next_turn(e, null);
  end loop;
  perform set_config('qp.e', e::text, true);
  -- timings (as the DM, inside SQL: excludes HTTP)
  t0 := clock_timestamp(); perform public.combat_get_encounter(e); insert into t values ('combat_get_encounter (20 combatants, 30 effects)', extract(epoch from clock_timestamp() - t0) * 1000);
  t0 := clock_timestamp(); perform public.combat_list_encounters(null); insert into t values ('combat_list_encounters (41 encounters)', extract(epoch from clock_timestamp() - t0) * 1000);
  t0 := clock_timestamp(); perform public.combat_next_turn(e, null); insert into t values ('combat_next_turn', extract(epoch from clock_timestamp() - t0) * 1000);
  t0 := clock_timestamp(); perform public.combat_apply_hp((select id from public.combat_participants where encounter_id = e and kind = 'monster' limit 1), 'damage', 1);
    insert into t values ('combat_apply_hp (monster)', extract(epoch from clock_timestamp() - t0) * 1000);
  t0 := clock_timestamp(); perform public.combat_apply_hp((select id from public.combat_participants where encounter_id = e and kind = 'character' limit 1), 'damage', 1);
    insert into t values ('combat_apply_hp (character)', extract(epoch from clock_timestamp() - t0) * 1000);
  t0 := clock_timestamp(); perform public.combat_add_effect(e, jsonb_build_object('effect_type', 'condition', 'condition_key', 'prone', 'target', p));
    insert into t values ('combat_add_effect', extract(epoch from clock_timestamp() - t0) * 1000);
  t0 := clock_timestamp(); perform public.combat_get_participant(p); insert into t values ('combat_get_participant', extract(epoch from clock_timestamp() - t0) * 1000);
  t0 := clock_timestamp(); perform public.combat_get_history(e, null, 50); insert into t values ('combat_get_history (50 of 450)', extract(epoch from clock_timestamp() - t0) * 1000);
  t0 := clock_timestamp(); perform public.combat_get_changes(e, 0); insert into t values ('combat_get_changes (reconnect)', extract(epoch from clock_timestamp() - t0) * 1000);
  t0 := clock_timestamp(); perform public.combat_monster_library(camp, 'goblin'); insert into t values ('combat_monster_library search', extract(epoch from clock_timestamp() - t0) * 1000);
  t0 := clock_timestamp(); perform public.combat_monster_detail('srd52:srd52-lich', camp); insert into t values ('combat_monster_detail', extract(epoch from clock_timestamp() - t0) * 1000);
end $$;
select 'TIMING ' || step || ': ' || round(ms, 1) || ' ms' from t order by step;
analyze public.combat_participants; analyze public.combat_effects; analyze public.combat_events; analyze public.combat_changes; analyze public.combat_encounters;
create or replace function pg_temp.plan(q text) returns text language plpgsql as $f$
declare l text; out text := '';
begin
  for l in execute 'explain ' || q loop out := out || ' | ' || btrim(l); end loop;
  return out;
end $f$;
select 'PLAN participants by encounter:' || pg_temp.plan($q$select * from public.combat_participants where encounter_id = current_setting('qp.e')::uuid order by initiative_order$q$);
select 'PLAN active effects of a target:' || pg_temp.plan($q$select * from public.combat_effects where encounter_id = current_setting('qp.e')::uuid and target_participant_id = gen_random_uuid() and active$q$);
select 'PLAN history page:' || pg_temp.plan($q$select * from public.combat_events where encounter_id = current_setting('qp.e')::uuid order by id desc limit 50$q$);
select 'PLAN change log since:' || pg_temp.plan($q$select max(id) from public.combat_changes where encounter_id = current_setting('qp.e')::uuid$q$);
select 'PLAN request replay:' || pg_temp.plan($q$select * from public.combat_events where encounter_id = current_setting('qp.e')::uuid and request_id = gen_random_uuid()$q$);
select 'PLAN running encounters of a campaign:' || pg_temp.plan($q$select * from public.combat_encounters where campaign_id = gen_random_uuid() and status in ('active', 'paused')$q$);
select 'PLAN linked character participants:' || pg_temp.plan($q$select * from public.combat_participants where linked_character_id = gen_random_uuid()$q$);
rollback;
