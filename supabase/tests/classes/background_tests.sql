-- =============================================================================
-- Versioned backgrounds (20261017001200, docs/BACKGROUNDS.md): catalog separation of 2024 and legacy versions, 2024 ability
-- increases (+2/+1 or +1/+1/+1, listed abilities only, capped at 20 after the lineage, compatibility mode), proficiency grants
-- as their own source (never manual rows), choices and their rules, duplicates and replacements, Expertise on a background
-- skill, playtest permission, equipment review / apply once, removal keeps the inventory, RLS.
-- =============================================================================
\set b1 f1b00000-0000-0000-0000-000000000001
\set b2 f1b00000-0000-0000-0000-000000000002
\set b3 f1b00000-0000-0000-0000-000000000003
\set b4 f1b00000-0000-0000-0000-000000000004
insert into public.characters (id, owner_id, name, campaign_id, strength, dexterity, constitution, intelligence, wisdom, charisma) values
  (:'b1', :'alice', 'Background Soldier', :'camp', 15, 12, 14, 10, 10, 8),
  (:'b2', :'alice', 'Background Strong', null, 19, 10, 18, 10, 10, 10),
  (:'b3', :'alice', 'Background Rogue', null, 10, 16, 12, 12, 10, 10),
  (:'b4', :'alice', 'Background Legacy', null, 10, 14, 12, 10, 12, 10);
create function tl_test.bg(p_char uuid) returns jsonb language sql as $$ select public.get_character_background(p_char) $$;
create function tl_test.setbg(p_char uuid, p_version text, p_ability jsonb default null, p_choices jsonb default '{}', p_repl jsonb default '[]',
                              p_options jsonb default '{}') returns jsonb language sql as $$
  select public.set_character_background(p_char, p_version, p_ability, p_choices, p_repl, p_options) $$;
create function tl_test.pe(p_char uuid, p_kind text, p_id text) returns jsonb language sql as $$
  select e from jsonb_array_elements(public.get_character_proficiencies(p_char) -> p_kind) e where e ->> 'id' = p_id $$;
create function tl_test.score(p_char uuid, p_ab text) returns int language sql as $$
  select (public.get_character_derived_stats(p_char) -> 'abilities' -> p_ab ->> 'score')::int $$;
grant all on all functions in schema tl_test to public;

select tl_test.rec('BG1 catalog: 30 versions (16 of 2024, 14 legacy); every 2024 version lists 3 abilities and an origin feat; legacy ones none',
  (select count(*) from public.background_versions) = 30 and (select count(*) from public.background_versions where ruleset = '2024') = 16
  and not exists (select 1 from public.background_versions v where v.ruleset = '2024'
                  and ((select count(*) from public.background_ability_options a where a.version_id = v.id) <> 3
                       or not exists (select 1 from public.background_feat_grants f join public.feat_versions ft on ft.id = f.feat_id   -- feat versions since 20261019000300
                                      where f.version_id = v.id and ft.category = 'origin')))
  and not exists (select 1 from public.background_ability_options a join public.background_versions v on v.id = a.version_id where v.legacy)
  and not exists (select 1 from public.background_feat_grants f join public.background_versions v on v.id = f.version_id
                  where v.legacy and v.status = 'official'));
select tl_test.rec('BG2 Rune Carver is Unearthed Arcana: playtest, DM permission, not enabled by default; Folk Hero records the requested "Fol Hero"',
  (select status = 'playtest' and dm_permission and not enabled_by_default from public.background_versions where id = 'rune-carver-ua')
  and (select requested_as from public.background_versions where id = 'folk-hero-phb') = 'Fol Hero');

select tl_test.as_user(:'alice');
select tl_test.setbg(:'b1', 'soldier-2024', '{"mode": "plus2_plus1", "allocation": {"str": 2, "con": 1}}', '{"tool": ["dice-set"]}');
select tl_test.rec('BG3 Soldier 2024 with +2 STR / +1 CON: STR 15 -> 17, CON 14 -> 15; the stored scores do not change',
  tl_test.score(:'b1', 'str') = 17 and tl_test.score(:'b1', 'con') = 15
  and (public.get_character_derived_stats(:'b1') -> 'abilities' -> 'str' ->> 'background_applied')::int = 2
  and (select strength from public.characters where id = :'b1') = 15);
