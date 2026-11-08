-- Items: Herbs & Plants, Potion details, per-item icons from the internal gallery, and safe permanent deletion of unused
-- custom items (docs/HERBS_AND_PLANTS_ITEMS.md, docs/CUSTOM_ITEM_ICONS.md, docs/CUSTOM_ITEM_DELETION.md,
-- docs/POTION_AND_HERBAL_CRAFTING_DESIGN.md). Rollback: supabase/rollback/rollback_items_herbs_icons_deletion.sql.
--
-- Existing data: no stored item, inventory entry or icon is changed. Two nullable / defaulted columns are added to items
-- (icon_key NULL = the category default as before; details '{}' = nothing extra). One reference kind and its eleven
-- subtype categories are inserted (idempotent). No catalog row is patched or re-imported.
--   * item kind 'herbs_plants' ("Herbs & Plants"): a herb needs no armor, weapon, tool, potion, charge or recipe field.
--   * items.icon_key: a key of the icon registry (js/icon-registry.js) from the gallery groups item / potion / plant /
--     inventory / slot. The check refuses anything else (URLs, paths, SVG, HTML). The browser falls back to the category
--     icon when a key is unknown to its registry.
--   * items.details: optional typed metadata, validated per kind by _item_details (unknown keys are refused, so values of
--     another type never survive a type switch): crafting-ready ingredient tags and recipe references for every kind, herb
--     fields (environment, region, harvesting, properties, shelf life) and potion fields (doses, use action, effect text,
--     saving throw, duration, ingredients). Nothing here is automated; a structured use effect stays in consumable_effects.
--   * _write_homebrew (player homebrew and DM content items share it) accepts icon_key, details and the new kind.
--   * v_item_catalog gets icon_key and details appended (existing columns unchanged).
--   * preview_item_deletion / delete_custom_item: permanent deletion of an UNUSED custom item only, rechecked inside the
--     transaction under the item row lock (inventories of characters, stashes and parties, owned assets, background
--     equipment, proficiencies, items based on it, inventory history, pending requests, other DM content versions).
--     Anything used is archived instead. Official items are never deleted.
--   * delete_unused_dm_item: the same for a published DM content item (all of its versions must be unused).

-- ---- reference data -------------------------------------------------------------------------------------------------------
insert into public.item_kinds (id, name, sort_order) values ('herbs_plants', 'Herbs & Plants', 65)
on conflict (id) do nothing;
insert into public.item_categories (id, kind_id, name, sort_order) values
  ('plant-herb', 'herbs_plants', 'Herb', 10), ('plant-flower', 'herbs_plants', 'Flower', 20), ('plant-root', 'herbs_plants', 'Root', 30),
  ('plant-fungus', 'herbs_plants', 'Fungus', 40), ('plant-seed', 'herbs_plants', 'Seed', 50), ('plant-leaf', 'herbs_plants', 'Leaf', 60),
  ('plant-fruit-berry', 'herbs_plants', 'Fruit or Berry', 70), ('plant-bark', 'herbs_plants', 'Bark', 80), ('plant-resin', 'herbs_plants', 'Resin', 90),
  ('plant-material', 'herbs_plants', 'Plant Material', 100), ('plant-other', 'herbs_plants', 'Other', 110)
on conflict (id) do nothing;

-- ---- columns ----------------------------------------------------------------------------------------------------------------
alter table public.items add column if not exists icon_key text;
alter table public.items add column if not exists details jsonb not null default '{}'::jsonb;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'items_icon_key_check' and conrelid = 'public.items'::regclass) then
    alter table public.items add constraint items_icon_key_check check (icon_key is null or icon_key ~ '^(item|potion|plant|inventory|slot)\.[a-z0-9]+(-[a-z0-9]+)*$');
  end if;
  if not exists (select 1 from pg_constraint where conname = 'items_details_check' and conrelid = 'public.items'::regclass) then
    alter table public.items add constraint items_details_check check (jsonb_typeof(details) = 'object' and pg_column_size(details) <= 8000);
  end if;
end $$;

