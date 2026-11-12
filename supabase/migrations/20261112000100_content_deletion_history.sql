-- Content deletion keeps history instead of being blocked by it (docs/CONTENT_MANAGEMENT.md, docs/CUSTOM_ITEM_DELETION.md).
-- ADDITIVE: replaces eight functions (same signatures and return types) and adds four; no table, column, policy or row changes
-- except the additive history stamp written at delete time.
--
-- Before: every item that was ever in an inventory, or assigned once, could never be deleted: _item_blocking counted
-- inventory_events, and delete_unused_dm_content refused on any history (earlier assignments, audit lines, inventory events).
-- An archived, unused item was a dead end (no archive, no delete). Now:
--  * CURRENT use still blocks (TLUSE): an inventory / stash / NPC / shop entry, equipped or attuned, owned assets, starting
--    equipment, proficiencies, items based on it, every assignment (spell, feat, form, companion, background, lineage,
--    condition), a running or planned encounter, a submitted / returned / apply_failed change request that is not stale, and
--    the PUBLISHED version of other, non-archived content that names it. inventory_items.item_id ON DELETE RESTRICT stays the
--    hard backstop; the delete functions still lock first and re-check inside the transaction.
--  * HISTORY no longer blocks: inventory events, audit lines, earlier assignments, player draft or stale requests, archived /
--    draft / superseded versions of other content. Completed encounter snapshots still block creatures (encounter history).
--  * Before the delete the history is preserved: inventory_events whose item link the FK nulls get
--    metadata.deleted_item = {id, name, content_id, deleted_at} (a player-safe name: the disguise for a secret item), and the
--    content_deleted audit event (DM visibility) lists the earlier assignments that the dm_content_events cascade removes.
--    inventory_events, audit events and encounter history are never deleted.
--  * Text references match exactly ("<ref>" or ":<ref>" followed by a quote), no LIKE wildcards, no v1 / v10 confusion.
--  * get_dm_content_usage: new classification delete_keeps_history (can_delete); an archived item is never told to archive.
--  * get_dm_content_usage_detail(content): WHERE content is used (character, inventory / stash, request, encounter, other
--    content) for a DM of the campaign / an admin; rows in campaigns the caller does not run are only counted. Same gate as
--    get_dm_content_usage: a player, an unrelated DM and anonymous get "Content not found".
-- Lock order is unchanged (dm_content -> catalog rows -> dependent rows); the stamp only updates inventory_events rows that the
-- FK SET NULL would update in the same transaction anyway.
-- Rollback: supabase/rollback/rollback_content_deletion_history.sql (restores the eight previous bodies, drops the four new).

-- exact text reference inside JSON text: "<ref>" or "<prefix>:<ref>" (e.g. "feat:<ref>")
create or replace function public._json_mentions(p_text text, p_ref text)
returns boolean language sql immutable set search_path = public, pg_temp as $$
  select p_text is not null and p_ref is not null and p_ref <> ''
         and (strpos(p_text, '"' || p_ref || '"') > 0 or strpos(p_text, ':' || p_ref || '"') > 0);
$$;
revoke all on function public._json_mentions(text, text) from public, anon, authenticated;

-- Everything that uses an item definition outside its own definition rows. History keys (inventory_history, request_history)
-- are reported but never block (see _item_blocking).
create or replace function public._item_dependencies(p_item text, p_self_content uuid default null)
returns jsonb language sql stable security definer set search_path = public, pg_temp as $$
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
$$;

-- blocking count: everything except flags (equipped, in containers: already counted as inventory entries) and history
create or replace function public._item_blocking(d jsonb)
returns int language sql immutable set search_path = public, pg_temp as $$
  select coalesce(sum(value::int), 0)::int from jsonb_each_text(d)
  where key not in ('equipped_or_attuned', 'in_containers', 'inventory_history', 'request_history');
$$;

-- Preserve the history of item definitions about to be deleted: the FK sets inventory_events.item_id to null, so the name is
-- stamped first (additive key, nothing overwritten). Player-safe: a secret (unidentified) item keeps its disguise here; the true
-- name is only in the DM-visibility audit event. Returns the number of stamped events.
create or replace function public._stamp_item_history(p_refs text[], p_content uuid default null)
returns int language plpgsql security definer set search_path = public, pg_temp as $$
declare n int;
begin
  update public.inventory_events e
     set metadata = coalesce(e.metadata, '{}'::jsonb) || jsonb_build_object('deleted_item', jsonb_strip_nulls(jsonb_build_object(
           'id', i.id,
           'name', case when i.secret then coalesce(nullif(btrim(s.unidentified_name), ''), 'an unidentified item') else i.name end,
           'content_id', p_content, 'deleted_at', now())))
    from public.items i left join public.item_secrets s on s.item_id = i.id
   where i.id = e.item_id and e.item_id = any (coalesce(p_refs, '{}')) and not (coalesce(e.metadata, '{}'::jsonb) ? 'deleted_item');
  get diagnostics n = row_count;
  return n;
