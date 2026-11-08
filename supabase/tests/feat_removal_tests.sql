-- Tests of feat removal (20261107000100_feat_removal.sql; docs/FEAT_REMOVAL.md). LOCAL ONLY; run as supabase_admin;
-- everything happens in one transaction that is rolled back (synthetic users, campaigns, characters).
-- Usage: docker exec -i supabase_db_tavern_ledger psql -U supabase_admin -d postgres -qAt -v ON_ERROR_STOP=1 < supabase/tests/feat_removal_tests.sql
-- Prints failed checks and a TOTAL line. Concurrent sessions: supabase/tests/feat_removal_concurrency_test.sh.
begin;
create temp table fr (n serial, chk text, ok boolean, detail text) on commit drop;
grant all on fr to authenticated, anon;
grant all on sequence fr_n_seq to authenticated, anon;
create temp table fx (k text primary key, v text) on commit drop;
grant all on fx to authenticated, anon;

create or replace function pg_temp.as_user(u uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
end $$;
create or replace function pg_temp.as_admin() returns void language plpgsql as $$
begin
  execute 'reset role';
  perform set_config('request.jwt.claims', '', true);
end $$;
create or replace function pg_temp.ok(c text, b boolean, d text default '') returns void language sql as $$
  insert into fr (chk, ok, detail) values (c, coalesce(b, false), coalesce(d, ''));
$$;
-- run a statement, return 'ok' or 'SQLSTATE|hint|message'
create or replace function pg_temp.try(q text) returns text language plpgsql as $$
declare h text;
begin
  execute q;
  return 'ok';
exception when others then
  get stacked diagnostics h = pg_exception_hint;
  return sqlstate || '|' || coalesce(h, '') || '|' || sqlerrm;
end $$;
create or replace function pg_temp.fu(k text) returns uuid language sql as $$ select v::uuid from fx where fx.k = $1 $$;
create or replace function pg_temp.put(k text, v text) returns void language sql as $$
  insert into fx values (k, v) on conflict (k) do update set v = excluded.v;
$$;
create or replace function pg_temp.cf(ch uuid, feat text) returns uuid language sql as $$
  select id from public.character_feats where character_id = ch and feat_version_id = feat limit 1;
$$;
create or replace function pg_temp.assign(ch uuid, feat text, choices jsonb default '{}') returns uuid language plpgsql as $$
begin
  perform public.assign_character_feat(ch, feat, choices, 'direct', null, null, null);
  return pg_temp.cf(ch, feat);
end $$;
create or replace function pg_temp.score(ch uuid, k text) returns int language sql as $$
  select (public._derived_stats_full(ch) -> 'abilities' -> k ->> 'score')::int;
$$;
create or replace function pg_temp.maxhp(ch uuid) returns int language sql as $$ select (public._feat_hp_bonus(ch) ->> 'max')::int $$;
create or replace function pg_temp.audits(ch uuid) returns int language sql as $$
  select count(*)::int from public.campaign_audit_events where character_id = ch and event_type = 'feat_removed';
$$;
create or replace function pg_temp.revs(ch uuid) returns int language sql as $$ select count(*)::int from public.character_revisions where character_id = ch $$;

-- ------------------------------------------------------------------------------------------------------------- fixtures
do $$
declare dm uuid := gen_random_uuid(); pl uuid := gen_random_uuid(); other uuid := gen_random_uuid();
  relaxed uuid := gen_random_uuid(); standard uuid := gen_random_uuid(); k text; ch uuid;
begin
  insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at) values
    (dm, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'fr-dm-' || dm || '@example.test', now(), now()),
    (pl, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'fr-pl-' || pl || '@example.test', now(), now()),
    (other, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'fr-ot-' || other || '@example.test', now(), now());
  insert into public.campaigns (id, name, created_by) values (relaxed, 'FR Relaxed Table', dm), (standard, 'FR Secret Standard Table', dm);
  insert into public.campaign_members (campaign_id, user_id, role) values (relaxed, dm, 'dm'), (relaxed, pl, 'player'), (standard, dm, 'dm'), (standard, pl, 'player');
  insert into public.campaign_governance (campaign_id, preset) values (relaxed, 'relaxed'), (standard, 'standard');
  perform pg_temp.put('dm', dm::text); perform pg_temp.put('pl', pl::text); perform pg_temp.put('other', other::text);
  perform pg_temp.put('relaxed', relaxed::text); perform pg_temp.put('standard', standard::text);
  -- solo (no campaign), relaxed campaign, standard campaign (feats need approval), other player's character
  foreach k in array array['solo', 'rel', 'std', 'mi', 'tough', 'res', 'src', 'lock', 'oth'] loop
    insert into public.characters (owner_id, name, level, hp_max, hp_current, strength, dexterity, constitution, intelligence, wisdom, charisma)
    values (case when k = 'oth' then other else pl end, 'FR ' || k, 1, 40, 40, 15, 14, 14, 10, 12, 10) returning id into ch;
    perform pg_temp.put(k, ch::text);
    perform pg_temp.as_user(case when k = 'oth' then other else pl end);
    perform public.set_character_class(ch, case when k = 'mi' then 'wizard-phb' else 'fighter-phb' end, 4, null);
    perform pg_temp.as_admin();
  end loop;
  update public.characters set campaign_id = relaxed where id in (pg_temp.fu('rel'), pg_temp.fu('lock'));
  update public.characters set campaign_id = standard where id = pg_temp.fu('std');
  insert into public.character_governance (character_id, setup_complete) values (pg_temp.fu('rel'), true), (pg_temp.fu('std'), true), (pg_temp.fu('lock'), true);
