-- =============================================================================
-- Simple crafting (20261115000100, docs/CRAFTING_V1.md "Simple crafting (?v=42)"): start_craft_batch (N batches in one atomic
-- attempt, one request id), a roll only with a DC, the 2-step chain plant -> extract -> potion, a recipe shaped like the production
-- one (known, approval, DC 15, alchemists-supplies, one exact ingredient x3, a manual teacher consume_on_learn, lose_all, acid-vial
-- failure result, crit bonus 1) through the old and the new start, equipped / attuned / quest / charged rows never used up, an
-- unidentified ingredient never matches (byte-identical read, the one fixed refusal), the DM sees batches and cannot craft for a
-- player. Runs inside the per-class harness (alice = player of :camp, bob = made a player here, dm = DM of :camp).
-- =============================================================================
\set ca f8c00000-0000-0000-0000-0000000000a1
\set cb f8c00000-0000-0000-0000-0000000000b2
insert into public.campaign_members (campaign_id, user_id, role) values (:'camp', :'bob', 'player') on conflict do nothing;
insert into public.characters (id, owner_id, name, campaign_id, level, strength, dexterity, constitution, intelligence, wisdom, charisma, hp_max, hp_current, speed) values
  (:'ca', :'alice', 'Simple Crafter A', :'camp', 1, 10, 12, 12, 10, 14, 10, 10, 10, 30),
  (:'cb', :'bob', 'Simple Crafter B', :'camp', 1, 10, 12, 12, 10, 14, 10, 10, 10, 30);
create function tl_test.s_msg(p_sql text) returns text language plpgsql as $$
begin execute p_sql; return 'ok'; exception when others then return sqlstate || ' ' || sqlerrm; end $$;
create function tl_test.s_qty(p_char uuid, p_item text) returns int language sql security definer as $$
  select coalesce(sum(ii.quantity), 0)::int from public.inventory_items ii join public.inventories inv on inv.id = ii.inventory_id
  where inv.character_id = p_char and ii.item_id = p_item $$;
create function tl_test.s_sel(p_seq int, p_row uuid, p_qty int) returns jsonb language sql as $$
  select jsonb_build_object('seq', p_seq, 'inventory_item_id', p_row, 'quantity', p_qty) $$;
create function tl_test.s_rec(p_read jsonb, p_recipe uuid) returns jsonb language sql as $$
  select r from jsonb_array_elements(p_read -> 'recipes') r where r ->> 'recipe_id' = p_recipe::text $$;
create function tl_test.s_cands(p_read jsonb, p_recipe uuid, p_seq int) returns text language sql as $$
  select coalesce(string_agg(c ->> 'inventory_item_id', ',' order by c ->> 'inventory_item_id'), '')
  from jsonb_array_elements(tl_test.s_rec(p_read, p_recipe) -> 'ingredients') g, jsonb_array_elements(g -> 'candidates') c
  where (g ->> 'seq')::int = p_seq $$;
grant all on all functions in schema tl_test to public;

-- ---- fixtures (DM) ---------------------------------------------------------------------------------------------------------------
select tl_test.as_user(:'dm');
select public.set_campaign_governance(:'camp', '{"overrides": {"inventory.craft": "player_managed"}}');
select public.create_homebrew_item(gen_random_uuid(), jsonb_build_object('name', 'Silverleaf', 'kind_id', 'herbs_plants', 'category_id', 'plant-flower',
  'campaign_id', :'camp', 'stackable', true)) ->> 'id' as leaf \gset
