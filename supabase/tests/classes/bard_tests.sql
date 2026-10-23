-- =============================================================================
-- Bard (bard-phb) and College of Lore (bard-lore-phb): Bardic Inspiration (uses from CHA, die by level, recovery change at
-- 5), Jack of All Trades (half proficiency incl. initiative), Expertise, Magical Secrets (any list, castable level by the
-- Bard level, counted as known), Lore skills and Additional Magical Secrets, progression, multiclass, RLS.
-- =============================================================================
\set b1 f1b00000-0000-0000-0000-000000000001
\set b2 f1b00000-0000-0000-0000-000000000002
insert into public.characters (id, owner_id, name, campaign_id, strength, dexterity, constitution, intelligence, wisdom, charisma) values
  (:'b1', :'alice', 'Bard Tester', :'camp', 8, 14, 12, 10, 12, 16),
  (:'b2', :'alice', 'Wizard then Bard', null, 8, 14, 12, 16, 10, 14);
create function tl_test.granted(p_char uuid, p_spell text) returns jsonb language sql as $$
  select g from jsonb_array_elements(tl_test.spell(p_char, p_spell) -> 'grants') g where g ->> 'source_type' = 'class_feature' limit 1 $$;
grant all on all functions in schema tl_test to public;

select tl_test.rec('BA1 Bard: every class level 1-20 is represented', tl_test.levels_represented('bard-phb') = 20);
select tl_test.rec('BA2 class metadata: d8, CHA primary, DEX and CHA saves, any three skills, three instruments, subclass at 3',
  (select hit_die = 'd8' and primary_abilities = '{cha}' and saving_throws = '{dex,cha}' and (skill_choice ->> 'count')::int = 3
          and not skill_choice ? 'from' and subclass_level = 3 from public.class_versions where id = 'bard-phb')
  and (select max_picks = 3 and config ->> 'category' = 'musical-instrument' from public.class_feature_choices where id = 'bard-proficiencies-phb-tools-choice'));

select tl_test.as_user(:'alice');
select tl_test.setc(:'b1', 'bard-phb', 1);
select tl_test.rec('BA3 Bard 1 (CHA 16): Bardic Inspiration 3 uses, d6, back after a long rest',
  (tl_test.res(:'b1', 'bard-bardic-inspiration-phb-uses') ->> 'max')::int = 3 and tl_test.res(:'b1', 'bard-bardic-inspiration-phb-uses') ->> 'die' = 'd6'
  and tl_test.res(:'b1', 'bard-bardic-inspiration-phb-uses') ->> 'recharge' = 'long_rest');
select public.expend_character_resource(:'b1', tl_test.rkey(:'b1', 'bard', 'bard-bardic-inspiration-phb-uses'));
select public.short_rest_character(:'b1');
select tl_test.rec('BA4 at Bard 1 a short rest does not restore Bardic Inspiration',
  (tl_test.res(:'b1', 'bard-bardic-inspiration-phb-uses') ->> 'remaining')::int = 2);
select tl_test.choose(:'b1', 'bard', 'bard-phb-u1-proficiencies', 'bard-proficiencies-phb-skills', '{performance,persuasion,deception}');
select tl_test.choose(:'b1', 'bard', 'bard-phb-u1-proficiencies', 'bard-proficiencies-phb-tools-choice', '{lute,flute,drum}');
select tl_test.rec('BA5 three instruments are accepted; a non-instrument tool is refused',
  tl_test.ch(:'b1', 'bard', 'bard-phb-u1-proficiencies:bard-proficiencies-phb-tools-choice') ->> 'status' = 'complete'
  and tl_test.raises($$select tl_test.choose('f1b00000-0000-0000-0000-000000000001', 'bard', 'bard-phb-u1-proficiencies', 'bard-proficiencies-phb-tools-choice', '{lute,flute,thieves-tools}')$$)
    like '%not an allowed tool%');
select tl_test.setc(:'b1', 'bard-phb', 2);
select tl_test.rec('BA6 Jack of All Trades at PB 2: +1 on every skill (Arcana included) and initiative +1',
  (tl_test.d(:'b1') -> 'check_half_proficiency' ->> 'value')::int = 1
  and (tl_test.d(:'b1') -> 'skills' -> 'arcana' -> 'half_proficiency' ->> 'value')::int = 1
  and (tl_test.d(:'b1') -> 'initiative' ->> 'bonus')::int = 1);
