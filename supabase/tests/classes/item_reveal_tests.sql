-- =============================================================================
-- Per-character reveal (20261112000400, docs/HIDDEN_DM_DATA.md "Revealing items to characters"): dm_set_item_knowledge (one /
-- selected / whole party, partial levels, undo, raise never lowers, idempotency), hiding an item a character holds undisguised
-- (m6), official items refused, role refusals (player, outsider, anon), the DM's "who knows what" read and item picker, the
-- append-only history, and the REQUIRED check: player A sees the revealed item while player B (same item, same campaign) still
-- reads only the decoy through every player surface. The backfill on a synthetic row-knowledge fixture leaves every
-- character's visible state identical.
-- Runs inside the per-class harness (alice = player of :camp, bob = made a player here, dm = DM of :camp).
-- =============================================================================
\set r1 f4b00000-0000-0000-0000-000000000001
\set r2 f4b00000-0000-0000-0000-000000000002
\set r3 f4b00000-0000-0000-0000-000000000003
\set eve e5555555-5555-5555-5555-555555555555
insert into public.campaign_members (campaign_id, user_id, role) values (:'camp', :'bob', 'player');
insert into auth.users (id, email) values (:'eve', 'eve@test');
insert into public.characters (id, owner_id, name, campaign_id, level, strength, dexterity, constitution, intelligence, wisdom, charisma, hp_max, hp_current, speed) values
  (:'r1', :'alice', 'Reveal A', :'camp', 1, 10, 12, 12, 10, 14, 10, 10, 10, 30),
  (:'r2', :'bob', 'Reveal B', :'camp', 1, 10, 12, 12, 10, 14, 10, 10, 10, 30),
  (:'r3', :'alice', 'Reveal A2', :'camp', 1, 10, 12, 12, 10, 14, 10, 10, 10, 30);
create function tl_test.ir_code(p_sql text) returns text language plpgsql as $$
begin execute p_sql; return 'ok'; exception when others then return sqlstate; end $$;
create function tl_test.ir_row(p_char uuid, p_item text) returns public.inventory_items language sql security definer as $$
  select ii.* from public.inventory_items ii join public.inventories inv on inv.id = ii.inventory_id
  where inv.character_id = p_char and ii.item_id = p_item order by ii.quantity desc, ii.id limit 1 $$;
create function tl_test.ir_revs(p_char uuid) returns int language sql security definer as $$
  select count(*)::int from public.character_revisions where character_id = p_char $$;
create function tl_test.ir_audits(p_char uuid) returns int language sql security definer as $$
  select count(*)::int from public.campaign_audit_events where character_id = p_char $$;
create function tl_test.ir_events(p_item text) returns int language sql security definer as $$
  select count(*)::int from public.item_knowledge_events where item_id = p_item $$;
create function tl_test.ir_ck(p_char uuid, p_item text) returns text language sql security definer as $$
  select state || ':' || array_to_string(revealed, ',') from public.character_item_knowledge where character_id = p_char and item_id = p_item $$;
create function tl_test.ir_rowk(p_char uuid, p_item text) returns text language sql security definer as $$
  select string_agg(coalesce(k.state, '-') || ':' || coalesce(array_to_string(k.revealed, ','), ''), ';' order by ii.id)
  from public.inventory_items ii join public.inventories inv on inv.id = ii.inventory_id left join public.inventory_item_knowledge k on k.inventory_item_id = ii.id
  where inv.character_id = p_char and ii.item_id = p_item $$;
-- what the CURRENT caller sees of one character's items: view rows, catalog rows of campaign / secret items, knowledge read
create function tl_test.ir_seen(p_char uuid) returns text language sql as $$
  select coalesce((select string_agg(concat_ws('|', d.id, d.name, d.description, d.item_id, d.kind_id, d.rarity_id, d.is_magic, d.knowledge_state), ';' order by d.id)
                   from public.v_inventory_detail d where d.character_id = p_char), '') || '#'
      || coalesce((select string_agg(it.id || '|' || it.name, ';' order by it.id) from public.items it where it.campaign_id is not null or it.secret), '') || '#'
      || coalesce(public.get_character_item_knowledge(p_char)::text, '') $$;
create function tl_test.ir_clean(p_text text) returns boolean language sql as $$
  select position('Starbloom' in coalesce(p_text, '')) = 0 and position('Glows under moonlight' in coalesce(p_text, '')) = 0 $$;
grant all on all functions in schema tl_test to public;

-- ---- setup: a disguised campaign herb given to A (alice) and B (bob) ----------------------------------------------------------
select tl_test.as_user(:'dm');
select public.create_homebrew_item(gen_random_uuid(), jsonb_build_object('name', 'Starbloom', 'kind_id', 'herbs_plants', 'category_id', 'plant-flower',
  'campaign_id', :'camp', 'stackable', true, 'description', 'Glows under moonlight.')) ->> 'id' as herb \gset
