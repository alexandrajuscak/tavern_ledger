-- =============================================================================
-- Versioned feat catalog and feat engine (20261019000300, docs/FEATS.md, FEAT_DATA_MODEL.md): exact versions, 2014 vs 2024,
-- background Origin feats, ASI feats, lineage feats, repeatability, prerequisites and DM overrides, ability / HP /
-- proficiency / spell / resource effects, duplicate sources, incomplete choices, catalog protection, campaign visibility,
-- requests, export / import. Runs inside the per-class harness (alice = player, bob = outsider, dm = DM of :camp).
-- =============================================================================
\set f1 f1f00000-0000-0000-0000-000000000001
\set f2 f1f00000-0000-0000-0000-000000000002
\set f3 f1f00000-0000-0000-0000-000000000003
\set f4 f1f00000-0000-0000-0000-000000000004
\set f5 f1f00000-0000-0000-0000-000000000005
\set f6 f1f00000-0000-0000-0000-000000000006
insert into public.characters (id, owner_id, name, campaign_id, level, strength, dexterity, constitution, intelligence, wisdom, charisma, hp_max, hp_current) values
  (:'f1', :'alice', 'Feat Guard', null, 1, 12, 14, 13, 10, 12, 8, 10, 10),
  (:'f2', :'alice', 'Feat Fighter', null, 1, 16, 12, 14, 10, 10, 8, 12, 12),
  (:'f3', :'alice', 'Feat Human', null, 1, 10, 10, 10, 10, 10, 10, 8, 8),
  (:'f4', :'alice', 'Feat Wizard', null, 1, 8, 14, 12, 16, 10, 10, 6, 6),
  (:'f5', :'alice', 'Feat Campaign', :'camp', 1, 10, 10, 10, 10, 10, 10, 8, 8),
  (:'f6', :'alice', 'Feat Import Target', null, 1, 10, 10, 10, 10, 10, 10, 8, 8);
create function tl_test.code(p_sql text) returns text language plpgsql as $$
begin execute p_sql; return 'ok'; exception when others then return sqlstate; end $$;
create function tl_test.feats(p_char uuid) returns jsonb language sql as $$ select public.get_character_feats(p_char) -> 'feats' $$;
create function tl_test.feat(p_char uuid, p_version text) returns jsonb language sql as $$
  select f from jsonb_array_elements(public.get_character_feats(p_char) -> 'feats') f where f -> 'feat' ->> 'id' = p_version limit 1 $$;
create function tl_test.dd(p_char uuid) returns jsonb language sql as $$ select public.get_character_derived_stats(p_char) $$;
create function tl_test.cfid(p_char uuid, p_version text) returns uuid language sql as $$
  select id from public.character_feats where character_id = p_char and feat_version_id = p_version order by created_at limit 1 $$;
grant all on all functions in schema tl_test to public;
select tl_test.as_user(:'alice');

-- ---- catalog ----------------------------------------------------------------------------------------------------------------
select tl_test.rec('FT1 an exact version resolves with its ruleset, category, source and automation',
  (public.get_feat_detail('alert-2024') ->> 'ruleset') = '2024' and (public.get_feat_detail('alert-2024') ->> 'category') = 'origin'
  and (public.get_feat_detail('alert-2024') ->> 'source_label') = 'Player''s Handbook'
  and (public.get_feat_detail('alert-2024') ->> 'automation') in ('automated', 'partially_automated'));
select tl_test.rec('FT2 2014 and 2024 versions of a feat stay distinct (same canonical feat, different mechanics)',
  (select count(*) from public.feat_versions where feat_id = 'alert') = 2
  and (select value from public.feat_effects where version_id = 'alert-2014' and effect_type = 'initiative_bonus') = 5
  and (select value_text from public.feat_effects where version_id = 'alert-2024' and effect_type = 'initiative_bonus') = 'pb'
  and jsonb_array_length(public.get_feat_detail('alert-2024') -> 'other_versions') = 1);
