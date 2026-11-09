-- =============================================================================
-- DM / admin content management (20261109000300; docs/CONTENT_MANAGEMENT.md): usage report and classification, permanent delete
-- of unused custom content of every type (re-checked in the transaction, one audit event, repeat-safe), refusal for used or
-- historically referenced content, official content protection, duplicate official as homebrew, permissions and existence leaks.
-- Runs inside the per-class harness (alice = player of :camp, bob = outsider, dm = DM of :camp).
-- =============================================================================
\set cmc1 f1e00000-0000-0000-0000-000000000001
\set cmc2 f1e00000-0000-0000-0000-000000000002
\set camp2 f1e00000-0000-0000-0000-0000000000c2
insert into public.characters (id, owner_id, name, campaign_id, level, strength, dexterity, constitution, intelligence, wisdom, charisma, hp_max, hp_current, speed) values
  (:'cmc1', :'alice', 'CM Wizard', :'camp', 1, 8, 14, 12, 16, 10, 10, 8, 8, 30),
  (:'cmc2', :'alice', 'CM Druid', :'camp', 2, 10, 12, 14, 10, 16, 10, 10, 10, 30);
-- bob is the DM of another campaign (an unrelated DM)
insert into public.campaigns (id, name, created_by) values (:'camp2', 'Other Secret Table', :'bob');
insert into public.campaign_members (campaign_id, user_id, role) values (:'camp2', :'bob', 'dm');
create function tl_test.cm_code(p_sql text) returns text language plpgsql as $$
begin execute p_sql; return 'ok'; exception when others then return sqlstate; end $$;
create function tl_test.cm_err(p_sql text) returns text language plpgsql as $$
begin execute p_sql; return 'ok'; exception when others then return sqlstate || ': ' || sqlerrm; end $$;
create function tl_test.cm_ref(p_content uuid) returns text language sql security definer as $$
  select v.catalog_ref from public.dm_content c join public.dm_content_versions v on v.id = c.published_version_id where c.id = p_content $$;
create function tl_test.cm_exists(p_content uuid) returns boolean language sql security definer as $$ select exists (select 1 from public.dm_content where id = p_content) $$;
create function tl_test.cm_audits(p_content uuid) returns int language sql security definer as $$
  select count(*)::int from public.campaign_audit_events where event_type = 'content_deleted' and before ->> 'content_id' = p_content::text $$;
create function tl_test.cm_catalog(p_type text, p_ref text) returns boolean language sql security definer as $$
  select case p_type when 'spell' then exists (select 1 from public.spell_versions where id = p_ref)
                     when 'feat' then exists (select 1 from public.feat_versions where id = p_ref)
                     when 'creature' then exists (select 1 from public.creatures where id = p_ref)
                     when 'background' then exists (select 1 from public.background_versions where id = p_ref)
                     when 'lineage' then exists (select 1 from public.lineage_versions where id = p_ref)
                     when 'item' then exists (select 1 from public.items where id = p_ref) end $$;
grant all on all functions in schema tl_test to public;
select tl_test.as_user(:'alice');
select public.set_character_class(:'cmc1', 'wizard-phb', 1, null, true);
select public.set_character_class(:'cmc2', 'druid-phb', 2, null, true);

-- ---- duplicate official as homebrew: every supported type becomes a valid draft; the official row is only read ----------------
select tl_test.as_root();
select md5(string_agg(t, '|' order by t)) as official_before from (
  select md5(to_jsonb(s)::text) t from public.spell_versions s where id = 'fire-bolt-phb'
  union all select md5(to_jsonb(f)::text) from public.feat_versions f where id = 'fey-touched-2024'
  union all select md5(to_jsonb(c)::text) from public.creatures c where id = (select id from public.creatures where owner_id is null and content_version_id is null and wild_shape_eligible order by id limit 1)
  union all select md5(to_jsonb(b)::text) from public.background_versions b where id = 'sage-2024'
  union all select md5(to_jsonb(l)::text) from public.lineage_versions l where id = 'dragonborn-chromatic'
  union all select md5(to_jsonb(i)::text) from public.items i where id = 'longsword') x \gset