select public.set_item_identify_options(:'herb', '{"unidentified_name": "Pale bud", "unidentified_description": "A closed pale bud.", "show_kind": true}');
select public.dm_give_item(:'herb', array[:'r1', :'r2']::uuid[], 2, false);

-- ---- roles and validation ---------------------------------------------------------------------------------------------------
select tl_test.as_user(:'alice');
select tl_test.ir_code(format('select public.dm_set_item_knowledge(%L, array[%L]::uuid[], ''{all}'')', :'herb', :'r1')) as c_alice \gset
select tl_test.ir_code(format('select public.get_item_knowledge_overview(%L, %L)', :'herb', :'camp')) as c_alice_ov \gset
select tl_test.ir_code(format('select public.get_campaign_knowledge_items(%L)', :'camp')) as c_alice_list \gset
select tl_test.ir_code('select 1 from public.item_knowledge_events') as c_alice_tab \gset
select tl_test.as_user(:'bob');
select tl_test.ir_code(format('select public.dm_set_item_knowledge(%L, array[%L]::uuid[], ''{all}'')', :'herb', :'r2')) as c_bob \gset
select tl_test.as_user(:'eve');
select tl_test.ir_code(format('select public.dm_set_item_knowledge(%L, array[%L]::uuid[], ''{all}'', ''set'', %L)', :'herb', :'r1', :'camp')) as c_eve \gset
select tl_test.ir_code(format('select public.get_item_knowledge_overview(%L, %L)', :'herb', :'camp')) as c_eve_ov \gset
select tl_test.as_root();
select set_config('role', 'anon', true), set_config('request.jwt.claim.sub', '', true);
select tl_test.ir_code(format('select public.dm_set_item_knowledge(%L, array[%L]::uuid[], ''{all}'')', :'herb', :'r1')) as c_anon \gset
select tl_test.ir_code(format('select public.get_campaign_knowledge_items(%L)', :'camp')) as c_anon_list \gset
select tl_test.as_root();
select tl_test.rec('IR1 refusals: player A, player B, an outsider and anon cannot set, read who knows what, list items or read the history (42501)',
  :'c_alice' = '42501' and :'c_alice_ov' = '42501' and :'c_alice_list' = '42501' and :'c_alice_tab' = '42501' and :'c_bob' = '42501'
  and :'c_eve' = '42501' and :'c_eve_ov' = '42501' and :'c_anon' = '42501' and :'c_anon_list' = '42501'
  and tl_test.ir_ck(:'r1', :'herb') = 'unidentified:',
  concat_ws(',', :'c_alice', :'c_alice_ov', :'c_alice_list', :'c_alice_tab', :'c_bob', :'c_eve', :'c_eve_ov', :'c_anon', :'c_anon_list'));
select tl_test.as_user(:'dm');
select tl_test.rec('IR2 validation: no characters, a character of another campaign, unknown mode, no reveal list, an official item hidden (22023); unknown item (P0002)',
  tl_test.ir_code(format('select public.dm_set_item_knowledge(%L, ''{}''::uuid[], ''{all}'')', :'herb')) = '22023'
  and tl_test.ir_code(format('select public.dm_set_item_knowledge(%L, array[%L]::uuid[], ''{all}'')', :'herb', gen_random_uuid())) = '22023'
  and tl_test.ir_code(format('select public.dm_set_item_knowledge(%L, array[%L]::uuid[], ''{all}'', ''lower'')', :'herb', :'r1')) = '22023'
  and tl_test.ir_code(format('select public.dm_set_item_knowledge(%L, array[%L]::uuid[], null)', :'herb', :'r1')) = '22023'
  and tl_test.ir_code(format('select public.dm_set_item_knowledge(''candle'', array[%L]::uuid[], ''{}'', ''set'', %L)', :'r1', :'camp')) = '22023'
  and tl_test.ir_code(format('select public.dm_set_item_knowledge(''no-such-item'', array[%L]::uuid[], ''{all}'')', :'r1')) = 'P0002');

