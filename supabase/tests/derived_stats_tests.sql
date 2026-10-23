-- =============================================================================
-- Derived character stats tests (migration 20261015001400). Same harness as inventory_tests.sql: one transaction,
-- rolled back at the end; PASSED / FAILED per check; any FAILED check ends with an error.
-- Needs the reference seed and supabase/seed/item_effects.sql (the runner pipes that file in first; it is idempotent).
-- Synthetic fixtures only.
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
create function tl_test.ac(p_char uuid) returns int language sql as $$ select (public.get_character_derived_stats(p_char) -> 'armor_class' ->> 'value')::int $$;
create function tl_test.has_warning(p_char uuid, p_code text) returns boolean language sql as $$
  select exists (select 1 from jsonb_array_elements(public.get_character_derived_stats(p_char) -> 'warnings') w where w ->> 'code' = p_code) $$;
create function tl_test.weapon(p_char uuid, p_row uuid) returns jsonb language sql as $$
  select w from jsonb_array_elements(public.get_character_derived_stats(p_char) -> 'equipped_weapon_attacks') w
  where (w ->> 'inventory_item_id')::uuid = p_row $$;
create function tl_test.add(p_inv uuid, p_item text) returns uuid language sql as $$ select public.add_inventory_item(p_inv, p_item, 1) $$;
grant all on all functions in schema tl_test to public;
grant all on tl_test.results to public;
grant all on sequence tl_test.results_n_seq to public;

-- ---- fixtures -----------------------------------------------------------------------------------------------------
insert into auth.users (id, email) values
  ('a1111111-1111-1111-1111-111111111111', 'alice@test'), ('b2222222-2222-2222-2222-222222222222', 'bob@test'),
  ('d3333333-3333-3333-3333-333333333333', 'dm@test'),    ('c4444444-4444-4444-4444-444444444444', 'carol@test');
insert into public.campaigns (id, name, created_by) values ('cccccccc-0000-0000-0000-000000000001', 'Derived Test Campaign', 'd3333333-3333-3333-3333-333333333333');
insert into public.campaign_members (campaign_id, user_id, role) values
  ('cccccccc-0000-0000-0000-000000000001', 'a1111111-1111-1111-1111-111111111111', 'player'),
  ('cccccccc-0000-0000-0000-000000000001', 'b2222222-2222-2222-2222-222222222222', 'player'),
  ('cccccccc-0000-0000-0000-000000000001', 'd3333333-3333-3333-3333-333333333333', 'dm');
-- Since 20261019000100 only DMs author mechanical content: the homebrew author of this suite (alice) DMs a campaign of her own.
insert into public.campaigns (id, name, created_by) values ('cccccccc-0000-0000-0000-0000000000a1', 'Alice Authoring', 'a1111111-1111-1111-1111-111111111111');
insert into public.campaign_members (campaign_id, user_id, role) values ('cccccccc-0000-0000-0000-0000000000a1', 'a1111111-1111-1111-1111-111111111111', 'dm');
-- A: proficient (level 5 -> PB 3, STR 16, DEX 14); B: not proficient (level 1 -> PB 2, STR 12, DEX 14)
insert into public.characters (id, owner_id, name, campaign_id, level, strength, dexterity, speed) values
  ('aaaaaaaa-0000-0000-0000-00000000000a', 'a1111111-1111-1111-1111-111111111111', 'Proficient Hero', 'cccccccc-0000-0000-0000-000000000001', 5, 16, 14, 30),
  ('bbbbbbbb-0000-0000-0000-00000000000b', 'a1111111-1111-1111-1111-111111111111', 'Untrained Hero',  'cccccccc-0000-0000-0000-000000000001', 1, 12, 14, 30);
select 'aaaaaaaa-0000-0000-0000-00000000000a'::uuid as ca, 'bbbbbbbb-0000-0000-0000-00000000000b'::uuid as cb,
       'a1111111-1111-1111-1111-111111111111'::uuid as alice, 'b2222222-2222-2222-2222-222222222222'::uuid as bob,
       'd3333333-3333-3333-3333-333333333333'::uuid as dm, 'c4444444-4444-4444-4444-444444444444'::uuid as carol \gset
select id as inv_a from public.inventories where character_id = :'ca' \gset
select id as inv_b from public.inventories where character_id = :'cb' \gset

