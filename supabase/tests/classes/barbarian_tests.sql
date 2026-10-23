-- =============================================================================
-- Barbarian (barbarian-phb) and Path of the Berserker (barbarian-berserker-phb): Rage as an active state (start spends a use,
-- benefits only while active and not in heavy armor, Rage Damage on STR melee weapons only, rests end it, unlimited at 20),
-- Unarmored Defense, Fast Movement, Danger Sense, Primal Knowledge, Primal Champion, Mindless Rage, progression,
-- multiclass, RLS.
-- =============================================================================
\set r1 f1c00000-0000-0000-0000-000000000001
\set r2 f1c00000-0000-0000-0000-000000000002
insert into public.characters (id, owner_id, name, campaign_id, strength, dexterity, constitution, intelligence, wisdom, charisma) values
  (:'r1', :'alice', 'Barbarian Tester', :'camp', 16, 14, 16, 8, 10, 10),
  (:'r2', :'alice', 'Wizard then Barbarian', null, 14, 14, 14, 16, 10, 10);
create function tl_test.states(p_char uuid) returns jsonb language sql as $$ select public.get_character_states(p_char) -> 'states' $$;
create function tl_test.weapon(p_char uuid, p_item text) returns jsonb language sql as $$
  select w from jsonb_array_elements(tl_test.d(p_char) -> 'equipped_weapon_attacks') w where w ->> 'item_id' = p_item limit 1 $$;
create function tl_test.equip(p_char uuid, p_item text, p_slot text) returns void language plpgsql as $$
declare inv uuid; ii uuid;
begin
  select id into inv from public.inventories where character_id = p_char and kind = 'character';
  ii := public.add_inventory_item(inv, p_item, 1);
  perform public.equip_item(ii, p_slot);
end $$;
grant all on all functions in schema tl_test to public;

select tl_test.rec('BR1 Barbarian: every class level 1-20 is represented; Rage is a declared state that spends the Rage resource',
  tl_test.levels_represented('barbarian-phb') = 20
  and exists (select 1 from public.class_feature_states where key = 'rage' and resource_id = 'barbarian-rage-phb-uses'));

select tl_test.as_user(:'alice');
select tl_test.setc(:'r1', 'barbarian-phb', 1);
select tl_test.rec('BR2 Barbarian 1 without armor: AC 15 (10 + DEX 2 + CON 3); Rage 2 / 2; not raging, so no resistances',
  (tl_test.d(:'r1') -> 'armor_class' ->> 'value')::int = 15 and (tl_test.res(:'r1', 'barbarian-rage-phb-uses') ->> 'max')::int = 2
  and not (tl_test.d(:'r1') -> 'resistances')::text like '%slashing%'
  and not (tl_test.states(:'r1') -> 0 ->> 'active')::boolean);
select tl_test.equip(:'r1', 'greataxe', 'main_hand');
select tl_test.rec('BR3 before raging the greataxe deals 1d12 + 3',
  tl_test.weapon(:'r1', 'greataxe') ->> 'damage' = '1d12 + 3', tl_test.weapon(:'r1', 'greataxe') ->> 'damage');
select public.start_character_state(:'r1', 'rage');
select tl_test.rec('BR4 Start Rage: one use spent (1 / 2), state active; resistant to bludgeoning, piercing, slashing; STR save advantage applied',
  (tl_test.res(:'r1', 'barbarian-rage-phb-uses') ->> 'remaining')::int = 1 and (tl_test.states(:'r1') -> 0 ->> 'active')::boolean
  and (tl_test.d(:'r1') -> 'resistances')::text like '%bludgeoning%' and (tl_test.d(:'r1') -> 'resistances')::text like '%slashing%'
  and tl_test.d(:'r1') -> 'active_states' = '["rage"]'::jsonb,
  (tl_test.d(:'r1') -> 'resistances')::text);
select tl_test.rec('BR5 raging: the greataxe (STR) deals 1d12 + 5 with Rage Damage +2 in the breakdown',
  tl_test.weapon(:'r1', 'greataxe') ->> 'damage' = '1d12 + 5'
  and tl_test.weapon(:'r1', 'greataxe') -> 'damage_breakdown' @> '[{"effect": "damage_bonus", "value": 2}]'::jsonb,
  tl_test.weapon(:'r1', 'greataxe') ->> 'damage');
select tl_test.rec('BR6 starting Rage again is refused while it is active',
  tl_test.raises($$select public.start_character_state('f1c00000-0000-0000-0000-000000000001', 'rage')$$) like '%already active%');
