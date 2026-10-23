-- =============================================================================
-- Character classes, spell slot progression, Pact Magic, resources and rests (migration 20261015001700).
-- Same harness as spell_tests.sql: one transaction, rolled back; PASSED / FAILED per check; any FAILED check ends with an
-- error. Needs reference_data.sql, item_effects.sql, spells.sql, classes.sql and lineages.sql. Synthetic users only.
-- =============================================================================
\set ON_ERROR_STOP on
\pset format unaligned
\pset tuples_only on
begin;
\o /dev/null

create schema tl_test;
grant usage on schema tl_test to public;
create table tl_test.results (n serial, name text, ok boolean, detail text);
create function tl_test.rec(p_name text, p_ok boolean, p_detail text default '') returns void language plpgsql as $$
begin insert into tl_test.results (name, ok, detail) values (p_name, coalesce(p_ok, false), p_detail); end $$;
create function tl_test.raises(p_sql text) returns text language plpgsql as $$
begin execute p_sql; return null; exception when others then return sqlerrm; end $$;
create function tl_test.as_user(p_uid uuid) returns void language plpgsql as $$
begin perform set_config('request.jwt.claim.sub', p_uid::text, true); perform set_config('role', 'authenticated', true); end $$;
create function tl_test.as_root() returns void language plpgsql as $$
begin perform set_config('role', 'postgres', true); perform set_config('request.jwt.claim.sub', '', true); end $$;
create function tl_test.cls(p_char uuid, p_version text, p_level int, p_sub text default null, p_primary boolean default null)
returns jsonb language sql as $$ select public.set_character_class(p_char, p_version, p_level, p_sub, p_primary) $$;
create function tl_test.row_id(p_char uuid, p_class text) returns uuid language sql as $$
  select id from public.character_classes where character_id = p_char and class_id = p_class $$;
create function tl_test.src(p_char uuid, p_class text) returns uuid language sql as $$
  select s.id from public.character_spellcasting_sources s join public.character_classes c on c.id = s.character_class_id
  where c.character_id = p_char and c.class_id = p_class $$;
-- "1:4,2:2" from the standard slots of a character
create function tl_test.std(p_char uuid) returns text language sql as $$
  select coalesce(string_agg((e ->> 'slot_level') || ':' || (e ->> 'max'), ',' order by (e ->> 'slot_level')::int), '')
  from jsonb_array_elements(public.get_character_spell_slots(p_char) -> 'standard') e $$;
create function tl_test.remaining(p_char uuid, p_level int) returns int language sql as $$
  select (e ->> 'remaining')::int from jsonb_array_elements(public.get_character_spell_slots(p_char) -> 'standard') e
  where (e ->> 'slot_level')::int = p_level $$;
create function tl_test.prog(p_id text, p_level int) returns text language sql as $$
  select coalesce(string_agg(slot_level || ':' || slots, ',' order by slot_level), '')
  from public.spell_slot_progression_levels where progression_id = p_id and class_level = p_level $$;
create function tl_test.klass(p_char uuid, p_class text) returns jsonb language sql as $$
  select e from jsonb_array_elements(public.get_character_class_summary(p_char) -> 'classes') e where e ->> 'class_id' = p_class $$;
create function tl_test.warn(p_char uuid, p_code text) returns boolean language sql as $$
  select exists (select 1 from jsonb_array_elements(public.get_character_class_summary(p_char) -> 'warnings') w where w ->> 'code' = p_code) $$;
create function tl_test.res(p_char uuid, p_key text) returns jsonb language sql as $$
  select e from jsonb_array_elements(public.get_character_class_summary(p_char) -> 'resources') e where e ->> 'resource_key' = p_key $$;
grant all on all functions in schema tl_test to public;
grant all on tl_test.results to public;
grant all on sequence tl_test.results_n_seq to public;

-- ---- catalog and progression data --------------------------------------------------------------------------------------------
select tl_test.rec('K1 13 classes and 13 class versions (9 spellcasting + Barbarian, Fighter, Monk, Rogue), each with a hit die',
  (select count(*) from public.classes where id not like 'engine-test%') = 13
  and (select count(*) from public.class_versions where hit_die is not null and id not like 'engine-test%') = 13
  and (select hit_die from public.class_versions where id = 'barbarian-phb') = 'd12'
  and (select hit_die from public.class_versions where id = 'wizard-phb') = 'd6' and (select hit_die from public.class_versions where id = 'fighter-phb') = 'd10');
select tl_test.rec('K2 every class version has 20 level rows; proficiency bonus +2 .. +6 from the tables',
  (select count(*) from public.class_version_levels where class_version_id not like 'engine-test%') = 260
  and not exists (select 1 from public.class_version_levels where proficiency_bonus <> (level - 1) / 4 + 2));
select tl_test.rec('K3 explicit multiclass contributions (no class-name inference)',
  (select string_agg(id || '=' || multiclass_contribution, ',' order by id) from public.class_versions where id not like 'engine-test%')
  = 'artificer-tce=half_up,barbarian-phb=none,bard-phb=full,cleric-phb=full,druid-phb=full,fighter-phb=none,monk-phb=none,paladin-phb=half_down,'
    'ranger-phb=half_down,rogue-phb=none,sorcerer-phb=full,warlock-phb=pact,wizard-phb=full');
select tl_test.rec('K4 standard table: caster level 1 / 3 / 5 / 9 / 17 / 20',
  tl_test.prog('standard-caster', 1) = '1:2' and tl_test.prog('standard-caster', 3) = '1:4,2:2'
  and tl_test.prog('standard-caster', 5) = '1:4,2:3,3:2' and tl_test.prog('standard-caster', 9) = '1:4,2:3,3:3,4:3,5:1'
  and tl_test.prog('standard-caster', 17) = '1:4,2:3,3:3,4:3,5:2,6:1,7:1,8:1,9:1'
  and tl_test.prog('standard-caster', 20) = '1:4,2:3,3:3,4:3,5:3,6:2,7:2,8:1,9:1');
select tl_test.rec('K5 half caster (Paladin, Ranger): nothing at 1st level, 2 slots at 2nd, 5th-level slots from 17th',
  tl_test.prog('half-caster', 1) = '' and tl_test.prog('half-caster', 2) = '1:2' and tl_test.prog('half-caster', 5) = '1:4,2:2'
  and tl_test.prog('half-caster', 17) = '1:4,2:3,3:3,4:3,5:1'
  and (select spellcasting_start_level from public.class_versions where id = 'paladin-phb') = 2);
