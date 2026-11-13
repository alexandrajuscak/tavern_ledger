-- Quest log (docs/QUEST_LOG.md). Additive; rollback supabase/rollback/rollback_quest_log.sql.
--
-- 1. Tables (campaign-scoped, NO grants for anon / authenticated: no REST, no Realtime; every read and write is an RPC below):
--    * quests: title, description, status (active / completed / failed), visibility, target character, DM sort order,
--      soft archive (archived_at; a quest is never deleted by the app).
--        visibility 'party'      -> every character of the campaign sees it (no target);
--                   'individual' -> assigned to one character, the rest of the party sees it too;
--                   'private'    -> only the DM and that one character (its owner) see it.
--      The target column is deliberately NOT named character_id: the cache coverage rule would then require
--      tl_cache.bump('character'), and a party quest (no target) would bump the GLOBAL counter on every edit (the 57014
--      pattern). Target FK: on delete set null (deleting a character is never blocked); a non-party quest without a target is
--      shown to the DM only ("character deleted").
--    * quest_objectives: the DM's checklist (done / done_at / done_by); removed objectives are archived, never deleted.
--    * quest_dm_notes: the DM's hidden notes, a separate table read ONLY by the DM read get_campaign_quests.
-- 2. Reads:
--    * get_character_quests(character): ONE small request when the player opens the Quests tab. The caller must be allowed to
--      open the character (can_access_character: owner, DM of its campaign, admin) and always gets the PLAYER view of that
--      character, whoever calls: quests of the character's CURRENT campaign, not archived, that are party, individual (target
--      still in that campaign) or private to exactly this character. It never selects quest_dm_notes. A character without a
--      campaign gets an empty list; a character moved to another campaign sees only that campaign's quests.
--    * get_campaign_quests(campaign, include_archived): DM of the campaign / admin only; includes DM notes and the campaign's
--      characters for the target picker.
-- 3. Writes (DM of the quest's campaign or admin; 42501 otherwise): dm_save_quest (create / edit incl. objectives and notes,
--    optional expected revision), dm_set_quest_status, dm_set_quest_objective (tick), dm_archive_quest (archive / restore),
--    dm_reorder_quests. Players cannot tick objectives (owner decision default: DM only).
-- 4. Cache: tl_cache.skip() on all three tables (justified like the crafting recipe tables): the quest reads are never part of
--    get_character_reads' cacheable list and never go through tl_cache, so no cached value depends on them. No
--    character_revisions row either (a new source_table would make a ?v=31 sheet throw in onRemote / reconcile); the player
--    tab re-reads on every open and on its Refresh button.
set lock_timeout = '5s';

-- ---- 1. tables -----------------------------------------------------------------------------------------------------------------
create table public.quests (
  id                  uuid primary key default gen_random_uuid(),
  campaign_id         uuid not null references public.campaigns (id) on delete cascade,
  title               text not null check (length(btrim(title)) between 1 and 120),
  description         text not null default '' check (length(description) <= 4000),
  status              text not null default 'active' check (status in ('active', 'completed', 'failed')),
  visibility          text not null default 'party' check (visibility in ('party', 'individual', 'private')),
  target_character_id uuid references public.characters (id) on delete set null,
  sort_order          int not null default 0,
  archived_at         timestamptz,
  archived_by         uuid references public.profiles (id) on delete set null,
  revision            int not null default 1,
  created_by          uuid references public.profiles (id) on delete set null default auth.uid(),
  updated_by          uuid references public.profiles (id) on delete set null,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  check (visibility <> 'party' or target_character_id is null)    -- a party quest has no target
);
create index quests_campaign on public.quests (campaign_id, status, sort_order) where archived_at is null;
create index quests_target on public.quests (target_character_id) where target_character_id is not null;

create table public.quest_objectives (
  id          uuid primary key default gen_random_uuid(),
  quest_id    uuid not null references public.quests (id) on delete cascade,
  seq         int not null default 0,
  body        text not null check (length(btrim(body)) between 1 and 300),
  done        boolean not null default false,
  done_at     timestamptz,
  done_by     uuid references public.profiles (id) on delete set null,
  archived_at timestamptz,
  created_at  timestamptz not null default now()
);
create index quest_objectives_quest on public.quest_objectives (quest_id, seq) where archived_at is null;

