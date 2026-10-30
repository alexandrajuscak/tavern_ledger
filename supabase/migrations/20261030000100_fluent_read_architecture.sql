-- Fluent read architecture (docs/FLUENT_READ_ARCHITECTURE.md, docs/CHARACTER_SHELL_CONTRACT.md). Additive and reversible:
-- rollback supabase/rollback/rollback_fluent_read_architecture.sql. No existing read RPC is removed or changed in behaviour.
--
-- 1. get_character_derived_stats: transaction-local memo, active ONLY inside the read bundles below. Outside a bundle the
--    function computes exactly as before. Inside one bundle every nested caller (_character_mods, slots, resources, states,
--    spellbook, ...) shares one rules evaluation per (bundle token, character, current_user, auth.uid()); current_user is part
--    of the key because SECURITY DEFINER callers run as the owner and must never share a result with invoker callers.
-- 2. _character_read: allowlisted reads of one character (the existing RPCs unchanged + the table reads the sheet does today,
--    with the same ordering). Every read runs as the caller: RLS and each RPC's own access check decide.
-- 3. get_character_reads / get_character_view / get_character_bundle: one round trip, one memo scope, per-read error capture.
-- 4. character_revisions: append-only change log (id = revision), one row per transaction, character and source table, written
--    by a trigger on the 21 tables the sheet watched with 64 Realtime bindings; the sheet now watches this one table (INSERT).
-- 5. get_background_list / get_background_detail: the Background picker without the 359 KB feat list it never used.

-- ---------------------------------------------------------------------------------------------------------------- 1. memo
create or replace function public.get_character_derived_stats(p_character uuid)
returns jsonb language plpgsql stable set search_path = public, pg_temp as $$
declare tok text := current_setting('tl_memo.token', true); k text; v text;
begin
  if tok is null or tok = '' then
    return public._wild_shape_layer(p_character, public._feat_layer(p_character, public._derived_stats_full(p_character)));
  end if;
  k := 'tl_memo.d' || md5(tok || p_character::text || current_user || coalesce(auth.uid()::text, '-'));
  v := current_setting(k, true);
  if v is not null and v <> '' then return v::jsonb; end if;
  v := public._wild_shape_layer(p_character, public._feat_layer(p_character, public._derived_stats_full(p_character)))::text;
  perform set_config(k, v, true);
  return v::jsonb;
end $$;

-- The rules core is also reached without the full layer (get_character_feats, get_character_states,
-- get_character_transformation call _derived_stats_levels directly): the same memo there, same key rules. Body unchanged.
create or replace function public._derived_stats_levels(p_character uuid)
returns jsonb language plpgsql stable set search_path = public, pg_temp as $$
declare d jsonb; li jsonb; tok text := current_setting('tl_memo.token', true); k text; v text;
begin
  if tok is not null and tok <> '' then
    k := 'tl_memo.l' || md5(tok || p_character::text || current_user || coalesce(auth.uid()::text, '-'));
    v := current_setting(k, true);
    if v is not null and v <> '' then return v::jsonb; end if;
  end if;
  d := public._derived_stats_core(p_character);                      -- RLS: owner, campaign DM, admin
  li := public._character_level_info(p_character);
  d := d || jsonb_build_object(
    'level', li,
    'proficiency_bonus', (d -> 'proficiency_bonus') || jsonb_build_object(
      'source', 'total_level', 'level', (li ->> 'total_level')::int, 'level_source', li ->> 'source',
      'fallback', (li ->> 'fallback')::boolean));
  if k is not null then perform set_config(k, d::text, true); end if;
  return d;
end $$;

-- ------------------------------------------------------------------------------------------------------- 4. revisions (change log)
-- Append-only: one row per transaction, character and source table. The row id is the revision (monotonic). Inserting (never
-- updating a shared row) means no row lock is held between statements: no new lock-ordering / deadlock path, and nothing is
-- left pending in the transaction (DDL after DML in one transaction still works). Old rows are pruned on the way.
create table if not exists public.character_revisions (
  id bigint generated always as identity primary key,
  character_id uuid not null references public.characters(id) on delete cascade,
  source_table text not null,
  changed_at timestamptz not null default now()
);
create index if not exists character_revisions_character on public.character_revisions (character_id, source_table, id desc);
create index if not exists character_revisions_changed_at on public.character_revisions (changed_at);
comment on table public.character_revisions is
  'Change log per character and source table (fluent read architecture): id = revision. Written only by _bump_character_revision; the sheet watches it (Realtime INSERT) to refresh only the affected domain. No data, only which table changed.';
alter table public.character_revisions enable row level security;
drop policy if exists character_revisions_read on public.character_revisions;
create policy character_revisions_read on public.character_revisions for select to authenticated
  using (public.can_access_character(character_id));