end $$;
revoke all on function public._stamp_item_history(text[], uuid) from public, anon, authenticated;

-- the 'assigned' lifecycle events of a content (removed by the dm_content_events cascade): kept in the delete audit event
create or replace function public._dm_content_assignments(p_content uuid)
returns jsonb language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object('character_id', ev.detail ->> 'character_id', 'character_name', ch.name,
                                                                 'mode', ev.detail ->> 'mode', 'version_id', ev.version_id, 'at', ev.created_at))
                            order by ev.created_at), '[]'::jsonb)
  from public.dm_content_events ev left join public.characters ch on ch.id::text = ev.detail ->> 'character_id'
  where ev.content_id = p_content and ev.event = 'assigned';
$$;
revoke all on function public._dm_content_assignments(uuid) from public, anon, authenticated;

create or replace function public.preview_item_deletion(p_item text)
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
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
end $$;

-- permanent delete of an unused player / DM homebrew item (not managed DM content: see delete_unused_dm_content)
create or replace function public.delete_custom_item(p_item text, p_confirm_name text)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare it public.items; d jsonb; stamped int;
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
    raise exception 'This item is in use (inventories or requests). Archive it instead; nothing was deleted.' using errcode = 'TLUSE', hint = 'archive';
  end if;
  stamped := public._stamp_item_history(array[p_item], null);   -- history keeps the name; the FK nulls only the link
  delete from public.items where id = p_item;
  return jsonb_build_object('deleted', p_item, 'name', it.name, 'history_kept', stamped);
exception when foreign_key_violation then
  raise exception 'This item is in use. Archive it instead; nothing was deleted.' using errcode = 'TLUSE', hint = 'archive';
end $$;

-- permanent delete of a published DM content item whose versions are all unused (legacy path, content management off; author only)
create or replace function public.delete_unused_dm_item(p_content uuid, p_confirm_name text)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare c public.dm_content; r record; d jsonb; refs text[] := '{}'; asg jsonb; stamped int;
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
  asg := public._dm_content_assignments(p_content);
  stamped := public._stamp_item_history(refs, p_content);
  update public.dm_content set current_version_id = null, published_version_id = null where id = p_content;
  delete from public.items where id = any (refs);
  delete from public.dm_content where id = p_content;
  insert into public.campaign_audit_events (campaign_id, actor_id, event_type, summary, before, visibility)
  values (c.campaign_id, auth.uid(), 'content_deleted', left(format('Deleted unused item "%s"', c.name), 300),
          jsonb_build_object('content_id', c.id, 'content_type', c.content_type, 'name', c.name, 'catalog_refs', to_jsonb(refs),
                             'assignments', asg, 'history_kept', stamped), 'dm');
  return jsonb_build_object('deleted', p_content, 'name', c.name, 'item_versions', to_jsonb(refs), 'history_kept', stamped);
exception when foreign_key_violation then
  raise exception 'This item is in use. Archive it instead; nothing was deleted.' using errcode = 'TLUSE', hint = 'archive';
end $$;

create or replace function public._dm_content_dependencies(p_content uuid)
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
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
end $$;

