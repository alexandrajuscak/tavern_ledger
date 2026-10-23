-- =============================================================================
-- Hidden DM data (docs/HIDDEN_DM_DATA.md): secret character notes, character conditions (visible or hidden, timers, custom
-- condition definitions of 20261019000400), item knowledge (unidentified / partially identified / identified) with item
-- secrets and curses, reveal actions, and the DM-only campaign backup.
--
-- Rule: hidden data lives in rows a player's RLS never returns. Player read models and Realtime therefore cannot carry it
-- (Supabase Realtime evaluates the select policy per subscriber). An unidentified item's catalog row is hidden from the
-- player too (items.secret + _item_visible): the inventory row carries only the disguise the DM chose.
-- Rollback: supabase/rollback/rollback_hidden_dm_data.sql.
-- =============================================================================

-- ---- secret notes -------------------------------------------------------------------------------------------------------
create table public.dm_character_notes (
  id           uuid primary key default gen_random_uuid(),
  character_id uuid not null references public.characters (id) on delete cascade,
  campaign_id  uuid references public.campaigns (id) on delete cascade,
  author_id    uuid references public.profiles (id) on delete set null default auth.uid(),
  title        text not null check (length(title) between 1 and 120),
  body         text not null default '' check (length(body) <= 4000),
  reveal_note  text check (length(reveal_note) <= 1000),          -- what the player sees once revealed (null: the body)
  revealed_at  timestamptz,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);
create index dm_character_notes_character on public.dm_character_notes (character_id);

-- ---- character conditions ----------------------------------------------------------------------------------------------
create table public.character_conditions (
  id                 uuid primary key default gen_random_uuid(),
  character_id       uuid not null references public.characters (id) on delete cascade,
  content_version_id uuid references public.dm_content_versions (id) on delete restrict,   -- a custom condition definition
  name               text not null check (length(name) between 1 and 80),
  hidden             boolean not null default false,
  note               text check (length(note) <= 500),               -- shown to the player when visible
  expires_at         timestamptz,                                    -- a (possibly hidden) timer
  applied_by         uuid references public.profiles (id) on delete set null default auth.uid(),
  applied_at         timestamptz not null default now(),
  revealed_at        timestamptz
);
create index character_conditions_character on public.character_conditions (character_id);
create table public.character_condition_secrets (                    -- DM-only text of a condition (visible or hidden)
  condition_id uuid primary key references public.character_conditions (id) on delete cascade,
  dm_note      text not null check (length(dm_note) <= 2000)
);

-- ---- item knowledge and secrets ----------------------------------------------------------------------------------------
alter table public.items add column secret boolean not null default false;   -- some instance is (partially) unidentified

create table public.item_secrets (
  item_id                 text primary key references public.items (id) on delete cascade,
  unidentified_name       text check (length(unidentified_name) <= 80),
  unidentified_description text check (length(unidentified_description) <= 1000),
  curse                   text check (length(curse) <= 2000),
  properties              jsonb not null default '[]' check (jsonb_typeof(properties) = 'array'),   -- [{key, label, text}]
  updated_by              uuid references public.profiles (id) on delete set null,
  updated_at              timestamptz not null default now()
);

create table public.inventory_item_knowledge (
  inventory_item_id uuid primary key references public.inventory_items (id) on delete cascade,
  state             text not null default 'identified' check (state in ('unidentified', 'partially_identified', 'identified')),
  magic_known       boolean not null default false,       -- the DM told the player it is magical
  revealed          text[] not null default '{}',          -- revealed facts / property keys: magic, rarity, attunement, curse, <property key>
  true_name         text,                                  -- kept to restore the instance name on identification (DM-only via RLS of items)
  updated_by        uuid references public.profiles (id) on delete set null,
  updated_at        timestamptz not null default now()
);

