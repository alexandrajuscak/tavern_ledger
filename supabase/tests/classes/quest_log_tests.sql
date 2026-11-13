-- =============================================================================
-- Quest log (20261114000400, docs/QUEST_LOG.md): visibility per role (DM, owning player, other player of the party, player of
-- another campaign, anon), DM notes never in a player read, no REST / Realtime path, archive, ordering, campaign move, the
-- RPC role checks and the cache classification. Runs inside the per-class harness (alice = player of :camp, dm = its DM).
-- =============================================================================
\set ca 9a000000-0000-0000-0000-00000000000a
\set cb 9a000000-0000-0000-0000-00000000000b
\set ce 9a000000-0000-0000-0000-00000000000e
\set eve e7777777-7777-7777-7777-777777777777
\set carl c8888888-8888-8888-8888-888888888888
\set camp2 c2c00000-0000-0000-0000-0000000000a2
insert into public.campaign_members (campaign_id, user_id, role) values (:'camp', :'bob', 'player');
insert into auth.users (id, email) values (:'eve', 'eve-quests@test'), (:'carl', 'carl-quests@test');
insert into public.campaigns (id, name, created_by) values (:'camp2', 'Other Table', :'eve');
insert into public.campaign_members (campaign_id, user_id, role) values (:'camp2', :'eve', 'dm'), (:'camp2', :'carl', 'player'), (:'camp2', :'alice', 'player');
insert into public.characters (id, owner_id, name, campaign_id, level, strength, dexterity, constitution, intelligence, wisdom, charisma, hp_max, hp_current, speed) values
  (:'ca', :'alice', 'Quest A', :'camp', 1, 10, 12, 12, 10, 14, 10, 10, 10, 30),
  (:'cb', :'bob', 'Quest B', :'camp', 1, 10, 12, 12, 10, 14, 10, 10, 10, 30),
  (:'ce', :'carl', 'Quest E', :'camp2', 1, 10, 12, 12, 10, 14, 10, 10, 10, 30);
create function tl_test.qcode(p_sql text) returns text language plpgsql as $$
begin execute p_sql; return 'ok'; exception when others then return sqlstate; end $$;
-- titles of a quest read, in order
create function tl_test.qtitles(p jsonb) returns text language sql as $$
  select coalesce(string_agg(q ->> 'title', ',' order by n), '') from jsonb_array_elements(p -> 'quests') with ordinality x(q, n) $$;
grant all on all functions in schema tl_test to public;

-- ---- 1. the DM creates quests -------------------------------------------------------------------------------------------------
select tl_test.as_user(:'dm');
select public.dm_save_quest(:'camp', jsonb_build_object('title', 'Party', 'description', 'Find the lost mine', 'visibility', 'party',
  'dm_notes', 'NOTE-MARK-PARTY', 'objectives', jsonb_build_array(jsonb_build_object('text', 'Reach Phandalin'), jsonb_build_object('text', 'Find the map')))) ->> 'id' as qp \gset
select public.dm_save_quest(:'camp', jsonb_build_object('title', 'Indiv', 'visibility', 'individual', 'target_character_id', :'ca',
  'dm_notes', 'NOTE-MARK-INDIV')) ->> 'id' as qi \gset
select public.dm_save_quest(:'camp', jsonb_build_object('title', 'PrivA', 'visibility', 'private', 'target_character_id', :'ca',
  'dm_notes', 'NOTE-MARK-PRIVA', 'objectives', jsonb_build_array(jsonb_build_object('text', 'Secret step')))) ->> 'id' as qva \gset
select public.dm_save_quest(:'camp', jsonb_build_object('title', 'PrivB', 'visibility', 'private', 'target_character_id', :'cb',
  'dm_notes', 'NOTE-MARK-PRIVB')) ->> 'id' as qvb \gset
