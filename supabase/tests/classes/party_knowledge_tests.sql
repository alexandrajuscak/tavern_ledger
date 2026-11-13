-- =============================================================================
-- Party-wide identification (20261114000100; docs/HIDDEN_DM_DATA.md "Identification is shared with the party"): the campaign
-- rule (default on, DM-only read / switch), sharing on a successful examine answered by the DM, on a DM raise and on the old
-- per-copy editor; a DM "set" holds a character back and survives later sharing; release; a FAILED examine stays private; joiners
-- (new character, moved character) inherit; rule off = the per-character model; switching it on catches up; another campaign and
-- characters without a campaign are untouched; the catch-up is idempotent; and the leak check: a held-back player reads no truth
-- of the item through views, tables, RPCs or the audit after the party learned it.
-- Runs inside the per-class harness (alice = player of :camp, bob / carol = made players here, dm = DM of :camp).
-- =============================================================================
\set pa f5a00000-0000-0000-0000-000000000001
\set pb f5a00000-0000-0000-0000-000000000002
\set pc f5a00000-0000-0000-0000-000000000003
\set pd f5a00000-0000-0000-0000-000000000004
\set pj f5a00000-0000-0000-0000-000000000005
\set pm f5a00000-0000-0000-0000-000000000006
\set pn f5a00000-0000-0000-0000-000000000007
\set carol c7777777-7777-7777-7777-777777777777
\set camp2 c1c00000-0000-0000-0000-000000000002
insert into auth.users (id, email) values (:'carol', 'carol@test');
insert into public.campaigns (id, name, created_by) values (:'camp2', 'Other Campaign', :'dm');
insert into public.campaign_members (campaign_id, user_id, role) values (:'camp', :'bob', 'player'), (:'camp', :'carol', 'player'),
  (:'camp2', :'dm', 'dm'), (:'camp2', :'bob', 'player');
insert into public.characters (id, owner_id, name, campaign_id, level, strength, dexterity, constitution, intelligence, wisdom, charisma, hp_max, hp_current, speed) values
  (:'pa', :'alice', 'Party A', :'camp', 1, 10, 12, 12, 10, 14, 10, 10, 10, 30),
  (:'pb', :'bob', 'Party B', :'camp', 1, 10, 12, 12, 10, 14, 10, 10, 10, 30),
  (:'pc', :'carol', 'Party C', :'camp', 1, 10, 12, 12, 10, 14, 10, 10, 10, 30),
  (:'pd', :'bob', 'Other D', :'camp2', 1, 10, 12, 12, 10, 14, 10, 10, 10, 30),
  (:'pm', :'bob', 'Mover M', null, 1, 10, 12, 12, 10, 14, 10, 10, 10, 30);
create function tl_test.pk_code(p_sql text) returns text language plpgsql as $$
begin execute p_sql; return 'ok'; exception when others then return sqlstate; end $$;
create function tl_test.pk_ck(p_char uuid, p_item text) returns text language sql security definer as $$
  select state || ':' || array_to_string(revealed, ',') || case when held_by_dm then ':held' else '' end
  from public.character_item_knowledge where character_id = p_char and item_id = p_item $$;
create function tl_test.pk_rowk(p_char uuid, p_item text) returns text language sql security definer as $$
  select string_agg(ii.name || '/' || coalesce(k.state, '-'), ';' order by ii.id)
  from public.inventory_items ii join public.inventories inv on inv.id = ii.inventory_id left join public.inventory_item_knowledge k on k.inventory_item_id = ii.id
  where inv.character_id = p_char and ii.item_id = p_item $$;
create function tl_test.pk_revs(p_char uuid) returns int language sql security definer as $$
  select count(*)::int from public.character_revisions where character_id = p_char $$;
create function tl_test.pk_fresh(p_char uuid) returns void language plpgsql as $$
begin
  perform set_config('tl_rev.r' || md5(p_char::text || 'inventory_items' || txid_current()::text), '', true);
  perform set_config('tl_cache.c' || md5(p_char::text || txid_current()::text), '', true);
end $$;
create function tl_test.pk_attempt(p_char uuid) returns uuid language sql security definer as $$
  select id from public.item_identify_attempts where character_id = p_char order by created_at desc, id limit 1 $$;
create function tl_test.pk_row(p_char uuid, p_item text) returns uuid language sql security definer as $$
  select ii.id from public.inventory_items ii join public.inventories inv on inv.id = ii.inventory_id
  where inv.character_id = p_char and ii.item_id = p_item order by ii.id limit 1 $$;
create function tl_test.pk_event(p_char uuid, p_item text) returns text language sql security definer as $$
  select coalesce(e.source, '-') || ':' || coalesce((select c.name from public.characters c where c.id = e.source_character_id), '-')
  from public.item_knowledge_events e where e.character_id = p_char and e.item_id = p_item order by e.created_at desc, e.id desc limit 1 $$;
-- everything a caller can see of one character's items, plus the campaign audit and the catalog rows
create function tl_test.pk_seen(p_char uuid, p_camp uuid) returns text language sql as $$
  select coalesce((select string_agg(concat_ws('|', d.id, d.name, d.description, d.item_id, d.kind_id, d.rarity_id, d.is_magic, d.knowledge_state), ';' order by d.id)
                   from public.v_inventory_detail d where d.character_id = p_char), '') || '#'
      || coalesce((select string_agg(it.id || '|' || it.name || '|' || coalesce(it.description, ''), ';' order by it.id) from public.items it where it.campaign_id is not null or it.secret), '') || '#'
      || coalesce(public.get_character_item_knowledge(p_char)::text, '') || '#' || coalesce(public.get_campaign_audit(p_camp)::text, '') $$;
create function tl_test.pk_clean(p_text text) returns boolean language sql as $$
  select position('Sunpetal' in coalesce(p_text, '')) = 0 and position('Burns bright' in coalesce(p_text, '')) = 0 $$;
grant all on all functions in schema tl_test to public;