-- ---- helpers ----------------------------------------------------------------------------------------------------------------
create or replace function public._item_icon_key(p text)
returns text language plpgsql immutable set search_path = public, pg_temp as $$
begin
  if nullif(btrim(p), '') is null then return null; end if;
  if length(p) > 60 or p !~ '^(item|potion|plant|inventory|slot)\.[a-z0-9]+(-[a-z0-9]+)*$' then
    raise exception 'Choose an icon from the gallery' using errcode = '22023';
  end if;
  return p;
end $$;

-- a short text list (tags, references): at most n entries of at most len characters, trimmed, empty entries dropped
create or replace function public._item_text_list(p jsonb, n int, len int, label text)
returns jsonb language plpgsql stable set search_path = public, pg_temp as $$
declare out jsonb := '[]'; x text;
begin
  if p is null or p = 'null'::jsonb then return null; end if;
  if jsonb_typeof(p) <> 'array' then raise exception '% must be a list', label using errcode = '22023'; end if;
  for x in select btrim(v) from jsonb_array_elements_text(p) v loop
    if x = '' then continue; end if;
    if length(x) > len then raise exception '% entries are at most % characters', label, len using errcode = '22023'; end if;
    if not out @> to_jsonb(array[x]) then out := out || to_jsonb(x); end if;
  end loop;
  if jsonb_array_length(out) > n then raise exception '% has at most % entries', label, n using errcode = '22023'; end if;
  return nullif(out, '[]'::jsonb);
end $$;

-- optional typed metadata per kind. Unknown keys are refused; empty values are dropped. Nothing here is automated.
create or replace function public._item_details(p_kind text, p jsonb)
returns jsonb language plpgsql stable set search_path = public, pg_temp as $$
declare k text; out jsonb := '{}'; common constant text[] := array['ingredient_tags', 'recipe_refs', 'preparation'];
  herb constant text[] := array['environment', 'region', 'harvesting', 'properties', 'shelf_life'];
  potion constant text[] := array['doses', 'use_action', 'effect_text', 'saving_throw', 'duration', 'ingredients']; v jsonb;
begin
  if p is null or p = 'null'::jsonb then return '{}'; end if;
  if jsonb_typeof(p) <> 'object' then raise exception 'Item details must be an object' using errcode = '22023'; end if;
  for k in select jsonb_object_keys(p) loop
    if not (k = any (common) or (p_kind = 'herbs_plants' and k = any (herb)) or (p_kind = 'potion' and k = any (potion))) then
      raise exception 'Field "%" is not part of a % item', k, replace(coalesce(p_kind, 'this'), '_', ' & ') using errcode = '22023';
    end if;
  end loop;
  out := jsonb_strip_nulls(jsonb_build_object(
    'ingredient_tags', public._item_text_list(p -> 'ingredient_tags', 12, 40, 'Ingredient tags'),
    'recipe_refs', public._item_text_list(p -> 'recipe_refs', 12, 80, 'Recipe references'),
    'preparation', public._j_text(p, 'preparation', 1000, 'Preparation notes'),
    'environment', public._j_text(p, 'environment', 120, 'Environment'),
    'region', public._j_text(p, 'region', 120, 'Region'),
    'harvesting', public._j_text(p, 'harvesting', 1000, 'Harvesting notes'),
    'shelf_life', public._j_text(p, 'shelf_life', 200, 'Shelf life'),
    'effect_text', public._j_text(p, 'effect_text', 1000, 'Effect'),
    'saving_throw', public._j_text(p, 'saving_throw', 60, 'Saving throw'),
    'duration', public._j_text(p, 'duration', 100, 'Duration'),
    'ingredients', public._item_text_list(p -> 'ingredients', 20, 80, 'Ingredients'),
    'doses', public._j_int(p, 'doses', 1, 100, 'Doses'),
    'use_action', public._j_text(p, 'use_action', 20, 'Use')));
  v := p -> 'properties';
  if v is not null and v <> 'null'::jsonb then
    if jsonb_typeof(v) <> 'array' or exists (select 1 from jsonb_array_elements_text(v) x where x not in ('alchemical', 'medicinal', 'poisonous', 'edible')) then
      raise exception 'Plant properties are alchemical, medicinal, poisonous or edible' using errcode = '22023';
    end if;
    if jsonb_array_length(v) > 0 then out := out || jsonb_build_object('properties', (select jsonb_agg(distinct x) from jsonb_array_elements_text(v) x)); end if;
  end if;
  if out ? 'use_action' and out ->> 'use_action' not in ('action', 'bonus_action', 'reaction', 'minute', 'special') then
    raise exception 'Use must be an action, a bonus action, a reaction, a minute or special' using errcode = '22023';
  end if;
  return out;