-- items with an unidentified instance: visible to the DM, and to players only through an identified instance
create function public._item_visible(p_item text, p_owner uuid, p_campaign uuid, p_secret boolean)
returns boolean
language sql stable security definer
set search_path = public, pg_temp
as $$
  select public.can_view_owned(p_owner, p_campaign)
     and (not p_secret or public.can_edit_owned(p_owner, p_campaign) or public.is_admin()
          or (p_campaign is not null and public.is_campaign_dm(p_campaign))
          or exists (select 1 from public.inventory_items ii join public.inventory_item_knowledge k on k.inventory_item_id = ii.id
                     where ii.item_id = p_item and k.state = 'identified' and public.can_read_inventory(ii.inventory_id))
          or exists (select 1 from public.inventory_items ii where ii.item_id = p_item and public.can_read_inventory(ii.inventory_id)
                     and not exists (select 1 from public.inventory_item_knowledge k where k.inventory_item_id = ii.id)));
$$;
grant execute on function public._item_visible(text, uuid, uuid, boolean) to anon, authenticated;
drop policy "items_read" on public.items;
create policy "items_read" on public.items for select to anon, authenticated using (public._item_visible(id, owner_id, campaign_id, secret));
create or replace function public.can_view_item(p_item text)
returns boolean
language sql stable security definer
set search_path = public, pg_temp
as $$ select exists (select 1 from public.items i where i.id = p_item and public._item_visible(i.id, i.owner_id, i.campaign_id, i.secret)); $$;

-- secrets of a published custom item come from its definition ("hidden" part) when the version is published
create function public._dm_item_secrets_sync()
returns trigger
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare t text; h jsonb;
begin
  if new.status <> 'published' or new.catalog_ref is null or (tg_op = 'UPDATE' and old.status = 'published') then return new; end if;
  select content_type into t from public.dm_content where id = new.content_id;
  if t <> 'item' then return new; end if;
  h := coalesce(new.definition -> 'hidden', '{}');
  if h = '{}'::jsonb then return new; end if;
  insert into public.item_secrets (item_id, unidentified_name, unidentified_description, curse, properties, updated_by)
  values (new.catalog_ref, nullif(h ->> 'unidentified_name', ''), nullif(h ->> 'unidentified_description', ''), nullif(h ->> 'curse', ''),
          coalesce(h -> 'properties', '[]'), auth.uid())
  on conflict (item_id) do update set unidentified_name = excluded.unidentified_name, unidentified_description = excluded.unidentified_description,
    curse = excluded.curse, properties = excluded.properties, updated_by = excluded.updated_by, updated_at = now();
  return new;
end;
$$;
create trigger dm_content_versions_item_secrets after insert or update of status on public.dm_content_versions
  for each row execute function public._dm_item_secrets_sync();

-- add an item for the DM, optionally unidentified (replaces the plain version of 20261019000400)
create or replace function public._dm_add_item(p_inventory uuid, p_item text, p_quantity int, p_custom_name text, p_identified boolean, p_version uuid)
returns uuid
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare r uuid; s public.item_secrets; it public.items;
begin
  r := public.add_inventory_item(p_inventory, p_item, greatest(coalesce(p_quantity, 1), 1), p_custom_name);
  if not coalesce(p_identified, true) then
    select * into it from public.items where id = p_item;
    select * into s from public.item_secrets where item_id = p_item;
    insert into public.inventory_item_knowledge (inventory_item_id, state, true_name, updated_by) values (r, 'unidentified', it.name, auth.uid())
    on conflict (inventory_item_id) do update set state = 'unidentified', true_name = excluded.true_name, revealed = '{}', magic_known = false;
    update public.items set secret = true where id = p_item;
    update public.inventory_items set name = coalesce(s.unidentified_name, 'Unidentified ' || lower(coalesce((select name from public.item_kinds where id = it.kind_id), 'item'))),
      description = coalesce(s.unidentified_description, ''), custom_name = null where id = r;
  end if;
  return r;
end;
$$;

-- ---- DM operations ------------------------------------------------------------------------------------------------------
create function public._dm_hidden_gate(p_character uuid)
returns uuid
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
declare camp uuid;
begin
  select campaign_id into camp from public.characters where id = p_character;
  if auth.uid() is null or not (public.is_admin() or (camp is not null and public.is_campaign_dm(camp))) then
    raise exception 'Only the DM of the character''s campaign can see or change hidden information' using errcode = '42501';
  end if;
  return camp;