-- ---- REQUIRED: reveal to A only; B still sees only the decoy -----------------------------------------------------------------
select tl_test.as_user(:'bob');
select tl_test.ir_seen(:'r2') as b_before \gset
select public.get_campaign_audit(:'camp')::text as b_audit0 \gset
select tl_test.as_root();
-- one transaction: forget the per-transaction "already touched" markers of the give above, as a new request would
select set_config('tl_rev.r' || md5(c::text || 'inventory_items' || txid_current()::text), '', true) from unnest(array[:'r1', :'r2']::uuid[]) c;
select tl_test.ir_revs(:'r2') as b_revs0 \gset
select tl_test.ir_revs(:'r1') as a_revs0 \gset
select tl_test.as_user(:'dm');
select public.dm_set_item_knowledge(:'herb', array[:'r1']::uuid[], '{all}', 'set') as s1 \gset
select tl_test.as_user(:'alice');
select (select to_jsonb(d) from public.v_inventory_detail d where d.character_id = :'r1' and d.item_id = :'herb') as a_row \gset
select tl_test.rec('IR3 A (revealed): the view row shows the true name, description, item id and "identified"; the catalog row opens; the sheet got a revision',
  :'a_row'::jsonb ->> 'name' = 'Starbloom' and :'a_row'::jsonb ->> 'description' = 'Glows under moonlight.' and :'a_row'::jsonb ->> 'knowledge_state' = 'identified'
  and exists (select 1 from public.items where id = :'herb') and (:'s1'::jsonb ->> 'changed')::int = 1, :'s1');
select tl_test.as_user(:'bob');
select tl_test.ir_seen(:'r2') as b_after \gset
select (select to_jsonb(d) from public.v_inventory_detail d where d.character_id = :'r2' and d.name = 'Pale bud') as b_row \gset
select public.get_campaign_audit(:'camp')::text as b_audit1 \gset
select tl_test.as_root();
select tl_test.rec('IR4 REQUIRED B (not revealed): view row, catalog, knowledge read and audit are byte-identical to before and carry no truth; B got no revision',
  :'b_before' = :'b_after' and tl_test.ir_clean(:'b_after') and :'b_row'::jsonb ->> 'item_id' is null and :'b_row'::jsonb ->> 'knowledge_state' = 'unidentified'
  and :'b_audit0' = :'b_audit1' and tl_test.ir_clean(:'b_audit1') and tl_test.ir_revs(:'r2') = :b_revs0 and tl_test.ir_revs(:'r1') > :a_revs0
  and tl_test.ir_rowk(:'r2', :'herb') = 'unidentified:',
  concat_ws(' ', :'b_before' = :'b_after', tl_test.ir_clean(:'b_after'), :'b_audit0' = :'b_audit1', tl_test.ir_clean(:'b_audit1'), tl_test.ir_revs(:'r2') = :b_revs0,
            tl_test.ir_revs(:'r1') > :a_revs0, tl_test.ir_rowk(:'r2', :'herb')));

-- ---- partial levels ---------------------------------------------------------------------------------------------------------
select tl_test.as_user(:'dm');
select public.dm_set_item_knowledge(:'herb', array[:'r2']::uuid[], '{name}', 'set');
select tl_test.as_user(:'bob');
select (select to_jsonb(d) from public.v_inventory_detail d where d.character_id = :'r2' and d.item_id is null) as b_row2 \gset
select tl_test.rec('IR5 "name only" for B: true name, decoy description, still masked (no item id, no catalog row), record = row knowledge',
  :'b_row2'::jsonb ->> 'name' = 'Starbloom' and :'b_row2'::jsonb ->> 'description' = 'A closed pale bud.' and :'b_row2'::jsonb ->> 'knowledge_state' = 'partially_identified'
  and not exists (select 1 from public.items where id = :'herb') and tl_test.ir_ck(:'r2', :'herb') = 'partially_identified:name'
  and tl_test.ir_rowk(:'r2', :'herb') = 'partially_identified:name', :'b_row2');
select tl_test.as_user(:'dm');
select public.dm_set_item_knowledge(:'herb', array[:'r2']::uuid[], array['description', 'name'], 'set');
select tl_test.as_user(:'bob');
select (select to_jsonb(d) from public.v_inventory_detail d where d.character_id = :'r2' and d.item_id is null) as b_row3 \gset
select tl_test.rec('IR6 "name + description" for B: both true, still masked; record and rows agree',
  :'b_row3'::jsonb ->> 'name' = 'Starbloom' and :'b_row3'::jsonb ->> 'description' = 'Glows under moonlight.'
  and not exists (select 1 from public.items where id = :'herb') and tl_test.ir_ck(:'r2', :'herb') = 'partially_identified:description,name', :'b_row3');