select tl_test.as_user(:'alice');
select public.set_character_proficiency(:'ca', g) from unnest(array['light-armor', 'medium-armor', 'heavy-armor', 'shields', 'simple-weapons', 'martial-weapons']) g;
select tl_test.add(:'inv_a', 'leather') as a_leather, tl_test.add(:'inv_a', 'half-plate') as a_halfplate, tl_test.add(:'inv_a', 'plate') as a_plate,
       tl_test.add(:'inv_a', 'shield') as a_shield, tl_test.add(:'inv_a', 'longsword') as a_longsword, tl_test.add(:'inv_a', 'rapier') as a_rapier,
       tl_test.add(:'inv_a', 'ring-of-protection') as a_ring, tl_test.add(:'inv_a', 'chain-mail') as a_chain \gset
select tl_test.add(:'inv_b', 'chain-mail') as b_chain, tl_test.add(:'inv_b', 'hide') as b_hide, tl_test.add(:'inv_b', 'shield') as b_shield,
       tl_test.add(:'inv_b', 'longsword') as b_longsword, tl_test.add(:'inv_b', 'ring-of-protection') as b_ring,
       tl_test.add(:'inv_b', 'bracers-of-defense') as b_bracers \gset

-- =============================================================================
-- Armor Class
-- =============================================================================
select tl_test.rec('D1 unarmored AC = 10 + DEX modifier (DEX 14 -> 12)',
  tl_test.ac(:'ca') = 12 and tl_test.d(:'ca') -> 'armor_class' ->> 'base_formula' = 'unarmored', tl_test.d(:'ca') ->> 'armor_class');
select public.equip_item(:'a_leather', 'armor');
select tl_test.rec('D2 light armor uses the full DEX modifier (Leather 11 + 2 = 13)',
  tl_test.ac(:'ca') = 13 and tl_test.d(:'ca') -> 'armor_class' ->> 'base_formula' = 'light_armor');
select tl_test.as_root(); update public.characters set dexterity = 18 where id = :'ca'; select tl_test.as_user(:'alice');
select public.equip_item(:'a_halfplate', 'armor', true);
select tl_test.rec('D3 medium armor caps DEX at +2 (Half Plate 15, DEX 18 -> +2 = 17)',
  tl_test.ac(:'ca') = 17 and exists (select 1 from jsonb_array_elements(tl_test.d(:'ca') -> 'armor_class' -> 'breakdown') p
                                     where p ->> 'effect' = 'ability_modifier' and (p ->> 'value')::int = 2 and (p ->> 'modifier')::int = 4 and (p ->> 'cap')::int = 2),
  tl_test.d(:'ca') ->> 'armor_class');
select tl_test.as_root(); update public.characters set dexterity = 8 where id = :'cb'; select tl_test.as_user(:'alice');
select tl_test.rec('D4a negative DEX lowers unarmored AC (DEX 8 -> 9)', tl_test.ac(:'cb') = 9);
select public.equip_item(:'b_hide', 'armor');
select tl_test.rec('D4b negative DEX is not raised to 0 by medium armor (Hide 12 - 1 = 11)', tl_test.ac(:'cb') = 11);
select public.unequip_item(:'b_hide');
select public.equip_item(:'a_plate', 'armor', true);
select tl_test.rec('D5 heavy armor ignores DEX (Plate 18 with DEX 18)',
  tl_test.ac(:'ca') = 18 and tl_test.d(:'ca') -> 'armor_class' ->> 'base_formula' = 'heavy_armor'
  and exists (select 1 from jsonb_array_elements(tl_test.d(:'ca') -> 'armor_class' -> 'breakdown') p
              where p ->> 'effect' = 'ability_modifier' and not (p ->> 'applied')::boolean and (p ->> 'value')::int = 0));
select public.equip_item(:'a_shield', 'shield');
select tl_test.rec('D6 a shield adds its AC bonus (18 + 2 = 20)', tl_test.ac(:'ca') = 20);
select tl_test.rec('D7 the shield does not replace the armor formula (heavy_armor, base 18 from Plate, shield as ac_bonus)',
  tl_test.d(:'ca') -> 'armor_class' ->> 'base_formula' = 'heavy_armor'
  and (select count(*) = 1 from jsonb_array_elements(tl_test.d(:'ca') -> 'armor_class' -> 'breakdown') p where p ->> 'effect' = 'base_ac')
  and exists (select 1 from jsonb_array_elements(tl_test.d(:'ca') -> 'armor_class' -> 'breakdown') p
              where p ->> 'source_type' = 'shield' and p ->> 'effect' = 'ac_bonus' and (p ->> 'value')::int = 2));
