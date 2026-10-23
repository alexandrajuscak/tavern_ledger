-- =============================================================================
-- Character lineage tests (migration 20261015001500). Same harness as derived_stats_tests.sql: one transaction, rolled
-- back at the end; PASSED / FAILED per check; any FAILED check ends with an error.
-- Needs the reference seed, item_effects.sql and lineages.sql. Synthetic fixtures only. The engine rules are tested
-- with a synthetic test lineage created inside the transaction ("zztest"), so they do not depend on catalog data;
-- the Halfling and Custom Lineage checks test the seeded vertical slice.
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
create function tl_test.d(p_char uuid) returns jsonb language sql as $$ select public.get_character_derived_stats(p_char) $$;
create function tl_test.lin(p_char uuid) returns jsonb language sql as $$ select public.get_character_lineage(p_char) $$;
create function tl_test.set(p_char uuid, p_v text, p_s text default null, p_c jsonb default '{}', p_incl boolean default false,
                            p_strict boolean default false) returns jsonb language sql as $$
  select public.set_character_lineage(p_char, p_v, p_s, p_c, p_incl, p_strict) $$;
create function tl_test.trait_names(p jsonb) returns text language sql as $$
  select string_agg(t ->> 'name', ',' order by t ->> 'origin', t ->> 'id') from jsonb_array_elements(p -> 'traits') t $$;
create function tl_test.choice_status(p jsonb, p_id text) returns text language sql as $$
  select c ->> 'status' from jsonb_array_elements(p -> 'choices') c where c ->> 'id' = p_id $$;
create function tl_test.has_warning(p_char uuid, p_code text) returns boolean language sql as $$
  select exists (select 1 from jsonb_array_elements(public.get_character_derived_stats(p_char) -> 'warnings') w where w ->> 'code' = p_code) $$;
create function tl_test.add(p_inv uuid, p_item text) returns uuid language sql as $$ select public.add_inventory_item(p_inv, p_item, 1) $$;
create function tl_test.prof(p_char uuid, p_item text) returns jsonb language sql as $$
  select public._proficiency_match(p_char, p_item, null,
    (select g.id from public.proficiency_groups g join public.items i on i.category_id = g.armor_category_id where i.id = p_item)) $$;
grant all on all functions in schema tl_test to public;
grant all on tl_test.results to public;
grant all on sequence tl_test.results_n_seq to public;

-- ---- synthetic test lineage (catalog rows are written by the seed only; postgres here stands in for the seed) -------
insert into public.lineages (id, category_id, name, source_url) values
  ('zztest', 'exotic', 'Zz Test Lineage', 'https://dnd5e.wikidot.com/lineage:zztest');
insert into public.lineage_versions (id, lineage_id, parent_version_id, kind, name, source_label, source_url, status, creature_type, sort_order) values
  ('zztest-base', 'zztest', null, 'base', 'Zz Base', 'Test Book', 'https://example.test/zz', 'current', 'humanoid', 0),
  ('zztest-other', 'zztest', null, 'base', 'Zz Other', 'Older Book', 'https://example.test/zz', 'legacy', 'humanoid', 1);
insert into public.lineage_versions (id, lineage_id, parent_version_id, kind, name, source_label, source_url, status, sort_order) values
  ('zztest-variant', 'zztest', 'zztest-base', 'variant', 'Zz Variant', 'Test Book', 'https://example.test/zz', 'current', 2);
insert into public.lineage_traits (id, version_id, name, summary, automation, sort_order) values
  ('zztest-base:asi', 'zztest-base', 'ASI', 'STR +2', 'automatic', 1),
  ('zztest-base:speed', 'zztest-base', 'Speed', 'walk 30', 'automatic', 2),
  ('zztest-base:flight', 'zztest-base', 'Flight', 'fly = walk, not in medium/heavy armor', 'automatic', 3),
  ('zztest-base:scales', 'zztest-base', 'Scales', '13 + DEX, best of', 'automatic', 4),
  ('zztest-base:claws', 'zztest-base', 'Claws', '1d6 slashing', 'automatic', 5),
  ('zztest-base:sturdy', 'zztest-base', 'Sturdy', 'heavy armor does not slow', 'automatic', 6),
  ('zztest-base:training', 'zztest-base', 'Training', 'light armor, longsword, thieves tools, perception', 'automatic', 7),
  ('zztest-base:quick', 'zztest-base', 'Quick', '+PB initiative', 'automatic', 8),
  ('zztest-base:tough', 'zztest-base', 'Tough', '+1 HP per level', 'partial', 9),
  ('zztest-base:magic', 'zztest-base', 'Magic', 'Shield at 3rd level', 'partial', 10),
  ('zztest-base:growth', 'zztest-base', 'Growth', 'small, medium at 5th', 'automatic', 11),
  ('zztest-base:legacy', 'zztest-base', 'Fire Legacy', 'fire resistance', 'automatic', 12),
  ('zztest-base:gift', 'zztest-base', 'Gift', 'keep or wings', 'automatic', 13),
  ('zztest-base:tongue', 'zztest-base', 'Tongue', 'Common', 'automatic', 14),
  ('zztest-variant:variant-asi', 'zztest-variant', 'Variant ASI', 'DEX +2 instead', 'automatic', 1),
  ('zztest-variant:shell', 'zztest-variant', 'Shell', '17, armor gives no benefit', 'automatic', 2),
  ('zztest-other:asi', 'zztest-other', 'ASI', 'CON +2', 'automatic', 1);
insert into public.lineage_trait_replacements values ('zztest-variant:variant-asi', 'zztest-base:asi');
insert into public.lineage_choices (id, version_id, trait_id, kind, label, pick_count, config) values
  ('zztest-base:spell-ability', 'zztest-base', 'zztest-base:magic', 'spellcasting_ability', 'Spellcasting ability', 1, '{}'),
  ('zztest-base:gift', 'zztest-base', 'zztest-base:gift', 'option', 'Gift', 1, '{}');
insert into public.lineage_choice_options (choice_id, option_id, label) values
  ('zztest-base:spell-ability', 'int', 'Intelligence'), ('zztest-base:spell-ability', 'wis', 'Wisdom'), ('zztest-base:spell-ability', 'cha', 'Charisma'),
  ('zztest-base:gift', 'keep', 'Keep the fire legacy'), ('zztest-base:gift', 'frost', 'Frost instead');