select tl_test.setc(:'b1', 'bard-phb', 5);
select tl_test.rec('BA7 Bard 5 (Font of Inspiration): d8, back after a short or long rest; a short rest restores it',
  tl_test.res(:'b1', 'bard-bardic-inspiration-phb-uses') ->> 'die' = 'd8'
  and tl_test.res(:'b1', 'bard-bardic-inspiration-phb-uses') ->> 'recharge' = 'short_or_long_rest'
  and (select (public.short_rest_character(:'b1') -> 'breakdown' -> 'restored') @> '[{"name": "Bardic Inspiration"}]'::jsonb)
  and (tl_test.res(:'b1', 'bard-bardic-inspiration-phb-uses') ->> 'remaining')::int = 3);
select tl_test.choose(:'b1', 'bard', 'bard-phb-u3-expertise', 'bard-expertise-phb-expertise', '{performance,persuasion}');
select tl_test.rec('BA8 Expertise (level 3): Performance and Persuasion have class expertise; Jack of All Trades still applies to other skills',
  (tl_test.d(:'b1') -> 'skills' -> 'persuasion' ->> 'class_expertise')::boolean
  and (tl_test.d(:'b1') -> 'skills' -> 'history' -> 'half_proficiency' ->> 'value')::int = 1);

-- ---- Magical Secrets ----------------------------------------------------------------------------------------------------------------
select tl_test.setc(:'b1', 'bard-phb', 10);
select tl_test.rec('BA9 Magical Secrets (Bard 10, spells up to level 5): a 6th-level spell is refused; Fireball (Wizard list) is accepted',
  tl_test.raises($$select tl_test.choose('f1b00000-0000-0000-0000-000000000001', 'bard', 'bard-phb-u10-magical-secrets', 'bard-magical-secrets-phb-spells', '{disintegrate-phb,fireball-phb}')$$)
    like '%up to level 5%'
  and tl_test.raises($$select tl_test.choose('f1b00000-0000-0000-0000-000000000001', 'bard', 'bard-phb-u10-magical-secrets', 'bard-magical-secrets-phb-spells', '{fireball-phb,hunters-mark-phb}')$$) is null);
select tl_test.rec('BA10 Magical Secrets spells are Bard spells (Charisma), known and counted against spells known',
  (tl_test.granted(:'b1', 'fireball-phb') ->> 'casting_ability') = 'cha' and (tl_test.granted(:'b1', 'fireball-phb') ->> 'counts_against_known_limit')::boolean
  and (tl_test.granted(:'b1', 'hunters-mark-phb') ->> 'known')::boolean);
select tl_test.rec('BA11 Magical Secrets opens again at 14 and 18 (three unlocks of one feature)',
  (select array_agg(level order by level) = '{10,14,18}' from public.class_feature_unlocks where feature_version_id = 'bard-magical-secrets-phb'));

-- ---- College of Lore ----------------------------------------------------------------------------------------------------------------
select public.set_character_subclass(:'b1', tl_test.k(:'b1', 'bard'), 'bard-lore-phb');
select tl_test.choose(:'b1', 'bard', 'bard-lore-phb-u3-bonus-proficiencies', 'bard-lore-bonus-proficiencies-phb-skills', '{arcana,history,nature}');
select tl_test.rec('BA12 Lore Bonus Proficiencies: three skills of any kind (Arcana, History, Nature) are class proficient',
  (tl_test.d(:'b1') -> 'skills' -> 'nature' ->> 'class_proficient')::boolean and (tl_test.d(:'b1') -> 'skills' -> 'arcana' ->> 'class_proficient')::boolean);
select tl_test.choose(:'b1', 'bard', 'bard-lore-phb-u6-additional-magical-secrets', 'bard-lore-additional-magical-secrets-phb-spells', '{banishment-phb,find-steed-phb}');
select tl_test.rec('BA13 Additional Magical Secrets: Bard spells that do not count against spells known',
  not (tl_test.granted(:'b1', 'banishment-phb') ->> 'counts_against_known_limit')::boolean);
select tl_test.setc(:'b1', 'bard-phb', 6);
select tl_test.rec('BA14 lowering to Bard 6: Banishment (4th level) is kept and flagged for review (Bard 6 casts up to 3rd); the level-10 Magical Secrets are kept but inactive',
  tl_test.ch(:'b1', 'bard', 'bard-lore-phb-u6-additional-magical-secrets:bard-lore-additional-magical-secrets-phb-spells') -> 'values' ? 'banishment-phb'
  and tl_test.ch(:'b1', 'bard', 'bard-lore-phb-u6-additional-magical-secrets:bard-lore-additional-magical-secrets-phb-spells') ->> 'status' = 'invalid'
  and (tl_test.ch(:'b1', 'bard', 'bard-lore-phb-u6-additional-magical-secrets:bard-lore-additional-magical-secrets-phb-spells') ->> 'castable_level')::int = 3
  and tl_test.ch(:'b1', 'bard', 'bard-phb-u10-magical-secrets:bard-magical-secrets-phb-spells') ->> 'status' = 'inactive_preserved');