create or replace function public.get_dm_content_usage(p_content uuid)
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
declare c public.dm_content; d jsonb; cls text; published boolean; author boolean; may_delete boolean; archived boolean;
begin
  if auth.uid() is null or not public._dm_can_manage(p_content) then raise exception 'Content not found' using errcode = '42501'; end if;
  select * into c from public.dm_content where id = p_content;
  d := public._dm_content_dependencies(p_content);
  published := c.published_version_id is not null or (d ->> 'published_versions')::int > 0;
  archived := c.archived_at is not null;
  cls := case when (d ->> 'current')::int > 0 then 'delete_blocked'
              when coalesce((d ->> 'blocking_history')::int, 0) > 0 then 'archive_recommended'
              when (d ->> 'history')::int > 0 then 'delete_keeps_history'
              else 'safe_to_delete' end;
  author := c.author_id = auth.uid();
  may_delete := public.is_admin() or (c.campaign_id is not null and public.is_campaign_dm(c.campaign_id)) or (c.campaign_id is null and author);
  return jsonb_build_object(
    'content_id', c.id, 'name', c.name, 'content_type', c.content_type, 'status', c.status, 'source', 'campaign_custom',
    'scope', c.scope, 'archived', archived,
    'version_no', (select version_no from public.dm_content_versions where id = coalesce(c.published_version_id, c.current_version_id)),
    'characters', d -> 'characters', 'counts', d -> 'counts', 'current_uses', d -> 'current', 'history_references', d -> 'history',
    'published_versions', d -> 'published_versions',
    'classification', cls,
    'edit', case when not published then 'edit_draft' when (d ->> 'current')::int > 0 then 'new_version_required' else 'new_version' end,
    'can_delete', may_delete and cls in ('safe_to_delete', 'delete_keeps_history'),
    'can_archive', published and not archived,
    'advice', case cls
      when 'safe_to_delete' then 'Nothing uses this content and nothing refers to it. Deleting it cannot be undone.'
      when 'delete_keeps_history' then 'Nothing uses it now. Deleting removes the definition for good; inventory history, audit lines and earlier assignments stay readable (the name is kept).'
                                       || case when archived then '' else ' Archive it instead if you may want it back.' end
      when 'archive_recommended' then case when archived then 'It appears in a completed encounter, so it stays archived: the encounter history keeps its stat block.'
        else 'Nothing uses it now, but it appears in a completed encounter. Archive it: it can no longer be picked, and the encounter history stays readable.' end
      else case when archived then 'It is archived but still in use. Remove it from the places listed below first; then it can be deleted.'
        else 'It is in use. Archive it (no new picks; everything that has it keeps working) or remove it from the places listed below first.' end end);
end $$;

create or replace function public.delete_unused_dm_content(p_content uuid, p_confirm_name text)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare c public.dm_content; d jsonb; refs text[]; base text; vno int; asg jsonb; stamped int := 0;
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
  -- the authoritative re-check, after the locks: current use blocks; history does not (it is kept), except encounter history
  d := public._dm_content_dependencies(p_content);
  if (d ->> 'current')::int > 0 then
    raise exception 'This content is in use. Archive it instead; nothing was deleted.' using errcode = 'TLUSE', hint = 'archive';
  end if;
  if coalesce((d ->> 'blocking_history')::int, 0) > 0 then
    raise exception 'This content is part of the campaign history (a completed encounter). Archive it instead; nothing was deleted.' using errcode = 'TLUSE', hint = 'archive';
  end if;
  select version_no into vno from public.dm_content_versions where id = coalesce(c.published_version_id, c.current_version_id);
  asg := public._dm_content_assignments(p_content);   -- the cascade removes the lifecycle events: the audit event keeps them
  begin
    if c.content_type = 'item' then stamped := public._stamp_item_history(refs, p_content); end if;
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
            jsonb_build_object('content_id', c.id, 'content_type', c.content_type, 'name', c.name, 'version_no', vno, 'catalog_refs', to_jsonb(refs),
                               'assignments', asg, 'history_kept', stamped,
                               'history', jsonb_build_object('inventory_history', coalesce((d -> 'counts' ->> 'inventory_history')::int, 0),
                                                             'audit_references', (d -> 'counts' ->> 'audit_references')::int,
                                                             'earlier_assignments', (d -> 'counts' ->> 'earlier_assignments')::int)), 'dm');
  exception when foreign_key_violation or restrict_violation then
    raise exception 'This content is in use. Archive it instead; nothing was deleted.' using errcode = 'TLUSE', hint = 'archive';
  end;
  return jsonb_build_object('deleted', p_content, 'name', c.name, 'content_type', c.content_type, 'catalog_refs', to_jsonb(refs), 'history_kept', stamped);
end $$;

-- WHERE content is used (DM / admin only). Rows in a campaign the caller does not run (possible for private-library content and
-- personal stashes) are only counted (hidden_places), never named. Players' draft requests are never listed (history counts).
create or replace function public.get_dm_content_usage_detail(p_content uuid)
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
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
end $$;
revoke all on function public.get_dm_content_usage_detail(uuid) from public, anon;
grant execute on function public.get_dm_content_usage_detail(uuid) to authenticated;
