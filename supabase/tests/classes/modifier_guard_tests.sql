-- =============================================================================
-- Modifier guard (20261114001100, review finding M1 of R-E2): a direct insert / delete of an inventory_item_modifiers row is
-- allowed only on a managed path (inventory RPCs, crafting, infusions), by the DM of the item's campaign or an admin.
-- The player's REST insert of an official modifier and REST delete are refused; the DM can do both; split / transfer / merge of
-- a stack with a modifier, deleting the item or the character (cascade) and the JSON import keep working.
-- Runs inside the per-class harness (alice = player of :camp, bob = no campaign role here, dm = DM of :camp).
-- Infusions: artificer_tests; enhancement crafting: weapon_enhancement_tests.
-- =============================================================================
\set mga f6e10000-0000-0000-0000-0000000000a1
\set mgb f6e10000-0000-0000-0000-0000000000b1
\set mgs f6e10000-0000-0000-0000-0000000000a2
insert into public.characters (id, owner_id, name, campaign_id, level, strength, dexterity, constitution, intelligence, wisdom, charisma, hp_max, hp_current, speed) values
  (:'mga', :'alice', 'Guard A', :'camp', 3, 16, 12, 12, 10, 10, 10, 24, 24, 30),
  (:'mgs', :'alice', 'Guard Spare', :'camp', 3, 16, 12, 12, 10, 10, 10, 24, 24, 30),
  (:'mgb', :'bob', 'Guard Solo', null, 3, 16, 12, 12, 10, 10, 10, 24, 24, 30);
set constraints all immediate;
create function tl_test.g_msg(p_sql text) returns text language plpgsql as $$
begin execute p_sql; return 'ok'; exception when others then return sqlstate || ' ' || sqlerrm; end $$;
create function tl_test.g_mods(p_row uuid) returns text language sql security definer as $$
  select coalesce(string_agg(modifier_id, ',' order by modifier_id), '') from public.inventory_item_modifiers where inventory_item_id = p_row $$;
create function tl_test.g_ins(p_row uuid, p_mod text) returns text language sql as $$
  select tl_test.g_msg(format('insert into public.inventory_item_modifiers (inventory_item_id, modifier_id) values (%L, %L)', p_row, p_mod)) $$;
create function tl_test.g_del(p_row uuid) returns text language sql as $$
  select tl_test.g_msg(format('delete from public.inventory_item_modifiers where inventory_item_id = %L', p_row)) $$;
create function tl_test.g_attack(p_char uuid, p_row uuid) returns int language sql as $$
  select (w ->> 'attack_bonus')::int from jsonb_array_elements(public.get_character_derived_stats(p_char) -> 'equipped_weapon_attacks') w
  where w ->> 'inventory_item_id' = p_row::text $$;
grant all on all functions in schema tl_test to public;

-- ---- the player (REST role authenticated, own campaign character) --------------------------------------------------------------
select tl_test.as_user(:'alice');
select tl_test.give(:'mga', 'mace', 'main_hand') as mace \gset
select tl_test.g_attack(:'mga', :'mace') as atk0 \gset
select tl_test.g_ins(:'mace', 'weapon-plus-3') as p_ins \gset
select tl_test.rec('MG1 a player''s direct insert of an official modifier (weapon-plus-3) on an own item is refused (42501)',
  :'p_ins' like '42501 %not directly%' and tl_test.g_mods(:'mace') = '', :'p_ins');
select tl_test.rec('MG2 the refused insert leaves the attack bonus unchanged', tl_test.g_attack(:'mga', :'mace') = :atk0);

-- ---- the DM attaches and removes directly ---------------------------------------------------------------------------------------
select tl_test.as_user(:'dm');
select tl_test.rec('MG3 the campaign DM attaches an official modifier directly', tl_test.g_ins(:'mace', 'weapon-plus-1') = 'ok' and tl_test.g_mods(:'mace') = 'weapon-plus-1');
select tl_test.as_user(:'alice');
select tl_test.rec('MG4 the DM-given modifier counts for the player (+1 attack)', tl_test.g_attack(:'mga', :'mace') = :atk0 + 1);
select tl_test.g_del(:'mace') as p_del \gset
select tl_test.rec('MG5 a player''s direct delete of a modifier row on an own item is refused (42501)',
  :'p_del' like '42501 %' and tl_test.g_mods(:'mace') = 'weapon-plus-1', :'p_del');
select tl_test.as_user(:'dm');
select tl_test.rec('MG6 the campaign DM removes the modifier directly', tl_test.g_del(:'mace') = 'ok' and tl_test.g_mods(:'mace') = '');
select tl_test.rec('MG7 the DM''s direct changes are logged (apply_modifier / remove_modifier)',
  (select count(*) filter (where action = 'apply_modifier') >= 1 and count(*) filter (where action = 'remove_modifier') >= 1
   from public.inventory_events where inventory_item_id = :'mace'));
-- bob is the DM of no campaign here: not the item's DM
select tl_test.as_user(:'bob');
select tl_test.rec('MG8 another user cannot insert either (RLS or the guard)', tl_test.g_ins(:'mace', 'weapon-plus-1') <> 'ok');