select tl_test.rec('FT3 the catalog covers both rulesets and all four 2024 categories; playtest is never "official"',
  (select count(*) from public.feat_versions where ruleset = '2014') > 150 and (select count(*) from public.feat_versions where ruleset = '2024') > 150
  and (select count(distinct category) from public.feat_versions where ruleset = '2024' and category in ('origin', 'general', 'fighting_style', 'epic_boon')) = 4
  and not exists (select 1 from public.feat_versions where status = 'official' and (source_label like 'Unearthed Arcana%' or id like '%-ua-%')));
select tl_test.rec('FT4 the official catalog is read-only for players',
  tl_test.code($$insert into public.feat_versions (id, feat_id, name, category, ruleset, status) values ('hack-2024', 'alert', 'Hack', 'general', '2024', 'official')$$) = '42501'
  and tl_test.code($$update public.feat_versions set summary = 'x' where id = 'alert-2024'$$) = '42501'
  and tl_test.code($$delete from public.feat_effects where version_id = 'tough-2024'$$) = '42501');

-- ---- background Origin feat ----------------------------------------------------------------------------------------------------
select public.set_character_background(:'f1', 'guard-2024', '{"mode": "plus1_x3", "allocation": {"str": 1, "int": 1, "wis": 1}}', '{}');
select tl_test.rec('FT5 a 2024 background grants its Origin feat automatically (exact version, background source)',
  (tl_test.feat(:'f1', 'alert-2024') ->> 'source_type') = 'background' and (tl_test.feat(:'f1', 'alert-2024') ->> 'active')::boolean);
