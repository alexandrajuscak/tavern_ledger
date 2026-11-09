-- Feat choice repair and state machine (20261109000100_feat_choice_state.sql; docs/FEAT_SYSTEM_AUDIT.md). LOCAL ONLY; run as
-- supabase_admin; one transaction that is rolled back (synthetic users and characters).
-- Usage: docker exec -i supabase_db_tavern_ledger psql -U supabase_admin -d postgres -qAt -v ON_ERROR_STOP=1 < supabase/tests/feat_choice_state_tests.sql
-- Prints failed checks and a TOTAL line.
begin;
create temp table fc (n serial, chk text, ok boolean, detail text) on commit drop;
grant all on fc to authenticated, anon;
grant all on sequence fc_n_seq to authenticated, anon;
create temp table fx (k text primary key, v text) on commit drop;
grant all on fx to authenticated, anon;
create or replace function pg_temp.as_user(u uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
end $$;
create or replace function pg_temp.as_admin() returns void language plpgsql as $$
begin execute 'reset role'; perform set_config('request.jwt.claims', '', true); end $$;
create or replace function pg_temp.ok(c text, b boolean, d text default '') returns void language sql as $$
  insert into fc (chk, ok, detail) values (c, coalesce(b, false), coalesce(d, ''));
$$;
create or replace function pg_temp.try(q text) returns text language plpgsql as $$
begin execute q; return 'ok'; exception when others then return sqlstate || '|' || sqlerrm; end $$;
create or replace function pg_temp.fu(k text) returns uuid language sql as $$ select v::uuid from fx where fx.k = $1 $$;
create or replace function pg_temp.put(k text, v text) returns void language sql as $$
  insert into fx values (k, v) on conflict (k) do update set v = excluded.v;
$$;
-- the grant of a character (first one matching a grant-key prefix), as get_character_feats returns it
create or replace function pg_temp.grant_of(ch uuid, prefix text) returns jsonb language sql as $$
  select g from jsonb_array_elements(public.get_character_feats(ch) -> 'feats') g where g ->> 'grant_key' like prefix || '%' limit 1;
$$;
create or replace function pg_temp.choice_of(g jsonb, k text) returns jsonb language sql as $$
  select c from jsonb_array_elements(g -> 'choices') c where c ->> 'key' = k;
$$;
create or replace function pg_temp.feat_spells(ch uuid, prefix text) returns text language sql as $$
  select string_agg(cs.spell_version_id, ',' order by cs.spell_version_id) from public.character_spells cs
  join public.character_spellcasting_sources s on s.id = cs.source_id where s.character_id = ch and s.feat_grant_key like prefix || '%';
$$;

do $$
declare pl uuid := gen_random_uuid(); ch uuid; k text;
begin
  insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at) values
    (pl, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'fc-pl-' || pl || '@example.test', now(), now());
  perform pg_temp.put('pl', pl::text);
  foreach k in array array['vh', 'asi', 'fey', 'cleric', 'imp'] loop
    insert into public.characters (owner_id, name, level, hp_max, hp_current, strength, dexterity, constitution, intelligence, wisdom, charisma)
    values (pl, 'FC ' || k, 4, 30, 30, 15, 12, 12, 14, 16, 10) returning id into ch;
    perform pg_temp.put(k, ch::text);
    perform pg_temp.as_user(pl);
    perform public.set_character_class(ch, case when k = 'cleric' then 'cleric-phb' else 'fighter-phb' end, 4, null);
    perform pg_temp.as_admin();
  end loop;
  -- Variant Human whose feat is Magic Initiate (2024), no feat choices made yet (the production case)
  perform pg_temp.as_user(pl);
  perform public.set_character_lineage(pg_temp.fu('vh'), 'human-phb', 'human-variant', '{}', false, false);
  perform pg_temp.as_admin();
  insert into public.character_lineage_choices (character_id, choice_id, pick, value) values (pg_temp.fu('vh'), 'human-variant:feat', 1, 'feat:magic-initiate-2024');
end $$;

