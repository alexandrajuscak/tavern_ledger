-- =============================================================================
-- Herbs & Plants identification (20261112000300; docs/HIDDEN_DM_DATA.md "Identifying items: Examine"): DM options, decoy,
-- player Examine with the total of a physical roll, the attempt state machine (pending -> succeeded / failed, auto), retry rules,
-- per-character knowledge, DM reveal to one / all, split / transfer / merge, and the LEAK checks: before a reveal a player never
-- reads the true name / description / details / effects / DC / hint (RPCs, table and view selects, get_character_reads cache
-- miss and hit, tl_cache payloads, use_inventory_item, inventory_events, audit), the INSERT of an unidentified row never carries
-- the true name (the row image Realtime would publish), and a hidden option change writes no revision / cache signal.
-- Runs inside the per-class harness (alice = player of :camp, bob = outsider made a player here, dm = DM of :camp).
-- =============================================================================
\set h1 f4d00000-0000-0000-0000-000000000001
\set h2 f4d00000-0000-0000-0000-000000000002
\set h3 f4d00000-0000-0000-0000-000000000003
insert into public.campaign_members (campaign_id, user_id, role) values (:'camp', :'bob', 'player');
insert into public.characters (id, owner_id, name, campaign_id, level, strength, dexterity, constitution, intelligence, wisdom, charisma, hp_max, hp_current, speed) values
  (:'h1', :'alice', 'Herb Hero', :'camp', 1, 10, 12, 12, 10, 14, 10, 10, 10, 30),
  (:'h2', :'alice', 'Herb Twin', :'camp', 1, 10, 12, 12, 10, 14, 10, 10, 10, 30),
  (:'h3', :'bob', 'Herb Other', :'camp', 1, 10, 12, 12, 10, 14, 10, 10, 10, 30);
create function tl_test.hi_code(p_sql text) returns text language plpgsql as $$
begin execute p_sql; return 'ok'; exception when others then return sqlstate; end $$;
-- a row of the character's inventory (as root)
create function tl_test.hi_row(p_char uuid, p_item text) returns public.inventory_items language sql security definer as $$
  select ii.* from public.inventory_items ii join public.inventories inv on inv.id = ii.inventory_id
  where inv.character_id = p_char and ii.item_id = p_item order by ii.quantity desc, ii.id limit 1 $$;
create function tl_test.hi_rows(p_char uuid, p_item text) returns int language sql security definer as $$
  select count(*)::int from public.inventory_items ii join public.inventories inv on inv.id = ii.inventory_id
  where inv.character_id = p_char and ii.item_id = p_item $$;
create function tl_test.hi_revs(p_char uuid) returns int language sql security definer as $$
  select count(*)::int from public.character_revisions where character_id = p_char $$;
create function tl_test.hi_cache_rev(p_char uuid) returns bigint language sql security definer as $$
  select coalesce((select rev from tl_cache.character_rev where character_id = p_char), 0) $$;
create function tl_test.hi_cached(p_char uuid, p_viewer uuid) returns text language sql security definer as $$
  select coalesce(string_agg(payload::text, '|'), '') from tl_cache.character_reads where character_id = p_char and viewer = p_viewer $$;
create function tl_test.hi_attempt(p_char uuid) returns uuid language sql security definer as $$
  select id from public.item_identify_attempts where character_id = p_char order by created_at desc, id limit 1 $$;
create function tl_test.hi_ref(p_content uuid) returns text language sql security definer as $$
  select v.catalog_ref from public.dm_content c join public.dm_content_versions v on v.id = c.published_version_id where c.id = p_content $$;
-- forget the per-transaction "already bumped" markers so the next change behaves like a new transaction
create function tl_test.hi_fresh(p_char uuid) returns void language plpgsql as $$
begin
  perform set_config('tl_rev.r' || md5(p_char::text || 'inventory_items' || txid_current()::text), '', true);
  perform set_config('tl_cache.c' || md5(p_char::text || txid_current()::text), '', true);
  perform set_config('tl_cache.g' || md5(txid_current()::text), '', true);
end $$;
-- none of the secret strings in a text
create function tl_test.hi_clean(p_text text) returns boolean language sql as $$
  select position('Nightshade' in coalesce(p_text, '')) = 0 and position('Deadly' in coalesce(p_text, '')) = 0
     and position('Paralysis' in coalesce(p_text, '')) = 0 and position('lavender' in coalesce(p_text, '')) = 0
     and position('"dc"' in coalesce(p_text, '')) = 0 and position('identify_dc' in coalesce(p_text, '')) = 0 $$;
-- every row image an INSERT on inventory_items produced (what Realtime would publish for an INSERT)
create table tl_test.hi_inserts (name text, description text);
grant all on tl_test.hi_inserts to public;
create function tl_test.hi_capture() returns trigger language plpgsql security definer as $$
begin insert into tl_test.hi_inserts values (new.name, new.description); return null; end $$;
create trigger hi_capture after insert on public.inventory_items for each row execute function tl_test.hi_capture();
grant all on all functions in schema tl_test to public;

