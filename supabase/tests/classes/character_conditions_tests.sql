-- =============================================================================
-- Character conditions and DM tags on the sheet (20261112000200; docs/HIDDEN_DM_DATA.md "Conditions and tags on the sheet"):
-- DM RPCs (SRD condition, Exhaustion 1-6, tags with damage type, note, duration, hidden), the characters.conditions mirror of
-- the visible rows, the old-client compatibility path, removal rights, combat carry with the Exhaustion level, and the LEAK
-- checks: a player never reads a hidden row (RPC, table select, secrets, get_character_reads cache miss and hit, tl_cache
-- payloads, mirror), and a hidden-only change writes no character_revisions row and does not touch the characters row.
-- Runs inside the per-class harness (alice = player of :camp, bob = outsider, dm = DM of :camp).
-- =============================================================================
\set cc1 f3d00000-0000-0000-0000-000000000001
\set cc2 f3d00000-0000-0000-0000-000000000002
\set cc3 f3d00000-0000-0000-0000-000000000003
insert into public.characters (id, owner_id, name, campaign_id, level, strength, dexterity, constitution, intelligence, wisdom, charisma, hp_max, hp_current, speed) values
  (:'cc1', :'alice', 'Cond Hero', :'camp', 1, 14, 12, 12, 10, 10, 10, 10, 10, 30),
  (:'cc2', :'alice', 'Cond Rogue', :'camp', 1, 10, 16, 12, 10, 10, 10, 9, 9, 30);
create function tl_test.cc_code(p_sql text) returns text language plpgsql as $$
begin execute p_sql; return 'ok'; exception when others then return sqlstate; end $$;
-- forget this transaction's "already bumped" markers of one character, so the next change behaves like a new transaction
create function tl_test.cc_fresh(p_char uuid) returns void language plpgsql as $$
begin
  perform set_config('tl_rev.r' || md5(p_char::text || 'character_conditions' || txid_current()::text), '', true);
  perform set_config('tl_rev.r' || md5(p_char::text || 'characters' || txid_current()::text), '', true);
  perform set_config('tl_cache.c' || md5(p_char::text || txid_current()::text), '', true);
  perform set_config('tl_cache.g' || md5(txid_current()::text), '', true);
end $$;
create function tl_test.cc_revs(p_char uuid) returns int language sql security definer as $$
  select count(*)::int from public.character_revisions where character_id = p_char $$;
create function tl_test.cc_row(p_char uuid) returns text language sql security definer as $$
  select xmin::text || '/' || ctid::text || '/' || conditions::text from public.characters where id = p_char $$;
create function tl_test.cc_mirror(p_char uuid) returns jsonb language sql security definer as $$
  select conditions from public.characters where id = p_char $$;
create function tl_test.cc_find(p_list jsonb, p_name text) returns jsonb language sql as $$
  select x from jsonb_array_elements(p_list) x where x ->> 'name' = p_name limit 1 $$;
create function tl_test.cc_id(p_char uuid, p_name text) returns uuid language sql security definer as $$
  select id from public.character_conditions where character_id = p_char and name = p_name order by applied_at limit 1 $$;
create function tl_test.cc_cached(p_char uuid, p_viewer uuid) returns text language sql security definer as $$
  select coalesce(string_agg(payload::text, '|'), '') from tl_cache.character_reads where character_id = p_char and viewer = p_viewer $$;
grant all on all functions in schema tl_test to public;

-- ---- DM adds visible conditions and tags --------------------------------------------------------------------------------------
select tl_test.as_user(:'dm');
select public.apply_character_effect(:'cc1', '{"kind": "condition", "condition_key": "poisoned"}') as r \gset
select public.apply_character_effect(:'cc1', '{"kind": "exhaustion", "level": 2}') as r \gset
select public.apply_character_effect(:'cc1', '{"kind": "tag", "tag_type": "resistance", "damage_type_id": "fire", "note": "Potion of Fire Resistance", "duration_text": "1 hour"}') as r \gset
select tl_test.as_user(:'alice');
select public.get_character_conditions(:'cc1') as pv \gset
select tl_test.rec('CC1 the player sees the DM''s Poisoned with the SRD reminder, marked DM-applied and not removable',
  tl_test.cc_find(:'pv', 'Poisoned') ->> 'condition_key' = 'poisoned' and tl_test.cc_find(:'pv', 'Poisoned') ->> 'rule' like 'Disadvantage on attack rolls%'
  and (tl_test.cc_find(:'pv', 'Poisoned') ->> 'dm_applied')::boolean and not (tl_test.cc_find(:'pv', 'Poisoned') ->> 'can_remove')::boolean
  and tl_test.cc_find(:'pv', 'Poisoned') -> 'hidden' = 'null'::jsonb, :'pv');
