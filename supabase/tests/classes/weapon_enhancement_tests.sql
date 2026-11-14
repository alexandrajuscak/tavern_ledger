-- =============================================================================
-- Weapon enhancement (20261114001000, docs/CRAFTING_V1.md "Weapon enhancement"): the DM's campaign modifiers, enhancement recipes
-- (one BASE line, kept, quantity 1), the same inventory row enhanced (id, knowledge, equipped state kept), the modifier in the
-- derived stats with its numbers, masking for a disguised copy (labels, REST), the unidentified base refused, a failure keeps the
-- base, the direct REST attach refused, and the review follow-ups m3 (no natural roll without a check) and m4 (recipe items are
-- campaign items only).
-- Runs inside the per-class harness (alice = player of :camp, bob = DM of another campaign here, dm = DM of :camp).
-- =============================================================================
\set ea f6e00000-0000-0000-0000-0000000000a1
\set camp2 f6e00000-0000-0000-0000-0000000000c2
insert into public.characters (id, owner_id, name, campaign_id, level, strength, dexterity, constitution, intelligence, wisdom, charisma, hp_max, hp_current, speed) values
  (:'ea', :'alice', 'Smith E', :'camp', 3, 16, 12, 12, 10, 10, 10, 24, 24, 30);
insert into public.campaigns (id, name, created_by) values (:'camp2', 'Other Enh Campaign', :'bob');
insert into public.campaign_members (campaign_id, user_id, role) values (:'camp2', :'bob', 'dm');
set constraints all immediate;                    -- the grant sync flushes at commit; this file is ONE transaction
create function tl_test.e_msg(p_sql text) returns text language plpgsql as $$
begin execute p_sql; return 'ok'; exception when others then return sqlstate || ' ' || sqlerrm; end $$;
create function tl_test.e_rows(p_char uuid, p_item text) returns uuid[] language sql security definer as $$
  select coalesce(array_agg(ii.id order by ii.created_at, ii.id), '{}') from public.inventory_items ii join public.inventories inv on inv.id = ii.inventory_id
  where inv.character_id = p_char and ii.item_id = p_item $$;
create function tl_test.e_qty(p_char uuid, p_item text) returns int language sql security definer as $$
  select coalesce(sum(ii.quantity), 0)::int from public.inventory_items ii join public.inventories inv on inv.id = ii.inventory_id
  where inv.character_id = p_char and ii.item_id = p_item $$;
create function tl_test.e_sel(p_seq int, p_row uuid, p_qty int) returns jsonb language sql as $$
  select jsonb_build_object('seq', p_seq, 'inventory_item_id', p_row, 'quantity', p_qty) $$;
create function tl_test.e_rec(p_read jsonb, p_recipe uuid) returns jsonb language sql as $$
  select r from jsonb_array_elements(p_read -> 'recipes') r where r ->> 'recipe_id' = p_recipe::text $$;
create function tl_test.e_w(p_d jsonb, p_row uuid) returns jsonb language sql as $$
  select w from jsonb_array_elements(p_d -> 'equipped_weapon_attacks') w where w ->> 'inventory_item_id' = p_row::text $$;
create function tl_test.e_has_mod(p_row uuid, p_mod text) returns boolean language sql security definer as $$
  select exists (select 1 from public.inventory_item_modifiers where inventory_item_id = p_row and modifier_id = p_mod) $$;
create function tl_test.e_locked(p_item text) returns boolean language sql as $$
  select exists (select 1 from pg_locks l where l.locktype = 'advisory' and l.pid = pg_backend_pid() and l.classid = 4242
                 and l.objid = (hashtext(p_item)::bigint & 4294967295)::oid and l.objsubid = 2 and l.granted) $$;
create function tl_test.e_pub(p_def jsonb) returns text language plpgsql as $$
declare c uuid;
begin
  c := (public.create_dm_content('item', 'c1c00000-0000-0000-0000-000000000001', p_def) ->> 'id')::uuid;
  perform public.publish_dm_content(c);
  return (select v.catalog_ref from public.dm_content x join public.dm_content_versions v on v.id = x.published_version_id where x.id = c);