-- ---- idempotency, raise never lowers, whole party, undo ----------------------------------------------------------------------
select tl_test.as_root();
select tl_test.ir_events(:'herb') as ev0 \gset
select tl_test.ir_revs(:'r2') as rv0 \gset
select tl_test.ir_audits(:'r2') as au0 \gset
select tl_test.as_user(:'dm');
select public.dm_set_item_knowledge(:'herb', array[:'r2']::uuid[], array['name', 'description'], 'set') as s_same \gset
select public.dm_set_item_knowledge(:'herb', array[:'r2']::uuid[], '{name}', 'raise') as s_raise_low \gset
select tl_test.as_root();
select tl_test.rec('IR7 idempotent / never lowering: the same level again and a lower "raise" change nothing (no history, revision or audit row)',
  (:'s_same'::jsonb ->> 'changed')::int = 0 and (:'s_raise_low'::jsonb ->> 'changed')::int = 0 and tl_test.ir_events(:'herb') = :ev0
  and tl_test.ir_revs(:'r2') = :rv0 and tl_test.ir_audits(:'r2') = :au0 and tl_test.ir_ck(:'r2', :'herb') = 'partially_identified:description,name');
select tl_test.as_user(:'dm');
select public.dm_set_item_knowledge(:'herb', array[:'r1', :'r2', :'r3']::uuid[], '{all}', 'raise', :'camp') as s_party \gset
select tl_test.as_root();
select tl_test.rec('IR8 whole party (raise, all): B and A2 become identified, A (already identified) is unchanged',
  (:'s_party'::jsonb ->> 'changed')::int = 2 and split_part(tl_test.ir_ck(:'r2', :'herb'), ':', 1) = 'identified' and tl_test.ir_ck(:'r3', :'herb') = 'identified:'
  and split_part(tl_test.ir_rowk(:'r2', :'herb'), ':', 1) = 'identified', :'s_party');
select tl_test.as_user(:'dm');
select public.dm_set_item_knowledge(:'herb', array[:'r1']::uuid[], '{}', 'set') as s_undo \gset
select tl_test.as_user(:'alice');
select (select to_jsonb(d) from public.v_inventory_detail d where d.character_id = :'r1' and d.name = 'Pale bud') as a_row2 \gset
select (select count(*) from public.items where id = :'herb') as a_cat \gset
select tl_test.as_user(:'bob');
select (select to_jsonb(d) from public.v_inventory_detail d where d.character_id = :'r2' and d.item_id = :'herb') as b_row4 \gset
select tl_test.as_root();
select tl_test.rec('IR9 undo for A only (selected character): A is back to the decoy (masked, record + rows unidentified); B stays identified',
  :'a_row2'::jsonb ->> 'item_id' is null and :'a_row2'::jsonb ->> 'description' = 'A closed pale bud.' and :'a_row2'::jsonb ->> 'knowledge_state' = 'unidentified'
  and tl_test.ir_ck(:'r1', :'herb') = 'unidentified:' and tl_test.ir_rowk(:'r1', :'herb') = 'unidentified:'
  and :'b_row4'::jsonb ->> 'name' = 'Starbloom' and (:'s_undo'::jsonb ->> 'changed')::int = 1, :'a_row2');
-- alice's other character A2 holds nothing but its record says identified: the catalog row stays closed (no readable row)
select tl_test.rec('IR10 per user: A2''s record alone does not open the catalog row to alice', :a_cat = 0);

-- ---- m6: hide an item a character holds undisguised -------------------------------------------------------------------------
select tl_test.as_user(:'dm');
select public.create_homebrew_item(gen_random_uuid(), jsonb_build_object('name', 'Ironleaf', 'kind_id', 'herbs_plants', 'category_id', 'plant-flower',
  'campaign_id', :'camp', 'stackable', true, 'description', 'Hard as iron.')) ->> 'id' as iron \gset
select public.dm_give_item(:'iron', array[:'r1']::uuid[], 1, true);
select public.get_item_knowledge_overview(:'iron', :'camp') as ov0 \gset
select (select x from jsonb_array_elements(:'ov0'::jsonb -> 'characters') x where x ->> 'character_id' = :'r1') as ov0a \gset
select (select x from jsonb_array_elements(:'ov0'::jsonb -> 'characters') x where x ->> 'character_id' = :'r2') as ov0b \gset
select tl_test.rec('IR11 who knows what: an undisguised copy counts as known (source undisguised_copy); a non-holder of a non-secret item sees it (not_hidden)',
  :'ov0a'::jsonb -> 'effective' ->> 'state' = 'identified' and :'ov0a'::jsonb -> 'effective' ->> 'source' = 'undisguised_copy' and (:'ov0a'::jsonb ->> 'plain_rows')::int = 1
  and :'ov0b'::jsonb -> 'effective' ->> 'source' = 'not_hidden' and jsonb_array_length(:'ov0'::jsonb -> 'characters') = 3, :'ov0a');
