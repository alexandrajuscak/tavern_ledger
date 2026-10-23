-- =============================================================================
-- Paladin (paladin-phb) and Oath of Devotion (paladin-devotion-phb): Divine Sense, Lay on Hands (pool spent by amount),
-- fighting styles of the Paladin page (Blessed Warrior cantrips, UA options), Divine Smite (slot rider), Divine Health,
-- Channel Divinity, Harness Divine Power, Aura of Protection (CHA to own saves), auras (condition immunities), oath spells,
-- progression, multiclass, RLS.
-- =============================================================================
\set p1 f1a00000-0000-0000-0000-000000000001
\set p2 f1a00000-0000-0000-0000-000000000002
\set p3 f1a00000-0000-0000-0000-000000000003
insert into public.characters (id, owner_id, name, campaign_id, strength, dexterity, constitution, intelligence, wisdom, charisma) values
  (:'p1', :'alice', 'Paladin Tester', :'camp', 16, 10, 14, 8, 10, 16),
  (:'p2', :'alice', 'Low CHA Paladin', null, 16, 10, 14, 8, 10, 8),
  (:'p3', :'alice', 'Rogue then Paladin', null, 14, 16, 12, 10, 10, 14);
create function tl_test.granted(p_char uuid, p_spell text) returns jsonb language sql as $$
  select g from jsonb_array_elements(tl_test.spell(p_char, p_spell) -> 'grants') g where g ->> 'source_type' = 'class_feature' limit 1 $$;
grant all on all functions in schema tl_test to public;

select tl_test.rec('PA1 Paladin: every class level 1-20 is represented', tl_test.levels_represented('paladin-phb') = 20);
select tl_test.rec('PA2 class metadata: d10, STR and CHA primary, WIS and CHA saves, subclass at 3',
  (select hit_die = 'd10' and primary_abilities = '{str,cha}' and saving_throws = '{wis,cha}' and subclass_level = 3 from public.class_versions where id = 'paladin-phb'));

select tl_test.as_user(:'alice');
select tl_test.setc(:'p1', 'paladin-phb', 1);
select tl_test.rec('PA3 Paladin 1 (CHA 16): Divine Sense 4 uses (1 + CHA), Lay on Hands pool 5',
  (tl_test.res(:'p1', 'paladin-divine-sense-phb-uses') ->> 'max')::int = 4 and (tl_test.res(:'p1', 'paladin-lay-on-hands-phb-pool') ->> 'max')::int = 5
  and tl_test.res(:'p1', 'paladin-lay-on-hands-phb-pool') ->> 'resource_type' = 'pool');
select public.expend_character_resource(:'p1', tl_test.rkey(:'p1', 'paladin', 'paladin-lay-on-hands-phb-pool'), 3);
select tl_test.rec('PA4 Lay on Hands spends an amount (3 of 5: 2 left); spending 3 more is refused',
  (tl_test.res(:'p1', 'paladin-lay-on-hands-phb-pool') ->> 'remaining')::int = 2
  and tl_test.raises($$select public.expend_character_resource('f1a00000-0000-0000-0000-000000000001', tl_test.rkey('f1a00000-0000-0000-0000-000000000001', 'paladin', 'paladin-lay-on-hands-phb-pool'), 3)$$) like '%Not enough%');
select tl_test.setc(:'p1', 'paladin-phb', 2);
select tl_test.rec('PA5 Paladin 2: the fighting style list is the Paladin page''s (Blessed Warrior yes, Archery no; Thrown Weapon Fighting only as UA playtest)',
  exists (select 1 from jsonb_array_elements(tl_test.ch(:'p1', 'paladin', 'paladin-phb-u2-fighting-style:paladin-fighting-style-phb-style') -> 'options') o where o ->> 'id' = 'blessed-warrior')
  and not exists (select 1 from jsonb_array_elements(tl_test.ch(:'p1', 'paladin', 'paladin-phb-u2-fighting-style:paladin-fighting-style-phb-style') -> 'options') o where o ->> 'id' = 'archery')
  and (select data ->> 'status' from public.class_feature_choice_options where choice_id = 'paladin-fighting-style-phb-style' and option_id = 'thrown-weapon-fighting') = 'playtest');