end $$;
create function tl_test.e_fx(p_d jsonb, p_row uuid) returns text language sql as $$
  select string_agg(concat_ws(':', e ->> 'effect_type', e ->> 'value', e ->> 'applied'), ',' order by e ->> 'effect_type', e ->> 'value')
  from jsonb_array_elements(coalesce(p_d -> 'effects', '[]'::jsonb) || coalesce(p_d -> 'inactive_effects', '[]'::jsonb)) e
  where e ->> 'source_id' = p_row::text $$;
grant all on all functions in schema tl_test to public;

-- ---- fixtures (DM) ---------------------------------------------------------------------------------------------------------------
select tl_test.as_user(:'dm');
select public.set_campaign_governance(:'camp', '{"overrides": {"inventory.craft": "player_managed"}}');
select public.create_homebrew_item(gen_random_uuid(), jsonb_build_object('name', 'Rune Dust', 'kind_id', 'gear', 'campaign_id', :'camp', 'stackable', true)) ->> 'id' as dust \gset
select public.create_homebrew_item(gen_random_uuid(), jsonb_build_object('name', 'Smithing Manual', 'kind_id', 'gear', 'campaign_id', :'camp')) ->> 'id' as manual \gset
select tl_test.e_pub('{"name": "Rune Blade", "definition": {"item": {"kind_id": "weapon", "category_id": "martial-melee", "is_magic": false, "rarity_id": "common"},
  "stats": {"weapon": {"weapon_group": "martial", "damage_dice": "1d8", "damage_type_id": "slashing"}},
  "hidden": {"unidentified_name": "Plain blade", "unidentified_description": "A plain blade."}}}') as blade \gset
select public.dm_save_campaign_modifier(:'camp', jsonb_build_object('name', 'Flame Rune', 'description', 'SENTINEL-MODDESC glows', 'applies_to_kind_id', 'weapon',
  'rarity_id', 'uncommon', 'effects', jsonb_build_array(jsonb_build_object('type', 'attack_bonus', 'value', 1), jsonb_build_object('type', 'damage_bonus', 'value', 2),
  jsonb_build_object('type', 'custom', 'text', 'Sheds light')))) as modj \gset
select :'modj'::jsonb ->> 'id' as mod \gset
select public.dm_save_campaign_modifier(:'camp', jsonb_build_object('name', 'Armor Glyph', 'applies_to_kind_id', 'armor',
  'effects', jsonb_build_array(jsonb_build_object('type', 'ac_bonus', 'value', 1)))) ->> 'id' as amod \gset
-- r1: longsword (base, exact) + 2 Rune Dust, Smith's tools DC 10, the DM confirms
select public.dm_save_recipe(:'camp', jsonb_build_object('name', 'Flame Forging', 'kind', 'enhancement', 'enhance_modifier_id', :'mod',
  'dm_notes', 'SENTINEL-ENHNOTE', 'check_key', 'smiths-tools', 'check_dc', 10, 'failure_mode', 'lose_all',
  'ingredients', jsonb_build_array(jsonb_build_object('item_id', 'longsword', 'base', true), jsonb_build_object('item_id', :'dust', 'quantity', 2)),
  'teachers', jsonb_build_array(jsonb_build_object('item_id', :'manual')))) as r1j \gset
select :'r1j'::jsonb ->> 'id' as r1 \gset
select public.dm_set_recipe_status(:'r1', 'published');
-- r2: Rune Blade (base) + 1 Rune Dust, no check, automatic
select public.dm_save_recipe(:'camp', jsonb_build_object('name', 'Quick Rune', 'kind', 'enhancement', 'enhance_modifier_id', :'mod', 'requires_dm_approval', false,
  'ingredients', jsonb_build_array(jsonb_build_object('item_id', :'blade', 'base', true), jsonb_build_object('item_id', :'dust', 'quantity', 1)))) ->> 'id' as r2 \gset