select public.dm_save_quest(:'camp', jsonb_build_object('title', 'Done', 'visibility', 'party', 'status', 'completed')) ->> 'id' as qdone \gset
select public.dm_save_quest(:'camp', jsonb_build_object('title', 'Lost', 'visibility', 'party', 'status', 'failed')) ->> 'id' as qfail \gset
select public.dm_save_quest(:'camp', jsonb_build_object('title', 'Gone', 'visibility', 'party', 'dm_notes', 'NOTE-MARK-GONE')) ->> 'id' as qgone \gset
select public.dm_archive_quest(:'qgone') ->> 'archived_at' is not null as gone_archived \gset
select public.get_campaign_quests(:'camp')::text as dm_read \gset
select public.get_campaign_quests(:'camp', true)::text as dm_read_all \gset
select public.get_character_quests(:'ca')::text as dm_view_a \gset
select tl_test.as_user(:'eve');
select public.dm_save_quest(:'camp2', jsonb_build_object('title', 'Camp2 party', 'visibility', 'party', 'dm_notes', 'NOTE-MARK-C2')) ->> 'id' as q2 \gset
select tl_test.qcode(format('select public.get_campaign_quests(%L)', :'camp')) as eve_read_camp \gset
select tl_test.qcode(format('select public.dm_set_quest_status(%L, ''failed'')', :'qp')) as eve_write_camp \gset
select tl_test.qcode(format('select public.dm_save_quest(%L, %L)', :'camp', jsonb_build_object('id', :'qp', 'title', 'hijack'))) as eve_save_camp \gset
select tl_test.as_root();

select tl_test.rec('QL1 DM read: 6 live quests with DM notes, archived only on request',
  jsonb_array_length((:'dm_read')::jsonb -> 'quests') = 6 and :'dm_read' like '%NOTE-MARK-PRIVA%' and :'dm_read' not like '%NOTE-MARK-GONE%'
  and jsonb_array_length((:'dm_read_all')::jsonb -> 'quests') = 7 and :'dm_read_all' like '%NOTE-MARK-GONE%' and :'gone_archived', :'dm_read');
select tl_test.rec('QL2 the DM viewing a sheet gets the player view (no notes, not another character''s private quest)',
  tl_test.qtitles((:'dm_view_a')::jsonb) = 'Party,Indiv,PrivA,Done,Lost' and :'dm_view_a' not like '%NOTE-MARK%', :'dm_view_a');
select tl_test.rec('QL3 a DM of another campaign cannot read or write this campaign''s quests (42501)',
  :'eve_read_camp' = '42501' and :'eve_write_camp' = '42501' and :'eve_save_camp' = '42501',
  :'eve_read_camp' || '/' || :'eve_write_camp' || '/' || :'eve_save_camp');

-- ---- 2. players ---------------------------------------------------------------------------------------------------------------
select id as obj_secret from public.quest_objectives where body = 'Secret step' \gset
select tl_test.as_user(:'alice');
select public.get_character_quests(:'ca')::text as a_read \gset
select tl_test.qcode(format('select public.get_character_quests(%L)', :'cb')) as a_reads_b \gset
select tl_test.qcode(format('select public.get_campaign_quests(%L)', :'camp')) as a_dm_read \gset
select tl_test.qcode('select count(*) from public.quests') as a_rest_q \gset
select tl_test.qcode('select count(*) from public.quest_objectives') as a_rest_o \gset
select tl_test.qcode('select count(*) from public.quest_dm_notes') as a_rest_n \gset
select tl_test.qcode(format('select public.dm_save_quest(%L, %L)', :'camp', '{"title":"mine","visibility":"party"}')) as a_save \gset
select tl_test.qcode(format('select public.dm_set_quest_status(%L, ''completed'')', :'qva')) as a_status \gset
select tl_test.qcode(format('select public.dm_set_quest_objective(%L, true)', :'obj_secret')) as a_tick \gset
select tl_test.qcode(format('select public.dm_archive_quest(%L)', :'qva')) as a_archive \gset
select tl_test.qcode(format('select public.dm_reorder_quests(%L, array[%L]::uuid[])', :'camp', :'qva')) as a_reorder \gset
select tl_test.as_user(:'bob');
select public.get_character_quests(:'cb')::text as b_read \gset
select tl_test.qcode(format('select public.get_character_quests(%L)', :'ca')) as b_reads_a \gset
select tl_test.as_user(:'carl');
select public.get_character_quests(:'ce')::text as e_read \gset
select tl_test.qcode(format('select public.get_character_quests(%L)', :'ca')) as e_reads_a \gset
select tl_test.as_root();
-- anon: no execute on any quest RPC
set local role anon;
select tl_test.qcode(format('select public.get_character_quests(%L)', :'ca')) as anon_read \gset
select tl_test.qcode(format('select public.get_campaign_quests(%L)', :'camp')) as anon_dm \gset
select tl_test.qcode('select count(*) from public.quests') as anon_rest \gset
select tl_test.as_root();
reset role;

select tl_test.rec('QL4 owning player A sees party, own individual and own private quest; never notes or B''s private quest',
  tl_test.qtitles((:'a_read')::jsonb) = 'Party,Indiv,PrivA,Done,Lost' and :'a_read' not like '%NOTE-MARK%' and :'a_read' not like '%PrivB%'
  and :'a_read' not like '%dm_notes%', :'a_read');