select tl_test.rec('K6 Artificer has its own table: 2 slots at 1st level, 3 at 3rd, 5th-level slots at 17th',
  tl_test.prog('artificer-tce-slots', 1) = '1:2' and tl_test.prog('artificer-tce-slots', 3) = '1:3'
  and tl_test.prog('artificer-tce-slots', 17) = '1:4,2:3,3:3,4:3,5:1'
  and (select spellcasting_start_level from public.class_versions where id = 'artificer-tce') = 1
  and (select prepared_formula ->> 'level_divisor' from public.class_versions where id = 'artificer-tce') = '2');
select tl_test.rec('K7 one-third caster foundation: Eldritch Knight / Arcane Trickster from level 3, 4th-level slots at 19',
  tl_test.prog('third-caster', 3) = '1:2' and tl_test.prog('third-caster', 7) = '1:4,2:2' and tl_test.prog('third-caster', 19) = '1:4,2:3,3:3,4:1'
  and (select count(*) from public.subclass_versions where multiclass_contribution = 'third_down') = 2
  and (select cantrips_known from public.subclass_version_levels where subclass_version_id = 'rogue-arcane-trickster-phb' and level = 3) = 3);
select tl_test.rec('K8 Pact Magic table: one slot level per Warlock level, never above 5th, 4 slots at 17th',
  (select string_agg(level || '=' || pact_slots || 'x' || pact_slot_level, ',' order by level) from public.class_version_levels
   where class_version_id = 'warlock-phb' and level in (1, 2, 3, 5, 9, 11, 17)) = '1=1x1,2=2x1,3=2x2,5=2x3,9=2x5,11=3x5,17=4x5'
  and (select max(pact_slot_level) from public.class_version_levels where class_version_id = 'warlock-phb') = 5
  and not exists (select 1 from public.spell_slot_progression_levels where progression_id = 'pact-magic' and slot_level > 5));
select tl_test.rec('K9 known / cantrip metadata (Bard 3: 2 cantrips, 6 known; Sorcerer 1: 4 / 2; Ranger 2: 2 known; Warlock 3: 2 / 4)',
  (select cantrips_known || '/' || spells_known from public.class_version_levels where class_version_id = 'bard-phb' and level = 3) = '2/6'
  and (select cantrips_known || '/' || spells_known from public.class_version_levels where class_version_id = 'sorcerer-phb' and level = 1) = '4/2'
  and (select spells_known from public.class_version_levels where class_version_id = 'ranger-phb' and level = 2) = 2
  and (select cantrips_known || '/' || spells_known from public.class_version_levels where class_version_id = 'warlock-phb' and level = 3) = '2/4');

-- ---- users and characters ------------------------------------------------------------------------------------------------
insert into auth.users (id, email) values
  ('a1111111-1111-1111-1111-111111111111', 'alice@test'), ('b2222222-2222-2222-2222-222222222222', 'bob@test'),
  ('d3333333-3333-3333-3333-333333333333', 'dm@test'), ('e4444444-4444-4444-4444-444444444444', 'outsider@test');
insert into public.campaigns (id, name, created_by) values ('cccccccc-0000-0000-0000-000000000001', 'Class Test Campaign', 'd3333333-3333-3333-3333-333333333333');
insert into public.campaign_members (campaign_id, user_id, role) values
  ('cccccccc-0000-0000-0000-000000000001', 'a1111111-1111-1111-1111-111111111111', 'player'),
  ('cccccccc-0000-0000-0000-000000000001', 'b2222222-2222-2222-2222-222222222222', 'player'),
  ('cccccccc-0000-0000-0000-000000000001', 'd3333333-3333-3333-3333-333333333333', 'dm');
-- INT 16 (+3), WIS 12 (+1), CHA 16 (+3), STR 14, DEX 14
insert into public.characters (id, owner_id, name, campaign_id, level, strength, dexterity, intelligence, wisdom, charisma)
select ('aaaaaaaa-0000-0000-0000-0000000000' || lpad(n::text, 2, '0'))::uuid, 'a1111111-1111-1111-1111-111111111111', 'Class Tester ' || n,
       'cccccccc-0000-0000-0000-000000000001', 4, 14, 14, 16, 12, 16
from generate_series(1, 14) n;
select 'aaaaaaaa-0000-0000-0000-000000000001'::uuid as c1, 'aaaaaaaa-0000-0000-0000-000000000002'::uuid as c2,
       'aaaaaaaa-0000-0000-0000-000000000003'::uuid as c3, 'aaaaaaaa-0000-0000-0000-000000000004'::uuid as c4,
       'aaaaaaaa-0000-0000-0000-000000000005'::uuid as c5, 'aaaaaaaa-0000-0000-0000-000000000006'::uuid as c6,
       'aaaaaaaa-0000-0000-0000-000000000007'::uuid as c7, 'aaaaaaaa-0000-0000-0000-000000000008'::uuid as c8,
       'aaaaaaaa-0000-0000-0000-000000000009'::uuid as c9, 'aaaaaaaa-0000-0000-0000-000000000010'::uuid as c10,
       'aaaaaaaa-0000-0000-0000-000000000011'::uuid as c11, 'aaaaaaaa-0000-0000-0000-000000000012'::uuid as c12,
       'aaaaaaaa-0000-0000-0000-000000000013'::uuid as c13, 'aaaaaaaa-0000-0000-0000-000000000014'::uuid as c14,
       'a1111111-1111-1111-1111-111111111111'::uuid as alice, 'b2222222-2222-2222-2222-222222222222'::uuid as bob,
       'd3333333-3333-3333-3333-333333333333'::uuid as dm, 'e4444444-4444-4444-4444-444444444444'::uuid as outsider \gset

-- ---- total level, mirror, fallback ---------------------------------------------------------------------------------------
select tl_test.as_user(:'alice');
select tl_test.rec('L1 without classes the legacy level is used and reported as a fallback',
  (public.get_character_class_summary(:'c1') ->> 'total_level')::int = 4 and (public.get_character_class_summary(:'c1') ->> 'fallback')::boolean
  and public.get_character_derived_stats(:'c1') -> 'proficiency_bonus' ->> 'level_source' = 'legacy');