-- ---- setup: two disguised campaign herbs (examine DC 12, DM confirms) given to A, B and C; one in the other campaign ----------
select tl_test.as_user(:'dm');
select public.create_homebrew_item(gen_random_uuid(), jsonb_build_object('name', 'Sunpetal', 'kind_id', 'herbs_plants', 'category_id', 'plant-flower',
  'campaign_id', :'camp', 'stackable', true, 'description', 'Burns bright at noon.')) ->> 'id' as herb \gset
select public.set_item_identify_options(:'herb', '{"unidentified_name": "Yellow petal", "unidentified_description": "A dry petal.", "show_kind": true, "identify_dc": 12}');
select public.create_homebrew_item(gen_random_uuid(), jsonb_build_object('name', 'Grey Moss', 'kind_id', 'herbs_plants', 'category_id', 'plant-flower',
  'campaign_id', :'camp', 'stackable', true, 'description', 'Soft grey moss.')) ->> 'id' as moss \gset
select public.set_item_identify_options(:'moss', '{"unidentified_name": "Damp tuft", "identify_dc": 15}');
select public.create_homebrew_item(gen_random_uuid(), jsonb_build_object('name', 'Ash Root', 'kind_id', 'herbs_plants', 'category_id', 'plant-flower',
  'campaign_id', :'camp', 'stackable', true, 'description', 'Smells of smoke.')) ->> 'id' as root \gset
select public.set_item_identify_options(:'root', '{"unidentified_name": "Dark root", "identify_dc": 10}');
select public.dm_give_item(:'herb', array[:'pa', :'pb', :'pc']::uuid[], 1, false);
select public.dm_give_item(:'moss', array[:'pa', :'pb']::uuid[], 1, false);
select public.dm_give_item(:'root', array[:'pa', :'pb']::uuid[], 1, false);
select public.create_homebrew_item(gen_random_uuid(), jsonb_build_object('name', 'Ghost Cap', 'kind_id', 'herbs_plants', 'category_id', 'plant-flower',
  'campaign_id', :'camp', 'stackable', true, 'description', 'Pale glow in the dark.')) ->> 'id' as cap \gset
select public.set_item_identify_options(:'cap', '{"unidentified_name": "Grey mushroom", "identify_dc": 10}');
select public.dm_give_item(:'cap', array[:'pa', :'pb', :'pc']::uuid[], 1, false);
select public.create_homebrew_item(gen_random_uuid(), jsonb_build_object('name', 'Far Lichen', 'kind_id', 'herbs_plants', 'category_id', 'plant-flower',
  'campaign_id', :'camp2', 'stackable', true, 'description', 'Far away.')) ->> 'id' as far \gset
select public.set_item_identify_options(:'far', '{"unidentified_name": "Odd lichen", "identify_dc": 10}');
select public.dm_give_item(:'far', array[:'pd']::uuid[], 1, false);

-- ---- PK1 the rule: on by default; only the DM reads or switches it; players cannot touch the tables or internal functions ----
select tl_test.as_user(:'alice');
select tl_test.pk_code(format('select public.get_campaign_identification_sharing(%L)', :'camp')) as c_get \gset
select tl_test.pk_code(format('select public.set_campaign_identification_sharing(%L, false)', :'camp')) as c_set \gset
select tl_test.pk_code(format('select public.dm_release_item_knowledge_hold(%L, array[%L]::uuid[])', :'herb', :'pa')) as c_rel \gset
select tl_test.pk_code('select 1 from public.campaign_item_rules') as c_tab \gset
select tl_test.pk_code('select held_by_dm from public.character_item_knowledge') as c_ck \gset
select tl_test.pk_code(format('select public._party_share_sync(%L)', :'camp')) as c_sync \gset
select tl_test.pk_code(format('select public._party_apply_to(%L, %L, ''identified'', ''{}'')', :'pa', :'herb')) as c_apply \gset
select tl_test.as_user(:'dm');
select tl_test.rec('PK1 rule on by default (DM read); a player cannot read / switch it, release a hold, read the rule or record tables or call the share functions (42501)',
  (public.get_campaign_identification_sharing(:'camp') ->> 'share_identification')::boolean
  and :'c_get' = '42501' and :'c_set' = '42501' and :'c_rel' = '42501' and :'c_tab' = '42501' and :'c_ck' = '42501'
  and :'c_sync' = '42501' and :'c_apply' = '42501',
  concat_ws(',', :'c_get', :'c_set', :'c_rel', :'c_tab', :'c_ck', :'c_sync', :'c_apply'));

-- ---- PK2 a FAILED examine stays private -------------------------------------------------------------------------------------
select tl_test.as_user(:'bob');
select tl_test.pk_seen(:'pb', :'camp') as b_seen0 \gset
select tl_test.as_root();
select tl_test.pk_fresh(:'pa'); select tl_test.pk_fresh(:'pb');
select tl_test.pk_revs(:'pa') as a_revs0 \gset
select tl_test.as_user(:'carol');
select public.examine_inventory_item(tl_test.pk_row(:'pc', :'herb'), 'nature', 5) ->> 'status' as c_ex \gset
select tl_test.as_user(:'dm');
select public.resolve_identify_attempt(tl_test.pk_attempt(:'pc'), null) ->> 'status' as c_res \gset
select tl_test.as_user(:'bob');
select tl_test.pk_seen(:'pb', :'camp') as b_seen1 \gset
select tl_test.as_root();
select tl_test.rec('PK2 a failed examine (DM decides by the roll) changes nothing for anyone else: B''s reads byte-identical, A and B no revision, no record raised',
  :'c_ex' = 'pending' and :'c_res' = 'failed' and :'b_seen0' = :'b_seen1' and tl_test.pk_revs(:'pa') = :a_revs0
  and tl_test.pk_ck(:'pa', :'herb') = 'unidentified:' and tl_test.pk_ck(:'pb', :'herb') = 'unidentified:' and tl_test.pk_ck(:'pc', :'herb') = 'unidentified:',
  concat_ws(' ', :'c_ex', :'c_res', :'b_seen0' = :'b_seen1', tl_test.pk_ck(:'pa', :'herb'), tl_test.pk_ck(:'pb', :'herb')));

