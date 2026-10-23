-- =============================================================================
-- Spell catalog / class foundation / character spellcasting tests (migration 20261015001600). Same harness as
-- lineage_tests.sql: one transaction, rolled back; PASSED / FAILED per check; any FAILED check ends with an error.
-- Needs reference_data.sql, item_effects.sql, spells.sql and lineages.sql. Synthetic users and characters only;
-- exact mechanics are also checked on synthetic catalog rows created inside the transaction ("zz-" ids).
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
create function tl_test.book(p_char uuid) returns jsonb language sql as $$ select public.get_character_spellbook(p_char) $$;
create function tl_test.spell(p_char uuid, p_version text) returns jsonb language sql as $$
  select s from jsonb_array_elements(public.get_character_spellbook(p_char) -> 'spells') s where s ->> 'id' = p_version $$;
create function tl_test.src(p_char uuid, p_label text) returns jsonb language sql as $$
  select s from jsonb_array_elements(public.get_character_spellbook(p_char) -> 'sources') s where s ->> 'label' = p_label $$;
grant all on all functions in schema tl_test to public;
grant all on tl_test.results to public;
grant all on sequence tl_test.results_n_seq to public;

-- ---- synthetic catalog rows (stand in for the seed; exact mechanics) ---------------------------------------------------------
insert into public.catalog_spells (id, name) values ('zz-twin-burn', 'Zz Twin Burn'), ('zz-prism', 'Zz Prism');
insert into public.spell_versions (id, spell_id, name, level, school_id, casting_time_raw, casting_time_unit, casting_time_amount, range_raw,
  range_type, range_distance, range_unit, duration_raw, duration_type, components_raw, has_verbal_component, mechanism, save_ability,
  automation, source_label, source_url) values
  ('zz-twin-burn-test', 'zz-twin-burn', 'Zz Twin Burn', 5, 'evocation', '1 action', 'action', 1, '60 feet', 'distance', 60, 'feet',
   'Instantaneous', 'instantaneous', 'V', true, 'save', 'dex', 'partially_automated', 'Test Book', 'https://example.test/zz'),
  ('zz-prism-test', 'zz-prism', 'Zz Prism', 1, 'evocation', '1 action', 'action', 1, '90 feet', 'distance', 90, 'feet',
   'Instantaneous', 'instantaneous', 'V', true, 'attack', null, 'partially_automated', 'Test Book', 'https://example.test/zz');
insert into public.spell_effects (version_id, seq, category, mechanism, dice, damage_mode, automation) values
  ('zz-twin-burn-test', 1, 'damage', 'save', '4d6', 'simultaneous', 'partially_automated'),
  ('zz-twin-burn-test', 2, 'damage', 'save', '4d6', 'simultaneous', 'partially_automated'),
  ('zz-prism-test', 1, 'damage', 'attack', '3d8', 'choice', 'partially_automated');
insert into public.spell_effect_damage_types values ('zz-twin-burn-test', 1, 'fire'), ('zz-twin-burn-test', 2, 'radiant'),
  ('zz-prism-test', 1, 'acid'), ('zz-prism-test', 1, 'cold'), ('zz-prism-test', 1, 'fire');
insert into public.spell_damage_type_links values ('zz-twin-burn-test', 'fire', 'always'), ('zz-twin-burn-test', 'radiant', 'always'),
  ('zz-prism-test', 'acid', 'choice'), ('zz-prism-test', 'cold', 'choice'), ('zz-prism-test', 'fire', 'choice');
insert into public.spell_slot_progressions (id, name, kind) values ('zz-full', 'Synthetic full caster', 'full');
insert into public.spell_slot_progression_levels values ('zz-full', 3, 1, 4), ('zz-full', 3, 2, 2);

-- ---- users and characters ------------------------------------------------------------------------------------------------
insert into auth.users (id, email) values
  ('a1111111-1111-1111-1111-111111111111', 'alice@test'), ('b2222222-2222-2222-2222-222222222222', 'bob@test'),
  ('d3333333-3333-3333-3333-333333333333', 'dm@test');
