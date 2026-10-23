-- =============================================================================
-- Inventory / catalog / RLS tests. Run by supabase/tests/run_local.sh against a LOCAL, throwaway database
-- (after 01_expected_counts.sql). The whole script is one transaction that is rolled back at the end.
-- Each check prints PASSED or FAILED; any FAILED check makes the script exit with an error.
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
begin
  insert into tl_test.results (name, ok, detail) values (p_name, coalesce(p_ok, false), p_detail);
end $$;
-- runs a statement, returns the error message (or null when it succeeded)
create function tl_test.raises(p_sql text) returns text language plpgsql as $$
begin execute p_sql; return null; exception when others then return sqlerrm; end $$;
create function tl_test.as_user(p_uid uuid) returns void language plpgsql as $$
begin perform set_config('request.jwt.claim.sub', p_uid::text, true); perform set_config('role', 'authenticated', true); end $$;
create function tl_test.as_anon() returns void language plpgsql as $$
begin perform set_config('request.jwt.claim.sub', '', true); perform set_config('role', 'anon', true); end $$;
create function tl_test.as_root() returns void language plpgsql as $$
begin perform set_config('role', 'postgres', true); perform set_config('request.jwt.claim.sub', '', true); end $$;
grant all on all functions in schema tl_test to public;
grant all on tl_test.results to public;
grant all on sequence tl_test.results_n_seq to public;

-- ---- fixtures ---------------------------------------------------------------------------------------------------
insert into auth.users (id, email) values
  ('a1111111-1111-1111-1111-111111111111', 'alice@test'), ('b2222222-2222-2222-2222-222222222222', 'bob@test'),
  ('d3333333-3333-3333-3333-333333333333', 'dm@test'),    ('c4444444-4444-4444-4444-444444444444', 'carol@test'),
  ('e5555555-5555-5555-5555-555555555555', 'admin@test');
update public.profiles set role = 'admin' where email = 'admin@test';
insert into public.campaigns (id, name, created_by) values ('cccccccc-0000-0000-0000-000000000001', 'Test Campaign', 'd3333333-3333-3333-3333-333333333333');
insert into public.campaign_members (campaign_id, user_id, role) values
  ('cccccccc-0000-0000-0000-000000000001', 'a1111111-1111-1111-1111-111111111111', 'player'),
  ('cccccccc-0000-0000-0000-000000000001', 'b2222222-2222-2222-2222-222222222222', 'player'),
  ('cccccccc-0000-0000-0000-000000000001', 'd3333333-3333-3333-3333-333333333333', 'dm');
-- Since 20261019000100 only DMs author mechanical content (a private library needs DM rights in some campaign). The
-- homebrew authors of this suite (alice) therefore DM a one-person campaign of their own; nothing else changes for them.
insert into public.campaigns (id, name, created_by) values ('cccccccc-0000-0000-0000-0000000000a1', 'Alice Authoring', 'a1111111-1111-1111-1111-111111111111');
insert into public.campaign_members (campaign_id, user_id, role) values ('cccccccc-0000-0000-0000-0000000000a1', 'a1111111-1111-1111-1111-111111111111', 'dm');
insert into public.characters (id, owner_id, name, campaign_id) values
  ('aaaaaaaa-0000-0000-0000-00000000000a', 'a1111111-1111-1111-1111-111111111111', 'Alice Char', 'cccccccc-0000-0000-0000-000000000001'),
  ('bbbbbbbb-0000-0000-0000-00000000000b', 'b2222222-2222-2222-2222-222222222222', 'Bob Char',   'cccccccc-0000-0000-0000-000000000001'),
  ('cccccccc-0000-0000-0000-00000000000c', 'c4444444-4444-4444-4444-444444444444', 'Carol Char', null);
select id as inv_a from public.inventories where character_id = 'aaaaaaaa-0000-0000-0000-00000000000a' \gset
select id as inv_b from public.inventories where character_id = 'bbbbbbbb-0000-0000-0000-00000000000b' \gset
select id as inv_c from public.inventories where character_id = 'cccccccc-0000-0000-0000-00000000000c' \gset
select 'a1111111-1111-1111-1111-111111111111'::uuid as alice, 'b2222222-2222-2222-2222-222222222222'::uuid as bob,
       'd3333333-3333-3333-3333-333333333333'::uuid as dm, 'c4444444-4444-4444-4444-444444444444'::uuid as carol,
       'e5555555-5555-5555-5555-555555555555'::uuid as adm, 'f0000000-0000-0000-0000-000000000001'::uuid as legacy \gset
select id as scroll_id from public.items where kind_id = 'scroll' order by id limit 1 \gset
select id as ring_id from public.items where category_id = 'ring' and requires_attunement order by id limit 1 \gset
select id as at1 from public.items where kind_id = 'magic_item' and category_id = 'wondrous-item' and requires_attunement order by id limit 1 offset 0 \gset
select id as at2 from public.items where kind_id = 'magic_item' and category_id = 'wondrous-item' and requires_attunement order by id limit 1 offset 1 \gset
select id as at3 from public.items where kind_id = 'magic_item' and category_id = 'wondrous-item' and requires_attunement order by id limit 1 offset 2 \gset
select id as at4 from public.items where kind_id = 'magic_item' and category_id = 'wondrous-item' and requires_attunement order by id limit 1 offset 3 \gset

-- =============================================================================
-- A. Reference data (as superuser)
-- =============================================================================
select tl_test.rec('A1 item count per kind matches the normalized data',
  not exists (select 1 from expected_kind_counts e where e.n is distinct from (select count(*) from public.items i where i.kind_id = e.kind_id and i.owner_id is null))
  and (select count(*) from public.items where owner_id is null) = (select sum(n) from expected_kind_counts),
  (select string_agg(kind_id || '=' || (select count(*) from public.items i where i.kind_id = e.kind_id), ', ') from expected_kind_counts e));
select tl_test.rec('A2 no duplicate item ids', (select count(*) = count(distinct id) from public.items));
select tl_test.rec('A3 no orphan typed stats (every stats row has an item of the right kind)',
  not exists (select 1 from public.weapon_stats s left join public.items i on i.id = s.item_id and i.kind_id = 'weapon' where i.id is null)
  and not exists (select 1 from public.armor_stats s left join public.items i on i.id = s.item_id and i.kind_id = 'armor' where i.id is null)
  and not exists (select 1 from public.ammunition_stats s left join public.items i on i.id = s.item_id and i.kind_id = 'ammunition' where i.id is null)
  and not exists (select 1 from public.mount_stats s left join public.items i on i.id = s.item_id and i.kind_id = 'mount' where i.id is null)
  and not exists (select 1 from public.vehicle_stats s left join public.items i on i.id = s.item_id and i.kind_id = 'vehicle' where i.id is null)
  and not exists (select 1 from public.firearm_stats f left join public.weapon_stats w on w.item_id = f.item_id where w.item_id is null));
select tl_test.rec('A4 every mundane weapon/armor/mount/vehicle has its stats row',
  not exists (select 1 from public.items i where i.owner_id is null and not i.is_magic and (
     (i.kind_id = 'weapon' and not exists (select 1 from public.weapon_stats where item_id = i.id))
  or (i.kind_id = 'armor'  and not exists (select 1 from public.armor_stats where item_id = i.id))
  or (i.kind_id = 'mount'  and not exists (select 1 from public.mount_stats where item_id = i.id))
  or (i.kind_id = 'vehicle' and not exists (select 1 from public.vehicle_stats where item_id = i.id)))));
select tl_test.rec('A5 Net has a null damage type', (select damage_type_id is null and damage_dice is null from public.weapon_stats where item_id = 'net'));
select tl_test.rec('A6 shields are armor (no shield kind; every shield stats row is kind armor / category shield / is_shield)',
  not exists (select 1 from public.item_kinds where id = 'shield')
  and not exists (select 1 from public.items i where i.category_id = 'shield' and i.kind_id <> 'armor')
  and not exists (select 1 from public.armor_stats a join public.items i on i.id = a.item_id where a.is_shield <> (i.category_id = 'shield'))
  and (select is_shield and base_ac is null and ac_bonus = 2 from public.armor_stats where item_id = 'shield'));
select tl_test.rec('A7 firearms have weapon_stats and firearm_stats',
  (select count(*) from public.items where category_id = 'firearm') = 7
  and not exists (select 1 from public.items i where i.category_id = 'firearm'
                  and (not exists (select 1 from public.weapon_stats where item_id = i.id) or not exists (select 1 from public.firearm_stats where item_id = i.id))));
select tl_test.rec('A8 all potions are consumable and stackable',
  (select count(*) from public.items where kind_id = 'potion') = 46
  and not exists (select 1 from public.items where kind_id = 'potion' and not (is_consumable and stackable)));
select tl_test.rec('A9 all scrolls are consumable and stackable by default',
  (select count(*) from public.items where kind_id = 'scroll') = 9
  and not exists (select 1 from public.items where kind_id = 'scroll' and not (is_consumable and stackable)));
select tl_test.rec('A10 thrown weapons are stackable (and only they among mundane weapons)',
  (select count(*) from public.items i join public.weapon_property_links l on l.item_id = i.id and l.property_id = 'thrown' where i.stackable) = 9
  and not exists (select 1 from public.weapon_property_links l join public.items i on i.id = l.item_id where l.property_id = 'thrown' and not i.stackable)
  and not exists (select 1 from public.items i where i.kind_id = 'weapon' and not i.is_magic and i.stackable
                  and not exists (select 1 from public.weapon_property_links l where l.item_id = i.id and l.property_id = 'thrown')));