end $$;

-- ============================================================================================ 1. direct removal + authorization
do $$
declare pl uuid := pg_temp.fu('pl'); dm uuid := pg_temp.fu('dm'); other uuid := pg_temp.fu('other'); f uuid; r text; j jsonb; n int;
begin
  perform pg_temp.as_user(pl);
  f := pg_temp.assign(pg_temp.fu('solo'), 'alert-2014');
  perform pg_temp.ok('F1 a directly assigned feat exists', f is not null);
  j := public.remove_character_feat(f, null);
  perform pg_temp.ok('F2 owner removes it (no campaign)', pg_temp.cf(pg_temp.fu('solo'), 'alert-2014') is null and j ? 'feats');
  -- relaxed campaign: owner and DM
  f := pg_temp.assign(pg_temp.fu('rel'), 'alert-2014');
  r := pg_temp.try(format('select public.remove_character_feat(%L, null)', f));
  perform pg_temp.ok('F2b owner removes it under relaxed governance', r = 'ok', r);
  f := pg_temp.assign(pg_temp.fu('rel'), 'tough-2014');
  perform pg_temp.as_user(dm);
  r := pg_temp.try(format('select public.remove_character_feat(%L, %L)', f, 'DM cleanup'));
  perform pg_temp.ok('F3 campaign DM removes a player''s feat', r = 'ok' and pg_temp.cf(pg_temp.fu('rel'), 'tough-2014') is null, r);
  perform pg_temp.as_admin();
  perform pg_temp.ok('F30 the removal is audited once with the reason, readable by the DM',
    (select count(*) from public.campaign_audit_events where character_id = pg_temp.fu('rel') and event_type = 'feat_removed' and reason = 'DM cleanup') = 1);
  -- standard campaign: the player's removal needs approval; nothing changes
  perform pg_temp.as_user(dm);
  f := pg_temp.assign(pg_temp.fu('std'), 'alert-2014');
  perform pg_temp.as_user(pl);
  r := pg_temp.try(format('select public.remove_character_feat(%L, null)', f));
  perform pg_temp.ok('F4 approval-required: the player gets TLAPR (sent as a request by the UI)', r like 'TLAPR|request|%', r);
  perform pg_temp.ok('F4b ... and the feat stays', pg_temp.cf(pg_temp.fu('std'), 'alert-2014') = f);
  j := public.preview_character_feat_removal(f);
  perform pg_temp.ok('P3 preview under approval: decision approval_required, consequences shown',
    j ->> 'decision' = 'approval_required' and (j ->> 'ok')::boolean and j -> 'diff' @> '[{"label": "Initiative bonus"}]', left(j::text, 300));
  perform pg_temp.as_user(dm);
  r := pg_temp.try(format('select public.remove_character_feat(%L, null)', f));
  perform pg_temp.ok('F4c the DM of that campaign removes it directly', r = 'ok', r);
  -- unrelated player, other character, anonymous
  perform pg_temp.as_user(other);
  f := pg_temp.assign(pg_temp.fu('oth'), 'alert-2014');
  perform pg_temp.as_user(dm);
  f := pg_temp.assign(pg_temp.fu('std'), 'alert-2014');
  perform pg_temp.as_user(other);
  r := pg_temp.try(format('select public.remove_character_feat(%L, null)', f));
  perform pg_temp.ok('F5 an unrelated player is refused with the not-found answer', r like 'P0002|feat_absent|%', r);
  perform pg_temp.ok('F5b ... which never names the campaign', r not like '%Secret Standard%', r);
  r := pg_temp.try(format('select public.preview_character_feat_removal(%L)', f));
  perform pg_temp.ok('F5c ... the preview too', r like 'P0002|feat_absent|%' and r not like '%Secret%', r);
  r := pg_temp.try(format('select public.set_character_feat_choices(%L, %L, %L::jsonb)', pg_temp.fu('std'), 'cf:' || f, '{}'));
  perform pg_temp.ok('F5d choices of a feat on someone else''s character: "Character not found", never the campaign rule',
    r like '42501|%Character not found%' and r not like '%Secret%', r);
  perform pg_temp.as_user(pl);
  r := pg_temp.try(format('select public.remove_character_feat(%L, null)', pg_temp.cf(pg_temp.fu('oth'), 'alert-2014')));
  perform pg_temp.as_admin();
  perform pg_temp.ok('F7 a player cannot remove a feat of another player''s character', r like 'P0002|feat_absent|%'
    and pg_temp.cf(pg_temp.fu('oth'), 'alert-2014') is not null, r);
  perform pg_temp.ok('F6 anonymous users cannot execute either function',
    not has_function_privilege('anon', 'public.remove_character_feat(uuid, text)', 'execute')
    and not has_function_privilege('anon', 'public.preview_character_feat_removal(uuid)', 'execute')
    and not has_function_privilege('public', 'public.preview_character_feat_removal(uuid)', 'execute'));
  perform pg_temp.ok('F6b authenticated users can', has_function_privilege('authenticated', 'public.remove_character_feat(uuid, text)', 'execute')
    and has_function_privilege('authenticated', 'public.preview_character_feat_removal(uuid)', 'execute'));
  perform pg_temp.ok('F6c both run with a fixed search_path', (select bool_and(proconfig::text like '%search_path=public, pg_temp%') from pg_proc
    where proname in ('remove_character_feat', 'preview_character_feat_removal')));