select tl_test.rec('CC2 Exhaustion 2 with its level and the SRD 5.2.1 reminder',
  (tl_test.cc_find(:'pv', 'Exhaustion') ->> 'level')::int = 2 and tl_test.cc_find(:'pv', 'Exhaustion') ->> 'label' = 'Exhaustion 2'
  and tl_test.cc_find(:'pv', 'Exhaustion') ->> 'rule_source' like 'SRD 5.2.1%', :'pv');
select tl_test.rec('CC3 a resistance tag: generated name, damage type, note and duration reach the player',
  tl_test.cc_find(:'pv', 'Resistant to fire') ->> 'damage_type_id' = 'fire' and tl_test.cc_find(:'pv', 'Resistant to fire') ->> 'note' = 'Potion of Fire Resistance'
  and tl_test.cc_find(:'pv', 'Resistant to fire') ->> 'duration_text' = '1 hour' and tl_test.cc_find(:'pv', 'Resistant to fire') ->> 'tag_type' = 'resistance', :'pv');
-- (rows applied in one transaction share applied_at; separate RPC calls keep their order)
select tl_test.rec('CC4 the mirror characters.conditions lists the visible rows', tl_test.cc_mirror(:'cc1') @> '["Poisoned", "Exhaustion 2", "Resistant to fire"]'
  and jsonb_array_length(tl_test.cc_mirror(:'cc1')) = 3,
  tl_test.cc_mirror(:'cc1')::text);
select tl_test.rec('CC5 the player read path serves the conditions (get_character_reads, the caller''s view)',
  jsonb_array_length(public.get_character_reads(:'cc1', array['get_character_conditions']) -> 'reads' -> 'get_character_conditions') = 3);

-- ---- hidden: LEAK checks ------------------------------------------------------------------------------------------------------
select tl_test.as_root();
select tl_test.cc_fresh(:'cc1');
select tl_test.cc_revs(:'cc1') as revs0, tl_test.cc_row(:'cc1') as row0 \gset
select tl_test.as_user(:'dm');
select public.apply_character_effect(:'cc1', '{"kind": "tag", "tag_type": "curse", "name": "Cursed by the lich", "note": "Whispers at night", "hidden": true, "dm_note": "Dies at level 5 unless lifted"}') as r \gset
select tl_test.rec('CC6 the DM sees the hidden tag with its DM note', (tl_test.cc_find(:'r', 'Cursed by the lich') ->> 'hidden')::boolean
  and tl_test.cc_find(:'r', 'Cursed by the lich') ->> 'dm_note' = 'Dies at level 5 unless lifted');
select tl_test.rec('LK1 a hidden insert writes no character_revisions row and leaves the characters row untouched (no Realtime event, no updated_at)',
  tl_test.cc_revs(:'cc1') = :revs0 and tl_test.cc_row(:'cc1') = :'row0', tl_test.cc_revs(:'cc1') || ' / ' || :revs0);
select public.update_character_effect(tl_test.cc_id(:'cc1', 'Cursed by the lich'), '{"note": "Whispers louder", "duration_text": "until lifted"}') as r \gset
select public.set_condition_dm_note(tl_test.cc_id(:'cc1', 'Cursed by the lich'), 'Dies at level 6');
select tl_test.rec('LK2 a hidden update (note, duration, DM note) writes no revision and leaves the characters row untouched',
  tl_test.cc_revs(:'cc1') = :revs0 and tl_test.cc_row(:'cc1') = :'row0');