-- ---- PK3 share on identify: A examines, the DM answers success -> B and C know; their rows follow; history + revision -------
select tl_test.pk_fresh(:'pb'); select tl_test.pk_fresh(:'pc');
select tl_test.pk_revs(:'pb') as b_revs0 \gset
select tl_test.as_user(:'alice');
select public.examine_inventory_item(tl_test.pk_row(:'pa', :'herb'), 'nature', 14) ->> 'status' as a_ex \gset
select tl_test.as_root();
select tl_test.pk_ck(:'pb', :'herb') as b_pending \gset
select tl_test.as_user(:'dm');
select public.resolve_identify_attempt(tl_test.pk_attempt(:'pa'), true) ->> 'status' as a_res \gset
select tl_test.as_user(:'bob');
select (select to_jsonb(d) from public.v_inventory_detail d where d.character_id = :'pb' and d.item_id = :'herb') as b_row \gset
select public.get_campaign_audit(:'camp')::text as b_audit \gset
select tl_test.as_root();
select tl_test.rec('PK3 A''s success (DM confirmed) reaches B and C: records identified, B''s view row shows the truth, B got a revision, history says party_share from A; nothing while it was pending',
  :'a_ex' = 'pending' and :'b_pending' = 'unidentified:' and :'a_res' = 'succeeded'
  and tl_test.pk_ck(:'pb', :'herb') = 'identified:' and tl_test.pk_ck(:'pc', :'herb') = 'identified:'
  and :'b_row'::jsonb ->> 'name' = 'Sunpetal' and :'b_row'::jsonb ->> 'knowledge_state' = 'identified'
  and tl_test.pk_revs(:'pb') > :b_revs0 and tl_test.pk_event(:'pb', :'herb') = 'party_share:Party A' and tl_test.pk_event(:'pa', :'herb') = '-:-',
  concat_ws(' ', :'a_ex', :'b_pending', :'a_res', tl_test.pk_ck(:'pb', :'herb'), tl_test.pk_ck(:'pc', :'herb'), :'b_row', tl_test.pk_event(:'pb', :'herb')));
select tl_test.rec('PK4 B''s own audit line: the item as B now knows it, no actor, never who identified it',
  exists (select 1 from public.campaign_audit_events e where e.character_id = :'pb' and e.visibility = 'party' and e.actor_id is null
          and e.summary = 'Your party learned something about an item: Sunpetal')
  and position('Party A' in :'b_audit') = 0 and position('alice' in :'b_audit') = 0, left(:'b_audit', 400));

-- ---- PK5 share on a DM raise (partial) and on the old per-copy editor; set_item_knowledge lowering holds ---------------------
select tl_test.as_user(:'dm');
select public.dm_set_item_knowledge(:'moss', array[:'pa']::uuid[], '{name}', 'raise') as r1 \gset
select tl_test.as_root();
select tl_test.rec('PK5 DM "reveal to A" (name only, raise) is shared: B gets the name (row renamed, still masked), C gets a record without a copy; the result reports shared_with',
  tl_test.pk_ck(:'pb', :'moss') = 'partially_identified:name' and tl_test.pk_rowk(:'pb', :'moss') = 'Grey Moss/partially_identified'
  and tl_test.pk_ck(:'pc', :'moss') = 'partially_identified:name' and (:'r1'::jsonb ->> 'shared_with')::int = 2 and (:'r1'::jsonb ->> 'party_share')::boolean,
  concat_ws(' ', tl_test.pk_ck(:'pb', :'moss'), tl_test.pk_rowk(:'pb', :'moss'), :'r1'));
select tl_test.as_user(:'dm');
select public.set_item_knowledge(tl_test.pk_row(:'pa', :'root'), 'identified');
select tl_test.as_root();
select tl_test.pk_ck(:'pb', :'root') as b_root1 \gset
select tl_test.as_user(:'dm');
select public.set_item_knowledge(tl_test.pk_row(:'pb', :'root'), 'unidentified', '{}');
select tl_test.as_root();
select tl_test.rec('PK6 old per-copy editor: identifying A''s copy is shared (B identified); lowering B''s copy holds B back',
  :'b_root1' = 'identified:' and tl_test.pk_ck(:'pb', :'root') = 'unidentified::held' and tl_test.pk_rowk(:'pb', :'root') = 'Dark root/unidentified',
  concat_ws(' ', :'b_root1', tl_test.pk_ck(:'pb', :'root'), tl_test.pk_rowk(:'pb', :'root')));

-- ---- PK7 DM "set" holds back and survives later sharing; release ------------------------------------------------------------
select tl_test.as_user(:'dm');
select public.dm_set_item_knowledge(:'cap', array[:'pc']::uuid[], '{}', 'set') as s_c \gset
select public.dm_set_item_knowledge(:'cap', array[:'pa']::uuid[], '{all}', 'raise') as r2 \gset
select tl_test.as_root();
select tl_test.rec('PK7 the DM hides the cap from C first (set, no visible change): C held; A then identified (raise) -> B identified, C stays hidden',
  tl_test.pk_ck(:'pc', :'cap') = 'unidentified::held' and tl_test.pk_ck(:'pb', :'cap') = 'identified:'
  and (:'s_c'::jsonb -> 'results' -> 0 ->> 'held')::boolean and (:'r2'::jsonb ->> 'shared_with')::int = 1,
  concat_ws(' ', tl_test.pk_ck(:'pc', :'cap'), tl_test.pk_ck(:'pb', :'cap'), :'s_c', :'r2'));