select (select id from public.creatures where owner_id is null and content_version_id is null and wild_shape_eligible order by id limit 1) as beast \gset
select tl_test.as_user(:'dm');
select public.duplicate_official_as_homebrew('spell', 'fire-bolt-phb', :'camp') ->> 'id' as d_spell \gset
select public.duplicate_official_as_homebrew('feat', 'fey-touched-2024', :'camp') ->> 'id' as d_feat \gset
select public.duplicate_official_as_homebrew('creature', :'beast', :'camp') ->> 'id' as d_creature \gset
select public.duplicate_official_as_homebrew('background', 'sage-2024', :'camp') ->> 'id' as d_bg \gset
select public.duplicate_official_as_homebrew('lineage', 'dragonborn-chromatic', :'camp') ->> 'id' as d_lin \gset
select public.duplicate_official_as_homebrew('item', 'longsword', :'camp') ->> 'id' as d_item \gset
select tl_test.rec('CM1 duplicate as homebrew creates a campaign DRAFT for spell, feat, creature, background, lineage and item',
  (select bool_and(c.status = 'draft' and c.campaign_id = :'camp' and c.author_id = :'dm')
   from public.dm_content c where c.id in (:'d_spell', :'d_feat', :'d_creature', :'d_bg', :'d_lin', :'d_item'))
  and (select count(*) from public.dm_content where id in (:'d_spell', :'d_feat', :'d_creature', :'d_bg', :'d_lin', :'d_item')) = 6);
select tl_test.rec('CM2 every duplicate validates (backend validation is authoritative)',
  (select bool_and((public.validate_dm_content(x) -> 'validation' ->> 'ok')::boolean)
   from unnest(array[:'d_spell', :'d_feat', :'d_creature', :'d_bg', :'d_lin', :'d_item']::uuid[]) x),
  (select string_agg(x || ':' || (public.validate_dm_content(x) -> 'validation')::text, ' ')
   from unnest(array[:'d_spell', :'d_feat', :'d_creature', :'d_bg', :'d_lin', :'d_item']::uuid[]) x));
select tl_test.rec('CM3 the duplicate keeps the mechanics (feat choices + spell grants, creature stat block, background feat)',
  (select jsonb_array_length(v.definition -> 'choices') = 2 and jsonb_array_length(v.definition -> 'spells') = 2
   from public.dm_content c join public.dm_content_versions v on v.id = c.current_version_id where c.id = :'d_feat')
  and (select (v.definition ->> 'hit_points') is not null from public.dm_content c join public.dm_content_versions v on v.id = c.current_version_id where c.id = :'d_creature')
  and (select v.definition ->> 'feat' = 'magic-initiate-2024' from public.dm_content c join public.dm_content_versions v on v.id = c.current_version_id where c.id = :'d_bg'));
select tl_test.as_root();
select tl_test.rec('CM4 the official rows are unchanged (read only) and no official id is reused',
  (select md5(string_agg(t, '|' order by t)) from (
    select md5(to_jsonb(s)::text) t from public.spell_versions s where id = 'fire-bolt-phb'
    union all select md5(to_jsonb(f)::text) from public.feat_versions f where id = 'fey-touched-2024'
    union all select md5(to_jsonb(c)::text) from public.creatures c where id = :'beast'
    union all select md5(to_jsonb(b)::text) from public.background_versions b where id = 'sage-2024'
    union all select md5(to_jsonb(l)::text) from public.lineage_versions l where id = 'dragonborn-chromatic'
    union all select md5(to_jsonb(i)::text) from public.items i where id = 'longsword') x) = :'official_before');
select tl_test.as_user(:'alice');
select tl_test.rec('CM5 a player cannot duplicate official content into the campaign',
  tl_test.cm_code(format('select public.duplicate_official_as_homebrew(%L, %L, %L)', 'spell', 'fire-bolt-phb', :'camp')) in ('42501', 'TLDMO'));
select tl_test.as_user(:'bob');
select tl_test.rec('CM6 an unrelated DM cannot duplicate into a campaign that is not theirs (and learns nothing about it)',
  tl_test.cm_err(format('select public.duplicate_official_as_homebrew(%L, %L, %L)', 'spell', 'fire-bolt-phb', :'camp')) like '42501%'
  and tl_test.cm_err(format('select public.duplicate_official_as_homebrew(%L, %L, %L)', 'spell', 'fire-bolt-phb', :'camp')) not like '%Class Test Campaign%');
select tl_test.as_user(:'dm');
select tl_test.rec('CM7 a campaign custom row cannot be "duplicated as official homebrew" (only official rows qualify)',
  tl_test.cm_code(format('select public.duplicate_official_as_homebrew(%L, %L, %L)', 'spell', 'no-such-spell', :'camp')) = 'P0002');

