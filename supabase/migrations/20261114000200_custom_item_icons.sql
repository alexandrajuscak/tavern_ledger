-- The DM's own item icons (docs/CUSTOM_ICONS.md). Additive; rollback supabase/rollback/rollback_custom_item_icons.sql.
--
-- 1. Storage bucket `item-icons`: PUBLIC (a plain <img> URL, no extra request, cached by the browser), with server-side limits
--    file_size_limit 64 KB and allowed_mime_types image/webp + image/png (the browser shrinks to ~128 px first, but the
--    Storage API refuses anything else on its own). Object names are `<campaign uuid>/<random uuid>.<webp|png>`: they carry no
--    item id, name or order, so a URL says nothing about the item and cannot be guessed. Policies on storage.objects:
--      * insert: only a DM of the campaign named by the first folder, and only names of that exact shape;
--      * select (API listing / metadata): the same DMs only, so a player cannot list the bucket and enumerate icons;
--      * NO update and NO delete policy: a replaced or removed icon leaves its object in place (custom content is never
--        deleted; a leftover object is a few KB, unreferenced and unlisted).
-- 2. public.campaign_item_icons (campaign_id, item_id) -> object_path: the per-campaign override. Only the short object path is
--    stored, never image bytes. RLS: the campaign's DMs (and admins) read every row; another member reads a row only while
--    the items row is readable to them (items RLS = _item_visible), i.e. never more than the catalog row they can already
--    read. No write grants: writes go through dm_set_item_icon only.
--    Cache: tl_cache.skip() (justified): no read in get_character_reads' cacheable list reads this table or v_inventory_detail
--    (only the never-cached inventory_bundle and the legacy REST read do). Not in the Realtime publication: a player sees a
--    new icon the next time their inventory is read.
-- 3. v_inventory_detail gets ONE appended column, custom_icon: the campaign's object path for that copy, NULL whenever the copy
--    is masked for the caller (the same mk.masked as item_id: hidden, unidentified, partially identified, herb decoy). This
--    is the only way the reference reaches a player's sheet (fluent bundle and ?fluent=0 REST alike), per copy, with zero
--    extra requests. The campaign of a copy: the inventory's own campaign (party stash, shop, NPC) or its character's.
-- 4. dm_set_item_icon(campaign, item, path | null): DM of that campaign only. The item must be official, campaign content of
--    that campaign, or held in that campaign. The object must exist in the bucket under that campaign's folder with an
--    allowed type and size. A DM Content item spans several catalog rows (one per published version): the icon is set on all
--    of them, and a version published later inherits it (trigger on dm_content_versions.catalog_ref).
--    get_campaign_item_icons(campaign): the DM's picker list (items of the campaign + current icon).
set lock_timeout = '5s';

-- ---- 1. bucket + storage policies ------------------------------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('item-icons', 'item-icons', true, 65536, array['image/webp', 'image/png'])
on conflict (id) do update
  set public = true, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;