-- ---- DM creates the herb (campaign homebrew, as from the Inventory homebrew form) and sets the disguise ------------------------
select tl_test.as_user(:'dm');
select public.create_homebrew_item(gen_random_uuid(), jsonb_build_object('name', 'Nightshade Bloom', 'kind_id', 'herbs_plants', 'category_id', 'plant-flower',
  'campaign_id', :'camp', 'stackable', true, 'is_consumable', true, 'description', 'Deadly purple flower.',
  'details', jsonb_build_object('harvesting', 'Paralysis poison in the sap', 'properties', jsonb_build_array('poisonous')))) ->> 'id' as herb \gset
select tl_test.as_root();
insert into public.consumable_effects (item_id, seq, effect_type, dice_expression) values (:'herb', 1, 'damage', '2d6');
select tl_test.as_user(:'dm');
select public.set_item_identify_options(:'herb', '{"unidentified_name": "Purple wildflower", "unidentified_description": "A pretty purple flower.",
  "show_kind": true, "identify_dc": 13, "identify_checks": ["nature", "medicine", "herbalism-kit"], "identify_reveal": ["all"],
  "identify_auto": false, "identify_retry": "dm", "fail_hint": "It smells like lavender: probably harmless."}') as opts \gset
select tl_test.rec('HI1 the DM sets decoy, DC, checks, reveal, retry and hint; the item leaves the players'' catalog',
  (:'opts'::jsonb ->> 'identify_dc')::int = 13 and :'opts'::jsonb ->> 'face_kind_id' = 'herbs_plants'
  and (select secret from public.items where id = :'herb'), :'opts');
select tl_test.hi_code('select public.set_item_identify_options(''candle'', ''{"identify_dc": 5}'')') as off_code \gset
select tl_test.as_user(:'alice');
select tl_test.rec('HI2 a player cannot set options; official items cannot get options',
  tl_test.hi_code(format('select public.set_item_identify_options(%L, %L)', :'herb', '{"identify_dc": 1}')) = '42501' and :'off_code' = '42501');
select tl_test.as_user(:'dm');
select public.set_item_identify_options(:'herb', '{"identify_dc": 13}');

-- ---- assignment: inserted with the disguise ------------------------------------------------------------------------------------
select tl_test.hi_cache_rev(:'h1') as cr0 \gset
select public.dm_give_item(:'herb', array[:'h1', :'h3']::uuid[], 3, false) as give \gset
select tl_test.rec('HI3 dm_give_item gives the herb unidentified to two characters',
  (select bool_and((x ->> 'ok')::boolean) from jsonb_array_elements(:'give'::jsonb -> 'results') x)
  and tl_test.hi_rows(:'h1', :'herb') = 1 and (tl_test.hi_row(:'h1', :'herb')).quantity = 3 and (tl_test.hi_row(:'h1', :'herb')).name = 'Purple wildflower', :'give');
select tl_test.rec('HI4 LEAK Realtime INSERT: no inserted row image ever carried the true name or description',
  (select count(*) from tl_test.hi_inserts) >= 2 and (select bool_and(tl_test.hi_clean(name || ' ' || coalesce(description, ''))) from tl_test.hi_inserts),
  (select string_agg(name, ',') from tl_test.hi_inserts));

-- ---- the player before any reveal --------------------------------------------------------------------------------------------
select tl_test.as_user(:'alice');
select (select to_jsonb(d) from public.v_inventory_detail d where d.character_id = :'h1' and d.name = 'Purple wildflower') as vrow \gset
select public.get_character_item_knowledge(:'h1') as kn \gset
select tl_test.rec('HI5 player view row: decoy name + description, type Herbs & Plants (face), no item id / rarity / magic / category',
  :'vrow'::jsonb ->> 'item_id' is null and :'vrow'::jsonb ->> 'kind_id' = 'herbs_plants' and :'vrow'::jsonb ->> 'category_id' is null
  and :'vrow'::jsonb ->> 'is_magic' is null and :'vrow'::jsonb ->> 'knowledge_state' = 'unidentified'
  and :'vrow'::jsonb ->> 'description' = 'A pretty purple flower.' and (:'vrow'::jsonb ->> 'is_consumable')::boolean and (:'vrow'::jsonb ->> 'stackable')::boolean
  and tl_test.hi_clean(:'vrow'), :'vrow');
select tl_test.rec('HI6 player knowledge read: decoy, face type, allowed checks with labels, can examine; no DC, hint, true name, details',
  :'kn'::jsonb -> 0 ->> 'description' = 'A pretty purple flower.' and :'kn'::jsonb -> 0 ->> 'kind_id' = 'herbs_plants'
  and (:'kn'::jsonb -> 0 -> 'identify' ->> 'can_examine')::boolean and :'kn'::jsonb -> 0 -> 'details' = 'null'::jsonb
  and :'kn'::jsonb -> 0 -> 'identify' -> 'checks' @> '[{"key": "herbalism-kit", "label": "Herbalism kit"}]'
  and tl_test.hi_clean(:'kn'), :'kn');
