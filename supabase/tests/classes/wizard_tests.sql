-- =============================================================================
-- Wizard (wizard-phb) and School of Evocation (wizard-evocation-phb): catalog, spellbook (acquisition, summary),
-- Arcane Recovery (slot recovery action), Spell Mastery / Signature Spells (spellbook choices), progression, multiclass, RLS.
-- Run with _harness.sql before and _report.sql after (the runners do this).
-- =============================================================================
\set w1 f1d00000-0000-0000-0000-000000000001
\set w2 f1d00000-0000-0000-0000-000000000002
insert into public.characters (id, owner_id, name, campaign_id, strength, dexterity, constitution, intelligence, wisdom, charisma) values
  (:'w1', :'alice', 'Wizard Tester', :'camp', 8, 14, 14, 16, 12, 10),
  (:'w2', :'alice', 'Fighter then Wizard', null, 16, 12, 14, 14, 10, 8);
create function tl_test.wsrc(p_char uuid) returns uuid language sql as $$
  select s.id from public.character_spellcasting_sources s where s.character_id = p_char and s.class_version_id = 'wizard-phb' $$;
create function tl_test.learn(p_char uuid, p_spell text, p_acq text default 'starting') returns uuid language plpgsql as $$
declare gid uuid;
begin
  perform public.set_character_spell(p_char, tl_test.wsrc(p_char), p_spell, true, false);
  select id into gid from public.character_spells where source_id = tl_test.wsrc(p_char) and spell_version_id = p_spell;
  perform public.set_character_spell_acquisition(gid, p_acq, null, null);
  return gid;
end $$;
create function tl_test.book(p_char uuid) returns jsonb language sql as $$
  select s -> 'spellbook' from jsonb_array_elements(public.get_character_spellbook(p_char) -> 'sources') s where s ->> 'id' = tl_test.wsrc(p_char)::text $$;
grant all on all functions in schema tl_test to public;

select tl_test.rec('WI1 Wizard: every class level 1-20 is represented', tl_test.levels_represented('wizard-phb') = 20);
select tl_test.rec('WI2 class metadata: d6, INT primary, INT and WIS saves, two skills, subclass at 2, no multiclass proficiencies',
  (select hit_die = 'd6' and primary_abilities = '{int}' and saving_throws = '{int,wis}' and (skill_choice ->> 'count')::int = 2
          and subclass_level = 2 and multiclass_skill_choice is null and feature_status = 'complete'
   from public.class_versions where id = 'wizard-phb'));
select tl_test.rec('WI3 starting equipment: the arcane focus option lists the five focus kinds; the spellbook is fixed',
  (select items -> 0 -> 'one_of' = '["crystal", "orb", "rod", "staff", "wand"]'::jsonb from public.class_starting_equipment
   where class_version_id = 'wizard-phb' and choice_group = 2 and option_key = 'b')
  and (select count(*) from public.class_starting_equipment where class_version_id = 'wizard-phb' and choice_group = 4) = 1);

select tl_test.as_user(:'alice');
select tl_test.setc(:'w1', 'wizard-phb', 1);
select tl_test.rec('WI4 Wizard 1: a spellbook spellcasting source; Arcane Recovery 1 use, budget 1 slot level',
  (select preparation_mode = 'spellbook' and ritual_mode = 'spellbook' from public.character_spellcasting_sources where id = tl_test.wsrc(:'w1'))
  and (tl_test.res(:'w1', 'wizard-arcane-recovery-phb-uses') ->> 'max')::int = 1
  and (tl_test.res(:'w1', 'wizard-arcane-recovery-phb-uses') ->> 'slot_recovery_budget')::int = 1);
select tl_test.learn(:'w1', 'magic-missile-phb'); select tl_test.learn(:'w1', 'shield-phb'); select tl_test.learn(:'w1', 'mage-armor-phb');
select tl_test.learn(:'w1', 'detect-magic-phb'); select tl_test.learn(:'w1', 'sleep-phb'); select tl_test.learn(:'w1', 'burning-hands-phb');
select tl_test.rec('WI5 spellbook summary: 6 spells (all "starting"), 6 free spells expected at Wizard 1, none prepared yet',
  (tl_test.book(:'w1') ->> 'spells')::int = 6 and (tl_test.book(:'w1') ->> 'free_expected')::int = 6
  and tl_test.book(:'w1') -> 'by_acquisition' = '{"starting": 6}'::jsonb and (tl_test.book(:'w1') ->> 'prepared')::int = 0, tl_test.book(:'w1')::text);
select tl_test.setc(:'w1', 'wizard-phb', 5);
select tl_test.learn(:'w1', 'misty-step-phb', 'level_up'); select tl_test.learn(:'w1', 'scorching-ray-phb', 'level_up');
select tl_test.learn(:'w1', 'fireball-phb', 'copied'); select tl_test.learn(:'w1', 'counterspell-phb', 'scroll'); select tl_test.learn(:'w1', 'haste-phb', 'copied');
select tl_test.rec('WI6 Wizard 5: 14 free spells expected; copied and scroll spells are counted separately',
  (tl_test.book(:'w1') ->> 'free_expected')::int = 14 and (tl_test.book(:'w1') ->> 'spells')::int = 11
  and (tl_test.book(:'w1') -> 'by_acquisition' ->> 'copied')::int = 2 and (tl_test.book(:'w1') -> 'by_acquisition' ->> 'scroll')::int = 1);