select tl_test.choose(:'p1', 'paladin', 'paladin-phb-u2-fighting-style', 'paladin-fighting-style-phb-style', '{blessed-warrior}');
select tl_test.choose(:'p1', 'paladin', 'paladin-phb-u2-fighting-style', 'paladin-fighting-style-phb-blessed-warrior-cantrips', '{sacred-flame-phb,guidance-phb}');
select tl_test.rec('PA6 Blessed Warrior: two Cleric cantrips granted as Paladin features, cast with Charisma',
  (tl_test.granted(:'p1', 'sacred-flame-phb') ->> 'casting_ability') = 'cha' and tl_test.granted(:'p1', 'guidance-phb') is not null);
select tl_test.rec('PA7 Divine Smite: a slot rider (2d8 with a 1st-level slot, 5d8 cap), radiant, needs an explicit slot',
  tl_test.d(:'p1') -> 'attack_riders' @> '[{"name": "Divine Smite", "damage_type": "radiant"}]'::jsonb
  and (select r -> 'dice_by_slot' ->> '1' = '2d8' and r -> 'dice_by_slot' ->> '5' = '5d8'
       from jsonb_array_elements(tl_test.d(:'p1') -> 'attack_riders') r where r ->> 'name' = 'Divine Smite'));

select tl_test.setc(:'p1', 'paladin-phb', 3, 'paladin-devotion-phb');
select tl_test.rec('PA8 Devotion 3: oath spells always prepared (Protection from Evil and Good, Sanctuary); Divine Health: immune to disease; Channel Divinity 1',
  (tl_test.granted(:'p1', 'sanctuary-phb') ->> 'always_prepared')::boolean and (tl_test.granted(:'p1', 'protection-from-evil-and-good-phb') ->> 'always_prepared')::boolean
  and tl_test.d(:'p1') -> 'condition_immunities' @> '["disease"]'::jsonb
  and tl_test.d(:'p1') -> 'condition_immunity_sources' @> '[{"condition": "disease", "sources": ["Paladin: Divine Health"]}]'::jsonb
  and (tl_test.res(:'p1', 'paladin-channel-divinity-phb-uses') ->> 'max')::int = 1);
select public.set_character_optional_feature(:'p1', tl_test.k(:'p1', 'paladin'), 'paladin-phb-u3-harness-divine-power', true);
select public.expend_standard_spell_slot(:'p1', 1);
select public.recover_spell_slots(:'p1', tl_test.rkey(:'p1', 'paladin', 'paladin-harness-divine-power-tce-uses'), '{1}');
select tl_test.rec('PA9 Harness Divine Power (Paladin): recovers the 1st-level slot and spends Channel Divinity',
  (tl_test.res(:'p1', 'paladin-channel-divinity-phb-uses') ->> 'remaining')::int = 0
  and coalesce((select expended from public.character_spell_slot_state where character_id = :'p1' and pool = 'standard' and slot_level = 1), 0) = 0);

select tl_test.setc(:'p1', 'paladin-phb', 6);
select tl_test.rec('PA10 Aura of Protection: +3 (CHA) on every own saving throw, radius 10 ft; Extra Attack (2 attacks)',
  (tl_test.d(:'p1') -> 'saving_throws' -> 'str' ->> 'class_bonus')::int = 3 and (tl_test.d(:'p1') -> 'saving_throws' -> 'wis' ->> 'class_bonus')::int = 3
  and (tl_test.d(:'p1') -> 'attacks_per_action' ->> 'value')::int = 2);
select tl_test.setc(:'p2', 'paladin-phb', 6);
select tl_test.rec('PA11 with CHA 8 the aura still gives the minimum +1',
  (tl_test.d(:'p2') -> 'saving_throws' -> 'dex' ->> 'class_bonus')::int = 1);
select tl_test.setc(:'p1', 'paladin-phb', 11);
select tl_test.rec('PA12 Paladin 11: immune to charmed (Aura of Devotion) and frightened (Aura of Courage); Improved Divine Smite 1d8 on every melee hit',
  tl_test.d(:'p1') -> 'condition_immunities' @> '["charmed", "frightened", "disease"]'::jsonb
  and tl_test.d(:'p1') -> 'attack_riders' @> '[{"name": "Improved Divine Smite", "dice": "1d8", "once_per_turn": false}]'::jsonb);
