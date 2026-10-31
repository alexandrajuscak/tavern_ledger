-- Rollback of 20261031000200_cache_put_no_wait.sql: tl_cache.put exactly as 20261030000200 defined it.
begin;
CREATE OR REPLACE FUNCTION tl_cache.put(p_character uuid, p_read text, p_key jsonb, p_payload jsonb)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
begin
  if not coalesce((p_key ->> 'ok')::boolean, false) or auth.uid() is null or p_payload is null then return; end if;
  -- this transaction already changed the character or the rules data: a later write in it would not bump again (one bump per
  -- transaction), so a value computed now could outlive that write. Not stored.
  if current_setting('tl_cache.c' || md5(p_character::text || txid_current()::text), true) = '1'
     or current_setting('tl_cache.g' || md5(txid_current()::text), true) = '1' then
    return;
  end if;
  insert into tl_cache.character_reads as r (character_id, viewer, read_name, char_rev, global_rev, mig, payload, computed_at)
  values (p_character, auth.uid(), p_read, (p_key ->> 'c')::bigint, (p_key ->> 'g')::bigint, p_key ->> 'm', p_payload, now())
  on conflict (character_id, viewer, read_name) do update
    set char_rev = excluded.char_rev, global_rev = excluded.global_rev, mig = excluded.mig, payload = excluded.payload,
        computed_at = excluded.computed_at;
exception when foreign_key_violation then
  return;   -- the character was deleted meanwhile
end $function$

;
commit;
