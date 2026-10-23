-- =============================================================================
-- Fighter (fighter-phb) and Champion (fighter-champion-phb): catalog, progression 1-20, choices, resources, rests,
-- derived values, subclass, multiclass, level decrease, class removal, export / import, RLS.
-- Run with _harness.sql before and _report.sql after (the runners do this).
-- =============================================================================
\set f1 f1f00000-0000-0000-0000-000000000001
\set f2 f1f00000-0000-0000-0000-000000000002
\set f3 f1f00000-0000-0000-0000-000000000003
\set f4 f1f00000-0000-0000-0000-000000000004
insert into public.characters (id, owner_id, name, campaign_id, strength, dexterity, constitution, intelligence, wisdom, charisma) values
  (:'f1', :'alice', 'Fighter Tester', :'camp', 16, 14, 14, 10, 12, 8),
  (:'f2', :'alice', 'Wizard then Fighter', null, 13, 14, 12, 16, 12, 10),
  (:'f3', :'alice', 'Fighter Import Target', null, 16, 14, 14, 10, 12, 8),
  (:'f4', :'alice', 'Fighter Style Tester', null, 16, 14, 14, 10, 12, 8);

-- ---- catalog ------------------------------------------------------------------------------------------------------------------
select tl_test.rec('FI1 Fighter: every class level 1-20 is represented (class unlocks, Champion unlocks, scaling thresholds)',
  tl_test.levels_represented('fighter-phb') = 20, tl_test.levels_represented('fighter-phb')::text);
select tl_test.rec('FI2 class metadata: d10, STR or DEX primary, STR and CON saves, two skills from eight, subclass at 3, complete',
  (select hit_die = 'd10' and primary_abilities = '{str,dex}' and saving_throws = '{str,con}' and (skill_choice ->> 'count')::int = 2
          and jsonb_array_length(skill_choice -> 'from') = 8 and subclass_level = 3 and feature_status = 'complete'
   from public.class_versions where id = 'fighter-phb'));
select tl_test.rec('FI3 seven Ability Score Improvement unlocks (4, 6, 8, 12, 14, 16, 19) share one repeatable feature version',
  (select array_agg(level order by level) = '{4,6,8,12,14,16,19}' and count(distinct feature_version_id) = 1
   from public.class_feature_unlocks where class_version_id = 'fighter-phb' and feature_version_id = 'fighter-asi-phb')
  and (select repeatable from public.class_feature_versions where id = 'fighter-asi-phb'));
select tl_test.rec('FI4 every Fighter feature has a source link, a short summary and an automation status',
  not exists (select 1 from public.class_feature_versions v join public.class_features f on f.id = v.feature_id
              where f.class_id = 'fighter' and (v.source_url !~ '^https://dnd5e\.wikidot\.com/fighter' or length(v.summary) > 600
                                                or v.automation not in ('automated', 'partially_automated', 'informational'))));
select tl_test.rec('FI5 fighting styles: official, Tasha''s optional and UA playtest options are separated; UA needs DM permission',
  (select count(*) from public.class_feature_choice_options where choice_id = 'fighter-fighting-style-phb-style') = 14
  and (select count(*) from public.class_feature_choice_options where choice_id = 'fighter-fighting-style-phb-style' and data ->> 'status' = 'playtest'
         and prerequisites::text like '%DM permission%' and label like '%(UA)') = 3
  and (select data ->> 'status' from public.class_feature_choice_options where choice_id = 'fighter-fighting-style-phb-style' and option_id = 'interception') = 'optional_rule');
select tl_test.rec('FI6 the subclass catalog lists 10 official Fighter archetypes (Champion complete, Eldritch Knight progression, Echo Knight setting-specific)',
  (select count(*) from public.subclass_versions where class_id = 'fighter') = 10
  and (select implementation_status from public.subclass_versions where id = 'fighter-champion-phb') = 'complete'
  and (select implementation_status from public.subclass_versions where id = 'fighter-eldritch-knight-phb') = 'progression_only'
  and (select source_status = 'setting' and requires_dm_permission from public.subclass_versions where id = 'fighter-echo-knight-egw')
  and (select implementation_status from public.subclass_versions where id = 'fighter-battle-master-phb') = 'catalog_only');
