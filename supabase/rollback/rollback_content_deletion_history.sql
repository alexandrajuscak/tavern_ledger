-- Rollback of 20261112000100_content_deletion_history.sql: drops the four new functions and restores the exact previous bodies
-- of the eight replaced ones (captured with pg_get_functiondef from the local database at 20261109000300; md5 of
-- pg_get_functiondef: _item_dependencies 90ba3fce, _item_blocking 221a113f, preview_item_deletion 1a47e667,
-- delete_custom_item 4ec27602, delete_unused_dm_item 20be018a, _dm_content_dependencies b4299c79, get_dm_content_usage 5c7c62f9,
-- delete_unused_dm_content 54be8932). Grants are unchanged by CREATE OR REPLACE.
-- DATA: no row is changed. inventory_events.metadata.deleted_item stamps written by deletes made meanwhile stay (additive history);
-- content deleted meanwhile stays deleted. After the rollback history blocks deletion again. Deploy the previous frontend first or
-- together (the new usage dialog calls get_dm_content_usage_detail; without it the dialog only shows the counts).
begin;
drop function if exists public.get_dm_content_usage_detail(uuid);
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
    'pending_requests', (select count(*) from public.change_requests r where r.status in ('draft', 'submitted', 'returned_for_changes')
                         and r.ops::text like '%"' || p_item || '"%'),
    'dm_content_versions', (select count(*) from public.dm_content_versions v where v.catalog_ref = p_item
                            and v.content_id is distinct from p_self_content));