end $$;

-- ============================================================================================ 2. locks, idempotency, audit
do $$
declare pl uuid := pg_temp.fu('pl'); dm uuid := pg_temp.fu('dm'); ch uuid := pg_temp.fu('lock'); f uuid; r text; j jsonb; a int; v int;
begin
  perform pg_temp.as_user(pl);
  f := pg_temp.assign(ch, 'alert-2014');
  perform pg_temp.as_admin();
  update public.character_governance set lock_mode = 'build_locked', lock_reason = 'Session night' where character_id = ch;
  perform pg_temp.as_user(pl);
  r := pg_temp.try(format('select public.remove_character_feat(%L, null)', f));
  perform pg_temp.ok('F8 build lock: the player is refused (TLLCK), the feat stays', r like 'TLLCK%' and pg_temp.cf(ch, 'alert-2014') = f, r);
  j := public.preview_character_feat_removal(f);
  perform pg_temp.ok('P4 preview under a lock: not ok, with the lock message', not (j ->> 'ok')::boolean and j ->> 'message' like '%locked%', left(j::text, 300));
  perform pg_temp.as_admin();
  update public.character_governance set lock_mode = 'progression_locked' where character_id = ch;
  perform pg_temp.as_user(pl);
  r := pg_temp.try(format('select public.remove_character_feat(%L, null)', f));
  perform pg_temp.ok('F9 progression lock: refused too', r like 'TLLCK%' and pg_temp.cf(ch, 'alert-2014') = f, r);
  perform pg_temp.as_admin();
  update public.character_governance set lock_mode = 'unlocked', lock_reason = null where character_id = ch;
  a := pg_temp.audits(ch); v := pg_temp.revs(ch); perform pg_temp.put('solo_revs', pg_temp.revs(pg_temp.fu('solo'))::text);
  perform pg_temp.as_user(pl);
  r := pg_temp.try(format('select public.remove_character_feat(%L, null)', f));
  perform pg_temp.ok('F9b unlocked again: removed', r = 'ok', r);
  r := pg_temp.try(format('select public.remove_character_feat(%L, null)', f));
  perform pg_temp.ok('F24 a repeated request gets the friendly already-removed answer (no raw error)',
    r like 'P0002|feat_absent|This feat is no longer on the character.%', r);
  perform pg_temp.ok('F31 ... with no constraint, relation or function name in it', r !~* '(constraint|relation|function|violates|character_feats)', r);
  perform pg_temp.as_admin();
  perform pg_temp.ok('F22 exactly one audit event for the two calls', pg_temp.audits(ch) = a + 1, (pg_temp.audits(ch) - a)::text);
  -- the cache bumps a character once per transaction (this whole suite is one), so the triggers themselves are checked here;
  -- progressive_read_tests.sql / read_cache browser tests exercise the bump across transactions
  perform pg_temp.ok('F26c Realtime: character_revisions triggers on character_feats and character_feat_choices',
    (select count(*) from pg_trigger where tgname in ('character_feats_revision', 'character_feat_choices_revision')) = 2);
  perform pg_temp.ok('F26 removal invalidates the read cache: tl_cache_rev on character_feats, its choices and resources',
    (select count(*) from pg_trigger t where t.tgname = 'tl_cache_rev' and t.tgrelid in ('public.character_feats'::regclass,
       'public.character_feat_choices'::regclass, 'public.character_resources'::regclass, 'public.character_spellcasting_sources'::regclass)) = 4, '');
  perform pg_temp.ok('F26b no unrelated character got a revision', pg_temp.revs(pg_temp.fu('solo')) = (select fx.v::int from fx where fx.k = 'solo_revs'));
  perform pg_temp.as_user(pl);
  r := pg_temp.try(format('select public.remove_character_feat(%L, null)', gen_random_uuid()));
  perform pg_temp.as_admin();
  perform pg_temp.ok('F24b an unknown id: the same friendly answer', r like 'P0002|feat_absent|%', r);