insert into public.lineage_option_replacements values ('zztest-base:gift', 'frost', 'zztest-base:legacy');
insert into public.lineage_trait_effects (trait_id, seq, effect_type, target, value, value_text, min_level, conditions, data) values
  ('zztest-base:asi', 1, 'ability_bonus', 'str', 2, null, 1, '{}', '{}'),
  ('zztest-base:speed', 1, 'speed', 'walk', 30, null, 1, '{}', '{}'),
  ('zztest-base:flight', 1, 'speed', 'fly', null, 'walk', 1, '{"not_armor": ["medium-armor", "heavy-armor"]}', '{}'),
  ('zztest-base:scales', 1, 'natural_armor', null, 13, null, 1, '{}', '{"dex": "full", "mode": "best_of"}'),
  ('zztest-base:claws', 1, 'natural_weapon', null, null, 'Claws', 1, '{}', '{"damage_dice": "1d6", "damage_type": "slashing"}'),
  ('zztest-base:sturdy', 1, 'ignore_heavy_armor_speed_penalty', null, null, null, 1, '{}', '{}'),
  ('zztest-base:training', 1, 'proficiency', 'group', null, 'light-armor', 1, '{}', '{}'),
  ('zztest-base:training', 2, 'proficiency', 'weapon', null, 'longsword', 1, '{}', '{}'),
  ('zztest-base:training', 3, 'proficiency', 'tool', null, 'thieves-tools', 1, '{}', '{}'),
  ('zztest-base:training', 4, 'proficiency', 'skill', null, 'perception', 1, '{}', '{}'),
  ('zztest-base:quick', 1, 'initiative_bonus', null, null, 'pb', 1, '{}', '{}'),
  ('zztest-base:tough', 1, 'hp_per_level', null, 1, null, 1, '{}', '{}'),
  ('zztest-base:magic', 1, 'spell', null, null, 'Shield', 3, '{}', '{"slug": "shield", "uses": "1", "recharge": "long_rest", "ability_choice": "zztest-base:spell-ability"}'),
  ('zztest-base:growth', 1, 'size', null, null, 'small', 1, '{}', '{}'),
  ('zztest-base:growth', 2, 'size', null, null, 'medium', 5, '{}', '{}'),
  ('zztest-base:legacy', 1, 'resistance', null, null, 'fire', 1, '{}', '{}'),
  ('zztest-base:tongue', 1, 'language', null, null, 'common', 1, '{}', '{}'),
  ('zztest-variant:variant-asi', 1, 'ability_bonus', 'dex', 2, null, 1, '{}', '{}'),
  ('zztest-variant:shell', 1, 'natural_armor', null, 17, null, 1, '{}', '{"dex": "none", "mode": "replaces_armor"}'),
  ('zztest-other:asi', 1, 'ability_bonus', 'con', 2, null, 1, '{}', '{}');
insert into public.lineage_trait_effects (trait_id, seq, effect_type, value_text, option_choice_id, option_id) values
  ('zztest-base:gift', 1, 'resistance', 'cold', 'zztest-base:gift', 'frost');

-- ---- characters ---------------------------------------------------------------------------------------------------
insert into auth.users (id, email) values
  ('a1111111-1111-1111-1111-111111111111', 'alice@test'), ('b2222222-2222-2222-2222-222222222222', 'bob@test'),
  ('d3333333-3333-3333-3333-333333333333', 'dm@test');
insert into public.campaigns (id, name, created_by) values ('cccccccc-0000-0000-0000-000000000001', 'Lineage Test Campaign', 'd3333333-3333-3333-3333-333333333333');
insert into public.campaign_members (campaign_id, user_id, role) values
  ('cccccccc-0000-0000-0000-000000000001', 'a1111111-1111-1111-1111-111111111111', 'player'),
  ('cccccccc-0000-0000-0000-000000000001', 'b2222222-2222-2222-2222-222222222222', 'player'),
  ('cccccccc-0000-0000-0000-000000000001', 'd3333333-3333-3333-3333-333333333333', 'dm');
-- H: halfling / custom; Z: synthetic lineage (level 1, STR 10 -> chain mail needs 13, DEX 14); N: never gets a lineage
insert into public.characters (id, owner_id, name, campaign_id, level, strength, dexterity, constitution, speed,
                               skill_proficiencies, proficiencies) values
  ('aaaaaaaa-0000-0000-0000-00000000000a', 'a1111111-1111-1111-1111-111111111111', 'Halfling Hero', 'cccccccc-0000-0000-0000-000000000001', 5, 10, 14, 12, 30,
   '{"athletics": {"proficient": true, "expertise": false}}', 'Languages: Common'),
  ('bbbbbbbb-0000-0000-0000-00000000000b', 'a1111111-1111-1111-1111-111111111111', 'Zz Hero', 'cccccccc-0000-0000-0000-000000000001', 1, 10, 14, 12, 30, '{}', ''),
  ('eeeeeeee-0000-0000-0000-00000000000e', 'a1111111-1111-1111-1111-111111111111', 'No Lineage', 'cccccccc-0000-0000-0000-000000000001', 3, 12, 16, 10, 35, '{}', '');
select 'aaaaaaaa-0000-0000-0000-00000000000a'::uuid as ch, 'bbbbbbbb-0000-0000-0000-00000000000b'::uuid as cz,
       'eeeeeeee-0000-0000-0000-00000000000e'::uuid as cn,
       'a1111111-1111-1111-1111-111111111111'::uuid as alice, 'b2222222-2222-2222-2222-222222222222'::uuid as bob,
       'd3333333-3333-3333-3333-333333333333'::uuid as dm \gset
select id as inv_h from public.inventories where character_id = :'ch' \gset
select id as inv_z from public.inventories where character_id = :'cz' \gset
select tl_test.as_user(:'alice');
select tl_test.add(:'inv_h', 'dagger') as h_dagger \gset
select tl_test.add(:'inv_z', 'leather') as z_leather, tl_test.add(:'inv_z', 'chain-mail') as z_chain, tl_test.add(:'inv_z', 'half-plate') as z_half,
       tl_test.add(:'inv_z', 'longsword') as z_sword, tl_test.add(:'inv_z', 'thieves-tools') as z_tools,
       tl_test.add(:'inv_z', 'gauntlets-of-ogre-power') as z_gauntlets \gset
select public.set_character_proficiency(:'ch', 'simple-weapons');
select tl_test.as_root();
create temp table baseline_n as select tl_test.d(:'cn') as d;

-- =============================================================================
-- Catalog integrity (seeded data and triggers)
-- =============================================================================
select tl_test.rec('L1 the four lineage categories exist',
  (select string_agg(id, ',' order by sort_order) from public.lineage_categories) = 'standard,custom,exotic,monstrous');
