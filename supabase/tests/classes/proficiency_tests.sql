-- =============================================================================
-- Proficiency resolution (20261017001100, docs/PROFICIENCY_RESOLUTION.md): get_character_proficiencies merges manual,
-- class (primary / multiclass), class feature and lineage sources without copying them into manual rows. Removing one source
-- removes only its contribution; a manual duplicate stays; armor warnings follow the effective result; RLS.
-- =============================================================================
\set p1 f1d00000-0000-0000-0000-000000000001
\set p2 f1d00000-0000-0000-0000-000000000002
\set p3 f1d00000-0000-0000-0000-000000000003
\set p4 f1d00000-0000-0000-0000-000000000004
\set p5 f1d00000-0000-0000-0000-000000000005
\set p6 f1d00000-0000-0000-0000-000000000006
insert into public.characters (id, owner_id, name, campaign_id, strength, dexterity, constitution, intelligence, wisdom, charisma) values
  (:'p1', :'alice', 'Fighter Primary', :'camp', 16, 12, 14, 10, 10, 10),
  (:'p2', :'alice', 'Wizard then Fighter', null, 14, 12, 14, 16, 10, 10),
  (:'p3', :'alice', 'Artificer Primary', null, 10, 14, 14, 16, 10, 10),
  (:'p4', :'alice', 'Fighter then Artificer', null, 16, 12, 14, 14, 10, 10),
  (:'p5', :'alice', 'Dwarf Wizard', null, 10, 12, 14, 16, 10, 10),
  (:'p6', :'alice', 'Half-Elf Rogue', null, 10, 16, 12, 10, 10, 14);
-- one resolved entry: kind groups | items | skills | saves | tools | languages
create function tl_test.pr(p_char uuid, p_kind text, p_id text) returns jsonb language sql as $$
  select e from jsonb_array_elements(public.get_character_proficiencies(p_char) -> p_kind) e where e ->> 'id' = p_id $$;
create function tl_test.pon(p_char uuid, p_kind text, p_id text) returns boolean language sql as $$
  select coalesce((tl_test.pr(p_char, p_kind, p_id) ->> 'effective')::boolean, false) $$;
create function tl_test.labels(p_char uuid, p_kind text, p_id text) returns text[] language sql as $$
  select coalesce(array_agg(s ->> 'label' order by s ->> 'label'), '{}') from jsonb_array_elements(tl_test.pr(p_char, p_kind, p_id) -> 'sources') s $$;
grant all on all functions in schema tl_test to public;

select tl_test.as_user(:'alice');
select tl_test.setc(:'p1', 'fighter-phb', 1);
select tl_test.rec('PF1 primary Fighter: light, medium and heavy armor are effective, granted by Fighter, with no manual row',
  tl_test.pon(:'p1', 'groups', 'light-armor') and tl_test.pon(:'p1', 'groups', 'medium-armor') and tl_test.pon(:'p1', 'groups', 'heavy-armor')
  and tl_test.labels(:'p1', 'groups', 'heavy-armor') = '{Fighter}'
  and not (tl_test.pr(:'p1', 'groups', 'heavy-armor') ->> 'manual')::boolean
  and (select count(*) from public.character_proficiencies where character_id = :'p1') = 0,
  tl_test.pr(:'p1', 'groups', 'heavy-armor')::text);
select tl_test.rec('PF2 primary Fighter: shields', tl_test.pon(:'p1', 'groups', 'shields') and tl_test.labels(:'p1', 'groups', 'shields') = '{Fighter}');
select tl_test.rec('PF3 primary Fighter: simple and martial weapons; STR and CON saves; no firearms',
  tl_test.pon(:'p1', 'groups', 'simple-weapons') and tl_test.pon(:'p1', 'groups', 'martial-weapons') and not tl_test.pon(:'p1', 'groups', 'firearms')
  and tl_test.pon(:'p1', 'saves', 'str') and tl_test.pon(:'p1', 'saves', 'con') and not tl_test.pon(:'p1', 'saves', 'dex'));