end $$;
revoke all on function public._item_icon_key(text), public._item_text_list(jsonb, int, int, text), public._item_details(text, jsonb) from public, anon, authenticated;

-- ---- the homebrew item writer (exact previous body + icon_key, details, Herbs & Plants) ----------------------------------
CREATE OR REPLACE FUNCTION public._write_homebrew(p_id text, p_def jsonb, p_stats jsonb, p_is_new boolean)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  allowed_def constant text[] := array['name','kind_id','category_id','description','weight_lb','cost_value','cost_unit','rarity_id',
                                       'is_magic','requires_attunement','is_consumable','stackable','campaign_id',
                                       'icon_key','details'];   -- 20261107000300
  k text; prev public.items;
  v_name text; v_kind text; v_cat text; v_desc text; v_weight numeric; v_cost numeric; v_unit text; v_rarity text;
  v_magic boolean; v_att boolean; v_cons boolean; v_stack boolean; v_campaign uuid;
  s jsonb := coalesce(p_stats, '{}'::jsonb); w jsonb; a jsonb; c jsonb; e jsonb;
  dice_re constant text := '^([1-9][0-9]?d(4|6|8|10|12|20|100)([+-][0-9]{1,3})?|[0-9]{1,3})$';
  props text[]; grp text; rtype text; v_ammo text; rn int; rm int; vd text; dd text; dt text; mode text; cap int;
  is_shield boolean; base int; bonus int; v_icon text; v_details jsonb;
begin
  if p_def is null or jsonb_typeof(p_def) <> 'object' then raise exception 'Item definition is missing' using errcode = '22023'; end if;
  for k in select jsonb_object_keys(p_def) loop
    if not k = any (allowed_def) then raise exception 'Field "%" cannot be set on a homebrew item', k using errcode = '22023'; end if;
  end loop;
  for k in select jsonb_object_keys(s) loop
    if not k = any (array['weapon','armor','ammunition','container','effect']) then raise exception 'Unknown stats section "%"', k using errcode = '22023'; end if;
  end loop;
  -- 20261031000100: a section without any value (an untouched part of a form, e.g. only an unchecked "Stealth disadvantage"
  -- box) is no section: it must not block a non-armor / non-weapon item. A section WITH values still has to fit the type.
  for k in select jsonb_object_keys(s) loop
    if jsonb_typeof(s -> k) = 'object' and not exists (select 1 from jsonb_each(s -> k) x
        where x.value not in ('null'::jsonb, 'false'::jsonb, '""'::jsonb, '[]'::jsonb, '{}'::jsonb)) then
      s := s - k;
    end if;
  end loop;

  if not p_is_new then select * into prev from public.items where id = p_id; end if;

  v_name := public._j_text(p_def, 'name', 120, 'Name');
  if v_name is null then raise exception 'Name is required' using errcode = '22023'; end if;
  v_kind := coalesce(public._j_text(p_def, 'kind_id', 40, 'Type'), prev.kind_id);
  if not p_is_new and v_kind is distinct from prev.kind_id then
    raise exception 'The type of a homebrew item cannot change; create a new item instead' using errcode = '22023';
  end if;
  if v_kind is null or not v_kind = any (array['weapon','armor','tool','gear','ammunition','potion','scroll','magic_item','herbs_plants']) then
    raise exception 'Type must be one of weapon, armor, tool, gear, ammunition, potion, scroll, magic item, herbs & plants' using errcode = '22023';
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
  v_stack := public._j_bool(p_def, 'stackable', v_kind in ('potion', 'scroll', 'ammunition', 'herbs_plants'));
  -- 20261107000300: an icon from the internal gallery (a registry key, never a URL, SVG or HTML) and optional typed details
  if not p_is_new and not p_def ? 'icon_key' then v_icon := prev.icon_key;
  else v_icon := public._item_icon_key(p_def ->> 'icon_key');
  end if;
  if not p_is_new and not p_def ? 'details' then v_details := coalesce(prev.details, '{}'::jsonb);
  else v_details := public._item_details(v_kind, p_def -> 'details');
  end if;
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
    if dd is null then raise exception 'A weapon needs damage dice (for example 1d8)' using errcode = '22023'; end if;   -- 20261031000100
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
                              requires_attunement, is_consumable, stackable, owner_id, campaign_id, data_source_id, source_label, updated_by,
                              icon_key, details)
    values (p_id, v_kind, v_cat, v_name, v_desc, v_weight, v_cost, v_unit, v_rarity, v_magic, v_att, v_cons, v_stack,
            auth.uid(), v_campaign, 'homebrew', 'Homebrew', auth.uid(), v_icon, v_details);
  else
    update public.items set category_id = v_cat, name = v_name, description = v_desc, weight_lb = v_weight, cost_value = v_cost,
           cost_unit = v_unit, rarity_id = v_rarity, is_magic = v_magic, requires_attunement = v_att, is_consumable = v_cons,
           stackable = v_stack, campaign_id = v_campaign, updated_by = auth.uid(), icon_key = v_icon, details = v_details
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
$function$;