select tl_test.as_root();
insert into public.inventory_item_modifiers (inventory_item_id, modifier_id) values (:'a_plate', 'armor-plus-1');
select tl_test.as_user(:'alice');
select tl_test.rec('D8 magic armor (+1 modifier on the worn plate) applies (21)', tl_test.ac(:'ca') = 21);
select tl_test.as_root();
insert into public.inventory_item_modifiers (inventory_item_id, modifier_id) values (:'a_shield', 'shield-plus-1');
select tl_test.as_user(:'alice');
select tl_test.rec('D9 magic shield (+1 modifier) applies (22)', tl_test.ac(:'ca') = 22);
select public.equip_item(:'a_ring', 'ring_1');
select tl_test.rec('D11 an equipped but unattuned Ring of Protection does not apply (still 22, listed as not_attuned)',
  tl_test.ac(:'ca') = 22 and exists (select 1 from jsonb_array_elements(tl_test.d(:'ca') -> 'armor_class' -> 'inactive_effects') e
                                     where e ->> 'item_id' = 'ring-of-protection' and e ->> 'inactive_reason' = 'not_attuned'));
select public.attune_item(:'a_ring');
select tl_test.rec('D10 equipped + attuned Ring of Protection adds +1 AC and +1 to every save (23)',
  tl_test.ac(:'ca') = 23 and (tl_test.d(:'ca') -> 'saving_throws' -> 'wis' ->> 'item_bonus')::int = 1);
select public.attune_item(:'b_ring');
select tl_test.rec('D12 an owned + attuned but unequipped ring does not apply (B stays 9, reason not_equipped)',
  tl_test.ac(:'cb') = 9 and exists (select 1 from jsonb_array_elements(tl_test.d(:'cb') -> 'armor_class' -> 'inactive_effects') e
                                    where e ->> 'item_id' = 'ring-of-protection' and e ->> 'inactive_reason' = 'not_equipped'));
select public.unattune_item(:'a_ring');
select tl_test.rec('D10b unattuning removes the ring''s effect (22)', tl_test.ac(:'ca') = 22);
select public.unequip_item(:'a_shield');
select tl_test.rec('D14 unequipping the shield removes its bonus and its +1 modifier (22 - 3 = 19)', tl_test.ac(:'ca') = 19);
select public.unequip_item(:'a_plate');
select tl_test.rec('D13 unequipping the armor restores the unarmored formula (10 + 4 = 14)',
  tl_test.ac(:'ca') = 14 and tl_test.d(:'ca') -> 'armor_class' ->> 'base_formula' = 'unarmored');
-- historical data: rows written before the projection trigger existed can still say equipped = true
select tl_test.as_root();
alter table public.inventory_items disable trigger inventory_items_before_write;
update public.inventory_items set equipped = true where id = :'a_chain';
insert into public.inventory_items (inventory_id, character_id, name, quantity, weight, equipped)
values (:'inv_a', :'ca', 'Old Plate Armor', 1, 65, true);
alter table public.inventory_items enable trigger inventory_items_before_write;
select tl_test.as_user(:'alice');
select tl_test.rec('D15 only character_equipment counts (equipped flag on an unequipped Chain Mail row changes nothing)', tl_test.ac(:'ca') = 14);
select tl_test.rec('D16 a legacy free-text row flagged equipped does not affect AC (warning legacy_equipped_ignored)',
  tl_test.ac(:'ca') = 14 and tl_test.has_warning(:'ca', 'legacy_equipped_ignored'));
select public.equip_item(:'b_bracers', 'hands');
select public.attune_item(:'b_bracers');
select tl_test.rec('D36 Bracers of Defense (attuned, no armor, no shield) add +2 (9 -> 11)', tl_test.ac(:'cb') = 11);
select public.equip_item(:'b_shield', 'shield');
select tl_test.rec('D37 Bracers stop working with a shield (condition no_shield): 9 + 2 shield = 11, bracers inactive',
  tl_test.ac(:'cb') = 11 and exists (select 1 from jsonb_array_elements(tl_test.d(:'cb') -> 'armor_class' -> 'inactive_effects') e
                                     where e ->> 'item_id' = 'bracers-of-defense' and e ->> 'inactive_reason' = 'using_shield'));
