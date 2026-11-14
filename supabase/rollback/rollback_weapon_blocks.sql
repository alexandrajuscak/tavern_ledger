-- Rollback of 20261114000600_weapon_blocks.sql (R-D2 weapon blocks). Run the previous frontend (?v=33) FIRST.
-- Never deletes DM-authored data:
--   * item_weapon_blocks is RENAMED to item_weapon_blocks_rd2_backup (kept with its rows; re-applying the migration renames it
--     back, section 0);
--   * weapon action counters (character_resources 'itemw-...') are only deactivated (expended and resource events kept) and get a
--     neutral label 'Weapon action' (review v34 m5: the restored sync no longer renames them when a copy is unidentified later);
--   * item_effects rows attack_bonus / damage_bonus of weapons stay: the R-D1 engine reads them (only authoring them returns).
-- The functions get their exact bodies before 20261114000600 (dumped from a database at 20261114000500). Safe to run twice.
set lock_timeout = '5s';

CREATE OR REPLACE FUNCTION public.get_character_derived_stats(p_character uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare tok text := current_setting('tl_memo.token', true); k text; v text;
begin
  if tok is null or tok = '' then
    return public._wild_shape_layer(p_character, public._feat_layer(p_character, public._derived_stats_full(p_character)));
  end if;
  k := 'tl_memo.d' || md5(tok || p_character::text || current_user || coalesce(auth.uid()::text, '-'));
  v := current_setting(k, true);
  if v is not null and v <> '' then return v::jsonb; end if;
  v := public._wild_shape_layer(p_character, public._feat_layer(p_character, public._derived_stats_full(p_character)))::text;
  perform set_config(k, v, true);
  return v::jsonb;
end $function$
;

drop function if exists public._weapon_blocks_layer(uuid, jsonb);
drop function if exists public._character_weapon_blocks(uuid, uuid[]);

CREATE OR REPLACE FUNCTION public._item_grants_on_inventory()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
begin
  if tg_op <> 'DELETE' and exists (select 1 from public.item_spell_grants g where g.item_id = new.item_id and g.activation <> 'permanent') then
    perform public._item_grants_mark((select i.character_id from public.inventories i where i.id = new.inventory_id));
  end if;
  if tg_op <> 'INSERT' and exists (select 1 from public.item_spell_grants g where g.item_id = old.item_id and g.activation <> 'permanent') then
    perform public._item_grants_mark((select i.character_id from public.inventories i where i.id = old.inventory_id));
  end if;
  return null;
end $function$
;

CREATE OR REPLACE FUNCTION public._item_grants_on_equipment()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
begin
  if tg_op <> 'DELETE' and exists (select 1 from public.inventory_items ii join public.item_spell_grants g on g.item_id = ii.item_id
                                   where ii.id = new.inventory_item_id and g.activation <> 'permanent') then
    perform public._item_grants_mark(new.character_id);
  end if;
  if tg_op <> 'INSERT' and exists (select 1 from public.inventory_items ii join public.item_spell_grants g on g.item_id = ii.item_id
                                   where ii.id = old.inventory_item_id and g.activation <> 'permanent') then
    perform public._item_grants_mark(old.character_id);
  end if;
  return null;
end $function$
;

CREATE OR REPLACE FUNCTION public._item_grants_on_knowledge()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare cid uuid; rid uuid := case when tg_op = 'DELETE' then old.inventory_item_id else new.inventory_item_id end;
begin
  select inv.character_id into cid from public.inventory_items ii join public.inventories inv on inv.id = ii.inventory_id
  where ii.id = rid and exists (select 1 from public.item_spell_grants g where g.item_id = ii.item_id and g.activation <> 'permanent');
  perform public._item_grants_mark(cid);
  return null;
end $function$
;

CREATE OR REPLACE FUNCTION public._item_grants_on_transformation()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare cid uuid := case when tg_op = 'DELETE' then old.character_id else new.character_id end;
begin
  if exists (select 1 from public.inventories inv join public.inventory_items ii on ii.inventory_id = inv.id
             join public.item_spell_grants g on g.item_id = ii.item_id
             where inv.character_id = cid and g.activation in ('equipped', 'attuned', 'equipped_and_attuned')) then
    perform public._item_grants_mark(cid);
  end if;
  return null;
end $function$
;

CREATE OR REPLACE FUNCTION public._sync_item_spell_grants(p_character uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare want jsonb; gk text; w jsonb; lbl text; src uuid; keep_src text[] := '{}'; keep_res text[] := '{}'; rk text; ab_default text;
  engine_before text := coalesce(current_setting('tavern.resource_engine', true), '');
begin
  if p_character is null then return; end if;
  select case when spellcasting_ability in ('str', 'dex', 'con', 'int', 'wis', 'cha') then spellcasting_ability end into ab_default
  from public.characters where id = p_character;
  if not found then return; end if;                                   -- the character is being deleted
  select coalesce(jsonb_agg(to_jsonb(x) order by x.gkey, x.seq), '[]') into want from (
    select 'ii:' || h.row_id as gkey, 'item-' || replace(h.row_id::text, '-', '') as rbase, h.label, gr.seq, gr.spell_version_id,
           gr.casting, gr.uses, gr.recharge, gr.ability
    from (select ii.id as row_id, ii.item_id, ii.is_attuned and public._item_active_in_form(p_character, ii.id) as is_attuned, e.slot_id,
                 case when kk.state is not null and kk.state <> 'identified'
                      then coalesce(nullif(ii.custom_name, ''), nullif(ii.name, ''), 'Unidentified item')
                      else coalesce(nullif(ii.custom_name, ''), it.name) end as label
          from public.inventories inv
          join public.inventory_items ii on ii.inventory_id = inv.id
          join public.items it on it.id = ii.item_id
          left join public.character_equipment e on e.inventory_item_id = ii.id and e.character_id = p_character
            and public._item_active_in_form(p_character, ii.id)          -- merged or dropped in Wild Shape: not equipped (review v33 m3)
          left join public.inventory_item_knowledge kk on kk.inventory_item_id = ii.id
          where inv.character_id = p_character
            and exists (select 1 from public.item_spell_grants x where x.item_id = ii.item_id and x.activation <> 'permanent')) h
    join public.item_spell_grants gr on gr.item_id = h.item_id and gr.activation <> 'permanent'
    where case gr.activation when 'owned' then true when 'equipped' then h.slot_id is not null when 'attuned' then h.is_attuned
                             when 'equipped_and_attuned' then h.slot_id is not null and h.is_attuned else false end
    union all
    select 'pe:' || p.id, 'itemp-' || replace(p.id::text, '-', ''), public._permanent_effect_label(p, false), p.seq, p.spell_version_id,
           p.casting, p.uses, p.recharge, p.ability
    from public.character_permanent_effects p
    where p.character_id = p_character and p.kind = 'spell' and p.reverted_at is null) x;

  if want = '[]'::jsonb and not exists (select 1 from public.character_spellcasting_sources where character_id = p_character and item_grant_key is not null)
     and not exists (select 1 from public.character_resources where character_id = p_character and source_type = 'item' and active
                     and resource_key ~ '^itemp?-[0-9a-f]{32}-') then
    return;                                                           -- nothing granted, nothing to clean up
  end if;
  perform set_config('tavern.resource_engine', 'on', true);          -- reset below (the resource guard bypass of this sync)
  for gk in select distinct x ->> 'gkey' from jsonb_array_elements(want) x loop
    keep_src := keep_src || gk;
    select x ->> 'label' into lbl from jsonb_array_elements(want) x where x ->> 'gkey' = gk limit 1;
    lbl := left(coalesce(nullif(btrim(lbl), ''), 'Magic item'), 80);
    select id into src from public.character_spellcasting_sources where character_id = p_character and item_grant_key = gk;
    if src is null then
      insert into public.character_spellcasting_sources (character_id, source_type, label, casting_ability, preparation_mode, ritual_mode,
                                                         uses_spell_slots, item_grant_key, notes, created_by)
      values (p_character, 'item', lbl,
              coalesce((select x ->> 'ability' from jsonb_array_elements(want) x where x ->> 'gkey' = gk and x ->> 'ability' is not null limit 1), ab_default),
              'innate', 'none', true, gk, 'Granted by an item; removed when the item no longer grants it.', auth.uid())
      returning id into src;
    else
      update public.character_spellcasting_sources set label = lbl where id = src and label is distinct from lbl;
    end if;
    delete from public.character_spells cs where cs.source_id = src
      and not cs.spell_version_id in (select x ->> 'spell_version_id' from jsonb_array_elements(want) x where x ->> 'gkey' = gk);
    for w in select x from jsonb_array_elements(want) x where x ->> 'gkey' = gk order by (x ->> 'seq')::int loop
      insert into public.character_spells as cs (character_id, source_id, spell_version_id, known, prepared, always_prepared,
                                                 counts_against_known_limit, counts_against_prepared_limit, uses_spell_slot, casting_ability,
                                                 acquisition, acquisition_notes)
      values (p_character, src, w ->> 'spell_version_id', true, false, false, false, false, w ->> 'casting' = 'spell_slots',
              coalesce(w ->> 'ability', ab_default), 'other', left('Granted by ' || lbl, 300))
      on conflict (source_id, spell_version_id) do update set uses_spell_slot = excluded.uses_spell_slot,
        casting_ability = excluded.casting_ability, acquisition_notes = excluded.acquisition_notes
        where (cs.uses_spell_slot, cs.casting_ability, cs.acquisition_notes)
              is distinct from (excluded.uses_spell_slot, excluded.casting_ability, excluded.acquisition_notes);
      if w ->> 'casting' = 'per_rest' then
        rk := (w ->> 'rbase') || '-' || (w ->> 'seq');
        keep_res := keep_res || rk;
        insert into public.character_resources as r (character_id, resource_key, name, source_type, source_id, max_formula, recharge,
                                                     spell_version_id, active, notes, created_by)
        values (p_character, rk, left('Free cast: ' || coalesce((select name from public.spell_versions where id = w ->> 'spell_version_id'), 'spell'), 80),
                'item', gk, jsonb_build_object('fixed', (w ->> 'uses')::int), w ->> 'recharge', w ->> 'spell_version_id', true,
                left(lbl || ': cast without a spell slot', 500), auth.uid())
        on conflict (character_id, resource_key) do update set active = true, max_formula = excluded.max_formula, recharge = excluded.recharge,
          name = excluded.name, notes = excluded.notes, source_id = excluded.source_id, spell_version_id = excluded.spell_version_id
          where (r.active, r.max_formula, r.recharge, r.name, r.notes, r.source_id, r.spell_version_id)
                is distinct from (true, excluded.max_formula, excluded.recharge, excluded.name, excluded.notes, excluded.source_id, excluded.spell_version_id);
      end if;
    end loop;
  end loop;
  delete from public.character_spellcasting_sources s where s.character_id = p_character and s.item_grant_key is not null
    and not s.item_grant_key = any (keep_src);
  update public.character_resources r set active = false
  where r.character_id = p_character and r.source_type = 'item' and r.active and r.resource_key ~ '^itemp?-[0-9a-f]{32}-'
    and not r.resource_key = any (keep_res);
  perform set_config('tavern.resource_engine', engine_before, true);
end $function$
;

CREATE OR REPLACE FUNCTION public._write_homebrew(p_id text, p_def jsonb, p_stats jsonb, p_is_new boolean)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  allowed_def constant text[] := array['name','kind_id','category_id','description','weight_lb','cost_value','cost_unit','rarity_id',
                                       'is_magic','requires_attunement','is_consumable','stackable','campaign_id',
                                       'icon_key','details',    -- 20261107000300
                                       'effects','spells'];     -- 20261114000500: DM content items only (cc-)
  k text; prev public.items;
  v_name text; v_kind text; v_cat text; v_desc text; v_weight numeric; v_cost numeric; v_unit text; v_rarity text;
  v_magic boolean; v_att boolean; v_cons boolean; v_stack boolean; v_campaign uuid;
  s jsonb := coalesce(p_stats, '{}'::jsonb); w jsonb; a jsonb; c jsonb; e jsonb;
  dice_re constant text := '^([1-9][0-9]?d(4|6|8|10|12|20|100)([+-][0-9]{1,3})?|[0-9]{1,3})$';
  props text[]; grp text; rtype text; v_ammo text; rn int; rm int; vd text; dd text; dt text; mode text; cap int;
  is_shield boolean; base int; bonus int; v_icon text; v_details jsonb;
  -- 20261114000500
  fx jsonb; fx_type text; fx_act text; fx_target text; fx_val numeric; fx_max int; fx_list jsonb := '[]'; gs_list jsonb := '[]';
  gs_cast text; gs_uses int; gs_rech text; has_fx boolean; has_gs boolean;
  abil constant text[] := array['str', 'dex', 'con', 'int', 'wis', 'cha'];
  skl constant text[] := array['acrobatics', 'animal_handling', 'arcana', 'athletics', 'deception', 'history', 'insight',
    'intimidation', 'investigation', 'medicine', 'nature', 'perception', 'performance', 'persuasion', 'religion',
    'sleight_of_hand', 'stealth', 'survival'];
  acts constant text[] := array['owned', 'equipped', 'attuned', 'equipped_and_attuned', 'permanent'];
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

  -- 20261114000500: automated effects and granted spells. Only DM content items (cc-...) may have them: player homebrew
  -- (create / update homebrew item) cannot author a +2 item. Validated here, so a DM sees a readable message on Validate.
  has_fx := p_def ? 'effects' and jsonb_typeof(p_def -> 'effects') <> 'null';
  has_gs := p_def ? 'spells' and jsonb_typeof(p_def -> 'spells') <> 'null';
  if (has_fx or has_gs) and p_id !~ '^cc-' then
    raise exception 'Only items made in DM Space can have automated effects or granted spells' using errcode = '42501';
  end if;
  if (has_fx or has_gs) and not p_is_new then                         -- review v33 m2: copies players hold keep their version
    raise exception 'A published version never changes its effects or granted spells: make a new version in DM Space' using errcode = '22023';
  end if;
  if has_fx then
    if jsonb_typeof(p_def -> 'effects') <> 'array' or jsonb_array_length(p_def -> 'effects') > 20 then
      raise exception 'Effects are a list of at most 20 effects' using errcode = '22023';
    end if;
    for fx in select x from jsonb_array_elements(p_def -> 'effects') x loop
      if jsonb_typeof(fx) <> 'object' then raise exception 'An effect must be an object' using errcode = '22023'; end if;
      fx_type := nullif(fx ->> 'type', '');
      if fx_type is null or not fx_type = any (array['ability_bonus', 'ability_override', 'skill_bonus', 'save_bonus', 'ac_bonus',
           'initiative_bonus', 'speed_bonus', 'speed_penalty', 'resistance', 'skill_advantage', 'skill_disadvantage']) then
        raise exception 'Choose what each effect changes (unknown effect "%")', coalesce(fx_type, '') using errcode = '22023';
      end if;
      fx_act := coalesce(nullif(fx ->> 'activation', ''), case when v_att then 'attuned' else 'equipped' end);
      if not fx_act = any (acts) then
        raise exception 'Choose when the effect applies: while carried, equipped, attuned, equipped and attuned, or permanently when used' using errcode = '22023';
      end if;
      if v_att and fx_act in ('owned', 'equipped') then
        raise exception 'This item requires attunement: its effects apply while attuned (or permanently when it is used)' using errcode = '22023';
      end if;
      if fx_act = 'permanent' and not v_cons then
        raise exception 'A permanent effect applies when the item is used up: make the item consumable' using errcode = '22023';
      end if;
      if fx_act = 'permanent' and not fx_type = any (array['ability_bonus', 'ac_bonus', 'save_bonus', 'skill_bonus', 'initiative_bonus', 'speed_bonus']) then
        raise exception 'A permanent effect is an ability, AC, saving throw, skill, initiative or speed bonus' using errcode = '22023';
      end if;
      fx_target := nullif(btrim(coalesce(fx ->> 'target', '')), '');
      if fx_type in ('ability_bonus', 'ability_override') then
        if fx_target is null or not fx_target = any (abil) then raise exception 'Choose the ability the effect changes' using errcode = '22023'; end if;
      elsif fx_type in ('skill_bonus', 'skill_advantage', 'skill_disadvantage') then
        if fx_target is null or not fx_target = any (skl) then raise exception 'Choose the skill the effect changes' using errcode = '22023'; end if;
      elsif fx_type = 'save_bonus' then
        if fx_target is not null and not fx_target = any (abil) then
          raise exception 'A saving throw bonus applies to one ability''s save, or to all saves (no target)' using errcode = '22023';
        end if;
      elsif fx_type = 'resistance' then
        if fx_target is null or not exists (select 1 from public.damage_types where id = fx_target) then
          raise exception 'Choose the damage type of the resistance' using errcode = '22023';
        end if;
      else
        fx_target := null;                                             -- AC, initiative, speed: no target
      end if;
      begin
        fx_val := nullif(fx ->> 'value', '')::numeric;
      exception when others then raise exception 'The value of an effect must be a number' using errcode = '22023';
      end;
      if fx_type in ('resistance', 'skill_advantage', 'skill_disadvantage') then fx_val := null;
      elsif fx_val is null or fx_val <> trunc(fx_val) then raise exception 'Give each effect a whole number value' using errcode = '22023';
      elsif fx_type = 'ability_override' and fx_val not between 1 and 30 then raise exception 'An ability score is set to a value from 1 to 30' using errcode = '22023';
      elsif fx_type in ('speed_bonus', 'speed_penalty') and fx_val not between -120 and 120 then raise exception 'A speed change is at most 120 ft' using errcode = '22023';
      elsif fx_type not in ('ability_override', 'speed_bonus', 'speed_penalty') and fx_val not between -10 and 10 then
        raise exception 'A bonus is a number from -10 to +10' using errcode = '22023';
      end if;
      fx_max := public._j_int(fx, 'max', 1, 30, 'Maximum score');
      if fx_max is not null and not (fx_type = 'ability_bonus' and fx_act = 'permanent') then
        raise exception 'A maximum score only applies to a permanent ability increase' using errcode = '22023';
      end if;
      fx_list := fx_list || jsonb_build_array(jsonb_build_object('type', fx_type, 'target', fx_target, 'value', fx_val, 'activation', fx_act,
                                                                 'max', fx_max));
    end loop;
  end if;
  if has_gs then
    if jsonb_typeof(p_def -> 'spells') <> 'array' or jsonb_array_length(p_def -> 'spells') > 10 then
      raise exception 'Granted spells are a list of at most 10 spells' using errcode = '22023';
    end if;
    for fx in select x from jsonb_array_elements(p_def -> 'spells') x loop
      if jsonb_typeof(fx) <> 'object' then raise exception 'A granted spell must be an object' using errcode = '22023'; end if;
      if nullif(fx ->> 'spell', '') is null or not exists (select 1 from public.spell_versions where id = fx ->> 'spell') then
        raise exception 'Choose a spell from the list for each granted spell (unknown "%")', coalesce(fx ->> 'spell', '') using errcode = '22023';
      end if;
      gs_cast := coalesce(nullif(fx ->> 'casting', ''), 'per_rest');
      if gs_cast not in ('at_will', 'spell_slots', 'per_rest') then
        raise exception 'A granted spell is cast at will, with the character''s spell slots, or a number of times per rest' using errcode = '22023';
      end if;
      gs_uses := public._j_int(fx, 'uses', 1, 20, 'Uses');
      gs_rech := nullif(fx ->> 'recharge', '');
      if gs_cast = 'per_rest' then
        gs_uses := coalesce(gs_uses, 1); gs_rech := coalesce(gs_rech, 'long_rest');
        if gs_rech not in ('short_rest', 'long_rest') then raise exception 'The uses come back after a short or a long rest' using errcode = '22023'; end if;
      else
        gs_uses := null; gs_rech := null;
      end if;
      fx_act := coalesce(nullif(fx ->> 'activation', ''), case when v_att then 'attuned' else 'equipped' end);
      if not fx_act = any (acts) then
        raise exception 'Choose when the spell is granted: while carried, equipped, attuned, equipped and attuned, or permanently when used' using errcode = '22023';
      end if;
      if v_att and fx_act in ('owned', 'equipped') then
        raise exception 'This item requires attunement: its spells are granted while attuned (or permanently when it is used)' using errcode = '22023';
      end if;
      if fx_act = 'permanent' and not v_cons then
        raise exception 'A permanent spell is granted when the item is used up: make the item consumable' using errcode = '22023';
      end if;
      if nullif(fx ->> 'ability', '') is not null and not (fx ->> 'ability') = any (abil) then
        raise exception 'Unknown spellcasting ability' using errcode = '22023';
      end if;
      gs_list := gs_list || jsonb_build_array(jsonb_build_object('spell', fx ->> 'spell', 'casting', gs_cast, 'uses', gs_uses, 'recharge', gs_rech,
                                                                 'activation', fx_act, 'ability', nullif(fx ->> 'ability', '')));
    end loop;
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
    if has_fx then delete from public.item_effects where item_id = p_id; end if;          -- 20261114000500
    if has_gs then delete from public.item_spell_grants where item_id = p_id; end if;
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
  -- 20261114000500: effects and granted spells (validated above; item_effects_before_write checks again)
  insert into public.item_effects (item_id, seq, effect_type, value, target, activation, stacking, max_score)
  select p_id, o::int, x ->> 'type', (x ->> 'value')::numeric, x ->> 'target', x ->> 'activation',
         case when x ->> 'type' = 'ability_override' then 'override' else 'additive' end, (x ->> 'max')::int
  from jsonb_array_elements(fx_list) with ordinality t(x, o);
  insert into public.item_spell_grants (item_id, seq, spell_version_id, casting, uses, recharge, activation, ability)
  select p_id, o::int, x ->> 'spell', x ->> 'casting', (x ->> 'uses')::int, x ->> 'recharge', x ->> 'activation', x ->> 'ability'
  from jsonb_array_elements(gs_list) with ordinality t(x, o);
end;
$function$
;

drop function if exists public._item_grant_relevant(text);

-- weapon action counters: deactivated, never deleted
do $$
begin
  perform set_config('tavern.resource_engine', 'on', true);
  update public.character_resources set active = false where source_type = 'item' and active and resource_key ~ '^itemw-[0-9a-f]{32}-';
  -- review v34 m5: the restored R-D1 sync never renames 'itemw-' rows, so a label must not name the action or the weapon (the
  -- copy may be unidentified later). Neutral label; expended and events kept; re-applying 20261114000600 names an active one again.
  update public.character_resources set name = 'Weapon action', notes = 'Weapon action (inactive)'
  where source_type = 'item' and resource_key ~ '^itemw-[0-9a-f]{32}-' and (name, coalesce(notes, '')) is distinct from ('Weapon action', 'Weapon action (inactive)');
  perform set_config('tavern.resource_engine', '', true);
end $$;

-- the table is kept (renamed), with its rows
alter table if exists public.item_weapon_blocks rename to item_weapon_blocks_rd2_backup;

update tl_cache.global_rev set rev = rev + 1 where id = 1;
reset lock_timeout;
notify pgrst, 'reload schema';
