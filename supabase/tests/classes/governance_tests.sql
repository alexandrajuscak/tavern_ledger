-- =============================================================================
-- Campaign governance and change requests (20261019000100, 20261019000200; docs/DM_GOVERNANCE.md, APPROVAL_WORKFLOWS.md,
-- CHARACTER_LOCKS.md): presets, overrides, decisions, locks, initial setup, direct-write triggers, gated RPCs, content
-- creation, requests (create, draft tray, preview, return, resubmit, approve, reject, stale, edit and approve, apply
-- failure rollback, lock during apply, idempotency), audit, RLS of requests and private notes.
-- Runs inside the per-class harness (alice = player, bob = outsider, dm = DM of :camp).
-- =============================================================================
\set g1 f1900000-0000-0000-0000-000000000001
\set g2 f1900000-0000-0000-0000-000000000002
\set g3 f1900000-0000-0000-0000-000000000003
\set g4 f1900000-0000-0000-0000-000000000004
\set g5 f1900000-0000-0000-0000-000000000005
\set camp2 c1c00000-0000-0000-0000-000000000002
insert into public.campaigns (id, name, created_by) values (:'camp2', 'Other Campaign', :'bob');
insert into public.campaign_members (campaign_id, user_id, role) values (:'camp2', :'bob', 'dm');
insert into public.characters (id, owner_id, name, campaign_id, level, strength, dexterity, constitution, intelligence, wisdom, charisma, hp_max, hp_current) values
  (:'g1', :'alice', 'Gov Fighter', :'camp', 1, 15, 12, 14, 10, 10, 8, 12, 12),
  (:'g2', :'alice', 'Gov Free', null, 1, 10, 10, 10, 10, 10, 10, 8, 8),
  (:'g3', :'alice', 'Gov Newcomer', :'camp', 1, 10, 10, 10, 10, 10, 10, 8, 8),
  (:'g4', :'bob', 'Bob Elsewhere', :'camp2', 1, 10, 10, 10, 10, 10, 10, 8, 8),
  (:'g5', :'alice', 'Gov Locked', :'camp', 1, 10, 10, 10, 10, 10, 10, 8, 8);
insert into public.inventories (kind, character_id, name) select 'character', id, 'Inventory' from public.characters
  where id in (:'g1', :'g3', :'g5') and not exists (select 1 from public.inventories i where i.character_id = public.characters.id);
-- set up before governance applies: fighter 1 (still "relaxed": no settings row yet)
select tl_test.as_user(:'alice');
select public.set_character_class(:'g1', 'fighter-phb', 1, null, true);
select public.set_character_class(:'g5', 'fighter-phb', 1, null, true);
select tl_test.as_root();
insert into public.character_governance (character_id, setup_complete) values (:'g1', true), (:'g5', true);

create function tl_test.code(p_sql text) returns text language plpgsql as $$
begin execute p_sql; return 'ok'; exception when others then return sqlstate; end $$;
create function tl_test.dec(p_camp uuid, p_action text) returns text language sql security definer as $$ select public._gov_policy(p_camp, p_action) $$;
create function tl_test.gjson(p_camp uuid) returns jsonb language sql security definer as $$ select public._campaign_governance_json(p_camp) $$;
create function tl_test.lvl(p_char uuid) returns int language sql as $$
  select coalesce(sum(level), 0)::int from public.character_classes where character_id = p_char $$;
grant all on all functions in schema tl_test to public;

-- ---- presets and policy ------------------------------------------------------------------------------------------------
select tl_test.rec('G1 a campaign without settings resolves as relaxed and reports "not configured"',
  tl_test.dec(:'camp', 'build.class_level') = 'player_managed' and tl_test.dec(:'camp', 'content.create_spell') = 'dm_only'
  and (tl_test.gjson(:'camp') ->> 'configured')::boolean = false);
select tl_test.rec('G2 pre-existing campaigns got an explicit relaxed row and a report row',
  not exists (select 1 from public.campaign_governance g where g.migrated_from = 'pre_governance'
              and (g.preset <> 'relaxed' or not exists (select 1 from public.governance_migration_report r where r.campaign_id = g.campaign_id))));