-- the DM reads (and caches) his view: it is stored under the DM, never served to the player
select public.get_character_reads(:'cc1', array['get_character_conditions', 'characters', 'get_character_derived_stats']) as dmr \gset
select tl_test.as_root();
select tl_test.cc_fresh(:'cc1');   -- in production the reads run in later transactions: the cache stores them
select tl_test.as_user(:'alice');
select public.get_character_conditions(:'cc1')::text as p1, public.get_character_reads(:'cc1', array['get_character_conditions', 'characters', 'get_character_derived_stats', 'revisions']) as pr1 \gset
select public.get_character_reads(:'cc1', array['get_character_conditions', 'characters', 'get_character_derived_stats', 'revisions']) as pr2 \gset
select tl_test.rec('LK3 RPC: the player''s get_character_conditions has no hidden row, name, note or DM note',
  :'p1' not like '%Cursed%' and :'p1' not like '%Whispers%' and :'p1' not like '%Dies at%' and :'p1' not like '%"hidden": true%');
select tl_test.rec('LK4 REST/table: the player selects no hidden row from character_conditions and nothing from the secrets',
  (select count(*) from public.character_conditions where character_id = :'cc1' and hidden) = 0
  and (select count(*) from public.character_conditions where character_id = :'cc1') = 3
  and (select count(*) from public.character_condition_secrets) = 0);
select tl_test.rec('LK5 get_character_reads cache MISS: no hidden content in conditions, characters or revisions',
  (:'pr1')::jsonb ->> 'reads' not like '%Cursed%' and (:'pr1')::jsonb ->> 'reads' not like '%Whispers%' and ((:'pr1')::jsonb -> 'errors') = '{}'::jsonb, :'pr1');
select tl_test.rec('LK6 get_character_reads cache HIT (derived stats served from the player''s cache entry): still no hidden content',
  ((:'pr2')::jsonb -> 'cache' ->> 'hits')::int >= 1 and (:'pr2')::jsonb ->> 'reads' not like '%Cursed%' and (:'pr2')::jsonb ->> 'reads' not like '%Whispers%', (:'pr2')::jsonb ->> 'cache');
select tl_test.rec('LK7 the conditions read is never stored in tl_cache (only the per-viewer rules reads are)',
  (select tl_test.cc_cached(:'cc1', :'alice')) not like '%Cursed%' and (select tl_test.cc_cached(:'cc1', :'alice')) not like '%Potion of Fire%'
  and (select tl_test.cc_cached(:'cc1', :'alice')) <> '');
select tl_test.rec('LK8 the mirror characters.conditions never contains a hidden name', tl_test.cc_mirror(:'cc1')::text not like '%Cursed%');
select tl_test.rec('LK9 the revisions read has no trace of the hidden change', ((:'pr1')::jsonb -> 'reads' -> 'revisions') = ((:'pr2')::jsonb -> 'reads' -> 'revisions'));
select tl_test.rec('LK10 a player cannot update, reveal, remove or annotate a hidden row (not found)',
  tl_test.cc_code(format('select public.update_character_effect(%L, %L)', tl_test.cc_id(:'cc1', 'Cursed by the lich'), '{"note": "x"}')) = 'P0002'
  and tl_test.cc_code(format('select public.remove_character_condition(%L)', tl_test.cc_id(:'cc1', 'Cursed by the lich'))) = 'P0002'
  and tl_test.cc_code(format('select public.reveal_character_condition(%L)', tl_test.cc_id(:'cc1', 'Cursed by the lich'))) = '42501'
  and tl_test.cc_code(format('select public.set_condition_dm_note(%L, %L)', tl_test.cc_id(:'cc1', 'Cursed by the lich'), 'x')) = '42501');
select tl_test.rec('LK11 a player cannot add a hidden row or a DM note',
  tl_test.cc_code(format('select public.apply_character_effect(%L, %L)', :'cc1', '{"kind": "tag", "tag_type": "other", "name": "Secret", "hidden": true}')) = '42501'
  and tl_test.cc_code(format('select public.apply_character_effect(%L, %L)', :'cc1', '{"kind": "tag", "tag_type": "other", "name": "Secret", "dm_note": "x"}')) = '42501');
select tl_test.as_user(:'bob');
select tl_test.rec('LK12 an outsider reads nothing', tl_test.cc_code(format('select public.get_character_conditions(%L)', :'cc1')) = '42501'
  and (select count(*) from public.character_conditions where character_id = :'cc1') = 0);