-- ---- PK8 REQUIRED leak check: held-back C (as carol) reads no truth of the cap, also with a second copy given now -----------
select tl_test.as_user(:'dm');
select public.dm_give_item(:'cap', array[:'pc']::uuid[], 1, false);
select tl_test.as_user(:'carol');
select tl_test.pk_seen(:'pc', :'camp') as c_seen \gset
select tl_test.pk_code('select 1 from public.item_knowledge_events') as c_ev \gset
select tl_test.pk_code(format('select public.get_item_knowledge_overview(%L, %L)', :'cap', :'camp')) as c_ov \gset
select (select count(*) from public.items where id = :'cap') as c_cat \gset
select tl_test.as_root();
select tl_test.rec('PK8 REQUIRED held-back C: the new copy arrives disguised; view, catalog, knowledge read and audit carry no "Ghost Cap" / "Pale glow"; history and overview refused',
  position('Ghost Cap' in :'c_seen') = 0 and position('Pale glow' in :'c_seen') = 0 and position('Grey mushroom' in :'c_seen') > 0
  and :'c_ev' = '42501' and :'c_ov' = '42501' and :c_cat = 0 and tl_test.pk_rowk(:'pc', :'cap') like 'Grey mushroom/unidentified%',
  concat_ws(' ', :'c_ev', :'c_ov', :c_cat, tl_test.pk_rowk(:'pc', :'cap'), left(:'c_seen', 300)));
select tl_test.as_user(:'dm');
select public.dm_release_item_knowledge_hold(:'cap', array[:'pc']::uuid[], :'camp') as rel \gset
select (public.get_item_knowledge_overview(:'cap', :'camp') -> 'characters') as ov_chars \gset
select tl_test.as_root();
select tl_test.rec('PK9 release: C gets the party level at once (identified, copies renamed); the overview shows no hold and "from Party A"',
  tl_test.pk_ck(:'pc', :'cap') = 'identified:' and tl_test.pk_rowk(:'pc', :'cap') like 'Ghost Cap/identified%' and (:'rel'::jsonb ->> 'released')::int = 1
  and (select bool_and(not (c ->> 'held')::boolean) from jsonb_array_elements(:'ov_chars'::jsonb) c)
  and (select c -> 'party_source' ->> 'from' from jsonb_array_elements(:'ov_chars'::jsonb) c where c ->> 'name' = 'Party C') = 'Party A',
  concat_ws(' ', tl_test.pk_ck(:'pc', :'cap'), tl_test.pk_rowk(:'pc', :'cap'), :'rel', :'ov_chars'));

-- ---- PK10 joiners: a new character in the campaign and a character moved into it inherit; their later copies arrive known ----
insert into public.characters (id, owner_id, name, campaign_id, level, strength, dexterity, constitution, intelligence, wisdom, charisma, hp_max, hp_current, speed)
values (:'pj', :'carol', 'Joiner J', :'camp', 1, 10, 12, 12, 10, 14, 10, 10, 10, 30);
update public.characters set campaign_id = :'camp' where id = :'pm';
select tl_test.as_user(:'dm');
select public.dm_give_item(:'herb', array[:'pj']::uuid[], 1, false);
select tl_test.as_root();
select tl_test.rec('PK10 joiners inherit the party level (herb and cap identified, moss name only); root: B is held, A identified -> joiner identified; a copy given later arrives identified',
  tl_test.pk_ck(:'pj', :'herb') = 'identified:' and tl_test.pk_ck(:'pm', :'herb') = 'identified:' and tl_test.pk_ck(:'pm', :'cap') = 'identified:'
  and tl_test.pk_ck(:'pm', :'moss') = 'partially_identified:name'
  and tl_test.pk_ck(:'pj', :'root') = 'identified:' and tl_test.pk_rowk(:'pj', :'herb') = 'Sunpetal/-'
  and tl_test.pk_ck(:'pj', :'far') is null and tl_test.pk_event(:'pm', :'herb') = 'party_share:Party A',
  concat_ws(' ', tl_test.pk_ck(:'pj', :'herb'), tl_test.pk_ck(:'pm', :'herb'), tl_test.pk_ck(:'pj', :'root'), tl_test.pk_rowk(:'pj', :'herb'), tl_test.pk_event(:'pm', :'herb')));

-- ---- PK11 another campaign and characters without a campaign are untouched --------------------------------------------------
insert into public.characters (id, owner_id, name, campaign_id, level, strength, dexterity, constitution, intelligence, wisdom, charisma, hp_max, hp_current, speed)
values (:'pn', :'bob', 'Loner N', null, 1, 10, 12, 12, 10, 14, 10, 10, 10, 30);
select tl_test.rec('PK11 the other campaign''s D and a character without a campaign have no record of this campaign''s items; D''s own herb is unchanged',
  tl_test.pk_ck(:'pd', :'herb') is null and tl_test.pk_ck(:'pd', :'moss') is null and tl_test.pk_ck(:'pn', :'herb') is null
  and tl_test.pk_ck(:'pd', :'far') = 'unidentified:' and public._party_share_from(:'pn', :'herb') = 0,
  concat_ws(' ', tl_test.pk_ck(:'pd', :'herb'), tl_test.pk_ck(:'pd', :'far')));

-- ---- PK12 rule off = per character; switching on catches up once; the catch-up is idempotent --------------------------------
select tl_test.as_user(:'dm');
select public.set_campaign_identification_sharing(:'camp', false) as off \gset
select public.create_homebrew_item(gen_random_uuid(), jsonb_build_object('name', 'Blue Fern', 'kind_id', 'herbs_plants', 'category_id', 'plant-flower',
  'campaign_id', :'camp', 'stackable', true, 'description', 'Blue.')) ->> 'id' as fern \gset