select public.unequip_item(:'b_shield');
select public.unattune_item(:'b_bracers');
select public.unequip_item(:'b_bracers');

-- =============================================================================
-- Proficiency consequences, Strength requirement, Stealth
-- =============================================================================
select public.equip_item(:'b_chain', 'armor');
select tl_test.rec('D17 non-proficient armor still sets AC (Chain Mail 16 for B)', tl_test.ac(:'cb') = 16);
select tl_test.rec('D18 non-proficient armor exposes structured penalties',
  (tl_test.d(:'cb') -> 'armor_consequences' ->> 'nonproficient_armor')::boolean
  and tl_test.d(:'cb') -> 'armor_consequences' -> 'ability_check_disadvantage' = '["str","dex"]'
  and tl_test.d(:'cb') -> 'armor_consequences' -> 'saving_throw_disadvantage' = '["str","dex"]'
  and tl_test.d(:'cb') -> 'armor_consequences' -> 'attack_disadvantage' = '["str","dex"]'
  and (tl_test.d(:'cb') -> 'armor_consequences' ->> 'spellcasting_restricted')::boolean
  and (tl_test.d(:'cb') -> 'saving_throws' -> 'dex' ->> 'disadvantage')::boolean
  and not (tl_test.d(:'cb') -> 'saving_throws' -> 'wis' ->> 'disadvantage')::boolean
  and exists (select 1 from jsonb_array_elements(tl_test.d(:'cb') -> 'warnings') w
              where w ->> 'code' = 'nonproficient_armor' and w ->> 'missing_group_id' = 'heavy-armor' and (w ->> 'source_id')::uuid = :'b_chain'),
  tl_test.d(:'cb') ->> 'armor_consequences');
select tl_test.rec('D19 armor with stealth disadvantage is reported with its source',
  (tl_test.d(:'cb') -> 'armor_consequences' ->> 'stealth_disadvantage')::boolean
  and (tl_test.d(:'cb') -> 'skills' -> 'stealth' ->> 'disadvantage')::boolean
  and (tl_test.d(:'cb') -> 'armor_consequences' -> 'stealth_sources' -> 0 ->> 'source_id')::uuid = :'b_chain');
select tl_test.rec('D21 unmet Strength requirement (13 vs 12): warning and speed 30 -> 20, stored speed unchanged',
  (tl_test.d(:'cb') -> 'armor_consequences' ->> 'strength_requirement_unmet')::boolean
  and (tl_test.d(:'cb') -> 'speed' ->> 'value')::int = 20 and (tl_test.d(:'cb') -> 'speed' ->> 'base')::int = 30
  and (select speed = 30 from public.characters where id = :'cb')
  and exists (select 1 from jsonb_array_elements(tl_test.d(:'cb') -> 'warnings') w
              where w ->> 'code' = 'strength_requirement_unmet' and (w ->> 'required')::int = 13 and (w ->> 'current')::int = 12));
select tl_test.as_root(); update public.characters set strength = 13 where id = :'cb'; select tl_test.as_user(:'alice');
select tl_test.rec('D22 met Strength requirement removes the warning and the speed penalty',
  not (tl_test.d(:'cb') -> 'armor_consequences' ->> 'strength_requirement_unmet')::boolean
  and (tl_test.d(:'cb') -> 'speed' ->> 'value')::int = 30 and not tl_test.has_warning(:'cb', 'strength_requirement_unmet'));
select public.unequip_item(:'b_chain');
select tl_test.rec('D20 unequipping the armor removes Stealth disadvantage and the armor warnings',
  not (tl_test.d(:'cb') -> 'armor_consequences' ->> 'stealth_disadvantage')::boolean
  and not tl_test.has_warning(:'cb', 'nonproficient_armor') and not tl_test.has_warning(:'cb', 'spellcasting_restricted'));
select public.equip_item(:'b_shield', 'shield');
select tl_test.rec('D18b a shield without shield proficiency is reported separately',
  tl_test.has_warning(:'cb', 'nonproficient_shield') and not tl_test.has_warning(:'cb', 'nonproficient_armor')
  and (tl_test.d(:'cb') -> 'armor_consequences' ->> 'nonproficient_shield')::boolean);
