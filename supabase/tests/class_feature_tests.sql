-- =============================================================================
-- Class feature engine (migration 20261015001800). Same harness as class_slot_tests.sql: one transaction, rolled back;
-- PASSED / FAILED per check; any FAILED check ends with an error. Needs all seeds (incl. class_features.sql) AND the
-- synthetic fixture supabase/tests/fixtures/class_feature_engine_fixture.sql loaded first (the runners do this).
-- Synthetic users only. Concurrency (F28) is tested by feature_resource_concurrency_test.sh; rollback (F60) by the runners.
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
-- class row of the engine test class
create function tl_test.k(p_char uuid) returns uuid language sql as $$
  select id from public.character_classes where character_id = p_char and class_id = 'engine-test' $$;
-- set the engine class level, keeping version and subclass
create function tl_test.lvl(p_char uuid, p_level int) returns jsonb language sql as $$
  select public.set_character_class(p_char, cc.class_version_id, p_level, cc.subclass_version_id, null, cc.id)
  from public.character_classes cc where cc.character_id = p_char and cc.class_id = 'engine-test' $$;
create function tl_test.f(p_char uuid) returns jsonb language sql as $$ select public.get_character_class_features(p_char) $$;
create function tl_test.feat(p_char uuid, p_unlock text) returns jsonb language sql as $$
  select f from jsonb_array_elements(public.get_character_class_features(p_char) -> 'classes') k, jsonb_array_elements(k -> 'features') f
  where k ->> 'class_id' = 'engine-test' and f ->> 'unlock_id' = p_unlock $$;
create function tl_test.ustatus(p_char uuid, p_unlock text) returns text language sql as $$
  select status from public._character_feature_unlocks(p_char) where unlock_id = p_unlock $$;
create function tl_test.ch(p_char uuid, p_key text) returns jsonb language sql as $$
  select c from jsonb_array_elements(public.get_character_class_features(p_char) -> 'classes') k, jsonb_array_elements(k -> 'choices') c
  where k ->> 'class_id' = 'engine-test' and c ->> 'key' = p_key $$;
create function tl_test.choose(p_char uuid, p_unlock text, p_choice text, p_values text[], p_manual text default null) returns jsonb
  language sql as $$ select public.set_character_feature_choice(p_char, tl_test.k(p_char), p_unlock, p_choice, p_values, p_manual) $$;
create function tl_test.res(p_char uuid, p_resource text) returns jsonb language sql as $$
  select r from jsonb_array_elements(public.get_character_resources(p_char) -> 'resources') r where r ->> 'resource_id' = p_resource $$;
create function tl_test.rkey(p_char uuid, p_resource text) returns text language sql as $$
  select 'f:' || tl_test.k(p_char) || ':' || p_resource $$;
create function tl_test.d(p_char uuid) returns jsonb language sql as $$ select public.get_character_derived_stats(p_char) $$;
create function tl_test.warn(p_char uuid, p_code text) returns boolean language sql as $$
  select exists (select 1 from jsonb_array_elements(public.get_character_class_features(p_char) -> 'warnings') w where w ->> 'code' = p_code) $$;
create function tl_test.spell(p_char uuid, p_version text) returns jsonb language sql as $$
  select s from jsonb_array_elements(public.get_character_spellbook(p_char) -> 'spells') s where s ->> 'id' = p_version $$;
grant all on all functions in schema tl_test to public;
grant all on tl_test.results to public;
grant all on sequence tl_test.results_n_seq to public;

-- ---- synthetic users and characters -----------------------------------------------------------------------------------------
\set alice a1111111-1111-1111-1111-111111111111
\set bob b2222222-2222-2222-2222-222222222222
\set dm d3333333-3333-3333-3333-333333333333
\set c1 f1000000-0000-0000-0000-000000000001
\set c2 f1000000-0000-0000-0000-000000000002
\set c3 f1000000-0000-0000-0000-000000000003
\set c4 f1000000-0000-0000-0000-000000000004
\set c5 f1000000-0000-0000-0000-000000000005
\set c6 f1000000-0000-0000-0000-000000000006
\set c7 f1000000-0000-0000-0000-000000000007
insert into auth.users (id, email) values (:'alice', 'alice@test'), (:'bob', 'bob@test'), (:'dm', 'dm@test');
insert into public.campaigns (id, name, created_by) values ('f1c00000-0000-0000-0000-000000000001', 'Feature Campaign', :'dm');
insert into public.campaign_members (campaign_id, user_id, role) values
  ('f1c00000-0000-0000-0000-000000000001', :'alice', 'player'), ('f1c00000-0000-0000-0000-000000000001', :'dm', 'dm');
insert into public.characters (id, owner_id, name, campaign_id, strength, dexterity, constitution, intelligence, wisdom, charisma) values
  (:'c1', :'alice', 'Feature Tester', 'f1c00000-0000-0000-0000-000000000001', 14, 14, 12, 10, 16, 12),
  (:'c2', :'alice', 'Multiclass Tester', null, 10, 14, 12, 16, 12, 10),
  (:'c3', :'alice', 'Manual Proficiency Tester', null, 14, 12, 12, 10, 12, 10),
  (:'c4', :'alice', 'Regression Tester', null, 10, 12, 12, 10, 12, 16),
  (:'c5', :'alice', 'Lineage Tester', null, 15, 12, 14, 10, 12, 10),
  (:'c6', :'alice', 'Import Target', null, 14, 14, 12, 10, 16, 12),
  (:'c7', :'alice', 'Fresh Tester', null, 10, 10, 10, 10, 10, 10);
select id as inv1 from public.inventories where character_id = :'c1' \gset

select tl_test.as_user(:'alice');
select public.set_character_class(:'c1', 'engine-test-fixture', 1);

-- ---- unlocks ---------------------------------------------------------------------------------------------------------------------
select tl_test.rec('F1 a level 1 feature is active at class level 1 (Spirit Strike, Test Surge)',
  tl_test.ustatus(:'c1', 'et-u1-strike') = 'active' and tl_test.ustatus(:'c1', 'et-u1-surge') = 'active'
  and tl_test.feat(:'c1', 'et-u1-strike') ->> 'automation' = 'automated');
select tl_test.rec('F2 a level 2 feature is inactive below its level and listed in the next-level preview, not as a feature',
  tl_test.ustatus(:'c1', 'et-u2-burst') = 'locked' and tl_test.feat(:'c1', 'et-u2-burst') is null
  and exists (select 1 from jsonb_array_elements(tl_test.f(:'c1') -> 'classes' -> 0 -> 'next_level' -> 'features') x where x ->> 'unlock_id' = 'et-u2-burst'));