select tl_test.rec('A11 weapons with the ammunition property have compatible ammunition (only the documented Hoopak exception)',
  (select coalesce(string_agg(w.item_id, ','), '') from public.weapon_stats w
    join public.weapon_property_links l on l.item_id = w.item_id and l.property_id = 'ammunition'
    where not exists (select 1 from public.ammunition_stats a where a.ammo_type_id = w.ammo_type_id)) = 'hoopak',
  'weapons without compatible ammunition: ' || (select coalesce(string_agg(w.item_id, ','), '') from public.weapon_stats w
    join public.weapon_property_links l on l.item_id = w.item_id and l.property_id = 'ammunition'
    where not exists (select 1 from public.ammunition_stats a where a.ammo_type_id = w.ammo_type_id)));
select tl_test.rec('A12 cost_cp is derived from cost_value and cost_unit',
  not exists (select 1 from public.items i join public.currencies c on c.id = i.cost_unit where i.cost_cp is distinct from round(i.cost_value * c.conversion_to_cp)::bigint)
  and (select cost_cp from public.items where id = 'longsword') = 1500);
select tl_test.rec('A13 modifiers: 12 seeded, +N effects present (class infusion modifiers of the class catalog not counted)',
  (select count(*) from public.item_modifiers where id not like 'infusion-%') = 12
  and (select count(*) from public.item_modifier_effects where modifier_id not like 'infusion-%') = 18);
select tl_test.rec('A14 two-handed weapons exist in the data (glaive, greatsword...)',
  (select count(*) from public.weapon_property_links where property_id = 'two-handed') >= 10);

-- =============================================================================
-- B. Stacking, using, constraints (as Alice)
-- =============================================================================
select tl_test.as_user(:'alice');
select public.add_inventory_item(:'inv_a', 'javelin', 5) as jav \gset
select tl_test.rec('B1 identical thrown weapons form one stack', (select quantity = 5 from public.inventory_items where id = :'jav'));
select public.add_inventory_item(:'inv_a', 'javelin', 2) as jav2 \gset
select tl_test.rec('B2 adding more merges into the identical stack (same row)', :'jav2' = :'jav' and (select quantity = 7 from public.inventory_items where id = :'jav')
  and (select count(*) = 1 from public.inventory_items where inventory_id = :'inv_a' and item_id = 'javelin'));
select public.add_inventory_item(:'inv_a', 'javelin', 1, 'Lucky Javelin') as lucky \gset
select tl_test.rec('B3 a piece with a custom name is not merged', :'lucky' <> :'jav' and (select count(*) = 2 from public.inventory_items where inventory_id = :'inv_a' and item_id = 'javelin'));
select tl_test.rec('B4 stack_key differs between plain and renamed stacks',
  (select count(distinct stack_key) = 2 from public.inventory_items where inventory_id = :'inv_a' and item_id = 'javelin'));
select tl_test.rec('B5 quantity cannot be set below 1 (RPC) and the table is not writable directly',
  tl_test.raises(format('select public.set_inventory_item_quantity(%L, 0)', :'jav')) like '%at least 1%'
  and tl_test.raises(format('update public.inventory_items set quantity = 0 where id = %L', :'jav')) like '%permission denied%');
select tl_test.rec('B6 remove more than owned is rejected',
  tl_test.raises(format('select public.remove_inventory_item(%L, 99)', :'jav')) like '%Invalid quantity%');

-- potion: use until gone, never below zero
select public.add_inventory_item(:'inv_a', 'potion-of-healing-common', 2) as pot \gset
select public.use_inventory_item(:'pot', 1) as r1 \gset
select tl_test.rec('B7 using a potion decrements quantity and reports the result',
  (:'r1'::jsonb ->> 'consumed')::boolean and (:'r1'::jsonb ->> 'remaining')::int = 1 and not (:'r1'::jsonb ->> 'deleted')::boolean, :'r1');
select tl_test.rec('B8 using more than owned is rejected (quantity never < 0)',
  tl_test.raises(format('select public.use_inventory_item(%L, 2)', :'pot')) like '%Not enough items%'
  and (select quantity = 1 from public.inventory_items where id = :'pot'));
select public.use_inventory_item(:'pot', 1) as r2 \gset
select tl_test.rec('B9 using the last piece removes the row', (:'r2'::jsonb ->> 'deleted')::boolean and not exists (select 1 from public.inventory_items where id = :'pot'));
select tl_test.rec('B10 using it again fails (no double use)', tl_test.raises(format('select public.use_inventory_item(%L, 1)', :'pot')) like '%not found%');

-- scrolls
select public.add_inventory_item(:'inv_a', :'scroll_id', 2) as sc \gset
select public.add_inventory_item(:'inv_a', :'scroll_id', 1, null, null, '{"spell":"fireball","level":3}') as sc2 \gset
select tl_test.rec('B11 identical scrolls stack; a scroll with a different spell (state) does not', :'sc2' <> :'sc' and (select quantity = 2 from public.inventory_items where id = :'sc'));
select public.use_inventory_item(:'sc2', 1) as r3 \gset
select tl_test.rec('B12 using a scroll consumes it and returns its state', (:'r3'::jsonb ->> 'consumed')::boolean and (:'r3'::jsonb -> 'state' ->> 'spell') = 'fireball' and (:'r3'::jsonb ->> 'deleted')::boolean);
select public.update_inventory_item_details(:'sc', '{"consumable_override": false}');
select public.use_inventory_item(:'sc', 1) as r4 \gset
select tl_test.rec('B13 consumable_override = false keeps the scroll (explicit exception)', not (:'r4'::jsonb ->> 'consumed')::boolean and (select quantity = 2 from public.inventory_items where id = :'sc'));
select tl_test.rec('B14 the catalog default for scrolls is unchanged', (select is_consumable and stackable from public.items where id = :'scroll_id'));

-- legacy rows: clients cannot create them any more; existing ones (created here by the migration role) stay readable
select tl_test.rec('B15 a client cannot create a legacy (item_id null) row',
  tl_test.raises($$insert into public.inventory_items (character_id, name, quantity, weight, description, equipped, sort_order)
                   values ('aaaaaaaa-0000-0000-0000-00000000000a', 'Rusty Key', 1, 0.1, 'old', false, 99)$$) like '%permission denied%');
select tl_test.as_root();
insert into public.inventory_items (character_id, name, quantity, weight, description, sort_order)
  values ('aaaaaaaa-0000-0000-0000-00000000000a', 'Rusty Key', 1, 0.1, 'old', 99);
select tl_test.as_user(:'alice');
select tl_test.rec('B15b an existing legacy row is readable by its owner and attached to the inventory',
  (select inventory_id = :'inv_a' and item_id is null and quantity = 1 from public.inventory_items where name = 'Rusty Key'));

-- containers
select public.add_inventory_item(:'inv_a', 'backpack', 1) as bp \gset
select public.add_inventory_item(:'inv_a', 'torch', 3) as tor \gset
select public.move_inventory_item(:'tor', :'bp') as tor \gset
select tl_test.rec('B16 an item can be put into a container of the same inventory', (select container_item_id = :'bp' from public.inventory_items where id = :'tor'));
select tl_test.rec('B17 a container cannot contain itself', tl_test.raises(format('select public.move_inventory_item(%L, %L)', :'bp', :'bp')) is not null);
select tl_test.rec('B18 container cycles are rejected', tl_test.raises(format('select public.move_inventory_item(%L, %L)', :'bp', :'tor')) like '%cycle%');

-- =============================================================================
-- C. Equipment
-- =============================================================================
select tl_test.as_user(:'alice');
select (public.equip_item(:'jav', 'main_hand') ->> 'inventory_item_id')::uuid as eq_jav \gset
select tl_test.rec('C1 equipping one piece of a stack splits it (7 -> 6 + 1 equipped)',
  :'eq_jav' <> :'jav' and (select quantity = 6 from public.inventory_items where id = :'jav')
  and (select quantity = 1 from public.inventory_items where id = :'eq_jav')
  and (select count(*) = 1 from public.character_equipment where character_id = 'aaaaaaaa-0000-0000-0000-00000000000a' and inventory_item_id = :'eq_jav'));
select tl_test.rec('C2 the original stack is not equipped; total pieces unchanged',
  not exists (select 1 from public.character_equipment where inventory_item_id = :'jav')
  and (select sum(quantity) = 7 from public.inventory_items where inventory_id = :'inv_a' and item_id = 'javelin' and custom_name is null));
select tl_test.rec('C3 an equipped row has no stack_key (never auto-merged)', (select stack_key is null from public.inventory_items where id = :'eq_jav'));
select tl_test.rec('C4 the split and equip are in the event log',
  exists (select 1 from public.inventory_events where inventory_id = :'inv_a' and action = 'split' and metadata ->> 'reason' = 'equip')
  and exists (select 1 from public.inventory_events where inventory_id = :'inv_a' and action = 'equip' and inventory_item_id = :'eq_jav'));
select tl_test.rec('C5 an equipped item cannot be changed to quantity > 1',
  tl_test.raises(format('select public.set_inventory_item_quantity(%L, 2)', :'eq_jav')) like '%equipped%');
