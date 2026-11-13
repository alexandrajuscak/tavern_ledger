-- =============================================================================
-- Rollback of 20261113000100_crafting_v1.sql. Run as postgres in ONE transaction:
--   psql -v ON_ERROR_STOP=1 -1 -f supabase/rollback/rollback_crafting_v1.sql
-- Restores the exact previous bodies of the four replaced functions (captured with pg_get_functiondef from the local database at
-- 20261112000400; md5 of pg_get_functiondef, first 8: _item_dependencies 7f355733, preview_item_deletion f612021c,
-- _dm_content_dependencies 02ef480f, get_dm_content_usage_detail fe9bc419; grants are unchanged by CREATE OR REPLACE), drops
-- every new function and table, and removes the governance action inventory.craft (its per-campaign overrides go with it:
-- campaign_policy_overrides cascades). No existing row is changed.
-- Data LOST on purpose (it only exists because of this feature; export it first if it matters):
--   select * from public.crafting_recipes; select * from public.crafting_recipe_ingredients;
--   select * from public.character_known_recipes; select * from public.crafting_attempts;
-- KEPT: inventory rows produced / consumed by applied attempts (ordinary inventory rows), their inventory_events
-- (metadata.craft_attempt), knowledge records written by a produced item, audit events.
-- Deploy order for a rollback: the previous frontend (?v=27) first, then this file.
-- =============================================================================
do $$
begin
  if exists (select 1 from public.change_requests where action_type = 'inventory.craft')
     or exists (select 1 from public.change_request_ops where action_key = 'inventory.craft') then
    raise exception 'A change request names inventory.craft: resolve it before rolling back';
  end if;