revoke all on public.character_revisions from public, anon, authenticated;
grant select on public.character_revisions to authenticated;

-- One row per transaction and (character, table) (transaction-local marker), written at the end of the statement. It never fails
-- the user's write: an error is only a warning. About 1 in 50 calls removes up to 200 rows older than 3 days (skip locked).
create or replace function public._bump_character_revision()
returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
declare cid uuid; prev uuid; k text;
begin
  if tg_op = 'DELETE' then cid := old.character_id; else cid := new.character_id; end if;
  if tg_op = 'UPDATE' then prev := old.character_id; end if;
  foreach cid in array array_remove(array[cid, nullif(prev, cid)], null) loop
    k := 'tl_rev.r' || md5(cid::text || tg_table_name || txid_current()::text);
    continue when current_setting(k, true) = '1';
    perform set_config(k, '1', true);
    insert into public.character_revisions (character_id, source_table)
    select cid, tg_table_name where exists (select 1 from public.characters c where c.id = cid);
  end loop;
  if random() < 0.02 then
    delete from public.character_revisions where id in (
      select id from public.character_revisions where changed_at < now() - interval '3 days' order by id limit 200 for update skip locked);
  end if;
  return null;
exception when others then
  raise warning 'character revision not recorded (%): %', tg_table_name, sqlerrm;
  return null;
end $$;
revoke all on function public._bump_character_revision() from public, anon, authenticated;

do $$
declare t text;
begin
  foreach t in array array['inventory_items', 'character_equipment', 'character_proficiencies', 'character_lineages',
    'character_lineage_choices', 'character_backgrounds', 'character_transformations', 'character_spellcasting_sources',
    'character_spells', 'character_classes', 'character_spell_slot_state', 'character_temporary_spell_slots', 'character_resources',
    'character_feature_choices', 'character_optional_features', 'notes', 'spell_slots', 'feature_trackers', 'features', 'attacks', 'spells']
  loop
    execute format('drop trigger if exists %I on public.%I', t || '_revision', t);
    execute format('create trigger %I after insert or update or delete on public.%I '
                   'for each row execute function public._bump_character_revision()', t || '_revision', t);
  end loop;
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime')
     and not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'character_revisions') then
    execute 'alter publication supabase_realtime add table public.character_revisions';
  end if;
end $$;

-- ------------------------------------------------------------------------------------------------------- 2. read dispatcher
-- Runs as the caller (SECURITY INVOKER). Table reads mirror the PostgREST queries of js/store.js, js/creature-api.js,
-- js/class-api.js and js/inventory-api.js (same columns, same order), so the client receives the same rows as before.
create or replace function public._character_read(p_character uuid, p_name text)
returns jsonb language plpgsql stable set search_path = public, pg_temp as $$
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
            pack_size, capacity_weight_lb, capacity_volume_cuft, weightless_contents, extradimensional
          from public.v_item_catalog
          where id in (select ii.item_id from public.inventory_items ii where ii.inventory_id = inv and ii.item_id is not null)) ci));
  when 'revisions' then   -- latest revision (log id) per source table
    return (select coalesce(jsonb_object_agg(x.source_table, x.rev), '{}') from (
      select r2.source_table, max(r2.id) as rev from public.character_revisions r2 where r2.character_id = p_character group by 1) x);
  else
    raise exception 'Unknown read %', p_name using errcode = '22023';
  end case;
end $$;

-- ------------------------------------------------------------------------------------------------------- 3. read entry points
create or replace function public.get_character_reads(p_character uuid, p_reads text[])
returns jsonb language plpgsql volatile set search_path = public, pg_temp as $$
declare n text; ok jsonb := '{}'; err jsonb := '{}'; started timestamptz := clock_timestamp();
begin
  if p_character is null or auth.uid() is null or not public.can_access_character(p_character) then
    raise exception 'Character not found' using errcode = '42501';
  end if;
  if coalesce(cardinality(p_reads), 0) = 0 or cardinality(p_reads) > 40 then
    raise exception 'Between 1 and 40 reads' using errcode = '22023';
  end if;
  perform set_config('tl_memo.token', md5(random()::text || clock_timestamp()::text), true);
  for n in select distinct x from unnest(p_reads) x loop
    begin
      ok := ok || jsonb_build_object(n, public._character_read(p_character, n));
    exception
      when query_canceled then raise;   -- a statement timeout ends the whole request, never only one part
      when others then err := err || jsonb_build_object(n, jsonb_build_object('code', sqlstate, 'message', sqlerrm));
    end;
  end loop;
  perform set_config('tl_memo.token', '', true);
  return jsonb_build_object('character_id', p_character, 'reads', ok, 'errors', err,
    'server_ms', round(extract(epoch from clock_timestamp() - started) * 1000));