select tl_test.rec('QL5 the "mine" flag: true on A''s individual and private quest only',
  (select string_agg(q ->> 'title', ',' order by q ->> 'title') from jsonb_array_elements((:'a_read')::jsonb -> 'quests') q where (q ->> 'mine')::boolean) = 'Indiv,PrivA', :'a_read');
select tl_test.rec('QL6 other player B sees the party quests and A''s individual quest, not A''s private one; own private quest yes',
  tl_test.qtitles((:'b_read')::jsonb) = 'Party,Indiv,PrivB,Done,Lost' and :'b_read' not like '%PrivA%' and :'b_read' not like '%Secret step%'
  and :'b_read' not like '%NOTE-MARK%', :'b_read');
select tl_test.rec('QL7 a player of another campaign sees only that campaign''s quests', tl_test.qtitles((:'e_read')::jsonb) = 'Camp2 party'
  and :'e_read' not like '%NOTE-MARK%', :'e_read');
select tl_test.rec('QL8 a player cannot read another character''s quests (42501)',
  :'a_reads_b' = '42501' and :'b_reads_a' = '42501' and :'e_reads_a' = '42501', :'a_reads_b' || '/' || :'b_reads_a' || '/' || :'e_reads_a');
select tl_test.rec('QL9 a player cannot use the DM read or any DM write (42501)',
  :'a_dm_read' = '42501' and :'a_save' = '42501' and :'a_status' = '42501' and :'a_tick' = '42501' and :'a_archive' = '42501' and :'a_reorder' = '42501',
  concat_ws('/', :'a_dm_read', :'a_save', :'a_status', :'a_tick', :'a_archive', :'a_reorder'));
select tl_test.rec('QL10 REST on the quest tables is refused for players (42501: no grants)',
  :'a_rest_q' = '42501' and :'a_rest_o' = '42501' and :'a_rest_n' = '42501', concat_ws('/', :'a_rest_q', :'a_rest_o', :'a_rest_n'));
select tl_test.rec('QL11 anon: no RPC, no table (42501)', :'anon_read' = '42501' and :'anon_dm' = '42501' and :'anon_rest' = '42501',
  concat_ws('/', :'anon_read', :'anon_dm', :'anon_rest'));
select tl_test.rec('QL12 no quest table is in the supabase_realtime publication',
  not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename in ('quests', 'quest_objectives', 'quest_dm_notes')));
select tl_test.rec('QL13 RLS on, zero table grants for anon / authenticated',
  (select bool_and(c.relrowsecurity) from pg_class c where c.oid in ('public.quests'::regclass, 'public.quest_objectives'::regclass, 'public.quest_dm_notes'::regclass))
  and not exists (select 1 from information_schema.role_table_grants g where g.table_schema = 'public'
                  and g.table_name in ('quests', 'quest_objectives', 'quest_dm_notes') and g.grantee in ('anon', 'authenticated', 'PUBLIC')));
select tl_test.rec('QL14 every quest RPC: security definer, fixed search_path, no anon / PUBLIC execute',
  (select bool_and(p.prosecdef and p.proconfig::text like '%search_path=public, pg_temp%'
                   and not has_function_privilege('anon', p.oid, 'execute'))
   from pg_proc p where p.pronamespace = 'public'::regnamespace
     and p.proname in ('get_character_quests', 'get_campaign_quests', 'dm_save_quest', 'dm_set_quest_status', 'dm_set_quest_objective',
                       'dm_archive_quest', 'dm_reorder_quests', '_quest_dm_gate', '_quest_objectives_json', '_quest_dm_json')));

-- ---- 3. tick, status, ordering ------------------------------------------------------------------------------------------------
select (select id from public.quest_objectives where body = 'Find the map') as obj_map \gset
select tl_test.as_user(:'dm');
select public.dm_set_quest_objective(:'obj_map', true) is not null as ticked \gset
select tl_test.as_user(:'bob');
select public.get_character_quests(:'cb')::text as b_after_tick \gset
select tl_test.as_root();
select tl_test.rec('QL15 an objective the DM ticks shows as done to the players; done_by / done_at recorded',
  (select (o ->> 'done')::boolean from jsonb_array_elements((:'b_after_tick')::jsonb -> 'quests' -> 0 -> 'objectives') o where o ->> 'text' = 'Find the map')
  and (select done_by = :'dm' and done_at is not null from public.quest_objectives where id = :'obj_map'), :'b_after_tick');

