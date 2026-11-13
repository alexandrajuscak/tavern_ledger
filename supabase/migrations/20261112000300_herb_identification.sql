-- =============================================================================
-- Herbs & Plants identification (docs/HIDDEN_DM_DATA.md "Identifying items: Examine"): a disguised item (decoy name and
-- description) that a player can examine with the total of a physical roll; the DM confirms (or the item reveals itself
-- automatically when the DM allowed it and the roll meets the DC). Knowledge is PER CHARACTER.
--
-- * DM-only options per item live on item_secrets (DM-only RLS since 20261019000500): DC, allowed checks (skill or tool ids),
--   what a success reveals, auto reveal, retry rule, a wrong-but-plausible failure hint, and whether the item type shows.
-- * character_item_knowledge (character, item) is the record of what a character knows. inventory_item_knowledge rows of that
--   character's inventory follow it (_identify_sync_rows); stash rows keep their own row knowledge.
-- * item_identify_attempts: the player's examine attempts (pending -> succeeded / failed). The server never rolls.
-- * Leaks closed here: an unidentified add is INSERTED with the disguise (the Realtime INSERT no longer carries the true name);
--   split copies the knowledge row (it used to reveal the catalog row); transfer applies the RECEIVING character's knowledge
--   in the same UPDATE; stacks of a secret item never merge across names or knowledge states; use_inventory_item returns no
--   effects for an unidentified item; v_inventory_detail masks item_id / category / rarity / magic / attunement of an
--   unidentified instance for a non-DM caller (kind = the face the DM allowed) and the inventory bundle's catalog part
--   follows the masked rows.
-- * Not closed (documented, docs/HIDDEN_DM_DATA.md): the raw inventory_items.item_id (REST table read, Realtime payload,
--   ?fluent=0 bundle) and inventory_events.item_id (kept: history stamping of deleted content matches on it). Herbs and DM content have opaque ids (hb-<uuid>, cc-<hex>) whose
--   catalog row and child tables stay hidden; official items assigned unidentified keep their readable slug (L3, unchanged).
-- * Cache: item_secrets feeds no cached read -> tl_cache.skip() (a hidden DM edit no longer invalidates every cache). The new
--   tables carry character_id -> tl_cache.bump('character'); every change on them is visible to the player (status, reveal).
--   inventory_item_knowledge (no character_id: it was bump('global')) -> tl_cache.bump_item_knowledge(): the characters holding
--   the item only (cached reads see items through RLS, which depends on the knowledge rows).
-- * DM Content keeps its identification options in the content definition (one source of truth); set_item_identify_options
--   is for campaign homebrew (hb-) only. A stack's stored keys follow items.secret (items_secret_stack_keys).
-- Rollback: supabase/rollback/rollback_herb_identification.sql.
-- =============================================================================

-- ---- 1. DM-only identification options ---------------------------------------------------------------------------------
alter table public.item_secrets
  add column face_kind_id     text references public.item_kinds (id),      -- the type a player sees while unidentified (null: hidden)
  add column identify_dc      int check (identify_dc between 1 and 40),     -- null: the item cannot be examined
  add column identify_checks  text[] not null default '{}' check (cardinality(identify_checks) <= 12),   -- skill / tool ids; {} = any
  add column identify_reveal  text[] not null default '{all}' check (cardinality(identify_reveal) between 1 and 24),
  add column identify_auto    boolean not null default false,              -- reveal on roll >= DC without the DM
  add column identify_retry   text not null default 'dm' check (identify_retry in ('once', 'dm', 'per_long_rest', 'unlimited')),
  add column fail_hint        text check (length(fail_hint) <= 500);       -- shown to the player after a failed attempt

-- ---- 2. per-character knowledge and examine attempts -------------------------------------------------------------------
create table public.character_item_knowledge (
  character_id uuid not null references public.characters (id) on delete cascade,
  item_id      text not null references public.items (id) on delete cascade,
  state        text not null default 'unidentified' check (state in ('unidentified', 'partially_identified', 'identified')),
  revealed     text[] not null default '{}',
  updated_by   uuid references public.profiles (id) on delete set null,
  updated_at   timestamptz not null default now(),
  primary key (character_id, item_id)
);
create table public.item_identify_attempts (
  id                uuid primary key default gen_random_uuid(),
  character_id      uuid not null references public.characters (id) on delete cascade,
  inventory_item_id uuid references public.inventory_items (id) on delete set null,
  item_id           text not null references public.items (id) on delete cascade,
  check_key         text not null check (length(check_key) between 1 and 60),
  roll_total        int not null check (roll_total between -10 and 60),
  status            text not null default 'pending' check (status in ('pending', 'succeeded', 'failed')),
  auto              boolean not null default false,
  revealed          text[] not null default '{}',
  retry_allowed     boolean not null default false,
  dm_roll_total     int check (dm_roll_total between -10 and 60),
  dm_note           text check (length(dm_note) <= 500),                   -- DM-only
  request_id        uuid unique,
  created_by        uuid references public.profiles (id) on delete set null default auth.uid(),
  created_at        timestamptz not null default now(),
  resolved_at       timestamptz,
  resolved_by       uuid references public.profiles (id) on delete set null
);
create index item_identify_attempts_char_item on public.item_identify_attempts (character_id, item_id, created_at desc);
create index item_identify_attempts_pending on public.item_identify_attempts (status) where status = 'pending';
create index character_item_knowledge_item on public.character_item_knowledge (item_id);

-- no player (or DM) reads these tables directly: everything goes through the RPCs below
alter table public.character_item_knowledge enable row level security;
alter table public.item_identify_attempts enable row level security;
revoke all on public.character_item_knowledge, public.item_identify_attempts from anon, authenticated;

create trigger tl_cache_rev after insert or update or delete on public.character_item_knowledge
  for each row execute function tl_cache.bump('character');
create trigger tl_cache_rev after insert or update or delete on public.item_identify_attempts
  for each row execute function tl_cache.bump('character');
-- item_secrets is read by no cached character read (get_character_item_knowledge, get_dm_character_hidden, the view: none is
-- cached): a DM's hidden edit must neither invalidate every cache (57014 pattern) nor signal anything to players
drop trigger if exists tl_cache_rev on public.item_secrets;
create trigger tl_cache_rev after insert or update or delete on public.item_secrets
  for each row execute function tl_cache.skip();
-- inventory_item_knowledge has no character_id, so 20261030000200 gave it bump('global'): every reveal / examine invalidated
-- every cached read of every character (57014 pattern). It cannot be skipped: cached reads run as the caller (get_character_reads
-- is security invoker) and _derived_stats_core, _character_effects, _cf_equipment, ... read public.items, whose RLS
-- (_item_visible) depends on the knowledge rows (an equipped secret item becomes visible once identified). The rows' visibility
-- effect is per item, so the counter of every character that holds a row of the same item is bumped (that covers another
-- character of the same viewer and party-stash rows); nobody else's cache is touched. Deleted rows (cascade from
-- inventory_items) bump nothing here: the inventory_items trigger already bumped their character.
create function tl_cache.bump_item_knowledge()
returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
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
end $$;
revoke all on function tl_cache.bump_item_knowledge() from public, anon, authenticated;
drop trigger if exists tl_cache_rev on public.inventory_item_knowledge;
create trigger tl_cache_rev after insert or update or delete on public.inventory_item_knowledge
  for each row execute function tl_cache.bump_item_knowledge();

-- ---- 3. helpers -----------------------------------------------------------------------------------------------------------
-- the caller sees the truth of every item in this inventory (admin, or DM of its campaign)
create function public._inventory_knows_all(p_inventory uuid)
returns boolean
language sql stable security definer
set search_path = public, pg_temp
as $$
  select public.is_admin() or exists (
    select 1 from public.inventories i left join public.characters c on c.id = i.character_id
    where i.id = p_inventory and coalesce(i.campaign_id, c.campaign_id) is not null
      and public.is_campaign_dm(coalesce(i.campaign_id, c.campaign_id)));
$$;

-- what a reader of the inventory may see of an unidentified instance: the type the DM allowed (null: hidden) and the handling
-- affordances (stackable, consumable: the Use and quantity controls), never rarity, magic, attunement or the item id
create function public._inventory_face(p_inventory_item uuid, out kind_id text, out stackable boolean, out is_consumable boolean)
language sql stable security definer
set search_path = public, pg_temp
as $$
  select s.face_kind_id, it.stackable, it.is_consumable
  from public.inventory_items ii join public.items it on it.id = ii.item_id left join public.item_secrets s on s.item_id = ii.item_id
  where ii.id = p_inventory_item and public.can_read_inventory(ii.inventory_id);