select tl_test.rec('BG4 invalid allocations are refused: an ability not listed, +2 and +1 on the same ability, +1/+1/+1 in the +2/+1 mode',
  tl_test.raises(format('select tl_test.setbg(%L, ''soldier-2024'', ''{"mode": "plus2_plus1", "allocation": {"wis": 2, "str": 1}}'')', :'b1')) like '%can only increase%'
  and tl_test.raises(format('select tl_test.setbg(%L, ''soldier-2024'', ''{"mode": "plus2_plus1", "allocation": {"str": 2}}'')', :'b1')) like '%+2 for one%'
  and tl_test.raises(format('select tl_test.setbg(%L, ''soldier-2024'', ''{"mode": "plus2_plus1", "allocation": {"str": 1, "dex": 1, "con": 1}}'')', :'b1')) like '%+2 for one%'
  and tl_test.raises(format('select tl_test.setbg(%L, ''soldier-2024'', ''{"mode": "plus1_x3", "allocation": {"str": 2, "dex": 1}}'')', :'b1')) like '%each of the three%'
  and tl_test.raises(format('select tl_test.setbg(%L, ''urchin-phb'', ''{"mode": "plus1_x3", "allocation": {"str": 1, "dex": 1, "con": 1}}'')', :'b1')) like '%legacy background has no ability%'
  and tl_test.score(:'b1', 'str') = 17);
select tl_test.rec('BG5 background skills and the chosen tool are active with the background as source, without manual rows',
  (tl_test.pe(:'b1', 'skills', 'athletics') ->> 'effective')::boolean
  and (tl_test.pe(:'b1', 'skills', 'athletics') -> 'sources') @> '[{"kind": "background", "label": "Soldier"}]'::jsonb
  and not (tl_test.pe(:'b1', 'skills', 'athletics') ->> 'manual')::boolean
  and (tl_test.pe(:'b1', 'tools', 'dice-set') -> 'sources') @> '[{"kind": "background", "label": "Soldier"}]'::jsonb
  and (select count(*) from public.character_proficiencies where character_id = :'b1') = 0
  and (select skill_proficiencies from public.characters where id = :'b1') = '{}'::jsonb);
select tl_test.give(:'b1', 'dice-set') \gset ds_
select tl_test.rec('BG6 a carried tool counts as proficient through the background (derived tools list)',
  exists (select 1 from jsonb_array_elements(public.get_character_derived_stats(:'b1') -> 'tools') t
          where t ->> 'item_id' = 'dice-set' and (t ->> 'proficient')::boolean));
select tl_test.rec('BG7 the read model: 2024 ruleset, source, origin feat (informational, with its source), no open choices, equipment packages A and B',
  tl_test.bg(:'b1') ->> 'ruleset' = '2024' and tl_test.bg(:'b1') -> 'source' ->> 'label' = 'Player''s Handbook (2024)'
  and tl_test.bg(:'b1') -> 'feat' ->> 'name' = 'Savage Attacker' and tl_test.bg(:'b1') -> 'feat' ->> 'automation' = 'informational'
  and (tl_test.bg(:'b1') ->> 'open_choices')::int = 0
  and (select array_agg(e ->> 'key' order by e ->> 'key') from jsonb_array_elements(tl_test.bg(:'b1') -> 'equipment') e) = '{A,B}');

select tl_test.setbg(:'b2', 'soldier-2024', '{"mode": "plus2_plus1", "allocation": {"str": 2, "con": 1}}', '{}');
select tl_test.rec('BG8 the increase stops at 20 (STR 19 + 2 -> 20, CON 18 + 1 -> 19) and the read model says it was limited',
  tl_test.score(:'b2', 'str') = 20 and tl_test.score(:'b2', 'con') = 19
  and (tl_test.bg(:'b2') -> 'warnings') @> '[{"code": "ability_capped", "ability": "str"}]'::jsonb
  and (tl_test.bg(:'b2') ->> 'open_choices')::int = 1);
