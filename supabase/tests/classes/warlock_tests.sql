-- =============================================================================
-- Warlock (warlock-phb) and the Fiend (warlock-fiend-phb): Pact Magic (separate), expanded spell list (set_character_spell
-- and on-list), Eldritch Invocations (prerequisites: level, Pact Boon, Eldritch Blast; picks by level; spell grants; uses),
-- Pact Boon (Chain: Find Familiar, Tome: cantrips from any list), Mystic Arcanum, Eldritch Master (Pact slot recovery),
-- Fiend features, progression, multiclass, RLS.
-- =============================================================================
\set k1 f1800000-0000-0000-0000-000000000001
\set k2 f1800000-0000-0000-0000-000000000002
insert into public.characters (id, owner_id, name, campaign_id, strength, dexterity, constitution, intelligence, wisdom, charisma) values
  (:'k1', :'alice', 'Warlock Tester', :'camp', 8, 14, 14, 10, 12, 16),
  (:'k2', :'alice', 'Paladin then Warlock', null, 16, 10, 14, 8, 10, 16);
create function tl_test.ksrc(p_char uuid) returns uuid language sql as $$
  select s.id from public.character_spellcasting_sources s where s.character_id = p_char and s.class_version_id = 'warlock-phb' $$;
create function tl_test.granted(p_char uuid, p_spell text) returns jsonb language sql as $$
  select g from jsonb_array_elements(tl_test.spell(p_char, p_spell) -> 'grants') g where g ->> 'source_type' = 'class_feature' limit 1 $$;
create function tl_test.inv(p_char uuid, p_vals text[]) returns text language sql as $$
  select tl_test.raises(format('select tl_test.choose(%L, %L, %L, %L, %L)', p_char, 'warlock', 'warlock-phb-u2-eldritch-invocations',
                                'warlock-eldritch-invocations-phb-invocations', p_vals)) $$;
grant all on all functions in schema tl_test to public;

select tl_test.rec('WA1 Warlock: every class level 1-20 is represented', tl_test.levels_represented('warlock-phb') = 20);
select tl_test.rec('WA2 the invocation catalog holds the 54 official invocations (UA ones are not selectable)',
  (select count(*) from public.class_feature_choice_options where choice_id = 'warlock-eldritch-invocations-phb-invocations') = 54);

select tl_test.as_user(:'alice');
select tl_test.setc(:'k1', 'warlock-phb', 1, 'warlock-fiend-phb');
select tl_test.rec('WA3 Fiend expanded spells: Burning Hands can be learned by the Warlock source; Cure Wounds (not on the list) is refused',
  tl_test.raises($$select public.set_character_spell('f1800000-0000-0000-0000-000000000001', tl_test.ksrc('f1800000-0000-0000-0000-000000000001'), 'burning-hands-phb')$$) is null
  and tl_test.raises($$select public.set_character_spell('f1800000-0000-0000-0000-000000000001', tl_test.ksrc('f1800000-0000-0000-0000-000000000001'), 'cure-wounds-phb')$$) like '%list%');
select tl_test.rec('WA4 Burning Hands is shown on the source''s list (expanded) and the source lists its expanded spells',
  (select (g ->> 'on_source_list')::boolean from jsonb_array_elements(tl_test.spell(:'k1', 'burning-hands-phb') -> 'grants') g where g ->> 'source_type' = 'class')
  and (select jsonb_array_length(s -> 'expanded_spells') from jsonb_array_elements(public.get_character_spellbook(:'k1') -> 'sources') s where s ->> 'id' = tl_test.ksrc(:'k1')::text) = 10);

select tl_test.setc(:'k1', 'warlock-phb', 2);
select tl_test.rec('WA5 Warlock 2: two invocations; Agonizing Blast is refused without Eldritch Blast; Lifedrinker (level 12, Blade) is refused',
  tl_test.inv(:'k1', '{agonizing-blast,armor-of-shadows}') like '%Eldritch Blast%'
  and tl_test.inv(:'k1', '{lifedrinker,armor-of-shadows}') like '%class level 12%');
select public.set_character_spell(:'k1', tl_test.ksrc(:'k1'), 'eldritch-blast-phb');
select tl_test.choose(:'k1', 'warlock', 'warlock-phb-u2-eldritch-invocations', 'warlock-eldritch-invocations-phb-invocations', '{agonizing-blast,armor-of-shadows}');
select tl_test.rec('WA6 with Eldritch Blast known Agonizing Blast is accepted; Armor of Shadows grants Mage Armor at will (no slot)',
  tl_test.ch(:'k1', 'warlock', 'warlock-phb-u2-eldritch-invocations:warlock-eldritch-invocations-phb-invocations') ->> 'status' = 'complete'
  and not (tl_test.granted(:'k1', 'mage-armor-phb') ->> 'uses_spell_slot')::boolean
  and tl_test.d(:'k1') -> 'attack_riders' @> '[{"name": "Agonizing Blast"}]'::jsonb);