select public.unequip_item(:'b_shield');

-- =============================================================================
-- Weapons
-- =============================================================================
select public.equip_item(:'a_longsword', 'main_hand');
select tl_test.rec('D23 proficient weapon adds the proficiency bonus (STR +3, PB +3 -> +6; 1d8 + 3)',
  (tl_test.weapon(:'ca', :'a_longsword') ->> 'attack_bonus')::int = 6 and (tl_test.weapon(:'ca', :'a_longsword') ->> 'proficient')::boolean
  and tl_test.weapon(:'ca', :'a_longsword') ->> 'damage' = '1d8 + 3', tl_test.weapon(:'ca', :'a_longsword')::text);
select tl_test.rec('D28 group proficiency matches (martial-weapons)',
  tl_test.weapon(:'ca', :'a_longsword') -> 'proficiency' ->> 'matched_by' = 'group'
  and tl_test.weapon(:'ca', :'a_longsword') -> 'proficiency' ->> 'group_id' = 'martial-weapons');
select public.equip_item(:'b_longsword', 'main_hand');
select tl_test.rec('D24 non-proficient weapon omits the proficiency bonus (B: STR +1, no PB -> +1)',
  (tl_test.weapon(:'cb', :'b_longsword') ->> 'attack_bonus')::int = 1
  and not (tl_test.weapon(:'cb', :'b_longsword') ->> 'proficiency_bonus_applied')::boolean
  and tl_test.has_warning(:'cb', 'nonproficient_weapon'));
select tl_test.rec('D25 missing proficiency does not remove the ability modifier from damage (1d8 + 1)',
  tl_test.weapon(:'cb', :'b_longsword') ->> 'damage' = '1d8 + 1');
select public.equip_item(:'a_rapier', 'main_hand', true);
select tl_test.rec('D26 finesse uses the better of STR and DEX (DEX +4 > STR +3 -> +4 + 3 = +7)',
  tl_test.weapon(:'ca', :'a_rapier') ->> 'ability' = 'dex' and tl_test.weapon(:'ca', :'a_rapier') ->> 'ability_rule' = 'finesse_best'
  and (tl_test.weapon(:'ca', :'a_rapier') ->> 'attack_bonus')::int = 7);
select tl_test.as_root();
insert into public.inventory_item_modifiers (inventory_item_id, modifier_id) values (:'a_rapier', 'weapon-plus-1');
select tl_test.as_user(:'alice');
select tl_test.rec('D38 a +1 weapon adds +1 to its own attack and damage (+8, 1d8 + 5)',
  (tl_test.weapon(:'ca', :'a_rapier') ->> 'attack_bonus')::int = 8 and tl_test.weapon(:'ca', :'a_rapier') ->> 'damage' = '1d8 + 5');
select public.set_character_proficiency(:'cb', null, 'longsword');
select tl_test.rec('D27/D30 a specific-item proficiency (Longsword) makes B proficient: +1 + 2 = +3',
  (tl_test.weapon(:'cb', :'b_longsword') ->> 'attack_bonus')::int = 3
  and tl_test.weapon(:'cb', :'b_longsword') -> 'proficiency' ->> 'matched_by' = 'item' and not tl_test.has_warning(:'cb', 'nonproficient_weapon'));
select public.set_character_proficiency(:'cb', null, 'longsword', false);
select tl_test.rec('D30b removing the proficiency changes the result back (+1)', (tl_test.weapon(:'cb', :'b_longsword') ->> 'attack_bonus')::int = 1);
select public.equip_item(:'b_chain', 'armor');
select tl_test.rec('D39 non-proficient armor marks STR/DEX weapon attacks with disadvantage',
  (tl_test.weapon(:'cb', :'b_longsword') ->> 'attack_disadvantage')::boolean);
select public.unequip_item(:'b_chain');