select public.set_item_identify_options(:'fern', '{"unidentified_name": "Curled frond", "identify_dc": 10, "identify_auto": true}');
select public.dm_give_item(:'fern', array[:'pa', :'pb']::uuid[], 1, false);
select tl_test.as_user(:'alice');
select public.examine_inventory_item(tl_test.pk_row(:'pa', :'fern'), 'nature', 18) ->> 'status' as fern_ex \gset
select tl_test.as_root();
select tl_test.pk_ck(:'pb', :'fern') as b_fern_off \gset
insert into public.characters (id, owner_id, name, campaign_id, level, strength, dexterity, constitution, intelligence, wisdom, charisma, hp_max, hp_current, speed)
values ('f5a00000-0000-0000-0000-000000000008', :'carol', 'Late K', :'camp', 1, 10, 12, 12, 10, 14, 10, 10, 10, 30);
select coalesce(tl_test.pk_ck('f5a00000-0000-0000-0000-000000000008', :'herb'), 'none') as k_herb_off \gset
select tl_test.as_user(:'dm');
select public.set_campaign_identification_sharing(:'camp', true) as on1 \gset
select tl_test.as_root();
select tl_test.pk_ck(:'pb', :'fern') as b_fern_on \gset
select tl_test.pk_rowk(:'pb', :'fern') as b_fern_row \gset
select md5(string_agg(ck.character_id || ck.item_id || ck.state || array_to_string(ck.revealed, ',') || ck.held_by_dm, ';' order by ck.character_id, ck.item_id)) as fp1
  from public.character_item_knowledge ck \gset
select public._party_share_sync(:'camp') as again \gset
select md5(string_agg(ck.character_id || ck.item_id || ck.state || array_to_string(ck.revealed, ',') || ck.held_by_dm, ';' order by ck.character_id, ck.item_id)) as fp2
  from public.character_item_knowledge ck \gset
select tl_test.rec('PK12 rule off: A''s auto success stays with A (B unidentified), a joiner inherits nothing; switching on catches B and the joiner up (held B on root stays); a second catch-up changes nothing',
  not (:'off'::jsonb ->> 'share_identification')::boolean and :'fern_ex' = 'succeeded' and :'b_fern_off' = 'unidentified:' and :'k_herb_off' = 'none'
  and (:'on1'::jsonb ->> 'caught_up')::int > 0 and :'b_fern_on' = 'identified:' and :'b_fern_row' = 'Blue Fern/identified'
  and tl_test.pk_ck('f5a00000-0000-0000-0000-000000000008', :'herb') = 'identified:' and tl_test.pk_ck(:'pb', :'root') = 'unidentified::held'
  and :again = 0 and :'fp1' = :'fp2',
  concat_ws(' ', :'off', :'fern_ex', :'b_fern_off', :'k_herb_off', :'on1', :'b_fern_on', :again));

-- ---- PK13 the history is DM-only and explains the share --------------------------------------------------------------------
select tl_test.as_user(:'dm');
select public.get_item_knowledge_overview(:'herb', :'camp') as ov \gset
select tl_test.as_root();
select tl_test.rec('PK13 overview: party_share flag, history rows with source party_share and the source character',
  (:'ov'::jsonb ->> 'party_share')::boolean
  and exists (select 1 from jsonb_array_elements(:'ov'::jsonb -> 'history') h where h ->> 'source' = 'party_share' and h ->> 'source_character_name' = 'Party A'),
  left(:'ov', 400));

-- ---- round 2 ------------------------------------------------------------------------------------------------------------------
-- PK14 M1: knowledge never travels between campaigns (official item made secret, learned in camp, character moved to camp2)
select tl_test.as_root();
update public.items set secret = true where id = 'longsword';
select tl_test.as_user(:'dm');
select public.dm_set_item_knowledge('longsword', array[:'pa']::uuid[], '{all}', 'raise', :'camp');
select tl_test.as_root();
update public.characters set campaign_id = :'camp2' where id = :'pa';
insert into public.characters (id, owner_id, name, campaign_id, level, strength, dexterity, constitution, intelligence, wisdom, charisma, hp_max, hp_current, speed)
values ('f5a00000-0000-0000-0000-000000000009', :'bob', 'Joiner Two', :'camp2', 1, 10, 12, 12, 10, 14, 10, 10, 10, 30);
select tl_test.as_user(:'dm');
select public.set_campaign_identification_sharing(:'camp2', false);
select public.set_campaign_identification_sharing(:'camp2', true) as on2 \gset
select public.dm_sync_party_knowledge(:'camp2') as sync2 \gset
select tl_test.as_root();
select coalesce(tl_test.pk_ck('f5a00000-0000-0000-0000-000000000009', 'longsword'), 'none') as j2_ls \gset
select coalesce(tl_test.pk_ck(:'pd', 'longsword'), 'none') as d_ls \gset
select tl_test.rec('PK14 M1 knowledge learned in camp does not travel: after A moves to camp2, a joiner, a rule switch-on and a DM sync in camp2 give nobody the item',
  tl_test.pk_ck(:'pa', 'longsword') = 'identified:' and :'j2_ls' = 'none' and :'d_ls' = 'none'
  and (select count(*) from public._party_levels(:'camp2', null, 'longsword')) = 0,
  concat_ws(' ', :'j2_ls', :'d_ls', :'on2', :'sync2'));
update public.characters set campaign_id = :'camp' where id = :'pa';

-- PK15 pending rows: applied in the target's own context by sync_party_knowledge, re-checked (hold, campaign), never readable
select tl_test.as_user(:'dm');
select public.create_homebrew_item(gen_random_uuid(), jsonb_build_object('name', 'Iron Bark', 'kind_id', 'herbs_plants', 'category_id', 'plant-flower',
  'campaign_id', :'camp', 'stackable', true, 'description', 'Hard as iron.')) ->> 'id' as bark \gset
select public.set_item_identify_options(:'bark', '{"unidentified_name": "Grey bark", "identify_dc": 10}');
select public.dm_give_item(:'bark', array[:'pa', :'pb', :'pc']::uuid[], 1, false);
select public.set_campaign_identification_sharing(:'camp', false);
select public.dm_set_item_knowledge(:'bark', array[:'pa']::uuid[], '{all}', 'raise');
select public.dm_set_item_knowledge(:'bark', array[:'pc']::uuid[], '{}', 'set');
select tl_test.as_root();
-- the rule goes back on without a catch-up (a direct row write), so only the pending rows can bring B up
insert into public.campaign_item_rules (campaign_id, share_identification) values (:'camp', true)
  on conflict (campaign_id) do update set share_identification = true;