insert into public.campaigns (id, name, created_by) values ('cccccccc-0000-0000-0000-000000000001', 'Spell Test Campaign', 'd3333333-3333-3333-3333-333333333333');
insert into public.campaign_members (campaign_id, user_id, role) values
  ('cccccccc-0000-0000-0000-000000000001', 'a1111111-1111-1111-1111-111111111111', 'player'),
  ('cccccccc-0000-0000-0000-000000000001', 'b2222222-2222-2222-2222-222222222222', 'player'),
  ('cccccccc-0000-0000-0000-000000000001', 'd3333333-3333-3333-3333-333333333333', 'dm');
-- level 3 (PB 2); INT 16 (+3), WIS 12 (+1), CHA 14 (+2)
insert into public.characters (id, owner_id, name, campaign_id, level, intelligence, wisdom, charisma) values
  ('aaaaaaaa-0000-0000-0000-00000000000a', 'a1111111-1111-1111-1111-111111111111', 'Spell Tester', 'cccccccc-0000-0000-0000-000000000001', 3, 16, 12, 14),
  ('bbbbbbbb-0000-0000-0000-00000000000b', 'b2222222-2222-2222-2222-222222222222', 'Bob Caster', 'cccccccc-0000-0000-0000-000000000001', 1, 10, 10, 10);
insert into public.spells (character_id, name, level) values ('aaaaaaaa-0000-0000-0000-00000000000a', 'My Homemade Hex', 1);
select 'aaaaaaaa-0000-0000-0000-00000000000a'::uuid as ca, 'bbbbbbbb-0000-0000-0000-00000000000b'::uuid as cb,
       'a1111111-1111-1111-1111-111111111111'::uuid as alice, 'b2222222-2222-2222-2222-222222222222'::uuid as bob,
       'd3333333-3333-3333-3333-333333333333'::uuid as dm \gset

select tl_test.as_user(:'alice');
select (public.save_character_spellcasting_source(:'ca', '{"source_type": "class", "label": "Artificer (preview)", "class_version_id": "artificer-tce", "class_level": 3, "progression_id": "zz-full"}') ->> 'id') as src_art \gset
select (public.save_character_spellcasting_source(:'ca', '{"source_type": "manual", "label": "Manual Spellcasting Source", "casting_ability": "cha", "always_prepared_allowed": true, "allowed_abilities": ["wis"]}') ->> 'id') as src_man \gset
select (public.save_character_spellcasting_source(:'ca', '{"source_type": "item", "label": "Wand of Testing", "fixed_dc": 15, "fixed_attack_bonus": 7, "uses_spell_slots": false}') ->> 'id') as src_item \gset

-- =============================================================================
-- Catalog
-- =============================================================================
select tl_test.as_root();
select tl_test.rec('S1 all eight spell schools exist',
  (select string_agg(id, ',' order by sort_order) from public.spell_schools) = 'abjuration,conjuration,divination,enchantment,evocation,illusion,necromancy,transmutation');
select tl_test.rec('S2 every spell version references one valid school; no school is stored as text elsewhere',
  not exists (select 1 from public.spell_versions v left join public.spell_schools s on s.id = v.school_id where s.id is null)
  and (select count(*) from public.spell_versions) >= 400);
select tl_test.rec('S3 spell levels are limited to 0-9',
  tl_test.raises($q$update public.spell_versions set level = 10 where id = 'zz-prism-test'$q$) like '%check%'
  and (select min(level) = 0 and max(level) = 9 from public.spell_versions));
select tl_test.rec('S4 ritual is a boolean on the version (Alarm yes, Fireball no)',
  (select is_ritual from public.spell_versions where id = 'alarm-phb') and not (select is_ritual from public.spell_versions where id = 'fireball-phb'));
select tl_test.rec('S5 concentration is an explicit boolean that agrees with the duration (Bless yes, Fireball no)',
  (select requires_concentration from public.spell_versions where id = 'bless-phb')
  and not (select requires_concentration from public.spell_versions where id = 'fireball-phb')
  and not exists (select 1 from public.spell_versions where requires_concentration <> (lower(duration_raw) like 'concentration%')));