select tl_test.as_user(:'dm');
select public.dm_reorder_quests(:'camp', array[:'qva', :'qi', :'qp']::uuid[]) is not null as reordered \gset
select public.dm_set_quest_status(:'qfail', 'active') is not null as reopened \gset
select tl_test.as_user(:'alice');
select tl_test.qtitles(public.get_character_quests(:'ca')) as a_order \gset
select tl_test.as_root();
select tl_test.rec('QL16 order: active first in the DM''s order, then completed, then failed (a status change moves it)',
  :'a_order' = 'PrivA,Indiv,Party,Lost,Done', :'a_order');

-- ---- 4. edit: objectives archived, never deleted; validation; stale revision ---------------------------------------------------
select tl_test.as_user(:'dm');
select (public.get_campaign_quests(:'camp') -> 'quests') as dmq \gset
select public.dm_save_quest(:'camp', jsonb_build_object('id', :'qp', 'objectives',
  jsonb_build_array(jsonb_build_object('id', :'obj_map', 'text', 'Find the map (torn)'), jsonb_build_object('text', 'Talk to Sildar')))) as saved \gset
select tl_test.qcode(format('select public.dm_save_quest(%L, %L)', :'camp', '{"title":"x","visibility":"individual"}')) as v_no_target \gset
select tl_test.qcode(format('select public.dm_save_quest(%L, %L)', :'camp', jsonb_build_object('title', 'x', 'visibility', 'private', 'target_character_id', :'ce'))) as v_other_camp \gset
select tl_test.qcode(format('select public.dm_save_quest(%L, %L, 1)', :'camp', jsonb_build_object('id', :'qp', 'title', 'stale'))) as v_stale \gset
select tl_test.qcode(format('select public.dm_save_quest(%L, %L)', :'camp', '{"title":"  ","visibility":"party"}')) as v_blank \gset
select tl_test.qcode(format('select public.dm_save_quest(%L, %L)', :'camp2', jsonb_build_object('id', :'qp', 'title', 'moved'))) as v_wrong_camp \gset
select tl_test.as_root();
select tl_test.rec('QL17 a removed objective is archived (row kept), kept ones keep their tick, new ones appended',
  (select count(*) from public.quest_objectives where quest_id = :'qp') = 3
  and (select archived_at is not null from public.quest_objectives where body = 'Reach Phandalin')
  and (select done from public.quest_objectives where id = :'obj_map')
  and (select string_agg(o ->> 'text', ',' order by n) from jsonb_array_elements((:'saved')::jsonb -> 'objectives') with ordinality x(o, n)) = 'Find the map (torn),Talk to Sildar',
  :'saved');
select tl_test.rec('QL18 validation: target required, target must be in the campaign, stale revision 40001, blank title, wrong campaign',
  :'v_no_target' = '22023' and :'v_other_camp' = '22023' and :'v_stale' = '40001' and :'v_blank' = '22023' and :'v_wrong_camp' = '42501',
  concat_ws('/', :'v_no_target', :'v_other_camp', :'v_stale', :'v_blank', :'v_wrong_camp'));

-- ---- 5. archive / restore --------------------------------------------------------------------------------------------------
select tl_test.as_user(:'dm');
select public.dm_archive_quest(:'qi') is not null as arch \gset
select tl_test.as_user(:'bob');
select tl_test.qtitles(public.get_character_quests(:'cb')) as b_arch \gset
select tl_test.as_user(:'dm');
select public.dm_archive_quest(:'qi', false) is not null as restored \gset
select tl_test.as_user(:'bob');
select tl_test.qtitles(public.get_character_quests(:'cb')) as b_restored \gset
select tl_test.as_root();
select tl_test.rec('QL19 archive hides a quest from players (row kept), restore brings it back',
  :'b_arch' not like '%Indiv%' and :'b_restored' like '%Indiv%' and (select count(*) from public.quests where campaign_id = :'camp') = 7,
  :'b_arch' || ' / ' || :'b_restored');

