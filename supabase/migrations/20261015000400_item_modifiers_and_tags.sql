-- =============================================================================
-- Item modifiers (+N, silvered, adamantine, homebrew ...) and tags.
-- A modifier is NOT a catalog item; it is applied to a concrete inventory item.
-- =============================================================================

create table public.item_modifiers (
  id                           text primary key check (id ~ '^[a-z0-9]+(-[a-z0-9]+)*$'),
  name                         text not null,
  description                  text,
  applies_to_kind_id           text references public.item_kinds (id),   -- null = any kind
  rarity_id                    text references public.rarities (id),
  requires_attunement_override boolean,                                  -- null = keep the item's own value
  is_magic_override            boolean,                                  -- null = keep; true = makes the item magic
  data_source_id               text not null default 'wikidot' references public.data_sources (id),
  source_book_id               text references public.source_books (id),
  source_url                   text,
  owner_id                     uuid references public.profiles (id) on delete set null,   -- homebrew author
  campaign_id                  uuid references public.campaigns (id) on delete cascade,
  created_at                   timestamptz not null default now(),
  constraint modifiers_official_scope check (owner_id is not null or campaign_id is null)
);

-- Compatible categories (no rows = every category of applies_to_kind_id).
create table public.item_modifier_categories (
  modifier_id text not null references public.item_modifiers (id) on delete cascade,
  category_id text not null references public.item_categories (id),
  primary key (modifier_id, category_id)
);

create table public.item_modifier_effects (
  modifier_id text not null references public.item_modifiers (id) on delete cascade,
  seq         int  not null default 1,
  effect_type text not null check (effect_type in ('attack_bonus', 'damage_bonus', 'ac_bonus', 'save_bonus',
                                                    'spell_attack_bonus', 'spell_save_dc_bonus', 'custom')),
  value       numeric,
  data        jsonb not null default '{}'::jsonb,                       -- extensible effects only
  primary key (modifier_id, seq)
);

create table public.item_tags (
  id        text primary key check (id ~ '^[a-z0-9]+(-[a-z0-9]+)*$'),
  name      text not null,
  tag_group text not null default 'system',
  is_system boolean not null default true,
  owner_id  uuid references public.profiles (id) on delete cascade     -- reserved for player tags (phase 2, no client write yet)
);

create table public.item_tag_links (
  item_id text not null references public.items (id) on delete cascade,
  tag_id  text not null references public.item_tags (id) on delete cascade,
  primary key (item_id, tag_id)
);

-- homebrew modifiers are never labelled as official data
create function public.item_modifiers_before_write()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  if new.owner_id is not null then new.data_source_id := 'homebrew'; end if;
  -- homebrew is always created in the caller's own name (a DM cannot create rows owned by a player)
  if tg_op = 'INSERT' and new.owner_id is distinct from auth.uid() and auth.uid() is not null and not public.is_admin() then
    raise exception 'Homebrew must be created in your own name';
  end if;
  if tg_op = 'UPDATE' and new.owner_id is distinct from old.owner_id and auth.uid() is not null and not public.is_admin() then
    raise exception 'Only an admin can change the owner of a modifier';
  end if;
  return new;
end;
$$;

create trigger item_modifiers_before_write before insert or update on public.item_modifiers
  for each row execute function public.item_modifiers_before_write();