select tl_test.setbg(:'b2', 'soldier-2024', '{"mode": "plus2_plus1", "allocation": {"str": 2, "con": 1}}', '{}', '[]', '{"bonuses_included": true}');
select tl_test.rec('BG9 "my stored scores already include it": no double counting, allocation kept, compatibility mode shown',
  tl_test.score(:'b2', 'str') = 19 and (tl_test.bg(:'b2') -> 'ability' ->> 'compatibility_mode')::boolean
  and tl_test.bg(:'b2') -> 'ability' -> 'allocation' = '{"str": 2, "con": 1}'::jsonb);

-- changing and removing the background removes only its contribution
select public.set_character_proficiency(:'b1', null, 'longsword', true, 'Manual test row');
update public.characters set skill_proficiencies = '{"athletics": 1}' where id = :'b1';
select tl_test.setbg(:'b1', 'criminal-2024', '{"mode": "plus1_x3", "allocation": {"dex": 1, "con": 1, "int": 1}}', '{}');
select tl_test.rec('BG10 switching to Criminal: Soldier skills and STR +2 are gone (manual Athletics stays), Criminal skills and thieves'' tools arrive',
  tl_test.score(:'b1', 'str') = 15 and tl_test.score(:'b1', 'dex') = 13
  and (tl_test.pe(:'b1', 'skills', 'athletics') -> 'sources') = '[{"kind": "manual", "label": "Manual", "detail": null}]'::jsonb
  and not (tl_test.pe(:'b1', 'skills', 'intimidation') ->> 'effective')::boolean
  and (tl_test.pe(:'b1', 'skills', 'stealth') -> 'sources') @> '[{"kind": "background", "label": "Criminal"}]'::jsonb
  and (tl_test.pe(:'b1', 'tools', 'thieves-tools') ->> 'effective')::boolean and tl_test.pe(:'b1', 'tools', 'dice-set') is null,
  (tl_test.pe(:'b1', 'skills', 'athletics'))::text);
select public.clear_character_background(:'b1');
select tl_test.rec('BG11 removing the background removes its increases and grants only (manual longsword and Athletics stay)',
  tl_test.score(:'b1', 'dex') = 12 and not (tl_test.pe(:'b1', 'skills', 'stealth') ->> 'effective')::boolean
  and (tl_test.pe(:'b1', 'skills', 'athletics') ->> 'effective')::boolean and (tl_test.pe(:'b1', 'items', 'longsword') ->> 'effective')::boolean
  and not (tl_test.bg(:'b1') ->> 'selected')::boolean);

-- legacy versions
select tl_test.setbg(:'b4', 'urchin-phb');
select tl_test.rec('BG12 legacy Urchin: no ability increases, skills and both tools from the background, City Secrets as an informational feature,'
  || ' personality / ideal / bond / flaw tables',
  tl_test.score(:'b4', 'dex') = 14 and (tl_test.pe(:'b4', 'skills', 'sleight_of_hand') ->> 'effective')::boolean
  and (tl_test.pe(:'b4', 'tools', 'disguise-kit') ->> 'effective')::boolean and (tl_test.pe(:'b4', 'tools', 'thieves-tools') ->> 'effective')::boolean
  and tl_test.bg(:'b4') -> 'features' @> '[{"name": "City Secrets", "automation": "informational"}]'::jsonb
  and (select count(*) from jsonb_array_elements(tl_test.bg(:'b4') -> 'characteristic_tables') t where t ->> 'kind' <> 'special') = 4
  and tl_test.bg(:'b4') -> 'feat' = 'null'::jsonb);