select tl_test.as_root();
select tl_test.rec('LK13 Realtime: character_conditions and its secrets are not published (DELETE events are not RLS-filtered); revisions are',
  not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename in ('character_conditions', 'character_condition_secrets'))
  and exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'character_revisions'));
select tl_test.rec('LK14 anon cannot call the new RPCs; internal helpers are not callable by API roles',
  not has_function_privilege('anon', 'public.apply_character_effect(uuid, jsonb)', 'execute')
  and not has_function_privilege('anon', 'public.update_character_effect(uuid, jsonb)', 'execute')
  and not has_function_privilege('authenticated', 'public._conditions_visible(uuid)', 'execute')
  and not has_function_privilege('authenticated', 'public._condition_insert(uuid, jsonb, text, int)', 'execute')
  and not has_function_privilege('authenticated', 'public._combat_carry_spec(uuid, text)', 'execute'));
-- hidden delete: still nothing; then a visible change: exactly one revision
select tl_test.as_user(:'dm');
select public.apply_character_effect(:'cc1', '{"kind": "condition", "condition_key": "blinded", "hidden": true}') as r \gset
select public.remove_character_condition(tl_test.cc_id(:'cc1', 'Blinded')) as r \gset
select tl_test.rec('LK15 a hidden delete writes no revision and leaves the characters row untouched',
  tl_test.cc_revs(:'cc1') = :revs0 and tl_test.cc_row(:'cc1') = :'row0');
select public.update_character_effect(tl_test.cc_id(:'cc1', 'Resistant to fire'), '{"note": "Potion (half drunk)"}') as r \gset
select tl_test.rec('LK16 a visible change (note only) writes exactly one revision row, the characters row stays (same names)',
  tl_test.cc_revs(:'cc1') = :revs0 + 1 and tl_test.cc_row(:'cc1') = :'row0');

-- ---- reveal / hide ---------------------------------------------------------------------------------------------------------
select tl_test.as_root();
select tl_test.cc_fresh(:'cc1');
select tl_test.cc_revs(:'cc1') as revs1 \gset
select tl_test.as_user(:'dm');
select public.update_character_effect(tl_test.cc_id(:'cc1', 'Cursed by the lich'), '{"hidden": false}') as r \gset
select tl_test.as_user(:'alice');
select public.get_character_conditions(:'cc1') as pv \gset
select tl_test.rec('CC7 revealed: the player sees the tag (note, no DM note), the mirror lists it, one revision',
  tl_test.cc_find(:'pv', 'Cursed by the lich') ->> 'note' = 'Whispers louder' and tl_test.cc_find(:'pv', 'Cursed by the lich') -> 'dm_note' = 'null'::jsonb
  and tl_test.cc_find(:'pv', 'Cursed by the lich') ->> 'tag_type' = 'curse' and tl_test.cc_mirror(:'cc1')::text like '%Cursed by the lich%'
  and tl_test.cc_revs(:'cc1') = :revs1 + 1);
select tl_test.as_user(:'dm');
select public.update_character_effect(tl_test.cc_id(:'cc1', 'Poisoned'), '{"hidden": true}') as r \gset
select tl_test.as_user(:'alice');
select tl_test.rec('CC8 hidden again by the DM: gone from the player''s RPC and from the mirror',
  tl_test.cc_find(public.get_character_conditions(:'cc1'), 'Poisoned') is null and tl_test.cc_mirror(:'cc1')::text not like '%Poisoned%');

-- ---- removal rights, player rows, validation -----------------------------------------------------------------------------------
select tl_test.rec('CC9 a player cannot remove or change a DM-applied row (42501)',
  tl_test.cc_code(format('select public.remove_character_condition(%L)', tl_test.cc_id(:'cc1', 'Resistant to fire'))) = '42501'
  and tl_test.cc_code(format('select public.update_character_effect(%L, %L)', tl_test.cc_id(:'cc1', 'Exhaustion'), '{"level": 1}')) = '42501'
  and tl_test.cc_code(format('select public.apply_character_effect(%L, %L)', :'cc1', '{"kind": "exhaustion", "level": 1}')) = '42501');
