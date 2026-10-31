-- Read cache write without waiting (forward fix of 20261030000200; docs/GAMEPLAY_POLISH_AUDIT.md, section 9).
-- Rollback: supabase/rollback/rollback_cache_put_no_wait.sql.
--
-- Found on production: 2 "deadlock detected" since the progressive release; reproduced locally (5 deadlocks in 3 runs) with
-- concurrent cold reads of ONE character by ONE viewer (a player on two devices, a prefetch overlapping the open). Both
-- requests upserted the same tl_cache.character_reads rows in a different order; get_character_reads caught the 40P01 per read,
-- so the sheet got a failed read (and waited for the deadlock timeout first). Concurrent gameplay writes (slots, rests, HP,
-- ability scores, coins, resources) with the cache counters produced no deadlock.
-- Now: one cache writer per (character, viewer) at a time, taken with TRY (never waits); a request that does not get it simply
-- does not store (the cache is optional, the value it returns is unaffected). Any failure of a cache write is swallowed.
create or replace function tl_cache.put(p_character uuid, p_read text, p_key jsonb, p_payload jsonb)
returns void language plpgsql volatile security definer set search_path = public, pg_temp as $$
begin
  if not coalesce((p_key ->> 'ok')::boolean, false) or auth.uid() is null or p_payload is null then return; end if;
  -- this transaction already changed the character or the rules data: a later write in it would not bump again (one bump per
  -- transaction), so a value computed now could outlive that write. Not stored.
  if current_setting('tl_cache.c' || md5(p_character::text || txid_current()::text), true) = '1'
     or current_setting('tl_cache.g' || md5(txid_current()::text), true) = '1' then
    return;
  end if;
  -- another request of the same viewer is storing this character's reads right now: skip (no wait, no lock-order deadlock)
  if not pg_try_advisory_xact_lock(hashtextextended('tl_cache.put:' || p_character::text || ':' || auth.uid()::text, 0)) then
    return;
  end if;
  insert into tl_cache.character_reads as r (character_id, viewer, read_name, char_rev, global_rev, mig, payload, computed_at)
  values (p_character, auth.uid(), p_read, (p_key ->> 'c')::bigint, (p_key ->> 'g')::bigint, p_key ->> 'm', p_payload, now())
  on conflict (character_id, viewer, read_name) do update
    set char_rev = excluded.char_rev, global_rev = excluded.global_rev, mig = excluded.mig, payload = excluded.payload,
        computed_at = excluded.computed_at;
exception when others then
  return;   -- a cache write never fails a read (the character was deleted meanwhile, a lock conflict, ...)
end $$;
revoke all on function tl_cache.put(uuid, text, jsonb, jsonb) from public, anon;
grant execute on function tl_cache.put(uuid, text, jsonb, jsonb) to authenticated, service_role;
