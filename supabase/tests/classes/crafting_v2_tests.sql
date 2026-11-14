-- =============================================================================
-- Crafting v2 (20261114000900, docs/CRAFTING_V1.md "v2"): the DC and the tool in the player read, the tool rule on the server,
-- recipe items (learn from a manual / a scroll, used up per link, unidentified copies never teach, drafts never teach, counts
-- only before learning), the DM's suggested outcome, the per-item lock 4242 on every crafting path, and hidden data.
-- Runs inside the per-class harness (alice = player of :camp, bob = made a player here, dm = DM of :camp).
-- =============================================================================
\set ca f6c00000-0000-0000-0000-0000000000a1
\set cb f6c00000-0000-0000-0000-0000000000b2
insert into public.campaign_members (campaign_id, user_id, role) values (:'camp', :'bob', 'player');
insert into public.characters (id, owner_id, name, campaign_id, level, strength, dexterity, constitution, intelligence, wisdom, charisma, hp_max, hp_current, speed) values
  (:'ca', :'alice', 'Crafter V2 A', :'camp', 1, 10, 12, 12, 10, 14, 10, 10, 10, 30),
  (:'cb', :'bob', 'Crafter V2 B', :'camp', 1, 10, 12, 12, 10, 14, 10, 10, 10, 30);
create function tl_test.v2_code(p_sql text) returns text language plpgsql as $$
begin execute p_sql; return 'ok'; exception when others then return sqlstate; end $$;
create function tl_test.v2_msg(p_sql text) returns text language plpgsql as $$
begin execute p_sql; return 'ok'; exception when others then return sqlstate || ' ' || sqlerrm; end $$;
create function tl_test.v2_qty(p_char uuid, p_item text) returns int language sql security definer as $$
  select coalesce(sum(ii.quantity), 0)::int from public.inventory_items ii join public.inventories inv on inv.id = ii.inventory_id
  where inv.character_id = p_char and ii.item_id = p_item $$;
create function tl_test.v2_row(p_char uuid, p_item text) returns uuid language sql security definer as $$
  select ii.id from public.inventory_items ii join public.inventories inv on inv.id = ii.inventory_id
  where inv.character_id = p_char and ii.item_id = p_item order by ii.quantity desc, ii.id limit 1 $$;
create function tl_test.v2_sel(p_seq int, p_row uuid, p_qty int) returns jsonb language sql as $$
  select jsonb_build_object('seq', p_seq, 'inventory_item_id', p_row, 'quantity', p_qty) $$;
create function tl_test.v2_rec(p_read jsonb, p_recipe uuid) returns jsonb language sql as $$
  select r from jsonb_array_elements(p_read -> 'recipes') r where r ->> 'recipe_id' = p_recipe::text $$;
-- 4242 locks this backend holds for an item
create function tl_test.v2_locked(p_item text) returns boolean language sql as $$
  select exists (select 1 from pg_locks l where l.locktype = 'advisory' and l.pid = pg_backend_pid() and l.classid = 4242
                 and l.objid = (hashtext(p_item)::bigint & 4294967295)::oid and l.objsubid = 2 and l.granted) $$;
grant all on all functions in schema tl_test to public;

-- ---- fixtures (DM) ---------------------------------------------------------------------------------------------------------------
select tl_test.as_user(:'dm');
select public.set_campaign_governance(:'camp', '{"overrides": {"inventory.craft": "player_managed"}}');
select public.create_homebrew_item(gen_random_uuid(), jsonb_build_object('name', 'Sunroot', 'kind_id', 'herbs_plants', 'category_id', 'plant-flower',
  'campaign_id', :'camp', 'stackable', true)) ->> 'id' as root \gset
select public.create_homebrew_item(gen_random_uuid(), jsonb_build_object('name', 'Sun Tonic', 'kind_id', 'gear', 'campaign_id', :'camp', 'stackable', true)) ->> 'id' as tonic \gset
select public.create_homebrew_item(gen_random_uuid(), jsonb_build_object('name', 'Herbal Manual', 'kind_id', 'gear', 'campaign_id', :'camp')) ->> 'id' as manual \gset
select public.create_homebrew_item(gen_random_uuid(), jsonb_build_object('name', 'Recipe Scroll', 'kind_id', 'scroll', 'campaign_id', :'camp', 'stackable', true)) ->> 'id' as scroll \gset
select public.create_homebrew_item(gen_random_uuid(), jsonb_build_object('name', 'Draft Manual', 'kind_id', 'gear', 'campaign_id', :'camp')) ->> 'id' as dmanual \gset
select public.set_item_identify_options(:'manual', '{"unidentified_name": "Battered book"}');
-- a secret recipe taught by the manual (kept) and by the scroll (default: a scroll is used up); a tool check with a DC
select public.dm_save_recipe(:'camp', jsonb_build_object('name', 'Secret Sun Tonic', 'dm_notes', 'SENTINEL-V2NOTE', 'visibility', 'secret',
  'check_key', 'herbalism-kit', 'check_dc', 12, 'output_item_id', :'tonic',
  'ingredients', jsonb_build_array(jsonb_build_object('item_id', :'root', 'quantity', 2)),
  'teachers', jsonb_build_array(jsonb_build_object('item_id', :'manual'), jsonb_build_object('item_id', :'scroll')))) as r1j \gset