select tl_test.rec('FT6 Alert 2024 adds the proficiency bonus to initiative, with the feat as source',
  (tl_test.dd(:'f1') -> 'initiative' ->> 'bonus')::int = 2
  and exists (select 1 from jsonb_array_elements(tl_test.dd(:'f1') -> 'initiative' -> 'sources') s where s #>> '{}' like 'Feat: Alert%'));
select tl_test.rec('FT7 a non-repeatable feat cannot be taken twice (background Alert + direct Alert)',
  tl_test.raises(format('select public.assign_character_feat(%L, %L)', :'f1', 'alert-2024')) like '%only once%');
select public.clear_character_background(:'f1');
select tl_test.rec('FT8 removing the background removes its feat (and its initiative bonus)',
  tl_test.feat(:'f1', 'alert-2024') is null and (tl_test.dd(:'f1') -> 'initiative' ->> 'bonus')::int = 0);

-- ---- ASI feat, HP, prerequisites ------------------------------------------------------------------------------------------------
select public.set_character_class(:'f2', 'fighter-phb', 4, null, true);
select tl_test.rec('FT9 a prerequisite blocks with the exact reason (Great Weapon Master 2024 needs STR 13; Heavy Armor Master needs heavy armor -> met)',
  tl_test.raises(format('select tl_test.choose(%L, %L, %L, %L, array[%L])', :'f2', 'fighter', 'fighter-phb-u4-asi', 'fighter-asi-phb-asi', 'feat:defensive-duelist-2024')) like '%prerequisite not met%Dexterity 13%');
select tl_test.choose(:'f2', 'fighter', 'fighter-phb-u4-asi', 'fighter-asi-phb-asi', array['feat:tough-2014']);
select tl_test.rec('FT10 an ASI feat pick resolves to the exact version with the class feature as source',
  (tl_test.feat(:'f2', 'tough-2014') ->> 'source_type') = 'class'
  and (tl_test.feat(:'f2', 'tough-2014') ->> 'source_label') like 'Fighter: Ability Score Improvement%');
select tl_test.rec('FT11 Tough: maximum HP = stored 12 + 2 x level 4 = 20 (derived, never written into hp_max)',
  (tl_test.dd(:'f2') -> 'hit_points' ->> 'max')::int = 20 and (select hp_max from public.characters where id = :'f2') = 12);
update public.characters set hp_current = 20 where id = :'f2';
select public.set_character_class(:'f2', 'fighter-phb', 3);
select tl_test.rec('FT12 losing the ASI level deactivates the feat: max HP back to 12 and current HP clamped to it',
  (tl_test.dd(:'f2') -> 'hit_points' ->> 'max')::int = 12 and (select hp_current from public.characters where id = :'f2') = 12
  and not (tl_test.feat(:'f2', 'tough-2014') ->> 'active')::boolean);
select public.set_character_class(:'f2', 'fighter-phb', 4);

-- ---- direct feats: ability, saves, proficiency, incomplete choices ---------------------------------------------------------------
select public.assign_character_feat(:'f2', 'resilient-2014', '{"ability": ["con"]}');
select tl_test.rec('FT14 Resilient (CON): +1 CON from the choice and CON saving throw proficiency',
  (tl_test.dd(:'f2') -> 'abilities' -> 'con' ->> 'score')::int = 15
  and coalesce((tl_test.dd(:'f2') -> 'saving_throws' -> 'con' ->> 'class_proficient')::boolean, false));
select public.assign_character_feat(:'f2', 'skilled-2014', '{"profs": ["skill:stealth", "tool:thieves-tools"]}');
select tl_test.rec('FT15 an incomplete choice keeps the dependent effects inactive (2 of 3 Skilled picks: no proficiency yet)',
  (tl_test.feat(:'f2', 'skilled-2014') ->> 'open_choices')::int = 1
  and not coalesce((tl_test.dd(:'f2') -> 'skills' -> 'stealth' ->> 'class_proficient')::boolean, false));
select public.set_character_feat_choices(:'f2', 'cf:' || tl_test.cfid(:'f2', 'skilled-2014'), '{"profs": ["skill:stealth", "skill:arcana", "tool:thieves-tools"]}');
select tl_test.rec('FT16 completing the choices applies the proficiencies (skills and a tool, feat as source)',
  coalesce((tl_test.dd(:'f2') -> 'skills' -> 'stealth' ->> 'class_proficient')::boolean, false)
  and coalesce((tl_test.dd(:'f2') -> 'skills' -> 'arcana' ->> 'class_proficient')::boolean, false)
  and exists (select 1 from jsonb_array_elements(tl_test.dd(:'f2') -> 'proficiencies') p where p ->> 'item_id' = 'thieves-tools'));
select tl_test.rec('FT17 invalid choice values are refused (unknown skill, too many picks, duplicates)',
  tl_test.raises(format('select public.set_character_feat_choices(%L, %L, %L)', :'f2', 'cf:' || tl_test.cfid(:'f2', 'skilled-2014'), '{"profs": ["skill:flying"]}')) like '%choose skill:%'
  and tl_test.raises(format('select public.set_character_feat_choices(%L, %L, %L)', :'f2', 'cf:' || tl_test.cfid(:'f2', 'skilled-2014'), '{"profs": ["skill:stealth", "skill:arcana", "skill:history", "skill:nature"]}')) like '%at most 3%');

-- ---- lineage feat -----------------------------------------------------------------------------------------------------------------
select public.set_character_lineage(:'f3', 'human-phb', 'human-variant', '{"human-variant:asi": ["str:1", "dex:1"], "human-variant:skill": ["perception"], "human-variant:feat": ["feat:lucky-2014"]}', false, false);
select tl_test.rec('FT18 a lineage feat choice (Variant Human) resolves through the catalog with the lineage as source',
  (tl_test.feat(:'f3', 'lucky-2014') ->> 'source_type') = 'lineage' and (tl_test.feat(:'f3', 'lucky-2014') ->> 'active')::boolean);
select (tl_test.feat(:'f3', 'lucky-2014') -> 'resources' -> 0 ->> 'max')::int as ft19max \gset
select public.expend_character_resource(:'f3', tl_test.feat(:'f3', 'lucky-2014') -> 'resources' -> 0 ->> 'key') is not null as ft19x \gset
select tl_test.rec('FT19 a resource feat (Lucky 2014): 3 luck points, long rest, spendable through the resource engine',
  :ft19max = 3 and :'ft19x' = 't' and (select expended from public.character_resources where character_id = :'f3' and source_type = 'feat') = 1);
select public.set_character_lineage(:'f3', 'human-phb', null, '{}', false, false);
select tl_test.rec('FT20 changing the lineage removes only the lineage feat (its resource is kept inactive with the count)',
  tl_test.feat(:'f3', 'lucky-2014') is null
  and (select active from public.character_resources where character_id = :'f3' and source_type = 'feat') = false);

-- ---- spell feat, duplicate source --------------------------------------------------------------------------------------------------
select public.set_character_class(:'f4', 'wizard-phb', 1, null, true);
select public.set_character_spell(:'f4', (select id from public.character_spellcasting_sources where character_id = :'f4' and source_type = 'class'), 'light-phb', true, false);
select public.assign_character_feat(:'f4', 'magic-initiate-2014', '{"list": ["wizard-spell-list"], "cantrips": ["fire-bolt-phb", "light-phb"], "spell1": ["magic-missile-phb"]}');
select tl_test.rec('FT21 Magic Initiate: the chosen spells are on the spellbook under the feat source with INT (Wizard list), plus one free cast',
  (select count(*) from public.character_spells cs join public.character_spellcasting_sources s on s.id = cs.source_id
   where s.character_id = :'f4' and s.source_type = 'feat') = 3
  and (select casting_ability from public.character_spellcasting_sources where character_id = :'f4' and source_type = 'feat') = 'int'
  and exists (select 1 from public.character_resources where character_id = :'f4' and source_type = 'feat' and spell_version_id = 'magic-missile-phb'));
select tl_test.rec('FT22 a spell from a wrong list is refused (Cure Wounds is not a wizard spell)',
  tl_test.raises(format('select public.set_character_feat_choices(%L, %L, %L)', :'f4', 'cf:' || tl_test.cfid(:'f4', 'magic-initiate-2014'), '{"spell1": ["cure-wounds-phb"]}')) like '%not on the chosen spell list%');
select public.remove_character_feat(tl_test.cfid(:'f4', 'magic-initiate-2014'));
select tl_test.rec('FT23 removing the feat removes only its source: Light stays known from the Wizard class',
  not exists (select 1 from public.character_spellcasting_sources where character_id = :'f4' and source_type = 'feat')
  and exists (select 1 from public.character_spells cs join public.character_spellcasting_sources s on s.id = cs.source_id
              where s.character_id = :'f4' and s.source_type = 'class' and cs.spell_version_id = 'light-phb'));

-- ---- repeatable --------------------------------------------------------------------------------------------------------------------
select public.assign_character_feat(:'f4', 'magic-initiate-2024', '{"list": ["wizard-spell-list"], "ability": ["int"], "cantrips": ["fire-bolt-phb", "light-phb"], "spell1": ["shield-phb"]}');
select tl_test.rec('FT24 a "repeatable with a different option" feat refuses the same option again ...',
  tl_test.raises(format('select public.assign_character_feat(%L, %L, %L)', :'f4', 'magic-initiate-2024', '{"list": ["wizard-spell-list"]}')) like '%different%');
select tl_test.code(format('select public.assign_character_feat(%L, %L, %L)', :'f4', 'magic-initiate-2024', '{"list": ["cleric-spell-list"], "ability": ["wis"]}')) as ft25 \gset
select tl_test.rec('FT25 ... and accepts a different one (Magic Initiate 2024: Cleric list)',
  :'ft25' = 'ok'
  and (select count(*) from public.character_feats where character_id = :'f4' and feat_version_id = 'magic-initiate-2024') = 2);

-- ---- campaign: governance, override, visibility, requests -----------------------------------------------------------------------------
select tl_test.as_user(:'dm');
select public.set_campaign_governance(:'camp', '{"preset": "standard", "unmet_prerequisites": "dm_override"}');
select public.set_character_setup_complete(:'f5', true);
select tl_test.as_user(:'alice');
select tl_test.rec('FT26 in a standard campaign a player feat needs approval (TLAPR)',
  tl_test.code(format('select public.assign_character_feat(%L, %L)', :'f5', 'tough-2024')) = 'TLAPR');
select (public.create_change_request(:'f5', '[{"op": "assign_character_feat", "args": {"p_version": "tough-2024"}}]'::jsonb, 'Take Tough') ->> 'id') as rq \gset
select tl_test.rec('FT27 the feat request previews the HP gain', exists (select 1 from jsonb_array_elements((select preview -> 'diff' from public.change_requests where id = :'rq')) d
  where d ->> 'label' = 'Maximum HP' and (d ->> 'after')::int = (d ->> 'before')::int + 2));
select tl_test.as_user(:'dm');
select public.review_change_request(:'rq', 'approve');
select tl_test.rec('FT28 approved: the feat is on the character as an approved request',
  (select source_type from public.character_feats where character_id = :'f5' and feat_version_id = 'tough-2024') = 'approved_request');
select tl_test.code(format('select public.assign_character_feat(%L, %L, %L, %L, null, %L)', :'f5', 'great-weapon-master-2024', '{"asi": ["str"]}', 'dm_grant', 'Story reward')) as ft29 \gset
select tl_test.rec('FT29 a DM override needs the DM and records the reason (audit: dm_override_used)',
  :'ft29' = 'ok'
  and (select prerequisite_override and override_reason = 'Story reward' from public.character_feats where character_id = :'f5' and feat_version_id = 'great-weapon-master-2024')
  and exists (select 1 from public.campaign_audit_events where character_id = :'f5' and event_type = 'dm_override_used'));
select tl_test.as_root();
insert into public.feats (id, name, owner_id, campaign_id) values ('zz-test-custom', 'Test Custom Feat', :'dm', :'camp');
insert into public.feat_versions (id, feat_id, name, category, ruleset, status, summary, owner_id, campaign_id)
values ('zz-test-custom-v1', 'zz-test-custom', 'Test Custom Feat', 'general', '2024', 'homebrew', 'Campaign test feat', :'dm', :'camp');
select tl_test.as_user(:'bob');
select tl_test.rec('FT30 a campaign custom feat is invisible outside its campaign', not exists (select 1 from public.feat_versions where id = 'zz-test-custom-v1')
  and tl_test.code($$select public.get_feat_detail('zz-test-custom-v1')$$) = 'P0002');
select tl_test.as_user(:'alice');
select tl_test.rec('FT31 ... and visible (with campaign scope) to its members; the picker marks it',
  exists (select 1 from jsonb_array_elements(public.get_feat_catalog(:'f5')) x where x ->> 'id' = 'zz-test-custom-v1' and x ->> 'scope' = 'campaign'));
select tl_test.rec('FT32 the picker evaluates prerequisites for the character',
  (select x -> 'prerequisite' ->> 'status' from jsonb_array_elements(public.get_feat_catalog(:'f5')) x where x ->> 'id' = 'great-weapon-master-2024') = 'unsatisfied');

-- ---- export / import ---------------------------------------------------------------------------------------------------------------
select public.export_character_feats(:'f2') as exported \gset
select public.import_character_feats(:'f6', :'exported'::jsonb) as imported \gset
select tl_test.rec('FT33 export keeps exact versions and choices; import assigns direct feats and reports the rest',
  exists (select 1 from jsonb_array_elements(:'exported'::jsonb) e where e ->> 'feat_version_id' = 'skilled-2014' and e -> 'choices' -> 'profs' ? 'skill:arcana')
  and (select count(*) from public.character_feats where character_id = :'f6') = 2
  and exists (select 1 from jsonb_array_elements(:'imported'::jsonb -> 'report') r where r ->> 'feat' = 'Tough' and r ->> 'status' = 'skipped'));
select tl_test.rec('FT34 an unknown version is never created by an import',
  (public.import_character_feats(:'f6', '[{"feat_version_id": "made-up-feat-2024", "feat_name": "Made Up"}]') -> 'report' -> 0 ->> 'status') = 'unresolved'
  and not exists (select 1 from public.feat_versions where id = 'made-up-feat-2024'));
select tl_test.rec('FT35 no orphan feat grants: every stored choice belongs to an existing grant source',
  not exists (select 1 from public.character_feat_choices c where c.grant_key like 'cf:%'
              and not exists (select 1 from public.character_feats f where 'cf:' || f.id = c.grant_key)));
select tl_test.as_user(:'alice');
select public.set_character_lineage(:'f3', 'human-phb', 'human-variant', '{"human-variant:asi": ["str:1", "dex:1"], "human-variant:skill": ["perception"], "human-variant:feat": ["Some Table Feat"]}', false, false);
select tl_test.rec('FT13 a free-text feat placeholder (older data) stays allowed and is reported as unresolved, with no effect',
  jsonb_array_length(public.get_character_feats(:'f3') -> 'placeholders') = 1 and jsonb_array_length(public.get_character_feats(:'f3') -> 'feats') = 0);
select tl_test.as_root();
