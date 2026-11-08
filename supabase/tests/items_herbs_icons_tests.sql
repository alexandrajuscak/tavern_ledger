-- Herbs & Plants, Potion details, icon overrides, category switching and safe deletion (authors are DMs: only DMs create custom content)
-- (20261107000300_items_herbs_icons_deletion.sql). LOCAL ONLY; run as supabase_admin; one transaction, rolled back.
-- Usage: docker exec -i supabase_db_tavern_ledger psql -U supabase_admin -d postgres -qAt -v ON_ERROR_STOP=1 < supabase/tests/items_herbs_icons_tests.sql
-- Concurrent deletion vs. "add to inventory": supabase/tests/item_deletion_concurrency_test.sh.
begin;
create temp table ih (n serial, chk text, ok boolean, detail text) on commit drop;
grant all on ih to authenticated, anon;
grant all on sequence ih_n_seq to authenticated, anon;
create temp table fx (k text primary key, v text) on commit drop;
grant all on fx to authenticated, anon;

create or replace function pg_temp.as_user(u uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
end $$;
create or replace function pg_temp.as_admin() returns void language plpgsql as $$
begin
  execute 'reset role';
  perform set_config('request.jwt.claims', '', true);
end $$;
create or replace function pg_temp.ok(c text, b boolean, d text default '') returns void language sql as $$
  insert into ih (chk, ok, detail) values (c, coalesce(b, false), coalesce(d, ''));
$$;
create or replace function pg_temp.try(q text) returns text language plpgsql as $$
begin
  execute q;
  return 'ok';
exception when others then return sqlstate || ': ' || sqlerrm;
end $$;
create or replace function pg_temp.fu(k text) returns uuid language sql as $$ select v::uuid from fx where fx.k = $1 $$;
create or replace function pg_temp.fx(k text) returns text language sql as $$ select v from fx where fx.k = $1 $$;
create or replace function pg_temp.put(k text, v text) returns void language sql as $$
  insert into fx values (k, v) on conflict (k) do update set v = excluded.v;
$$;
create or replace function pg_temp.hb(def jsonb, stats jsonb default '{}') returns text language plpgsql as $$
declare r jsonb;
begin
  r := public.create_homebrew_item(gen_random_uuid(), def, stats);
  return r ->> 'id';
end $$;

do $$
declare dm uuid := gen_random_uuid(); pl uuid := gen_random_uuid(); other uuid := gen_random_uuid(); camp uuid := gen_random_uuid(); ch uuid;
begin
  insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at) values
    (dm, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'ih-dm-' || dm || '@example.test', now(), now()),
    (pl, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'ih-pl-' || pl || '@example.test', now(), now()),
    (other, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'ih-ot-' || other || '@example.test', now(), now());
  insert into public.campaigns (id, name, created_by) values (camp, 'IH herb campaign', dm);
  insert into public.campaign_members (campaign_id, user_id, role) values (camp, dm, 'dm'), (camp, pl, 'player');
  insert into public.characters (owner_id, name, campaign_id, level, hp_max, hp_current) values (pl, 'IH Herbalist', camp, 3, 20, 20) returning id into ch;
  perform pg_temp.put('dm', dm::text); perform pg_temp.put('pl', pl::text); perform pg_temp.put('other', other::text);
  perform pg_temp.put('camp', camp::text); perform pg_temp.put('ch', ch::text);
  perform pg_temp.put('inv', (select id::text from public.inventories where character_id = ch and kind = 'character' limit 1));
end $$;