-- ---- the catalog view: two columns appended (existing columns unchanged) --------------------------------------------
create or replace view public.v_item_catalog with (security_invoker = true) as
SELECT i.id,
    i.name,
    i.kind_id,
    k.name AS kind_name,
    i.category_id,
    c.name AS category_name,
    i.rarity_id,
    i.is_magic,
    i.requires_attunement,
    i.is_consumable,
    i.stackable,
    i.stack_max,
    i.weight_lb,
    i.cost_value,
    i.cost_unit,
    i.cost_cp,
    i.base_item_id,
    i.data_source_id,
    i.description,
    i.source_book_id,
    sb.name AS source_book_name,
    i.source_label,
    i.source_url,
    i.owner_id,
    i.campaign_id,
    item_visibility(i.owner_id, i.campaign_id) AS visibility,
    i.owner_id IS NOT NULL AND i.owner_id = auth.uid() AS is_mine,
    can_edit_owned(i.owner_id, i.campaign_id) AS can_edit,
    i.archived_at,
    i.created_at,
    i.updated_at,
    ws.weapon_group,
    ws.damage_dice,
    ws.damage_type_id,
    ws.versatile_damage,
    ws.is_ranged,
    ws.range_type,
    ws.range_normal,
    ws.range_max,
    ws.ammo_type_id AS weapon_ammo_type_id,
    fs.reload,
    fs.misfire,
    ( SELECT COALESCE(array_agg(l.property_id ORDER BY l.property_id), '{}'::text[]) AS "coalesce"
           FROM weapon_property_links l
          WHERE l.item_id = i.id) AS weapon_properties,
    a.base_ac,
    a.ac_bonus,
    a.dex_modifier_mode,
    a.dex_cap,
    a.strength_requirement,
    a.stealth_disadvantage,
    a.is_shield,
    am.ammo_type_id,
    am.pack_size,
    am.pack_cost_cp,
    cs.capacity_weight_lb,
    cs.capacity_volume_cuft,
    cs.weightless_contents,
    cs.extradimensional,
    COALESCE(ms.speed_value, vs.speed_value) AS speed_value,
    COALESCE(ms.speed_unit, vs.speed_unit) AS speed_unit,
    ms.carrying_capacity_lb,
    vs.cargo_lb,
    ( SELECT COALESCE(array_agg(t.tag_id ORDER BY t.tag_id), '{}'::text[]) AS "coalesce"
           FROM item_tag_links t
          WHERE t.item_id = i.id) AS tag_ids,
    i.icon_key,
    i.details
   FROM items i
     JOIN item_kinds k ON k.id = i.kind_id
     LEFT JOIN item_categories c ON c.id = i.category_id
     LEFT JOIN source_books sb ON sb.id = i.source_book_id
     LEFT JOIN weapon_stats ws ON ws.item_id = i.id
     LEFT JOIN firearm_stats fs ON fs.item_id = i.id
     LEFT JOIN armor_stats a ON a.item_id = i.id
     LEFT JOIN ammunition_stats am ON am.item_id = i.id
     LEFT JOIN container_stats cs ON cs.item_id = i.id
     LEFT JOIN mount_stats ms ON ms.item_id = i.id
     LEFT JOIN vehicle_stats vs ON vs.item_id = i.id;