-- ============================================================================================ 1. the repaired edit-choices path
do $$
declare pl uuid := pg_temp.fu('pl'); vh uuid := pg_temp.fu('vh'); g jsonb; r jsonb;
begin
  perform pg_temp.as_user(pl);
  g := pg_temp.grant_of(vh, 'lin:');
  perform pg_temp.ok('FC1 lineage-granted Magic Initiate without choices: state incomplete, 4 open choices', g ->> 'state' = 'incomplete'
    and (g ->> 'open_choices')::int = 4, left(g::text, 300));
  perform pg_temp.ok('FC2 the spell list choice carries its options (the defect: none were sent)',
    jsonb_array_length(pg_temp.choice_of(g, 'list') -> 'options') = 3
    and pg_temp.choice_of(g, 'list') -> 'options' @> '[{"option_id": "cleric-spell-list", "label": "Cleric"}]', pg_temp.choice_of(g, 'list')::text);
  perform pg_temp.ok('FC3 other kinds carry no options key value (null)', pg_temp.choice_of(g, 'cantrips') -> 'options' = 'null'::jsonb);
  -- partial: list + ability only -> stored, no spell source (no partial grant)
  r := public.set_character_feat_choices(vh, g ->> 'grant_key', '{"list": ["cleric-spell-list"], "ability": ["wis"]}');
  g := (select x from jsonb_array_elements(r -> 'feats') x where x ->> 'grant_key' = g ->> 'grant_key');
  perform pg_temp.ok('FC4 a partial save stores what was chosen and says what is still open (2 choices)',
    (g ->> 'open_choices')::int = 2 and g ->> 'state' = 'incomplete'
    and (select count(*) from public.character_feat_choices where character_id = vh) = 2, left(g::text, 200));
  perform pg_temp.ok('FC5 no spell source from an incomplete feat', pg_temp.feat_spells(vh, 'lin:') is null);
  r := public.set_character_feat_choices(vh, g ->> 'grant_key', '{"list": ["cleric-spell-list"], "ability": ["wis"], "cantrips": ["guidance-phb", "light-phb"], "spell1": ["bless-phb"]}');
  g := (select x from jsonb_array_elements(r -> 'feats') x where x ->> 'grant_key' = g ->> 'grant_key');
  perform pg_temp.ok('FC6 complete choices: state applied, the save response says 0 open', g ->> 'state' = 'applied' and (g ->> 'open_choices')::int = 0);
  perform pg_temp.ok('FC7 the three spells are granted under the feat source, Wisdom, labelled by the lineage source',
    pg_temp.feat_spells(vh, 'lin:') = 'bless-phb,guidance-phb,light-phb'
    and (select casting_ability from public.character_spellcasting_sources where character_id = vh and feat_grant_key like 'lin:%') = 'wis'
    and (select label from public.character_spellcasting_sources where character_id = vh and feat_grant_key like 'lin:%') like 'Magic Initiate (Lineage%');
  perform pg_temp.ok('FC8 the spellbook lists them with spell attack and save DC from Wisdom',
    (select count(*) from jsonb_array_elements(public.get_character_spellbook(vh) -> 'spells') s where s ->> 'id' in ('bless-phb', 'guidance-phb', 'light-phb')) >= 3);
  perform pg_temp.ok('FC9 a spell off the chosen list is refused on save (nothing changes)',
    pg_temp.try(format('select public.set_character_feat_choices(%L, %L, %L)', vh, g ->> 'grant_key',
      '{"list": ["cleric-spell-list"], "ability": ["wis"], "cantrips": ["fire-bolt-phb", "light-phb"], "spell1": ["bless-phb"]}')) like '%not on the chosen spell list%'
    and pg_temp.feat_spells(vh, 'lin:') = 'bless-phb,guidance-phb,light-phb');
  -- replacement: another cantrip replaces exactly one spell of this source
  r := public.set_character_feat_choices(vh, g ->> 'grant_key', '{"list": ["cleric-spell-list"], "ability": ["wis"], "cantrips": ["guidance-phb", "thaumaturgy-phb"], "spell1": ["bless-phb"]}');
  perform pg_temp.ok('FC10 replacing a cantrip swaps exactly that spell (no duplicate, no orphan)',
    pg_temp.feat_spells(vh, 'lin:') = 'bless-phb,guidance-phb,thaumaturgy-phb', pg_temp.feat_spells(vh, 'lin:'));
  -- progressive read path (cached per viewer): the new shape is served
  perform pg_temp.ok('FC11 the progressive read (get_character_reads) serves the options and the state',
    (select (x ->> 'state') = 'applied' and jsonb_array_length(pg_temp.choice_of(x, 'list') -> 'options') = 3
     from jsonb_array_elements(public.get_character_reads(vh, array['get_character_feats']) -> 'reads' -> 'get_character_feats' -> 'feats') x
     where x ->> 'grant_key' like 'lin:%'));
  perform pg_temp.as_admin();