-- ---- progression snapshot -----------------------------------------------------------------------------------------------------------
select tl_test.as_root();
create table tl_test.bsnap (level int, die text, rech text, song text, half int);
grant all on tl_test.bsnap to public;
select tl_test.as_user(:'alice');
do $$
declare l int; ch uuid := 'f1b00000-0000-0000-0000-000000000001';
begin
  for l in 1..20 loop
    perform tl_test.setc(ch, 'bard-phb', l);
    insert into tl_test.bsnap values (l, tl_test.res(ch, 'bard-bardic-inspiration-phb-uses') ->> 'die',
      left(tl_test.res(ch, 'bard-bardic-inspiration-phb-uses') ->> 'recharge', 2),
      coalesce((select s ->> 'value' from jsonb_array_elements(tl_test.f(ch) -> 'classes' -> 0 -> 'features') f, jsonb_array_elements(f -> 'scaling') s
                where f ->> 'unlock_id' = 'bard-phb-u2-song-of-rest'), '-'),
      coalesce((tl_test.d(ch) -> 'check_half_proficiency' ->> 'value')::int, 0));
  end loop;
end $$;
select tl_test.rec('BA15 progression snapshot 1-20 (inspiration die, recovery, Song of Rest die, Jack of All Trades)',
  (select string_agg(format('%s:%s/%s/%s/%s', level, die, rech, song, half), ' ' order by level) from tl_test.bsnap)
  = '1:d6/lo/-/0 2:d6/lo/d6/1 3:d6/lo/d6/1 4:d6/lo/d6/1 5:d8/sh/d6/1 6:d8/sh/d6/1 7:d8/sh/d6/1 8:d8/sh/d6/1 9:d8/sh/d8/2 10:d10/sh/d8/2 '
    '11:d10/sh/d8/2 12:d10/sh/d8/2 13:d10/sh/d10/2 14:d10/sh/d10/2 15:d12/sh/d10/2 16:d12/sh/d10/2 17:d12/sh/d12/3 18:d12/sh/d12/3 19:d12/sh/d12/3 20:d12/sh/d12/3',
  (select string_agg(format('%s:%s/%s/%s/%s', level, die, rech, song, half), ' ' order by level) from tl_test.bsnap));

-- ---- multiclass ----------------------------------------------------------------------------------------------------------------------
select tl_test.setc(:'b2', 'wizard-phb', 3);
select tl_test.setc(:'b2', 'bard-phb', 1);
select tl_test.rec('BA16 Bard as a second class: one skill of any kind and one instrument; no DEX / CHA saves',
  (tl_test.ch(:'b2', 'bard', 'bard-phb-u1-proficiencies:bard-proficiencies-phb-skills-multiclass') ->> 'max')::int = 1
  and (tl_test.ch(:'b2', 'bard', 'bard-phb-u1-proficiencies:bard-proficiencies-phb-tools-choice-multiclass') ->> 'max')::int = 1
  and tl_test.ch(:'b2', 'bard', 'bard-phb-u1-proficiencies:bard-proficiencies-phb-tools-choice') ->> 'status' = 'not_applicable'
  and not coalesce((tl_test.d(:'b2') -> 'saving_throws' -> 'cha' ->> 'class_proficient')::boolean, false));
select tl_test.rec('BA17 Bardic Inspiration of the multiclass Bard uses its CHA (+2: 2 uses)',
  (tl_test.res(:'b2', 'bard-bardic-inspiration-phb-uses') ->> 'max')::int = 2);

select tl_test.as_user(:'bob');
select tl_test.rec('BA18 an outsider cannot spend Bardic Inspiration or choose Magical Secrets',
  tl_test.raises($$select public.expend_character_resource('f1b00000-0000-0000-0000-000000000001', 'f:' || gen_random_uuid() || ':bard-bardic-inspiration-phb-uses')$$) is not null
  and tl_test.raises($$select tl_test.choose('f1b00000-0000-0000-0000-000000000001', 'bard', 'bard-phb-u10-magical-secrets', 'bard-magical-secrets-phb-spells', '{fireball-phb,hunters-mark-phb}')$$) is not null);
select tl_test.as_root();