select tl_test.rec('HI7 LEAK REST: catalog row, child tables, secrets, knowledge and attempt tables are closed to the player',
  not exists (select 1 from public.items where id = :'herb') and not exists (select 1 from public.v_item_catalog where id = :'herb')
  and not exists (select 1 from public.consumable_effects where item_id = :'herb') and not exists (select 1 from public.item_secrets)
  and tl_test.hi_code('select 1 from public.character_item_knowledge') = '42501' and tl_test.hi_code('select 1 from public.item_identify_attempts') = '42501'
  and tl_test.hi_code('select true_name from public.inventory_item_knowledge') = '42501'
  and tl_test.hi_clean((select string_agg(to_jsonb(d)::text, '') from public.v_inventory_detail d where d.character_id = :'h1'))
  and tl_test.hi_clean((select string_agg(to_jsonb(e)::text, '') from public.inventory_events e))
  and tl_test.hi_clean(public.get_campaign_audit(:'camp')::text));
select tl_test.hi_fresh(:'h1');
select public.get_character_reads(:'h1', array['get_character_derived_stats', 'inventory_bundle', 'get_character_states']) as rd1 \gset
select public.get_character_reads(:'h1', array['get_character_derived_stats', 'inventory_bundle', 'get_character_states']) as rd2 \gset
select tl_test.rec('HI8 LEAK get_character_reads: cache miss and hit carry neither the truth nor the catalog row; tl_cache rows are clean',
  (:'rd2'::jsonb -> 'cache' ->> 'hits')::int >= 1 and tl_test.hi_clean(:'rd1') and tl_test.hi_clean(:'rd2')
  and :'rd1'::jsonb -> 'reads' -> 'inventory_bundle' -> 'rows' -> 0 ->> 'item_id' is null
  and position(:'herb' in :'rd1') = 0 and tl_test.hi_clean(tl_test.hi_cached(:'h1', :'alice')), :'rd2'::jsonb ->> 'cache');
select public.use_inventory_item((tl_test.hi_row(:'h1', :'herb')).id, 1) as used \gset
select tl_test.rec('HI9 LEAK eating an unidentified herb: no effects, the face type, no item id, the decoy name',
  :'used'::jsonb -> 'effects' = '[]'::jsonb and :'used'::jsonb ->> 'item_id' is null and :'used'::jsonb ->> 'kind_id' = 'herbs_plants'
  and :'used'::jsonb ->> 'name' = 'Purple wildflower' and (:'used'::jsonb ->> 'remaining')::int = 2 and tl_test.hi_clean(:'used')
  and tl_test.hi_clean((select string_agg(to_jsonb(e)::text, '') from public.inventory_events e)), :'used');

-- ---- examine: validation, pending, DM inbox ----------------------------------------------------------------------------------
select (tl_test.hi_row(:'h1', :'herb')).id as r1 \gset
select tl_test.as_user(:'bob');
select tl_test.hi_code(format('select public.examine_inventory_item(%L, %L, 12)', :'r1', 'nature')) as bob_code \gset
select tl_test.as_user(:'alice');
select tl_test.rec('HI10 examine validation: wrong check, roll out of range, another player''s row',
  tl_test.hi_code(format('select public.examine_inventory_item(%L, %L, 12)', :'r1', 'arcana')) = '22023'
  and tl_test.hi_code(format('select public.examine_inventory_item(%L, %L, 99)', :'r1', 'nature')) = '22023' and :'bob_code' = '42501');
select tl_test.hi_fresh(:'h1');
select tl_test.hi_revs(:'h1') as rv0 \gset
select public.examine_inventory_item(:'r1', 'Nature', 15, 'e0000000-0000-0000-0000-000000000001') as ex1 \gset
select tl_test.rec('HI11 examine (Nature 15) -> pending; the answer has no DC; replay with the same request id returns the same attempt; the sheet is signalled',
  :'ex1'::jsonb ->> 'status' = 'pending' and :'ex1'::jsonb ->> 'check_key' = 'nature' and tl_test.hi_clean(:'ex1')
  and (public.examine_inventory_item(:'r1', 'nature', 15, 'e0000000-0000-0000-0000-000000000001') ->> 'attempt_id') = :'ex1'::jsonb ->> 'attempt_id'
  and tl_test.hi_code(format('select public.examine_inventory_item(%L, %L, 18)', :'r1', 'medicine')) = '55000'
  and tl_test.hi_revs(:'h1') > :rv0, :'ex1');
select tl_test.rec('HI12 a player cannot read the DM inbox, resolve or reveal',
  tl_test.hi_code(format('select public.get_campaign_identify_attempts(%L)', :'camp')) = '42501'
  and tl_test.hi_code(format('select public.resolve_identify_attempt(%L, true)', :'ex1'::jsonb ->> 'attempt_id')) = '42501'
  and tl_test.hi_code(format('select public.dm_reveal_item(%L, null)', :'herb')) = '42501'
  and tl_test.hi_code(format('select public.dm_give_item(%L, array[%L]::uuid[], 1, false)', :'herb', :'h2')) = 'P0002');
select tl_test.as_user(:'dm');
select public.get_campaign_identify_attempts(:'camp') as inbox \gset
select tl_test.rec('HI13 DM inbox: the pending attempt with true name, decoy, DC and roll',
  :'inbox'::jsonb -> 0 ->> 'true_name' = 'Nightshade Bloom' and (:'inbox'::jsonb -> 0 ->> 'dc')::int = 13
  and :'inbox'::jsonb -> 0 ->> 'shown_name' = 'Purple wildflower' and (:'inbox'::jsonb -> 0 ->> 'roll_total')::int = 15, :'inbox');