-- =============================================================================
-- Tools, effects, override, mirror
-- =============================================================================
select tl_test.add(:'inv_b', 'thieves-tools') as b_tools \gset
select tl_test.rec('D29 a tool can be owned without proficiency; listed as not proficient, no warning',
  :'b_tools' is not null and exists (select 1 from jsonb_array_elements(tl_test.d(:'cb') -> 'tools') t where t ->> 'item_id' = 'thieves-tools' and not (t ->> 'proficient')::boolean)
  and not exists (select 1 from jsonb_array_elements(tl_test.d(:'cb') -> 'warnings') w where w ->> 'item_id' = 'thieves-tools'));
select public.set_character_proficiency(:'cb', null, 'thieves-tools');
select tl_test.rec('D29b tool proficiency is informational (proficient = true)',
  exists (select 1 from jsonb_array_elements(tl_test.d(:'cb') -> 'tools') t where t ->> 'item_id' = 'thieves-tools' and (t ->> 'proficient')::boolean));
select tl_test.rec('D40 the sheet flags mirror character_proficiencies (A has light/medium/heavy/shields/simple/martial)',
  (select equipment_proficiencies = '{"heavy": true, "light": true, "medium": true, "simple": true, "martial": true, "shields": true}'::jsonb
   from public.characters where id = :'ca'));
update public.characters set equipment_proficiencies = equipment_proficiencies || '{"firearms": true}' where id = :'cb';
select tl_test.rec('D41 a write to the old flags (old client / import) creates the proficiency row',
  exists (select 1 from public.character_proficiencies where character_id = :'cb' and group_id = 'firearms'));
update public.characters set ac_override = 25 where id = :'cb';
select tl_test.rec('D42 a manual AC override is explicit: active 25, calculated still shown',
  tl_test.ac(:'cb') = 25 and (tl_test.d(:'cb') -> 'armor_class' ->> 'calculated')::int = 9 and tl_test.d(:'cb') -> 'armor_class' ->> 'source' = 'override');
update public.characters set ac_override = null where id = :'cb';
select tl_test.as_root();
update public.characters set strength = 8 where id = :'cb';
select tl_test.as_user(:'alice');
select tl_test.add(:'inv_b', 'gauntlets-of-ogre-power') as b_gauntlets \gset
select public.equip_item(:'b_gauntlets', 'hands');
select public.attune_item(:'b_gauntlets');
select public.equip_item(:'b_chain', 'armor');
select tl_test.rec('D43 Gauntlets of Ogre Power set STR to 19, which meets the Chain Mail requirement (no speed penalty)',
  (tl_test.d(:'cb') -> 'abilities' -> 'str' ->> 'score')::int = 19 and (tl_test.d(:'cb') -> 'abilities' -> 'str' ->> 'base')::int = 8
  and not (tl_test.d(:'cb') -> 'armor_consequences' ->> 'strength_requirement_unmet')::boolean);
select public.unequip_item(:'b_chain');

-- homebrew armor uses the same typed calculation
select public.create_homebrew_item('77777777-7777-7777-7777-777777777777',
  '{"name":"Derived Test Scale","kind_id":"armor","category_id":"medium-armor"}', '{"armor":{"base_ac":14,"stealth_disadvantage":true}}') as hb \gset
select tl_test.add(:'inv_b', 'hb-77777777-7777-7777-7777-777777777777') as b_hb \gset
select public.equip_item(:'b_hb', 'armor');
select tl_test.rec('D34 homebrew medium armor: base 14 + DEX (-1, capped mode) = 13, formula medium_armor',
  tl_test.ac(:'cb') = 13 and tl_test.d(:'cb') -> 'armor_class' ->> 'base_formula' = 'medium_armor', tl_test.d(:'cb') ->> 'armor_class');
select public.unequip_item(:'b_hb');

-- =============================================================================
-- Security
-- =============================================================================
select tl_test.as_user(:'bob');
select tl_test.rec('D31a another player cannot modify the character''s proficiencies (RPC)',
  tl_test.raises(format('select public.set_character_proficiency(%L, %L)', :'ca', 'firearms')) like '%Character not found%');
select tl_test.rec('D31b direct writes to character_proficiencies are refused (no write grant)',
  tl_test.raises(format('insert into public.character_proficiencies (character_id, proficiency_type, group_id) values (%L, ''weapon'', ''firearms'')', :'ca')) is not null
  and tl_test.raises(format('delete from public.character_proficiencies where character_id = %L', :'ca')) is not null);
select tl_test.rec('D33a another player cannot read the derived stats',
  tl_test.raises(format('select public.get_character_derived_stats(%L)', :'ca')) like '%Character not found%');