select public.apply_character_effect(:'cc2', '{"kind": "condition", "condition_key": "prone"}') as r \gset
select public.apply_character_effect(:'cc2', '{"kind": "exhaustion", "level": 1}') as r \gset
select public.apply_character_effect(:'cc2', '{"kind": "exhaustion", "level": 3}') as r \gset
select tl_test.rec('CC10 a player adds his own rows; a second Exhaustion sets the level of the one row',
  (tl_test.cc_find(:'r', 'Prone') ->> 'can_remove')::boolean and not (tl_test.cc_find(:'r', 'Prone') ->> 'dm_applied')::boolean
  and (select count(*) from jsonb_array_elements(:'r') x where x ->> 'kind' = 'exhaustion') = 1 and (tl_test.cc_find(:'r', 'Exhaustion') ->> 'level')::int = 3);
select tl_test.rec('CC11 a player changes and removes his own rows, but cannot hide them',
  tl_test.cc_code(format('select public.update_character_effect(%L, %L)', tl_test.cc_id(:'cc2', 'Exhaustion'), '{"level": 2}')) = 'ok'
  and tl_test.cc_code(format('select public.update_character_effect(%L, %L)', tl_test.cc_id(:'cc2', 'Prone'), '{"hidden": true}')) = '42501'
  and tl_test.cc_code(format('select public.remove_character_condition(%L)', tl_test.cc_id(:'cc2', 'Prone'))) = 'ok'
  and tl_test.cc_mirror(:'cc2') = '["Exhaustion 2"]', tl_test.cc_mirror(:'cc2')::text);
select tl_test.rec('CC12 validation: unknown condition, level 7, a damage type on a blessing, an unnamed free tag, an unknown kind (22023)',
  tl_test.cc_code(format('select public.apply_character_effect(%L, %L)', :'cc2', '{"kind": "condition", "condition_key": "sleepy"}')) = '22023'
  and tl_test.cc_code(format('select public.apply_character_effect(%L, %L)', :'cc2', '{"kind": "exhaustion", "level": 7}')) = '22023'
  and tl_test.cc_code(format('select public.apply_character_effect(%L, %L)', :'cc2', '{"kind": "tag", "tag_type": "blessing", "damage_type_id": "fire"}')) = '22023'
  and tl_test.cc_code(format('select public.apply_character_effect(%L, %L)', :'cc2', '{"kind": "tag", "tag_type": "other"}')) = '22023'
  and tl_test.cc_code(format('select public.apply_character_effect(%L, %L)', :'cc2', '{"kind": "buff"}')) = '22023');

-- ---- old clients: direct writes of characters.conditions -----------------------------------------------------------------------
select tl_test.as_user(:'alice');
update public.characters set conditions = '["Exhaustion 2", "Hexed", "Concentrating"]' where id = :'cc2';
select tl_test.rec('CC13 an old client adding entries: they become the player''s rows, the list stays the mirror',
  (select count(*) from public.character_conditions where character_id = :'cc2' and source = 'player' and name in ('Hexed', 'Concentrating')) = 2
  and tl_test.cc_mirror(:'cc2') = '["Exhaustion 2", "Hexed", "Concentrating"]', tl_test.cc_mirror(:'cc2')::text);
update public.characters set conditions = '["Exhaustion 2", "Concentrating"]' where id = :'cc2';
select tl_test.rec('CC14 an old client removing its own entry deletes that row', tl_test.cc_id(:'cc2', 'Hexed') is null
  and tl_test.cc_mirror(:'cc2') = '["Exhaustion 2", "Concentrating"]');
update public.characters set conditions = '[]' where id = :'cc1';
select tl_test.rec('CC15 an old client cannot remove DM rows (the list comes back) and never sees hidden ones',
  (select count(*) from public.character_conditions where character_id = :'cc1') = 3
  and tl_test.cc_mirror(:'cc1')::text like '%Resistant to fire%' and tl_test.cc_mirror(:'cc1')::text not like '%Poisoned%', tl_test.cc_mirror(:'cc1')::text);