end $$;
CREATE OR REPLACE FUNCTION public._item_dependencies(p_item text, p_self_content uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select jsonb_build_object(
    'character_inventories', (select count(*) from public.inventory_items ii join public.inventories inv on inv.id = ii.inventory_id
                              where ii.item_id = p_item and inv.kind = 'character'),
    'other_inventories', (select count(*) from public.inventory_items ii join public.inventories inv on inv.id = ii.inventory_id
                          where ii.item_id = p_item and inv.kind <> 'character'),
    'equipped_or_attuned', (select count(*) from public.inventory_items ii where ii.item_id = p_item and (ii.equipped or ii.is_attuned)),
    'in_containers', (select count(*) from public.inventory_items ii where ii.item_id = p_item and ii.container_item_id is not null),
    'owned_assets', (select count(*) from public.owned_assets where item_id = p_item),
    'background_equipment', (select count(*) from public.background_equipment_entries where item_id = p_item),
    'proficiencies', (select count(*) from public.character_proficiencies where item_id = p_item),
    'items_based_on_it', (select count(*) from public.items where base_item_id = p_item),
    'inventory_history', (select count(*) from public.inventory_events where item_id = p_item),
    'pending_requests', (select count(*) from public.change_requests r where r.status in ('submitted', 'returned_for_changes', 'apply_failed')
                         and not r.stale and public._json_mentions(r.ops::text, p_item)),
    'request_history', (select count(*) from public.change_requests r
                        where (r.status = 'draft' or (r.status in ('submitted', 'returned_for_changes', 'apply_failed') and r.stale))
                        and public._json_mentions(r.ops::text, p_item)),
    'dm_content_versions', (select count(*) from public.dm_content_versions v where v.catalog_ref = p_item
                            and v.content_id is distinct from p_self_content));
$function$
;
CREATE OR REPLACE FUNCTION public.preview_item_deletion(p_item text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare it public.items; d jsonb; n int; dm uuid; reasons text[] := '{}'; hist text[] := '{}';
begin
  select * into it from public.items where id = p_item;
  if it.id is null or not public.can_view_owned(it.owner_id, it.campaign_id) then raise exception 'Unknown item' using errcode = 'P0002'; end if;
  if it.owner_id is null then
    return jsonb_build_object('item_id', it.id, 'name', it.name, 'deletable', false, 'official', true, 'reasons', jsonb_build_array('Official items are never deleted.'));
  end if;
  if not public.can_edit_owned(it.owner_id, it.campaign_id) then raise exception 'Not allowed to change this item' using errcode = '42501'; end if;
  select content_id into dm from public.dm_content_versions where catalog_ref = p_item limit 1;
  d := public._item_dependencies(p_item, dm);
  n := public._item_blocking(d);
  if (d ->> 'character_inventories')::int > 0 then reasons := reasons || format('%s character inventory entr%s', d ->> 'character_inventories', case when (d ->> 'character_inventories')::int = 1 then 'y' else 'ies' end); end if;
  if (d ->> 'other_inventories')::int > 0 then reasons := reasons || format('%s stash or party entr%s', d ->> 'other_inventories', case when (d ->> 'other_inventories')::int = 1 then 'y' else 'ies' end); end if;
  if (d ->> 'owned_assets')::int > 0 then reasons := reasons || 'owned assets'::text; end if;
  if (d ->> 'background_equipment')::int > 0 then reasons := reasons || 'background starting equipment'::text; end if;
  if (d ->> 'proficiencies')::int > 0 then reasons := reasons || 'character proficiencies'::text; end if;
  if (d ->> 'items_based_on_it')::int > 0 then reasons := reasons || 'other items are based on it'::text; end if;
  if (d ->> 'pending_requests')::int > 0 then reasons := reasons || 'submitted change requests'::text; end if;
  if (d ->> 'dm_content_versions')::int > 0 then reasons := reasons || 'other DM content versions'::text; end if;
  if (d ->> 'inventory_history')::int > 0 then hist := hist || format('%s inventory history entr%s', d ->> 'inventory_history', case when (d ->> 'inventory_history')::int = 1 then 'y' else 'ies' end); end if;
  if (d ->> 'request_history')::int > 0 then hist := hist || 'draft or outdated change requests'::text; end if;
  return jsonb_build_object('item_id', it.id, 'name', it.name, 'kind_id', it.kind_id, 'archived', it.archived_at is not null,
    'dm_content_id', dm, 'deletable', n = 0, 'dependencies', d, 'reasons', to_jsonb(reasons), 'history', to_jsonb(hist),
    'advice', case when n = 0 and cardinality(hist) > 0 then 'Nothing uses this definition now. Deleting it cannot be undone; its history stays readable under its name.'
                   when n = 0 then 'Nothing uses this definition. Deleting it cannot be undone.'
                   when it.archived_at is not null then 'This archived definition is still in use. Remove it from those places first; then it can be deleted.'
                   else 'This definition is in use. Archive it instead: it can no longer be added, and every existing entry keeps working.' end);
end $function$
;
CREATE OR REPLACE FUNCTION public._dm_content_dependencies(p_content uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare c public.dm_content; refs text[]; vids uuid[]; base text; d jsonb := '{}'; cur int := 0; hist int := 0; n int;
  item jsonb; r text;
begin
  select * into c from public.dm_content where id = p_content;
  if c.id is null then return null; end if;
  select coalesce(array_agg(v.catalog_ref) filter (where v.catalog_ref is not null), '{}'), coalesce(array_agg(v.id), '{}')
    into refs, vids from public.dm_content_versions v where v.content_id = p_content;
  base := public._dm_short(p_content);
  -- current use, per type
  case c.content_type
  when 'spell' then
    d := d || jsonb_build_object(
      'character_spells', (select count(*) from public.character_spells where spell_version_id = any (refs)),
      'character_resources', (select count(*) from public.character_resources where spell_version_id = any (refs)),
      'feat_spell_grants', (select count(*) from public.feat_spell_grants where spell_version_id = any (refs)),
      'class_feature_effects', (select count(*) from public.class_feature_effects where spell_version_id = any (refs)));
  when 'item' then
    foreach r in array refs loop
      item := public._item_dependencies(r, p_content);
      d := d || jsonb_build_object(
        'inventory_instances', coalesce((d ->> 'inventory_instances')::int, 0) + coalesce((item ->> 'character_inventories')::int, 0) + coalesce((item ->> 'other_inventories')::int, 0),
        'inventory_history', coalesce((d ->> 'inventory_history')::int, 0) + coalesce((item ->> 'inventory_history')::int, 0),
        'owned_assets', coalesce((d ->> 'owned_assets')::int, 0) + coalesce((item ->> 'owned_assets')::int, 0),
        'background_equipment', coalesce((d ->> 'background_equipment')::int, 0) + coalesce((item ->> 'background_equipment')::int, 0),
        'proficiencies', coalesce((d ->> 'proficiencies')::int, 0) + coalesce((item ->> 'proficiencies')::int, 0),
        'items_based_on_it', coalesce((d ->> 'items_based_on_it')::int, 0) + coalesce((item ->> 'items_based_on_it')::int, 0));
    end loop;
    d := d || jsonb_build_object(
      'equipped_instances', (select count(*) from public.character_equipment e join public.inventory_items ii on ii.id = e.inventory_item_id where ii.item_id = any (refs)),
      'attuned_instances', (select count(*) from public.inventory_items ii where ii.item_id = any (refs) and coalesce(ii.is_attuned, false)));
  when 'feat' then
    d := d || jsonb_build_object(
      'feat_assignments', (select count(*) from public.character_feats where feat_version_id = any (refs)),
      'feat_choices', (select count(*) from public.character_feat_choices x join public.feat_choices fc on fc.id = x.choice_id where fc.version_id = any (refs)),
      'lineage_feat_picks', (select count(*) from public.character_lineage_choices where value = any (array(select 'feat:' || x from unnest(refs) x))),
      'class_feat_picks', (select count(*) from public.character_feature_choice_values where value = any (array(select 'feat:' || x from unnest(refs) x))),
      'backgrounds_granting', (select count(*) from public.background_feat_grants where feat_id = any (refs)));
  when 'creature', 'companion' then
    d := d || jsonb_build_object(
      'seen_forms', (select count(*) from public.character_seen_forms where creature_id = any (refs)),
      'form_favorites', (select count(*) from public.character_form_favorites where creature_id = any (refs)),
      'companions', (select count(*) from public.character_companions where creature_id = any (refs) or template_version_id = any (vids)),
      'transformations', (select count(*) from public.character_transformations where creature_id = any (refs)),
      'active_encounter_snapshots', (select count(*) from public.combat_statblocks s join public.combat_encounters e on e.id = s.encounter_id
                                     where s.source_id = any (refs) and e.status <> 'completed'));
  when 'background' then
    d := d || jsonb_build_object(
      'background_assignments', (select count(*) from public.character_backgrounds where version_id = any (refs)),
      'background_equipment', (select count(*) from public.character_background_equipment where version_id = any (refs)),
      'background_choices', (select count(*) from public.character_background_choices x join public.background_choices bc on bc.id = x.choice_id where bc.version_id = any (refs)));
  when 'lineage' then
    d := d || jsonb_build_object(
      'lineage_assignments', (select count(*) from public.character_lineages where version_id = any (refs) or subversion_id = any (refs)),
      'lineage_choices', (select count(*) from public.character_lineage_choices x join public.lineage_choices lc on lc.id = x.choice_id where lc.version_id = any (refs)));
  when 'condition' then
    d := d || jsonb_build_object('condition_assignments', (select count(*) from public.character_conditions where content_version_id = any (vids)));
  else null;
  end case;
  d := d || jsonb_build_object(
    -- a request the DM can still approve; a player's draft or a stale request is history (below)
    'pending_requests', (select count(*) from public.change_requests cr where cr.status in ('submitted', 'returned_for_changes', 'apply_failed')
                         and not cr.stale and exists (select 1 from unnest(refs) x where public._json_mentions(cr.ops::text, x))),
    -- only the published version of other content that is not archived depends on it
    'other_content', (select count(*) from public.dm_content_versions ov join public.dm_content oc on oc.id = ov.content_id
                      where ov.content_id <> p_content and ov.id = oc.published_version_id and oc.archived_at is null and oc.status <> 'archived'
                      and exists (select 1 from unnest(refs) x where public._json_mentions(ov.definition::text, x))));
  -- every key so far is current use, except inventory_history (history, never blocking)
  select coalesce(sum(value::int), 0) into cur from jsonb_each_text(d) where key <> 'inventory_history';
  -- history: kept for the record and readable after a delete; only completed encounter snapshots still block (creatures)
  d := d || jsonb_build_object(
    'completed_encounter_snapshots', case when c.content_type in ('creature', 'companion') then
        (select count(*) from public.combat_statblocks s join public.combat_encounters e on e.id = s.encounter_id where s.source_id = any (refs) and e.status = 'completed') else 0 end,
    'audit_references', (select count(*) from public.campaign_audit_events a where a.campaign_id is not distinct from c.campaign_id
                         and a.character_id is not null   -- a character's history (the content's own publish / archive events do not count)
                         and exists (select 1 from unnest(refs) x where public._json_mentions(coalesce(a.before::text, '') || coalesce(a.after::text, ''), x))),
    'earlier_assignments', (select count(*) from public.dm_content_events ev where ev.content_id = p_content and ev.event = 'assigned'),
    'request_history', (select count(*) from public.change_requests cr
                        where (cr.status = 'draft' or (cr.status in ('submitted', 'returned_for_changes', 'apply_failed') and cr.stale))
                        and exists (select 1 from unnest(refs) x where public._json_mentions(cr.ops::text, x))),
    'other_content_history', (select count(*) from public.dm_content_versions ov join public.dm_content oc on oc.id = ov.content_id
                              where ov.content_id <> p_content
                              and not (ov.id = oc.published_version_id and oc.archived_at is null and oc.status <> 'archived')
                              and exists (select 1 from unnest(refs) x where public._json_mentions(ov.definition::text, x))));
  hist := (d ->> 'completed_encounter_snapshots')::int + (d ->> 'audit_references')::int + (d ->> 'earlier_assignments')::int
          + coalesce((d ->> 'inventory_history')::int, 0) + (d ->> 'request_history')::int + (d ->> 'other_content_history')::int;
  n := (select count(distinct x.cid) from (
      select character_id as cid from public.character_spells where spell_version_id = any (refs)
      union all select ii.character_id from public.inventory_items ii where ii.item_id = any (refs)
      union all select character_id from public.character_feats where feat_version_id = any (refs)
      union all select character_id from public.character_lineage_choices where value = any (array(select 'feat:' || x from unnest(refs) x))
      union all select ch.character_id from public.character_feature_choice_values fv join public.character_feature_choices ch on ch.id = fv.character_choice_id
                where fv.value = any (array(select 'feat:' || x from unnest(refs) x))
      union all select character_id from public.character_seen_forms where creature_id = any (refs)
      union all select character_id from public.character_companions where creature_id = any (refs) or template_version_id = any (vids)
      union all select character_id from public.character_transformations where creature_id = any (refs)
      union all select character_id from public.character_backgrounds where version_id = any (refs)
      union all select character_id from public.character_lineages where version_id = any (refs) or subversion_id = any (refs)
      union all select character_id from public.character_conditions where content_version_id = any (vids)) x where x.cid is not null);
  return jsonb_build_object('counts', d, 'characters', n, 'current', cur, 'history', hist,
                            'blocking_history', (d ->> 'completed_encounter_snapshots')::int, 'published_versions', cardinality(refs),
                            'catalog_refs', to_jsonb(refs), 'base', base);
end $function$
;
CREATE OR REPLACE FUNCTION public.get_dm_content_usage_detail(p_content uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare c public.dm_content; refs text[]; vids uuid[]; admin boolean; me uuid := auth.uid(); places jsonb; hidden int; total int;
  lim constant int := 200; d jsonb;
begin
  if me is null or not public._dm_can_manage(p_content) then raise exception 'Content not found' using errcode = '42501'; end if;
  select * into c from public.dm_content where id = p_content;
  select coalesce(array_agg(v.catalog_ref) filter (where v.catalog_ref is not null), '{}'), coalesce(array_agg(v.id), '{}')
    into refs, vids from public.dm_content_versions v where v.content_id = p_content;
  admin := public.is_admin();
  with uses as (
    -- inventory entries: character inventories, party stash, NPC, shop and personal stashes
    select 10 as ord, jsonb_build_object(
             'kind', case inv.kind when 'character' then 'character_inventory' when 'party_stash' then 'party_stash'
                                   when 'npc' then 'npc_inventory' when 'shop' then 'shop' else 'stash' end,
             'character_id', ch.id, 'character_name', ch.name, 'inventory_id', inv.id, 'inventory_name', inv.name,
             'entry_name', ii.name, 'quantity', ii.quantity, 'equipped', coalesce(ii.equipped, false), 'attuned', coalesce(ii.is_attuned, false),
             'in_container', ii.container_item_id is not null, 'blocks', true) as j,
           coalesce(ch.campaign_id, inv.campaign_id) as camp, inv.owner_id as owner
      from public.inventory_items ii join public.inventories inv on inv.id = ii.inventory_id
      left join public.characters ch on ch.id = inv.character_id
     where c.content_type = 'item' and ii.item_id = any (refs)
    union all
    -- other per-character uses (one row per character and kind of use)
    select 20, jsonb_build_object('kind', 'character', 'use', x.use, 'character_id', ch.id, 'character_name', ch.name, 'count', count(*), 'blocks', true),
           ch.campaign_id, null::uuid
      from (
        select character_id, 'owned asset' as use from public.owned_assets where c.content_type = 'item' and item_id = any (refs)
        union all select character_id, 'proficiency' from public.character_proficiencies where c.content_type = 'item' and item_id = any (refs)
        union all select character_id, 'knows or prepares the spell' from public.character_spells where c.content_type = 'spell' and spell_version_id = any (refs)
        union all select character_id, 'free-cast counter' from public.character_resources where c.content_type = 'spell' and spell_version_id = any (refs)
        union all select character_id, 'has the feat' from public.character_feats where c.content_type = 'feat' and feat_version_id = any (refs)
        union all select x.character_id, 'saved feat choice' from public.character_feat_choices x join public.feat_choices fc on fc.id = x.choice_id
                  where c.content_type = 'feat' and fc.version_id = any (refs)
        union all select character_id, 'lineage feat pick' from public.character_lineage_choices
                  where c.content_type = 'feat' and value = any (array(select 'feat:' || r from unnest(refs) r))
        union all select ch2.character_id, 'Ability Score Improvement feat pick' from public.character_feature_choice_values fv
                  join public.character_feature_choices ch2 on ch2.id = fv.character_choice_id
                  where c.content_type = 'feat' and fv.value = any (array(select 'feat:' || r from unnest(refs) r))
        union all select character_id, 'Wild Shape form known' from public.character_seen_forms where c.content_type in ('creature', 'companion') and creature_id = any (refs)
        union all select character_id, 'form favourite' from public.character_form_favorites where c.content_type in ('creature', 'companion') and creature_id = any (refs)
        union all select character_id, 'companion' from public.character_companions
                  where c.content_type in ('creature', 'companion') and (creature_id = any (refs) or template_version_id = any (vids))
        union all select character_id, 'active transformation' from public.character_transformations where c.content_type in ('creature', 'companion') and creature_id = any (refs)
        union all select character_id, 'background' from public.character_backgrounds where c.content_type = 'background' and version_id = any (refs)
        union all select character_id, 'background equipment' from public.character_background_equipment where c.content_type = 'background' and version_id = any (refs)
        union all select x.character_id, 'saved background choice' from public.character_background_choices x join public.background_choices bc on bc.id = x.choice_id
                  where c.content_type = 'background' and bc.version_id = any (refs)
        union all select character_id, 'lineage' from public.character_lineages where c.content_type = 'lineage' and (version_id = any (refs) or subversion_id = any (refs))
        union all select x.character_id, 'saved lineage choice' from public.character_lineage_choices x join public.lineage_choices lc on lc.id = x.choice_id
                  where c.content_type = 'lineage' and lc.version_id = any (refs)
        union all select character_id, 'applied condition' from public.character_conditions where c.content_type = 'condition' and content_version_id = any (vids)
      ) x join public.characters ch on ch.id = x.character_id
     group by x.use, ch.id, ch.name, ch.campaign_id
    union all
    -- change requests the DM can still approve (drafts and stale requests are history: counted only)
    select 30, jsonb_build_object('kind', 'request', 'request_id', cr.id, 'status', cr.status, 'title', cr.title,
                                  'character_id', ch.id, 'character_name', ch.name, 'submitted_at', cr.submitted_at, 'blocks', true),
           cr.campaign_id, null::uuid
      from public.change_requests cr join public.characters ch on ch.id = cr.character_id
     where cr.status in ('submitted', 'returned_for_changes', 'apply_failed') and not cr.stale
       and exists (select 1 from unnest(refs) r where public._json_mentions(cr.ops::text, r))
    union all
    -- encounters with a stat block snapshot of the creature (running / planned: current use; completed: encounter history)
    select 40, jsonb_build_object('kind', 'encounter', 'encounter_id', e.id, 'encounter_name', e.name, 'status', e.status, 'blocks', true),
           e.campaign_id, null::uuid
      from public.combat_encounters e
     where c.content_type in ('creature', 'companion')
       and exists (select 1 from public.combat_statblocks s where s.encounter_id = e.id and s.source_id = any (refs))
    union all
    -- published, not archived content that names it
    select 50, jsonb_build_object('kind', 'other_content', 'content_id', oc.id, 'content_name', oc.name, 'content_type', oc.content_type,
                                  'status', oc.status, 'blocks', true),
           oc.campaign_id, case when oc.campaign_id is null then oc.author_id end
      from public.dm_content oc join public.dm_content_versions ov on ov.id = oc.published_version_id
     where oc.id <> p_content and oc.archived_at is null and oc.status <> 'archived'
       and exists (select 1 from unnest(refs) r where public._json_mentions(ov.definition::text, r))
  ), vis as (
    select ord, j, camp, (admin or (camp is not null and public.is_campaign_dm(camp)) or (camp is null and owner = me)) as visible from uses
  )
  select coalesce(jsonb_agg(v.j || jsonb_build_object('campaign_id', v.camp, 'campaign_name', k.name)
                            order by v.ord, v.j ->> 'character_name', v.j ->> 'inventory_name') filter (where v.visible), '[]'::jsonb),
         count(*) filter (where not v.visible), count(*) filter (where v.visible)
    into places, hidden, total
    from vis v left join public.campaigns k on k.id = v.camp;
  if jsonb_array_length(places) > lim then
    places := (select jsonb_agg(e) from (select e from jsonb_array_elements(places) with ordinality t(e, i) where i <= lim) s);
  end if;
  d := public._dm_content_dependencies(p_content) -> 'counts';
  return jsonb_build_object('content_id', c.id, 'name', c.name, 'content_type', c.content_type, 'archived', c.archived_at is not null,
    'places', places, 'total_places', total, 'truncated', total > lim, 'hidden_places', hidden,
    'history', jsonb_strip_nulls(jsonb_build_object(
      'inventory_history', d -> 'inventory_history', 'audit_references', d -> 'audit_references', 'earlier_assignments', d -> 'earlier_assignments',
      'request_history', d -> 'request_history', 'other_content_history', d -> 'other_content_history',
      'completed_encounter_snapshots', d -> 'completed_encounter_snapshots')));
end $function$
;

drop function if exists public.get_character_recipes(uuid);
drop function if exists public.start_craft_attempt(uuid, uuid, jsonb, int, uuid, text, text);
drop function if exists public.cancel_craft_attempt(uuid);
drop function if exists public.mark_recipes_seen(uuid);
drop function if exists public.dm_save_recipe(uuid, jsonb, int);
drop function if exists public.dm_set_recipe_status(uuid, text);
drop function if exists public.dm_grant_recipe(uuid, uuid[], boolean);
drop function if exists public.dm_resolve_craft_attempt(uuid, text, text, int, text, text, text, int);
drop function if exists public.get_campaign_recipes(uuid);
drop function if exists public.get_campaign_craft_attempts(uuid, text);
drop function if exists public.get_campaign_pending_craft_count(uuid);
drop function if exists public.get_campaign_craft_items(uuid, text);
drop function if exists public._craft_apply(uuid, text, text);
drop function if exists public._craft_produce(uuid, uuid, text, int, boolean, jsonb);
drop function if exists public._craft_audit(public.crafting_attempts);
drop function if exists public._craft_attempt_player(public.crafting_attempts);
drop function if exists public._craft_attempt_dm(public.crafting_attempts);
drop function if exists public._craft_recipe_player(uuid, uuid);
drop function if exists public._craft_recipe_dm(uuid);
drop function if exists public._craft_row_matches(text, public.crafting_recipe_ingredients);
drop function if exists public._craft_row_known(uuid);
drop function if exists public._craft_row_free(uuid);
drop function if exists public._craft_item_known(uuid, text);
drop function if exists public._craft_item_ok(text, uuid);
drop function if exists public._craft_player_gate(uuid);
drop function if exists public._craft_dm_gate(uuid);
drop table if exists public.crafting_attempts;
drop table if exists public.character_known_recipes;
drop table if exists public.crafting_recipe_ingredients;
drop table if exists public.crafting_recipes;
delete from public.governance_actions where action_key = 'inventory.craft';
do $$
begin
  if to_regclass('supabase_migrations.schema_migrations') is not null then
    delete from supabase_migrations.schema_migrations where version = '20261113000100';
  end if;
end $$;
notify pgrst, 'reload schema';