select public.create_homebrew_item(gen_random_uuid(), jsonb_build_object('name', 'Silverleaf Extract', 'kind_id', 'gear', 'campaign_id', :'camp', 'stackable', true)) ->> 'id' as extract \gset
select public.create_homebrew_item(gen_random_uuid(), jsonb_build_object('name', 'Rough Salts', 'kind_id', 'gear', 'campaign_id', :'camp', 'stackable', true)) ->> 'id' as salts \gset
select public.create_homebrew_item(gen_random_uuid(), jsonb_build_object('name', 'Alchemy Manual', 'kind_id', 'gear', 'campaign_id', :'camp')) ->> 'id' as manual \gset
-- r_ex: 2 Silverleaf -> 1 Extract, herbalism kit carried, no DC, instant (the simple editor's defaults)
select public.dm_save_recipe(:'camp', jsonb_build_object('name', 'Silverleaf Extract', 'dm_notes', 'SENTINEL-T8NOTE', 'visibility', 'known',
  'requires_dm_approval', false, 'check_key', 'herbalism-kit', 'output_item_id', :'extract',
  'ingredients', jsonb_build_array(jsonb_build_object('item_id', :'leaf', 'quantity', 2)))) ->> 'id' as r_ex \gset
select public.dm_set_recipe_status(:'r_ex', 'published');
-- r_pot: 1 Extract + 1 Rough Salts -> Potion of Healing, alchemist's supplies carried, instant
select public.dm_save_recipe(:'camp', jsonb_build_object('name', 'Healing Draught', 'requires_dm_approval', false, 'check_key', 'alchemists-supplies',
  'output_item_id', 'potion-of-healing-common',
  'ingredients', jsonb_build_array(jsonb_build_object('item_id', :'extract', 'quantity', 1), jsonb_build_object('item_id', :'salts', 'quantity', 1)))) ->> 'id' as r_pot \gset
select public.dm_set_recipe_status(:'r_pot', 'published');
-- r_old: shaped like the production recipe (published copy)
select public.dm_save_recipe(:'camp', jsonb_build_object('name', 'Old Shape Potion', 'visibility', 'known', 'requires_dm_approval', true,
  'check_key', 'alchemists-supplies', 'check_dc', 15, 'failure_mode', 'lose_all', 'failure_output_item_id', 'acid-vial', 'crit_bonus_quantity', 1,
  'output_item_id', 'potion-of-healing-common', 'ingredients', jsonb_build_array(jsonb_build_object('item_id', :'leaf', 'quantity', 3, 'consumed', true)),
  'teachers', jsonb_build_array(jsonb_build_object('item_id', :'manual', 'consumed', true)))) ->> 'id' as r_old \gset
select public.dm_set_recipe_status(:'r_old', 'published');
-- r_arch: the same shape, archived (as production)
select public.dm_save_recipe(:'camp', jsonb_build_object('name', 'Archived Shape', 'visibility', 'known', 'requires_dm_approval', true,
  'check_key', 'alchemists-supplies', 'check_dc', 15, 'failure_mode', 'lose_all', 'failure_output_item_id', 'acid-vial', 'crit_bonus_quantity', 1,
  'output_item_id', 'potion-of-healing-common', 'ingredients', jsonb_build_array(jsonb_build_object('item_id', :'leaf', 'quantity', 3, 'consumed', true)),
  'teachers', jsonb_build_array(jsonb_build_object('item_id', :'manual', 'consumed', true)))) ->> 'id' as r_arch \gset
select public.dm_set_recipe_status(:'r_arch', 'published');
select public.dm_set_recipe_status(:'r_arch', 'archived');
select tl_test.as_root();
select public._craft_recipe_dm(:'r_arch') - 'updated_at' - 'pending' - 'attempts' as arch_before \gset

-- ---- S1 instant craft through the simple start (tool without a DC: no roll) --------------------------------------------------------
select tl_test.as_user(:'alice');
select tl_test.give(:'ca', 'herbalism-kit') as kit_row \gset
select tl_test.give(:'ca', :'leaf', null, 4) as leaf_a \gset
select public.get_character_recipes(:'ca') as read1 \gset
select tl_test.s_msg(format('select public.start_craft_attempt(%L, %L, %L::jsonb, null, gen_random_uuid())', :'ca', :'r_ex',
  jsonb_build_array(tl_test.s_sel(1, :'leaf_a', 2)))) as old_needs_roll \gset
select gen_random_uuid() as req1 \gset
select public.start_craft_batch(:'ca', :'r_ex', jsonb_build_array(tl_test.s_sel(1, :'leaf_a', 2)), 1, null, :'req1') as s1 \gset
select tl_test.as_root();
select tl_test.rec('S1 instant: start_craft_batch applies at once without a roll (2 Silverleaf -> 1 Extract, the kit kept); remove + add events carry metadata.craft_attempt; the old start_craft_attempt still asks for a roll (v1 behaviour unchanged)',
  :'s1'::jsonb ->> 'status' = 'applied' and (:'s1'::jsonb ->> 'batches')::int = 1 and tl_test.s_qty(:'ca', :'leaf') = 2
  and tl_test.s_qty(:'ca', :'extract') = 1 and tl_test.s_qty(:'ca', 'herbalism-kit') = 1
  and (select count(*) from public.inventory_events e where e.metadata ->> 'craft_attempt' = :'s1'::jsonb ->> 'attempt_id' and e.action in ('remove', 'add')) = 2
  and :'old_needs_roll' like '22023 Enter the total of your roll%'
  and (tl_test.s_rec(:'read1'::jsonb, :'r_ex') ->> 'can_craft')::boolean and not (tl_test.s_rec(:'read1'::jsonb, :'r_ex') ->> 'dm_confirms')::boolean,
  concat_ws(' | ', left(:'s1', 300), :'old_needs_roll'));

-- ---- S2 double click: the same request id is applied once ------------------------------------------------------------------------------
select tl_test.as_user(:'alice');
select public.start_craft_batch(:'ca', :'r_ex', jsonb_build_array(tl_test.s_sel(1, :'leaf_a', 2)), 1, null, :'req1') as s2 \gset
select tl_test.as_root();
select tl_test.rec('S2 double click: a repeat with the same request id replays the first attempt (one attempt, one consume)',
  (:'s2'::jsonb ->> 'replayed')::boolean and :'s2'::jsonb ->> 'attempt_id' = :'s1'::jsonb ->> 'attempt_id'
  and tl_test.s_qty(:'ca', :'leaf') = 2 and tl_test.s_qty(:'ca', :'extract') = 1
  and (select count(*) from public.crafting_attempts where character_id = :'ca' and request_id = :'req1') = 1, left(:'s2', 200));

-- ---- S3 missing ingredient, bounds ----------------------------------------------------------------------------------------------------
select tl_test.as_user(:'alice');
select tl_test.s_msg(format('select public.start_craft_batch(%L, %L, %L::jsonb, 2, null, gen_random_uuid())', :'ca', :'r_ex',
  jsonb_build_array(tl_test.s_sel(1, :'leaf_a', 2)))) as miss_cover \gset
select tl_test.s_msg(format('select public.start_craft_batch(%L, %L, %L::jsonb, 2, null, gen_random_uuid())', :'ca', :'r_ex',
  jsonb_build_array(tl_test.s_sel(1, :'leaf_a', 4)))) as miss_stack \gset
select tl_test.s_msg(format('select public.start_craft_batch(%L, %L, %L::jsonb, 1, null, gen_random_uuid())', :'ca', :'r_pot',
  jsonb_build_array(tl_test.s_sel(1, (select ii.id from public.inventory_items ii join public.inventories inv on inv.id = ii.inventory_id
                                      where inv.character_id = :'ca' and ii.item_id = :'extract' limit 1), 1)))) as miss_line \gset
select tl_test.s_msg(format('select public.start_craft_batch(%L, %L, %L::jsonb, 21, null, gen_random_uuid())', :'ca', :'r_ex',
  jsonb_build_array(tl_test.s_sel(1, :'leaf_a', 2)))) as b21 \gset
select tl_test.s_msg(format('select public.start_craft_batch(%L, %L, %L::jsonb, 0, null, gen_random_uuid())', :'ca', :'r_ex',
  jsonb_build_array(tl_test.s_sel(1, :'leaf_a', 2)))) as b0 \gset
select tl_test.s_msg(format('select public.start_craft_batch(%L, %L, %L::jsonb, 1, null, gen_random_uuid(), %L)', :'ca', :'r_ex',
  jsonb_build_array(tl_test.s_sel(1, :'leaf_a', 2)), 'nat20')) as nat_nodc \gset
select tl_test.as_root();
select tl_test.rec('S3 refusals change nothing: too few for 2 batches, a stack too small, a missing line (no salts), 21 / 0 batches, a natural roll without a DC',
  :'miss_cover' = '22023 Choose exactly what the recipe needs for each ingredient' and :'miss_stack' = '22023 Not enough items in that stack'
  and :'miss_line' = '22023 Choose exactly what the recipe needs for each ingredient'
  and :'b21' = '22023 Craft 1 to 20 at a time' and :'b0' = '22023 Craft 1 to 20 at a time' and :'nat_nodc' = '22023 This recipe has no roll'
  and tl_test.s_qty(:'ca', :'leaf') = 2 and tl_test.s_qty(:'ca', :'extract') = 1
  and (select count(*) from public.crafting_attempts where character_id = :'ca') = 1,
  concat_ws(' | ', :'miss_cover', :'miss_stack', :'miss_line', :'b21', :'b0', :'nat_nodc'));

-- ---- S4 N batches from several stacks, atomic; S5 the chain plant -> extract -> potion ---------------------------------------------
-- two more separate Silverleaf stacks (1 and 3; written directly so that no auto merge joins them)
insert into public.inventory_items (inventory_id, item_id, quantity, name, notes)
select inventory_id, item_id, 1, name, 'stack B' from public.inventory_items where id = :'leaf_a' returning id as leaf_b \gset
insert into public.inventory_items (inventory_id, item_id, quantity, name, notes)
select inventory_id, item_id, 3, name, 'stack C' from public.inventory_items where id = :'leaf_a' returning id as leaf_c \gset
select tl_test.as_user(:'alice');
select tl_test.s_qty(:'ca', :'leaf') as leaf_total \gset
select public.start_craft_batch(:'ca', :'r_ex', jsonb_build_array(tl_test.s_sel(1, :'leaf_a', 2), tl_test.s_sel(1, :'leaf_b', 1), tl_test.s_sel(1, :'leaf_c', 3)),
  3, null, gen_random_uuid()) as s4 \gset
select tl_test.as_root();
select tl_test.rec('S4 three batches in one attempt from three stacks (2 + 1 + 3 Silverleaf): 6 used, 3 Extracts made, batches 3, one attempt',
  :'leaf_total'::int = 6 and :'s4'::jsonb ->> 'status' = 'applied' and (:'s4'::jsonb ->> 'batches')::int = 3
  and tl_test.s_qty(:'ca', :'leaf') = 0 and tl_test.s_qty(:'ca', :'extract') = 4
  and (select batches from public.crafting_attempts where id = (:'s4'::jsonb ->> 'attempt_id')::uuid) = 3,
  left(:'s4', 300));
select tl_test.as_user(:'alice');
select tl_test.give(:'ca', 'alchemists-supplies') as sup_row \gset
select tl_test.give(:'ca', :'salts', null, 3) as salts_row \gset
select (select ii.id from public.inventory_items ii join public.inventories inv on inv.id = ii.inventory_id
        where inv.character_id = :'ca' and ii.item_id = :'extract' order by ii.quantity desc limit 1) as ext_row \gset
-- 4 potions would need 4 salts: refused, nothing changes (all or nothing)
select tl_test.s_msg(format('select public.start_craft_batch(%L, %L, %L::jsonb, 4, null, gen_random_uuid())', :'ca', :'r_pot',
  jsonb_build_array(tl_test.s_sel(1, :'ext_row', 4), tl_test.s_sel(2, :'salts_row', 4)))) as s5_over \gset
select public.start_craft_batch(:'ca', :'r_pot', jsonb_build_array(tl_test.s_sel(1, :'ext_row', 3), tl_test.s_sel(2, :'salts_row', 3)), 3, null, gen_random_uuid()) as s5 \gset
select tl_test.as_root();
select tl_test.rec('S5 chain: Silverleaf -> Extract -> Potion of Healing (3 batches: 3 Extract + 3 Salts used, 3 potions); 4 batches with 3 salts refused and nothing used',
  :'s5_over' = '22023 Not enough items in that stack' and :'s5'::jsonb ->> 'status' = 'applied'
  and tl_test.s_qty(:'ca', :'extract') = 1 and tl_test.s_qty(:'ca', :'salts') = 0 and tl_test.s_qty(:'ca', 'potion-of-healing-common') = 3
  and tl_test.s_qty(:'ca', 'alchemists-supplies') = 1,
  concat_ws(' | ', :'s5_over', left(:'s5', 200)));

-- ---- S6 the production-shaped recipe: old start (pending -> approve), new start with 2 batches (critical success) ------------------
select tl_test.as_user(:'alice');
select tl_test.give(:'ca', :'leaf', null, 9) as leaf_d \gset
select public.get_character_recipes(:'ca') as read6 \gset
select public.start_craft_attempt(:'ca', :'r_old', jsonb_build_array(tl_test.s_sel(1, :'leaf_d', 3)), 16, gen_random_uuid()) as s6a \gset
select tl_test.s_msg(format('select public.start_craft_batch(%L, %L, %L::jsonb, 2, null, gen_random_uuid())', :'ca', :'r_old',
  jsonb_build_array(tl_test.s_sel(1, :'leaf_d', 6)))) as s6_noroll \gset
select tl_test.as_user(:'dm');
select public.dm_resolve_craft_attempt((:'s6a'::jsonb ->> 'attempt_id')::uuid, 'approve') as s6a_res \gset
select tl_test.as_user(:'alice');
select tl_test.s_msg(format('select public.start_craft_batch(%L, %L, %L::jsonb, 2, 18, gen_random_uuid(), %L)', :'ca', :'r_old',
  jsonb_build_array(tl_test.s_sel(1, :'leaf_d', 6)), 'nat20')) as s6b_try \gset
select tl_test.as_root();
select (select a.id from public.crafting_attempts a where a.character_id = :'ca' and a.recipe_id = :'r_old' and a.status = 'pending') as s6b_id \gset
select tl_test.as_user(:'alice');
select tl_test.s_msg(format('select public.start_craft_batch(%L, %L, %L::jsonb, 1, 18, gen_random_uuid())', :'ca', :'r_old',
  jsonb_build_array(tl_test.s_sel(1, :'leaf_d', 3)))) as s6_second_pending \gset
select tl_test.as_user(:'dm');
select public.get_campaign_craft_attempts(:'camp') as inbox6 \gset
select public.dm_resolve_craft_attempt(:'s6b_id', 'approve', 'critical_success') as s6b_res \gset
select public.get_campaign_recipes(:'camp') as dm_all \gset
select tl_test.s_msg(format('select public.dm_save_recipe(%L, %L::jsonb)', :'camp', jsonb_build_object('id', :'r_arch', 'name', 'x',
  'output_item_id', 'potion-of-healing-common', 'ingredients', jsonb_build_array(jsonb_build_object('item_id', :'leaf'))))) as arch_save \gset
select tl_test.as_root();
select public._craft_recipe_dm(:'r_arch') - 'updated_at' - 'pending' - 'attempts' as arch_after \gset
select tl_test.rec('S6a production shape, old start: the player read shows DC 15, the tool and "DM confirms"; pending with roll 16 -> DM approve -> applied (3 Silverleaf used, 1 potion); the new start without a roll is refused (DC)',
  (tl_test.s_rec(:'read6'::jsonb, :'r_old') -> 'check' ->> 'dc')::int = 15 and (tl_test.s_rec(:'read6'::jsonb, :'r_old') ->> 'dm_confirms')::boolean
  and tl_test.s_rec(:'read6'::jsonb, :'r_old') -> 'tool' ->> 'item_id' = 'alchemists-supplies'
  and :'s6a'::jsonb ->> 'status' = 'pending' and :'s6a_res'::jsonb ->> 'status' = 'applied' and :'s6a_res'::jsonb ->> 'outcome' = 'success'
  and :'s6_noroll' like '22023 Enter the total of your roll%',
  concat_ws(' | ', left(:'s6a_res', 200), :'s6_noroll'));
select tl_test.rec('S6b production shape, new start: 2 batches with a nat20 -> pending (one per character and recipe: a second start is refused 55000); the DM queue shows batches 2; critical success uses 6 and makes 2 x 1 + bonus 1 = 3 potions',
  :'s6b_try' = 'ok' and :'s6b_id' <> '' and :'s6_second_pending' like '55000%'
  and (select (x ->> 'batches')::int from jsonb_array_elements(:'inbox6'::jsonb) x where x ->> 'attempt_id' = :'s6b_id') = 2
  and :'s6b_res'::jsonb ->> 'status' = 'applied' and tl_test.s_qty(:'ca', :'leaf') = 0
  and tl_test.s_qty(:'ca', 'potion-of-healing-common') = 3 + 1 + 3,
  concat_ws(' | ', :'s6b_try', :'s6_second_pending', left(:'s6b_res', 300)));
select tl_test.rec('S6c the archived production-shaped recipe is untouched and answers as before: same fields (known, approval, DC 15, alchemists-supplies, lose_all, acid-vial, crit 1, ingredient x3, manual consume_on_learn), listed for the DM, not in the player read, editing refused 55000',
  :'arch_before' = :'arch_after' and :'arch_after'::jsonb ->> 'status' = 'archived' and :'arch_after'::jsonb ->> 'visibility' = 'known'
  and (:'arch_after'::jsonb ->> 'requires_dm_approval')::boolean and (:'arch_after'::jsonb ->> 'check_dc')::int = 15
  and :'arch_after'::jsonb ->> 'check_key' = 'alchemists-supplies' and :'arch_after'::jsonb ->> 'failure_mode' = 'lose_all'
  and :'arch_after'::jsonb ->> 'failure_output_item_id' = 'acid-vial' and (:'arch_after'::jsonb ->> 'crit_bonus_quantity')::int = 1
  and (:'arch_after'::jsonb -> 'ingredients' -> 0 ->> 'quantity')::int = 3 and (:'arch_after'::jsonb -> 'teachers' -> 0 ->> 'consume_on_learn')::boolean
  and (select count(*) from jsonb_array_elements(:'dm_all'::jsonb -> 'recipes') r where r ->> 'id' = :'r_arch') = 1
  and tl_test.s_rec(:'read6'::jsonb, :'r_arch') is null and :'arch_save' like '55000%',
  :'arch_save');

-- ---- S7 equipped / attuned / quest / charged rows are never used up ---------------------------------------------------------------
select tl_test.as_user(:'dm');
select public.create_homebrew_item(gen_random_uuid(), jsonb_build_object('name', 'Spark Shard', 'kind_id', 'gear', 'campaign_id', :'camp', 'stackable', true)) ->> 'id' as shard \gset
select public.create_homebrew_item(gen_random_uuid(), jsonb_build_object('name', 'Zap Rod', 'kind_id', 'gear', 'campaign_id', :'camp', 'stackable', true)) ->> 'id' as rod \gset
select public.dm_save_recipe(:'camp', jsonb_build_object('name', 'Shard Dust', 'requires_dm_approval', false, 'output_item_id', :'salts',
  'ingredients', jsonb_build_array(jsonb_build_object('item_id', :'shard', 'quantity', 1)))) ->> 'id' as r_sh \gset
select public.dm_set_recipe_status(:'r_sh', 'published');
select public.dm_save_recipe(:'camp', jsonb_build_object('name', 'Rod Dust', 'requires_dm_approval', false, 'output_item_id', :'salts',
  'ingredients', jsonb_build_array(jsonb_build_object('item_id', :'rod', 'quantity', 1)))) ->> 'id' as r_rod \gset
select public.dm_set_recipe_status(:'r_rod', 'published');
select tl_test.as_user(:'alice');
select tl_test.give(:'ca', :'shard') as sh_charged \gset
select tl_test.give(:'ca', :'rod') as rod_row \gset
select tl_test.as_root();
-- separate rows: one with charges, one attuned, one quest item, and a rod whose item has a weapon action with uses
update public.inventory_items set charges_max = 3, charges_current = 2, notes = 'charged' where id = :'sh_charged';
update public.items set requires_attunement = true where id = :'shard';   -- so that a row of it can be attuned
insert into public.inventory_items (inventory_id, item_id, quantity, name, notes, is_attuned)
select inventory_id, item_id, 1, name, 'attuned', true from public.inventory_items where id = :'sh_charged' returning id as sh_att \gset
insert into public.inventory_items (inventory_id, item_id, quantity, name, notes, is_quest_item)
select inventory_id, item_id, 1, name, 'quest', true from public.inventory_items where id = :'sh_charged' returning id as sh_quest \gset
insert into public.item_weapon_blocks (item_id, block_type, seq, name, action_cost, roll, uses, recharge) values (:'rod', 'action', 1, 'Zap', 'action', 'none', 1, 'long_rest');
select tl_test.as_user(:'alice');
select public.get_character_recipes(:'ca') as read7 \gset
select tl_test.s_msg(format('select public.start_craft_batch(%L, %L, %L::jsonb, 1, null, gen_random_uuid())', :'ca', :'r_sh',
  jsonb_build_array(tl_test.s_sel(1, :'sh_charged', 1)))) as c_new \gset
select tl_test.s_msg(format('select public.start_craft_attempt(%L, %L, %L::jsonb, null, gen_random_uuid())', :'ca', :'r_sh',
  jsonb_build_array(tl_test.s_sel(1, :'sh_charged', 1)))) as c_old \gset
select tl_test.s_msg(format('select public.start_craft_batch(%L, %L, %L::jsonb, 1, null, gen_random_uuid())', :'ca', :'r_sh',
  jsonb_build_array(tl_test.s_sel(1, :'sh_att', 1)))) as c_att \gset
select tl_test.s_msg(format('select public.start_craft_batch(%L, %L, %L::jsonb, 1, null, gen_random_uuid())', :'ca', :'r_sh',
  jsonb_build_array(tl_test.s_sel(1, :'sh_quest', 1)))) as c_quest \gset
select tl_test.s_msg(format('select public.start_craft_batch(%L, %L, %L::jsonb, 1, null, gen_random_uuid())', :'ca', :'r_rod',
  jsonb_build_array(tl_test.s_sel(1, :'rod_row', 1)))) as c_rod \gset
select tl_test.as_root();
select tl_test.rec('S7 charged (charges 2/3), attuned, quest rows and an item with its own uses are never offered (have 0, no candidates) and are refused by the new and the old start; nothing used',
  (tl_test.s_rec(:'read7'::jsonb, :'r_sh') -> 'ingredients' -> 0 ->> 'have')::int = 0 and tl_test.s_cands(:'read7'::jsonb, :'r_sh', 1) = ''
  and (tl_test.s_rec(:'read7'::jsonb, :'r_rod') -> 'ingredients' -> 0 ->> 'have')::int = 0
  and :'c_new' like '22023 Equipped, attuned or quest items, items with charges%' and :'c_old' like '22023 Equipped, attuned or quest items%'
  and :'c_att' like '22023 Equipped, attuned%' and :'c_quest' like '22023 Equipped, attuned%' and :'c_rod' like '22023 Equipped, attuned%'
  and tl_test.s_qty(:'ca', :'shard') = 3 and tl_test.s_qty(:'ca', :'rod') = 1 and not public._craft_row_free(:'sh_charged')
  and not public._craft_row_free(:'rod_row'),
  concat_ws(' | ', :'c_new', :'c_old', :'c_att', :'c_quest', :'c_rod'));
-- an equipped row
select tl_test.as_user(:'dm');
select public.dm_save_recipe(:'camp', jsonb_build_object('name', 'Melt a Dagger', 'requires_dm_approval', false, 'output_item_id', :'salts',
  'ingredients', jsonb_build_array(jsonb_build_object('item_id', 'dagger', 'quantity', 1)))) ->> 'id' as r_dag \gset
select public.dm_set_recipe_status(:'r_dag', 'published');
select tl_test.as_user(:'alice');
select tl_test.give(:'ca', 'dagger', 'main_hand') as dag_row \gset
select public.get_character_recipes(:'ca') as read7b \gset
select tl_test.s_msg(format('select public.start_craft_batch(%L, %L, %L::jsonb, 1, null, gen_random_uuid())', :'ca', :'r_dag',
  jsonb_build_array(tl_test.s_sel(1, :'dag_row', 1)))) as c_eq \gset
select tl_test.as_root();
select tl_test.rec('S7b an equipped dagger is not offered and is refused; it stays',
  tl_test.s_cands(:'read7b'::jsonb, :'r_dag', 1) = '' and :'c_eq' like '22023 Equipped, attuned%' and tl_test.s_qty(:'ca', 'dagger') = 1,
  :'c_eq');

-- ---- S8 an unidentified ingredient never matches (read byte-identical, the one fixed refusal) -------------------------------------
select tl_test.as_user(:'dm');
select public.set_item_identify_options(:'leaf', '{"unidentified_name": "Pale weed"}');
select tl_test.as_user(:'bob');
select tl_test.give(:'cb', 'herbalism-kit');
select public.get_character_recipes(:'cb')::text as b_none \gset
select tl_test.as_user(:'dm');
select public.dm_give_item(:'leaf', array[:'cb']::uuid[], 4, false);
select tl_test.as_root();
select (select ii.id from public.inventory_items ii join public.inventories inv on inv.id = ii.inventory_id
        where inv.character_id = :'cb' and ii.item_id = :'leaf' limit 1) as b_leaf \gset
select tl_test.as_user(:'bob');
select public.get_character_recipes(:'cb')::text as b_with \gset
select tl_test.s_msg(format('select public.start_craft_batch(%L, %L, %L::jsonb, 2, null, gen_random_uuid())', :'cb', :'r_ex',
  jsonb_build_array(tl_test.s_sel(1, :'b_leaf', 4)))) as b_try \gset
select tl_test.as_root();
select tl_test.rec('S8 a disguised matching herb: bob''s read is byte-identical with it and without it; the simple start is refused with the fixed text; nothing used',
  :'b_none' = :'b_with' and :'b_try' = '22023 You don''t know what this ingredient is yet' and tl_test.s_qty(:'cb', :'leaf') = 4
  and (select count(*) from public.crafting_attempts where character_id = :'cb') = 0,
  concat_ws(' | ', :'b_none' = :'b_with', :'b_try'));

-- ---- S9 who crafts; hidden data -------------------------------------------------------------------------------------------------------
select tl_test.as_user(:'dm');
select public.get_character_recipes(:'ca')::text as dm_reads \gset
select tl_test.s_msg(format('select public.start_craft_batch(%L, %L, %L::jsonb, 1, null, gen_random_uuid())', :'ca', :'r_ex',
  jsonb_build_array(tl_test.s_sel(1, :'leaf_d', 2)))) as dm_crafts \gset
select tl_test.as_user(:'bob');
select tl_test.s_msg(format('select public.start_craft_batch(%L, %L, %L::jsonb, 1, null, gen_random_uuid())', :'ca', :'r_ex',
  jsonb_build_array(tl_test.s_sel(1, :'leaf_d', 2)))) as other_crafts \gset
select tl_test.as_root();
select tl_test.rec('S9 the DM reads the character''s crafting (recipes listed) but cannot craft for the player (42501), nor can another player; the player outputs carry no DM notes, no check_dc key',
  position('Silverleaf Extract' in :'dm_reads') > 0 and :'dm_crafts' like '42501%' and :'other_crafts' like '42501%'
  and position('SENTINEL-T8NOTE' in :'read1') = 0 and position('SENTINEL-T8NOTE' in :'s1') = 0 and position('"check_dc"' in :'read6') = 0
  and position('dm_private_note' in :'s4') = 0,
  concat_ws(' | ', :'dm_crafts', :'other_crafts'));

-- ---- S10 the rule off: the simple start is refused ------------------------------------------------------------------------------------
select tl_test.as_user(:'dm');
select public.set_campaign_governance(:'camp', '{"overrides": {"inventory.craft": "disabled"}}');
select tl_test.as_user(:'alice');
select tl_test.s_msg(format('select public.start_craft_batch(%L, %L, %L::jsonb, 1, null, gen_random_uuid())', :'ca', :'r_ex',
  jsonb_build_array(tl_test.s_sel(1, :'leaf_d', 2)))) as off_try \gset
select tl_test.as_root();
select tl_test.rec('S10 crafting turned off: start_craft_batch refused (TLDIS)', :'off_try' like 'TLDIS%', :'off_try');
select tl_test.rec('S11 grants: start_craft_batch is executable by authenticated, _craft_item_has_uses is not',
  has_function_privilege('authenticated', 'public.start_craft_batch(uuid, uuid, jsonb, int, int, uuid, text, text)', 'execute')
  and not has_function_privilege('authenticated', 'public._craft_item_has_uses(text)', 'execute')
  and not has_function_privilege('anon', 'public.start_craft_batch(uuid, uuid, jsonb, int, int, uuid, text, text)', 'execute'), '');