select tl_test.rec('S6 components are structured (Fireball V,S,M with text; Chromatic Orb 50 gp; Revivify 300 gp consumed)',
  (select has_verbal_component and has_somatic_component and has_material_component and material_text like '%bat guano%'
   from public.spell_versions where id = 'fireball-phb')
  and (select material_cost_gp = 50 from public.spell_versions where id = 'chromatic-orb-phb')
  and (select material_cost_gp = 300 and material_consumed from public.spell_versions where id = 'revivify-phb'));
select tl_test.rec('S7 one spell can deal several damage types (two effects, both linked as always)',
  (select count(*) from public.spell_effects where version_id = 'zz-twin-burn-test' and category = 'damage') = 2
  and (select string_agg(damage_type_id || ':' || relation, ',' order by damage_type_id) from public.spell_damage_type_links where version_id = 'zz-twin-burn-test')
      = 'fire:always,radiant:always');
select tl_test.rec('S8 a damage-type choice is distinct from simultaneous damage (Chromatic Orb: one effect, six choices)',
  (select damage_mode = 'choice' from public.spell_effects where version_id = 'chromatic-orb-phb' and category = 'damage' limit 1)
  and (select count(*) from public.spell_damage_type_links where version_id = 'chromatic-orb-phb' and relation = 'choice') = 6
  and (select damage_mode from public.spell_effects where version_id = 'zz-twin-burn-test' and seq = 1) = 'simultaneous');
select tl_test.rec('S9 every class spell-list entry resolves to a version with the same level',
  not exists (select 1 from public.class_spell_list_entries e join public.spell_versions v on v.id = e.spell_version_id where v.level <> e.spell_level)
  and (select count(distinct list_id) from public.class_spell_list_entries) = 9);
select tl_test.rec('S10 the Artificer list resolves (cantrips to 5th level, Cure Wounds and Alarm on it, Fireball not)',
  (select count(*) from public.class_spell_list_entries where list_id = 'artificer-spell-list') >= 50
  and (select max(spell_level) from public.class_spell_list_entries where list_id = 'artificer-spell-list') = 5
  and exists (select 1 from public.class_spell_list_entries where list_id = 'artificer-spell-list' and spell_version_id = 'cure-wounds-phb')
  and exists (select 1 from public.class_spell_list_entries where list_id = 'artificer-spell-list' and spell_version_id = 'alarm-phb')
  and not exists (select 1 from public.class_spell_list_entries where list_id = 'artificer-spell-list' and spell_version_id = 'fireball-phb')
  and (select spell_list_id from public.class_versions where id = 'artificer-tce') = 'artificer-spell-list');
select tl_test.rec('S30 no orphan effects or links: every damage link type appears in an effect of that version',
  not exists (select 1 from public.spell_damage_type_links l where not exists (
    select 1 from public.spell_effect_damage_types t where t.version_id = l.version_id and t.damage_type_id = l.damage_type_id)));
select tl_test.rec('S31 no orphan class-list entries (every list belongs to a class version)',
  not exists (select 1 from public.class_spell_lists l left join public.class_versions v on v.id = l.class_version_id where v.id is null));
select tl_test.rec('S35a playtest versions of official spells are legacy and point to the official version (Antagonize)',
  (select status = 'legacy' and rule_status = 'playtest' and superseded_by_version_id = 'antagonize-bomt' from public.spell_versions where id = 'antagonize-ua')
  and not exists (select 1 from public.spell_versions where rule_status = 'playtest' and source_label not ilike '%unearthed arcana%' and id not like '%-ua'));
select tl_test.rec('S12 lineage spell grants resolve to the catalog (Asmodeus: Thaumaturgy, Hellish Rebuke, Darkness)',
  (select string_agg(spell_version_id, ',' order by seq) from public.lineage_trait_effects where trait_id = 'tiefling-asmodeus:infernal-legacy')
    = 'thaumaturgy-phb,hellish-rebuke-phb,darkness-phb');

