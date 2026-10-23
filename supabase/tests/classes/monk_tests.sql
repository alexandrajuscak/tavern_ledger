-- =============================================================================
-- Monk (monk-phb) and Way of the Open Hand (monk-open-hand-phb): Unarmored Defense (no shield), Martial Arts unarmed strike
-- (best of STR / DEX, die by level), Ki points and the Ki save DC (feature DC), Unarmored Movement (scaled speed, no armor /
-- shield), Purity of Body, Diamond Soul, Wholeness of Body, tool choice, progression, multiclass, RLS.
-- =============================================================================
\set m1 f1d00000-0000-0000-0000-000000000001
\set m2 f1d00000-0000-0000-0000-000000000002
insert into public.characters (id, owner_id, name, campaign_id, strength, dexterity, constitution, intelligence, wisdom, charisma) values
  (:'m1', :'alice', 'Monk Tester', :'camp', 10, 16, 12, 10, 16, 8),
  (:'m2', :'alice', 'Cleric then Monk', null, 10, 14, 12, 10, 16, 10);
create function tl_test.atk(p_char uuid, p_name text) returns jsonb language sql as $$
  select a from jsonb_array_elements(tl_test.d(p_char) -> 'feature_attacks') a where a ->> 'name' = p_name limit 1 $$;
create function tl_test.dc(p_char uuid, p_name text) returns int language sql as $$
  select (x ->> 'dc')::int from jsonb_array_elements(tl_test.d(p_char) -> 'feature_dcs') x where x ->> 'name' = p_name limit 1 $$;
create function tl_test.equip(p_char uuid, p_item text, p_slot text) returns void language plpgsql as $$
declare inv uuid; ii uuid;
begin
  select id into inv from public.inventories where character_id = p_char and kind = 'character';
  ii := public.add_inventory_item(inv, p_item, 1);
  perform public.equip_item(ii, p_slot);
end $$;
grant all on all functions in schema tl_test to public;

select tl_test.rec('MO1 Monk: every class level 1-20 is represented; tool choice offers artisan''s tools and instruments',
  tl_test.levels_represented('monk-phb') = 20
  and (select config -> 'from' ? 'lute' and config -> 'from' ? 'smiths-tools' from public.class_feature_choices where id = 'monk-proficiencies-phb-tools-choice'));

select tl_test.as_user(:'alice');
select tl_test.setc(:'m1', 'monk-phb', 1);
select tl_test.rec('MO2 Monk 1: AC 16 (10 + DEX 3 + WIS 3); unarmed strike +5 to hit, 1d4 + 3 bludgeoning; no Ki yet',
  (tl_test.d(:'m1') -> 'armor_class' ->> 'value')::int = 16
  and (tl_test.atk(:'m1', 'Unarmed Strike (Martial Arts)') ->> 'attack_bonus')::int = 5
  and tl_test.atk(:'m1', 'Unarmed Strike (Martial Arts)') ->> 'damage' = '1d4 + 3'
  and tl_test.res(:'m1', 'monk-ki-phb-points') is null,
  tl_test.atk(:'m1', 'Unarmed Strike (Martial Arts)')::text);
select tl_test.setc(:'m1', 'monk-phb', 2);
select tl_test.rec('MO3 Monk 2: Ki 2 points (short rest); Ki save DC 13 (8 + 2 + WIS 3); speed 40 (Unarmored Movement +10)',
  (tl_test.res(:'m1', 'monk-ki-phb-points') ->> 'max')::int = 2 and tl_test.res(:'m1', 'monk-ki-phb-points') ->> 'recharge' = 'short_or_long_rest'
  and tl_test.dc(:'m1', 'Ki save DC') = 13 and (tl_test.d(:'m1') -> 'speed' ->> 'value')::int = 40);
select public.expend_character_resource(:'m1', tl_test.rkey(:'m1', 'monk', 'monk-ki-phb-points'), 2);
select public.short_rest_character(:'m1');
select tl_test.rec('MO4 spending 2 ki and a short rest: Ki back to 2', (tl_test.res(:'m1', 'monk-ki-phb-points') ->> 'remaining')::int = 2);
select tl_test.equip(:'m1', 'shield', 'shield');
select tl_test.rec('MO5 with a shield: no Unarmored Defense (AC 10 + DEX 3 + shield 2 = 15) and no Unarmored Movement (speed 30)',
  (tl_test.d(:'m1') -> 'armor_class' ->> 'value')::int = 15 and (tl_test.d(:'m1') -> 'speed' ->> 'value')::int = 30,
  (tl_test.d(:'m1') -> 'armor_class')::text);
select public.unequip_item((select inventory_item_id from public.character_equipment where character_id = :'m1' and slot_id = 'shield'));

