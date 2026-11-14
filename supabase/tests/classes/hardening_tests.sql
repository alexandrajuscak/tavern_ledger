-- =============================================================================
-- R-D3 hardening (20261114000700, review v34): M4 (no true name / item id of a disguised equipped copy on the derived read, its
-- cached copies and tl_cache rows), m1 (an inactive counter of a disguised copy is not listed for the player), m2 (item / feat /
-- lineage counters: no player edit or create, no delete for anybody), n1 (a Special's linked effect says whether it applies),
-- and a server-side guard of the Combat Builder feature read (call counts + a generous time cap; review of the ?v=33/34 smoke).
-- Runs inside the per-class harness (alice = player, bob = outsider, dm = DM of :camp).
-- =============================================================================
\set h1 f5e00000-0000-0000-0000-000000000001
\set h2 f5e00000-0000-0000-0000-000000000002
\set h3 f5e00000-0000-0000-0000-000000000003
insert into public.characters (id, owner_id, name, campaign_id, level, strength, dexterity, constitution, intelligence, wisdom, charisma, hp_max, hp_current, speed) values
  (:'h1', :'alice', 'Mask Holder', :'camp', 5, 16, 12, 14, 10, 10, 10, 40, 40, 30),
  (:'h2', :'alice', 'Mask Knower', :'camp', 5, 16, 12, 14, 10, 10, 10, 40, 40, 30),
  (:'h3', :'alice', 'Feature Fighter', :'camp', 1, 16, 12, 14, 10, 12, 8, 12, 12, 30);
set constraints all immediate;                    -- the grant sync flushes at commit; this file is ONE transaction
create function tl_test.code(p_sql text) returns text language plpgsql as $$
begin execute p_sql; return 'ok'; exception when others then return sqlstate; end $$;
create function tl_test.ref(p_content uuid) returns text language sql security definer as $$
  select v.catalog_ref from public.dm_content c join public.dm_content_versions v on v.id = c.published_version_id where c.id = p_content $$;
create function tl_test.pub(p_def jsonb) returns text language plpgsql as $$
declare c uuid;
begin
  c := (public.create_dm_content('item', 'c1c00000-0000-0000-0000-000000000001', p_def) ->> 'id')::uuid;
  perform public.publish_dm_content(c);
  return c::text;
end $$;
create function tl_test.unident_row(p_char uuid, p_item text) returns uuid language sql security definer as $$
  select ii.id from public.inventory_items ii join public.inventories i on i.id = ii.inventory_id
  join public.inventory_item_knowledge k on k.inventory_item_id = ii.id
  where i.character_id = p_char and ii.item_id = p_item and k.state <> 'identified' order by ii.created_at limit 1 $$;
create function tl_test.ident_row(p_char uuid, p_item text) returns uuid language sql security definer as $$
  select ii.id from public.inventory_items ii join public.inventories i on i.id = ii.inventory_id
  left join public.inventory_item_knowledge k on k.inventory_item_id = ii.id
  where i.character_id = p_char and ii.item_id = p_item and coalesce(k.state, 'identified') = 'identified' order by ii.created_at limit 1 $$;
create function tl_test.cache_text(p_char uuid, p_viewer uuid) returns text language sql security definer as $$
  select coalesce(string_agg(payload::text, '|'), '') from tl_cache.character_reads where character_id = p_char and viewer = p_viewer $$;
create function tl_test.res_of(p_char uuid, p_like text) returns public.character_resources language sql security definer as $$
  select * from public.character_resources where character_id = p_char and resource_key like p_like order by created_at limit 1 $$;
-- per-function call counts of this transaction (track_functions = all, set below)
create function tl_test.fcalls() returns jsonb language sql as $$
  select coalesce(jsonb_object_agg(funcname, calls), '{}') from pg_stat_xact_user_functions where schemaname in ('public', 'tl_cache') $$;
grant all on all functions in schema tl_test to public;
set track_functions = 'all';

-- ---- authored items: a weapon (limited action, Special linked to an attuned-only effect), an armor, a tool ---------------------
select tl_test.as_user(:'dm');
select tl_test.ref(tl_test.pub('{"name": "Truthblade", "definition": {"item": {"kind_id": "weapon", "category_id": "martial-melee", "is_magic": true, "rarity_id": "rare",
  "requires_attunement": true,
  "effects": [{"type": "attack_bonus", "value": 1, "activation": "attuned"}],
  "weapon_actions": [{"name": "Riposte", "description": "Strike back.", "cost": "reaction", "roll": "attack", "damage": "1d6", "damage_type": "slashing", "uses": 1, "recharge": "short_rest"}],
  "weapon_special": [{"name": "Honed", "text": "Sharper when bonded.", "effect": 1}]},
  "stats": {"weapon": {"weapon_group": "martial", "damage_dice": "1d8", "damage_type_id": "slashing"}},
  "hidden": {"unidentified_name": "Plain sword", "unidentified_description": "A plain sword."}}}')::uuid) as wpn \gset
