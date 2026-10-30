-- Progressive fluent reads (docs/FLUENCY_BENCHMARKS.md §6, docs/CHARACTER_SHELL_CONTRACT.md). Additive and reversible:
-- rollback supabase/rollback/rollback_progressive_fluent_reads.sql. No existing RPC changes behaviour; the legacy read path
-- (every get_character_* RPC called directly) never touches the cache below.
--
-- Why: the one-request view (20261030000100) evaluated the rules ~2 times per open, but all at once; 7 concurrent opens on the
-- Free compute took 15-23 s against the 8 s statement timeout. Most of that work is the SAME result computed again: a
-- character's derived stats only change when its build or the rules data change.
--
-- 1. tl_cache: a server-side result cache of the expensive per-character reads, per viewer (auth.uid()), used ONLY by
--    get_character_reads (and so by the shell / view / bundle entry points). A cached value is served only while all of these
--    are unchanged since it was computed:
--      * the character's change counter: bumped (once per transaction) by a row trigger on EVERY public table that has a
--        character_id column, on tables with an inventory_id column (via inventories.character_id), and on characters itself
--        except updates that change only runtime columns (HP, temp HP, death saves, inspiration, hit dice, coins, updated_at;
--        none of these is read by a cached read: see the list in _CACHEABLE below);
--      * the global counter: bumped by a row trigger on every OTHER public table (catalog, campaigns, members, policies, DM
--        content, profiles, ...);
--      * the latest applied migration (a migration may change a rules function);
--      * the calculation version constant below.
--    The counters are read BEFORE the result is computed, so a concurrent change can only make a stored value look older
--    (a miss), never newer. Not cached at all: characters with a Wild Shape row (the form layer depends on current HP and on
--    the clock), governance, change requests, table reads, and any read that raised an error.
--    fluent_read_tests.sql asserts that every public table carries a counter trigger, so a future table cannot be missed.
-- 2. get_character_shell: the small first request of a character open (stored rows, derived stats, governance, open requests,
--    revisions). The sheet renders identity and vitals from it; its loaders then ask for the rest in one coalesced
--    get_character_reads (js/read-layer.js).
-- 3. Starting equipment: get_class_starting_equipment (granted to anon and authenticated since 20261017000600) calls
--    _starting_equipment_candidates, which nobody but the owner could execute, so the starting-equipment prompt silently
--    failed for classes with placeholder entries. The helper reads official, non-archived catalog items only (no character
--    data); authenticated gets EXECUTE on it.

-- ------------------------------------------------------------------------------------------------------------- 1. tl_cache
create schema if not exists tl_cache;
revoke all on schema tl_cache from public, anon;
grant usage on schema tl_cache to authenticated, service_role;
comment on schema tl_cache is
  'Fluent read cache (20261030000200). Not exposed by the API (PostgREST serves public and graphql_public only); its tables have no grants; only the functions below touch them.';

create table if not exists tl_cache.character_rev (
  character_id uuid primary key references public.characters (id) on delete cascade,
  rev bigint not null default 0
);
create table if not exists tl_cache.global_rev (
  id int primary key default 1 check (id = 1),
  rev bigint not null default 0
);
insert into tl_cache.global_rev (id, rev) values (1, 0) on conflict (id) do nothing;
create table if not exists tl_cache.character_reads (
  character_id uuid not null references public.characters (id) on delete cascade,
  viewer uuid not null,
  read_name text not null,
  char_rev bigint not null,
  global_rev bigint not null,
  mig text not null,
  payload jsonb not null,
  computed_at timestamptz not null default now(),
  primary key (character_id, viewer, read_name)
);
alter table tl_cache.character_rev enable row level security;
alter table tl_cache.global_rev enable row level security;
alter table tl_cache.character_reads enable row level security;
revoke all on all tables in schema tl_cache from public, anon, authenticated;

-- Counter trigger. tg_argv[0]: 'character' (character_id column), 'inventory' (inventory_id -> inventories.character_id),
-- 'characters' (the characters table) or 'global'. Errors are NOT swallowed: a missed bump could serve a stale value.
create or replace function tl_cache.bump()
returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
declare mode text := tg_argv[0]; o jsonb; n jsonb; ids uuid[] := '{}'; g boolean := false; cid uuid; k text;
  runtime constant text[] := array['hp_current', 'hp_temp', 'death_successes', 'death_failures', 'inspiration', 'hit_dice_current',
    'cp', 'sp', 'ep', 'gp', 'pp', 'updated_at'];