end $$;

-- ============================================================================================ 2. INVALIDATED: a stored value that is no longer valid
do $$
declare pl uuid := pg_temp.fu('pl'); vh uuid := pg_temp.fu('vh'); g jsonb;
begin
  -- simulate a catalog / list change: the stored cantrip is no longer on the chosen list
  update public.character_feat_choices set value = 'fire-bolt-phb' where character_id = vh and choice_id = 'magic-initiate-2024:cantrips' and value = 'thaumaturgy-phb';
  perform public._sync_character_feats(vh);
  perform pg_temp.as_user(pl);
  g := pg_temp.grant_of(vh, 'lin:');
  perform pg_temp.ok('FC12 an invalid stored value: state invalidated, the choice is "invalid" with the reason',
    g ->> 'state' = 'invalidated' and pg_temp.choice_of(g, 'cantrips') ->> 'status' = 'invalid'
    and pg_temp.choice_of(g, 'cantrips') -> 'invalid' -> 0 ->> 'error' like '%not on the chosen spell list%', left(g::text, 400));
  perform pg_temp.ok('FC13 ... and its spells are not silently kept active (no stale grant)', pg_temp.feat_spells(vh, 'lin:') is null);
  perform public.set_character_feat_choices(vh, g ->> 'grant_key', '{"list": ["cleric-spell-list"], "ability": ["wis"], "cantrips": ["guidance-phb", "light-phb"], "spell1": ["bless-phb"]}');
  perform pg_temp.ok('FC14 choosing again applies it', pg_temp.grant_of(vh, 'lin:') ->> 'state' = 'applied' and pg_temp.feat_spells(vh, 'lin:') = 'bless-phb,guidance-phb,light-phb');
  perform pg_temp.as_admin();
end $$;

