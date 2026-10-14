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
  role         text not null default 'player' check (role in ('player', 'dm')),
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
  kind         text not null check (kind in ('character', 'quest', 'campaign', 'spells', 'attacks')),
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
  category     text not null default 'custom' check (category in ('racial', 'class', 'feat', 'custom', 'magic_item')),
  name         text not null default 'New feature',
  description  text not null default '',
  sort_order   int  not null default 0,
  created_at   timestamptz not null default now()
);

create index if not exists characters_owner_idx        on public.characters (owner_id);
create index if not exists inventory_items_char_idx    on public.inventory_items (character_id);
create index if not exists notes_char_idx              on public.notes (character_id);
create index if not exists spell_slots_char_idx        on public.spell_slots (character_id);
create index if not exists feature_trackers_char_idx   on public.feature_trackers (character_id);
create index if not exists features_char_idx           on public.features (character_id);

-- -----------------------------------------------------------------------------
-- Helper functions (SECURITY DEFINER so they can be used inside RLS policies
-- without recursive policy evaluation)
-- -----------------------------------------------------------------------------

create or replace function public.is_dm()
returns boolean
language sql stable security definer set search_path = public
as $$
  select exists (select 1 from public.profiles where id = auth.uid() and role = 'dm');
$$;

create or replace function public.can_access_character(cid uuid)
returns boolean
language sql stable security definer set search_path = public
as $$
  select exists (
    select 1 from public.characters c
    where c.id = cid and (c.owner_id = auth.uid() or public.is_dm())
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

-- Only a DM may change roles. Requests coming from the SQL editor / service role
-- (auth.uid() is null) are allowed, so the first DM can be bootstrapped.
create or replace function public.protect_profile_role()
returns trigger
language plpgsql security definer set search_path = public
as $$
begin
  if auth.uid() is null or public.is_dm() then
    return new;
  end if;
  if tg_op = 'INSERT' then
    new.role := 'player';
  elsif new.role is distinct from old.role then
    raise exception 'Only the DM can change roles';
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
  select new.id, k from unnest(array['character', 'quest', 'campaign', 'spells', 'attacks']) k
  on conflict do nothing;
  return new;
end;
$$;

drop trigger if exists characters_seed on public.characters;
create trigger characters_seed after insert on public.characters
  for each row execute function public.seed_character();

-- -----------------------------------------------------------------------------
-- Row Level Security
--   players: full access to their own characters
--   DM:      full access to every character and every profile
-- -----------------------------------------------------------------------------

alter table public.profiles         enable row level security;
alter table public.characters       enable row level security;
alter table public.inventory_items  enable row level security;
alter table public.notes            enable row level security;
alter table public.spell_slots      enable row level security;
alter table public.feature_trackers enable row level security;
alter table public.features         enable row level security;

-- profiles
drop policy if exists "profiles_select" on public.profiles;
create policy "profiles_select" on public.profiles
  for select to authenticated using (id = auth.uid() or public.is_dm());

drop policy if exists "profiles_insert" on public.profiles;
create policy "profiles_insert" on public.profiles
  for insert to authenticated with check (id = auth.uid());

drop policy if exists "profiles_update" on public.profiles;
create policy "profiles_update" on public.profiles
  for update to authenticated
  using (id = auth.uid() or public.is_dm())
  with check (id = auth.uid() or public.is_dm());

-- characters
drop policy if exists "characters_select" on public.characters;
create policy "characters_select" on public.characters
  for select to authenticated using (owner_id = auth.uid() or public.is_dm());

drop policy if exists "characters_insert" on public.characters;
create policy "characters_insert" on public.characters
  for insert to authenticated with check (owner_id = auth.uid() or public.is_dm());

drop policy if exists "characters_update" on public.characters;
create policy "characters_update" on public.characters
  for update to authenticated
  using (owner_id = auth.uid() or public.is_dm())
  with check (owner_id = auth.uid() or public.is_dm());

drop policy if exists "characters_delete" on public.characters;
create policy "characters_delete" on public.characters
  for delete to authenticated using (owner_id = auth.uid() or public.is_dm());

-- child tables: access follows the parent character
do $$
declare t text;
begin
  foreach t in array array['inventory_items', 'notes', 'spell_slots', 'feature_trackers', 'features'] loop
    execute format('drop policy if exists "%1$s_all" on public.%1$I', t);
    execute format(
      'create policy "%1$s_all" on public.%1$I for all to authenticated
         using (public.can_access_character(character_id))
         with check (public.can_access_character(character_id))', t);
  end loop;
end $$;

grant usage on schema public to authenticated;
grant select, insert, update, delete on
  public.profiles, public.characters, public.inventory_items, public.notes,
  public.spell_slots, public.feature_trackers, public.features
to authenticated;

-- -----------------------------------------------------------------------------
-- Realtime: live sync between devices
-- -----------------------------------------------------------------------------

do $$
declare t text;
begin
  foreach t in array array['characters', 'inventory_items', 'notes', 'spell_slots', 'feature_trackers', 'features'] loop
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
-- Make yourself the DM (run after you have signed in once):
--
--   update public.profiles set role = 'dm' where email = 'you@example.com';
-- -----------------------------------------------------------------------------