-- ---- publish every duplicate; unused published content is SAFE TO DELETE --------------------------------------------------------
select public.publish_dm_content(x) from unnest(array[:'d_spell', :'d_feat', :'d_creature', :'d_bg', :'d_lin', :'d_item']::uuid[]) x;
select tl_test.cm_ref(:'d_spell') as r_spell, tl_test.cm_ref(:'d_feat') as r_feat, tl_test.cm_ref(:'d_creature') as r_creature,
       tl_test.cm_ref(:'d_bg') as r_bg, tl_test.cm_ref(:'d_lin') as r_lin, tl_test.cm_ref(:'d_item') as r_item \gset
select tl_test.rec('CM8 published duplicates have NEW custom ids (cc-...), source Campaign custom',
  :'r_spell' like 'cc-%' and :'r_feat' like 'cc-%' and :'r_creature' like 'cc-%' and :'r_bg' like 'cc-%' and :'r_lin' like 'cc-%' and :'r_item' like 'cc-%');
select tl_test.rec('CM9 usage report: unused published content is safe_to_delete, edit needs a new version',
  (select bool_and(public.get_dm_content_usage(x) ->> 'classification' = 'safe_to_delete' and (public.get_dm_content_usage(x) ->> 'can_delete')::boolean
                   and public.get_dm_content_usage(x) ->> 'edit' = 'new_version')
   from unnest(array[:'d_spell', :'d_feat', :'d_creature', :'d_bg', :'d_lin', :'d_item']::uuid[]) x));

-- ---- used content: the delete is refused and nothing changes ------------------------------------------------------------------
select public.dm_assign_content(:'d_spell', array[:'cmc1']::uuid[], 'known',
  jsonb_build_object('source_id', (select id from public.character_spellcasting_sources where character_id = :'cmc1' and source_type = 'class'))) as asg \gset
select public.dm_assign_content(:'d_feat', array[:'cmc2']::uuid[], 'dm_grant', '{}') as asgf \gset
select public.dm_assign_content(:'d_creature', array[:'cmc2']::uuid[], 'seen_form', '{}') as asgc \gset
select tl_test.rec('CM10 the assignments worked (spell known, feat granted, Wild Shape form seen)',
  (:'asg'::jsonb -> 'results' -> 0 ->> 'ok')::boolean and (:'asgf'::jsonb -> 'results' -> 0 ->> 'ok')::boolean and (:'asgc'::jsonb -> 'results' -> 0 ->> 'ok')::boolean,
  :'asg' || :'asgf' || :'asgc');
select tl_test.rec('CM11 usage counts the assignments (counts only, no names) and classifies delete_blocked / new_version_required',
  (public.get_dm_content_usage(:'d_spell') -> 'counts' ->> 'character_spells')::int = 1
  and (public.get_dm_content_usage(:'d_feat') -> 'counts' ->> 'feat_assignments')::int = 1
  and (public.get_dm_content_usage(:'d_creature') -> 'counts' ->> 'seen_forms')::int = 1
  and (select bool_and(public.get_dm_content_usage(x) ->> 'classification' = 'delete_blocked' and public.get_dm_content_usage(x) ->> 'edit' = 'new_version_required'
                       and not (public.get_dm_content_usage(x) ->> 'can_delete')::boolean)
       from unnest(array[:'d_spell', :'d_feat', :'d_creature']::uuid[]) x)
  and position('CM Wizard' in public.get_dm_content_usage(:'d_spell')::text) = 0);
select tl_test.as_root();
select count(*) as seen_before from public.character_seen_forms where character_id = :'cmc2' \gset
select tl_test.as_user(:'dm');
select tl_test.rec('CM12 deleting used content is refused (TLUSE) for spell, feat and creature',
  tl_test.cm_code(format('select public.delete_unused_dm_content(%L, %L)', :'d_spell', 'Fire Bolt (homebrew)')) = 'TLUSE'
  and tl_test.cm_code(format('select public.delete_unused_dm_content(%L, %L)', :'d_feat', 'Fey Touched (homebrew)')) = 'TLUSE'
  and tl_test.cm_code(format('select public.delete_unused_dm_content(%L, (select name from public.dm_content where id = %L))', :'d_creature', :'d_creature')) = 'TLUSE');