select tl_test.rec('FI7 starting equipment: four choice lines with two options each, all items resolved in the catalog',
  (select count(*) = 8 and bool_and(resolved) and count(distinct choice_group) = 4 from public.class_starting_equipment where class_version_id = 'fighter-phb'));

-- ---- level 1 ------------------------------------------------------------------------------------------------------------------
select tl_test.as_user(:'alice');
select tl_test.setc(:'f1', 'fighter-phb', 1);
select tl_test.rec('FI8 Fighter 1: Proficiencies, Fighting Style and Second Wind are active; Action Surge is not yet',
  tl_test.active(:'f1', 'fighter-phb-u1-proficiencies') and tl_test.active(:'f1', 'fighter-phb-u1-fighting-style')
  and tl_test.active(:'f1', 'fighter-phb-u1-second-wind') and tl_test.ust(:'f1', 'fighter-phb-u2-action-surge') = 'locked');
select tl_test.rec('FI9 first class: STR and CON saving throws and heavy armor come from the class',
  (tl_test.d(:'f1') -> 'saving_throws' -> 'str' ->> 'class_proficient')::boolean and (tl_test.d(:'f1') -> 'saving_throws' -> 'con' ->> 'class_proficient')::boolean
  and exists (select 1 from jsonb_array_elements(tl_test.d(:'f1') -> 'proficiencies') p where p ->> 'group_id' = 'heavy-armor' and p ->> 'source_type' = 'class'));
select tl_test.rec('FI10 the two skills and the fighting style are listed as incomplete choices',
  tl_test.ch(:'f1', 'fighter', 'fighter-phb-u1-proficiencies:fighter-proficiencies-phb-skills') ->> 'status' = 'incomplete'
  and tl_test.ch(:'f1', 'fighter', 'fighter-phb-u1-fighting-style:fighter-fighting-style-phb-style') ->> 'status' = 'incomplete'
  and tl_test.incomplete(:'f1') = 2);
select tl_test.rec('FI11 a skill outside the Fighter list is refused',
  tl_test.raises($$select tl_test.choose('f1f00000-0000-0000-0000-000000000001', 'fighter', 'fighter-phb-u1-proficiencies', 'fighter-proficiencies-phb-skills', '{athletics,arcana}')$$) like '%not an allowed skill%');
select tl_test.choose(:'f1', 'fighter', 'fighter-phb-u1-proficiencies', 'fighter-proficiencies-phb-skills', '{athletics,perception}');
select tl_test.choose(:'f1', 'fighter', 'fighter-phb-u1-fighting-style', 'fighter-fighting-style-phb-style', '{archery}');
select tl_test.give(:'f1', 'longbow', 'main_hand') \gset bow_
select tl_test.rec('FI12 Archery: +2 to the longbow attack (DEX 2 + PB 2 + Archery 2 = +6); skills are class proficient',
  (select (w ->> 'attack_bonus')::int = 6 and (w ->> 'class_attack_bonus')::int = 2
   from jsonb_array_elements(tl_test.d(:'f1') -> 'equipped_weapon_attacks') w where w ->> 'item_id' = 'longbow')
  and (tl_test.d(:'f1') -> 'skills' -> 'athletics' ->> 'class_proficient')::boolean and tl_test.incomplete(:'f1') = 0);

-- ---- resources and rests --------------------------------------------------------------------------------------------------------
select tl_test.rec('FI13 Second Wind: 1 use, short or long rest, healing 1d10 + 1 shown',
  (tl_test.res(:'f1', 'fighter-second-wind-phb-uses') ->> 'max')::int = 1 and tl_test.res(:'f1', 'fighter-second-wind-phb-uses') ->> 'recharge' = 'short_or_long_rest'
  and exists (select 1 from jsonb_array_elements(tl_test.f(:'f1') -> 'classes' -> 0 -> 'features') f, jsonb_array_elements(f -> 'scaling') s
              where f ->> 'unlock_id' = 'fighter-phb-u1-second-wind' and s ->> 'value' = '"1d10 + 1"' or s -> 'value' = '"1d10 + 1"'::jsonb));