select tl_test.rec('L2 stable slugs of the vertical slice exist',
  (select count(*) from public.lineage_versions where id in ('halfling-phb', 'halfling-lightfoot', 'halfling-stout', 'halfling-ghostwise',
     'halfling-lotusden', 'halfling-mark-of-hospitality', 'halfling-mark-of-healing', 'custom-tce')) = 8);
select tl_test.rec('L3 every sub-lineage has a base parent in the same lineage',
  not exists (select 1 from public.lineage_versions c left join public.lineage_versions p on p.id = c.parent_version_id
              where c.kind <> 'base' and (p.id is null or p.kind <> 'base' or p.lineage_id <> c.lineage_id)));
select tl_test.rec('L4 every lineage has a category and at least one base version',
  not exists (select 1 from public.lineages l where not exists (select 1 from public.lineage_versions v where v.lineage_id = l.id and v.kind = 'base')));
select tl_test.rec('L5 a sub-lineage of a sub-lineage is rejected',
  tl_test.raises($q$insert into public.lineage_versions (id, lineage_id, parent_version_id, kind, name, source_label, source_url, status)
                   values ('zztest-deep', 'zztest', 'zztest-variant', 'subrace', 'Deep', 'x', 'https://x.test', 'current')$q$) like '%base version%');
select tl_test.rec('L6 a child can only replace a trait of its own parent',
  tl_test.raises($q$insert into public.lineage_trait_replacements values ('zztest-variant:shell', 'halfling-phb:lucky')$q$) like '%parent version%');
select tl_test.rec('L7 effect targets are validated (skill, language, damage type, natural armor)',
  tl_test.raises($q$insert into public.lineage_trait_effects (trait_id, seq, effect_type, target, value_text) values ('zztest-base:tongue', 9, 'proficiency', 'skill', 'flying')$q$) like '%Unknown skill%'
  and tl_test.raises($q$insert into public.lineage_trait_effects (trait_id, seq, effect_type, value_text) values ('zztest-base:tongue', 9, 'language', 'klingon')$q$) like '%Unknown language%'
  and tl_test.raises($q$insert into public.lineage_trait_effects (trait_id, seq, effect_type, value_text) values ('zztest-base:tongue', 9, 'resistance', 'sonic')$q$) like '%Unknown damage type%'
  and tl_test.raises($q$insert into public.lineage_trait_effects (trait_id, seq, effect_type, value, data) values ('zztest-base:tongue', 9, 'natural_armor', 13, '{"dex": "half"}')$q$) like '%natural_armor%');
select tl_test.rec('L8 an ability score choice needs patterns',
  tl_test.raises($q$insert into public.lineage_choices (id, version_id, kind, label) values ('zztest-base:x', 'zztest-base', 'ability_scores', 'x')$q$) like '%patterns%');
select tl_test.rec('L9 Halfling (PHB) requires one of its 6 sub-lineages',
  (select requires_child from public.lineage_versions where id = 'halfling-phb')
  and (select count(*) from public.lineage_versions where parent_version_id = 'halfling-phb') = 6);
select tl_test.rec('L10 every seeded trait has an automation label and a summary; every version a source',
  not exists (select 1 from public.lineage_traits where automation is null or summary = '')
  and not exists (select 1 from public.lineage_versions where source_label = '' or source_url !~ '^https://'));
select tl_test.rec('L11 Wildemount and Eberron sub-lineages are marked setting-specific',
  (select string_agg(id || '=' || setting, ',' order by id) from public.lineage_versions where lineage_id = 'halfling' and setting is not null)
  = 'halfling-lotusden=Wildemount,halfling-mark-of-healing=Eberron,halfling-mark-of-hospitality=Eberron');

-- =============================================================================
-- No lineage
-- =============================================================================
select tl_test.as_user(:'alice');
select tl_test.rec('L12 a character without a lineage resolves to "not selected"',
  tl_test.lin(:'cn') ->> 'selected' = 'false' and tl_test.d(:'cn') -> 'lineage' = 'null'::jsonb);
select tl_test.rec('L13 without a lineage the derived stats keep the stored speed, no size, no lineage bonuses',
  (tl_test.d(:'cn') -> 'speed' ->> 'value')::int = 35 and tl_test.d(:'cn') -> 'speed' ->> 'base_source' = 'character'
  and tl_test.d(:'cn') -> 'size' = 'null'::jsonb and (tl_test.d(:'cn') -> 'abilities' -> 'dex' ->> 'score')::int = 16
  and (tl_test.d(:'cn') -> 'abilities' -> 'dex' ->> 'lineage_applied')::int = 0);

-- =============================================================================
-- Halfling: base + sub-lineage inheritance
-- =============================================================================
select tl_test.rec('L14 Halfling without a sub-lineage is rejected',
  tl_test.raises(format('select tl_test.set(%L, ''halfling-phb'')', :'ch')) like '%needs a sub-lineage%');
select tl_test.rec('L15 a sub-lineage of another lineage is rejected',
  tl_test.raises(format('select tl_test.set(%L, ''custom-tce'', ''halfling-stout'')', :'ch')) like '%not a sub-lineage%');
select tl_test.rec('L16 a sub-lineage cannot be chosen as the version',
  tl_test.raises(format('select tl_test.set(%L, ''halfling-stout'')', :'ch')) like '%sub-lineage%');
select tl_test.rec('L17 an unknown version is rejected',
  tl_test.raises(format('select tl_test.set(%L, ''halfling-2099'')', :'ch')) like '%Unknown lineage version%');
select tl_test.set(:'ch', 'halfling-phb', 'halfling-stout');
select tl_test.rec('L18 Stout halfling = 7 base traits + 2 sub-lineage traits, all resolved',
  jsonb_array_length(tl_test.lin(:'ch') -> 'traits') = 9 and (tl_test.lin(:'ch') ->> 'unresolved')::int = 0
  and (select count(*) from jsonb_array_elements(tl_test.lin(:'ch') -> 'traits') t where t ->> 'origin' = 'child') = 2,
  tl_test.trait_names(tl_test.lin(:'ch')));
select tl_test.rec('L19 inherited and own ability increases add up without touching the stored scores (DEX 14+2, CON 12+1)',
  (tl_test.d(:'ch') -> 'abilities' -> 'dex' ->> 'score')::int = 16 and (tl_test.d(:'ch') -> 'abilities' -> 'con' ->> 'score')::int = 13
  and (select dexterity from public.characters where id = :'ch') = 14 and (select constitution from public.characters where id = :'ch') = 12);