end;
$$;

create function public.save_dm_note(p_character uuid, p_title text, p_body text, p_note uuid default null, p_reveal_note text default null)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare camp uuid := public._dm_hidden_gate(p_character); nid uuid;
begin
  if coalesce(btrim(p_title), '') = '' then raise exception 'A note needs a title' using errcode = '22023'; end if;
  if p_note is null then
    insert into public.dm_character_notes (character_id, campaign_id, title, body, reveal_note)
    values (p_character, camp, left(btrim(p_title), 120), left(coalesce(p_body, ''), 4000), nullif(left(p_reveal_note, 1000), ''))
    returning id into nid;
    perform public._audit(camp, p_character, 'hidden_note_added', 'Hidden note added', null, null, null, null, 'dm');
  else
    update public.dm_character_notes set title = left(btrim(p_title), 120), body = left(coalesce(p_body, ''), 4000),
      reveal_note = nullif(left(p_reveal_note, 1000), ''), updated_at = now()
    where id = p_note and character_id = p_character returning id into nid;
    if nid is null then raise exception 'Note not found' using errcode = 'P0002'; end if;
  end if;
  return public.get_dm_character_hidden(p_character);
end;
$$;

create function public.delete_dm_note(p_note uuid)
returns void
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare cid uuid;
begin
  select character_id into cid from public.dm_character_notes where id = p_note;
  if cid is null then raise exception 'Note not found' using errcode = 'P0002'; end if;
  perform public._dm_hidden_gate(cid);
  delete from public.dm_character_notes where id = p_note;
end;
$$;

create function public.reveal_dm_note(p_note uuid)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare n public.dm_character_notes; camp uuid;
begin
  select * into n from public.dm_character_notes where id = p_note for update;
  if n.id is null then raise exception 'Note not found' using errcode = 'P0002'; end if;
  camp := public._dm_hidden_gate(n.character_id);
  update public.dm_character_notes set revealed_at = coalesce(revealed_at, now()) where id = p_note;
  perform public._audit(camp, n.character_id, 'hidden_note_revealed', 'Revealed: ' || n.title, null, null, null, null, 'party');
  return public.get_dm_character_hidden(n.character_id);
end;
$$;

-- conditions: visible ones may be applied by the player (runtime.conditions); hidden ones only by the DM
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
  insert into public.character_conditions (character_id, content_version_id, name, hidden, note, expires_at)
  values (p_character, p_version, left(nm, 80), coalesce(p_hidden, false), nullif(left(p_note, 500), ''), p_expires)
  returning id into cid;
  if camp is not null then
    perform public._audit(camp, p_character, case when coalesce(p_hidden, false) then 'hidden_effect_added' else 'condition_added' end,
                          case when coalesce(p_hidden, false) then 'Hidden condition: ' else 'Condition: ' end || nm, null, null, null, null,
                          case when coalesce(p_hidden, false) then 'dm' else 'party' end);
  end if;
  return public.get_character_conditions(p_character);
end;
$$;

create function public.remove_character_condition(p_condition uuid)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare k public.character_conditions; camp uuid;
begin
  select * into k from public.character_conditions where id = p_condition for update;
  if k.id is null or not public.can_access_character(k.character_id) then raise exception 'Condition not found' using errcode = 'P0002'; end if;
  if k.hidden then camp := public._dm_hidden_gate(k.character_id); else perform public._gov_gate(k.character_id, 'runtime.conditions'); end if;
  if not k.hidden and k.applied_by is distinct from auth.uid() and k.content_version_id is not null then
    perform public._gov_gate(k.character_id, 'runtime.conditions');
  end if;
  delete from public.character_conditions where id = p_condition;
  select campaign_id into camp from public.characters where id = k.character_id;
  if camp is not null then
    perform public._audit(camp, k.character_id, 'condition_removed', 'Condition removed: ' || k.name, null, null, null, null, case when k.hidden then 'dm' else 'party' end);
  end if;
  return public.get_character_conditions(k.character_id);