select tl_test.as_root();
insert into public.characters (id, owner_id, name, campaign_id, level, hp_max, hp_current, conditions)
values (:'cc3', :'alice', 'Cond Import', :'camp', 1, 8, 8, '["Stunned", "Exhaustion 3", {"name": "Raging"}]');
select tl_test.rec('CC16 an imported character: its entries become rows, the stored list is kept verbatim',
  (select string_agg(kind || ':' || coalesce(condition_key, '') || ':' || coalesce(level::text, ''), ',' order by legacy_pos) from public.character_conditions where character_id = :'cc3')
    = 'condition:stunned:,exhaustion:exhaustion:3,tag::'
  and tl_test.cc_mirror(:'cc3') = '["Stunned", "Exhaustion 3", {"name": "Raging"}]' and public._conditions_visible(:'cc3') = tl_test.cc_mirror(:'cc3'));

-- ---- combat carry keeps the Exhaustion level --------------------------------------------------------------------------------------
select tl_test.as_user(:'dm');
select public.combat_create_encounter(:'camp', 'Cond fight') -> 'encounter' ->> 'id' as enc \gset
select public.combat_add_characters(:'enc', array[:'cc2']::uuid[]) as r \gset
select tl_test.as_root();
select id as pid from public.combat_participants where encounter_id = :'enc' and linked_character_id = :'cc2' \gset
select tl_test.as_user(:'dm');
select public.combat_set_initiative(:'enc', jsonb_build_array(jsonb_build_object('id', :'pid', 'initiative', 12))) as r \gset
select public.combat_start(:'enc') as r \gset
select public.combat_add_effect(:'enc', jsonb_build_object('effect_type', 'condition', 'condition_key', 'exhaustion', 'exhaustion_level', 4, 'target', :'pid')) -> 'effects' -> 0 ->> 'id' as ex_fx \gset
select public.combat_add_effect(:'enc', jsonb_build_object('effect_type', 'condition', 'condition_key', 'poisoned', 'target', :'pid', 'visibility', 'dm')) -> 'effects' -> 0 ->> 'id' as po_fx \gset
select public.combat_finish(:'enc', 'done', jsonb_build_object(:'ex_fx', 'carry', :'po_fx', 'carry'), true) as r \gset
select tl_test.as_root();
select tl_test.rec('CC17 combat carry: Exhaustion keeps its level (the one visible row now has level 4, from combat)',
  (select count(*) from public.character_conditions where character_id = :'cc2' and kind = 'exhaustion' and not hidden) = 1
  and (select level from public.character_conditions where character_id = :'cc2' and kind = 'exhaustion' and not hidden) = 4
  and tl_test.cc_mirror(:'cc2')::text like '%Exhaustion 4%', tl_test.cc_mirror(:'cc2')::text);
select tl_test.rec('CC18 combat carry: a DM-only Poisoned stays hidden, keeps its SRD key, and is DM/combat-owned',
  exists (select 1 from public.character_conditions where character_id = :'cc2' and condition_key = 'poisoned' and hidden and source = 'combat')
  and tl_test.cc_mirror(:'cc2')::text not like '%Poisoned%');
select tl_test.as_user(:'alice');
select tl_test.rec('CC19 the player sees the carried Exhaustion 4 (not removable by him) but not the hidden Poisoned',
  (tl_test.cc_find(public.get_character_conditions(:'cc2'), 'Exhaustion') ->> 'level')::int = 4
  and not (tl_test.cc_find(public.get_character_conditions(:'cc2'), 'Exhaustion') ->> 'can_remove')::boolean
  and public.get_character_conditions(:'cc2')::text not like '%oisoned%');

-- ---- display only: no derived value changes -----------------------------------------------------------------------------------
select tl_test.as_root();
select tl_test.cc_fresh(:'cc1');
select tl_test.as_user(:'dm');
select (public.get_character_derived_stats(:'cc1') - 'computed_at')::text as d0 \gset
select public.apply_character_effect(:'cc1', '{"kind": "condition", "condition_key": "restrained"}') as r \gset
select public.apply_character_effect(:'cc1', '{"kind": "exhaustion", "level": 5}') as r \gset
select tl_test.as_root();
select tl_test.cc_fresh(:'cc1');
select tl_test.as_user(:'dm');
select tl_test.rec('CC20 conditions are reminders only: derived stats (AC, speed, saves ...) are unchanged',
  (public.get_character_derived_stats(:'cc1') - 'computed_at')::text = :'d0');