select tl_test.as_user(:'alice');
select tl_test.rec('G3 a player cannot change the campaign rules',
  tl_test.code(format('select public.set_campaign_governance(%L, %L)', :'camp', '{"preset": "relaxed"}')) = '42501');
select tl_test.as_user(:'dm');
select public.set_campaign_governance(:'camp', '{"preset": "standard"}');
select tl_test.rec('G4 standard preset: progression needs approval, runtime is player-managed, content is DM-only',
  tl_test.dec(:'camp', 'build.class_level') = 'approval_required' and tl_test.dec(:'camp', 'runtime.hp') = 'player_managed'
  and tl_test.dec(:'camp', 'spell.prepare') = 'player_managed' and tl_test.dec(:'camp', 'content.create_item') = 'dm_only'
  and tl_test.dec(:'camp', 'runtime.long_rest') = 'approval_required');
select tl_test.rec('G5 strict preset: mundane items need approval too',
  (select tl_test.dec(:'camp', 'inventory.add_mundane') from (select public.set_campaign_governance(:'camp', '{"preset": "strict"}')) x) = 'approval_required');
select public.set_campaign_governance(:'camp', '{"preset": "standard", "overrides": {"runtime.long_rest": "player_managed"}}');
select tl_test.rec('G6 a single override turns the preset into custom on the standard base',
  (select preset from public.campaign_governance where campaign_id = :'camp') = 'custom'
  and tl_test.dec(:'camp', 'runtime.long_rest') = 'player_managed' and tl_test.dec(:'camp', 'build.class_level') = 'approval_required');
select tl_test.rec('G7 an override cannot give players more than the action allows (content creation stays DM-only)',
  tl_test.code(format('select public.set_campaign_governance(%L, %L)', :'camp', '{"overrides": {"content.create_spell": "player_managed"}}')) = '22023'
  and tl_test.code(format('select public.set_campaign_governance(%L, %L)', :'camp', '{"overrides": {"dm.hidden_data": "approval_required"}}')) = '22023');
select tl_test.rec('G8 a stale revision is refused (two DMs editing the rules)',
  tl_test.code(format('select public.set_campaign_governance(%L, %L, 1)', :'camp', '{"preset": "standard"}')) = '40001');
select tl_test.rec('G9 the rules change is audited',
  exists (select 1 from public.campaign_audit_events where campaign_id = :'camp' and event_type = 'governance_changed'));

-- ---- decisions on the sheet ----------------------------------------------------------------------------------------------
select tl_test.as_user(:'alice');
select tl_test.code(format('update public.characters set hp_current = 9, conditions = %L where id = %L', '["Prone"]', :'g1')) as g10 \gset
select tl_test.rec('G10 player-managed: current HP and conditions change at once',
  :'g10' = 'ok' and (select hp_current from public.characters where id = :'g1') = 9);
select tl_test.rec('G11 approval-required: a direct ability or max-HP write is refused with TLAPR',
  tl_test.code(format('update public.characters set strength = 16 where id = %L', :'g1')) = 'TLAPR'
  and tl_test.code(format('update public.characters set hp_max = 30 where id = %L', :'g1')) = 'TLAPR');
select tl_test.rec('G12 approval-required: the class-level RPC is refused with TLAPR',
  tl_test.code(format('select public.set_character_class(%L, %L, 2)', :'g1', 'fighter-phb')) = 'TLAPR' and tl_test.lvl(:'g1') = 1);
select tl_test.rec('G13 DM-only: moving the character out of the campaign is refused',
  tl_test.code(format('update public.characters set campaign_id = null where id = %L', :'g1')) = 'TLDMO');
select tl_test.rec('G14 the sheet read model shows the decisions',
  (public.get_character_governance(:'g1') -> 'decisions' ->> 'build.class_level') = 'approval_required'
  and (public.get_character_governance(:'g1') -> 'decisions' ->> 'runtime.hp') = 'player_managed'
  and (public.get_character_governance(:'g1') ->> 'is_dm')::boolean = false);