select public.unequip_item(:'eq_jav') as back \gset
select tl_test.rec('C6 unequipping rejoins the identical stack (back to 7, one row)',
  :'back' = :'jav' and (select quantity = 7 from public.inventory_items where id = :'jav')
  and not exists (select 1 from public.inventory_items where id = :'eq_jav'));
-- a single piece is equipped in place (no new row)
select public.add_inventory_item(:'inv_a', 'longsword', 1) as ls \gset
select (public.equip_item(:'ls', 'main_hand') ->> 'inventory_item_id')::uuid = :'ls'::uuid as same_row \gset
select tl_test.rec('C7 equipping a stack of 1 does not create a new row', :'same_row'::boolean);
select tl_test.rec('C8 one slot holds at most one item', tl_test.raises(format('select public.equip_item(%L, ''main_hand'')', :'jav')) like '%already occupied%');
select tl_test.rec('C9 an item fits only compatible slots', tl_test.raises(format('select public.equip_item(%L, ''head'')', :'ls')) like '%cannot be equipped%');
select public.add_inventory_item(:'inv_a', 'shield', 1, 'Spare shield') as spare_shield \gset
select tl_test.rec('C9b a shield cannot be equipped in the armor slot', tl_test.raises(format('select public.equip_item(%L, ''armor'')', :'spare_shield')) like '%cannot be equipped%');
select tl_test.rec('C9c magic armor without a category fits the armor slot', exists (select 1 from public.equipment_slot_rules r join public.items i on i.id = r.item_id
  where r.slot_id = 'armor' and i.kind_id = 'armor' and i.category_id is null) and not exists (select 1 from public.equipment_slot_rules where slot_id = 'armor' and kind_id = 'armor' and category_id is null));
select tl_test.rec('C10 clients cannot write character_equipment directly (RPC only)',
  tl_test.raises(format('insert into public.character_equipment (character_id, slot_id, inventory_item_id) values (%L, ''off_hand'', %L)',
                        'aaaaaaaa-0000-0000-0000-00000000000a', :'ls')) like '%permission denied%'
  and tl_test.raises(format('delete from public.character_equipment where inventory_item_id = %L', :'ls')) like '%permission denied%');
select tl_test.as_root();
select tl_test.rec('C10b one item cannot sit in two slots (unique inventory_item_id)',
  tl_test.raises(format('insert into public.character_equipment (character_id, slot_id, inventory_item_id) values (%L, ''off_hand'', %L)',
                        'aaaaaaaa-0000-0000-0000-00000000000a', :'ls')) like '%unique%');
select tl_test.as_user(:'alice');

-- ownership
select tl_test.as_user(:'bob');
select tl_test.rec('C11 another player cannot equip Alice''s item (RPC)', tl_test.raises(format('select public.equip_item(%L, ''off_hand'')', :'jav')) like '%Not allowed%');
select tl_test.as_root();
select tl_test.rec('C12 equipment must belong to the character''s own inventory (trigger)',
  tl_test.raises(format('insert into public.character_equipment (character_id, slot_id, inventory_item_id) values (%L, ''off_hand'', %L)',
                        'bbbbbbbb-0000-0000-0000-00000000000b', :'jav')) like '%does not belong%');

-- two-handed vs shield
select tl_test.as_user(:'alice');
select public.unequip_item(:'ls');
select public.add_inventory_item(:'inv_a', 'shield', 1) as sh \gset
select public.add_inventory_item(:'inv_a', 'greatsword', 1) as gs \gset
select public.equip_item(:'sh', 'shield');
select tl_test.rec('C13 a two-handed weapon is blocked while a shield is equipped', tl_test.raises(format('select public.equip_item(%L, ''main_hand'')', :'gs')) like '%two-handed%');
select public.unequip_item(:'sh');
select public.equip_item(:'gs', 'main_hand');
select tl_test.rec('C14 a shield is blocked while a two-handed weapon is equipped', tl_test.raises(format('select public.equip_item(%L, ''shield'')', :'sh')) like '%two-handed%');
select public.add_inventory_item(:'inv_a', 'dagger', 1) as dg \gset
select tl_test.rec('C15 the off hand is blocked while a two-handed weapon is equipped', tl_test.raises(format('select public.equip_item(%L, ''off_hand'')', :'dg')) like '%two-handed%');
select tl_test.rec('C16 a two-handed weapon cannot go into the off hand', tl_test.raises(format('select public.equip_item(%L, ''off_hand'', true)', :'gs')) like '%two-handed%'
  or tl_test.raises(format('select public.equip_item(%L, ''off_hand'', true)', :'gs')) is not null);
select public.unequip_item(:'gs');
select public.equip_item(:'sh', 'shield');
select public.equip_item(:'dg', 'main_hand');
select tl_test.rec('C17 one-handed weapon + shield is allowed', (select count(*) = 2 from public.character_equipment where character_id = 'aaaaaaaa-0000-0000-0000-00000000000a' and slot_id in ('main_hand', 'shield')));

-- =============================================================================
-- D. Attunement (independent of equipping, limit 3)
-- =============================================================================
select public.add_inventory_item(:'inv_a', :'at1', 1) as a1 \gset
select public.add_inventory_item(:'inv_a', :'at2', 1) as a2 \gset
select public.add_inventory_item(:'inv_a', :'at3', 1) as a3 \gset
select public.add_inventory_item(:'inv_a', :'at4', 1) as a4 \gset
select public.attune_item(:'a1'); select public.attune_item(:'a2'); select public.attune_item(:'a3');
select tl_test.rec('D1 three items can be attuned', (select attuned_count = 3 and slots_free = 0 from public.v_character_attunement where character_id = 'aaaaaaaa-0000-0000-0000-00000000000a'));
select tl_test.rec('D2 the attunement limit cannot be exceeded', tl_test.raises(format('select public.attune_item(%L)', :'a4')) like '%limit%'
  and tl_test.raises(format('update public.inventory_items set is_attuned = true where id = %L', :'a4')) like '%permission denied%');
select public.unattune_item(:'a1');
select public.attune_item(:'a4');
select tl_test.rec('D3 after un-attuning, another item can be attuned', (select is_attuned from public.inventory_items where id = :'a4'));
select tl_test.rec('D4 attuning does not equip and equipping does not attune',
  not exists (select 1 from public.character_equipment where inventory_item_id in (:'a2'::uuid, :'a3'::uuid, :'a4'::uuid))
  and (select not is_attuned from public.inventory_items where id = :'sh'));
select tl_test.rec('D5 an item that does not require attunement cannot be attuned', tl_test.raises(format('select public.attune_item(%L)', :'sh')) like '%does not require%');
select tl_test.rec('D6 attune/unattune are in the event log',
  (select count(*) filter (where action = 'attune') >= 4 and count(*) filter (where action = 'unattune') >= 1 from public.inventory_events where inventory_id = :'inv_a'));

-- =============================================================================
-- E. Modifiers and stack identity
-- =============================================================================
select public.add_inventory_item(:'inv_a', 'dagger', 2) as dg2 \gset
select tl_test.rec('E0 the dagger stack merged with nothing equipped (equipped dagger is separate)', (select quantity = 2 from public.inventory_items where id = :'dg2'));
select public.add_inventory_item(:'inv_a', 'dagger', 1) as dg3 \gset
select tl_test.rec('E1 stackable thrown weapons merge', :'dg3' = :'dg2' and (select quantity = 3 from public.inventory_items where id = :'dg2'));
select public.split_inventory_stack(:'dg2', 1) as dg_split \gset
insert into public.inventory_item_modifiers (inventory_item_id, modifier_id) values (:'dg_split', 'weapon-plus-1');
select tl_test.rec('E2 a modifier changes the stack identity', (select stack_key is distinct from (select stack_key from public.inventory_items where id = :'dg2') from public.inventory_items where id = :'dg_split'));
select tl_test.rec('E3 stacks with different modifiers cannot be merged', tl_test.raises(format('select public.merge_inventory_stacks(%L, %L)', :'dg2', :'dg_split')) like '%not identical%');
select tl_test.rec('E4 a +1 weapon modifier cannot be applied to a potion',
  tl_test.raises(format('insert into public.inventory_item_modifiers (inventory_item_id, modifier_id) values (%L, ''weapon-plus-1'')', (select public.add_inventory_item(:'inv_a', 'potion-of-healing-common', 1)))) like '%does not apply%');
delete from public.inventory_item_modifiers where inventory_item_id = :'dg_split';
select public.merge_inventory_stacks(:'dg2', :'dg_split') as merged \gset
select tl_test.rec('E5 after removing the modifier the stacks merge again', (select quantity = 3 from public.inventory_items where id = :'merged') and not exists (select 1 from public.inventory_items where id = :'dg_split'));
select tl_test.rec('E6 modifier and merge events are logged',
  exists (select 1 from public.inventory_events where inventory_id = :'inv_a' and action = 'apply_modifier')
  and exists (select 1 from public.inventory_events where inventory_id = :'inv_a' and action = 'remove_modifier')
  and exists (select 1 from public.inventory_events where inventory_id = :'inv_a' and action = 'merge'));
select public.update_inventory_item_details(:'ls', '{"custom_name": "Sting"}');
select tl_test.rec('E7 rename is logged', exists (select 1 from public.inventory_events where inventory_item_id = :'ls' and action = 'rename'));

