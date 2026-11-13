-- =============================================================================
-- Party-wide identification (R-A; docs/HIDDEN_DM_DATA.md "Identification is shared with the party"). Owner decision: once one
-- character of a campaign identifies an item, every character of the campaign knows it, including characters who join later.
--
-- Model: COPY ON WRITE. character_item_knowledge stays the per-character record and the character's disguised inventory rows keep
-- following it (T4 _identify_sync_rows), so no read path changes: v_inventory_detail, _item_visible, _character_read, RLS and
-- Realtime are untouched (no slower inventory read, nothing computed per request).
-- * Campaign rule campaign_item_rules.share_identification (a missing row = ON, so existing and new campaigns share by default).
--   Off: exactly the per-character model of 20261112000300 / 20261112000400. Switching it on catches the campaign up once
--   (_party_share_sync); switching it off is never retroactive (nothing is lowered).
-- * Every RAISE of a character's knowledge goes through _identify_apply (examine success, the DM's answer, dm_reveal_item,
--   dm_set_item_knowledge mode raise, crafting's _craft_produce). Its old body is now _identify_apply_one; _identify_apply calls it,
--   lifts a DM hold of that character on that item, then pushes the character's record to the other characters of the campaign
--   (_party_share_from -> _party_apply_to -> _identify_apply_one: never recursive). set_item_knowledge (the old per-copy editor)
--   pushes when its write only added knowledge and holds the character when it took knowledge away.
-- * Explicit DM choices win: dm_set_item_knowledge mode 'set' (and a lowering set_item_knowledge) marks that character "held back
--   by the DM" for that item (character_item_knowledge.held_by_dm). Sharing never reaches a held character, and a held record is
--   never a source of the party level for joiners / catch-ups. dm_release_item_knowledge_hold lets sharing reach them again.
-- * A FAILED or pending examine writes nothing to anyone else. A target that holds only an undisguised copy is skipped (it sees
--   everything already; same rule as dm_set_item_knowledge raise). Party stash / shop rows keep their own knowledge (parked Q1).
-- * Joiners: an AFTER INSERT / UPDATE OF campaign_id trigger on characters copies the party level (union of the non-held records of
--   the other characters) of items of no campaign or of that campaign.
-- * History: item_knowledge_events gains source ('party_share') and source_character_id (who it came from), set through
--   transaction-local settings read by _item_knowledge_log. The target player's audit line names the item only as far as they now
--   know it, never who identified it, and has no actor.
-- * Data: holds are derived from the DM's past "set" calls (latest DM audit with mode set and no later record change, or a latest
--   history event that lowered knowledge); then every campaign is caught up (raise only, idempotent, never lowers or deletes).
-- Cache: campaign_item_rules feeds no cached read -> tl_cache.skip(). The record and row writes bump exactly as an ordinary reveal
-- of each target does (tl_cache.bump('character'), bump_item_knowledge, one character_revisions row per changed character).
-- Locks: a share locks the target's rows (id order) and record. Two characters examining the SAME item successfully at the SAME
-- moment can deadlock; Postgres then aborts one transaction cleanly (40P01, nothing half-written; the player retries).
-- Rollback: supabase/rollback/rollback_party_item_knowledge.sql.
-- =============================================================================
set lock_timeout = '5s';

-- ---- 1. the campaign rule ---------------------------------------------------------------------------------------------------
create table public.campaign_item_rules (
  campaign_id          uuid primary key references public.campaigns (id) on delete cascade,
  share_identification boolean not null default true,
  updated_by           uuid references public.profiles (id) on delete set null,
  updated_at           timestamptz not null default now()
);
alter table public.campaign_item_rules enable row level security;
revoke all on public.campaign_item_rules from anon, authenticated;
-- read by no cached read (only by the share functions and the DM's rule read): no cache invalidation, no player signal
create trigger tl_cache_rev after insert or update or delete on public.campaign_item_rules
  for each row execute function tl_cache.skip();

create function public._party_share_on(p_campaign uuid)
returns boolean
language sql stable security definer
set search_path = public, pg_temp
as $$
  select p_campaign is not null
     and coalesce((select r.share_identification from public.campaign_item_rules r where r.campaign_id = p_campaign), true);
$$;

-- ---- 2. hold marker and history source --------------------------------------------------------------------------------------
alter table public.character_item_knowledge add column held_by_dm boolean not null default false;
alter table public.item_knowledge_events
  add column source text check (source is null or source ~ '^[a-z_]{1,40}$'),
  add column source_character_id uuid references public.characters (id) on delete set null;

-- body of 20261112000400 + source / source_character_id from the transaction-local settings tl.ik_source / tl.ik_source_char
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
          new.state, new.revealed, auth.uid(), src,
          case when sch is not null and exists (select 1 from public.characters c where c.id = sch::uuid) then sch::uuid end);
  return null;
