-- =============================================================================
-- The DM's own item icons (20261114000200, docs/CUSTOM_ICONS.md): the item-icons bucket and its storage policies, the RPCs
-- dm_set_item_icon / get_campaign_item_icons, the table's RLS, the per-copy reference in v_inventory_detail.custom_icon, the
-- DM Content version inheritance, and the REQUIRED secrecy checks: a player never receives the reference of a hidden,
-- unidentified, partially identified (name only) copy, not through the view, the inventory bundle, the table or the bucket.
-- Runs inside the per-class harness (alice = player of :camp, bob = made a player here, dm = DM of :camp). The bucket's
-- size / type limits are Storage API checks (no SQL path): see supabase/tests/browser/custom_icons_ui_test.py.
-- =============================================================================
\set c1 c1c00000-0000-0000-0000-000000000001
\set c2 c1c00000-0000-0000-0000-000000000002
\set eve e6666666-6666-6666-6666-666666666666
\set camp2 c2c00000-0000-0000-0000-000000000002
\set o1 a1a00000-0000-0000-0000-000000000001
\set o2 a1a00000-0000-0000-0000-000000000002
\set o3 a1a00000-0000-0000-0000-000000000003
insert into public.campaign_members (campaign_id, user_id, role) values (:'camp', :'bob', 'player');
insert into auth.users (id, email) values (:'eve', 'eve-icons@test');
insert into public.campaigns (id, name, created_by) values (:'camp2', 'Other Table', :'eve');
insert into public.campaign_members (campaign_id, user_id, role) values (:'camp2', :'eve', 'dm');
insert into public.characters (id, owner_id, name, campaign_id, level, strength, dexterity, constitution, intelligence, wisdom, charisma, hp_max, hp_current, speed) values
  (:'c1', :'alice', 'Icon A', :'camp', 1, 10, 12, 12, 10, 14, 10, 10, 10, 30),
  (:'c2', :'bob', 'Icon B', :'camp', 1, 10, 12, 12, 10, 14, 10, 10, 10, 30);
create function tl_test.ci_code(p_sql text) returns text language plpgsql as $$
begin execute p_sql; return 'ok'; exception when others then return sqlstate; end $$;
-- a stored object as the Storage API would write it (bucket, name, metadata)
create function tl_test.ci_obj(p_name text, p_mime text default 'image/webp', p_size int default 6000) returns void language sql security definer as $$
  insert into storage.objects (bucket_id, name, metadata) values ('item-icons', p_name, jsonb_build_object('mimetype', p_mime, 'size', p_size)) $$;
create function tl_test.ci_row(p_char uuid, p_item text) returns uuid language sql security definer as $$
  select ii.id from public.inventory_items ii join public.inventories inv on inv.id = ii.inventory_id
  where inv.character_id = p_char and ii.item_id = p_item order by ii.id limit 1 $$;
-- everything the CURRENT caller can see of one character's inventory and of the icons: view rows, bundle, table, bucket listing
create function tl_test.ci_seen(p_char uuid) returns text language sql as $$
  select coalesce((select string_agg(concat_ws('|', d.id, d.item_id, d.custom_icon), ';' order by d.id) from public.v_inventory_detail d where d.character_id = p_char), '')
      || '#' || coalesce((public.get_character_reads(p_char, array['inventory_bundle']))::text, '')
      || '#' || coalesce((select string_agg(x.item_id || '|' || x.object_path, ';') from public.campaign_item_icons x), '')
      || '#' || coalesce((select string_agg(o.name, ';') from storage.objects o where o.bucket_id = 'item-icons'), '') $$;
create function tl_test.ci_icon(p_char uuid, p_row uuid) returns text language sql as $$
  select coalesce((select d.custom_icon from public.v_inventory_detail d where d.character_id = p_char and d.id = p_row), '-') $$;
grant all on all functions in schema tl_test to public;

select :'camp' || '/' || :'o1' || '.webp' as p1, :'camp' || '/' || :'o2' || '.png' as p2, :'camp2' || '/' || :'o3' || '.webp' as p3 \gset