select tl_test.ref(tl_test.pub('{"name": "Truthmail", "definition": {"item": {"kind_id": "armor", "category_id": "medium-armor", "is_magic": true, "rarity_id": "rare"},
  "stats": {"armor": {"base_ac": 14, "dex_modifier_mode": "capped", "dex_cap": 2}},
  "hidden": {"unidentified_name": "Dull mail", "unidentified_description": "Scratched mail."}}}')::uuid) as arm \gset
select tl_test.ref(tl_test.pub('{"name": "Truthkit", "definition": {"item": {"kind_id": "tool", "category_id": "artisan-tools", "is_magic": true, "rarity_id": "uncommon"},
  "hidden": {"unidentified_name": "Odd kit", "unidentified_description": "Some tools."}}}')::uuid) as tool \gset
-- the player's other character knows all three (the catalog rows are readable for alice); Mask Holder gets disguised copies
select public.dm_give_item(:'wpn', array[:'h2']::uuid[], 1, true);
select public.dm_give_item(:'arm', array[:'h2']::uuid[], 1, true);
select public.dm_give_item(:'tool', array[:'h2']::uuid[], 1, true);
select public.dm_give_item(:'wpn', array[:'h1']::uuid[], 1, false);
select public.dm_give_item(:'arm', array[:'h1']::uuid[], 1, false);
select public.dm_give_item(:'tool', array[:'h1']::uuid[], 1, false);
select tl_test.unident_row(:'h1', :'wpn') as uw, tl_test.unident_row(:'h1', :'arm') as ua, tl_test.unident_row(:'h1', :'tool') as ut,
       tl_test.ident_row(:'h2', :'wpn') as kw \gset
select tl_test.as_user(:'alice');
select public.equip_item(:'uw', 'main_hand', true);
select public.equip_item(:'ua', 'armor', true);
select (select count(*) from public.items where id in (:'wpn', :'arm', :'tool')) as visible_rows \gset

-- ---- M4 ---------------------------------------------------------------------------------------------------------------------
select public.get_character_derived_stats(:'h1')::text as pd \gset
select public.get_character_reads(:'h1', array['get_character_derived_stats']) ->> 'reads' as pr1 \gset
select public.get_character_reads(:'h1', array['get_character_derived_stats']) ->> 'reads' as pr2 \gset
select public.get_character_bundle(:'h1', 'core')::text as pb \gset
select tl_test.rec('H1 setup: the catalog rows are readable for the player (another character knows them), the copies are disguised',
  :'visible_rows'::int = 3 and :'uw' <> '' and :'ua' <> '' and :'ut' <> '');
select tl_test.rec('H2 M4 player derived: the equipped disguised weapon carries its disguise, no item id; armor too; no tool listed',
  (select w ->> 'name' = 'Plain sword' and w ->> 'item_id' is null from jsonb_array_elements(:'pd'::jsonb -> 'equipped_weapon_attacks') w
    where w ->> 'inventory_item_id' = :'uw')
  and :'pd'::jsonb -> 'armor' ->> 'name' = 'Dull mail' and :'pd'::jsonb -> 'armor' ->> 'item_id' is null
  and :'pd'::jsonb -> 'armor_class' ->> 'value' is not null
  and jsonb_array_length(:'pd'::jsonb -> 'tools') = 0, left(:'pd', 300));
-- (the raw inventory_items.item_id of the row itself stays readable: documented residual B9 of DESIGN_hidden_items_reveal.md)
select tl_test.rec('H3 M4 no true name anywhere (derived, cached reads miss and hit, core bundle, tl_cache rows); no item id on the derived reads',
  position('Truth' in :'pd') = 0 and position(:'wpn' in :'pd') = 0 and position(:'arm' in :'pd') = 0
  and position('Truth' in :'pr1') = 0 and position('Truth' in :'pr2') = 0 and position(:'wpn' in :'pr2') = 0
  and position('Truth' in :'pb') = 0
  and position('Truth' in tl_test.cache_text(:'h1', :'alice')) = 0 and position(:'wpn' in tl_test.cache_text(:'h1', :'alice')) = 0);