end $function$;

-- does (state, revealed) contain at least what (old_state, old_revealed) did?
create function public._ik_contains(p_state text, p_revealed text[], p_old_state text, p_old_revealed text[])
returns boolean
language sql immutable
set search_path = public, pg_temp
as $$
  select p_old_state is null or p_state = 'identified'
      or (coalesce(p_old_state, 'unidentified') <> 'identified' and coalesce(p_old_revealed, '{}') <@ coalesce(p_revealed, '{}'));
$$;

-- ---- 3. apply: one character (the old body), then the party ---------------------------------------------------------------
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

-- give ONE other character at least (p_state, p_revealed) of an item, as party knowledge. Skips a character held back by the DM
-- and one that holds only undisguised copies. Locks the target's rows (id order), then its record. Returns 1 when it changed.
create function public._party_apply_to(p_target uuid, p_item text, p_state text, p_revealed text[])
returns int
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare ck public.character_item_knowledge; rev text[]; st text; it public.items; d record; camp uuid; shown text;
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
  rev := array(select distinct x from unnest(coalesce(ck.revealed, '{}') || coalesce(p_revealed, '{}')) x
               where x is not null and btrim(x) <> '' and x <> 'all' order by 1);
  st := case when p_state = 'identified' or ck.state = 'identified' then 'identified'
             when cardinality(rev) > 0 then 'partially_identified' else coalesce(ck.state, 'unidentified') end;
  if st = 'unidentified' and cardinality(rev) = 0 then return 0; end if;          -- nothing to share
  if ck.character_id is not null and (ck.state, ck.revealed) is not distinct from (st, rev) then return 0; end if;
  perform 1 from public.inventory_items ii join public.inventories inv on inv.id = ii.inventory_id
   where inv.character_id = p_target and ii.item_id = p_item order by ii.id for update of ii;
  perform 1 from public.character_item_knowledge where character_id = p_target and item_id = p_item for update;
  perform public._identify_apply_one(p_target, p_item, case when st = 'identified' then rev || '{all}'::text[] else rev end);
  -- the target player's own line (non-DM audit events reach only the character's owner): no actor, never who identified it, the
  -- true name only when the target now knows the name
  select * into it from public.items where id = p_item;
  select * into d from public._item_decoy(p_item);
  select campaign_id into camp from public.characters where id = p_target;
  shown := case when st = 'identified' or 'name' = any (rev) then it.name else d.name end;
  insert into public.campaign_audit_events (campaign_id, character_id, actor_id, event_type, summary, after, visibility)
  values (camp, p_target, null, 'item_revealed', left('Your party learned something about an item: ' || shown, 300),
          jsonb_build_object('revealed', to_jsonb(case when st = 'identified' then '{all}'::text[] else rev end), 'source', 'party_share'), 'party');
  perform set_config('tl.ik_shared', (coalesce(nullif(current_setting('tl.ik_shared', true), ''), '0')::int + 1)::text, true);
  return 1;
end $$;

-- push what p_source now knows about an item to the other characters of its campaign (rule on). Returns the number changed.
create function public._party_share_from(p_source uuid, p_item text)
returns int
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare camp uuid; src public.character_item_knowledge; it public.items; t uuid; n int := 0; prev_s text; prev_c text;
begin
  select campaign_id into camp from public.characters where id = p_source;
  if camp is null or not public._party_share_on(camp) then return 0; end if;
  select * into src from public.character_item_knowledge where character_id = p_source and item_id = p_item;
  if src.character_id is null or (src.state = 'unidentified' and cardinality(src.revealed) = 0) then return 0; end if;
  select * into it from public.items where id = p_item;
  if it.id is null or (it.campaign_id is not null and it.campaign_id <> camp) then return 0; end if;
  prev_s := current_setting('tl.ik_source', true); prev_c := current_setting('tl.ik_source_char', true);
  perform set_config('tl.ik_source', 'party_share', true);
  perform set_config('tl.ik_source_char', p_source::text, true);
  for t in select c.id from public.characters c where c.campaign_id = camp and c.id <> p_source order by c.id loop
    n := n + public._party_apply_to(t, p_item, src.state, src.revealed);
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