-- ---- 6. campaign move ----------------------------------------------------------------------------------------------------------
update public.characters set campaign_id = :'camp2' where id = :'ca';
select tl_test.as_user(:'alice');
select tl_test.qtitles(public.get_character_quests(:'ca')) as a_moved \gset
select tl_test.as_user(:'bob');
select tl_test.qtitles(public.get_character_quests(:'cb')) as b_a_moved \gset
select tl_test.as_user(:'carl');
select tl_test.qtitles(public.get_character_quests(:'ce')) as e_a_moved \gset
select tl_test.as_user(:'dm');
select tl_test.qcode(format('select public.get_character_quests(%L)', :'ca')) as dm_a_moved \gset
select tl_test.as_root();
update public.characters set campaign_id = :'camp' where id = :'ca';
select tl_test.as_user(:'alice');
select tl_test.qtitles(public.get_character_quests(:'ca')) as a_back \gset
select tl_test.as_root();
select tl_test.rec('QL20 campaign move: A sees only the new campaign''s quests; B stops seeing A''s individual quest; nothing leaks to camp2',
  :'a_moved' = 'Camp2 party' and :'b_a_moved' not like '%Indiv%' and :'e_a_moved' = 'Camp2 party' and :'dm_a_moved' = '42501',
  concat_ws(' / ', :'a_moved', :'b_a_moved', :'e_a_moved', :'dm_a_moved'));
select tl_test.rec('QL21 moving back: A sees its old campaign''s quests again (they were kept)', :'a_back' like '%PrivA%' and :'a_back' like '%Indiv%', :'a_back');

-- ---- 6b. campaign membership --------------------------------------------------------------------------------------------------
-- bob is not a member of camp2: moving his character there is refused (governance trigger TLDMO first; the characters update
-- policy would refuse it too), so he can never read camp2's quests that way
select tl_test.as_user(:'bob');
select tl_test.qcode(format('update public.characters set campaign_id = %L where id = %L', :'camp2', :'cb')) as b_move \gset
select tl_test.as_root();
select tl_test.rec('QL24 a player cannot move a character into a campaign they are not a member of (refused: governance TLDMO / RLS)',
  :'b_move' in ('42501', 'TLDMO') and (select campaign_id = :'camp' from public.characters where id = :'cb'), :'b_move');
-- a player removed from the campaign keeps the character's campaign_id: no quest log any more
delete from public.campaign_members where campaign_id = :'camp' and user_id = :'bob';
select tl_test.as_user(:'bob');
select public.get_character_quests(:'cb')::text as b_removed \gset
select tl_test.as_root();
insert into public.campaign_members (campaign_id, user_id, role) values (:'camp', :'bob', 'player');
select tl_test.as_user(:'bob');
select tl_test.qtitles(public.get_character_quests(:'cb')) as b_readded \gset
select tl_test.as_root();
select tl_test.rec('QL25 a player removed from the campaign sees no quests (character still points at it); re-added: visible again',
  jsonb_array_length((:'b_removed')::jsonb -> 'quests') = 0 and (:'b_removed')::jsonb ->> 'campaign_id' is null and :'b_readded' like '%Party%',
  :'b_removed' || ' / ' || :'b_readded');

-- ---- 7. cache classification, character deletion -------------------------------------------------------------------------------
select rev as g0 from tl_cache.global_rev where id = 1 \gset
select coalesce((select rev from tl_cache.character_rev where character_id = :'ca'), 0) as c0 \gset
select tl_test.as_user(:'dm');
select public.dm_save_quest(:'camp', jsonb_build_object('id', :'qp', 'title', 'Party!', 'dm_notes', 'NOTE-MARK-2')) is not null as cache_write \gset
select public.dm_set_quest_objective(:'obj_map', false) is not null as cache_tick \gset
select tl_test.as_root();
select tl_test.rec('QL22 tl_cache_rev = tl_cache.skip() on the 3 tables; a DM quest write bumps neither the global nor a character counter',
  (select count(*) from pg_trigger t where t.tgname = 'tl_cache_rev' and t.tgfoid = 'tl_cache.skip()'::regprocedure
     and t.tgrelid in ('public.quests'::regclass, 'public.quest_objectives'::regclass, 'public.quest_dm_notes'::regclass)) = 3
  and (select rev from tl_cache.global_rev where id = 1) = :g0
  and coalesce((select rev from tl_cache.character_rev where character_id = :'ca'), 0) = :c0
  and not exists (select 1 from tl_cache.character_reads r where r.payload::text like '%NOTE-MARK%'));
delete from public.characters where id = :'cb';
select tl_test.as_user(:'dm');
select public.get_campaign_quests(:'camp')::text as dm_after_delete \gset
select tl_test.as_root();
select tl_test.rec('QL23 deleting a character is never blocked; its private quest stays (no target), DM-only',
  (select target_character_id is null and visibility = 'private' from public.quests where id = :'qvb')
  and :'dm_after_delete' like '%PrivB%', :'dm_after_delete');