select tl_test.rec('H4 M4 the numbers do not change: the disguised armor still sets AC 14 + DEX (capped), the weapon still attacks',
  (:'pd'::jsonb -> 'armor_class' ->> 'value')::int = 15
  and (select (w ->> 'attack_bonus') is not null from jsonb_array_elements(:'pd'::jsonb -> 'equipped_weapon_attacks') w where w ->> 'inventory_item_id' = :'uw'));
select tl_test.as_user(:'dm');
select public.get_character_derived_stats(:'h1')::text as dd \gset
select tl_test.rec('H5 M4 the DM still sees the true names and ids',
  (select w ->> 'name' = 'Truthblade' and w ->> 'item_id' = :'wpn' from jsonb_array_elements(:'dd'::jsonb -> 'equipped_weapon_attacks') w
    where w ->> 'inventory_item_id' = :'uw')
  and :'dd'::jsonb -> 'armor' ->> 'item_id' = :'arm' and jsonb_array_length(:'dd'::jsonb -> 'tools') = 1);
-- identification shows the truth to the player again
select public.set_item_knowledge(:'uw', 'identified');
select tl_test.as_user(:'alice');
select tl_test.rec('H6 M4 identified: the player sees the true name and item id',
  (select w ->> 'name' = 'Truthblade' and w ->> 'item_id' = :'wpn' from jsonb_array_elements(public.get_character_derived_stats(:'h1') -> 'equipped_weapon_attacks') w
    where w ->> 'inventory_item_id' = :'uw'));

-- ---- n1 + m1 ----------------------------------------------------------------------------------------------------------------
-- identified, in hand, not attuned: the Special's effect is inactive; attuned: active (and the action counter exists)
select coalesce((select w -> 'weapon_blocks' -> 'special' -> 0 -> 'effect' ->> 'active'
  from jsonb_array_elements(public.get_character_derived_stats(:'h1') -> 'equipped_weapon_attacks') w where w ->> 'inventory_item_id' = :'uw'), 'missing') as sp_before \gset
select public.attune_item(:'uw');
select coalesce((select w -> 'weapon_blocks' -> 'special' -> 0 -> 'effect' ->> 'active'
  from jsonb_array_elements(public.get_character_derived_stats(:'h1') -> 'equipped_weapon_attacks') w where w ->> 'inventory_item_id' = :'uw'), 'missing') as sp_after \gset
select tl_test.rec('H7 n1 a Special''s linked effect: inactive while not attuned, active once attuned',
  :'sp_before' = 'false' and :'sp_after' = 'true', :'sp_before' || ' / ' || :'sp_after');
select (tl_test.res_of(:'h1', 'itemw-' || replace(:'uw', '-', '') || '-%')).id as wres \gset
select tl_test.as_user(:'dm');
select public.set_item_knowledge(:'uw', 'unidentified');
select tl_test.as_user(:'alice');
select public.get_character_resources(:'h1')::text as pres \gset
select tl_test.as_user(:'dm');
select public.get_character_resources(:'h1')::text as dres \gset
select tl_test.rec('H8 m1 the inactive counter of the disguised copy is not listed for the player; the DM still sees it',
  :'wres' <> '' and (tl_test.res_of(:'h1', 'itemw-%')).active = false
  and position(:'wres' in :'pres') = 0 and position(:'wres' in :'dres') > 0);

-- ---- m2 ---------------------------------------------------------------------------------------------------------------------
select tl_test.as_root();
insert into public.character_resources (character_id, resource_key, name, source_type, source_id, max_formula, recharge, active, created_by)
values (:'h1', 'ft-0123456789-uses', 'Feat uses', 'feat', 'test', '{"fixed": 2}', 'long_rest', true, :'alice'),
       (:'h1', 'lin-test-trait', 'Trait uses', 'lineage', 'test', '{"fixed": 1}', 'long_rest', true, :'alice');
select (tl_test.res_of(:'h1', 'ft-%')).id as fres, (tl_test.res_of(:'h1', 'lin-%')).id as lres \gset
select tl_test.as_user(:'alice');
select tl_test.rec('H9 m2 player: no edit of an item / feat / lineage counter, no new counter with such a source or key (42501)',
  tl_test.code(format('select public.save_character_resource(%L, %L)', :'h1', jsonb_build_object('id', :'wres', 'name', 'Mine'))) = '42501'
  and tl_test.code(format('select public.save_character_resource(%L, %L)', :'h1', jsonb_build_object('id', :'fres', 'notes', 'x'))) = '42501'
  and tl_test.code(format('select public.save_character_resource(%L, %L)', :'h1', jsonb_build_object('id', :'lres', 'active', false))) = '42501'
  and tl_test.code(format('select public.save_character_resource(%L, %L)', :'h1', '{"resource_key": "itemw-00-1", "name": "Forged"}')) = '42501'
  and tl_test.code(format('select public.save_character_resource(%L, %L)', :'h1', '{"resource_key": "my-thing", "name": "Forged", "source_type": "item"}')) = '42501'
  and tl_test.code(format('select public.save_character_resource(%L, %L)', :'h1', '{"resource_key": "my-charm", "name": "Manual charm", "max_formula": {"fixed": 2}}')) = 'ok');
