-- =============================================================================
-- Ranger (ranger-phb) and Hunter (ranger-hunter-phb): Favored Enemy / Natural Explorer and their Tasha's replacements
-- (Favored Foe, Deft Explorer, Primal Awareness, Nature's Veil: one of each pair active), choices growing by level, Primal
-- Awareness spells, Hunter options, progression, multiclass, RLS.
-- =============================================================================
\set g1 f1900000-0000-0000-0000-000000000001
\set g2 f1900000-0000-0000-0000-000000000002
insert into public.characters (id, owner_id, name, campaign_id, strength, dexterity, constitution, intelligence, wisdom, charisma) values
  (:'g1', :'alice', 'Ranger Tester', :'camp', 12, 16, 14, 10, 14, 8),
  (:'g2', :'alice', 'Fighter then Ranger', null, 16, 14, 14, 10, 14, 8);
create function tl_test.granted(p_char uuid, p_spell text) returns jsonb language sql as $$
  select g from jsonb_array_elements(tl_test.spell(p_char, p_spell) -> 'grants') g where g ->> 'source_type' = 'class_feature' limit 1 $$;
grant all on all functions in schema tl_test to public;

select tl_test.rec('RA1 Ranger: every class level 1-20 is represented', tl_test.levels_represented('ranger-phb') = 20);
select tl_test.rec('RA2 four Tasha''s replacements are optional unlocks that replace their PHB features',
  (select count(*) from public.class_feature_unlocks where class_version_id = 'ranger-phb' and replaces_unlock_id is not null and replacement_mode = 'replace') = 4);

select tl_test.as_user(:'alice');
select tl_test.setc(:'g1', 'ranger-phb', 1);
select tl_test.choose(:'g1', 'ranger', 'ranger-phb-u1-favored-enemy', 'ranger-favored-enemy-phb-enemies', '{undead}');
select tl_test.choose(:'g1', 'ranger', 'ranger-phb-u1-favored-enemy', 'ranger-favored-enemy-phb-languages', '{abyssal}');
select tl_test.rec('RA3 Favored Enemy: undead chosen, Abyssal learned; the tracking advantage is a situational reminder',
  exists (select 1 from jsonb_array_elements(tl_test.d(:'g1') -> 'languages') l where l ->> 'id' = 'abyssal')
  and exists (select 1 from jsonb_array_elements(tl_test.d(:'g1') -> 'situational_advantages') a where a ->> 'source_name' like '%Favored Enemy'));
select public.set_character_optional_feature(:'g1', tl_test.k(:'g1', 'ranger'), 'ranger-phb-u1-favored-foe', true);
select tl_test.rec('RA4 Favored Foe (optional) replaces Favored Enemy: Abyssal is gone, the 1d4 rider and PB uses appear, the old choices are kept',
  tl_test.ust(:'g1', 'ranger-phb-u1-favored-enemy') = 'replaced'
  and not exists (select 1 from jsonb_array_elements(tl_test.d(:'g1') -> 'languages') l where l ->> 'id' = 'abyssal')
  and tl_test.d(:'g1') -> 'attack_riders' @> '[{"name": "Favored Foe", "dice": "1d4", "once_per_turn": true}]'::jsonb
  and (tl_test.res(:'g1', 'ranger-favored-foe-tce-uses') ->> 'max')::int = 2
  and exists (select 1 from public.character_feature_choices where character_id = :'g1' and unlock_id = 'ranger-phb-u1-favored-enemy'));
select tl_test.choose(:'g1', 'ranger', 'ranger-phb-u1-proficiencies', 'ranger-proficiencies-phb-skills', '{stealth,survival,perception}');
select public.set_character_optional_feature(:'g1', tl_test.k(:'g1', 'ranger'), 'ranger-phb-u1-deft-explorer', true);
select tl_test.choose(:'g1', 'ranger', 'ranger-phb-u1-deft-explorer', 'ranger-deft-explorer-tce-canny-skill', '{survival}');
select tl_test.choose(:'g1', 'ranger', 'ranger-phb-u1-deft-explorer', 'ranger-deft-explorer-tce-canny-languages', '{elvish,sylvan}');
select tl_test.rec('RA5 Deft Explorer replaces Natural Explorer: Survival expertise and two languages',
  tl_test.ust(:'g1', 'ranger-phb-u1-natural-explorer') = 'replaced' and (tl_test.d(:'g1') -> 'skills' -> 'survival' ->> 'class_expertise')::boolean
  and exists (select 1 from jsonb_array_elements(tl_test.d(:'g1') -> 'languages') l where l ->> 'id' = 'sylvan'));

select tl_test.setc(:'g1', 'ranger-phb', 3, 'ranger-hunter-phb');
select public.set_character_optional_feature(:'g1', tl_test.k(:'g1', 'ranger'), 'ranger-phb-u3-primal-awareness', true);
select tl_test.rec('RA6 Primal Awareness replaces Primeval Awareness: Speak with Animals known, not counted against spells known; 1 free cast',
  tl_test.ust(:'g1', 'ranger-phb-u3-primeval-awareness') = 'replaced'
  and not (tl_test.granted(:'g1', 'speak-with-animals-phb') ->> 'counts_against_known_limit')::boolean
  and (tl_test.res(:'g1', 'ranger-primal-awareness-tce-free-casts') ->> 'max')::int = 1);
select tl_test.choose(:'g1', 'ranger', 'ranger-hunter-phb-u3-hunters-prey', 'ranger-hunter-hunters-prey-phb-prey', '{colossus-slayer}');
select tl_test.rec('RA7 Hunter''s Prey: Colossus Slayer is a 1d8 once-per-turn rider',
  tl_test.d(:'g1') -> 'attack_riders' @> '[{"name": "Colossus Slayer", "dice": "1d8", "once_per_turn": true}]'::jsonb);
select tl_test.setc(:'g1', 'ranger-phb', 7);
select tl_test.choose(:'g1', 'ranger', 'ranger-hunter-phb-u7-defensive-tactics', 'ranger-hunter-defensive-tactics-phb-tactics', '{steel-will}');
select tl_test.rec('RA8 Steel Will is a situational save advantage (frightened); Deft Explorer Roving: speed 35',
  exists (select 1 from jsonb_array_elements(tl_test.d(:'g1') -> 'situational_advantages') a where a ->> 'condition' = 'Against being frightened')
  and (tl_test.d(:'g1') -> 'speed' ->> 'value')::int = 35);
select tl_test.setc(:'g1', 'ranger-phb', 10);
select public.set_character_optional_feature(:'g1', tl_test.k(:'g1', 'ranger'), 'ranger-phb-u10-natures-veil', true);
select tl_test.rec('RA9 Nature''s Veil replaces Hide in Plain Sight; uses = PB (4); Deft Explorer Tireless uses = PB',
  tl_test.ust(:'g1', 'ranger-phb-u10-hide-in-plain-sight') = 'replaced' and (tl_test.res(:'g1', 'ranger-natures-veil-tce-uses') ->> 'max')::int = 4
  and (tl_test.res(:'g1', 'ranger-deft-explorer-tce-tireless') ->> 'max')::int = 4);
select public.set_character_optional_feature(:'g1', tl_test.k(:'g1', 'ranger'), 'ranger-phb-u1-favored-foe', false);
select tl_test.rec('RA10 switching Favored Foe off at Ranger 10 brings Favored Enemy back with its stored choice, now needing a second pick',
  tl_test.ust(:'g1', 'ranger-phb-u1-favored-enemy') = 'active'
  and tl_test.ch(:'g1', 'ranger', 'ranger-phb-u1-favored-enemy:ranger-favored-enemy-phb-enemies') ->> 'status' = 'incomplete'
  and (tl_test.ch(:'g1', 'ranger', 'ranger-phb-u1-favored-enemy:ranger-favored-enemy-phb-enemies') ->> 'max')::int = 2);

-- ---- progression snapshot ---------------------------------------------------------------------------------------------------
select public.set_character_optional_feature(:'g1', tl_test.k(:'g1', 'ranger'), 'ranger-phb-u1-favored-foe', true);
select tl_test.as_root();
create table tl_test.gsnap (level int, foe text, attacks int, free int);
grant all on tl_test.gsnap to public;
select tl_test.as_user(:'alice');
do $$
declare l int; ch uuid := 'f1900000-0000-0000-0000-000000000001';
begin
  for l in 1..20 loop
    perform tl_test.setc(ch, 'ranger-phb', l);
    insert into tl_test.gsnap values (l, (select r ->> 'dice' from jsonb_array_elements(tl_test.d(ch) -> 'attack_riders') r where r ->> 'name' = 'Favored Foe'),
      (tl_test.d(ch) -> 'attacks_per_action' ->> 'value')::int,
      coalesce((case when (tl_test.res(ch, 'ranger-primal-awareness-tce-free-casts') ->> 'active')::boolean then tl_test.res(ch, 'ranger-primal-awareness-tce-free-casts') ->> 'max' end)::int, 0));
  end loop;
end $$;
select tl_test.rec('RA11 progression snapshot 1-20 (Favored Foe die, attacks, Primal Awareness free casts)',
  (select string_agg(format('%s:%s/%s/%s', level, foe, attacks, free), ' ' order by level) from tl_test.gsnap)
  = '1:1d4/1/0 2:1d4/1/0 3:1d4/1/1 4:1d4/1/1 5:1d4/2/2 6:1d6/2/2 7:1d6/2/2 8:1d6/2/2 9:1d6/2/3 10:1d6/2/3 11:1d6/2/3 12:1d6/2/3 '
    '13:1d6/2/4 14:1d8/2/4 15:1d8/2/4 16:1d8/2/4 17:1d8/2/5 18:1d8/2/5 19:1d8/2/5 20:1d8/2/5',
  (select string_agg(format('%s:%s/%s/%s', level, foe, attacks, free), ' ' order by level) from tl_test.gsnap));

select tl_test.setc(:'g2', 'fighter-phb', 1);
select tl_test.setc(:'g2', 'ranger-phb', 1);
select tl_test.rec('RA12 Ranger as a second class: one Ranger skill, no STR / DEX saves from the Ranger',
  (tl_test.ch(:'g2', 'ranger', 'ranger-phb-u1-proficiencies:ranger-proficiencies-phb-skills-multiclass') ->> 'max')::int = 1
  and not coalesce((tl_test.d(:'g2') -> 'saving_throws' -> 'dex' ->> 'class_proficient')::boolean, false));
select tl_test.as_user(:'bob');
select tl_test.rec('RA13 an outsider cannot switch the Ranger''s optional features',
  tl_test.raises($$select public.set_character_optional_feature('f1900000-0000-0000-0000-000000000001', (select id from public.character_classes where character_id = 'f1900000-0000-0000-0000-000000000001'), 'ranger-phb-u1-favored-foe', false)$$) is not null);
select tl_test.as_root();