select public.expend_character_resource(:'f1', tl_test.rkey(:'f1', 'fighter', 'fighter-second-wind-phb-uses'));
select tl_test.rec('FI14 a second use of Second Wind is refused (0 left)',
  tl_test.raises($$select public.expend_character_resource('f1f00000-0000-0000-0000-000000000001', tl_test.rkey('f1f00000-0000-0000-0000-000000000001', 'fighter', 'fighter-second-wind-phb-uses'))$$) like '%Not enough%');
select public.short_rest_character(:'f1');
select tl_test.rec('FI15 a short rest restores Second Wind',
  (tl_test.res(:'f1', 'fighter-second-wind-phb-uses') ->> 'remaining')::int = 1);

-- ---- progression ------------------------------------------------------------------------------------------------------------------
select tl_test.setc(:'f1', 'fighter-phb', 2);
select tl_test.rec('FI16 Fighter 2: Action Surge 1 use, short or long rest',
  (tl_test.res(:'f1', 'fighter-action-surge-phb-uses') ->> 'max')::int = 1 and tl_test.res(:'f1', 'fighter-action-surge-phb-uses') ->> 'recharge' = 'short_or_long_rest');
select tl_test.setc(:'f1', 'fighter-phb', 3);
select tl_test.rec('FI17 Fighter 3 without an archetype: subclass warning; the Champion can be chosen',
  tl_test.warn(:'f1', 'subclass_not_chosen')
  and exists (select 1 from jsonb_array_elements(tl_test.f(:'f1') -> 'classes' -> 0 -> 'subclass' -> 'options') o where o ->> 'id' = 'fighter-champion-phb'));
select public.set_character_subclass(:'f1', tl_test.k(:'f1', 'fighter'), 'fighter-champion-phb');
select tl_test.rec('FI18 Champion 3: Improved Critical makes the critical range 19-20',
  (tl_test.d(:'f1') -> 'critical_range' ->> 'value')::int = 19 and not tl_test.warn(:'f1', 'subclass_not_chosen'));
select tl_test.setc(:'f1', 'fighter-phb', 4);
select tl_test.rec('FI19 Fighter 4: the ASI is an incomplete choice; Martial Versatility is an optional feature (not selected)',
  tl_test.ch(:'f1', 'fighter', 'fighter-phb-u4-asi:fighter-asi-phb-asi') ->> 'status' = 'incomplete'
  and tl_test.ust(:'f1', 'fighter-phb-u4-martial-versatility') = 'available');
select tl_test.choose(:'f1', 'fighter', 'fighter-phb-u4-asi', 'fighter-asi-phb-asi', '{str:2}');
select tl_test.rec('FI20 ASI +2 STR: Strength 16 -> 18 (derived, the stored score is unchanged)',
  (tl_test.d(:'f1') -> 'abilities' -> 'str' ->> 'score')::int = 18 and (select strength from public.characters where id = :'f1') = 16);
select tl_test.setc(:'f1', 'fighter-phb', 5);
select tl_test.rec('FI21 Fighter 5: Extra Attack, two attacks per Attack action',
  (tl_test.d(:'f1') -> 'attacks_per_action' ->> 'value')::int = 2);
select tl_test.setc(:'f1', 'fighter-phb', 7);
select tl_test.rec('FI22 Champion 7: Remarkable Athlete adds half PB rounded up (+2 at PB 3) to STR/DEX/CON checks and initiative',
  (tl_test.d(:'f1') -> 'check_half_proficiency' ->> 'value')::int = 2
  and tl_test.d(:'f1') -> 'check_half_proficiency' -> 'abilities' = '["str", "dex", "con"]'::jsonb
  and (tl_test.d(:'f1') -> 'skills' -> 'acrobatics' -> 'half_proficiency' ->> 'value')::int = 2
  and tl_test.d(:'f1') -> 'skills' -> 'arcana' -> 'half_proficiency' is null
  and (tl_test.d(:'f1') -> 'initiative' ->> 'bonus')::int = 2);