-- the DM corrects the roll to 10: failure by the roll (p_success null)
select public.resolve_identify_attempt((:'ex1'::jsonb ->> 'attempt_id')::uuid, null, 10, 'You misread the leaves') as res1 \gset
select tl_test.as_user(:'alice');
select public.get_character_item_knowledge(:'h1') as kn2 \gset
select tl_test.rec('HI14 DM-corrected roll below the DC -> failed: the decoy stays, the hint shows, retry rule "dm" blocks a new attempt',
  :'res1'::jsonb ->> 'status' = 'failed' and :'kn2'::jsonb -> 0 -> 'identify' -> 'last' ->> 'hint' = 'It smells like lavender: probably harmless.'
  and not (:'kn2'::jsonb -> 0 -> 'identify' ->> 'can_examine')::boolean and (tl_test.hi_row(:'h1', :'herb')).name = 'Purple wildflower'
  and tl_test.hi_code(format('select public.examine_inventory_item(%L, %L, 20)', :'r1', 'nature')) = '55000'
  and position('misread' in :'kn2') = 0, :'kn2');
select tl_test.as_user(:'dm');
select public.resolve_identify_attempt((:'ex1'::jsonb ->> 'attempt_id')::uuid, null, null, null, true);
select tl_test.rec('HI15 an attempt is answered exactly once', tl_test.hi_code(format('select public.resolve_identify_attempt(%L, true)', :'ex1'::jsonb ->> 'attempt_id')) = '55000');
select tl_test.as_user(:'alice');
select public.examine_inventory_item(:'r1', 'herbalism-kit', 14) as ex2 \gset
select tl_test.as_user(:'dm');
select tl_test.hi_fresh(:'h1');
select tl_test.hi_revs(:'h1') as rv1 \gset
select tl_test.hi_cache_rev(:'h1') as cr1 \gset
select public.resolve_identify_attempt((:'ex2'::jsonb ->> 'attempt_id')::uuid, true) as res2 \gset
select tl_test.as_user(:'alice');
select (select to_jsonb(d) from public.v_inventory_detail d where d.character_id = :'h1' and d.knowledge_state is not null) as vrow2 \gset
select tl_test.rec('HI16 after the DM grants a retry and confirms: h1 sees the true name, description, item id and catalog row; the sheet and the cache are signalled',
  :'res2'::jsonb ->> 'status' = 'succeeded' and :'vrow2'::jsonb ->> 'name' = 'Nightshade Bloom' and :'vrow2'::jsonb ->> 'item_id' = :'herb'
  and :'vrow2'::jsonb ->> 'description' = 'Deadly purple flower.' and exists (select 1 from public.items where id = :'herb')
  and (public.get_character_item_knowledge(:'h1') -> 0 ->> 'state') = 'identified' and tl_test.hi_revs(:'h1') > :rv1
  and tl_test.hi_cache_rev(:'h1') > :cr1, :'vrow2');

-- ---- per character -------------------------------------------------------------------------------------------------------
select tl_test.as_user(:'dm');
select public.dm_give_item(:'herb', array[:'h2']::uuid[], 1, false);
select tl_test.as_user(:'alice');
select (select to_jsonb(d) from public.v_inventory_detail d where d.character_id = :'h2' and d.knowledge_state is not null) as vrow3 \gset
select public.get_character_reads(:'h2', array['inventory_bundle']) as rd3 \gset
select tl_test.rec('HI17 per character: the same player''s second character still sees the decoy (row, knowledge, bundle rows)',
  :'vrow3'::jsonb ->> 'name' = 'Purple wildflower' and :'vrow3'::jsonb ->> 'item_id' is null and :'vrow3'::jsonb ->> 'knowledge_state' = 'unidentified'
  and (public.get_character_item_knowledge(:'h2') -> 0 ->> 'state') = 'unidentified'
  and tl_test.hi_clean((public.get_character_item_knowledge(:'h2'))::text)
  and tl_test.hi_clean(:'rd3'::jsonb -> 'reads' -> 'inventory_bundle' ->> 'rows')
  and not (:'rd3'::jsonb -> 'reads' -> 'inventory_bundle' -> 'catalog_items' @> jsonb_build_array(jsonb_build_object('id', :'herb'))), :'vrow3');
select tl_test.as_user(:'bob');
select tl_test.rec('HI18 another player''s character (h3) still sees only the decoy; bob cannot read the catalog row',
  (select name from public.v_inventory_detail where character_id = :'h3' and knowledge_state is not null) = 'Purple wildflower'
  and not exists (select 1 from public.items where id = :'herb') and tl_test.hi_clean(public.get_character_item_knowledge(:'h3')::text));

-- ---- hidden option change: no signal ------------------------------------------------------------------------------------
select tl_test.as_user(:'dm');
select tl_test.hi_fresh(:'h3');
select tl_test.hi_revs(:'h3') as rv3 \gset
select tl_test.hi_cache_rev(:'h3') as cr3 \gset
select public.set_item_identify_options(:'herb', '{"identify_auto": true, "identify_retry": "once", "identify_reveal": ["description", "details"], "fail_hint": "It smells like lavender."}');
select tl_test.rec('HI19 a hidden option change writes no revision row and no cache counter change for any character',
  tl_test.hi_revs(:'h3') = :rv3 and tl_test.hi_cache_rev(:'h3') = :cr3);

