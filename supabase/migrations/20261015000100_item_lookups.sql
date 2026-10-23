-- =============================================================================
-- Item lookups. Static reference tables with stable text ids; rows come from
-- supabase/seed/reference_data.sql. Forward-only migration (applied once).
-- =============================================================================

create table public.item_kinds (
  id         text primary key check (id ~ '^[a-z][a-z0-9_]*$'),
  name       text not null,
  sort_order int  not null default 0
);

create table public.item_categories (
  id         text primary key check (id ~ '^[a-z0-9]+(-[a-z0-9]+)*$'),
  kind_id    text not null references public.item_kinds (id),
  name       text not null,
  sort_order int  not null default 0,
  unique (kind_id, name),
  unique (id, kind_id)            -- lets items reference (category_id, kind_id) so a category always matches the kind
);

create table public.rarities (
  id         text primary key check (id ~ '^[a-z]+(_[a-z]+)*$'),   -- enum-like constants: very_rare
  name       text not null,
  sort_order int  not null default 0
);

create table public.data_sources (            -- where the data came from (a website, or 'homebrew'), not a book
  id      text primary key,
  name    text not null,
  url     text,
  license text
);

create table public.source_books (            -- the D&D publication
  id   text primary key,
  code text not null unique,
  name text not null
);

create table public.currencies (
  id               text primary key,
  name             text not null,
  conversion_to_cp int  not null check (conversion_to_cp > 0),
  sort_order       int  not null default 0
);

create table public.damage_types (
  id   text primary key check (id = lower(id)),
  name text not null
);

create table public.ammo_types (
  id   text primary key check (id ~ '^[a-z0-9]+(-[a-z0-9]+)*$'),
  name text not null
);

create table public.weapon_properties (
  id   text primary key check (id ~ '^[a-z0-9]+(-[a-z0-9]+)*$'),
  name text not null
);

create table public.equipment_slots (
  id         text primary key check (id ~ '^[a-z][a-z0-9_]*$'),
  name       text not null,
  sort_order int  not null default 0
);
