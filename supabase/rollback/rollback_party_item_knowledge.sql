-- =============================================================================
-- Rollback of 20261114000100_party_item_knowledge.sql. Run as postgres in ONE transaction:
--   psql -v ON_ERROR_STOP=1 -1 -f supabase/rollback/rollback_party_item_knowledge.sql
-- Restores the exact previous bodies of the seven replaced functions (captured with pg_get_functiondef from the local database at
-- 20261113000100; md5 of pg_get_functiondef, first 8: _identify_apply ae98ff51, _item_knowledge_log e24b17c6, set_item_knowledge
-- 1df683f9, dm_set_item_knowledge f5115397, get_item_knowledge_overview 320cb154, dm_reveal_item 59c15bc7,
-- tl_cache.bump_item_knowledge 3013a275; grants are unchanged by CREATE OR REPLACE), drops the joiner trigger, every new function,
-- the tables campaign_item_rules and party_share_pending and the three new columns.
-- KEPT on purpose (ordinary T4 data, read by the T4 code exactly as before): knowledge records that party sharing raised, the
-- inventory rows' names / descriptions / row knowledge that followed them, examine attempts closed as "Learned from the party",
-- character_revisions and audit events. Nothing is lowered: a character who learned an item from the party keeps knowing it.
-- LOST (export first if it matters):
--   select campaign_id, share_identification from public.campaign_item_rules;           -- the rule per campaign
--   select * from public.party_share_pending;                                           -- party shares not applied yet
--   select character_id, item_id from public.character_item_knowledge where held_by_dm;  -- the DM holds
--   select id, source, source_character_id from public.item_knowledge_events where source is not null;
-- Deploy order for a rollback: the previous frontend (?v=28) first, then this file.
-- =============================================================================
set local lock_timeout = '5s';
drop trigger if exists characters_party_knowledge on public.characters;

CREATE OR REPLACE FUNCTION public._identify_apply(p_character uuid, p_item text, p_reveal text[])
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare ck public.character_item_knowledge; is_full boolean := 'all' = any (coalesce(p_reveal, '{all}')); rev text[]; st text;
begin
  select * into ck from public.character_item_knowledge where character_id = p_character and item_id = p_item for update;
  rev := array(select distinct x from unnest(coalesce(ck.revealed, '{}') || array_remove(coalesce(p_reveal, '{all}'), 'all')) x
               where x is not null and btrim(x) <> '' order by 1);
  st := case when is_full or ck.state = 'identified' then 'identified'
             when cardinality(rev) > 0 then 'partially_identified' else coalesce(ck.state, 'unidentified') end;
  insert into public.character_item_knowledge (character_id, item_id, state, revealed, updated_by)
  values (p_character, p_item, st, rev, auth.uid())
  on conflict (character_id, item_id) do update set state = excluded.state, revealed = excluded.revealed, updated_by = excluded.updated_by,
    updated_at = now();
  perform public._identify_sync_rows(p_character, p_item);
  perform public._identify_touch(p_character);
  return st;
end $function$
;

CREATE OR REPLACE FUNCTION public._item_knowledge_log()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
begin
  if tg_op = 'UPDATE' and (old.state, old.revealed) is not distinct from (new.state, new.revealed) then return null; end if;
  insert into public.item_knowledge_events (campaign_id, character_id, item_id, old_state, old_revealed, new_state, new_revealed, actor)
  values ((select c.campaign_id from public.characters c where c.id = new.character_id), new.character_id, new.item_id,
          case when tg_op = 'UPDATE' then old.state end, case when tg_op = 'UPDATE' then old.revealed end,
          new.state, new.revealed, auth.uid());
  return null;
end $function$
;