insert into public.party_share_pending (campaign_id, target_character_id, item_id, state, revealed, source_character_id) values
  (:'camp', :'pb', :'bark', 'identified', '{}', :'pa'),
  (:'camp', :'pc', :'bark', 'identified', '{}', :'pa'),
  (:'camp2', :'pb', :'herb', 'identified', '{}', :'pa');
select tl_test.as_user(:'carol');
select tl_test.pk_code(format('select public.sync_party_knowledge(%L)', :'pb')) as c_sync_b \gset
select tl_test.pk_code('select 1 from public.party_share_pending') as c_pend \gset
select public.sync_party_knowledge(:'pc') as sync_c \gset
select tl_test.as_user(:'bob');
select public.sync_party_knowledge(:'pb') as sync_b \gset
select public.sync_party_knowledge(:'pb') as sync_b2 \gset
select tl_test.as_root();
select tl_test.rec('PK15 pending shares: B''s row applied by B''s own sync (identified, copy renamed), the other-campaign row and C''s (held) are discarded; another player and the table are refused; a second sync is a no-op',
  :'c_sync_b' = '42501' and :'c_pend' = '42501' and tl_test.pk_ck(:'pb', :'bark') = 'identified:' and tl_test.pk_rowk(:'pb', :'bark') = 'Iron Bark/identified'
  and tl_test.pk_ck(:'pc', :'bark') = 'unidentified::held' and (select count(*) from public.party_share_pending) = 0
  and (:'sync_b2'::jsonb ->> 'applied')::int = 0 and (:'sync_b2'::jsonb ->> 'pending')::int = 0,
  concat_ws(' ', :'c_sync_b', :'c_pend', :'sync_c', :'sync_b', :'sync_b2', tl_test.pk_ck(:'pb', :'bark'), tl_test.pk_ck(:'pc', :'bark')));

-- PK16 a share never lowers a copy: B's copy is identified while B's record knows nothing; a name-only share keeps it identified
select tl_test.as_user(:'dm');
select public.create_homebrew_item(gen_random_uuid(), jsonb_build_object('name', 'Salt Fern', 'kind_id', 'herbs_plants', 'category_id', 'plant-flower',
  'campaign_id', :'camp', 'stackable', true, 'description', 'Salty.')) ->> 'id' as fern2 \gset
select public.set_item_identify_options(:'fern2', '{"unidentified_name": "Pale fern", "identify_dc": 10}');
select public.dm_give_item(:'fern2', array[:'pa', :'pb']::uuid[], 1, false);
select tl_test.as_root();
update public.inventory_item_knowledge k set state = 'identified', revealed = '{}' from public.inventory_items ii join public.inventories inv on inv.id = ii.inventory_id
  where k.inventory_item_id = ii.id and inv.character_id = :'pb' and ii.item_id = :'fern2';
select tl_test.as_user(:'dm');
select public.dm_set_item_knowledge(:'fern2', array[:'pa']::uuid[], '{name}', 'raise');
select tl_test.as_root();
select tl_test.rec('PK16 a share never lowers: B''s diverged identified copy stays identified and B''s record catches up to it',
  tl_test.pk_rowk(:'pb', :'fern2') like '%/identified' and tl_test.pk_ck(:'pb', :'fern2') like 'identified:%',
  concat_ws(' ', tl_test.pk_rowk(:'pb', :'fern2'), tl_test.pk_ck(:'pb', :'fern2')));

-- PK17 m3: B's pending examine is closed as learned from the party (no resolver, not "by the DM")
select tl_test.as_user(:'dm');
select public.create_homebrew_item(gen_random_uuid(), jsonb_build_object('name', 'Ash Lily', 'kind_id', 'herbs_plants', 'category_id', 'plant-flower',
  'campaign_id', :'camp', 'stackable', true, 'description', 'Ashen.')) ->> 'id' as lily \gset
select public.set_item_identify_options(:'lily', '{"unidentified_name": "Grey lily", "identify_dc": 10}');
select public.dm_give_item(:'lily', array[:'pa', :'pb']::uuid[], 1, false);
select tl_test.as_user(:'bob');
select public.examine_inventory_item(tl_test.pk_row(:'pb', :'lily'), 'nature', 15) ->> 'status' as b_lily \gset
select tl_test.as_user(:'dm');
select public.dm_set_item_knowledge(:'lily', array[:'pa']::uuid[], '{all}', 'raise');
select tl_test.as_root();
select tl_test.rec('PK17 m3 B''s pending examine is closed "Learned from the party" with no resolver when A''s knowledge reaches B',
  :'b_lily' = 'pending' and exists (select 1 from public.item_identify_attempts a where a.character_id = :'pb' and a.item_id = :'lily'
    and a.status = 'succeeded' and a.dm_note = 'Learned from the party' and a.resolved_by is null),
  (select string_agg(status || '|' || coalesce(dm_note, '-') || '|' || coalesce(resolved_by::text, '-'), ';') from public.item_identify_attempts where character_id = :'pb' and item_id = :'lily'));

-- PK18 m2: a joiner gets ONE summary audit line, not one per item
select tl_test.rec('PK18 m2 the joiner J has one summary line and no per-item line for the items it inherited',
  (select count(*) from public.campaign_audit_events where character_id = :'pj' and summary like 'Your party already knew%') = 1
  and (select count(*) from public.campaign_audit_events where character_id = :'pj' and summary in ('Your party learned something about an item: Sunpetal', 'Your party learned something about an item: Ghost Cap')) = 0,
  (select string_agg(summary, ' | ') from public.campaign_audit_events where character_id = :'pj'));