end $$;

-- ============================================================================================ 3. dependent mechanics
do $$
declare pl uuid := pg_temp.fu('pl'); ch uuid; f uuid; j jsonb; s int; can text[]; s1 text; n int; hp int; w0 jsonb; w1 jsonb; shared text;
begin
  -- Tough: maximum HP, current HP policy
  ch := pg_temp.fu('tough');
  perform pg_temp.as_user(pl);
  f := pg_temp.assign(ch, 'tough-2014');
  perform pg_temp.as_admin();
  perform pg_temp.ok('F15a Tough raises the maximum to 48', pg_temp.maxhp(ch) = 48, pg_temp.maxhp(ch)::text);
  update public.characters set hp_current = 30 where id = ch;
  perform pg_temp.as_user(pl);
  j := public.preview_character_feat_removal(f);
  perform pg_temp.ok('P1 preview: Maximum HP 48 -> 40 and the feat leaves the list', j -> 'diff' @> '[{"label": "Maximum HP", "before": 48, "after": 40}]'
    and j -> 'diff' @> '[{"label": "Feats", "kind": "list"}]', left((j -> 'diff')::text, 300));
  perform pg_temp.ok('P2 preview changes nothing (feat row, audit, HP, revision unchanged)', pg_temp.cf(ch, 'tough-2014') = f and pg_temp.maxhp(ch) = 48
    and (select hp_current from public.characters where id = ch) = 30);
  perform public.remove_character_feat(f, null);
  perform pg_temp.as_admin();
  perform pg_temp.ok('F15 Tough removed: maximum back to 40', pg_temp.maxhp(ch) = 40, pg_temp.maxhp(ch)::text);
  perform pg_temp.ok('F16 current HP below the new maximum is untouched (never raised)', (select hp_current from public.characters where id = ch) = 30);
  perform pg_temp.as_user(pl);
  f := pg_temp.assign(ch, 'tough-2014');
  perform public.apply_character_hp(ch, 'heal', 100, null);
  perform pg_temp.as_admin();
  perform pg_temp.ok('F16b healed to the Tough maximum 48', (select hp_current from public.characters where id = ch) = 48);
  perform pg_temp.as_user(pl);
  perform public.remove_character_feat(f, null);
  perform pg_temp.as_admin();
  hp := (select hp_current from public.characters where id = ch);
  perform pg_temp.ok('F16c current HP above the new maximum is lowered to it (40), not below', hp = 40, hp::text);

  -- Resilient: ability bonus + saving throw proficiency; the class keeps its own proficiency
  ch := pg_temp.fu('res');
  s := pg_temp.score(ch, 'con');
  perform pg_temp.as_user(pl);
  f := pg_temp.assign(ch, 'resilient-2014', '{"ability": ["con"]}');
  perform pg_temp.as_admin();
  perform pg_temp.ok('F14a Resilient (Constitution) adds +1', pg_temp.score(ch, 'con') = s + 1, s || ' -> ' || pg_temp.score(ch, 'con'));
  perform pg_temp.ok('F10a its choice row exists', exists (select 1 from public.character_feat_choices where character_id = ch and grant_key = 'cf:' || f));
  perform pg_temp.as_user(pl);
  perform public.remove_character_feat(f, null);
  perform pg_temp.as_admin();
  perform pg_temp.ok('F14 removed: Constitution back to its score, base unchanged', pg_temp.score(ch, 'con') = s
    and (select constitution from public.characters where id = ch) = 14, pg_temp.score(ch, 'con')::text);
  perform pg_temp.ok('F10 its choice rows are gone', not exists (select 1 from public.character_feat_choices where character_id = ch and grant_key = 'cf:' || f));
  perform pg_temp.ok('F17 the Fighter''s own Constitution save proficiency stays',
    coalesce((public._derived_stats_full(ch) -> 'saving_throws' -> 'con' ->> 'class_proficient')::boolean, false));
  -- Resilient (Wisdom): the feat's own save-proficiency effect goes with it. (Known, separate defect, docs/FEAT_REMOVAL.md:
  -- the derived saves and the proficiency resolver do not apply a feat's save proficiency at all, so there is nothing else to undo.)
  perform pg_temp.as_user(pl);
  f := pg_temp.assign(ch, 'resilient-2014', '{"ability": ["wis"]}');
  n := (select count(*) from jsonb_array_elements(public.get_character_feats(ch) -> 'feats') g, jsonb_array_elements(g -> 'effects') e
        where e ->> 'effect_type' = 'proficiency' and e ->> 'target' = 'wis' and (e ->> 'active')::boolean);
  perform public.remove_character_feat(f, null);
  perform pg_temp.ok('F17b the feat''s Wisdom save-proficiency effect is gone with it', n = 1 and not exists (select 1
    from jsonb_array_elements(public.get_character_feats(ch) -> 'feats') g, jsonb_array_elements(g -> 'effects') e
    where e ->> 'effect_type' = 'proficiency' and e ->> 'target' = 'wis'), n::text);
  w0 := (select x from jsonb_array_elements(public.get_character_proficiencies(ch) -> 'saves') x where x ->> 'id' = 'con');
  perform pg_temp.ok('F17c the class Constitution save stays effective in the resolver', (w0 ->> 'effective')::boolean
    and w0 -> 'sources' @> '[{"kind": "class"}]', left(w0::text, 160));
  perform pg_temp.as_admin();

  -- Magic Initiate (cleric list, direct) on a Wizard with a Sage background (Magic Initiate, wizard list)
  -- a cantrip on both the wizard and the cleric list: learned through the background (wizard) AND the direct feat (cleric)
  select e.spell_version_id into shared from public.class_spell_list_entries e join public.spell_versions v on v.id = e.spell_version_id
    where e.list_id = 'wizard-spell-list' and v.level = 0
      and exists (select 1 from public.class_spell_list_entries c where c.list_id = 'cleric-spell-list' and c.spell_version_id = e.spell_version_id)
    order by 1 limit 1;
  can := array[shared, (select e.spell_version_id from public.class_spell_list_entries e join public.spell_versions v on v.id = e.spell_version_id
    where e.list_id = 'wizard-spell-list' and v.level = 0 and e.spell_version_id <> shared order by 1 limit 1)];
  select e.spell_version_id into s1 from public.class_spell_list_entries e join public.spell_versions v on v.id = e.spell_version_id
    where e.list_id = 'wizard-spell-list' and v.level = 1 order by 1 limit 1;
  insert into public.character_backgrounds (character_id, version_id) values (ch, 'sage-2024');
  perform pg_temp.as_user(pl);
  perform public.set_character_feat_choices(ch, 'bg:sage-2024', jsonb_build_object('ability', jsonb_build_array('int'), 'cantrips', to_jsonb(can), 'spell1', jsonb_build_array(s1)));
  f := pg_temp.assign(ch, 'magic-initiate-2024', jsonb_build_object('list', '["cleric-spell-list"]'::jsonb, 'ability', '["wis"]'::jsonb,
         'cantrips', to_jsonb(array[shared, (select e.spell_version_id from public.class_spell_list_entries e join public.spell_versions v on v.id = e.spell_version_id
                                             where e.list_id = 'cleric-spell-list' and v.level = 0 and e.spell_version_id <> all (can) order by 1 limit 1)]),
         'spell1', (select to_jsonb(array_agg(spell_version_id)) from (select e.spell_version_id from public.class_spell_list_entries e join public.spell_versions v on v.id = e.spell_version_id
           where e.list_id = 'cleric-spell-list' and v.level = 1 order by 1 limit 1) x)));
  perform pg_temp.as_admin();
  perform pg_temp.ok('F11a the direct Magic Initiate grants its 3 spells under its own source', (select count(*) from public.character_spells cs
    join public.character_spellcasting_sources s on s.id = cs.source_id where s.character_id = ch and s.feat_grant_key = 'cf:' || f) = 3);
  perform pg_temp.ok('F13a ... and its free-cast resource', exists (select 1 from public.character_resources where character_id = ch and source_type = 'feat' and source_id = 'cf:' || f));
  perform pg_temp.as_user(pl);
  j := public.preview_character_feat_removal(f);
  perform pg_temp.ok('P6 preview lists the feat''s spell entries as removed', exists (select 1 from jsonb_array_elements(j -> 'diff') d
    where d ->> 'label' = 'Spells' and jsonb_array_length(d -> 'removed') >= 1), left((j -> 'diff')::text, 400));
  perform public.remove_character_feat(f, null);
  perform pg_temp.as_admin();
  perform pg_temp.ok('F11 its spell source and spells are gone', not exists (select 1 from public.character_spellcasting_sources where character_id = ch and feat_grant_key = 'cf:' || f));
  perform pg_temp.ok('F12 the shared cantrip stays through the background Magic Initiate', exists (select 1 from public.character_spells cs
    join public.character_spellcasting_sources s on s.id = cs.source_id where s.character_id = ch and s.feat_grant_key = 'bg:sage-2024' and cs.spell_version_id = can[1]));
  perform pg_temp.ok('F12b the background grant keeps all 3 spells', (select count(*) from public.character_spells cs
    join public.character_spellcasting_sources s on s.id = cs.source_id where s.character_id = ch and s.feat_grant_key = 'bg:sage-2024') = 3);
  perform pg_temp.ok('F13 its resource is gone; the background''s stays', not exists (select 1 from public.character_resources where character_id = ch and source_type = 'feat' and source_id = 'cf:' || f)
    and exists (select 1 from public.character_resources where character_id = ch and source_type = 'feat' and source_id = 'bg:sage-2024'));
  perform pg_temp.ok('F10b no choice row of the removed feat is left', not exists (select 1 from public.character_feat_choices where character_id = ch and grant_key = 'cf:' || f));
