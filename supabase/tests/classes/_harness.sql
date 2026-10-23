-- =============================================================================
-- Shared harness of the per-class SQL tests (supabase/tests/classes/<class>_tests.sql). The runners send
--   _harness.sql + <class>_tests.sql + _report.sql
-- as ONE psql session: one transaction, rolled back at the end; PASSED / FAILED per check; any FAILED check ends with an
-- error. Needs all seeds (classes.sql, class_features.sql ...). Synthetic users only (never real accounts).
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

-- class row of a class on a character
create function tl_test.k(p_char uuid, p_class text) returns uuid language sql as $$
  select id from public.character_classes where character_id = p_char and class_id = p_class $$;
-- add or change a class (version of the class that is current), keeping the subclass unless given
create function tl_test.setc(p_char uuid, p_version text, p_level int, p_subclass text default null) returns jsonb language sql as $$
  select public.set_character_class(p_char, p_version, p_level,
           coalesce(p_subclass, (select cc.subclass_version_id from public.character_classes cc
                                 join public.class_versions v on v.id = p_version
                                 where cc.character_id = p_char and cc.class_id = v.class_id)),
           null, (select cc.id from public.character_classes cc join public.class_versions v on v.id = p_version
                  where cc.character_id = p_char and cc.class_id = v.class_id)) $$;
create function tl_test.f(p_char uuid) returns jsonb language sql as $$ select public.get_character_class_features(p_char) $$;
create function tl_test.ust(p_char uuid, p_unlock text) returns text language sql as $$
  select status from public._character_feature_unlocks(p_char) where unlock_id = p_unlock $$;
create function tl_test.active(p_char uuid, p_unlock text) returns boolean language sql as $$
  select coalesce((select active from public._character_feature_unlocks(p_char) where unlock_id = p_unlock), false) $$;
create function tl_test.ch(p_char uuid, p_class text, p_key text) returns jsonb language sql as $$
  select c from jsonb_array_elements(public.get_character_class_features(p_char) -> 'classes') k, jsonb_array_elements(k -> 'choices') c
  where k ->> 'class_id' = p_class and c ->> 'key' = p_key $$;
create function tl_test.choose(p_char uuid, p_class text, p_unlock text, p_choice text, p_values text[], p_manual text default null)
  returns jsonb language sql as $$
  select public.set_character_feature_choice(p_char, tl_test.k(p_char, p_class), p_unlock, p_choice, p_values, p_manual) $$;
create function tl_test.res(p_char uuid, p_resource text) returns jsonb language sql as $$
  select r from jsonb_array_elements(public.get_character_resources(p_char) -> 'resources') r where r ->> 'resource_id' = p_resource $$;
create function tl_test.rkey(p_char uuid, p_class text, p_resource text) returns text language sql as $$
  select 'f:' || tl_test.k(p_char, p_class) || ':' || p_resource $$;
create function tl_test.d(p_char uuid) returns jsonb language sql as $$ select public.get_character_derived_stats(p_char) $$;
create function tl_test.warn(p_char uuid, p_code text) returns boolean language sql as $$
  select exists (select 1 from jsonb_array_elements(public.get_character_class_features(p_char) -> 'warnings') w where w ->> 'code' = p_code) $$;
create function tl_test.incomplete(p_char uuid) returns int language sql as $$
  select jsonb_array_length(public.get_character_class_features(p_char) -> 'incomplete_choices') $$;
create function tl_test.spell(p_char uuid, p_version text) returns jsonb language sql as $$
  select s from jsonb_array_elements(public.get_character_spellbook(p_char) -> 'spells') s where s ->> 'id' = p_version $$;
create function tl_test.inv(p_char uuid) returns uuid language sql as $$
  select id from public.inventories where character_id = p_char limit 1 $$;
create function tl_test.give(p_char uuid, p_item text, p_slot text default null, p_qty int default 1) returns uuid language plpgsql as $$
declare i uuid;
begin
  i := public.add_inventory_item(tl_test.inv(p_char), p_item, p_qty);
  if p_slot is not null then perform public.equip_item(i, p_slot, true); end if;
  return i;
end $$;
-- the class layer of the derived stats: effects of active features with their activation
create function tl_test.eff(p_char uuid, p_unlock text) returns jsonb language sql as $$
  select coalesce(jsonb_agg(to_jsonb(e) order by e.seq, e.pick), '[]') from public._character_class_effects(p_char) e where e.unlock_id = p_unlock $$;
-- catalog: every class level 1-20 has an unlock, a subclass unlock (any subclass of the class) or a scaling threshold
create function tl_test.levels_represented(p_version text) returns int language sql as $$
  select count(distinct l) from (
    select u.level as l from public.class_feature_unlocks u where u.class_version_id = p_version
    union select u.level from public.class_feature_unlocks u join public.subclass_versions s on s.id = u.subclass_version_id
          join public.class_versions v on v.id = p_version where s.class_id = v.class_id
    union select (e ->> 0)::int from public.class_feature_unlocks u join public.class_feature_scaling sc on sc.feature_version_id = u.feature_version_id
          cross join jsonb_array_elements(sc.table_by_level) e where u.class_version_id = p_version
    union select lv.level from public.class_version_levels lv where lv.class_version_id = p_version
          and (lv.cantrips_known is not null or lv.max_spell_level is not null or lv.pact_slots is not null)) x
  where l between 1 and 20 $$;
grant all on all functions in schema tl_test to public;
grant all on tl_test.results to public;
grant all on sequence tl_test.results_n_seq to public;

-- ---- synthetic users ------------------------------------------------------------------------------------------------------------
\set alice a1111111-1111-1111-1111-111111111111
\set bob b2222222-2222-2222-2222-222222222222
\set dm d3333333-3333-3333-3333-333333333333
\set camp c1c00000-0000-0000-0000-000000000001
insert into auth.users (id, email) values (:'alice', 'alice@test'), (:'bob', 'bob@test'), (:'dm', 'dm@test');
insert into public.campaigns (id, name, created_by) values (:'camp', 'Class Test Campaign', :'dm');
insert into public.campaign_members (campaign_id, user_id, role) values (:'camp', :'alice', 'player'), (:'camp', :'dm', 'dm');