select tl_test.as_root();
select tl_test.rec('CM13 ... and nothing changed: content, catalog rows, the seen form (a CASCADE path) and the feat stay',
  tl_test.cm_exists(:'d_spell') and tl_test.cm_exists(:'d_feat') and tl_test.cm_exists(:'d_creature')
  and tl_test.cm_catalog('spell', :'r_spell') and tl_test.cm_catalog('feat', :'r_feat') and tl_test.cm_catalog('creature', :'r_creature')
  and (select count(*) from public.character_seen_forms where character_id = :'cmc2') = :'seen_before'
  and exists (select 1 from public.character_feats where character_id = :'cmc2' and feat_version_id = :'r_feat')
  and tl_test.cm_audits(:'d_spell') = 0);

-- ---- a custom feat picked through a text reference only (lineage feat pick 'feat:<id>', no FK) blocks the delete --------------
select tl_test.as_user(:'dm');
select public.duplicate_official_as_homebrew('feat', 'alert-2024', :'camp') ->> 'id' as d_feat2 \gset
select public.publish_dm_content(:'d_feat2');
select tl_test.cm_ref(:'d_feat2') as r_feat2 \gset
select tl_test.as_root();
insert into public.character_lineages (character_id, lineage_id, version_id, ability_bonuses_included)
select :'cmc1', lineage_id, id, false from public.lineage_versions where id = 'custom-tce';
insert into public.character_lineage_choices (character_id, choice_id, pick, value) values (:'cmc1', 'custom-tce:feat', 1, 'feat:' || :'r_feat2');
select tl_test.as_user(:'dm');
select tl_test.rec('CM14 a lineage feat pick (text reference, no foreign key) is counted and blocks the delete',
  (public.get_dm_content_usage(:'d_feat2') -> 'counts' ->> 'lineage_feat_picks')::int = 1
  and tl_test.cm_code(format('select public.delete_unused_dm_content(%L, %L)', :'d_feat2', 'Alert (homebrew)')) = 'TLUSE');
select tl_test.as_root();
delete from public.character_lineage_choices where character_id = :'cmc1' and value = 'feat:' || :'r_feat2';
delete from public.character_lineages where character_id = :'cmc1';

-- ---- permissions ---------------------------------------------------------------------------------------------------------------
select tl_test.as_user(:'alice');
select tl_test.rec('CM15 a player can neither read the usage report nor delete (same "not found" as for anything else)',
  tl_test.cm_code(format('select public.get_dm_content_usage(%L)', :'d_bg')) = '42501'
  and tl_test.cm_code(format('select public.delete_unused_dm_content(%L, %L)', :'d_bg', 'Sage (homebrew)')) = '42501');
select tl_test.as_user(:'bob');
select tl_test.rec('CM16 an unrelated DM gets "Content not found" (no campaign name, no existence leak)',
  tl_test.cm_err(format('select public.get_dm_content_usage(%L)', :'d_bg')) = '42501: Content not found'
  and tl_test.cm_err(format('select public.delete_unused_dm_content(%L, %L)', :'d_bg', 'Sage (homebrew)')) = '42501: Content not found'
  and tl_test.cm_err(format('select public.get_dm_content_usage(%L)', gen_random_uuid())) = '42501: Content not found');
select tl_test.as_root();
select set_config('request.jwt.claim.sub', '', true);
set local role anon;
select tl_test.rec('CM17 anonymous: no access to any content management function',
  tl_test.cm_code(format('select public.get_dm_content_usage(%L)', :'d_bg')) = '42501'
  and tl_test.cm_code(format('select public.delete_unused_dm_content(%L, %L)', :'d_bg', 'x')) = '42501'
  and tl_test.cm_code(format('select public.duplicate_official_as_homebrew(%L, %L, null)', 'spell', 'fire-bolt-phb')) = '42501');
reset role;

-- ---- safe permanent delete of unused content (every type) -----------------------------------------------------------------------
select tl_test.as_user(:'dm');
select tl_test.rec('CM18 the name must be typed exactly', tl_test.cm_code(format('select public.delete_unused_dm_content(%L, %L)', :'d_bg', 'sage')) = '22023'
  and tl_test.cm_exists(:'d_bg'));