select tl_test.lvl(:'c1', 2);
select tl_test.rec('F3 raising the class level activates the feature and its resource',
  tl_test.ustatus(:'c1', 'et-u2-burst') = 'active' and (tl_test.res(:'c1', 'et-burst-uses') ->> 'active')::boolean);
select tl_test.lvl(:'c1', 5);
select tl_test.rec('F43a Extra Attack at class level 5: two attacks per Attack action', (tl_test.d(:'c1') -> 'attacks_per_action' ->> 'value')::int = 2);
select tl_test.lvl(:'c1', 4);
select tl_test.rec('F4 lowering the class level deactivates the feature (Extra Attack locked at 4)', tl_test.ustatus(:'c1', 'et-u5-extra-attack') = 'locked');
select tl_test.rec('F5 a deactivated feature stops contributing (one attack per action again)',
  (tl_test.d(:'c1') -> 'attacks_per_action' ->> 'value')::int = 1);
select tl_test.lvl(:'c1', 11);
select tl_test.rec('F43b attack count from the highest Extra Attack effect at 11 (three attacks)', (tl_test.d(:'c1') -> 'attacks_per_action' ->> 'value')::int = 3);
select tl_test.rec('F42 level-scaled attack dice: Spirit Strike 1d10 at 11',
  (select a ->> 'damage_dice' from jsonb_array_elements(tl_test.d(:'c1') -> 'feature_attacks') a where a ->> 'name' = 'Spirit Strike') = '1d10');
select tl_test.lvl(:'c1', 5);
select tl_test.rec('F41 feature attack grant: Spirit Strike STR +2, PB +3 -> +5, 1d8 + 2 force at level 5',
  (select a ->> 'attack_bonus' || '|' || (a ->> 'damage') || '|' || (a ->> 'damage_type') from jsonb_array_elements(tl_test.d(:'c1') -> 'feature_attacks') a
   where a ->> 'name' = 'Spirit Strike') = '5|1d8 + 2|force');

-- ---- choices -------------------------------------------------------------------------------------------------------------------
select tl_test.rec('F13 open choices without values are reported as incomplete',
  exists (select 1 from jsonb_array_elements(tl_test.f(:'c1') -> 'incomplete_choices') x where x ->> 'key' = 'et-u1-fighting-style:et-style')
  and tl_test.ch(:'c1', 'et-u1-fighting-style:et-style') ->> 'status' = 'incomplete');
select tl_test.rec('F10 the minimum number of picks is enforced', tl_test.raises(format(
  'select tl_test.choose(%L, ''et-u1-proficiencies'', ''et-skills'', array[''athletics''])', :'c1')) like '%choose at least 2%');
select tl_test.rec('F11 the maximum number of picks is enforced', tl_test.raises(format(
  'select tl_test.choose(%L, ''et-u1-proficiencies'', ''et-skills'', array[''athletics'', ''perception'', ''stealth''])', :'c1')) like '%at most 2%');
select tl_test.rec('F14 an invalid option or skill is rejected',
  tl_test.raises(format('select tl_test.choose(%L, ''et-u1-fighting-style'', ''et-style'', array[''flying''])', :'c1')) like '%not one of the options%'
  and tl_test.raises(format('select tl_test.choose(%L, ''et-u1-proficiencies'', ''et-skills'', array[''athletics'', ''arcana''])', :'c1')) like '%not an allowed skill%');
select tl_test.rec('F36 expertise requires proficiency in the chosen skill', tl_test.raises(format(
  'select tl_test.choose(%L, ''et-u1-expertise'', ''et-expertise-pick'', array[''athletics'', ''perception''])', :'c1')) like '%needs proficiency%');
select tl_test.choose(:'c1', 'et-u1-proficiencies', 'et-skills', array['athletics', 'perception']);
select tl_test.choose(:'c1', 'et-u1-expertise', 'et-expertise-pick', array['athletics', 'perception']);
select tl_test.rec('F33a skill proficiency and expertise from feature choices reach the derived skills',
  (tl_test.d(:'c1') -> 'skills' -> 'athletics' ->> 'class_proficient')::boolean
  and (tl_test.d(:'c1') -> 'skills' -> 'athletics' ->> 'class_expertise')::boolean
  and tl_test.ch(:'c1', 'et-u1-expertise:et-expertise-pick') ->> 'status' = 'complete');
select tl_test.rec('F12 a dependent sub-choice needs its parent option first', tl_test.raises(format(
  'select tl_test.choose(%L, ''et-u2-discipline'', ''et-element'', array[''fire''])', :'c1')) like '%depends on another choice%'
  and tl_test.ch(:'c1', 'et-u2-discipline:et-element') ->> 'status' = 'disabled');
select tl_test.choose(:'c1', 'et-u2-discipline', 'et-discipline-pick', array['elements']);
select tl_test.choose(:'c1', 'et-u2-discipline', 'et-element', array['fire']);
select tl_test.rec('F12b after choosing Elements the sub-choice works: resistance to fire',
  exists (select 1 from jsonb_array_elements(tl_test.d(:'c1') -> 'resistances') r where r ->> 'damage_type' = 'fire'));
select tl_test.choose(:'c1', 'et-u2-discipline', 'et-discipline-pick', array['body']);
select tl_test.rec('F12c changing the parent keeps the sub-choice (disabled, not deleted) and its effect stops',
  tl_test.ch(:'c1', 'et-u2-discipline:et-element') -> 'values' = '["fire"]'::jsonb
  and tl_test.ch(:'c1', 'et-u2-discipline:et-element') ->> 'status' = 'inactive_preserved'
  and not exists (select 1 from jsonb_array_elements(tl_test.d(:'c1') -> 'resistances') r where r ->> 'damage_type' = 'fire'));
select tl_test.rec('F9b multiple selection: two techniques are accepted, the text prerequisite asks for confirmation',
  tl_test.choose(:'c1', 'et-u2-discipline', 'et-techniques', array['feint', 'forbidden-technique']) is not null
  and tl_test.warn(:'c1', 'prerequisite_confirm'));