end;
$$;

create function public.reveal_character_condition(p_condition uuid)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare k public.character_conditions; camp uuid;
begin
  select * into k from public.character_conditions where id = p_condition for update;
  if k.id is null then raise exception 'Condition not found' using errcode = 'P0002'; end if;
  camp := public._dm_hidden_gate(k.character_id);
  update public.character_conditions set hidden = false, revealed_at = now() where id = p_condition;
  perform public._audit(camp, k.character_id, 'hidden_effect_revealed', 'Revealed condition: ' || k.name, null, null, null, null, 'party');
  return public.get_character_conditions(k.character_id);
end;
$$;

create function public.set_condition_dm_note(p_condition uuid, p_note text)
returns void
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare cid uuid;
begin
  select character_id into cid from public.character_conditions where id = p_condition;
  if cid is null then raise exception 'Condition not found' using errcode = 'P0002'; end if;
  perform public._dm_hidden_gate(cid);
  if coalesce(btrim(p_note), '') = '' then delete from public.character_condition_secrets where condition_id = p_condition;
  else insert into public.character_condition_secrets (condition_id, dm_note) values (p_condition, left(p_note, 2000))
       on conflict (condition_id) do update set dm_note = excluded.dm_note; end if;
end;
$$;

-- the conditions the CALLER may see (players: visible only; DMs: all, with DM notes)
create function public.get_character_conditions(p_character uuid)
returns jsonb
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
declare camp uuid; dm boolean;
begin
  if auth.uid() is null or not public.can_access_character(p_character) then raise exception 'Character not found' using errcode = '42501'; end if;
  select campaign_id into camp from public.characters where id = p_character;
  dm := public.is_admin() or (camp is not null and public.is_campaign_dm(camp));
  return (select coalesce(jsonb_agg(jsonb_build_object('id', k.id, 'name', k.name, 'note', k.note, 'expires_at', case when dm or not k.hidden then k.expires_at end,
             'applied_at', k.applied_at, 'revealed_at', k.revealed_at, 'custom', k.content_version_id is not null,
             'summary', (select summary from public.dm_content_versions where id = k.content_version_id),
             'player_text', (select player_text from public.dm_content_versions where id = k.content_version_id),
             'effects', (select definition -> 'effects' from public.dm_content_versions where id = k.content_version_id),
             'hidden', case when dm then k.hidden end,
             'dm_note', case when dm then (select dm_note from public.character_condition_secrets where condition_id = k.id) end)
           order by k.applied_at), '[]')
          from public.character_conditions k where k.character_id = p_character and (dm or not k.hidden));
end;
$$;

-- item knowledge: the DM decides what the player knows about one instance
create function public.set_item_knowledge(p_inventory_item uuid, p_state text, p_revealed text[] default null, p_magic_known boolean default null)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
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
    update public.items set secret = true where id = r.item_id;
    update public.inventory_items set name = coalesce(s.unidentified_name, 'Unidentified item'), description = coalesce(s.unidentified_description, '')
    where id = r.id and old_state = 'identified';
  end if;
  if camp is not null then
    perform public._audit(camp, inv.character_id, 'item_revealed',
                          'Item knowledge: ' || replace(old_state, '_', ' ') || ' → ' || replace(p_state, '_', ' '),
                          null, jsonb_build_object('revealed', to_jsonb(coalesce(p_revealed, '{}'))), null, null, 'party');
  end if;
  return public.get_character_item_knowledge(inv.character_id);
end;
$$;

create function public.set_item_secrets(p_item text, p_secrets jsonb)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare it public.items;
begin
  select * into it from public.items where id = p_item;
  if it.id is null or it.owner_id is null or auth.uid() is null
     or not (public.is_admin() or (it.campaign_id is not null and public.is_campaign_dm(it.campaign_id))) then
    raise exception 'Only the DM of the item''s campaign can set its secrets' using errcode = '42501';
  end if;
  insert into public.item_secrets (item_id, unidentified_name, unidentified_description, curse, properties, updated_by)
  values (p_item, nullif(p_secrets ->> 'unidentified_name', ''), nullif(p_secrets ->> 'unidentified_description', ''), nullif(p_secrets ->> 'curse', ''),
          coalesce(p_secrets -> 'properties', '[]'), auth.uid())
  on conflict (item_id) do update set unidentified_name = excluded.unidentified_name, unidentified_description = excluded.unidentified_description,
    curse = excluded.curse, properties = excluded.properties, updated_by = excluded.updated_by, updated_at = now();
  return (select to_jsonb(s) from public.item_secrets s where s.item_id = p_item);