select tl_test.rec('L20 lineage walking speed (25) replaces the stored base speed (30); size Small',
  (tl_test.d(:'ch') -> 'speed' ->> 'value')::int = 25 and tl_test.d(:'ch') -> 'speed' ->> 'base_source' = 'lineage'
  and tl_test.d(:'ch') -> 'size' ->> 'value' = 'small');
select tl_test.rec('L21 Stout Resilience: poison resistance (automatic) and poison save advantage (listed)',
  tl_test.d(:'ch') -> 'resistances' @> '[{"damage_type": "poison"}]'
  and tl_test.d(:'ch') -> 'advantages' @> '[{"scope": "poison"}, {"scope": "frightened"}]');
select tl_test.rec('L22 languages Common and Halfling come from the lineage',
  (select string_agg(l ->> 'id', ',' order by l ->> 'id') from jsonb_array_elements(tl_test.d(:'ch') -> 'languages') l) = 'common,halfling');
select tl_test.rec('L23 informational traits are shown with their label (Lucky, Nimble)',
  (select count(*) from jsonb_array_elements(tl_test.lin(:'ch') -> 'traits') t
   where t ->> 'name' in ('Lucky', 'Nimble') and t ->> 'automation' = 'informational') = 2);
select tl_test.set(:'ch', 'halfling-phb', 'halfling-lotusden');
select tl_test.rec('L24 level-gated spells: at level 5 Druidcraft, Entangle (3) and Spike Growth (5) are unlocked',
  (select string_agg((s ->> 'name') || '=' || (s ->> 'unlocked'), ',' order by (s ->> 'min_level')::int)
   from jsonb_array_elements(tl_test.d(:'ch') -> 'lineage_spells') s) = 'Druidcraft=true,Entangle=true,Spike Growth=true');
select tl_test.as_root(); update public.characters set level = 3 where id = :'ch'; select tl_test.as_user(:'alice');
select tl_test.rec('L25 at level 3 Spike Growth (5th level) is listed but locked',
  (select s ->> 'unlocked' from jsonb_array_elements(tl_test.d(:'ch') -> 'lineage_spells') s where s ->> 'name' = 'Spike Growth') = 'false'
  and (select (s ->> 'save_dc')::int from jsonb_array_elements(tl_test.d(:'ch') -> 'lineage_spells') s where s ->> 'name' = 'Entangle') = 8 + 2 + 0);

-- =============================================================================
-- Custom Lineage: choices
-- =============================================================================
select tl_test.rec('L26 invalid choices are rejected with a clear message',
  tl_test.raises(format('select tl_test.set(%L, ''custom-tce'', null, ''{"custom-tce:asi": ["str:1"]}'')', :'ch')) like '%allowed pattern%'
  and tl_test.raises(format('select tl_test.set(%L, ''custom-tce'', null, ''{"custom-tce:asi": ["str:2", "dex:2"]}'')', :'ch')) like '%at most 1%'
  and tl_test.raises(format('select tl_test.set(%L, ''custom-tce'', null, ''{"custom-tce:size": ["large"]}'')', :'ch')) like '%not one of the options%'
  and tl_test.raises(format('select tl_test.set(%L, ''custom-tce'', null, ''{"custom-tce:language": ["common"]}'')', :'ch')) like '%not an allowed language%'
  and tl_test.raises(format('select tl_test.set(%L, ''custom-tce'', null, ''{"custom-tce:language": ["klingon"]}'')', :'ch')) like '%not an allowed language%'
  and tl_test.raises(format('select tl_test.set(%L, ''custom-tce'', null, ''{"custom-tce:variable-skill": ["flying"]}'')', :'ch')) like '%not an allowed skill%'
  and tl_test.raises(format('select tl_test.set(%L, ''custom-tce'', null, ''{"custom-tce:feat": ["  "]}'')', :'ch')) like '%enter a name%'
  and tl_test.raises(format('select tl_test.set(%L, ''custom-tce'', null, ''{"halfling-phb:x": ["a"]}'')', :'ch')) like '%does not belong%'
  and tl_test.raises(format('select tl_test.set(%L, ''custom-tce'', null, ''{"custom-tce:size": "small"}'')', :'ch')) like '%must be a list%');
select tl_test.rec('L27 a rejected change leaves the previous lineage untouched',
  (select version_id || '/' || subversion_id from public.character_lineages where character_id = :'ch') = 'halfling-phb/halfling-lotusden');
select tl_test.set(:'ch', 'custom-tce', null, '{"custom-tce:size": ["medium"], "custom-tce:asi": ["con:2"]}');
select tl_test.rec('L28 an incomplete Custom Lineage is saved and lists what is missing (feat, variable trait, language)',
  (tl_test.lin(:'ch') ->> 'unresolved')::int = 3 and tl_test.choice_status(tl_test.lin(:'ch'), 'custom-tce:feat') = 'missing'
  and tl_test.choice_status(tl_test.lin(:'ch'), 'custom-tce:variable-skill') = 'disabled'
  and (select t ->> 'status' from jsonb_array_elements(tl_test.lin(:'ch') -> 'traits') t where t ->> 'name' = 'Feat') = 'unresolved');
select tl_test.rec('L29 strict mode rejects an incomplete selection',
  tl_test.raises(format('select tl_test.set(%L, ''custom-tce'', null, ''{"custom-tce:size": ["small"]}'', false, true)', :'ch')) like '%Incomplete lineage choices%');
select tl_test.set(:'ch', 'custom-tce', null, '{"custom-tce:size": ["small"], "custom-tce:asi": ["con:2"], "custom-tce:feat": ["Alert"],
  "custom-tce:variable-trait": ["skill"], "custom-tce:variable-skill": ["stealth"], "custom-tce:language": ["elvish"]}', false, true);
select tl_test.rec('L30 a complete Custom Lineage: chosen size, +2, skill via the sub-choice, extra language; nothing unresolved',
  (tl_test.lin(:'ch') ->> 'unresolved')::int = 0 and tl_test.d(:'ch') -> 'size' ->> 'value' = 'small'
  and (tl_test.d(:'ch') -> 'abilities' -> 'con' ->> 'score')::int = 14
  and (tl_test.d(:'ch') -> 'skills' -> 'stealth' ->> 'lineage_proficient')::boolean
  and tl_test.d(:'ch') -> 'languages' @> '[{"id": "elvish"}, {"id": "common"}]' and (tl_test.d(:'ch') -> 'speed' ->> 'value')::int = 30);
select tl_test.set(:'ch', 'custom-tce', null, '{"custom-tce:size": ["small"], "custom-tce:asi": ["con:2"], "custom-tce:feat": ["Alert"],
  "custom-tce:variable-trait": ["darkvision"], "custom-tce:variable-skill": ["stealth"], "custom-tce:language": ["elvish"]}');
