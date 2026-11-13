-- =============================================================================
-- Crafting v1 (20261113000100, docs/CRAFTING_V1.md): governance off-switch (players refused while the DM manages recipes), auto
-- craft (consume + produce in one transaction, inventory_events remove / add with metadata.craft_attempt), the DC / approval
-- constraint, pending -> DM approve with an edited roll, reject, approve as failure (failure rule, junk result), apply_failed when
-- ingredients vanished, idempotent request ids, exactly-once answers, the knowledge rule (an unidentified row never matches and
-- the player read is byte-identical with or without it; one fixed refusal), secret result labels, recipe discovery, refusals of
-- equipped / quest / other characters' rows, hidden data never in player reads or tables (REST), the deletion report, cache and
-- Realtime wiring. Runs inside the per-class harness (alice = player of :camp, bob = made a player here, dm = DM of :camp).
-- Rollback / reapply of the migration is done by the runner (docs/CRAFTING_V1.md "Tests").
-- =============================================================================
\set ca f6c00000-0000-0000-0000-000000000001
\set cb f6c00000-0000-0000-0000-000000000002
\set eve e6666666-6666-6666-6666-666666666666
insert into public.campaign_members (campaign_id, user_id, role) values (:'camp', :'bob', 'player');
insert into auth.users (id, email) values (:'eve', 'eve-craft@test');
insert into public.characters (id, owner_id, name, campaign_id, level, strength, dexterity, constitution, intelligence, wisdom, charisma, hp_max, hp_current, speed) values
  (:'ca', :'alice', 'Crafter A', :'camp', 1, 10, 12, 12, 10, 14, 10, 10, 10, 30),
  (:'cb', :'bob', 'Crafter B', :'camp', 1, 10, 12, 12, 10, 14, 10, 10, 10, 30);
create function tl_test.cr_code(p_sql text) returns text language plpgsql as $$
begin execute p_sql; return 'ok'; exception when others then return sqlstate; end $$;
create function tl_test.cr_msg(p_sql text) returns text language plpgsql as $$
begin execute p_sql; return 'ok'; exception when others then return sqlstate || ' ' || sqlerrm; end $$;
create function tl_test.cr_qty(p_char uuid, p_item text) returns int language sql security definer as $$
  select coalesce(sum(ii.quantity), 0)::int from public.inventory_items ii join public.inventories inv on inv.id = ii.inventory_id
  where inv.character_id = p_char and ii.item_id = p_item $$;
create function tl_test.cr_row(p_char uuid, p_item text) returns uuid language sql security definer as $$
  select ii.id from public.inventory_items ii join public.inventories inv on inv.id = ii.inventory_id
  where inv.character_id = p_char and ii.item_id = p_item order by ii.quantity desc, ii.id limit 1 $$;
create function tl_test.cr_att(p_id uuid) returns public.crafting_attempts language sql security definer as $$
  select * from public.crafting_attempts where id = p_id $$;
create function tl_test.cr_events(p_attempt uuid, p_action text) returns int language sql security definer as $$
  select count(*)::int from public.inventory_events where metadata ->> 'craft_attempt' = p_attempt::text and action = p_action $$;
create function tl_test.cr_sel(p_seq int, p_row uuid, p_qty int) returns jsonb language sql as $$
  select jsonb_build_object('seq', p_seq, 'inventory_item_id', p_row, 'quantity', p_qty) $$;
-- one recipe of the player read
create function tl_test.cr_rec(p_read jsonb, p_recipe uuid) returns jsonb language sql as $$
  select r from jsonb_array_elements(p_read -> 'recipes') r where r ->> 'recipe_id' = p_recipe::text $$;
-- player-safe text: none of the DM-only key names or sentinels
create function tl_test.cr_clean(p_text text) returns boolean language sql as $$
  select position('"check_dc"' in p_text) = 0 and position('"dc"' in p_text) = 0 and position('dm_notes' in p_text) = 0
     and position('dm_private_note' in p_text) = 0 and position('SENTINEL-DMNOTE' in p_text) = 0 and position('SENTINEL-PRIVATE' in p_text) = 0
     and position('Starmoss' in p_text) = 0 and position('crit_output' in p_text) = 0 and position('failure_output' in p_text) = 0 $$;
grant all on all functions in schema tl_test to public;

-- ---- fixtures (DM): campaign items ---------------------------------------------------------------------------------------------
select tl_test.as_user(:'dm');
select public.create_homebrew_item(gen_random_uuid(), jsonb_build_object('name', 'Moonleaf', 'kind_id', 'herbs_plants', 'category_id', 'plant-flower',
  'campaign_id', :'camp', 'stackable', true, 'description', 'Silver leaf.', 'details', jsonb_build_object('ingredient_tags', jsonb_build_array('silver', 'calming')))) ->> 'id' as leaf \gset
select public.create_homebrew_item(gen_random_uuid(), jsonb_build_object('name', 'Mortar', 'kind_id', 'gear', 'campaign_id', :'camp')) ->> 'id' as mortar \gset
select public.create_homebrew_item(gen_random_uuid(), jsonb_build_object('name', 'Healing Draught', 'kind_id', 'gear', 'campaign_id', :'camp', 'stackable', true)) ->> 'id' as draught \gset
select public.create_homebrew_item(gen_random_uuid(), jsonb_build_object('name', 'Greater Draught', 'kind_id', 'gear', 'campaign_id', :'camp', 'stackable', true)) ->> 'id' as greater \gset
select public.create_homebrew_item(gen_random_uuid(), jsonb_build_object('name', 'Sludgy Tonic', 'kind_id', 'gear', 'campaign_id', :'camp', 'stackable', true)) ->> 'id' as sludge \gset
-- a secret herb (decoy) and a secret result
select public.create_homebrew_item(gen_random_uuid(), jsonb_build_object('name', 'Starmoss', 'kind_id', 'herbs_plants', 'category_id', 'plant-flower',
  'campaign_id', :'camp', 'stackable', true, 'description', 'Starmoss truth.', 'details', jsonb_build_object('ingredient_tags', jsonb_build_array('silver')))) ->> 'id' as moss \gset