select tl_test.rec('G15 a character without a campaign is not governed',
  tl_test.code(format('update public.characters set strength = 14, hp_max = 20 where id = %L', :'g2')) = 'ok');
select tl_test.rec('G16 initial setup: a new character may be built freely until the DM marks the setup complete',
  tl_test.code(format('select public.set_character_class(%L, %L, 2, null, true)', :'g3', 'fighter-phb')) = 'ok'
  and tl_test.code(format('update public.characters set strength = 15 where id = %L', :'g3')) = 'ok'
  and (public.get_character_governance(:'g3') -> 'decisions' ->> 'build.class_level') = 'player_managed');
select tl_test.rec('G16b content policy: a playtest feat is refused for the player (TLDIS) and marked in the picker; official is fine',
  tl_test.code(format('select public.assign_character_feat(%L, %L)', :'g3', 'acrobat-2014')) = 'TLDIS'
  and (select f ->> 'policy_reason' from jsonb_array_elements(public.get_feat_catalog(:'g3')) f where f ->> 'id' = 'acrobat-2014') like '%Playtest%'
  and (select f ->> 'policy_reason' from jsonb_array_elements(public.get_feat_catalog(:'g3')) f where f ->> 'id' = 'alert-2024') is null);
select tl_test.as_user(:'dm');
select public.set_character_setup_complete(:'g3', true);
select tl_test.as_user(:'alice');
select tl_test.rec('G17 after setup the same change needs approval',
  tl_test.code(format('select public.set_character_class(%L, %L, 3)', :'g3', 'fighter-phb')) = 'TLAPR');
select tl_test.rec('G18 content creation: a player cannot create a homebrew (mechanical) item',
  tl_test.code(format('select public.create_homebrew_item(gen_random_uuid(), %L)',
    jsonb_build_object('name', 'Player Blade', 'kind_id', 'gear', 'campaign_id', :'camp'))) = 'TLDMO'
  and tl_test.code(format('select public.create_homebrew_item(gen_random_uuid(), %L)', '{"name": "Private Blade", "kind_id": "gear"}')) = 'TLDMO');
select tl_test.as_user(:'dm');
select tl_test.rec('G19 the campaign DM may create campaign content and change the character directly',
  tl_test.code(format('select public.create_homebrew_item(gen_random_uuid(), %L)',
    jsonb_build_object('name', 'DM Blade', 'kind_id', 'gear', 'campaign_id', :'camp'))) = 'ok'
  and tl_test.code(format('update public.characters set strength = 16 where id = %L', :'g1')) = 'ok');
select tl_test.as_root(); update public.characters set strength = 15 where id = :'g1';

select tl_test.as_user(:'alice');
select tl_test.code(format('update public.notes set content = %L where character_id = %L and kind = %L', 'Diary', :'g1', 'character')) as g26a \gset
select tl_test.code(format('update public.spell_slots set used = 0 where character_id = %L and level = 1', :'g1')) as g26b \gset
select tl_test.code(format('insert into public.features (character_id, name) values (%L, %L)', :'g1', 'Scar')) as g26c \gset
select tl_test.code(format('insert into public.attacks (character_id, name) values (%L, %L)', :'g1', 'Knife')) as g26d \gset
select tl_test.rec('G19b direct writes to the legacy child tables follow their action (notes, slot use: free; a custom attack: approval)',
  :'g26a' = 'ok' and :'g26b' = 'ok' and :'g26c' = 'ok' and :'g26d' = 'TLAPR');
select tl_test.as_root();

-- ---- locks -----------------------------------------------------------------------------------------------------------------
select tl_test.as_user(:'alice');
select tl_test.rec('G20 a player cannot lock a character', tl_test.code(format('select public.set_character_lock(%L, %L)', :'g5', 'unlocked')) = '42501');
select tl_test.as_user(:'dm');
select public.set_character_lock(:'g5', 'progression_locked', 'Between sessions');
select tl_test.as_user(:'alice');
select tl_test.rec('G21 progression lock: level refused (TLLCK, with the reason), HP still works',
  tl_test.code(format('select public.set_character_class(%L, %L, 2)', :'g5', 'fighter-phb')) = 'TLLCK'
  and tl_test.raises(format('select public.set_character_class(%L, %L, 2)', :'g5', 'fighter-phb')) like '%Between sessions%'
  and tl_test.code(format('update public.characters set hp_current = 7 where id = %L', :'g5')) = 'ok');