-- the one accepted object name shape (also the table check below)
create or replace function public._item_icon_path_ok(p_path text)
returns boolean language sql immutable set search_path = public, pg_temp as $$
  select coalesce(p_path ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.(webp|png)$', false);
$$;

drop policy if exists "item_icons_insert" on storage.objects;
create policy "item_icons_insert" on storage.objects
  for insert to authenticated
  with check (bucket_id = 'item-icons' and public._item_icon_path_ok(name)
              and public.is_campaign_dm(public.try_uuid((storage.foldername(name))[1])));

drop policy if exists "item_icons_select" on storage.objects;
create policy "item_icons_select" on storage.objects
  for select to authenticated
  using (bucket_id = 'item-icons' and public.is_campaign_dm(public.try_uuid((storage.foldername(name))[1])));

-- ---- 2. the override table -------------------------------------------------------------------------------------------------
create table public.campaign_item_icons (
  campaign_id uuid not null references public.campaigns (id) on delete cascade,
  item_id     text not null references public.items (id) on delete cascade,
  object_path text not null,
  updated_by  uuid references public.profiles (id) on delete set null,
  updated_at  timestamptz not null default now(),
  primary key (campaign_id, item_id),
  constraint campaign_item_icons_path check (public._item_icon_path_ok(object_path) and split_part(object_path, '/', 1) = campaign_id::text)
);
comment on table public.campaign_item_icons is
  'The DM''s own icon of an item in one campaign (20261114000200, docs/CUSTOM_ICONS.md): object path in the item-icons bucket. Players get it only through v_inventory_detail.custom_icon (masked per copy).';
alter table public.campaign_item_icons enable row level security;
revoke all on public.campaign_item_icons from public, anon, authenticated;
grant select on public.campaign_item_icons to authenticated;
grant all on public.campaign_item_icons to service_role;
create policy campaign_item_icons_read on public.campaign_item_icons for select to authenticated
  using (public.is_admin() or public.is_campaign_dm(campaign_id)
         or (public.is_campaign_member(campaign_id)
             and exists (select 1 from public.items it where it.id = campaign_item_icons.item_id)));   -- items RLS: _item_visible
create trigger tl_cache_rev after insert or update or delete on public.campaign_item_icons
  for each row execute function tl_cache.skip();

-- ---- 3. inventory read model: one appended column (body of 20261112000300 + custom_icon) ------------------------------------
create or replace view public.v_inventory_detail with (security_invoker = true) as
select
  ii.id, ii.inventory_id, inv.kind as inventory_kind, inv.character_id,
  case when mk.masked then null else ii.item_id end as item_id,
  case when mk.masked then fc.kind_id else i.kind_id end as kind_id,
  case when mk.masked then null else i.category_id end as category_id,
  case when mk.masked then null else i.rarity_id end as rarity_id,
  case when mk.masked then null else i.is_magic end as is_magic,
  case when mk.masked then null else i.requires_attunement end as requires_attunement,
  case when mk.masked then fc.stackable else i.stackable end as stackable,
  ii.name, ii.custom_name, coalesce(nullif(ii.custom_name, ''), ii.name) as display_name, ii.notes, ii.description,
  ii.quantity, coalesce(i.weight_lb, ii.weight) as unit_weight_lb,
  ii.container_item_id, ii.is_quest_item, ii.is_attuned, ii.attuned_at,
  ii.charges_current, ii.charges_max, ii.charges_recharge, ii.durability, ii.state,
  ii.consumable_override, coalesce(ii.consumable_override, case when mk.masked then fc.is_consumable else i.is_consumable end, false) as is_consumable,
  ii.stack_key, ii.sort_order, ii.acquired_at,
  ce.slot_id as equipped_slot, (ce.slot_id is not null) as equipped,
  (select coalesce(array_agg(m.modifier_id order by m.modifier_id), '{}'::text[])
     from public.inventory_item_modifiers m where m.inventory_item_id = ii.id) as modifier_ids,
  kk.state as knowledge_state,
  ci.object_path as custom_icon   -- 20261114000200: null while the copy is masked (same rule as item_id)
from public.inventory_items ii
join public.inventories inv on inv.id = ii.inventory_id
left join public.items i on i.id = ii.item_id
left join public.character_equipment ce on ce.inventory_item_id = ii.id
left join public.inventory_item_knowledge kk on kk.inventory_item_id = ii.id
cross join lateral (select kk.state is not null and kk.state <> 'identified' and auth.uid() is not null
                           and not public._inventory_knows_all(ii.inventory_id) as masked) mk
left join lateral (select f.kind_id, f.stackable, f.is_consumable from public._inventory_face(ii.id) f where mk.masked) fc on true
left join lateral (select x.object_path from public.campaign_item_icons x
                   where not mk.masked and x.item_id = ii.item_id
                     and x.campaign_id = coalesce(inv.campaign_id, (select c.campaign_id from public.characters c where c.id = inv.character_id))) ci on true;

-- ---- 4. DM functions ---------------------------------------------------------------------------------------------------------
-- an item the DM of p_campaign may give an icon in that campaign: official, this campaign's content, or held in this campaign
create or replace function public._item_icon_in_scope(p_item text, p_campaign uuid)
returns boolean language sql stable security definer set search_path = public, pg_temp as $$
  select exists (select 1 from public.items it where it.id = p_item
                 and (it.owner_id is null or it.campaign_id = p_campaign
                      or exists (select 1 from public.inventory_items ii join public.inventories inv on inv.id = ii.inventory_id
                                 left join public.characters c on c.id = inv.character_id
                                 where ii.item_id = it.id and coalesce(inv.campaign_id, c.campaign_id) = p_campaign)));
$$;

create or replace function public.dm_set_item_icon(p_campaign uuid, p_item text, p_path text)
returns jsonb language plpgsql volatile security definer set search_path = public, pg_temp as $$
declare targets text[]; n int := 0; obj record;
begin
  if auth.uid() is null or p_campaign is null or not public.is_campaign_dm(p_campaign) then
    raise exception 'Only the DM of this campaign can change item icons' using errcode = '42501';
  end if;
  if p_item is null or not public._item_icon_in_scope(p_item, p_campaign) then
    raise exception 'Item not found in this campaign' using errcode = 'P0002';
  end if;
  if p_path is not null then
    if not public._item_icon_path_ok(p_path) or split_part(p_path, '/', 1) <> p_campaign::text then
      raise exception 'Not an icon of this campaign' using errcode = '22023';
    end if;
    select o.metadata into obj from storage.objects o where o.bucket_id = 'item-icons' and o.name = p_path;
    if not found then raise exception 'Upload the image first' using errcode = '22023'; end if;
    if coalesce(obj.metadata ->> 'mimetype', '') not in ('image/webp', 'image/png')
       or coalesce((obj.metadata ->> 'size')::bigint, 0) not between 1 and 65536 then
      raise exception 'The icon must be a WebP or PNG image of at most 64 KB' using errcode = '22023';
    end if;
  end if;
  -- a DM Content item: every published version's catalog row (characters keep the version they have)
  select array_agg(distinct t) into targets from (
    select p_item as t
    union
    select v2.catalog_ref from public.dm_content_versions v1
      join public.dm_content_versions v2 on v2.content_id = v1.content_id
     where v1.catalog_ref = p_item and v2.catalog_ref is not null) s
  where public._item_icon_in_scope(s.t, p_campaign);
  if p_path is null then
    delete from public.campaign_item_icons where campaign_id = p_campaign and item_id = any (targets);   -- the link only, never the file
    get diagnostics n = row_count;
  else
    insert into public.campaign_item_icons as x (campaign_id, item_id, object_path, updated_by, updated_at)
    select p_campaign, t, p_path, auth.uid(), now() from unnest(targets) t
    on conflict (campaign_id, item_id) do update
      set object_path = excluded.object_path, updated_by = excluded.updated_by, updated_at = excluded.updated_at
      where x.object_path is distinct from excluded.object_path;
    get diagnostics n = row_count;
  end if;
  return jsonb_build_object('item_id', p_item, 'custom_icon', p_path, 'items', coalesce(cardinality(targets), 0), 'changed', n);
end $$;

-- the DM's list: the campaign's own items (one row per DM Content item: its newest version) and every item held in it
create or replace function public.get_campaign_item_icons(p_campaign uuid)
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  if auth.uid() is null or p_campaign is null or not (public.is_campaign_dm(p_campaign) or public.is_admin()) then
    raise exception 'Only the DM of this campaign can see its item icons' using errcode = '42501';
  end if;
  return (select coalesce(jsonb_agg(jsonb_build_object('id', z.id, 'name', z.name, 'kind_id', z.kind_id, 'category_id', z.category_id,
            'icon_key', z.icon_key, 'is_magic', z.is_magic, 'official', z.official, 'content_id', z.content_id,
            'custom_icon', z.custom_icon) order by lower(z.name), z.id), '[]'::jsonb)
    from (
      select distinct on (coalesce(v.content_id::text, it.id)) it.id, it.name, it.kind_id, it.category_id, it.icon_key, it.is_magic,
             it.owner_id is null as official, v.content_id, x.object_path as custom_icon
        from public.items it
        left join public.dm_content_versions v on v.catalog_ref = it.id
        left join public.campaign_item_icons x on x.campaign_id = p_campaign and x.item_id = it.id
       where it.campaign_id = p_campaign
          or x.item_id is not null
          or exists (select 1 from public.inventory_items ii join public.inventories inv on inv.id = ii.inventory_id
                     left join public.characters c on c.id = inv.character_id
                     where ii.item_id = it.id and coalesce(inv.campaign_id, c.campaign_id) = p_campaign)
       order by coalesce(v.content_id::text, it.id), v.version_no desc nulls last) z);
end $$;

-- a DM Content version published later inherits the icon of its earlier versions (same campaign; never overwrites)
create or replace function public._item_icon_follow_version()
returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if new.catalog_ref is null or (tg_op = 'UPDATE' and new.catalog_ref is not distinct from old.catalog_ref)
     or not exists (select 1 from public.items where id = new.catalog_ref) then
    return null;
  end if;
  insert into public.campaign_item_icons (campaign_id, item_id, object_path, updated_by, updated_at)
  select distinct on (x.campaign_id) x.campaign_id, new.catalog_ref, x.object_path, x.updated_by, now()
    from public.campaign_item_icons x join public.dm_content_versions v on v.catalog_ref = x.item_id
   where v.content_id = new.content_id and v.id <> new.id and x.item_id <> new.catalog_ref
   order by x.campaign_id, x.updated_at desc
  on conflict (campaign_id, item_id) do nothing;
  return null;
end $$;
create trigger dm_content_versions_item_icon after insert or update of catalog_ref on public.dm_content_versions
  for each row when (new.catalog_ref is not null) execute function public._item_icon_follow_version();

-- ---- 5. grants -------------------------------------------------------------------------------------------------------------
revoke all on function public._item_icon_in_scope(text, uuid), public._item_icon_follow_version() from public, anon, authenticated;
-- used by the storage policy and the table check: callable, it only tests a string
revoke all on function public._item_icon_path_ok(text) from public, anon;
grant execute on function public._item_icon_path_ok(text) to authenticated, service_role;
revoke all on function public.dm_set_item_icon(uuid, text, text), public.get_campaign_item_icons(uuid) from public, anon;
grant execute on function public.dm_set_item_icon(uuid, text, text), public.get_campaign_item_icons(uuid) to authenticated, service_role;

reset lock_timeout;
notify pgrst, 'reload schema';