-- =============================================================================
-- Character spellbook
-- =============================================================================
select tl_test.as_user(:'alice');
select tl_test.rec('S36 a class source is always a preview and takes the class ability and list (INT, Artificer list)',
  (select (s ->> 'is_preview')::boolean and s ->> 'casting_ability' = 'int' and s ->> 'spell_list_id' = 'artificer-spell-list'
   from jsonb_array_elements(tl_test.book(:'ca') -> 'sources') s where s ->> 'id' = :'src_art'));
select tl_test.rec('S17-19 Artificer source: Save DC 8 + PB 2 + INT 3 = 13; attack bonus PB 2 + INT 3 = +5',
  (tl_test.src(:'ca', 'Artificer (preview)') -> 'stats' ->> 'save_dc')::int = 13
  and (tl_test.src(:'ca', 'Artificer (preview)') -> 'stats' ->> 'attack_bonus')::int = 5);
select tl_test.rec('S23 a second source with another ability has its own DC (CHA: 8 + 2 + 2 = 12)',
  (tl_test.src(:'ca', 'Manual Spellcasting Source') -> 'stats' ->> 'save_dc')::int = 12);
select tl_test.rec('S21-22 a fixed item DC and attack bonus replace the formula (15, +7)',
  (tl_test.src(:'ca', 'Wand of Testing') -> 'stats' ->> 'save_dc')::int = 15
  and (tl_test.src(:'ca', 'Wand of Testing') -> 'stats' ->> 'attack_bonus')::int = 7
  and tl_test.src(:'ca', 'Wand of Testing') -> 'stats' -> 'dc_breakdown' = '[{"part": "fixed", "value": 15}]');
select public.save_character_spellcasting_source(:'ca', jsonb_build_object('id', :'src_man', 'source_type', 'manual', 'label', 'Manual Spellcasting Source',
  'casting_ability', 'cha', 'always_prepared_allowed', true, 'allowed_abilities', '["wis"]'::jsonb, 'dc_bonus', 1, 'attack_bonus', 1));
select tl_test.rec('S20 a permanent bonus is added to the formula (DC 12 + 1 = 13, attack +4 + 1 = +5) and shown in the breakdown',
  (tl_test.src(:'ca', 'Manual Spellcasting Source') -> 'stats' ->> 'save_dc')::int = 13
  and (tl_test.src(:'ca', 'Manual Spellcasting Source') -> 'stats' ->> 'attack_bonus')::int = 5
  and tl_test.src(:'ca', 'Manual Spellcasting Source') -> 'stats' -> 'dc_breakdown' @> '[{"part": "bonus", "value": 1}]');
select tl_test.as_root(); update public.characters set level = 5 where id = :'ca'; select tl_test.as_user(:'alice');
select tl_test.rec('S19b the proficiency bonus is part of the formula (level 5: PB 3, Artificer DC 14)',
  (tl_test.src(:'ca', 'Artificer (preview)') -> 'stats' ->> 'save_dc')::int = 14);
select tl_test.as_root(); update public.characters set level = 3 where id = :'ca'; select tl_test.as_user(:'alice');

select public.set_character_spell(:'ca', :'src_art', 'cure-wounds-phb', true, true);
select public.set_character_spell(:'ca', :'src_art', 'alarm-phb', true, false);
select public.set_character_spell(:'ca', :'src_man', 'zz-prism-test', true, false, true);
select public.set_character_spell(:'ca', :'src_item', 'fireball-phb', true, false);
select tl_test.rec('S15 known and prepared are separate states (Cure Wounds known+prepared, Alarm known only)',
  (tl_test.spell(:'ca', 'cure-wounds-phb') ->> 'prepared')::boolean and (tl_test.spell(:'ca', 'cure-wounds-phb') ->> 'known')::boolean
  and not (tl_test.spell(:'ca', 'alarm-phb') ->> 'prepared')::boolean and (tl_test.spell(:'ca', 'alarm-phb') ->> 'known')::boolean);