-- views
select tl_test.rec('E8 v_inventory_weight returns the carried weight', (select total_weight_lb > 0 from public.v_inventory_weight where inventory_id = :'inv_a'));
select tl_test.rec('E9 v_inventory_detail shows the equipped slot and modifiers columns', exists (select 1 from public.v_inventory_detail where id = :'dg' and equipped_slot = 'main_hand'));
select tl_test.rec('E10 v_item_catalog exposes weapon stats', (select damage_dice = '1d8' and 'versatile' = any(weapon_properties) from public.v_item_catalog where id = 'longsword'));

-- =============================================================================
-- F. Transfer, party stash, events are not forgeable
-- =============================================================================
select tl_test.as_root();
insert into public.inventories (kind, name, campaign_id) values ('party_stash', 'Party Stash', 'cccccccc-0000-0000-0000-000000000001');
select id as inv_stash from public.inventories where kind = 'party_stash' \gset
select tl_test.as_user(:'alice');
select public.transfer_inventory_item(:'merged', :'inv_stash', 1) as tmoved \gset
select tl_test.rec('F1 a player can deposit into the party stash', (select inventory_id = :'inv_stash' from public.inventory_items where id = :'tmoved'));
select tl_test.rec('F2 a member can read the party stash', (select count(*) = 1 from public.inventory_items where inventory_id = :'inv_stash'));
select tl_test.rec('F3 a player cannot withdraw from the party stash', tl_test.raises(format('select public.transfer_inventory_item(%L, %L)', :'tmoved', :'inv_a')) like '%Not allowed%');
select tl_test.rec('F4 a player cannot write the party stash (direct or RPC)', tl_test.raises(format('update public.inventory_items set notes = ''x'' where id = %L', :'tmoved')) like '%permission denied%'
  and tl_test.raises(format('select public.update_inventory_item_details(%L, ''{"notes":"x"}'')', :'tmoved')) like '%Not allowed%'
  and (select notes is null from public.inventory_items where id = :'tmoved'));
select tl_test.rec('F5 transfer is logged on both sides', exists (select 1 from public.inventory_events where inventory_id = :'inv_a' and action = 'transfer' and quantity_delta = -1)
  and exists (select 1 from public.inventory_events where inventory_id = :'inv_stash' and action = 'transfer' and quantity_delta = 1));
select tl_test.rec('F6 an equipped item cannot be transferred', tl_test.raises(format('select public.transfer_inventory_item(%L, %L)', :'dg', :'inv_stash')) like '%Unequip%');
select tl_test.rec('F7 clients cannot forge events', tl_test.raises(format('insert into public.inventory_events (inventory_id, action) values (%L, ''add'')', :'inv_a')) like '%permission denied%');
select tl_test.rec('F8 clients cannot call the event writer', tl_test.raises(format('select public.log_inventory_event(%L, null, ''add'', 1, null)', :'inv_a')) like '%permission denied%');
select tl_test.as_user(:'dm');
select public.transfer_inventory_item(:'tmoved', :'inv_a') as wd \gset
select tl_test.rec('F9 the DM can withdraw from the party stash', (select inventory_id = :'inv_a' from public.inventory_items where id = :'wd'));
select tl_test.as_user(:'alice');

-- owned assets
insert into public.owned_assets (item_id, character_id, custom_name) values ('warhorse', 'aaaaaaaa-0000-0000-0000-00000000000a', 'Storm');
select tl_test.rec('F10 a character can own a mount', exists (select 1 from public.v_owned_assets_detail where display_name = 'Storm'));
select tl_test.rec('F11 owned_assets accept only mounts and vehicles', tl_test.raises($$insert into public.owned_assets (item_id, character_id) values ('longsword', 'aaaaaaaa-0000-0000-0000-00000000000a')$$) like '%only mounts%');
select tl_test.rec('F12 owned mounts do not count toward carried weight',
  (select total_weight_lb from public.v_inventory_weight where inventory_id = :'inv_a') = (select sum(coalesce(i.weight_lb, ii.weight) * ii.quantity) from public.inventory_items ii left join public.items i on i.id = ii.item_id where ii.inventory_id = :'inv_a'));

-- =============================================================================
-- G. RLS
-- =============================================================================
select tl_test.as_user(:'bob');
select tl_test.rec('G1 another player sees none of Alice''s inventory', (select count(*) = 0 from public.inventory_items where inventory_id = :'inv_a'));
select tl_test.rec('G2 another player cannot see Alice''s inventory row, equipment, events or assets',
  (select count(*) = 0 from public.inventories where id = :'inv_a')
  and (select count(*) = 0 from public.character_equipment where character_id = 'aaaaaaaa-0000-0000-0000-00000000000a')
  and (select count(*) = 0 from public.inventory_events where inventory_id = :'inv_a')
  and (select count(*) = 0 from public.owned_assets where character_id = 'aaaaaaaa-0000-0000-0000-00000000000a'));
select tl_test.raises(format('select public.update_inventory_item_details(%L, ''{"notes":"hacked"}'')', (select id from public.inventory_items where inventory_id = :'inv_a' limit 1)));
select tl_test.as_root();
select tl_test.rec('G3 another player cannot modify Alice''s items', not exists (select 1 from public.inventory_items where notes = 'hacked'));
select tl_test.as_user(:'bob');
select tl_test.rec('G4 another player cannot add to Alice''s inventory', tl_test.raises(format('select public.add_inventory_item(%L, ''dagger'', 1)', :'inv_a')) like '%Not allowed%'
  and tl_test.raises(format('insert into public.inventory_items (character_id, name, quantity) values (%L, ''x'', 1)', 'aaaaaaaa-0000-0000-0000-00000000000a')) like '%permission denied%');
select tl_test.rec('G5 a player can use their own inventory', (select public.add_inventory_item(:'inv_b', 'dagger', 1)) is not null);
select tl_test.as_user(:'carol');
select tl_test.rec('G6 a player outside the campaign sees neither campaign inventories nor the party stash',
  (select count(*) = 0 from public.inventory_items where inventory_id in (:'inv_a', :'inv_b', :'inv_stash')));
select tl_test.as_user(:'dm');
select tl_test.rec('G7 the campaign DM sees and can modify players'' inventories',
  (select count(*) > 0 from public.inventory_items where inventory_id = :'inv_a') and (select count(*) > 0 from public.inventory_events where inventory_id = :'inv_a')
  and (select public.add_inventory_item(:'inv_b', 'dagger', 1)) is not null);
select tl_test.as_user(:'adm');
select tl_test.rec('G8 an admin sees all inventories', (select count(*) >= 3 from public.inventories));
select tl_test.as_anon();
select tl_test.rec('G9 anon can read the official catalog and lookups', (select count(*) > 1000 from public.items) and (select count(*) = 13 from public.damage_types)
  and (select count(*) > 0 from public.v_item_catalog) and (select count(*) > 0 from public.weapon_stats));
select tl_test.rec('G10a anon has no access to inventory_items (grant revoked)', tl_test.raises('select count(*) from public.inventory_items') like '%permission denied%');
select tl_test.rec('G10b anon cannot read equipment', tl_test.raises('select count(*) from public.character_equipment') like '%permission denied%');
select tl_test.rec('G10c anon cannot read events', tl_test.raises('select count(*) from public.inventory_events') like '%permission denied%');
select tl_test.rec('G10d anon cannot read owned assets', tl_test.raises('select count(*) from public.owned_assets') like '%permission denied%');
select tl_test.rec('G10e anon cannot read the user views', tl_test.raises('select count(*) from public.v_inventory_detail') like '%permission denied%');
select tl_test.rec('G11 anon cannot change the catalog', tl_test.raises($$update public.items set name = 'x' where id = 'longsword'$$) like '%permission denied%'
  and tl_test.raises($$delete from public.items$$) like '%permission denied%');
select tl_test.rec('G12 anon cannot call the inventory RPCs', tl_test.raises($$select public.use_inventory_item(gen_random_uuid(), 1)$$) like '%permission denied%');

-- catalog write protection and homebrew
select tl_test.as_user(:'alice');
select tl_test.raises($$update public.items set name = 'Hacked Sword' where id = 'longsword'$$) as g13 \gset
select public.create_homebrew_item('11111111-1111-1111-1111-111111111111', '{"name":"Secret Blade","kind_id":"weapon","category_id":"martial-melee"}',
  '{"weapon":{"weapon_group":"martial","damage_dice":"1d8","damage_type_id":"slashing","properties":["finesse"]}}');
-- campaign content is authored by the campaign DM (20261019000100)
select tl_test.as_user(:'dm');
select public.create_homebrew_item('22222222-2222-2222-2222-222222222222', '{"name":"Campaign Axe","kind_id":"weapon","category_id":"martial-melee",
  "rarity_id":"rare","is_magic":true,"campaign_id":"cccccccc-0000-0000-0000-000000000001"}', '{"weapon":{"weapon_group":"martial","damage_dice":"1d12","damage_type_id":"slashing","properties":["heavy","two-handed"]}}');