end $$;

-- ============================================================================================ 4. source-granted feats
do $$
declare pl uuid := pg_temp.fu('pl'); ch uuid := pg_temp.fu('src'); j jsonb; row uuid; r text;
begin
  insert into public.character_backgrounds (character_id, version_id) values (ch, 'sage-2024');
  perform pg_temp.as_user(pl);
  perform public.set_character_lineage(ch, 'human-phb', 'human-variant');
  perform pg_temp.as_admin();
  insert into public.character_lineage_choices (character_id, choice_id, pick, value) values (ch, 'human-variant:feat', 1, 'feat:skilled-2014');
  select id into row from public.character_classes where character_id = ch limit 1;
  perform pg_temp.as_user(pl);
  perform public.set_character_feature_choice(ch, row, 'fighter-phb-u4-asi', 'fighter-asi-phb-asi', array['feat:tough-2014'], null);
  j := public.get_character_feats(ch);
  perform pg_temp.as_admin();
  perform pg_temp.ok('F18 background feat: listed, no removable row (change the background instead)', exists (select 1 from jsonb_array_elements(j -> 'feats') g
    where g ->> 'source_type' = 'background' and g -> 'character_feat_id' = 'null'::jsonb), left(j::text, 200));
  perform pg_temp.ok('F19 lineage feat: listed, no removable row', exists (select 1 from jsonb_array_elements(j -> 'feats') g
    where g ->> 'source_type' = 'lineage' and g -> 'character_feat_id' = 'null'::jsonb));
  perform pg_temp.ok('F20 class ASI feat: listed with its choice key, no removable row', exists (select 1 from jsonb_array_elements(j -> 'feats') g
    where g ->> 'source_type' = 'class' and g -> 'character_feat_id' = 'null'::jsonb and g ->> 'grant_key' like 'asi:%:fighter-phb-u4-asi:fighter-asi-phb-asi'));
  perform pg_temp.ok('F20b none of them is a character_feats row (remove_character_feat cannot reach them)',
    not exists (select 1 from public.character_feats where character_id = ch));
  -- F21 the change-choice path stays: replacing the ASI feat with +2 Strength removes Tough's HP bonus at the source
  perform pg_temp.ok('F21a with the ASI feat Tough the maximum is 48', pg_temp.maxhp(ch) = 48, pg_temp.maxhp(ch)::text);
  perform pg_temp.as_user(pl);
  perform public.set_character_feature_choice(ch, row, 'fighter-phb-u4-asi', 'fighter-asi-phb-asi', array['str:2'], null);
  perform pg_temp.as_admin();
  perform pg_temp.ok('F21 changing the ASI choice replaces the feat (Tough gone, +2 Strength)', pg_temp.maxhp(ch) = 40 and pg_temp.score(ch, 'str') = 17,
    pg_temp.maxhp(ch) || ' / ' || pg_temp.score(ch, 'str'));