create table public.quest_dm_notes (
  quest_id   uuid primary key references public.quests (id) on delete cascade,
  body       text not null default '' check (length(body) <= 4000),
  updated_by uuid references public.profiles (id) on delete set null,
  updated_at timestamptz not null default now()
);

alter table public.quests enable row level security;
alter table public.quest_objectives enable row level security;
alter table public.quest_dm_notes enable row level security;
revoke all on public.quests, public.quest_objectives, public.quest_dm_notes from public, anon, authenticated;

-- cache counters: no cached read reads these tables (see the header) -> nothing to invalidate
create trigger tl_cache_rev after insert or update or delete on public.quests
  for each row execute function tl_cache.skip();
create trigger tl_cache_rev after insert or update or delete on public.quest_objectives
  for each row execute function tl_cache.skip();
create trigger tl_cache_rev after insert or update or delete on public.quest_dm_notes
  for each row execute function tl_cache.skip();

-- ---- 2. helpers ----------------------------------------------------------------------------------------------------------------
create function public._quest_dm_gate(p_campaign uuid)
returns void
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
begin
  if auth.uid() is null or p_campaign is null or not (public.is_admin() or public.is_campaign_dm(p_campaign)) then
    raise exception 'Only the DM of the campaign can manage quests' using errcode = '42501';
  end if;
end $$;

-- active first, then completed, then failed
create function public._quest_status_rank(p_status text)
returns int language sql immutable set search_path = public, pg_temp as $$
  select case p_status when 'active' then 0 when 'completed' then 1 else 2 end;
$$;

-- the objectives of a quest that are not archived, in the DM's order (shared by the player and the DM read: no hidden field)
create function public._quest_objectives_json(p_quest uuid)
returns jsonb
language sql stable security definer
set search_path = public, pg_temp
as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', o.id, 'text', o.body, 'done', o.done, 'done_at', o.done_at)
                            order by o.seq, o.created_at, o.id), '[]'::jsonb)
  from public.quest_objectives o where o.quest_id = p_quest and o.archived_at is null;
$$;

-- the DM view of one quest (with notes)
create function public._quest_dm_json(p_quest uuid)
returns jsonb
language sql stable security definer
set search_path = public, pg_temp
as $$
  select jsonb_build_object('id', q.id, 'campaign_id', q.campaign_id, 'title', q.title, 'description', q.description,
    'status', q.status, 'visibility', q.visibility, 'target_character_id', q.target_character_id,
    'target_name', c.name, 'target_in_campaign', c.id is not null and c.campaign_id = q.campaign_id,
    'sort_order', q.sort_order, 'archived_at', q.archived_at, 'revision', q.revision, 'updated_at', q.updated_at,
    'dm_notes', coalesce(n.body, ''), 'objectives', public._quest_objectives_json(q.id))
  from public.quests q
  left join public.characters c on c.id = q.target_character_id
  left join public.quest_dm_notes n on n.quest_id = q.id
  where q.id = p_quest;
$$;

-- ---- 3. player read --------------------------------------------------------------------------------------------------------------
-- The Quests tab of one character: ONE request, opened lazily. Never contains DM notes, archived quests, quests of another
-- campaign, or another character's private quests, whoever calls (the DM viewing a sheet gets that character's player view).
create function public.get_character_quests(p_character uuid)
returns jsonb
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
declare camp uuid;
begin
  if auth.uid() is null or p_character is null or not public.can_access_character(p_character) then
    raise exception 'Character not found' using errcode = '42501';
  end if;
  select c.campaign_id into camp from public.characters c where c.id = p_character;
  return jsonb_build_object('character_id', p_character, 'campaign_id', camp, 'quests', coalesce((
    select jsonb_agg(jsonb_build_object('id', q.id, 'title', q.title, 'description', q.description, 'status', q.status,
             'visibility', q.visibility, 'mine', coalesce(q.target_character_id = p_character, false),
             'target_name', case when q.visibility = 'party' then null else t.name end,
             'updated_at', q.updated_at, 'objectives', public._quest_objectives_json(q.id))
           order by public._quest_status_rank(q.status), q.sort_order, q.created_at, q.id)
    from public.quests q
    left join public.characters t on t.id = q.target_character_id
    where camp is not null and q.campaign_id = camp and q.archived_at is null
      and (q.visibility = 'party'
           or (q.visibility = 'individual' and t.campaign_id = camp)
           or (q.visibility = 'private' and q.target_character_id = p_character))), '[]'::jsonb));