select tl_test.rec('S16 an always-prepared spell does not count against the prepared selection',
  (tl_test.spell(:'ca', 'zz-prism-test') ->> 'always_prepared')::boolean
  and (tl_test.src(:'ca', 'Manual Spellcasting Source') -> 'counts' ->> 'prepared')::int = 0
  and (tl_test.src(:'ca', 'Manual Spellcasting Source') -> 'counts' ->> 'always_prepared')::int = 1
  and (tl_test.src(:'ca', 'Artificer (preview)') -> 'counts' ->> 'prepared')::int = 1);
create temp table rit as select tl_test.spell(:'ca', 'alarm-phb') as known_only;
select public.set_character_spell(:'ca', :'src_art', 'alarm-phb', true, true);
select tl_test.rec('S37 ritual capability follows the source rule: Artificer rituals need the spell prepared (Alarm known only: no; prepared: yes)',
  ((select known_only from rit) ->> 'ritual')::boolean and not ((select known_only from rit) ->> 'ritual_castable')::boolean
  and (tl_test.spell(:'ca', 'alarm-phb') ->> 'ritual_castable')::boolean
  and (tl_test.src(:'ca', 'Artificer (preview)') ->> 'ritual_mode') = 'prepared');
select public.set_character_spell(:'ca', :'src_art', 'alarm-phb', true, false);
select tl_test.rec('S38 each grant carries the DC/attack of its own source (item spell DC 15, class spell DC 13)',
  (tl_test.spell(:'ca', 'fireball-phb') -> 'grants' -> 0 -> 'stats' ->> 'save_dc')::int = 15
  and (tl_test.spell(:'ca', 'cure-wounds-phb') -> 'grants' -> 0 -> 'stats' ->> 'save_dc')::int = 13);
select tl_test.rec('S11 class-list eligibility is visible: Fireball is not on the Artificer list',
  (tl_test.spell(:'ca', 'cure-wounds-phb') -> 'grants' -> 0 ->> 'on_source_list')::boolean
  and tl_test.raises(format('select public.save_character_spellcasting_source(%L, %L)', :'ca',
        jsonb_build_object('id', :'src_art', 'source_type', 'class', 'label', 'Artificer (preview)', 'class_version_id', 'artificer-tce', 'enforce_spell_list', true,
                     'class_level', 3, 'progression_id', 'zz-full'))) is null
  and tl_test.raises(format('select public.set_character_spell(%L, %L, ''fireball-phb'')', :'ca', :'src_art')) like '%not on the spell list%'
  and tl_test.raises(format('select public.set_character_spell(%L, %L, ''cure-wounds-phb'')', :'ca', :'src_art')) is null);
select tl_test.rec('S39 always-prepared is only allowed when the source permits it',
  tl_test.raises(format('select public.set_character_spell(%L, %L, ''alarm-phb'', true, false, true)', :'ca', :'src_art')) like '%always prepared%');
select tl_test.rec('S40 a spell grant may only choose an ability the source allows',
  tl_test.raises(format('select public.set_character_spell(%L, %L, ''zz-prism-test'', true, false, true, ''int'')', :'ca', :'src_man')) like '%does not let%'
  and (public.set_character_spell(:'ca', :'src_man', 'zz-prism-test', true, false, true, 'wis') ->> 'casting_ability') = 'wis'
  and (tl_test.spell(:'ca', 'zz-prism-test') -> 'grants' -> 0 -> 'stats' ->> 'attack_bonus')::int = 2 + 1 + 1);
select public.set_character_spell(:'ca', :'src_art', 'detect-magic-phb', false, true);
select tl_test.rec('S41 a spell must be known, prepared or always prepared; a prepared-only spell cannot be unprepared',
  tl_test.raises(format('select public.set_character_spell(%L, %L, ''alarm-phb'', false, false, false)', :'ca', :'src_art')) like '%known, prepared%'
  and tl_test.raises(format('select public.set_character_spell_prepared(%L, false)',
        (select id from public.character_spells where source_id = :'src_art' and spell_version_id = 'detect-magic-phb'))) like '%remove it instead%');