-- ---- auto mode, retry once, partial reveal --------------------------------------------------------------------------------
select tl_test.as_user(:'bob');
select (tl_test.hi_row(:'h3', :'herb')).id as r3 \gset
select public.examine_inventory_item(:'r3', 'medicine', 9) as ex3 \gset
select tl_test.rec('HI20 auto mode: a roll below the DC fails at once with the hint; retry rule "once" blocks the next attempt',
  :'ex3'::jsonb ->> 'status' = 'failed' and :'ex3'::jsonb ->> 'hint' = 'It smells like lavender.' and (:'ex3'::jsonb ->> 'auto')::boolean
  and tl_test.hi_code(format('select public.examine_inventory_item(%L, %L, 20)', :'r3', 'nature')) = '55000'
  and tl_test.hi_clean((:'ex3'::jsonb - 'hint')::text), :'ex3');
select tl_test.as_user(:'dm');
select public.set_item_identify_options(:'herb', '{"identify_retry": "unlimited"}');
select tl_test.as_user(:'bob');
select public.examine_inventory_item(:'r3', 'nature', 13) as ex4 \gset
select (select to_jsonb(d) from public.v_inventory_detail d where d.character_id = :'h3' and d.knowledge_state is not null) as vrow4 \gset
select public.get_character_item_knowledge(:'h3') as kn4 \gset
select tl_test.rec('HI21 auto mode, roll = DC: only the configured parts (description, details) are revealed; the name and the catalog row stay hidden',
  :'ex4'::jsonb ->> 'status' = 'succeeded' and :'vrow4'::jsonb ->> 'knowledge_state' = 'partially_identified'
  and :'vrow4'::jsonb ->> 'name' = 'Purple wildflower' and :'vrow4'::jsonb ->> 'description' = 'Deadly purple flower.' and :'vrow4'::jsonb ->> 'item_id' is null
  and :'kn4'::jsonb -> 0 -> 'details' ->> 'harvesting' = 'Paralysis poison in the sap' and :'kn4'::jsonb -> 0 ->> 'true_name' is null
  and not exists (select 1 from public.items where id = :'herb') and position('Nightshade' in :'kn4') = 0, :'kn4');
select tl_test.rec('HI22 unlimited retries keep working after a partial reveal (the DC is never returned)',
  tl_test.hi_code(format('select public.examine_inventory_item(%L, %L, 2)', :'r3', 'nature')) = 'ok'
  and position('"dc"' in public.get_character_item_knowledge(:'h3')::text) = 0);

-- ---- merge, split, transfer --------------------------------------------------------------------------------------------
select tl_test.as_user(:'dm');
select public.dm_give_item(:'herb', array[:'h3']::uuid[], 2, false);
select tl_test.rec('HI23 a new copy for a character who knows part of the item arrives in that state and merges into its stack',
  tl_test.hi_rows(:'h3', :'herb') = 1 and (tl_test.hi_row(:'h3', :'herb')).quantity = 5
  and (select state from public.inventory_item_knowledge where inventory_item_id = (tl_test.hi_row(:'h3', :'herb')).id) = 'partially_identified');
select tl_test.as_user(:'bob');
select public.split_inventory_stack((tl_test.hi_row(:'h3', :'herb')).id, 2) as sp \gset
select tl_test.rec('HI24 split copies the knowledge row (the split-off part never reveals the catalog row)',
  (select state from public.inventory_item_knowledge where inventory_item_id = :'sp') = 'partially_identified'
  and (select item_id from public.v_inventory_detail where id = :'sp') is null and not exists (select 1 from public.items where id = :'herb'));
select tl_test.as_user(:'dm');
delete from tl_test.hi_inserts;
select public.transfer_inventory_item((tl_test.hi_row(:'h1', :'herb')).id, tl_test.inv(:'h2'), 1) as tr \gset
select tl_test.rec('HI25 transfer from a character who identified it to one who did not: the receiver gets the decoy, in the same write',
  (select name from public.inventory_items where id = :'tr') = 'Purple wildflower'
  and (select state from public.inventory_item_knowledge where inventory_item_id = :'tr') = 'unidentified'
  and (tl_test.hi_row(:'h1', :'herb')).name = 'Nightshade Bloom');
select tl_test.as_root();
select tl_test.rec('HI26 stack keys: every non-secret row''s stored key equals the recomputed key (normal stacks still merge)',
  not exists (select 1 from public.inventory_items ii join public.items i on i.id = ii.item_id where not i.secret
              and ii.stack_key is distinct from public.compute_stack_key(ii)));
select tl_test.as_user(:'alice');
select tl_test.give(:'h1', 'candle', null, 2) as c1 \gset
select tl_test.give(:'h1', 'candle', null, 3) as c2 \gset
select tl_test.rec('HI27 an ordinary stackable item still merges', :'c1' = :'c2' and (select quantity from public.inventory_items where id = :'c1') = 5);