-- ---- the inventory bundle read (fluent path): catalog item columns follow js/inventory-api.js CATALOG_COLUMNS --------------
CREATE OR REPLACE FUNCTION public._character_read(p_character uuid, p_name text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare inv uuid; r jsonb; v text;
begin
  case p_name
  when 'get_character_derived_stats' then return public.get_character_derived_stats(p_character);
  when 'get_character_proficiencies' then return public.get_character_proficiencies(p_character);
  when 'get_character_lineage' then return public.get_character_lineage(p_character);
  when 'get_character_background' then return public.get_character_background(p_character);
  when 'get_character_feats' then return public.get_character_feats(p_character);
  when 'get_character_class_summary' then return public.get_character_class_summary(p_character);
  when 'get_character_spell_slots' then return public.get_character_spell_slots(p_character);
  when 'get_character_class_features' then return public.get_character_class_features(p_character);
  when 'get_character_resources' then return public.get_character_resources(p_character);
  when 'get_character_states' then return public.get_character_states(p_character);
  when 'get_character_transformation' then return public.get_character_transformation(p_character);
  when 'get_character_infusions' then return public.get_character_infusions(p_character);
  when 'get_character_governance' then return public.get_character_governance(p_character);
  when 'get_character_change_requests' then return public.get_character_change_requests(p_character, false);
  when 'get_character_spellbook' then return public.get_character_spellbook(p_character);
  -- the stored rows of js/store.js loadBundle
  when 'characters' then
    select to_jsonb(c) into r from public.characters c where c.id = p_character;
    if r is null then raise exception 'Character not found' using errcode = '42501'; end if;
    return r;
  when 'inventory_items' then
    return (select coalesce(jsonb_agg(to_jsonb(x) order by x.sort_order, x.created_at), '[]') from public.inventory_items x where x.character_id = p_character);
  when 'notes' then
    return (select coalesce(jsonb_agg(to_jsonb(x) order by x.id), '[]') from public.notes x where x.character_id = p_character);
  when 'spell_slots' then
    return (select coalesce(jsonb_agg(to_jsonb(x) order by x.level), '[]') from public.spell_slots x where x.character_id = p_character);
  when 'feature_trackers' then
    return (select coalesce(jsonb_agg(to_jsonb(x) order by x.sort_order, x.created_at), '[]') from public.feature_trackers x where x.character_id = p_character);
  when 'features' then
    return (select coalesce(jsonb_agg(to_jsonb(x) order by x.sort_order, x.created_at), '[]') from public.features x where x.character_id = p_character);
  when 'attacks' then
    return (select coalesce(jsonb_agg(to_jsonb(x) order by x.sort_order, x.created_at), '[]') from public.attacks x where x.character_id = p_character);
  when 'spells' then
    return (select coalesce(jsonb_agg(to_jsonb(x) order by x.level, x.sort_order, x.created_at), '[]') from public.spells x where x.character_id = p_character);
  -- js/creature-api.js getCompanions (embedded creature, ordered by created_at)
  when 'companions' then
    return (select coalesce(jsonb_agg(jsonb_build_object('id', cc.id, 'name', cc.name, 'source', cc.source, 'hp_max', cc.hp_max,
        'hp_current', cc.hp_current, 'notes', cc.notes, 'active', cc.active, 'creature_id', cc.creature_id,
        'creature', (select jsonb_build_object('id', cr.id, 'name', cr.name, 'size', cr.size, 'creature_type', cr.creature_type,
            'challenge_rating', cr.challenge_rating, 'armor_class', cr.armor_class, 'speed', cr.speed, 'actions', cr.actions,
            'abilities', cr.abilities) from public.creatures cr where cr.id = cc.creature_id)) order by cc.created_at), '[]')
      from public.character_companions cc where cc.character_id = p_character);
  -- js/class-api.js getStartingEquipmentState: applied marker + the primary class's starting-equipment catalog
  when 'starting_equipment_applied' then
    return (select jsonb_build_object('class_version_id', s.class_version_id) from public.character_starting_equipment s where s.character_id = p_character);
  when 'primary_class_starting_equipment' then
    select k.class_version_id into v from public.character_classes k where k.character_id = p_character and k.is_primary limit 1;
    if v is null then return null; end if;
    return jsonb_build_object('class_version_id', v, 'equipment', public.get_class_starting_equipment(v));
  -- js/inventory-ui.js load(): one bundle instead of 7 requests + a catalog chunk
  when 'inventory_bundle' then
    select id into inv from public.inventories where character_id = p_character and kind = 'character';
    if inv is null then return null; end if;
    return jsonb_build_object(
      'inventory_id', inv,
      'rows', (select coalesce(jsonb_agg(to_jsonb(d) order by d.sort_order, d.acquired_at, d.id), '[]') from public.v_inventory_detail d where d.inventory_id = inv),
      'equipment', (select coalesce(jsonb_agg(jsonb_build_object('slot_id', e.slot_id, 'inventory_item_id', e.inventory_item_id, 'equipped_at', e.equipped_at) order by e.slot_id), '[]')
                    from public.character_equipment e where e.character_id = p_character),
      'attunement', (select to_jsonb(a) from public.v_character_attunement a where a.character_id = p_character),
      'weight', (select to_jsonb(w) from public.v_inventory_weight w where w.inventory_id = inv),
      'containers', (select coalesce(jsonb_agg(to_jsonb(c) order by c.container_item_id), '[]') from public.v_container_contents c where c.inventory_id = inv),
      'review', (select coalesce(jsonb_agg(jsonb_build_object('inventory_item_id', x.inventory_item_id, 'category', x.category, 'status', x.status, 'detail', x.detail) order by x.id), '[]')
                 from public.legacy_inventory_review x where x.character_id = p_character and x.status in ('pending', 'manual_review')),
      -- the columns of js/inventory-api.js CATALOG_COLUMNS
      'catalog_items', (select coalesce(jsonb_agg(to_jsonb(ci)), '[]') from (
          select id, name, kind_id, kind_name, category_id, category_name, rarity_id, is_magic, requires_attunement, is_consumable,
            stackable, weight_lb, cost_value, cost_unit, source_book_id, source_book_name, source_label, owner_id, campaign_id,
            visibility, is_mine, can_edit, archived_at, description, data_source_id, weapon_group, damage_dice, damage_type_id,
            versatile_damage, is_ranged, range_type, range_normal, range_max, weapon_ammo_type_id, reload, misfire, weapon_properties,
            base_ac, ac_bonus, dex_modifier_mode, dex_cap, strength_requirement, stealth_disadvantage, is_shield, ammo_type_id,
            pack_size, capacity_weight_lb, capacity_volume_cuft, weightless_contents, extradimensional, icon_key, details   -- 20261107000300
          from public.v_item_catalog
          where id in (select ii.item_id from public.inventory_items ii where ii.inventory_id = inv and ii.item_id is not null)) ci));
  when 'revisions' then   -- latest revision (log id) per source table
    return (select coalesce(jsonb_object_agg(x.source_table, x.rev), '{}') from (
      select r2.source_table, max(r2.id) as rev from public.character_revisions r2 where r2.character_id = p_character group by 1) x);
  else
    raise exception 'Unknown read %', p_name using errcode = '22023';
  end case;
end $function$;

-- cached bundles were built without the new columns: one global read-cache revision makes them rebuild on the next read
update tl_cache.global_rev set rev = rev + 1 where id = 1;

-- ---- deletion --------------------------------------------------------------------------------------------------------------
-- Everything that uses an item definition outside its own definition rows (stats, tags, provenance, secrets, its own
-- lifecycle events and slot rules go with it). p_self_content: DM content whose versions may reference it (ignored).
create or replace function public._item_dependencies(p_item text, p_self_content uuid default null)
returns jsonb language sql stable security definer set search_path = public, pg_temp as $$
  select jsonb_build_object(
    'character_inventories', (select count(*) from public.inventory_items ii join public.inventories inv on inv.id = ii.inventory_id
                              where ii.item_id = p_item and inv.kind = 'character'),
    'other_inventories', (select count(*) from public.inventory_items ii join public.inventories inv on inv.id = ii.inventory_id
                          where ii.item_id = p_item and inv.kind <> 'character'),
    'equipped_or_attuned', (select count(*) from public.inventory_items ii where ii.item_id = p_item and (ii.equipped or ii.is_attuned)),
    'in_containers', (select count(*) from public.inventory_items ii where ii.item_id = p_item and ii.container_item_id is not null),
    'owned_assets', (select count(*) from public.owned_assets where item_id = p_item),
    'background_equipment', (select count(*) from public.background_equipment_entries where item_id = p_item),
    'proficiencies', (select count(*) from public.character_proficiencies where item_id = p_item),
    'items_based_on_it', (select count(*) from public.items where base_item_id = p_item),
    'inventory_history', (select count(*) from public.inventory_events where item_id = p_item),
    'pending_requests', (select count(*) from public.change_requests r where r.status in ('draft', 'submitted', 'returned_for_changes')
                         and r.ops::text like '%"' || p_item || '"%'),
    'dm_content_versions', (select count(*) from public.dm_content_versions v where v.catalog_ref = p_item
                            and v.content_id is distinct from p_self_content));
$$;

create or replace function public._item_blocking(d jsonb)
returns int language sql immutable set search_path = public, pg_temp as $$
  select coalesce(sum(value::int), 0)::int from jsonb_each_text(d) where key <> 'equipped_or_attuned' and key <> 'in_containers';
$$;

-- what a permanent delete would do: allowed only when nothing uses the definition (otherwise: archive)
create or replace function public.preview_item_deletion(p_item text)
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
declare it public.items; d jsonb; n int; dm uuid; reasons text[] := '{}';
begin
  select * into it from public.items where id = p_item;
  if it.id is null or not public.can_view_owned(it.owner_id, it.campaign_id) then raise exception 'Unknown item' using errcode = 'P0002'; end if;
  if it.owner_id is null then
    return jsonb_build_object('item_id', it.id, 'name', it.name, 'deletable', false, 'official', true, 'reasons', jsonb_build_array('Official items are never deleted.'));
  end if;
  if not public.can_edit_owned(it.owner_id, it.campaign_id) then raise exception 'Not allowed to change this item' using errcode = '42501'; end if;
  select content_id into dm from public.dm_content_versions where catalog_ref = p_item limit 1;
  d := public._item_dependencies(p_item, dm);
  n := public._item_blocking(d);
  if (d ->> 'character_inventories')::int > 0 then reasons := reasons || format('%s character inventory entr%s', d ->> 'character_inventories', case when (d ->> 'character_inventories')::int = 1 then 'y' else 'ies' end); end if;
  if (d ->> 'other_inventories')::int > 0 then reasons := reasons || format('%s stash or party entr%s', d ->> 'other_inventories', case when (d ->> 'other_inventories')::int = 1 then 'y' else 'ies' end); end if;
  if (d ->> 'inventory_history')::int > 0 then reasons := reasons || 'it has inventory history'::text; end if;
  if (d ->> 'owned_assets')::int > 0 then reasons := reasons || 'owned assets'::text; end if;
  if (d ->> 'background_equipment')::int > 0 then reasons := reasons || 'background starting equipment'::text; end if;
  if (d ->> 'proficiencies')::int > 0 then reasons := reasons || 'character proficiencies'::text; end if;
  if (d ->> 'items_based_on_it')::int > 0 then reasons := reasons || 'other items are based on it'::text; end if;
  if (d ->> 'pending_requests')::int > 0 then reasons := reasons || 'pending change requests'::text; end if;
  if (d ->> 'dm_content_versions')::int > 0 then reasons := reasons || 'other DM content versions'::text; end if;
  return jsonb_build_object('item_id', it.id, 'name', it.name, 'kind_id', it.kind_id, 'archived', it.archived_at is not null,
    'dm_content_id', dm, 'deletable', n = 0, 'dependencies', d, 'reasons', to_jsonb(reasons),
    'advice', case when n = 0 then 'Nothing uses this definition. Deleting it cannot be undone.'
                   else 'This definition is in use. Archive it instead: it can no longer be added, and every existing entry keeps working.' end);
end $$;

-- permanent delete of an unused player / DM homebrew item (not managed DM content: see delete_unused_dm_item)
create or replace function public.delete_custom_item(p_item text, p_confirm_name text)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare it public.items; d jsonb;
begin
  it := public._lock_homebrew(p_item);           -- access first (no governance text for strangers); FOR UPDATE: a concurrent
                                                 -- "add to inventory" waits, then fails its foreign key
  perform public._gov_content_gate(it.campaign_id, 'content.create_item');
  if exists (select 1 from public.dm_content_versions where catalog_ref = p_item) then
    raise exception 'This item is managed in DM Space. Delete or archive it there.' using errcode = '22023';
  end if;
  if coalesce(btrim(p_confirm_name), '') <> it.name then raise exception 'Type the item name to confirm' using errcode = '22023'; end if;
  d := public._item_dependencies(p_item, null);   -- rechecked here, under the lock
  if public._item_blocking(d) > 0 then
    raise exception 'This item is in use (inventories, history or requests). Archive it instead; nothing was deleted.' using errcode = 'TLUSE', hint = 'archive';
  end if;
  delete from public.items where id = p_item;
  return jsonb_build_object('deleted', p_item, 'name', it.name);
exception when foreign_key_violation then
  raise exception 'This item is in use. Archive it instead; nothing was deleted.' using errcode = 'TLUSE', hint = 'archive';
end $$;

-- permanent delete of a published DM content item whose versions are all unused (drafts keep delete_dm_content)
create or replace function public.delete_unused_dm_item(p_content uuid, p_confirm_name text)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare c public.dm_content; r record; d jsonb; refs text[] := '{}';
begin
  if not public._dm_can_manage(p_content) then raise exception 'Content not found' using errcode = '42501'; end if;
  select * into c from public.dm_content where id = p_content for update;
  if c.content_type <> 'item' then raise exception 'Only unused items can be deleted after publishing; archive other content' using errcode = '22023'; end if;
  if c.author_id <> auth.uid() and not public.is_admin() then raise exception 'Only the author can delete this item' using errcode = '42501'; end if;
  if coalesce(btrim(p_confirm_name), '') <> c.name then raise exception 'Type the item name to confirm' using errcode = '22023'; end if;
  for r in select v.catalog_ref from public.dm_content_versions v where v.content_id = p_content and v.catalog_ref is not null loop
    perform 1 from public.items where id = r.catalog_ref for update;
    d := public._item_dependencies(r.catalog_ref, p_content);
    if public._item_blocking(d) > 0 then
      raise exception 'A version of this item is in use. Archive it instead; nothing was deleted.' using errcode = 'TLUSE', hint = 'archive';
    end if;
    refs := refs || r.catalog_ref;
  end loop;
  if exists (select 1 from public.character_conditions k join public.dm_content_versions v on v.id = k.content_version_id where v.content_id = p_content) then
    raise exception 'This content is in use. Archive it instead; nothing was deleted.' using errcode = 'TLUSE', hint = 'archive';
  end if;
  update public.dm_content set current_version_id = null, published_version_id = null where id = p_content;
  delete from public.items where id = any (refs);
  delete from public.dm_content where id = p_content;
  return jsonb_build_object('deleted', p_content, 'name', c.name, 'item_versions', to_jsonb(refs));
exception when foreign_key_violation then
  raise exception 'This item is in use. Archive it instead; nothing was deleted.' using errcode = 'TLUSE', hint = 'archive';
end $$;

revoke all on function public._item_dependencies(text, uuid), public._item_blocking(jsonb) from public, anon, authenticated;
revoke all on function public.preview_item_deletion(text), public.delete_custom_item(text, text), public.delete_unused_dm_item(uuid, text) from public, anon;
grant execute on function public.preview_item_deletion(text), public.delete_custom_item(text, text), public.delete_unused_dm_item(uuid, text) to authenticated;