select public.set_item_identify_options(:'moss', '{"unidentified_name": "Grey fluff", "show_kind": true}');
select public.create_homebrew_item(gen_random_uuid(), jsonb_build_object('name', 'Elixir of Stars', 'kind_id', 'gear', 'campaign_id', :'camp', 'stackable', true)) ->> 'id' as elixir \gset
select public.set_item_identify_options(:'elixir', '{"unidentified_name": "Glittering vial"}');
select public.create_homebrew_item(gen_random_uuid(), jsonb_build_object('name', 'Unused Petal', 'kind_id', 'herbs_plants', 'category_id', 'plant-flower',
  'campaign_id', :'camp', 'stackable', true)) ->> 'id' as petal \gset

-- ---- CR8 governance off: the DM manages recipes, players are refused (TLDIS) -----------------------------------------------------
select public.dm_save_recipe(:'camp', jsonb_build_object('name', 'Auto Draught', 'description', 'Mix and pour.', 'dm_notes', 'SENTINEL-DMNOTE',
  'requires_dm_approval', false, 'output_item_id', :'draught', 'output_quantity', 1,
  'ingredients', jsonb_build_array(jsonb_build_object('item_id', :'leaf', 'quantity', 2), jsonb_build_object('item_id', :'mortar', 'quantity', 1, 'consumed', false)))) ->> 'id' as r_auto \gset
select public.dm_set_recipe_status(:'r_auto', 'published') ->> 'status' as r_auto_st \gset
select public.dm_save_recipe(:'camp', jsonb_build_object('name', 'Star Draught', 'dm_notes', 'SENTINEL-DMNOTE', 'check_key', 'nature', 'check_dc', 37,
  'output_item_id', :'draught', 'crit_output_item_id', :'greater', 'crit_bonus_quantity', 1, 'failure_mode', 'keep', 'failure_output_item_id', :'sludge',
  'ingredients', jsonb_build_array(jsonb_build_object('tag', 'silver', 'quantity', 1, 'label', 'A silvery herb')))) ->> 'id' as r_dc \gset
select public.dm_set_recipe_status(:'r_dc', 'published');
select tl_test.as_user(:'alice');
select tl_test.give(:'ca', :'leaf', null, 6) as leaf_row \gset
select tl_test.give(:'ca', :'mortar') as mortar_row \gset
select tl_test.cr_code(format('select public.get_character_recipes(%L)', :'ca')) as off_read \gset
select tl_test.cr_code(format('select public.start_craft_attempt(%L, %L, %L::jsonb, null, gen_random_uuid())', :'ca', :'r_auto',
  jsonb_build_array(tl_test.cr_sel(1, :'leaf_row', 2), tl_test.cr_sel(2, :'mortar_row', 1)))) as off_start \gset
select tl_test.cr_code(format('select public.mark_recipes_seen(%L)', :'ca')) as off_seen \gset
select tl_test.as_root();
select tl_test.rec('CR8 governance inventory.craft disabled (default, every preset): player read / start / seen refused TLDIS; the DM saved and published recipes',
  :'off_read' = 'TLDIS' and :'off_start' = 'TLDIS' and :'off_seen' = 'TLDIS' and :'r_auto_st' = 'published'
  and (select relaxed = 'disabled' and standard = 'disabled' and strict = 'disabled' and not can_request from public.governance_actions where action_key = 'inventory.craft'),
  concat_ws(',', :'off_read', :'off_start', :'off_seen'));
select tl_test.as_user(:'dm');
select tl_test.rec('CR8b approval_required cannot be chosen for crafting (can_request false: it would build a request nobody can apply)',
  tl_test.cr_code(format('select public.set_campaign_governance(%L, ''{"overrides": {"inventory.craft": "approval_required"}}'')', :'camp')) = '22023');
select public.set_campaign_governance(:'camp', '{"overrides": {"inventory.craft": "player_managed"}}');

-- ---- CR1 auto craft --------------------------------------------------------------------------------------------------------------
select tl_test.as_user(:'alice');
select public.get_character_recipes(:'ca') as read1 \gset
select public.start_craft_attempt(:'ca', :'r_auto', jsonb_build_array(tl_test.cr_sel(1, :'leaf_row', 2), tl_test.cr_sel(2, :'mortar_row', 1)), null, :'r_auto') as a1 \gset
select tl_test.as_root();
select tl_test.rec('CR1 auto craft (no DC, no approval): applied at once; 2 leaves consumed, the tool kept, 1 draught made; one remove + one add event with metadata.craft_attempt',
  :'a1'::jsonb ->> 'status' = 'applied' and :'a1'::jsonb ->> 'outcome' = 'success' and tl_test.cr_qty(:'ca', :'leaf') = 4 and tl_test.cr_qty(:'ca', :'mortar') = 1
  and tl_test.cr_qty(:'ca', :'draught') = 1 and tl_test.cr_events((:'a1'::jsonb ->> 'attempt_id')::uuid, 'remove') = 1
  and tl_test.cr_events((:'a1'::jsonb ->> 'attempt_id')::uuid, 'add') = 1
  and (tl_test.cr_rec(:'read1'::jsonb, :'r_auto') ->> 'can_craft')::boolean and (tl_test.cr_rec(:'read1'::jsonb, :'r_auto') -> 'ingredients' -> 0 ->> 'have')::int = 6,
  left(:'a1', 300));