select :'r1j'::jsonb ->> 'id' as r1 \gset
select public.dm_set_recipe_status(:'r1', 'published');
-- a draft recipe linked to another manual
select public.dm_save_recipe(:'camp', jsonb_build_object('name', 'Draft Brew', 'visibility', 'secret', 'output_item_id', :'tonic',
  'ingredients', jsonb_build_array(jsonb_build_object('item_id', :'root', 'quantity', 1)),
  'teachers', jsonb_build_array(jsonb_build_object('item_id', :'dmanual', 'consumed', true)))) ->> 'id' as r_draft \gset
select tl_test.as_root();
select tl_test.rec('V1 teachers saved: the manual is kept, the scroll is used up by default; the DM view lists them and the tool',
  (select bool_and(case t ->> 'item_id' when :'manual' then not (t ->> 'consume_on_learn')::boolean when :'scroll' then (t ->> 'consume_on_learn')::boolean end)
     from jsonb_array_elements(:'r1j'::jsonb -> 'teachers') t)
  and jsonb_array_length(:'r1j'::jsonb -> 'teachers') = 2 and :'r1j'::jsonb ->> 'tool_item_id' = 'herbalism-kit',
  left(:'r1j'::jsonb ->> 'teachers', 300));

-- ---- learn from items ------------------------------------------------------------------------------------------------------------
select tl_test.as_user(:'dm');
select public.dm_give_item(:'manual', array[:'cb']::uuid[], 1, false);   -- bob: an unidentified copy
select public.dm_give_item(:'manual', array[:'ca']::uuid[], 1, true);    -- alice: an identified copy
select tl_test.as_root();
select tl_test.v2_row(:'ca', :'manual') as manual_row \gset
select tl_test.as_user(:'alice');
select tl_test.give(:'ca', :'scroll', null, 2) as scroll_row \gset
select tl_test.give(:'ca', :'dmanual') as dmanual_row \gset
select public.get_character_recipes(:'ca') as a0 \gset
select public.get_inventory_item_recipes(:'manual_row') as a_info \gset
select tl_test.v2_msg(format('select public.learn_recipe_from_item(%L)', :'dmanual_row')) as a_draft \gset
select public.learn_recipe_from_item(:'manual_row') as a_learn \gset
select public.get_character_recipes(:'ca') as a1 \gset
select public.learn_recipe_from_item(:'scroll_row') as a_learn_again \gset
select tl_test.as_root();
select tl_test.rec('V2 before learning: the secret recipe is not listed, the manual shows only counts (no name); a draft recipe teaches nothing',
  tl_test.v2_rec(:'a0'::jsonb, :'r1') is null and (:'a_info'::jsonb ->> 'unlearned')::int = 1 and position('Secret Sun' in :'a_info') = 0
  and position('Secret Sun' in :'a0') = 0 and position('Draft Brew' in :'a0') = 0
  and (select count(*) from jsonb_array_elements(:'a0'::jsonb -> 'manuals') m where m ->> 'inventory_item_id' = :'manual_row') = 1
  and (select count(*) from jsonb_array_elements(:'a0'::jsonb -> 'manuals') m where m ->> 'inventory_item_id' = :'dmanual_row') = 0
  and :'a_draft' = '22023 There is no recipe to learn in this item',
  concat_ws(' | ', :'a_draft', left(:'a_info', 200)));