select tl_test.setc(:'f1', 'fighter-phb', 10);
select tl_test.rec('FI23 Champion 10: the Additional Fighting Style cannot repeat Archery',
  tl_test.raises($$select tl_test.choose('f1f00000-0000-0000-0000-000000000001', 'fighter', 'fighter-champion-phb-u10-additional-fighting-style', 'fighter-champion-additional-fighting-style-phb-style', '{archery}')$$)
    like '%already chosen%');
select tl_test.choose(:'f1', 'fighter', 'fighter-champion-phb-u10-additional-fighting-style', 'fighter-champion-additional-fighting-style-phb-style', '{defense}');
select tl_test.give(:'f1', 'chain-mail', 'armor') \gset mail_
select tl_test.rec('FI24 Defense from the second style: chain mail 16 + 1 = AC 17',
  (tl_test.d(:'f1') -> 'armor_class' ->> 'value')::int = 17);
select tl_test.setc(:'f1', 'fighter-phb', 11);
select tl_test.rec('FI25 Fighter 11: three attacks', (tl_test.d(:'f1') -> 'attacks_per_action' ->> 'value')::int = 3);
select tl_test.setc(:'f1', 'fighter-phb', 13);
select tl_test.rec('FI26 Fighter 13: Indomitable 2 uses, long rest only',
  (tl_test.res(:'f1', 'fighter-indomitable-phb-uses') ->> 'max')::int = 2 and tl_test.res(:'f1', 'fighter-indomitable-phb-uses') ->> 'recharge' = 'long_rest');
select public.expend_character_resource(:'f1', tl_test.rkey(:'f1', 'fighter', 'fighter-indomitable-phb-uses'));
select public.short_rest_character(:'f1');
select tl_test.rec('FI27 a short rest does not restore Indomitable; a long rest does',
  (tl_test.res(:'f1', 'fighter-indomitable-phb-uses') ->> 'remaining')::int = 1
  and (select (public.long_rest_character(:'f1') -> 'breakdown' -> 'restored') @> '[{"name": "Indomitable"}]'::jsonb)
  and (tl_test.res(:'f1', 'fighter-indomitable-phb-uses') ->> 'remaining')::int = 2);
select tl_test.setc(:'f1', 'fighter-phb', 15);
select tl_test.rec('FI28 Champion 15: Superior Critical, critical range 18-20', (tl_test.d(:'f1') -> 'critical_range' ->> 'value')::int = 18);
select tl_test.setc(:'f1', 'fighter-phb', 17);
select tl_test.rec('FI29 Fighter 17: Action Surge 2 uses, Indomitable 3 uses',
  (tl_test.res(:'f1', 'fighter-action-surge-phb-uses') ->> 'max')::int = 2 and (tl_test.res(:'f1', 'fighter-indomitable-phb-uses') ->> 'max')::int = 3);
select tl_test.setc(:'f1', 'fighter-phb', 18);
select tl_test.rec('FI30 Champion 18: Survivor is shown as informational (no automatic healing)',
  (select f ->> 'automation' = 'informational' and (f ->> 'active')::boolean
   from jsonb_array_elements(tl_test.f(:'f1') -> 'classes' -> 0 -> 'features') f where f ->> 'unlock_id' = 'fighter-champion-phb-u18-survivor'));
select tl_test.setc(:'f1', 'fighter-phb', 20);
select tl_test.rec('FI31 Fighter 20: four attacks; seven ASI choices open (six incomplete)',
  (tl_test.d(:'f1') -> 'attacks_per_action' ->> 'value')::int = 4
  and (select count(*) from jsonb_array_elements(tl_test.f(:'f1') -> 'incomplete_choices') x where x ->> 'kind' = 'asi') = 6);