select tl_test.rec('L31 switching the variable trait to darkvision drops the now-disabled skill choice',
  (tl_test.d(:'ch') -> 'senses' -> 'darkvision' ->> 'value')::int = 60 and not coalesce((tl_test.d(:'ch') -> 'skills' -> 'stealth' ->> 'lineage_proficient')::boolean, false)
  and not exists (select 1 from public.character_lineage_choices where character_id = :'ch' and choice_id = 'custom-tce:variable-skill'));

-- =============================================================================
-- Change and removal keep unrelated data
-- =============================================================================
select tl_test.set(:'ch', 'halfling-phb', 'halfling-lightfoot');
select tl_test.rec('L32 changing the lineage removes the old choices and keeps unrelated character data',
  not exists (select 1 from public.character_lineage_choices where character_id = :'ch')
  and (select skill_proficiencies ->> 'athletics' from public.characters where id = :'ch') is not null
  and (select proficiencies from public.characters where id = :'ch') = 'Languages: Common'
  and exists (select 1 from public.character_proficiencies where character_id = :'ch' and group_id = 'simple-weapons')
  and exists (select 1 from public.inventory_items where id = :'h_dagger'));
select public.clear_character_lineage(:'ch');
select tl_test.rec('L33 removing the lineage restores the stored values (speed 30, DEX 14, no size) and keeps everything else',
  tl_test.lin(:'ch') ->> 'selected' = 'false' and (tl_test.d(:'ch') -> 'speed' ->> 'value')::int = 30
  and (tl_test.d(:'ch') -> 'abilities' -> 'dex' ->> 'score')::int = 14 and tl_test.d(:'ch') -> 'size' = 'null'::jsonb
  and exists (select 1 from public.character_proficiencies where character_id = :'ch' and group_id = 'simple-weapons')
  and exists (select 1 from public.inventory_items where id = :'h_dagger'));
select tl_test.rec('L34 clearing again is harmless', (public.clear_character_lineage(:'ch') ->> 'cleared')::boolean = false);

-- =============================================================================
-- Engine rules (synthetic lineage)
-- =============================================================================
select tl_test.set(:'cz', 'zztest-base');
select tl_test.rec('L35 natural armor (13 + DEX) beats unarmored when no armor is worn',
  (tl_test.d(:'cz') -> 'armor_class' ->> 'value')::int = 15 and tl_test.d(:'cz') -> 'armor_class' ->> 'base_formula' = 'natural_armor');
select public.equip_item(:'z_leather', 'armor');
select tl_test.rec('L36 natural armor "best of": better than Leather (11 + 2), armor listed as an unused alternative',
  (tl_test.d(:'cz') -> 'armor_class' ->> 'value')::int = 15
  and tl_test.d(:'cz') -> 'armor_class' -> 'alternatives' @> '[{"formula": "armor", "value": 13, "used": false}]');
select tl_test.rec('L37 flight equal to walking speed works in light armor',
  (tl_test.d(:'cz') -> 'speed' -> 'movement' -> 'fly' ->> 'value')::int = 30
  and (tl_test.d(:'cz') -> 'speed' -> 'movement' -> 'fly' ->> 'active')::boolean);
select public.equip_item(:'z_chain', 'armor', true);
select tl_test.rec('L38 Chain Mail (16) beats natural armor (15)',
  (tl_test.d(:'cz') -> 'armor_class' ->> 'value')::int = 16 and tl_test.d(:'cz') -> 'armor_class' ->> 'base_formula' = 'heavy_armor');
select tl_test.rec('L39 flight is inactive in heavy armor (reason: armor)',
  not (tl_test.d(:'cz') -> 'speed' -> 'movement' -> 'fly' ->> 'active')::boolean
  and tl_test.d(:'cz') -> 'speed' -> 'movement' -> 'fly' ->> 'inactive_reason' = 'armor');
select tl_test.rec('L40 "not slowed by heavy armor": Strength 12 < 13 keeps speed 30, warning says no penalty',
  (tl_test.d(:'cz') -> 'speed' ->> 'value')::int = 30
  and (select (w ->> 'speed_penalty')::int = 0 and w ->> 'speed_penalty_ignored_by' = 'Sturdy'
       from jsonb_array_elements(tl_test.d(:'cz') -> 'warnings') w where w ->> 'code' = 'strength_requirement_unmet'),
  tl_test.d(:'cz') ->> 'warnings');
select tl_test.as_root(); delete from public.lineage_trait_effects where trait_id = 'zztest-base:sturdy'; select tl_test.as_user(:'alice');
select tl_test.rec('L41 without that trait the same armor costs 10 ft (the armor rule is unchanged)',
  (tl_test.d(:'cz') -> 'speed' ->> 'value')::int = 20);
select tl_test.as_root();
insert into public.lineage_trait_effects (trait_id, seq, effect_type) values ('zztest-base:sturdy', 1, 'ignore_heavy_armor_speed_penalty');
select tl_test.as_user(:'alice');
select tl_test.rec('L42 lineage proficiency: light armor group, a weapon and a tool, each matched "by lineage"',
  tl_test.prof(:'cz', 'leather') ->> 'matched_by' = 'lineage'
  and public._proficiency_match(:'cz', 'longsword', null, 'martial-weapons') ->> 'matched_by' = 'lineage'
  and public._proficiency_match(:'cz', 'thieves-tools', null, null) ->> 'matched_by' = 'lineage'
  and (tl_test.d(:'cz') -> 'skills' -> 'perception' ->> 'lineage_proficient')::boolean);
select tl_test.rec('L43 lineage grants are listed with source "lineage" and are not stored as character proficiency rows',
  (select count(*) from jsonb_array_elements(tl_test.d(:'cz') -> 'proficiencies') p where p ->> 'source_type' = 'lineage') = 3
  and not exists (select 1 from public.character_proficiencies where character_id = :'cz'));
select public.set_character_proficiency(:'cz', 'light-armor');
select tl_test.rec('L44 with a manual and a lineage origin the manual row wins the match',
  tl_test.prof(:'cz', 'leather') ->> 'matched_by' = 'group');
select tl_test.set(:'cz', 'zztest-other');
select tl_test.rec('L45 changing the lineage removes only its grants: manual light armor stays, the longsword does not',
  (tl_test.prof(:'cz', 'leather') ->> 'proficient')::boolean
  and not (public._proficiency_match(:'cz', 'longsword', null, 'martial-weapons') ->> 'proficient')::boolean
  and (select (equipment_proficiencies ->> 'light')::boolean from public.characters where id = :'cz'));