select tl_test.setc(:'p1', 'paladin-phb', 14);
select tl_test.rec('PA13 Paladin 14: Cleansing Touch uses = CHA modifier (3)', (tl_test.res(:'p1', 'paladin-cleansing-touch-phb-uses') ->> 'max')::int = 3);

-- ---- progression snapshot ---------------------------------------------------------------------------------------------------
select tl_test.as_root();
create table tl_test.psnap (level int, pool int, aura text, oath int, smite boolean);
grant all on tl_test.psnap to public;
select tl_test.as_user(:'alice');
do $$
declare l int; ch uuid := 'f1a00000-0000-0000-0000-000000000001';
begin
  for l in 1..20 loop
    perform tl_test.setc(ch, 'paladin-phb', l);
    insert into tl_test.psnap values (l, (tl_test.res(ch, 'paladin-lay-on-hands-phb-pool') ->> 'max')::int,
      coalesce((select s ->> 'value' from jsonb_array_elements(tl_test.f(ch) -> 'classes' -> 0 -> 'features') f, jsonb_array_elements(f -> 'scaling') s
                where f ->> 'unlock_id' = 'paladin-phb-u6-aura-of-protection'), '-'),
      (select count(*) from jsonb_array_elements(public.get_character_spellbook(ch) -> 'spells') sp, jsonb_array_elements(sp -> 'grants') g
       where g ->> 'source_type' = 'class_feature' and (g ->> 'always_prepared')::boolean and (g ->> 'unlocked')::boolean),
      tl_test.d(ch) -> 'attack_riders' @> '[{"name": "Divine Smite"}]'::jsonb);
  end loop;
end $$;
select tl_test.rec('PA14 progression snapshot 1-20 (Lay on Hands pool, aura radius, oath spells, Divine Smite from 2)',
  (select string_agg(format('%s:%s/%s/%s/%s', level, pool, aura, oath, smite::int), ' ' order by level) from tl_test.psnap)
  = '1:5/-/0/0 2:10/-/0/1 3:15/-/2/1 4:20/-/2/1 5:25/-/4/1 6:30/10/4/1 7:35/10/4/1 8:40/10/4/1 9:45/10/6/1 10:50/10/6/1 11:55/10/6/1 '
    '12:60/10/6/1 13:65/10/8/1 14:70/10/8/1 15:75/10/8/1 16:80/10/8/1 17:85/10/10/1 18:90/30/10/1 19:95/30/10/1 20:100/30/10/1',
  (select string_agg(format('%s:%s/%s/%s/%s', level, pool, aura, oath, smite::int), ' ' order by level) from tl_test.psnap));

-- ---- multiclass / RLS ----------------------------------------------------------------------------------------------------------
select tl_test.setc(:'p3', 'rogue-phb', 2);
select tl_test.setc(:'p3', 'paladin-phb', 2);
select tl_test.rec('PA15 Paladin as a second class: martial weapons and shields, no heavy armor, no WIS / CHA saves',
  exists (select 1 from jsonb_array_elements(tl_test.d(:'p3') -> 'proficiencies') p where p ->> 'group_id' = 'martial-weapons')
  and not exists (select 1 from jsonb_array_elements(tl_test.d(:'p3') -> 'proficiencies') p where p ->> 'group_id' = 'heavy-armor')
  and not coalesce((tl_test.d(:'p3') -> 'saving_throws' -> 'cha' ->> 'class_proficient')::boolean, false));
select tl_test.as_user(:'bob');
select tl_test.rec('PA16 an outsider cannot spend Lay on Hands or read the auras',
  tl_test.raises($$select public.expend_character_resource('f1a00000-0000-0000-0000-000000000001', 'f:' || gen_random_uuid() || ':paladin-lay-on-hands-phb-pool', 5)$$) is not null
  and tl_test.raises($$select public.get_character_derived_stats('f1a00000-0000-0000-0000-000000000001')$$) is not null);
select tl_test.as_root();