-- ---- progression snapshot: attacks, critical range and resource maximums at every level ---------------------------------------
select tl_test.as_root();
create table tl_test.snap (level int, attacks int, crit int, second_wind int, surge int, indomitable int);
grant all on tl_test.snap to public;
select tl_test.as_user(:'alice');
do $$
declare l int; ch uuid := 'f1f00000-0000-0000-0000-000000000001';
begin
  for l in 1..20 loop
    perform tl_test.setc(ch, 'fighter-phb', l);
    insert into tl_test.snap values (l, (tl_test.d(ch) -> 'attacks_per_action' ->> 'value')::int, (tl_test.d(ch) -> 'critical_range' ->> 'value')::int,
      coalesce((case when (tl_test.res(ch, 'fighter-second-wind-phb-uses') ->> 'active')::boolean then tl_test.res(ch, 'fighter-second-wind-phb-uses') ->> 'max' end)::int, 0),
      coalesce((case when (tl_test.res(ch, 'fighter-action-surge-phb-uses') ->> 'active')::boolean then tl_test.res(ch, 'fighter-action-surge-phb-uses') ->> 'max' end)::int, 0),
      coalesce((case when (tl_test.res(ch, 'fighter-indomitable-phb-uses') ->> 'active')::boolean then tl_test.res(ch, 'fighter-indomitable-phb-uses') ->> 'max' end)::int, 0));
  end loop;
end $$;
select tl_test.rec('FI32 progression snapshot 1-20 (attacks, critical range with Champion, Second Wind / Action Surge / Indomitable)',
  (select string_agg(format('%s:%s/%s/%s/%s/%s', level, attacks, crit, second_wind, surge, indomitable), ' ' order by level) from tl_test.snap)
  = '1:1/20/1/0/0 2:1/20/1/1/0 3:1/19/1/1/0 4:1/19/1/1/0 5:2/19/1/1/0 6:2/19/1/1/0 7:2/19/1/1/0 8:2/19/1/1/0 9:2/19/1/1/1 10:2/19/1/1/1 '
    '11:3/19/1/1/1 12:3/19/1/1/1 13:3/19/1/1/2 14:3/19/1/1/2 15:3/18/1/1/2 16:3/18/1/1/2 17:3/18/1/2/3 18:3/18/1/2/3 19:3/18/1/2/3 20:4/18/1/2/3',
  (select string_agg(format('%s:%s/%s/%s/%s/%s', level, attacks, crit, second_wind, surge, indomitable), ' ' order by level) from tl_test.snap));

-- ---- level decrease keeps choices ---------------------------------------------------------------------------------------------------
select tl_test.setc(:'f1', 'fighter-phb', 2);
select tl_test.rec('FI33 lowering to 2: Extra Attack and the Champion are inactive, the critical range is back to 20, choices are kept',
  (tl_test.d(:'f1') -> 'attacks_per_action' ->> 'value')::int = 1 and (tl_test.d(:'f1') -> 'critical_range' ->> 'value')::int = 20
  and tl_test.warn(:'f1', 'subclass_below_level')
  and tl_test.ch(:'f1', 'fighter', 'fighter-champion-phb-u10-additional-fighting-style:fighter-champion-additional-fighting-style-phb-style') ->> 'status' = 'inactive_preserved'
  and (select count(*) from public.character_feature_choices where character_id = :'f1') >= 4);
select tl_test.setc(:'f1', 'fighter-phb', 10);
select tl_test.rec('FI34 raising to 10 again restores the Champion features and both styles (AC 17 again)',
  (tl_test.d(:'f1') -> 'critical_range' ->> 'value')::int = 19 and (tl_test.d(:'f1') -> 'armor_class' ->> 'value')::int = 17);