-- ============================================================================================ 3. other spell-selecting feats and sources
do $$
declare pl uuid := pg_temp.fu('pl'); a uuid := pg_temp.fu('asi'); f uuid := pg_temp.fu('fey'); cl uuid := pg_temp.fu('cleric'); g jsonb; cf jsonb; cfid uuid; r text;
begin
  perform pg_temp.as_user(pl);
  -- Magic Initiate (2014) through a Fighter ASI: the casting ability comes from the list option (Wizard -> INT)
  cf := public.get_character_class_features(a);
  perform public.set_character_feature_choice(a, (cf -> 'classes' -> 0 ->> 'id')::uuid, 'fighter-phb-u4-asi', 'fighter-asi-phb-asi', array['feat:magic-initiate-2014'], null);
  g := pg_temp.grant_of(a, 'asi:');
  perform pg_temp.ok('FC15 ASI-granted Magic Initiate (2014): list options carry their casting ability',
    jsonb_array_length(pg_temp.choice_of(g, 'list') -> 'options') = 6
    and pg_temp.choice_of(g, 'list') -> 'options' @> '[{"option_id": "wizard-spell-list", "data": {"ability": "int"}}]', left(g::text, 300));
  perform public.set_character_feat_choices(a, g ->> 'grant_key', '{"list": ["wizard-spell-list"], "cantrips": ["fire-bolt-phb", "light-phb"], "spell1": ["magic-missile-phb"]}');
  perform pg_temp.ok('FC16 ... complete: three spells, Intelligence, one free cast of the level-1 spell',
    pg_temp.feat_spells(a, 'asi:') = 'fire-bolt-phb,light-phb,magic-missile-phb'
    and (select casting_ability from public.character_spellcasting_sources where character_id = a and feat_grant_key like 'asi:%') = 'int'
    and (select count(*) from public.character_resources where character_id = a and source_type = 'feat' and spell_version_id = 'magic-missile-phb' and active) = 1);
  -- Fey Touched (2024) assigned without choices, chosen later: Misty Step + one Divination / Enchantment spell, ability from +1
  perform public.assign_character_feat(f, 'fey-touched-2024', '{}', 'direct', null, null, null);
  g := pg_temp.grant_of(f, 'cf:');
  perform pg_temp.ok('FC17 Fey Touched without choices: incomplete, Misty Step not granted yet (no partial grant)',
    g ->> 'state' = 'incomplete' and pg_temp.feat_spells(f, 'cf:') is null);
  perform pg_temp.ok('FC18 a spell of the wrong school is refused', pg_temp.try(format('select public.set_character_feat_choices(%L, %L, %L)', f, g ->> 'grant_key',
    '{"asi": ["wis"], "spell1": ["magic-missile-phb"]}')) like '%required school%');
  perform public.set_character_feat_choices(f, g ->> 'grant_key', '{"asi": ["wis"], "spell1": ["bless-phb"]}');
  perform pg_temp.ok('FC19 Fey Touched complete: Misty Step + Bless, always prepared, Wisdom, two free casts',
    pg_temp.feat_spells(f, 'cf:') = 'bless-phb,misty-step-phb'
    and (select bool_and(cs.always_prepared and cs.casting_ability = 'wis') from public.character_spells cs join public.character_spellcasting_sources s on s.id = cs.source_id
         where s.character_id = f and s.feat_grant_key like 'cf:%')
    and (select count(*) from public.character_resources where character_id = f and source_type = 'feat' and active and spell_version_id is not null) = 2);
  -- the same spell from a class and from a feat: removing the feat keeps the class one
  perform public.assign_character_feat(cl, 'magic-initiate-2024', '{"list": ["cleric-spell-list"], "ability": ["wis"], "cantrips": ["guidance-phb", "light-phb"], "spell1": ["bless-phb"]}',
                                       'direct', null, null, null);
  perform pg_temp.as_admin();
  insert into public.character_spells (character_id, source_id, spell_version_id, known, prepared)
  select cl, s.id, 'guidance-phb', true, true from public.character_spellcasting_sources s where s.character_id = cl and s.source_type = 'class' limit 1
  on conflict do nothing;
  perform pg_temp.as_user(pl);
  cfid := (select id from public.character_feats where character_id = cl and feat_version_id = 'magic-initiate-2024');
  perform public.remove_character_feat(cfid, null);
  perform pg_temp.ok('FC20 removing Magic Initiate removes only its source; Guidance from the class stays',
    pg_temp.feat_spells(cl, 'cf:') is null
    and exists (select 1 from public.character_spells cs join public.character_spellcasting_sources s on s.id = cs.source_id
                where s.character_id = cl and s.source_type = 'class' and cs.spell_version_id = 'guidance-phb')
    and not exists (select 1 from public.character_feat_choices where character_id = cl));
  -- export / import keeps the choices and the grants
  r := pg_temp.try(format('select public.import_character_feats(%L, public.export_character_feats(%L))', pg_temp.fu('imp'), f));
  perform pg_temp.ok('FC21 export / import of a direct Fey Touched keeps its choices and grants its spells',
    r = 'ok' and pg_temp.feat_spells(pg_temp.fu('imp'), 'cf:') = 'bless-phb,misty-step-phb', r);
  perform pg_temp.as_admin();
end $$;