select tl_test.rec('H10 m2 player: no delete of an item / feat / lineage counter (a manual one still can be deleted)',
  tl_test.code(format('select public.delete_character_resource(%L)', :'wres')) = '42501'
  and tl_test.code(format('select public.delete_character_resource(%L)', :'fres')) = '42501'
  and tl_test.code(format('select public.delete_character_resource(%L)', :'lres')) = '42501'
  and tl_test.code(format('select public.delete_character_resource(%L)', (tl_test.res_of(:'h1', 'my-charm')).id)) = 'ok');
select tl_test.as_user(:'dm');
select tl_test.rec('H11 m2 DM: may adjust an item counter, may not delete it (the sync would recreate it unspent)',
  tl_test.code(format('select public.save_character_resource(%L, %L)', :'h1', jsonb_build_object('id', :'wres', 'notes', 'DM note'))) = 'ok'
  and tl_test.code(format('select public.delete_character_resource(%L)', :'wres')) = '42501'
  and tl_test.code(format('select public.delete_character_resource(%L)', :'fres')) = '42501'
  and (select count(*) from public.character_resources where id in (:'wres', :'fres', :'lres')) = 3);

-- ---- Combat Builder feature read guard (C-01 of production_active_features_smoke.py) -----------------------------------------
-- the smoke character: fighter 5, Chromatic Dragonborn, DM-granted Interception; the DM opens its active features (cache miss)
select tl_test.as_user(:'alice');
select public.set_character_class(:'h3', 'fighter-phb', 5, null);
select public.set_character_lineage(:'h3', 'dragonborn-chromatic', null, '{"dragonborn-chromatic:ancestry": ["blue"]}'::jsonb);
select tl_test.as_user(:'dm');
select public.assign_character_feat(:'h3', 'interception-2024', '{}'::jsonb, 'dm_grant', null, null, null);
select tl_test.as_root();
delete from tl_cache.character_reads where character_id = :'h3';
select tl_test.fcalls()::text as c0 \gset
select tl_test.as_user(:'dm');
select clock_timestamp() as t0 \gset
select public.get_character_reads(:'h3', array['get_character_class_features', 'get_character_resources', 'get_character_feats', 'get_character_lineage'])::text as fr \gset
select round(extract(epoch from clock_timestamp() - :'t0'::timestamptz) * 1000) as fr_ms \gset
select tl_test.as_root();
select tl_test.fcalls()::text as c1 \gset
create function tl_test.dcalls(p_fn text, p_before text, p_after text) returns int language sql as $$
  select coalesce((p_after::jsonb ->> p_fn)::int, 0) - coalesce((p_before::jsonb ->> p_fn)::int, 0) $$;
select tl_test.rec('H12 feature read (DM, cache miss): all 4 reads, no errors, Breath Weapon and Interception present',
  :'fr'::jsonb -> 'errors' = '{}'::jsonb and (:'fr'::jsonb -> 'cache' ->> 'stored')::int = 4
  and position('Breath Weapon' in :'fr') > 0 and position('Interception' in :'fr') > 0, left(:'fr', 200));
select tl_test.rec('H13 feature read guard: derived stats computed at most twice, item effect rows at most twice, no weapon-block helper, bounded access checks, under 3 s',
  tl_test.dcalls('_derived_stats_full', :'c0', :'c1') <= 2 and tl_test.dcalls('_character_item_effect_rows', :'c0', :'c1') <= 2
  and tl_test.dcalls('_character_weapon_blocks', :'c0', :'c1') = 0 and tl_test.dcalls('can_access_character', :'c0', :'c1') <= 1500
  and :'fr_ms'::int < 3000,
  format('ms=%s derived=%s item_rows=%s blocks=%s access=%s', :'fr_ms', tl_test.dcalls('_derived_stats_full', :'c0', :'c1'),
         tl_test.dcalls('_character_item_effect_rows', :'c0', :'c1'), tl_test.dcalls('_character_weapon_blocks', :'c0', :'c1'),
         tl_test.dcalls('can_access_character', :'c0', :'c1')));