select tl_test.setc(:'p2', 'wizard-phb', 1);
select tl_test.setc(:'p2', 'fighter-phb', 1);
select tl_test.rec('PF4 Fighter as a multiclass: light / medium armor, shields, simple / martial weapons; no heavy armor, no STR / CON saves',
  tl_test.pon(:'p2', 'groups', 'light-armor') and tl_test.pon(:'p2', 'groups', 'medium-armor') and tl_test.pon(:'p2', 'groups', 'shields')
  and tl_test.pon(:'p2', 'groups', 'simple-weapons') and tl_test.pon(:'p2', 'groups', 'martial-weapons')
  and not tl_test.pon(:'p2', 'groups', 'heavy-armor') and not tl_test.pon(:'p2', 'saves', 'str') and not tl_test.pon(:'p2', 'saves', 'con')
  and tl_test.pon(:'p2', 'saves', 'int') and tl_test.pon(:'p2', 'saves', 'wis'),
  (public.get_character_proficiencies(:'p2') -> 'groups')::text);

select tl_test.setc(:'p3', 'artificer-tce', 1);
select tl_test.rec('PF5 primary Artificer: light and medium armor, shields, simple weapons, thieves'' and tinker''s tools; CON / INT saves',
  tl_test.pon(:'p3', 'groups', 'light-armor') and tl_test.pon(:'p3', 'groups', 'medium-armor') and tl_test.pon(:'p3', 'groups', 'shields')
  and tl_test.pon(:'p3', 'groups', 'simple-weapons') and not tl_test.pon(:'p3', 'groups', 'heavy-armor')
  and tl_test.pon(:'p3', 'tools', 'thieves-tools') and tl_test.pon(:'p3', 'tools', 'tinkers-tools')
  and tl_test.pon(:'p3', 'saves', 'con') and tl_test.pon(:'p3', 'saves', 'int'));

select tl_test.setc(:'p4', 'fighter-phb', 1);
select tl_test.setc(:'p4', 'artificer-tce', 1);
select tl_test.rec('PF6 Artificer as a multiclass (Tasha''s): thieves'' and tinker''s tools from the Artificer, armor and shields also from it; no INT save',
  tl_test.pon(:'p4', 'tools', 'thieves-tools') and tl_test.pon(:'p4', 'tools', 'tinkers-tools')
  and tl_test.labels(:'p4', 'tools', 'tinkers-tools') = '{Artificer}'
  and tl_test.labels(:'p4', 'groups', 'medium-armor') = '{Artificer,Fighter}'
  and not tl_test.pon(:'p4', 'saves', 'int'),
  tl_test.labels(:'p4', 'groups', 'medium-armor')::text);

-- lineage sources
select tl_test.setc(:'p5', 'wizard-phb', 1);
select public.set_character_proficiency(:'p5', 'shields', null, true, 'Manual test row');
select public.set_character_lineage(:'p5', 'dwarf-phb', 'dwarf-mountain', '{}'::jsonb);
select tl_test.rec('PF7 a fixed lineage grant appears (Mountain Dwarf: light and medium armor) without a manual row',
  tl_test.pon(:'p5', 'groups', 'light-armor') and tl_test.pon(:'p5', 'groups', 'medium-armor')
  and (tl_test.pr(:'p5', 'groups', 'medium-armor') -> 'sources') @> '[{"kind": "lineage", "label": "Mountain Dwarf"}]'::jsonb
  and (select count(*) from public.character_proficiencies where character_id = :'p5') = 1,
  tl_test.pr(:'p5', 'groups', 'medium-armor')::text);
select tl_test.rec('PF7b lineage language grants are listed with their source (Dwarvish)',
  tl_test.pon(:'p5', 'languages', 'dwarvish') and not (tl_test.pr(:'p5', 'languages', 'dwarvish') ->> 'editable')::boolean);
select tl_test.give(:'p5', 'scale-mail', 'armor') \gset sm_
select tl_test.rec('PF15 the armor warning uses the effective result: a Mountain Dwarf wizard in scale mail is proficient',
  not (public.get_character_proficiencies(:'p5') -> 'armor' ->> 'nonproficient_armor')::boolean
  and not (tl_test.d(:'p5') -> 'armor_consequences' ->> 'nonproficient_armor')::boolean);