select tl_test.as_user(:'dm'); select public.set_character_lock(:'g5', 'build_locked'); select tl_test.as_user(:'alice');
select tl_test.rec('G22 build lock: manual stats refused, equip / HP still allowed',
  tl_test.code(format('update public.characters set speed = 35 where id = %L', :'g5')) = 'TLLCK'
  and tl_test.code(format('update public.characters set hp_temp = 2 where id = %L', :'g5')) = 'ok');
select tl_test.as_user(:'dm'); select public.set_character_lock(:'g5', 'fully_locked'); select tl_test.as_user(:'alice');
select tl_test.rec('G23 full lock: even runtime changes are DM-only; reading still works',
  tl_test.code(format('update public.characters set hp_current = 5 where id = %L', :'g5')) = 'TLLCK'
  and (public.get_character_governance(:'g5') ->> 'lock_mode') = 'fully_locked'
  and tl_test.code(format('select public.get_character_derived_stats(%L)', :'g5')) = 'ok');
select tl_test.as_user(:'dm');
select tl_test.rec('G24 a DM may still correct a fully locked character',
  tl_test.code(format('update public.characters set hp_current = 6 where id = %L', :'g5')) = 'ok');
select public.set_character_lock(:'g5', 'archived');
select tl_test.rec('G25 archived: read-only for everyone, the DM can restore it',
  tl_test.code(format('update public.characters set hp_current = 5 where id = %L', :'g5')) = 'TLLCK'
  and tl_test.code(format('select public.set_character_lock(%L, %L)', :'g5', 'unlocked')) = 'ok'
  and tl_test.code(format('update public.characters set hp_current = 5 where id = %L', :'g5')) = 'ok');
select tl_test.rec('G26 lock changes are audited', (select count(*) from public.campaign_audit_events where character_id = :'g5' and event_type = 'character_lock_changed') = 5);

-- ---- change requests ------------------------------------------------------------------------------------------------------
select tl_test.as_user(:'alice');
select (public.create_change_request(:'g1', '[{"op": "set_character_class", "args": {"p_class_version": "fighter-phb", "p_level": 2}}]'::jsonb,
                                     'Fighter 2', 'Reached level 2', null, true, 'a0000000-0000-0000-0000-000000000001') ->> 'id') as r1 \gset
select tl_test.rec('A1 a player creates a request for their own character: submitted, with a structured diff',
  (select status from public.change_requests where id = :'r1') = 'submitted' and tl_test.lvl(:'g1') = 1
  and exists (select 1 from jsonb_array_elements((select preview -> 'diff' from public.change_requests where id = :'r1')) d
              where d ->> 'label' = 'Total level' and (d ->> 'before')::int = 1 and (d ->> 'after')::int = 2));
select tl_test.rec('A2 the same idempotency key returns the same request',
  (public.create_change_request(:'g1', '[{"op": "set_character_class", "args": {"p_class_version": "fighter-phb", "p_level": 2}}]'::jsonb,
     null, null, null, true, 'a0000000-0000-0000-0000-000000000001') ->> 'id') = :'r1'
  and (select count(*) from public.change_requests where character_id = :'g1') = 1);
select tl_test.rec('A3 a request for an unrelated character is refused',
  tl_test.code(format('select public.create_change_request(%L, %L)', :'g4', '[{"op": "long_rest_character"}]')) = '42501');
select tl_test.rec('A4 unknown ops and arguments are refused (no free-form changes)',
  tl_test.code(format('select public.create_change_request(%L, %L)', :'g1', '[{"op": "drop_table"}]')) = '22023'
  and tl_test.code(format('select public.create_change_request(%L, %L)', :'g1', '[{"op": "set_character_class", "args": {"p_class_version": "fighter-phb", "p_level": 2, "owner_id": "x"}}]')) = '22023');