-- the party level of every item (union of the NON-HELD records of the other characters of the campaign) given to one character:
-- a joiner, a released hold, a catch-up. Items of another campaign never travel. Returns the number of items changed.
create function public._party_share_pull(p_character uuid)
returns int
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare camp uuid; r record; n int := 0; prev_s text; prev_c text;
begin
  select campaign_id into camp from public.characters where id = p_character;
  if camp is null or not public._party_share_on(camp) then return 0; end if;
  prev_s := current_setting('tl.ik_source', true); prev_c := current_setting('tl.ik_source_char', true);
  perform set_config('tl.ik_source', 'party_share', true);
  for r in
    with k as (
      select ck.* from public.character_item_knowledge ck
      join public.characters c on c.id = ck.character_id
      join public.items it on it.id = ck.item_id
      where c.campaign_id = camp and c.id <> p_character and not ck.held_by_dm
        and (it.campaign_id is null or it.campaign_id = camp)
        and (ck.state <> 'unidentified' or cardinality(ck.revealed) > 0))
    select k.item_id, bool_or(k.state = 'identified') as ident,
           coalesce((select array_agg(distinct x order by x) from k k2 cross join unnest(k2.revealed) x where k2.item_id = k.item_id), '{}') as rev,
           (array_agg(k.character_id order by public._ik_rank(k.state, k.revealed) desc, k.updated_at, k.character_id))[1] as src
    from k group by k.item_id order by k.item_id
  loop
    perform set_config('tl.ik_source_char', r.src::text, true);
    n := n + public._party_apply_to(p_character, r.item_id, case when r.ident then 'identified' else 'partially_identified' end, r.rev);
  end loop;
  perform set_config('tl.ik_source', coalesce(prev_s, ''), true);
  perform set_config('tl.ik_source_char', coalesce(prev_c, ''), true);
  return n;
end $$;

-- every character of a campaign raised to the party level (idempotent; raise only). The migration and "rule switched on".
create function public._party_share_sync(p_campaign uuid)
returns int
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare c uuid; n int := 0;
begin
  if not public._party_share_on(p_campaign) then return 0; end if;
  for c in select id from public.characters where campaign_id = p_campaign order by id loop
    n := n + public._party_share_pull(c);
  end loop;
  return n;
end $$;

-- the body of 20261112000300 is now _identify_apply_one; this wrapper adds the party
CREATE OR REPLACE FUNCTION public._identify_apply(p_character uuid, p_item text, p_reveal text[])
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare st text;
begin
  st := public._identify_apply_one(p_character, p_item, p_reveal);
  -- an explicit raise of this character (its own success, the DM's answer or reveal, crafting) lifts a DM hold on the item
  update public.character_item_knowledge set held_by_dm = false where character_id = p_character and item_id = p_item and held_by_dm;
  perform public._party_share_from(p_character, p_item);
  return st;
end $function$;

-- ---- 4. joiners ---------------------------------------------------------------------------------------------------------------
create function public._party_share_join()
returns trigger
language plpgsql security definer
set search_path = public, pg_temp
as $$
begin
  if new.campaign_id is null or (tg_op = 'UPDATE' and new.campaign_id is not distinct from old.campaign_id) then return null; end if;
  perform public._party_share_pull(new.id);
  return null;
end $$;
create trigger characters_party_knowledge after insert or update of campaign_id on public.characters
  for each row execute function public._party_share_join();

-- ---- 5. replaced RPCs ---------------------------------------------------------------------------------------------------------
-- set_item_knowledge (old per-copy editor; body of 20261112000300 + the marked lines): a write that only ADDED knowledge is shared
-- with the party; a write that took knowledge away holds the character back (party sharing skips it from now on)
CREATE OR REPLACE FUNCTION public.set_item_knowledge(p_inventory_item uuid, p_state text, p_revealed text[] DEFAULT NULL::text[], p_magic_known boolean DEFAULT NULL::boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare r public.inventory_items; it public.items; inv public.inventories; k public.inventory_item_knowledge; camp uuid; s public.item_secrets; old_state text;
  ck0 public.character_item_knowledge; ck1 public.character_item_knowledge;   -- 20261114000100
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
    select * into ck0 from public.character_item_knowledge where character_id = inv.character_id and item_id = r.item_id;   -- 20261114000100
    insert into public.character_item_knowledge (character_id, item_id, state, revealed, updated_by)
    values (inv.character_id, r.item_id, p_state, (select revealed from public.inventory_item_knowledge where inventory_item_id = r.id), auth.uid())
    on conflict (character_id, item_id) do update set state = excluded.state, revealed = excluded.revealed, updated_by = excluded.updated_by, updated_at = now();
    perform public._identify_sync_rows(inv.character_id, r.item_id);
    perform public._identify_touch(inv.character_id);
    -- 20261114000100: share an addition with the party; a removal holds the character back
    select * into ck1 from public.character_item_knowledge where character_id = inv.character_id and item_id = r.item_id;
    if public._ik_contains(ck1.state, ck1.revealed, ck0.state, ck0.revealed) then
      if (ck0.state, ck0.revealed) is distinct from (ck1.state, ck1.revealed) then
        update public.character_item_knowledge set held_by_dm = false where character_id = inv.character_id and item_id = r.item_id and held_by_dm;
        perform public._party_share_from(inv.character_id, r.item_id);
      end if;
    else
      update public.character_item_knowledge set held_by_dm = true where character_id = inv.character_id and item_id = r.item_id and not held_by_dm;
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

-- dm_set_item_knowledge (body of 20261112000400 + the marked lines): mode 'set' holds the characters back from party sharing;
-- mode 'raise' shares with the party (through _identify_apply); the result says how many other characters it reached
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
  perform set_config('tl.ik_shared', '0', true);   -- 20261114000100: counted by _party_apply_to

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
      -- 20261114000100: the DM's exact choice for this character; party sharing skips it until released or raised
      update public.character_item_knowledge set held_by_dm = true where character_id = cid and item_id = p_item and not held_by_dm;
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
      'held', coalesce(ck.held_by_dm, false),   -- 20261114000100
      'skipped', case when skip_plain then 'holds an undisguised copy' end,
      'warning', case when not skip_plain and it.owner_id is not distinct from owner_uid and coalesce(ck.state, 'unidentified') <> 'identified'
                      then 'The player created this item and can still look it up in the catalog' end));
  end loop;
  return jsonb_build_object('item_id', p_item, 'mode', p_mode, 'changed', n, 'results', out,
    'party_share', public._party_share_on(camp), 'shared_with', coalesce(nullif(current_setting('tl.ik_shared', true), ''), '0')::int);   -- 20261114000100