select public.set_character_proficiency(:'cz', 'light-armor', null, false);
select tl_test.rec('L46 with no origin left the proficiency is gone',
  not (tl_test.prof(:'cz', 'leather') ->> 'proficient')::boolean);
select tl_test.set(:'cz', 'zztest-base', 'zztest-variant');
select tl_test.rec('L47 a variant trait replaces the parent trait (STR +2 replaced by DEX +2)',
  (tl_test.d(:'cz') -> 'abilities' -> 'str' ->> 'lineage_applied')::int = 0 and (tl_test.d(:'cz') -> 'abilities' -> 'dex' ->> 'score')::int = 16
  and tl_test.lin(:'cz') -> 'replaced_traits' @> '[{"id": "zztest-base:asi"}]');
select tl_test.rec('L48 natural armor "replaces armor": AC 17 in Chain Mail, with a warning that the armor gives no benefit',
  (tl_test.d(:'cz') -> 'armor_class' ->> 'value')::int = 17 and tl_test.has_warning(:'cz', 'lineage_armor_no_benefit'));
select public.unequip_item(:'z_chain');
select tl_test.set(:'cz', 'zztest-base', null, '{"zztest-base:gift": ["frost"]}');
select tl_test.rec('L49 an option replaces a trait (fire resistance) and adds its own effect (cold)',
  (select string_agg(r ->> 'damage_type', ',' order by r ->> 'damage_type') from jsonb_array_elements(tl_test.d(:'cz') -> 'resistances') r) = 'cold'
  and tl_test.lin(:'cz') -> 'replaced_traits' @> '[{"id": "zztest-base:legacy"}]');
select tl_test.set(:'cz', 'zztest-base', null, '{"zztest-base:gift": ["keep"]}');
select tl_test.rec('L50 the other option keeps the original trait',
  (select string_agg(r ->> 'damage_type', ',') from jsonb_array_elements(tl_test.d(:'cz') -> 'resistances') r) = 'fire');
select tl_test.rec('L51 natural weapon: Claws to-hit = STR mod + PB, damage 1d6 + STR mod',
  tl_test.d(:'cz') -> 'natural_weapons' @> '[{"name": "Claws", "attack_bonus": 3, "damage": "1d6 + 1", "damage_type": "slashing"}]',
  tl_test.d(:'cz') ->> 'natural_weapons');
select tl_test.rec('L52 initiative bonus = proficiency bonus; +1 HP per level is reported',
  (tl_test.d(:'cz') -> 'initiative' ->> 'bonus')::int = 2 and (tl_test.d(:'cz') -> 'hit_points' ->> 'lineage_bonus')::int = 1);
select tl_test.rec('L53 a 3rd-level spell is locked at level 1 and needs a spellcasting ability; size is Small',
  (select (s ->> 'unlocked')::boolean = false and (s ->> 'ability_needed')::boolean
   from jsonb_array_elements(tl_test.d(:'cz') -> 'lineage_spells') s where s ->> 'name' = 'Shield')
  and tl_test.d(:'cz') -> 'size' ->> 'value' = 'small');
select tl_test.as_root(); update public.characters set level = 5, wisdom = 14 where id = :'cz'; select tl_test.as_user(:'alice');
select tl_test.set(:'cz', 'zztest-base', null, '{"zztest-base:gift": ["keep"], "zztest-base:spell-ability": ["wis"]}');
select tl_test.rec('L54 at level 5: the spell unlocks with DC 8 + PB 3 + WIS 2 = 13, and the size becomes Medium',
  (select (s ->> 'unlocked')::boolean and (s ->> 'save_dc')::int = 13 and s ->> 'ability' = 'wis'
   from jsonb_array_elements(tl_test.d(:'cz') -> 'lineage_spells') s where s ->> 'name' = 'Shield')
  and tl_test.d(:'cz') -> 'size' ->> 'value' = 'medium');

-- =============================================================================
-- Ability scores: never twice, never above 20, item overrides on top
-- =============================================================================
select tl_test.as_root(); update public.characters set strength = 19 where id = :'cz'; select tl_test.as_user(:'alice');
select tl_test.rec('L55 a lineage increase cannot raise a score above 20 (19 + 2 = 20)',
  (tl_test.d(:'cz') -> 'abilities' -> 'str' ->> 'score')::int = 20 and (tl_test.d(:'cz') -> 'abilities' -> 'str' ->> 'lineage_applied')::int = 1);
select tl_test.as_root(); update public.characters set strength = 22 where id = :'cz'; select tl_test.as_user(:'alice');
select tl_test.rec('L56 and never lowers a score that is already above 20 (22 stays 22)',
  (tl_test.d(:'cz') -> 'abilities' -> 'str' ->> 'score')::int = 22);
select tl_test.as_root(); update public.characters set strength = 15 where id = :'cz'; select tl_test.as_user(:'alice');
select tl_test.set(:'cz', 'zztest-base', null, '{"zztest-base:gift": ["keep"]}', true);
select tl_test.rec('L57 "scores already include lineage bonuses": the bonus is not applied a second time',
  (tl_test.d(:'cz') -> 'abilities' -> 'str' ->> 'score')::int = 15 and (tl_test.d(:'cz') -> 'abilities' -> 'str' ->> 'lineage_included')::boolean);
select tl_test.set(:'cz', 'zztest-base', null, '{"zztest-base:gift": ["keep"]}', false);
select public.equip_item(:'z_gauntlets', 'hands'); select public.attune_item(:'z_gauntlets');
select tl_test.rec('L58 an item override still applies on top (Gauntlets of Ogre Power 19 beats 15 + 2)',
  (tl_test.d(:'cz') -> 'abilities' -> 'str' ->> 'score')::int = 19);
select tl_test.rec('L59 the stored base scores were never changed by any lineage operation',
  (select strength || '/' || dexterity || '/' || constitution from public.characters where id = :'cz') = '15/14/12');

-- =============================================================================
-- Security
-- =============================================================================
select tl_test.as_user(:'bob');
select tl_test.rec('L60 another player cannot read or change the lineage of a character they cannot access',
  tl_test.raises(format('select tl_test.set(%L, ''custom-tce'')', :'cz')) like '%Character not found%'
  and tl_test.raises(format('select public.clear_character_lineage(%L)', :'cz')) like '%Character not found%'
  and not exists (select 1 from public.character_lineages where character_id = :'cz')
  and tl_test.raises(format('select public.get_character_lineage(%L)', :'cz')) like '%Character not found%');