select tl_test.rec('V3 reading the manual teaches the recipe permanently (source manual, shown as new), the manual is kept; reading the scroll again teaches nothing and is NOT used up',
  :'a_learn'::jsonb -> 'learned' -> 0 ->> 'name' = 'Secret Sun Tonic' and not (:'a_learn'::jsonb ->> 'consumed')::boolean
  and tl_test.v2_rec(:'a1'::jsonb, :'r1') ->> 'source' = 'learned' and (tl_test.v2_rec(:'a1'::jsonb, :'r1') ->> 'new')::boolean
  and (select source from public.character_known_recipes where character_id = :'ca' and recipe_id = :'r1') = 'manual'
  and tl_test.v2_qty(:'ca', :'manual') = 1 and jsonb_array_length(:'a_learn_again'::jsonb -> 'learned') = 0
  and not (:'a_learn_again'::jsonb ->> 'consumed')::boolean and tl_test.v2_qty(:'ca', :'scroll') = 2,
  concat_ws(' | ', :'a_learn', :'a_learn_again'));
-- bob: a scroll teaches and is used up (one of two); his unidentified manual never teaches and says nothing
select tl_test.as_user(:'bob');
select tl_test.v2_row(:'cb', :'manual') as b_manual \gset
select tl_test.give(:'cb', :'scroll', null, 2) as b_scroll \gset
select public.get_character_recipes(:'cb')::text as b_read0 \gset
select public.get_inventory_item_recipes(:'b_manual') as b_info \gset
select tl_test.v2_msg(format('select public.learn_recipe_from_item(%L)', :'b_manual')) as b_unid \gset
select public.learn_recipe_from_item(:'b_scroll') as b_learn \gset
select tl_test.v2_msg(format('select public.learn_recipe_from_item(%L)', :'manual_row')) as b_other \gset
select tl_test.as_root();
select tl_test.rec('V4 an unidentified manual: counts 0, not listed, one fixed refusal; another player''s row is refused (42501)',
  (:'b_info'::jsonb ->> 'recipes')::int = 0 and position(:'b_manual' in :'b_read0') = 0
  and :'b_unid' = '22023 You don''t know what this item is yet' and :'b_other' like '42501%',
  concat_ws(' | ', :'b_info', :'b_unid', :'b_other'));
select tl_test.rec('V5 the scroll teaches bob and is used up (2 -> 1); an inventory_events use row with via learn_recipe',
  (:'b_learn'::jsonb ->> 'consumed')::boolean and tl_test.v2_qty(:'cb', :'scroll') = 1
  and exists (select 1 from public.inventory_events e where e.action = 'use' and e.metadata ->> 'via' = 'learn_recipe' and e.item_id = :'scroll'),
  :'b_learn');

-- ---- DC and tool -----------------------------------------------------------------------------------------------------------------
select tl_test.as_user(:'alice');
select tl_test.give(:'ca', :'root', null, 3) as root_row \gset
select public.get_character_recipes(:'ca') as a2 \gset
select tl_test.v2_msg(format('select public.start_craft_attempt(%L, %L, %L::jsonb, 15, gen_random_uuid())', :'ca', :'r1',
  jsonb_build_array(tl_test.v2_sel(1, :'root_row', 2)))) as a_notool \gset
select tl_test.give(:'ca', 'herbalism-kit') as kit_row \gset
select public.get_character_recipes(:'ca') as a3 \gset
select public.start_craft_attempt(:'ca', :'r1', jsonb_build_array(tl_test.v2_sel(1, :'root_row', 2)), 15, gen_random_uuid(), 'nat20') as att \gset
select tl_test.as_root();
select tl_test.rec('V6 the player sees the DC (check.dc 12) and the tool: missing -> can_craft false and start refused (22023); carried -> listed under tools, can_craft true, start pending',
  (tl_test.v2_rec(:'a2'::jsonb, :'r1') -> 'check' ->> 'dc')::int = 12 and not (tl_test.v2_rec(:'a2'::jsonb, :'r1') -> 'tool' ->> 'have')::boolean
  and not (tl_test.v2_rec(:'a2'::jsonb, :'r1') ->> 'can_craft')::boolean and :'a_notool' like '22023 You need Herbalism%'
  and (tl_test.v2_rec(:'a3'::jsonb, :'r1') -> 'tool' ->> 'have')::boolean and (tl_test.v2_rec(:'a3'::jsonb, :'r1') ->> 'can_craft')::boolean
  and (select count(*) from jsonb_array_elements(:'a3'::jsonb -> 'tools') t where t ->> 'item_id' = 'herbalism-kit') = 1
  and :'att'::jsonb ->> 'status' = 'pending',
  concat_ws(' | ', :'a_notool', left(:'a3'::jsonb ->> 'tools', 200)));