end;
$$;

-- what the caller knows about the items of a character (players: the disguise + revealed facts only)
create function public.get_character_item_knowledge(p_character uuid)
returns jsonb
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
declare camp uuid; dm boolean;
begin
  if auth.uid() is null or not public.can_access_character(p_character) then raise exception 'Character not found' using errcode = '42501'; end if;
  select campaign_id into camp from public.characters where id = p_character;
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
             'true_name', case when dm then coalesce(k.true_name, it.name) end, 'item_id', case when dm or k.state = 'identified' then it.id end)
           order by ii.name), '[]')
          from public.inventories inv join public.inventory_items ii on ii.inventory_id = inv.id
          join public.inventory_item_knowledge k on k.inventory_item_id = ii.id
          left join public.items it on it.id = ii.item_id
          left join public.item_secrets s on s.item_id = ii.item_id
          where inv.character_id = p_character);
end;
$$;

-- the DM view of everything hidden on one character
create function public.get_dm_character_hidden(p_character uuid)
returns jsonb
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
begin
  perform public._dm_hidden_gate(p_character);
  return jsonb_build_object('character_id', p_character,
    'notes', (select coalesce(jsonb_agg(to_jsonb(n) order by n.created_at desc), '[]') from public.dm_character_notes n where n.character_id = p_character),
    'conditions', public.get_character_conditions(p_character),
    'items', public.get_character_item_knowledge(p_character),
    'item_secrets', (select coalesce(jsonb_agg(to_jsonb(s)), '[]') from public.item_secrets s
                     where s.item_id in (select ii.item_id from public.inventories inv join public.inventory_items ii on ii.inventory_id = inv.id
                                         where inv.character_id = p_character)));
end;
$$;

-- revealed notes for the player
create function public.get_character_revealed_notes(p_character uuid)
returns jsonb
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
begin
  if auth.uid() is null or not public.can_access_character(p_character) then raise exception 'Character not found' using errcode = '42501'; end if;
  return (select coalesce(jsonb_agg(jsonb_build_object('id', n.id, 'title', n.title, 'text', coalesce(n.reveal_note, n.body), 'revealed_at', n.revealed_at)
           order by n.revealed_at desc), '[]')
          from public.dm_character_notes n where n.character_id = p_character and n.revealed_at is not null);
end;
$$;

-- DM-only campaign backup (hidden data included). The player character export never calls this.
create function public.export_campaign_dm_backup(p_campaign uuid)
returns jsonb
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
begin
  if auth.uid() is null or not (public.is_admin() or public.is_campaign_dm(p_campaign)) then
    raise exception 'Only a DM of the campaign can export its DM backup' using errcode = '42501';
  end if;
  return jsonb_build_object('format', 'tavern-ledger-dm-backup', 'version', 1, 'exported_at', now(),
    'campaign', (select to_jsonb(c) from public.campaigns c where c.id = p_campaign),
    'governance', public._campaign_governance_json(p_campaign) - 'actions',
    'content', (select coalesce(jsonb_agg(public._dm_content_json(d.id)), '[]') from public.dm_content d where d.campaign_id = p_campaign),
    'hidden', (select coalesce(jsonb_agg(public.get_dm_character_hidden(ch.id)), '[]') from public.characters ch where ch.campaign_id = p_campaign),
    'locks', (select coalesce(jsonb_agg(to_jsonb(g)), '[]') from public.character_governance g join public.characters ch on ch.id = g.character_id
              where ch.campaign_id = p_campaign));
end;
$$;