select tl_test.as_user(:'dm');
select tl_test.rec('L61 the campaign DM can read and change it',
  tl_test.lin(:'cz') ->> 'selected' = 'true' and (tl_test.set(:'cz', 'zztest-base', null, '{"zztest-base:gift": ["keep"]}') ->> 'selected')::boolean);
select tl_test.as_user(:'alice');
select tl_test.rec('L62 selections can only be written through the RPCs',
  tl_test.raises(format('insert into public.character_lineages (character_id, lineage_id, version_id) values (%L, ''custom'', ''custom-tce'')', :'cn')) like '%permission denied%'
  and tl_test.raises(format('delete from public.character_lineage_choices where character_id = %L', :'cz')) like '%permission denied%'
  and tl_test.raises('update public.lineage_traits set summary = ''x''') like '%permission denied%');
select set_config('role', 'anon', true);
select tl_test.rec('L63 anonymous visitors can browse the catalog but not character lineages',
  (select count(*) from public.v_lineage_catalog) >= 2 and public.get_lineage_detail('halfling') ->> 'name' = 'Halfling'
  and tl_test.raises('select count(*) from public.character_lineages') like '%permission denied%');
select tl_test.as_root();
select tl_test.rec('L64 every lineage SECURITY DEFINER function pins its search_path',
  not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
              where n.nspname = 'public' and p.prosecdef and p.proname like '%lineage%'
                and not exists (select 1 from unnest(coalesce(p.proconfig, '{}')) c where c like 'search_path=%')));
delete from public.characters where id = :'cz';
select tl_test.rec('L65 deleting a character deletes its lineage selection and choices',
  not exists (select 1 from public.characters where id = :'cz')
  and not exists (select 1 from public.character_lineages where character_id = :'cz')
  and not exists (select 1 from public.character_lineage_choices where character_id = :'cz'));
select tl_test.rec('L66 the derived stats of a character without a lineage are unaffected by other characters'' lineage changes',
  tl_test.d(:'cn') = (select d from baseline_n));

-- =============================================================================
-- Representative catalog examples (Phase 4): mechanically different lineages from the seeded data
-- =============================================================================
select tl_test.as_root();
update public.characters set level = 1, strength = 10, dexterity = 14, constitution = 14, speed = 30 where id = :'ch';
select tl_test.as_user(:'alice');
select tl_test.add(:'inv_h', 'plate') as h_plate, tl_test.add(:'inv_h', 'shield') as h_shield, tl_test.add(:'inv_h', 'leather') as h_leather \gset
select public.equip_item(:'h_plate', 'armor');
select tl_test.set(:'ch', 'dwarf-phb', 'dwarf-mountain', '{"dwarf-phb:tool": ["smiths-tools"]}');
select tl_test.rec('L70 Mountain Dwarf in plate: STR 10+2 < 15 but speed stays 25 (dwarves are not slowed by heavy armor); plate is heavy, so not proficient',
  (tl_test.d(:'ch') -> 'speed' ->> 'value')::int = 25 and tl_test.has_warning(:'ch', 'nonproficient_armor')
  and tl_test.has_warning(:'ch', 'strength_requirement_unmet') and (tl_test.d(:'ch') -> 'armor_class' ->> 'value')::int = 18
  and tl_test.prof(:'ch', 'half-plate') ->> 'matched_by' = 'lineage' and tl_test.prof(:'ch', 'leather') ->> 'matched_by' = 'lineage',
  tl_test.d(:'ch') ->> 'speed');
select tl_test.rec('L71 Dwarven Combat Training makes the warhammer proficient by lineage; the chosen tool is listed',
  public._proficiency_match(:'ch', 'warhammer', null, 'martial-weapons') ->> 'matched_by' = 'lineage'
  and tl_test.d(:'ch') -> 'proficiencies' @> '[{"item_id": "smiths-tools", "source_type": "lineage"}]');
select tl_test.set(:'ch', 'tortle-mpmm', null, '{"tortle-mpmm:size": ["medium"]}');
select tl_test.rec('L72 Tortle (MotM) in plate: AC 17 from the shell, the armor gives no benefit',
  (tl_test.d(:'ch') -> 'armor_class' ->> 'value')::int = 17 and tl_test.has_warning(:'ch', 'lineage_armor_no_benefit'));
select public.unequip_item(:'h_plate');
select public.equip_item(:'h_shield', 'shield');
select tl_test.rec('L73 Tortle with a shield: 17 + 2 = 19 (DEX ignored)',
  (tl_test.d(:'ch') -> 'armor_class' ->> 'value')::int = 19 and tl_test.d(:'ch') -> 'armor_class' ->> 'base_formula' = 'natural_armor');
select public.unequip_item(:'h_shield');
select tl_test.set(:'ch', 'lizardfolk-mpmm');
select tl_test.rec('L74 Lizardfolk: natural armor 13 + DEX 2 = 15 unarmored, bite 1d6, swim speed equal to walking speed',
  (tl_test.d(:'ch') -> 'armor_class' ->> 'value')::int = 15 and (tl_test.d(:'ch') -> 'speed' -> 'movement' -> 'swim' ->> 'value')::int = 30
  and tl_test.d(:'ch') -> 'natural_weapons' @> '[{"name": "Bite", "damage_dice": "1d6"}]');
select tl_test.set(:'ch', 'aarakocra-mpmm');
select public.equip_item(:'h_leather', 'armor');
create temp table aar as select tl_test.d(:'ch') as mpmm;
select tl_test.set(:'ch', 'aarakocra-eepc');
select tl_test.rec('L75 Aarakocra (MotM): fly = walk 30 in light armor; (EEPC) fly 50, walk 25 - two versions, different numbers',
  ((select mpmm from aar) -> 'speed' -> 'movement' -> 'fly' ->> 'value')::int = 30
  and ((select mpmm from aar) -> 'speed' -> 'movement' -> 'fly' ->> 'active')::boolean
  and (tl_test.d(:'ch') -> 'speed' -> 'movement' -> 'fly' ->> 'value')::int = 50 and (tl_test.d(:'ch') -> 'speed' ->> 'value')::int = 25,
  (select mpmm from aar) ->> 'speed');
select public.unequip_item(:'h_leather');
select tl_test.set(:'ch', 'aasimar-mpmm', null, '{"aasimar-mpmm:size": ["small"]}');
select tl_test.rec('L76 Aasimar (MotM): chosen size Small; the 3rd-level revelation choice waits ("later") at level 1',
  tl_test.d(:'ch') -> 'size' ->> 'value' = 'small' and tl_test.choice_status(tl_test.lin(:'ch'), 'aasimar-mpmm:revelation') = 'later'
  and (tl_test.d(:'ch') -> 'resistances') @> '[{"damage_type": "necrotic"}, {"damage_type": "radiant"}]');