select public.dm_set_item_knowledge(:'iron', array[:'r1']::uuid[], '{}', 'set') as s_hide \gset
select tl_test.as_user(:'alice');
select (select to_jsonb(d) from public.v_inventory_detail d where d.character_id = :'r1' and d.item_id is null and d.name like 'Unidentified%') as a_iron \gset
select (select count(*) from public.items where id = :'iron') as a_iron_cat \gset
select tl_test.as_root();
select tl_test.rec('IR12 m6: the DM hides an undisguised held item: the row gets knowledge, shows the default decoy, is masked; the item is secret; catalog closed',
  :'a_iron'::jsonb is not null and :'a_iron'::jsonb ->> 'knowledge_state' = 'unidentified' and position('Hard as iron' in :'a_iron') = 0
  and position('Ironleaf' in :'a_iron') = 0 and :a_iron_cat = 0 and (select secret from public.items where id = :'iron')
  and tl_test.ir_rowk(:'r1', :'iron') = 'unidentified:' and tl_test.ir_ck(:'r1', :'iron') = 'unidentified:', coalesce(:'a_iron', 'null'));

-- ---- the DM's reads and the history ------------------------------------------------------------------------------------------
select tl_test.as_user(:'dm');
select public.get_item_knowledge_overview(:'herb', :'camp') as ov \gset
select public.get_campaign_knowledge_items(:'camp') as lst \gset
select tl_test.rec('IR13 who knows what (herb): A unidentified (rows), B identified, A2 identified by record only; history newest first with actor names; picker lists both items',
  (select x -> 'effective' ->> 'state' from jsonb_array_elements(:'ov'::jsonb -> 'characters') x where x ->> 'character_id' = :'r1') = 'unidentified'
  and (select x -> 'effective' ->> 'state' from jsonb_array_elements(:'ov'::jsonb -> 'characters') x where x ->> 'character_id' = :'r2') = 'identified'
  and (select x -> 'effective' ->> 'source' from jsonb_array_elements(:'ov'::jsonb -> 'characters') x where x ->> 'character_id' = :'r3') = 'record'
  and not (select (x ->> 'diverges')::boolean from jsonb_array_elements(:'ov'::jsonb -> 'characters') x where x ->> 'character_id' = :'r1')
  and jsonb_array_length(:'ov'::jsonb -> 'history') >= 5 and :'ov'::jsonb -> 'history' -> 0 ->> 'new_state' = 'unidentified'
  and :'ov'::jsonb -> 'item' ->> 'decoy_name' = 'Pale bud'
  and (select count(*) from jsonb_array_elements(:'lst'::jsonb) x where x ->> 'id' in (:'herb', :'iron')) = 2, left(:'ov', 400));
select tl_test.as_root();
select tl_test.rec('IR14 history: append-only rows with old -> new and the DM as actor; DM-only table (no grants), character cache trigger (coverage rule), not in Realtime',
  exists (select 1 from public.item_knowledge_events where item_id = :'herb' and character_id = :'r1' and old_state = 'identified' and new_state = 'unidentified' and actor = :'dm')
  and not has_table_privilege('authenticated', 'public.item_knowledge_events', 'select') and not has_table_privilege('anon', 'public.item_knowledge_events', 'select')
  and (select tgfoid = 'tl_cache.bump()'::regprocedure and encode(tgargs, 'escape') = 'character\000' from pg_trigger where tgrelid = 'public.item_knowledge_events'::regclass and tgname = 'tl_cache_rev')
  and not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename in ('item_knowledge_events', 'character_item_knowledge')));

-- ---- a player-created homebrew item: hidden, with a warning ------------------------------------------------------------------
select tl_test.as_user(:'dm');
select public.create_homebrew_item(gen_random_uuid(), jsonb_build_object('name', 'Alice Charm', 'kind_id', 'gear', 'campaign_id', :'camp')) ->> 'id' as charm \gset
select tl_test.as_root();
update public.items set owner_id = :'alice' where id = :'charm';   -- as if alice had created it (the campaign rules allowed it)
select tl_test.as_user(:'alice');
select tl_test.give(:'r1', :'charm') as charm_row \gset
select tl_test.as_user(:'dm');
select public.dm_set_item_knowledge(:'charm', array[:'r1']::uuid[], '{}', 'set') as s_charm \gset
select tl_test.rec('IR15 hiding a player-created item works but warns that its creator can still look it up',
  :'s_charm'::jsonb -> 'results' -> 0 ->> 'warning' is not null and tl_test.ir_rowk(:'r1', :'charm') = 'unidentified:', :'s_charm');