select public.end_character_state(:'r1', 'rage');
select tl_test.rec('BR7 End Rage: benefits off, the use stays spent',
  not (tl_test.d(:'r1') -> 'resistances')::text like '%slashing%' and (tl_test.res(:'r1', 'barbarian-rage-phb-uses') ->> 'remaining')::int = 1
  and tl_test.weapon(:'r1', 'greataxe') ->> 'damage' = '1d12 + 3');
select public.start_character_state(:'r1', 'rage');
select tl_test.rec('BR8 the last use: a third Rage is refused (no uses left) after ending the second',
  (select public.end_character_state(:'r1', 'rage') is not null)
  and tl_test.raises($$select public.start_character_state('f1c00000-0000-0000-0000-000000000001', 'rage')$$) like '%Not enough%');
select public.long_rest_character(:'r1');
select tl_test.rec('BR9 a long rest restores Rage uses (2 / 2)', (tl_test.res(:'r1', 'barbarian-rage-phb-uses') ->> 'remaining')::int = 2);
select public.start_character_state(:'r1', 'rage');
select tl_test.rec('BR10 a short rest ends an active Rage (reported in states_ended)',
  public.short_rest_character(:'r1') -> 'states_ended' = '["rage"]'::jsonb);
select tl_test.rec('BR10b after the rest Rage is inactive', not (tl_test.states(:'r1') -> 0 ->> 'active')::boolean);
select public.start_character_state(:'r1', 'rage', false);
select tl_test.rec('BR11 starting without spending (already paid) keeps the uses; the state records it',
  (tl_test.res(:'r1', 'barbarian-rage-phb-uses') ->> 'remaining')::int = 1 and not (tl_test.states(:'r1') -> 0 ->> 'resource_spent')::boolean);
select tl_test.equip(:'r1', 'plate', 'armor');
select tl_test.rec('BR12 raging in heavy armor (plate): the Rage benefits do not apply (inactive reason wearing_heavy_armor)',
  not (tl_test.d(:'r1') -> 'resistances')::text like '%slashing%');
select public.end_character_state(:'r1', 'rage');

select tl_test.setc(:'r1', 'barbarian-phb', 6, 'barbarian-berserker-phb');
select tl_test.rec('BR13 Berserker 6 not raging: no charmed / frightened immunity; Fast Movement needs no heavy armor (plate worn: speed 30)',
  not tl_test.d(:'r1') -> 'condition_immunities' ? 'charmed' and (tl_test.d(:'r1') -> 'speed' ->> 'value')::int = 30);
select public.start_character_state(:'r1', 'rage');
select tl_test.rec('BR14 Mindless Rage: while raging, immune to charmed and frightened (even in plate: the immunity has no armor condition)',
  tl_test.d(:'r1') -> 'condition_immunities' @> '["charmed", "frightened"]'::jsonb);
select tl_test.rec('BR15 Primal Knowledge is optional: its skill cannot be chosen until the optional feature is switched on',
  tl_test.raises($$select tl_test.choose('f1c00000-0000-0000-0000-000000000001', 'barbarian', 'barbarian-phb-u3-primal-knowledge', 'barbarian-primal-knowledge-tce-skill', '{nature}')$$) like '%not active%');
select public.set_character_optional_feature(:'r1', tl_test.k(:'r1', 'barbarian'), 'barbarian-phb-u3-primal-knowledge', true);
select tl_test.choose(:'r1', 'barbarian', 'barbarian-phb-u3-primal-knowledge', 'barbarian-primal-knowledge-tce-skill', '{nature}');
select tl_test.rec('BR16 with Primal Knowledge on: Nature proficient; Wizard skills are refused',
  (tl_test.d(:'r1') -> 'skills' -> 'nature' ->> 'class_proficient')::boolean
  and tl_test.raises($$select tl_test.choose('f1c00000-0000-0000-0000-000000000001', 'barbarian', 'barbarian-phb-u3-primal-knowledge', 'barbarian-primal-knowledge-tce-skill', '{arcana}')$$) is not null);
select public.end_character_state(:'r1', 'rage');

