-- =============================================================================
-- Rogue (rogue-phb) and Thief (rogue-thief-phb): catalog, progression 1-20, Expertise (skills and thieves' tools),
-- Sneak Attack dice, resources, subclass, multiclass, level decrease, RLS.
-- Run with _harness.sql before and _report.sql after (the runners do this).
-- =============================================================================
\set r1 f1e00000-0000-0000-0000-000000000001
\set r2 f1e00000-0000-0000-0000-000000000002
insert into public.characters (id, owner_id, name, campaign_id, strength, dexterity, constitution, intelligence, wisdom, charisma) values
  (:'r1', :'alice', 'Rogue Tester', :'camp', 10, 16, 14, 12, 12, 10),
  (:'r2', :'alice', 'Fighter then Rogue', null, 16, 14, 14, 10, 12, 8);

select tl_test.rec('RO1 Rogue: every class level 1-20 is represented',
  tl_test.levels_represented('rogue-phb') = 20, tl_test.levels_represented('rogue-phb')::text);
select tl_test.rec('RO2 class metadata: d8, DEX primary, DEX and INT saves, four skills from eleven, subclass at 3, complete',
  (select hit_die = 'd8' and primary_abilities = '{dex}' and saving_throws = '{dex,int}' and (skill_choice ->> 'count')::int = 4
          and jsonb_array_length(skill_choice -> 'from') = 11 and subclass_level = 3 and feature_status = 'complete'
          and (multiclass_skill_choice ->> 'count')::int = 1
   from public.class_versions where id = 'rogue-phb'));
select tl_test.rec('RO3 six ASI unlocks (4, 8, 10, 12, 16, 19); Expertise unlocks at 1 and 6; Steady Aim optional (Tasha''s)',
  (select array_agg(level order by level) = '{4,8,10,12,16,19}' from public.class_feature_unlocks where class_version_id = 'rogue-phb' and feature_version_id = 'rogue-asi-phb')
  and (select array_agg(level order by level) = '{1,6}' from public.class_feature_unlocks where class_version_id = 'rogue-phb' and feature_version_id = 'rogue-expertise-phb')
  and (select is_optional from public.class_feature_unlocks where id = 'rogue-phb-u3-steady-aim')
  and (select source_status from public.class_feature_versions where id = 'rogue-steady-aim-tce') = 'optional_rule');
select tl_test.rec('RO4 nine official Rogue archetypes in the catalog; Thief complete; Arcane Trickster progression only',
  (select count(*) from public.subclass_versions where class_id = 'rogue') = 9
  and (select implementation_status from public.subclass_versions where id = 'rogue-thief-phb') = 'complete'
  and (select implementation_status from public.subclass_versions where id = 'rogue-arcane-trickster-phb') = 'progression_only');
select tl_test.rec('RO5 starting equipment: three choices and one fixed line (leather, two daggers, thieves'' tools)',
  (select count(*) from public.class_starting_equipment where class_version_id = 'rogue-phb') = 8
  and (select count(*) from public.class_starting_equipment where class_version_id = 'rogue-phb' and choice_group = 4) = 1);

select tl_test.as_user(:'alice');
select tl_test.setc(:'r1', 'rogue-phb', 1);
select tl_test.rec('RO6 Rogue 1: DEX and INT saves, light armor, rapier and thieves'' tools proficiency, Thieves'' Cant language',
  (tl_test.d(:'r1') -> 'saving_throws' -> 'dex' ->> 'class_proficient')::boolean and (tl_test.d(:'r1') -> 'saving_throws' -> 'int' ->> 'class_proficient')::boolean
  and exists (select 1 from jsonb_array_elements(tl_test.d(:'r1') -> 'proficiencies') p where p ->> 'item_id' = 'rapier')
  and exists (select 1 from jsonb_array_elements(tl_test.d(:'r1') -> 'proficiencies') p where p ->> 'item_id' = 'thieves-tools')
  and exists (select 1 from jsonb_array_elements(tl_test.d(:'r1') -> 'languages') l where l ->> 'id' = 'thieves-cant'));
select tl_test.give(:'r1', 'rapier', 'main_hand') \gset rap_
select tl_test.rec('RO7 the rapier attack is proficient through the class (+5: DEX 3 + PB 2)',
  (select (w ->> 'proficient')::boolean and (w ->> 'attack_bonus')::int = 5 from jsonb_array_elements(tl_test.d(:'r1') -> 'equipped_weapon_attacks') w where w ->> 'item_id' = 'rapier'));
select tl_test.rec('RO8 Expertise needs proficiency first (Stealth not yet proficient)',
  tl_test.raises($$select tl_test.choose('f1e00000-0000-0000-0000-000000000001', 'rogue', 'rogue-phb-u1-expertise', 'rogue-expertise-phb-expertise', '{stealth,perception}')$$)
    like '%needs proficiency%');
select tl_test.choose(:'r1', 'rogue', 'rogue-phb-u1-proficiencies', 'rogue-proficiencies-phb-skills', '{stealth,perception,acrobatics,deception}');
select tl_test.choose(:'r1', 'rogue', 'rogue-phb-u1-expertise', 'rogue-expertise-phb-expertise', '{stealth,thieves-tools}');
select tl_test.rec('RO9 Expertise in Stealth and thieves'' tools: Stealth has class expertise, thieves'' tools are listed as tool expertise',
  (tl_test.d(:'r1') -> 'skills' -> 'stealth' ->> 'class_expertise')::boolean
  and tl_test.d(:'r1') -> 'tool_expertise' @> '[{"item_id": "thieves-tools"}]'::jsonb
  and not coalesce((tl_test.d(:'r1') -> 'skills' -> 'perception' ->> 'class_expertise')::boolean, false));
select tl_test.rec('RO10 Sneak Attack 1d6 is shown as an attack rider (once per turn, with its conditions), never added to the rapier',
  tl_test.d(:'r1') -> 'attack_riders' @> '[{"name": "Sneak Attack", "dice": "1d6", "once_per_turn": true}]'::jsonb
  and (select w ->> 'damage' = '1d8 + 3' from jsonb_array_elements(tl_test.d(:'r1') -> 'equipped_weapon_attacks') w where w ->> 'item_id' = 'rapier'));

select tl_test.setc(:'r1', 'rogue-phb', 3, 'rogue-thief-phb');
select tl_test.rec('RO11 Thief 3: Fast Hands and Second-Story Work are active reminders',
  tl_test.active(:'r1', 'rogue-thief-phb-u3-fast-hands') and tl_test.active(:'r1', 'rogue-thief-phb-u3-second-story-work')
  and (select automation from public.class_feature_versions where id = 'rogue-thief-fast-hands-phb') = 'informational');
select tl_test.setc(:'r1', 'rogue-phb', 6);
select tl_test.rec('RO12 Rogue 6: the second Expertise choice is open and cannot repeat Stealth',
  tl_test.ch(:'r1', 'rogue', 'rogue-phb-u6-expertise:rogue-expertise-phb-expertise') ->> 'status' = 'incomplete'
  and tl_test.raises($$select tl_test.choose('f1e00000-0000-0000-0000-000000000001', 'rogue', 'rogue-phb-u6-expertise', 'rogue-expertise-phb-expertise', '{stealth,perception}')$$)
    like '%already has expertise%');
select tl_test.choose(:'r1', 'rogue', 'rogue-phb-u6-expertise', 'rogue-expertise-phb-expertise', '{perception,acrobatics}');
select tl_test.setc(:'r1', 'rogue-phb', 9);
select tl_test.rec('RO13 Thief 9: Supreme Sneak is a situational advantage (listed, Stealth is not marked as always advantaged)',
  exists (select 1 from jsonb_array_elements(tl_test.d(:'r1') -> 'situational_advantages') a where a ->> 'source_name' like '%Supreme Sneak')
  and not coalesce((tl_test.d(:'r1') -> 'skills' -> 'stealth' ->> 'advantage')::boolean, false));

-- ---- progression snapshot: Sneak Attack dice, WIS save, blindsense, Stroke of Luck -------------------------------------------------
select tl_test.as_root();
create table tl_test.rsnap (level int, dice text, wis boolean, blind int, luck int);
grant all on tl_test.rsnap to public;
select tl_test.as_user(:'alice');
do $$
declare l int; ch uuid := 'f1e00000-0000-0000-0000-000000000001'; d jsonb;
begin
  for l in 1..20 loop
    perform tl_test.setc(ch, 'rogue-phb', l);
    d := tl_test.d(ch);
    insert into tl_test.rsnap values (l, (select r ->> 'dice' from jsonb_array_elements(d -> 'attack_riders') r where r ->> 'name' = 'Sneak Attack'),
      coalesce((d -> 'saving_throws' -> 'wis' ->> 'class_proficient')::boolean, false), coalesce((d -> 'senses' -> 'blindsense' ->> 'value')::int, 0),
      coalesce((case when (tl_test.res(ch, 'rogue-stroke-of-luck-phb-uses') ->> 'active')::boolean then tl_test.res(ch, 'rogue-stroke-of-luck-phb-uses') ->> 'max' end)::int, 0));
  end loop;
end $$;
select tl_test.rec('RO14 progression snapshot 1-20 (Sneak Attack dice, Slippery Mind at 15, Blindsense at 14, Stroke of Luck at 20)',
  (select string_agg(format('%s:%s/%s/%s/%s', level, dice, wis::int, blind, luck), ' ' order by level) from tl_test.rsnap)
  = '1:1d6/0/0/0 2:1d6/0/0/0 3:2d6/0/0/0 4:2d6/0/0/0 5:3d6/0/0/0 6:3d6/0/0/0 7:4d6/0/0/0 8:4d6/0/0/0 9:5d6/0/0/0 10:5d6/0/0/0 '
    '11:6d6/0/0/0 12:6d6/0/0/0 13:7d6/0/0/0 14:7d6/0/10/0 15:8d6/1/10/0 16:8d6/1/10/0 17:9d6/1/10/0 18:9d6/1/10/0 19:10d6/1/10/0 20:10d6/1/10/1',
  (select string_agg(format('%s:%s/%s/%s/%s', level, dice, wis::int, blind, luck), ' ' order by level) from tl_test.rsnap));
select tl_test.rec('RO15 Stroke of Luck recovers on a short or long rest',
  tl_test.res(:'r1', 'rogue-stroke-of-luck-phb-uses') ->> 'recharge' = 'short_or_long_rest');

select tl_test.setc(:'r1', 'rogue-phb', 5);
select tl_test.rec('RO16 lowering to 5: the second Expertise is kept but inactive; Perception loses expertise, Stealth keeps it',
  tl_test.ch(:'r1', 'rogue', 'rogue-phb-u6-expertise:rogue-expertise-phb-expertise') ->> 'status' = 'inactive_preserved'
  and not coalesce((tl_test.d(:'r1') -> 'skills' -> 'perception' ->> 'class_expertise')::boolean, false)
  and (tl_test.d(:'r1') -> 'skills' -> 'stealth' ->> 'class_expertise')::boolean);

-- ---- multiclass: Fighter first, then Rogue -----------------------------------------------------------------------------------------
select tl_test.setc(:'r2', 'fighter-phb', 3);
select tl_test.setc(:'r2', 'rogue-phb', 1);
select tl_test.rec('RO17 Rogue as a second class: no DEX / INT saves; thieves'' tools; one skill from the Rogue list (not four)',
  not coalesce((tl_test.d(:'r2') -> 'saving_throws' -> 'int' ->> 'class_proficient')::boolean, false)
  and exists (select 1 from jsonb_array_elements(tl_test.d(:'r2') -> 'proficiencies') p where p ->> 'item_id' = 'thieves-tools')
  and tl_test.ch(:'r2', 'rogue', 'rogue-phb-u1-proficiencies:rogue-proficiencies-phb-skills') ->> 'status' = 'not_applicable'
  and (tl_test.ch(:'r2', 'rogue', 'rogue-phb-u1-proficiencies:rogue-proficiencies-phb-skills-multiclass') ->> 'max')::int = 1);
select tl_test.rec('RO18 a multiclass Rogue cannot take a skill outside the Rogue list',
  tl_test.raises($$select tl_test.choose('f1e00000-0000-0000-0000-000000000002', 'rogue', 'rogue-phb-u1-proficiencies', 'rogue-proficiencies-phb-skills-multiclass', '{arcana}')$$)
    like '%not an allowed skill%');
select tl_test.rec('RO19 Sneak Attack uses the Rogue level (1d6 at Rogue 1, total level 4)',
  tl_test.d(:'r2') -> 'attack_riders' @> '[{"name": "Sneak Attack", "dice": "1d6"}]'::jsonb);

select tl_test.as_user(:'bob');
select tl_test.rec('RO20 an outsider cannot read or change the Rogue state',
  tl_test.raises($$select public.get_character_class_features('f1e00000-0000-0000-0000-000000000001')$$) is not null
  and tl_test.raises($$select tl_test.choose('f1e00000-0000-0000-0000-000000000001', 'rogue', 'rogue-phb-u1-expertise', 'rogue-expertise-phb-expertise', '{acrobatics,deception}')$$) is not null);
select tl_test.as_root();