-- lineage + duplicate sources
select public.set_character_lineage(:'ca', 'tiefling-phb', 'tiefling-asmodeus');
select public.set_character_spell(:'ca', :'src_man', 'thaumaturgy-phb', true, false);
select tl_test.rec('S13a lineage spells appear automatically with their unlock level (Hellish Rebuke at 3rd: unlocked; Darkness: locked)',
  (tl_test.spell(:'ca', 'hellish-rebuke-phb') ->> 'unlocked')::boolean and not (tl_test.spell(:'ca', 'darkness-phb') ->> 'unlocked')::boolean
  and tl_test.spell(:'ca', 'hellish-rebuke-phb') -> 'grants' -> 0 ->> 'source_type' = 'lineage'
  and (tl_test.spell(:'ca', 'hellish-rebuke-phb') -> 'grants' -> 0 ->> 'cast_level')::int = 2);
select tl_test.rec('S14 a spell from the lineage and a manual source is one spell with two grants',
  (select count(*) from jsonb_array_elements(tl_test.book(:'ca') -> 'spells') s where s ->> 'id' = 'thaumaturgy-phb') = 1
  and (tl_test.spell(:'ca', 'thaumaturgy-phb') ->> 'source_count')::int = 2
  and (select string_agg(g ->> 'source_type', ',' order by g ->> 'source_type') from jsonb_array_elements(tl_test.spell(:'ca', 'thaumaturgy-phb') -> 'grants') g) = 'lineage,manual');
select tl_test.rec('S42 the lineage source has its own DC from its ability (CHA 14 + 2 lineage = 16: 8 + PB 2 + 3 = 13)',
  (select (s -> 'stats' ->> 'save_dc')::int from jsonb_array_elements(tl_test.book(:'ca') -> 'sources') s where s ->> 'source_type' = 'lineage') = 13);
select public.clear_character_lineage(:'ca');
select tl_test.rec('S13b removing the lineage removes only its grants: Thaumaturgy stays (manual), Hellish Rebuke is gone',
  (tl_test.spell(:'ca', 'thaumaturgy-phb') ->> 'source_count')::int = 1 and tl_test.spell(:'ca', 'hellish-rebuke-phb') is null);
select tl_test.rec('S34 free-text spells stay visible (with a catalog match when the name matches exactly)',
  (select count(*) from jsonb_array_elements(tl_test.book(:'ca') -> 'free_text_spells') x where x ->> 'name' = 'My Homemade Hex' and x ->> 'catalog_match' is null) = 1);
select public.set_character_spell(:'ca', :'src_man', 'antagonize-ua', true, false);
select tl_test.rec('S35b a character grant of a playtest version keeps that exact version (no silent replacement)',
  tl_test.spell(:'ca', 'antagonize-ua') ->> 'rule_status' = 'playtest' and tl_test.spell(:'ca', 'antagonize-bomt') is null);
select tl_test.rec('S43 slots come from a source progression when one is set (synthetic: level 3 -> 4 first, 2 second)',
  tl_test.book(:'ca') -> 'slots' -> 'progression' -> 'slots' = '[{"level": 1, "total": 4}, {"level": 2, "total": 2}]');
select public.delete_character_spellcasting_source(:'src_item');
select tl_test.rec('S44 deleting a source removes only its grants (Fireball gone, Cure Wounds stays)',
  tl_test.spell(:'ca', 'fireball-phb') is null and tl_test.spell(:'ca', 'cure-wounds-phb') is not null);

-- =============================================================================
-- Security
-- =============================================================================
select tl_test.as_user(:'bob');
select tl_test.rec('S24 another player cannot read the spellbook or the sources',
  tl_test.raises(format('select public.get_character_spellbook(%L)', :'ca')) like '%Character not found%'
  and not exists (select 1 from public.character_spellcasting_sources where character_id = :'ca')
  and not exists (select 1 from public.character_spells where character_id = :'ca'));