CREATE OR REPLACE FUNCTION public.set_item_knowledge(p_inventory_item uuid, p_state text, p_revealed text[] DEFAULT NULL::text[], p_magic_known boolean DEFAULT NULL::boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare r public.inventory_items; it public.items; inv public.inventories; k public.inventory_item_knowledge; camp uuid; s public.item_secrets; old_state text;
begin
  select * into r from public.inventory_items where id = p_inventory_item for update;
  if r.id is null then raise exception 'Item not found' using errcode = 'P0002'; end if;
  select * into inv from public.inventories where id = r.inventory_id;
  select * into it from public.items where id = r.item_id;
  camp := coalesce(inv.campaign_id, (select campaign_id from public.characters where id = inv.character_id), it.campaign_id);
  if auth.uid() is null or not (public.is_admin() or (camp is not null and public.is_campaign_dm(camp))) then
    raise exception 'Only the DM can identify items or reveal their properties' using errcode = '42501';
  end if;
  if p_state not in ('unidentified', 'partially_identified', 'identified') then raise exception 'Unknown knowledge state' using errcode = '22023'; end if;
  select * into k from public.inventory_item_knowledge where inventory_item_id = r.id;
  old_state := coalesce(k.state, 'identified');
  select * into s from public.item_secrets where item_id = r.item_id;
  insert into public.inventory_item_knowledge (inventory_item_id, state, magic_known, revealed, true_name, updated_by)
  values (r.id, p_state, coalesce(p_magic_known, false), coalesce(p_revealed, '{}'), coalesce(k.true_name, it.name), auth.uid())
  on conflict (inventory_item_id) do update set state = excluded.state, magic_known = coalesce(p_magic_known, inventory_item_knowledge.magic_known),
    revealed = coalesce(p_revealed, inventory_item_knowledge.revealed), updated_by = excluded.updated_by, updated_at = now();
  if p_state = 'identified' then
    update public.inventory_items set name = coalesce(k.true_name, it.name), description = coalesce(it.description, '') where id = r.id;
  else
    update public.items set secret = true where id = r.item_id and not secret;   -- 20261112000300: no global cache bump when already secret
    update public.inventory_items set name = coalesce(s.unidentified_name, 'Unidentified item'), description = coalesce(s.unidentified_description, '')
    where id = r.id and old_state = 'identified';
  end if;
  -- 20261112000300: knowledge is per character
  if inv.character_id is not null and r.item_id is not null then
    insert into public.character_item_knowledge (character_id, item_id, state, revealed, updated_by)
    values (inv.character_id, r.item_id, p_state, (select revealed from public.inventory_item_knowledge where inventory_item_id = r.id), auth.uid())
    on conflict (character_id, item_id) do update set state = excluded.state, revealed = excluded.revealed, updated_by = excluded.updated_by, updated_at = now();
    perform public._identify_sync_rows(inv.character_id, r.item_id);
    perform public._identify_touch(inv.character_id);
  end if;
  if camp is not null then
    perform public._audit(camp, inv.character_id, 'item_revealed',
                          'Item knowledge: ' || replace(old_state, '_', ' ') || ' → ' || replace(p_state, '_', ' '),
                          null, jsonb_build_object('revealed', to_jsonb(coalesce(p_revealed, '{}'))), null, null, 'party');
  end if;
  return public.get_character_item_knowledge(inv.character_id);
end;
$function$
;

CREATE OR REPLACE FUNCTION public.dm_set_item_knowledge(p_item text, p_characters uuid[], p_reveal text[], p_mode text DEFAULT 'set'::text, p_campaign uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare it public.items; camp uuid; is_full boolean; rev text[]; st text; cid uuid; ck public.character_item_knowledge;
  fp0 text; fp1 text; changed boolean; plain int; skip_plain boolean; d record; shown text; owner_uid uuid; out jsonb := '[]'; n int := 0;
begin
  if auth.uid() is null then raise exception 'Not authenticated' using errcode = '42501'; end if;
  select * into it from public.items where id = p_item;
  if it.id is null then raise exception 'Item not found' using errcode = 'P0002'; end if;
  if it.campaign_id is not null and p_campaign is not null and p_campaign <> it.campaign_id then
    raise exception 'The item belongs to another campaign' using errcode = '22023';
  end if;
  camp := coalesce(it.campaign_id, p_campaign);
  if camp is null or not (public.is_admin() or public.is_campaign_dm(camp)) then
    raise exception 'Only the DM of the campaign can change what characters know about an item' using errcode = '42501';
  end if;
  if not public._ik_item_in_campaign(p_item, camp) then raise exception 'Item not found' using errcode = 'P0002'; end if;
  if p_mode is null or p_mode not in ('set', 'raise') then raise exception 'Unknown mode (set or raise)' using errcode = '22023'; end if;
  if p_characters is null or cardinality(p_characters) = 0 then raise exception 'Choose at least one character' using errcode = '22023'; end if;
  if cardinality(p_characters) > 100 then raise exception 'Too many characters' using errcode = '22023'; end if;
  if exists (select 1 from unnest(p_characters) t left join public.characters c on c.id = t where t is null or c.campaign_id is distinct from camp) then
    raise exception 'Every character must be in the campaign' using errcode = '22023';
  end if;
  if p_reveal is null or cardinality(p_reveal) > 24
     or exists (select 1 from unnest(p_reveal) x where x is null or length(btrim(x)) not between 1 and 40) then
    raise exception 'Choose what to reveal (a list of up to 24 parts, or all)' using errcode = '22023';
  end if;
  is_full := 'all' = any (p_reveal);
  rev := case when is_full then '{}'::text[] else array(select distinct btrim(x) from unnest(p_reveal) x order by 1) end;
  st := case when is_full then 'identified' when cardinality(rev) > 0 then 'partially_identified' else 'unidentified' end;
  -- hiding an official row would hide it in every campaign (items.secret is global)
  if p_mode = 'set' and st <> 'identified' and it.owner_id is null then
    raise exception 'Official items cannot be hidden again: copy the item to campaign homebrew first' using errcode = '22023';
  end if;
  select * into d from public._item_decoy(p_item);

  foreach cid in array array(select distinct x from unnest(p_characters) x order by 1) loop
    -- the character's rows of the item (id order), then its record, both NOWAIT: examine locks the examined row, then the record,
    -- then the other rows, and _identify_apply locks the record before the rows. Waiting here could deadlock (40P01); a busy
    -- row or record answers at once with a message the DM can act on (P0001: not rewritten into the generic text by the UI).
    begin
      perform 1 from public.inventory_items ii join public.inventories inv on inv.id = ii.inventory_id
       where inv.character_id = cid and ii.item_id = p_item order by ii.id for update of ii nowait;
      select * into ck from public.character_item_knowledge where character_id = cid and item_id = p_item for update nowait;
    exception when lock_not_available then
      raise exception 'The player is examining this item right now, try again in a moment' using errcode = 'P0001',
        hint = 'Nothing was changed.';
    end;
    fp0 := public._ik_fingerprint(cid, p_item);
    -- raise: a character who holds an undisguised copy (and no disguised one) already sees everything; a record would only be
    -- LOWER than what the player sees, so nothing is written (no record, history, audit or revision)
    skip_plain := p_mode = 'raise'
      and exists (select 1 from public.inventory_items ii join public.inventories inv on inv.id = ii.inventory_id
                  where inv.character_id = cid and ii.item_id = p_item
                    and not exists (select 1 from public.inventory_item_knowledge k where k.inventory_item_id = ii.id))
      and not exists (select 1 from public.inventory_items ii join public.inventories inv on inv.id = ii.inventory_id
                      join public.inventory_item_knowledge k on k.inventory_item_id = ii.id
                      where inv.character_id = cid and ii.item_id = p_item);
    if skip_plain then
      null;
    elsif p_mode = 'raise' then
      -- never lowers: skipped when the character already knows at least this much
      if not (coalesce(ck.state = 'identified', false)
              or (not is_full and (cardinality(rev) = 0 or coalesce(ck.character_id is not null and rev <@ ck.revealed, false)))) then
        perform public._identify_apply(cid, p_item, case when is_full then '{all}'::text[] else rev end);
      end if;
    else
      if st <> 'identified' then
        -- undisguised rows of this character get a knowledge row, so the sync below disguises them too (m6)
        insert into public.inventory_item_knowledge (inventory_item_id, state, revealed, true_name, updated_by)
        select ii.id, 'identified', '{}', it.name, auth.uid()
          from public.inventory_items ii join public.inventories inv on inv.id = ii.inventory_id
         where inv.character_id = cid and ii.item_id = p_item
           and not exists (select 1 from public.inventory_item_knowledge k where k.inventory_item_id = ii.id)
         order by ii.id;
        get diagnostics plain = row_count;
        if plain > 0 then update public.items set secret = true where id = p_item and not secret; end if;
      end if;
      insert into public.character_item_knowledge as x (character_id, item_id, state, revealed, updated_by)
      values (cid, p_item, st, rev, auth.uid())
      on conflict (character_id, item_id) do update set state = excluded.state, revealed = excluded.revealed,
        updated_by = excluded.updated_by, updated_at = now()
      where (x.state, x.revealed) is distinct from (excluded.state, excluded.revealed);
      perform public._identify_sync_rows(cid, p_item);
    end if;
    fp1 := public._ik_fingerprint(cid, p_item);
    changed := fp0 is distinct from fp1;
    select * into ck from public.character_item_knowledge where character_id = cid and item_id = p_item;
    if changed then
      n := n + 1;
      perform public._identify_touch(cid);
      shown := case when ck.state = 'identified' or 'name' = any (ck.revealed) then it.name else d.name end;
      -- the player's line (non-DM audit events reach only the character's owner): no true name unless the name is known
      perform public._audit(camp, cid, 'item_revealed',
        case when ck.state = 'identified' then 'The DM revealed an item: ' || shown
             else 'The DM changed what you know about an item: ' || shown end,
        null, jsonb_build_object('revealed', to_jsonb(case when ck.state = 'identified' then '{all}'::text[] else ck.revealed end)), null, null, 'party');
      perform public._audit(camp, cid, 'item_revealed',
        'Knowledge of ' || it.name || ': ' || replace(ck.state, '_', ' ')
          || case when cardinality(ck.revealed) > 0 then ' (' || array_to_string(ck.revealed, ', ') || ')' else '' end,
        null, jsonb_build_object('item_id', it.id, 'mode', p_mode, 'state', ck.state, 'revealed', to_jsonb(ck.revealed)), null, null, 'dm');
    end if;
    select owner_id into owner_uid from public.characters where id = cid;
    out := out || jsonb_build_array(jsonb_build_object('character_id', cid, 'changed', changed,
      'state', coalesce(ck.state, 'unidentified'), 'revealed', to_jsonb(coalesce(ck.revealed, '{}'::text[])),
      'skipped', case when skip_plain then 'holds an undisguised copy' end,
      'warning', case when not skip_plain and it.owner_id is not distinct from owner_uid and coalesce(ck.state, 'unidentified') <> 'identified'
                      then 'The player created this item and can still look it up in the catalog' end));
  end loop;
  return jsonb_build_object('item_id', p_item, 'mode', p_mode, 'changed', n, 'results', out);
end $function$
;

CREATE OR REPLACE FUNCTION public.get_item_knowledge_overview(p_item text, p_campaign uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare it public.items; d record;
begin
  if auth.uid() is null or p_campaign is null or not (public.is_admin() or public.is_campaign_dm(p_campaign)) then
    raise exception 'Only a DM of the campaign can see who knows what' using errcode = '42501';
  end if;
  select * into it from public.items where id = p_item;
  if it.id is null then raise exception 'Item not found' using errcode = 'P0002'; end if;
  if it.campaign_id is not null and it.campaign_id <> p_campaign then raise exception 'The item belongs to another campaign' using errcode = '22023'; end if;
  if not public._ik_item_in_campaign(p_item, p_campaign) then raise exception 'Item not found' using errcode = 'P0002'; end if;
  select * into d from public._item_decoy(p_item);
  return jsonb_build_object(
    'item', jsonb_build_object('id', it.id, 'name', it.name, 'kind_id', it.kind_id, 'official', it.owner_id is null, 'secret', it.secret,
      'decoy_name', d.name, 'decoy_description', d.description, 'can_hide', it.owner_id is not null,
      'properties', coalesce((select s.properties from public.item_secrets s where s.item_id = it.id), '[]')),
    'characters', (select coalesce(jsonb_agg(x.j order by x.nm, x.cid), '[]') from (
      select c.name as nm, c.id as cid, jsonb_build_object('character_id', c.id, 'name', c.name,
        'is_creator', it.owner_id is not distinct from c.owner_id,
        'record', (select jsonb_build_object('state', ck.state, 'revealed', to_jsonb(ck.revealed), 'updated_at', ck.updated_at,
                     'updated_by', (select coalesce(p.display_name, 'someone') from public.profiles p where p.id = ck.updated_by))
                   from public.character_item_knowledge ck where ck.character_id = c.id and ck.item_id = it.id),
        'rows', r.n_rows, 'quantity', r.qty, 'plain_rows', r.n_plain, 'disguised_rows', r.n_disg, 'equipped_rows', r.n_eq,
        'shown_names', to_jsonb(r.names),
        'effective', case
          when r.n_plain > 0 then jsonb_build_object('state', 'identified', 'revealed', '[]'::jsonb, 'source', 'undisguised_copy')
          when r.n_disg > 0 then jsonb_build_object('state', r.low_state, 'revealed', to_jsonb(r.low_revealed), 'source', 'rows')
          when not it.secret then jsonb_build_object('state', 'identified', 'revealed', '[]'::jsonb, 'source', 'not_hidden')
          when ck2.character_id is not null then jsonb_build_object('state', ck2.state, 'revealed', to_jsonb(ck2.revealed), 'source', 'record')
          else jsonb_build_object('state', 'unidentified', 'revealed', '[]'::jsonb, 'source', 'none') end,
        'diverges', r.n_disg > 0 and (ck2.character_id is null or exists (
          select 1 from public.inventory_items ii join public.inventories inv on inv.id = ii.inventory_id
          join public.inventory_item_knowledge k on k.inventory_item_id = ii.id
          where inv.character_id = c.id and ii.item_id = it.id and (k.state, k.revealed) is distinct from (ck2.state, ck2.revealed)))) as j
      from public.characters c
      left join public.character_item_knowledge ck2 on ck2.character_id = c.id and ck2.item_id = it.id
      cross join lateral (
        select count(ii.id)::int as n_rows, coalesce(sum(ii.quantity), 0)::int as qty,
               count(ii.id) filter (where k.inventory_item_id is null)::int as n_plain,
               count(ii.id) filter (where k.inventory_item_id is not null)::int as n_disg,
               count(ii.id) filter (where exists (select 1 from public.character_equipment e where e.inventory_item_id = ii.id))::int as n_eq,
               coalesce(array_agg(distinct coalesce(nullif(ii.custom_name, ''), ii.name)) filter (where ii.id is not null), '{}') as names,
               (array_agg(k.state order by public._ik_rank(k.state, k.revealed), ii.id) filter (where k.inventory_item_id is not null))[1] as low_state,
               (array_agg(array_to_string(k.revealed, chr(31)) order by public._ik_rank(k.state, k.revealed), ii.id) filter (where k.inventory_item_id is not null))[1] as low_rev_txt,
               null::text[] as low_revealed
        from public.inventories inv join public.inventory_items ii on ii.inventory_id = inv.id
        left join public.inventory_item_knowledge k on k.inventory_item_id = ii.id
        where inv.character_id = c.id and ii.item_id = it.id) r0
      cross join lateral (select r0.n_rows, r0.qty, r0.n_plain, r0.n_disg, r0.n_eq, r0.names, r0.low_state,
                                 coalesce(string_to_array(nullif(r0.low_rev_txt, ''), chr(31)), '{}') as low_revealed) r
      where c.campaign_id = p_campaign) x),
    'stash', (select coalesce(jsonb_agg(jsonb_build_object('inventory_id', inv.id, 'inventory_kind', inv.kind, 'inventory_name', inv.name,
                 'inventory_item_id', ii.id, 'shown_name', coalesce(nullif(ii.custom_name, ''), ii.name), 'quantity', ii.quantity,
                 'state', coalesce(k.state, 'identified'), 'revealed', to_jsonb(coalesce(k.revealed, '{}'::text[])), 'disguised', k.inventory_item_id is not null)
                 order by inv.kind, inv.name, ii.id), '[]')
              from public.inventories inv join public.inventory_items ii on ii.inventory_id = inv.id
              left join public.inventory_item_knowledge k on k.inventory_item_id = ii.id
              where inv.character_id is null and inv.campaign_id = p_campaign and ii.item_id = it.id),
    'history', (select coalesce(jsonb_agg(h.j order by h.at desc, h.id desc), '[]') from (
      select e.created_at as at, e.id, jsonb_build_object('at', e.created_at, 'character_id', e.character_id,
        'character_name', (select c.name from public.characters c where c.id = e.character_id),
        'old_state', e.old_state, 'old_revealed', to_jsonb(e.old_revealed), 'new_state', e.new_state, 'new_revealed', to_jsonb(e.new_revealed),
        'actor', (select coalesce(p.display_name, 'someone') from public.profiles p where p.id = e.actor)) as j
      from public.item_knowledge_events e where e.item_id = it.id and e.campaign_id = p_campaign
      order by e.created_at desc, e.id desc limit 50) h));
end $function$
;

CREATE OR REPLACE FUNCTION public.dm_reveal_item(p_item text, p_characters uuid[] DEFAULT NULL::uuid[], p_reveal text[] DEFAULT NULL::text[], p_campaign uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare it public.items; camp uuid; targets uuid[]; cid uuid; st text; n int := 0;
begin
  select * into it from public.items where id = p_item;
  if it.id is null then raise exception 'Item not found' using errcode = 'P0002'; end if;
  if it.campaign_id is not null and p_campaign is not null and p_campaign <> it.campaign_id then
    raise exception 'The item belongs to another campaign' using errcode = '22023';
  end if;
  camp := coalesce(it.campaign_id, p_campaign);
  if auth.uid() is null or camp is null or not (public.is_admin() or public.is_campaign_dm(camp)) then
    raise exception 'Only the DM of the campaign can reveal items' using errcode = '42501';
  end if;
  targets := coalesce(p_characters, array(select id from public.characters where campaign_id = camp order by id));
  if exists (select 1 from unnest(targets) t left join public.characters c on c.id = t where c.campaign_id is distinct from camp) then
    raise exception 'Every character must be in the campaign' using errcode = '22023';
  end if;
  foreach cid in array targets loop
    st := public._identify_apply(cid, p_item, coalesce(p_reveal, '{all}'));
    n := n + 1;
    perform public._audit(camp, cid, 'item_revealed', 'The DM revealed ' || case when st = 'identified' then 'an item: ' || it.name else 'part of an item' end,
                          null, jsonb_build_object('revealed', to_jsonb(coalesce(p_reveal, '{all}'))), null, null, 'party');
  end loop;
  return jsonb_build_object('item_id', p_item, 'characters', n);
end $function$
;

CREATE OR REPLACE FUNCTION tl_cache.bump_item_knowledge()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare rid uuid; iid text; cid uuid; k text;
begin
  if tg_op = 'UPDATE' and to_jsonb(old) = to_jsonb(new) then return null; end if;
  foreach rid in array array_remove(array[case when tg_op <> 'DELETE' then new.inventory_item_id end,
                                          case when tg_op <> 'INSERT' then old.inventory_item_id end], null) loop
    select ii.item_id into iid from public.inventory_items ii where ii.id = rid;
    continue when iid is null;
    k := 'tl_cache.i' || md5(iid || txid_current()::text);   -- once per item and transaction
    continue when current_setting(k, true) = '1';
    perform set_config(k, '1', true);
    for cid in select distinct inv.character_id from public.inventory_items ii join public.inventories inv on inv.id = ii.inventory_id
               where ii.item_id = iid and inv.character_id is not null loop
      k := 'tl_cache.c' || md5(cid::text || txid_current()::text);   -- the dedup key of tl_cache.bump
      continue when current_setting(k, true) = '1';
      insert into tl_cache.character_rev as r (character_id, rev)
      select cid, 1 where exists (select 1 from public.characters c where c.id = cid)
      on conflict (character_id) do update set rev = r.rev + 1;
      perform set_config(k, '1', true);
    end loop;
  end loop;
  return null;
end $function$
;

drop function if exists public.dm_sync_party_knowledge(uuid);
drop function if exists public.sync_party_knowledge(uuid);
drop function if exists public.dm_release_item_knowledge_hold(text, uuid[], uuid);
drop function if exists public.set_campaign_identification_sharing(uuid, boolean);
drop function if exists public.get_campaign_identification_sharing(uuid);
drop function if exists public._party_share_join();
drop function if exists public._party_share_sync(uuid);
drop function if exists public._party_pending_apply(uuid);
drop function if exists public._party_share_pull(uuid, boolean, text);
drop function if exists public._party_levels(uuid, uuid, text);
drop function if exists public._party_share_from(uuid, text);
drop function if exists public._party_guarded(uuid, text, text, text[], uuid, uuid, boolean, bigint);
drop function if exists public._party_apply_to(uuid, text, text, text[], boolean);
drop function if exists public._ik_apply_set(uuid, text, text, text[]);
drop function if exists public._identify_apply_one(uuid, text, text[]);
drop function if exists public._ik_lock_target(uuid, text);
drop function if exists public._ik_contains(text, text[], text, text[]);
drop function if exists public._ik_drop_pending(uuid, text);
drop function if exists public._ik_campaign_level(uuid, text, uuid);
drop function if exists public._party_share_on(uuid);
alter table public.item_knowledge_events drop column if exists source_character_id, drop column if exists source;
alter table public.character_item_knowledge drop column if exists held_by_dm;
drop table if exists public.party_share_pending;
drop table if exists public.campaign_item_rules;
do $$
begin
  if to_regclass('supabase_migrations.schema_migrations') is not null then
    delete from supabase_migrations.schema_migrations where version = '20261114000100';
  end if;
end $$;
notify pgrst, 'reload schema';