select tl_test.as_user(:'alice');
select public.start_craft_attempt(:'ca', :'r_auto', jsonb_build_array(tl_test.cr_sel(1, :'leaf_row', 2), tl_test.cr_sel(2, :'mortar_row', 1)), null, :'r_auto') as a1_again \gset
select tl_test.as_root();
select tl_test.rec('CR6 idempotent request id: the same request again replays the attempt (no second attempt, nothing consumed again)',
  (:'a1_again'::jsonb ->> 'replayed')::boolean and :'a1_again'::jsonb ->> 'attempt_id' = :'a1'::jsonb ->> 'attempt_id'
  and (select count(*) from public.crafting_attempts where request_id = :'r_auto') = 1 and tl_test.cr_qty(:'ca', :'leaf') = 4);

-- ---- CR2 a DC needs approval -------------------------------------------------------------------------------------------------------
select tl_test.as_user(:'dm');
select tl_test.cr_code(format('select public.dm_save_recipe(%L, %L::jsonb)', :'camp', jsonb_build_object('name', 'Bad', 'check_key', 'nature', 'check_dc', 10,
  'requires_dm_approval', false, 'output_item_id', :'draught', 'ingredients', jsonb_build_array(jsonb_build_object('tag', 'silver'))))) as c2_rpc \gset
select tl_test.cr_code(format('select public.dm_save_recipe(%L, %L::jsonb)', :'camp', jsonb_build_object('name', 'Bad2', 'check_dc', 10,
  'output_item_id', :'draught', 'ingredients', jsonb_build_array(jsonb_build_object('tag', 'silver'))))) as c2_key \gset
select tl_test.as_root();
select tl_test.cr_code(format('insert into public.crafting_recipes (campaign_id, name, output_item_id, check_key, check_dc, requires_dm_approval) values (%L, ''x'', %L, ''nature'', 10, false)',
  :'camp', :'draught')) as c2_table \gset
select tl_test.rec('CR2 a recipe with a DC must require approval (RPC 22023, table CHECK 23514); a DC needs a check (22023)',
  :'c2_rpc' = '22023' and :'c2_table' = '23514' and :'c2_key' = '22023', concat_ws(',', :'c2_rpc', :'c2_table', :'c2_key'));

-- ---- CR3 pending -> DM approve with an edited roll -----------------------------------------------------------------------------------
select tl_test.as_user(:'alice');
select public.start_craft_attempt(:'ca', :'r_dc', jsonb_build_array(tl_test.cr_sel(1, :'leaf_row', 1)), 12, gen_random_uuid(), 'nat20', 'Careful now') as a3 \gset
select tl_test.cr_code(format('select public.start_craft_attempt(%L, %L, %L::jsonb, 14, gen_random_uuid())', :'ca', :'r_dc',
  jsonb_build_array(tl_test.cr_sel(1, :'leaf_row', 1)))) as a3_dup \gset
select tl_test.as_root();
select tl_test.cr_qty(:'ca', :'leaf') as leaf_before3 \gset
select tl_test.as_user(:'dm');
select public.get_campaign_craft_attempts(:'camp') as inbox3 \gset
select public.dm_resolve_craft_attempt((:'a3'::jsonb ->> 'attempt_id')::uuid, 'approve', null, 38, 'Well done', 'SENTINEL-PRIVATE') as r3 \gset
select tl_test.cr_code(format('select public.dm_resolve_craft_attempt(%L, ''approve'')', :'a3'::jsonb ->> 'attempt_id')) as r3_again \gset
select tl_test.as_root();
select tl_test.rec('CR3 pending (nothing consumed, a second pending attempt refused 55000) -> the DM inbox shows the DC and the roll -> approve with edited roll 38 >= DC 37 -> applied, success, consumed and produced; a second answer is refused (55000)',
  :'a3'::jsonb ->> 'status' = 'pending' and :'a3_dup' = '55000' and :leaf_before3 = 4
  and (select (x ->> 'check_dc')::int = 37 and (x ->> 'roll_total')::int = 12 and x ->> 'natural' = 'nat20' from jsonb_array_elements(:'inbox3'::jsonb) x where x ->> 'attempt_id' = :'a3'::jsonb ->> 'attempt_id')
  and :'r3'::jsonb ->> 'status' = 'applied' and :'r3'::jsonb ->> 'outcome' = 'success' and (:'r3'::jsonb ->> 'dm_roll_total')::int = 38
  and tl_test.cr_qty(:'ca', :'leaf') = 3 and tl_test.cr_qty(:'ca', :'draught') = 2 and :'r3_again' = '55000',
  left(:'r3', 300));