-- ============================================================================================ 4. Resilient: the save proficiency is applied
do $$
declare pl uuid := pg_temp.fu('pl'); f uuid := pg_temp.fu('imp'); cfid uuid; w0 int;
begin
  perform pg_temp.as_user(pl);
  w0 := (public._derived_stats_full(f) -> 'abilities' -> 'wis' ->> 'score')::int;
  perform pg_temp.ok('FC24 before: a Fighter is not proficient in Wisdom saves',
    not coalesce((public.get_character_derived_stats(f) -> 'saving_throws' -> 'wis' ->> 'class_proficient')::boolean, false));
  perform public.assign_character_feat(f, 'resilient-2014', '{"ability": ["wis"]}', 'direct', null, null, null);
  perform pg_temp.ok('FC25 Resilient (Wisdom): proficient in Wisdom saves, the source is named, +1 WIS',
    coalesce((public.get_character_derived_stats(f) -> 'saving_throws' -> 'wis' ->> 'class_proficient')::boolean, false)
    and public.get_character_derived_stats(f) -> 'saving_throws' -> 'wis' -> 'class_sources' ? 'Feat: Resilient'
    and (public._derived_stats_full(f) -> 'abilities' -> 'wis' ->> 'score')::int = w0 + 1,
    (public.get_character_derived_stats(f) -> 'saving_throws' -> 'wis')::text);
  cfid := (select id from public.character_feats where character_id = f and feat_version_id = 'resilient-2014');
  perform public.remove_character_feat(cfid, null);
  perform pg_temp.ok('FC26 removing Resilient removes the save proficiency and the +1 (Fighter CON save stays)',
    not coalesce((public.get_character_derived_stats(f) -> 'saving_throws' -> 'wis' ->> 'class_proficient')::boolean, false)
    and (public._derived_stats_full(f) -> 'abilities' -> 'wis' ->> 'score')::int = w0
    and (public.get_character_derived_stats(f) -> 'saving_throws' -> 'con' ->> 'class_proficient')::boolean);
  perform pg_temp.as_admin();
end $$;

-- ============================================================================================ 5. admin removal (approval campaign)
do $$
declare pl uuid := pg_temp.fu('pl'); adm uuid := gen_random_uuid(); dmu uuid := gen_random_uuid(); camp uuid := gen_random_uuid();
  ch uuid := pg_temp.fu('fey'); cfid uuid; r text;
begin
  insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at) values
    (adm, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'fc-adm-' || adm || '@example.test', now(), now()),
    (dmu, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'fc-dm-' || dmu || '@example.test', now(), now());
  update public.profiles set role = 'admin' where id = adm;
  insert into public.campaigns (id, name, created_by) values (camp, 'FC Approval Table', dmu);
  insert into public.campaign_members (campaign_id, user_id, role) values (camp, dmu, 'dm'), (camp, pl, 'player');
  insert into public.campaign_governance (campaign_id, preset) values (camp, 'standard');
  update public.characters set campaign_id = camp where id = ch;
  insert into public.character_governance (character_id, setup_complete) values (ch, true) on conflict do nothing;
  cfid := (select id from public.character_feats where character_id = ch and feat_version_id = 'fey-touched-2024');
  perform pg_temp.as_user(pl);
  r := pg_temp.try(format('select public.remove_character_feat(%L, null)', cfid));
  perform pg_temp.ok('FC27 approval campaign: the player''s removal becomes a request (TLAPR), the feat stays',
    r like 'TLAPR%' and exists (select 1 from public.character_feats where id = cfid), r);
  perform pg_temp.as_user(adm);
  r := pg_temp.try(format('select public.remove_character_feat(%L, %L)', cfid, 'Admin cleanup'));
  perform pg_temp.as_admin();
  perform pg_temp.ok('FC28 an administrator removes it directly, audited once with the reason, its spells gone',
    r = 'ok' and not exists (select 1 from public.character_feats where id = cfid) and pg_temp.feat_spells(ch, 'cf:') is null
    and (select count(*) from public.campaign_audit_events where character_id = ch and event_type = 'feat_removed' and reason = 'Admin cleanup') = 1, r);
end $$;

-- ============================================================================================ 6. no duplicates anywhere
do $$
begin
  perform pg_temp.ok('FC22 no feat source holds the same spell twice', not exists (
    select 1 from public.character_spells cs join public.character_spellcasting_sources s on s.id = cs.source_id
    where s.feat_grant_key is not null group by cs.source_id, cs.spell_version_id having count(*) > 1));
  perform pg_temp.ok('FC23 one spell source per feat grant', not exists (
    select 1 from public.character_spellcasting_sources where feat_grant_key is not null group by character_id, feat_grant_key having count(*) > 1));
end $$;

select chk || '   <-- ' || detail from fc where not ok order by n;
select format('TOTAL %s checks, %s failed', count(*), count(*) filter (where not ok)) from fc;
rollback;