-- ---- RLS, Realtime ------------------------------------------------------------------------------------------------------
alter table public.dm_character_notes enable row level security;
alter table public.character_conditions enable row level security;
alter table public.character_condition_secrets enable row level security;
alter table public.item_secrets enable row level security;
alter table public.inventory_item_knowledge enable row level security;
revoke all on public.dm_character_notes, public.character_conditions, public.character_condition_secrets, public.item_secrets,
  public.inventory_item_knowledge from anon, authenticated;
create policy "dm_character_notes_dm" on public.dm_character_notes for select to authenticated
  using (public.is_admin() or (campaign_id is not null and public.is_campaign_dm(campaign_id)));
create policy "dm_character_notes_revealed" on public.dm_character_notes for select to authenticated
  using (revealed_at is not null and public.can_access_character(character_id));
create policy "character_conditions_read" on public.character_conditions for select to authenticated
  using (public.can_access_character(character_id)
         and (not hidden or public.is_admin()
              or exists (select 1 from public.characters c where c.id = character_id and c.campaign_id is not null and public.is_campaign_dm(c.campaign_id))));
create policy "character_condition_secrets_dm" on public.character_condition_secrets for select to authenticated
  using (exists (select 1 from public.character_conditions k join public.characters c on c.id = k.character_id
                 where k.id = condition_id and (public.is_admin() or (c.campaign_id is not null and public.is_campaign_dm(c.campaign_id)))));
create policy "item_secrets_dm" on public.item_secrets for select to authenticated
  using (exists (select 1 from public.items i where i.id = item_id and (public.is_admin() or (i.campaign_id is not null and public.is_campaign_dm(i.campaign_id)))));
create policy "inventory_item_knowledge_read" on public.inventory_item_knowledge for select to authenticated
  using (exists (select 1 from public.inventory_items ii where ii.id = inventory_item_id and public.can_read_inventory(ii.inventory_id)));
grant select on public.dm_character_notes, public.character_conditions, public.character_condition_secrets, public.item_secrets,
  public.inventory_item_knowledge to authenticated;
-- inventory_item_knowledge.true_name is DM information: players read knowledge through get_character_item_knowledge only
revoke select on public.inventory_item_knowledge from authenticated;
grant select (inventory_item_id, state, magic_known, revealed, updated_at) on public.inventory_item_knowledge to authenticated;

do $$
declare t text;
begin
  foreach t in array array['character_conditions'] loop
    execute format('alter table public.%I replica identity full', t);
    if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t) then
      execute format('alter publication supabase_realtime add table public.%I', t);
    end if;
  end loop;
end $$;

revoke all on function public._dm_hidden_gate(uuid), public._dm_item_secrets_sync() from public, anon, authenticated;
revoke all on function public.save_dm_note(uuid, text, text, uuid, text), public.delete_dm_note(uuid), public.reveal_dm_note(uuid),
  public.apply_character_condition(uuid, uuid, text, boolean, timestamptz, text), public.remove_character_condition(uuid),
  public.reveal_character_condition(uuid), public.set_condition_dm_note(uuid, text), public.get_character_conditions(uuid),
  public.set_item_knowledge(uuid, text, text[], boolean), public.set_item_secrets(text, jsonb), public.get_character_item_knowledge(uuid),
  public.get_dm_character_hidden(uuid), public.get_character_revealed_notes(uuid), public.export_campaign_dm_backup(uuid)
  from public, anon;
grant execute on function public.save_dm_note(uuid, text, text, uuid, text), public.delete_dm_note(uuid), public.reveal_dm_note(uuid),
  public.apply_character_condition(uuid, uuid, text, boolean, timestamptz, text), public.remove_character_condition(uuid),
  public.reveal_character_condition(uuid), public.set_condition_dm_note(uuid, text), public.get_character_conditions(uuid),
  public.set_item_knowledge(uuid, text, text[], boolean), public.set_item_secrets(text, jsonb), public.get_character_item_knowledge(uuid),
  public.get_dm_character_hidden(uuid), public.get_character_revealed_notes(uuid), public.export_campaign_dm_backup(uuid)
  to authenticated;
