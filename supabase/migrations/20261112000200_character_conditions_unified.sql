-- =============================================================================
-- Character conditions and DM tags, one source of truth (docs/HIDDEN_DM_DATA.md "Conditions and tags on the sheet").
--
-- character_conditions (20261019000500) becomes the only store of a character's conditions: SRD conditions, Exhaustion with a
-- level (1-6), and tags (resistance / immunity / vulnerability to a damage type, condition immunity, blessed, cursed, free
-- text), each with an optional note, duration text, timer and the DM's "hidden" flag. Display and reminder ONLY: nothing here
-- changes AC, speed, saves or any other derived value.
--
--   1. additive columns (kind, condition_key, level, tag_type, damage_type_id, duration_text, source, legacy_value, legacy_pos);
--      rows that existed before get source 'player' when the character's owner applied them, otherwise 'dm';
--   2. COPY (idempotent): every entry of characters.conditions becomes a visible row (source 'legacy_sheet', legacy_value = the
--      entry itself, legacy_pos = its position). characters.conditions is NOT changed by the migration;
--   3. MIRROR: characters.conditions is kept as the list of the VISIBLE rows (home card, export, Wild Shape panel, combat,
--      ?fluent=0 keep working). A hidden-only change never touches the characters row: no Realtime event, no updated_at;
--   4. COMPATIBILITY (one release): a client that still writes characters.conditions directly (cached old JS, import) is
--      translated into rows; it can add and remove only its own visible rows (source player / legacy_sheet);
--   5. RPCs: apply_character_effect, update_character_effect (new); remove_character_condition (a player removes only his own
--      rows: DM and combat rows need the DM), get_character_conditions (new fields), apply_character_condition (source);
--   6. the player read path: _character_read('get_character_conditions') (the caller's view; not in the server cache);
--   7. Realtime: character_revisions rows for VISIBLE changes only (three WHEN-guarded triggers), and character_conditions
--      leaves the supabase_realtime publication (no client subscribes to it; its DELETE events are not RLS-filtered and would
--      carry the id of a removed hidden row to any subscriber);
--   8. combat_finish carries Exhaustion with its level (and SRD conditions with their key) instead of a bare name.
-- Cache: character_conditions keeps its tl_cache_rev trigger (mode 'character'); no new table. Every change, hidden or not,
-- invalidates that character's cached reads (a miss, never a leak: tl_cache is per viewer).
-- Rollback: supabase/rollback/rollback_character_conditions_unified.sql.
-- =============================================================================

-- ---- 1. columns ---------------------------------------------------------------------------------------------------------
do $$
declare fresh boolean := not exists (select 1 from information_schema.columns
                                     where table_schema = 'public' and table_name = 'character_conditions' and column_name = 'source');
begin
  alter table public.character_conditions
    add column if not exists kind text not null default 'condition',
    add column if not exists condition_key text,
    add column if not exists level int,
    add column if not exists tag_type text,
    add column if not exists damage_type_id text references public.damage_types (id),
    add column if not exists duration_text text,
    add column if not exists source text not null default 'dm',
    add column if not exists legacy_value jsonb,
    add column if not exists legacy_pos int;
  if fresh then   -- once: who applied the rows that already exist (no trigger of this migration exists yet)
    update public.character_conditions k set source = 'player'
    from public.characters c where c.id = k.character_id and k.applied_by = c.owner_id and k.content_version_id is null
      and not k.hidden;
  end if;
end $$;
do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'character_conditions_kind_check') then
    alter table public.character_conditions add constraint character_conditions_kind_check check (kind in ('condition', 'exhaustion', 'tag'));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'character_conditions_key_check') then
    alter table public.character_conditions add constraint character_conditions_key_check check (condition_key ~ '^[a-z]+$');
  end if;
  if not exists (select 1 from pg_constraint where conname = 'character_conditions_level_check') then
    alter table public.character_conditions add constraint character_conditions_level_check
      check (case when kind = 'exhaustion' then level is not null and level between 1 and 6 else level is null end);
  end if;
  if not exists (select 1 from pg_constraint where conname = 'character_conditions_tag_check') then
    alter table public.character_conditions add constraint character_conditions_tag_check
      check (case when kind = 'tag' then tag_type is not null
                  and tag_type in ('resistance', 'immunity', 'vulnerability', 'condition_immunity', 'blessing', 'curse', 'other')
                  else tag_type is null end);
  end if;
  if not exists (select 1 from pg_constraint where conname = 'character_conditions_duration_check') then
    alter table public.character_conditions add constraint character_conditions_duration_check check (length(duration_text) <= 80);
  end if;
  if not exists (select 1 from pg_constraint where conname = 'character_conditions_source_check') then
    alter table public.character_conditions add constraint character_conditions_source_check
      check (source in ('dm', 'player', 'combat', 'legacy_sheet'));
  end if;
end $$;
-- one Exhaustion per character and visibility (a DM-only Exhaustion from combat stays hidden next to a visible one)
create unique index if not exists character_conditions_one_exhaustion on public.character_conditions (character_id, hidden) where kind = 'exhaustion';