select tl_test.as_root();
select tl_test.rec('G13 a player cannot edit official catalog rows', :'g13' like '%permission denied%' and (select name = 'Longsword' from public.items where id = 'longsword'));
select tl_test.as_user(:'alice');
select tl_test.rec('G14 an author creates homebrew items and sees them (private: alice, campaign: the DM)', (select count(*) = 1 from public.items where owner_id = :'alice')
  and exists (select 1 from public.items where id = 'hb-22222222-2222-2222-2222-222222222222'));
select tl_test.rec('G15 a player cannot write the items table directly (no official, no homebrew)', tl_test.raises($$insert into public.items (id, kind_id, name) values ('fake-official', 'gear', 'Fake')$$) like '%permission denied%');
select tl_test.as_user(:'bob');
select tl_test.rec('G16 campaign members see campaign homebrew, others do not',
  exists (select 1 from public.items where id = 'hb-22222222-2222-2222-2222-222222222222') and not exists (select 1 from public.items where id = 'hb-11111111-1111-1111-1111-111111111111'));
select tl_test.as_user(:'carol');
select tl_test.rec('G17 outsiders see no homebrew', not exists (select 1 from public.items where owner_id is not null));
select tl_test.as_anon();
select tl_test.rec('G18 anon sees no homebrew', not exists (select 1 from public.items where owner_id is not null));
select tl_test.as_user(:'dm');
select public.update_homebrew_item('hb-22222222-2222-2222-2222-222222222222', '{"name":"Campaign Axe (DM edit)","kind_id":"weapon","category_id":"martial-melee","rarity_id":"rare","is_magic":true}',
  '{"weapon":{"weapon_group":"martial","damage_dice":"1d12","damage_type_id":"slashing","properties":["heavy","two-handed"]}}');
select tl_test.as_root();
select tl_test.rec('G19 the campaign DM can edit campaign homebrew', (select name = 'Campaign Axe (DM edit)' from public.items where id = 'hb-22222222-2222-2222-2222-222222222222'));
select tl_test.as_user(:'bob');
select tl_test.raises($$select public.update_homebrew_item('hb-22222222-2222-2222-2222-222222222222', '{"name":"Bob edit"}')$$) as g20 \gset
select tl_test.as_root();
select tl_test.rec('G20 a plain member cannot edit it', (:'g20' like '%Not allowed%' or :'g20' like '%Only the DM%') and (select name = 'Campaign Axe (DM edit)' from public.items where id = 'hb-22222222-2222-2222-2222-222222222222'));

-- =============================================================================
-- I. Equipped state: character_equipment is the only source of truth
-- =============================================================================
select tl_test.as_user(:'alice');
select public.add_inventory_item(:'inv_a', 'mace', 1) as mace \gset
select tl_test.rec('I1 a client cannot write the legacy equipped column',
  tl_test.raises(format('update public.inventory_items set equipped = true where id = %L', :'mace')) like '%permission denied%'
  and (select not equipped from public.inventory_items where id = :'mace')
  and not exists (select 1 from public.character_equipment where inventory_item_id = :'mace'));
select public.unequip_item(:'dg');
select public.equip_item(:'mace', 'main_hand');
select tl_test.rec('I2 after equip_item the legacy column shows true (projection)', (select equipped from public.inventory_items where id = :'mace')
  and (select equipped and equipped_slot = 'main_hand' from public.v_inventory_detail where id = :'mace'));
select tl_test.rec('I3 a client cannot un-equip by writing the legacy column', tl_test.raises(format('update public.inventory_items set equipped = false where id = %L', :'mace')) like '%permission denied%'
  and (select equipped from public.inventory_items where id = :'mace')
  and exists (select 1 from public.character_equipment where inventory_item_id = :'mace'));
select public.unequip_item(:'mace');
select tl_test.rec('I4 after unequip_item the legacy column shows false', (select not equipped from public.inventory_items where id = :'mace'));
select tl_test.rec('I5 legacy column and character_equipment agree for every row',
  not exists (select 1 from public.inventory_items ii
              where ii.equipped is distinct from exists (select 1 from public.character_equipment e where e.inventory_item_id = ii.id)));

-- =============================================================================
-- J. Quantity >= 1 for every new write; legacy zero rows only keep their value
-- =============================================================================
select tl_test.as_root();
select tl_test.rec('J1 even the migration role cannot create a new row with quantity 0',
  tl_test.raises($$insert into public.inventory_items (character_id, name, quantity) values ('aaaaaaaa-0000-0000-0000-00000000000a', 'Empty', 0)$$) like '%at least 1%');
select tl_test.as_user(:'alice');
select tl_test.rec('J2 setting quantity to 0 is rejected (remove the item instead)',
  tl_test.raises(format('select public.set_inventory_item_quantity(%L, 0)', :'mace')) like '%at least 1%');
select tl_test.rec('J3 RPCs reject quantity 0',
  tl_test.raises(format('select public.add_inventory_item(%L, ''dagger'', 0)', :'inv_a')) like '%at least 1%'
  and tl_test.raises(format('select public.split_inventory_stack(%L, 0)', :'jav')) like '%Cannot split%'
  and tl_test.raises(format('select public.use_inventory_item(%L, 0)', :'jav')) like '%at least 1%'
  and tl_test.raises(format('select public.transfer_inventory_item(%L, %L, 0)', :'jav', :'inv_stash')) like '%Invalid quantity%'
  and tl_test.raises(format('select public.remove_inventory_item(%L, 0)', :'jav')) like '%Invalid quantity%');
select tl_test.as_root();
select id as legacy_zero from public.inventory_items where name = 'Spent torch' \gset
select tl_test.as_user(:'legacy');
select public.update_inventory_item_details(:'legacy_zero', '{"notes": "kept for the story"}');
select tl_test.rec('J4 a legacy row with quantity 0 keeps its quantity while personal notes change',
  (select quantity = 0 and notes = 'kept for the story' and description = '' from public.inventory_items where id = :'legacy_zero'));
select public.remove_inventory_item(:'legacy_zero');
select tl_test.rec('J5 removing all pieces also removes a legacy quantity-0 row', not exists (select 1 from public.inventory_items where id = :'legacy_zero'));
select tl_test.as_user(:'alice');

-- =============================================================================
-- K. Column privileges: structural changes only through RPCs
-- =============================================================================
select tl_test.rec('K1 item_id, inventory_id, character_id, stack_key cannot be written directly',
  tl_test.raises(format('update public.inventory_items set item_id = ''greatsword'' where id = %L', :'mace')) like '%permission denied%'
  and tl_test.raises(format('update public.inventory_items set inventory_id = %L where id = %L', :'inv_b', :'mace')) like '%permission denied%'
  and tl_test.raises(format('update public.inventory_items set character_id = %L where id = %L', 'bbbbbbbb-0000-0000-0000-00000000000b', :'mace')) like '%permission denied%'
  and tl_test.raises(format('update public.inventory_items set stack_key = ''x'' where id = %L', :'mace')) like '%permission denied%');
select tl_test.rec('K2 catalog items cannot be inserted directly (add_inventory_item only)',
  tl_test.raises(format('insert into public.inventory_items (inventory_id, item_id, quantity) values (%L, ''dagger'', 1)', :'inv_a')) like '%permission denied%');
select tl_test.rec('K3 a direct quantity change of a catalog row is still audited',
  (select public.add_inventory_item(:'inv_a', 'chalk-1-pc', 1)) is not null);
select id as chalk from public.inventory_items where inventory_id = :'inv_a' and item_id = 'chalk-1-pc' \gset
select tl_test.rec('K3b the quantity cannot be written directly any more',
  tl_test.raises(format('update public.inventory_items set quantity = 4 where id = %L', :'chalk')) like '%permission denied%');
select tl_test.rec('K4 provenance is not exposed to clients', tl_test.raises('select count(*) from public.item_provenance') like '%permission denied%');
select tl_test.as_user(:'bob');
select tl_test.rec('K5 inventory_of_item does not reveal other people''s inventory ids', (select public.inventory_of_item(:'mace')) is null);
select tl_test.as_user(:'alice');

-- =============================================================================
-- L. Containers: capacity is reported, cycles/depth are blocked, weight rules
-- =============================================================================
select public.add_inventory_item(:'inv_a', 'sack', 1) as sack \gset
select public.add_inventory_item(:'inv_a', 'sledgehammer', 4) as hammers \gset
select public.move_inventory_item(id, :'sack') from public.inventory_items where item_id = 'sledgehammer' and inventory_id = :'inv_a';
select tl_test.rec('L1 a sack over its 30 lb capacity is reported, not blocked',
  (select over_capacity and contents_weight_lb = 40 and capacity_weight_lb = 30 from public.v_container_contents where container_item_id = :'sack'));
select public.add_inventory_item(:'inv_a', 'bag-of-holding', 1) as boh \gset
select public.add_inventory_item(:'inv_a', 'rope-hemp-50-ft', 2) as chains \gset
select (select total_weight_lb from public.v_inventory_weight where inventory_id = :'inv_a') as w_before \gset
select public.move_inventory_item(:'chains', :'boh');
select tl_test.rec('L2 contents of a Bag of Holding do not count toward carried weight (the bag counts 15 lb)',
  (select total_weight_lb from public.v_inventory_weight where inventory_id = :'inv_a') = :'w_before'::numeric - 20
  and (select weight_lb = 15 from public.items where id = 'bag-of-holding'));