select public.delete_unused_dm_content(:'d_bg', 'Sage (homebrew)') as del_bg \gset
select public.delete_unused_dm_content(:'d_lin', 'Chromatic Dragonborn (homebrew)') as del_lin \gset
select public.delete_unused_dm_content(:'d_item', 'Longsword (homebrew)') as del_item \gset
select public.delete_unused_dm_content(:'d_feat2', 'Alert (homebrew)') as del_feat2 \gset
select tl_test.as_root();
select tl_test.rec('CM19 unused background, lineage, item and feat are deleted with their catalog rows',
  not tl_test.cm_exists(:'d_bg') and not tl_test.cm_catalog('background', :'r_bg')
  and not tl_test.cm_exists(:'d_lin') and not tl_test.cm_catalog('lineage', :'r_lin')
  and not tl_test.cm_exists(:'d_item') and not tl_test.cm_catalog('item', :'r_item')
  and not tl_test.cm_exists(:'d_feat2') and not tl_test.cm_catalog('feat', :'r_feat2')
  and not exists (select 1 from public.backgrounds where id = split_part(:'r_bg', '-v', 1))
  and not exists (select 1 from public.lineages where id = split_part(:'r_lin', '-v', 1)));
select tl_test.rec('CM20 each delete wrote exactly one audit event (DM visibility), without player data',
  tl_test.cm_audits(:'d_bg') = 1 and tl_test.cm_audits(:'d_lin') = 1 and tl_test.cm_audits(:'d_item') = 1 and tl_test.cm_audits(:'d_feat2') = 1
  and (select bool_and(visibility = 'dm' and campaign_id = :'camp') from public.campaign_audit_events where event_type = 'content_deleted'));
select tl_test.as_user(:'dm');
select tl_test.rec('CM21 a repeated delete is safe: "Content not found", still one audit event',
  tl_test.cm_err(format('select public.delete_unused_dm_content(%L, %L)', :'d_bg', 'Sage (homebrew)')) = '42501: Content not found'
  and tl_test.cm_audits(:'d_bg') = 1);
-- a never-published draft is deleted the same way (any DM of the campaign, not only its author)
select public.create_dm_content('condition', :'camp', '{"name": "Draft Curse"}') ->> 'id' as d_draft \gset
select tl_test.rec('CM22 a never-published draft is safe_to_delete with edit_draft and is deleted',
  public.get_dm_content_usage(:'d_draft') ->> 'classification' = 'safe_to_delete' and public.get_dm_content_usage(:'d_draft') ->> 'edit' = 'edit_draft'
  and tl_test.cm_code(format('select public.delete_unused_dm_content(%L, %L)', :'d_draft', 'Draft Curse')) = 'ok' and not tl_test.cm_exists(:'d_draft'));

-- ---- history: an earlier assignment makes it archive_recommended; archive / restore keep the assignment working -----------------
select tl_test.as_root();
delete from public.character_feats where character_id = :'cmc2' and feat_version_id = :'r_feat';
select tl_test.as_user(:'dm');
select tl_test.rec('CM23 removed from the character but assigned before: archive_recommended, delete refused',
  public.get_dm_content_usage(:'d_feat') ->> 'classification' = 'archive_recommended'
  and tl_test.cm_code(format('select public.delete_unused_dm_content(%L, %L)', :'d_feat', 'Fey Touched (homebrew)')) = 'TLUSE'
  and tl_test.cm_catalog('feat', :'r_feat'));
select public.archive_dm_content(:'d_spell', 'Retired');
select tl_test.rec('CM24a archive keeps the existing assignment readable and is reported',
  exists (select 1 from jsonb_array_elements(public.get_character_spellbook(:'cmc1') -> 'spells') s where s ->> 'id' = :'r_spell')
  and (public.get_dm_content_usage(:'d_spell') ->> 'archived')::boolean and not (public.get_dm_content_usage(:'d_spell') ->> 'can_archive')::boolean);
select public.restore_dm_content(:'d_spell');
select tl_test.rec('CM24 restore brings it back; usage unchanged',
  not (public.get_dm_content_usage(:'d_spell') ->> 'archived')::boolean
  and (public.get_dm_content_usage(:'d_spell') -> 'counts' ->> 'character_spells')::int = 1);
select public.new_dm_content_version(:'d_spell');
select tl_test.rec('CM25 a new version of used content is a draft; the character keeps the published version',
  (select status from public.dm_content_versions where id = (select current_version_id from public.dm_content where id = :'d_spell')) = 'draft'
  and exists (select 1 from public.character_spells where character_id = :'cmc1' and spell_version_id = :'r_spell'));