-- ---- helpers ------------------------------------------------------------------------------------------------------------
-- the text of one characters.conditions entry (strings; an object's name)
create or replace function public._condition_text(p jsonb)
returns text language sql immutable set search_path = public, pg_temp as $$
  select nullif(btrim(left(case jsonb_typeof(p) when 'string' then p #>> '{}' when 'object' then coalesce(p ->> 'name', '')
                                                when 'null' then '' else p #>> '{}' end, 80)), '')
$$;

-- what a free-text name means: an SRD condition, Exhaustion (with a level), Blessed / Cursed, or a free tag
create or replace function public._condition_parse(p_text text)
returns jsonb language sql stable set search_path = public, pg_temp as $$
  with t as (select lower(btrim(coalesce(p_text, ''))) as s, left(btrim(coalesce(p_text, '')), 80) as n)
  select case
    when t.s ~ '^(exhaustion|exhausted)( +(level +)?[1-6])?$' then
      jsonb_build_object('kind', 'exhaustion', 'condition_key', 'exhaustion', 'level', coalesce(substring(t.s from '([1-6])$')::int, 1), 'name', 'Exhaustion')
    when exists (select 1 from public.combat_conditions c where c.key = t.s and c.key <> 'exhaustion') then
      jsonb_build_object('kind', 'condition', 'condition_key', t.s, 'name', t.n)
    when t.s in ('blessed', 'bless') then jsonb_build_object('kind', 'tag', 'tag_type', 'blessing', 'name', t.n)
    when t.s in ('cursed', 'curse') then jsonb_build_object('kind', 'tag', 'tag_type', 'curse', 'name', t.n)
    else jsonb_build_object('kind', 'tag', 'tag_type', 'other', 'name', t.n) end
  from t
$$;

-- the characters.conditions entry of one row: a copied legacy entry verbatim, otherwise its name ("Exhaustion 2")
create or replace function public._condition_label(k public.character_conditions)
returns jsonb language sql immutable set search_path = public, pg_temp as $$
  select coalesce(k.legacy_value, to_jsonb(case when k.kind = 'exhaustion' then 'Exhaustion ' || k.level else k.name end))
$$;

-- the visible rows of one character, as the characters.conditions list
create or replace function public._conditions_visible(p_character uuid)
returns jsonb language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce(jsonb_agg(public._condition_label(k) order by k.applied_at, coalesce(k.legacy_pos, 0), k.id), '[]')
  from public.character_conditions k where k.character_id = p_character and not k.hidden
$$;

-- one visible row from a sheet entry (copy, old clients, import). A second Exhaustion becomes a free tag (nothing is lost).
create or replace function public._condition_insert(p_character uuid, p_value jsonb, p_source text, p_pos int)
returns uuid language plpgsql security definer set search_path = public, pg_temp as $$
declare t text := public._condition_text(p_value); p jsonb; i uuid;
begin
  if t is null then return null; end if;
  p := public._condition_parse(t);
  if p ->> 'kind' = 'exhaustion' and exists (select 1 from public.character_conditions
                                             where character_id = p_character and kind = 'exhaustion' and not hidden) then
    p := jsonb_build_object('kind', 'tag', 'tag_type', 'other', 'name', t);
  end if;
  insert into public.character_conditions (character_id, name, hidden, kind, condition_key, level, tag_type, source, legacy_value, legacy_pos)
  values (p_character, p ->> 'name', false, p ->> 'kind', p ->> 'condition_key', (p ->> 'level')::int, p ->> 'tag_type', p_source,
          p_value, p_pos)
  returning id into i;
  return i;
end $$;

-- ---- 2. copy of the sheet lists (idempotent; characters.conditions is only read) -----------------------------------------
do $$
declare c record; e record;
begin
  perform set_config('tl.cond_mirror', '1', true);   -- the mirror (created below, or present on a re-run) must not rewrite the source
  for c in select id, conditions from public.characters where jsonb_typeof(conditions) = 'array' and conditions <> '[]' order by id loop
    for e in select x, n::int as pos from jsonb_array_elements(c.conditions) with ordinality as a(x, n) loop
      continue when exists (select 1 from public.character_conditions k where k.character_id = c.id and k.source = 'legacy_sheet'
                            and k.legacy_pos = e.pos and k.legacy_value = e.x);
      perform public._condition_insert(c.id, e.x, 'legacy_sheet', e.pos);
    end loop;
  end loop;
  perform set_config('tl.cond_mirror', '', true);
end $$;

-- ---- 3. mirror: characters.conditions = the visible rows ------------------------------------------------------------------
create or replace function public._conditions_mirror()
returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
declare ids uuid[]; cid uuid; v jsonb;
begin
  if coalesce(current_setting('tl.cond_mirror', true), '') = '1' then return null; end if;
  -- a hidden-only change: nothing a player can see changed, so the characters row is not touched
  if tg_op = 'INSERT' then
    if new.hidden then return null; end if;
    ids := array[new.character_id];
  elsif tg_op = 'DELETE' then
    if old.hidden then return null; end if;
    ids := array[old.character_id];
  else
    if old.hidden and new.hidden and old.character_id = new.character_id then return null; end if;
    ids := array_remove(array[new.character_id, nullif(old.character_id, new.character_id)], null);
  end if;
  perform set_config('tl.cond_mirror', '1', true);
  foreach cid in array ids loop
    v := public._conditions_visible(cid);
    update public.characters set conditions = v where id = cid and conditions is distinct from v;
  end loop;
  perform set_config('tl.cond_mirror', '', true);
  return null;
end $$;
drop trigger if exists character_conditions_mirror on public.character_conditions;
create trigger character_conditions_mirror after insert or update or delete on public.character_conditions
  for each row execute function public._conditions_mirror();

-- ---- 4. compatibility: direct writes of characters.conditions (old clients, one release; import) --------------------------
-- BEFORE UPDATE, after characters_governance (triggers fire in name order, so the runtime.conditions gate raises first).
-- Removed entries delete only the sheet's own visible rows (player / legacy_sheet); DM, combat and hidden rows stay. The stored
-- list is then the mirror again (a DM entry an old client removed comes back).
create or replace function public._conditions_from_sheet()
returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
declare e record; t text; was text[]; now_ text[];
begin
  if coalesce(current_setting('tl.cond_mirror', true), '') = '1' then return new; end if;
  if jsonb_typeof(new.conditions) is distinct from 'array' then raise exception 'Conditions must be a list' using errcode = '22023'; end if;
  select coalesce(array_agg(lower(public._condition_text(x))) filter (where public._condition_text(x) is not null), '{}') into was
  from jsonb_array_elements(case when jsonb_typeof(old.conditions) = 'array' then old.conditions else '[]' end) x;
  select coalesce(array_agg(lower(public._condition_text(x))) filter (where public._condition_text(x) is not null), '{}') into now_
  from jsonb_array_elements(new.conditions) x;
  perform set_config('tl.cond_mirror', '1', true);
  delete from public.character_conditions k
  where k.character_id = new.id and not k.hidden and k.source in ('player', 'legacy_sheet')
    and lower(public._condition_text(public._condition_label(k))) = any (was)
    and not lower(public._condition_text(public._condition_label(k))) = any (now_);
  for e in select x, n::int as pos from jsonb_array_elements(new.conditions) with ordinality as a(x, n) loop
    t := lower(public._condition_text(e.x));
    continue when t is null or t = any (was);
    continue when exists (select 1 from public.character_conditions k where k.character_id = new.id and not k.hidden
                          and lower(public._condition_text(public._condition_label(k))) = t);
    perform public._condition_insert(new.id, e.x, 'player', e.pos);
  end loop;
  perform set_config('tl.cond_mirror', '', true);
  new.conditions := public._conditions_visible(new.id);
  return new;
end $$;
drop trigger if exists characters_legacy_conditions on public.characters;
create trigger characters_legacy_conditions before update of conditions on public.characters
  for each row when (old.conditions is distinct from new.conditions) execute function public._conditions_from_sheet();

-- a character created with a list (import): its entries become rows; the stored list stays as it was written
create or replace function public._conditions_from_new_sheet()
returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
declare e record;
begin
  perform set_config('tl.cond_mirror', '1', true);
  for e in select x, n::int as pos from jsonb_array_elements(new.conditions) with ordinality as a(x, n) loop
    perform public._condition_insert(new.id, e.x, 'player', e.pos);
  end loop;
  perform set_config('tl.cond_mirror', '', true);
  return null;
end $$;
drop trigger if exists characters_legacy_conditions_insert on public.characters;
create trigger characters_legacy_conditions_insert after insert on public.characters
  for each row when (jsonb_typeof(new.conditions) = 'array' and new.conditions <> '[]') execute function public._conditions_from_new_sheet();

-- ---- 5. RPCs -------------------------------------------------------------------------------------------------------------
-- the conditions the CALLER may see (players: visible only; DMs: all, with DM notes). Rule text = the SRD reminder of the
-- campaign's ruleset (2024 unless the campaign allows 2014 content only).
create or replace function public.get_character_conditions(p_character uuid)
returns jsonb
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
declare camp uuid; dm boolean; rs text;
begin
  if auth.uid() is null or not public.can_access_character(p_character) then raise exception 'Character not found' using errcode = '42501'; end if;
  select campaign_id into camp from public.characters where id = p_character;
  dm := public.is_admin() or (camp is not null and public.is_campaign_dm(camp));
  rs := coalesce((select case when not ('2024' = any (g.content_rulesets)) then '2014' end from public.campaign_governance g where g.campaign_id = camp), '2024');
  return (select coalesce(jsonb_agg(jsonb_build_object('id', k.id, 'name', k.name, 'note', k.note, 'expires_at', case when dm or not k.hidden then k.expires_at end,
             'applied_at', k.applied_at, 'revealed_at', k.revealed_at, 'custom', k.content_version_id is not null,
             'summary', (select summary from public.dm_content_versions where id = k.content_version_id),
             'player_text', (select player_text from public.dm_content_versions where id = k.content_version_id),
             'effects', (select definition -> 'effects' from public.dm_content_versions where id = k.content_version_id),
             'kind', k.kind, 'condition_key', k.condition_key, 'level', k.level, 'tag_type', k.tag_type,
             'damage_type_id', k.damage_type_id, 'damage_type', (select d.name from public.damage_types d where d.id = k.damage_type_id),
             'duration_text', k.duration_text, 'label', public._condition_text(public._condition_label(k)),
             'dm_applied', k.source in ('dm', 'combat'), 'from_combat', k.source = 'combat',
             'can_remove', dm or (not k.hidden and k.source in ('player', 'legacy_sheet')),
             'can_edit', dm or (not k.hidden and k.source in ('player', 'legacy_sheet')),
             'rule', (select c.summary from public.combat_conditions c where c.ruleset = rs and k.kind in ('condition', 'exhaustion') and c.key = k.condition_key),
             'rule_source', (select c.source_ref from public.combat_conditions c where c.ruleset = rs and k.kind in ('condition', 'exhaustion') and c.key = k.condition_key),
             'icon', (select c.icon from public.combat_conditions c where c.ruleset = rs and k.kind = 'condition' and c.key = k.condition_key),
             'hidden', case when dm then k.hidden end,
             'dm_note', case when dm then (select dm_note from public.character_condition_secrets where condition_id = k.id) end)
           order by k.applied_at, coalesce(k.legacy_pos, 0), k.id), '[]')
          from public.character_conditions k where k.character_id = p_character and (dm or not k.hidden));
end;
$$;

-- add a condition, Exhaustion or a tag. p_spec: {kind: condition|exhaustion|tag, condition_key, level, tag_type, damage_type_id,
-- name, note, duration_text, expires_at, hidden, dm_note}. Visible: runtime.conditions (players may add their own); hidden and
-- dm_note: the DM only. A second Exhaustion of the same visibility sets the level of the existing one.
create or replace function public.apply_character_effect(p_character uuid, p_spec jsonb)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare camp uuid; dm boolean; s jsonb := coalesce(p_spec, '{}'); hid boolean; kd text; ck text; lv int; tt text; dt text; nm text;
  nt text; du text; src text; ex public.character_conditions; cid uuid; dn text;
begin
  if auth.uid() is null or p_character is null or not public.can_access_character(p_character) then
    raise exception 'Character not found' using errcode = '42501';
  end if;
  if jsonb_typeof(s) <> 'object' then raise exception 'A condition is an object' using errcode = '22023'; end if;
  select campaign_id into camp from public.characters where id = p_character;
  dm := public.is_admin() or (camp is not null and public.is_campaign_dm(camp));
  hid := coalesce((s ->> 'hidden')::boolean, false);
  if hid or (s ? 'dm_note' and coalesce(btrim(s ->> 'dm_note'), '') <> '') then perform public._dm_hidden_gate(p_character);
  else perform public._gov_gate(p_character, 'runtime.conditions'); end if;
  kd := coalesce(nullif(s ->> 'kind', ''), 'condition');
  nt := nullif(btrim(coalesce(s ->> 'note', '')), '');
  du := nullif(btrim(coalesce(s ->> 'duration_text', '')), '');
  dn := nullif(btrim(coalesce(s ->> 'dm_note', '')), '');
  nm := nullif(btrim(coalesce(s ->> 'name', '')), '');
  if length(nt) > 500 then raise exception 'The note is at most 500 characters' using errcode = '22023'; end if;
  if length(du) > 80 then raise exception 'The duration is at most 80 characters' using errcode = '22023'; end if;
  if length(dn) > 2000 then raise exception 'The DM note is at most 2000 characters' using errcode = '22023'; end if;
  if length(nm) > 80 then raise exception 'The name is at most 80 characters' using errcode = '22023'; end if;
  src := case when not dm then 'player' when s ->> 'source' = 'combat' then 'combat' else 'dm' end;
  if kd = 'condition' then
    ck := lower(btrim(coalesce(s ->> 'condition_key', '')));
    if ck = 'exhaustion' then raise exception 'Exhaustion has a level: use kind exhaustion' using errcode = '22023'; end if;
    select coalesce(nm, c.name) into nm from public.combat_conditions c where c.key = ck order by c.ruleset desc limit 1;
    if not found then raise exception 'Unknown condition' using errcode = '22023'; end if;
  elsif kd = 'exhaustion' then
    lv := (s ->> 'level')::int;
    if lv is null or lv not between 1 and 6 then raise exception 'Exhaustion has a level from 1 to 6' using errcode = '22023'; end if;
    ck := 'exhaustion'; nm := 'Exhaustion';
  elsif kd = 'tag' then
    tt := coalesce(nullif(s ->> 'tag_type', ''), 'other');
    if tt not in ('resistance', 'immunity', 'vulnerability', 'condition_immunity', 'blessing', 'curse', 'other') then
      raise exception 'Unknown tag type' using errcode = '22023';
    end if;
    dt := nullif(s ->> 'damage_type_id', '');
    if dt is not null and tt not in ('resistance', 'immunity', 'vulnerability') then
      raise exception 'A damage type belongs to a resistance, an immunity or a vulnerability' using errcode = '22023';
    end if;
    if dt is not null and not exists (select 1 from public.damage_types where id = dt) then raise exception 'Unknown damage type' using errcode = '22023'; end if;
    if tt = 'condition_immunity' then
      ck := nullif(lower(btrim(coalesce(s ->> 'condition_key', ''))), '');
      if ck is not null and not exists (select 1 from public.combat_conditions where key = ck) then raise exception 'Unknown condition' using errcode = '22023'; end if;
    end if;
    nm := coalesce(nm, case tt when 'resistance' then 'Resistant' when 'immunity' then 'Immune' when 'vulnerability' then 'Vulnerable'
                               when 'condition_immunity' then 'Immune' when 'blessing' then 'Blessed' when 'curse' then 'Cursed' end
                       || coalesce(' to ' || lower((select name from public.damage_types where id = dt)), ' to ' || lower((select name from public.combat_conditions where key = ck limit 1)), ''));
    if nm is null then raise exception 'Name the tag' using errcode = '22023'; end if;
  else
    raise exception 'Unknown kind: condition, exhaustion or tag' using errcode = '22023';
  end if;
  perform 1 from public.characters where id = p_character for update;
  if kd = 'exhaustion' then
    select * into ex from public.character_conditions where character_id = p_character and kind = 'exhaustion' and hidden = hid for update;
    if ex.id is not null then
      if not dm and ex.source not in ('player', 'legacy_sheet') then raise exception 'Only the DM can change this condition' using errcode = '42501'; end if;
      -- the DM (or a carried combat effect) setting the level makes the row his: the player can no longer remove it
      update public.character_conditions set level = lv, legacy_value = null, note = coalesce(nt, note), duration_text = coalesce(du, duration_text),
        source = case when dm then src else source end
      where id = ex.id;
      cid := ex.id;
    end if;
  end if;
  if cid is null then
    insert into public.character_conditions (character_id, name, hidden, note, expires_at, kind, condition_key, level, tag_type, damage_type_id,
                                             duration_text, source)
    values (p_character, nm, hid, nt, (s ->> 'expires_at')::timestamptz, kd, ck, lv, tt, dt, du, src)
    returning id into cid;
  end if;
  if dn is not null then
    insert into public.character_condition_secrets (condition_id, dm_note) values (cid, dn)
    on conflict (condition_id) do update set dm_note = excluded.dm_note;
  end if;
  if camp is not null then
    perform public._audit(camp, p_character, case when hid then 'hidden_effect_added' else 'condition_added' end,
                          case when hid then 'Hidden condition: ' else 'Condition: ' end || nm || coalesce(' ' || lv, ''), null, null, null, null,
                          case when hid then 'dm' else 'party' end);
  end if;
  return public.get_character_conditions(p_character);
end $$;

-- change one row. p_patch: {level, note, duration_text, expires_at, name (tags), damage_type_id (tags), hidden, dm_note}.
-- A player changes only his own visible rows and never their visibility; the DM changes everything (hiding a visible row
-- removes it from the player's sheet; he may already have seen it).
create or replace function public.update_character_effect(p_condition uuid, p_patch jsonb)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare k public.character_conditions; camp uuid; dm boolean; p jsonb := coalesce(p_patch, '{}'); hid boolean; lv int; nt text; du text; nm text;
  dt text; relabel boolean := false;
begin
  select * into k from public.character_conditions where id = p_condition for update;
  if k.id is null or auth.uid() is null or not public.can_access_character(k.character_id) then raise exception 'Condition not found' using errcode = 'P0002'; end if;
  select campaign_id into camp from public.characters where id = k.character_id;
  dm := public.is_admin() or (camp is not null and public.is_campaign_dm(camp));
  if k.hidden and not dm then raise exception 'Condition not found' using errcode = 'P0002'; end if;
  if jsonb_typeof(p) <> 'object' then raise exception 'A change is an object' using errcode = '22023'; end if;
  if k.hidden or k.source not in ('player', 'legacy_sheet') or p ? 'hidden' or p ? 'dm_note' then perform public._dm_hidden_gate(k.character_id);
  else perform public._gov_gate(k.character_id, 'runtime.conditions'); end if;
  hid := coalesce((p ->> 'hidden')::boolean, k.hidden);
  lv := k.level;
  if p ? 'level' then
    if k.kind <> 'exhaustion' then raise exception 'Only Exhaustion has a level' using errcode = '22023'; end if;
    lv := (p ->> 'level')::int;
    if lv is null or lv not between 1 and 6 then raise exception 'Exhaustion has a level from 1 to 6' using errcode = '22023'; end if;
    relabel := relabel or lv is distinct from k.level;
  end if;
  nt := case when p ? 'note' then nullif(btrim(coalesce(p ->> 'note', '')), '') else k.note end;
  du := case when p ? 'duration_text' then nullif(btrim(coalesce(p ->> 'duration_text', '')), '') else k.duration_text end;
  nm := k.name; dt := k.damage_type_id;
  if p ? 'name' then
    if k.kind <> 'tag' then raise exception 'Only a tag can be renamed' using errcode = '22023'; end if;
    nm := nullif(btrim(coalesce(p ->> 'name', '')), '');
    if nm is null then raise exception 'Name the tag' using errcode = '22023'; end if;
    relabel := relabel or nm is distinct from k.name;
  end if;
  if p ? 'damage_type_id' then
    dt := nullif(p ->> 'damage_type_id', '');
    if dt is not null and (k.tag_type is null or k.tag_type not in ('resistance', 'immunity', 'vulnerability')) then
      raise exception 'A damage type belongs to a resistance, an immunity or a vulnerability' using errcode = '22023';
    end if;
    if dt is not null and not exists (select 1 from public.damage_types where id = dt) then raise exception 'Unknown damage type' using errcode = '22023'; end if;
  end if;
  if length(nt) > 500 then raise exception 'The note is at most 500 characters' using errcode = '22023'; end if;
  if length(du) > 80 then raise exception 'The duration is at most 80 characters' using errcode = '22023'; end if;
  if length(nm) > 80 then raise exception 'The name is at most 80 characters' using errcode = '22023'; end if;
  if k.kind = 'exhaustion' and hid <> k.hidden
     and exists (select 1 from public.character_conditions where character_id = k.character_id and kind = 'exhaustion' and hidden = hid) then
    raise exception 'The character already has an Exhaustion with that visibility: change its level instead' using errcode = '23505';
  end if;
  update public.character_conditions set level = lv, note = nt, duration_text = du, name = nm, damage_type_id = dt, hidden = hid,
    expires_at = case when p ? 'expires_at' then (p ->> 'expires_at')::timestamptz else expires_at end,
    revealed_at = case when k.hidden and not hid then now() else revealed_at end,
    legacy_value = case when relabel then null else legacy_value end
  where id = k.id;
  if dm and p ? 'dm_note' then
    if coalesce(btrim(p ->> 'dm_note'), '') = '' then delete from public.character_condition_secrets where condition_id = k.id;
    else
      if length(p ->> 'dm_note') > 2000 then raise exception 'The DM note is at most 2000 characters' using errcode = '22023'; end if;
      insert into public.character_condition_secrets (condition_id, dm_note) values (k.id, btrim(p ->> 'dm_note'))
      on conflict (condition_id) do update set dm_note = excluded.dm_note;
    end if;
  end if;
  if camp is not null then
    perform public._audit(camp, k.character_id,
      case when k.hidden and not hid then 'hidden_effect_revealed' when hid and not k.hidden then 'condition_hidden' else 'condition_changed' end,
      case when k.hidden and not hid then 'Revealed condition: ' when hid and not k.hidden then 'Condition hidden: ' else 'Condition changed: ' end
        || nm || case when k.kind = 'exhaustion' then ' ' || lv else '' end,
      null, null, null, null, case when hid then 'dm' else 'party' end);
  end if;
  return public.get_character_conditions(k.character_id);
end $$;

-- remove: hidden rows and rows the DM or a combat applied need the DM; a player removes his own (and copied sheet) rows
create or replace function public.remove_character_condition(p_condition uuid)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare k public.character_conditions; camp uuid;
begin
  select * into k from public.character_conditions where id = p_condition for update;
  if k.id is null or auth.uid() is null or not public.can_access_character(k.character_id) then raise exception 'Condition not found' using errcode = 'P0002'; end if;
  select campaign_id into camp from public.characters where id = k.character_id;
  if k.hidden and not (public.is_admin() or (camp is not null and public.is_campaign_dm(camp))) then
    raise exception 'Condition not found' using errcode = 'P0002';
  end if;
  if k.hidden or k.source not in ('player', 'legacy_sheet') then perform public._dm_hidden_gate(k.character_id);
  else perform public._gov_gate(k.character_id, 'runtime.conditions'); end if;
  delete from public.character_conditions where id = p_condition;
  if camp is not null then
    perform public._audit(camp, k.character_id, 'condition_removed', 'Condition removed: ' || k.name, null, null, null, null, case when k.hidden then 'dm' else 'party' end);
  end if;
  return public.get_character_conditions(k.character_id);
end;
$$;

-- the 6-argument form (DM Space, dm_assign_content): unchanged except that the row records who applied it and the SRD key
create or replace function public.apply_character_condition(p_character uuid, p_version uuid, p_name text, p_hidden boolean, p_expires timestamptz, p_note text)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare camp uuid; nm text := btrim(coalesce(p_name, '')); v public.dm_content_versions; c public.dm_content; cid uuid;
begin
  if auth.uid() is null or not public.can_access_character(p_character) then raise exception 'Character not found' using errcode = '42501'; end if;
  select campaign_id into camp from public.characters where id = p_character;
  if coalesce(p_hidden, false) then
    perform public._dm_hidden_gate(p_character);
  else
    perform public._gov_gate(p_character, 'runtime.conditions');
  end if;
  if p_version is not null then
    select * into v from public.dm_content_versions where id = p_version;
    select * into c from public.dm_content where id = v.content_id;
    if c.content_type <> 'condition' or v.status <> 'published' or c.campaign_id is distinct from camp then
      raise exception 'Unknown or unpublished condition' using errcode = '22023';
    end if;
    nm := coalesce(nullif(nm, ''), v.name);
  end if;
  if nm = '' then raise exception 'Name the condition' using errcode = '22023'; end if;
  perform 1 from public.characters where id = p_character for update;
  insert into public.character_conditions (character_id, content_version_id, name, hidden, note, expires_at, condition_key, source)
  values (p_character, p_version, left(nm, 80), coalesce(p_hidden, false), nullif(left(p_note, 500), ''), p_expires,
          case when p_version is null then (select k.key from public.combat_conditions k where k.key = lower(nm) and k.key <> 'exhaustion' limit 1) end,
          case when public.is_admin() or (camp is not null and public.is_campaign_dm(camp)) then 'dm' else 'player' end)
  returning id into cid;
  if camp is not null then
    perform public._audit(camp, p_character, case when coalesce(p_hidden, false) then 'hidden_effect_added' else 'condition_added' end,
                          case when coalesce(p_hidden, false) then 'Hidden condition: ' else 'Condition: ' end || nm, null, null, null, null,
                          case when coalesce(p_hidden, false) then 'dm' else 'party' end);
  end if;
  return public.get_character_conditions(p_character);
end;
$$;

-- combat_finish carry: what one lasting combat effect becomes on the sheet (Exhaustion keeps its level)
create or replace function public._combat_carry_spec(p_effect uuid, p_encounter_name text)
returns jsonb language sql stable security definer set search_path = public, pg_temp as $$
  select jsonb_build_object('hidden', x.visibility = 'dm', 'source', 'combat', 'note', left('From the encounter "' || coalesce(p_encounter_name, '') || '"', 500))
    || case
         when x.effect_type = 'condition' and (x.condition_key = 'exhaustion' or x.exhaustion_level is not null) then
           jsonb_build_object('kind', 'exhaustion', 'level', coalesce(x.exhaustion_level, 1))
         when x.effect_type = 'condition' and exists (select 1 from public.combat_conditions c where c.key = x.condition_key) then
           jsonb_build_object('kind', 'condition', 'condition_key', x.condition_key, 'name', left(btrim(x.display_name), 80))
         else jsonb_build_object('kind', 'tag', 'tag_type', 'other', 'name', left(btrim(x.display_name), 80)) end
  from public.combat_effects x where x.id = p_effect
$$;

-- ---- 6. the player read path: the caller's conditions as one more read of get_character_reads (not cached) --------------
-- body of 20261107000300 with one more read
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
          where id in (select ii.item_id from public.inventory_items ii where ii.inventory_id = inv and ii.item_id is not null)) ci));
  when 'revisions' then   -- latest revision (log id) per source table
    return (select coalesce(jsonb_object_agg(x.source_table, x.rev), '{}') from (
      select r2.source_table, max(r2.id) as rev from public.character_revisions r2 where r2.character_id = p_character group by 1) x);
  else
    raise exception 'Unknown read %', p_name using errcode = '22023';
  end case;
end $function$;

-- ---- 8. combat_finish: the carry keeps Exhaustion levels (body of 20261106000200, only the carry call changed) ------------
CREATE OR REPLACE FUNCTION public.combat_finish(p_encounter uuid, p_notes text DEFAULT NULL::text, p_decisions jsonb DEFAULT '{}'::jsonb, p_confirm boolean DEFAULT false, p_request uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare e public.combat_encounters := public._combat_auth(p_encounter, 'update'); r jsonb; lasting jsonb; l jsonb; d text; kept jsonb := '[]'; carried jsonb := '[]';
  summ jsonb; secs int; ev bigint;
begin
  r := public._combat_replay(e.id, p_request); if r is not null then return r; end if;
  if e.status not in ('active', 'paused') then raise exception 'Only a running or paused combat can be finished' using errcode = '22023'; end if;
  lasting := public._combat_lasting_effects(e.id);
  if jsonb_array_length(lasting) > 0 and not coalesce(p_confirm, false)
     and exists (select 1 from jsonb_array_elements(lasting) y where not coalesce(p_decisions, '{}') ? (y ->> 'id')) then
    return jsonb_build_object('needs_review', true, 'effects', lasting);
  end if;
  for l in select y from jsonb_array_elements(lasting) y loop
    d := coalesce(p_decisions ->> (l ->> 'id'), 'keep');
    if d = 'carry' and (l ->> 'can_carry')::boolean then
      -- 20261112000200: the sheet row keeps the kind, the SRD key and the Exhaustion level of the effect
      perform public.apply_character_effect((l ->> 'character_id')::uuid, public._combat_carry_spec((l ->> 'id')::uuid, e.name));
      update public.combat_effects set active = false, ended_at = now(), ended_reason = 'carried_to_sheet', rev = rev + 1 where id = (l ->> 'id')::uuid;
      carried := carried || l;
    elsif d = 'end' then
      update public.combat_effects set active = false, ended_at = now(), ended_reason = 'encounter_finished', rev = rev + 1 where id = (l ->> 'id')::uuid;
    else kept := kept || l; end if;
  end loop;
  -- every other effect is a combat effect: it ends with the fight
  update public.combat_effects set active = false, ended_at = now(), ended_reason = 'encounter_finished', rev = rev + 1
  where encounter_id = e.id and active and not (id = any (public._combat_ids(kept, 'id')));
  secs := e.active_seconds + case when e.status = 'active' and e.resumed_at is not null then extract(epoch from now() - e.resumed_at)::int else 0 end;
  summ := jsonb_build_object('duration_seconds', secs, 'rounds', e.round, 'ruleset', e.ruleset,
    'participants', (select coalesce(jsonb_agg(jsonb_build_object('id', p.id, 'name', p.display_name || coalesce(' ' || p.instance_label, ''), 'kind', p.kind,
        'hp', case when p.kind = 'monster' then p.hp_current else (select c.hp_current from public.characters c where c.id = p.linked_character_id) end,
        'max', case when p.kind = 'monster' then p.hp_max else (select (public._feat_hp_bonus(c.id) ->> 'max')::int from public.characters c where c.id = p.linked_character_id) end,
        'defeated', p.defeated, 'removed', p.removed_at is not null, 'hidden', p.hidden,
        'down', p.kind = 'character' and coalesce((select c.hp_current from public.characters c where c.id = p.linked_character_id), 1) <= 0)
        order by p.initiative_order nulls last), '[]') from public.combat_participants p where p.encounter_id = e.id),
    'effects_applied', (select count(*) from public.combat_effects where encounter_id = e.id),
    'conditions', (select coalesce(jsonb_agg(distinct display_name), '[]') from public.combat_effects where encounter_id = e.id and effect_type = 'condition'),
    'kept_effects', kept, 'carried_effects', carried,
    'damage_total', (select coalesce(sum((details ->> 'amount')::int), 0) from public.combat_events where encounter_id = e.id and kind = 'damage' and undone_by is null),
    'healing_total', (select coalesce(sum((details ->> 'amount')::int), 0) from public.combat_events where encounter_id = e.id and kind = 'heal' and undone_by is null),
    'major_events', (select coalesce(jsonb_agg(jsonb_build_object('kind', z.kind, 'round', z.round, 'participant', (select display_name || coalesce(' ' || instance_label, '')
                       from public.combat_participants where id = z.participant_id), 'amount', z.details -> 'amount') order by z.id), '[]')
                     from (select * from public.combat_events where encounter_id = e.id and undone_by is null
                           and kind in ('participant_defeat', 'concentration_failed', 'participant_revealed', 'participants_added', 'damage')
                           and (kind <> 'damage' or coalesce((details ->> 'amount')::int, 0) >= 10)
                           and (kind <> 'participants_added' or coalesce(round, 0) > 0)   -- joins during the fight, not the preparation
                           order by id desc limit 20) z));
  update public.combat_encounters set status = 'completed', completed_at = now(), active_seconds = secs, summary = summ,
    finish_notes = coalesce(left(p_notes, 8000), finish_notes), turn_rev = turn_rev + 1, rev = rev + 1, updated_at = now() where id = e.id;
  ev := public._combat_event(e.id, 'combat_finished', null, null, null, jsonb_build_object('kept', kept, 'carried', carried), p_request, false);
  perform public._combat_changed(e.id, 'encounter', 'finished', null, true);
  r := jsonb_build_object('encounter', public._combat_encounter_json((select x from public.combat_encounters x where x.id = e.id)), 'summary', summ);
  perform public._combat_set_result(ev, r);
  return r;
end $function$;

-- ---- 7. Realtime: a revision row for VISIBLE changes only ----------------------------------------------------------------
-- The fluent sheet refreshes its conditions on a character_revisions INSERT (source_table 'character_conditions'). A hidden-only
-- insert, update or delete writes no revision (players read character_revisions), so it leaves no timing trace on the sheet.
drop trigger if exists character_conditions_revision_ins on public.character_conditions;
drop trigger if exists character_conditions_revision_upd on public.character_conditions;
drop trigger if exists character_conditions_revision_del on public.character_conditions;
create trigger character_conditions_revision_ins after insert on public.character_conditions
  for each row when (not new.hidden) execute function public._bump_character_revision();
create trigger character_conditions_revision_upd after update on public.character_conditions
  for each row when (not old.hidden or not new.hidden) execute function public._bump_character_revision();
create trigger character_conditions_revision_del after delete on public.character_conditions
  for each row when (not old.hidden) execute function public._bump_character_revision();

-- no client subscribes to character_conditions; its DELETE events (not RLS-filtered) would carry the id of a removed hidden row
do $$
begin
  if exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'character_conditions') then
    alter publication supabase_realtime drop table public.character_conditions;
  end if;
end $$;

-- ---- grants --------------------------------------------------------------------------------------------------------------
revoke all on function public._condition_text(jsonb), public._condition_parse(text), public._condition_label(public.character_conditions),
  public._conditions_visible(uuid), public._condition_insert(uuid, jsonb, text, int), public._conditions_mirror(),
  public._conditions_from_sheet(), public._conditions_from_new_sheet(), public._combat_carry_spec(uuid, text)
  from public, anon, authenticated;
revoke all on function public.apply_character_effect(uuid, jsonb), public.update_character_effect(uuid, jsonb) from public, anon;
grant execute on function public.apply_character_effect(uuid, jsonb), public.update_character_effect(uuid, jsonb) to authenticated, service_role;

notify pgrst, 'reload schema';