begin
  if tg_op <> 'INSERT' then o := to_jsonb(old); end if;
  if tg_op <> 'DELETE' then n := to_jsonb(new); end if;
  if tg_op = 'UPDATE' and o = n then return null; end if;                          -- a no-op update changes nothing
  if mode = 'characters' then
    if tg_op = 'UPDATE' and (o - runtime) = (n - runtime) then return null; end if;  -- HP, coins, ...: runtime only
    ids := array[coalesce(n ->> 'id', o ->> 'id')::uuid];
  elsif mode = 'character' then
    ids := array_remove(array[(n ->> 'character_id')::uuid, (o ->> 'character_id')::uuid], null);
    g := (n is not null and n ->> 'character_id' is null) or (o is not null and o ->> 'character_id' is null);
  elsif mode = 'inventory' then
    -- a character's inventory bumps that character; a party / shop / NPC inventory (or an unknown one) bumps the global counter
    foreach cid in array array_remove(array[(n ->> 'inventory_id')::uuid, (o ->> 'inventory_id')::uuid], null) loop
      k := (select i.character_id::text from public.inventories i where i.id = cid);
      if k is null then g := true; else ids := ids || k::uuid; end if;
    end loop;
  else
    g := true;
  end if;
  foreach cid in array ids loop
    k := 'tl_cache.c' || md5(cid::text || txid_current()::text);
    continue when current_setting(k, true) = '1';
    insert into tl_cache.character_rev as r (character_id, rev)
    select cid, 1 where exists (select 1 from public.characters c where c.id = cid)
    on conflict (character_id) do update set rev = r.rev + 1;
    perform set_config(k, '1', true);
  end loop;
  if g then
    k := 'tl_cache.g' || md5(txid_current()::text);
    if coalesce(current_setting(k, true), '') <> '1' then
      update tl_cache.global_rev set rev = rev + 1 where id = 1;
      perform set_config(k, '1', true);
    end if;
  end if;
  return null;
end $$;
revoke all on function tl_cache.bump() from public, anon, authenticated;

-- one counter trigger on every public table (named tl_cache_rev; fluent_read_tests.sql checks the coverage)
do $$
declare t record; mode text;
begin
  for t in
    select c.relname,
      exists (select 1 from pg_attribute a where a.attrelid = c.oid and a.attname = 'character_id' and not a.attisdropped) as has_char,
      exists (select 1 from pg_attribute a where a.attrelid = c.oid and a.attname = 'inventory_id' and not a.attisdropped) as has_inv
    from pg_class c where c.relnamespace = 'public'::regnamespace and c.relkind in ('r', 'p') and c.relname <> 'character_revisions'
  loop
    mode := case when t.relname = 'characters' then 'characters' when t.has_char then 'character' when t.has_inv then 'inventory' else 'global' end;
    execute format('drop trigger if exists tl_cache_rev on public.%I', t.relname);
    execute format('create trigger tl_cache_rev after insert or update or delete on public.%I for each row execute function tl_cache.bump(%L)',
      t.relname, mode);
  end loop;
end $$;

create or replace function tl_cache._mig()
returns text language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v text;
begin
  if to_regclass('supabase_migrations.schema_migrations') is null then return 'local'; end if;
  execute 'select max(version) from supabase_migrations.schema_migrations' into v;
  return coalesce(v, '-');
end $$;

-- Validity key of one character, read before anything is computed. cacheable = false for a character with a Wild Shape row
-- and for callers other than an authenticated API user (service role, owner sessions, anonymous).
create or replace function tl_cache.key(p_character uuid, p_role name)
returns jsonb language sql stable security definer set search_path = public, pg_temp as $$
  select jsonb_build_object(
    'c', coalesce((select r.rev from tl_cache.character_rev r where r.character_id = p_character), 0),
    'g', (select g.rev from tl_cache.global_rev g where g.id = 1),
    'm', tl_cache._mig() || '/calc1',
    'ok', p_role = 'authenticated' and auth.uid() is not null
          and not exists (select 1 from public.character_transformations t where t.character_id = p_character))
$$;

create or replace function tl_cache.get(p_character uuid, p_read text, p_key jsonb)
returns jsonb language sql stable security definer set search_path = public, pg_temp as $$
  select r.payload from tl_cache.character_reads r
  where (p_key ->> 'ok')::boolean and r.character_id = p_character and r.viewer = auth.uid() and r.read_name = p_read
    and r.char_rev = (p_key ->> 'c')::bigint and r.global_rev = (p_key ->> 'g')::bigint and r.mig = p_key ->> 'm'
$$;

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
  insert into tl_cache.character_reads as r (character_id, viewer, read_name, char_rev, global_rev, mig, payload, computed_at)
  values (p_character, auth.uid(), p_read, (p_key ->> 'c')::bigint, (p_key ->> 'g')::bigint, p_key ->> 'm', p_payload, now())
  on conflict (character_id, viewer, read_name) do update
    set char_rev = excluded.char_rev, global_rev = excluded.global_rev, mig = excluded.mig, payload = excluded.payload,
        computed_at = excluded.computed_at;
exception when foreign_key_violation then
  return;   -- the character was deleted meanwhile
end $$;

revoke all on function tl_cache._mig(), tl_cache.key(uuid, name), tl_cache.get(uuid, text, jsonb), tl_cache.put(uuid, text, jsonb, jsonb)
  from public, anon;
grant execute on function tl_cache._mig(), tl_cache.key(uuid, name), tl_cache.get(uuid, text, jsonb), tl_cache.put(uuid, text, jsonb, jsonb)
  to authenticated, service_role;

-- the counters start for every existing character (no row = 0 is also valid; this only makes the state explicit)
insert into tl_cache.character_rev (character_id, rev) select id, 0 from public.characters on conflict do nothing;