end $$;

-- ---- 4. DM read ------------------------------------------------------------------------------------------------------------------
create function public.get_campaign_quests(p_campaign uuid, p_include_archived boolean default false)
returns jsonb
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
begin
  perform public._quest_dm_gate(p_campaign);
  return jsonb_build_object('campaign_id', p_campaign,
    'quests', coalesce((select jsonb_agg(public._quest_dm_json(q.id)
                                         order by (q.archived_at is not null), public._quest_status_rank(q.status), q.sort_order, q.created_at, q.id)
                        from public.quests q
                        where q.campaign_id = p_campaign and (p_include_archived or q.archived_at is null)), '[]'::jsonb),
    'characters', coalesce((select jsonb_agg(jsonb_build_object('id', c.id, 'name', c.name) order by c.name, c.id)
                            from public.characters c where c.campaign_id = p_campaign), '[]'::jsonb));
end $$;

-- ---- 5. DM writes ----------------------------------------------------------------------------------------------------------------
-- Create (p_quest.id null) or edit a quest. Keys: title, description, status, visibility, target_character_id, dm_notes,
-- objectives [{id?, text, done?}] (the full list in order; listed rows are kept / updated, missing ones are archived).
-- A key that is absent keeps the stored value (on create: the default). p_expected_revision: refuse a stale edit (40001).
create function public.dm_save_quest(p_campaign uuid, p_quest jsonb, p_expected_revision int default null)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare q public.quests; qid uuid; v_title text; v_desc text; v_status text; v_vis text; v_target uuid; o jsonb; i int := 0;
  oid uuid; otext text; odone boolean; keep uuid[] := '{}';
