-- Incident fix 20261029000100: golden check of the derived stats, READ-ONLY. Run once before and once after the migration and
-- compare the two outputs line by line (they must be identical). Prints a character index and hashes only (no names, no ids).
-- The class proficiency list is compared as a sorted set: entries with the same type and name may change their order
-- (it was never defined), everything else must be byte-identical. Every call runs as the character's owner (RLS applies).
do $$
declare ids uuid[]; owners uuid[]; i int; d jsonb; p jsonb; line text;
begin
  select array_agg(id order by id), array_agg(owner_id order by id) into ids, owners from public.characters;
  for i in 1 .. coalesce(cardinality(ids), 0) loop
    perform set_config('request.jwt.claims', json_build_object('sub', owners[i], 'role', 'authenticated')::text, true);
    set local role authenticated;
    d := public.get_character_derived_stats(ids[i]);
    p := public.get_character_proficiencies(ids[i]);
    set local role postgres;
    line := format('char %s derived %s profs-set %s proficiencies %s', i,
      left(md5((d - 'proficiencies')::text), 12),
      left(md5(coalesce((select string_agg(x::text, '|' order by x::text) from jsonb_array_elements(d -> 'proficiencies') x), '')), 12),
      left(md5(p::text), 12));
    raise notice '%', line;
  end loop;
end $$;