-- ---- an item without a campaign: no DM, only the managed paths ---------------------------------------------------------------
select tl_test.give(:'mgb', 'mace') as solo \gset
select tl_test.g_ins(:'solo', 'weapon-plus-1') as solo_ins \gset
select tl_test.rec('MG9 the owner of a character outside any campaign cannot attach a modifier directly', :'solo_ins' like '42501 %', :'solo_ins');
select tl_test.as_root();
insert into public.inventory_item_modifiers (inventory_item_id, modifier_id) values (:'solo', 'weapon-plus-1');
select tl_test.as_user(:'bob');
select tl_test.g_del(:'solo') as solo_del \gset
select tl_test.rec('MG10 ... nor remove one (maintenance as postgres stays possible)', :'solo_del' like '42501 %' and tl_test.g_mods(:'solo') = 'weapon-plus-1', :'solo_del');

-- ---- managed paths keep working for the player: split, transfer, merge, delete, character delete, import --------------------
select tl_test.as_user(:'alice');
select tl_test.give(:'mga', 'dagger', null, 4) as dg \gset
select tl_test.as_user(:'dm');
select tl_test.g_ins(:'dg', 'weapon-plus-1') as dm_ins \gset
select tl_test.as_user(:'alice');
select public.split_inventory_stack(:'dg', 1) as dg_split \gset
select tl_test.rec('MG11 a player splits a stack with a modifier (the copy keeps it)', :'dm_ins' = 'ok' and tl_test.g_mods(:'dg_split') = 'weapon-plus-1'
  and (select quantity from public.inventory_items where id = :'dg') = 3);
select public.merge_inventory_stacks(:'dg', :'dg_split') as dg_merged \gset
select tl_test.rec('MG12 a player merges the stacks back (the merged row''s modifier rows go with it)',
  (select quantity from public.inventory_items where id = :'dg') = 4 and not exists (select 1 from public.inventory_items where id = :'dg_split')
  and tl_test.g_mods(:'dg') = 'weapon-plus-1');
select tl_test.g_msg(format('select public.transfer_inventory_item(%L, %L, 2)', :'dg', tl_test.inv(:'mgs'))) as tr \gset
select tl_test.rec('MG13 a player transfers part of the stack to another own character (the moved part keeps the modifier)', :'tr' = 'ok'
  and exists (select 1 from public.inventory_items ii where ii.inventory_id = tl_test.inv(:'mgs') and ii.item_id = 'dagger' and ii.quantity = 2
              and tl_test.g_mods(ii.id) = 'weapon-plus-1')
  and (select quantity from public.inventory_items where id = :'dg') = 2, :'tr');
select tl_test.g_msg(format('select public.transfer_inventory_item(%L, %L, null)', :'dg', tl_test.inv(:'mgs'))) as tr2 \gset
select tl_test.rec('MG14 a player transfers the whole rest of the stack (auto-merge on arrival deletes the moved row)', :'tr2' = 'ok'
  and not exists (select 1 from public.inventory_items where id = :'dg' and inventory_id = tl_test.inv(:'mga')), :'tr2');
select ii.id as dg_b from public.inventory_items ii where ii.inventory_id = tl_test.inv(:'mgs') and ii.item_id = 'dagger' order by ii.quantity desc limit 1 \gset
select tl_test.g_msg(format('select public.remove_inventory_item(%L, null)', :'dg_b')) as rm \gset
select tl_test.rec('MG15 a player removes an own item that carries a modifier (RPC)', :'rm' = 'ok' and not exists (select 1 from public.inventory_items where id = :'dg_b'), :'rm');
-- the item row itself has no client DELETE grant (unchanged): items leave through remove_inventory_item (MG15)
select tl_test.g_msg(format('delete from public.inventory_items where id = %L', :'mace')) as rest_del \gset
select tl_test.rec('MG16 a REST delete of an item row stays not granted (42501 permission denied, unchanged)',
  :'rest_del' like '42501 permission denied%' and exists (select 1 from public.inventory_items where id = :'mace'), :'rest_del');
select tl_test.give(:'mgs', 'mace') as smace \gset
select tl_test.as_user(:'dm');
select tl_test.g_ins(:'smace', 'weapon-plus-1') as dm_ins3 \gset
select tl_test.as_user(:'alice');
select tl_test.g_msg(format('delete from public.characters where id = %L', :'mgs')) as ch_del \gset
select tl_test.rec('MG17 a player deletes an own character holding a modified item (cascade)', :'dm_ins3' = 'ok' and :'ch_del' = 'ok'
  and not exists (select 1 from public.characters where id = :'mgs'), :'ch_del');
select tl_test.g_msg(format('select public.import_inventory_items(%L, %L::jsonb)', :'mga', '[{"name": "Longsword", "quantity": 1}, {"name": "Guard Trinket", "quantity": 2}]')) as imp \gset
select tl_test.rec('MG18 the JSON import of inventory items keeps working for the player', :'imp' = 'ok', :'imp');