-- ---- round 3 ------------------------------------------------------------------------------------------------------------------
-- PK19 M1b: only what was learned IN this campaign is shared ({name} learned in camp, moved, camp2 DM raises {magic} -> camp2 gets
-- {magic} only); n5: back in camp, the camp2 part does not come along
select tl_test.as_root();
update public.items set secret = true where id = 'dagger';
select tl_test.as_user(:'dm');
select public.dm_set_item_knowledge('dagger', array[:'pa']::uuid[], '{name}', 'raise', :'camp');
select tl_test.as_root();
update public.characters set campaign_id = :'camp2' where id = :'pa';
select tl_test.as_user(:'dm');
select public.dm_set_item_knowledge('dagger', array[:'pa']::uuid[], '{magic}', 'raise', :'camp2') as m1b \gset
select tl_test.as_root();
insert into public.characters (id, owner_id, name, campaign_id, level, strength, dexterity, constitution, intelligence, wisdom, charisma, hp_max, hp_current, speed)
values ('f5a00000-0000-0000-0000-00000000000a', :'bob', 'Joiner Three', :'camp2', 1, 10, 12, 12, 10, 14, 10, 10, 10, 30);
select coalesce(tl_test.pk_ck(:'pd', 'dagger'), 'none') as d_dag \gset
select coalesce(tl_test.pk_ck('f5a00000-0000-0000-0000-00000000000a', 'dagger'), 'none') as j3_dag \gset
update public.characters set campaign_id = :'camp' where id = :'pa';
insert into public.characters (id, owner_id, name, campaign_id, level, strength, dexterity, constitution, intelligence, wisdom, charisma, hp_max, hp_current, speed)
values ('f5a00000-0000-0000-0000-00000000000b', :'carol', 'Joiner Four', :'camp', 1, 10, 12, 12, 10, 14, 10, 10, 10, 30);
select coalesce(tl_test.pk_ck('f5a00000-0000-0000-0000-00000000000b', 'dagger'), 'none') as j4_dag \gset
select tl_test.rec('PK19 M1b only knowledge learned in this campaign is shared: camp2 gets {magic} only (not the {name} from camp); back in camp, a joiner gets {name} only (n5)',
  tl_test.pk_ck(:'pa', 'dagger') = 'partially_identified:magic,name' and :'d_dag' = 'partially_identified:magic'
  and :'j3_dag' = 'partially_identified:magic' and :'j4_dag' = 'partially_identified:name',
  concat_ws(' ', tl_test.pk_ck(:'pa', 'dagger'), :'d_dag', :'j3_dag', :'j4_dag', :'m1b'));

-- PK20 N1: a DM write supersedes queued party shares; a pending share never lifts a hold, never re-reveals, never spreads
select tl_test.as_user(:'dm');
select public.create_homebrew_item(gen_random_uuid(), jsonb_build_object('name', 'Night Root', 'kind_id', 'herbs_plants', 'category_id', 'plant-flower',
  'campaign_id', :'camp', 'stackable', true, 'description', 'Black.')) ->> 'id' as nroot \gset