select public.dm_set_recipe_status(:'r2', 'published');
-- r3: a dagger as the base (daggers stack)
select public.dm_save_recipe(:'camp', jsonb_build_object('name', 'Dagger Rune', 'kind', 'enhancement', 'enhance_modifier_id', :'mod', 'requires_dm_approval', false,
  'ingredients', jsonb_build_array(jsonb_build_object('item_id', 'dagger', 'base', true), jsonb_build_object('item_id', :'dust', 'quantity', 1)))) ->> 'id' as r3 \gset
select public.dm_set_recipe_status(:'r3', 'published');
select public.get_campaign_recipes(:'camp') as dmread \gset
select tl_test.as_root();
select tl_test.rec('E1 authoring: a campaign modifier (cm- id, 3 effects, owner = DM, campaign scoped) and an enhancement recipe (no result item, base line kept, quantity 1); the DM read lists the modifier and the recipe''s enhancement',
  :'mod' ~ '^cm-[0-9a-f]{10}$' and jsonb_array_length(:'modj'::jsonb -> 'effects') = 3
  and (select owner_id = :'dm' and campaign_id = :'camp' and managed_by is null and is_magic_override from public.item_modifiers where id = :'mod')
  and :'r1j'::jsonb ->> 'kind' = 'enhancement' and :'r1j'::jsonb ->> 'output_item_id' is null and :'r1j'::jsonb ->> 'enhance_modifier_name' = 'Flame Rune'
  and (select (g ->> 'base')::boolean and not (g ->> 'consumed')::boolean and (g ->> 'quantity')::int = 1
         from jsonb_array_elements(:'r1j'::jsonb -> 'ingredients') g where (g ->> 'seq')::int = 1)
  and exists (select 1 from jsonb_array_elements(:'dmread'::jsonb -> 'modifiers') m where m ->> 'id' = :'mod')
  and exists (select 1 from jsonb_array_elements(:'dmread'::jsonb -> 'modifiers') m where m ->> 'id' = :'amod'),
  left(:'r1j', 300));

-- ---- validation ------------------------------------------------------------------------------------------------------------------
select tl_test.as_user(:'bob');
select public.dm_save_campaign_modifier(:'camp2', '{"name": "Other Rune", "effects": [{"type": "attack_bonus", "value": 1}]}') ->> 'id' as omod \gset
select tl_test.as_user(:'dm');
create temp table e_v (k text, m text);
grant all on e_v to public;
insert into e_v select 'nobase', tl_test.e_msg(format('select public.dm_save_recipe(%L, %L)', :'camp', jsonb_build_object('name', 'X', 'kind', 'enhancement',
  'enhance_modifier_id', :'mod', 'ingredients', jsonb_build_array(jsonb_build_object('item_id', 'longsword', 'consumed', false)))));
insert into e_v select 'twobase', tl_test.e_msg(format('select public.dm_save_recipe(%L, %L)', :'camp', jsonb_build_object('name', 'X', 'kind', 'enhancement',
  'enhance_modifier_id', :'mod', 'ingredients', jsonb_build_array(jsonb_build_object('item_id', 'longsword', 'base', true), jsonb_build_object('item_id', 'dagger', 'base', true)))));
insert into e_v select 'consumed', tl_test.e_msg(format('select public.dm_save_recipe(%L, %L)', :'camp', jsonb_build_object('name', 'X', 'kind', 'enhancement',
  'enhance_modifier_id', :'mod', 'ingredients', jsonb_build_array(jsonb_build_object('item_id', 'longsword', 'base', true, 'consumed', true)))));
insert into e_v select 'qty2', tl_test.e_msg(format('select public.dm_save_recipe(%L, %L)', :'camp', jsonb_build_object('name', 'X', 'kind', 'enhancement',
  'enhance_modifier_id', :'mod', 'ingredients', jsonb_build_array(jsonb_build_object('item_id', 'longsword', 'base', true, 'quantity', 2)))));
insert into e_v select 'official', tl_test.e_msg(format('select public.dm_save_recipe(%L, %L)', :'camp', jsonb_build_object('name', 'X', 'kind', 'enhancement',
  'enhance_modifier_id', 'weapon-plus-1', 'ingredients', jsonb_build_array(jsonb_build_object('item_id', 'longsword', 'base', true)))));
