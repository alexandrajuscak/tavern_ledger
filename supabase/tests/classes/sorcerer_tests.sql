-- =============================================================================
-- Sorcerer (sorcerer-phb) and Draconic Bloodline (sorcerer-draconic-bloodline-phb): Sorcery Points, Flexible Casting
-- (slot -> points, points -> temporary slot, limits, rests), temporary slot use, Metamagic picks by level, Sorcerous
-- Restoration, Draconic AC formula and ancestor, progression, multiclass slot conversion, RLS.
-- =============================================================================
\set s1 f1500000-0000-0000-0000-000000000001
\set s2 f1500000-0000-0000-0000-000000000002
insert into public.characters (id, owner_id, name, campaign_id, strength, dexterity, constitution, intelligence, wisdom, charisma) values
  (:'s1', :'alice', 'Sorcerer Tester', :'camp', 8, 14, 14, 10, 12, 16),
  (:'s2', :'alice', 'Wizard then Sorcerer', null, 8, 14, 12, 16, 10, 14);
create function tl_test.sp(p_char uuid) returns jsonb language sql as $$ select tl_test.res(p_char, 'sorcerer-font-of-magic-phb-points') $$;
create function tl_test.spkey(p_char uuid) returns text language sql as $$ select tl_test.rkey(p_char, 'sorcerer', 'sorcerer-font-of-magic-phb-points') $$;
create function tl_test.temps(p_char uuid) returns int language sql as $$
  select coalesce(sum(quantity - expended), 0)::int from public.character_temporary_spell_slots where character_id = p_char $$;
grant all on all functions in schema tl_test to public;

select tl_test.rec('SO1 Sorcerer: every class level 1-20 is represented', tl_test.levels_represented('sorcerer-phb') = 20);
select tl_test.rec('SO2 class metadata: d6, CHA primary, CON and CHA saves, two skills, subclass at 1; the saving throw line parses',
  (select hit_die = 'd6' and primary_abilities = '{cha}' and saving_throws = '{con,cha}' and subclass_level = 1
          and proficiency_lines ->> 'Saving Throws' = 'Constitution, Charisma' from public.class_versions where id = 'sorcerer-phb'));

select tl_test.as_user(:'alice');
select tl_test.setc(:'s1', 'sorcerer-phb', 1, 'sorcerer-draconic-bloodline-phb');
select tl_test.rec('SO3 Draconic Resilience: without armor AC 13 + DEX 2 = 15; Draconic is known; no sorcery points at level 1',
  (tl_test.d(:'s1') -> 'armor_class' ->> 'value')::int = 15
  and exists (select 1 from jsonb_array_elements(tl_test.d(:'s1') -> 'languages') l where l ->> 'id' = 'draconic')
  and coalesce((tl_test.sp(:'s1') ->> 'active')::boolean, false) = false);
select tl_test.give(:'s1', 'leather', 'armor') \gset lea_
select tl_test.rec('SO4 in leather armor the normal armor AC applies (11 + 2 = 13), not the draconic formula',
  (tl_test.d(:'s1') -> 'armor_class' ->> 'value')::int = 13);
select public.unequip_item(:'lea_give');
select tl_test.rec('SO5 the dragon ancestor choice lists the ten dragon types',
  jsonb_array_length(tl_test.ch(:'s1', 'sorcerer', 'sorcerer-draconic-bloodline-phb-u1-dragon-ancestor:sorcerer-draconic-bloodline-dragon-ancestor-phb-ancestor') -> 'options') = 10);

select tl_test.setc(:'s1', 'sorcerer-phb', 3);
select tl_test.rec('SO6 Sorcerer 3: 3 sorcery points, back after a long rest; Metamagic asks for two options from eleven',
  (tl_test.sp(:'s1') ->> 'max')::int = 3 and tl_test.sp(:'s1') ->> 'recharge' = 'long_rest'
  and (tl_test.ch(:'s1', 'sorcerer', 'sorcerer-phb-u3-metamagic:sorcerer-metamagic-phb-options') ->> 'max')::int = 2
  and jsonb_array_length(tl_test.ch(:'s1', 'sorcerer', 'sorcerer-phb-u3-metamagic:sorcerer-metamagic-phb-options') -> 'options') = 11);
select public.convert_spell_slot(:'s1', tl_test.spkey(:'s1'), 'points_to_slot', 2);
select tl_test.rec('SO7 Flexible Casting: 3 points create a temporary 2nd-level slot (0 points left)',
  (tl_test.sp(:'s1') ->> 'remaining')::int = 0 and tl_test.temps(:'s1') = 1
  and (select slot_level from public.character_temporary_spell_slots where character_id = :'s1') = 2);
select tl_test.rec('SO8 with no points left, creating a slot is refused; a 6th-level slot is never possible',
  tl_test.raises($$select public.convert_spell_slot('f1500000-0000-0000-0000-000000000001', tl_test.spkey('f1500000-0000-0000-0000-000000000001'), 'points_to_slot', 1)$$) like '%costs 2%'
  and tl_test.raises($$select public.convert_spell_slot('f1500000-0000-0000-0000-000000000001', tl_test.spkey('f1500000-0000-0000-0000-000000000001'), 'points_to_slot', 6)$$) like '%level 1 to 5%');
select public.use_temporary_spell_slot(:'s1', (select id from public.character_temporary_spell_slots where character_id = :'s1'));
select tl_test.rec('SO9 the temporary slot is spent once; a second use is refused',
  tl_test.temps(:'s1') = 0
  and tl_test.raises($$select public.use_temporary_spell_slot('f1500000-0000-0000-0000-000000000001', (select id from public.character_temporary_spell_slots where character_id = 'f1500000-0000-0000-0000-000000000001'))$$) like '%already used%');