begin
  perform public._quest_dm_gate(p_campaign);
  if p_quest is null or jsonb_typeof(p_quest) <> 'object' then raise exception 'Quest data missing' using errcode = '22023'; end if;
  qid := nullif(p_quest ->> 'id', '')::uuid;
  if qid is not null then
    select * into q from public.quests where id = qid for update;
    if q.id is null or q.campaign_id <> p_campaign then raise exception 'Quest not found' using errcode = 'P0002'; end if;
    if p_expected_revision is not null and p_expected_revision <> q.revision then
      raise exception 'This quest was changed meanwhile. Reload and try again.' using errcode = '40001';
    end if;
  end if;
  v_title := btrim(coalesce(case when p_quest ? 'title' then p_quest ->> 'title' end, q.title, ''));
  v_desc := coalesce(case when p_quest ? 'description' then p_quest ->> 'description' end, q.description, '');
  v_status := coalesce(case when p_quest ? 'status' then p_quest ->> 'status' end, q.status, 'active');
  v_vis := coalesce(case when p_quest ? 'visibility' then p_quest ->> 'visibility' end, q.visibility, 'party');
  v_target := case when p_quest ? 'target_character_id' then nullif(p_quest ->> 'target_character_id', '')::uuid else q.target_character_id end;
  if length(v_title) not between 1 and 120 then raise exception 'A quest needs a title (at most 120 characters)' using errcode = '22023'; end if;
  if length(v_desc) > 4000 then raise exception 'The description is too long (at most 4000 characters)' using errcode = '22023'; end if;
  if v_status not in ('active', 'completed', 'failed') then raise exception 'Unknown status' using errcode = '22023'; end if;
  if v_vis not in ('party', 'individual', 'private') then raise exception 'Unknown visibility' using errcode = '22023'; end if;
  if v_vis = 'party' then
    v_target := null;
  elsif v_target is null then
    raise exception 'Choose the character this quest belongs to' using errcode = '22023';
  elsif v_target is distinct from q.target_character_id
        and not exists (select 1 from public.characters c where c.id = v_target and c.campaign_id = p_campaign) then
    raise exception 'That character is not in this campaign' using errcode = '22023';
  end if;
  if p_quest ? 'dm_notes' and length(coalesce(p_quest ->> 'dm_notes', '')) > 4000 then
    raise exception 'The DM notes are too long (at most 4000 characters)' using errcode = '22023';
  end if;
  if p_quest ? 'objectives' and (jsonb_typeof(p_quest -> 'objectives') <> 'array' or jsonb_array_length(p_quest -> 'objectives') > 30) then
    raise exception 'At most 30 objectives' using errcode = '22023';
  end if;

  if qid is null then
    insert into public.quests (campaign_id, title, description, status, visibility, target_character_id, sort_order, updated_by)
    values (p_campaign, v_title, v_desc, v_status, v_vis, v_target,
            coalesce((select max(x.sort_order) + 10 from public.quests x where x.campaign_id = p_campaign), 10), auth.uid())
    returning * into q;
  elsif (v_title, v_desc, v_status, v_vis, v_target) is distinct from (q.title, q.description, q.status, q.visibility, q.target_character_id) then
    update public.quests set title = v_title, description = v_desc, status = v_status, visibility = v_vis, target_character_id = v_target,
      revision = revision + 1, updated_by = auth.uid(), updated_at = now()
    where id = q.id returning * into q;
  end if;

  if p_quest ? 'dm_notes' then
    insert into public.quest_dm_notes as n (quest_id, body, updated_by) values (q.id, coalesce(p_quest ->> 'dm_notes', ''), auth.uid())
    on conflict (quest_id) do update set body = excluded.body, updated_by = excluded.updated_by, updated_at = now()
      where n.body is distinct from excluded.body;
  end if;

  if p_quest ? 'objectives' then
    for o in select value from jsonb_array_elements(p_quest -> 'objectives') loop
      i := i + 1;
      oid := nullif(o ->> 'id', '')::uuid;
      otext := btrim(coalesce(o ->> 'text', ''));
      odone := coalesce((o ->> 'done')::boolean, false);
      if length(otext) not between 1 and 300 then raise exception 'Objective % needs a text (at most 300 characters)', i using errcode = '22023'; end if;
      if oid is not null and exists (select 1 from public.quest_objectives x where x.id = oid and x.quest_id = q.id) then
        update public.quest_objectives set seq = i, body = otext, archived_at = null,
          done = case when o ? 'done' then odone else done end,
          done_at = case when o ? 'done' and odone and not done then now() when o ? 'done' and not odone then null else done_at end,
          done_by = case when o ? 'done' and odone and not done then auth.uid() when o ? 'done' and not odone then null else done_by end
        where id = oid and (seq, body, archived_at, done) is distinct from (i, otext, null::timestamptz, case when o ? 'done' then odone else done end);
      else
        insert into public.quest_objectives (quest_id, seq, body, done, done_at, done_by)
        values (q.id, i, otext, odone, case when odone then now() end, case when odone then auth.uid() end)
        returning id into oid;
      end if;
      keep := keep || oid;
    end loop;
    update public.quest_objectives set archived_at = now()
    where quest_id = q.id and archived_at is null and not (id = any (keep));
  end if;
  return public._quest_dm_json(q.id);
end $$;

create function public.dm_set_quest_status(p_quest uuid, p_status text)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare q public.quests;
begin
  select * into q from public.quests where id = p_quest for update;
  if q.id is null then raise exception 'Quest not found' using errcode = 'P0002'; end if;
  perform public._quest_dm_gate(q.campaign_id);
  if p_status is null or p_status not in ('active', 'completed', 'failed') then raise exception 'Unknown status' using errcode = '22023'; end if;
  if q.status <> p_status then
    update public.quests set status = p_status, revision = revision + 1, updated_by = auth.uid(), updated_at = now() where id = q.id;
  end if;
  return public._quest_dm_json(q.id);
end $$;