-- ---- export / import ---------------------------------------------------------------------------------------------------------------
select public.expend_character_resource(:'f1', tl_test.rkey(:'f1', 'fighter', 'fighter-action-surge-phb-uses'));
select public.export_character_class_features(:'f1') as fexp \gset
select tl_test.setc(:'f3', 'fighter-phb', 10, 'fighter-champion-phb');
select public.import_character_class_features(:'f3', (:'fexp')::jsonb || jsonb_build_object('classRows',
  jsonb_build_object(tl_test.k(:'f1', 'fighter')::text, tl_test.k(:'f3', 'fighter')::text))) as fimp \gset
select tl_test.rec('FI35 export / import: choices (skills, two styles, ASI) and resource use come back; nothing unresolved',
  (:'fimp')::jsonb -> 'unresolved' = '[]'::jsonb
  and tl_test.ch(:'f3', 'fighter', 'fighter-phb-u1-fighting-style:fighter-fighting-style-phb-style') -> 'values' = '["archery"]'::jsonb
  and tl_test.ch(:'f3', 'fighter', 'fighter-champion-phb-u10-additional-fighting-style:fighter-champion-additional-fighting-style-phb-style') -> 'values' = '["defense"]'::jsonb
  and (tl_test.res(:'f3', 'fighter-action-surge-phb-uses') ->> 'expended')::int = 1
  and (tl_test.d(:'f3') -> 'abilities' -> 'str' ->> 'score')::int = 18, (:'fimp')::text);

-- ---- multiclass ------------------------------------------------------------------------------------------------------------------
select tl_test.setc(:'f2', 'wizard-phb', 1);
select tl_test.setc(:'f2', 'fighter-phb', 1);
select tl_test.rec('FI36 Fighter as a second class: no STR / CON save proficiency, no heavy armor; martial weapons, medium armor and shields',
  not coalesce((tl_test.d(:'f2') -> 'saving_throws' -> 'str' ->> 'class_proficient')::boolean, false)
  and not exists (select 1 from jsonb_array_elements(tl_test.d(:'f2') -> 'proficiencies') p where p ->> 'group_id' = 'heavy-armor')
  and exists (select 1 from jsonb_array_elements(tl_test.d(:'f2') -> 'proficiencies') p where p ->> 'group_id' = 'martial-weapons')
  and exists (select 1 from jsonb_array_elements(tl_test.d(:'f2') -> 'proficiencies') p where p ->> 'group_id' = 'medium-armor')
  and tl_test.ch(:'f2', 'fighter', 'fighter-phb-u1-proficiencies:fighter-proficiencies-phb-skills') ->> 'status' = 'not_applicable');

-- ---- shared fighting-style catalog behaviour -------------------------------------------------------------------------------------------
select tl_test.setc(:'f4', 'fighter-phb', 1);
select tl_test.choose(:'f4', 'fighter', 'fighter-phb-u1-fighting-style', 'fighter-fighting-style-phb-style', '{superior-technique}');
select tl_test.rec('FI37 Superior Technique: opens a maneuver choice (23 maneuvers) and a d6 superiority die (short or long rest)',
  tl_test.ch(:'f4', 'fighter', 'fighter-phb-u1-fighting-style:fighter-fighting-style-phb-superior-technique-maneuver') ->> 'status' = 'incomplete'
  and jsonb_array_length(tl_test.ch(:'f4', 'fighter', 'fighter-phb-u1-fighting-style:fighter-fighting-style-phb-superior-technique-maneuver') -> 'options') = 23
  and tl_test.res(:'f4', 'fighter-fighting-style-phb-superior-technique-die') ->> 'die' = 'd6'
  and (tl_test.res(:'f4', 'fighter-fighting-style-phb-superior-technique-die') ->> 'max')::int = 1);
select tl_test.choose(:'f4', 'fighter', 'fighter-phb-u1-fighting-style', 'fighter-fighting-style-phb-style', '{blind-fighting}');
select tl_test.rec('FI38 switching the style (replaceable): Blind Fighting gives blindsight 10 ft; the superiority die is gone',
  (tl_test.d(:'f4') -> 'senses' -> 'blindsight' ->> 'value')::int = 10 and tl_test.res(:'f4', 'fighter-fighting-style-phb-superior-technique-die') is null);
