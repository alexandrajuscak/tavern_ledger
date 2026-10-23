-- =============================================================================
-- Item catalog: items, item_source_books, item_provenance
-- Official rows: owner_id is null (written only by the seed / service role).
-- Homebrew rows: owner_id set; data_source_id is forced to 'homebrew'.
-- =============================================================================

create table public.items (
  id                  text primary key check (id ~ '^[a-z0-9]+(-[a-z0-9]+)*$'),
  kind_id             text not null references public.item_kinds (id),
  category_id         text,
  name                text not null check (length(btrim(name)) > 0),
  description         text,                                   -- optional layer, null for all official rows today
  weight_lb           numeric(10, 2) check (weight_lb >= 0),  -- null = unknown
  cost_value          numeric(14, 2) check (cost_value >= 0), -- original price; 0 = explicitly free, null = unknown
  cost_unit           text references public.currencies (id),
  cost_cp             bigint check (cost_cp >= 0),            -- derived by the trigger below
  rarity_id           text references public.rarities (id),
  is_magic            boolean not null default false,
  requires_attunement boolean not null default false,
  is_consumable       boolean not null default false,
  stackable           boolean not null default false,
  stack_max           int check (stack_max > 0),              -- null = unlimited
  base_item_id        text references public.items (id) on delete set null,
  data_source_id      text not null default 'wikidot' references public.data_sources (id),
  source_book_id      text references public.source_books (id),
  source_url          text,
  source_label        text,                                   -- original source text, e.g. 'DMG, LLK'
  owner_id            uuid references public.profiles (id) on delete set null,   -- homebrew author
  campaign_id         uuid references public.campaigns (id) on delete cascade,   -- homebrew shared with a campaign
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),

  unique (id, kind_id),                                       -- lets typed tables enforce the kind
  foreign key (category_id, kind_id) references public.item_categories (id, kind_id),
  constraint items_cost_pair      check ((cost_value is null) = (cost_unit is null)),
  constraint items_magic_rarity   check (not is_magic or rarity_id is not null),
  constraint items_official_scope check (owner_id is not null or campaign_id is null),
  constraint items_no_self_base   check (base_item_id is distinct from id)
);

create table public.item_source_books (        -- an item can appear in several books
  item_id        text not null references public.items (id) on delete cascade,
  source_book_id text not null references public.source_books (id),
  position       int  not null default 1,
  primary key (item_id, source_book_id)
);

create table public.item_provenance (          -- raw dataset records an item was built from (not exposed to clients)
  item_id          text not null references public.items (id) on delete cascade,
  dataset          text not null,
  source_record_id text not null,
  primary key (item_id, dataset, source_record_id)
);

create function public.items_before_write()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  -- cost_cp is always derived from cost_value + cost_unit
  if new.cost_value is null or new.cost_unit is null then
    new.cost_cp := null;
  else
    new.cost_cp := round(new.cost_value * (select conversion_to_cp from public.currencies where id = new.cost_unit))::bigint;
  end if;
  -- homebrew is never labelled as coming from the official data source
  if new.owner_id is not null then
    new.data_source_id := 'homebrew';
  end if;
  -- authorship cannot be reassigned by a client (the DM may edit campaign homebrew, not take it over)
  -- homebrew is always created in the caller's own name (a DM cannot create rows owned by a player)
  if tg_op = 'INSERT' and new.owner_id is distinct from auth.uid() and auth.uid() is not null and not public.is_admin() then
    raise exception 'Homebrew must be created in your own name';
  end if;
  if tg_op = 'UPDATE' and new.owner_id is distinct from old.owner_id and auth.uid() is not null and not public.is_admin() then
    raise exception 'Only an admin can change the owner of an item';
  end if;
  new.updated_at := now();
  return new;
end;
$$;

create trigger items_before_write before insert or update on public.items
  for each row execute function public.items_before_write();