select tl_test.setbg(:'b4', 'haunted-one-vrgr', null, '{"skills": ["arcana", "religion"], "languages": ["dwarvish", "elvish"]}');
select tl_test.rec('BG13 choice rules: Haunted One needs one exotic language (warning), options outside the list are refused',
  (tl_test.bg(:'b4') -> 'warnings') @> '[{"code": "choice_rule", "choice": "languages"}]'::jsonb
  and tl_test.raises(format('select tl_test.setbg(%L, ''haunted-one-vrgr'', null, ''{"skills": ["athletics"]}'')', :'b4')) like '%not one of the options%'
  and tl_test.raises(format('select tl_test.setbg(%L, ''haunted-one-vrgr'', null, ''{"skills": ["arcana", "religion", "survival"]}'')', :'b4')) like '%at most 2%');
select tl_test.setbg(:'b4', 'haunted-one-vrgr', null, '{"skills": ["arcana", "religion"], "languages": ["dwarvish", "infernal"]}');
select tl_test.rec('BG14 with an exotic language the rule is met; the languages show the background as source',
  not (tl_test.bg(:'b4') -> 'warnings') @> '[{"code": "choice_rule"}]'::jsonb
  and (tl_test.pe(:'b4', 'languages', 'infernal') -> 'sources') @> '[{"kind": "background", "label": "Haunted One"}]'::jsonb);
select tl_test.rec('BG15 Rune Carver (playtest) needs the DM''s permission; with it the read model warns',
  tl_test.raises(format('select tl_test.setbg(%L, ''rune-carver-ua'')', :'b4')) like '%confirm that your DM allows it%'
  and (select (tl_test.setbg(:'b4', 'rune-carver-ua', null, '{}', '[]', '{"allow_playtest": true}') -> 'warnings') @> '[{"code": "dm_permission"}]'::jsonb)
  and (tl_test.pe(:'b4', 'languages', 'giant') ->> 'effective')::boolean);
select tl_test.setbg(:'b4', 'guild-merchant-phb', null, '{"trade": ["tool:navigators-tools"], "language": ["elvish"]}');
select tl_test.rec('BG16 Guild Merchant variant: navigator''s tools or a language (mixed choice); the variant is linked to Guild Artisan',
  (tl_test.pe(:'b4', 'tools', 'navigators-tools') ->> 'effective')::boolean
  and (select variant_of from public.background_versions where id = 'guild-merchant-phb') = 'guild-artisan-phb');

-- duplicates, replacement and Expertise
select tl_test.setc(:'b3', 'rogue-phb', 1);
select tl_test.choose(:'b3', 'rogue', 'rogue-phb-u1-proficiencies', 'rogue-proficiencies-phb-skills', '{stealth,perception,acrobatics,deception}');
select tl_test.setbg(:'b3', 'criminal-2024', '{"mode": "plus2_plus1", "allocation": {"dex": 2, "int": 1}}');
select tl_test.rec('BG17 a duplicate grant (Stealth from Rogue and Criminal) is reported with the ruleset''s rule; both sources stay listed',
  (tl_test.bg(:'b3') -> 'warnings') @> '[{"code": "duplicate_grant"}]'::jsonb
  and (tl_test.pe(:'b3', 'skills', 'stealth') -> 'sources') @> '[{"kind": "background"}, {"kind": "class"}]'::jsonb);
select tl_test.setbg(:'b3', 'criminal-2024', '{"mode": "plus2_plus1", "allocation": {"dex": 2, "int": 1}}', '{}',
                     '[{"kind": "skill", "original": "stealth", "replacement": "investigation"}]');
select tl_test.rec('BG18 the duplicate can be replaced (Stealth -> Investigation); Stealth still comes from the Rogue',
  (tl_test.pe(:'b3', 'skills', 'investigation') -> 'sources') @> '[{"kind": "background", "label": "Criminal"}]'::jsonb
  and not (tl_test.pe(:'b3', 'skills', 'stealth') -> 'sources') @> '[{"kind": "background"}]'::jsonb
  and (tl_test.pe(:'b3', 'skills', 'stealth') ->> 'effective')::boolean
  and tl_test.raises(format('select tl_test.setbg(%L, ''criminal-2024'', null, ''{}'', ''[{"kind": "skill", "original": "history", "replacement": "arcana"}]'')', :'b3'))
      like '%is not a skill this background gives%');