insert into e_v select 'othercamp', tl_test.e_msg(format('select public.dm_save_recipe(%L, %L)', :'camp', jsonb_build_object('name', 'X', 'kind', 'enhancement',
  'enhance_modifier_id', :'omod', 'ingredients', jsonb_build_array(jsonb_build_object('item_id', 'longsword', 'base', true)))));
insert into e_v select 'output', tl_test.e_msg(format('select public.dm_save_recipe(%L, %L)', :'camp', jsonb_build_object('name', 'X', 'kind', 'enhancement',
  'enhance_modifier_id', :'mod', 'output_item_id', :'dust', 'ingredients', jsonb_build_array(jsonb_build_object('item_id', 'longsword', 'base', true)))));
insert into e_v select 'itembase', tl_test.e_msg(format('select public.dm_save_recipe(%L, %L)', :'camp', jsonb_build_object('name', 'X',
  'output_item_id', :'dust', 'ingredients', jsonb_build_array(jsonb_build_object('item_id', 'longsword', 'base', true)))));
insert into e_v select 'misfit', tl_test.e_msg(format('select public.dm_save_recipe(%L, %L)', :'camp', jsonb_build_object('name', 'X', 'kind', 'enhancement',
  'enhance_modifier_id', :'amod', 'ingredients', jsonb_build_array(jsonb_build_object('item_id', 'longsword', 'base', true)))));
insert into e_v select 'fx0', tl_test.e_msg(format('select public.dm_save_campaign_modifier(%L, %L)', :'camp', '{"name": "Z", "effects": [{"type": "attack_bonus", "value": 0}]}'));
insert into e_v select 'fxkind', tl_test.e_msg(format('select public.dm_save_campaign_modifier(%L, %L)', :'camp', '{"name": "Z", "effects": [{"type": "spell_attack_bonus", "value": 1}]}'));
insert into e_v select 'm4', tl_test.e_msg(format('select public.dm_save_recipe(%L, %L)', :'camp', jsonb_build_object('name', 'X', 'output_item_id', :'dust',
  'ingredients', jsonb_build_array(jsonb_build_object('item_id', :'dust')), 'teachers', jsonb_build_array(jsonb_build_object('item_id', 'book')))));
select tl_test.as_user(:'alice');
insert into e_v select 'player', tl_test.e_msg(format('select public.dm_save_campaign_modifier(%L, %L)', :'camp', '{"name": "Z"}'));
select tl_test.as_root();
select tl_test.rec('E2 validation (22023 each): no base, two bases, a used-up base, base quantity 2, an official modifier, another campaign''s modifier, a result item on an enhancement, a base on an item recipe, a modifier that does not fit the base, a 0 / unknown effect; a player cannot author (42501)',
  (select bool_and(m like '22023%') from e_v where k <> 'player' and k <> 'm4') and (select m like '42501%' from e_v where k = 'player'),
  (select string_agg(k || '=' || left(m, 60), ' | ') from e_v));
select tl_test.rec('E3 m4: an official catalog item as a recipe item is refused (22023); a campaign item is accepted (r1 manual)',
  (select m like '22023 A recipe item must be an item of this campaign%' from e_v where k = 'm4')
  and jsonb_array_length(:'r1j'::jsonb -> 'teachers') = 1,
  (select m from e_v where k = 'm4'));

-- ---- the player: read, start, refusals ---------------------------------------------------------------------------------------------
select tl_test.as_user(:'alice');
select tl_test.give(:'ea', 'longsword', 'main_hand') as sword \gset
select tl_test.give(:'ea', :'dust', null, 6) as dust_row \gset
select tl_test.give(:'ea', 'smiths-tools') as tools_row \gset
select tl_test.give(:'ea', 'dagger', null, 2) as daggers \gset
select public.get_character_derived_stats(:'ea') as d0 \gset
select public.get_character_recipes(:'ea') as p0 \gset
select tl_test.e_msg(format('select public.start_craft_attempt(%L, %L, %L::jsonb, null, gen_random_uuid(), %L)', :'ea', :'r3',
  jsonb_build_array(tl_test.e_sel(1, :'daggers', 1), tl_test.e_sel(2, :'dust_row', 1)), 'nat20')) as m3 \gset