-- tick / untick one objective (DM only; players see the result on their next read)
create function public.dm_set_quest_objective(p_objective uuid, p_done boolean)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare o public.quest_objectives; q public.quests;
begin
  select * into o from public.quest_objectives where id = p_objective;
  if o.id is null then raise exception 'Objective not found' using errcode = 'P0002'; end if;
  select * into q from public.quests where id = o.quest_id for update;
  perform public._quest_dm_gate(q.campaign_id);
  if p_done is null then raise exception 'Done or not done?' using errcode = '22023'; end if;
  update public.quest_objectives set done = p_done, done_at = case when p_done then now() end, done_by = case when p_done then auth.uid() end
  where id = o.id and done is distinct from p_done;
  if found then
    update public.quests set revision = revision + 1, updated_by = auth.uid(), updated_at = now() where id = q.id;
  end if;
  return public._quest_dm_json(q.id);
end $$;

-- archive (soft delete) or restore; nothing is ever deleted
create function public.dm_archive_quest(p_quest uuid, p_archived boolean default true)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare q public.quests;
begin
  select * into q from public.quests where id = p_quest for update;
  if q.id is null then raise exception 'Quest not found' using errcode = 'P0002'; end if;
  perform public._quest_dm_gate(q.campaign_id);
  if coalesce(p_archived, true) and q.archived_at is null then
    update public.quests set archived_at = now(), archived_by = auth.uid(), revision = revision + 1, updated_by = auth.uid(), updated_at = now()
    where id = q.id;
  elsif not coalesce(p_archived, true) and q.archived_at is not null then
    update public.quests set archived_at = null, archived_by = null, revision = revision + 1, updated_by = auth.uid(), updated_at = now(),
      sort_order = coalesce((select max(x.sort_order) + 10 from public.quests x where x.campaign_id = q.campaign_id), 10)
    where id = q.id;
  end if;
  return public._quest_dm_json(q.id);
end $$;

-- the DM's order: the listed quests (all of this campaign) get increasing sort orders in the given order; others keep theirs.
-- The players' list orders by status first, so reordering inside one status is what the DM Space offers.
create function public.dm_reorder_quests(p_campaign uuid, p_quests uuid[])
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare n int;
begin
  perform public._quest_dm_gate(p_campaign);
  if coalesce(cardinality(p_quests), 0) = 0 or cardinality(p_quests) > 500 then raise exception 'Between 1 and 500 quests' using errcode = '22023'; end if;
  if cardinality(p_quests) <> (select count(distinct x) from unnest(p_quests) x) then raise exception 'A quest is listed twice' using errcode = '22023'; end if;
  perform 1 from public.quests q where q.id = any (p_quests) order by q.id for update;
  select count(*) into n from public.quests q where q.id = any (p_quests) and q.campaign_id = p_campaign;
  if n <> cardinality(p_quests) then raise exception 'Quest not found' using errcode = 'P0002'; end if;
  update public.quests q set sort_order = x.ord * 10, revision = q.revision + 1, updated_by = auth.uid(), updated_at = now()
  from unnest(p_quests) with ordinality as x(id, ord)
  where q.id = x.id and q.sort_order is distinct from x.ord * 10;
  return jsonb_build_object('campaign_id', p_campaign, 'order', to_jsonb(p_quests));
end $$;

-- ---- 6. grants -------------------------------------------------------------------------------------------------------------------
revoke all on function public._quest_dm_gate(uuid), public._quest_status_rank(text), public._quest_objectives_json(uuid),
  public._quest_dm_json(uuid) from public, anon, authenticated;
revoke all on function public.get_character_quests(uuid), public.get_campaign_quests(uuid, boolean),
  public.dm_save_quest(uuid, jsonb, int), public.dm_set_quest_status(uuid, text), public.dm_set_quest_objective(uuid, boolean),
  public.dm_archive_quest(uuid, boolean), public.dm_reorder_quests(uuid, uuid[]) from public, anon;
grant execute on function public.get_character_quests(uuid), public.get_campaign_quests(uuid, boolean),
  public.dm_save_quest(uuid, jsonb, int), public.dm_set_quest_status(uuid, text), public.dm_set_quest_objective(uuid, boolean),
  public.dm_archive_quest(uuid, boolean), public.dm_reorder_quests(uuid, uuid[]) to authenticated, service_role;

reset lock_timeout;
notify pgrst, 'reload schema';