-- ---- CR4 reject keeps everything; approve as failure applies the failure rule and the junk result --------------------------------------
select tl_test.as_user(:'alice');
select public.start_craft_attempt(:'ca', :'r_dc', jsonb_build_array(tl_test.cr_sel(1, :'leaf_row', 1)), 5, gen_random_uuid()) as a4 \gset
select tl_test.as_user(:'dm');
select public.dm_resolve_craft_attempt((:'a4'::jsonb ->> 'attempt_id')::uuid, 'reject', null, null, 'Not in the middle of a fight') as r4 \gset
select tl_test.as_root();
select tl_test.cr_qty(:'ca', :'leaf') as leaf_after_reject \gset
select tl_test.as_user(:'alice');
select public.start_craft_attempt(:'ca', :'r_dc', jsonb_build_array(tl_test.cr_sel(1, :'leaf_row', 1)), 5, gen_random_uuid()) as a4b \gset
select tl_test.as_user(:'dm');
select public.dm_resolve_craft_attempt((:'a4b'::jsonb ->> 'attempt_id')::uuid, 'approve') as r4b \gset
select tl_test.as_user(:'alice');
select public.start_craft_attempt(:'ca', :'r_dc', jsonb_build_array(tl_test.cr_sel(1, :'leaf_row', 1)), 5, gen_random_uuid()) as a4c \gset
select tl_test.as_user(:'dm');
select public.dm_resolve_craft_attempt((:'a4c'::jsonb ->> 'attempt_id')::uuid, 'approve', 'failure', null, null, null, 'lose_all') as r4c \gset
select tl_test.as_root();
select tl_test.rec('CR4 reject: nothing changes; failure by the roll with rule keep: nothing consumed, junk made; failure with lose_all: the leaf is lost, junk made',
  :'r4'::jsonb ->> 'status' = 'rejected' and :leaf_after_reject = 3
  and :'r4b'::jsonb ->> 'outcome' = 'failure' and :'r4b'::jsonb ->> 'status' = 'applied' and jsonb_array_length(:'r4b'::jsonb -> 'consumed') = 0
  and :'r4c'::jsonb ->> 'outcome' = 'failure' and jsonb_array_length(:'r4c'::jsonb -> 'consumed') = 1
  and tl_test.cr_qty(:'ca', :'leaf') = 2 and tl_test.cr_qty(:'ca', :'sludge') = 2 and tl_test.cr_qty(:'ca', :'draught') = 2,
  concat_ws(' | ', left(:'r4b', 200), tl_test.cr_qty(:'ca', :'leaf'), tl_test.cr_qty(:'ca', :'sludge')));

-- ---- critical success: the other result + the bonus -------------------------------------------------------------------------------------
select tl_test.as_user(:'alice');
select public.start_craft_attempt(:'ca', :'r_dc', jsonb_build_array(tl_test.cr_sel(1, :'leaf_row', 1)), 39, gen_random_uuid(), 'nat20') as a_crit \gset
select tl_test.as_user(:'dm');
select public.dm_resolve_craft_attempt((:'a_crit'::jsonb ->> 'attempt_id')::uuid, 'approve', 'critical_success') as r_crit \gset
select tl_test.as_root();
select tl_test.rec('CR4b critical success (chosen by the DM): the alternative result with the bonus quantity (2 Greater Draughts), the leaf consumed',
  :'r_crit'::jsonb ->> 'outcome' = 'critical_success' and tl_test.cr_qty(:'ca', :'greater') = 2 and tl_test.cr_qty(:'ca', :'leaf') = 1, left(:'r_crit', 200));

-- ---- CR5 ingredients gone at approval -> apply_failed, nothing changed -------------------------------------------------------------------
select tl_test.as_user(:'alice');
select public.start_craft_attempt(:'ca', :'r_dc', jsonb_build_array(tl_test.cr_sel(1, :'leaf_row', 1)), 20, gen_random_uuid()) as a5 \gset
select public.remove_inventory_item(:'leaf_row', 1);   -- the last leaf leaves the inventory meanwhile
select tl_test.as_root();
select count(*) as ev5 from public.inventory_events \gset
select tl_test.as_user(:'dm');
select public.dm_resolve_craft_attempt((:'a5'::jsonb ->> 'attempt_id')::uuid, 'approve', 'success') as r5 \gset
select tl_test.as_root();
select tl_test.rec('CR5 approval after the ingredient left: apply_failed with a fixed reason, nothing consumed or produced, no inventory event; the DM can still reject it',
  :'r5'::jsonb ->> 'status' = 'apply_failed' and :'r5'::jsonb ->> 'apply_error' = 'Some ingredients are no longer in the inventory'
  and (select count(*) from public.inventory_events) = :ev5 and tl_test.cr_qty(:'ca', :'draught') = 2,
  left(:'r5', 300));
select tl_test.as_user(:'dm');
select public.dm_resolve_craft_attempt((:'a5'::jsonb ->> 'attempt_id')::uuid, 'reject') ->> 'status' as r5_rej \gset
select tl_test.as_root();
select tl_test.rec('CR5b an apply_failed attempt can still be rejected', :'r5_rej' = 'rejected');