-- confirming a prerequisite is a DM control in a campaign (20261019000100): the player is refused, the DM confirms.
-- This suite also runs after the 20261019* rollbacks (run_local.sh), where the player may confirm again.
select tl_test.rec('F9b2 the player cannot confirm the prerequisite themselves (DM-only in a campaign; only with governance)',
  to_regclass('public.campaign_governance') is null
  or tl_test.raises(format('select tl_test.choose(%L, ''et-u2-discipline'', ''et-techniques'', array[''feint'', ''forbidden-technique''], ''confirmed'')', :'c1')) like '%Only the DM%');
select tl_test.as_user(:'dm');
select tl_test.choose(:'c1', 'et-u2-discipline', 'et-techniques', array['feint', 'forbidden-technique'], 'confirmed');
select tl_test.as_user(:'alice');
select tl_test.rec('F9c a confirmed text prerequisite no longer warns', not tl_test.warn(:'c1', 'prerequisite_confirm'));
select tl_test.rec('F12d an evaluable prerequisite blocks: Heavy Stance needs STR 13 (STR 12 here is refused after lowering)',
  (select tl_test.raises(format('update public.characters set strength = 12 where id = %L', :'c1')) is null)
  and tl_test.raises(format('select tl_test.choose(%L, ''et-u1-fighting-style'', ''et-style'', array[''heavy-stance''])', :'c1')) like '%needs STR 13%');
update public.characters set strength = 14 where id = :'c1';

-- ---- optional and replacement features --------------------------------------------------------------------------------------
select tl_test.rec('F7a an optional feature is available until selected (no Elvish yet)',
  tl_test.ustatus(:'c1', 'et-u1-optional-lore') = 'available'
  and not exists (select 1 from jsonb_array_elements(tl_test.d(:'c1') -> 'languages') l where l ->> 'id' = 'elvish'));
select public.set_character_optional_feature(:'c1', tl_test.k(:'c1'), 'et-u1-optional-lore', true);
select tl_test.rec('F7 selecting the optional feature activates it: Elvish from the class feature',
  tl_test.ustatus(:'c1', 'et-u1-optional-lore') = 'active'
  and exists (select 1 from jsonb_array_elements(tl_test.d(:'c1') -> 'languages') l where l ->> 'id' = 'elvish'));
select tl_test.rec('F8a before the replacement: Keen Senses gives +1 initiative',
  tl_test.ustatus(:'c1', 'et-u3-keen-senses') = 'active' and (tl_test.d(:'c1') -> 'initiative' ->> 'bonus')::int = 1);
select public.set_character_optional_feature(:'c1', tl_test.k(:'c1'), 'et-u3-swift-reflexes', true);
select tl_test.rec('F8 a replacement feature deactivates the replaced feature (initiative = PB 3, not PB + 1; +5 ft speed)',
  tl_test.ustatus(:'c1', 'et-u3-keen-senses') = 'replaced' and tl_test.ustatus(:'c1', 'et-u3-swift-reflexes') = 'active'
  and (tl_test.d(:'c1') -> 'initiative' ->> 'bonus')::int = 3 and (tl_test.d(:'c1') -> 'speed' ->> 'value')::int = 35
  and tl_test.feat(:'c1', 'et-u3-keen-senses') -> 'replaced_by' ->> 'unlock_id' = 'et-u3-swift-reflexes');
select public.set_character_optional_feature(:'c1', tl_test.k(:'c1'), 'et-u3-swift-reflexes', false);
select tl_test.rec('F9 removing the replacement restores the base feature',
  tl_test.ustatus(:'c1', 'et-u3-keen-senses') = 'active' and (tl_test.d(:'c1') -> 'initiative' ->> 'bonus')::int = 1
  and (tl_test.d(:'c1') -> 'speed' ->> 'value')::int = 30);
select public.set_character_optional_feature(:'c1', tl_test.k(:'c1'), 'et-u3-swift-reflexes', true);
select tl_test.rec('F7b a non-optional feature cannot be toggled', tl_test.raises(format(
  'select public.set_character_optional_feature(%L, tl_test.k(%L), ''et-u1-strike'', true)', :'c1', :'c1')) like '%not optional%');

-- ---- subclass -----------------------------------------------------------------------------------------------------------------------
select tl_test.lvl(:'c1', 2);
select tl_test.rec('F17 a subclass is not selectable before its level', tl_test.raises(format(
  'select public.set_character_subclass(%L, tl_test.k(%L), ''engine-test-path-fixture'')', :'c1', :'c1')) like '%can be chosen from%level 3%');
select tl_test.lvl(:'c1', 3);
select tl_test.rec('F19 a subclass of another class is rejected', tl_test.raises(format(
  'select public.set_character_subclass(%L, tl_test.k(%L), ''fighter-eldritch-knight-phb'')', :'c1', :'c1')) like '%does not belong%');
select tl_test.rec('F18a at level 3 without a subclass: warning, subclass choice incomplete',
  tl_test.warn(:'c1', 'subclass_not_chosen') and tl_test.ch(:'c1', 'et-u3-subclass:et-subclass-pick') ->> 'status' = 'incomplete');
select public.set_character_subclass(:'c1', tl_test.k(:'c1'), 'engine-test-path-fixture');
select tl_test.rec('F18 the subclass activates at its level; subclass features and the subclass choice are complete',
  (select k -> 'subclass' ->> 'status' from jsonb_array_elements(tl_test.f(:'c1') -> 'classes') k) = 'active'
  and tl_test.ustatus(:'c1', 'et-p3-precision') = 'active' and tl_test.ch(:'c1', 'et-u3-subclass:et-subclass-pick') ->> 'status' = 'complete'
  and (tl_test.d(:'c1') -> 'critical_range' ->> 'value')::int = 19);
select tl_test.rec('F20 a subclass feature follows the class level (Path Mastery locked at 3, active at 7 with its resource)',
  tl_test.ustatus(:'c1', 'et-p7-mastery') = 'locked'
  and (select tl_test.lvl(:'c1', 7)) is not null and tl_test.ustatus(:'c1', 'et-p7-mastery') = 'active'
  and (tl_test.res(:'c1', 'et-path-mastery-uses') ->> 'max')::int = 2);
select tl_test.rec('F20b a unlock prerequisite on the subclass: Advanced Technique active only with the Test Path',
  tl_test.ustatus(:'c1', 'et-u6-advanced') = 'active' and (tl_test.d(:'c1') -> 'saving_throws' -> 'str' ->> 'item_bonus')::int = 1);