select tl_test.e_msg(format('select public.start_craft_attempt(%L, %L, %L::jsonb, null, gen_random_uuid())', :'ea', :'r3',
  jsonb_build_array(tl_test.e_sel(1, :'daggers', 1), tl_test.e_sel(2, :'dust_row', 1)))) as stack \gset
select public.start_craft_attempt(:'ea', :'r1', jsonb_build_array(tl_test.e_sel(1, :'sword', 1), tl_test.e_sel(2, :'dust_row', 2)), 14, gen_random_uuid()) as att \gset
select tl_test.as_root();
select tl_test.rec('E4 player read: the result is the enhancement (name, effects), the base line is marked and offers the equipped longsword; no DM notes',
  tl_test.e_rec(:'p0'::jsonb, :'r1') -> 'output' ->> 'name' = 'Flame Rune' and (tl_test.e_rec(:'p0'::jsonb, :'r1') -> 'output' ->> 'enhancement')::boolean
  and jsonb_array_length(tl_test.e_rec(:'p0'::jsonb, :'r1') -> 'output' -> 'effects') = 3
  and tl_test.e_rec(:'p0'::jsonb, :'r1') ->> 'kind' = 'enhancement'
  and (select (g ->> 'base')::boolean and g -> 'candidates' -> 0 ->> 'inventory_item_id' = :'sword'
         from jsonb_array_elements(tl_test.e_rec(:'p0'::jsonb, :'r1') -> 'ingredients') g where (g ->> 'seq')::int = 1)
  and (tl_test.e_rec(:'p0'::jsonb, :'r1') ->> 'can_craft')::boolean
  and position('SENTINEL-ENHNOTE' in :'p0') = 0
  and jsonb_array_length((select g -> 'candidates' from jsonb_array_elements(tl_test.e_rec(:'p0'::jsonb, :'r3') -> 'ingredients') g where (g ->> 'seq')::int = 1)) = 0,
  left(tl_test.e_rec(:'p0'::jsonb, :'r1')::text, 300));
select tl_test.rec('E5 refusals: m3 a natural roll on a recipe without a check; a stack of 2 daggers as the base (split first)',
  :'m3' = '22023 This recipe has no roll' and :'stack' = '22023 Only a single item can be enhanced: split the stack first',
  concat_ws(' | ', :'m3', :'stack'));

-- ---- DM approves: the same row is enhanced ------------------------------------------------------------------------------------------
select tl_test.e_locked('longsword') as lock_before \gset
select tl_test.as_user(:'dm');
select public.dm_resolve_craft_attempt((:'att'::jsonb ->> 'attempt_id')::uuid, 'approve') as res \gset
select tl_test.as_user(:'alice');
select public.get_character_derived_stats(:'ea') as d1 \gset
select tl_test.as_root();
select tl_test.rec('E6 approval (roll 14 vs DC 10 -> success): the SAME row (id, quantity 1, still in the main hand) carries the enhancement; 2 Rune Dust used, the tools kept; the 4242 lock of the base item is held',
  :'res'::jsonb ->> 'status' = 'applied' and :'res'::jsonb ->> 'outcome' = 'success'
  and tl_test.e_rows(:'ea', 'longsword') = array[:'sword'::uuid] and tl_test.e_has_mod(:'sword', :'mod')
  and (select quantity = 1 from public.inventory_items where id = :'sword')
  and exists (select 1 from public.character_equipment where inventory_item_id = :'sword' and slot_id = 'main_hand')
  and not exists (select 1 from public.inventory_item_knowledge where inventory_item_id = :'sword')
  and tl_test.e_qty(:'ea', :'dust') = 4 and tl_test.e_qty(:'ea', 'smiths-tools') = 1
  and not :'lock_before'::boolean and tl_test.e_locked('longsword')
  and :'res'::jsonb -> 'produced_detail' -> 0 ->> 'inventory_item_id' = :'sword' and :'res'::jsonb -> 'produced' -> 0 ->> 'name' = 'Longsword (Flame Rune)',
  left(:'res', 300));