-- ---------------------------------------------------------------------------------------------- read entry point with cache
-- Same contract as 20261030000100. The reads in _CACHEABLE are served from tl_cache when the key matches and stored after a
-- successful computation. A cached derived-stats value also seeds the bundle memo, so nested invoker callers (slots,
-- resources, spellbook, ...) reuse it instead of evaluating the rules again.
create or replace function public.get_character_reads(p_character uuid, p_reads text[])
returns jsonb language plpgsql volatile set search_path = public, pg_temp as $$
declare n text; ok jsonb := '{}'; err jsonb := '{}'; started timestamptz := clock_timestamp(); tok text; key jsonb; v jsonb;
  hits int := 0; stored int := 0;
  cacheable constant text[] := array['get_character_derived_stats', 'get_character_proficiencies', 'get_character_lineage',
    'get_character_background', 'get_character_feats', 'get_character_class_summary', 'get_character_spell_slots',
    'get_character_class_features', 'get_character_resources', 'get_character_states', 'get_character_infusions',
    'get_character_spellbook', 'primary_class_starting_equipment',
    -- only reached for characters WITHOUT a Wild Shape row (key.ok); then it depends on counted data only (no HP, no clock)
    'get_character_transformation'];
begin
  if p_character is null or auth.uid() is null or not public.can_access_character(p_character) then
    raise exception 'Character not found' using errcode = '42501';
  end if;
  if coalesce(cardinality(p_reads), 0) = 0 or cardinality(p_reads) > 40 then
    raise exception 'Between 1 and 40 reads' using errcode = '22023';
  end if;
  key := tl_cache.key(p_character, current_user);   -- before any computation (see the header)
  tok := md5(random()::text || clock_timestamp()::text);
  perform set_config('tl_memo.token', tok, true);
  if (key ->> 'ok')::boolean then
    v := tl_cache.get(p_character, 'get_character_derived_stats', key);
    if v is not null then
      perform set_config('tl_memo.d' || md5(tok || p_character::text || current_user || coalesce(auth.uid()::text, '-')), v::text, true);
    end if;
  end if;
  for n in select distinct x from unnest(p_reads) x loop
    begin
      v := case when n = any (cacheable) then tl_cache.get(p_character, n, key) end;
      if v is not null then
        hits := hits + 1;
      else
        v := public._character_read(p_character, n);
        if n = any (cacheable) and (key ->> 'ok')::boolean and v is not null then
          perform tl_cache.put(p_character, n, key, v); stored := stored + 1;
        end if;
      end if;
      ok := ok || jsonb_build_object(n, v);
    exception
      when query_canceled then raise;   -- a statement timeout ends the whole request, never only one part
      when others then err := err || jsonb_build_object(n, jsonb_build_object('code', sqlstate, 'message', sqlerrm));
    end;
  end loop;
  perform set_config('tl_memo.token', '', true);
  return jsonb_build_object('character_id', p_character, 'reads', ok, 'errors', err,
    'server_ms', round(extract(epoch from clock_timestamp() - started) * 1000), 'cache', jsonb_build_object('hits', hits, 'stored', stored));
end $$;

-- 'core' = the Character Shell (first request of an open); 'shell' (the full first view) is kept for get_character_view.
create or replace function public._character_read_set(p_domain text)
returns text[] language sql immutable as $$
  select case p_domain
    when 'core' then array['characters', 'inventory_items', 'notes', 'spell_slots', 'feature_trackers', 'features', 'attacks', 'spells',
      'get_character_derived_stats', 'get_character_governance', 'get_character_change_requests', 'revisions']
    when 'shell' then array['characters', 'inventory_items', 'notes', 'spell_slots', 'feature_trackers', 'features', 'attacks', 'spells',
      'get_character_derived_stats', 'get_character_proficiencies', 'get_character_lineage', 'get_character_background',
      'get_character_feats', 'get_character_class_summary', 'get_character_spell_slots', 'get_character_class_features',
      'get_character_resources', 'get_character_states', 'get_character_transformation', 'companions', 'get_character_infusions',
      'starting_equipment_applied', 'primary_class_starting_equipment', 'get_character_governance', 'get_character_change_requests',
      'revisions']
    when 'spells' then array['get_character_spellbook']
    when 'inventory' then array['inventory_bundle']
  end $$;

/** Character Shell: the first request of a character open (identity, vitals, permissions, lock, open requests, revisions). */
create or replace function public.get_character_shell(p_character uuid)
returns jsonb language plpgsql volatile set search_path = public, pg_temp as $$
begin
  return public.get_character_reads(p_character, public._character_read_set('core')) || jsonb_build_object('domain', 'core', 'contract', 2);
end $$;

revoke all on function public.get_character_shell(uuid) from public, anon;
grant execute on function public.get_character_shell(uuid) to authenticated, service_role;

-- ------------------------------------------------------------------------------------------------- 3. starting equipment
revoke all on function public._starting_equipment_candidates(jsonb) from public, anon;   -- local stacks grant new functions to anon by default
grant execute on function public._starting_equipment_candidates(jsonb) to authenticated;

notify pgrst, 'reload schema';