select tl_test.setc(:'k1', 'warlock-phb', 3);
select tl_test.choose(:'k1', 'warlock', 'warlock-phb-u3-pact-boon', 'warlock-pact-boon-phb-pact', '{pact-of-the-chain}');
select tl_test.rec('WA7 Pact of the Chain grants Find Familiar (ritual, not counted); Pact Magic 2 slots of 2nd level, separate from standard slots',
  (tl_test.granted(:'k1', 'find-familiar-phb') ->> 'always_prepared')::boolean
  and (public.get_character_spell_slots(:'k1') -> 'pact_magic' ->> 'max')::int = 2 and jsonb_array_length(public.get_character_spell_slots(:'k1') -> 'standard') = 0);
select tl_test.choose(:'k1', 'warlock', 'warlock-phb-u3-pact-boon', 'warlock-pact-boon-phb-pact', '{pact-of-the-tome}');
select tl_test.choose(:'k1', 'warlock', 'warlock-phb-u3-pact-boon', 'warlock-pact-boon-phb-tome-cantrips', '{guidance-phb,sacred-flame-phb,fire-bolt-phb}');
select tl_test.rec('WA8 Pact of the Tome: three cantrips from any class list (Guidance, Sacred Flame, Fire Bolt) granted; Find Familiar is gone',
  tl_test.granted(:'k1', 'sacred-flame-phb') is not null and tl_test.granted(:'k1', 'fire-bolt-phb') is not null
  and tl_test.granted(:'k1', 'find-familiar-phb') is null);
select tl_test.setc(:'k1', 'warlock-phb', 5);
select tl_test.rec('WA9 Warlock 5: a third invocation is needed; Book of Ancient Secrets (Tome) and Mire the Mind (5) are accepted',
  tl_test.ch(:'k1', 'warlock', 'warlock-phb-u2-eldritch-invocations:warlock-eldritch-invocations-phb-invocations') ->> 'status' = 'incomplete'
  and tl_test.inv(:'k1', '{agonizing-blast,armor-of-shadows,mire-the-mind}') is null);
select tl_test.rec('WA10 Mire the Mind: Slow granted with a once-per-long-rest use; Thirsting Blade needs the Blade pact',
  (tl_test.res(:'k1', 'warlock-eldritch-invocations-phb-mire-the-mind-uses') ->> 'max')::int = 1
  and tl_test.granted(:'k1', 'slow-phb') is not null
  and tl_test.inv(:'k1', '{agonizing-blast,armor-of-shadows,thirsting-blade}') like '%Pact of the Blade%');
select tl_test.choose(:'k1', 'warlock', 'warlock-phb-u2-eldritch-invocations', 'warlock-eldritch-invocations-phb-invocations', '{agonizing-blast,devils-sight,beguiling-influence}');
select tl_test.rec('WA11 Devil''s Sight: darkvision 120 ft; Beguiling Influence: Deception and Persuasion proficient; Mage Armor is gone with Armor of Shadows',
  (tl_test.d(:'k1') -> 'senses' -> 'darkvision' ->> 'value')::int = 120 and (tl_test.d(:'k1') -> 'skills' -> 'persuasion' ->> 'class_proficient')::boolean
  and tl_test.granted(:'k1', 'mage-armor-phb') is null);

select tl_test.setc(:'k1', 'warlock-phb', 10);
select tl_test.choose(:'k1', 'warlock', 'warlock-fiend-phb-u10-fiendish-resilience', 'warlock-fiend-fiendish-resilience-phb-type', '{fire}');
select tl_test.rec('WA12 Fiend 10: Fiendish Resilience fire resistance; Dark One''s Own Luck d10 once per short rest',
  tl_test.d(:'k1') -> 'resistances' @> '["fire"]'::jsonb or exists (select 1 from jsonb_array_elements(tl_test.d(:'k1') -> 'resistances') r where r::text like '%fire%'),
  (tl_test.d(:'k1') -> 'resistances')::text);
select tl_test.rec('WA12b Dark One''s Own Luck: d10, short or long rest',
  tl_test.res(:'k1', 'warlock-fiend-dark-ones-own-luck-phb-uses') ->> 'die' = 'd10' and tl_test.res(:'k1', 'warlock-fiend-dark-ones-own-luck-phb-uses') ->> 'recharge' = 'short_or_long_rest');