select tl_test.rec('E7 audit: one apply_modifier inventory event on the row with metadata.craft_attempt',
  (select count(*) from public.inventory_events e where e.inventory_item_id = :'sword' and e.action = 'apply_modifier'
     and e.metadata ->> 'craft_attempt' = :'att'::jsonb ->> 'attempt_id' and e.metadata ->> 'modifier_id' = :'mod') = 1);
select tl_test.rec('E8 derived stats: the longsword''s attack +1 and damage +2 higher, the effects labelled "Longsword (Flame Rune)"',
  (tl_test.e_w(:'d1'::jsonb, :'sword') ->> 'attack_bonus')::int = (tl_test.e_w(:'d0'::jsonb, :'sword') ->> 'attack_bonus')::int + 1
  and tl_test.e_w(:'d1'::jsonb, :'sword') ->> 'damage' <> tl_test.e_w(:'d0'::jsonb, :'sword') ->> 'damage'
  and exists (select 1 from jsonb_array_elements(:'d1'::jsonb -> 'effects') e where e ->> 'source_id' = :'sword' and e ->> 'source_name' = 'Longsword (Flame Rune)'
              and e ->> 'effect_type' = 'damage_bonus' and (e ->> 'value')::numeric = 2 and (e ->> 'applied')::boolean),
  concat_ws(' / ', tl_test.e_w(:'d0'::jsonb, :'sword')::text, tl_test.e_w(:'d1'::jsonb, :'sword')::text));

-- ---- a second sword: already enhanced is refused; a (critical) failure keeps the base -------------------------------------------
select tl_test.as_user(:'alice');
select tl_test.e_msg(format('select public.start_craft_attempt(%L, %L, %L::jsonb, 14, gen_random_uuid())', :'ea', :'r1',
  jsonb_build_array(tl_test.e_sel(1, :'sword', 1), tl_test.e_sel(2, :'dust_row', 2)))) as again \gset
select tl_test.give(:'ea', 'longsword') as sword2 \gset
select public.start_craft_attempt(:'ea', :'r1', jsonb_build_array(tl_test.e_sel(1, :'sword2', 1), tl_test.e_sel(2, :'dust_row', 2)), 3, gen_random_uuid(), 'nat1') as att2 \gset
select tl_test.as_user(:'dm');
select public.dm_resolve_craft_attempt((:'att2'::jsonb ->> 'attempt_id')::uuid, 'approve', 'critical_failure') as res2 \gset
select tl_test.as_root();
select tl_test.rec('E9 the enhanced sword cannot take the same enhancement again (22023); a critical failure uses up the dust but never the base: the second sword stays (quantity 1, no enhancement)',
  :'again' = '22023 This item already has that enhancement'
  and :'res2'::jsonb ->> 'status' = 'applied' and :'res2'::jsonb ->> 'outcome' = 'critical_failure'
  and tl_test.e_qty(:'ea', :'dust') = 2 and :'sword2'::uuid = any (tl_test.e_rows(:'ea', 'longsword'))
  and not tl_test.e_has_mod(:'sword2', :'mod') and (select quantity = 1 from public.inventory_items where id = :'sword2')
  and jsonb_array_length(:'res2'::jsonb -> 'produced_detail') = 0,
  concat_ws(' | ', :'again', left(:'res2', 200)));

-- ---- a disguised base is refused; an enhanced copy that becomes disguised is masked ------------------------------------------------
select tl_test.as_user(:'dm');
select public.dm_give_item(:'blade', array[:'ea']::uuid[], 1, false);
select tl_test.as_root();
select (tl_test.e_rows(:'ea', :'blade'))[1] as ublade \gset
select tl_test.as_user(:'alice');
select public.get_character_recipes(:'ea') as p1 \gset
select tl_test.e_msg(format('select public.start_craft_attempt(%L, %L, %L::jsonb, null, gen_random_uuid())', :'ea', :'r2',
  jsonb_build_array(tl_test.e_sel(1, :'ublade', 1), tl_test.e_sel(2, :'dust_row', 1)))) as unid \gset