select tl_test.rec('A5 a player cannot write requests directly or approve their own',
  tl_test.code(format('insert into public.change_requests (campaign_id, character_id, requested_by, category, action_type, title) values (%L, %L, %L, %L, %L, %L)',
                      :'camp', :'g1', :'alice', 'core_build', 'build.class_level', 'x')) = '42501'
  and tl_test.code(format('select public.review_change_request(%L, %L)', :'r1', 'approve')) = '42501');
select tl_test.rec('A6 the player preview does not change the character',
  (public.preview_change_request(:'r1') -> 'preview' ->> 'ok')::boolean and tl_test.lvl(:'g1') = 1);
select tl_test.as_user(:'bob');
select tl_test.rec('A7 a DM of another campaign cannot read or review it',
  tl_test.code(format('select public.review_change_request(%L, %L)', :'r1', 'approve')) = '42501'
  and (select count(*) from public.change_requests where id = :'r1') = 0);
select tl_test.as_user(:'dm');
select tl_test.rec('A8 the campaign DM sees it in the inbox',
  exists (select 1 from jsonb_array_elements(public.get_campaign_change_requests(:'camp')) x where x ->> 'id' = :'r1'));
select tl_test.rec('A9 return needs a note', tl_test.code(format('select public.review_change_request(%L, %L)', :'r1', 'return')) = '22023');
select public.review_change_request(:'r1', 'return', 'Take level 2 after the next session', null, null, 'Secret: they owe me');
select tl_test.as_user(:'alice');
select tl_test.rec('A10 returned: the player sees the note but never the private DM note',
  (select status from public.change_requests where id = :'r1') = 'returned_for_changes'
  and (select x ->> 'review_note' from jsonb_array_elements(public.get_character_change_requests(:'g1')) x where x ->> 'id' = :'r1') like 'Take level 2%'
  and (select x ->> 'private_note' from jsonb_array_elements(public.get_character_change_requests(:'g1')) x where x ->> 'id' = :'r1') is null
  and (select count(*) from public.change_request_private_notes) = 0);
select public.update_change_request(:'r1', null, 'Fighter 2 (after session)', 'Revised');
select public.submit_change_request(:'r1');
select tl_test.rec('A11 the player revises and resubmits', (select status from public.change_requests where id = :'r1') = 'submitted'
  and exists (select 1 from public.change_request_events where request_id = :'r1' and event = 'resubmitted'));
select tl_test.as_user(:'dm');
select public.review_change_request(:'r1', 'approve');
select tl_test.rec('A12 approved: the change is applied through the class RPC',
  (select status from public.change_requests where id = :'r1') = 'applied' and tl_test.lvl(:'g1') = 2);
select tl_test.rec('A13 a second approval (another DM, a double click) is refused',
  tl_test.code(format('select public.review_change_request(%L, %L)', :'r1', 'approve')) = 'TLRVW' and tl_test.lvl(:'g1') = 2);
select tl_test.as_user(:'alice');
select tl_test.rec('A14 an applied request cannot be edited by the player',
  tl_test.code(format('select public.update_change_request(%L, null, %L)', :'r1', 'x')) = '22023');
-- rejected request
select (public.create_change_request(:'g1', '[{"op": "update_character_build", "args": {"p_patch": {"strength": 18}}}]'::jsonb, 'Strength 18') ->> 'id') as r2 \gset
select tl_test.as_user(:'dm');
select public.review_change_request(:'r2', 'reject', 'Not without a reason in the story');
select tl_test.rec('A15 rejected: nothing changes and it cannot be applied',
  (select strength from public.characters where id = :'g1') = 15
  and tl_test.code(format('select public.retry_change_request(%L)', :'r2')) = 'TLRVW');