select tl_test.choose(:'f4', 'fighter', 'fighter-phb-u1-fighting-style', 'fighter-fighting-style-phb-style', '{unarmed-fighting}');
select tl_test.rec('FI39 Unarmed Fighting: unarmed strike 1d8 + 3 with no weapon or shield',
  (select a ->> 'damage' = '1d8 + 3' from jsonb_array_elements(tl_test.d(:'f4') -> 'feature_attacks') a where a ->> 'name' like 'Unarmed Strike%'));
select tl_test.give(:'f4', 'longsword', 'main_hand') \gset ls_
select tl_test.rec('FI40 ... and 1d6 + 3 while a weapon is held',
  (select a ->> 'damage' = '1d6 + 3' from jsonb_array_elements(tl_test.d(:'f4') -> 'feature_attacks') a where a ->> 'name' like 'Unarmed Strike%'));
select tl_test.choose(:'f4', 'fighter', 'fighter-phb-u1-fighting-style', 'fighter-fighting-style-phb-style', '{dueling}');
select tl_test.rec('FI41 Dueling: longsword alone in hand deals 1d8 + 5 (STR 3 + Dueling 2)',
  (select w ->> 'damage' = '1d8 + 5' from jsonb_array_elements(tl_test.d(:'f4') -> 'equipped_weapon_attacks') w where w ->> 'item_id' = 'longsword'));
select tl_test.choose(:'f4', 'fighter', 'fighter-phb-u1-fighting-style', 'fighter-fighting-style-phb-style', '{thrown-weapon-fighting}');
select public.unequip_item(:'ls_give');
select tl_test.give(:'f4', 'javelin', 'main_hand') \gset jav_
select tl_test.rec('FI42 Thrown Weapon Fighting: +2 shown as a conditional bonus on the javelin, not added to its melee damage',
  (select w -> 'conditional_bonuses' @> '[{"value": 2, "condition": "thrown"}]'::jsonb and w ->> 'damage' = '1d6 + 3'
   from jsonb_array_elements(tl_test.d(:'f4') -> 'equipped_weapon_attacks') w where w ->> 'item_id' = 'javelin'));
select tl_test.choose(:'f4', 'fighter', 'fighter-phb-u1-fighting-style', 'fighter-fighting-style-phb-style', '{mariner}');
select tl_test.rec('FI43 a UA style is accepted only as a playtest option: a DM-permission warning is shown until confirmed',
  tl_test.warn(:'f4', 'prerequisite_confirm'));

-- ---- class removal ----------------------------------------------------------------------------------------------------------------
select public.remove_character_class(tl_test.k(:'f4', 'fighter'), true);
select tl_test.rec('FI44 removing the Fighter class removes its choices and resource state, nothing else',
  not exists (select 1 from public.character_feature_choices where character_id = :'f4')
  and not exists (select 1 from public.character_resources where character_id = :'f4' and feature_resource_id is not null)
  and exists (select 1 from public.inventory_items ii join public.inventories i on i.id = ii.inventory_id where i.character_id = :'f4'));

-- ---- RLS ---------------------------------------------------------------------------------------------------------------------------
select tl_test.as_user(:'bob');
select tl_test.rec('FI45 an outsider cannot read the Fighter state or spend Second Wind',
  tl_test.raises($$select public.get_character_class_features('f1f00000-0000-0000-0000-000000000001')$$) is not null
  and tl_test.raises($$select public.expend_character_resource('f1f00000-0000-0000-0000-000000000001', 'f:' || (select id from public.character_classes limit 1) || ':fighter-second-wind-phb-uses')$$) is not null);
select tl_test.as_user(:'dm');
select tl_test.rec('FI46 the campaign DM reads the Fighter features and resources',
  jsonb_array_length(public.get_character_class_features(:'f1') -> 'classes') = 1
  and jsonb_array_length(public.get_character_resources(:'f1') -> 'resources') >= 3);
select tl_test.as_root();