select tl_test.set(:'ch', 'elf-phb', 'elf-wood');
select tl_test.rec('L77 Wood Elf: Fleet of Foot replaces the base speed (35); Perception from Keen Senses',
  (tl_test.d(:'ch') -> 'speed' ->> 'value')::int = 35 and (tl_test.d(:'ch') -> 'skills' -> 'perception' ->> 'lineage_proficient')::boolean);
select tl_test.set(:'ch', 'elf-phb', 'elf-drow');
select tl_test.rec('L78 Drow: Superior Darkvision 120 replaces 60',
  (tl_test.d(:'ch') -> 'senses' -> 'darkvision' ->> 'value')::int = 120
  and tl_test.lin(:'ch') -> 'replaced_traits' @> '[{"id": "elf-phb:darkvision"}]');
select tl_test.set(:'ch', 'harengon-mpmm', null, '{"harengon-mpmm:size": ["small"]}');
select tl_test.rec('L79 Harengon: initiative bonus equal to the proficiency bonus (+2 at level 1)', (tl_test.d(:'ch') -> 'initiative' ->> 'bonus')::int = 2);
select tl_test.set(:'ch', 'dragonborn-phb', null, '{"dragonborn-phb:ancestry": ["red"]}');
select tl_test.rec('L80 Red dragonborn: fire resistance; breath weapon 2d6 fire, DC 8 + CON 2 + PB 2 = 12',
  tl_test.d(:'ch') -> 'resistances' @> '[{"damage_type": "fire"}]'
  and tl_test.d(:'ch') -> 'lineage_actions' @> '[{"name": "Breath Weapon", "dice": "2d6", "damage_type": "fire", "save_dc": 12}]',
  tl_test.d(:'ch') ->> 'lineage_actions');
select tl_test.as_root(); update public.characters set level = 5 where id = :'ch'; select tl_test.as_user(:'alice');
select tl_test.set(:'ch', 'tiefling-phb', 'tiefling-asmodeus');
select tl_test.rec('L81 Tiefling (Asmodeus) at level 5: Thaumaturgy, Hellish Rebuke (as 2nd level) and Darkness unlocked',
  (select count(*) from jsonb_array_elements(tl_test.d(:'ch') -> 'lineage_spells') x where (x ->> 'unlocked')::boolean) = 3
  and tl_test.d(:'ch') -> 'lineage_spells' @> '[{"name": "Hellish Rebuke", "cast_level": 2}]');
select tl_test.set(:'ch', 'tiefling-phb', 'tiefling-variant', '{"tiefling-variant:ability-scores": ["feral"], "tiefling-variant:legacy": ["winged"]}');
select tl_test.rec('L82 Variant Tiefling: Feral replaces CHA +2 (DEX +2, INT +1) and Winged gives a 30 ft fly speed',
  (tl_test.d(:'ch') -> 'abilities' -> 'cha' ->> 'lineage_applied')::int = 0 and (tl_test.d(:'ch') -> 'abilities' -> 'dex' ->> 'lineage_applied')::int = 2
  and (tl_test.d(:'ch') -> 'speed' -> 'movement' -> 'fly' ->> 'value')::int = 30);
select tl_test.set(:'ch', 'verdan-ai', null, '{"verdan-ai:language": ["elvish"]}');
select tl_test.rec('L83 Verdan grows to Medium at 5th level', tl_test.d(:'ch') -> 'size' ->> 'value' = 'medium');
select tl_test.set(:'ch', 'human-phb', 'human-mark-of-finding');
select tl_test.rec('L84 Mark of Finding replaces every human trait (no +1 to all abilities; Goblin instead of a free language)',
  (tl_test.d(:'ch') -> 'abilities' -> 'str' ->> 'lineage_applied')::int = 0 and (tl_test.d(:'ch') -> 'abilities' -> 'wis' ->> 'lineage_applied')::int = 2
  and tl_test.choice_status(tl_test.lin(:'ch'), 'human-phb:language') = 'disabled'
  and tl_test.d(:'ch') -> 'languages' @> '[{"id": "goblin"}]');

-- =============================================================================
-- Whole catalog sweep: every version and sub-lineage resolves and feeds the derived stats without an error
-- =============================================================================
select tl_test.as_user(:'alice');
create temp table sweep (version text, sub text, err text);
grant all on sweep to public;
do $$
declare v record; r jsonb; d jsonb;
begin
  for v in select b.id as vid, c.id as sid from public.lineage_versions b
           left join public.lineage_versions c on c.parent_version_id = b.id
           where b.kind = 'base' and (c.id is not null or not b.requires_child) order by b.id, c.id loop
    begin
      r := public.set_character_lineage('aaaaaaaa-0000-0000-0000-00000000000a', v.vid, v.sid);
      d := public.get_character_derived_stats('aaaaaaaa-0000-0000-0000-00000000000a');
      if d -> 'lineage' ->> 'version_id' is distinct from v.vid or jsonb_array_length(r -> 'traits') = 0 then
        insert into sweep values (v.vid, v.sid, 'not applied');
      end if;
      insert into sweep values (v.vid, v.sid, null);
    exception when others then insert into sweep values (v.vid, v.sid, sqlerrm);
    end;
  end loop;
end $$;
select tl_test.rec('L67 every catalog version and sub-lineage can be assigned and resolved (' || (select count(*) from sweep where err is null) || ' combinations)',
  (select count(*) from sweep where err is null) >= 100 and not exists (select 1 from sweep where err is not null),
  (select string_agg(version || '/' || coalesce(sub, '-') || ': ' || err, '; ') from sweep where err is not null));
select tl_test.rec('L68 every ability_choice / option_data_from reference in spell and action effects points to a choice of the same version',
  not exists (select 1 from public.lineage_trait_effects e join public.lineage_traits t on t.id = e.trait_id
              where coalesce(e.data ->> 'ability_choice', e.data ->> 'option_data_from') is not null
                and not exists (select 1 from public.lineage_choices c where c.id = coalesce(e.data ->> 'ability_choice', e.data ->> 'option_data_from')
                                and c.version_id = t.version_id)));
select tl_test.rec('L69 every legacy version that is superseded points to a current version of the same lineage',
  not exists (select 1 from public.lineage_versions v join public.lineage_versions s on s.id = v.superseded_by_version_id
              where s.status <> 'current' or s.lineage_id <> v.lineage_id));
select tl_test.as_root();

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