select tl_test.as_root();
select tl_test.rec('E10 an unidentified base: not offered as a candidate and refused with the fixed ingredient text',
  :'unid' = '22023 You don''t know what this ingredient is yet'
  and jsonb_array_length((select g -> 'candidates' from jsonb_array_elements(tl_test.e_rec(:'p1'::jsonb, :'r2') -> 'ingredients') g where (g ->> 'seq')::int = 1)) = 0,
  :'unid');
select tl_test.as_user(:'dm');
select public.set_item_knowledge(:'ublade', 'identified');
select tl_test.as_user(:'alice');
select public.start_craft_attempt(:'ea', :'r2', jsonb_build_array(tl_test.e_sel(1, :'ublade', 1), tl_test.e_sel(2, :'dust_row', 1)), null, gen_random_uuid()) as att3 \gset
select public.unequip_item(:'sword');
select public.equip_item(:'ublade', 'main_hand', true);
select count(*) as rest_known from public.item_modifiers where id = :'mod' \gset
select tl_test.as_user(:'dm');
select public.set_item_knowledge(:'ublade', 'unidentified');
delete from public.inventory_item_modifiers where inventory_item_id = :'sword';   -- the DM takes the longsword's rune off (only the disguised copy keeps it)
select count(*) as dm_rest_mod from public.item_modifiers where id = :'mod' \gset
select public.get_character_derived_stats(:'ea')::text as dd \gset
select tl_test.as_user(:'alice');
select public.get_character_derived_stats(:'ea')::text as pd \gset
select count(*) as rest_mod from public.item_modifiers where id = :'mod' \gset
select count(*) as rest_fx from public.item_modifier_effects where modifier_id = :'mod' \gset
select tl_test.as_root();
select tl_test.rec('E11 auto craft on the identified blade: applied, the same row enhanced; the holder can read the modifier row (REST) while he knows the copy',
  :'att3'::jsonb ->> 'status' = 'applied' and tl_test.e_has_mod(:'ublade', :'mod') and :'rest_known'::int = 1, left(:'att3', 200));
select tl_test.rec('E12 the copy is disguised again: the player''s derived stats carry the disguise only (no modifier name, no modifier id, no description), the effect numbers equal the DM''s (the player has no attack card for a weapon whose catalog row he cannot read: R-D3, unchanged)',
  exists (select 1 from jsonb_array_elements(:'pd'::jsonb -> 'effects') e where e ->> 'source_id' = :'ublade' and e ->> 'source_name' = 'Plain blade'
          and e ->> 'modifier_id' is null and e ->> 'item_id' is null)
  and position('Flame' in :'pd') = 0 and position(:'mod' in :'pd') = 0 and position('Rune Blade' in :'pd') = 0
  and exists (select 1 from jsonb_array_elements(:'dd'::jsonb -> 'effects') e where e ->> 'source_id' = :'ublade' and e ->> 'source_name' = 'Rune Blade (Flame Rune)')
  and tl_test.e_fx(:'pd'::jsonb, :'ublade') = tl_test.e_fx(:'dd'::jsonb, :'ublade') and tl_test.e_fx(:'pd'::jsonb, :'ublade') like 'attack_bonus:1:true%',
  tl_test.e_fx(:'pd'::jsonb, :'ublade') || ' / ' || tl_test.e_fx(:'dd'::jsonb, :'ublade'));
select tl_test.rec('E13 REST: holding only the disguised copy, the player reads neither the modifier nor its effects; the DM reads it',
  :'rest_mod'::int = 0 and :'rest_fx'::int = 0 and :'dm_rest_mod'::int = 1, concat_ws(',', :'rest_mod', :'rest_fx', :'dm_rest_mod'));
select tl_test.as_user(:'alice');
select tl_test.e_msg(format('insert into public.inventory_item_modifiers (inventory_item_id, modifier_id) values (%L, %L)', :'sword2', :'mod')) as direct \gset
select tl_test.as_root();
select tl_test.rec('E14 a player cannot attach a campaign enhancement directly (42501)', :'direct' like '42501 This enhancement is attached by crafting%', :'direct');