-- ---- 1. bucket ----------------------------------------------------------------------------------------------------------------
select tl_test.rec('CI1 bucket item-icons: public, 64 KB limit, WebP / PNG only (server-side Storage checks)',
  exists (select 1 from storage.buckets where id = 'item-icons' and public and file_size_limit = 65536
          and allowed_mime_types @> array['image/webp', 'image/png'] and cardinality(allowed_mime_types) = 2));

-- ---- 2. storage policies: who can put an object where ---------------------------------------------------------------------------
select tl_test.as_user(:'dm');
select tl_test.ci_code(format('insert into storage.objects (bucket_id, name, metadata) values (''item-icons'', %L, ''{"mimetype":"image/webp","size":6000}'')', :'p1')) as up_dm \gset
select tl_test.ci_code(format('insert into storage.objects (bucket_id, name) values (''item-icons'', %L)', :'camp' || '/sword-of-truth.webp')) as up_dm_badname \gset
select tl_test.ci_code(format('insert into storage.objects (bucket_id, name) values (''item-icons'', %L)', :'p3')) as up_dm_other \gset
select tl_test.as_user(:'alice');
select tl_test.ci_code(format('insert into storage.objects (bucket_id, name) values (''item-icons'', %L)', :'camp' || '/' || gen_random_uuid() || '.webp')) as up_alice \gset
select tl_test.as_user(:'eve');
select tl_test.ci_code(format('insert into storage.objects (bucket_id, name) values (''item-icons'', %L)', :'camp' || '/' || gen_random_uuid() || '.webp')) as up_eve \gset
select tl_test.ci_code(format('insert into storage.objects (bucket_id, name, metadata) values (''item-icons'', %L, ''{"mimetype":"image/webp","size":6000}'')', :'p3')) as up_eve_own \gset
select tl_test.ci_code(format('update storage.objects set metadata = ''{}'' where name = %L', :'p3')) as upd_eve \gset
select count(*) as upd_eve_rows from storage.objects where name = :'p3' and metadata = '{}' \gset
select tl_test.as_root();
select tl_test.rec('CI2 uploads: the DM puts a random-named icon in the campaign folder; a non-uuid name, another campaign''s folder, a player and another campaign''s DM are refused (RLS)',
  :'up_dm' = 'ok' and :'up_dm_badname' = '42501' and :'up_dm_other' = '42501' and :'up_alice' = '42501' and :'up_eve' = '42501' and :'up_eve_own' = 'ok',
  concat_ws(',', :'up_dm', :'up_dm_badname', :'up_dm_other', :'up_alice', :'up_eve', :'up_eve_own'));
select tl_test.rec('CI3 no update / delete policy: an object cannot be changed or removed through the API (never deleted)',
  :'upd_eve_rows' = '0' and (select count(*) from pg_policy where polrelid = 'storage.objects'::regclass and polname like 'item_icons%' and polcmd in ('w', 'd', '*')) = 0);
select tl_test.ci_obj(:'p2', 'image/png', 9000);
select tl_test.ci_obj(:'camp' || '/' || :'o3' || '.webp', 'text/html', 500);

-- ---- 3. a campaign herb: A holds it identified, B holds it disguised -----------------------------------------------------------
select tl_test.as_user(:'dm');
select public.create_homebrew_item(gen_random_uuid(), jsonb_build_object('name', 'Dawnpetal', 'kind_id', 'herbs_plants', 'category_id', 'plant-flower',
  'campaign_id', :'camp', 'stackable', true, 'description', 'Smells of sunrise.')) ->> 'id' as herb \gset
select public.set_item_identify_options(:'herb', '{"unidentified_name": "Brown leaf", "unidentified_description": "A dull leaf.", "show_kind": true}');
select public.dm_give_item(:'herb', array[:'c1']::uuid[], 1, true);
select public.dm_give_item(:'herb', array[:'c2']::uuid[], 1, false);
select tl_test.ci_row(:'c1', :'herb') as row_a, tl_test.ci_row(:'c2', :'herb') as row_b \gset
select public.create_homebrew_item(gen_random_uuid(), jsonb_build_object('name', 'Elsewhere Root', 'kind_id', 'herbs_plants', 'category_id', 'plant-flower',
  'campaign_id', :'camp', 'stackable', true)) ->> 'id' as herb_unheld \gset