-- ---- backfill on a synthetic row-knowledge fixture: every character's visible state is identical ---------------------------
select tl_test.as_user(:'dm');
select public.create_homebrew_item(gen_random_uuid(), jsonb_build_object('name', 'Old Relic', 'kind_id', 'gear', 'campaign_id', :'camp', 'description', 'Relic truth.')) ->> 'id' as relic \gset
select public.create_homebrew_item(gen_random_uuid(), jsonb_build_object('name', 'Odd Relic', 'kind_id', 'gear', 'campaign_id', :'camp', 'description', 'Odd truth.')) ->> 'id' as odd \gset
select tl_test.as_root();
-- rows with row knowledge only (no records), as the pre-T4 code left them: r3 consistent, r2 conflicting (two states)
insert into public.inventory_items (inventory_id, item_id, quantity, name, description) values
  (tl_test.inv(:'r3'), :'relic', 1, 'Dusty thing', 'decoy'), (tl_test.inv(:'r2'), :'odd', 1, 'Odd Relic', 'Odd truth.'), (tl_test.inv(:'r2'), :'odd', 1, 'Strange thing', 'decoy');
insert into public.inventory_item_knowledge (inventory_item_id, state, revealed, true_name)
select ii.id, case when ii.name = 'Odd Relic' then 'identified' else 'unidentified' end, '{}', it.name
from public.inventory_items ii join public.items it on it.id = ii.item_id where ii.item_id in (:'relic', :'odd');
update public.items set secret = true where id in (:'relic', :'odd');
select tl_test.as_user(:'alice');
select tl_test.ir_seen(:'r3') as fx_a3 \gset
select tl_test.ir_seen(:'r1') as fx_a1 \gset
select tl_test.as_user(:'bob');
select tl_test.ir_seen(:'r2') as fx_b2 \gset
select tl_test.as_root();
select public._item_knowledge_backfill() as bf1 \gset
select public._item_knowledge_backfill() as bf2 \gset
select tl_test.as_user(:'alice');
select tl_test.ir_seen(:'r3') = :'fx_a3' and tl_test.ir_seen(:'r1') = :'fx_a1' as same_a \gset
select tl_test.as_user(:'bob');
select tl_test.ir_seen(:'r2') = :'fx_b2' as same_b \gset
select tl_test.as_root();
select tl_test.rec('IR16 backfill: the consistent pair gets its record, the conflicting one none; a second run copies nothing; every character sees exactly the same',
  :bf1 >= 1 and :bf2 = 0 and tl_test.ir_ck(:'r3', :'relic') = 'unidentified:' and tl_test.ir_ck(:'r2', :'odd') is null and :'same_a' and :'same_b'
  and (select count(*) from public.inventory_item_knowledge k join public.inventory_items ii on ii.id = k.inventory_item_id where ii.item_id in (:'relic', :'odd')) = 3,
  :bf1 || '/' || :bf2);

-- ---- review round 2 ------------------------------------------------------------------------------------------------------------
-- B1: another user's PERSONAL homebrew (no campaign) is out of reach of the DM functions unless a copy is held in the campaign
\set rx f4b00000-0000-0000-0000-000000000004
insert into public.characters (id, owner_id, name, campaign_id, level, strength, dexterity, constitution, intelligence, wisdom, charisma, hp_max, hp_current, speed) values
  (:'rx', :'bob', 'Reveal B elsewhere', null, 1, 10, 12, 12, 10, 14, 10, 10, 10, 30);
select 'hb-' || gen_random_uuid() as priv \gset
insert into public.items (id, name, kind_id, owner_id, description) values (:'priv', 'Bobs Private Blade', 'gear', :'bob', 'Private truth.');
insert into public.item_secrets (item_id, properties) values (:'priv', '[{"key": "edge", "label": "Private edge"}]');
select tl_test.as_user(:'bob');
select tl_test.give(:'rx', :'priv') as priv_row \gset
select tl_test.as_root();
-- a record of a campaign character alone (e.g. it once held the item) does not open it either
insert into public.character_item_knowledge (character_id, item_id, state, revealed) values (:'r1', :'priv', 'unidentified', '{}');
select tl_test.ir_events(:'priv') as pv_ev0 \gset
select tl_test.as_user(:'dm');
select tl_test.ir_code(format('select public.get_item_knowledge_overview(%L, %L)', :'priv', :'camp')) as pv_ov \gset
select tl_test.ir_code(format('select public.dm_set_item_knowledge(%L, array[%L]::uuid[], ''{name}'', ''raise'', %L)', :'priv', :'r1', :'camp')) as pv_raise \gset
select tl_test.ir_code(format('select public.dm_set_item_knowledge(%L, array[%L]::uuid[], ''{}'', ''set'', %L)', :'priv', :'r1', :'camp')) as pv_set \gset
select tl_test.ir_code(format('select public.get_item_knowledge_overview(''no-such-item'', %L)', :'camp')) as pv_none \gset
select public.get_campaign_knowledge_items(:'camp')::text as pv_list \gset
select tl_test.as_root();
select tl_test.rec('IR17a B1 another user''s personal item not held in the campaign: overview, raise and set answer P0002 like an unknown id; the picker omits it; nothing written',
  :'pv_ov' = 'P0002' and :'pv_raise' = 'P0002' and :'pv_set' = 'P0002' and :'pv_none' = 'P0002' and position(:'priv' in :'pv_list') = 0
  and position('Bobs Private' in :'pv_list') = 0 and tl_test.ir_events(:'priv') = :pv_ev0 and tl_test.ir_ck(:'r1', :'priv') = 'unidentified:',
  concat_ws(',', :'pv_ov', :'pv_raise', :'pv_set', :'pv_none'));