-- ============================================================================================ 1. Herbs & Plants, Potions
do $$
declare iid text; s text; r jsonb;
begin
  perform pg_temp.ok('K1 kind herbs_plants "Herbs & Plants" with 11 subtypes', (select name from public.item_kinds where id = 'herbs_plants') = 'Herbs & Plants'
    and (select count(*) from public.item_categories where kind_id = 'herbs_plants') = 11);
  perform pg_temp.ok('K2 existing items untouched: no icon_key, empty details', not exists (select 1 from public.items where owner_id is null and (icon_key is not null or details <> '{}')));
  perform pg_temp.as_user(pg_temp.fu('dm'));
  iid := pg_temp.hb('{"name": "IH Silverleaf", "kind_id": "herbs_plants"}');
  perform pg_temp.ok('H1 a simple herb needs only a name (no armor, weapon, tool, potion, charges, recipe)', iid is not null);
  perform pg_temp.put('herb1', iid);
  perform pg_temp.ok('H2 herb defaults: stackable, not consumable, no category required', (select stackable and not is_consumable from public.items where id = pg_temp.fx('herb1')));
  iid := pg_temp.hb(jsonb_build_object('name', 'IH Moonpetal', 'kind_id', 'herbs_plants', 'category_id', 'plant-flower', 'icon_key', 'plant.flower',
    'details', jsonb_build_object('environment', 'Moonlit meadows', 'region', 'North vale', 'harvesting', 'Pick at night', 'properties', jsonb_build_array('medicinal', 'alchemical'),
      'ingredient_tags', jsonb_build_array('calming', 'silver', 'calming'), 'recipe_refs', jsonb_build_array('Sleep draught'), 'preparation', 'Dry for a week', 'shelf_life', 'One month')));
  perform pg_temp.put('herb2', iid);
  r := (select to_jsonb(c) from public.v_item_catalog c where c.id = iid);
  perform pg_temp.ok('H3 herb subtype, icon and metadata stored and visible in the catalog view', r ->> 'category_id' = 'plant-flower' and r ->> 'icon_key' = 'plant.flower'
    and r -> 'details' ->> 'environment' = 'Moonlit meadows' and r -> 'details' -> 'properties' @> '["medicinal","alchemical"]', left(r::text, 300));
  perform pg_temp.ok('H4 duplicate ingredient tags collapsed', jsonb_array_length(r -> 'details' -> 'ingredient_tags') = 2);
  s := pg_temp.try($q$select pg_temp.hb('{"name": "IH Bad herb", "kind_id": "herbs_plants", "details": {"doses": 3}}')$q$);
  perform pg_temp.ok('H5 a potion field on a herb is refused (friendly 22023)', s like '22023%Field "doses" is not part of%', s);
  s := pg_temp.try($q$select pg_temp.hb('{"name": "IH Bad herb", "kind_id": "herbs_plants", "details": {"properties": ["explosive"]}}')$q$);
  perform pg_temp.ok('H6 unknown plant property refused', s like '22023%', s);
  s := pg_temp.try($q$select pg_temp.hb('{"name": "IH Bad herb", "kind_id": "herbs_plants", "category_id": "light-armor"}')$q$);
  perform pg_temp.ok('H7 an armor category on a herb is refused', s like '22023%', s);
  -- potions
  iid := pg_temp.hb('{"name": "IH Plain tonic", "kind_id": "potion"}');
  perform pg_temp.ok('P1 a basic potion needs only the ordinary fields (consumable, stackable by default)', (select is_consumable and stackable from public.items i where i.id = iid) and iid is not null);
  iid := pg_temp.hb(jsonb_build_object('name', 'IH Draught of Rest', 'kind_id', 'potion', 'icon_key', 'potion.flask', 'campaign_id', pg_temp.fx('camp'),
    'details', jsonb_build_object('doses', 2, 'use_action', 'bonus_action', 'effect_text', 'You fall into a calm sleep.', 'saving_throw', 'CON DC 12',
      'duration', '1 hour', 'ingredients', jsonb_build_array('IH Moonpetal', 'Water'), 'recipe_refs', jsonb_build_array('Sleep draught'))),
    '{"effect": {"effect_type": "healing", "dice_expression": "2d4", "flat_value": 2}}');
  perform pg_temp.put('potion', iid);
  perform pg_temp.ok('P2 potion metadata stored; a structured effect stays in consumable_effects', (select details ->> 'use_action' = 'bonus_action' and (details ->> 'doses')::int = 2 from public.items where id = pg_temp.fx('potion'))
    and exists (select 1 from public.consumable_effects where item_id = pg_temp.fx('potion') and effect_type = 'healing'));
  s := pg_temp.try($q$select pg_temp.hb('{"name": "IH Bad potion", "kind_id": "potion", "details": {"harvesting": "x"}}')$q$);
  perform pg_temp.ok('P3 a herb field on a potion is refused', s like '22023%', s);
  s := pg_temp.try($q$select pg_temp.hb('{"name": "IH Bad potion", "kind_id": "potion", "details": {"use_action": "teleport"}}')$q$);
  perform pg_temp.ok('P4 unknown use action refused', s like '22023%', s);
  s := pg_temp.try($q$select pg_temp.hb('{"name": "IH Bad potion", "kind_id": "potion", "is_consumable": false}')$q$);
  perform pg_temp.ok('P5 a potion is always consumable (existing rule kept)', s like '22023%', s);
  perform pg_temp.as_admin();