select tl_test.as_user(:'eve');
select public.create_homebrew_item(gen_random_uuid(), jsonb_build_object('name', 'Foreign Moss', 'kind_id', 'herbs_plants', 'category_id', 'plant-flower',
  'campaign_id', :'camp2', 'stackable', true)) ->> 'id' as herb_other \gset

-- ---- 4. dm_set_item_icon: roles and validation ----------------------------------------------------------------------------------
select tl_test.as_user(:'alice');
select tl_test.ci_code(format('select public.dm_set_item_icon(%L, %L, %L)', :'camp', :'herb', :'p1')) as s_alice \gset
select tl_test.ci_code(format('select public.get_campaign_item_icons(%L)', :'camp')) as l_alice \gset
select tl_test.ci_code(format('insert into public.campaign_item_icons (campaign_id, item_id, object_path) values (%L, %L, %L)', :'camp', :'herb', :'p1')) as t_alice \gset
select tl_test.as_user(:'eve');
select tl_test.ci_code(format('select public.dm_set_item_icon(%L, %L, %L)', :'camp', :'herb', :'p1')) as s_eve \gset
select tl_test.ci_code(format('select public.get_campaign_item_icons(%L)', :'camp')) as l_eve \gset
select tl_test.as_root();
select set_config('role', 'anon', true), set_config('request.jwt.claim.sub', '', true);
select tl_test.ci_code(format('select public.dm_set_item_icon(%L, %L, %L)', :'camp', :'herb', :'p1')) as s_anon \gset
select tl_test.as_user(:'dm');
select tl_test.ci_code(format('insert into public.campaign_item_icons (campaign_id, item_id, object_path) values (%L, %L, %L)', :'camp', :'herb', :'p1')) as t_dm \gset
select tl_test.as_root();
select tl_test.rec('CI4 refusals: a player, another campaign''s DM and anon cannot set or list icons (42501); nobody writes the table directly (42501)',
  :'s_alice' = '42501' and :'l_alice' = '42501' and :'t_alice' = '42501' and :'s_eve' = '42501' and :'l_eve' = '42501'
  and :'s_anon' = '42501' and :'t_dm' = '42501' and not exists (select 1 from public.campaign_item_icons),
  concat_ws(',', :'s_alice', :'l_alice', :'t_alice', :'s_eve', :'l_eve', :'s_anon', :'t_dm'));
select tl_test.as_user(:'dm');
select tl_test.rec('CI5 validation: an object not uploaded, another campaign''s folder, a bad name, a non-image object (22023); another campaign''s item (P0002)',
  tl_test.ci_code(format('select public.dm_set_item_icon(%L, %L, %L)', :'camp', :'herb', :'camp' || '/' || gen_random_uuid() || '.webp')) = '22023'
  and tl_test.ci_code(format('select public.dm_set_item_icon(%L, %L, %L)', :'camp', :'herb', :'p3')) = '22023'
  and tl_test.ci_code(format('select public.dm_set_item_icon(%L, %L, %L)', :'camp', :'herb', 'x/../evil.webp')) = '22023'
  and tl_test.ci_code(format('select public.dm_set_item_icon(%L, %L, %L)', :'camp', :'herb', :'camp' || '/' || :'o3' || '.webp')) = '22023'
  and tl_test.ci_code(format('select public.dm_set_item_icon(%L, %L, %L)', :'camp', :'herb_other', :'p1')) = 'P0002'
  and tl_test.ci_code(format('select public.dm_set_item_icon(%L, %L, %L)', :'camp', 'no-such-item', :'p1')) = 'P0002');
select public.dm_set_item_icon(:'camp', :'herb', :'p1') as set1 \gset
select public.dm_set_item_icon(:'camp', 'longsword', :'p2') as set2 \gset
select tl_test.rec('CI6 the DM sets icons: a campaign herb and an official item (only the short object path is stored)',
  (:'set1')::jsonb ->> 'changed' = '1' and (:'set2')::jsonb ->> 'changed' = '1'
  and (select object_path from public.campaign_item_icons where campaign_id = :'camp' and item_id = :'herb') = :'p1'
  and (select object_path from public.campaign_item_icons where campaign_id = :'camp' and item_id = 'longsword') = :'p2', :'set1');