-- bob brings it into the campaign (his character r2 holds a copy): now the DM of the campaign may manage it here
select tl_test.as_user(:'bob');
select tl_test.give(:'r2', :'priv') as priv_row2 \gset
select tl_test.as_user(:'dm');
select tl_test.ir_code(format('select public.get_item_knowledge_overview(%L, %L)', :'priv', :'camp')) as pv_ov2 \gset
select public.dm_set_item_knowledge(:'priv', array[:'r1']::uuid[], '{name}', 'raise', :'camp') as pv_raise2 \gset
select public.get_campaign_knowledge_items(:'camp')::text as pv_list2 \gset
select tl_test.as_root();
select tl_test.rec('IR17b B1 held in the campaign: overview allowed, the raise works, the picker lists it',
  :'pv_ov2' = 'ok' and (:'pv_raise2'::jsonb ->> 'changed')::int = 1 and tl_test.ir_ck(:'r1', :'priv') = 'partially_identified:name'
  and position(:'priv' in :'pv_list2') > 0, :'pv_raise2');

-- M2: "raise" on a character holding only an undisguised copy writes nothing; a mixed holder (plain + disguised) is raised
select tl_test.as_user(:'dm');
select public.create_homebrew_item(gen_random_uuid(), jsonb_build_object('name', 'Clearleaf', 'kind_id', 'herbs_plants', 'category_id', 'plant-flower',
  'campaign_id', :'camp', 'stackable', true, 'description', 'Clear truth.')) ->> 'id' as clear \gset
select public.dm_give_item(:'clear', array[:'r2']::uuid[], 1, true);
select tl_test.as_root();
select set_config('tl_rev.r' || md5(:'r2' || 'inventory_items' || txid_current()::text), '', true);
select tl_test.ir_revs(:'r2') as m2_rv0 \gset
select tl_test.ir_audits(:'r2') as m2_au0 \gset
select tl_test.ir_events(:'clear') as m2_ev0 \gset
select tl_test.as_user(:'dm');
select public.dm_set_item_knowledge(:'clear', array[:'r2']::uuid[], '{name}', 'raise') as m2_rz \gset
select public.dm_set_item_knowledge(:'clear', array[:'r2']::uuid[], '{all}', 'raise') as m2_rz_all \gset
select public.get_item_knowledge_overview(:'clear', :'camp') as m2_ov \gset
select tl_test.as_root();
select tl_test.rec('IR18a M2 raise on a holder of an undisguised copy: unchanged and skipped; no record, history, audit or revision; overview: holds an undisguised copy',
  (:'m2_rz'::jsonb ->> 'changed')::int = 0 and (:'m2_rz_all'::jsonb ->> 'changed')::int = 0
  and :'m2_rz'::jsonb -> 'results' -> 0 ->> 'skipped' = 'holds an undisguised copy' and tl_test.ir_ck(:'r2', :'clear') is null
  and tl_test.ir_events(:'clear') = :m2_ev0 and tl_test.ir_audits(:'r2') = :m2_au0 and tl_test.ir_revs(:'r2') = :m2_rv0
  and tl_test.ir_rowk(:'r2', :'clear') = '-:'
  and (select x -> 'effective' ->> 'source' from jsonb_array_elements(:'m2_ov'::jsonb -> 'characters') x where x ->> 'character_id' = :'r2') = 'undisguised_copy',
  :'m2_rz');
select tl_test.as_user(:'dm');
select public.set_item_identify_options(:'clear', '{"unidentified_name": "Murky leaf"}');
select public.dm_give_item(:'clear', array[:'r2']::uuid[], 1, false);
select public.dm_set_item_knowledge(:'clear', array[:'r2']::uuid[], '{all}', 'raise') as m2_mixed \gset
select tl_test.as_root();
select tl_test.rec('IR18b M2 a mixed holder (undisguised + disguised copy) is still raised: the disguised copy becomes identified',
  (:'m2_mixed'::jsonb ->> 'changed')::int = 1 and position('unidentified' in tl_test.ir_rowk(:'r2', :'clear')) = 0
  and split_part(tl_test.ir_ck(:'r2', :'clear'), ':', 1) = 'identified', tl_test.ir_rowk(:'r2', :'clear') || ' ' || :'m2_mixed');