select tl_test.setc(:'m1', 'monk-phb', 6, 'monk-open-hand-phb');
select tl_test.rec('MO6 Open Hand 6: Wholeness of Body once per long rest (healing 18 shown); Martial Arts 1d6; speed 45',
  (tl_test.res(:'m1', 'monk-open-hand-wholeness-of-body-phb-uses') ->> 'max')::int = 1
  and tl_test.atk(:'m1', 'Unarmed Strike (Martial Arts)') ->> 'damage' = '1d6 + 3' and (tl_test.d(:'m1') -> 'speed' ->> 'value')::int = 45);
select tl_test.setc(:'m1', 'monk-phb', 10);
select tl_test.rec('MO7 Purity of Body: immune to poison damage, poisoned and disease',
  tl_test.d(:'m1') -> 'immunities' ? 'poison' and tl_test.d(:'m1') -> 'condition_immunities' @> '["disease", "poisoned"]'::jsonb,
  (tl_test.d(:'m1') -> 'immunities')::text || (tl_test.d(:'m1') -> 'condition_immunities')::text);
select tl_test.setc(:'m1', 'monk-phb', 14);
select tl_test.rec('MO8 Diamond Soul: proficient in all six saving throws',
  (select bool_and((tl_test.d(:'m1') -> 'saving_throws' -> a ->> 'class_proficient')::boolean) from unnest(array['str','dex','con','int','wis','cha']) a));

-- ---- progression snapshot ---------------------------------------------------------------------------------------------------
select tl_test.as_root();
create table tl_test.msnap (level int, ki int, die text, speed int, attacks int, dc int);
grant all on tl_test.msnap to public;
select tl_test.as_user(:'alice');
do $$
declare l int; ch uuid := 'f1d00000-0000-0000-0000-000000000001'; dd jsonb;
begin
  for l in 1..20 loop
    perform tl_test.setc(ch, 'monk-phb', l);
    dd := tl_test.d(ch);
    insert into tl_test.msnap values (l, coalesce((case when (tl_test.res(ch, 'monk-ki-phb-points') ->> 'active')::boolean then tl_test.res(ch, 'monk-ki-phb-points') ->> 'max' end)::int, 0),
      (select split_part(a ->> 'damage', ' ', 1) from jsonb_array_elements(dd -> 'feature_attacks') a where a ->> 'name' = 'Unarmed Strike (Martial Arts)'),
      (dd -> 'speed' ->> 'value')::int, (dd -> 'attacks_per_action' ->> 'value')::int,
      (select (x ->> 'dc')::int from jsonb_array_elements(dd -> 'feature_dcs') x where x ->> 'name' = 'Ki save DC'));
  end loop;
end $$;
select tl_test.rec('MO9 progression snapshot 1-20 (ki, Martial Arts die, speed, attacks, Ki DC)',
  (select string_agg(format('%s:%s/%s/%s/%s/%s', level, ki, die, speed, attacks, coalesce(dc::text, '-')), ' ' order by level) from tl_test.msnap)
  = '1:0/1d4/30/1/- 2:2/1d4/40/1/13 3:3/1d4/40/1/13 4:4/1d4/40/1/13 5:5/1d6/40/2/14 6:6/1d6/45/2/14 7:7/1d6/45/2/14 8:8/1d6/45/2/14 '
    '9:9/1d6/45/2/15 10:10/1d6/50/2/15 11:11/1d8/50/2/15 12:12/1d8/50/2/15 13:13/1d8/50/2/16 14:14/1d8/55/2/16 15:15/1d8/55/2/16 '
    '16:16/1d8/55/2/16 17:17/1d10/55/2/17 18:18/1d10/60/2/17 19:19/1d10/60/2/17 20:20/1d10/60/2/17',
  (select string_agg(format('%s:%s/%s/%s/%s/%s', level, ki, die, speed, attacks, coalesce(dc::text, '-')), ' ' order by level) from tl_test.msnap));

select tl_test.setc(:'m2', 'cleric-phb', 1);
select tl_test.setc(:'m2', 'monk-phb', 2);
select tl_test.rec('MO10 Monk as a second class: shortswords, no STR / DEX saves, no tool choice; Ki 2',
  exists (select 1 from jsonb_array_elements(tl_test.d(:'m2') -> 'proficiencies') p where p ->> 'item_id' = 'shortsword' or p ->> 'value' = 'shortsword')
  and not coalesce((tl_test.d(:'m2') -> 'saving_throws' -> 'str' ->> 'class_proficient')::boolean, false)
  and (tl_test.res(:'m2', 'monk-ki-phb-points') ->> 'max')::int = 2,
  (tl_test.d(:'m2') -> 'proficiencies')::text);
select tl_test.as_user(:'bob');
select tl_test.rec('MO11 an outsider cannot spend Ki or read the Monk derived values',
  tl_test.raises($$select public.expend_character_resource('f1d00000-0000-0000-0000-000000000001', 'f:' || gen_random_uuid() || ':monk-ki-phb-points', 1)$$) is not null
  and tl_test.raises($$select public.get_character_derived_stats('f1d00000-0000-0000-0000-000000000001')$$) is not null);
select tl_test.as_root();
