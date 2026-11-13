-- =============================================================================
-- Party-wide identification (R-A; docs/HIDDEN_DM_DATA.md "Identification is shared with the party"). Owner decision: once one
-- character of a campaign identifies an item, every character of the campaign knows it, including characters who join later.
--
-- Model: COPY ON WRITE. character_item_knowledge stays the per-character record and the character's disguised inventory rows keep
-- following it (T4 _identify_sync_rows), so no read path changes (v_inventory_detail, _item_visible, _character_read, RLS, Realtime).
-- * Rule campaign_item_rules.share_identification (a missing row = ON). Off = the per-character model of 20261112000300/0400.
--   Switching it on catches the campaign up once; switching it off never lowers anything.
-- * A player-side raise (examine success, the DM's answer, crafting) goes through _identify_apply: it locks its own target in the
--   canonical order, applies (_identify_apply_one = the old body), lifts a DM hold only when the result is 'identified', applies
--   the target's own pending shares and
--   shares with the other characters. The DM's bulk calls (dm_set_item_knowledge, dm_reveal_item) apply per character and share
--   ONCE at the end (worst case O(N) guarded writes for N characters).
-- * LOCKING (B1): a transaction never waits on another character. A character that is not the transaction's own target is
--   touched only in a subtransaction with a 200 ms lock_timeout (restored) and NOWAIT locks in the order of the existing RPCs:
--   characters (key share) -> tl_cache.character_rev -> its rows (id order) -> their row knowledge -> its record.
-- * PENDING SHARES (round 3: party shares ONLY; DM writes are never queued). A party share that finds its target busy is kept in
--   party_share_pending (one row per target and item, merged; plain ids, no foreign keys: writing it locks nothing of the target).
--   It is applied in the target's own context (its next _identify_apply, sync_party_knowledge from the sheet,
--   dm_sync_party_knowledge) with the system actor, and dropped when the target is held, left the campaign, the rule is off, or
--   a DM wrote that character's knowledge of the item after the row was made. Every DM write of a (character, item) deletes its
--   pending rows. A busy character in a DM call is NOT changed and is named in busy_names ("try again").
-- * Knowledge travels only inside its campaign (M1/M1b): what a character can share in a campaign is what it learned there:
--   the union of the facts its item_knowledge_events of THIS campaign added (new_revealed - old_revealed), and "identified" only
--   when such an event reached it.
-- * Explicit DM choices win: mode 'set' and a lowering through the old per-copy editor hold the character back (held_by_dm);
--   sharing never reaches it and it is never a source. THE HOLD RULE (v31, owner): a hold is lifted ONLY by
--   dm_release_item_knowledge_hold or when a raise moves the character's record INTO 'identified' from a lower state (its own
--   full success, the DM's reveal of everything); "Set" at any level, also Everything, holds, and a later raise of a record that
--   is identified already keeps the hold. A non-held character raised by the DM also gets the party level of the item (m1). A partial raise of any kind (examine, the DM's answer, dm_set_item_knowledge 'raise', dm_reveal_item, the
--   per-copy editor), a rule switch, a sync or another character's reveal never lifts it. The hold follows the character and the
--   item, also into another campaign (m4).
-- * A failed or pending examine writes nothing for anyone else. A share never lowers a copy and closes the target's pending
--   examine attempts as "Learned from the party" (no resolver). Shares are written with no actor (system).
-- * Joiners: an AFTER INSERT / UPDATE OF campaign_id / DELETE trigger gives a joining character the party level (own rows only,
--   one summary audit line, never aborts) and removes pending rows of a character that left or was deleted.
-- Cache: campaign_item_rules and party_share_pending feed no cached read -> tl_cache.skip() (party_share_pending names its
-- character column target_character_id on purpose: a bump would lock the busy target's counter row, the thing it avoids).
-- tl_cache.bump_item_knowledge takes other holders' counters NOWAIT: in a share it defers the share (busy), elsewhere it falls
-- back to one global bump (NOWAIT); when that is busy too it raises lock_not_available (never a silently skipped bump).
-- Rollback: supabase/rollback/rollback_party_item_knowledge.sql.
-- =============================================================================
set lock_timeout = '5s';

-- ---- 1. tables and columns --------------------------------------------------------------------------------------------------
create table public.campaign_item_rules (
  campaign_id          uuid primary key references public.campaigns (id) on delete cascade,
  share_identification boolean not null default true,
  updated_by           uuid references public.profiles (id) on delete set null,
  updated_at           timestamptz not null default now()
);
alter table public.campaign_item_rules enable row level security;
revoke all on public.campaign_item_rules from anon, authenticated;
create trigger tl_cache_rev after insert or update or delete on public.campaign_item_rules
  for each row execute function tl_cache.skip();

-- a party share that could not take the target's locks at once (one row per target and item, merged); plain ids, no foreign keys
create table public.party_share_pending (
  id                  bigint generated always as identity primary key,
  campaign_id         uuid not null,
  target_character_id uuid not null,
  item_id             text not null,
  state               text not null check (state in ('partially_identified', 'identified')),
  revealed            text[] not null default '{}',
  source_character_id uuid,
  created_at          timestamptz not null default now(),
  unique (target_character_id, item_id)
);
create index party_share_pending_campaign on public.party_share_pending (campaign_id);
alter table public.party_share_pending enable row level security;
revoke all on public.party_share_pending from anon, authenticated;
create trigger tl_cache_rev after insert or update or delete on public.party_share_pending
  for each row execute function tl_cache.skip();

alter table public.character_item_knowledge add column held_by_dm boolean not null default false;
-- source_character_id is a plain uuid (round 1, B1: a foreign key would key-share-lock the source character on every event)
alter table public.item_knowledge_events
  add column source text check (source is null or source ~ '^[a-z_]{1,40}$'),
  add column source_character_id uuid;

-- ---- 2. small helpers ---------------------------------------------------------------------------------------------------------
create function public._party_share_on(p_campaign uuid)
returns boolean
language sql stable security definer
set search_path = public, pg_temp
as $$
  select p_campaign is not null
     and coalesce((select r.share_identification from public.campaign_item_rules r where r.campaign_id = p_campaign), true);
$$;

-- what a character can share about an item in THIS campaign (M1b + M1c): the facts its events of this campaign added, and
-- "identified" only when such an event reached it -- CAPPED by what its record knows NOW (knowledge the DM took back is never
-- shared: "identified" only while the record is identified; otherwise only the facts still in the record's revealed[]).
-- Knowledge from another campaign (or with no event) is never shared here.
create function public._ik_campaign_level(p_character uuid, p_item text, p_campaign uuid, out ident boolean, out rev text[])
language sql stable security definer
set search_path = public, pg_temp
as $$
  with ev as (
    select coalesce(bool_or(e.new_state = 'identified' and e.old_state is distinct from 'identified'), false) as ident,
           coalesce((select array_agg(distinct x order by x) from public.item_knowledge_events e2 cross join unnest(e2.new_revealed) x
                     where e2.character_id = p_character and e2.item_id = p_item and e2.campaign_id = p_campaign
                       and x <> 'all' and not (x = any (coalesce(e2.old_revealed, '{}')))), '{}') as rev
    from public.item_knowledge_events e
    where e.character_id = p_character and e.item_id = p_item and e.campaign_id = p_campaign),
  ck as (select state, revealed from public.character_item_knowledge where character_id = p_character and item_id = p_item)
  select coalesce(ev.ident and ck.state = 'identified', false),
         case when ck.state is null then '{}'::text[]
              when ck.state = 'identified' then ev.rev
              else coalesce(array(select x from unnest(ev.rev) x where x = any (ck.revealed) order by x), '{}') end
  from ev left join ck on true;
$$;

-- every DM write of a character's knowledge of an item supersedes the party shares queued for that pair. No lock of the target and
-- no wait: a row another transaction is merging or applying at this moment is skipped (SKIP LOCKED); such a row can never undo a
-- hide, because applying it re-checks the hold, the campaign, the rule and a newer DM write of the pair, and drops it.
create function public._ik_drop_pending(p_character uuid, p_item text)
returns void
language sql security definer
set search_path = public, pg_temp
as $$
  delete from public.party_share_pending
   where id in (select id from public.party_share_pending where target_character_id = p_character and item_id = p_item
                for update skip locked);
$$;

-- does (state, revealed) contain at least what (old_state, old_revealed) did?
create function public._ik_contains(p_state text, p_revealed text[], p_old_state text, p_old_revealed text[])
returns boolean
language sql immutable
set search_path = public, pg_temp
as $$
  select p_old_state is null or p_state = 'identified'
      or (coalesce(p_old_state, 'unidentified') <> 'identified' and coalesce(p_old_revealed, '{}') <@ coalesce(p_revealed, '{}'));
$$;

-- body of 20261112000400 + source / source_character_id from the transaction-local settings tl.ik_source / tl.ik_source_char;
-- a party share is written with no actor (tl.ik_system)
CREATE OR REPLACE FUNCTION public._item_knowledge_log()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare src text := nullif(current_setting('tl.ik_source', true), ''); sch text := nullif(current_setting('tl.ik_source_char', true), '');
begin
  if tg_op = 'UPDATE' and (old.state, old.revealed) is not distinct from (new.state, new.revealed) then return null; end if;
  insert into public.item_knowledge_events (campaign_id, character_id, item_id, old_state, old_revealed, new_state, new_revealed, actor,
                                            source, source_character_id)
  values ((select c.campaign_id from public.characters c where c.id = new.character_id), new.character_id, new.item_id,
          case when tg_op = 'UPDATE' then old.state end, case when tg_op = 'UPDATE' then old.revealed end,
          new.state, new.revealed, case when current_setting('tl.ik_system', true) = '1' then null else auth.uid() end,
          src, case when src is not null then sch::uuid end);
  return null;
end $function$;

-- T4 (20261112000300) + B1: the counter rows of OTHER holders are taken NOWAIT. A busy one:
-- * inside a party share (tl.ik_defer = '1'): raise lock_not_available, so the whole share for that target is deferred (pending);
-- * elsewhere (the transaction's own target: an examine, the DM's answer or set): one global bump instead, NOWAIT; if the global
--   counter is busy as well: raise lock_not_available (the DM call reports that character busy, an own write fails "try again"):
--   a bump is never skipped silently, so a lowering always invalidates the caches it must.
CREATE OR REPLACE FUNCTION tl_cache.bump_item_knowledge()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare rid uuid; iid text; cid uuid; k text; g text;
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
               where ii.item_id = iid and inv.character_id is not null order by 1 loop
      k := 'tl_cache.c' || md5(cid::text || txid_current()::text);   -- the dedup key of tl_cache.bump
      continue when current_setting(k, true) = '1';
      begin
        perform 1 from tl_cache.character_rev where character_id = cid for update nowait;
        insert into tl_cache.character_rev as r (character_id, rev)
        select cid, 1 where exists (select 1 from public.characters c where c.id = cid)
        on conflict (character_id) do update set rev = r.rev + 1;
        perform set_config(k, '1', true);
      exception when lock_not_available then
        if current_setting('tl.ik_defer', true) = '1' then raise; end if;
        g := 'tl_cache.g' || md5(txid_current()::text);
        if coalesce(current_setting(g, true), '') <> '1' then
          perform 1 from tl_cache.global_rev where id = 1 for update nowait;   -- busy: lock_not_available goes to the caller
          update tl_cache.global_rev set rev = rev + 1 where id = 1;
          perform set_config(g, '1', true);
        end if;
      end;
    end loop;
  end loop;
  return null;
end $function$;

-- the locks of a character that is NOT the transaction's own target, in the order of the existing RPCs, all NOWAIT.
-- Call it only inside a guarded subtransaction (a busy lock raises lock_not_available).
create function public._ik_lock_target(p_character uuid, p_item text)
returns void
language plpgsql security definer
set search_path = public, pg_temp
as $$
begin
  perform 1 from public.characters where id = p_character for key share nowait;
  perform 1 from tl_cache.character_rev where character_id = p_character for update nowait;
  perform 1 from public.inventory_items ii join public.inventories inv on inv.id = ii.inventory_id
   where inv.character_id = p_character and ii.item_id = p_item order by ii.id for update of ii nowait;
  perform 1 from public.inventory_item_knowledge k join public.inventory_items ii on ii.id = k.inventory_item_id
    join public.inventories inv on inv.id = ii.inventory_id
   where inv.character_id = p_character and ii.item_id = p_item order by k.inventory_item_id for update of k nowait;
  perform 1 from public.character_item_knowledge where character_id = p_character and item_id = p_item for update nowait;
end $$;

-- ---- 3. apply ---------------------------------------------------------------------------------------------------------------
-- the body of _identify_apply of 20261112000300, unchanged: reveal parts (or 'all') of an item to ONE character
create function public._identify_apply_one(p_character uuid, p_item text, p_reveal text[])
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

-- the DM's exact level for one character (the 'set' branch of dm_set_item_knowledge of 20261112000400) + the hold
create function public._ik_apply_set(p_character uuid, p_item text, p_state text, p_revealed text[])
returns boolean
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare it public.items; plain int; fp0 text := public._ik_fingerprint(p_character, p_item);
begin
  select * into it from public.items where id = p_item;
  perform public._ik_drop_pending(p_character, p_item);
  if p_state <> 'identified' then
    -- undisguised rows of this character get a knowledge row, so the sync below disguises them too (m6)
    insert into public.inventory_item_knowledge (inventory_item_id, state, revealed, true_name, updated_by)
    select ii.id, 'identified', '{}', it.name, auth.uid()
      from public.inventory_items ii join public.inventories inv on inv.id = ii.inventory_id
     where inv.character_id = p_character and ii.item_id = p_item
       and not exists (select 1 from public.inventory_item_knowledge k where k.inventory_item_id = ii.id)
     order by ii.id;
    get diagnostics plain = row_count;
    if plain > 0 then update public.items set secret = true where id = p_item and not secret; end if;
  end if;
  insert into public.character_item_knowledge as x (character_id, item_id, state, revealed, updated_by)
  values (p_character, p_item, p_state, coalesce(p_revealed, '{}'), auth.uid())
  on conflict (character_id, item_id) do update set state = excluded.state, revealed = excluded.revealed,
    updated_by = excluded.updated_by, updated_at = now()
  where (x.state, x.revealed) is distinct from (excluded.state, excluded.revealed);
  update public.character_item_knowledge set held_by_dm = true where character_id = p_character and item_id = p_item and not held_by_dm;
  perform public._identify_sync_rows(p_character, p_item);
  return fp0 is distinct from public._ik_fingerprint(p_character, p_item);
end $$;

-- give ONE other character at least (p_state, p_revealed) of an item, as party knowledge. No locks of its own (the caller,
-- _party_guarded, holds the target's locks). Skips a held character and one that holds only undisguised copies. Never lowers a
-- copy: the target's own row knowledge is part of the union. Written with no actor (system). Returns 1 when it changed.
create function public._party_apply_to(p_target uuid, p_item text, p_state text, p_revealed text[], p_quiet boolean default false)
returns int
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare ck public.character_item_knowledge; rev text[]; st text; it public.items; d record; camp uuid; shown text;
  row_ident boolean; row_rev text[];
begin
  if p_target is null or p_item is null or p_state is null then return 0; end if;
  select * into ck from public.character_item_knowledge where character_id = p_target and item_id = p_item;
  if coalesce(ck.held_by_dm, false) then return 0; end if;
  if exists (select 1 from public.inventory_items ii join public.inventories inv on inv.id = ii.inventory_id
             where inv.character_id = p_target and ii.item_id = p_item
               and not exists (select 1 from public.inventory_item_knowledge k where k.inventory_item_id = ii.id))
     and not exists (select 1 from public.inventory_items ii join public.inventories inv on inv.id = ii.inventory_id
                     join public.inventory_item_knowledge k on k.inventory_item_id = ii.id
                     where inv.character_id = p_target and ii.item_id = p_item) then
    return 0;
  end if;
  select bool_or(k.state = 'identified'), coalesce(array_agg(x) filter (where x is not null), '{}')
    into row_ident, row_rev
    from public.inventory_items ii join public.inventories inv on inv.id = ii.inventory_id
    join public.inventory_item_knowledge k on k.inventory_item_id = ii.id
    left join lateral unnest(k.revealed) x on true
   where inv.character_id = p_target and ii.item_id = p_item;
  rev := array(select distinct x from unnest(coalesce(ck.revealed, '{}') || coalesce(p_revealed, '{}') || coalesce(row_rev, '{}')) x
               where x is not null and btrim(x) <> '' and x <> 'all' order by 1);
  st := case when p_state = 'identified' or ck.state = 'identified' or coalesce(row_ident, false) then 'identified'
             when cardinality(rev) > 0 then 'partially_identified' else coalesce(ck.state, 'unidentified') end;
  if st = 'unidentified' and cardinality(rev) = 0 then return 0; end if;
  if ck.character_id is not null and (ck.state, ck.revealed) is not distinct from (st, rev) then return 0; end if;
  -- the target's own pending examine attempts are closed as learned from the party (not "by the DM", no resolver)
  if st = 'identified' then
    update public.item_identify_attempts set status = 'succeeded', revealed = '{all}', resolved_at = now(), resolved_by = null,
           dm_note = coalesce(dm_note, 'Learned from the party')
     where character_id = p_target and item_id = p_item and status = 'pending';
  end if;
  perform set_config('tl.ik_system', '1', true);   -- no actor: neither the player who identified it nor the one who synced
  perform public._identify_apply_one(p_target, p_item, case when st = 'identified' then rev || '{all}'::text[] else rev end);
  update public.character_item_knowledge set updated_by = null where character_id = p_target and item_id = p_item and updated_by is not null;
  perform set_config('tl.ik_system', '', true);
  -- a hold set meanwhile (cannot happen while we hold the record NOWAIT, kept as a guard): undo this share in the subtransaction
  if exists (select 1 from public.character_item_knowledge where character_id = p_target and item_id = p_item and held_by_dm) then
    raise exception 'held back meanwhile' using errcode = '55P03';
  end if;
  if not p_quiet then
    -- the target player's own line (non-DM audit events reach only the character's owner): no actor, never who identified it, the
    -- true name only when the target now knows the name
    select * into it from public.items where id = p_item;
    select * into d from public._item_decoy(p_item);
    select campaign_id into camp from public.characters where id = p_target;
    shown := case when st = 'identified' or 'name' = any (rev) then it.name else d.name end;
    insert into public.campaign_audit_events (campaign_id, character_id, actor_id, event_type, summary, after, visibility)
    values (camp, p_target, null, 'item_revealed', left('Your party learned something about an item: ' || shown, 300),
            jsonb_build_object('revealed', to_jsonb(case when st = 'identified' then '{all}'::text[] else rev end), 'source', 'party_share'), 'party');
  end if;
  perform set_config('tl.ik_shared', (coalesce(nullif(current_setting('tl.ik_shared', true), ''), '0')::int + 1)::text, true);
  return 1;
end $$;

-- B1: one party share to a character that is not the transaction's own target. Own subtransaction, 200 ms lock_timeout
-- (restored), NOWAIT locks in the canonical order, tl.ik_defer (a busy co-holder counter defers the share too). Busy -> the
-- share is kept in party_share_pending (merged with an earlier one: union of facts, the higher level) and -1. Applied: 1 / 0.
-- p_pending: the pending row being applied (deleted on success, kept while busy).
create function public._party_guarded(p_target uuid, p_item text, p_state text, p_revealed text[], p_source uuid,
                                      p_campaign uuid, p_quiet boolean default false, p_pending bigint default null)
returns int
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare lt text := current_setting('lock_timeout'); df text := coalesce(current_setting('tl.ik_defer', true), ''); r int := 0;
begin
  begin
    perform set_config('lock_timeout', '200ms', true);
    perform set_config('tl.ik_defer', '1', true);
    perform public._ik_lock_target(p_target, p_item);
    r := public._party_apply_to(p_target, p_item, p_state, p_revealed, p_quiet);
    perform set_config('lock_timeout', lt, true);
    perform set_config('tl.ik_defer', df, true);
  exception when lock_not_available or deadlock_detected then
    -- the subtransaction (writes and both settings) is rolled back; nothing of the target was locked or written
    if p_pending is null then
      insert into public.party_share_pending as x (campaign_id, target_character_id, item_id, state, revealed, source_character_id)
      values (p_campaign, p_target, p_item, p_state, coalesce(p_revealed, '{}'), p_source)
      on conflict (target_character_id, item_id) do update set
        state = case when x.campaign_id = excluded.campaign_id and x.state = 'identified' then 'identified' else excluded.state end,
        revealed = case when x.campaign_id = excluded.campaign_id
                        then array(select distinct u from unnest(x.revealed || excluded.revealed) u order by 1) else excluded.revealed end,
        campaign_id = excluded.campaign_id, source_character_id = excluded.source_character_id, created_at = now();
    end if;
    perform set_config('tl.ik_pending', (coalesce(nullif(current_setting('tl.ik_pending', true), ''), '0')::int + 1)::text, true);
    return -1;
  end;
  if p_pending is not null then delete from public.party_share_pending where id = p_pending; end if;
  return r;
end $$;

-- push what p_source learned about an item IN THIS campaign (M1b) to the other characters of its campaign (rule on)
create function public._party_share_from(p_source uuid, p_item text)
returns int
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare camp uuid; src public.character_item_knowledge; it public.items; lv record; t uuid; n int := 0; r int; prev_s text; prev_c text;
begin
  select campaign_id into camp from public.characters where id = p_source;
  if camp is null or not public._party_share_on(camp) then return 0; end if;
  select * into src from public.character_item_knowledge where character_id = p_source and item_id = p_item;
  if src.character_id is null or src.held_by_dm then return 0; end if;
  select * into it from public.items where id = p_item;
  if it.id is null or (it.campaign_id is not null and it.campaign_id <> camp) then return 0; end if;
  select * into lv from public._ik_campaign_level(p_source, p_item, camp);
  if not lv.ident and cardinality(lv.rev) = 0 then return 0; end if;
  prev_s := current_setting('tl.ik_source', true); prev_c := current_setting('tl.ik_source_char', true);
  perform set_config('tl.ik_source', 'party_share', true);
  perform set_config('tl.ik_source_char', p_source::text, true);
  for t in select c.id from public.characters c where c.campaign_id = camp and c.id <> p_source order by c.id loop
    r := public._party_guarded(t, p_item, case when lv.ident then 'identified' else 'partially_identified' end, lv.rev, p_source, camp);
    if r > 0 then n := n + 1; end if;
  end loop;
  perform set_config('tl.ik_source', coalesce(prev_s, ''), true);
  perform set_config('tl.ik_source_char', coalesce(prev_c, ''), true);
  if n > 0 then
    perform public._audit(camp, p_source, 'item_revealed',
      'Knowledge of ' || it.name || ' shared with the party (' || n || ' character' || case when n = 1 then '' else 's' end || ')',
      null, jsonb_build_object('item_id', it.id, 'mode', 'party_share', 'characters', n), null, null, 'dm');
  end if;
  return n;
end $$;

-- the party level of the items of a campaign: union of what its non-held characters (except p_except) learned IN THIS campaign
-- (M1b), for items of no campaign or of this campaign; one representative source per item
create function public._party_levels(p_campaign uuid, p_except uuid, p_item text default null)
returns table (item_id text, ident boolean, rev text[], src uuid)
language sql stable security definer
set search_path = public, pg_temp
as $$
  with k as (
    select ck.character_id, ck.item_id, ck.updated_at, l.ident, l.rev
    from public.character_item_knowledge ck
    join public.characters c on c.id = ck.character_id
    join public.items it on it.id = ck.item_id
    cross join lateral public._ik_campaign_level(ck.character_id, ck.item_id, p_campaign) l
    where c.campaign_id = p_campaign and c.id is distinct from p_except and not ck.held_by_dm
      and (p_item is null or ck.item_id = p_item)
      and (it.campaign_id is null or it.campaign_id = p_campaign)
      and (l.ident or cardinality(l.rev) > 0))
  select k.item_id, bool_or(k.ident),
         coalesce((select array_agg(distinct x order by x) from k k2 cross join unnest(k2.rev) x where k2.item_id = k.item_id), '{}'),
         (array_agg(k.character_id order by k.ident desc, cardinality(k.rev) desc, k.updated_at, k.character_id))[1]
  from k group by k.item_id order by k.item_id;
$$;

-- the party level of every item given to one character (a joiner, a catch-up). Returns the number of items changed.
create function public._party_share_pull(p_character uuid, p_quiet boolean default false, p_item text default null)
returns int
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare camp uuid; r record; n int := 0; x int; prev_s text; prev_c text;
begin
  select campaign_id into camp from public.characters where id = p_character;
  if camp is null or not public._party_share_on(camp) then return 0; end if;
  prev_s := current_setting('tl.ik_source', true); prev_c := current_setting('tl.ik_source_char', true);
  perform set_config('tl.ik_source', 'party_share', true);
  for r in select * from public._party_levels(camp, p_character, p_item) loop
    perform set_config('tl.ik_source_char', r.src::text, true);
    x := public._party_guarded(p_character, r.item_id, case when r.ident then 'identified' else 'partially_identified' end,
                               r.rev, r.src, camp, p_quiet);
    if x > 0 then n := n + 1; end if;
  end loop;
  perform set_config('tl.ik_source', coalesce(prev_s, ''), true);
  perform set_config('tl.ik_source_char', coalesce(prev_c, ''), true);
  return n;
end $$;

-- apply a character's pending party shares. Dropped (never applied) when: the character left the campaign or is gone, the rule
-- is off, the character is held back for the item, or a DM wrote its knowledge of the item after the row was made. The stored
-- level was computed from what the source learned in this campaign (M1b) when the row was made. Idempotent; a busy row stays.
create function public._party_pending_apply(p_character uuid)
returns int
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare camp uuid; p record; n int := 0; x int; prev_s text; prev_c text;
begin
  if not exists (select 1 from public.party_share_pending where target_character_id = p_character) then return 0; end if;
  if current_setting('tl.ik_pending_run', true) = '1' then return 0; end if;   -- no recursion through _identify_apply
  perform set_config('tl.ik_pending_run', '1', true);
  prev_s := current_setting('tl.ik_source', true); prev_c := current_setting('tl.ik_source_char', true);
  select campaign_id into camp from public.characters where id = p_character;
  for p in select * from public.party_share_pending where target_character_id = p_character order by id loop
    if camp is null or camp is distinct from p.campaign_id or not public._party_share_on(camp)
       or coalesce((select ck.held_by_dm from public.character_item_knowledge ck where ck.character_id = p_character and ck.item_id = p.item_id), false)
       or exists (select 1 from public.item_knowledge_events e
                  where e.character_id = p_character and e.item_id = p.item_id and e.created_at > p.created_at and e.source is null
                    and e.actor in (select m.user_id from public.campaign_members m where m.campaign_id = camp and m.role = 'dm')) then
      delete from public.party_share_pending where id = p.id;
      continue;
    end if;
    perform set_config('tl.ik_source', 'party_share', true);
    perform set_config('tl.ik_source_char', coalesce(p.source_character_id::text, ''), true);
    x := public._party_guarded(p_character, p.item_id, p.state, p.revealed, p.source_character_id, camp, false, p.id);
    if x >= 0 then n := n + 1; end if;
  end loop;
  perform set_config('tl.ik_source', coalesce(prev_s, ''), true);
  perform set_config('tl.ik_source_char', coalesce(prev_c, ''), true);
  perform set_config('tl.ik_pending_run', '', true);
  return n;
end $$;

-- every character of a campaign: its pending rows, then the party level (raise only, idempotent). Rule switch-on, DM sync, migration.
create function public._party_share_sync(p_campaign uuid)
returns int
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare c uuid; n int := 0;
begin
  if not public._party_share_on(p_campaign) then return 0; end if;
  for c in select id from public.characters where campaign_id = p_campaign order by id loop
    n := n + public._party_pending_apply(c) + public._party_share_pull(c);
  end loop;
  return n;
end $$;

-- the body of 20261112000300 is now _identify_apply_one; this wrapper adds the canonical lock, the hold, pending rows, the party
CREATE OR REPLACE FUNCTION public._identify_apply(p_character uuid, p_item text, p_reveal text[])
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare st text; old_st text;
begin
  -- this transaction's own target: the canonical order of the existing RPCs (the character row before its counter row)
  perform 1 from public.characters where id = p_character for key share;
  select state into old_st from public.character_item_knowledge where character_id = p_character and item_id = p_item for update;
  st := public._identify_apply_one(p_character, p_item, p_reveal);
  -- the hold rule: a raise of this character (its own success, the DM's answer, crafting) lifts a DM hold on the item only on the
  -- TRANSITION into 'identified' (v31 r2: a record the DM "Set to Everything" is identified already; a later partial raise of it
  -- must not lift its hold); a partial result keeps the hold (and a held character is never a source below)
  if st = 'identified' and old_st is distinct from 'identified' then
    update public.character_item_knowledge set held_by_dm = false where character_id = p_character and item_id = p_item and held_by_dm;
  end if;
  perform public._party_pending_apply(p_character);
  perform public._party_share_from(p_character, p_item);
  return st;
end $function$;

-- ---- 4. joiners ---------------------------------------------------------------------------------------------------------------
-- joining: the party level (own rows only); never aborts the insert or the join (busy items stay pending, any error is only a
-- warning). Leaving or deletion: the character's pending rows of other campaigns are removed.
create function public._party_share_join()
returns trigger
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare n int;
begin
  if tg_op = 'DELETE' then
    delete from public.party_share_pending where target_character_id = old.id;
    return null;
  end if;
  if tg_op = 'UPDATE' and new.campaign_id is not distinct from old.campaign_id then return null; end if;
  delete from public.party_share_pending where target_character_id = new.id and campaign_id is distinct from new.campaign_id;
  if new.campaign_id is null then return null; end if;
  begin
    n := public._party_share_pull(new.id, true);
    if n > 0 then
      insert into public.campaign_audit_events (campaign_id, character_id, actor_id, event_type, summary, after, visibility)
      values (new.campaign_id, new.id, null, 'item_revealed',
              'Your party already knew ' || n || ' item' || case when n = 1 then '' else 's' end || ': you know ' || case when n = 1 then 'it' else 'them' end || ' too',
              jsonb_build_object('items', n, 'source', 'party_share'), 'party');
    end if;
  exception when others then
    raise warning 'party knowledge for a joining character was skipped (%): %', sqlstate, sqlerrm;
  end;
  return null;
end $$;
create trigger characters_party_knowledge after insert or update of campaign_id or delete on public.characters
  for each row execute function public._party_share_join();

-- ---- 5. replaced RPCs ---------------------------------------------------------------------------------------------------------
-- set_item_knowledge (old per-copy editor; body of 20261112000300 + the marked lines): the character row is taken first (the
-- canonical order); the DM write supersedes queued party shares of the pair; a write that only ADDED knowledge is shared with the
-- party; a write that took knowledge away holds the character back (party sharing skips it from now on); an addition lifts a hold
-- only when the record ends up identified (the hold rule)
CREATE OR REPLACE FUNCTION public.set_item_knowledge(p_inventory_item uuid, p_state text, p_revealed text[] DEFAULT NULL::text[], p_magic_known boolean DEFAULT NULL::boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare r public.inventory_items; it public.items; inv public.inventories; k public.inventory_item_knowledge; camp uuid; s public.item_secrets; old_state text;
  ck0 public.character_item_knowledge; ck1 public.character_item_knowledge;   -- 20261114000300
begin
  -- 20261114000300: the character row before the inventory row and its counter (the order of the existing RPCs)
  perform 1 from public.characters c join public.inventories i on i.character_id = c.id join public.inventory_items ii on ii.inventory_id = i.id
   where ii.id = p_inventory_item for key share of c;
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
    perform public._ik_drop_pending(inv.character_id, r.item_id);   -- 20261114000300
    select * into ck0 from public.character_item_knowledge where character_id = inv.character_id and item_id = r.item_id;   -- 20261114000300
    insert into public.character_item_knowledge (character_id, item_id, state, revealed, updated_by)
    values (inv.character_id, r.item_id, p_state, (select revealed from public.inventory_item_knowledge where inventory_item_id = r.id), auth.uid())
    on conflict (character_id, item_id) do update set state = excluded.state, revealed = excluded.revealed, updated_by = excluded.updated_by, updated_at = now();
    perform public._identify_sync_rows(inv.character_id, r.item_id);
    perform public._identify_touch(inv.character_id);
    -- 20261114000300: share an addition with the party (guarded per target); a removal holds the character back
    select * into ck1 from public.character_item_knowledge where character_id = inv.character_id and item_id = r.item_id;
    if public._ik_contains(ck1.state, ck1.revealed, ck0.state, ck0.revealed) then
      if (ck0.state, ck0.revealed) is distinct from (ck1.state, ck1.revealed) then
        -- the hold rule: only the transition into 'identified' lifts a hold; a held character is no source (_party_share_from
        -- returns 0). A non-held character also gets the party level of the item (its queued shares were dropped above: m1)
        if ck1.state = 'identified' and ck0.state is distinct from 'identified' then
          update public.character_item_knowledge set held_by_dm = false where character_id = inv.character_id and item_id = r.item_id and held_by_dm;
        end if;
        if not exists (select 1 from public.character_item_knowledge where character_id = inv.character_id and item_id = r.item_id and held_by_dm) then
          perform public._party_share_pull(inv.character_id, true, r.item_id);
        end if;
        perform public._party_share_from(inv.character_id, r.item_id);
      end if;
    else
      update public.character_item_knowledge set held_by_dm = true where character_id = inv.character_id and item_id = r.item_id and not held_by_dm;
      if found then   -- n8: the hold is derivable after a rollback -> reapply
        perform public._audit(camp, inv.character_id, 'item_revealed', 'Knowledge of ' || it.name || ': held back (per-copy editor)',
          null, jsonb_build_object('item_id', it.id, 'mode', 'set', 'state', ck1.state, 'revealed', to_jsonb(ck1.revealed)), null, null, 'dm');
      end if;
    end if;
  end if;
  if camp is not null then
    perform public._audit(camp, inv.character_id, 'item_revealed',
                          'Item knowledge: ' || replace(old_state, '_', ' ') || ' → ' || replace(p_state, '_', ' '),
                          null, jsonb_build_object('revealed', to_jsonb(coalesce(p_revealed, '{}'))), null, null, 'party');
  end if;
  return public.get_character_item_knowledge(inv.character_id);
end;
$function$;

-- dm_set_item_knowledge (body of 20261112000400, changed per character): every character in its own guarded subtransaction (B1).
-- A busy character is NOT changed and NOT queued: it is named in busy_names ("try again"). The call supersedes queued party
-- shares of every listed character. Mode 'set' holds the character back; mode 'raise' shares with the party ONCE at the end and
-- lifts a hold only for a character it raises to 'identified' (the hold rule).
CREATE OR REPLACE FUNCTION public.dm_set_item_knowledge(p_item text, p_characters uuid[], p_reveal text[], p_mode text DEFAULT 'set'::text, p_campaign uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare it public.items; camp uuid; is_full boolean; rev text[]; st text; cid uuid; ck public.character_item_knowledge;
  fp0 text; fp1 text; changed boolean; skip_plain boolean; d record; shown text; owner_uid uuid; out jsonb := '[]'; n int := 0;
  lt text := current_setting('lock_timeout'); busy text[] := '{}'; first_raised uuid; held0 boolean := true; sw text;
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
  perform set_config('tl.ik_shared', '0', true);

  foreach cid in array array(select distinct x from unnest(p_characters) x order by 1) loop
    -- the DM's decision supersedes queued party shares of this pair, also when the character is busy right now (no target lock)
    perform public._ik_drop_pending(cid, p_item);
    begin
      -- B1: the character's locks NOWAIT in the canonical order, 200 ms for anything implicit; busy -> not changed, listed
      perform set_config('lock_timeout', '200ms', true);
      perform public._ik_lock_target(cid, p_item);
      select * into ck from public.character_item_knowledge where character_id = cid and item_id = p_item;
      fp0 := public._ik_fingerprint(cid, p_item);
      -- raise: a character who holds an undisguised copy (and no disguised one) already sees everything; nothing is written
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
          -- the hold rule: only a raise INTO 'identified' (from a lower state) lifts a hold; a held character is no source, so the
          -- one share at the end comes from the first raised character that is not held
          if public._identify_apply_one(cid, p_item, case when is_full then '{all}'::text[] else rev end) = 'identified'
             and ck.state is distinct from 'identified' then
            update public.character_item_knowledge set held_by_dm = false where character_id = cid and item_id = p_item and held_by_dm;
          end if;
          if not exists (select 1 from public.character_item_knowledge where character_id = cid and item_id = p_item and held_by_dm) then
            first_raised := coalesce(first_raised, cid);
            -- m1: the queued party shares of this pair were dropped above; a non-held character gets the party level instead
            -- (not counted in shared_with: that counts the others)
            sw := current_setting('tl.ik_shared', true);
            perform public._party_share_pull(cid, true, p_item);
            perform set_config('tl.ik_shared', coalesce(sw, '0'), true);
          end if;
        end if;
      else
        held0 := coalesce(ck.held_by_dm, false);
        perform public._ik_apply_set(cid, p_item, st, rev);   -- the DM's exact choice; holds the character back from sharing
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
      elsif p_mode = 'set' and not held0 and coalesce(ck.held_by_dm, false) then
        -- n8: only the hold changed; the DM line (mode set) is what makes the hold derivable again after a rollback -> reapply
        perform public._audit(camp, cid, 'item_revealed', 'Knowledge of ' || it.name || ': held back (unchanged)',
          null, jsonb_build_object('item_id', it.id, 'mode', 'set', 'state', ck.state, 'revealed', to_jsonb(ck.revealed)), null, null, 'dm');
      end if;
      select owner_id into owner_uid from public.characters where id = cid;
      out := out || jsonb_build_array(jsonb_build_object('character_id', cid, 'changed', changed,
        'state', coalesce(ck.state, 'unidentified'), 'revealed', to_jsonb(coalesce(ck.revealed, '{}'::text[])),
        'held', coalesce(ck.held_by_dm, false), 'busy', false,
        'skipped', case when skip_plain then 'holds an undisguised copy' end,
        'warning', case when not skip_plain and it.owner_id is not distinct from owner_uid and coalesce(ck.state, 'unidentified') <> 'identified'
                        then 'The player created this item and can still look it up in the catalog' end));
      perform set_config('lock_timeout', lt, true);
    exception when lock_not_available or deadlock_detected then
      busy := busy || coalesce((select name from public.characters where id = cid), '?');
      out := out || jsonb_build_array(jsonb_build_object('character_id', cid, 'changed', false, 'busy', true,
        'state', null, 'revealed', '[]'::jsonb, 'held', null, 'skipped', null, 'warning', null));
    end;
  end loop;
  -- one share for the whole call (n4): from a character this call raised; characters already raised here are unchanged by it
  if first_raised is not null then perform public._party_share_from(first_raised, p_item); end if;
  return jsonb_build_object('item_id', p_item, 'mode', p_mode, 'changed', n, 'results', out,
    'party_share', public._party_share_on(camp), 'shared_with', coalesce(nullif(current_setting('tl.ik_shared', true), ''), '0')::int,
    'busy', cardinality(busy), 'busy_names', to_jsonb(busy));
end $function$;

-- dm_reveal_item (body of 20261112000300, changed per character): each character in a guarded subtransaction (B1; this loop
-- deadlocked with players' RPCs at 0a05e81). A busy character is NOT changed and is named in busy_names; one party share at the
-- end (n4: O(N) guarded writes for N characters instead of N x N). A partial reveal never lifts a hold (the hold rule).
CREATE OR REPLACE FUNCTION public.dm_reveal_item(p_item text, p_characters uuid[] DEFAULT NULL::uuid[], p_reveal text[] DEFAULT NULL::text[], p_campaign uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare it public.items; camp uuid; targets uuid[]; cid uuid; st text; n int := 0; busy text[] := '{}'; lt text := current_setting('lock_timeout');
  first_raised uuid; old_st text;
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
  foreach cid in array array(select distinct x from unnest(targets) x order by 1) loop   -- n9: a stable lock order
    perform public._ik_drop_pending(cid, p_item);
    begin
      perform set_config('lock_timeout', '200ms', true);
      perform public._ik_lock_target(cid, p_item);
      select state into old_st from public.character_item_knowledge where character_id = cid and item_id = p_item;
      st := public._identify_apply_one(cid, p_item, coalesce(p_reveal, '{all}'));
      -- the hold rule: only the transition into 'identified' lifts a hold (v31 r2: a "Set to Everything" record is identified
      -- already; a later partial or full reveal of it keeps the hold); the share at the end comes from a character that is not held
      if st = 'identified' and old_st is distinct from 'identified' then
        update public.character_item_knowledge set held_by_dm = false where character_id = cid and item_id = p_item and held_by_dm;
      end if;
      if not exists (select 1 from public.character_item_knowledge where character_id = cid and item_id = p_item and held_by_dm) then
        first_raised := coalesce(first_raised, cid);
        perform public._party_share_pull(cid, true, p_item);   -- m1: its queued shares were dropped above; the party level instead
      end if;
      perform set_config('lock_timeout', lt, true);
    exception when lock_not_available or deadlock_detected then
      busy := busy || coalesce((select name from public.characters where id = cid), '?');
      continue;
    end;
    n := n + 1;
    perform public._audit(camp, cid, 'item_revealed', 'The DM revealed ' || case when st = 'identified' then 'an item: ' || it.name else 'part of an item' end,
                          null, jsonb_build_object('revealed', to_jsonb(coalesce(p_reveal, '{all}'))), null, null, 'party');
  end loop;
  if first_raised is not null then perform public._party_share_from(first_raised, p_item); end if;
  return jsonb_build_object('item_id', p_item, 'characters', n, 'busy', cardinality(busy), 'busy_names', to_jsonb(busy));
end;
$function$;

-- get_item_knowledge_overview (body of 20261112000400 + the marked keys): the rule, holds, pending shares, party origin
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
    'party_share', public._party_share_on(p_campaign),   -- 20261114000300
    'item', jsonb_build_object('id', it.id, 'name', it.name, 'kind_id', it.kind_id, 'official', it.owner_id is null, 'secret', it.secret,
      'decoy_name', d.name, 'decoy_description', d.description, 'can_hide', it.owner_id is not null,
      'properties', coalesce((select s.properties from public.item_secrets s where s.item_id = it.id), '[]')),
    'characters', (select coalesce(jsonb_agg(x.j order by x.nm, x.cid), '[]') from (
      select c.name as nm, c.id as cid, jsonb_build_object('character_id', c.id, 'name', c.name,
        'is_creator', it.owner_id is not distinct from c.owner_id,
        'record', (select jsonb_build_object('state', ck.state, 'revealed', to_jsonb(ck.revealed), 'updated_at', ck.updated_at,
                     'updated_by', (select coalesce(p.display_name, 'someone') from public.profiles p where p.id = ck.updated_by))
                   from public.character_item_knowledge ck where ck.character_id = c.id and ck.item_id = it.id),
        'held', coalesce(ck2.held_by_dm, false),   -- 20261114000300
        'pending', (select count(*)::int from public.party_share_pending ps where ps.target_character_id = c.id and ps.item_id = it.id),
        'party_source', (select jsonb_build_object('at', e.created_at,
                           'from', (select sc.name from public.characters sc where sc.id = e.source_character_id))
                         from public.item_knowledge_events e where e.character_id = c.id and e.item_id = it.id and e.source = 'party_share'
                         order by e.created_at desc, e.id desc limit 1),
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
        'actor', (select coalesce(p.display_name, 'someone') from public.profiles p where p.id = e.actor),
        'source', e.source,   -- 20261114000300
        'source_character_name', (select c.name from public.characters c where c.id = e.source_character_id)) as j
      from public.item_knowledge_events e where e.item_id = it.id and e.campaign_id = p_campaign
      order by e.created_at desc, e.id desc limit 50) h));
end $function$;

-- ---- 6. new RPCs ------------------------------------------------------------------------------------------------------------
create function public.get_campaign_identification_sharing(p_campaign uuid)
returns jsonb
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
begin
  if auth.uid() is null or p_campaign is null or not (public.is_admin() or public.is_campaign_dm(p_campaign)) then
    raise exception 'Only a DM of the campaign can see its rules' using errcode = '42501';
  end if;
  return jsonb_build_object('campaign_id', p_campaign, 'share_identification', public._party_share_on(p_campaign),
    'held', (select count(*)::int from public.character_item_knowledge ck join public.characters c on c.id = ck.character_id
             where c.campaign_id = p_campaign and ck.held_by_dm),
    'pending', (select count(*)::int from public.party_share_pending p where p.campaign_id = p_campaign));
end $$;

-- switch the rule. On: the campaign catches up once (raise only, guarded per character). Off: nothing is lowered.
create function public.set_campaign_identification_sharing(p_campaign uuid, p_on boolean)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare was boolean; n int := 0;
begin
  if auth.uid() is null or p_campaign is null or not (public.is_admin() or public.is_campaign_dm(p_campaign)) then
    raise exception 'Only the DM of the campaign can change its rules' using errcode = '42501';
  end if;
  if p_on is null then raise exception 'Choose on or off' using errcode = '22023'; end if;
  -- one switch at a time per campaign (NO KEY UPDATE: foreign-key key-share locks of other transactions are not blocked)
  perform 1 from public.campaigns where id = p_campaign for no key update;
  was := public._party_share_on(p_campaign);
  insert into public.campaign_item_rules (campaign_id, share_identification, updated_by) values (p_campaign, p_on, auth.uid())
  on conflict (campaign_id) do update set share_identification = excluded.share_identification, updated_by = excluded.updated_by, updated_at = now()
  where campaign_item_rules.share_identification is distinct from excluded.share_identification;
  if p_on and not was then n := public._party_share_sync(p_campaign); end if;
  if was is distinct from p_on then
    perform public._audit(p_campaign, null, 'campaign_rules',
      case when p_on then 'Identification is now shared with the party' else 'Identification is no longer shared with the party' end,
      jsonb_build_object('share_identification', was), jsonb_build_object('share_identification', p_on, 'caught_up', n), null, null, 'dm');
  end if;
  return public.get_campaign_identification_sharing(p_campaign) || jsonb_build_object('caught_up', n);
end $$;

-- let party sharing reach characters the DM held back: the party level of the item now, then their knowledge joins it. A busy
-- character is not changed (busy_names, "try again").
create function public.dm_release_item_knowledge_hold(p_item text, p_characters uuid[], p_campaign uuid default null)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare it public.items; camp uuid; cid uuid; n int := 0; lt text := current_setting('lock_timeout'); busy text[] := '{}';
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
  if p_characters is null or cardinality(p_characters) = 0 or cardinality(p_characters) > 100 then
    raise exception 'Choose at least one character' using errcode = '22023';
  end if;
  if exists (select 1 from unnest(p_characters) t left join public.characters c on c.id = t where t is null or c.campaign_id is distinct from camp) then
    raise exception 'Every character must be in the campaign' using errcode = '22023';
  end if;
  perform set_config('tl.ik_shared', '0', true);
  foreach cid in array array(select distinct x from unnest(p_characters) x order by 1) loop
    perform public._ik_drop_pending(cid, p_item);
    begin
      perform set_config('lock_timeout', '200ms', true);
      perform public._ik_lock_target(cid, p_item);
      update public.character_item_knowledge set held_by_dm = false where character_id = cid and item_id = p_item and held_by_dm;
      if found then
        n := n + 1;
        perform public._audit(camp, cid, 'item_revealed', 'Party sharing of ' || it.name || ' reaches this character again', null,
          jsonb_build_object('item_id', it.id, 'mode', 'release'), null, null, 'dm');
      end if;
      perform set_config('lock_timeout', lt, true);
    exception when lock_not_available or deadlock_detected then
      busy := busy || coalesce((select name from public.characters where id = cid), '?');
      continue;
    end;
    -- outside the subtransaction: the party level of THIS item, then what they learned here goes to the others (both guarded)
    perform public._party_share_pull(cid, false, p_item);
    perform public._party_share_from(cid, p_item);
  end loop;
  return jsonb_build_object('item_id', p_item, 'released', n, 'busy', cardinality(busy), 'busy_names', to_jsonb(busy),
    'shared_with', coalesce(nullif(current_setting('tl.ik_shared', true), ''), '0')::int);
end $$;

-- the sheet calls this on open and after an inventory refresh: apply the character's pending party shares (its owner, its DM,
-- an admin). One indexed lookup when nothing is pending. Returns counts only.
create function public.sync_party_knowledge(p_character uuid)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare n int := 0;
begin
  if auth.uid() is null or p_character is null or not public.can_access_character(p_character) then
    raise exception 'Character not found' using errcode = '42501';
  end if;
  if exists (select 1 from public.party_share_pending where target_character_id = p_character) then
    n := public._party_pending_apply(p_character);
  end if;
  return jsonb_build_object('applied', n,
    'pending', (select count(*)::int from public.party_share_pending where target_character_id = p_character));
end $$;

-- DM: "Sync party knowledge": drop pending rows of characters that left, then every character's pending rows and the party level
create function public.dm_sync_party_knowledge(p_campaign uuid)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare n int; dropped int;
begin
  if auth.uid() is null or p_campaign is null or not (public.is_admin() or public.is_campaign_dm(p_campaign)) then
    raise exception 'Only the DM of the campaign can sync party knowledge' using errcode = '42501';
  end if;
  delete from public.party_share_pending p where p.campaign_id = p_campaign
    and not exists (select 1 from public.characters c where c.id = p.target_character_id and c.campaign_id = p_campaign);
  get diagnostics dropped = row_count;
  n := public._party_share_sync(p_campaign);
  return jsonb_build_object('applied', n, 'dropped', dropped,
    'pending', (select count(*)::int from public.party_share_pending where campaign_id = p_campaign));
end $$;

-- ---- 7. data: holds from the DM's past choices (the hold rule), then every campaign catches up (guarded, raise only) -----------
-- The hold rule replayed over the history: a HOLD POINT is a DM audit line with mode 'set' (dm_set_item_knowledge 'set', the
-- per-copy editor's hold line) or ANY knowledge event that took knowledge away; a LIFT is a DM audit line with mode 'release' or
-- a knowledge event that moved the record INTO 'identified' (old state not identified), strictly AFTER the hold point (a "Set Everything" writes its line and its event in
-- one transaction, same now(): it stays held, as _ik_apply_set does). Held = the latest hold point has no lift after it. Not
-- campaign-scoped: the hold follows the character and the item (m4). scripts/fluent/party_share_preview.sql has the same CTE.
create function public._ik_derived_holds()
returns table (character_id uuid, item_id text)
language sql stable security definer
set search_path = public, pg_temp
as $$
  with hold_pt as (
    select e.character_id, e.after ->> 'item_id' as item_id, e.created_at
    from public.campaign_audit_events e
    where e.event_type = 'item_revealed' and e.visibility = 'dm' and e.character_id is not null and e.after ->> 'mode' = 'set'
      and e.after ? 'item_id'
    union all
    select ev.character_id, ev.item_id, ev.created_at
    from public.item_knowledge_events ev
    where ev.old_state is not null and not public._ik_contains(ev.new_state, ev.new_revealed, ev.old_state, ev.old_revealed)),
  last_hold as (select h.character_id, h.item_id, max(h.created_at) as at from hold_pt h group by 1, 2)
  select l.character_id, l.item_id from last_hold l
  where not exists (select 1 from public.campaign_audit_events e
                    where e.event_type = 'item_revealed' and e.visibility = 'dm' and e.character_id = l.character_id
                      and e.after ->> 'item_id' = l.item_id and e.after ->> 'mode' = 'release' and e.created_at > l.at)
    and not exists (select 1 from public.item_knowledge_events ev
                    where ev.character_id = l.character_id and ev.item_id = l.item_id and ev.new_state = 'identified'
                      and ev.old_state is distinct from 'identified' and ev.created_at > l.at);
$$;

update public.character_item_knowledge ck set held_by_dm = true
from public._ik_derived_holds() h
where ck.character_id = h.character_id and ck.item_id = h.item_id and not ck.held_by_dm;

do $$
declare c uuid; n int := 0; h int;
begin
  select count(*) into h from public.character_item_knowledge where held_by_dm;
  for c in select id from public.campaigns order by id loop
    n := n + public._party_share_sync(c);
  end loop;
  raise notice 'party item knowledge: % held record(s); % record(s) raised to the party level; % pending', h, n,
    (select count(*) from public.party_share_pending);
end $$;

-- ---- 8. grants ---------------------------------------------------------------------------------------------------------------
revoke all on function public._party_share_on(uuid), public._ik_campaign_level(uuid, text, uuid), public._ik_drop_pending(uuid, text),
  public._ik_contains(text, text[], text, text[]), public._ik_lock_target(uuid, text), public._identify_apply_one(uuid, text, text[]),
  public._ik_apply_set(uuid, text, text, text[]), public._party_apply_to(uuid, text, text, text[], boolean),
  public._party_guarded(uuid, text, text, text[], uuid, uuid, boolean, bigint), public._party_share_from(uuid, text),
  public._party_levels(uuid, uuid, text), public._party_share_pull(uuid, boolean, text), public._party_pending_apply(uuid),
  public._party_share_sync(uuid), public._party_share_join(), public._ik_derived_holds() from public, anon, authenticated;
revoke all on function public.get_campaign_identification_sharing(uuid), public.set_campaign_identification_sharing(uuid, boolean),
  public.dm_release_item_knowledge_hold(text, uuid[], uuid), public.sync_party_knowledge(uuid), public.dm_sync_party_knowledge(uuid) from public, anon;
grant execute on function public.get_campaign_identification_sharing(uuid), public.set_campaign_identification_sharing(uuid, boolean),
  public.dm_release_item_knowledge_hold(text, uuid[], uuid), public.sync_party_knowledge(uuid), public.dm_sync_party_knowledge(uuid)
  to authenticated, service_role;

reset lock_timeout;
notify pgrst, 'reload schema';