-- stale request
select tl_test.as_user(:'alice');
select (public.create_change_request(:'g1', '[{"op": "set_character_class", "args": {"p_class_version": "fighter-phb", "p_level": 3}}]'::jsonb) ->> 'id') as r3 \gset
select tl_test.as_user(:'dm');
select public.set_character_class(:'g1', 'fighter-phb', 3);    -- a direct DM correction meanwhile
select public.review_change_request(:'r3', 'approve') ->> 'refused' as a16 \gset
select tl_test.rec('A16 stale: the approval is refused and the changed assumptions are shown',
  :'a16' = 'stale'
  and (select stale from public.change_requests where id = :'r3')
  and (select status from public.change_requests where id = :'r3') = 'submitted'
  and jsonb_array_length(public.preview_change_request(:'r3') -> 'changed_assumptions') >= 1);
select public.refresh_change_request(:'r3');
select tl_test.rec('A17 after a refresh the DM may approve the (now empty) change',
  (public.review_change_request(:'r3', 'approve') ->> 'status') = 'applied' and tl_test.lvl(:'g1') = 3);
-- multi-step level-up: level 4 + the ASI of level 4 in one request ($class reference)
select tl_test.as_user(:'alice');
select (public.create_change_request(:'g1', jsonb_build_array(
  jsonb_build_object('op', 'set_character_class', 'args', jsonb_build_object('p_class_version', 'fighter-phb', 'p_level', 4)),
  jsonb_build_object('op', 'set_character_feature_choice', 'args', jsonb_build_object('p_character_class', '$class:fighter',
    'p_unlock', 'fighter-phb-u4-asi', 'p_choice', 'fighter-asi-phb-asi', 'p_values', jsonb_build_array('str:1', 'con:1')))),
  'Fighter 4 with ASI') ->> 'id') as r4 \gset
select tl_test.rec('A18 one coherent level-up request (level + ASI) previews both changes',
  (select status from public.change_requests where id = :'r4') = 'submitted'
  and exists (select 1 from jsonb_array_elements((select preview -> 'diff' from public.change_requests where id = :'r4')) d where d ->> 'label' = 'STR')
  and exists (select 1 from jsonb_array_elements((select preview -> 'diff' from public.change_requests where id = :'r4')) d where d ->> 'label' = 'Total level'));
select tl_test.as_user(:'dm');
-- edit and approve with a broken second step: the whole application is rolled back
select tl_test.rec('A19 edit and approve needs a note',
  tl_test.code(format('select public.review_change_request(%L, %L, null, null, %L)', :'r4', 'approve',
    '[{"op": "long_rest_character"}]')) = '22023');
select public.review_change_request(:'r4', 'approve', 'Corrected', null, jsonb_build_array(
  jsonb_build_object('op', 'set_character_class', 'args', jsonb_build_object('p_class_version', 'fighter-phb', 'p_level', 4)),
  jsonb_build_object('op', 'set_character_feature_choice', 'args', jsonb_build_object('p_character_class', '$class:fighter',
    'p_unlock', 'fighter-phb-u4-asi', 'p_choice', 'fighter-asi-phb-asi', 'p_values', jsonb_build_array('str:9')))));
select tl_test.rec('A20 a failing step marks apply_failed and rolls back every step (no partial level-up)',
  (select status from public.change_requests where id = :'r4') = 'apply_failed' and tl_test.lvl(:'g1') = 3
  and (select apply_error from public.change_requests where id = :'r4') like 'Step 2:%');
select tl_test.as_root();
update public.change_requests set approved_ops = null where id = :'r4';
select tl_test.as_user(:'dm');
select public.retry_change_request(:'r4');
select tl_test.rec('A21 after the correction the DM retries and it applies atomically',
  (select status from public.change_requests where id = :'r4') = 'applied' and tl_test.lvl(:'g1') = 4
  and (public.get_character_derived_stats(:'g1') -> 'abilities' -> 'str' ->> 'score')::int = 16);
select tl_test.rec('A22 the audit timeline holds the request steps and the level change, linked to the request',
  (select count(*) from public.campaign_audit_events where request_id = :'r4' and event_type in ('request_submitted', 'request_approved', 'request_applied', 'request_apply_failed')) >= 4
  and exists (select 1 from public.campaign_audit_events where request_id = :'r4' and event_type = 'level_changed'));