end $$;

-- ============================================================================================ 5. export / import, ASI "already included"
do $$
declare pl uuid := pg_temp.fu('pl'); ch uuid := pg_temp.fu('solo'); f uuid; ex jsonb; row uuid; s0 int; s1 int;
begin
  perform pg_temp.as_user(pl);
  f := pg_temp.assign(ch, 'tough-2014');
  perform public.remove_character_feat(f, null);
  ex := public.export_character_feats(ch);
  perform pg_temp.ok('F28 export after the removal does not list the feat', ex::text not like '%tough-2014%', left(ex::text, 200));
  perform public.import_character_feats(ch, coalesce(ex -> 'feats', ex));
  perform pg_temp.as_admin();
  perform pg_temp.ok('F29 importing that export does not recreate the removed feat', pg_temp.cf(ch, 'tough-2014') is null);
  -- the class ASI "Already included in my ability scores" option: no bonus is added on top of the stored base
  select id into row from public.character_classes where character_id = ch limit 1;
  s0 := pg_temp.score(ch, 'str');
  perform pg_temp.as_user(pl);
  perform public.set_character_feature_choice(ch, row, 'fighter-phb-u4-asi', 'fighter-asi-phb-asi', array['str:2'], 'applied_manually');
  perform pg_temp.as_admin();
  s1 := pg_temp.score(ch, 'str');
  perform pg_temp.ok('A33 ASI marked "already included": the score stays the base (no double application)', s1 = s0, s0 || ' -> ' || s1);
  perform pg_temp.as_user(pl);
  perform public.set_character_feature_choice(ch, row, 'fighter-phb-u4-asi', 'fighter-asi-phb-asi', array['str:2'], null);
  perform pg_temp.as_admin();
  perform pg_temp.ok('A33b the same ASI not marked: +2 once', pg_temp.score(ch, 'str') = s0 + 2, s0 || ' -> ' || pg_temp.score(ch, 'str'));
end $$;

-- ------------------------------------------------------------------------------------------------------------- report
select 'FAILED ' || chk || coalesce('  <-- ' || nullif(detail, ''), '') from fr where not ok order by n;
select 'TOTAL ' || count(*) || ' checks, ' || count(*) filter (where not ok) || ' failed' from fr;
rollback;