-- ---- DM reveal to one / to all -----------------------------------------------------------------------------------------
select tl_test.as_user(:'dm');
select public.dm_reveal_item(:'herb', array[:'h2']::uuid[]) as rv \gset
select tl_test.as_user(:'alice');
select (select string_agg(distinct name, ',') from public.v_inventory_detail where character_id = :'h2' and knowledge_state is not null) as h2names \gset
select tl_test.as_user(:'bob');
select tl_test.rec('HI28 DM reveal to one character: h2 now sees the truth (all its rows), bob''s h3 does not',
  :'h2names' = 'Nightshade Bloom'
  and (select string_agg(distinct name, ',') from public.v_inventory_detail where character_id = :'h3' and knowledge_state is not null) = 'Purple wildflower', :'h2names');
select tl_test.as_user(:'dm');
select public.dm_reveal_item(:'herb', null) as rv2 \gset
select tl_test.as_user(:'bob');
select tl_test.rec('HI29 DM reveal to all characters of the campaign: bob''s rows are identified (pending attempts closed)',
  (:'rv2'::jsonb ->> 'characters')::int >= 3
  and not exists (select 1 from public.v_inventory_detail where character_id = :'h3' and knowledge_state <> 'identified')
  and exists (select 1 from public.items where id = :'herb'));