select tl_test.rec('S26 another player cannot add, prepare, remove or forge sources on that character',
  tl_test.raises(format('select public.set_character_spell(%L, %L, ''alarm-phb'')', :'ca', :'src_art')) like '%Character not found%'
  and tl_test.raises(format('select public.set_character_spell_prepared(%L, true)', (select id from public.character_spells limit 1))) like '%not found%'
  and tl_test.raises(format('select public.delete_character_spellcasting_source(%L)', :'src_man')) like '%not found%'
  and tl_test.raises(format('select public.set_character_spell(%L, %L, ''alarm-phb'')', :'cb', :'src_man')) like '%Spellcasting source not found%');
select tl_test.rec('S45 forged ownership fields are refused (character_id / created_by in the source payload)',
  tl_test.raises(format('select public.save_character_spellcasting_source(%L, %L)', :'cb',
    jsonb_build_object('source_type', 'manual', 'label', 'x', 'character_id', :'ca'))) like '%cannot be set%'
  and tl_test.raises(format('select public.save_character_spellcasting_source(%L, %L)', :'cb',
    jsonb_build_object('source_type', 'lineage', 'label', 'x'))) like '%Unknown source type%');
select tl_test.as_user(:'dm');
select tl_test.rec('S25 the campaign DM reads the spellbook', jsonb_array_length(tl_test.book(:'ca') -> 'spells') >= 3);
select tl_test.as_user(:'alice');
select tl_test.rec('S27 the official catalog is read-only for clients',
  tl_test.raises($q$update public.spell_versions set name = 'x' where id = 'fireball-phb'$q$) like '%permission denied%'
  and tl_test.raises($q$insert into public.catalog_spells (id, name) values ('evil', 'Evil')$q$) like '%permission denied%'
  and tl_test.raises(format('insert into public.character_spells (character_id, source_id, spell_version_id) values (%L, %L, ''alarm-phb'')', :'ca', :'src_art')) like '%permission denied%');
select tl_test.as_root();
insert into public.catalog_spells (id, name, owner_id) values ('zz-alice-secret', 'Alice Secret Spell', :'alice');
insert into public.spell_versions (id, spell_id, name, level, school_id, casting_time_raw, casting_time_unit, range_raw, range_type,
  duration_raw, duration_type, components_raw, automation, rule_status, source_label, source_url) values
  ('zz-alice-secret-hb', 'zz-alice-secret', 'Alice Secret Spell', 1, 'illusion', '1 action', 'action', 'Self', 'self', 'Instantaneous',
   'instantaneous', 'V', 'informational', 'homebrew', 'Homebrew', 'https://example.test/hb');
select tl_test.as_user(:'bob');
select tl_test.rec('S28 private homebrew spells are invisible to others and cannot be granted by them',
  not exists (select 1 from public.v_spell_catalog where id = 'zz-alice-secret-hb')
  and tl_test.raises(format('select public.set_character_spell(%L, (select id from public.character_spellcasting_sources limit 1), ''zz-alice-secret-hb'')', :'cb')) is not null);
select tl_test.as_user(:'alice');
select tl_test.rec('S28b the owner sees her private homebrew spell (scope private)',
  (select scope from public.v_spell_catalog where id = 'zz-alice-secret-hb') = 'private');
select set_config('role', 'anon', true);
select tl_test.rec('S46 anonymous visitors read the official catalog and class lists, not character spells',
  (select count(*) from public.v_spell_catalog) >= 400 and (select count(*) from public.class_spell_list_entries) > 0
  and tl_test.raises('select count(*) from public.character_spells') like '%permission denied%');
select tl_test.as_root();
select tl_test.rec('S47 every spell SECURITY DEFINER function pins its search_path',
  not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
              where n.nspname = 'public' and p.prosecdef and (p.proname like '%spell%')
                and not exists (select 1 from unnest(coalesce(p.proconfig, '{}')) c where c like 'search_path=%')));

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