-- ---- 5. REQUIRED secrecy ---------------------------------------------------------------------------------------------------------
select tl_test.as_user(:'alice');
select tl_test.ci_icon(:'c1', :'row_a') as icon_a, tl_test.ci_seen(:'c1') as seen_a \gset
select tl_test.as_user(:'bob');
select tl_test.ci_icon(:'c2', :'row_b') as icon_b, tl_test.ci_seen(:'c2') as seen_b \gset
select coalesce((select item_id from public.v_inventory_detail where id = :'row_b'), '-') as item_b \gset
select tl_test.as_user(:'dm');
select tl_test.ci_icon(:'c2', :'row_b') as icon_b_dm, (public.get_campaign_item_icons(:'camp'))::text as dm_list \gset
select tl_test.as_root();
select tl_test.rec('CI7 the identified copy (A) carries the icon reference in the view',
  :'icon_a' = :'p1', :'icon_a');
select tl_test.rec('CI8 REQUIRED the disguised copy (B): no reference in the view row, the inventory bundle, the table or a bucket listing (item id masked too)',
  position(:'row_b' in :'seen_b') > 0 and :'icon_b' = '-' and :'item_b' = '-' and position(:'p1' in :'seen_b') = 0 and position(:'o1' in :'seen_b') = 0,
  :'seen_b');
select tl_test.rec('CI9 the DM sees the icon on every copy; the DM''s list shows the herb with its icon and the official item held nowhere is listed through its icon',
  :'icon_b_dm' = :'p1' and position(:'p1' in :'dm_list') > 0 and position('"longsword"' in :'dm_list') > 0
  and position(:'herb_unheld' in :'dm_list') > 0 and position(:'herb_other' in :'dm_list') = 0);
select tl_test.rec('CI10 a player reads a table row only for an item whose catalog row they can read (A: the herb and the official item; no bucket listing)',
  position(:'herb' || '|' || :'p1' in :'seen_a') > 0 and position('longsword|' || :'p2' in :'seen_a') > 0
  and split_part(:'seen_a', '#', 4) = '', :'seen_a');
-- name only (partially identified): still masked, still no reference
select tl_test.as_user(:'dm');
select public.dm_set_item_knowledge(:'herb', array[:'c2']::uuid[], '{name}', 'set', :'camp');
select tl_test.as_user(:'bob');
select tl_test.ci_icon(:'c2', :'row_b') as icon_b2, tl_test.ci_seen(:'c2') as seen_b2 \gset
select tl_test.as_user(:'dm');
-- hiding A's copy again (identified -> unidentified): A loses the reference at once
select public.dm_set_item_knowledge(:'herb', array[:'c1']::uuid[], '{}', 'set', :'camp');
select tl_test.as_user(:'alice');
select tl_test.ci_icon(:'c1', :'row_a') as icon_a2, tl_test.ci_seen(:'c1') as seen_a2 \gset
select tl_test.as_root();
select tl_test.rec('CI11 REQUIRED name-only reveal (partially identified) keeps the reference away; hiding an identified copy removes it',
  :'icon_b2' = '-' and position(:'p1' in :'seen_b2') = 0 and :'icon_a2' = '-' and position(:'p1' in :'seen_a2') = 0,
  :'seen_b2' || ' // ' || :'seen_a2');
-- full reveal to B: the icon appears on B's copy
select tl_test.as_user(:'dm');
select public.dm_set_item_knowledge(:'herb', array[:'c2']::uuid[], '{all}', 'set', :'camp');
select tl_test.as_user(:'bob');
select tl_test.ci_icon(:'c2', :'row_b') as icon_b3 \gset
select tl_test.as_root();
select tl_test.rec('CI12 once B identifies the herb, B''s copy carries the icon', :'icon_b3' = :'p1', :'icon_b3');