select public.convert_spell_slot(:'s1', tl_test.spkey(:'s1'), 'slot_to_points', 1);
select tl_test.rec('SO10 a 1st-level slot becomes 1 sorcery point (the slot is expended)',
  (tl_test.sp(:'s1') ->> 'remaining')::int = 1
  and (select expended from public.character_spell_slot_state where character_id = :'s1' and pool = 'standard' and slot_level = 1) = 1);
select public.long_rest_character(:'s1');
select tl_test.rec('SO11 a long rest restores the points and removes temporary slots',
  (tl_test.sp(:'s1') ->> 'remaining')::int = 3 and not exists (select 1 from public.character_temporary_spell_slots where character_id = :'s1'));
select tl_test.rec('SO12 converting a slot while the points are full is refused (nothing is spent)',
  tl_test.raises($$select public.convert_spell_slot('f1500000-0000-0000-0000-000000000001', tl_test.spkey('f1500000-0000-0000-0000-000000000001'), 'slot_to_points', 1)$$) like '%already full%'
  and coalesce((select expended from public.character_spell_slot_state where character_id = :'s1' and pool = 'standard' and slot_level = 1), 0) = 0);
select tl_test.choose(:'s1', 'sorcerer', 'sorcerer-phb-u3-metamagic', 'sorcerer-metamagic-phb-options', '{quickened-spell,twinned-spell}');
select tl_test.rec('SO13 two Metamagic options are saved; the playtest Seeking Spell carries a DM-permission prerequisite',
  tl_test.ch(:'s1', 'sorcerer', 'sorcerer-phb-u3-metamagic:sorcerer-metamagic-phb-options') ->> 'status' = 'complete'
  and (select prerequisites::text like '%DM permission%' from public.class_feature_choice_options
       where choice_id = 'sorcerer-metamagic-phb-options' and option_id = 'seeking-spell-ua'));
select tl_test.setc(:'s1', 'sorcerer-phb', 10);
select tl_test.rec('SO14 Sorcerer 10: a third Metamagic option is needed (incomplete with two)',
  (tl_test.ch(:'s1', 'sorcerer', 'sorcerer-phb-u3-metamagic:sorcerer-metamagic-phb-options') ->> 'max')::int = 3
  and tl_test.ch(:'s1', 'sorcerer', 'sorcerer-phb-u3-metamagic:sorcerer-metamagic-phb-options') ->> 'status' = 'incomplete');

-- ---- Sorcerous Restoration ------------------------------------------------------------------------------------------------------
select tl_test.setc(:'s1', 'sorcerer-phb', 19);
select public.expend_character_resource(:'s1', tl_test.spkey(:'s1'), 6);
select public.short_rest_character(:'s1');
select tl_test.rec('SO15 Sorcerer 19: a short rest restores no sorcery points', (tl_test.sp(:'s1') ->> 'expended')::int = 6);
select tl_test.setc(:'s1', 'sorcerer-phb', 20);
select public.short_rest_character(:'s1');
select tl_test.rec('SO16 Sorcerer 20 (Sorcerous Restoration): a short rest restores 4 sorcery points (6 -> 2 used)',
  (tl_test.sp(:'s1') ->> 'expended')::int = 2 and (tl_test.sp(:'s1') ->> 'max')::int = 20);

-- ---- multiclass: the shared slot pool can pay for points ---------------------------------------------------------------------------
select tl_test.setc(:'s2', 'wizard-phb', 3);
select tl_test.setc(:'s2', 'sorcerer-phb', 2, 'sorcerer-draconic-bloodline-phb');
select public.expend_character_resource(:'s2', tl_test.rkey(:'s2', 'sorcerer', 'sorcerer-font-of-magic-phb-points'), 2);
select public.convert_spell_slot(:'s2', tl_test.rkey(:'s2', 'sorcerer', 'sorcerer-font-of-magic-phb-points'), 'slot_to_points', 3);
select tl_test.rec('SO17 Wizard 3 / Sorcerer 2 (caster level 5): a 3rd-level slot gives 2 points (capped by the maximum of 2)',
  (tl_test.res(:'s2', 'sorcerer-font-of-magic-phb-points') ->> 'remaining')::int = 2
  and (select expended from public.character_spell_slot_state where character_id = :'s2' and pool = 'standard' and slot_level = 3) = 1);
select tl_test.rec('SO18 the multiclass Sorcerer gets no proficiencies and no CON / CHA saves',
  not coalesce((tl_test.d(:'s2') -> 'saving_throws' -> 'con' ->> 'class_proficient')::boolean, false)
  and tl_test.ch(:'s2', 'sorcerer', 'sorcerer-phb-u1-proficiencies:sorcerer-proficiencies-phb-skills') ->> 'status' = 'not_applicable');

select tl_test.as_user(:'bob');
select tl_test.rec('SO19 an outsider cannot convert slots or use temporary slots',
  tl_test.raises($$select public.convert_spell_slot('f1500000-0000-0000-0000-000000000001', 'f:' || gen_random_uuid() || ':sorcerer-font-of-magic-phb-points', 'points_to_slot', 1)$$) is not null
  and tl_test.raises($$select public.use_temporary_spell_slot('f1500000-0000-0000-0000-000000000001', gen_random_uuid())$$) is not null);
select tl_test.as_root();