-- ---- CR7 exactly once: revision guard + row lock (the harness is one session; the two-session run is in the report) ----------------------
select tl_test.as_user(:'alice');
select tl_test.give(:'ca', :'leaf', null, 3) as leaf_row \gset
select public.start_craft_attempt(:'ca', :'r_dc', jsonb_build_array(tl_test.cr_sel(1, :'leaf_row', 1)), 20, gen_random_uuid()) as a7 \gset
select tl_test.as_user(:'dm');
select tl_test.cr_code(format('select public.dm_resolve_craft_attempt(%L, ''approve'', ''success'', null, null, null, null, 99)', :'a7'::jsonb ->> 'attempt_id')) as r7_stale \gset
select tl_test.as_root();
select tl_test.rec('CR7 exactly once: a stale expected revision is refused (40001) and changes nothing; the answer locks the attempt row FOR UPDATE and refuses any non-open status',
  :'r7_stale' = '40001' and (tl_test.cr_att((:'a7'::jsonb ->> 'attempt_id')::uuid)).status = 'pending'
  and (select position('for update' in d) > 0 and position('This attempt was already answered' in d) > 0
       from (select pg_get_functiondef('public.dm_resolve_craft_attempt(uuid, text, text, int, text, text, text, int)'::regprocedure) d) f));

-- ---- CR9 the knowledge rule -------------------------------------------------------------------------------------------------------------
-- bob: the read without any row, then with a disguised Starmoss (tag silver, fits Star Draught) and a disguised Elixir; identical
select tl_test.as_user(:'bob');
select public.get_character_recipes(:'cb')::text as b_none \gset
select tl_test.as_user(:'dm');
select public.dm_give_item(:'moss', array[:'cb']::uuid[], 2, false);
select public.dm_give_item(:'elixir', array[:'cb']::uuid[], 1, false);
select tl_test.as_root();
select tl_test.cr_row(:'cb', :'moss') as moss_row \gset
select tl_test.cr_row(:'cb', :'elixir') as elixir_row \gset
select tl_test.as_user(:'bob');
select public.get_character_recipes(:'cb')::text as b_with \gset
select tl_test.cr_msg(format('select public.start_craft_attempt(%L, %L, %L::jsonb, 30, gen_random_uuid())', :'cb', :'r_dc',
  jsonb_build_array(tl_test.cr_sel(1, :'moss_row', 1)))) as b_try_match \gset
select tl_test.cr_msg(format('select public.start_craft_attempt(%L, %L, %L::jsonb, 30, gen_random_uuid())', :'cb', :'r_dc',
  jsonb_build_array(tl_test.cr_sel(1, :'elixir_row', 1)))) as b_try_nomatch \gset
select tl_test.as_root();
select tl_test.rec('CR9 an unidentified row never matches: bob''s read is byte-identical with a disguised matching herb and without it; matching and non-matching unidentified rows get the SAME fixed refusal',
  :'b_none' = :'b_with' and :'b_try_match' = '22023 You don''t know what this ingredient is yet' and :'b_try_match' = :'b_try_nomatch'
  and tl_test.cr_clean(:'b_with') and (select count(*) from public.crafting_attempts where character_id = :'cb') = 0,
  concat_ws(' | ', :'b_none' = :'b_with', :'b_try_match', :'b_try_nomatch'));
-- once bob knows Starmoss, it fits the silver tag
select tl_test.as_user(:'dm');
select public.dm_set_item_knowledge(:'moss', array[:'cb']::uuid[], '{all}', 'set');
select tl_test.as_user(:'bob');
select public.get_character_recipes(:'cb') as b_known \gset
select tl_test.as_root();
select tl_test.rec('CR9b after the reveal the identified Starmoss counts for the silver tag (have 2, candidate listed)',
  (tl_test.cr_rec(:'b_known'::jsonb, :'r_dc') -> 'ingredients' -> 0 ->> 'have')::int = 2
  and tl_test.cr_rec(:'b_known'::jsonb, :'r_dc') -> 'ingredients' -> 0 -> 'candidates' -> 0 ->> 'inventory_item_id' = :'moss_row');

-- ---- CR12 secret result: the DM's label, never the name or id -------------------------------------------------------------------------
select tl_test.as_user(:'dm');
select public.dm_save_recipe(:'camp', jsonb_build_object('name', 'Starlight Brew', 'output_item_id', :'elixir', 'output_label', 'A mysterious brew',
  'output_identified', false, 'requires_dm_approval', false,
  'ingredients', jsonb_build_array(jsonb_build_object('item_id', :'leaf', 'quantity', 1)))) ->> 'id' as r_sec \gset
select public.dm_set_recipe_status(:'r_sec', 'published');
select public.dm_save_recipe(:'camp', jsonb_build_object('name', 'Moss Paste', 'output_item_id', :'draught', 'requires_dm_approval', false,
  'ingredients', jsonb_build_array(jsonb_build_object('item_id', :'moss', 'quantity', 1, 'label', 'a grey fluff')))) ->> 'id' as r_mossp \gset