select tl_test.lvl(:'c1', 2);
select tl_test.rec('F15 a temporary level reduction keeps the subclass and choices (inactive, flagged)',
  (select cc.subclass_version_id from public.character_classes cc where cc.id = tl_test.k(:'c1')) = 'engine-test-path-fixture'
  and tl_test.warn(:'c1', 'subclass_below_level') and tl_test.ustatus(:'c1', 'et-p3-precision') = 'subclass_inactive'
  and (tl_test.d(:'c1') -> 'critical_range' ->> 'value')::int = 20);
select tl_test.lvl(:'c1', 5);
select tl_test.choose(:'c1', 'et-u3-insight', 'et-cantrip', array['light-phb']);
select tl_test.lvl(:'c1', 2);
select tl_test.rec('F16 a preserved choice of an inactive feature is inactive: its cantrip leaves the spellbook, values are kept',
  tl_test.ch(:'c1', 'et-u3-insight:et-cantrip') ->> 'status' = 'inactive_preserved'
  and tl_test.ch(:'c1', 'et-u3-insight:et-cantrip') -> 'values' = '["light-phb"]'::jsonb
  and tl_test.spell(:'c1', 'light-phb') is null and tl_test.warn(:'c1', 'choice_inactive_preserved'));
select tl_test.lvl(:'c1', 5);
select tl_test.rec('F15b back at level 5 the preserved choices work again (cantrip back, subclass active)',
  tl_test.spell(:'c1', 'light-phb') is not null and tl_test.ustatus(:'c1', 'et-p3-precision') = 'active');

-- ---- resources ---------------------------------------------------------------------------------------------------------------------
select tl_test.rec('F21 fixed maximum: Test Surge 1', (tl_test.res(:'c1', 'et-surge-uses') ->> 'max')::int = 1);
select tl_test.rec('F22 class-level maximum: Test Focus Pool 5 at level 5', (tl_test.res(:'c1', 'et-focus-points') ->> 'max')::int = 5);
select tl_test.rec('F23 proficiency-bonus maximum: Test Reserve 3 at total level 5', (tl_test.res(:'c1', 'et-reserve-uses') ->> 'max')::int = 3);
update public.characters set charisma = 8 where id = :'c1';
select tl_test.rec('F24a ability-modifier maximum with minimum 1: CHA 8 (-1) -> 1', (tl_test.res(:'c1', 'et-inspiration-uses') ->> 'max')::int = 1);
update public.characters set charisma = 16 where id = :'c1';
select tl_test.rec('F24b CHA 16 (+3) -> 3 uses; the die scales with level (d8 at 5)',
  (tl_test.res(:'c1', 'et-inspiration-uses') ->> 'max')::int = 3 and tl_test.res(:'c1', 'et-inspiration-uses') ->> 'die' = 'd8');
update public.characters set charisma = 12 where id = :'c1';
select tl_test.rec('F25 table maximum: Test Burst 1 at 5, 2 at 17',
  (tl_test.res(:'c1', 'et-burst-uses') ->> 'max')::int = 1
  and (select tl_test.lvl(:'c1', 17)) is not null and (tl_test.res(:'c1', 'et-burst-uses') ->> 'max')::int = 2
  and (select tl_test.lvl(:'c1', 5)) is not null);
select tl_test.rec('F26 nothing to restore: a resource cannot go below 0 used', tl_test.raises(format(
  'select public.restore_character_resource(%L, %L)', :'c1', tl_test.rkey(:'c1', 'et-surge-uses'))) like '%Nothing of Test Surge to restore%');
create temp table ex_surge as select public.expend_character_resource(:'c1', tl_test.rkey(:'c1', 'et-surge-uses')) as r;
select tl_test.rec('F27a spending works and is logged',
  (select (r ->> 'remaining')::int from ex_surge) = 0
  and exists (select 1 from public.character_resource_events e where e.character_id = :'c1' and e.feature_resource_id = 'et-surge-uses' and e.event_type = 'expend'));
select tl_test.rec('F27 a resource cannot be over-expended', tl_test.raises(format(
  'select public.expend_character_resource(%L, %L)', :'c1', tl_test.rkey(:'c1', 'et-surge-uses'))) like '%Not enough Test Surge left%');
select public.expend_character_resource(:'c1', tl_test.rkey(:'c1', 'et-reserve-uses'), 2);
select public.expend_character_resource(:'c1', tl_test.rkey(:'c1', 'et-focus-points'), 4);
select public.expend_character_resource(:'c1', tl_test.rkey(:'c1', 'et-inspiration-uses'));
select tl_test.rec('F27b an inactive resource cannot be spent (Path Mastery below level 7)', tl_test.raises(format(
  'select public.expend_character_resource(%L, %L)', :'c1', tl_test.rkey(:'c1', 'et-path-mastery-uses'))) like '%not granted%');