end $function$;

-- get_item_knowledge_overview (body of 20261112000400 + the marked keys): the rule, holds, where party knowledge came from
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
    'party_share', public._party_share_on(p_campaign),   -- 20261114000100
    'item', jsonb_build_object('id', it.id, 'name', it.name, 'kind_id', it.kind_id, 'official', it.owner_id is null, 'secret', it.secret,
      'decoy_name', d.name, 'decoy_description', d.description, 'can_hide', it.owner_id is not null,
      'properties', coalesce((select s.properties from public.item_secrets s where s.item_id = it.id), '[]')),
    'characters', (select coalesce(jsonb_agg(x.j order by x.nm, x.cid), '[]') from (
      select c.name as nm, c.id as cid, jsonb_build_object('character_id', c.id, 'name', c.name,
        'is_creator', it.owner_id is not distinct from c.owner_id,
        'record', (select jsonb_build_object('state', ck.state, 'revealed', to_jsonb(ck.revealed), 'updated_at', ck.updated_at,
                     'updated_by', (select coalesce(p.display_name, 'someone') from public.profiles p where p.id = ck.updated_by))
                   from public.character_item_knowledge ck where ck.character_id = c.id and ck.item_id = it.id),
        'held', coalesce(ck2.held_by_dm, false),   -- 20261114000100
        'party_source', (select jsonb_build_object('at', e.created_at,   -- 20261114000100: the last knowledge that came from the party
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
        'source', e.source,   -- 20261114000100
        'source_character_name', (select c.name from public.characters c where c.id = e.source_character_id)) as j
      from public.item_knowledge_events e where e.item_id = it.id and e.campaign_id = p_campaign
      order by e.created_at desc, e.id desc limit 50) h));
end $function$;

-- ---- 6. new DM RPCs -----------------------------------------------------------------------------------------------------------
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
             where c.campaign_id = p_campaign and ck.held_by_dm));
end $$;

-- switch the rule. On: the campaign catches up once (raise only). Off: nothing is lowered, later discoveries stay per character.
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
  perform 1 from public.campaigns where id = p_campaign for update;   -- one switch at a time per campaign
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