-- M1: the rows and the record are locked NOWAIT; a busy lock answers with the DM-facing message. The harness is one session,
-- so the handler path is asserted on the function text here (the two-session check is in the round 2 report).
select tl_test.rec('IR19 M1 dm_set_item_knowledge locks rows and record NOWAIT and maps lock_not_available to a P0001 message',
  (select (length(d) - length(replace(d, 'nowait', ''))) / 6 = 2 and position('when lock_not_available' in d) > 0
          and position('The player is examining this item right now' in d) > 0
   from (select pg_get_functiondef('public.dm_set_item_knowledge(text, uuid[], text[], text, uuid)'::regprocedure) as d) f));

-- derived stats: hiding equipped armour a player could see takes it out of THEIR numbers (the DM's view keeps it)
\set rd f4b00000-0000-0000-0000-000000000005
insert into public.characters (id, owner_id, name, campaign_id, level, strength, dexterity, constitution, intelligence, wisdom, charisma, hp_max, hp_current, speed) values
  (:'rd', :'alice', 'Reveal Armoured', :'camp', 1, 16, 12, 12, 10, 14, 10, 10, 10, 30);
select 'hb-' || gen_random_uuid() as plate \gset
insert into public.items (id, name, kind_id, category_id, base_item_id, owner_id, campaign_id, is_magic, rarity_id, description)
values (:'plate', 'Moon Plate', 'armor', 'heavy-armor', 'plate', :'dm', :'camp', true, 'rare', 'Shines.');
select tl_test.as_user(:'alice');
select tl_test.give(:'rd', :'plate', 'armor') as plate_row \gset
select (public.get_character_derived_stats(:'rd') -> 'armor_class' ->> 'value')::int as ac0 \gset
select tl_test.as_user(:'dm');
select public.dm_set_item_knowledge(:'plate', array[:'rd']::uuid[], '{}', 'set');
select public.get_item_knowledge_overview(:'plate', :'camp') as pl_ov \gset
select (public.get_character_derived_stats(:'rd') -> 'armor_class' ->> 'value')::int as ac_dm \gset
select tl_test.as_user(:'alice');
select (public.get_character_derived_stats(:'rd') -> 'armor_class' ->> 'value')::int as ac1 \gset
select public.get_character_derived_stats(:'rd') -> 'armor_class' ->> 'base_formula' as ac1_formula \gset
select tl_test.as_root();
select tl_test.rec('IR20 hiding equipped armour: still equipped, but the player''s AC falls back to unarmoured (18 -> 11); the DM still reads 18; the overview reports equipped_rows',
  :ac0 = 18 and :ac1 = 11 and :'ac1_formula' = 'unarmored' and :ac_dm = 18
  and exists (select 1 from public.character_equipment where inventory_item_id = :'plate_row')
  and (select (x ->> 'equipped_rows')::int from jsonb_array_elements(:'pl_ov'::jsonb -> 'characters') x where x ->> 'character_id' = :'rd') = 1,
  :ac0 || ' -> ' || :ac1 || ' (DM ' || :ac_dm || ')');

-- M5: the Hidden tab's count
select tl_test.as_user(:'dm');
select public.create_homebrew_item(gen_random_uuid(), jsonb_build_object('name', 'Countroot', 'kind_id', 'herbs_plants', 'category_id', 'plant-flower',
  'campaign_id', :'camp', 'stackable', true, 'description', 'Counted.')) ->> 'id' as cnt \gset
select public.set_item_identify_options(:'cnt', '{"unidentified_name": "Brown root", "identify_dc": 12}');
select public.dm_give_item(:'cnt', array[:'r1']::uuid[], 1, false);
select public.get_campaign_pending_examine_count(:'camp') as pc0 \gset
select tl_test.as_user(:'alice');
select public.examine_inventory_item((tl_test.ir_row(:'r1', :'cnt')).id, 'nature', 9, gen_random_uuid());
select tl_test.ir_code(format('select public.get_campaign_pending_examine_count(%L)', :'camp')) as pc_alice \gset
select tl_test.as_user(:'dm');
select public.get_campaign_pending_examine_count(:'camp') as pc1 \gset
select jsonb_array_length(public.get_campaign_identify_attempts(:'camp', 'pending')) as pc_list \gset
select tl_test.as_root();
select tl_test.rec('IR21 M5 the pending examine count: +1 after an examine, equals the pending list, DM-only (42501 for a player)',
  :pc1 = :pc0 + 1 and :pc1 = :pc_list and :'pc_alice' = '42501', :pc0 || '/' || :pc1 || '/' || :pc_list || ' ' || :'pc_alice');
