-- =============================================================================
-- Typed 1:1 stats. Each table carries a constant kind_id and a composite FK (item_id, kind_id) -> items,
-- so e.g. a weapon_stats row can only exist for an item of kind 'weapon'.
-- (tool_stats and item_effects were removed in the scope review: no data and no MVP use.)
-- =============================================================================

create table public.weapon_stats (
  item_id          text primary key,
  kind_id          text not null default 'weapon' check (kind_id = 'weapon'),
  weapon_group     text not null check (weapon_group in ('simple', 'martial', 'firearm')),
  damage_dice      text,                                  -- null = no damage (Net); '1' = flat damage (Blowgun)
  damage_type_id   text references public.damage_types (id),
  versatile_damage text,
  is_ranged        boolean not null default false,
  range_type       text check (range_type in ('thrown', 'ammunition')),
  range_normal     int check (range_normal > 0),
  range_max        int check (range_max > 0),
  ammo_type_id     text references public.ammo_types (id),
  foreign key (item_id, kind_id) references public.items (id, kind_id) on delete cascade,
  constraint weapon_range_order check (range_normal is null or range_max is null or range_normal <= range_max),
  constraint weapon_damage_pair check (damage_dice is not null or damage_type_id is null),
  constraint weapon_ammo_range  check (ammo_type_id is null or range_type = 'ammunition')
);

create table public.weapon_property_links (
  item_id     text not null references public.weapon_stats (item_id) on delete cascade,
  property_id text not null references public.weapon_properties (id),
  primary key (item_id, property_id)
);

create table public.firearm_stats (            -- firearms are ordinary weapons plus reload/misfire
  item_id text primary key references public.weapon_stats (item_id) on delete cascade,
  reload  int not null check (reload > 0),
  misfire int not null check (misfire > 0)
);

create table public.armor_stats (
  item_id              text primary key,
  kind_id              text not null default 'armor' check (kind_id = 'armor'),
  base_ac              int check (base_ac >= 0),          -- armor only
  ac_bonus             int check (ac_bonus >= 0),         -- shield only (added to AC)
  dex_modifier_mode    text not null check (dex_modifier_mode in ('full', 'capped', 'none')),
  dex_cap              int,
  strength_requirement int check (strength_requirement > 0),
  stealth_disadvantage boolean not null default false,
  is_shield            boolean not null default false,
  foreign key (item_id, kind_id) references public.items (id, kind_id) on delete cascade,
  constraint armor_dex_cap  check ((dex_cap is not null) = (dex_modifier_mode = 'capped')),
  constraint armor_ac_model check ((is_shield and base_ac is null and ac_bonus is not null)
                                or (not is_shield and base_ac is not null and ac_bonus is null))
);

create table public.ammunition_stats (
  item_id      text primary key,
  kind_id      text not null default 'ammunition' check (kind_id = 'ammunition'),
  ammo_type_id text not null references public.ammo_types (id),
  pack_size    int not null check (pack_size > 0),
  pack_cost_cp bigint check (pack_cost_cp >= 0),          -- price of one pack; unit price is derived in the UI
  foreign key (item_id, kind_id) references public.items (id, kind_id) on delete cascade
);

-- Containers (any kind: gear containers, Bag of Holding ...). Capacity is informational: the database
-- only blocks self-containment, cycles and too-deep nesting; over-capacity is reported by v_container_contents.
create table public.container_stats (
  item_id              text primary key references public.items (id) on delete cascade,
  capacity_weight_lb   numeric(10, 2) check (capacity_weight_lb >= 0),
  capacity_volume_cuft numeric(10, 2) check (capacity_volume_cuft >= 0),
  weightless_contents  boolean not null default false,     -- contents do not count toward carried weight
  extradimensional     boolean not null default false,     -- Bag of Holding & co. (nesting two of them is flagged)
  max_nested_depth     int check (max_nested_depth between 1 and 8),   -- null = the global limit (8)
  capacity_note        text                                 -- original capacity text (liquids, "20 arrows" ...)
);

create table public.mount_stats (
  item_id              text primary key,
  kind_id              text not null default 'mount' check (kind_id = 'mount'),
  speed_value          numeric(8, 2) check (speed_value >= 0),
  speed_unit           text check (speed_unit in ('ft', 'mph')),
  carrying_capacity_lb numeric(10, 2) check (carrying_capacity_lb >= 0),
  foreign key (item_id, kind_id) references public.items (id, kind_id) on delete cascade,
  constraint mount_speed_unit check ((speed_value is null) = (speed_unit is null))
);

create table public.vehicle_stats (
  item_id         text primary key,
  kind_id         text not null default 'vehicle' check (kind_id = 'vehicle'),
  speed_value     numeric(8, 2) check (speed_value >= 0),
  speed_unit      text check (speed_unit in ('ft', 'mph')),
  cargo_lb        numeric(12, 2) check (cargo_lb >= 0),
  cargo_tons      numeric(10, 2) check (cargo_tons >= 0),
  is_spelljamming boolean not null default false,
  foreign key (item_id, kind_id) references public.items (id, kind_id) on delete cascade,
  constraint vehicle_speed_unit check ((speed_value is null) = (speed_unit is null))
);

-- What using a consumable does. The RPC returns these rows; it never changes character HP itself.
create table public.consumable_effects (
  item_id         text not null references public.items (id) on delete cascade,
  seq             int  not null default 1 check (seq > 0),
  effect_type     text not null check (effect_type in ('healing', 'damage', 'buff', 'condition', 'cast_spell', 'other')),
  dice_expression text check (dice_expression ~ '^[0-9]+d[0-9]+$'),   -- '2d4'
  flat_value      int,                                                 -- '+ 2'
  damage_type_id  text references public.damage_types (id),
  duration        text,
  target_type     text check (target_type in ('self', 'creature', 'area', 'object')),
  effect_data     jsonb not null default '{}'::jsonb,                  -- extensions only
  primary key (item_id, seq),
  constraint consumable_effect_has_value check (effect_type not in ('healing', 'damage') or dice_expression is not null or flat_value is not null)
);