select public.set_item_identify_options(:'nroot', '{"unidentified_name": "Dark tuber", "identify_dc": 10}');
select public.dm_give_item(:'nroot', array[:'pa', :'pb', :'pc']::uuid[], 1, false);
select tl_test.as_root();
insert into public.party_share_pending (campaign_id, target_character_id, item_id, state, revealed, source_character_id)
values (:'camp', :'pb', :'nroot', 'identified', '{}', :'pa');
select tl_test.as_user(:'dm');
select public.dm_set_item_knowledge(:'nroot', array[:'pb']::uuid[], '{}', 'set');   -- the DM hides it from B
select tl_test.as_root();
select count(*) as nr_pend from public.party_share_pending where target_character_id = :'pb' and item_id = :'nroot' \gset
select tl_test.as_user(:'bob');
select public.sync_party_knowledge(:'pb') as nr_sync \gset
select tl_test.as_root();
-- belt and braces: a pending row older than a DM write of that pair is dropped at apply time
select tl_test.as_user(:'dm');
select public.dm_set_item_knowledge(:'nroot', array[:'pc']::uuid[], '{name}', 'raise');
select tl_test.as_root();
insert into public.party_share_pending (campaign_id, target_character_id, item_id, state, revealed, source_character_id, created_at)
values (:'camp', :'pc', :'nroot', 'identified', '{}', :'pa', now() - interval '1 minute');
select tl_test.as_user(:'carol');
select public.sync_party_knowledge(:'pc') as nc_sync \gset
select tl_test.as_root();
select tl_test.rec('PK20 N1 the DM''s hide deletes B''s queued share; B''s sync leaves B hidden and held; a share older than a DM write is dropped; only the DM''''s name reveal spread (nothing identified)',
  :nr_pend = 0 and tl_test.pk_ck(:'pb', :'nroot') = 'unidentified::held' and tl_test.pk_rowk(:'pb', :'nroot') = 'Dark tuber/unidentified'
  and tl_test.pk_ck(:'pc', :'nroot') like 'partially_identified:name%' and (select count(*) from public.party_share_pending where item_id = :'nroot') = 0
  and tl_test.pk_ck(:'pa', :'nroot') like 'partially_identified:name%',
  concat_ws(' ', :nr_pend, :'nr_sync', :'nc_sync', tl_test.pk_ck(:'pb', :'nroot'), tl_test.pk_ck(:'pc', :'nroot'), tl_test.pk_ck(:'pa', :'nroot')));

-- PK21 n2 + n3: one pending row per target and item (merged), and shares are written with no actor
select tl_test.as_root();
insert into public.party_share_pending (campaign_id, target_character_id, item_id, state, revealed, source_character_id)
values (:'camp', :'pc', :'fern2', 'partially_identified', '{name}', :'pa');
select tl_test.pk_code(format('insert into public.party_share_pending (campaign_id, target_character_id, item_id, state, revealed) values (%L, %L, %L, ''identified'', ''{}'')',
  :'camp', :'pc', :'fern2')) as dup \gset
delete from public.party_share_pending where target_character_id = :'pc' and item_id = :'fern2';
select tl_test.rec('PK21 a second pending row for the same target and item is refused (the share path merges); every party-share history row has no actor',
  :'dup' = '23505' and not exists (select 1 from public.item_knowledge_events where source = 'party_share' and actor is not null)
  and exists (select 1 from public.item_knowledge_events where source = 'party_share'),
  :'dup');

-- ---- round 4 ------------------------------------------------------------------------------------------------------------------
-- PK22 M1c: what the DM took back from a character is never shared from it (P4a release, P4b raise after a full hide, P4c partial)
select tl_test.as_user(:'dm');
select public.create_homebrew_item(gen_random_uuid(), jsonb_build_object('name', 'Star Moss', 'kind_id', 'herbs_plants', 'category_id', 'plant-flower',
  'campaign_id', :'camp', 'stackable', true, 'description', 'Twinkles.')) ->> 'id' as smoss \gset
select public.set_item_identify_options(:'smoss', '{"unidentified_name": "Grey star", "identify_dc": 10}');
select public.dm_give_item(:'smoss', array[:'pa', :'pb', :'pc']::uuid[], 1, false);
select public.dm_set_item_knowledge(:'smoss', array[:'pa']::uuid[], '{all}', 'set');
select public.dm_set_item_knowledge(:'smoss', array[:'pa']::uuid[], '{}', 'set');
select public.dm_release_item_knowledge_hold(:'smoss', array[:'pa']::uuid[], :'camp') as p4a \gset
select tl_test.as_root();
select tl_test.pk_ck(:'pb', :'smoss') as p4a_b \gset
select tl_test.pk_ck(:'pc', :'smoss') as p4a_c \gset
select tl_test.as_user(:'dm');
select public.dm_set_item_knowledge(:'smoss', array[:'pa']::uuid[], '{magic}', 'raise') as p4b \gset
select tl_test.as_root();
select tl_test.rec('PK22 M1c P4a: Everything -> Nothing -> release shares nothing; P4b: then raise {magic} -> the others get only {magic}, decoy name kept',
  :'p4a_b' = 'unidentified:' and :'p4a_c' = 'unidentified:' and (:'p4a'::jsonb ->> 'shared_with')::int = 0
  and tl_test.pk_ck(:'pa', :'smoss') = 'partially_identified:magic'
  and tl_test.pk_ck(:'pb', :'smoss') = 'partially_identified:magic' and tl_test.pk_rowk(:'pb', :'smoss') = 'Grey star/partially_identified'
  and tl_test.pk_ck(:'pc', :'smoss') = 'partially_identified:magic',
  concat_ws(' ', :'p4a_b', :'p4a_c', :'p4a', tl_test.pk_ck(:'pa', :'smoss'), tl_test.pk_ck(:'pb', :'smoss'), tl_test.pk_rowk(:'pb', :'smoss')));

select tl_test.as_user(:'dm');
select public.create_homebrew_item(gen_random_uuid(), jsonb_build_object('name', 'Moon Bell', 'kind_id', 'herbs_plants', 'category_id', 'plant-flower',
  'campaign_id', :'camp', 'stackable', true, 'description', 'Rings softly.')) ->> 'id' as bell \gset
select public.set_item_identify_options(:'bell', '{"unidentified_name": "Pale cup", "identify_dc": 10}');
select public.dm_give_item(:'bell', array[:'pa', :'pb']::uuid[], 1, false);
select public.dm_set_item_knowledge(:'bell', array[:'pa']::uuid[], '{name}', 'set');
select public.dm_set_item_knowledge(:'bell', array[:'pa']::uuid[], '{}', 'set');
select public.dm_set_item_knowledge(:'bell', array[:'pa']::uuid[], '{magic}', 'raise');
select tl_test.as_root();
select tl_test.rec('PK23 M1c P4c: {name} -> Nothing -> raise {magic}: the others get only {magic} (not the name), decoy name kept',
  tl_test.pk_ck(:'pb', :'bell') = 'partially_identified:magic' and tl_test.pk_rowk(:'pb', :'bell') = 'Pale cup/partially_identified'
  and (select ident from public._ik_campaign_level(:'pa', :'bell', :'camp')) = false
  and (select rev from public._ik_campaign_level(:'pa', :'bell', :'camp')) = '{magic}',
  concat_ws(' ', tl_test.pk_ck(:'pb', :'bell'), tl_test.pk_rowk(:'pb', :'bell')));

-- PK24 n8: a DM "set" that only holds the character back (nothing else changes) still writes its DM line (mode set)
select tl_test.as_user(:'dm');
select public.create_homebrew_item(gen_random_uuid(), jsonb_build_object('name', 'Quiet Leaf', 'kind_id', 'herbs_plants', 'category_id', 'plant-flower',
  'campaign_id', :'camp', 'stackable', true, 'description', 'Silent.')) ->> 'id' as qleaf \gset
select public.set_item_identify_options(:'qleaf', '{"unidentified_name": "Thin leaf", "identify_dc": 10}');
select public.dm_give_item(:'qleaf', array[:'pb']::uuid[], 1, false);
select public.dm_set_item_knowledge(:'qleaf', array[:'pb']::uuid[], '{}', 'set') as n8 \gset
select tl_test.as_root();
select tl_test.rec('PK24 n8 a hold-only set writes a DM audit line with mode set (the hold is derivable after rollback -> reapply)',
  (:'n8'::jsonb ->> 'changed')::int = 0 and tl_test.pk_ck(:'pb', :'qleaf') = 'unidentified::held'
  and exists (select 1 from public.campaign_audit_events e where e.character_id = :'pb' and e.visibility = 'dm' and e.after ->> 'item_id' = :'qleaf'
              and e.after ->> 'mode' = 'set'),
  :'n8');