select tl_test.rec('L3 the bag still reports its own load and capacity', (select contents_weight_lb = 20 and capacity_weight_lb = 500 and not over_capacity
  from public.v_container_contents where container_item_id = :'boh'));
select public.move_inventory_item(:'sack', :'boh');
select tl_test.rec('L4 a normal container inside a weightless one: its contents do not count either',
  (select total_weight_lb from public.v_inventory_weight where inventory_id = :'inv_a') = :'w_before'::numeric - 20 - 40 - 0.5);
select public.add_inventory_item(:'inv_a', 'bag-of-holding', 1, 'Second Bag') as boh2 \gset
select public.move_inventory_item(:'boh2', :'boh');
select tl_test.rec('L5 a Bag of Holding inside a Bag of Holding is flagged (no automatic consequence)',
  (select extradimensional_nesting from public.v_container_contents where container_item_id = :'boh'));
-- depth limit: an item may sit inside at most 8 nested containers
select public.add_inventory_item(:'inv_a', 'pouch', 1, 'P' || g) from generate_series(1, 10) g;
do $$
declare ids uuid[]; i int;
begin
  select array_agg(id order by custom_name) into ids from public.inventory_items where item_id = 'pouch' and custom_name ~ '^P[1-9]$';
  for i in 2..9 loop perform public.move_inventory_item(ids[i], ids[i - 1]); end loop;
end $$;
select tl_test.rec('L6 eight nested levels are allowed, a ninth is rejected',
  (select container_item_id is not null from public.inventory_items where custom_name = 'P9') and
  tl_test.raises(format('select public.move_inventory_item(%L, %L)', (select id from public.inventory_items where custom_name = 'P10'),
                        (select id from public.inventory_items where custom_name = 'P9'))) like '%at most 8 levels%');
select tl_test.rec('L7 moving a container with contents may not exceed the depth limit either',
  tl_test.raises(format('select public.move_inventory_item(%L, %L)', (select id from public.inventory_items where custom_name = 'P1'),
                        (select id from public.inventory_items where custom_name = 'P10'))) like '%at most 8 levels%');

-- =============================================================================
-- M. Consumables
-- =============================================================================
select public.add_inventory_item(:'inv_a', 'potion-of-healing-uncommon', 1) as gph \gset
select public.use_inventory_item(:'gph') as m1 \gset
select tl_test.rec('M1 Potion of Healing returns its structured effect (dice + flat bonus), consumes the last piece',
  (:'m1'::jsonb -> 'effects' -> 0 ->> 'dice_expression') = '4d4' and (:'m1'::jsonb -> 'effects' -> 0 ->> 'flat_value')::int = 4
  and (:'m1'::jsonb -> 'effects' -> 0 ->> 'effect_type') = 'healing' and (:'m1'::jsonb ->> 'deleted')::boolean
  and (:'m1'::jsonb ->> 'previous_quantity')::int = 1);
select tl_test.rec('M2 the use event keeps item, previous quantity and name after the row is gone',
  exists (select 1 from public.inventory_events where inventory_id = :'inv_a' and action = 'use' and item_id = 'potion-of-healing-uncommon'
          and inventory_item_id is null and (metadata ->> 'previous_quantity')::int = 1 and metadata ->> 'name' is not null));
select tl_test.rec('M3 using a potion does not change character HP',
  (select hp_current from public.characters where id = 'aaaaaaaa-0000-0000-0000-00000000000a') = 10);
select public.add_inventory_item(:'inv_a', 'acid-vial', 2) as acid \gset
select public.use_inventory_item(:'acid') as m4 \gset
select tl_test.rec('M4 a generic consumable is consumed without an automatic effect',
  (:'m4'::jsonb ->> 'consumed')::boolean and jsonb_array_length(:'m4'::jsonb -> 'effects') = 0 and (:'m4'::jsonb ->> 'remaining')::int = 1);
select public.use_inventory_item(:'mace') as m5 \gset
select tl_test.rec('M5 a non-consumable item is not consumed', not (:'m5'::jsonb ->> 'consumed')::boolean
  and (select quantity = 1 from public.inventory_items where id = :'mace'));
select public.add_inventory_item(:'inv_a', :'scroll_id', 1, null, null, '{"spell":"shield","level":1}') as sc3 \gset
select public.use_inventory_item(:'sc3') as m6 \gset
select tl_test.rec('M6 a scroll is consumed and its spell is reported (not cast automatically)',
  (:'m6'::jsonb ->> 'kind_id') = 'scroll' and (:'m6'::jsonb -> 'state' ->> 'spell') = 'shield' and (:'m6'::jsonb ->> 'deleted')::boolean);

-- =============================================================================
-- N. Homebrew ownership
-- =============================================================================
select tl_test.rec('N1 a player cannot create homebrew in someone else''s name',
  tl_test.raises('select public.create_homebrew_item(''33333333-3333-3333-3333-333333333333'', ''{"name":"Gift","kind_id":"gear","owner_id":"' || :'bob' || '"}'')') like '%cannot be set%');
select tl_test.rec('N2 homebrew is labelled data_source homebrew', (select data_source_id = 'homebrew' from public.items where id = 'hb-22222222-2222-2222-2222-222222222222'));
-- the campaign axe is authored by the DM since 20261019000100: a player of the campaign can neither take it over nor
-- move it out of the campaign
select tl_test.as_user(:'alice');
select tl_test.rec('N3 a player cannot take over or re-share campaign homebrew', tl_test.raises(format('update public.items set owner_id = %L where id = ''hb-22222222-2222-2222-2222-222222222222''', :'alice')) like '%permission denied%'
  and tl_test.raises($$select public.update_homebrew_item('hb-22222222-2222-2222-2222-222222222222', '{"name":"X","kind_id":"weapon","category_id":"martial-melee","campaign_id":null}', '{"weapon":{"weapon_group":"martial"}}')$$) like '%Only the DM%');
select tl_test.as_user(:'dm');
select tl_test.rec('N4 the DM cannot write the items table directly',
  tl_test.raises(format('insert into public.items (id, kind_id, name, owner_id, campaign_id) values (''dm-fake'', ''gear'', ''X'', %L, ''cccccccc-0000-0000-0000-000000000001'')', :'alice')) like '%permission denied%');
select tl_test.as_user(:'alice');

-- =============================================================================
-- O. INSERT ... RETURNING as a normal user (what PostgREST does with return=representation)
-- =============================================================================
select tl_test.as_user(:'dm');
select tl_test.rec('O1 the DM creates an NPC inventory with RETURNING',
  tl_test.raises($$insert into public.inventories (kind, name, campaign_id) values ('npc', 'Goblin loot', 'cccccccc-0000-0000-0000-000000000001') returning id$$) is null);
select tl_test.as_user(:'alice');
select tl_test.rec('O2 a player creates homebrew through the RPC and gets the row back',
  (select public.create_homebrew_item('44444444-4444-4444-4444-444444444444', '{"name":"Ret","kind_id":"gear"}') ->> 'data_source_id') = 'homebrew');
select tl_test.rec('O3 a player creates a personal stash with RETURNING',
  tl_test.raises(format('insert into public.inventories (kind, name, owner_id) values (''stash'', ''My chest'', %L) returning id', :'alice')) is null);
select tl_test.rec('O4 a player cannot create a party stash', tl_test.raises($$insert into public.inventories (kind, name, campaign_id) values ('party_stash', 'X', 'cccccccc-0000-0000-0000-000000000001')$$) like '%row-level security%');

-- =============================================================================
-- P. Frontend RPCs: set quantity, move into containers, link legacy rows
-- =============================================================================
select tl_test.as_user(:'alice');
select public.add_inventory_item(:'inv_a', 'torch', 2) as pt \gset
select public.set_inventory_item_quantity(:'pt', 5) as p1 \gset
select tl_test.rec('P1 set_inventory_item_quantity raises a stackable stack and logs previous quantity',
  (select quantity = 5 from public.inventory_items where id = :'pt') and (:'p1'::jsonb ->> 'previous_quantity')::int = 2
  and exists (select 1 from public.inventory_events where inventory_item_id = :'pt' and action = 'add' and quantity_delta = 3
              and (metadata ->> 'previous_quantity')::int = 2));
select public.set_inventory_item_quantity(:'pt', 1);
select tl_test.rec('P2 set_inventory_item_quantity lowers it (never to 0)', (select quantity = 1 from public.inventory_items where id = :'pt')
  and tl_test.raises(format('select public.set_inventory_item_quantity(%L, 0)', :'pt')) like '%at least 1%'
  and tl_test.raises(format('select public.set_inventory_item_quantity(%L, -3)', :'pt')) like '%at least 1%');
select tl_test.rec('P3 a non-stackable catalog item cannot get quantity > 1',
  tl_test.raises(format('select public.set_inventory_item_quantity(%L, 2)', :'mace')) like '%does not stack%');
select tl_test.rec('P4 an equipped piece cannot get quantity > 1',
  tl_test.raises(format('select public.set_inventory_item_quantity(%L, 2)', (select inventory_item_id from public.character_equipment
                        where character_id = 'aaaaaaaa-0000-0000-0000-00000000000a' and slot_id = 'shield'))) is not null);
select tl_test.as_user(:'bob');
select tl_test.rec('P5 another player cannot change the quantity', tl_test.raises(format('select public.set_inventory_item_quantity(%L, 3)', :'pt')) like '%Not allowed%');
select tl_test.as_user(:'alice');