-- ---- 6. party stash copy follows its own knowledge -----------------------------------------------------------------------------------
insert into public.inventories (kind, name, campaign_id) select 'party_stash', 'Icon Hoard', :'camp'
where not exists (select 1 from public.inventories where campaign_id = :'camp' and kind = 'party_stash');
select id as stash from public.inventories where campaign_id = :'camp' and kind = 'party_stash' limit 1 \gset
insert into public.inventory_items (inventory_id, item_id, name, quantity) values (:'stash', 'longsword', 'Longsword', 1);
select tl_test.as_user(:'bob');
select coalesce((select custom_icon from public.v_inventory_detail where inventory_id = :'stash' and item_id = 'longsword' limit 1), '-') as stash_icon \gset
select tl_test.as_root();
select tl_test.rec('CI13 a party stash copy uses the stash''s campaign', :'stash_icon' = :'p2', :'stash_icon');

-- ---- 7. remove: the link goes, the file stays ----------------------------------------------------------------------------------------
select count(*) as objs_before from storage.objects where bucket_id = 'item-icons' \gset
select tl_test.as_user(:'dm');
select public.dm_set_item_icon(:'camp', :'herb', null) as rm \gset
select tl_test.as_user(:'alice');
select coalesce((select string_agg(coalesce(custom_icon, '-'), ',') from public.v_inventory_detail where character_id = :'c1'), 'none') as icon_after \gset
select tl_test.as_root();
select tl_test.rec('CI14 remove: the link is gone (the default icon comes back), the uploaded object is NOT deleted',
  (:'rm')::jsonb ->> 'changed' = '1' and not exists (select 1 from public.campaign_item_icons where item_id = :'herb')
  and :'icon_after' = '-' and (select count(*) from storage.objects where bucket_id = 'item-icons') = :'objs_before', :'icon_after');

-- ---- 8. DM Content: every version's catalog row; a later version inherits ----------------------------------------------------------
select tl_test.as_user(:'dm');
select public.duplicate_official_as_homebrew('item', 'longsword', :'camp') ->> 'id' as dc \gset
select public.publish_dm_content(:'dc');
select catalog_ref as v1 from public.dm_content_versions where content_id = :'dc' and catalog_ref is not null order by version_no limit 1 \gset
select public.dm_assign_content(:'dc', array[:'c1']::uuid[], 'inventory', '{}');
select public.dm_set_item_icon(:'camp', :'v1', :'p1');
select public.new_dm_content_version(:'dc');
select public.publish_dm_content(:'dc');
select catalog_ref as v2 from public.dm_content_versions where content_id = :'dc' and catalog_ref is not null order by version_no desc limit 1 \gset
select tl_test.as_user(:'alice');
select coalesce((select custom_icon from public.v_inventory_detail where character_id = :'c1' and item_id = :'v1' limit 1), '-') as v1_icon \gset
select tl_test.as_root();
select tl_test.rec('CI15 DM Content: a version published later inherits the icon; the character''s v1 copy keeps it',
  :'v1' <> :'v2' and (select object_path from public.campaign_item_icons where campaign_id = :'camp' and item_id = :'v2') = :'p1' and :'v1_icon' = :'p1',
  :'v1' || ' ' || :'v2');
select tl_test.as_user(:'dm');
select public.dm_set_item_icon(:'camp', :'v2', :'p2') as dset \gset
select tl_test.as_root();
select tl_test.rec('CI16 setting or removing the icon on one version applies to every version of that content',
  (select count(*) from public.campaign_item_icons where campaign_id = :'camp' and item_id in (:'v1', :'v2') and object_path = :'p2') = 2, :'dset');

-- ---- 9. cache classification -----------------------------------------------------------------------------------------------------------
select tl_test.rec('CI17 tl_cache_rev on campaign_item_icons is tl_cache.skip (no cached read reads it)',
  exists (select 1 from pg_trigger t where t.tgrelid = 'public.campaign_item_icons'::regclass and t.tgname = 'tl_cache_rev'
          and t.tgfoid = 'tl_cache.skip()'::regprocedure));