-- let party sharing reach characters the DM held back: they get the party level now and their own knowledge joins it
create function public.dm_release_item_knowledge_hold(p_item text, p_characters uuid[], p_campaign uuid default null)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare it public.items; camp uuid; cid uuid; n int := 0; r record; prev_s text;
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
    update public.character_item_knowledge set held_by_dm = false where character_id = cid and item_id = p_item and held_by_dm;
    if not found then continue; end if;
    n := n + 1;
    if public._party_share_on(camp) then
      -- the party level of THIS item, then what they know goes to the others
      prev_s := current_setting('tl.ik_source', true);
      perform set_config('tl.ik_source', 'party_share', true);
      for r in
        select bool_or(ck.state = 'identified') as ident,
               coalesce(array_agg(distinct x order by x) filter (where x is not null), '{}') as rev,
               (array_agg(ck.character_id order by public._ik_rank(ck.state, ck.revealed) desc, ck.updated_at, ck.character_id))[1] as src
        from public.character_item_knowledge ck join public.characters c on c.id = ck.character_id
        left join lateral unnest(ck.revealed) x on true
        where c.campaign_id = camp and c.id <> cid and ck.item_id = p_item and not ck.held_by_dm
          and (ck.state <> 'unidentified' or cardinality(ck.revealed) > 0)
        having count(*) > 0
      loop
        perform set_config('tl.ik_source_char', r.src::text, true);
        perform public._party_apply_to(cid, p_item, case when r.ident then 'identified' else 'partially_identified' end, r.rev);
      end loop;
      perform set_config('tl.ik_source', coalesce(prev_s, ''), true);
      perform set_config('tl.ik_source_char', '', true);
      perform public._party_share_from(cid, p_item);
    end if;
    perform public._audit(camp, cid, 'item_revealed', 'Party sharing of ' || it.name || ' reaches this character again', null,
      jsonb_build_object('item_id', it.id, 'mode', 'release'), null, null, 'dm');
  end loop;
  return jsonb_build_object('item_id', p_item, 'released', n,
    'shared_with', coalesce(nullif(current_setting('tl.ik_shared', true), ''), '0')::int);
end $$;

-- ---- 7. data: holds from the DM's past exact choices, then every campaign catches up -----------------------------------------
-- a DM "set" (Set / Hide) of a character's knowledge that nothing changed afterwards is an explicit choice: keep it
with last_dm as (
  select distinct on (e.character_id, e.after ->> 'item_id') e.character_id, e.after ->> 'item_id' as item_id, e.after ->> 'mode' as mode, e.created_at
  from public.campaign_audit_events e
  where e.event_type = 'item_revealed' and e.visibility = 'dm' and e.character_id is not null and e.after ? 'mode' and e.after ? 'item_id'
  order by e.character_id, e.after ->> 'item_id', e.created_at desc, e.id desc)
update public.character_item_knowledge ck set held_by_dm = true
from last_dm l
where l.mode = 'set' and ck.character_id = l.character_id and ck.item_id = l.item_id and not ck.held_by_dm
  and not exists (select 1 from public.item_knowledge_events ev where ev.character_id = ck.character_id and ev.item_id = ck.item_id
                  and ev.created_at > l.created_at);
-- a record whose LAST history event took knowledge away (the old per-copy editor) is held too
with last_ev as (
  select distinct on (ev.character_id, ev.item_id) ev.*
  from public.item_knowledge_events ev order by ev.character_id, ev.item_id, ev.created_at desc, ev.id desc)
update public.character_item_knowledge ck set held_by_dm = true
from last_ev l
where ck.character_id = l.character_id and ck.item_id = l.item_id and not ck.held_by_dm and l.old_state is not null
  and not public._ik_contains(l.new_state, l.new_revealed, l.old_state, l.old_revealed);

do $$
declare c uuid; n int := 0; h int;
begin
  select count(*) into h from public.character_item_knowledge where held_by_dm;
  for c in select id from public.campaigns order by id loop
    n := n + public._party_share_sync(c);
  end loop;
  raise notice 'party item knowledge: % held record(s); % record(s) raised to the party level', h, n;
end $$;

-- ---- 8. grants ---------------------------------------------------------------------------------------------------------------
revoke all on function public._party_share_on(uuid), public._ik_contains(text, text[], text, text[]),
  public._identify_apply_one(uuid, text, text[]), public._party_apply_to(uuid, text, text, text[]), public._party_share_from(uuid, text),
  public._party_share_pull(uuid), public._party_share_sync(uuid), public._party_share_join() from public, anon, authenticated;
revoke all on function public.get_campaign_identification_sharing(uuid), public.set_campaign_identification_sharing(uuid, boolean),
  public.dm_release_item_knowledge_hold(text, uuid[], uuid) from public, anon;
grant execute on function public.get_campaign_identification_sharing(uuid), public.set_campaign_identification_sharing(uuid, boolean),
  public.dm_release_item_knowledge_hold(text, uuid[], uuid) to authenticated, service_role;

reset lock_timeout;
notify pgrst, 'reload schema';