select public.add_inventory_item(:'inv_a', 'backpack', 1, 'Pack P') as pbp \gset
select public.move_inventory_item(:'pt', :'pbp') as pmoved \gset
select tl_test.rec('P6 move_inventory_item puts an item into a container and logs a move event',
  (select container_item_id = :'pbp' from public.inventory_items where id = :'pmoved')
  and exists (select 1 from public.inventory_events where inventory_item_id = :'pmoved' and action = 'move'));
select public.move_inventory_item(:'pmoved', null);
select tl_test.rec('P7 move_inventory_item(null) takes it out again', (select container_item_id is null from public.inventory_items where id = :'pmoved'));
select tl_test.rec('P8 a container cannot be moved into itself', tl_test.raises(format('select public.move_inventory_item(%L, %L)', :'pbp', :'pbp')) is not null);
select tl_test.rec('P9 an equipped item cannot be put into a container',
  tl_test.raises(format('select public.move_inventory_item(%L, %L)', (select inventory_item_id from public.character_equipment
                        where character_id = 'aaaaaaaa-0000-0000-0000-00000000000a' and slot_id = 'shield'), :'pbp')) like '%Unequip%');
select tl_test.as_user(:'bob');
select tl_test.rec('P10 another player cannot move items', tl_test.raises(format('select public.move_inventory_item(%L, null)', :'pmoved')) like '%Not allowed%');
select tl_test.as_user(:'alice');

select tl_test.as_root();
insert into public.inventory_items (character_id, name, quantity, weight, description) values
  ('aaaaaaaa-0000-0000-0000-00000000000a', 'Grandpa''s rope', 1, 10, 'smells of tar');
select tl_test.as_user(:'alice');
select id as legacy_rope from public.inventory_items where name = 'Grandpa''s rope' \gset
select public.link_inventory_item(:'legacy_rope', 'rope-hemp-50-ft');
select tl_test.rec('P11 link_inventory_item links a legacy row; legacy name -> custom name, description -> notes',
  (select item_id = 'rope-hemp-50-ft' and custom_name = 'Grandpa''s rope' and notes like '%Legacy description: smells of tar%'
     and description = 'smells of tar' from public.inventory_items where id = :'legacy_rope')
  and exists (select 1 from public.inventory_events where inventory_item_id = :'legacy_rope' and action = 'link'));
select tl_test.rec('P12 a linked row cannot be linked again', tl_test.raises(format('select public.link_inventory_item(%L, ''torch'')', :'legacy_rope')) like '%already linked%');
select tl_test.rec('P13 unknown catalog ids are rejected',
  tl_test.raises(format('select public.link_inventory_item(%L, ''no-such-item'')', (select id from public.inventory_items where name = 'Rusty Key'))) like '%Unknown catalog item%');

-- =============================================================================
-- Q. Homebrew catalog items and legacy items
-- =============================================================================
select tl_test.as_user(:'alice');
select 'hb-11111111-1111-1111-1111-111111111111' as blade, 'hb-22222222-2222-2222-2222-222222222222' as axe \gset
select tl_test.rec('Q1 an official item cannot be edited', tl_test.raises($$select public.update_homebrew_item('longsword', '{"name":"X"}')$$) like '%Official items cannot be changed%');
select tl_test.rec('Q2 an official item cannot be archived', tl_test.raises($$select public.archive_homebrew_item('longsword')$$) like '%Official items cannot be changed%');
select tl_test.rec('Q3 private homebrew belongs to its author and is labelled homebrew',
  (select owner_id = :'alice' and campaign_id is null and data_source_id = 'homebrew' and source_url is null and source_book_id is null
   from public.items where id = :'blade')
  and (select visibility = 'private' and is_mine and can_edit from public.v_item_catalog where id = :'blade'));
select tl_test.rec('Q5 owner_id cannot be passed in', tl_test.raises(format('select public.create_homebrew_item(gen_random_uuid(), %L)',
  json_build_object('name', 'X', 'kind_id', 'gear', 'owner_id', :'bob')::text)) like '%cannot be set%');
select tl_test.rec('Q6 the data source cannot be passed in (no fake official items)', tl_test.raises($$select public.create_homebrew_item(gen_random_uuid(), '{"name":"X","kind_id":"gear","data_source_id":"wikidot"}')$$) like '%cannot be set%');
select tl_test.rec('Q6b category must belong to the type', tl_test.raises($$select public.create_homebrew_item(gen_random_uuid(), '{"name":"X","kind_id":"gear","category_id":"shield"}')$$) like '%does not belong%');
select tl_test.rec('Q10 create writes the typed stats',
  (select damage_dice = '1d8' and damage_type_id = 'slashing' and 'finesse' = any (weapon_properties) from public.v_item_catalog where id = :'blade'));
select tl_test.rec('Q11 invalid typed stats roll back the whole create',
  tl_test.raises($$select public.create_homebrew_item('55555555-5555-5555-5555-555555555555', '{"name":"Bad","kind_id":"weapon"}', '{"weapon":{"damage_dice":"lots"}}')$$) like '%Damage dice%'
  and not exists (select 1 from public.items where id = 'hb-55555555-5555-5555-5555-555555555555'));
select tl_test.rec('Q11b a shield uses an AC bonus, armor needs a category',
  (select public.create_homebrew_item('77777777-7777-7777-7777-777777777777', '{"name":"Tower Shield","kind_id":"armor","category_id":"shield"}', '{"armor":{"ac_bonus":3}}') ->> 'ac_bonus') = '3'
  and tl_test.raises($$select public.create_homebrew_item(gen_random_uuid(), '{"name":"Plate","kind_id":"armor"}', '{"armor":{"base_ac":18}}')$$) like '%needs a category%'
  and tl_test.raises($$select public.create_homebrew_item(gen_random_uuid(), '{"name":"S","kind_id":"armor","category_id":"shield"}', '{"armor":{"base_ac":2}}')$$) like '%AC bonus%');
select tl_test.rec('Q11c a replayed create (same request id) returns the same item, no duplicate',
  (select public.create_homebrew_item('11111111-1111-1111-1111-111111111111', '{"name":"Whatever","kind_id":"gear"}') ->> 'id') = :'blade'
  and (select count(*) = 1 from public.items where name = 'Secret Blade'));
select public.add_inventory_item(:'inv_a', :'blade', 1) as blade_row \gset
select public.update_homebrew_item(:'blade', '{"name":"Secret Blade II","kind_id":"weapon","category_id":"martial-melee"}',
  '{"weapon":{"weapon_group":"martial","damage_dice":"1d10","damage_type_id":"slashing"}}');
select tl_test.rec('Q12 update keeps the id and replaces the stats; the inventory shows the new definition',
  (select name = 'Secret Blade II' and damage_dice = '1d10' and weapon_properties = '{}' from public.v_item_catalog where id = :'blade')
  and (select item_id = :'blade' from public.inventory_items where id = :'blade_row'));
select tl_test.rec('Q13 the type cannot change', tl_test.raises(format('select public.update_homebrew_item(%L, ''{"name":"X","kind_id":"gear"}'')', :'blade')) like '%cannot change%');
select tl_test.rec('Q13b usage count is available to the author', public.homebrew_usage_count(:'blade') = 1);
select tl_test.rec('Q13c private homebrew cannot go into the party stash or another player''s character',
  tl_test.raises(format('select public.add_inventory_item(%L, %L, 1)', :'inv_stash', :'blade')) like '%Private homebrew%');
select public.archive_homebrew_item(:'blade');
select tl_test.rec('Q14 archived homebrew is excluded from the picker query', not exists (select 1 from public.v_item_catalog where id = :'blade' and archived_at is null));
select tl_test.rec('Q15 an archived item stays visible in the inventory', exists (select 1 from public.v_inventory_detail where id = :'blade_row')
  and exists (select 1 from public.v_item_catalog where id = :'blade' and archived_at is not null));
select tl_test.rec('Q16 an archived item cannot be added again', tl_test.raises(format('select public.add_inventory_item(%L, %L, 1)', :'inv_a', :'blade')) like '%archived%');
select tl_test.rec('Q26 archiving did not delete inventory rows', exists (select 1 from public.inventory_items where id = :'blade_row'));
select public.restore_homebrew_item(:'blade');
select tl_test.rec('Q16b restore makes it addable again', (select public.add_inventory_item(:'inv_a', :'blade', 1)) is not null);
select tl_test.rec('Q16c the author sees the homebrew history', (select count(*) >= 4 from public.homebrew_item_events where item_id = :'blade'));

select tl_test.as_user(:'bob');
select tl_test.rec('Q7 another player does not see private homebrew', not exists (select 1 from public.items where id = :'blade')
  and not exists (select 1 from public.homebrew_item_events where item_id = :'blade'));
select tl_test.rec('Q8 a campaign member sees campaign homebrew', exists (select 1 from public.v_item_catalog where id = :'axe' and visibility = 'campaign'));
select tl_test.rec('Q8b a member cannot see the usage count or edit it', tl_test.raises(format('select public.homebrew_usage_count(%L)', :'axe')) like '%Not allowed%');
select tl_test.as_root();
select tl_test.rec('Q27 a profile that still owns homebrew cannot be deleted (homebrew never becomes official)',
  tl_test.raises(format('delete from public.profiles where id = %L', :'alice')) like '%items_owner_id_fkey%'
  and (select owner_id from public.items where id = :'blade') = :'alice'::uuid
  and tl_test.raises(format('update public.items set owner_id = null, campaign_id = null where id = %L', :'blade')) like '%items_homebrew_has_owner%');
