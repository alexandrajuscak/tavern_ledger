-- =============================================================================
-- Per-character reveal of hidden / unidentified items (T4b; docs/HIDDEN_DM_DATA.md "Revealing items to characters").
-- ONE model: character_item_knowledge (T4, 20261112000300) is the record of what a character knows about an item, with the T4
-- vocabulary (state + revealed[]: name, description, details, magic, rarity, attunement, curse, property keys; 'all' = identified).
-- The character's inventory rows follow it through T4's _identify_sync_rows. This migration only ADDS:
-- * item_knowledge_events: append-only, DM-only history of every change of a record (trigger on character_item_knowledge, so
--   every path is logged: examine, DM answer, reveal, set_item_knowledge, transfer, the new RPC, the backfill).
-- * dm_set_item_knowledge(item, characters[], reveal[], mode, campaign): the DM reveals to one / selected / all characters
--   (explicit list), partially or fully (mode 'raise': never lowers), or sets an exact level (mode 'set': can lower = undo). A
--   lower level also disguises the character's undisguised rows of the item (they get a knowledge row first, so the sync
--   reaches them). Refused for official items (copy to campaign homebrew first). An unchanged character writes nothing.
-- * get_item_knowledge_overview(item, campaign): DM-only "who knows what" (record, rows, effective level, divergence, stash
--   rows, history). get_campaign_knowledge_items(campaign): the DM's item picker.
-- * _item_knowledge_backfill(): copies unambiguous row knowledge of character rows into missing records (never deletes, never
--   syncs rows; a record alone changes nothing a player sees). Production held 0 row-knowledge rows at the time of writing.
-- Untouched on purpose (parked, docs/night/DESIGN_hidden_items_reveal.md): _item_visible, v_inventory_detail, _character_read,
-- transfer / split / merge, party-stash semantics, dm_reveal_item / set_item_knowledge / examine bodies.
-- Cache: item_knowledge_events -> tl_cache.bump('character') (coverage rule; always deduplicated with the record's own bump);
-- DM-only, read by no cached read; not in the Realtime publication.
-- Rollback: supabase/rollback/rollback_item_knowledge_reveal.sql.
-- =============================================================================

-- ---- 1. history ------------------------------------------------------------------------------------------------------------
-- it lives and goes with the record: a deleted character or item takes its history along (deletes are not logged)
create table public.item_knowledge_events (
  id           bigint generated always as identity primary key,
  campaign_id  uuid,
  character_id uuid not null references public.characters (id) on delete cascade,
  item_id      text not null references public.items (id) on delete cascade,
  old_state    text,
  old_revealed text[],
  new_state    text not null,
  new_revealed text[] not null,
  actor        uuid,
  created_at   timestamptz not null default now()
);
create index item_knowledge_events_item on public.item_knowledge_events (item_id, created_at desc);
create index item_knowledge_events_campaign on public.item_knowledge_events (campaign_id, created_at desc);
create index item_knowledge_events_character on public.item_knowledge_events (character_id);
alter table public.item_knowledge_events enable row level security;
revoke all on public.item_knowledge_events from anon, authenticated;
-- the coverage rule of the cache (progressive_read_tests): a table with character_id carries bump('character'). Free here: a
-- history row is only ever written by the trigger below, in the same transaction as the record change, which already bumped
-- that character (tl_cache.bump dedups per character and transaction). No cached read reads this table.
create trigger tl_cache_rev after insert or update or delete on public.item_knowledge_events
  for each row execute function tl_cache.bump('character');

create function public._item_knowledge_log()
returns trigger
language plpgsql security definer
set search_path = public, pg_temp
as $$
begin
  if tg_op = 'UPDATE' and (old.state, old.revealed) is not distinct from (new.state, new.revealed) then return null; end if;
  insert into public.item_knowledge_events (campaign_id, character_id, item_id, old_state, old_revealed, new_state, new_revealed, actor)
  values ((select c.campaign_id from public.characters c where c.id = new.character_id), new.character_id, new.item_id,
          case when tg_op = 'UPDATE' then old.state end, case when tg_op = 'UPDATE' then old.revealed end,
          new.state, new.revealed, auth.uid());
  return null;
end $$;
create trigger item_knowledge_log after insert or update on public.character_item_knowledge
  for each row execute function public._item_knowledge_log();

-- ---- 2. helpers ------------------------------------------------------------------------------------------------------------
-- what a character's rows of an item and its record look like (to tell a change from a no-op)
create function public._ik_fingerprint(p_character uuid, p_item text)
returns text
language sql stable security definer
set search_path = public, pg_temp
as $$
  select md5(coalesce((select ck.state || '|' || array_to_string(ck.revealed, ',') from public.character_item_knowledge ck
                       where ck.character_id = p_character and ck.item_id = p_item), '-')
             || '#' || coalesce((select string_agg(ii.id::text || '|' || coalesce(ii.name, '') || '|' || coalesce(ii.description, '') || '|'
                                                  || coalesce(k.state, '-') || '|' || coalesce(array_to_string(k.revealed, ','), ''), ';' order by ii.id)
                                 from public.inventory_items ii join public.inventories inv on inv.id = ii.inventory_id
                                 left join public.inventory_item_knowledge k on k.inventory_item_id = ii.id
                                 where inv.character_id = p_character and ii.item_id = p_item), ''));
$$;

-- level rank for display (0 nothing .. 3 everything)
create function public._ik_rank(p_state text, p_revealed text[])
returns int
language sql immutable
set search_path = public, pg_temp
as $$
  select case when p_state = 'identified' then 3
              when 'name' = any (coalesce(p_revealed, '{}')) and 'description' = any (coalesce(p_revealed, '{}')) then 2
              when cardinality(coalesce(p_revealed, '{}')) > 0 then 1 else 0 end;
$$;

-- ---- 3. DM: set / raise what characters know -------------------------------------------------------------------------------
create function public.dm_set_item_knowledge(p_item text, p_characters uuid[], p_reveal text[], p_mode text default 'set',
                                             p_campaign uuid default null)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare it public.items; camp uuid; is_full boolean; rev text[]; st text; cid uuid; ck public.character_item_knowledge;
  fp0 text; fp1 text; changed boolean; plain int; d record; shown text; owner_uid uuid; out jsonb := '[]'; n int := 0;
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
    -- the character's rows of the item first (id order), then its record: the order examine and _identify_apply use
    perform 1 from public.inventory_items ii join public.inventories inv on inv.id = ii.inventory_id
     where inv.character_id = cid and ii.item_id = p_item order by ii.id for update of ii;
    select * into ck from public.character_item_knowledge where character_id = cid and item_id = p_item for update;
    fp0 := public._ik_fingerprint(cid, p_item);
    if p_mode = 'raise' then
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
      'warning', case when it.owner_id is not distinct from owner_uid and coalesce(ck.state, 'unidentified') <> 'identified'
                      then 'The player created this item and can still look it up in the catalog' end));
  end loop;
  return jsonb_build_object('item_id', p_item, 'mode', p_mode, 'changed', n, 'results', out);