end $$;

-- ============================================================================================ 2. icons
do $$
declare s text; iid text;
begin
  perform pg_temp.as_user(pg_temp.fu('dm'));
  foreach s in array array['https://evil.example/x.svg', '<svg onload=alert(1)>', 'javascript:alert(1)', '../../etc/passwd', 'ui.attack', 'plant.Flower', 'plant.']
  loop
    perform pg_temp.ok('I1 refused icon key: ' || left(s, 30), pg_temp.try(format('select pg_temp.hb(%L)', jsonb_build_object('name', 'IH Icon test', 'kind_id', 'gear', 'icon_key', s))) like '22023%Choose an icon from the gallery%');
  end loop;
  iid := pg_temp.hb('{"name": "IH Ingredient pouch", "kind_id": "gear", "icon_key": "item.mortar-pestle"}');
  perform pg_temp.ok('I2 gallery key accepted on another kind', (select icon_key from public.items i where i.id = iid) = 'item.mortar-pestle');
  perform public.update_homebrew_item(pg_temp.fx('herb2'), '{"name": "IH Moonpetal"}', '{}');
  perform pg_temp.ok('I3 an edit that does not mention the icon keeps it (and keeps the details)', (select icon_key = 'plant.flower' and details ->> 'region' = 'North vale' from public.items where id = pg_temp.fx('herb2')));
  perform public.update_homebrew_item(pg_temp.fx('herb2'), '{"name": "IH Moonpetal", "icon_key": null}', '{}');
  perform pg_temp.ok('I4 clearing the icon falls back to the category default (null)', (select icon_key is null from public.items where id = pg_temp.fx('herb2')));
  perform pg_temp.as_admin();
  s := pg_temp.try($q$update public.items set icon_key = 'https://x' where id = pg_temp.fx('herb2')$q$);
  perform pg_temp.ok('I5 the table check refuses a URL even for a direct write', s like '23514%', s);
end $$;