select public.dm_set_recipe_status(:'r_mossp', 'published');
select tl_test.as_user(:'alice');
select public.get_character_recipes(:'ca') as a_sec \gset
select public.start_craft_attempt(:'ca', :'r_sec', jsonb_build_array(tl_test.cr_sel(1, :'leaf_row', 1)), null, gen_random_uuid()) as a_sec_made \gset
select (select to_jsonb(d) from public.v_inventory_detail d where d.character_id = :'ca' and d.name = 'Glittering vial') as a_vial \gset
select public.get_campaign_audit(:'camp')::text as a_audit \gset
select tl_test.as_root();
select tl_test.rec('CR12 a result unknown to the character shows the DM label (no name, no id, known false); an exact secret ingredient shows its label; made "unidentified": the row arrives disguised (decoy, masked) and the audit has no true name',
  tl_test.cr_rec(:'a_sec'::jsonb, :'r_sec') -> 'output' ->> 'name' = 'A mysterious brew' and tl_test.cr_rec(:'a_sec'::jsonb, :'r_sec') -> 'output' ->> 'item_id' is null
  and not (tl_test.cr_rec(:'a_sec'::jsonb, :'r_sec') -> 'output' ->> 'known')::boolean
  and tl_test.cr_rec(:'a_sec'::jsonb, :'r_mossp') -> 'ingredients' -> 0 ->> 'label' = 'a grey fluff' and tl_test.cr_rec(:'a_sec'::jsonb, :'r_mossp') -> 'ingredients' -> 0 ->> 'item_id' is null
  and position('Elixir of Stars' in :'a_sec') = 0 and position(:'elixir' in :'a_sec') = 0 and position(:'moss' in :'a_sec') = 0 and tl_test.cr_clean(:'a_sec')
  and :'a_sec_made'::jsonb ->> 'status' = 'applied' and :'a_sec_made'::jsonb -> 'produced' -> 0 ->> 'name' = 'Glittering vial'
  and :'a_vial'::jsonb ->> 'item_id' is null and :'a_vial'::jsonb ->> 'knowledge_state' = 'unidentified' and position('Elixir of Stars' in :'a_audit') = 0,
  left(coalesce(:'a_vial', 'null'), 300));
select tl_test.as_user(:'dm');
select tl_test.rec('CR12b an official result cannot be made to arrive unidentified (22023: copy it to campaign homebrew first)',
  tl_test.cr_code(format('select public.dm_save_recipe(%L, %L::jsonb)', :'camp', jsonb_build_object('name', 'Off', 'output_item_id', 'candle', 'output_identified', false,
    'ingredients', jsonb_build_array(jsonb_build_object('tag', 'silver'))))) = '22023');

-- ---- CR14 discovery: discoverable / secret / draft; grant; "new" until seen --------------------------------------------------------------
select public.dm_save_recipe(:'camp', jsonb_build_object('name', 'Hidden Tea', 'visibility', 'discoverable', 'output_item_id', :'draught', 'requires_dm_approval', false,
  'ingredients', jsonb_build_array(jsonb_build_object('tag', 'calming')))) ->> 'id' as r_disc \gset
select public.dm_set_recipe_status(:'r_disc', 'published');
select public.dm_save_recipe(:'camp', jsonb_build_object('name', 'Secret Tea', 'visibility', 'secret', 'output_item_id', :'draught',
  'ingredients', jsonb_build_array(jsonb_build_object('tag', 'calming')))) ->> 'id' as r_secret \gset
select public.dm_set_recipe_status(:'r_secret', 'published');
select public.dm_save_recipe(:'camp', jsonb_build_object('name', 'Draft Tea', 'output_item_id', :'draught',
  'ingredients', jsonb_build_array(jsonb_build_object('tag', 'calming')))) ->> 'id' as r_draft \gset
select tl_test.as_user(:'alice');
select public.get_character_recipes(:'ca') as d0 \gset
select tl_test.as_user(:'dm');
select public.dm_grant_recipe(:'r_disc', array[:'ca']::uuid[]) ->> 'changed' as g1 \gset
select tl_test.as_user(:'alice');
select public.get_character_recipes(:'ca') as d1 \gset
select public.mark_recipes_seen(:'ca') as seen_n \gset
select public.get_character_recipes(:'ca') as d2 \gset
select tl_test.as_user(:'bob');
select public.get_character_recipes(:'cb') as d_bob \gset
select tl_test.as_root();
select tl_test.rec('CR14 discovery: a discoverable recipe is hidden (counted as undiscovered), secret and draft ones neither shown nor counted; after the grant it shows as new (learned) until seen; bob still does not see it',
  tl_test.cr_rec(:'d0'::jsonb, :'r_disc') is null and (:'d0'::jsonb ->> 'undiscovered')::int = 1 and tl_test.cr_rec(:'d0'::jsonb, :'r_secret') is null
  and tl_test.cr_rec(:'d0'::jsonb, :'r_draft') is null and position('Secret Tea' in :'d0') = 0 and position('Draft Tea' in :'d0') = 0
  and :g1 = 1 and (tl_test.cr_rec(:'d1'::jsonb, :'r_disc') ->> 'new')::boolean and tl_test.cr_rec(:'d1'::jsonb, :'r_disc') ->> 'source' = 'learned'
  and (:'d1'::jsonb ->> 'undiscovered')::int = 0 and :seen_n = 1 and not (tl_test.cr_rec(:'d2'::jsonb, :'r_disc') ->> 'new')::boolean
  and tl_test.cr_rec(:'d_bob'::jsonb, :'r_disc') is null and exists (select 1 from public.campaign_audit_events where character_id = :'ca' and summary = 'New recipe learned: Hidden Tea'),
  left(:'d1', 200));

-- ---- CR15 refusals -------------------------------------------------------------------------------------------------------------------
insert into public.inventory_items (inventory_id, item_id, quantity, is_quest_item) values (tl_test.inv(:'ca'), :'leaf', 2, true) returning id as leaf_q \gset
select tl_test.as_user(:'alice');
select tl_test.cr_code(format('select public.start_craft_attempt(%L, %L, %L::jsonb, null, gen_random_uuid())', :'ca', :'r_auto',
  jsonb_build_array(tl_test.cr_sel(1, :'leaf_q', 2), tl_test.cr_sel(2, :'mortar_row', 1)))) as c15_quest \gset
select tl_test.cr_code(format('select public.start_craft_attempt(%L, %L, %L::jsonb, null, gen_random_uuid())', :'ca', :'r_auto',
  jsonb_build_array(tl_test.cr_sel(1, :'moss_row', 2), tl_test.cr_sel(2, :'mortar_row', 1)))) as c15_other \gset