-- ---- DM Content path: hidden options in the definition, assignment, examine --------------------------------------------
select tl_test.as_user(:'dm');
select (public.create_dm_content('item', :'camp', '{"name": "Ghostcap", "summary": "A pale mushroom.",
  "definition": {"item": {"kind_id": "herbs_plants", "category_id": "plant-fungus", "stackable": true},
                 "hidden": {"unidentified_name": "Pale mushroom", "unidentified_description": "Small and pale.", "identify_dc": 12,
                            "identify_checks": ["nature"], "identify_auto": true, "identify_retry": "unlimited"}}}') ->> 'id') as gc \gset
select public.publish_dm_content(:'gc');
select tl_test.hi_ref(:'gc') as gref \gset
select public.dm_assign_content(:'gc', array[:'h2']::uuid[], 'inventory', '{"identified": false}');
select tl_test.as_user(:'alice');
select tl_test.rec('HI30 DM Content: the hidden options reach item_secrets; the herb shows as Herbs & Plants under its decoy',
  (select kind_id from public.v_inventory_detail where character_id = :'h2' and name = 'Pale mushroom') = 'herbs_plants'
  and position('Ghostcap' in public.get_character_item_knowledge(:'h2')::text) = 0);
select public.examine_inventory_item((select id from public.v_inventory_detail where character_id = :'h2' and name = 'Pale mushroom'), 'nature', 12) as ex5 \gset
select tl_test.rec('HI31 auto success on the DM Content herb: identified for h2 only',
  :'ex5'::jsonb ->> 'status' = 'succeeded' and exists (select 1 from public.v_inventory_detail where character_id = :'h2' and name = 'Ghostcap')
  , :'ex5');
select tl_test.as_root();
select tl_test.rec('HI32 the DM Content herb is unknown to h1 (knowledge is per character)',
  not exists (select 1 from public.character_item_knowledge where character_id = :'h1' and item_id = :'gref')
  and (select state from public.character_item_knowledge where character_id = :'h2' and item_id = :'gref') = 'identified');

-- ---- review round 2 (M1): DM Content keeps its options in the definition; the direct RPC refuses it -------------------------
create function tl_test.hi_idcols(p_item text) returns text language sql security definer as $$
  select concat_ws('|', identify_dc, identify_checks::text, identify_reveal::text, identify_auto, identify_retry, fail_hint, face_kind_id)
  from public.item_secrets where item_id = p_item $$;
create function tl_test.hi_def(p_content uuid) returns jsonb language sql security definer as $$
  select v.definition from public.dm_content c join public.dm_content_versions v on v.id = c.current_version_id where c.id = p_content $$;
create function tl_test.hi_grev() returns bigint language sql security definer as $$ select rev from tl_cache.global_rev where id = 1 $$;
grant execute on all functions in schema tl_test to public;
select tl_test.hi_idcols(:'gref') as gcols \gset
select tl_test.as_user(:'dm');
select tl_test.hi_code(format('select public.set_item_identify_options(%L, %L)', :'gref', '{"identify_dc": 5}')) as cc_code \gset
select (select x from jsonb_array_elements(public.get_character_item_knowledge(:'h2')) x where x ->> 'item_id' = :'gref') as gkn \gset
select (select x from jsonb_array_elements(public.get_character_item_knowledge(:'h2')) x where x ->> 'item_id' = :'herb' limit 1) as hkn \gset
select tl_test.rec('HI33 DM Content: set_item_identify_options refuses it (55000) and changes nothing; the DM view links the content (no direct editing), homebrew stays editable',
  :'cc_code' = '55000' and tl_test.hi_idcols(:'gref') = :'gcols' and :'gkn'::jsonb -> 'identify' ->> 'content_id' = :'gc'
  and not (:'gkn'::jsonb -> 'identify' ->> 'secrets_editable')::boolean and (:'hkn'::jsonb -> 'identify' ->> 'secrets_editable')::boolean
  and :'hkn'::jsonb -> 'identify' ->> 'content_id' is null, :'cc_code' || ' ' || coalesce(:'gkn'::jsonb ->> 'identify', ''));
-- republish without a change: identical options on the new version's catalog row, the held copy untouched
select public.new_dm_content_version(:'gc');
select public.publish_dm_content(:'gc');
select tl_test.hi_ref(:'gc') as gref2 \gset
select tl_test.rec('HI34 a new version published without a change keeps the identification options (round trip), the held v1 copy is unchanged',
  :'gref2' <> :'gref' and tl_test.hi_idcols(:'gref2') = :'gcols' and tl_test.hi_idcols(:'gref') = :'gcols', tl_test.hi_idcols(:'gref2'));
-- the DM changes the DC and the hint in the content: copies players already hold (v1) follow; their decoy stays
select public.new_dm_content_version(:'gc');
select public.save_dm_content(:'gc', jsonb_build_object('definition', jsonb_set(jsonb_set(tl_test.hi_def(:'gc'), '{hidden,identify_dc}', '16'),
  '{hidden,fail_hint}', '"Just a mushroom."')));
select public.publish_dm_content(:'gc');
select tl_test.hi_ref(:'gc') as gref3 \gset
select tl_test.as_root();
select tl_test.rec('HI35 a changed DC / hint in a new version reaches every version''s catalog row (held copies included); the decoy stays per version',
  (select identify_dc from public.item_secrets where item_id = :'gref') = 16 and (select fail_hint from public.item_secrets where item_id = :'gref') = 'Just a mushroom.'
  and (select identify_dc from public.item_secrets where item_id = :'gref3') = 16 and (select unidentified_name from public.item_secrets where item_id = :'gref') = 'Pale mushroom'
  and tl_test.hi_idcols(:'gref') = tl_test.hi_idcols(:'gref3'), tl_test.hi_idcols(:'gref'));
-- a definition without an identification section (an API caller) wipes nothing on the earlier versions
select tl_test.as_user(:'dm');
select public.new_dm_content_version(:'gc');
select public.save_dm_content(:'gc', jsonb_build_object('definition', (tl_test.hi_def(:'gc') - 'hidden') || '{"hidden": {"unidentified_name": "Grey mushroom"}}'));
select public.publish_dm_content(:'gc');
select tl_test.as_root();
select tl_test.rec('HI36 a published definition without identification fields leaves the earlier versions'' options as they were',
  (select identify_dc from public.item_secrets where item_id = :'gref') = 16 and (select identify_dc from public.item_secrets where item_id = :'gref3') = 16
  and (select fail_hint from public.item_secrets where item_id = :'gref') = 'Just a mushroom.');

-- ---- m2: a stack's stored key follows items.secret --------------------------------------------------------------------
select tl_test.as_user(:'dm');
select public.create_homebrew_item(gen_random_uuid(), jsonb_build_object('name', 'Sunroot', 'kind_id', 'herbs_plants', 'category_id', 'plant-flower',
  'campaign_id', :'camp', 'stackable', true, 'is_consumable', true)) ->> 'id' as sun \gset
select tl_test.as_user(:'alice');
select tl_test.give(:'h1', :'sun', null, 2) as sr \gset
select tl_test.as_root();
select stack_key as sk0 from public.inventory_items where id = :'sr' \gset
select tl_test.as_user(:'dm');
select public.set_item_identify_options(:'sun', '{"identify_dc": 10}');
select tl_test.as_root();
select tl_test.rec('HI37 the item becomes secret: its stored row keys are recomputed (name part), quantity and rows unchanged, no merge',
  (select secret from public.items where id = :'sun') and (select stack_key from public.inventory_items where id = :'sr') is distinct from :'sk0'
  and (select stack_key = public.compute_stack_key(ii) from public.inventory_items ii where id = :'sr') and (select quantity from public.inventory_items where id = :'sr') = 2
  and tl_test.hi_rows(:'h1', :'sun') = 1);
select tl_test.rec('HI38 stack keys: every row''s stored key (secret items included) equals the recomputed key',
  not exists (select 1 from public.inventory_items ii where ii.stack_key is distinct from public.compute_stack_key(ii)));

-- ---- m3: a knowledge change bumps the holders of the item only, never the global counter -------------------------------
select tl_test.as_user(:'dm');
select public.dm_give_item(:'sun', array[:'h3']::uuid[], 1, false);
select tl_test.as_root();
select tl_test.hi_fresh(:'h3'), tl_test.hi_fresh(:'h2'), tl_test.hi_fresh(:'h1'), set_config('tl_cache.i' || md5(:'sun' || txid_current()::text), '', true);
select tl_test.hi_grev() as g0 \gset
select tl_test.hi_cache_rev(:'h3') as c3 \gset
select tl_test.hi_cache_rev(:'h1') as c1 \gset
select tl_test.hi_cache_rev(:'h2') as c2 \gset
update public.inventory_item_knowledge set revealed = '{magic}' where inventory_item_id = (tl_test.hi_row(:'h3', :'sun')).id;
select tl_test.rec('HI39 a knowledge row change bumps every holder of the item (h3, h1), not the others (h2), not the global counter',
  tl_test.hi_cache_rev(:'h3') > :c3 and tl_test.hi_cache_rev(:'h1') > :c1 and tl_test.hi_cache_rev(:'h2') = :c2 and tl_test.hi_grev() = :g0
  and (select tgfoid = 'tl_cache.bump_item_knowledge()'::regprocedure from pg_trigger where tgrelid = 'public.inventory_item_knowledge'::regclass and tgname = 'tl_cache_rev'));
select tl_test.hi_fresh(:'h3'), tl_test.hi_fresh(:'h2'), set_config('tl_cache.i' || md5(:'sun' || txid_current()::text), '', true);
select tl_test.hi_cache_rev(:'h3') as c3b \gset
select tl_test.hi_revs(:'h3') as rv3b \gset
select tl_test.as_user(:'dm');
select public.set_item_knowledge((tl_test.hi_row(:'h3', :'sun')).id, 'partially_identified', '{description}');
select tl_test.as_root();
select tl_test.rec('HI40 a DM reveal through the RPC: the character''s revision and cache counter move, the global counter does not (item already secret)',
  tl_test.hi_cache_rev(:'h3') > :c3b and tl_test.hi_revs(:'h3') > :rv3b and tl_test.hi_grev() = :g0 and tl_test.hi_cache_rev(:'h2') = :c2);

-- ---- m5: retry after a long rest, replay of a duplicate request, transfer to the party stash ------------------------------
select tl_test.as_user(:'dm');
select public.create_homebrew_item(gen_random_uuid(), jsonb_build_object('name', 'Moonleaf', 'kind_id', 'herbs_plants', 'category_id', 'plant-flower',
  'campaign_id', :'camp', 'stackable', true)) ->> 'id' as moon \gset
select public.set_item_identify_options(:'moon', '{"unidentified_name": "Silver leaf", "identify_dc": 15, "identify_auto": true, "identify_retry": "per_long_rest"}');
select public.dm_give_item(:'moon', array[:'h1']::uuid[], 1, false);
select tl_test.as_user(:'alice');
select (tl_test.hi_row(:'h1', :'moon')).id as mr \gset
select public.examine_inventory_item(:'mr', 'nature', 5) as m1 \gset
select tl_test.rec('HI41 retry "per_long_rest": after a failure no new attempt before a long rest',
  :'m1'::jsonb ->> 'status' = 'failed' and tl_test.hi_code(format('select public.examine_inventory_item(%L, %L, 20)', :'mr', 'nature')) = '55000'
  and not ((select x from jsonb_array_elements(public.get_character_item_knowledge(:'h1')) x where x ->> 'inventory_item_id' = :'mr') -> 'identify' ->> 'can_examine')::boolean);
select tl_test.as_root();
-- one transaction: now() is frozen, so the rest is stamped explicitly after the failed attempt
insert into public.character_resource_events (character_id, event_type, pool, created_at) values (:'h1', 'long_rest', 'rest', now() + interval '1 minute');
select tl_test.as_user(:'alice');
select ((select x from jsonb_array_elements(public.get_character_item_knowledge(:'h1')) x where x ->> 'inventory_item_id' = :'mr') -> 'identify' ->> 'can_examine')::boolean as can2 \gset
select public.examine_inventory_item(:'mr', 'nature', 18, 'e0000000-0000-0000-0000-000000000042') as m2 \gset
select tl_test.rec('HI42 after a long rest the player may examine again (auto success)', :'can2' and :'m2'::jsonb ->> 'status' = 'succeeded', :'m2');
select tl_test.as_root();
select (select count(*) from public.item_identify_attempts where request_id = 'e0000000-0000-0000-0000-000000000042') as n_req \gset
select tl_test.as_user(:'alice');
select public.examine_inventory_item(:'mr', 'nature', 18, 'e0000000-0000-0000-0000-000000000042') as m3 \gset
select tl_test.as_user(:'bob');
select tl_test.hi_code(format('select public.examine_inventory_item(%L, %L, 18, %L)', :'mr', 'nature', 'e0000000-0000-0000-0000-000000000042')) as bob_replay \gset
select tl_test.as_root();
select tl_test.rec('HI43 a duplicate request after an auto success replays the same attempt (no 22023 / 23505, no second row); another user is refused',
  (:'m3'::jsonb ->> 'replayed')::boolean and :'m3'::jsonb ->> 'attempt_id' = :'m2'::jsonb ->> 'attempt_id' and :'m3'::jsonb ->> 'status' = 'succeeded'
  and :n_req = 1 and (select count(*) from public.item_identify_attempts where request_id = 'e0000000-0000-0000-0000-000000000042') = 1
  and :'bob_replay' = '42501', :'m3');
-- current behaviour (documented, T4b): a party stash keeps the row's own knowledge, so an identified copy deposited there
-- shows its true name to every member who can read the stash
insert into public.inventories (kind, name, campaign_id) values ('party_stash', 'Herb Stash', :'camp') returning id as stash \gset
select tl_test.as_user(:'alice');
select public.transfer_inventory_item(:'mr', :'stash') as ms \gset
select tl_test.as_user(:'bob');
select tl_test.rec('HI44 (documented) an identified row moved into the party stash keeps its knowledge and true name; party members read it',
  (select name from public.inventory_items where id = :'ms') = 'Moonleaf'
  and (select knowledge_state from public.v_inventory_detail where id = :'ms') = 'identified'
  and (select item_id from public.v_inventory_detail where id = :'ms') = :'moon');