-- ============================================================================================ 3. category switching (DM content versions)
do $$
declare c uuid; r jsonb; v uuid; s text; ref1 text; ref2 text;
begin
  perform pg_temp.as_user(pg_temp.fu('dm'));
  -- an Armor draft whose hidden armor stats are left in the definition, switched to Herbs & Plants: publish refuses stale stats
  r := public.create_dm_content('item', pg_temp.fu('camp'), jsonb_build_object('name', 'IH Switch', 'definition',
    jsonb_build_object('item', jsonb_build_object('kind_id', 'herbs_plants', 'category_id', 'plant-root'), 'stats', jsonb_build_object('armor', jsonb_build_object('base_ac', 14)))), gen_random_uuid());
  c := (r ->> 'id')::uuid;
  r := public.validate_dm_content(c);
  perform pg_temp.ok('S1 Armor -> Herbs & Plants with stale armor stats: validation refuses (no hidden mechanics)', not coalesce((r -> 'validation' ->> 'ok')::boolean, true), left((r -> 'validation')::text, 200));
  perform public.save_dm_content(c, jsonb_build_object('definition', jsonb_build_object('item', jsonb_build_object('kind_id', 'herbs_plants', 'category_id', 'plant-root', 'icon_key', 'plant.root'))), null);
  r := public.publish_dm_content(c, null);
  select catalog_ref into ref1 from public.dm_content_versions where content_id = c and catalog_ref is not null limit 1;
  perform pg_temp.ok('S2 the cleaned herb publishes: kind herbs_plants, icon carried to the item, no armor stats',
    (select kind_id = 'herbs_plants' and icon_key = 'plant.root' from public.items where id = ref1) and not exists (select 1 from public.armor_stats where item_id = ref1), coalesce(ref1, 'none'));
  perform pg_temp.put('dmc', c::text); perform pg_temp.put('ref1', ref1);
  -- new version as a Weapon: only the weapon section; the herb version stays as it was
  perform public.new_dm_content_version(c);
  perform public.save_dm_content(c, jsonb_build_object('definition', jsonb_build_object('item', jsonb_build_object('kind_id', 'weapon', 'category_id', 'simple-melee'),
    'stats', jsonb_build_object('weapon', jsonb_build_object('damage_dice', '1d6', 'damage_type_id', 'piercing')))), null);
  r := public.publish_dm_content(c, null);
  select catalog_ref into ref2 from public.dm_content_versions where content_id = c and catalog_ref is not null and catalog_ref <> ref1 limit 1;
  perform pg_temp.ok('S3 Herbs & Plants -> Weapon as a new version: weapon stats on the new version only, the published herb version unchanged',
    (select kind_id from public.items where id = ref2) = 'weapon' and exists (select 1 from public.weapon_stats where item_id = ref2)
    and (select kind_id from public.items where id = ref1) = 'herbs_plants' and not exists (select 1 from public.weapon_stats where item_id = ref1), coalesce(ref2, 'none'));
  perform pg_temp.put('ref2', ref2);
  perform pg_temp.as_user(pg_temp.fu('dm'));
  s := pg_temp.try(format('select public.update_homebrew_item(%L, %L, %L)', pg_temp.fx('herb1'), '{"name": "IH Silverleaf", "kind_id": "potion"}', '{}'));
  perform pg_temp.ok('S4 a homebrew item cannot change its type in place (create a new item; existing rule)', s like '22023%', s);
  s := pg_temp.try(format('select pg_temp.hb(%L, %L)', '{"name": "IH Weaponish herb", "kind_id": "herbs_plants"}', '{"weapon": {"damage_dice": "1d4"}}'));
  perform pg_temp.ok('S5 weapon stats sent with a herb are refused', s like '22023%', s);
  s := pg_temp.try(format('select pg_temp.hb(%L, %L)', '{"name": "IH Potion with armor", "kind_id": "potion"}', '{"armor": {"base_ac": 12}}'));
  perform pg_temp.ok('S6 armor stats sent with a potion are refused', s like '22023%', s);
  s := pg_temp.try(format('select pg_temp.hb(%L, %L)', '{"name": "IH Potion to weapon", "kind_id": "weapon"}', '{"weapon": {"damage_dice": "1d4"}, "effect": {"effect_type": "healing", "dice_expression": "1d4"}}'));
  perform pg_temp.ok('S7 Potion -> Weapon with a stale use effect: refused (only consumables have effects)', s like '22023%', s);
  perform pg_temp.as_admin();
end $$;