select tl_test.as_user(:'carol');
select tl_test.rec('Q9 an outsider does not see campaign homebrew', not exists (select 1 from public.items where id = :'axe'));
select tl_test.rec('Q4 campaign homebrew needs campaign membership',
  tl_test.raises($$select public.create_homebrew_item(gen_random_uuid(), '{"name":"X","kind_id":"gear","campaign_id":"cccccccc-0000-0000-0000-000000000001"}')$$) similar to '%(not a member|Only the DM)%');

-- customized instance
select tl_test.as_user(:'alice');
select tl_test.rec('Q18 update_inventory_item_details only accepts instance fields',
  tl_test.raises(format('select public.update_inventory_item_details(%L, ''{"name":"X"}'')', :'blade_row')) like '%cannot be changed%'
  and tl_test.raises(format('select public.update_inventory_item_details(%L, ''{"item_id":"longsword"}'')', :'blade_row')) like '%cannot be changed%');
select public.update_inventory_item_details(:'blade_row', '{"custom_name":"Dawnbringer","notes":"Loot from Goblin Cave","is_quest_item":true}');
select tl_test.rec('Q18b renaming one piece does not change the catalog',
  (select display_name = 'Dawnbringer' and is_quest_item from public.v_inventory_detail where id = :'blade_row')
  and (select name = 'Secret Blade II' from public.items where id = :'blade'));

-- legacy rows (created by the migration role: clients cannot)
select tl_test.as_root();
insert into public.inventory_items (character_id, name, quantity, weight, description, notes, is_quest_item) values
  ('aaaaaaaa-0000-0000-0000-00000000000a', 'Torches', 3, 1, 'from the old keep', 'keep dry', true),
  ('aaaaaaaa-0000-0000-0000-00000000000a', 'Lucky Charm', 1, 0, 'a carved bone', null, false),
  ('aaaaaaaa-0000-0000-0000-00000000000a', 'Leather Armor', 1, 10, '', null, false);
select id as l_torch from public.inventory_items where name = 'Torches' \gset
select id as l_charm from public.inventory_items where name = 'Lucky Charm' \gset
select id as l_armor from public.inventory_items where name = 'Leather Armor' and item_id is null and character_id = 'aaaaaaaa-0000-0000-0000-00000000000a' \gset
insert into public.legacy_inventory_review (inventory_item_id, character_id, legacy_name, legacy_quantity, legacy_equipped, category, status)
values (:'l_armor', 'aaaaaaaa-0000-0000-0000-00000000000a', 'Leather Armor', 1, true, 'equipped_manual', 'manual_review');
select tl_test.as_user(:'alice');
select public.find_link_candidates(:'l_torch') as cand_torch \gset
select public.find_link_candidates(:'l_armor') as cand_armor \gset
select tl_test.rec('Q19a candidates: plural is a probable match, never exact', exists (select 1 from jsonb_array_elements(:'cand_torch'::jsonb) x
  where x ->> 'item_id' = 'torch' and x ->> 'confidence' = 'probable'));
select tl_test.rec('Q19b candidates: "Leather Armor" suggests "Leather" (probable)', exists (select 1 from jsonb_array_elements(:'cand_armor'::jsonb) x
  where x ->> 'item_id' = 'leather' and x ->> 'confidence' = 'probable'));
select public.preview_link_inventory_item(:'l_torch', 'torch') as prev \gset
select tl_test.rec('Q19c preview shows the differences and changes nothing',
  jsonb_array_length(:'prev'::jsonb -> 'changes') >= 1 and (select item_id is null from public.inventory_items where id = :'l_torch'));
select public.link_inventory_item(:'l_torch', 'torch') as lnk \gset
select tl_test.rec('Q19 link keeps the custom data (name, description, notes, quest flag)',
  (select item_id = 'torch' and custom_name = 'Torches' and notes like 'keep dry%Legacy description: from the old keep%' and is_quest_item
   from public.inventory_items where id = :'l_torch'));
select tl_test.rec('Q20 link keeps the quantity', (select quantity = 3 from public.inventory_items where id = :'l_torch')
  and (:'lnk'::jsonb -> 'preserved' ->> 'quantity')::int = 3);
select public.link_inventory_item(:'l_armor', 'leather') as lnk2 \gset
select tl_test.rec('Q21 linking a formerly equipped legacy item requires an equipment review',
  (:'lnk2'::jsonb ->> 'equipment_review_required')::boolean and not (select equipped from public.inventory_items where id = :'l_armor'));
select public.equip_item(:'l_armor', 'armor');
select tl_test.rec('Q21b equipping it resolves the review', (select status = 'resolved' from public.legacy_inventory_review
  where inventory_item_id = :'l_armor' and category = 'equipped_manual'));
select tl_test.rec('Q21c legacy audit keeps the original values', (select detail -> 'legacy' ->> 'description' = 'from the old keep'
  from public.legacy_inventory_review where inventory_item_id = :'l_torch' and category = 'linked_by_user'));

select tl_test.as_user(:'bob');
select tl_test.rec('Q24 another player cannot link my legacy item', tl_test.raises(format('select public.link_inventory_item(%L, ''torch'')', :'l_charm')) like '%Not allowed%');
select tl_test.rec('Q25 another player cannot convert my legacy item',
  tl_test.raises(format('select public.convert_legacy_item_to_homebrew(%L, gen_random_uuid(), ''{"name":"X","kind_id":"gear"}'')', :'l_charm')) similar to '%(Not allowed|Only a DM)%');
select tl_test.as_user(:'alice');
select tl_test.rec('Q22b a failing convert leaves the legacy row untouched',
  tl_test.raises(format('select public.convert_legacy_item_to_homebrew(%L, ''88888888-8888-8888-8888-888888888888'', ''{"name":"X","kind_id":"mount"}'')', :'l_charm')) like '%Type must be%'
  and (select item_id is null from public.inventory_items where id = :'l_charm')
  and not exists (select 1 from public.items where id = 'hb-88888888-8888-8888-8888-888888888888'));
select public.convert_legacy_item_to_homebrew(:'l_charm', '66666666-6666-6666-6666-666666666666',
  '{"name":"Lucky Charm","kind_id":"gear","category_id":"general","description":"a carved bone"}') as conv \gset
select tl_test.rec('Q22 convert creates the homebrew item and links the row in one transaction',
  (select owner_id = :'alice' and kind_id = 'gear' from public.items where id = 'hb-66666666-6666-6666-6666-666666666666')
  and (select item_id = 'hb-66666666-6666-6666-6666-666666666666' from public.inventory_items where id = :'l_charm')
  and exists (select 1 from public.legacy_inventory_review where inventory_item_id = :'l_charm' and category = 'converted_to_homebrew'));
select tl_test.rec('Q23 a retried convert does not create a duplicate',
  (public.convert_legacy_item_to_homebrew(:'l_charm', '66666666-6666-6666-6666-666666666666', '{"name":"Lucky Charm","kind_id":"gear"}') ->> 'replayed')::boolean
  and (select count(*) = 1 from public.items where name = 'Lucky Charm')
  and tl_test.raises(format('select public.convert_legacy_item_to_homebrew(%L, gen_random_uuid(), ''{"name":"Lucky Charm","kind_id":"gear"}'')', :'l_charm')) like '%already linked%');
select public.import_inventory_items('aaaaaaaa-0000-0000-0000-00000000000a',
  '[{"name":"Crowbar","quantity":1},{"name":"Mystery Orb","quantity":1,"description":"glows faintly"}]') as imp \gset
select tl_test.rec('Q17 no client path creates a legacy row: JSON import uses the catalog or homebrew',
  (:'imp'::jsonb ->> 'matched')::int = 1 and (:'imp'::jsonb ->> 'homebrew_created')::int = 1
  and exists (select 1 from public.v_inventory_detail d join public.items i on i.id = d.item_id
              where d.inventory_id = :'inv_a' and i.name = 'Mystery Orb' and i.owner_id is not null and i.campaign_id is not null), :'imp');
select tl_test.as_user(:'alice');

-- =============================================================================
-- H. Cascades
-- =============================================================================
delete from public.characters where id = 'cccccccc-0000-0000-0000-00000000000c';
select tl_test.rec('H1 deleting a character removes its inventory', not exists (select 1 from public.inventories where id = :'inv_c'));
delete from public.characters where id = 'bbbbbbbb-0000-0000-0000-00000000000b';
select tl_test.rec('H2 deleting a character with items works and leaves no orphans',
  not exists (select 1 from public.inventory_items where inventory_id = :'inv_b'));

-- =============================================================================
-- Report
-- =============================================================================
select tl_test.as_root();
\o
select case when ok then 'PASSED' else 'FAILED' end || '  ' || name || case when ok then '' else '   <-- ' || coalesce(detail, '') end
from tl_test.results order by n;
select format('%s passed, %s failed', count(*) filter (where ok), count(*) filter (where not ok)) from tl_test.results;
select 1 / (count(*) filter (where not ok) = 0)::int as all_checks_passed from tl_test.results;   -- division by zero if anything failed
rollback;