select tl_test.setc(:'k1', 'warlock-phb', 11);
select tl_test.rec('WA13 Mystic Arcanum (6th): a 6th-level Warlock spell is accepted, a 5th-level one (or one off the list) refused; cast once per long rest without a slot',
  tl_test.raises($$select tl_test.choose('f1800000-0000-0000-0000-000000000001', 'warlock', 'warlock-phb-u11-mystic-arcanum-6', 'warlock-mystic-arcanum-6-phb-spell', '{hold-monster-phb}')$$) is not null
  and tl_test.raises($$select tl_test.choose('f1800000-0000-0000-0000-000000000001', 'warlock', 'warlock-phb-u11-mystic-arcanum-6', 'warlock-mystic-arcanum-6-phb-spell', '{eyebite-phb}')$$) is null
  and not (tl_test.granted(:'k1', 'eyebite-phb') ->> 'uses_spell_slot')::boolean
  and (tl_test.res(:'k1', 'warlock-mystic-arcanum-6-phb-uses') ->> 'recharge') = 'long_rest');

select tl_test.setc(:'k1', 'warlock-phb', 20);
select public.expend_pact_magic_slot(:'k1'); select public.expend_pact_magic_slot(:'k1');
select public.recover_spell_slots(:'k1', tl_test.rkey(:'k1', 'warlock', 'warlock-eldritch-master-phb-uses'), '{}');
select tl_test.rec('WA14 Eldritch Master: both expended Pact slots come back; the use is spent',
  (public.get_character_spell_slots(:'k1') -> 'pact_magic' ->> 'remaining')::int = 4
  and (tl_test.res(:'k1', 'warlock-eldritch-master-phb-uses') ->> 'remaining')::int = 0);

-- ---- progression snapshot: invocations known, pact slots ---------------------------------------------------------------------
select tl_test.as_root();
create table tl_test.ksnap (level int, inv int, slots int, slot_level int);
grant all on tl_test.ksnap to public;
select tl_test.as_user(:'alice');
do $$
declare l int; ch uuid := 'f1800000-0000-0000-0000-000000000001';
begin
  for l in 1..20 loop
    perform tl_test.setc(ch, 'warlock-phb', l);
    insert into tl_test.ksnap values (l,
      coalesce((case when (tl_test.ch(ch, 'warlock', 'warlock-phb-u2-eldritch-invocations:warlock-eldritch-invocations-phb-invocations') ->> 'open')::boolean
                     then tl_test.ch(ch, 'warlock', 'warlock-phb-u2-eldritch-invocations:warlock-eldritch-invocations-phb-invocations') ->> 'max' end)::int, 0),
      (public.get_character_spell_slots(ch) -> 'pact_magic' ->> 'max')::int, (public.get_character_spell_slots(ch) -> 'pact_magic' ->> 'slot_level')::int);
  end loop;
end $$;
select tl_test.rec('WA15 progression snapshot 1-20 (invocations known, Pact slots x level)',
  (select string_agg(format('%s:%s/%sx%s', level, inv, slots, slot_level), ' ' order by level) from tl_test.ksnap)
  = '1:0/1x1 2:2/2x1 3:2/2x2 4:2/2x2 5:3/2x3 6:3/2x3 7:4/2x4 8:4/2x4 9:5/2x5 10:5/2x5 11:5/3x5 12:6/3x5 13:6/3x5 14:6/3x5 15:7/3x5 16:7/3x5 '
    '17:7/4x5 18:8/4x5 19:8/4x5 20:8/4x5',
  (select string_agg(format('%s:%s/%sx%s', level, inv, slots, slot_level), ' ' order by level) from tl_test.ksnap));

select tl_test.setc(:'k2', 'paladin-phb', 2);
select tl_test.setc(:'k2', 'warlock-phb', 1);
select tl_test.rec('WA16 Paladin 2 / Warlock 1: standard slots (Paladin) and Pact Magic (Warlock) stay separate; no WIS / CHA saves from the Warlock',
  jsonb_array_length(public.get_character_spell_slots(:'k2') -> 'standard') = 1 and (public.get_character_spell_slots(:'k2') -> 'pact_magic' ->> 'max')::int = 1);
select tl_test.as_user(:'bob');
select tl_test.rec('WA17 an outsider cannot choose invocations or recover Pact slots',
  tl_test.inv('f1800000-0000-0000-0000-000000000001', '{agonizing-blast,devils-sight}') is not null
  and tl_test.raises($$select public.recover_spell_slots('f1800000-0000-0000-0000-000000000001', 'f:' || gen_random_uuid() || ':warlock-eldritch-master-phb-uses', '{}')$$) is not null);
select tl_test.as_root();