select tl_test.choose(:'b3', 'rogue', 'rogue-phb-u1-expertise', 'rogue-expertise-phb-expertise', '{sleight_of_hand,investigation}');
select tl_test.rec('BG19 Expertise can be taken in a background skill (Sleight of Hand, Investigation): level 2',
  (tl_test.pe(:'b3', 'skills', 'sleight_of_hand') ->> 'level')::int = 2 and (tl_test.pe(:'b3', 'skills', 'investigation') ->> 'level')::int = 2);

-- equipment: review, apply once, removal never deletes items
select tl_test.setbg(:'b1', 'soldier-2024', '{"mode": "plus2_plus1", "allocation": {"str": 2, "con": 1}}', '{"tool": ["playing-card-set"]}');
select tl_test.rec('BG20 equipment review: package A lists spear, shortbow, 20 arrows, the chosen gaming set; package B is 50 gp',
  (select bool_and(e ->> 'status' = 'resolved') from jsonb_array_elements(public.preview_background_equipment(:'b1', 'A') -> 'entries') e)
  and exists (select 1 from jsonb_array_elements(public.preview_background_equipment(:'b1', 'A') -> 'entries') e where e ->> 'item_id' = 'playing-card-set')
  and public.preview_background_equipment(:'b1', 'B') -> 'coins' = '{"gp": 50}'::jsonb);
select (select gp from public.characters where id = :'b1') as gp_before \gset
select public.apply_background_equipment(:'b1', 'A');
select tl_test.rec('BG21 applying package A adds the items once and 14 gp; a second application is refused',
  (select count(*) from public.inventory_items ii join public.inventories i on i.id = ii.inventory_id
   where i.character_id = :'b1' and ii.item_id in ('spear', 'shortbow', 'arrows', 'playing-card-set', 'healers-kit', 'quiver', 'travelers-clothes')) = 7
  and (select gp from public.characters where id = :'b1') = :'gp_before'::int + 14
  and tl_test.raises(format('select public.apply_background_equipment(%L, ''B'')', :'b1')) like '%already added%');
select public.clear_character_background(:'b1');
select tl_test.rec('BG22 removing the background keeps the equipment in the inventory and says so',
  exists (select 1 from public.inventory_items ii join public.inventories i on i.id = ii.inventory_id where i.character_id = :'b1' and ii.item_id = 'spear')
  and tl_test.bg(:'b1') ->> 'note' like '%stays in the inventory%');
select tl_test.setbg(:'b4', 'wayfarer-2024', '{"mode": "plus1_x3", "allocation": {"dex": 1, "wis": 1, "cha": 1}}');
select tl_test.rec('BG23 a "pick any" entry (Wayfarer: gaming set) must be picked from its category',
  tl_test.raises(format('select public.apply_background_equipment(%L, ''A'')', :'b4')) like '%pick one of the listed items%'
  and (select (public.apply_background_equipment(:'b4', 'A', '{"3": "dragonchess-set"}') ->> 'added')::int) = 6);

-- security
select tl_test.as_user(:'bob');
select tl_test.rec('BG24 another user can neither read nor set the background',
  tl_test.raises(format('select public.get_character_background(%L)', :'b3')) like '%not found%'
  and tl_test.raises(format('select tl_test.setbg(%L, ''sage-2024'')', :'b3')) like '%not found%');
select tl_test.as_user(:'alice');
select tl_test.rec('BG25 direct writes are blocked (character background rows and the catalog)',
  tl_test.raises(format('insert into public.character_backgrounds (character_id, version_id) values (%L, ''sage-2024'')', :'b1')) like '%permission denied%'
  and tl_test.raises(format('update public.character_backgrounds set ability_allocation = ''{"str": 9}'' where character_id = %L', :'b3')) like '%permission denied%'
  and tl_test.raises('update public.background_versions set status = ''official'' where id = ''rune-carver-ua''') like '%permission denied%');
select tl_test.as_user(:'dm');
select tl_test.rec('BG26 the campaign DM can read a campaign character''s background',
  (tl_test.bg(:'b1') ->> 'selected') is not null);
