-- =============================================================================
-- Homebrew catalog items, customized inventory instances and legacy items (docs/HOMEBREW_ITEMS.md,
-- docs/LEGACY_ITEM_MIGRATION_UI.md, docs/CUSTOM_ITEMS_AUDIT.md).
--
--  * Legacy item       inventory_items row without item_id. Never created by clients again; linked or converted.
--  * Customized instance inventory_items row with item_id; per-piece fields via update_inventory_item_details.
--  * Homebrew item     items row with owner_id (+ campaign_id); written only by the RPCs below.
--
-- Homebrew id: 'hb-' || <uuid>. The uuid is the client's request id, which makes create/convert idempotent:
-- a retried request finds the item it already created instead of creating a second one. Renaming never changes it.
-- Visibility is derived (no extra column): owner_id null = official; campaign_id null = private; else campaign.
-- =============================================================================

-- ---- data model ------------------------------------------------------------------------------------------
alter table public.items
  add column archived_at timestamptz,
  add column archived_by uuid references public.profiles (id) on delete set null,
  add column updated_by  uuid references public.profiles (id) on delete set null,
  add constraint items_archive_homebrew_only check (archived_at is null or owner_id is not null);

-- Homebrew never loses its author: with ON DELETE SET NULL a deleted author's private homebrew would turn into an
-- "official" row (owner_id and campaign_id both null). A profile that still owns homebrew cannot be deleted; its
-- items must be deleted or transferred first (an admin can change owner_id).
alter table public.items drop constraint items_owner_id_fkey;
alter table public.items
  add constraint items_owner_id_fkey foreign key (owner_id) references public.profiles (id) on delete restrict,
  add constraint items_homebrew_has_owner check (data_source_id <> 'homebrew' or owner_id is not null);