-- ---- Arcane Recovery -------------------------------------------------------------------------------------------------------------------
select public.expend_standard_spell_slot(:'w1', 2); select public.expend_standard_spell_slot(:'w1', 1); select public.expend_standard_spell_slot(:'w1', 1);
select tl_test.rec('WI7 Arcane Recovery at Wizard 5 recovers at most 3 slot levels: 2 + 2 is refused, a slot that is not expended is refused',
  tl_test.raises($$select public.recover_spell_slots('f1d00000-0000-0000-0000-000000000001', tl_test.rkey('f1d00000-0000-0000-0000-000000000001', 'wizard', 'wizard-arcane-recovery-phb-uses'), '{2,2}')$$) like '%at most 3%'
  and tl_test.raises($$select public.recover_spell_slots('f1d00000-0000-0000-0000-000000000001', tl_test.rkey('f1d00000-0000-0000-0000-000000000001', 'wizard', 'wizard-arcane-recovery-phb-uses'), '{3}')$$) like '%expended level 3%');
select public.recover_spell_slots(:'w1', tl_test.rkey(:'w1', 'wizard', 'wizard-arcane-recovery-phb-uses'), '{2,1}') as rec1 \gset
select tl_test.rec('WI8 recovering a 2nd- and a 1st-level slot: both restored in one step, Arcane Recovery used (0 / 1)',
  (select (e ->> 'expended')::int = 0 from jsonb_array_elements((:'rec1')::jsonb -> 'slots' -> 'standard') e where (e ->> 'slot_level')::int = 2)
  and (select (e ->> 'expended')::int = 1 from jsonb_array_elements((:'rec1')::jsonb -> 'slots' -> 'standard') e where (e ->> 'slot_level')::int = 1)
  and ((:'rec1')::jsonb -> 'resource' ->> 'remaining')::int = 0);
select tl_test.rec('WI9 a second Arcane Recovery before a long rest is refused; nothing changes',
  tl_test.raises($$select public.recover_spell_slots('f1d00000-0000-0000-0000-000000000001', tl_test.rkey('f1d00000-0000-0000-0000-000000000001', 'wizard', 'wizard-arcane-recovery-phb-uses'), '{1}')$$) like '%already used%'
  and (select expended from public.character_spell_slot_state where character_id = :'w1' and pool = 'standard' and slot_level = 1) = 1);
select public.short_rest_character(:'w1');
select tl_test.rec('WI10 a short rest does not restore Arcane Recovery; a long rest does',
  (tl_test.res(:'w1', 'wizard-arcane-recovery-phb-uses') ->> 'remaining')::int = 0
  and (select (public.long_rest_character(:'w1') -> 'breakdown' -> 'restored') @> '[{"name": "Arcane Recovery"}]'::jsonb)
  and (tl_test.res(:'w1', 'wizard-arcane-recovery-phb-uses') ->> 'remaining')::int = 1);

-- ---- subclass ---------------------------------------------------------------------------------------------------------------------------
select public.set_character_subclass(:'w1', tl_test.k(:'w1', 'wizard'), 'wizard-evocation-phb');
select tl_test.rec('WI11 School of Evocation: Evocation Savant and Sculpt Spells (2), Potent Cantrip (6) active at Wizard 5? (not 6)',
  tl_test.active(:'w1', 'wizard-evocation-phb-u2-evocation-savant') and tl_test.active(:'w1', 'wizard-evocation-phb-u2-sculpt-spells')
  and tl_test.ust(:'w1', 'wizard-evocation-phb-u6-potent-cantrip') = 'locked');
select tl_test.setc(:'w1', 'wizard-phb', 14);
select tl_test.rec('WI12 Wizard 14: Overchannel free use (1, long rest); Empowered Evocation listed as a reminder rider',
  (tl_test.res(:'w1', 'wizard-evocation-overchannel-phb-uses') ->> 'max')::int = 1
  and tl_test.d(:'w1') -> 'attack_riders' @> '[{"name": "Empowered Evocation"}]'::jsonb);

-- ---- Spell Mastery / Signature Spells: spells from the spellbook ----------------------------------------------------------------------
select tl_test.setc(:'w1', 'wizard-phb', 18);
select tl_test.rec('WI13 Spell Mastery: a spell that is not in the spellbook is refused; a wrong level is refused',
  tl_test.raises($$select tl_test.choose('f1d00000-0000-0000-0000-000000000001', 'wizard', 'wizard-phb-u18-spell-mastery', 'wizard-spell-mastery-phb-first', '{sleep-phb}')$$) is null
  and tl_test.raises($$select tl_test.choose('f1d00000-0000-0000-0000-000000000001', 'wizard', 'wizard-phb-u18-spell-mastery', 'wizard-spell-mastery-phb-first', '{thunderwave-phb}')$$) like '%not in your spellbook%'
  and tl_test.raises($$select tl_test.choose('f1d00000-0000-0000-0000-000000000001', 'wizard', 'wizard-phb-u18-spell-mastery', 'wizard-spell-mastery-phb-second', '{shield-phb}')$$) like '%choose a level 2 spell%');