$function$
;
CREATE OR REPLACE FUNCTION public._item_blocking(d jsonb)
 RETURNS integer
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select coalesce(sum(value::int), 0)::int from jsonb_each_text(d) where key <> 'equipped_or_attuned' and key <> 'in_containers';
$function$
;
CREATE OR REPLACE FUNCTION public.preview_item_deletion(p_item text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare it public.items; d jsonb; n int; dm uuid; reasons text[] := '{}';
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
  if (d ->> 'inventory_history')::int > 0 then reasons := reasons || 'it has inventory history'::text; end if;
  if (d ->> 'owned_assets')::int > 0 then reasons := reasons || 'owned assets'::text; end if;
  if (d ->> 'background_equipment')::int > 0 then reasons := reasons || 'background starting equipment'::text; end if;
  if (d ->> 'proficiencies')::int > 0 then reasons := reasons || 'character proficiencies'::text; end if;
  if (d ->> 'items_based_on_it')::int > 0 then reasons := reasons || 'other items are based on it'::text; end if;
  if (d ->> 'pending_requests')::int > 0 then reasons := reasons || 'pending change requests'::text; end if;
  if (d ->> 'dm_content_versions')::int > 0 then reasons := reasons || 'other DM content versions'::text; end if;
  return jsonb_build_object('item_id', it.id, 'name', it.name, 'kind_id', it.kind_id, 'archived', it.archived_at is not null,
    'dm_content_id', dm, 'deletable', n = 0, 'dependencies', d, 'reasons', to_jsonb(reasons),
    'advice', case when n = 0 then 'Nothing uses this definition. Deleting it cannot be undone.'
                   else 'This definition is in use. Archive it instead: it can no longer be added, and every existing entry keeps working.' end);
end $function$
;
CREATE OR REPLACE FUNCTION public.delete_custom_item(p_item text, p_confirm_name text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare it public.items; d jsonb;
begin
  it := public._lock_homebrew(p_item);           -- access first (no governance text for strangers); FOR UPDATE: a concurrent
                                                 -- "add to inventory" waits, then fails its foreign key
  perform public._gov_content_gate(it.campaign_id, 'content.create_item');
  if exists (select 1 from public.dm_content_versions where catalog_ref = p_item) then
    raise exception 'This item is managed in DM Space. Delete or archive it there.' using errcode = '22023';
  end if;
  if coalesce(btrim(p_confirm_name), '') <> it.name then raise exception 'Type the item name to confirm' using errcode = '22023'; end if;
  d := public._item_dependencies(p_item, null);   -- rechecked here, under the lock
  if public._item_blocking(d) > 0 then
    raise exception 'This item is in use (inventories, history or requests). Archive it instead; nothing was deleted.' using errcode = 'TLUSE', hint = 'archive';
  end if;
  delete from public.items where id = p_item;
  return jsonb_build_object('deleted', p_item, 'name', it.name);
exception when foreign_key_violation then
  raise exception 'This item is in use. Archive it instead; nothing was deleted.' using errcode = 'TLUSE', hint = 'archive';
end $function$
;
CREATE OR REPLACE FUNCTION public.delete_unused_dm_item(p_content uuid, p_confirm_name text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare c public.dm_content; r record; d jsonb; refs text[] := '{}';
begin
  if not public._dm_can_manage(p_content) then raise exception 'Content not found' using errcode = '42501'; end if;
  select * into c from public.dm_content where id = p_content for update;
  if c.content_type <> 'item' then raise exception 'Only unused items can be deleted after publishing; archive other content' using errcode = '22023'; end if;
  if c.author_id <> auth.uid() and not public.is_admin() then raise exception 'Only the author can delete this item' using errcode = '42501'; end if;
  if coalesce(btrim(p_confirm_name), '') <> c.name then raise exception 'Type the item name to confirm' using errcode = '22023'; end if;
  for r in select v.catalog_ref from public.dm_content_versions v where v.content_id = p_content and v.catalog_ref is not null loop
    perform 1 from public.items where id = r.catalog_ref for update;
    d := public._item_dependencies(r.catalog_ref, p_content);
    if public._item_blocking(d) > 0 then
      raise exception 'A version of this item is in use. Archive it instead; nothing was deleted.' using errcode = 'TLUSE', hint = 'archive';
    end if;
    refs := refs || r.catalog_ref;
  end loop;
  if exists (select 1 from public.character_conditions k join public.dm_content_versions v on v.id = k.content_version_id where v.content_id = p_content) then
    raise exception 'This content is in use. Archive it instead; nothing was deleted.' using errcode = 'TLUSE', hint = 'archive';
  end if;
  update public.dm_content set current_version_id = null, published_version_id = null where id = p_content;
  delete from public.items where id = any (refs);
  delete from public.dm_content where id = p_content;
  return jsonb_build_object('deleted', p_content, 'name', c.name, 'item_versions', to_jsonb(refs));
exception when foreign_key_violation then
  raise exception 'This item is in use. Archive it instead; nothing was deleted.' using errcode = 'TLUSE', hint = 'archive';
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
    'pending_requests', (select count(*) from public.change_requests cr where cr.status in ('draft', 'submitted', 'returned_for_changes')
                         and exists (select 1 from unnest(refs) x where cr.ops::text like '%' || x || '%')),
    'other_content', (select count(*) from public.dm_content_versions ov where ov.content_id <> p_content
                      and exists (select 1 from unnest(refs) x where ov.definition::text like '%"' || x || '"%')));
  select coalesce(sum(value::int), 0) into cur from jsonb_each_text(d) where key not in ('inventory_history', 'items_based_on_it');
  cur := cur + coalesce((d ->> 'items_based_on_it')::int, 0);
  -- history: kept for the record, so the content is archived instead of deleted
  d := d || jsonb_build_object(
    'completed_encounter_snapshots', case when c.content_type in ('creature', 'companion') then
        (select count(*) from public.combat_statblocks s join public.combat_encounters e on e.id = s.encounter_id where s.source_id = any (refs) and e.status = 'completed') else 0 end,
    'audit_references', (select count(*) from public.campaign_audit_events a where a.campaign_id is not distinct from c.campaign_id
                         and a.character_id is not null   -- a character's history (the content's own publish / archive events do not count)
                         and exists (select 1 from unnest(refs) x where coalesce(a.before::text, '') || coalesce(a.after::text, '') like '%' || x || '%')),
    'earlier_assignments', (select count(*) from public.dm_content_events ev where ev.content_id = p_content and ev.event = 'assigned'));
  hist := (d ->> 'completed_encounter_snapshots')::int + (d ->> 'audit_references')::int + (d ->> 'earlier_assignments')::int
          + coalesce((d ->> 'inventory_history')::int, 0);
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
  return jsonb_build_object('counts', d, 'characters', n, 'current', cur, 'history', hist, 'published_versions', cardinality(refs),
                            'catalog_refs', to_jsonb(refs), 'base', base);
end $function$
;
CREATE OR REPLACE FUNCTION public.get_dm_content_usage(p_content uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare c public.dm_content; d jsonb; cls text; published boolean; author boolean; may_delete boolean;
begin
  if auth.uid() is null or not public._dm_can_manage(p_content) then raise exception 'Content not found' using errcode = '42501'; end if;
  select * into c from public.dm_content where id = p_content;
  d := public._dm_content_dependencies(p_content);
  published := c.published_version_id is not null or (d ->> 'published_versions')::int > 0;
  cls := case when (d ->> 'current')::int > 0 then 'delete_blocked'
              when (d ->> 'history')::int > 0 then 'archive_recommended'
              else 'safe_to_delete' end;
  author := c.author_id = auth.uid();
  may_delete := public.is_admin() or (c.campaign_id is not null and public.is_campaign_dm(c.campaign_id)) or (c.campaign_id is null and author);
  return jsonb_build_object(
    'content_id', c.id, 'name', c.name, 'content_type', c.content_type, 'status', c.status, 'source', 'campaign_custom',
    'scope', c.scope, 'archived', c.archived_at is not null,
    'version_no', (select version_no from public.dm_content_versions where id = coalesce(c.published_version_id, c.current_version_id)),
    'characters', d -> 'characters', 'counts', d -> 'counts', 'current_uses', d -> 'current', 'history_references', d -> 'history',
    'published_versions', d -> 'published_versions',
    'classification', cls,
    'edit', case when not published then 'edit_draft' when (d ->> 'current')::int > 0 then 'new_version_required' else 'new_version' end,
    'can_delete', may_delete and cls = 'safe_to_delete',
    'can_archive', published and c.archived_at is null,
    'advice', case cls
      when 'safe_to_delete' then 'Nothing uses this content and nothing refers to it. Deleting it cannot be undone.'
      when 'archive_recommended' then 'Nothing uses it now, but it is part of the campaign history (an encounter, an earlier assignment or the audit log). Archive it: it can no longer be picked, and the history stays readable.'
      else 'It is in use. Archive it (no new picks; everything that has it keeps working) or remove it from the characters first.' end);
end $function$
;
CREATE OR REPLACE FUNCTION public.delete_unused_dm_content(p_content uuid, p_confirm_name text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare c public.dm_content; d jsonb; refs text[]; base text; vno int;
begin
  if auth.uid() is null or not public._dm_can_manage(p_content) then raise exception 'Content not found' using errcode = '42501'; end if;
  -- lock order: the content row, then its catalog rows (a concurrent assignment holds / waits for a key-share lock on them)
  select * into c from public.dm_content where id = p_content for update;
  if c.id is null then raise exception 'Content not found' using errcode = '42501'; end if;    -- deleted meanwhile (repeat / race)
  if not (public.is_admin() or (c.campaign_id is not null and public.is_campaign_dm(c.campaign_id)) or (c.campaign_id is null and c.author_id = auth.uid())) then
    raise exception 'Only a DM of this campaign or an admin can delete it' using errcode = '42501';
  end if;
  if coalesce(btrim(p_confirm_name), '') <> c.name then raise exception 'Type the exact name to confirm' using errcode = '22023'; end if;
  select coalesce(array_agg(catalog_ref) filter (where catalog_ref is not null), '{}') into refs from public.dm_content_versions where content_id = p_content;
  base := public._dm_short(p_content);
  case c.content_type
    when 'spell' then perform 1 from public.spell_versions where id = any (refs) for update;
    when 'item' then perform 1 from public.items where id = any (refs) for update;
    when 'feat' then perform 1 from public.feat_versions where id = any (refs) for update;
    when 'creature', 'companion' then perform 1 from public.creatures where id = any (refs) for update;
    when 'background' then perform 1 from public.background_versions where id = any (refs) for update;
    when 'lineage' then perform 1 from public.lineage_versions where id = any (refs) for update;
    else null;
  end case;
  -- the authoritative re-check, after the locks
  d := public._dm_content_dependencies(p_content);
  if (d ->> 'current')::int > 0 then
    raise exception 'This content is in use. Archive it instead; nothing was deleted.' using errcode = 'TLUSE', hint = 'archive';
  end if;
  if (d ->> 'history')::int > 0 then
    raise exception 'This content is part of the campaign history. Archive it instead; nothing was deleted.' using errcode = 'TLUSE', hint = 'archive';
  end if;
  select version_no into vno from public.dm_content_versions where id = coalesce(c.published_version_id, c.current_version_id);
  begin
    update public.dm_content set current_version_id = null, published_version_id = null where id = p_content;
    case c.content_type
      when 'spell' then
        delete from public.class_spell_list_entries where spell_version_id = any (refs);
        delete from public.spell_versions where id = any (refs);
        delete from public.catalog_spells s where s.id = base and not exists (select 1 from public.spell_versions v where v.spell_id = s.id);
      when 'item' then
        delete from public.items where id = any (refs);
      when 'feat' then
        delete from public.feat_versions where id = any (refs);
        delete from public.feats f where f.id = base and not exists (select 1 from public.feat_versions v where v.feat_id = f.id);
      when 'creature', 'companion' then
        delete from public.creatures where id = any (refs);
      when 'background' then
        delete from public.background_versions where id = any (refs);
        delete from public.backgrounds b where b.id = base and not exists (select 1 from public.background_versions v where v.background_id = b.id);
      when 'lineage' then
        delete from public.lineage_versions where id = any (refs);
        delete from public.lineages l where l.id = base and not exists (select 1 from public.lineage_versions v where v.lineage_id = l.id);
      else null;
    end case;
    delete from public.dm_content where id = p_content;
    insert into public.campaign_audit_events (campaign_id, actor_id, event_type, summary, before, visibility)
    values (c.campaign_id, auth.uid(), 'content_deleted', left(format('Deleted unused %s "%s"', replace(c.content_type, '_', ' '), c.name), 300),
            jsonb_build_object('content_id', c.id, 'content_type', c.content_type, 'name', c.name, 'version_no', vno, 'catalog_refs', to_jsonb(refs)), 'dm');
  exception when foreign_key_violation or restrict_violation then
    raise exception 'This content is in use. Archive it instead; nothing was deleted.' using errcode = 'TLUSE', hint = 'archive';
  end;
  return jsonb_build_object('deleted', p_content, 'name', c.name, 'content_type', c.content_type, 'catalog_refs', to_jsonb(refs));
end $function$
;
drop function if exists public._dm_content_assignments(uuid);
drop function if exists public._stamp_item_history(text[], uuid);
drop function if exists public._json_mentions(text, text);
commit;