create temp table set_burst as select public.set_character_resource_state(:'c1', tl_test.rkey(:'c1', 'et-burst-uses'), 1, 'forgot to mark it') as r;
select tl_test.rec('F27c a manual correction needs a reason and is logged as manual_set',
  tl_test.raises(format('select public.set_character_resource_state(%L, %L, 1, '''')', :'c1', tl_test.rkey(:'c1', 'et-burst-uses'))) like '%needs a reason%'
  and (select (r ->> 'expended')::int from set_burst) = 1
  and exists (select 1 from public.character_resource_events e where e.character_id = :'c1' and e.feature_resource_id = 'et-burst-uses' and e.event_type = 'manual_set'));
-- a manual (non-class) resource that recovers only by hand
select public.save_character_resource(:'c1', '{"resource_key": "manual-charm", "name": "Manual charm", "recharge": "manual", "max_formula": {"fixed": 2}}');
select public.change_character_resource((select id from public.character_resources where character_id = :'c1' and resource_key = 'manual-charm'), 1);
create temp table sr as select public.short_rest_character(:'c1') as r;
select tl_test.rec('F29 a short rest restores short-rest resources (Test Surge, Test Burst) and 1 Focus point (partial recovery)',
  (tl_test.res(:'c1', 'et-surge-uses') ->> 'remaining')::int = 1 and (tl_test.res(:'c1', 'et-burst-uses') ->> 'remaining')::int = 1
  and (tl_test.res(:'c1', 'et-focus-points') ->> 'remaining')::int = 2
  and exists (select 1 from sr, jsonb_array_elements(sr.r -> 'breakdown' -> 'restored') x where x ->> 'name' = 'Test Focus Pool' and (x ->> 'partial')::boolean));
select tl_test.rec('F30 a short rest does not restore long-rest resources (Reserve, Inspiration) and lists them as not restored',
  (tl_test.res(:'c1', 'et-reserve-uses') ->> 'remaining')::int = 1 and (tl_test.res(:'c1', 'et-inspiration-uses') ->> 'remaining')::int = 0
  and exists (select 1 from sr, jsonb_array_elements(sr.r -> 'breakdown' -> 'not_restored') x where x ->> 'name' = 'Test Reserve'));
create temp table lr as select public.long_rest_character(:'c1') as r;
select tl_test.rec('F31 a long rest restores long-rest and short-rest resources',
  (tl_test.res(:'c1', 'et-reserve-uses') ->> 'remaining')::int = 3 and (tl_test.res(:'c1', 'et-inspiration-uses') ->> 'remaining')::int = 1
  and (tl_test.res(:'c1', 'et-focus-points') ->> 'remaining')::int = 5);
select tl_test.rec('F32 a manual-recovery resource is not restored by rests and is listed',
  (select expended from public.character_resources where character_id = :'c1' and resource_key = 'manual-charm') = 1
  and exists (select 1 from lr, jsonb_array_elements(lr.r -> 'breakdown' -> 'not_restored') x where x ->> 'name' = 'Manual charm' and x ->> 'reason' = 'manual'));
select tl_test.rec('F32b temporary bonus uses: counted on top of the maximum, removed by a long rest',
  (public.set_character_resource_state(:'c1', tl_test.rkey(:'c1', 'et-surge-uses'), 0, 'blessing', 1) ->> 'max')::int = 2
  and (select public.long_rest_character(:'c1')) is not null and (tl_test.res(:'c1', 'et-surge-uses') ->> 'max')::int = 1);

-- ---- grants: proficiencies, spells, effects --------------------------------------------------------------------------------------
select tl_test.rec('F33 feature proficiency grants: martial weapons and heavy armor (subclass) listed with their class source; a longsword is proficient',
  exists (select 1 from jsonb_array_elements(tl_test.d(:'c1') -> 'proficiencies') p where p ->> 'group_id' = 'martial-weapons' and p ->> 'source_type' = 'class')
  and exists (select 1 from jsonb_array_elements(tl_test.d(:'c1') -> 'proficiencies') p where p ->> 'group_id' = 'heavy-armor' and p ->> 'source_type' = 'class')
  and public._proficiency_match(:'c1', 'longsword', null, 'martial-weapons') ->> 'matched_by' = 'class_feature');
select tl_test.rec('F33b the primary class grants its saving throws (WIS, CON)',
  (tl_test.d(:'c1') -> 'saving_throws' -> 'wis' ->> 'class_proficient')::boolean and (tl_test.d(:'c1') -> 'saving_throws' -> 'con' ->> 'class_proficient')::boolean);
select tl_test.rec('F37 feature spell grants: Detect Magic (class) and Shield (subclass) always prepared, from the feature source',
  (select bool_and((g ->> 'always_prepared')::boolean) from jsonb_array_elements(tl_test.spell(:'c1', 'detect-magic-phb') -> 'grants') g where g ->> 'source_type' = 'class_feature')
  and tl_test.spell(:'c1', 'shield-phb') ->> 'always_prepared' = 'true'
  and exists (select 1 from jsonb_array_elements(public.get_character_spellbook(:'c1') -> 'sources') s where s ->> 'source_type' = 'class_feature'));
select public.save_character_spellcasting_source(:'c1', '{"source_type": "manual", "label": "Manual Spellcasting Source", "casting_ability": "int"}');
select public.set_character_spell(:'c1', (select id from public.character_spellcasting_sources where character_id = :'c1' and source_type = 'manual'), 'detect-magic-phb');
select tl_test.rec('F38a the same spell from a feature and a manual source: one card, two sources', (tl_test.spell(:'c1', 'detect-magic-phb') ->> 'source_count')::int = 2);
select tl_test.lvl(:'c1', 2);
select tl_test.rec('F38 deactivating the feature removes only its spell source (Detect Magic keeps the manual grant)',
  (tl_test.spell(:'c1', 'detect-magic-phb') ->> 'source_count')::int = 1
  and (tl_test.spell(:'c1', 'detect-magic-phb') -> 'grants' -> 0 ->> 'source_type') = 'manual');
select tl_test.rec('F39 other spell sources and stored spells remain', exists (select 1 from public.character_spells where character_id = :'c1'));
select tl_test.lvl(:'c1', 5);
select tl_test.rec('F44 an informational feature does not apply mechanics (Tactical Note: no Stealth advantage)',
  not coalesce((tl_test.d(:'c1') -> 'skills' -> 'stealth' ->> 'advantage')::boolean, false)
  and (select e ->> 'inactive_reason' from jsonb_array_elements(tl_test.feat(:'c1', 'et-u2-tactical-note') -> 'effects') e) = 'informational'
  and tl_test.feat(:'c1', 'et-u2-tactical-note') ->> 'automation' = 'informational');
select tl_test.rec('F45a the ASI placeholder stays incomplete without a choice',
  tl_test.ch(:'c1', 'et-u4-asi:et-asi-pick') ->> 'status' = 'incomplete'
  and exists (select 1 from jsonb_array_elements(tl_test.f(:'c1') -> 'incomplete_choices') x where x ->> 'key' = 'et-u4-asi:et-asi-pick'));
select tl_test.choose(:'c1', 'et-u4-asi', 'et-asi-pick', array['str:2']);
select tl_test.rec('F45b a completed ASI (+2 STR) applies: STR 16 with the class feature as source',
  tl_test.ch(:'c1', 'et-u4-asi:et-asi-pick') ->> 'status' = 'complete' and (tl_test.d(:'c1') -> 'abilities' -> 'str' ->> 'score')::int = 16);
select tl_test.choose(:'c1', 'et-u4-asi', 'et-asi-pick', array['str:2'], 'applied_manually');
select tl_test.rec('F45c "already in my scores" keeps the choice complete but adds nothing', (tl_test.d(:'c1') -> 'abilities' -> 'str' ->> 'score')::int = 14
  and tl_test.ch(:'c1', 'et-u4-asi:et-asi-pick') ->> 'status' = 'complete');
select tl_test.choose(:'c1', 'et-u4-asi', 'et-asi-pick', array['feat:Alert']);
select tl_test.rec('F45d a feat placeholder completes the ASI without ability changes; invalid ASI values are refused',
  tl_test.ch(:'c1', 'et-u4-asi:et-asi-pick') ->> 'status' = 'complete' and (tl_test.d(:'c1') -> 'abilities' -> 'str' ->> 'score')::int = 14
  and tl_test.raises(format('select tl_test.choose(%L, ''et-u4-asi'', ''et-asi-pick'', array[''str:2'', ''dex:1''])', :'c1')) like '%at most 2 points%');

-- equipment conditions: Defense (+1 AC in armor) vs the unarmored formula; Archery; Dueling
select tl_test.choose(:'c1', 'et-u1-fighting-style', 'et-style', array['defense']);
select tl_test.rec('F50a unarmored: the class AC formula 10 + DEX + WIS = 15 applies; Defense is inactive without armor',
  (tl_test.d(:'c1') -> 'armor_class' ->> 'value')::int = 15 and tl_test.d(:'c1') -> 'armor_class' ->> 'base_formula' = 'class_feature'
  and exists (select 1 from jsonb_array_elements(tl_test.d(:'c1') -> 'armor_class' -> 'inactive_effects') e where e ->> 'inactive_reason' = 'not_wearing_armor'));
select public.add_inventory_item(:'inv1', 'chain-mail', 1) as mail \gset
select public.equip_item(:'mail', 'armor');
select public.add_inventory_item(:'inv1', 'ring-of-protection', 1) as ring \gset
select public.equip_item(:'ring', 'ring_1');
select public.attune_item(:'ring');
select tl_test.rec('F50 item effects still apply next to class effects: Chain Mail 16 + Defense 1 + Ring of Protection 1 = 18',
  (tl_test.d(:'c1') -> 'armor_class' ->> 'value')::int = 18 and tl_test.d(:'c1') -> 'armor_class' ->> 'base_formula' = 'heavy_armor'
  and (select count(*) from jsonb_array_elements(tl_test.d(:'c1') -> 'armor_class' -> 'breakdown') p where p ->> 'effect' = 'ac_bonus') = 2);
select tl_test.choose(:'c1', 'et-u1-fighting-style', 'et-style', array['archery']);
select public.add_inventory_item(:'inv1', 'shortbow', 1) as bow \gset
select public.equip_item(:'bow', 'main_hand');
select tl_test.rec('F50b Archery: +2 to the ranged weapon attack (DEX 2 + PB 3 + 2 = 7)',
  (select (w ->> 'attack_bonus')::int from jsonb_array_elements(tl_test.d(:'c1') -> 'equipped_weapon_attacks') w where w ->> 'item_id' = 'shortbow') = 7);
select public.unequip_item(:'bow');
select tl_test.choose(:'c1', 'et-u1-fighting-style', 'et-style', array['dueling']);
select public.add_inventory_item(:'inv1', 'longsword', 1) as sword \gset
select public.equip_item(:'sword', 'main_hand');
select tl_test.rec('F50c Dueling: +2 damage with one melee weapon (1d8 + 4)',
  (select w ->> 'damage' from jsonb_array_elements(tl_test.d(:'c1') -> 'equipped_weapon_attacks') w where w ->> 'item_id' = 'longsword') = '1d8 + 4');

-- ---- class removal keeps unrelated grants (manual proficiency of the same value) -----------------------------------------------
select public.set_character_proficiency(:'c3', 'martial-weapons');
select public.set_character_class(:'c3', 'engine-test-fixture', 1);
select tl_test.rec('F34a with the class: shields come from the class, martial weapons from both the class and the manual row',
  exists (select 1 from jsonb_array_elements(tl_test.d(:'c3') -> 'proficiencies') p where p ->> 'group_id' = 'shields' and p ->> 'source_type' = 'class')
  and (select count(*) from jsonb_array_elements(tl_test.d(:'c3') -> 'proficiencies') p where p ->> 'group_id' = 'martial-weapons') = 2);
select public.remove_character_class(tl_test.k(:'c3'), true);
select tl_test.rec('F34 removing the class removes only its derived grants (shields gone)',
  not exists (select 1 from jsonb_array_elements(tl_test.d(:'c3') -> 'proficiencies') p where p ->> 'group_id' = 'shields'));
select tl_test.rec('F35 the manual proficiency with the same value remains',
  exists (select 1 from jsonb_array_elements(tl_test.d(:'c3') -> 'proficiencies') p where p ->> 'group_id' = 'martial-weapons' and p ->> 'source_type' <> 'class')
  and exists (select 1 from public.character_proficiencies where character_id = :'c3' and group_id = 'martial-weapons'));

-- ---- multiclass, primary-class grants, regressions ---------------------------------------------------------------------------
select public.set_character_class(:'c2', 'wizard-phb', 3);
select public.set_character_class(:'c2', 'engine-test-fixture', 3);
select tl_test.rec('F22b multiclass grants: the non-primary test class gives no saving throws or martial weapons, but its multiclass skill choice',
  -- the fixture class saves are WIS and CON; the primary Wizard grants INT and WIS itself, so CON is the one to check
  not coalesce((tl_test.d(:'c2') -> 'saving_throws' -> 'con' ->> 'class_proficient')::boolean, false)
  and not exists (select 1 from jsonb_array_elements(tl_test.d(:'c2') -> 'proficiencies') p where p ->> 'group_id' = 'martial-weapons')
  and exists (select 1 from jsonb_array_elements(tl_test.d(:'c2') -> 'proficiencies') p where p ->> 'group_id' = 'light-armor')
  and tl_test.ch(:'c2', 'et-u1-proficiencies:et-skills') ->> 'status' = 'not_applicable'
  and tl_test.ch(:'c2', 'et-u1-proficiencies:et-skills-mc') ->> 'status' = 'incomplete');
select tl_test.rec('F46 total level and proficiency bonus stay correct (Wizard 3 + Test 3 = 6, PB +3)',
  (tl_test.f(:'c2') ->> 'total_level')::int = 6 and (tl_test.f(:'c2') ->> 'proficiency_bonus')::int = 3
  and (select level from public.characters where id = :'c2') = 6);
select tl_test.rec('F47 spell slots unchanged: Wizard 3 alone counts (4 / 2)',
  (select string_agg((e ->> 'slot_level') || ':' || (e ->> 'max'), ',' order by (e ->> 'slot_level')::int)
   from jsonb_array_elements(public.get_character_spell_slots(:'c2') -> 'standard') e) = '1:4,2:2');
select tl_test.rec('F40 an always-prepared feature spell does not count against the Wizard prepared limit',
  (select (k -> 'spellcasting' -> 'counts' ->> 'prepared')::int from jsonb_array_elements(public.get_character_class_summary(:'c2') -> 'classes') k
   where k ->> 'class_id' = 'wizard') = 0
  and (tl_test.spell(:'c2', 'detect-magic-phb') ->> 'always_prepared')::boolean);
select public.set_character_class(:'c4', 'warlock-phb', 3);
select tl_test.rec('F48 Pact Magic unchanged (Warlock 3: 2 slots of 2nd level); the Warlock features come from the official catalog',
  (public.get_character_spell_slots(:'c4') -> 'pact_magic' ->> 'max')::int = 2 and (public.get_character_spell_slots(:'c4') -> 'pact_magic' ->> 'slot_level')::int = 2
  and (jsonb_array_length(tl_test.f(:'c4') -> 'classes' -> 0 -> 'features') = 0
       or exists (select 1 from jsonb_array_elements(tl_test.f(:'c4') -> 'classes' -> 0 -> 'features') f where f ->> 'name' = 'Pact Magic')));
select public.set_character_lineage(:'c5', 'dwarf-phb', 'dwarf-mountain', '{"dwarf-phb:tool": ["smiths-tools"]}');
select tl_test.rec('F49 lineages unchanged (Mountain Dwarf: STR 17, speed 25)',
  (tl_test.d(:'c5') -> 'abilities' -> 'str' ->> 'score')::int = 17 and (tl_test.d(:'c5') -> 'speed' ->> 'value')::int = 25);

-- ---- level change review (read only) and class version change ------------------------------------------------------------------
create temp table pv as select public.preview_character_class_change(:'c1', tl_test.k(:'c1'), 6) as p;
select tl_test.rec('F62 the level preview lists new features and resource changes, and stores nothing',
  (select (p ->> 'possible')::boolean and not (p ->> 'stored')::boolean from pv)
  and exists (select 1 from pv, jsonb_array_elements(pv.p -> 'features_activated') f where f ->> 'name' = 'Advanced Technique')
  and exists (select 1 from pv, jsonb_array_elements(pv.p -> 'resources') r where r ->> 'name' = 'Test Focus Pool' and (r ->> 'max_to')::int = 6)
  and (select level from public.character_classes where id = tl_test.k(:'c1')) = 5);
create temp table pv2 as select public.preview_character_class_change(:'c1', tl_test.k(:'c1'), 2) as p;
select tl_test.rec('F62b the decrease preview lists deactivated features, inactive choices and the subclass going inactive',
  exists (select 1 from pv2, jsonb_array_elements(pv2.p -> 'features_deactivated') f where f ->> 'name' = 'Extra Attack')
  and exists (select 1 from pv2, jsonb_array_elements(pv2.p -> 'choices_inactive') c where c ->> 'label' = 'One Wizard cantrip')
  and (select p -> 'subclass' ->> 'to' from pv2) = 'below_level');
create temp table pv3 as select public.preview_character_class_change(:'c1', tl_test.k(:'c1'), null, 'engine-test-fixture-v2') as p;
select tl_test.rec('F63 the version change preview shows lost features, the incompatible subclass and review items',
  exists (select 1 from pv3, jsonb_array_elements(pv3.p -> 'features_deactivated') f where f ->> 'name' = 'Test Fighting Style')
  and (select p -> 'subclass' ->> 'to' from pv3) = 'incompatible'
  and (select jsonb_array_length(p -> 'review_items') > 0 from pv3)
  and (select class_version_id from public.character_classes where id = tl_test.k(:'c1')) = 'engine-test-fixture');
select public.set_character_class(:'c1', 'engine-test-fixture-v2', 5, 'engine-test-path-fixture', null, tl_test.k(:'c1'));
select tl_test.rec('F63b after the version change old selections are kept for review and inactive; nothing was deleted',
  tl_test.warn(:'c1', 'subclass_incompatible') and tl_test.warn(:'c1', 'review_items')
  and (select count(*) from public.character_feature_choices where character_class_id = tl_test.k(:'c1')) >= 6
  and (tl_test.d(:'c1') -> 'critical_range' ->> 'value')::int = 20);
select public.set_character_class(:'c1', 'engine-test-fixture', 5, 'engine-test-path-fixture', null, tl_test.k(:'c1'));
select tl_test.rec('F63c changing back restores the preserved selections', not tl_test.warn(:'c1', 'review_items')
  and (tl_test.d(:'c1') -> 'critical_range' ->> 'value')::int = 19);

-- ---- export / import ------------------------------------------------------------------------------------------------------------
create temp table ex as select public.export_character_class_features(:'c1') as j;
select tl_test.rec('F56 the export contains stable catalog references and the character state only',
  exists (select 1 from ex, jsonb_array_elements(ex.j -> 'choices') c where c ->> 'unlock' = 'et-u1-fighting-style' and c ->> 'choice' = 'et-style'
          and c -> 'values' = '["dueling"]'::jsonb)
  and exists (select 1 from ex, jsonb_array_elements(ex.j -> 'optionalFeatures') o where o ->> 'unlock' = 'et-u3-swift-reflexes')
  and exists (select 1 from ex, jsonb_array_elements(ex.j -> 'resources') r where r ->> 'resource' = 'et-surge-uses')
  and not (select j ? 'features' from ex));
select public.expend_character_resource(:'c1', tl_test.rkey(:'c1', 'et-focus-points'), 2);
create temp table ex2 as select public.export_character_class_features(:'c1') as j;
select public.set_character_class(:'c6', 'engine-test-fixture', 5, 'engine-test-path-fixture');
create temp table im as select public.import_character_class_features(:'c6', (select j from ex2) || jsonb_build_object(
  'classRows', jsonb_build_object(tl_test.k(:'c1')::text, tl_test.k(:'c6')::text))) as r;
select tl_test.rec('F57 import restores choices, optional features and resource state',
  (select (r -> 'applied' ->> 'choices')::int >= 8 and (r -> 'applied' ->> 'optional_features')::int = 2 from im)
  and tl_test.ch(:'c6', 'et-u1-fighting-style:et-style') -> 'values' = '["dueling"]'::jsonb
  and tl_test.ustatus(:'c6', 'et-u3-keen-senses') = 'replaced'
  and (tl_test.res(:'c6', 'et-focus-points') ->> 'remaining')::int = 3);
create temp table im2 as select public.import_character_class_features(:'c6', jsonb_build_object(
  'classRows', jsonb_build_object('old', tl_test.k(:'c6')::text),
  'resources', jsonb_build_array(jsonb_build_object('classKey', 'old', 'resource', 'et-surge-uses', 'expended', 99)),
  'choices', jsonb_build_array(jsonb_build_object('classKey', 'old', 'unlock', 'no-such-unlock', 'choice', 'et-style', 'values', '["archery"]'::jsonb)))) as r;
select tl_test.rec('F58 an invalid imported resource state is clamped with a warning; unknown entries are reported, not stored',
  (tl_test.res(:'c6', 'et-surge-uses') ->> 'expended')::int = 1
  and exists (select 1 from im2, jsonb_array_elements(im2.r -> 'warnings') w where w ->> 'code' = 'resource_clamped')
  and (select jsonb_array_length(r -> 'unresolved') = 1 from im2));

-- ---- security ---------------------------------------------------------------------------------------------------------------------
select tl_test.rec('F51 the owner edits choices (done above) and reads the state', (tl_test.f(:'c1') ->> 'character_id') = :'c1');
select tl_test.as_user(:'dm');
select tl_test.rec('F52 the campaign DM reads the resolved features and may change a choice (character access policy)',
  (tl_test.f(:'c1') ->> 'character_id') = :'c1'
  and tl_test.raises(format('select tl_test.choose(%L, ''et-u2-discipline'', ''et-techniques'', array[''feint'', ''parry''])', :'c1')) is null);
select tl_test.as_user(:'bob');
select tl_test.rec('F53 an outsider cannot read private feature state (resolved, raw choices, resources)',
  tl_test.raises(format('select public.get_character_class_features(%L)', :'c1')) like '%not found%'
  and (select count(*) from public.character_feature_choices where character_id = :'c1') = 0
  and tl_test.raises(format('select public.get_character_resources(%L)', :'c1')) like '%not found%');
select tl_test.rec('F54 an outsider cannot spend, set or choose',
  tl_test.raises(format('select public.expend_character_resource(%L, %L)', :'c1', 'f:' || (select id from public.character_classes limit 0) || 'x')) is not null
  and tl_test.raises(format('select public.set_character_resource_state(%L, ''f:00000000-0000-0000-0000-000000000000:et-surge-uses'', 0, ''x'')', :'c1')) like '%not found%'
  and tl_test.raises(format('select public.set_character_feature_choice(%L, gen_random_uuid(), ''et-u1-fighting-style'', ''et-style'', array[''archery''])', :'c1')) like '%not found%');
select tl_test.as_user(:'alice');
select tl_test.rec('F55 the official catalog and character state are not writable directly',
  tl_test.raises($$insert into public.class_feature_versions (id, feature_id, name, summary, source_label, automation)
                   values ('x', 'et-strike', 'X', 'X', 'X', 'automated')$$) like '%permission denied%'
  and tl_test.raises($$update public.class_feature_resources set max_formula = '{"fixed": 9}'$$) like '%permission denied%'
  and tl_test.raises(format('insert into public.character_feature_choices (character_id, character_class_id, unlock_id, choice_id) values (%L, %L, ''et-u1-strike'', ''et-style'')',
                            :'c1', tl_test.k(:'c1'))) like '%permission denied%'
  and tl_test.raises(format('update public.character_resources set expended = 0 where character_id = %L', :'c1')) like '%permission denied%');
select tl_test.rec('F55b class resource rows cannot be changed or deleted through the old manual-resource RPCs',
  tl_test.raises(format('select public.change_character_resource(%L, 1)', (select id from public.character_resources where character_id = :'c1' and feature_resource_id = 'et-surge-uses'))) like '%class feature%'
  and tl_test.raises(format('select public.delete_character_resource(%L)', (select id from public.character_resources where character_id = :'c1' and feature_resource_id = 'et-surge-uses'))) like '%class feature%');
select tl_test.rec('F21b a forged resource key for another character is refused',
  tl_test.raises(format('select public.expend_character_resource(%L, %L)', :'c1', 'f:' || tl_test.k(:'c6') || ':et-surge-uses')) like '%not granted%');

-- ---- integrity -----------------------------------------------------------------------------------------------------------------
select public.remove_character_class(tl_test.k(:'c6'), true);
select tl_test.rec('F59 no orphan feature rows: removing a class removes its choices, values, optional features and class resource state',
  not exists (select 1 from public.character_feature_choices where character_id = :'c6')
  and not exists (select 1 from public.character_optional_features where character_id = :'c6')
  and not exists (select 1 from public.character_resources where character_id = :'c6' and feature_resource_id is not null)
  and not exists (select 1 from public.character_feature_choice_values v where not exists (select 1 from public.character_feature_choices c where c.id = v.character_choice_id)));
select tl_test.as_root();
select tl_test.rec('F61 the test fixture is marked as test content and kept apart from the official catalog',
  (select bool_and(content_scope = 'test') from public.class_features where class_id = 'engine-test')
  and (select bool_and(v.source_status = 'test_fixture') from public.class_feature_versions v join public.class_features f on f.id = v.feature_id where f.class_id = 'engine-test')
  and not exists (select 1 from public.class_feature_versions v join public.class_features f on f.id = v.feature_id
                  where f.class_id <> 'engine-test' and (f.content_scope = 'test' or v.source_status = 'test_fixture'))
  and (select content_scope from public.class_versions where id = 'engine-test-fixture') = 'test'
  and (select count(*) from public.class_versions where content_scope = 'official') = 13);
select tl_test.rec('F64 catalog guards: an automated resource needs a formula; unknown effect conditions are refused',
  tl_test.raises($$insert into public.class_feature_resources (id, feature_version_id, name, recharge) values ('bad', 'et-surge', 'Bad', 'long_rest')$$) like '%cannot be automated%'
  and tl_test.raises($$insert into public.class_feature_effects (feature_version_id, seq, effect_type, value, conditions) values ('et-surge', 9, 'ac_bonus', 1, '{"raining": true}')$$) like '%Unknown effect condition%'
  and tl_test.raises($$insert into public.class_feature_resources (id, feature_version_id, name, recharge, max_formula) values ('bad2', 'et-surge', 'Bad', 'long_rest', '{"eval": "1+1"}')$$) like '%needs fixed, table or terms%');

-- ---- report ---------------------------------------------------------------------------------------------------------------------------
\o
select case when ok then 'PASSED' else 'FAILED' end || '  ' || name || case when ok then '' else '   <-- ' || coalesce(detail, '') end
from tl_test.results order by n;
select format('%s passed, %s failed', count(*) filter (where ok), count(*) filter (where not ok)) from tl_test.results;
select 1 / (count(*) filter (where not ok) = 0)::int as all_checks_passed from tl_test.results;
rollback;