end $$;

-- the reads every mounted sheet needs (header, vitals, Play, Abilities, Build, Bio); Spells and Inventory are domains of their own
create or replace function public._character_read_set(p_domain text)
returns text[] language sql immutable as $$
  select case p_domain
    when 'shell' then array['characters', 'inventory_items', 'notes', 'spell_slots', 'feature_trackers', 'features', 'attacks', 'spells',
      'get_character_derived_stats', 'get_character_proficiencies', 'get_character_lineage', 'get_character_background',
      'get_character_feats', 'get_character_class_summary', 'get_character_spell_slots', 'get_character_class_features',
      'get_character_resources', 'get_character_states', 'get_character_transformation', 'companions', 'get_character_infusions',
      'starting_equipment_applied', 'primary_class_starting_equipment', 'get_character_governance', 'get_character_change_requests',
      'revisions']
    when 'spells' then array['get_character_spellbook']
    when 'inventory' then array['inventory_bundle']
  end $$;

/** Character open: the shell plus the active tab's domain, one request, one rules evaluation per security context. */
create or replace function public.get_character_view(p_character uuid, p_tab text default 'combat')
returns jsonb language plpgsql volatile set search_path = public, pg_temp as $$
begin
  if p_tab not in ('combat', 'stats', 'spells', 'inventory', 'features', 'bio') then raise exception 'Unknown tab' using errcode = '22023'; end if;
  return public.get_character_reads(p_character, public._character_read_set('shell')
    || coalesce(public._character_read_set(case p_tab when 'spells' then 'spells' when 'inventory' then 'inventory' end), '{}'))
    || jsonb_build_object('tab', p_tab, 'contract', 1);
end $$;

/** First open of the Spells or Inventory domain (or a shell refresh). */
create or replace function public.get_character_bundle(p_character uuid, p_domain text)
returns jsonb language plpgsql volatile set search_path = public, pg_temp as $$
begin
  if public._character_read_set(p_domain) is null then raise exception 'Unknown domain' using errcode = '22023'; end if;
  return public.get_character_reads(p_character, public._character_read_set(p_domain)) || jsonb_build_object('domain', p_domain, 'contract', 1);
end $$;

-- ------------------------------------------------------------------------------------------------------- 5. Background picker
-- The list carries what the picker list shows and filters on, plus every tool name (the duplicate-replacement dialog); the
-- detail is the same version object get_background_catalog returns. Visibility: RLS on background_versions (invoker).
create or replace function public.get_background_list()
returns jsonb language sql stable set search_path = public, pg_temp as $$
  with v as (
    select public._background_version_json(bv.id) as j, bv.ruleset, b.sort_order as bs, bv.sort_order as vs
    from public.background_versions bv join public.backgrounds b on b.id = bv.background_id)
  select jsonb_build_object(
    'versions', coalesce((select jsonb_agg(jsonb_build_object('id', j ->> 'id', 'name', j ->> 'name', 'ruleset', j ->> 'ruleset',
        'enabled_by_default', j -> 'enabled_by_default', 'status', j ->> 'status', 'dm_permission', j -> 'dm_permission',
        'setting', j ->> 'setting', 'source_label', j ->> 'source_label', 'legacy', j -> 'legacy',
        'skills', coalesce((select jsonb_agg(g ->> 'name') from jsonb_array_elements(j -> 'grants') g where g ->> 'kind' = 'skill'), '[]'))
      order by ruleset desc, bs, vs) from v), '[]'),
    'tools', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'name', name) order by name) from (
        select distinct t ->> 'id' as id, t ->> 'name' as name from v,
          lateral (select o as t from jsonb_array_elements(j -> 'choices') c, jsonb_array_elements(c -> 'options') o where o ->> 'kind' = 'tool'
                   union all select g from jsonb_array_elements(j -> 'grants') g where g ->> 'kind' = 'tool') x) tl), '[]'));
$$;

create or replace function public.get_background_detail(p_version text)
returns jsonb language sql stable set search_path = public, pg_temp as $$
  select public._background_version_json(bv.id) from public.background_versions bv where bv.id = p_version
$$;

-- ------------------------------------------------------------------------------------------------------------------- grants
revoke all on function public._character_read(uuid, text), public.get_character_reads(uuid, text[]), public._character_read_set(text),
  public.get_character_view(uuid, text), public.get_character_bundle(uuid, text), public.get_background_list(),
  public.get_background_detail(text) from public, anon;
grant execute on function public._character_read(uuid, text), public.get_character_reads(uuid, text[]), public._character_read_set(text),
  public.get_character_view(uuid, text), public.get_character_bundle(uuid, text), public.get_background_list(),
  public.get_background_detail(text) to authenticated, service_role;

notify pgrst, 'reload schema';