select public.set_character_lineage(:'p5', 'dwarf-phb', 'dwarf-hill', '{}'::jsonb);
select tl_test.rec('PF9 changing the lineage (Hill Dwarf) removes only the lineage source: medium armor gone, the manual shield stays',
  not tl_test.pon(:'p5', 'groups', 'medium-armor') and tl_test.pon(:'p5', 'groups', 'shields')
  and tl_test.labels(:'p5', 'groups', 'shields') = '{Manual}');
select tl_test.rec('PF16 the armor warning returns when the last source is gone (scale mail, no medium armor proficiency)',
  (public.get_character_proficiencies(:'p5') -> 'armor' ->> 'nonproficient_armor')::boolean);

select tl_test.setc(:'p6', 'rogue-phb', 1);
select public.set_character_lineage(:'p6', 'half-elf-phb', null,
  '{"half-elf-phb:versatility": ["skill-versatility"], "half-elf-phb:versatility-skills": ["insight", "persuasion"]}'::jsonb);
select tl_test.rec('PF8 a lineage choice proficiency appears (Half-Elf versatility: Insight, Persuasion) with the lineage as source',
  tl_test.pon(:'p6', 'skills', 'insight') and tl_test.pon(:'p6', 'skills', 'persuasion')
  and (tl_test.pr(:'p6', 'skills', 'insight') -> 'sources') @> '[{"kind": "lineage", "label": "Half-Elf"}]'::jsonb
  and not (tl_test.pr(:'p6', 'skills', 'insight') ->> 'manual')::boolean,
  tl_test.pr(:'p6', 'skills', 'insight')::text);
select tl_test.choose(:'p6', 'rogue', 'rogue-phb-u1-proficiencies', 'rogue-proficiencies-phb-skills', '{stealth,perception,acrobatics,deception}');
select tl_test.choose(:'p6', 'rogue', 'rogue-phb-u1-expertise', 'rogue-expertise-phb-expertise', '{stealth,insight}');
select tl_test.rec('PF13 expertise resolves over the effective proficiency (Insight from the lineage, Stealth from the class: level 2)',
  (tl_test.pr(:'p6', 'skills', 'insight') ->> 'level')::int = 2 and (tl_test.pr(:'p6', 'skills', 'stealth') ->> 'level')::int = 2
  and (tl_test.pr(:'p6', 'skills', 'stealth') ->> 'expertise')::boolean
  and (tl_test.pr(:'p6', 'skills', 'stealth') -> 'sources') @> '[{"kind": "feature", "label": "Feature: Expertise", "expertise": true}]'::jsonb,
  tl_test.pr(:'p6', 'skills', 'stealth')::text);

-- manual duplicates and removal of a class source
select public.set_character_proficiency(:'p1', 'light-armor', null, true, 'Marked by hand');
select public.set_character_proficiency(:'p1', 'firearms', null, true, 'Table rule');
select tl_test.rec('PF11 a manual duplicate is kept with both sources and noted (light armor: Fighter + Manual)',
  tl_test.labels(:'p1', 'groups', 'light-armor') = '{Fighter,Manual}'
  and (public.get_character_proficiencies(:'p1') -> 'warnings') @> '[{"code": "manual_also_granted", "id": "light-armor"}]'::jsonb
  and tl_test.pon(:'p1', 'groups', 'firearms') and tl_test.labels(:'p1', 'groups', 'firearms') = '{Manual}');
select public.remove_character_class(tl_test.k(:'p1', 'fighter'), true);
select tl_test.rec('PF10 removing the class removes only its source: light armor stays (manual), heavy armor and shields go, firearms stay',
  tl_test.pon(:'p1', 'groups', 'light-armor') and tl_test.labels(:'p1', 'groups', 'light-armor') = '{Manual}'
  and not tl_test.pon(:'p1', 'groups', 'heavy-armor') and not tl_test.pon(:'p1', 'groups', 'shields') and tl_test.pon(:'p1', 'groups', 'firearms')
  and not tl_test.pon(:'p1', 'saves', 'str'));
update public.characters set skill_proficiencies = '{"athletics": 1}', save_proficiencies = '{"dex": true}' where id = :'p1';
select tl_test.rec('PF11b manual skill and save marks on the character are sources too (Athletics, DEX save: Manual)',
  tl_test.pon(:'p1', 'skills', 'athletics') and tl_test.labels(:'p1', 'skills', 'athletics') = '{Manual}'
  and tl_test.pon(:'p1', 'saves', 'dex') and (tl_test.pr(:'p1', 'saves', 'dex') ->> 'manual')::boolean);