select tl_test.choose(:'w1', 'wizard', 'wizard-phb-u18-spell-mastery', 'wizard-spell-mastery-phb-first', '{shield-phb}');
select tl_test.choose(:'w1', 'wizard', 'wizard-phb-u18-spell-mastery', 'wizard-spell-mastery-phb-second', '{misty-step-phb}');
select tl_test.rec('WI14 Spell Mastery spells are always prepared and castable without a slot (feature source)',
  exists (select 1 from jsonb_array_elements(tl_test.spell(:'w1', 'shield-phb') -> 'grants') g
          where g ->> 'source_type' = 'class_feature' and (g ->> 'always_prepared')::boolean and not (g ->> 'uses_spell_slot')::boolean),
  (tl_test.spell(:'w1', 'shield-phb') -> 'grants')::text);
select tl_test.setc(:'w1', 'wizard-phb', 20);
select tl_test.choose(:'w1', 'wizard', 'wizard-phb-u20-signature-spells', 'wizard-signature-spells-phb-spells', '{fireball-phb,counterspell-phb}');
select tl_test.rec('WI15 Signature Spells: two 3rd-level spellbook spells always prepared (not counted); two free casts per short rest',
  exists (select 1 from jsonb_array_elements(tl_test.spell(:'w1', 'fireball-phb') -> 'grants') g where g ->> 'source_type' = 'class_feature' and (g ->> 'always_prepared')::boolean)
  and (tl_test.res(:'w1', 'wizard-signature-spells-phb-uses') ->> 'max')::int = 2
  and tl_test.res(:'w1', 'wizard-signature-spells-phb-uses') ->> 'recharge' = 'short_or_long_rest');

-- ---- progression snapshot: Arcane Recovery budget -------------------------------------------------------------------------------------
select tl_test.as_root();
create table tl_test.wsnap (level int, budget int);
grant all on tl_test.wsnap to public;
select tl_test.as_user(:'alice');
do $$
declare l int; ch uuid := 'f1d00000-0000-0000-0000-000000000001';
begin
  for l in 1..20 loop
    perform tl_test.setc(ch, 'wizard-phb', l);
    insert into tl_test.wsnap values (l, (tl_test.res(ch, 'wizard-arcane-recovery-phb-uses') ->> 'slot_recovery_budget')::int);
  end loop;
end $$;
select tl_test.rec('WI16 Arcane Recovery budget = half the Wizard level rounded up (1..10)',
  (select string_agg(budget::text, ',' order by level) from tl_test.wsnap) = '1,1,2,2,3,3,4,4,5,5,6,6,7,7,8,8,9,9,10,10',
  (select string_agg(budget::text, ',' order by level) from tl_test.wsnap));
select tl_test.setc(:'w2', 'wizard-phb', 2, 'wizard-evocation-phb');
select tl_test.rec('WI16b a Wizard added together with a school keeps the source name "Wizard" (only a spellcasting subclass names it)',
  (select label from public.character_spellcasting_sources where character_id = :'w2' and class_version_id = 'wizard-phb') = 'Wizard');
select public.remove_character_class(tl_test.k(:'w2', 'wizard'), true);
select tl_test.rec('WI17 Cantrip Formulas is an optional Tasha''s feature at 3',
  (select is_optional from public.class_feature_unlocks where id = 'wizard-phb-u3-cantrip-formulas'));

-- ---- multiclass ----------------------------------------------------------------------------------------------------------------------
select tl_test.setc(:'w2', 'fighter-phb', 2);
select tl_test.setc(:'w2', 'wizard-phb', 1);
select tl_test.rec('WI18 Wizard as a second class: no saving throws, no skills and no weapon proficiencies from the Wizard',
  not coalesce((tl_test.d(:'w2') -> 'saving_throws' -> 'int' ->> 'class_proficient')::boolean, false)
  and tl_test.ch(:'w2', 'wizard', 'wizard-phb-u1-proficiencies:wizard-proficiencies-phb-skills') ->> 'status' = 'not_applicable'
  and not exists (select 1 from jsonb_array_elements(tl_test.d(:'w2') -> 'proficiencies') p where p ->> 'notes' like 'Wizard%'));

select tl_test.as_user(:'bob');
select tl_test.rec('WI19 an outsider cannot recover slots or record spellbook acquisitions',
  tl_test.raises($$select public.recover_spell_slots('f1d00000-0000-0000-0000-000000000001', 'f:' || gen_random_uuid() || ':wizard-arcane-recovery-phb-uses', '{1}')$$) is not null
  and tl_test.raises($$select public.set_character_spell_acquisition((select id from public.character_spells limit 1), 'copied')$$) is not null);
select tl_test.as_root();