select tl_test.as_user(:'carol');
select tl_test.rec('D33b an outsider cannot read the derived stats or the proficiency rows',
  tl_test.raises(format('select public.get_character_derived_stats(%L)', :'ca')) like '%Character not found%'
  and not exists (select 1 from public.character_proficiencies where character_id = :'ca'));
select tl_test.as_user(:'dm');
select tl_test.rec('D32a the campaign DM reads the derived stats', tl_test.ac(:'ca') = 14);
select tl_test.rec('D32b the campaign DM may change proficiencies (same rule as editing the character)',
  (public.set_character_proficiency(:'ca', 'firearms') ->> 'changed')::boolean);
select tl_test.rec('D33c the DM does not see the player''s private homebrew, so its effects are hidden too',
  not exists (select 1 from public.items where id = 'hb-77777777-7777-7777-7777-777777777777'));
select tl_test.as_user(:'alice');
select tl_test.rec('D35a invalid proficiency targets are rejected (unknown group, non-equipment item, both set)',
  tl_test.raises(format('select public.set_character_proficiency(%L, %L)', :'ca', 'bogus-group')) like '%Unknown proficiency group%'
  and tl_test.raises(format('select public.set_character_proficiency(%L, null, %L)', :'ca', 'potion-of-healing-common')) like '%only applies%'
  and tl_test.raises(format('select public.set_character_proficiency(%L, %L, %L)', :'ca', 'firearms', 'longsword')) like '%either%');
select tl_test.rec('D35b clients cannot write item_effects', tl_test.raises('insert into public.item_effects (item_id, effect_type, value, activation) values (''club'', ''ac_bonus'', 5, ''owned'')') is not null);
select tl_test.as_root();
select tl_test.rec('D35c invalid effect types, targets, activation and conditions are rejected',
  tl_test.raises('insert into public.item_effects (item_id, seq, effect_type, value, activation) values (''club'', 1, ''fly'', 1, ''owned'')') is not null
  and tl_test.raises('insert into public.item_effects (item_id, seq, effect_type, value, target, activation) values (''club'', 1, ''save_bonus'', 1, ''luck'', ''owned'')') like '%Unknown saving throw%'
  and tl_test.raises('insert into public.item_effects (item_id, seq, effect_type, value, target, activation) values (''club'', 1, ''ac_bonus'', 1, ''dex'', ''owned'')') like '%takes no target%'
  and tl_test.raises('insert into public.item_effects (item_id, seq, effect_type, value, target, activation) values (''club'', 1, ''resistance'', null, ''lava'', ''owned'')') like '%Unknown damage type%'
  and tl_test.raises('insert into public.item_effects (item_id, seq, effect_type, value, activation) values (''ring-of-protection'', 9, ''ac_bonus'', 1, ''equipped'')') like '%requires attunement%'
  and tl_test.raises('insert into public.item_effects (item_id, seq, effect_type, value, activation, conditions) values (''club'', 1, ''ac_bonus'', 1, ''owned'', ''{"in_rain": true}'')') like '%Unknown effect condition%');
select md5(c::text) as row_before from public.characters c where id = :'ca' \gset
select tl_test.as_user(:'alice');
select tl_test.d(:'ca');
select tl_test.as_root();
select tl_test.rec('D44 the derived-stats function never mutates the character (row unchanged; STABLE, SECURITY INVOKER)',
  (select md5(c::text) = :'row_before' from public.characters c where id = :'ca')
  and (select provolatile = 's' and not prosecdef from pg_proc where proname = 'get_character_derived_stats'));
select tl_test.rec('D45 SECURITY DEFINER functions of this feature pin search_path',
  not exists (select 1 from pg_proc p where p.proname in ('set_character_proficiency', '_proficiency_type_of_item', 'character_proficiencies_before_write',
              '_equipment_proficiency_flags', 'character_proficiencies_sync_flags', 'characters_sync_proficiency_rows')
              and p.prosecdef and not exists (select 1 from unnest(p.proconfig) c where c like 'search_path=%')));
delete from public.characters where id = :'cb';
select tl_test.rec('D46 deleting a character removes its proficiencies (and the mirror trigger copes)',
  not exists (select 1 from public.character_proficiencies where character_id = :'cb'));

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