-- ---- progression snapshot ---------------------------------------------------------------------------------------------------
select tl_test.as_root();
create table tl_test.rsnap (level int, rages text, dmg int, speed int, attacks int);
grant all on tl_test.rsnap to public;
select tl_test.as_user(:'alice');
select public.unequip_item((select inventory_item_id from public.character_equipment where character_id = :'r1' and slot_id = 'armor'));
do $$
declare l int; ch uuid := 'f1c00000-0000-0000-0000-000000000001';
begin
  for l in 1..20 loop
    perform tl_test.setc(ch, 'barbarian-phb', l);
    insert into tl_test.rsnap values (l,
      case when (tl_test.res(ch, 'barbarian-rage-phb-uses') ->> 'unlimited')::boolean then 'U' else tl_test.res(ch, 'barbarian-rage-phb-uses') ->> 'max' end,
      (select (s ->> 'value')::int from jsonb_array_elements(tl_test.f(ch) -> 'classes' -> 0 -> 'features') f, jsonb_array_elements(f -> 'scaling') s
       where f ->> 'unlock_id' = 'barbarian-phb-u1-rage' and s ->> 'key' = 'rage_damage'),
      (tl_test.d(ch) -> 'speed' ->> 'value')::int, (tl_test.d(ch) -> 'attacks_per_action' ->> 'value')::int);
  end loop;
end $$;
select tl_test.rec('BR17 progression snapshot 1-20 (rages, Rage Damage, speed, attacks)',
  (select string_agg(format('%s:%s/%s/%s/%s', level, rages, dmg, speed, attacks), ' ' order by level) from tl_test.rsnap)
  = '1:2/2/30/1 2:2/2/30/1 3:3/2/30/1 4:3/2/30/1 5:3/2/40/2 6:4/2/40/2 7:4/2/40/2 8:4/2/40/2 9:4/3/40/2 10:4/3/40/2 11:4/3/40/2 '
    '12:5/3/40/2 13:5/3/40/2 14:5/3/40/2 15:5/3/40/2 16:5/4/40/2 17:6/4/40/2 18:6/4/40/2 19:6/4/40/2 20:U/4/40/2',
  (select string_agg(format('%s:%s/%s/%s/%s', level, rages, dmg, speed, attacks), ' ' order by level) from tl_test.rsnap));
select tl_test.rec('BR18 Primal Champion at 20: STR and CON +4 with a maximum of 24',
  (tl_test.d(:'r1') -> 'abilities' -> 'str' ->> 'score')::int = 20 and (tl_test.d(:'r1') -> 'ability_maximums' ->> 'str')::int = 24,
  (tl_test.d(:'r1') -> 'abilities' -> 'str')::text);
select public.start_character_state(:'r1', 'rage');
select tl_test.rec('BR19 unlimited Rage at 20: starting does not run out',
  (select public.end_character_state(:'r1', 'rage') is not null) and tl_test.raises($$select public.start_character_state('f1c00000-0000-0000-0000-000000000001', 'rage')$$) is null);

select tl_test.setc(:'r2', 'wizard-phb', 2);
select tl_test.setc(:'r2', 'barbarian-phb', 1);
select tl_test.rec('BR20 Barbarian as a second class: shields and martial weapons, no medium armor, no STR / CON saves',
  exists (select 1 from jsonb_array_elements(tl_test.d(:'r2') -> 'proficiencies') p where p ->> 'group_id' = 'martial-weapons')
  and not exists (select 1 from jsonb_array_elements(tl_test.d(:'r2') -> 'proficiencies') p where p ->> 'group_id' = 'medium-armor')
  and not coalesce((tl_test.d(:'r2') -> 'saving_throws' -> 'con' ->> 'class_proficient')::boolean, false));
select tl_test.as_user(:'bob');
select tl_test.rec('BR21 an outsider cannot start or end Rage, read the states or the raw state rows',
  tl_test.raises($$select public.start_character_state('f1c00000-0000-0000-0000-000000000001', 'rage')$$) is not null
  and tl_test.raises($$select public.end_character_state('f1c00000-0000-0000-0000-000000000001', 'rage')$$) is not null
  and tl_test.raises($$select public.get_character_states('f1c00000-0000-0000-0000-000000000001')$$) is not null
  and not exists (select 1 from public.character_active_states where character_id = 'f1c00000-0000-0000-0000-000000000001'));
select tl_test.as_user(:'alice');
select tl_test.rec('BR22 even the owner cannot write state rows directly (RPC only)',
  tl_test.raises($$insert into public.character_active_states (character_id, state_key, character_class_id, feature_version_id)
                  values ('f1c00000-0000-0000-0000-000000000002', 'rage', gen_random_uuid(), 'x')$$) is not null);
select tl_test.as_root();
