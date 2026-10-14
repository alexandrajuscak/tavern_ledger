-- =============================================================================
-- Tavern Ledger — D&D 5e character sheets
-- Supabase schema. Run this whole file once in: Supabase Dashboard → SQL Editor.
-- It is safe to re-run (idempotent).
-- =============================================================================

create extension if not exists pgcrypto;

-- -----------------------------------------------------------------------------
-- Tables
-- -----------------------------------------------------------------------------

create table if not exists public.profiles (
  id           uuid primary key references auth.users (id) on delete cascade,
  email        text,
  display_name text,
  role         text not null default 'player' check (role in ('player', 'admin')),
  created_at   timestamptz not null default now()
);

create table if not exists public.characters (
  id                  uuid primary key default gen_random_uuid(),
  owner_id            uuid not null default auth.uid() references public.profiles (id) on delete cascade,

  -- identity
  name                text not null default 'New Adventurer',
  race                text not null default '',
  class_name          text not null default '',
  subclass            text not null default '',
  background          text not null default '',
  alignment           text not null default '',
  level               int  not null default 1  check (level between 1 and 20),
  experience          int  not null default 0  check (experience >= 0),

  -- combat
  hp_current          int  not null default 10,
  hp_max              int  not null default 10 check (hp_max >= 1),
  hp_temp             int  not null default 0  check (hp_temp >= 0),
  ac                  int  not null default 10,
  initiative_bonus    int  not null default 0,   -- misc bonus on top of DEX
  speed               int  not null default 30,
  hit_die             text not null default 'd8' check (hit_die in ('d6', 'd8', 'd10', 'd12')),
  hit_dice_current    int  not null default 1  check (hit_dice_current >= 0),
  death_successes     int  not null default 0  check (death_successes between 0 and 3),
  death_failures      int  not null default 0  check (death_failures between 0 and 3),
  inspiration         boolean not null default false,

  -- abilities
  strength            int  not null default 10 check (strength between 1 and 30),
  dexterity           int  not null default 10 check (dexterity between 1 and 30),
  constitution        int  not null default 10 check (constitution between 1 and 30),
  intelligence        int  not null default 10 check (intelligence between 1 and 30),
  wisdom              int  not null default 10 check (wisdom between 1 and 30),
  charisma            int  not null default 10 check (charisma between 1 and 30),

  -- proficiencies: {"str": true, ...} and {"stealth": 1 (proficient) | 2 (expertise)}
  save_proficiencies  jsonb not null default '{}'::jsonb,
  skill_proficiencies jsonb not null default '{}'::jsonb,
  proficiencies       text  not null default '',  -- armor/weapons/tools/languages, free text

  -- spellcasting
  spellcasting_ability text not null default '' check (spellcasting_ability in ('', 'str', 'dex', 'con', 'int', 'wis', 'cha')),

  -- currency
  cp int not null default 0, sp int not null default 0, ep int not null default 0,
  gp int not null default 0, pp int not null default 0,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.inventory_items (
  id           uuid primary key default gen_random_uuid(),
  character_id uuid not null references public.characters (id) on delete cascade,
  name         text not null default 'New item',
  quantity     int  not null default 1 check (quantity >= 0),
  weight       numeric(8, 2) not null default 0 check (weight >= 0),
  description  text not null default '',
  equipped     boolean not null default false,
  sort_order   int  not null default 0,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);

-- One row per (character, kind). Rows are created automatically with the character.
create table if not exists public.notes (
  id           uuid primary key default gen_random_uuid(),
  character_id uuid not null references public.characters (id) on delete cascade,
  kind         text not null check (kind in ('character', 'session', 'campaign', 'spells', 'attacks')),
  content      text not null default '',
  updated_at   timestamptz not null default now(),
  unique (character_id, kind)
);

-- One row per (character, spell level 1–9). Created automatically with the character.
create table if not exists public.spell_slots (
  id           uuid primary key default gen_random_uuid(),
  character_id uuid not null references public.characters (id) on delete cascade,
  level        int  not null check (level between 1 and 9),
  total        int  not null default 0 check (total between 0 and 9),
  used         int  not null default 0 check (used >= 0),
  unique (character_id, level)
);

-- Trackable resource pools: Ki, Rage, Sorcery Points, Bardic Inspiration, custom…
create table if not exists public.feature_trackers (
  id           uuid primary key default gen_random_uuid(),
  character_id uuid not null references public.characters (id) on delete cascade,
  name         text not null default 'Resource',
  current      int  not null default 1 check (current >= 0),
  max          int  not null default 1 check (max >= 0),
  reset_on     text not null default 'long' check (reset_on in ('short', 'long', 'none')),
  sort_order   int  not null default 0,
  created_at   timestamptz not null default now()
);

-- Free-text features shown on the Features tab.
create table if not exists public.features (
  id           uuid primary key default gen_random_uuid(),
  character_id uuid not null references public.characters (id) on delete cascade,
  category     text not null default 'custom' check (category in ('racial', 'class', 'background', 'feat', 'custom', 'magic_item')),
  name         text not null default 'New feature',
  description  text not null default '',
  sort_order   int  not null default 0,
  created_at   timestamptz not null default now()
);

-- Weapons & attacks. To-hit and damage are calculated in the app from the
-- character's ability scores, proficiency and magic bonus.
create table if not exists public.attacks (
  id             uuid primary key default gen_random_uuid(),
  character_id   uuid not null references public.characters (id) on delete cascade,
  name           text not null default 'New attack',
  attack_kind    text not null default 'melee' check (attack_kind in ('melee', 'ranged')),
  ability        text not null default 'str' check (ability in ('str', 'dex', 'finesse', 'spell', 'none')),
  proficient     boolean not null default true,
  magic_bonus    int  not null default 0,
  damage_dice    text not null default '1d6',
  damage_type    text not null default 'slashing',
  add_modifier   boolean not null default true,  -- add ability modifier to damage
  range          text not null default '5 ft',
  properties     text not null default '',
  notes          text not null default '',
  sort_order     int  not null default 0,
  created_at     timestamptz not null default now()
);

-- Spells known / prepared. Level 0 = cantrip.
create table if not exists public.spells (
  id             uuid primary key default gen_random_uuid(),
  character_id   uuid not null references public.characters (id) on delete cascade,
  name           text not null default 'New spell',
  level          int  not null default 0 check (level between 0 and 9),
  school         text not null default '',
  casting_time   text not null default '1 action',
  range          text not null default '',
  components     text not null default 'V, S',
  duration       text not null default 'Instantaneous',
  concentration  boolean not null default false,
  ritual         boolean not null default false,
  attack_type    text not null default 'none' check (attack_type in ('none', 'attack', 'save')),
  save_ability   text not null default '' check (save_ability in ('', 'str', 'dex', 'con', 'int', 'wis', 'cha')),
  damage         text not null default '',
  damage_type    text not null default '',
  description    text not null default '',
  prepared       boolean not null default false,
  sort_order     int  not null default 0,
  created_at     timestamptz not null default now()
);

-- Added in v2: armor & weapon proficiency checkboxes
-- {"light": true, "medium": true, "heavy": false, "shields": true, "simple": true, "martial": true}
alter table public.characters add column if not exists equipment_proficiencies jsonb not null default '{}'::jsonb;

-- -----------------------------------------------------------------------------
-- v3: conditions, portraits, feature activation, session notes, skill objects.
-- Every statement below is safe to re-run.
-- -----------------------------------------------------------------------------

-- Active conditions, e.g. ["Prone", "Poisoned", "Hexed"]
alter table public.characters add column if not exists conditions jsonb not null default '[]'::jsonb;
-- Portrait: an uploaded image (Supabase Storage public URL) or any image URL
alter table public.characters add column if not exists portrait_url text not null default '';

-- How a feature is used, so the Combat tab can group it.
alter table public.features add column if not exists activation text not null default 'passive';
alter table public.features drop constraint if exists features_activation_check;
alter table public.features add constraint features_activation_check
  check (activation in ('passive', 'action', 'bonus_action', 'reaction', 'special'));

-- Feature source gains "background".
alter table public.features drop constraint if exists features_category_check;
alter table public.features add constraint features_category_check
  check (category in ('racial', 'class', 'background', 'feat', 'custom', 'magic_item'));

-- Notes: "Quest log" becomes "Session notes".
alter table public.notes drop constraint if exists notes_kind_check;
update public.notes n set kind = 'session'
  where kind = 'quest'
    and not exists (select 1 from public.notes s where s.character_id = n.character_id and s.kind = 'session');
delete from public.notes where kind = 'quest';
alter table public.notes add constraint notes_kind_check
  check (kind in ('character', 'session', 'campaign', 'spells', 'attacks'));

-- Skills: 0/1/2 numbers become {"proficient": bool, "expertise": bool}.
update public.characters c
set skill_proficiencies = coalesce((
  select jsonb_object_agg(e.key,
    case jsonb_typeof(e.value)
      when 'number'  then jsonb_build_object('proficient', (e.value #>> '{}')::int >= 1,
                                             'expertise',  (e.value #>> '{}')::int >= 2)
      when 'boolean' then jsonb_build_object('proficient', (e.value #>> '{}')::boolean, 'expertise', false)
      else e.value
    end)
  from jsonb_each(c.skill_proficiencies) e), '{}'::jsonb)
where exists (select 1 from jsonb_each(c.skill_proficiencies) e where jsonb_typeof(e.value) <> 'object');

-- -----------------------------------------------------------------------------
-- v4: campaigns. One global admin role; per-campaign DMs and players.
-- -----------------------------------------------------------------------------

create table if not exists public.campaigns (
  id          uuid primary key default gen_random_uuid(),
  name        text not null default 'New Campaign',
  description text not null default '',
  created_by  uuid default auth.uid() references public.profiles (id) on delete set null,
  created_at  timestamptz not null default now()
);

create table if not exists public.campaign_members (
  campaign_id uuid not null references public.campaigns (id) on delete cascade,
  user_id     uuid not null references public.profiles (id) on delete cascade,
  role        text not null default 'player' check (role in ('dm', 'player')),
  created_at  timestamptz not null default now(),
  primary key (campaign_id, user_id)
);

alter table public.characters add column if not exists campaign_id uuid references public.campaigns (id) on delete set null;
create index if not exists characters_campaign_idx on public.characters (campaign_id);
create index if not exists campaign_members_user_idx on public.campaign_members (user_id);

-- The old global "dm" role becomes "admin" (sees and manages everything).
alter table public.profiles drop constraint if exists profiles_role_check;
update public.profiles set role = 'admin' where role = 'dm';
alter table public.profiles add constraint profiles_role_check check (role in ('player', 'admin'));

-- First run only: put every existing character and person into one campaign,
-- with admins as its DMs, so nothing disappears.
do $$
declare camp uuid;
begin
  if not exists (select 1 from public.campaigns) and exists (select 1 from public.characters) then
    insert into public.campaigns (name, description, created_by)
    values ('Our Campaign', 'Created automatically from the existing characters. Rename it on the Campaigns page.',
            (select id from public.profiles where role = 'admin' order by created_at limit 1))
    returning id into camp;
    update public.characters set campaign_id = camp where campaign_id is null;
    insert into public.campaign_members (campaign_id, user_id, role)
    select camp, p.id, case when p.role = 'admin' then 'dm' else 'player' end
    from public.profiles p
    on conflict do nothing;
  end if;
end $$;

-- -----------------------------------------------------------------------------
-- v5: pending choices, resource formulas, spell sources, "special" activation
-- (the "special" value is part of features_activation_check above).
-- -----------------------------------------------------------------------------

-- Unresolved player choices: [{"id", "type", "description", "options": [...]}]
alter table public.characters add column if not exists pending_choices jsonb not null default '[]'::jsonb;
-- Optional, display-only formula for a resource maximum, e.g. "monkLevel", "paladinLevel * 5"
alter table public.feature_trackers add column if not exists formula text not null default '';
-- Where a spell comes from, e.g. "Warlock", "Magic Initiate", "Drow Magic"
alter table public.spells add column if not exists source text not null default '';

create index if not exists characters_owner_idx        on public.characters (owner_id);
create index if not exists attacks_char_idx            on public.attacks (character_id);
create index if not exists spells_char_idx             on public.spells (character_id);
create index if not exists inventory_items_char_idx    on public.inventory_items (character_id);
create index if not exists notes_char_idx              on public.notes (character_id);
create index if not exists spell_slots_char_idx        on public.spell_slots (character_id);
create index if not exists feature_trackers_char_idx   on public.feature_trackers (character_id);
create index if not exists features_char_idx           on public.features (character_id);

-- -----------------------------------------------------------------------------
-- Helper functions (SECURITY DEFINER so they can be used inside RLS policies
-- without recursive policy evaluation)
-- -----------------------------------------------------------------------------

create or replace function public.is_admin()
returns boolean
language sql stable security definer set search_path = public
as $$
  select exists (select 1 from public.profiles where id = auth.uid() and role = 'admin');
$$;

-- Kept for older policies/scripts; same as is_admin().
create or replace function public.is_dm()
returns boolean
language sql stable security definer set search_path = public
as $$
  select public.is_admin();
$$;

create or replace function public.is_campaign_member(camp uuid)
returns boolean
language sql stable security definer set search_path = public
as $$
  select exists (select 1 from public.campaign_members where campaign_id = camp and user_id = auth.uid());
$$;

create or replace function public.is_campaign_dm(camp uuid)
returns boolean
language sql stable security definer set search_path = public
as $$
  select exists (select 1 from public.campaign_members where campaign_id = camp and user_id = auth.uid() and role = 'dm');
$$;

-- True when the current user and `other` are in at least one campaign together.
create or replace function public.shares_campaign(other uuid)
returns boolean
language sql stable security definer set search_path = public
as $$
  select exists (
    select 1 from public.campaign_members me
    join public.campaign_members them on them.campaign_id = me.campaign_id
    where me.user_id = auth.uid() and them.user_id = other
  );
$$;

-- Owner, admin, or a DM of the character's campaign.
create or replace function public.can_access_character(cid uuid)
returns boolean
language sql stable security definer set search_path = public
as $$
  select exists (
    select 1 from public.characters c
    where c.id = cid
      and (c.owner_id = auth.uid() or public.is_admin() or public.is_campaign_dm(c.campaign_id))
  );
$$;

-- -----------------------------------------------------------------------------
-- Triggers
-- -----------------------------------------------------------------------------

-- Create a profile automatically for every new auth user.
create or replace function public.handle_new_user()
returns trigger
language plpgsql security definer set search_path = public
as $$
begin
  insert into public.profiles (id, email, display_name)
  values (
    new.id,
    new.email,
    coalesce(new.raw_user_meta_data ->> 'full_name',
             new.raw_user_meta_data ->> 'name',
             split_part(new.email, '@', 1))
  )
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- Only an admin may change roles. Requests coming from the SQL editor / service role
-- (auth.uid() is null) are allowed, so the first admin can be bootstrapped.
create or replace function public.protect_profile_role()
returns trigger
language plpgsql security definer set search_path = public
as $$
begin
  if auth.uid() is null or public.is_admin() then
    return new;
  end if;
  if tg_op = 'INSERT' then
    new.role := 'player';
  elsif new.role is distinct from old.role then
    raise exception 'Only an admin can change roles';
  end if;
  return new;
end;
$$;

drop trigger if exists profiles_protect_role on public.profiles;
create trigger profiles_protect_role
  before insert or update on public.profiles
  for each row execute function public.protect_profile_role();

create or replace function public.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

drop trigger if exists characters_updated_at on public.characters;
create trigger characters_updated_at before update on public.characters
  for each row execute function public.set_updated_at();

drop trigger if exists inventory_items_updated_at on public.inventory_items;
create trigger inventory_items_updated_at before update on public.inventory_items
  for each row execute function public.set_updated_at();

drop trigger if exists notes_updated_at on public.notes;
create trigger notes_updated_at before update on public.notes
  for each row execute function public.set_updated_at();

-- Seed spell slot rows (levels 1–9) and note rows for every new character.
create or replace function public.seed_character()
returns trigger
language plpgsql security definer set search_path = public
as $$
begin
  insert into public.spell_slots (character_id, level)
  select new.id, g from generate_series(1, 9) g
  on conflict do nothing;

  insert into public.notes (character_id, kind)
  select new.id, k from unnest(array['character', 'session', 'campaign', 'spells', 'attacks']) k
  on conflict do nothing;
  return new;
end;
$$;

drop trigger if exists characters_seed on public.characters;
create trigger characters_seed after insert on public.characters
  for each row execute function public.seed_character();

-- -----------------------------------------------------------------------------
-- Row Level Security
--   admin:        everything
--   campaign DM:  every character in their campaigns (and their players' names)
--   player:       their own characters
-- -----------------------------------------------------------------------------

alter table public.profiles         enable row level security;
alter table public.campaigns        enable row level security;
alter table public.campaign_members enable row level security;
alter table public.characters       enable row level security;
alter table public.inventory_items  enable row level security;
alter table public.notes            enable row level security;
alter table public.spell_slots      enable row level security;
alter table public.feature_trackers enable row level security;
alter table public.features         enable row level security;
alter table public.attacks          enable row level security;
alter table public.spells           enable row level security;

-- profiles: yourself, everyone you share a campaign with, or everyone (admin)
drop policy if exists "profiles_select" on public.profiles;
create policy "profiles_select" on public.profiles
  for select to authenticated using (id = auth.uid() or public.is_admin() or public.shares_campaign(id));

drop policy if exists "profiles_insert" on public.profiles;
create policy "profiles_insert" on public.profiles
  for insert to authenticated with check (id = auth.uid());

drop policy if exists "profiles_update" on public.profiles;
create policy "profiles_update" on public.profiles
  for update to authenticated
  using (id = auth.uid() or public.is_admin())
  with check (id = auth.uid() or public.is_admin());

-- campaigns: members can see them; admins create/delete; admins and the campaign's DMs edit
drop policy if exists "campaigns_select" on public.campaigns;
create policy "campaigns_select" on public.campaigns
  for select to authenticated using (public.is_admin() or public.is_campaign_member(id));

drop policy if exists "campaigns_insert" on public.campaigns;
create policy "campaigns_insert" on public.campaigns
  for insert to authenticated with check (public.is_admin());

drop policy if exists "campaigns_update" on public.campaigns;
create policy "campaigns_update" on public.campaigns
  for update to authenticated
  using (public.is_admin() or public.is_campaign_dm(id))
  with check (public.is_admin() or public.is_campaign_dm(id));

drop policy if exists "campaigns_delete" on public.campaigns;
create policy "campaigns_delete" on public.campaigns
  for delete to authenticated using (public.is_admin());

-- campaign_members: members see their campaign's roster; only admins change it
drop policy if exists "campaign_members_select" on public.campaign_members;
create policy "campaign_members_select" on public.campaign_members
  for select to authenticated using (public.is_admin() or public.is_campaign_member(campaign_id));

drop policy if exists "campaign_members_write" on public.campaign_members;
create policy "campaign_members_write" on public.campaign_members
  for all to authenticated using (public.is_admin()) with check (public.is_admin());

-- characters
drop policy if exists "characters_select" on public.characters;
create policy "characters_select" on public.characters
  for select to authenticated
  using (owner_id = auth.uid() or public.is_admin() or public.is_campaign_dm(campaign_id));

-- You may create/save a character if you are an admin, a DM of its campaign,
-- or its owner and (it has no campaign or you are a member of that campaign).
drop policy if exists "characters_insert" on public.characters;
create policy "characters_insert" on public.characters
  for insert to authenticated
  with check (
    public.is_admin()
    or public.is_campaign_dm(campaign_id)
    or (owner_id = auth.uid() and (campaign_id is null or public.is_campaign_member(campaign_id)))
  );

drop policy if exists "characters_update" on public.characters;
create policy "characters_update" on public.characters
  for update to authenticated
  using (owner_id = auth.uid() or public.is_admin() or public.is_campaign_dm(campaign_id))
  with check (
    public.is_admin()
    or public.is_campaign_dm(campaign_id)
    or (owner_id = auth.uid() and (campaign_id is null or public.is_campaign_member(campaign_id)))
  );

drop policy if exists "characters_delete" on public.characters;
create policy "characters_delete" on public.characters
  for delete to authenticated
  using (owner_id = auth.uid() or public.is_admin() or public.is_campaign_dm(campaign_id));

-- child tables: access follows the parent character
do $$
declare t text;
begin
  foreach t in array array['inventory_items', 'notes', 'spell_slots', 'feature_trackers', 'features', 'attacks', 'spells'] loop
    execute format('drop policy if exists "%1$s_all" on public.%1$I', t);
    execute format(
      'create policy "%1$s_all" on public.%1$I for all to authenticated
         using (public.can_access_character(character_id))
         with check (public.can_access_character(character_id))', t);
  end loop;
end $$;

grant usage on schema public to authenticated;
grant select, insert, update, delete on
  public.profiles, public.campaigns, public.campaign_members, public.characters, public.inventory_items, public.notes,
  public.spell_slots, public.feature_trackers, public.features, public.attacks, public.spells
to authenticated;

-- -----------------------------------------------------------------------------
-- Realtime: live sync between devices
-- -----------------------------------------------------------------------------

do $$
declare t text;
begin
  foreach t in array array['characters', 'inventory_items', 'notes', 'spell_slots', 'feature_trackers', 'features', 'attacks', 'spells'] loop
    execute format('alter table public.%I replica identity full', t);
    if not exists (
      select 1 from pg_publication_tables
      where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t
    ) then
      execute format('alter publication supabase_realtime add table public.%I', t);
    end if;
  end loop;
end $$;

-- -----------------------------------------------------------------------------
-- Storage: character portraits
--   Files live at portraits/<character_id>/<file>. Anyone with the link can view
--   them (public bucket); only the owner or the DM can upload or delete.
-- -----------------------------------------------------------------------------

create or replace function public.try_uuid(t text)
returns uuid
language plpgsql immutable
as $$
begin
  return t::uuid;
exception when others then
  return null;
end;
$$;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('portraits', 'portraits', true, 2097152, array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do update
  set public = true,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists "portraits_select" on storage.objects;
create policy "portraits_select" on storage.objects
  for select to authenticated
  using (bucket_id = 'portraits' and public.can_access_character(public.try_uuid((storage.foldername(name))[1])));

drop policy if exists "portraits_insert" on storage.objects;
create policy "portraits_insert" on storage.objects
  for insert to authenticated
  with check (bucket_id = 'portraits' and public.can_access_character(public.try_uuid((storage.foldername(name))[1])));

drop policy if exists "portraits_delete" on storage.objects;
create policy "portraits_delete" on storage.objects
  for delete to authenticated
  using (bucket_id = 'portraits' and public.can_access_character(public.try_uuid((storage.foldername(name))[1])));

-- -----------------------------------------------------------------------------
-- Make yourself the admin (run after you have signed in once):
--
--   update public.profiles set role = 'admin' where email = 'you@example.com';
-- -----------------------------------------------------------------------------