select tl_test.cr_code(format('select public.start_craft_attempt(%L, %L, %L::jsonb, null, gen_random_uuid())', :'ca', :'r_auto',
  jsonb_build_array(tl_test.cr_sel(1, :'mortar_row', 1), tl_test.cr_sel(2, :'mortar_row', 1)))) as c15_twice \gset
select tl_test.cr_code(format('select public.start_craft_attempt(%L, %L, %L::jsonb, null, gen_random_uuid())', :'cb', :'r_auto', '[]')) as c15_notmine \gset
select tl_test.cr_code(format('select public.get_character_recipes(%L)', :'cb')) as c15_read_other \gset
select tl_test.cr_code(format('select public.dm_save_recipe(%L, ''{"name": "x"}'')', :'camp')) as c15_dm_alice \gset
select tl_test.cr_code(format('select public.get_campaign_craft_attempts(%L)', :'camp')) as c15_inbox_alice \gset
select tl_test.cr_code(format('select public.cancel_craft_attempt(%L)', :'a7'::jsonb ->> 'attempt_id')) as c15_cancel_ok \gset
select tl_test.as_user(:'eve');
select tl_test.cr_code(format('select public.get_campaign_recipes(%L)', :'camp')) as c15_eve \gset
select tl_test.as_root();
select tl_test.rec('CR15 refusals: a quest item as a consumed ingredient, a row of another character, one stack twice (22023); another player''s character (42501); DM RPCs for a player and an outsider (42501); the owner may cancel a pending attempt',
  :'c15_quest' = '22023' and :'c15_other' = '22023' and :'c15_twice' = '22023' and :'c15_notmine' = '42501' and :'c15_read_other' = '42501'
  and :'c15_dm_alice' = '42501' and :'c15_inbox_alice' = '42501' and :'c15_eve' = '42501' and :'c15_cancel_ok' = 'ok'
  and (tl_test.cr_att((:'a7'::jsonb ->> 'attempt_id')::uuid)).status = 'cancelled',
  concat_ws(',', :'c15_quest', :'c15_other', :'c15_twice', :'c15_notmine', :'c15_read_other', :'c15_dm_alice', :'c15_inbox_alice', :'c15_eve', :'c15_cancel_ok'));

-- ---- CR10 hidden data: tables closed to REST, RPC answers without the DC, DM notes or private notes ---------------------------------------
select tl_test.as_user(:'alice');
select tl_test.cr_code('select 1 from public.crafting_recipes') as t1 \gset
select tl_test.cr_code('select 1 from public.crafting_recipe_ingredients') as t2 \gset
select tl_test.cr_code('select 1 from public.crafting_attempts') as t3 \gset
select tl_test.cr_code('select 1 from public.character_known_recipes') as t4 \gset
select public.get_character_recipes(:'ca')::text as a_all \gset
select tl_test.as_root();
select tl_test.rec('CR10 the four tables are closed to players (42501, no grants); the player read carries no DC, DM notes, private notes, crit / failure results; the DM reply does reach the player',
  :'t1' = '42501' and :'t2' = '42501' and :'t3' = '42501' and :'t4' = '42501' and tl_test.cr_clean(:'a_all') and tl_test.cr_clean(:'a3')
  and position('Well done' in :'a_all') > 0
  and not has_table_privilege('authenticated', 'public.crafting_attempts', 'select') and not has_table_privilege('anon', 'public.crafting_recipes', 'select'),
  concat_ws(',', :'t1', :'t2', :'t3', :'t4', tl_test.cr_clean(:'a_all')));

-- ---- lose_half -------------------------------------------------------------------------------------------------------------------------
select tl_test.as_user(:'dm');
select public.dm_save_recipe(:'camp', jsonb_build_object('name', 'Half Brew', 'check_key', 'nature', 'check_dc', 15, 'failure_mode', 'lose_half', 'output_item_id', :'draught',
  'ingredients', jsonb_build_array(jsonb_build_object('item_id', :'leaf', 'quantity', 2)))) ->> 'id' as r_half \gset
select public.dm_set_recipe_status(:'r_half', 'published');
select tl_test.as_user(:'alice');
select tl_test.cr_row(:'ca', :'leaf') as leaf_any \gset
select tl_test.cr_qty(:'ca', :'leaf') as leaf_h0 \gset
select public.start_craft_attempt(:'ca', :'r_half', jsonb_build_array(tl_test.cr_sel(1, (select ii.id from public.inventory_items ii join public.inventories inv on inv.id = ii.inventory_id
  where inv.character_id = :'ca' and ii.item_id = :'leaf' and not ii.is_quest_item order by ii.quantity desc limit 1), 2)), 3, gen_random_uuid()) as a_half \gset
select tl_test.as_user(:'dm');
select public.dm_resolve_craft_attempt((:'a_half'::jsonb ->> 'attempt_id')::uuid, 'approve') as r_half_res \gset
select tl_test.as_root();
select tl_test.rec('CR16 failure with the rule lose_half: 1 of 2 leaves lost, nothing produced',
  :'r_half_res'::jsonb ->> 'outcome' = 'failure' and tl_test.cr_qty(:'ca', :'leaf') = :leaf_h0 - 1 and jsonb_array_length(:'r_half_res'::jsonb -> 'produced') = 0,
  left(:'r_half_res', 200));