-- ============================================================================================ 4. deletion
do $$
declare r jsonb; s text; ii uuid;
begin
  perform pg_temp.as_user(pg_temp.fu('dm'));
  r := public.preview_item_deletion(pg_temp.fx('herb1'));
  perform pg_temp.ok('D1 preview: an unused herb is deletable', (r ->> 'deletable')::boolean, r::text);
  s := pg_temp.try(format('select public.delete_custom_item(%L, %L)', pg_temp.fx('herb1'), 'wrong name'));
  perform pg_temp.ok('D2 delete needs the exact name as confirmation', s like '22023%', s);
  -- used: put the potion into the character inventory
  ii := public.add_inventory_item(pg_temp.fu('inv'), pg_temp.fx('potion'), 2, null, null, '{}');
  r := public.preview_item_deletion(pg_temp.fx('potion'));
  perform pg_temp.ok('D3 preview of a used potion: not deletable, the inventory entry and history are listed, advice archive',
    not (r ->> 'deletable')::boolean and (r -> 'dependencies' ->> 'character_inventories')::int = 1 and r ->> 'advice' like 'This definition is in use%', r::text);
  s := pg_temp.try(format('select public.delete_custom_item(%L, %L)', pg_temp.fx('potion'), 'IH Draught of Rest'));
  perform pg_temp.ok('D4 deleting a used item is refused (TLUSE), the item and the entry stay', s like 'TLUSE%' and exists (select 1 from public.items where id = pg_temp.fx('potion'))
    and exists (select 1 from public.inventory_items where item_id = pg_temp.fx('potion')), s);
  perform public.archive_homebrew_item(pg_temp.fx('potion'));
  perform pg_temp.ok('D5 archive instead: archived, the entry keeps working', (select archived_at is not null from public.items where id = pg_temp.fx('potion'))
    and exists (select 1 from public.inventory_items where item_id = pg_temp.fx('potion')));
  -- removed from the inventory: history still blocks a permanent delete
  perform pg_temp.as_admin();
  delete from public.inventory_items where item_id = pg_temp.fx('potion');
  perform pg_temp.as_user(pg_temp.fu('dm'));
  r := public.preview_item_deletion(pg_temp.fx('potion'));
  perform pg_temp.ok('D6 an item with inventory history is still not deletable (archive)', not (r ->> 'deletable')::boolean and (r -> 'dependencies' ->> 'inventory_history')::int >= 1, r::text);
  r := public.delete_custom_item(pg_temp.fx('herb1'), 'IH Silverleaf');
  perform pg_temp.ok('D7 an unused herb is deleted for good (definition rows cascade)', not exists (select 1 from public.items where id = pg_temp.fx('herb1'))
    and not exists (select 1 from public.homebrew_item_events where item_id = pg_temp.fx('herb1')));
  s := pg_temp.try(format('select public.delete_custom_item(%L, %L)', pg_temp.fx('herb1'), 'IH Silverleaf'));
  perform pg_temp.ok('D8 deleting it again: friendly "unknown item", no raw error', s like 'P0002%', s);
  perform pg_temp.as_user(pg_temp.fu('other'));
  s := pg_temp.try(format('select public.preview_item_deletion(%L)', pg_temp.fx('herb2')));
  perform pg_temp.ok('D9 another user cannot even see the private item', s like 'P0002%', s);
  s := pg_temp.try(format('select public.delete_custom_item(%L, %L)', pg_temp.fx('herb2'), 'IH Moonpetal'));
  perform pg_temp.ok('D10 ... nor delete it', s like 'P0002%' or s like '42501%', s);
  perform pg_temp.as_user(pg_temp.fu('dm'));
  r := public.preview_item_deletion('potion-of-healing-common');
  perform pg_temp.ok('D11 official items are never deletable', not (r ->> 'deletable')::boolean and (r ->> 'official')::boolean, r::text);
  s := pg_temp.try($q$select public.delete_custom_item('potion-of-healing-common', 'Potion of Healing')$q$);
  perform pg_temp.ok('D12 ... and delete refuses them', s like '42501%', s);
  -- DM content item
  perform pg_temp.as_user(pg_temp.fu('dm'));
  s := pg_temp.try(format('select public.delete_custom_item(%L, %L)', pg_temp.fx('ref1'), 'IH Switch'));
  perform pg_temp.ok('D13 a DM Space item is deleted in DM Space, not as homebrew', s like '22023%managed in DM Space%' or s like '42501%', s);
  ii := public.add_inventory_item((select id from public.inventories where character_id = pg_temp.fu('ch') and kind = 'character' limit 1), pg_temp.fx('ref2'), 1, null, null, '{}');
  s := pg_temp.try(format('select public.delete_unused_dm_item(%L, %L)', pg_temp.fu('dmc'), 'IH Switch'));
  perform pg_temp.ok('D14 a published DM item with a used version cannot be deleted (TLUSE); both versions stay', s like 'TLUSE%'
    and exists (select 1 from public.items where id = pg_temp.fx('ref1')) and exists (select 1 from public.items where id = pg_temp.fx('ref2')), s);
  perform pg_temp.as_admin();
  delete from public.inventory_items where id = ii;
  delete from public.inventory_events where item_id in (pg_temp.fx('ref1'), pg_temp.fx('ref2'));
  perform pg_temp.as_user(pg_temp.fu('dm'));
  r := public.delete_unused_dm_item(pg_temp.fu('dmc'), 'IH Switch');
  perform pg_temp.ok('D15 an unused published DM item is deleted with all its versions', not exists (select 1 from public.dm_content where id = pg_temp.fu('dmc'))
    and not exists (select 1 from public.items where id in (pg_temp.fx('ref1'), pg_temp.fx('ref2'))), r::text);
  perform pg_temp.as_user(pg_temp.fu('dm'));
  s := pg_temp.try($q$select public.delete_unused_dm_item(gen_random_uuid(), 'x')$q$);
  perform pg_temp.ok('D16 a player cannot use the DM delete (42501)', s like '42501%', s);
  perform pg_temp.as_admin();
end $$;

select 'FAILED ' || chk || coalesce('  <-- ' || nullif(detail, ''), '') from ih where not ok order by n;
select 'TOTAL ' || count(*) || ' checks, ' || count(*) filter (where not ok) || ' failed' from ih;
rollback;