end $$;

-- ---- 4. DM: who knows what -------------------------------------------------------------------------------------------------
create function public.get_item_knowledge_overview(p_item text, p_campaign uuid)
returns jsonb
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
declare it public.items; d record;
begin
  if auth.uid() is null or p_campaign is null or not (public.is_admin() or public.is_campaign_dm(p_campaign)) then
    raise exception 'Only a DM of the campaign can see who knows what' using errcode = '42501';
  end if;
  select * into it from public.items where id = p_item;
  if it.id is null then raise exception 'Item not found' using errcode = 'P0002'; end if;
  if it.campaign_id is not null and it.campaign_id <> p_campaign then raise exception 'The item belongs to another campaign' using errcode = '22023'; end if;
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
        'rows', r.n_rows, 'quantity', r.qty, 'plain_rows', r.n_plain, 'disguised_rows', r.n_disg,
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
               coalesce(array_agg(distinct coalesce(nullif(ii.custom_name, ''), ii.name)) filter (where ii.id is not null), '{}') as names,
               (array_agg(k.state order by public._ik_rank(k.state, k.revealed), ii.id) filter (where k.inventory_item_id is not null))[1] as low_state,
               (array_agg(array_to_string(k.revealed, chr(31)) order by public._ik_rank(k.state, k.revealed), ii.id) filter (where k.inventory_item_id is not null))[1] as low_rev_txt,
               null::text[] as low_revealed
        from public.inventories inv join public.inventory_items ii on ii.inventory_id = inv.id
        left join public.inventory_item_knowledge k on k.inventory_item_id = ii.id
        where inv.character_id = c.id and ii.item_id = it.id) r0
      cross join lateral (select r0.n_rows, r0.qty, r0.n_plain, r0.n_disg, r0.names, r0.low_state,
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
end $$;

-- the DM's item picker: items held in the campaign (characters, stash, shop), campaign custom items, items with a record
create function public.get_campaign_knowledge_items(p_campaign uuid)
returns jsonb
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
begin
  if auth.uid() is null or p_campaign is null or not (public.is_admin() or public.is_campaign_dm(p_campaign)) then
    raise exception 'Only a DM of the campaign can list its items' using errcode = '42501';
  end if;
  return (select coalesce(jsonb_agg(z.j order by z.hidden desc, z.nm, z.id), '[]') from (
    select it.id, it.name as nm, (it.secret or coalesce(h.n_disg, 0) > 0) as hidden,
      jsonb_build_object('id', it.id, 'name', it.name, 'kind_id', it.kind_id, 'official', it.owner_id is null, 'secret', it.secret,
        'has_secrets', exists (select 1 from public.item_secrets s where s.item_id = it.id
                               and (s.unidentified_name is not null or s.identify_dc is not null or s.curse is not null)),
        'holders', coalesce(h.n_chars, 0), 'disguised_rows', coalesce(h.n_disg, 0),
        'records', (select count(*) from public.character_item_knowledge ck join public.characters c on c.id = ck.character_id
                    where ck.item_id = it.id and c.campaign_id = p_campaign)) as j
    from public.items it
    left join lateral (
      select count(distinct inv.character_id)::int as n_chars, count(k.inventory_item_id)::int as n_disg
      from public.inventory_items ii join public.inventories inv on inv.id = ii.inventory_id
      left join public.characters c on c.id = inv.character_id
      left join public.inventory_item_knowledge k on k.inventory_item_id = ii.id
      where ii.item_id = it.id and coalesce(inv.campaign_id, c.campaign_id) = p_campaign) h on true
    where it.id in (
        select ii.item_id from public.inventory_items ii join public.inventories inv on inv.id = ii.inventory_id
        left join public.characters c on c.id = inv.character_id
        where ii.item_id is not null and coalesce(inv.campaign_id, c.campaign_id) = p_campaign
      union select i2.id from public.items i2 where i2.campaign_id = p_campaign and i2.owner_id is not null and i2.archived_at is null
      union select ck.item_id from public.character_item_knowledge ck join public.characters c on c.id = ck.character_id where c.campaign_id = p_campaign)
    order by 3 desc, 2, 1
    limit 500) z);
end $$;

-- ---- 5. backfill: unambiguous row knowledge of character rows -> missing records --------------------------------------------
-- Copied only when every knowledge row of the character's rows of the item agrees (state and revealed facts) and, if the
-- character also holds an undisguised row, that agreed state is 'identified'. Never syncs rows, never deletes, never
-- overwrites a record. Returns the number of records created; conflicts are skipped and reported (NOTICE).
create function public._item_knowledge_backfill()
returns int
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare n int; skipped int;
begin
  with g as (
    select inv.character_id, ii.item_id,
           count(*) filter (where k.inventory_item_id is null) as n_plain,
           count(distinct k.state || '|' || array_to_string(k.revealed, chr(31))) filter (where k.inventory_item_id is not null) as variants,
           min(k.state) filter (where k.inventory_item_id is not null) as state
    from public.inventory_items ii join public.inventories inv on inv.id = ii.inventory_id
    left join public.inventory_item_knowledge k on k.inventory_item_id = ii.id
    where inv.character_id is not null and ii.item_id is not null
    group by 1, 2
    having count(k.inventory_item_id) > 0)
  insert into public.character_item_knowledge (character_id, item_id, state, revealed, updated_by)
  select g.character_id, g.item_id, g.state,
         (select k2.revealed from public.inventory_items ii2 join public.inventories inv2 on inv2.id = ii2.inventory_id
          join public.inventory_item_knowledge k2 on k2.inventory_item_id = ii2.id
          where inv2.character_id = g.character_id and ii2.item_id = g.item_id order by ii2.id limit 1), null
  from g
  where g.variants = 1 and (g.n_plain = 0 or g.state = 'identified')
  order by g.character_id, g.item_id
  on conflict (character_id, item_id) do nothing;
  get diagnostics n = row_count;
  select count(*) into skipped from (
    select inv.character_id, ii.item_id
    from public.inventory_items ii join public.inventories inv on inv.id = ii.inventory_id
    left join public.inventory_item_knowledge k on k.inventory_item_id = ii.id
    where inv.character_id is not null and ii.item_id is not null
    group by 1, 2
    having count(k.inventory_item_id) > 0
       and (count(distinct k.state || '|' || array_to_string(k.revealed, chr(31))) filter (where k.inventory_item_id is not null) > 1
            or (count(*) filter (where k.inventory_item_id is null) > 0 and min(k.state) filter (where k.inventory_item_id is not null) <> 'identified'))
       and not exists (select 1 from public.character_item_knowledge ck where ck.character_id = inv.character_id and ck.item_id = ii.item_id)) s;
  if skipped > 0 then raise notice 'item knowledge backfill: % character/item pair(s) with conflicting row knowledge left without a record', skipped; end if;
  return n;
end $$;

do $$
declare n int := public._item_knowledge_backfill();
begin
  raise notice 'item knowledge backfill: % record(s) created', n;
end $$;

-- ---- 6. grants --------------------------------------------------------------------------------------------------------------
revoke all on function public._item_knowledge_log(), public._ik_fingerprint(uuid, text), public._ik_rank(text, text[]),
  public._item_knowledge_backfill() from public, anon, authenticated;
revoke all on function public.dm_set_item_knowledge(text, uuid[], text[], text, uuid), public.get_item_knowledge_overview(text, uuid),
  public.get_campaign_knowledge_items(uuid) from public, anon;
grant execute on function public.dm_set_item_knowledge(text, uuid[], text[], text, uuid), public.get_item_knowledge_overview(text, uuid),
  public.get_campaign_knowledge_items(uuid) to authenticated, service_role;

notify pgrst, 'reload schema';