-- ---- CR13 deletion reports the recipe dependency (no raw foreign-key error) ---------------------------------------------------------------
select tl_test.as_user(:'dm');
select public.dm_save_recipe(:'camp', jsonb_build_object('name', 'Petal Jam', 'output_item_id', :'draught',
  'ingredients', jsonb_build_array(jsonb_build_object('item_id', :'petal')))) ->> 'id' as r_petal \gset
select public.preview_item_deletion(:'petal') as pv \gset
select tl_test.cr_msg(format('select public.delete_custom_item(%L, ''Unused Petal'')', :'petal')) as del_petal \gset
select tl_test.as_root();
select tl_test.rec('CR13 an item used only by a (draft) recipe: preview not deletable with "used in crafting recipe “Petal Jam”", the delete refuses with TLUSE (not 23503); the DM content report has the key',
  not (:'pv'::jsonb ->> 'deletable')::boolean and (:'pv'::jsonb -> 'dependencies' ->> 'crafting_recipes')::int = 1
  and :'pv'::jsonb -> 'reasons' ? 'used in crafting recipe “Petal Jam”' and split_part(:'del_petal', ' ', 1) = 'TLUSE'
  and exists (select 1 from public.items where id = :'petal')
  and position('crafting_recipes' in pg_get_functiondef('public._dm_content_dependencies(uuid)'::regprocedure)) > 0
  and position('crafting_recipe' in pg_get_functiondef('public.get_dm_content_usage_detail(uuid)'::regprocedure)) > 0,
  :'pv');

-- ---- CR17 cache, Realtime, grants ------------------------------------------------------------------------------------------------------
select tl_test.rec('CR17 cache triggers: recipe tables skip (no cached read reads them), attempts / known recipes bump the character; none in the Realtime publication; helpers not executable by players',
  (select count(*) from pg_trigger where tgname = 'tl_cache_rev' and tgfoid = 'tl_cache.skip()'::regprocedure
     and tgrelid in ('public.crafting_recipes'::regclass, 'public.crafting_recipe_ingredients'::regclass)) = 2
  and (select count(*) from pg_trigger where tgname = 'tl_cache_rev' and tgfoid = 'tl_cache.bump()'::regprocedure and encode(tgargs, 'escape') = 'character\000'
     and tgrelid in ('public.crafting_attempts'::regclass, 'public.character_known_recipes'::regclass)) = 2
  and not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and (tablename like '%recipe%' or tablename = 'crafting_attempts'))
  and not has_function_privilege('authenticated', 'public._craft_apply(uuid, text, text)', 'execute')
  and not has_function_privilege('authenticated', 'public._craft_produce(uuid, uuid, text, int, boolean, jsonb)', 'execute')
  and has_function_privilege('authenticated', 'public.start_craft_attempt(uuid, uuid, jsonb, int, uuid, text, text)', 'execute')
  and not has_function_privilege('anon', 'public.start_craft_attempt(uuid, uuid, jsonb, int, uuid, text, text)', 'execute'));

-- ---- CR18 a character who left the campaign: the old DM neither sees nor answers its attempt ------------------------------------------
select tl_test.as_user(:'alice');
select public.start_craft_attempt(:'ca', :'r_dc', jsonb_build_array(tl_test.cr_sel(1, (select ii.id from public.inventory_items ii join public.inventories inv on inv.id = ii.inventory_id
  where inv.character_id = :'ca' and ii.item_id = :'leaf' and not ii.is_quest_item order by ii.quantity desc limit 1), 1)), 20, gen_random_uuid()) as a18 \gset
select tl_test.as_root();
update public.characters set campaign_id = null where id = :'ca';
select tl_test.as_user(:'dm');
select tl_test.cr_code(format('select public.dm_resolve_craft_attempt(%L, ''approve'', ''success'')', :'a18'::jsonb ->> 'attempt_id')) as r18 \gset
select public.get_campaign_craft_attempts(:'camp', null)::text as inbox18 \gset
select tl_test.as_root();
select tl_test.rec('CR18 the character left the campaign: the old DM''s approve is refused (55000), the inbox no longer lists the attempt, nothing changed',
  :'r18' = '55000' and position(:'a18'::jsonb ->> 'attempt_id' in :'inbox18') = 0
  and (tl_test.cr_att((:'a18'::jsonb ->> 'attempt_id')::uuid)).status = 'pending', :'r18');
update public.characters set campaign_id = :'camp' where id = :'ca';

-- ---- CR19 a result that arrives unidentified leaves the catalog at publish (a DM action), not at a player's craft ---------------------
select tl_test.as_user(:'dm');
select public.create_homebrew_item(gen_random_uuid(), jsonb_build_object('name', 'Plain Result', 'kind_id', 'gear', 'campaign_id', :'camp')) ->> 'id' as plainres \gset
select public.dm_save_recipe(:'camp', jsonb_build_object('name', 'Mystery Make', 'output_item_id', :'plainres', 'output_identified', false,
  'ingredients', jsonb_build_array(jsonb_build_object('tag', 'calming')))) ->> 'id' as r19 \gset
select tl_test.as_root();
select secret as s19a from public.items where id = :'plainres' \gset
select tl_test.as_user(:'dm');
select public.dm_set_recipe_status(:'r19', 'published');
select tl_test.as_root();
select tl_test.rec('CR19 output_identified = false: the result becomes secret when the DM publishes the recipe (not while it is a draft)',
  not :'s19a'::boolean and (select secret from public.items where id = :'plainres'));