$$;

-- the disguise of an item: DM's decoy, or "Unidentified <type>"
create function public._item_decoy(p_item text, out name text, out description text)
language sql stable security definer
set search_path = public, pg_temp
as $$
  select coalesce(nullif(btrim(s.unidentified_name), ''), 'Unidentified ' || lower(coalesce(k.name, 'item'))), coalesce(s.unidentified_description, '')
  from public.items it left join public.item_kinds k on k.id = it.kind_id left join public.item_secrets s on s.item_id = it.id
  where it.id = p_item;
$$;

-- one character_revisions row (the player's open sheet re-reads its inventory), once per transaction
create function public._identify_touch(p_character uuid)
returns void
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare k text := 'tl_rev.r' || md5(p_character::text || 'inventory_items' || txid_current()::text);
begin
  if p_character is null or current_setting(k, true) = '1' then return; end if;
  perform set_config(k, '1', true);
  insert into public.character_revisions (character_id, source_table) select p_character, 'inventory_items'
  where exists (select 1 from public.characters c where c.id = p_character);
end $$;

-- the character's knowledge applied to its disguised rows of the item (rows that never had a knowledge row are not touched):
-- knowledge state + revealed, and the name / description the player may see. Full identification closes pending attempts.
create function public._identify_sync_rows(p_character uuid, p_item text)
returns void
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare ck public.character_item_knowledge; it public.items; d record; nm text; ds text;
begin
  select * into ck from public.character_item_knowledge where character_id = p_character and item_id = p_item;
  if ck.character_id is null then return; end if;
  select * into it from public.items where id = p_item;
  select * into d from public._item_decoy(p_item);
  if ck.state = 'identified' then nm := it.name; ds := coalesce(it.description, '');
  else
    nm := case when 'name' = any (ck.revealed) then it.name else d.name end;
    ds := case when 'description' = any (ck.revealed) then coalesce(it.description, '') else d.description end;
  end if;
  update public.inventory_item_knowledge k set state = ck.state, revealed = ck.revealed, updated_by = auth.uid(), updated_at = now(),
         true_name = coalesce(k.true_name, it.name)
    from public.inventory_items ii join public.inventories inv on inv.id = ii.inventory_id
   where k.inventory_item_id = ii.id and inv.character_id = p_character and ii.item_id = p_item
     and (k.state, k.revealed) is distinct from (ck.state, ck.revealed);
  update public.inventory_items ii set name = nm, description = ds
    from public.inventories inv
   where inv.id = ii.inventory_id and inv.character_id = p_character and ii.item_id = p_item
     and exists (select 1 from public.inventory_item_knowledge k where k.inventory_item_id = ii.id)
     and (ii.name, coalesce(ii.description, '')) is distinct from (nm, ds);
  if ck.state = 'identified' then
    update public.item_identify_attempts set status = 'succeeded', revealed = '{all}', resolved_at = now(), resolved_by = auth.uid(),
           dm_note = coalesce(dm_note, 'Identified by the DM')
     where character_id = p_character and item_id = p_item and status = 'pending';
  end if;
end $$;

-- reveal parts (or 'all') of an item to one character; returns the new state
create function public._identify_apply(p_character uuid, p_item text, p_reveal text[])
returns text
language plpgsql security definer
set search_path = public, pg_temp
as $$
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
end $$;

-- may this character try again after its last attempt?
create function public._identify_retry_ok(p_rule text, p_last public.item_identify_attempts)
returns boolean
language sql stable security definer
set search_path = public, pg_temp
as $$
  select case
    when p_last.id is null then true
    when p_last.status = 'pending' then false
    when p_rule = 'unlimited' then true
    when p_rule = 'once' then false
    when p_last.retry_allowed then true
    when p_rule = 'per_long_rest' then exists (
      select 1 from public.character_resource_events e where e.character_id = p_last.character_id and e.event_type = 'long_rest'
        and e.created_at > coalesce(p_last.resolved_at, p_last.created_at))
    else false end;
$$;

-- label of a check key (skill name, official tool name, or the key)
create function public._identify_check_label(p_key text)
returns text
language sql stable security definer
set search_path = public, pg_temp
as $$
  select coalesce((select name from public.skills where id = p_key), (select name from public.items where id = p_key and owner_id is null),
                  initcap(replace(replace(p_key, '-', ' '), '_', ' ')));
$$;

-- one attempt as the player sees it (never the DC, the true name, the DM note)
create function public._identify_attempt_player(a public.item_identify_attempts)
returns jsonb
language sql stable security definer
set search_path = public, pg_temp
as $$
  select jsonb_build_object('attempt_id', a.id, 'status', a.status, 'check_key', a.check_key, 'check_label', public._identify_check_label(a.check_key),
    'roll_total', a.roll_total, 'created_at', a.created_at, 'resolved_at', a.resolved_at, 'auto', a.auto,
    'hint', case when a.status = 'failed' then (select fail_hint from public.item_secrets where item_id = a.item_id) end,
    'revealed', case when a.status = 'succeeded' then to_jsonb(a.revealed) end);
$$;

-- one attempt as the DM sees it
create function public._identify_attempt_dm(a public.item_identify_attempts)
returns jsonb
language sql stable security definer
set search_path = public, pg_temp
as $$
  select public._identify_attempt_player(a) || jsonb_build_object('character_id', a.character_id, 'character_name', ch.name,
    'inventory_item_id', a.inventory_item_id, 'item_id', a.item_id, 'true_name', it.name,
    'shown_name', coalesce((select coalesce(nullif(ii.custom_name, ''), ii.name) from public.inventory_items ii where ii.id = a.inventory_item_id),
                           (select name from public._item_decoy(a.item_id))),
    'dc', s.identify_dc, 'identify_reveal', to_jsonb(coalesce(s.identify_reveal, '{all}')), 'identify_auto', coalesce(s.identify_auto, false),
    'identify_retry', coalesce(s.identify_retry, 'dm'), 'fail_hint', s.fail_hint,
    'dm_roll_total', a.dm_roll_total, 'dm_note', a.dm_note, 'retry_allowed', a.retry_allowed)
  from public.characters ch, public.items it left join public.item_secrets s on s.item_id = it.id
  where ch.id = a.character_id and it.id = a.item_id;
$$;

-- ---- 4. player: examine ---------------------------------------------------------------------------------------------------
create function public.examine_inventory_item(p_inventory_item uuid, p_check text, p_roll int, p_request uuid default null)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare r public.inventory_items; inv public.inventories; ch public.characters; s public.item_secrets; k public.inventory_item_knowledge;
  it public.items; last public.item_identify_attempts; a public.item_identify_attempts; chk text := lower(btrim(coalesce(p_check, '')));
begin
  if auth.uid() is null then raise exception 'Not authenticated' using errcode = '42501'; end if;
  if p_request is not null then
    select * into a from public.item_identify_attempts where request_id = p_request;
    if a.id is not null then
      if a.created_by is distinct from auth.uid() then raise exception 'Item not found' using errcode = '42501'; end if;
      return public._identify_attempt_player(a) || jsonb_build_object('replayed', true);
    end if;
  end if;
  select * into r from public.inventory_items where id = p_inventory_item for update;
  -- a concurrent duplicate waited for the row lock: once it holds the lock the first call has committed, so the replay (not the
  -- "nothing more to find out" / "not answered yet" checks below) answers it
  if p_request is not null then
    select * into a from public.item_identify_attempts where request_id = p_request;
    if a.id is not null then
      if a.created_by is distinct from auth.uid() then raise exception 'Item not found' using errcode = '42501'; end if;
      return public._identify_attempt_player(a) || jsonb_build_object('replayed', true);
    end if;
  end if;
  if r.id is null then raise exception 'Item not found' using errcode = 'P0002'; end if;
  select * into inv from public.inventories where id = r.inventory_id;
  select * into ch from public.characters where id = inv.character_id;
  if ch.id is null or not (ch.owner_id = auth.uid() or public.is_admin()) then
    raise exception 'Only the character''s player can examine this item' using errcode = '42501';
  end if;
  select * into k from public.inventory_item_knowledge where inventory_item_id = r.id;
  if r.item_id is null or k.inventory_item_id is null or k.state = 'identified' then
    raise exception 'There is nothing more to find out about this item' using errcode = '22023';
  end if;
  select * into s from public.item_secrets where item_id = r.item_id;
  if s.identify_dc is null then raise exception 'Your DM has not set up a check for this item' using errcode = '22023'; end if;
  if p_roll is null or p_roll < -10 or p_roll > 60 then raise exception 'Enter the total of your roll (-10 to 60)' using errcode = '22023'; end if;
  if chk = '' or length(chk) > 60 then raise exception 'Choose the check you rolled' using errcode = '22023'; end if;
  if cardinality(s.identify_checks) > 0 and not chk = any (s.identify_checks) then
    raise exception 'This check does not help with this item' using errcode = '22023';
  end if;
  perform 1 from public.characters where id = ch.id for update;   -- one attempt at a time per character
  select * into last from public.item_identify_attempts where character_id = ch.id and item_id = r.item_id order by created_at desc, id limit 1;
  if last.status = 'pending' then raise exception 'Your DM has not answered your last attempt yet' using errcode = '55000'; end if;
  if not public._identify_retry_ok(s.identify_retry, last) then raise exception 'You cannot try again yet' using errcode = '55000'; end if;

  insert into public.item_identify_attempts (character_id, inventory_item_id, item_id, check_key, roll_total, request_id)
  values (ch.id, r.id, r.item_id, chk, p_roll, p_request) on conflict (request_id) do nothing returning * into a;
  if a.id is null then   -- the same request id on another row, committed meanwhile: replay it as well (never a 23505)
    select * into a from public.item_identify_attempts where request_id = p_request;
    if a.created_by is distinct from auth.uid() then raise exception 'Item not found' using errcode = '42501'; end if;
    return public._identify_attempt_player(a) || jsonb_build_object('replayed', true);
  end if;
  insert into public.character_item_knowledge (character_id, item_id, state, revealed, updated_by)
  values (ch.id, r.item_id, k.state, k.revealed, auth.uid()) on conflict (character_id, item_id) do nothing;
  if s.identify_auto then
    if p_roll >= s.identify_dc then
      perform public._identify_apply(ch.id, r.item_id, s.identify_reveal);
      update public.item_identify_attempts set status = 'succeeded', auto = true, revealed = s.identify_reveal, resolved_at = now()
      where id = a.id returning * into a;
    else
      update public.item_identify_attempts set status = 'failed', auto = true, resolved_at = now() where id = a.id returning * into a;
    end if;
  end if;
  select * into it from public.items where id = r.item_id;
  perform public._audit(ch.campaign_id, ch.id, 'item_examined',
    'Examined ' || coalesce(nullif(r.custom_name, ''), r.name) || ' (' || public._identify_check_label(chk) || ' ' || p_roll || ')'
      || case a.status when 'succeeded' then ': learned something' when 'failed' then ': nothing new' else ': waiting for the DM' end,
    null, null, null, null, 'party');
  perform public._audit(ch.campaign_id, ch.id, 'item_examined',
    'Examine attempt on ' || it.name || ' (DC ' || s.identify_dc || '): ' || public._identify_check_label(chk) || ' ' || p_roll || ', ' || a.status,
    null, jsonb_build_object('item_id', it.id, 'attempt_id', a.id), null, null, 'dm');
  perform public._identify_touch(ch.id);
  return public._identify_attempt_player(a);
end $$;

-- ---- 5. DM: resolve, reveal, options, give -------------------------------------------------------------------------------
-- p_success null: decided by the (possibly corrected) roll against the DC. A failed attempt can later get a retry grant.
create function public.resolve_identify_attempt(p_attempt uuid, p_success boolean default null, p_dm_roll int default null,
                                                p_note text default null, p_allow_retry boolean default false, p_reveal text[] default null)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare a public.item_identify_attempts; camp uuid; s public.item_secrets; ok boolean; rev text[];
begin
  select * into a from public.item_identify_attempts where id = p_attempt for update;
  if a.id is null then raise exception 'Attempt not found' using errcode = 'P0002'; end if;
  select campaign_id into camp from public.characters where id = a.character_id;
  if auth.uid() is null or not (public.is_admin() or (camp is not null and public.is_campaign_dm(camp))) then
    raise exception 'Only the DM of the character''s campaign can answer an examine attempt' using errcode = '42501';
  end if;
  if a.status = 'failed' and coalesce(p_allow_retry, false) and p_success is distinct from true then
    update public.item_identify_attempts set retry_allowed = true, dm_note = coalesce(nullif(left(p_note, 500), ''), dm_note) where id = a.id returning * into a;
    perform public._identify_touch(a.character_id);
    return public._identify_attempt_dm(a);
  end if;
  if a.status <> 'pending' then raise exception 'This attempt was already answered' using errcode = '55000'; end if;
  if p_dm_roll is not null and (p_dm_roll < -10 or p_dm_roll > 60) then raise exception 'Roll out of range' using errcode = '22023'; end if;
  select * into s from public.item_secrets where item_id = a.item_id;
  ok := coalesce(p_success, coalesce(p_dm_roll, a.roll_total) >= coalesce(s.identify_dc, 1000));
  if ok then
    rev := coalesce(p_reveal, s.identify_reveal, '{all}');
    perform public._identify_apply(a.character_id, a.item_id, rev);
  end if;
  update public.item_identify_attempts set status = case when ok then 'succeeded' else 'failed' end, revealed = case when ok then rev else '{}' end,
         retry_allowed = not ok and coalesce(p_allow_retry, false), dm_roll_total = p_dm_roll, dm_note = nullif(left(p_note, 500), ''),
         resolved_at = now(), resolved_by = auth.uid()
   where id = a.id returning * into a;
  perform public._audit(camp, a.character_id, 'item_examined',
    'The DM answered an examine attempt: ' || case when ok then 'success' else 'no success' end, null, null, null, null, 'party');
  perform public._identify_touch(a.character_id);
  return public._identify_attempt_dm(a);
end $$;

-- reveal an item (all, or parts) to some characters, or to every character of the campaign (p_characters null)
create function public.dm_reveal_item(p_item text, p_characters uuid[] default null, p_reveal text[] default null, p_campaign uuid default null)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
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
end $$;

-- DM-only identification options (and the disguise) of a campaign homebrew item (hb-: the Inventory homebrew form). Never
-- official rows, and never DM Content: its options live in the content definition ("Identification by players" in the
-- Content editor, definition.hidden), the one source _dm_item_secrets_sync copies on every publish / restore
create function public.set_item_identify_options(p_item text, p_options jsonb)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare it public.items; o jsonb := coalesce(p_options, '{}'); dc int; chk text[]; rev text[]; rt text;
begin
  select * into it from public.items where id = p_item;
  if it.id is null or it.owner_id is null or auth.uid() is null
     or not (public.is_admin() or (it.campaign_id is not null and public.is_campaign_dm(it.campaign_id))) then
    raise exception 'Only the DM of the item''s campaign can set how it is identified' using errcode = '42501';
  end if;
  if exists (select 1 from public.dm_content_versions v where v.catalog_ref = p_item) then
    raise exception 'This item is DM Content: set how it is identified in Content (New version, "Identification by players", Publish)'
      using errcode = '55000';
  end if;
  if jsonb_typeof(o) <> 'object' then raise exception 'Options must be an object' using errcode = '22023'; end if;
  if o ? 'identify_dc' and jsonb_typeof(o -> 'identify_dc') <> 'null' then
    if jsonb_typeof(o -> 'identify_dc') <> 'number' or (o ->> 'identify_dc')::numeric not between 1 and 40 then
      raise exception 'The DC must be between 1 and 40' using errcode = '22023';
    end if;
    dc := (o ->> 'identify_dc')::numeric::int;
  end if;
  if o ? 'identify_checks' then
    if jsonb_typeof(o -> 'identify_checks') <> 'array' then raise exception 'Checks must be a list' using errcode = '22023'; end if;
    chk := array(select distinct lower(btrim(x)) from jsonb_array_elements_text(o -> 'identify_checks') x where btrim(x) <> '' and length(x) <= 60);
  end if;
  if o ? 'identify_reveal' then
    if jsonb_typeof(o -> 'identify_reveal') <> 'array' then raise exception 'Reveal must be a list' using errcode = '22023'; end if;
    rev := array(select distinct btrim(x) from jsonb_array_elements_text(o -> 'identify_reveal') x where btrim(x) <> '' and length(x) <= 40);
    if cardinality(rev) = 0 then rev := '{all}'; end if;
  end if;
  rt := o ->> 'identify_retry';
  if rt is not null and rt not in ('once', 'dm', 'per_long_rest', 'unlimited') then raise exception 'Unknown retry rule' using errcode = '22023'; end if;
  insert into public.item_secrets (item_id, updated_by) values (p_item, auth.uid()) on conflict (item_id) do nothing;
  update public.item_secrets set
    unidentified_name = case when o ? 'unidentified_name' then nullif(left(btrim(o ->> 'unidentified_name'), 80), '') else unidentified_name end,
    unidentified_description = case when o ? 'unidentified_description' then nullif(left(o ->> 'unidentified_description', 1000), '') else unidentified_description end,
    face_kind_id = case when o ? 'show_kind' then case when coalesce((o ->> 'show_kind')::boolean, false) then it.kind_id end else face_kind_id end,
    identify_dc = case when o ? 'identify_dc' then dc else identify_dc end,
    identify_checks = coalesce(chk, identify_checks),
    identify_reveal = coalesce(rev, identify_reveal),
    identify_auto = case when o ? 'identify_auto' then coalesce((o ->> 'identify_auto')::boolean, false) else identify_auto end,
    identify_retry = coalesce(rt, identify_retry),
    fail_hint = case when o ? 'fail_hint' then nullif(left(o ->> 'fail_hint', 500), '') else fail_hint end,
    updated_by = auth.uid(), updated_at = now()
  where item_id = p_item;
  -- a disguised campaign item leaves the players' catalog (they keep seeing identified copies they hold)
  update public.items set secret = true where id = p_item and not secret;
  return (select to_jsonb(s) from public.item_secrets s where s.item_id = p_item);
end $$;

-- give a campaign item (DM Content or campaign homebrew, e.g. a herb from the homebrew form) to characters, by default unidentified
create function public.dm_give_item(p_item text, p_characters uuid[], p_quantity int default 1, p_identified boolean default false)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare it public.items; cid uuid; camp uuid; inv uuid; out jsonb := '[]'; err text; d record;
begin
  select * into it from public.items where id = p_item;
  if it.id is null or auth.uid() is null or not public.can_view_item(p_item) then raise exception 'Item not found' using errcode = 'P0002'; end if;
  if not coalesce(p_identified, true) and it.owner_id is null then
    raise exception 'Copy an official item to campaign homebrew before giving it unidentified' using errcode = '22023';
  end if;
  if coalesce(p_quantity, 1) not between 1 and 999 then raise exception 'Quantity must be 1 to 999' using errcode = '22023'; end if;
  foreach cid in array coalesce(p_characters, '{}') loop
    err := null;
    begin
      select campaign_id into camp from public.characters where id = cid;
      if camp is null or not (public.is_admin() or public.is_campaign_dm(camp)) then raise exception 'Only the DM of the character''s campaign can give items'; end if;
      if it.campaign_id is not null and it.campaign_id <> camp then raise exception 'The item belongs to another campaign'; end if;
      select id into inv from public.inventories where character_id = cid and kind = 'character' order by created_at limit 1;
      if inv is null then raise exception 'The character has no inventory'; end if;
      perform public._dm_add_item(inv, p_item, coalesce(p_quantity, 1), null, coalesce(p_identified, false), null);
      if coalesce(p_identified, false) then
        perform public._audit(camp, cid, 'item_assigned', 'Assigned item: ' || it.name, null, jsonb_build_object('catalog_ref', it.id), null, null, 'party');
      else
        select * into d from public._item_decoy(p_item);
        perform public._audit(camp, cid, 'item_assigned', 'Assigned item: ' || d.name, null, jsonb_build_object('unidentified', true), null, null, 'party');
        perform public._audit(camp, cid, 'item_assigned', 'Assigned item (unidentified): ' || it.name, null,
                              jsonb_build_object('catalog_ref', it.id, 'unidentified', true), null, null, 'dm');
      end if;
    exception when others then err := sqlerrm;
    end;
    out := out || jsonb_build_array(jsonb_build_object('character_id', cid, 'ok', err is null, 'error', err));
  end loop;
  return jsonb_build_object('item_id', p_item, 'results', out);
end $$;

-- DM inbox: examine attempts of the campaign (pending first)
create function public.get_campaign_identify_attempts(p_campaign uuid, p_status text default 'pending')
returns jsonb
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
begin
  if auth.uid() is null or not (public.is_admin() or public.is_campaign_dm(p_campaign)) then
    raise exception 'Only a DM of the campaign can see examine attempts' using errcode = '42501';
  end if;
  return (select coalesce(jsonb_agg(public._identify_attempt_dm(a) order by (a.status = 'pending') desc, a.created_at desc), '[]')
          from (select x.* from public.item_identify_attempts x join public.characters c on c.id = x.character_id
                where c.campaign_id = p_campaign and (p_status is null or x.status = p_status)
                order by (x.status = 'pending') desc, x.created_at desc limit 200) a);
end $$;

-- ---- 6. replaced inventory functions (bodies of 20261015000700 / 20261015000500 / 20261019000500 + the marked changes) ------
-- stack key: a SECRET item's rows also key on their name, so a disguised stack never merges with an identified one. The key of
-- every other row is byte-identical to before (stored keys stay valid).
CREATE OR REPLACE FUNCTION public.compute_stack_key(r inventory_items)
 RETURNS text
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare stk boolean; mods text; sec boolean;
begin
  if r.item_id is null then return null; end if;
  select stackable, secret into stk, sec from public.items where id = r.item_id;
  if not coalesce(stk, false) then return null; end if;
  if exists (select 1 from public.character_equipment e where e.inventory_item_id = r.id) then return null; end if;
  select coalesce(string_agg(modifier_id, ',' order by modifier_id), '') into mods
  from public.inventory_item_modifiers where inventory_item_id = r.id;
  return md5(concat_ws('|', r.inventory_id::text, coalesce(r.container_item_id::text, ''), r.item_id,
                       coalesce(r.custom_name, ''), coalesce(r.notes, ''), r.is_quest_item::text, r.state::text,
                       coalesce(r.durability::text, ''), coalesce(r.charges_current::text, ''), coalesce(r.charges_max::text, ''),
                       coalesce(r.charges_recharge, ''), r.is_attuned::text, coalesce(r.consumable_override::text, ''), mods)
             || case when coalesce(sec, false) then '|n:' || coalesce(r.name, '') else '' end);   -- 20261112000300
end;
$function$;

-- when an item becomes secret (or stops being one) the stored keys of its rows are recomputed (the BEFORE trigger of
-- inventory_items computes the key; only the key changes: no merge, no quantity change). Without it, rows stored before the
-- flip keep the key without the name part and could merge with a row of another name.
create function public._items_secret_stack_keys()
returns trigger
language plpgsql security definer
set search_path = public, pg_temp
as $$
begin
  update public.inventory_items ii set stack_key = public.compute_stack_key(ii)
   where ii.item_id = new.id and ii.stack_key is distinct from public.compute_stack_key(ii);
  return null;
end $$;
revoke all on function public._items_secret_stack_keys() from public, anon, authenticated;
create trigger items_secret_stack_keys after update of secret on public.items
  for each row when (old.secret is distinct from new.secret) execute function public._items_secret_stack_keys();

-- merge only into a row with the same knowledge (state and revealed facts)
CREATE OR REPLACE FUNCTION public._try_auto_merge(p_id uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare r public.inventory_items; o public.inventory_items; smax int;
begin
  select * into r from public.inventory_items where id = p_id for update;
  if r.id is null or r.stack_key is null then return p_id; end if;
  select x.* into o from public.inventory_items x
  where x.stack_key = r.stack_key and x.id <> r.id and x.inventory_id = r.inventory_id
    -- 20261112000300: never across knowledge states (a disguised row and an identified one, or different revealed facts)
    and (select (k.state, k.revealed) from public.inventory_item_knowledge k where k.inventory_item_id = x.id)
        is not distinct from (select (k.state, k.revealed) from public.inventory_item_knowledge k where k.inventory_item_id = r.id)
  order by x.quantity desc, x.id limit 1 for update;
  if o.id is null then return p_id; end if;
  select stack_max into smax from public.items where id = r.item_id;
  if smax is not null and o.quantity + r.quantity > smax then return p_id; end if;
  update public.inventory_items set quantity = o.quantity + r.quantity where id = o.id;
  delete from public.inventory_items where id = r.id;
  perform public.log_inventory_event(o.inventory_id, o.id, 'merge', r.quantity, o.item_id,
                                     jsonb_build_object('merged_from', r.id, 'auto', true));
  return o.id;
end;
$function$;

-- a split copies the knowledge row (a split-off part without one used to reveal the catalog row to its holder)
CREATE OR REPLACE FUNCTION public._split_off(p_id uuid, p_qty integer)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare r public.inventory_items; new_id uuid;
begin
  select * into r from public.inventory_items where id = p_id for update;
  if p_qty < 1 or p_qty >= r.quantity then raise exception 'Cannot split % of %', p_qty, r.quantity; end if;
  if exists (select 1 from public.character_equipment where inventory_item_id = p_id) then
    raise exception 'An equipped item cannot be split';
  end if;
  update public.inventory_items set quantity = quantity - p_qty where id = p_id;
  insert into public.inventory_items
    (inventory_id, item_id, quantity, name, weight, description, sort_order, container_item_id, custom_name, notes,
     is_quest_item, charges_current, charges_max, charges_recharge, durability, state, consumable_override, acquired_at)
  values
    (r.inventory_id, r.item_id, p_qty, r.name, r.weight, r.description, r.sort_order, r.container_item_id, r.custom_name, r.notes,
     r.is_quest_item, r.charges_current, r.charges_max, r.charges_recharge, r.durability, r.state, r.consumable_override, r.acquired_at)
  returning id into new_id;
  insert into public.inventory_item_modifiers (inventory_item_id, modifier_id)
  select new_id, modifier_id from public.inventory_item_modifiers where inventory_item_id = p_id;
  -- 20261112000300
  insert into public.inventory_item_knowledge (inventory_item_id, state, magic_known, revealed, true_name, updated_by, updated_at)
  select new_id, k.state, k.magic_known, k.revealed, k.true_name, k.updated_by, k.updated_at
  from public.inventory_item_knowledge k where k.inventory_item_id = p_id;
  return new_id;
end;
$function$;

-- a transferred disguised row takes the RECEIVING character's knowledge, in the same UPDATE that moves it (the Realtime UPDATE
-- of the recipient never carries a name the recipient has not learned). A party stash keeps the row's own knowledge.
CREATE OR REPLACE FUNCTION public.transfer_inventory_item(p_item uuid, p_to_inventory uuid, p_quantity integer DEFAULT NULL::integer)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare r public.inventory_items; q int; moving uuid; from_inv uuid; res uuid;
  k public.inventory_item_knowledge; to_char uuid; ck public.character_item_knowledge; it public.items; d record; nm text; ds text;
begin
  perform public._gov_gate_item(p_item, 'inventory.transfer'); perform public._gov_gate_inventory(p_to_inventory, 'inventory.transfer');   -- campaign governance (20261019000100)
  perform public._rpc_begin();
  r := public._lock_item(p_item);
  from_inv := r.inventory_id;
  if from_inv = p_to_inventory then raise exception 'Source and target inventory are the same'; end if;
  if not public.can_write_inventory(from_inv) then raise exception 'Not allowed to take items from this inventory' using errcode = '42501'; end if;
  if not public.can_deposit_inventory(p_to_inventory) then raise exception 'Not allowed to add items to the target inventory' using errcode = '42501'; end if;
  if exists (select 1 from public.character_equipment where inventory_item_id = p_item) then
    raise exception 'Unequip the item before transferring it';
  end if;
  if exists (select 1 from public.inventory_items where container_item_id = p_item) then
    raise exception 'The container is not empty';
  end if;
  q := coalesce(p_quantity, r.quantity);
  if q < 1 or q > r.quantity then raise exception 'Invalid quantity % (have %)', q, r.quantity; end if;
  if q < r.quantity then moving := public._split_off(p_item, q); else moving := p_item; end if;

  -- 20261112000300: knowledge of the receiving character
  select * into k from public.inventory_item_knowledge where inventory_item_id = moving;
  select character_id into to_char from public.inventories where id = p_to_inventory;
  if k.inventory_item_id is not null and to_char is not null and r.item_id is not null then
    select * into ck from public.character_item_knowledge where character_id = to_char and item_id = r.item_id;
    if ck.character_id is null then
      insert into public.character_item_knowledge (character_id, item_id, state, revealed, updated_by)
      values (to_char, r.item_id, 'unidentified', '{}', auth.uid()) returning * into ck;
    end if;
    select * into it from public.items where id = r.item_id;
    select * into d from public._item_decoy(r.item_id);
    if ck.state = 'identified' then nm := it.name; ds := coalesce(it.description, '');
    else
      nm := case when 'name' = any (ck.revealed) then it.name else d.name end;
      ds := case when 'description' = any (ck.revealed) then coalesce(it.description, '') else d.description end;
    end if;
    update public.inventory_item_knowledge set state = ck.state, revealed = ck.revealed, updated_by = auth.uid(), updated_at = now()
    where inventory_item_id = moving;
    update public.inventory_items
    set inventory_id = p_to_inventory, container_item_id = null, is_attuned = false, sort_order = 0, name = nm, description = ds,
        custom_name = case when ck.state = 'identified' then custom_name end
    where id = moving;
  else
    update public.inventory_items
    set inventory_id = p_to_inventory, container_item_id = null, is_attuned = false, sort_order = 0
    where id = moving;
  end if;
  perform public.log_inventory_event(from_inv, null, 'transfer', -q, r.item_id, jsonb_build_object('to', p_to_inventory));
  perform public.log_inventory_event(p_to_inventory, moving, 'transfer', q, r.item_id, jsonb_build_object('from', from_inv));
  res := public._try_auto_merge(moving);
  perform public._rpc_end(); return res;
end;
$function$;

-- an unidentified item tells a player nothing when used: no effects, no true type (the face type the DM allowed), no item id in
-- the answer (the inventory event keeps it, as every inventory event does: residual L1, opaque for herbs)
CREATE OR REPLACE FUNCTION public.use_inventory_item(p_item uuid, p_quantity integer DEFAULT 1)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare r public.inventory_items; it public.items; consumable boolean; remaining int; gone boolean := false; fx jsonb; res jsonb;
  masked boolean; kind text; iid text;
begin
  perform public._gov_gate_item(p_item, 'runtime.resources');   -- campaign governance (20261019000100)
  perform public._rpc_begin();
  if p_quantity is null or p_quantity < 1 then raise exception 'Quantity must be at least 1'; end if;
  r := public._lock_item(p_item);
  if not public.can_write_inventory(r.inventory_id) then raise exception 'Not allowed' using errcode = '42501'; end if;
  if r.item_id is null then raise exception 'Only catalog items can be used'; end if;
  if r.quantity < 1 then raise exception 'Nothing left to use' using errcode = '22003'; end if;
  select * into it from public.items where id = r.item_id;
  consumable := coalesce(r.consumable_override, it.is_consumable);
  -- 20261112000300
  masked := exists (select 1 from public.inventory_item_knowledge k where k.inventory_item_id = r.id and k.state <> 'identified')
            and not public._inventory_knows_all(r.inventory_id);
  kind := case when masked then (select f.kind_id from public._inventory_face(r.id) f) else it.kind_id end;
  iid := case when masked then null else r.item_id end;
  if masked then fx := '[]'::jsonb;
  else
    select coalesce(jsonb_agg(jsonb_build_object(
             'effect_type', e.effect_type, 'dice_expression', e.dice_expression, 'flat_value', e.flat_value,
             'damage_type_id', e.damage_type_id, 'duration', e.duration, 'target_type', e.target_type, 'effect_data', e.effect_data)
             order by e.seq), '[]'::jsonb) into fx
    from public.consumable_effects e where e.item_id = r.item_id;
  end if;

  if not consumable then
    perform public.log_inventory_event(r.inventory_id, r.id, 'use', 0, r.item_id,
                                       jsonb_build_object('consumed', false, 'previous_quantity', r.quantity));
    res := jsonb_build_object('item_id', iid, 'kind_id', kind, 'name', coalesce(r.custom_name, r.name), 'consumed', false,
                              'quantity_used', 0, 'previous_quantity', r.quantity, 'remaining', r.quantity, 'deleted', false,
                              'state', r.state, 'effects', fx, 'unidentified', masked);
    perform public._rpc_end(); return res;
  end if;
  if r.quantity < p_quantity then raise exception 'Not enough items (have %, need %)', r.quantity, p_quantity using errcode = '22003'; end if;
  remaining := r.quantity - p_quantity;
  if remaining = 0 then
    delete from public.inventory_items where id = r.id;
    gone := true;
  else
    update public.inventory_items set quantity = remaining where id = r.id;
  end if;
  perform public.log_inventory_event(r.inventory_id, case when gone then null else r.id end, 'use', -p_quantity, r.item_id,
    jsonb_build_object('consumed', true, 'previous_quantity', r.quantity, 'remaining', remaining, 'deleted', gone,
                       'name', coalesce(r.custom_name, r.name), 'state', r.state));
  res := jsonb_build_object('item_id', iid, 'kind_id', kind, 'name', coalesce(r.custom_name, r.name), 'consumed', true,
                            'quantity_used', p_quantity, 'previous_quantity', r.quantity, 'remaining', remaining, 'deleted', gone,
                            'state', r.state, 'effects', fx, 'unidentified', masked);
  perform public._rpc_end(); return res;
end;
$function$;

-- unidentified add: the row is INSERTED with the disguise (and its knowledge row) and merges only with rows of the same
-- disguise and knowledge. A character that already identified the item gets an identified copy.
CREATE OR REPLACE FUNCTION public._dm_add_item(p_inventory uuid, p_item text, p_quantity integer, p_custom_name text, p_identified boolean, p_version uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare it public.items; cid uuid; ck public.character_item_knowledge; d record; nm text; ds text;
  qty int := greatest(coalesce(p_quantity, 1), 1); remaining int; chunk int; rid uuid; last_id uuid;
begin
  if coalesce(p_identified, true) then return public.add_inventory_item(p_inventory, p_item, qty, p_custom_name); end if;
  select character_id into cid from public.inventories where id = p_inventory;
  if cid is not null then select * into ck from public.character_item_knowledge where character_id = cid and item_id = p_item; end if;
  if ck.state = 'identified' then return public.add_inventory_item(p_inventory, p_item, qty, p_custom_name); end if;
  -- the checks of add_inventory_item
  perform public._gov_gate_add_item(p_inventory, p_item);
  perform public._rpc_begin();
  if auth.uid() is null then raise exception 'Not authenticated' using errcode = '42501'; end if;
  if not public.can_deposit_inventory(p_inventory) then raise exception 'Not allowed to add items to this inventory' using errcode = '42501'; end if;
  if not public.can_view_item(p_item) then raise exception 'Unknown item' using errcode = 'P0002'; end if;
  select * into it from public.items where id = p_item;
  if it.archived_at is not null then raise exception 'This homebrew item is archived and cannot be added' using errcode = '22023'; end if;
  update public.items set secret = true where id = p_item and not secret;   -- as before (official rows included: L3, unchanged)
  select * into d from public._item_decoy(p_item);
  nm := case when 'name' = any (coalesce(ck.revealed, '{}')) then it.name else d.name end;
  ds := case when 'description' = any (coalesce(ck.revealed, '{}')) then coalesce(it.description, '') else d.description end;
  remaining := qty;
  while remaining > 0 loop
    chunk := case when it.stackable then least(remaining, coalesce(it.stack_max, remaining)) else 1 end;
    insert into public.inventory_items (inventory_id, item_id, quantity, name, description)
    values (p_inventory, p_item, chunk, nm, ds) returning id into rid;
    insert into public.inventory_item_knowledge (inventory_item_id, state, revealed, true_name, updated_by)
    values (rid, coalesce(ck.state, 'unidentified'), coalesce(ck.revealed, '{}'), it.name, auth.uid());
    last_id := public._try_auto_merge(rid);
    remaining := remaining - chunk;
  end loop;
  -- the item id stays in the event (history stamping of deleted content matches on it); herbs and DM content have opaque ids
  perform public.log_inventory_event(p_inventory, last_id, 'add', qty, p_item, '{"via":"dm","unidentified":true}');
  if cid is not null then
    insert into public.character_item_knowledge (character_id, item_id, state, revealed, updated_by)
    values (cid, p_item, 'unidentified', '{}', auth.uid()) on conflict (character_id, item_id) do nothing;
  end if;
  perform public._rpc_end();
  return last_id;
end;
$function$;

-- DM sets the knowledge of one row: also the character's knowledge (every disguised row of that character follows)
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
$function$;

-- what the caller knows about the items of a character: + the face (type, description, revealed details) and the examine state
CREATE OR REPLACE FUNCTION public.get_character_item_knowledge(p_character uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare camp uuid; dm boolean; mine boolean;
begin
  if auth.uid() is null or not public.can_access_character(p_character) then raise exception 'Character not found' using errcode = '42501'; end if;
  select campaign_id, owner_id = auth.uid() into camp, mine from public.characters where id = p_character;
  dm := public.is_admin() or (camp is not null and public.is_campaign_dm(camp));
  return (select coalesce(jsonb_agg(jsonb_build_object(
             'inventory_item_id', ii.id, 'state', k.state, 'display_name', ii.name, 'magic_known', k.magic_known or 'magic' = any (k.revealed),
             'revealed', to_jsonb(k.revealed),
             'facts', jsonb_build_object(
               'magic', case when dm or 'magic' = any (k.revealed) or k.magic_known then it.is_magic end,
               'rarity', case when dm or 'rarity' = any (k.revealed) then it.rarity_id end,
               'attunement', case when dm or 'attunement' = any (k.revealed) then it.requires_attunement end),
             'properties', (select coalesce(jsonb_agg(p) filter (where dm or (p ->> 'key') = any (k.revealed)), '[]') from jsonb_array_elements(coalesce(s.properties, '[]')) p),
             'curse', case when dm or 'curse' = any (k.revealed) then s.curse end,
             'true_name', case when dm then coalesce(k.true_name, it.name) end, 'item_id', case when dm or k.state = 'identified' then it.id end,
             -- 20261112000300: the face and the examine state
             'kind_id', case when dm or k.state = 'identified' then it.kind_id else s.face_kind_id end,
             'description', ii.description,
             'details', case when dm or k.state = 'identified' or 'details' = any (k.revealed) then it.details end,
             'identify', case when k.state <> 'identified' or dm then jsonb_build_object(
               'enabled', s.identify_dc is not null,
               'checks', (select coalesce(jsonb_agg(jsonb_build_object('key', c, 'label', public._identify_check_label(c)) order by c), '[]')
                          from unnest(coalesce(s.identify_checks, '{}')) c),
               'last', (select public._identify_attempt_player(a) from public.item_identify_attempts a
                        where a.character_id = p_character and a.item_id = ii.item_id order by a.created_at desc, a.id limit 1),
               'can_examine', s.identify_dc is not null and k.state <> 'identified' and (mine or public.is_admin())
                 and public._identify_retry_ok(s.identify_retry, (select a from public.item_identify_attempts a
                        where a.character_id = p_character and a.item_id = ii.item_id order by a.created_at desc, a.id limit 1)))
               || case when dm then jsonb_build_object('dc', s.identify_dc, 'reveal', to_jsonb(coalesce(s.identify_reveal, '{all}')),
                    'auto', coalesce(s.identify_auto, false), 'retry', coalesce(s.identify_retry, 'dm'), 'fail_hint', s.fail_hint,
                    'face_kind_id', s.face_kind_id,
                    -- DM Content keeps its options in the content definition: the DM edits them in the Content editor
                    'content_id', (select v.content_id from public.dm_content_versions v where v.catalog_ref = it.id limit 1),
                    'secrets_editable', it.owner_id is not null
                      and not exists (select 1 from public.dm_content_versions v where v.catalog_ref = it.id)) else '{}'::jsonb end end)
           order by ii.name), '[]')
          from public.inventories inv join public.inventory_items ii on ii.inventory_id = inv.id
          join public.inventory_item_knowledge k on k.inventory_item_id = ii.id
          left join public.items it on it.id = ii.item_id
          left join public.item_secrets s on s.item_id = ii.item_id
          where inv.character_id = p_character);
end;
$function$;

-- secrets (and, since 20261112000300, the identification options) of a published custom item come from definition.hidden: the
-- ONE source of truth for DM Content (set_item_identify_options refuses DM Content). Every version has its own catalog row
-- (cc-<id>-v<n>); copies of an earlier version that players already hold follow the identification options of the version
-- published last, when its definition has an identification section (a definition without one changes nothing there).
-- The decoy, curse and properties stay per version, as before.
CREATE OR REPLACE FUNCTION public._dm_item_secrets_sync()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare t text; h jsonb; kind text; dc int; show boolean; s public.item_secrets; o record; fk text;
  ident constant text[] := array['identify_dc', 'identify_checks', 'identify_reveal', 'identify_auto', 'identify_retry', 'fail_hint', 'kind_face', 'show_kind'];
begin
  if new.status <> 'published' or new.catalog_ref is null or (tg_op = 'UPDATE' and old.status = 'published') then return new; end if;
  select content_type into t from public.dm_content where id = new.content_id;
  if t <> 'item' then return new; end if;
  h := coalesce(new.definition -> 'hidden', '{}');
  if h = '{}'::jsonb then return new; end if;
  kind := coalesce(new.definition -> 'item' ->> 'kind_id', (select kind_id from public.items where id = new.catalog_ref));
  dc := case when (h ->> 'identify_dc') ~ '^\s*\d{1,2}\s*$' then case when (h ->> 'identify_dc')::int between 1 and 40 then (h ->> 'identify_dc')::int end end;
  -- the editor's "Type shown while unidentified" (kind_face: show / hide / default), or show_kind (API); default: herbs show it
  show := case when h ->> 'kind_face' = 'show' then true when h ->> 'kind_face' = 'hide' then false
               when jsonb_typeof(h -> 'show_kind') = 'boolean' then (h ->> 'show_kind')::boolean else kind = 'herbs_plants' end;
  insert into public.item_secrets (item_id, unidentified_name, unidentified_description, curse, properties, updated_by,
                                   face_kind_id, identify_dc, identify_checks, identify_reveal, identify_auto, identify_retry, fail_hint)
  values (new.catalog_ref, nullif(h ->> 'unidentified_name', ''), nullif(h ->> 'unidentified_description', ''), nullif(h ->> 'curse', ''),
          coalesce(h -> 'properties', '[]'), auth.uid(),
          case when show and exists (select 1 from public.item_kinds where id = kind) then kind end, dc,
          case when jsonb_typeof(h -> 'identify_checks') = 'array'
               then array(select distinct lower(btrim(x)) from jsonb_array_elements_text(h -> 'identify_checks') x where btrim(x) <> '' and length(x) <= 60 limit 12)
               else '{}' end,
          coalesce(nullif(case when jsonb_typeof(h -> 'identify_reveal') = 'array'
               then array(select distinct btrim(x) from jsonb_array_elements_text(h -> 'identify_reveal') x where btrim(x) <> '' and length(x) <= 40 limit 24) end, '{}'), '{all}'),
          coalesce(case when jsonb_typeof(h -> 'identify_auto') = 'boolean' then (h ->> 'identify_auto')::boolean end, false),
          case when h ->> 'identify_retry' in ('once', 'dm', 'per_long_rest', 'unlimited') then h ->> 'identify_retry' else 'dm' end,
          nullif(left(h ->> 'fail_hint', 500), ''))
  on conflict (item_id) do update set unidentified_name = excluded.unidentified_name, unidentified_description = excluded.unidentified_description,
    curse = excluded.curse, properties = excluded.properties, updated_by = excluded.updated_by, updated_at = now(),
    face_kind_id = excluded.face_kind_id, identify_dc = excluded.identify_dc, identify_checks = excluded.identify_checks,
    identify_reveal = excluded.identify_reveal, identify_auto = excluded.identify_auto, identify_retry = excluded.identify_retry,
    fail_hint = excluded.fail_hint
  returning * into s;
  -- 20261112000300: an item with a disguise leaves the players' catalog as soon as it is published
  if nullif(h ->> 'unidentified_name', '') is not null or dc is not null then
    update public.items set secret = true where id = new.catalog_ref and not secret and owner_id is not null;
  end if;
  -- the identification options reach the catalog rows of the content's other versions (copies players already hold)
  if h ?| ident then
    for o in select v.catalog_ref as ref, it.kind_id from public.dm_content_versions v join public.items it on it.id = v.catalog_ref
             where v.content_id = new.content_id and v.id <> new.id and v.catalog_ref is distinct from new.catalog_ref loop
      -- the type shown follows the same rule, for that version's own type
      fk := case when (case when h ->> 'kind_face' = 'show' then true when h ->> 'kind_face' = 'hide' then false
                            when jsonb_typeof(h -> 'show_kind') = 'boolean' then (h ->> 'show_kind')::boolean
                            else o.kind_id = 'herbs_plants' end) then o.kind_id end;
      insert into public.item_secrets (item_id, updated_by) values (o.ref, auth.uid()) on conflict (item_id) do nothing;
      update public.item_secrets x set identify_dc = s.identify_dc, identify_checks = s.identify_checks, identify_reveal = s.identify_reveal,
             identify_auto = s.identify_auto, identify_retry = s.identify_retry, fail_hint = s.fail_hint, face_kind_id = fk,
             updated_by = auth.uid(), updated_at = now()
       where x.item_id = o.ref
         and (x.identify_dc, x.identify_checks, x.identify_reveal, x.identify_auto, x.identify_retry, x.fail_hint, x.face_kind_id)
             is distinct from (s.identify_dc, s.identify_checks, s.identify_reveal, s.identify_auto, s.identify_retry, s.fail_hint, fk);
      if dc is not null then update public.items set secret = true where id = o.ref and not secret and owner_id is not null; end if;
    end loop;
  end if;
  return new;
end;
$function$;

-- ---- 7. inventory read model: an unidentified instance is masked for a non-DM caller (appended column: knowledge_state) ----
create or replace view public.v_inventory_detail with (security_invoker = true) as
select
  ii.id, ii.inventory_id, inv.kind as inventory_kind, inv.character_id,
  case when mk.masked then null else ii.item_id end as item_id,
  case when mk.masked then fc.kind_id else i.kind_id end as kind_id,
  case when mk.masked then null else i.category_id end as category_id,
  case when mk.masked then null else i.rarity_id end as rarity_id,
  case when mk.masked then null else i.is_magic end as is_magic,
  case when mk.masked then null else i.requires_attunement end as requires_attunement,
  case when mk.masked then fc.stackable else i.stackable end as stackable,
  ii.name, ii.custom_name, coalesce(nullif(ii.custom_name, ''), ii.name) as display_name, ii.notes, ii.description,
  ii.quantity, coalesce(i.weight_lb, ii.weight) as unit_weight_lb,
  ii.container_item_id, ii.is_quest_item, ii.is_attuned, ii.attuned_at,
  ii.charges_current, ii.charges_max, ii.charges_recharge, ii.durability, ii.state,
  ii.consumable_override, coalesce(ii.consumable_override, case when mk.masked then fc.is_consumable else i.is_consumable end, false) as is_consumable,
  ii.stack_key, ii.sort_order, ii.acquired_at,
  ce.slot_id as equipped_slot, (ce.slot_id is not null) as equipped,
  (select coalesce(array_agg(m.modifier_id order by m.modifier_id), '{}'::text[])
     from public.inventory_item_modifiers m where m.inventory_item_id = ii.id) as modifier_ids,
  kk.state as knowledge_state
from public.inventory_items ii
join public.inventories inv on inv.id = ii.inventory_id
left join public.items i on i.id = ii.item_id
left join public.character_equipment ce on ce.inventory_item_id = ii.id
left join public.inventory_item_knowledge kk on kk.inventory_item_id = ii.id
cross join lateral (select kk.state is not null and kk.state <> 'identified' and auth.uid() is not null
                           and not public._inventory_knows_all(ii.inventory_id) as masked) mk
left join lateral (select f.kind_id, f.stackable, f.is_consumable from public._inventory_face(ii.id) f where mk.masked) fc on true;

-- ---- 8. _character_read: the inventory bundle's catalog part follows the masked rows (body of 20261112000200 + one change) --
CREATE OR REPLACE FUNCTION public._character_read(p_character uuid, p_name text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare inv uuid; r jsonb; v text;
begin
  case p_name
  when 'get_character_derived_stats' then return public.get_character_derived_stats(p_character);
  when 'get_character_proficiencies' then return public.get_character_proficiencies(p_character);
  when 'get_character_lineage' then return public.get_character_lineage(p_character);
  when 'get_character_background' then return public.get_character_background(p_character);
  when 'get_character_feats' then return public.get_character_feats(p_character);
  when 'get_character_class_summary' then return public.get_character_class_summary(p_character);
  when 'get_character_spell_slots' then return public.get_character_spell_slots(p_character);
  when 'get_character_class_features' then return public.get_character_class_features(p_character);
  when 'get_character_resources' then return public.get_character_resources(p_character);
  when 'get_character_states' then return public.get_character_states(p_character);
  when 'get_character_transformation' then return public.get_character_transformation(p_character);
  when 'get_character_infusions' then return public.get_character_infusions(p_character);
  when 'get_character_governance' then return public.get_character_governance(p_character);
  when 'get_character_change_requests' then return public.get_character_change_requests(p_character, false);
  when 'get_character_spellbook' then return public.get_character_spellbook(p_character);
  when 'get_character_conditions' then return public.get_character_conditions(p_character);   -- 20261112000200 (the caller's view)
  -- the stored rows of js/store.js loadBundle
  when 'characters' then
    select to_jsonb(c) into r from public.characters c where c.id = p_character;
    if r is null then raise exception 'Character not found' using errcode = '42501'; end if;
    return r;
  when 'inventory_items' then
    return (select coalesce(jsonb_agg(to_jsonb(x) order by x.sort_order, x.created_at), '[]') from public.inventory_items x where x.character_id = p_character);
  when 'notes' then
    return (select coalesce(jsonb_agg(to_jsonb(x) order by x.id), '[]') from public.notes x where x.character_id = p_character);
  when 'spell_slots' then
    return (select coalesce(jsonb_agg(to_jsonb(x) order by x.level), '[]') from public.spell_slots x where x.character_id = p_character);
  when 'feature_trackers' then
    return (select coalesce(jsonb_agg(to_jsonb(x) order by x.sort_order, x.created_at), '[]') from public.feature_trackers x where x.character_id = p_character);
  when 'features' then
    return (select coalesce(jsonb_agg(to_jsonb(x) order by x.sort_order, x.created_at), '[]') from public.features x where x.character_id = p_character);
  when 'attacks' then
    return (select coalesce(jsonb_agg(to_jsonb(x) order by x.sort_order, x.created_at), '[]') from public.attacks x where x.character_id = p_character);
  when 'spells' then
    return (select coalesce(jsonb_agg(to_jsonb(x) order by x.level, x.sort_order, x.created_at), '[]') from public.spells x where x.character_id = p_character);
  -- js/creature-api.js getCompanions (embedded creature, ordered by created_at)
  when 'companions' then
    return (select coalesce(jsonb_agg(jsonb_build_object('id', cc.id, 'name', cc.name, 'source', cc.source, 'hp_max', cc.hp_max,
        'hp_current', cc.hp_current, 'notes', cc.notes, 'active', cc.active, 'creature_id', cc.creature_id,
        'creature', (select jsonb_build_object('id', cr.id, 'name', cr.name, 'size', cr.size, 'creature_type', cr.creature_type,
            'challenge_rating', cr.challenge_rating, 'armor_class', cr.armor_class, 'speed', cr.speed, 'actions', cr.actions,
            'abilities', cr.abilities) from public.creatures cr where cr.id = cc.creature_id)) order by cc.created_at), '[]')
      from public.character_companions cc where cc.character_id = p_character);
  -- js/class-api.js getStartingEquipmentState: applied marker + the primary class's starting-equipment catalog
  when 'starting_equipment_applied' then
    return (select jsonb_build_object('class_version_id', s.class_version_id) from public.character_starting_equipment s where s.character_id = p_character);
  when 'primary_class_starting_equipment' then
    select k.class_version_id into v from public.character_classes k where k.character_id = p_character and k.is_primary limit 1;
    if v is null then return null; end if;
    return jsonb_build_object('class_version_id', v, 'equipment', public.get_class_starting_equipment(v));
  -- js/inventory-ui.js load(): one bundle instead of 7 requests + a catalog chunk
  when 'inventory_bundle' then
    select id into inv from public.inventories where character_id = p_character and kind = 'character';
    if inv is null then return null; end if;
    return jsonb_build_object(
      'inventory_id', inv,
      'rows', (select coalesce(jsonb_agg(to_jsonb(d) order by d.sort_order, d.acquired_at, d.id), '[]') from public.v_inventory_detail d where d.inventory_id = inv),
      'equipment', (select coalesce(jsonb_agg(jsonb_build_object('slot_id', e.slot_id, 'inventory_item_id', e.inventory_item_id, 'equipped_at', e.equipped_at) order by e.slot_id), '[]')
                    from public.character_equipment e where e.character_id = p_character),
      'attunement', (select to_jsonb(a) from public.v_character_attunement a where a.character_id = p_character),
      'weight', (select to_jsonb(w) from public.v_inventory_weight w where w.inventory_id = inv),
      'containers', (select coalesce(jsonb_agg(to_jsonb(c) order by c.container_item_id), '[]') from public.v_container_contents c where c.inventory_id = inv),
      'review', (select coalesce(jsonb_agg(jsonb_build_object('inventory_item_id', x.inventory_item_id, 'category', x.category, 'status', x.status, 'detail', x.detail) order by x.id), '[]')
                 from public.legacy_inventory_review x where x.character_id = p_character and x.status in ('pending', 'manual_review')),
      -- the columns of js/inventory-api.js CATALOG_COLUMNS
      'catalog_items', (select coalesce(jsonb_agg(to_jsonb(ci)), '[]') from (
          select id, name, kind_id, kind_name, category_id, category_name, rarity_id, is_magic, requires_attunement, is_consumable,
            stackable, weight_lb, cost_value, cost_unit, source_book_id, source_book_name, source_label, owner_id, campaign_id,
            visibility, is_mine, can_edit, archived_at, description, data_source_id, weapon_group, damage_dice, damage_type_id,
            versatile_damage, is_ranged, range_type, range_normal, range_max, weapon_ammo_type_id, reload, misfire, weapon_properties,
            base_ac, ac_bonus, dex_modifier_mode, dex_cap, strength_requirement, stealth_disadvantage, is_shield, ammo_type_id,
            pack_size, capacity_weight_lb, capacity_volume_cuft, weightless_contents, extradimensional, icon_key, details   -- 20261107000300
          from public.v_item_catalog
          -- 20261112000300: the masked rows' ids only (an unidentified instance has item_id null for a player), so the bundle never
          -- carries the catalog row of an item the character has not identified (L2)
          where id in (select d.item_id from public.v_inventory_detail d where d.inventory_id = inv and d.item_id is not null)) ci));
  when 'revisions' then   -- latest revision (log id) per source table
    return (select coalesce(jsonb_object_agg(x.source_table, x.rev), '{}') from (
      select r2.source_table, max(r2.id) as rev from public.character_revisions r2 where r2.character_id = p_character group by 1) x);
  else
    raise exception 'Unknown read %', p_name using errcode = '22023';
  end case;
end $function$;

-- ---- 9. grants ------------------------------------------------------------------------------------------------------------
revoke all on function public._item_decoy(text), public._identify_touch(uuid), public._identify_sync_rows(uuid, text),
  public._identify_apply(uuid, text, text[]), public._identify_retry_ok(text, public.item_identify_attempts), public._identify_check_label(text),
  public._identify_attempt_player(public.item_identify_attempts), public._identify_attempt_dm(public.item_identify_attempts)
  from public, anon, authenticated;
-- called inside v_inventory_detail (security invoker): the reader needs EXECUTE; both check the caller themselves
revoke all on function public._inventory_knows_all(uuid), public._inventory_face(uuid) from public, anon;
grant execute on function public._inventory_knows_all(uuid), public._inventory_face(uuid) to authenticated, service_role;
revoke all on function public.examine_inventory_item(uuid, text, int, uuid),
  public.resolve_identify_attempt(uuid, boolean, int, text, boolean, text[]), public.dm_reveal_item(text, uuid[], text[], uuid),
  public.set_item_identify_options(text, jsonb), public.dm_give_item(text, uuid[], int, boolean),
  public.get_campaign_identify_attempts(uuid, text) from public, anon;
grant execute on function public.examine_inventory_item(uuid, text, int, uuid),
  public.resolve_identify_attempt(uuid, boolean, int, text, boolean, text[]), public.dm_reveal_item(text, uuid[], text[], uuid),
  public.set_item_identify_options(text, jsonb), public.dm_give_item(text, uuid[], int, boolean),
  public.get_campaign_identify_attempts(uuid, text) to authenticated, service_role;

notify pgrst, 'reload schema';