create table public.homebrew_item_events (
  id         uuid primary key default gen_random_uuid(),
  item_id    text not null references public.items (id) on delete cascade,
  actor_id   uuid,
  action     text not null check (action in ('create', 'update', 'archive', 'restore', 'convert', 'import')),
  changes    jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
create index homebrew_item_events_item_idx on public.homebrew_item_events (item_id, created_at desc);

alter table public.legacy_inventory_review drop constraint legacy_inventory_review_category_check;
alter table public.legacy_inventory_review add constraint legacy_inventory_review_category_check check (category in (
  'equipped_pending', 'equipped_migrated', 'equipped_manual', 'qty0_empty_placeholder', 'qty0_corrupted',
  'qty0_convertible', 'qty0_manual', 'linked_by_name', 'linked_by_user', 'converted_to_homebrew'));

-- ---- small helpers ---------------------------------------------------------------------------------------
create function public._norm_name(t text)
returns text
language sql immutable
set search_path = public, pg_temp
as $$ select btrim(regexp_replace(lower(coalesce(t, '')), '[^a-z0-9]+', ' ', 'g')); $$;

create function public._j_text(j jsonb, k text, maxlen int, label text)
returns text
language plpgsql immutable
set search_path = public, pg_temp
as $$
declare v text := nullif(btrim(coalesce(j ->> k, '')), '');
begin
  if v is not null and length(v) > maxlen then raise exception '% is too long (max % characters)', label, maxlen using errcode = '22023'; end if;
  return v;
end;
$$;

create function public._j_num(j jsonb, k text, lo numeric, hi numeric, label text)
returns numeric
language plpgsql immutable
set search_path = public, pg_temp
as $$
declare v numeric;
begin
  if j -> k is null or jsonb_typeof(j -> k) = 'null' or btrim(j ->> k) = '' then return null; end if;
  begin
    v := (j ->> k)::numeric;
  exception when others then
    raise exception '% must be a number', label using errcode = '22023';
  end;
  if v < lo or v > hi then raise exception '% must be between % and %', label, lo, hi using errcode = '22023'; end if;
  return v;
end;
$$;

create function public._j_int(j jsonb, k text, lo int, hi int, label text)
returns int
language plpgsql immutable
set search_path = public, pg_temp
as $$
declare v numeric := public._j_num(j, k, lo, hi, label);
begin
  if v is not null and v <> trunc(v) then raise exception '% must be a whole number', label using errcode = '22023'; end if;
  return v::int;
end;
$$;

create function public._j_bool(j jsonb, k text, dflt boolean)
returns boolean
language plpgsql immutable
set search_path = public, pg_temp
as $$
begin
  if j -> k is null or jsonb_typeof(j -> k) = 'null' then return dflt; end if;
  if jsonb_typeof(j -> k) <> 'boolean' then raise exception '% must be true or false', k using errcode = '22023'; end if;
  return (j -> k)::boolean;
end;
$$;

-- visibility as text, for views and responses
create function public.item_visibility(p_owner uuid, p_campaign uuid)
returns text
language sql immutable
set search_path = public, pg_temp
as $$ select case when p_owner is null then 'official' when p_campaign is null then 'private' else 'campaign' end; $$;

-- ---- private homebrew may only sit in the owner's own character inventories ------------------------------
create function public.inventory_items_item_visibility_check()
returns trigger
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare it public.items; inv public.inventories; char_owner uuid;
begin
  if new.item_id is null then return new; end if;
  if tg_op = 'UPDATE' and new.item_id is not distinct from old.item_id and new.inventory_id = old.inventory_id then return new; end if;
  select * into it from public.items where id = new.item_id;
  if it.owner_id is not null and it.campaign_id is null then
    select * into inv from public.inventories where id = new.inventory_id;
    select owner_id into char_owner from public.characters where id = inv.character_id;
    if inv.kind <> 'character' or char_owner is distinct from it.owner_id then
      raise exception 'Private homebrew can only be in its author''s own characters. Share it with the campaign first.' using errcode = '42501';
    end if;
  end if;
  return new;
end;
$$;
revoke all on function public.inventory_items_item_visibility_check() from public, anon, authenticated;

create trigger inventory_items_item_visibility_check before insert or update of item_id, inventory_id on public.inventory_items
  for each row execute function public.inventory_items_item_visibility_check();

-- ---- homebrew validation and write (internal) ------------------------------------------------------------------
-- p_def keys: name, kind_id, category_id, description, weight_lb, cost_value, cost_unit, rarity_id, is_magic,
--             requires_attunement, is_consumable, stackable, campaign_id
-- p_stats keys by kind: weapon {weapon_group, damage_dice, damage_type_id, versatile_damage, range_normal, range_max,
--   ammo_type_id, properties[], reload, misfire}; armor {base_ac, ac_bonus, dex_modifier_mode, dex_cap,
--   strength_requirement, stealth_disadvantage}; ammunition {ammo_type_id, pack_size}; any kind {container{...}, effect{...}}
create function public._write_homebrew(p_id text, p_def jsonb, p_stats jsonb, p_is_new boolean)
returns void
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  allowed_def constant text[] := array['name','kind_id','category_id','description','weight_lb','cost_value','cost_unit','rarity_id',
                                       'is_magic','requires_attunement','is_consumable','stackable','campaign_id'];
  k text; prev public.items;
  v_name text; v_kind text; v_cat text; v_desc text; v_weight numeric; v_cost numeric; v_unit text; v_rarity text;
  v_magic boolean; v_att boolean; v_cons boolean; v_stack boolean; v_campaign uuid;
  s jsonb := coalesce(p_stats, '{}'::jsonb); w jsonb; a jsonb; c jsonb; e jsonb;
  dice_re constant text := '^([1-9][0-9]?d(4|6|8|10|12|20|100)([+-][0-9]{1,3})?|[0-9]{1,3})$';
  props text[]; grp text; rtype text; v_ammo text; rn int; rm int; vd text; dd text; dt text; mode text; cap int;
  is_shield boolean; base int; bonus int;
begin
  if p_def is null or jsonb_typeof(p_def) <> 'object' then raise exception 'Item definition is missing' using errcode = '22023'; end if;
  for k in select jsonb_object_keys(p_def) loop
    if not k = any (allowed_def) then raise exception 'Field "%" cannot be set on a homebrew item', k using errcode = '22023'; end if;
  end loop;
  for k in select jsonb_object_keys(s) loop
    if not k = any (array['weapon','armor','ammunition','container','effect']) then raise exception 'Unknown stats section "%"', k using errcode = '22023'; end if;
  end loop;

  if not p_is_new then select * into prev from public.items where id = p_id; end if;

  v_name := public._j_text(p_def, 'name', 120, 'Name');
  if v_name is null then raise exception 'Name is required' using errcode = '22023'; end if;
  v_kind := coalesce(public._j_text(p_def, 'kind_id', 40, 'Type'), prev.kind_id);
  if not p_is_new and v_kind is distinct from prev.kind_id then
    raise exception 'The type of a homebrew item cannot change; create a new item instead' using errcode = '22023';
  end if;
  if v_kind is null or not v_kind = any (array['weapon','armor','tool','gear','ammunition','potion','scroll','magic_item']) then
    raise exception 'Type must be one of weapon, armor, tool, gear, ammunition, potion, scroll, magic item' using errcode = '22023';
  end if;
  v_cat := public._j_text(p_def, 'category_id', 60, 'Category');
  if v_cat is not null and not exists (select 1 from public.item_categories where id = v_cat and kind_id = v_kind) then
    raise exception 'Category "%" does not belong to type "%"', v_cat, v_kind using errcode = '22023';
  end if;
  if v_kind = 'armor' and v_cat is null then raise exception 'Armor needs a category (light, medium, heavy armor or shield)' using errcode = '22023'; end if;
  v_desc := public._j_text(p_def, 'description', 4000, 'Description');
  v_weight := public._j_num(p_def, 'weight_lb', 0, 100000, 'Weight');
  v_cost := public._j_num(p_def, 'cost_value', 0, 100000000, 'Cost');
  v_unit := public._j_text(p_def, 'cost_unit', 2, 'Cost unit');
  if (v_cost is null) <> (v_unit is null) then raise exception 'Cost needs both an amount and a coin' using errcode = '22023'; end if;
  if v_unit is not null and not exists (select 1 from public.currencies where id = v_unit) then raise exception 'Unknown coin "%"', v_unit using errcode = '22023'; end if;
  v_rarity := public._j_text(p_def, 'rarity_id', 20, 'Rarity');
  if v_rarity is not null and not exists (select 1 from public.rarities where id = v_rarity) then raise exception 'Unknown rarity "%"', v_rarity using errcode = '22023'; end if;
  v_magic := public._j_bool(p_def, 'is_magic', false);
  if v_magic and v_rarity is null then raise exception 'A magic item needs a rarity' using errcode = '22023'; end if;
  v_att := public._j_bool(p_def, 'requires_attunement', false);
  v_cons := public._j_bool(p_def, 'is_consumable', v_kind in ('potion', 'scroll', 'ammunition'));
  if v_kind in ('potion', 'scroll') and not v_cons then raise exception 'Potions and scrolls are consumable' using errcode = '22023'; end if;
  v_stack := public._j_bool(p_def, 'stackable', v_kind in ('potion', 'scroll', 'ammunition'));
  if not p_is_new and not p_def ? 'campaign_id' then
    v_campaign := prev.campaign_id;            -- an update that does not mention visibility keeps it
  else
    begin
      v_campaign := nullif(p_def ->> 'campaign_id', '')::uuid;
    exception when others then raise exception 'Invalid campaign' using errcode = '22023';
    end;
  end if;
  if p_is_new or v_campaign is distinct from prev.campaign_id then
    if v_campaign is not null and not (public.is_admin() or public.is_campaign_member(v_campaign)) then
      raise exception 'You are not a member of that campaign' using errcode = '42501';
    end if;
    if not p_is_new and not (prev.owner_id = auth.uid() or public.is_admin()) then
      raise exception 'Only the author can change who can see this item' using errcode = '42501';
    end if;
    if not p_is_new and v_campaign is null and exists (
         select 1 from public.inventory_items ii join public.inventories inv on inv.id = ii.inventory_id
         left join public.characters ch on ch.id = inv.character_id
         where ii.item_id = p_id and (inv.kind <> 'character' or ch.owner_id is distinct from prev.owner_id)) then
      raise exception 'This item is used in other characters'' inventories and cannot become private' using errcode = '22023';
    end if;
  end if;

  -- typed stats (validated before anything is written)
  w := s -> 'weapon'; a := s -> 'armor'; c := s -> 'container'; e := s -> 'effect';
  if w is not null and v_kind <> 'weapon' then raise exception 'Weapon stats only apply to weapons' using errcode = '22023'; end if;
  if a is not null and v_kind <> 'armor' then raise exception 'Armor stats only apply to armor' using errcode = '22023'; end if;
  if s ? 'ammunition' and v_kind <> 'ammunition' then raise exception 'Ammunition stats only apply to ammunition' using errcode = '22023'; end if;
  if v_kind = 'weapon' then
    w := coalesce(w, '{}'::jsonb);
    grp := coalesce(public._j_text(w, 'weapon_group', 10, 'Weapon group'), case when v_cat = 'firearm' then 'firearm' when v_cat like 'simple%' then 'simple' else 'martial' end);
    if grp not in ('simple', 'martial', 'firearm') then raise exception 'Weapon group must be simple, martial or firearm' using errcode = '22023'; end if;
    if (grp = 'firearm') <> (v_cat = 'firearm') and v_cat is not null then
      raise exception 'Firearms use the firearm category and weapon group together' using errcode = '22023';
    end if;
    dd := public._j_text(w, 'damage_dice', 12, 'Damage dice');
    if dd is not null and dd !~ dice_re then raise exception 'Damage dice must look like 1d8, 2d6+1 or a flat number' using errcode = '22023'; end if;
    dt := public._j_text(w, 'damage_type_id', 20, 'Damage type');
    if dt is not null and not exists (select 1 from public.damage_types where id = dt) then raise exception 'Unknown damage type "%"', dt using errcode = '22023'; end if;
    if dt is not null and dd is null then raise exception 'A damage type needs damage dice' using errcode = '22023'; end if;
    props := coalesce(array(select jsonb_array_elements_text(coalesce(w -> 'properties', '[]'::jsonb))), '{}');
    if exists (select 1 from unnest(props) p where not exists (select 1 from public.weapon_properties wp where wp.id = p)) then
      raise exception 'Unknown weapon property' using errcode = '22023';
    end if;
    vd := public._j_text(w, 'versatile_damage', 12, 'Versatile damage');
    if vd is not null and not 'versatile' = any (props) then raise exception 'Versatile damage needs the versatile property' using errcode = '22023'; end if;
    if vd is not null and vd !~ dice_re then raise exception 'Versatile damage must look like 1d10' using errcode = '22023'; end if;
    rn := public._j_int(w, 'range_normal', 1, 10000, 'Normal range');
    rm := public._j_int(w, 'range_max', 1, 10000, 'Maximum range');
    if (rn is null) <> (rm is null) then raise exception 'Give both the normal and the maximum range' using errcode = '22023'; end if;
    if rm < rn then raise exception 'The maximum range cannot be smaller than the normal range' using errcode = '22023'; end if;
    v_ammo := public._j_text(w, 'ammo_type_id', 60, 'Ammunition type');
    if v_ammo is not null and not exists (select 1 from public.ammo_types where id = v_ammo) then raise exception 'Unknown ammunition type' using errcode = '22023'; end if;
    if v_ammo is not null and not 'ammunition' = any (props) then raise exception 'An ammunition type needs the ammunition property' using errcode = '22023'; end if;
    rtype := case when 'ammunition' = any (props) then 'ammunition' when 'thrown' = any (props) then 'thrown' end;
    if grp = 'firearm' and (public._j_int(w, 'reload', 1, 50, 'Reload') is null or public._j_int(w, 'misfire', 1, 20, 'Misfire') is null) then
      raise exception 'A firearm needs reload and misfire' using errcode = '22023';
    end if;
    if grp <> 'firearm' and (w ? 'reload' or w ? 'misfire') and (w ->> 'reload' is not null or w ->> 'misfire' is not null) then
      raise exception 'Reload and misfire only apply to firearms' using errcode = '22023';
    end if;
  end if;
  if v_kind = 'armor' then
    a := coalesce(a, '{}'::jsonb);
    is_shield := v_cat = 'shield';
    if is_shield then
      bonus := public._j_int(a, 'ac_bonus', 0, 10, 'AC bonus');
      if bonus is null then raise exception 'A shield needs an AC bonus' using errcode = '22023'; end if;
      if a ->> 'base_ac' is not null then raise exception 'A shield uses an AC bonus, not a base AC' using errcode = '22023'; end if;
      mode := 'none'; cap := null;
    else
      base := public._j_int(a, 'base_ac', 1, 30, 'Base AC');
      if base is null then raise exception 'Armor needs a base AC' using errcode = '22023'; end if;
      mode := coalesce(public._j_text(a, 'dex_modifier_mode', 10, 'Dexterity mode'),
                       case v_cat when 'light-armor' then 'full' when 'medium-armor' then 'capped' else 'none' end);
      if mode not in ('full', 'capped', 'none') then raise exception 'Dexterity mode must be full, capped or none' using errcode = '22023'; end if;
      cap := public._j_int(a, 'dex_cap', 0, 10, 'Dexterity cap');
      if mode = 'capped' then cap := coalesce(cap, 2); elsif cap is not null then raise exception 'A Dexterity cap only applies to capped mode' using errcode = '22023'; end if;
    end if;
    perform public._j_int(a, 'strength_requirement', 1, 30, 'Strength requirement');
  end if;
  if v_kind = 'ammunition' then
    if public._j_text(s -> 'ammunition', 'ammo_type_id', 60, 'Ammunition type') is null
       or not exists (select 1 from public.ammo_types where id = s -> 'ammunition' ->> 'ammo_type_id') then
      raise exception 'Ammunition needs a known ammunition type' using errcode = '22023';
    end if;
    perform public._j_int(s -> 'ammunition', 'pack_size', 1, 1000, 'Pack size');
  end if;
  if c is not null then
    perform public._j_num(c, 'capacity_weight_lb', 0, 100000, 'Capacity (weight)');
    perform public._j_num(c, 'capacity_volume_cuft', 0, 100000, 'Capacity (volume)');
    perform public._j_bool(c, 'weightless_contents', false);
    perform public._j_bool(c, 'extradimensional', false);
  end if;
  if e is not null then
    if not v_cons then raise exception 'Only consumable items can have a use effect' using errcode = '22023'; end if;
    if coalesce(e ->> 'effect_type', '') not in ('healing', 'damage', 'buff', 'condition', 'cast_spell', 'other') then
      raise exception 'Unknown effect type' using errcode = '22023';
    end if;
    if public._j_text(e, 'dice_expression', 12, 'Effect dice') !~ '^[1-9][0-9]?d[0-9]{1,3}$' then
      raise exception 'Effect dice must look like 2d4 (put the bonus in the flat value)' using errcode = '22023';
    end if;
    perform public._j_int(e, 'flat_value', -1000, 1000, 'Flat value');
    if e ->> 'effect_type' in ('healing', 'damage') and e ->> 'dice_expression' is null and e ->> 'flat_value' is null then
      raise exception 'Healing and damage need dice or a flat value' using errcode = '22023';
    end if;
    if e ->> 'damage_type_id' is not null and (e ->> 'effect_type' <> 'damage' or not exists (select 1 from public.damage_types where id = e ->> 'damage_type_id')) then
      raise exception 'A damage type only applies to a damage effect' using errcode = '22023';
    end if;
    perform public._j_text(e, 'duration', 100, 'Duration');
    if e ->> 'target_type' is not null and e ->> 'target_type' not in ('self', 'creature', 'area', 'object') then
      raise exception 'Unknown target type' using errcode = '22023';
    end if;
  end if;

  -- write the item
  if p_is_new then
    insert into public.items (id, kind_id, category_id, name, description, weight_lb, cost_value, cost_unit, rarity_id, is_magic,
                              requires_attunement, is_consumable, stackable, owner_id, campaign_id, data_source_id, source_label, updated_by)
    values (p_id, v_kind, v_cat, v_name, v_desc, v_weight, v_cost, v_unit, v_rarity, v_magic, v_att, v_cons, v_stack,
            auth.uid(), v_campaign, 'homebrew', 'Homebrew', auth.uid());
  else
    update public.items set category_id = v_cat, name = v_name, description = v_desc, weight_lb = v_weight, cost_value = v_cost,
           cost_unit = v_unit, rarity_id = v_rarity, is_magic = v_magic, requires_attunement = v_att, is_consumable = v_cons,
           stackable = v_stack, campaign_id = v_campaign, updated_by = auth.uid()
    where id = p_id;
    delete from public.weapon_stats where item_id = p_id;          -- cascades property links and firearm stats
    delete from public.armor_stats where item_id = p_id;
    delete from public.ammunition_stats where item_id = p_id;
    delete from public.container_stats where item_id = p_id;
    delete from public.consumable_effects where item_id = p_id;
  end if;

  -- write the typed stats
  if v_kind = 'weapon' then
    insert into public.weapon_stats (item_id, weapon_group, damage_dice, damage_type_id, versatile_damage, is_ranged, range_type,
                                     range_normal, range_max, ammo_type_id)
    values (p_id, grp, dd, dt, vd, grp = 'firearm' or coalesce(v_cat, '') like '%ranged' or 'ammunition' = any (props), rtype, rn, rm, v_ammo);
    insert into public.weapon_property_links (item_id, property_id) select p_id, p from unnest(props) p on conflict do nothing;
    if grp = 'firearm' then
      insert into public.firearm_stats (item_id, reload, misfire) values (p_id, (w ->> 'reload')::int, (w ->> 'misfire')::int);
    end if;
  elsif v_kind = 'armor' then
    insert into public.armor_stats (item_id, base_ac, ac_bonus, dex_modifier_mode, dex_cap, strength_requirement, stealth_disadvantage, is_shield)
    values (p_id, case when is_shield then null else base end, case when is_shield then bonus end, mode, cap,
            public._j_int(a, 'strength_requirement', 1, 30, 'Strength requirement'), public._j_bool(a, 'stealth_disadvantage', false), is_shield);
  elsif v_kind = 'ammunition' then
    insert into public.ammunition_stats (item_id, ammo_type_id, pack_size, pack_cost_cp)
    values (p_id, s -> 'ammunition' ->> 'ammo_type_id', coalesce(public._j_int(s -> 'ammunition', 'pack_size', 1, 1000, 'Pack size'), 1),
            (select cost_cp from public.items where id = p_id));
  end if;
  if c is not null then
    insert into public.container_stats (item_id, capacity_weight_lb, capacity_volume_cuft, weightless_contents, extradimensional)
    values (p_id, public._j_num(c, 'capacity_weight_lb', 0, 100000, 'Capacity (weight)'), public._j_num(c, 'capacity_volume_cuft', 0, 100000, 'Capacity (volume)'),
            public._j_bool(c, 'weightless_contents', false), public._j_bool(c, 'extradimensional', false));
  end if;
  if e is not null then
    insert into public.consumable_effects (item_id, seq, effect_type, dice_expression, flat_value, damage_type_id, duration, target_type)
    values (p_id, 1, e ->> 'effect_type', public._j_text(e, 'dice_expression', 12, 'Effect dice'), public._j_int(e, 'flat_value', -1000, 1000, 'Flat value'),
            public._j_text(e, 'damage_type_id', 20, 'Damage type'), public._j_text(e, 'duration', 100, 'Duration'), public._j_text(e, 'target_type', 10, 'Target'));
  end if;
end;
$$;

create function public._homebrew_json(p_id text)
returns jsonb
language sql stable security definer
set search_path = public, pg_temp
as $$
  select to_jsonb(c) || jsonb_build_object(
    'usage_count', (select count(*) from public.inventory_items where item_id = p_id),
    'container', (select to_jsonb(x) - 'item_id' from public.container_stats x where x.item_id = p_id),
    'effect', (select to_jsonb(x) - 'item_id' from public.consumable_effects x where x.item_id = p_id and x.seq = 1))
  from public.v_item_catalog c where c.id = p_id;
$$;

create function public._lock_homebrew(p_id text)
returns public.items
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare it public.items;
begin
  select * into it from public.items where id = p_id for update;
  if it.id is null or not public.can_view_owned(it.owner_id, it.campaign_id) then raise exception 'Unknown item' using errcode = 'P0002'; end if;
  if it.owner_id is null then raise exception 'Official items cannot be changed' using errcode = '42501'; end if;
  if not public.can_edit_owned(it.owner_id, it.campaign_id) then raise exception 'Not allowed to change this homebrew item' using errcode = '42501'; end if;
  return it;
end;
$$;

-- ---- homebrew RPCs -------------------------------------------------------------------------------------------
-- p_request_id: a uuid generated by the client per "create" attempt; repeating the call returns the same item.
create function public.create_homebrew_item(p_request_id uuid, p_definition jsonb, p_stats jsonb default '{}'::jsonb)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare v_id text; ex public.items;
begin
  if auth.uid() is null then raise exception 'Not authenticated' using errcode = '42501'; end if;
  if p_request_id is null then raise exception 'A request id is required' using errcode = '22023'; end if;
  v_id := 'hb-' || p_request_id::text;
  select * into ex from public.items where id = v_id;
  if ex.id is not null then
    if ex.owner_id = auth.uid() then return public._homebrew_json(v_id) || '{"replayed": true}'; end if;
    raise exception 'This request id was already used' using errcode = '23505';
  end if;
  perform public._write_homebrew(v_id, p_definition, p_stats, true);
  insert into public.homebrew_item_events (item_id, actor_id, action, changes)
  values (v_id, auth.uid(), 'create', jsonb_build_object('definition', p_definition, 'stats', p_stats));
  return public._homebrew_json(v_id);
end;
$$;

-- The type (kind) cannot change. Only the author (or an admin) may change who can see it; a campaign DM may edit the rest.
create function public.update_homebrew_item(p_item text, p_definition jsonb, p_stats jsonb default '{}'::jsonb)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare it public.items; before jsonb;
begin
  it := public._lock_homebrew(p_item);
  if it.archived_at is not null then raise exception 'Restore the item before editing it' using errcode = '22023'; end if;
  before := public._homebrew_json(p_item);
  perform public._write_homebrew(p_item, p_definition || jsonb_build_object('kind_id', coalesce(p_definition ->> 'kind_id', it.kind_id)), p_stats, false);
  insert into public.homebrew_item_events (item_id, actor_id, action, changes)
  values (p_item, auth.uid(), 'update', jsonb_build_object('before', before, 'definition', p_definition, 'stats', p_stats));
  return public._homebrew_json(p_item);
end;
$$;

create function public.archive_homebrew_item(p_item text)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare it public.items;
begin
  it := public._lock_homebrew(p_item);
  if it.archived_at is null then
    update public.items set archived_at = now(), archived_by = auth.uid(), updated_by = auth.uid() where id = p_item;
    insert into public.homebrew_item_events (item_id, actor_id, action) values (p_item, auth.uid(), 'archive');
  end if;
  return public._homebrew_json(p_item);
end;
$$;

create function public.restore_homebrew_item(p_item text)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare it public.items;
begin
  it := public._lock_homebrew(p_item);
  if it.archived_at is not null then
    update public.items set archived_at = null, archived_by = null, updated_by = auth.uid() where id = p_item;
    insert into public.homebrew_item_events (item_id, actor_id, action) values (p_item, auth.uid(), 'restore');
  end if;
  return public._homebrew_json(p_item);
end;
$$;

-- Number of inventory entries using a homebrew item (aggregate only: no names of other characters).
create function public.homebrew_usage_count(p_item text)
returns int
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
declare it public.items;
begin
  select * into it from public.items where id = p_item;
  if it.id is null or not public.can_edit_owned(it.owner_id, it.campaign_id) then raise exception 'Not allowed' using errcode = '42501'; end if;
  return (select count(*) from public.inventory_items where item_id = p_item);
end;
$$;

-- ---- customized inventory instance -------------------------------------------------------------------------------
-- Only per-piece fields. Catalog fields (name, kind, rarity, …) are never touched here.
create function public.update_inventory_item_details(p_item uuid, p_details jsonb)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  r public.inventory_items; k text; res jsonb;
  allowed constant text[] := array['custom_name','notes','is_quest_item','durability','charges_current','charges_max',
                                   'charges_recharge','state','consumable_override'];
begin
  perform public._rpc_begin();
  if p_details is null or jsonb_typeof(p_details) <> 'object' then raise exception 'Nothing to change' using errcode = '22023'; end if;
  for k in select jsonb_object_keys(p_details) loop
    if not k = any (allowed) then raise exception 'Field "%" cannot be changed on an inventory item', k using errcode = '22023'; end if;
  end loop;
  r := public._lock_item(p_item);
  if not public.can_write_inventory(r.inventory_id) then raise exception 'Not allowed' using errcode = '42501'; end if;
  if p_details ? 'state' and (jsonb_typeof(p_details -> 'state') <> 'object' or length((p_details -> 'state')::text) > 4000) then
    raise exception 'State must be a small JSON object' using errcode = '22023';
  end if;
  update public.inventory_items set
    custom_name        = case when p_details ? 'custom_name' then public._j_text(p_details, 'custom_name', 120, 'Custom name') else custom_name end,
    notes              = case when p_details ? 'notes' then public._j_text(p_details, 'notes', 4000, 'Notes') else notes end,
    is_quest_item      = case when p_details ? 'is_quest_item' then public._j_bool(p_details, 'is_quest_item', false) else is_quest_item end,
    durability         = case when p_details ? 'durability' then public._j_int(p_details, 'durability', 0, 1000000, 'Durability') else durability end,
    charges_current    = case when p_details ? 'charges_current' then public._j_int(p_details, 'charges_current', 0, 1000, 'Charges') else charges_current end,
    charges_max        = case when p_details ? 'charges_max' then public._j_int(p_details, 'charges_max', 0, 1000, 'Maximum charges') else charges_max end,
    charges_recharge   = case when p_details ? 'charges_recharge' then public._j_text(p_details, 'charges_recharge', 100, 'Recharge') else charges_recharge end,
    state              = case when p_details ? 'state' then p_details -> 'state' else state end,
    consumable_override = case when p_details ? 'consumable_override' then
                            case when jsonb_typeof(p_details -> 'consumable_override') = 'null' then null else public._j_bool(p_details, 'consumable_override', null) end
                          else consumable_override end
  where id = r.id;
  select to_jsonb(d) into res from public.v_inventory_detail d where d.id = r.id;
  perform public._rpc_end(); return res;
end;
$$;

-- ---- legacy items: candidates, comparison, link, convert, equipment review -------------------------------------------------
-- Candidates for a legacy row: 'exact' (same normalised name) and 'probable' (plural, "… armor", leading article, prefix).
-- Never applied automatically.
create function public.find_link_candidates(p_item uuid)
returns jsonb
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
declare r public.inventory_items; n text;
begin
  select * into r from public.inventory_items where id = p_item;
  if r.id is null or not public.can_read_inventory(r.inventory_id) then raise exception 'Inventory item not found' using errcode = 'P0002'; end if;
  n := public._norm_name(r.name);
  if n = '' then return '[]'::jsonb; end if;
  return coalesce((
    select jsonb_agg(x order by x ->> 'confidence', (x ->> 'visibility') <> 'official', x ->> 'name')
    from (
      select jsonb_build_object('item_id', i.id, 'name', i.name, 'kind_id', i.kind_id, 'category_id', i.category_id, 'rarity_id', i.rarity_id,
                                'weight_lb', i.weight_lb, 'stackable', i.stackable, 'is_magic', i.is_magic,
                                'visibility', public.item_visibility(i.owner_id, i.campaign_id),
                                'confidence', case when public._norm_name(i.name) = n then 'exact' else 'probable' end) as x
      from public.items i
      where i.archived_at is null and public.can_view_owned(i.owner_id, i.campaign_id)
        and (public._norm_name(i.name) = n
             or public._norm_name(i.name) = regexp_replace(n, 's$', '')
             or public._norm_name(i.name) = regexp_replace(n, 'es$', '')
             or public._norm_name(i.name) = n || 's'
             or public._norm_name(i.name) = regexp_replace(n, ' armou?r$', '')
             or public._norm_name(i.name) = regexp_replace(n, '^(a|an|the|some) ', '')
             or (length(n) >= 4 and public._norm_name(i.name) like n || ' %'))
      limit 12) s), '[]'::jsonb);
end;
$$;

-- Comparison of a legacy row with a catalog item and what linking would do (no changes).
create function public._link_plan(r public.inventory_items, it public.items)
returns jsonb
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
declare
  changes jsonb := '[]'::jsonb; warnings jsonb := '[]'::jsonb; keep_name text; notes text := r.notes; review boolean;
begin
  if public._norm_name(r.name) <> public._norm_name(it.name) and r.custom_name is null then keep_name := r.name; end if;
  if public._norm_name(r.name) <> public._norm_name(it.name) then
    changes := changes || jsonb_build_object('field', 'name', 'legacy', r.name, 'catalog', it.name,
                                             'result', coalesce(keep_name, r.custom_name) || ' (custom name)');
  end if;
  if coalesce(btrim(r.description), '') <> '' and coalesce(r.description, '') <> coalesce(it.description, '') then
    notes := concat_ws(E'\n', nullif(notes, ''), 'Legacy description: ' || r.description);
    changes := changes || jsonb_build_object('field', 'description', 'legacy', r.description, 'catalog', it.description,
                                             'result', 'kept in personal notes');
  end if;
  if coalesce(r.weight, 0) <> coalesce(it.weight_lb, 0) then
    changes := changes || jsonb_build_object('field', 'weight', 'legacy', r.weight, 'catalog', it.weight_lb,
                                             'result', case when it.weight_lb is null then 'catalog weight unknown; legacy weight kept in notes' else 'catalog weight is used' end);
    if it.weight_lb is null and coalesce(r.weight, 0) > 0 then notes := concat_ws(E'\n', nullif(notes, ''), 'Legacy weight: ' || r.weight || ' lb'); end if;
  end if;
  if r.quantity > 1 and not it.stackable then
    warnings := warnings || to_jsonb('This item does not stack; the ' || r.quantity || ' pieces stay in one entry until one is equipped or split.');
  end if;
  if it.archived_at is not null then warnings := warnings || to_jsonb('The catalog item is archived.'::text); end if;
  review := exists (select 1 from public.legacy_inventory_review x where x.inventory_item_id = r.id
                    and x.category like 'equipped%' and x.status in ('pending', 'manual_review'));
  if review then warnings := warnings || to_jsonb('This item was equipped in the old sheet: choose its slot after linking.'::text); end if;
  return jsonb_build_object(
    'inventory_item_id', r.id,
    'legacy', jsonb_build_object('name', r.name, 'description', r.description, 'weight', r.weight, 'quantity', r.quantity,
                                 'custom_name', r.custom_name, 'notes', r.notes, 'is_quest_item', r.is_quest_item),
    'catalog', jsonb_build_object('item_id', it.id, 'name', it.name, 'description', it.description, 'weight_lb', it.weight_lb,
                                  'kind_id', it.kind_id, 'category_id', it.category_id, 'is_magic', it.is_magic, 'rarity_id', it.rarity_id,
                                  'stackable', it.stackable, 'visibility', public.item_visibility(it.owner_id, it.campaign_id)),
    'changes', changes,
    'preserved', jsonb_build_object('custom_name', coalesce(r.custom_name, keep_name), 'notes', notes, 'quantity', r.quantity,
                                    'is_quest_item', r.is_quest_item),
    'warnings', warnings,
    'equipment_review_required', review);
end;
$$;

create function public._legacy_row_for_link(p_item uuid)
returns public.inventory_items
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare r public.inventory_items;
begin
  r := public._lock_item(p_item);
  if not public.can_write_inventory(r.inventory_id) then raise exception 'Not allowed' using errcode = '42501'; end if;
  if r.item_id is not null then raise exception 'This item is already linked to the catalog' using errcode = '22023'; end if;
  if r.quantity < 1 then raise exception 'A legacy item with quantity 0 cannot be linked; remove it instead' using errcode = '22023'; end if;
  return r;
end;
$$;

create function public._apply_link(r public.inventory_items, it public.items, p_category text)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare plan jsonb := public._link_plan(r, it);
begin
  update public.inventory_items set
    item_id = it.id, name = it.name, weight = coalesce(it.weight_lb, 0),
    custom_name = plan -> 'preserved' ->> 'custom_name', notes = plan -> 'preserved' ->> 'notes'
  where id = r.id;
  insert into public.legacy_inventory_review (inventory_item_id, character_id, legacy_name, legacy_quantity, legacy_equipped, category, status, detail, resolved_at)
  values (r.id, r.character_id, r.name, r.quantity, null, p_category, 'done', plan, now());
  perform public.log_inventory_event(r.inventory_id, r.id, 'link', null, it.id, jsonb_build_object('legacy', plan -> 'legacy', 'changes', plan -> 'changes'));
  return plan || jsonb_build_object('linked', true);
end;
$$;

create function public.preview_link_inventory_item(p_item uuid, p_catalog_item text)
returns jsonb
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
declare r public.inventory_items; it public.items;
begin
  select * into r from public.inventory_items where id = p_item;
  if r.id is null or not public.can_write_inventory(r.inventory_id) then raise exception 'Not allowed' using errcode = '42501'; end if;
  if r.item_id is not null then raise exception 'This item is already linked to the catalog' using errcode = '22023'; end if;
  select * into it from public.items where id = p_catalog_item;
  if it.id is null or not public.can_view_owned(it.owner_id, it.campaign_id) then raise exception 'Unknown catalog item' using errcode = 'P0002'; end if;
  return public._link_plan(r, it);
end;
$$;

-- link_inventory_item now returns the comparison (linked row, preserved and changed fields, warnings, equipment review).
drop function public.link_inventory_item(uuid, text);
create function public.link_inventory_item(p_item uuid, p_catalog_item text)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare r public.inventory_items; it public.items; res jsonb;
begin
  perform public._rpc_begin();
  r := public._legacy_row_for_link(p_item);
  select * into it from public.items where id = p_catalog_item;
  if it.id is null or not public.can_view_owned(it.owner_id, it.campaign_id) then raise exception 'Unknown catalog item' using errcode = 'P0002'; end if;
  if it.archived_at is not null then raise exception 'This homebrew item is archived' using errcode = '22023'; end if;
  res := public._apply_link(r, it, 'linked_by_user');
  perform public._rpc_end(); return res;
end;
$$;

-- One transaction: create the homebrew item from the (edited) legacy data and link the legacy row to it.
-- p_request_id makes it idempotent: a retry returns the first result instead of creating a second item.
create function public.convert_legacy_item_to_homebrew(p_item uuid, p_request_id uuid, p_definition jsonb, p_stats jsonb default '{}'::jsonb)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare r public.inventory_items; it public.items; v_id text; res jsonb;
begin
  perform public._rpc_begin();
  if p_request_id is null then raise exception 'A request id is required' using errcode = '22023'; end if;
  v_id := 'hb-' || p_request_id::text;
  r := public._lock_item(p_item);
  if not public.can_write_inventory(r.inventory_id) then raise exception 'Not allowed' using errcode = '42501'; end if;
  if r.item_id = v_id then   -- retry of a request that already succeeded
    res := jsonb_build_object('item', public._homebrew_json(v_id), 'link', (select detail from public.legacy_inventory_review
             where inventory_item_id = r.id and category = 'converted_to_homebrew' order by id desc limit 1), 'replayed', true);
    perform public._rpc_end(); return res;
  end if;
  r := public._legacy_row_for_link(p_item);
  if exists (select 1 from public.items where id = v_id) then raise exception 'This request id was already used' using errcode = '23505'; end if;
  perform public._write_homebrew(v_id, p_definition, p_stats, true);
  select * into it from public.items where id = v_id;
  insert into public.homebrew_item_events (item_id, actor_id, action, changes)
  values (v_id, auth.uid(), 'convert', jsonb_build_object('legacy_inventory_item', r.id, 'legacy_name', r.name, 'legacy_description', r.description,
                                                          'legacy_weight', r.weight, 'definition', p_definition, 'stats', p_stats));
  res := jsonb_build_object('item', public._homebrew_json(v_id), 'link', public._apply_link(r, it, 'converted_to_homebrew'));
  perform public._rpc_end(); return res;
end;
$$;

-- "This legacy item is not equipped" (the other answer is to equip it, which resolves the review automatically).
create function public.resolve_equipment_review(p_item uuid)
returns int
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare r public.inventory_items; n int;
begin
  select * into r from public.inventory_items where id = p_item;
  if r.id is null or not public.can_write_inventory(r.inventory_id) then raise exception 'Not allowed' using errcode = '42501'; end if;
  update public.legacy_inventory_review set status = 'resolved', resolved_at = now(), detail = detail || '{"resolution": "not equipped"}'
  where inventory_item_id = p_item and category like 'equipped%' and status in ('pending', 'manual_review');
  get diagnostics n = row_count;
  return n;
end;
$$;

-- equipping an item resolves its open equipment review
create or replace function public.character_equipment_after_write()
returns trigger
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare iid uuid := coalesce(new.inventory_item_id, old.inventory_item_id); r public.inventory_items;
begin
  select * into r from public.inventory_items where id = iid;
  if r.id is not null then
    update public.inventory_items set stack_key = public.compute_stack_key(r) where id = iid;
    perform public.log_inventory_event(r.inventory_id, r.id, case tg_op when 'DELETE' then 'unequip' else 'equip' end, null, r.item_id,
      jsonb_build_object('slot', coalesce(new.slot_id, old.slot_id)));
    if tg_op = 'INSERT' then
      update public.legacy_inventory_review set status = 'resolved', resolved_at = now(),
             detail = detail || jsonb_build_object('resolution', 'equipped', 'slot', new.slot_id)
      where inventory_item_id = iid and category like 'equipped%' and status in ('pending', 'manual_review');
    end if;
  end if;
  return null;
end;
$$;

-- ---- adding items: archived homebrew cannot be added -------------------------------------------------------------
create or replace function public.add_inventory_item(
  p_inventory uuid, p_item text, p_quantity int default 1,
  p_custom_name text default null, p_notes text default null, p_state jsonb default '{}'::jsonb)
returns uuid
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare it public.items; remaining int := p_quantity; chunk int; rid uuid; last_id uuid;
begin
  perform public._rpc_begin();
  if auth.uid() is null then raise exception 'Not authenticated' using errcode = '42501'; end if;
  if p_quantity is null or p_quantity < 1 then raise exception 'Quantity must be at least 1'; end if;
  if not public.can_deposit_inventory(p_inventory) then raise exception 'Not allowed to add items to this inventory' using errcode = '42501'; end if;
  if not public.can_view_item(p_item) then raise exception 'Unknown item' using errcode = 'P0002'; end if;
  select * into it from public.items where id = p_item;
  if it.archived_at is not null then raise exception 'This homebrew item is archived and cannot be added' using errcode = '22023'; end if;

  while remaining > 0 loop
    chunk := case when it.stackable then least(remaining, coalesce(it.stack_max, remaining)) else 1 end;
    insert into public.inventory_items (inventory_id, item_id, quantity, custom_name, notes, state)
    values (p_inventory, p_item, chunk, nullif(btrim(p_custom_name), ''), nullif(btrim(p_notes), ''), coalesce(p_state, '{}'::jsonb))
    returning id into rid;
    last_id := public._try_auto_merge(rid);
    remaining := remaining - chunk;
  end loop;
  perform public.log_inventory_event(p_inventory, last_id, 'add', p_quantity, p_item, '{"via":"rpc"}');
  perform public._rpc_end(); return last_id;
end;
$$;

-- removing ALL pieces also removes legacy rows whose quantity is 0
create or replace function public.remove_inventory_item(p_item uuid, p_quantity int default null)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare r public.inventory_items; q int; gone boolean;
begin
  perform public._rpc_begin();
  r := public._lock_item(p_item);
  if not public.can_write_inventory(r.inventory_id) then raise exception 'Not allowed' using errcode = '42501'; end if;
  q := coalesce(p_quantity, r.quantity);
  gone := p_quantity is null or q = r.quantity;
  if not gone and (q < 1 or q > r.quantity) then raise exception 'Invalid quantity % (have %)', q, r.quantity; end if;
  if gone then
    delete from public.inventory_items where id = r.id;
  else
    update public.inventory_items set quantity = quantity - q where id = r.id;
  end if;
  perform public.log_inventory_event(r.inventory_id, case when gone then null else r.id end, 'remove', -q, r.item_id,
    jsonb_build_object('previous_quantity', r.quantity, 'deleted', gone, 'name', coalesce(r.custom_name, r.name), 'legacy', r.item_id is null,
                       'legacy_description', case when r.item_id is null then r.description end));
  perform public._rpc_end(); return jsonb_build_object('removed', q, 'remaining', case when gone then 0 else r.quantity - q end, 'deleted', gone);
end;
$$;

-- ---- JSON import (js/transfer.js): no legacy rows any more -----------------------------------------------------------
-- Each entry {name, quantity, weight, description}: an exact, unique catalog match is added as that item (the original
-- name becomes the custom name when it differs, the description goes to notes); anything else becomes a homebrew item
-- (gear) — campaign homebrew if the character is in a campaign, otherwise private (only for your own character).
create function public.import_inventory_items(p_character uuid, p_items jsonb)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  inv uuid; ch public.characters; e jsonb; v_name text; v_qty int; v_desc text; v_weight numeric; hit text; n int; hb text;
  matched int := 0; created int := 0; skipped jsonb := '[]'::jsonb; cat_name text;
begin
  if auth.uid() is null then raise exception 'Not authenticated' using errcode = '42501'; end if;
  select * into ch from public.characters where id = p_character;
  select id into inv from public.inventories where character_id = p_character;
  if inv is null or not public.can_write_inventory(inv) then raise exception 'Not allowed' using errcode = '42501'; end if;
  if jsonb_typeof(coalesce(p_items, '[]'::jsonb)) <> 'array' or jsonb_array_length(coalesce(p_items, '[]'::jsonb)) > 500 then
    raise exception 'Expected a list of at most 500 items' using errcode = '22023';
  end if;
  for e in select * from jsonb_array_elements(coalesce(p_items, '[]'::jsonb)) loop
    v_name := left(nullif(btrim(coalesce(e ->> 'name', '')), ''), 120);
    if v_name is null then skipped := skipped || to_jsonb('(unnamed)'::text); continue; end if;
    v_qty := greatest(1, coalesce(public._j_int(e, 'quantity', 0, 100000, 'Quantity of ' || v_name), 1));
    v_desc := left(nullif(btrim(coalesce(e ->> 'description', '')), ''), 4000);
    v_weight := coalesce(public._j_num(e, 'weight', 0, 100000, 'Weight of ' || v_name), 0);
    select count(*), min(id), min(name) into n, hit, cat_name from public.items
    where archived_at is null and public.can_view_owned(owner_id, campaign_id) and public._norm_name(name) = public._norm_name(v_name);
    if n = 1 then
      perform public.add_inventory_item(inv, hit, v_qty, case when lower(v_name) <> lower(cat_name) then v_name end, v_desc);
      matched := matched + 1;
    elsif ch.campaign_id is not null or ch.owner_id = auth.uid() then
      hb := 'hb-' || gen_random_uuid()::text;
      perform public._write_homebrew(hb, jsonb_build_object('name', v_name, 'kind_id', 'gear', 'category_id', 'general',
        'description', v_desc, 'weight_lb', nullif(v_weight, 0), 'campaign_id', ch.campaign_id), '{}'::jsonb, true);
      insert into public.homebrew_item_events (item_id, actor_id, action, changes) values (hb, auth.uid(), 'import', e);
      perform public.add_inventory_item(inv, hb, v_qty);
      created := created + 1;
    else
      skipped := skipped || to_jsonb(v_name);
    end if;
  end loop;
  perform public._rpc_end();
  return jsonb_build_object('matched', matched, 'homebrew_created', created, 'skipped', skipped);
end;
$$;

-- ---- catalog view: visibility, archive state, permissions ---------------------------------------------------------
drop view public.v_item_catalog;
create view public.v_item_catalog with (security_invoker = true) as
select
  i.id, i.name, i.kind_id, k.name as kind_name, i.category_id, c.name as category_name,
  i.rarity_id, i.is_magic, i.requires_attunement, i.is_consumable, i.stackable, i.stack_max,
  i.weight_lb, i.cost_value, i.cost_unit, i.cost_cp, i.base_item_id, i.data_source_id, i.description,
  i.source_book_id, sb.name as source_book_name, i.source_label, i.source_url, i.owner_id, i.campaign_id,
  public.item_visibility(i.owner_id, i.campaign_id) as visibility,
  (i.owner_id is not null and i.owner_id = auth.uid()) as is_mine,
  public.can_edit_owned(i.owner_id, i.campaign_id) as can_edit,
  i.archived_at, i.created_at, i.updated_at,
  ws.weapon_group, ws.damage_dice, ws.damage_type_id, ws.versatile_damage, ws.is_ranged, ws.range_type,
  ws.range_normal, ws.range_max, ws.ammo_type_id as weapon_ammo_type_id, fs.reload, fs.misfire,
  (select coalesce(array_agg(l.property_id order by l.property_id), '{}'::text[])
     from public.weapon_property_links l where l.item_id = i.id) as weapon_properties,
  a.base_ac, a.ac_bonus, a.dex_modifier_mode, a.dex_cap, a.strength_requirement, a.stealth_disadvantage, a.is_shield,
  am.ammo_type_id, am.pack_size, am.pack_cost_cp,
  cs.capacity_weight_lb, cs.capacity_volume_cuft, cs.weightless_contents, cs.extradimensional,
  coalesce(ms.speed_value, vs.speed_value) as speed_value, coalesce(ms.speed_unit, vs.speed_unit) as speed_unit,
  ms.carrying_capacity_lb, vs.cargo_lb,
  (select coalesce(array_agg(t.tag_id order by t.tag_id), '{}'::text[])
     from public.item_tag_links t where t.item_id = i.id) as tag_ids
from public.items i
join public.item_kinds k on k.id = i.kind_id
left join public.item_categories c on c.id = i.category_id
left join public.source_books sb on sb.id = i.source_book_id
left join public.weapon_stats ws on ws.item_id = i.id
left join public.firearm_stats fs on fs.item_id = i.id
left join public.armor_stats a on a.item_id = i.id
left join public.ammunition_stats am on am.item_id = i.id
left join public.container_stats cs on cs.item_id = i.id
left join public.mount_stats ms on ms.item_id = i.id
left join public.vehicle_stats vs on vs.item_id = i.id;

-- ---- privileges and RLS -------------------------------------------------------------------------------------------
-- Inventory rows and homebrew items are written only by SECURITY DEFINER RPCs.
revoke insert, update, delete on public.inventory_items from anon, authenticated;
drop policy "inventory_items_write" on public.inventory_items;
revoke insert, update, delete on public.items from anon, authenticated;
drop policy "items_homebrew_write" on public.items;

alter table public.homebrew_item_events enable row level security;
revoke all on public.homebrew_item_events from anon, authenticated;
create policy "homebrew_item_events_read" on public.homebrew_item_events for select to authenticated
  using (exists (select 1 from public.items i where i.id = item_id and public.can_edit_owned(i.owner_id, i.campaign_id)));
grant select on public.homebrew_item_events to authenticated;

revoke all on public.v_item_catalog from public, anon, authenticated;
grant select on public.v_item_catalog to anon, authenticated;
grant execute on function public.can_edit_owned(uuid, uuid), public.item_visibility(uuid, uuid) to anon, authenticated;

revoke all on function public._norm_name(text), public._j_text(jsonb, text, int, text), public._j_num(jsonb, text, numeric, numeric, text),
  public._j_int(jsonb, text, int, int, text), public._j_bool(jsonb, text, boolean), public._write_homebrew(text, jsonb, jsonb, boolean),
  public._homebrew_json(text), public._lock_homebrew(text), public._link_plan(public.inventory_items, public.items),
  public._legacy_row_for_link(uuid), public._apply_link(public.inventory_items, public.items, text)
  from public, anon, authenticated;
revoke all on function public.create_homebrew_item(uuid, jsonb, jsonb), public.update_homebrew_item(text, jsonb, jsonb),
  public.archive_homebrew_item(text), public.restore_homebrew_item(text), public.homebrew_usage_count(text),
  public.update_inventory_item_details(uuid, jsonb), public.find_link_candidates(uuid), public.preview_link_inventory_item(uuid, text),
  public.link_inventory_item(uuid, text), public.convert_legacy_item_to_homebrew(uuid, uuid, jsonb, jsonb),
  public.resolve_equipment_review(uuid), public.import_inventory_items(uuid, jsonb)
  from public, anon;
grant execute on function public.create_homebrew_item(uuid, jsonb, jsonb), public.update_homebrew_item(text, jsonb, jsonb),
  public.archive_homebrew_item(text), public.restore_homebrew_item(text), public.homebrew_usage_count(text),
  public.update_inventory_item_details(uuid, jsonb), public.find_link_candidates(uuid), public.preview_link_inventory_item(uuid, text),
  public.link_inventory_item(uuid, text), public.convert_legacy_item_to_homebrew(uuid, uuid, jsonb, jsonb),
  public.resolve_equipment_review(uuid), public.import_inventory_items(uuid, jsonb)
  to authenticated;