select tl_test.cls(:'c1', 'wizard-phb', 3);
select tl_test.rec('L2 Wizard 3: total level 3 from classes, mirrored into characters.level, primary, PB +2',
  (public.get_character_class_summary(:'c1') ->> 'total_level')::int = 3 and (select level from public.characters where id = :'c1') = 3
  and (select is_primary from public.character_classes where character_id = :'c1') and (public.get_character_class_summary(:'c1') ->> 'proficiency_bonus')::int = 2
  and not (public.get_character_class_summary(:'c1') ->> 'fallback')::boolean);
select tl_test.rec('L3 a hand-edited level that conflicts with the classes is refused',
  tl_test.raises(format('update public.characters set level = 9 where id = %L', :'c1')) like '%comes from its classes%');
select tl_test.rec('L3b other character fields stay editable while classes exist',
  tl_test.raises(format('update public.characters set hp_current = 7 where id = %L', :'c1')) is null);
select tl_test.cls(:'c1', 'cleric-phb', 2);
select tl_test.rec('L4 adding Cleric 2: total 5, PB +3 everywhere (summary, derived stats, spell sources)',
  (public.get_character_class_summary(:'c1') ->> 'proficiency_bonus')::int = 3
  and (public.get_character_derived_stats(:'c1') -> 'proficiency_bonus' ->> 'value')::int = 3
  and (public.get_character_derived_stats(:'c1') -> 'proficiency_bonus' ->> 'level_source') = 'classes'
  and (select (s -> 'stats' ->> 'save_dc')::int from jsonb_array_elements(public.get_character_spellbook(:'c1') -> 'sources') s
       where s ->> 'label' = 'Wizard') = 14);
select tl_test.cls(:'c1', 'wizard-phb', 3);
select tl_test.rec('L5 one class row per class: setting the same class version again updates that row',
  (select count(*) from public.character_classes where character_id = :'c1' and class_id = 'wizard') = 1);
select tl_test.rec('L6 class level outside 1-20 and a total above 20 are refused',
  tl_test.raises(format('select public.set_character_class(%L, ''druid-phb'', 0)', :'c1')) like '%between 1 and 20%'
  and tl_test.raises(format('select public.set_character_class(%L, ''druid-phb'', 16)', :'c1')) like '%at most 20%');
select tl_test.rec('L7 a subclass of another class is refused (Arcane Trickster on a Fighter)',
  tl_test.raises(format('select public.set_character_class(%L, ''fighter-phb'', 3, ''rogue-arcane-trickster-phb'')', :'c2')) like '%does not belong%');
select tl_test.cls(:'c1', 'cleric-phb', 2, null, true);
select tl_test.rec('L8 only one primary class; marking another moves it',
  (select count(*) from public.character_classes where character_id = :'c1' and is_primary) = 1
  and (select class_id from public.character_classes where character_id = :'c1' and is_primary) = 'cleric');

-- ---- standard slots: single class, multiclass, rounding ------------------------------------------------------------------
select tl_test.cls(:'c2', 'paladin-phb', 5);
select tl_test.rec('M1 single-class Paladin 5 uses its own table (4 + 2), not the multiclass table at floor(5 / 2)',
  tl_test.std(:'c2') = '1:4,2:2' and public.get_character_spell_slots(:'c2') ->> 'slot_mode' = 'single_class');
select tl_test.cls(:'c3', 'paladin-phb', 3); select tl_test.cls(:'c3', 'ranger-phb', 3);
select tl_test.rec('M2 Paladin 3 / Ranger 3: half levels rounded down (1 + 1 = caster level 2: three 1st-level slots)',
  tl_test.std(:'c3') = '1:3' and (public.get_character_spell_slots(:'c3') ->> 'effective_caster_level')::int = 2
  and public.get_character_spell_slots(:'c3') ->> 'slot_mode' = 'multiclass');
select tl_test.rec('M3 Wizard 3 / Cleric 2: caster level 5 (4 / 3 / 2) with a breakdown per class',
  tl_test.std(:'c1') = '1:4,2:3,3:2'
  and (select string_agg((b ->> 'class_id') || ':' || (b ->> 'contribution_type') || ':' || (b ->> 'rounded_contribution'), ',' order by b ->> 'class_id')
       from jsonb_array_elements(public.get_character_spell_slots(:'c1') -> 'breakdown') b) = 'cleric:full:2,wizard:full:3');
select tl_test.cls(:'c4', 'artificer-tce', 3); select tl_test.cls(:'c4', 'wizard-phb', 1);
select tl_test.rec('M4 Artificer 3 / Wizard 1: Artificer half rounded UP (2) + 1 = caster level 3 (4 / 2)',
  tl_test.std(:'c4') = '1:4,2:2' and (public.get_character_spell_slots(:'c4') ->> 'effective_caster_level')::int = 3
  and (select (b ->> 'rounded_contribution')::int from jsonb_array_elements(public.get_character_spell_slots(:'c4') -> 'breakdown') b
       where b ->> 'class_id' = 'artificer') = 2);
select tl_test.cls(:'c5', 'artificer-tce', 1);
select tl_test.rec('M5 Artificer 1 alone has two 1st-level slots (own table)', tl_test.std(:'c5') = '1:2');
select tl_test.cls(:'c6', 'paladin-phb', 1); select tl_test.cls(:'c6', 'wizard-phb', 1);
select tl_test.rec('M6 Paladin 1 / Wizard 1: Paladin has no Spellcasting yet, so only the Wizard table counts (two 1st-level slots)',
  tl_test.std(:'c6') = '1:2' and public.get_character_spell_slots(:'c6') ->> 'slot_mode' = 'single_class'
  and (select (b ->> 'active')::boolean from jsonb_array_elements(public.get_character_spell_slots(:'c6') -> 'breakdown') b
       where b ->> 'class_id' = 'paladin') = false);
select tl_test.cls(:'c7', 'fighter-phb', 5);
select tl_test.rec('M7 a plain Fighter contributes nothing (no slots, contribution none)',
  tl_test.std(:'c7') = '' and public.get_character_spell_slots(:'c7') ->> 'slot_mode' = 'none');
select tl_test.cls(:'c7', 'fighter-phb', 5, 'fighter-eldritch-knight-phb');
select tl_test.rec('M8 Fighter 5 with the Eldritch Knight progression: one-third table (three 1st-level slots), INT source created',
  tl_test.std(:'c7') = '1:3' and (select casting_ability from public.character_spellcasting_sources where id = tl_test.src(:'c7', 'fighter')) = 'int'
  and (select spell_list_id from public.character_spellcasting_sources where id = tl_test.src(:'c7', 'fighter')) = 'wizard-spell-list');