-- draft tray + lock during apply
select tl_test.as_user(:'alice');
select public.add_change_request_op(:'g1', '{"op": "update_character_build", "args": {"p_patch": {"hp_max": 40}}}');
select (public.add_change_request_op(:'g1', '{"op": "set_seen_forms", "args": {"p_creatures": ["wolf"]}}') ->> 'id') as r5 \gset
select tl_test.rec('A23 the draft tray collects several changes into one request',
  (select jsonb_array_length(ops) from public.change_requests where id = :'r5') = 2
  and (select status from public.change_requests where id = :'r5') = 'draft');
select public.update_change_request(:'r5', '[{"op": "update_character_build", "args": {"p_patch": {"hp_max": 40}}}]');
select public.submit_change_request(:'r5');
select tl_test.as_user(:'dm');
select public.set_character_lock(:'g1', 'build_locked');
select public.review_change_request(:'r5', 'approve');
select tl_test.rec('A24 a request approved under a lock fails safely (unlock first)',
  (select status from public.change_requests where id = :'r5') = 'apply_failed' and (select hp_max from public.characters where id = :'g1') <> 40);
select public.set_character_lock(:'g1', 'unlocked');
select public.retry_change_request(:'r5');
select tl_test.rec('A25 after unlocking the retry applies', (select hp_max from public.characters where id = :'g1') = 40);
select tl_test.as_user(:'alice');
select tl_test.rec('A26 an approval-required manual value can be requested',
  (select tl_test.code(format('select public.create_change_request(%L, %L)', :'g1', '[{"op": "update_character_build", "args": {"p_patch": {"speed": 35}}}]'))) = 'ok');
select tl_test.as_user(:'dm');
select public.set_campaign_governance(:'camp', '{"overrides": {"build.manual_stats": "disabled"}}');
select tl_test.as_user(:'alice');
select tl_test.rec('A27 once the DM disables the action, a new request is refused at submit',
  tl_test.raises(format('select public.create_change_request(%L, %L)', :'g1', '[{"op": "update_character_build", "args": {"p_patch": {"speed": 40}}}]')) like '%turned off%');
select tl_test.rec('A28 the player can cancel a pending request',
  (select public.cancel_change_request(id) ->> 'status' from public.change_requests where character_id = :'g1' and status = 'submitted' limit 1) = 'cancelled');
select tl_test.rec('A29 the player audit view shows own characters only and no DM-only events',
  not exists (select 1 from jsonb_array_elements(public.get_campaign_audit(:'camp')) e where e ->> 'visibility' is not null)
  and not exists (select 1 from public.campaign_audit_events where visibility = 'dm'));
select tl_test.as_user(:'alice');
select tl_test.rec('A30 update_character_build is governed like the direct write',
  tl_test.code(format('select public.update_character_build(%L, %L)', :'g1', '{"strength": 17}')) = 'TLAPR'
  and tl_test.code(format('select public.update_character_build(%L, %L)', :'g2', '{"strength": 17}')) = 'ok');
-- the one-draft rule is checked at commit (deferred): "Ask your DM" (create + submit) works while a tray draft exists
select public.add_change_request_op(:'g1', '{"op": "set_character_class", "args": {"p_class_version": "fighter-phb", "p_level": 2}}');
select tl_test.rec('A31 a request can be sent while the player has a draft in the pending tray',
  tl_test.code(format('select public.create_change_request(%L, %L); set constraints public.change_requests_one_draft immediate', :'g1',
                      '[{"op": "set_character_class", "args": {"p_class_version": "fighter-phb", "p_level": 3}}]')) = 'ok');
select tl_test.rec('A32 ... but a second draft is still refused',
  tl_test.code(format('select public.create_change_request(%L, %L, p_submit => false); set constraints public.change_requests_one_draft immediate', :'g1',
                      '[{"op": "set_character_class", "args": {"p_class_version": "fighter-phb", "p_level": 3}}]')) = '23P01');
set constraints public.change_requests_one_draft deferred;
select tl_test.as_root();