select tl_test.rec('V7 hidden data: the player reads carry no DM notes, no check_dc key, no recipe item ids of the DM view; the teachers table is closed to players',
  position('SENTINEL-V2NOTE' in :'a3') = 0 and position('"check_dc"' in :'a3') = 0 and position('consume_on_learn' in :'a3') = 0
  and position('SENTINEL-V2NOTE' in :'b_read0') = 0 and position('Battered' in :'b_info') = 0,
  'see read');
select tl_test.as_user(:'alice');
select tl_test.v2_code('select count(*) from public.crafting_recipe_teachers') as t_rest \gset
select tl_test.as_root();
select tl_test.rec('V7b crafting_recipe_teachers: 42501 for a player (no grants)', :'t_rest' = '42501', :'t_rest');

-- ---- DM: suggested outcome, approval takes the 4242 locks -------------------------------------------------------------------------
select tl_test.as_user(:'dm');
select public.get_campaign_craft_attempts(:'camp') as inbox \gset
select tl_test.as_root();
select tl_test.rec('V8 suggested outcome: nat20 -> critical success in the DM view (the DC and the tool state are shown to the DM)',
  (select x ->> 'suggested_outcome' = 'critical_success' and (x ->> 'tool_ok')::boolean and (x ->> 'check_dc')::int = 12
     from jsonb_array_elements(:'inbox'::jsonb) x where x ->> 'attempt_id' = :'att'::jsonb ->> 'attempt_id')
  and public._craft_suggest(11, null, 12) = 'failure' and public._craft_suggest(12, null, 12) = 'success'
  and public._craft_suggest(30, 'nat1', 12) = 'critical_failure' and public._craft_suggest(null, null, null) = 'success'
  and public._craft_suggest(null, null, 12) is null,
  left(:'inbox', 300));
select tl_test.v2_locked(:'root') as lock_before \gset
select tl_test.as_user(:'dm');
select public.dm_resolve_craft_attempt((:'att'::jsonb ->> 'attempt_id')::uuid, 'approve', 'success') as res \gset
select tl_test.as_root();
select tl_test.rec('V9 approval applies (2 Sunroot used, 1 Sun Tonic made, the kit kept) and holds the per-item lock 4242 of the ingredient and the result',
  :'res'::jsonb ->> 'status' = 'applied' and tl_test.v2_qty(:'ca', :'root') = 1 and tl_test.v2_qty(:'ca', :'tonic') = 1
  and tl_test.v2_qty(:'ca', 'herbalism-kit') = 1 and not :'lock_before'::boolean and tl_test.v2_locked(:'root') and tl_test.v2_locked(:'tonic'),
  left(:'res', 300));
select tl_test.v2_locked(:'manual') as lock_manual \gset
select tl_test.rec('V9b learning took the 4242 lock of the recipe item (same transaction)', :'lock_manual'::boolean, :'lock_manual');
-- the tool vanished between start and approval -> apply_failed
select tl_test.as_user(:'alice');
select tl_test.give(:'ca', :'root', null, 2);
select public.start_craft_attempt(:'ca', :'r1', jsonb_build_array(tl_test.v2_sel(1, tl_test.v2_row(:'ca', :'root'), 2)), 15, gen_random_uuid()) as att2 \gset
select public.remove_inventory_item(:'kit_row', null);
select tl_test.as_user(:'dm');
select public.dm_resolve_craft_attempt((:'att2'::jsonb ->> 'attempt_id')::uuid, 'approve') as res2 \gset
select tl_test.as_root();
select tl_test.rec('V10 the tool removed before approval: apply_failed with a fixed text, nothing consumed',
  :'res2'::jsonb ->> 'status' = 'apply_failed' and :'res2'::jsonb ->> 'apply_error' = 'The tool for this recipe is no longer in the inventory'
  and tl_test.v2_qty(:'ca', :'root') >= 2, left(:'res2', 300));

-- ---- governance off ---------------------------------------------------------------------------------------------------------------
select tl_test.as_user(:'dm');
select public.set_campaign_governance(:'camp', '{"overrides": {"inventory.craft": "disabled"}}');
select tl_test.as_user(:'alice');
select tl_test.v2_code(format('select public.learn_recipe_from_item(%L)', :'scroll_row')) as off_learn \gset
select tl_test.v2_code(format('select public.get_inventory_item_recipes(%L)', :'scroll_row')) as off_info \gset
select tl_test.as_root();
select tl_test.rec('V11 crafting turned off: learn and the item read are refused (TLDIS)', :'off_learn' = 'TLDIS' and :'off_info' = 'TLDIS',
  concat_ws(',', :'off_learn', :'off_info'));