select tl_test.cls(:'c7', 'wizard-phb', 2);
select tl_test.rec('M9 Eldritch Knight 5 / Wizard 2: floor(5 / 3) + 2 = caster level 3 (4 / 2)',
  tl_test.std(:'c7') = '1:4,2:2' and (public.get_character_spell_slots(:'c7') ->> 'effective_caster_level')::int = 3);
-- 20261015001800: a subclass is chosen at its selection level (Fighter 3); lowering the level keeps it (inactive)
select tl_test.cls(:'c8', 'fighter-phb', 3, 'fighter-eldritch-knight-phb'); select tl_test.cls(:'c8', 'fighter-phb', 2, 'fighter-eldritch-knight-phb');
select tl_test.rec('M10 an Eldritch Knight below Fighter 3 has no slots yet', tl_test.std(:'c8') = '');

-- ---- Pact Magic ---------------------------------------------------------------------------------------------------------------
select tl_test.cls(:'c9', 'warlock-phb', 3); select tl_test.cls(:'c9', 'sorcerer-phb', 2);
select tl_test.rec('P1 Warlock 3 / Sorcerer 2: Pact Magic is separate (2 slots of 2nd level); standard slots come only from Sorcerer 2',
  tl_test.std(:'c9') = '1:3' and (public.get_character_spell_slots(:'c9') -> 'pact_magic' ->> 'max')::int = 2
  and (public.get_character_spell_slots(:'c9') -> 'pact_magic' ->> 'slot_level')::int = 2
  and (public.get_character_spell_slots(:'c9') -> 'pact_magic' ->> 'recovers') = 'short_or_long_rest');
select tl_test.rec('P2 Warlock spell access follows its own Pact slot level (max level 2), the Sorcerer only its own level (1)',
  (tl_test.klass(:'c9', 'warlock') -> 'spellcasting' ->> 'max_spell_level')::int = 2
  and (tl_test.klass(:'c9', 'sorcerer') -> 'spellcasting' ->> 'max_spell_level')::int = 1
  and (tl_test.klass(:'c9', 'warlock') -> 'spellcasting' ->> 'spells_known')::int = 4);
select public.expend_pact_magic_slot(:'c9');
select tl_test.rec('P3 a Pact slot is used without choosing a level; standard slots unchanged',
  (public.get_character_spell_slots(:'c9') -> 'pact_magic' ->> 'remaining')::int = 1 and tl_test.remaining(:'c9', 1) = 3);
select public.expend_pact_magic_slot(:'c9');
select tl_test.rec('P4 no Pact slot left: refused', tl_test.raises(format('select public.expend_pact_magic_slot(%L)', :'c9')) like '%No Pact Magic%');
select tl_test.rec('P5 a character without Warlock levels has no Pact pool',
  tl_test.raises(format('select public.expend_pact_magic_slot(%L)', :'c1')) like '%no Pact Magic%');
select tl_test.cls(:'c10', 'warlock-phb', 17);
select tl_test.rec('P6 Warlock 17: 4 Pact slots of 5th level, no 6th-9th level slots (Mystic Arcanum is not a Pact slot)',
  (public.get_character_spell_slots(:'c10') -> 'pact_magic' ->> 'max')::int = 4
  and (public.get_character_spell_slots(:'c10') -> 'pact_magic' ->> 'slot_level')::int = 5 and tl_test.std(:'c10') = ''
  and (tl_test.klass(:'c10', 'warlock') -> 'spellcasting' ->> 'max_spell_level')::int = 5);
select tl_test.rec('P7 casting options: a 1st-level spell can use a Pact slot (cast at the Pact level) or a standard slot',
  (select (o ->> 'pact_slot')::boolean from jsonb_array_elements(public.get_character_spell_slots(:'c10') -> 'casting_options') o
   where (o ->> 'spell_level')::int = 1)
  and (select o -> 'standard_slot_levels' from jsonb_array_elements(public.get_character_spell_slots(:'c1') -> 'casting_options') o
       where (o ->> 'spell_level')::int = 2) = '[2, 3]'::jsonb);

-- ---- standard slot use ------------------------------------------------------------------------------------------------------
select public.expend_standard_spell_slot(:'c1', 3); select public.expend_standard_spell_slot(:'c1', 3);
select tl_test.rec('U1 the two 3rd-level slots can be used, a third time is refused (no partial or combined slots)',
  tl_test.remaining(:'c1', 3) = 0
  and tl_test.raises(format('select public.expend_standard_spell_slot(%L, 3)', :'c1')) like '%No level 3 slot left%'
  and tl_test.remaining(:'c1', 2) = 3);
select tl_test.rec('U2 a slot level the character does not have is refused (level 4, level 0, level 10)',
  tl_test.raises(format('select public.expend_standard_spell_slot(%L, 4)', :'c1')) like '%no level 4 spell slots%'
  and tl_test.raises(format('select public.expend_standard_spell_slot(%L, 0)', :'c1')) like '%between 1 and 9%'
  and tl_test.raises(format('select public.expend_standard_spell_slot(%L, 10)', :'c1')) like '%between 1 and 9%');
select public.restore_standard_spell_slot(:'c1', 3);
select tl_test.rec('U3 restore gives one back; restoring an unused level is refused',
  tl_test.remaining(:'c1', 3) = 1 and tl_test.raises(format('select public.restore_standard_spell_slot(%L, 1)', :'c1')) like '%No expended%');
select tl_test.rec('U4 every use and restore is an event with the acting user',
  (select count(*) from public.character_resource_events where character_id = :'c1' and pool = 'standard') = 3
  and (select bool_and(actor_id = :'alice') from public.character_resource_events where character_id = :'c1'));