-- security
select tl_test.as_user(:'bob');
select tl_test.rec('PF17 another user can neither read nor change the proficiencies',
  tl_test.raises(format('select public.get_character_proficiencies(%L)', :'p1')) like '%not found%'
  and tl_test.raises(format('select public.set_character_proficiency(%L, ''heavy-armor'', null, true, null)', :'p1')) is not null);
select tl_test.as_user(:'alice');
select tl_test.rec('PF18 direct writes stay blocked (manual rows go through the RPC; class grants cannot be written)',
  tl_test.raises(format('insert into public.character_proficiencies (character_id, proficiency_type, group_id, source_type) values (%L, ''armor'', ''heavy-armor'', ''class'')', :'p1')) like '%permission denied%'
  and tl_test.raises('update public.class_feature_effects set value_text = ''heavy-armor'' where value_text = ''light-armor''') like '%permission denied%');
select tl_test.as_user(:'dm');
select tl_test.rec('PF19 the campaign DM can read the resolved proficiencies of a campaign character',
  tl_test.pon(:'p1', 'groups', 'light-armor'));

-- all 13 classes: primary gets exactly its saves; as a multiclass (after Wizard, or after Rogue for the Wizard) no class saves
-- and never heavy armor unless it is the primary class
select tl_test.as_root();
create function tl_test.class_sweep() returns text language plpgsql as $$
declare v record; cp uuid; cm uuid; first_v text; bad text := ''; want text[]; got text[];
begin
  for v in select cv.id, cv.class_id, cv.saving_throws from public.class_versions cv
           where cv.class_id in ('artificer', 'barbarian', 'bard', 'cleric', 'druid', 'fighter', 'monk', 'paladin', 'ranger', 'rogue',
                                 'sorcerer', 'warlock', 'wizard') order by cv.class_id loop
    cp := gen_random_uuid(); cm := gen_random_uuid();
    first_v := case when v.class_id = 'wizard' then 'rogue-phb' else 'wizard-phb' end;   -- a first class without heavy armor
    insert into public.characters (id, owner_id, name, strength, dexterity, constitution, intelligence, wisdom, charisma)
    values (cp, 'a1111111-1111-1111-1111-111111111111', 'Sweep ' || v.class_id, 13, 13, 13, 13, 13, 13),
           (cm, 'a1111111-1111-1111-1111-111111111111', 'Sweep mc ' || v.class_id, 13, 13, 13, 13, 13, 13);
    perform tl_test.as_user('a1111111-1111-1111-1111-111111111111');
    perform public.set_character_class(cp, v.id, 1, null, null, null);
    perform public.set_character_class(cm, first_v, 1, null, null, null);
    perform public.set_character_class(cm, v.id, 1, null, null, null);
    select array_agg(e ->> 'id' order by e ->> 'id') into got from jsonb_array_elements(public.get_character_proficiencies(cp) -> 'saves') e
    where (e ->> 'effective')::boolean;
    select array_agg(x order by x) into want from unnest(v.saving_throws) x;
    if got is distinct from want then bad := bad || format('%s primary saves %s <> %s; ', v.class_id, got, want); end if;
    if exists (select 1 from jsonb_array_elements(public.get_character_proficiencies(cm) -> 'saves') e
               where (e ->> 'effective')::boolean and e -> 'sources' @> jsonb_build_array(jsonb_build_object('label', initcap(v.class_id)))) then
      bad := bad || format('%s multiclass grants a save; ', v.class_id);
    end if;
    if (select (e ->> 'effective')::boolean from jsonb_array_elements(public.get_character_proficiencies(cm) -> 'groups') e where e ->> 'id' = 'heavy-armor') then
      bad := bad || format('%s multiclass grants heavy armor; ', v.class_id);
    end if;
    perform tl_test.as_root();
  end loop;
  return bad;
end $$;
select tl_test.class_sweep() as sweep \gset
select tl_test.rec('PF20 all 13 classes: primary saves match the class table; as a multiclass no saves and no heavy armor', :'sweep' = '', :'sweep');