select public.set_spell_slot_state(:'c1', 'standard', 1, 2, 'forgot to mark two');
select tl_test.rec('U5 a manual correction needs a reason and is recorded as manual_set',
  tl_test.raises(format('select public.set_spell_slot_state(%L, ''standard'', 1, 2, '''')', :'c1')) like '%needs a reason%'
  and tl_test.remaining(:'c1', 1) = 2
  and exists (select 1 from public.character_resource_events where character_id = :'c1' and event_type = 'manual_set' and reason = 'forgot to mark two'));
select tl_test.rec('U6 a manual correction cannot exceed the maximum or go below zero',
  tl_test.raises(format('select public.set_spell_slot_state(%L, ''standard'', 1, 5, ''x'')', :'c1')) like '%between 0 and 4%'
  and tl_test.raises(format('select public.set_spell_slot_state(%L, ''standard'', 1, -1, ''x'')', :'c1')) like '%between 0 and 4%');

-- ---- rests ----------------------------------------------------------------------------------------------------------------------
select tl_test.as_root();
insert into public.feature_trackers (character_id, name, current, max, reset_on) values
  (:'c9', 'Short thing', 0, 2, 'short'), (:'c9', 'Long thing', 0, 1, 'long');
update public.spell_slots set total = 2, used = 2 where character_id = :'c9' and level = 1;
insert into public.character_temporary_spell_slots (character_id, slot_level, source_label, expires_on) values (:'c9', 1, 'Test spark', 'long_rest');
select tl_test.as_user(:'alice');
select public.expend_standard_spell_slot(:'c9', 1);
select tl_test.rec('R0 temporary slots are listed separately and never change the class maximum',
  jsonb_array_length(public.get_character_spell_slots(:'c9') -> 'temporary') = 1 and tl_test.std(:'c9') = '1:3');
select (public.get_character_spell_slots(:'c9') -> 'pact_magic' ->> 'expended') as pact_before \gset
select public.short_rest_character(:'c9', 'eeeeeeee-0000-0000-0000-000000000001') as rest1 \gset
select tl_test.rec('R1b the short rest result reports what came back (Pact slots as expended before, not 0) and what did not'
  || ' (from 20261017001000; not applicable on the rolled-back functions)',
  (not exists (select 1 from pg_proc where proname = '_rest' and prosrc like '%report the value before the update%') or (:'pact_before'::int > 0 and (:'rest1'::jsonb -> 'restored' ->> 'pact_slots')::int = :'pact_before'::int
  and exists (select 1 from jsonb_array_elements(:'rest1'::jsonb -> 'breakdown' -> 'restored') x
              where x ->> 'kind' = 'pact' and (x ->> 'amount')::int = :'pact_before'::int)
  and exists (select 1 from jsonb_array_elements(:'rest1'::jsonb -> 'breakdown' -> 'not_restored') x
              where x ->> 'name' = 'Standard spell slots' and (x ->> 'amount')::int = 1))),
  :'rest1');
select tl_test.rec('R1 short rest: Pact slots back, short-rest tracker back; standard slots, long tracker, temporary slot unchanged',
  (public.get_character_spell_slots(:'c9') -> 'pact_magic' ->> 'remaining')::int = 2 and tl_test.remaining(:'c9', 1) = 2
  and (select current from public.feature_trackers where character_id = :'c9' and name = 'Short thing') = 2
  and (select current from public.feature_trackers where character_id = :'c9' and name = 'Long thing') = 0
  and jsonb_array_length(public.get_character_spell_slots(:'c9') -> 'temporary') = 1);
select public.expend_pact_magic_slot(:'c9');
select tl_test.rec('R2 the same rest id is applied once (retry safe): the Pact slot used afterwards stays used',
  (public.short_rest_character(:'c9', 'eeeeeeee-0000-0000-0000-000000000001') ->> 'already_applied')::boolean
  and (public.get_character_spell_slots(:'c9') -> 'pact_magic' ->> 'remaining')::int = 1);
select public.long_rest_character(:'c9') as rest3 \gset
select tl_test.rec('R3b the long rest result reports the standard slots per level and the Pact slot it restored'
  || ' (from 20261017001000; not applicable on the rolled-back functions)',
  (not exists (select 1 from pg_proc where proname = '_rest' and prosrc like '%report the value before the update%') or (:'rest3'::jsonb -> 'restored' -> 'standard_slots' = '[{"slot_level": 1, "restored": 1}]'::jsonb
  and (:'rest3'::jsonb -> 'restored' ->> 'pact_slots')::int = 1
  and exists (select 1 from jsonb_array_elements(:'rest3'::jsonb -> 'breakdown' -> 'restored') x
              where x ->> 'kind' = 'standard' and (x ->> 'amount')::int = 1))),
  :'rest3');
select tl_test.rec('R3 long rest: standard and Pact slots, trackers and manual slots back; temporary slot removed; HP untouched',
  tl_test.remaining(:'c9', 1) = 3 and (public.get_character_spell_slots(:'c9') -> 'pact_magic' ->> 'remaining')::int = 2
  and (select current from public.feature_trackers where character_id = :'c9' and name = 'Long thing') = 1
  and (select used from public.spell_slots where character_id = :'c9' and level = 1) = 0
  and jsonb_array_length(public.get_character_spell_slots(:'c9') -> 'temporary') = 0
  and (select count(*) from public.character_resource_events where character_id = :'c9' and event_type = 'long_rest') = 1);

-- ---- eligibility and limits ---------------------------------------------------------------------------------------------------
select tl_test.rec('E1 the class source was created automatically, linked, not a preview, enforcing its list',
  (select not is_preview and enforce_spell_list and source_type = 'class' from public.character_spellcasting_sources where id = tl_test.src(:'c1', 'wizard')));
select tl_test.rec('E2 Wizard 3 inside a caster-level-5 character cannot take a 3rd-level Wizard spell (class level decides, not slots)',
  tl_test.raises(format('select public.set_character_spell(%L, %L, ''fireball-phb'')', :'c1', tl_test.src(:'c1', 'wizard'))) like '%level 3 spell; a level 3 Wizard can choose spells up to level 2%');
select public.set_character_spell(:'c1', tl_test.src(:'c1', 'wizard'), 'misty-step-phb');
select tl_test.rec('E3 a 2nd-level Wizard spell and a cantrip are accepted',
  tl_test.raises(format('select public.set_character_spell(%L, %L, ''fire-bolt-phb'')', :'c1', tl_test.src(:'c1', 'wizard'))) is null
  and exists (select 1 from public.character_spells where source_id = tl_test.src(:'c1', 'wizard') and spell_version_id = 'misty-step-phb'));
select tl_test.rec('E4 Paladin 1 cannot take spells yet; Paladin 2 can',
  tl_test.raises(format('select public.set_character_spell(%L, %L, ''bless-phb'')', :'c6', tl_test.src(:'c6', 'paladin'))) like '%starts at level 2%'
  and tl_test.raises(format('select public.set_character_spell(%L, %L, ''bless-phb'')', :'c3', tl_test.src(:'c3', 'paladin'))) is null);
select tl_test.as_root();
update public.character_spellcasting_sources set enforce_spell_list = false where id = tl_test.src(:'c3', 'paladin');
select tl_test.as_user(:'alice');
select tl_test.rec('E5 classes without cantrips (Paladin) cannot take one even with the list check off',
  tl_test.raises(format('select public.set_character_spell(%L, %L, ''sacred-flame-phb'')', :'c3', tl_test.src(:'c3', 'paladin'))) like '%does not learn cantrips%');
-- Cleric 2, WIS 12 (+1): 1 + 2 = 3 prepared
select public.set_character_spell(:'c1', tl_test.src(:'c1', 'cleric'), 'bless-phb', true, true);
select public.set_character_spell(:'c1', tl_test.src(:'c1', 'cleric'), 'cure-wounds-phb', true, true);
select public.set_character_spell(:'c1', tl_test.src(:'c1', 'cleric'), 'guiding-bolt-phb', true, true);
select public.set_character_spell(:'c1', tl_test.src(:'c1', 'cleric'), 'sacred-flame-phb', true, true);
select tl_test.rec('E6 Cleric prepared limit = WIS modifier + cleric level (3); cantrips are not counted',
  (tl_test.klass(:'c1', 'cleric') -> 'spellcasting' ->> 'prepared_limit')::int = 3
  and (tl_test.klass(:'c1', 'cleric') -> 'spellcasting' -> 'counts' ->> 'prepared')::int = 3);
select tl_test.rec('E7 preparing a 4th counted spell is refused',
  tl_test.raises(format('select public.set_character_spell(%L, %L, ''healing-word-phb'', true, true)', :'c1', tl_test.src(:'c1', 'cleric'))) like '%can prepare 3 spells and has 3 prepared%');
select tl_test.rec('E8 the limit counts only this class source (manual, item, lineage spells never count)',
  (select count(*) from public.character_spellcasting_sources where character_id = :'c1') = 2
  and (tl_test.klass(:'c1', 'wizard') -> 'spellcasting' -> 'counts' ->> 'prepared')::int = 0);
select tl_test.as_root();
update public.characters set wisdom = 8 where id = :'c1';
select tl_test.as_user(:'alice');
select tl_test.rec('E9 lower Wisdom: over the prepared limit is a warning; nothing is unprepared automatically',
  tl_test.warn(:'c1', 'over_prepared') and (tl_test.klass(:'c1', 'cleric') -> 'spellcasting' ->> 'prepared_limit')::int = 1
  and (select count(*) from public.character_spells where source_id = tl_test.src(:'c1', 'cleric') and prepared) = 4);
select public.set_character_spell_prepared((select id from public.character_spells where source_id = tl_test.src(:'c1', 'cleric') and spell_version_id = 'bless-phb'), false);
select tl_test.rec('E10 unpreparing is allowed while over the limit',
  (select count(*) from public.character_spells where source_id = tl_test.src(:'c1', 'cleric') and prepared and spell_version_id <> 'sacred-flame-phb') = 2);
select tl_test.rec('E11 prepared formulas: Paladin 5 CHA 16 = 3 + 2; Artificer 3 INT 16 = 3 + 1; Wizard 3 INT 16 = 6',
  (tl_test.klass(:'c2', 'paladin') -> 'spellcasting' ->> 'prepared_limit')::int = 5
  and (tl_test.klass(:'c4', 'artificer') -> 'spellcasting' ->> 'prepared_limit')::int = 4
  and (tl_test.klass(:'c1', 'wizard') -> 'spellcasting' ->> 'prepared_limit')::int = 6
  and tl_test.klass(:'c9', 'sorcerer') -> 'spellcasting' ->> 'prepared_limit' is null);
select tl_test.cls(:'c1', 'wizard-phb', 5, null, false);
select public.set_character_spell(:'c1', tl_test.src(:'c1', 'wizard'), 'fireball-phb');
select tl_test.cls(:'c1', 'wizard-phb', 3, null, false);
select tl_test.rec('E12 lowering Wizard 5 -> 3 keeps Fireball and reports it for review',
  exists (select 1 from public.character_spells where source_id = tl_test.src(:'c1', 'wizard') and spell_version_id = 'fireball-phb')
  and tl_test.warn(:'c1', 'spell_above_class_level')
  and jsonb_array_length(tl_test.klass(:'c1', 'wizard') -> 'spellcasting' -> 'spells_above_max_level') = 1);
select tl_test.as_root();
update public.character_classes set level = 1 where id = tl_test.row_id(:'c1', 'cleric');
select tl_test.as_user(:'alice');
select tl_test.rec('E13 a lower maximum clamps the remaining slots at zero, never negative (3rd-level slots gone)',
  tl_test.std(:'c1') = '1:4,2:3' and tl_test.remaining(:'c1', 1) >= 0);

-- ---- removing and changing classes --------------------------------------------------------------------------------------------
select tl_test.rec('X1 removing a class with spells needs a confirmation',
  tl_test.raises(format('select public.remove_character_class(%L)', tl_test.row_id(:'c1', 'cleric'))) like '%confirm to continue%');
select public.save_character_spellcasting_source(:'c1', '{"source_type": "manual", "label": "Manual", "casting_ability": "wis"}');
select public.set_character_spell(:'c1', (select id from public.character_spellcasting_sources where character_id = :'c1' and label = 'Manual'), 'command-phb');
select public.remove_character_class(tl_test.row_id(:'c1', 'cleric'), true);
select tl_test.rec('X2 removing Cleric removes only its source and spells; Wizard and the manual source stay; level 3',
  tl_test.row_id(:'c1', 'cleric') is null
  and not exists (select 1 from public.character_spells g join public.spell_versions v on v.id = g.spell_version_id
                  where g.character_id = :'c1' and v.id in ('bless-phb', 'guiding-bolt-phb'))
  and exists (select 1 from public.character_spells where character_id = :'c1' and spell_version_id = 'command-phb')
  and exists (select 1 from public.character_spells where character_id = :'c1' and spell_version_id = 'misty-step-phb')
  and (select level from public.characters where id = :'c1') = 3
  and (select is_primary from public.character_classes where id = tl_test.row_id(:'c1', 'wizard')));
select tl_test.rec('X3 a class source cannot be deleted on its own',
  tl_test.raises(format('select public.delete_character_spellcasting_source(%L)', tl_test.src(:'c1', 'wizard'))) like '%belongs to a class%');
-- a legacy / alternative class version: the change is explicit and keeps the spells
select tl_test.as_root();
insert into public.class_versions (id, class_id, name, source_label, source_url, status, spellcasting_ability, preparation_mode,
  ritual_mode, caster_type, multiclass_contribution, spellcasting_start_level, slot_progression_id, hit_die, prepared_formula)
values ('zz-wizard-alt', 'wizard', 'Wizard (test version)', 'Test', 'https://example.test/w', 'legacy', 'int', 'spellbook', 'spellbook',
        'full', 'full', 1, 'standard-caster', 'd6', '{"ability": "int", "level_divisor": 1, "minimum": 1}');
insert into public.class_version_levels (class_version_id, level, proficiency_bonus, cantrips_known, max_spell_level, source_url)
select 'zz-wizard-alt', level, proficiency_bonus, cantrips_known, max_spell_level, 'https://example.test/w'
from public.class_version_levels where class_version_id = 'wizard-phb';
select tl_test.as_user(:'alice');
select tl_test.rec('X3b another version of a class the character has is never added silently as a second row',
  tl_test.raises(format('select public.set_character_class(%L, ''zz-wizard-alt'', 3)', :'c1')) like '%already has Wizard%');
select public.set_character_class(:'c1', 'zz-wizard-alt', 3, null, null, tl_test.row_id(:'c1', 'wizard'));
select tl_test.rec('X4 an explicit version change keeps the row, the source and its spells; a legacy version is reported',
  (select class_version_id from public.character_classes where character_id = :'c1' and class_id = 'wizard') = 'zz-wizard-alt'
  and (select class_version_id from public.character_spellcasting_sources where id = tl_test.src(:'c1', 'wizard')) = 'zz-wizard-alt'
  and exists (select 1 from public.character_spells where source_id = tl_test.src(:'c1', 'wizard') and spell_version_id = 'misty-step-phb')
  and tl_test.warn(:'c1', 'legacy_class_version'));
select tl_test.rec('X5 the class seed never changes a character''s class version (no newest-wins)',
  (select count(*) from public.character_classes where class_version_id = 'zz-wizard-alt') = 1);
-- preview source adoption
select public.save_character_spellcasting_source(:'c11', '{"source_type": "class", "label": "Artificer (preview)", "class_version_id": "artificer-tce"}');
select public.set_character_spell(:'c11', (select id from public.character_spellcasting_sources where character_id = :'c11'), 'cure-wounds-phb');
select tl_test.cls(:'c11', 'artificer-tce', 2);
select tl_test.rec('X6 adding a class adopts the existing preview source of that class (same id, spells kept, no longer a preview)',
  (select count(*) from public.character_spellcasting_sources where character_id = :'c11') = 1
  and (select not is_preview from public.character_spellcasting_sources where id = tl_test.src(:'c11', 'artificer'))
  and exists (select 1 from public.character_spells where source_id = tl_test.src(:'c11', 'artificer') and spell_version_id = 'cure-wounds-phb'));
select public.remove_character_class(tl_test.row_id(:'c5', 'artificer'));
select tl_test.rec('X7 removing the last class keeps the last level as the legacy fallback',
  (select level from public.characters where id = :'c5') = 1 and (public.get_character_class_summary(:'c5') ->> 'fallback')::boolean);

-- ---- lineage features follow the total level -------------------------------------------------------------------------------
select public.set_character_lineage(:'c12', 'tiefling-phb', 'tiefling-asmodeus');
select tl_test.cls(:'c12', 'wizard-phb', 2);
select tl_test.rec('V1 total level 2: Hellish Rebuke (3rd) is still locked',
  (select (s ->> 'unlocked')::boolean from jsonb_array_elements(public.get_character_spellbook(:'c12') -> 'spells') s where s ->> 'id' = 'hellish-rebuke-phb') = false);
select tl_test.cls(:'c12', 'warlock-phb', 1);
select tl_test.rec('V2 a level in another class (total 3) unlocks it',
  (select (s ->> 'unlocked')::boolean from jsonb_array_elements(public.get_character_spellbook(:'c12') -> 'spells') s where s ->> 'id' = 'hellish-rebuke-phb'));
select tl_test.rec('V3 multiclass prerequisites are warnings only (INT 16 / CHA 16 pass; a low score warns)',
  not tl_test.warn(:'c12', 'multiclass_prerequisite'));
select tl_test.as_root();
update public.characters set charisma = 8 where id = :'c12';
select tl_test.as_user(:'alice');
select tl_test.rec('V3b with CHA 8 the Warlock prerequisite is reported, nothing is blocked', tl_test.warn(:'c12', 'multiclass_prerequisite'));

-- ---- generic resources (Wild Shape shape, PB-based, ability-based, level x 5) ---------------------------------------------------
select tl_test.cls(:'c13', 'druid-phb', 2);
select public.save_character_resource(:'c13', jsonb_build_object('resource_key', 'wild-shape', 'name', 'Wild Shape', 'source_type', 'class',
  'source_id', 'druid-phb:wild-shape', 'character_class_id', tl_test.row_id(:'c13', 'druid'), 'unlock_level', 2, 'recharge', 'short_or_long_rest',
  'max_formula', '{"table": [[2, 2], [20, null]], "level": "class"}'::jsonb));
select public.save_character_resource(:'c13', '{"resource_key": "lucky-charm", "name": "Lucky charm", "max_formula": {"terms": [{"of": "proficiency_bonus"}]}, "recharge": "long_rest"}');
select public.save_character_resource(:'c13', '{"resource_key": "dawn-gem", "name": "Dawn gem", "max_formula": {"fixed": 3}, "recharge": "dawn"}');
select public.save_character_resource(:'c13', '{"resource_key": "inspire", "name": "Inspiration dice", "die": "d6", "max_formula": {"terms": [{"of": "ability", "ability": "cha"}], "minimum": 1}, "recharge": "long_rest"}');
select public.save_character_resource(:'c13', jsonb_build_object('resource_key', 'healing-pool', 'name', 'Healing pool', 'character_class_id', tl_test.row_id(:'c13', 'druid'),
  'max_formula', '{"terms": [{"of": "class_level", "multiplier": 5}]}'::jsonb));
select tl_test.rec('G1 resource maximums: Wild Shape 2 at Druid 2, PB 2, fixed 3, CHA +3 with d6, 5 x class level = 10',
  (tl_test.res(:'c13', 'wild-shape') ->> 'max')::int = 2 and (tl_test.res(:'c13', 'lucky-charm') ->> 'max')::int = 2
  and (tl_test.res(:'c13', 'dawn-gem') ->> 'max')::int = 3 and (tl_test.res(:'c13', 'inspire') ->> 'max')::int = 3
  and tl_test.res(:'c13', 'inspire') ->> 'die' = 'd6' and (tl_test.res(:'c13', 'healing-pool') ->> 'max')::int = 10);
select public.change_character_resource((tl_test.res(:'c13', 'wild-shape') ->> 'id')::uuid, 1);
select public.change_character_resource((tl_test.res(:'c13', 'wild-shape') ->> 'id')::uuid, 1);
select public.change_character_resource((tl_test.res(:'c13', 'dawn-gem') ->> 'id')::uuid, 2);
select public.change_character_resource((tl_test.res(:'c13', 'lucky-charm') ->> 'id')::uuid, 1);
select tl_test.rec('G2 a resource cannot go below zero remaining',
  tl_test.raises(format('select public.change_character_resource(%L, 1)', tl_test.res(:'c13', 'wild-shape') ->> 'id')) like '%Not enough Wild Shape%');
select public.short_rest_character(:'c13');
select tl_test.rec('G3 short rest restores short-or-long resources (Wild Shape), not long-rest or dawn ones',
  (tl_test.res(:'c13', 'wild-shape') ->> 'remaining')::int = 2 and (tl_test.res(:'c13', 'lucky-charm') ->> 'remaining')::int = 1
  and (tl_test.res(:'c13', 'dawn-gem') ->> 'remaining')::int = 1);
select public.long_rest_character(:'c13');
select tl_test.rec('G4 long rest restores long-rest resources; dawn resources are left to the player',
  (tl_test.res(:'c13', 'lucky-charm') ->> 'remaining')::int = 2 and (tl_test.res(:'c13', 'dawn-gem') ->> 'remaining')::int = 1);
select tl_test.cls(:'c13', 'druid-phb', 1);
select tl_test.rec('G5 below its unlock level the resource is locked and cannot be used',
  not (tl_test.res(:'c13', 'wild-shape') ->> 'unlocked')::boolean
  and tl_test.raises(format('select public.change_character_resource(%L, 1)', tl_test.res(:'c13', 'wild-shape') ->> 'id')) like '%not available%');
select tl_test.cls(:'c13', 'druid-phb', 20);
select tl_test.rec('G6 Druid 20: the table switches Wild Shape to unlimited; the healing pool scales (100)',
  (tl_test.res(:'c13', 'wild-shape') ->> 'unlimited')::boolean and (tl_test.res(:'c13', 'healing-pool') ->> 'max')::int = 100);
select tl_test.rec('G7 unknown resource fields and bad formulas are refused',
  tl_test.raises(format('select public.save_character_resource(%L, ''{"name": "x", "resource_key": "x", "character_id": "%s"}'')', :'c13', :'c13')) like '%cannot be set%'
  and tl_test.raises(format('select public.save_character_resource(%L, ''{"name": "x", "resource_key": "x", "max_formula": {"magic": 1}}'')', :'c13')) like '%fixed, table or terms%');

-- ---- access control ----------------------------------------------------------------------------------------------------------
select tl_test.as_user(:'bob');
select tl_test.rec('A1 another player cannot read or change the classes, slots, resources or rests',
  tl_test.raises(format('select public.get_character_class_summary(%L)', :'c9')) like '%not found%'
  and tl_test.raises(format('select public.set_character_class(%L, ''bard-phb'', 1)', :'c9')) like '%not found%'
  and tl_test.raises(format('select public.expend_standard_spell_slot(%L, 1)', :'c9')) like '%not found%'
  and tl_test.raises(format('select public.long_rest_character(%L)', :'c9')) like '%not found%'
  and (select count(*) from public.character_classes where character_id = :'c9') = 0
  and (select count(*) from public.character_resource_events where character_id = :'c9') = 0);
select tl_test.as_user(:'outsider');
select tl_test.rec('A2 an outsider is denied', tl_test.raises(format('select public.get_character_spell_slots(%L)', :'c9')) like '%not found%');
select tl_test.as_user(:'dm');
select tl_test.rec('A3 the campaign DM reads the summary and slots',
  (public.get_character_class_summary(:'c9') ->> 'total_level')::int = 5 and (public.get_character_spell_slots(:'c9') -> 'pact_magic') is not null);
select tl_test.as_user(:'alice');
select tl_test.rec('A4 direct writes are blocked (RPCs only)',
  tl_test.raises(format('insert into public.character_classes (character_id, class_id, class_version_id, level) values (%L, ''bard'', ''bard-phb'', 1)', :'c14')) like '%permission denied%'
  and tl_test.raises(format('insert into public.character_spell_slot_state (character_id, pool, slot_level) values (%L, ''standard'', 1)', :'c14')) like '%permission denied%'
  and tl_test.raises(format('update public.character_resources set expended = 0 where character_id = %L', :'c13')) like '%permission denied%'
  and tl_test.raises(format('select public._slot_change(%L, ''standard'', 1, 1, null)', :'c1')) like '%permission denied%');
select set_config('role', 'anon', true);
select tl_test.rec('A5 anonymous visitors read the class tables but no character class data',
  (select count(*) from public.class_version_levels where class_version_id not like 'zz-%' and class_version_id not like 'engine-test%') = 260
  and tl_test.raises('select count(*) from public.character_classes') like '%permission denied%');
select tl_test.as_root();
select tl_test.rec('A6 every SECURITY DEFINER function of this feature pins its search_path',
  not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
              where n.nspname = 'public' and p.prosecdef
                and (p.proname like '%class%' or p.proname like '%slot%' or p.proname like '%resource%' or p.proname like '%rest_character%')
                and not exists (select 1 from unnest(coalesce(p.proconfig, '{}')) c where c like 'search_path=%')));
delete from public.characters where id = :'c9';
select tl_test.rec('A7 deleting a character removes its classes, sources, slot state, resources and events',
  not exists (select 1 from public.character_classes where character_id = :'c9')
  and not exists (select 1 from public.character_spell_slot_state where character_id = :'c9')
  and not exists (select 1 from public.character_resource_events where character_id = :'c9'));

-- =============================================================================
-- Report
-- =============================================================================
select tl_test.as_root();
\o
select case when ok then 'PASSED' else 'FAILED' end || '  ' || name || case when ok then '' else '   <-- ' || coalesce(detail, '') end
from tl_test.results order by n;
select format('%s passed, %s failed', count(*) filter (where ok), count(*) filter (where not ok)) from tl_test.results;
select 1 / (count(*) filter (where not ok) = 0)::int as all_checks_passed from tl_test.results;
rollback;
