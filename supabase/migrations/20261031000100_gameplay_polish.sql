-- Gameplay polish (docs/GAMEPLAY_POLISH_AUDIT.md). Additive and reversible: supabase/rollback/rollback_gameplay_polish.sql.
-- 1. _write_homebrew: an empty stats section (an untouched form part) is ignored, so a non-armor item no longer fails with
--    "Armor stats only apply to armor"; a weapon now needs damage dice. Every other rule unchanged.
-- 2. _store_feat_choices: NULL-safe "fixed" test. The choices of a feat granted with a parameter (Magic Initiate from Acolyte,
--    Guide, Sage) were silently dropped, so its spells were never granted. Existing characters are re-synced at the end.
-- 3. adjust_character_coins: one atomic, row-locked coin transaction (spend with change, gain, undo by set), checked on the server.
-- 4. Lineage limited-use traits (Hungry Jaws, Breath Weapon, Healing Hands, ...: lineage_trait_effects 'limited_use') become
--    structured counters in character_resources (source_type 'lineage'), kept in step with the character's lineage by a trigger.

-- ----------------------------------------------------------------------------------------------- 1. homebrew item validation
CREATE OR REPLACE FUNCTION public._write_homebrew(p_id text, p_def jsonb, p_stats jsonb, p_is_new boolean)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
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
$function$;

-- ------------------------------------------------------------------------------------------------ 2. feat choices
CREATE OR REPLACE FUNCTION public._store_feat_choices(p_character uuid, p_grant text, p_version text, p_choices jsonb, p_require_complete boolean)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare c public.feat_choices; v_vals text[]; v text; err text; i int; lst text; total int; fixed boolean; par text;
begin
  if p_choices is not null and jsonb_typeof(p_choices) <> 'object' then raise exception 'Choices must be an object' using errcode = '22023'; end if;
  for c in select * from public.feat_choices where version_id = p_version order by seq loop
    select g.parameter into par from public._character_feat_grants(p_character) g where g.grant_key = p_grant;
    -- 20261031000100: coalesce. Without it, a choice WITHOUT a parameter_map (ability, cantrips, spell) of a feat granted WITH a
    -- parameter (Magic Initiate from Acolyte / Guide / Sage) made `fixed` NULL, `not fixed` NULL, and the choice was silently skipped
    fixed := coalesce(par is not null and (c.config -> 'parameter_map') ? par, false);
    if p_choices ? c.key and not fixed then
      if jsonb_typeof(p_choices -> c.key) <> 'array' then raise exception '% must be a list', c.label using errcode = '22023'; end if;
      v_vals := array(select jsonb_array_elements_text(p_choices -> c.key));
      if cardinality(v_vals) > c.max_picks then raise exception '%: at most % choices', c.label, c.max_picks using errcode = '22023'; end if;
      if (select count(distinct x) from unnest(v_vals) x) <> cardinality(v_vals) then raise exception '%: the same value twice', c.label using errcode = '22023'; end if;
      lst := case when c.config ? 'list_from' then coalesce(
               (select (array(select jsonb_array_elements_text(p_choices -> (c.config ->> 'list_from'))))[1]),
               (select x.vals[1] from public._character_feat_choice_values(p_character) x where x.grant_key = p_grant and x.key = c.config ->> 'list_from')) end;
      foreach v in array v_vals loop
        err := public._feat_choice_value_error(c, v, lst);
        if err is not null then raise exception '%: %', c.label, err using errcode = '22023'; end if;
      end loop;
      if c.kind = 'asi_points' then
        select coalesce(sum(split_part(x, ':', 2)::int), 0) into total from unnest(v_vals) x;
        if total > coalesce((c.config ->> 'points')::int, 2) then raise exception '%: % points at most', c.label, c.config ->> 'points' using errcode = '22023'; end if;
      end if;
      if c.kind = 'expertise' then
        foreach v in array v_vals loop
          if not (public._feat_prereq_ctx(p_character) -> 'skills') ? v
             and not exists (select 1 from unnest(array(select jsonb_array_elements_text(coalesce(p_choices -> 'skill', '[]'))) || '{}') s where s = v) then
            raise exception 'Expertise needs proficiency in %', v using errcode = '22023';
          end if;
        end loop;
      end if;
      -- a feat repeatable only with a different option (Magic Initiate list, Elemental Adept type): no other grant of the same
      -- feat may hold the same value of the distinct choice
      if exists (select 1 from public.feat_versions fv where fv.id = p_version and fv.repeatable = 'repeatable_distinct' and fv.distinct_choice_key = c.key)
         and exists (select 1 from public._character_feat_choice_values(p_character) o
                     join public.feat_versions ov on ov.id = o.feat_version_id
                     where o.grant_key <> p_grant and o.key = c.key and ov.feat_id = (select feat_id from public.feat_versions where id = p_version)
                       and o.vals && v_vals) then
        raise exception '%: you already have this feat with that choice; pick a different one', c.label using errcode = '22023';
      end if;
      delete from public.character_feat_choices where character_id = p_character and grant_key = p_grant and choice_id = c.id;
      i := 0;
      foreach v in array v_vals loop
        i := i + 1;
        insert into public.character_feat_choices (character_id, grant_key, choice_id, pick, value) values (p_character, p_grant, c.id, i, v);
      end loop;
    end if;
  end loop;
  if p_require_complete and exists (select 1 from public._character_feat_choice_values(p_character) x where x.grant_key = p_grant and not x.complete) then
    raise exception 'Some choices of this feat are still open' using errcode = '22023';
  end if;
end;
$function$;

-- ----------------------------------------------------------------------------------------------------------------- 3. coins
-- Deterministic spend (docs/GAMEPLAY_POLISH_AUDIT.md, "Coins"): (1) each requested denomination is paid from the same coins as far
-- as they go; (2) the rest is paid from the remaining coins, smallest denomination first, whole coins only; (3) if something is
-- still owed, ONE coin of the smallest denomination worth more than the rest is broken and the change returned largest first in
-- the standard coins below it (electrum is never created as change). Gain adds the entered coins as they are; no wallet is ever
-- normalised. 'set' writes an exact wallet and needs p_expected (the Undo of the last transaction).
create or replace function public.adjust_character_coins(p_character uuid, p_mode text, p_amount jsonb, p_expected jsonb default null)
returns jsonb language plpgsql volatile set search_path = public, pg_temp as $$
declare
  dn constant text[] := array['cp', 'sp', 'ep', 'gp', 'pp'];          -- ascending value
  val constant int[] := array[1, 10, 50, 100, 1000];
  w int[]; a int[] := array[0, 0, 0, 0, 0]; n int[]; i int; j int; k text; x jsonb; owed bigint; take int;
  tot_w bigint := 0; tot_a bigint := 0; chg bigint; brk int;
begin
  if p_character is null or auth.uid() is null or not public.can_access_character(p_character) then
    raise exception 'Character not found' using errcode = '42501';
  end if;
  if p_mode is null or p_mode not in ('spend', 'gain', 'set') then raise exception 'Choose spend or gain' using errcode = '22023'; end if;
  if p_amount is null or jsonb_typeof(p_amount) <> 'object' then raise exception 'Enter an amount' using errcode = '22023'; end if;
  for k in select jsonb_object_keys(p_amount) loop
    if not k = any (dn) then raise exception 'Unknown coin "%"', k using errcode = '22023'; end if;
    x := p_amount -> k;
    if jsonb_typeof(x) <> 'number' or (x #>> '{}') !~ '^[0-9]{1,7}$' then
      raise exception 'Coins must be whole numbers from 0 to 9,999,999' using errcode = '22023';
    end if;
    a[array_position(dn, k)] := (x #>> '{}')::int;
  end loop;
  select array[c.cp, c.sp, c.ep, c.gp, c.pp] into w from public.characters c where c.id = p_character for update;   -- RLS + row lock
  if w is null then raise exception 'Character not found' using errcode = '42501'; end if;
  w := array[coalesce(w[1], 0), coalesce(w[2], 0), coalesce(w[3], 0), coalesce(w[4], 0), coalesce(w[5], 0)];
  if p_expected is not null then
    for i in 1 .. 5 loop
      if coalesce((p_expected ->> dn[i])::int, 0) <> w[i] then
        raise exception 'The coins were changed in another session. Check the new amounts and try again.' using errcode = '40001';
      end if;
    end loop;
  end if;
  for i in 1 .. 5 loop tot_w := tot_w + w[i]::bigint * val[i]; tot_a := tot_a + a[i]::bigint * val[i]; end loop;
  if p_mode = 'set' then
    if p_expected is null then raise exception 'Undo needs the current amounts' using errcode = '22023'; end if;
    n := a;
  elsif tot_a = 0 then
    raise exception 'Enter an amount' using errcode = '22023';
  elsif p_mode = 'gain' then
    n := array[w[1] + a[1], w[2] + a[2], w[3] + a[3], w[4] + a[4], w[5] + a[5]];
  else
    if tot_a > tot_w then
      raise exception 'Not enough coins: you have % cp worth, this costs % cp.', tot_w, tot_a using errcode = '22023';
    end if;
    n := w; owed := 0;
    for i in 1 .. 5 loop                                   -- (1) the same coins
      take := least(n[i], a[i]); n[i] := n[i] - take; owed := owed + (a[i] - take)::bigint * val[i];
    end loop;
    for i in 1 .. 5 loop                                   -- (2) remaining coins, smallest first, whole coins
      exit when owed = 0;
      take := least(n[i]::bigint, owed / val[i])::int; n[i] := n[i] - take; owed := owed - take::bigint * val[i];
    end loop;
    if owed > 0 then                                       -- (3) break one coin; change in standard coins below it
      select min(i2) into brk from generate_series(1, 5) i2 where n[i2] > 0 and val[i2] > owed;
      n[brk] := n[brk] - 1; chg := val[brk] - owed;
      for j in reverse brk - 1 .. 1 loop
        continue when dn[j] = 'ep';
        n[j] := n[j] + (chg / val[j])::int; chg := chg % val[j];
      end loop;
    end if;
  end if;
  for i in 1 .. 5 loop
    if n[i] < 0 or n[i] > 99999999 then raise exception 'That would leave an impossible amount of %', dn[i] using errcode = '22023'; end if;
  end loop;
  update public.characters set cp = n[1], sp = n[2], ep = n[3], gp = n[4], pp = n[5] where id = p_character;   -- one statement
  return jsonb_build_object('character_id', p_character, 'mode', p_mode,
    'before', jsonb_build_object('cp', w[1], 'sp', w[2], 'ep', w[3], 'gp', w[4], 'pp', w[5]),
    'after', jsonb_build_object('cp', n[1], 'sp', n[2], 'ep', n[3], 'gp', n[4], 'pp', n[5]),
    'total_before_cp', tot_w,
    'total_after_cp', n[1] + n[2]::bigint * 10 + n[3]::bigint * 50 + n[4]::bigint * 100 + n[5]::bigint * 1000);
end $$;
revoke all on function public.adjust_character_coins(uuid, text, jsonb, jsonb) from public, anon;
grant execute on function public.adjust_character_coins(uuid, text, jsonb, jsonb) to authenticated, service_role;

-- ------------------------------------------------------------------------------------------------------- 4. lineage resources
-- One counter per limited-use trait of the character's lineage / sub-lineage ('limited_use' effects: uses 1 or pb, recharge
-- long_rest or short_or_long_rest; none of the 42 depends on an option). Key lin-<trait id>; unlock_level = the trait's minimum
-- level (compared with the total level on read). A trait the character no longer has is deactivated (its count kept), so a
-- re-chosen lineage reuses the same row: no duplicates.
create or replace function public._sync_lineage_resources(p_character uuid)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare t record; keep text[] := '{}'; k text;
begin
  -- the resource engine (20261015001700) may be rolled back on its own: then there is nothing to keep in step
  if to_regclass('public.character_resources') is null then return; end if;
  for t in
    select lt.id as trait_id, lt.name, lt.summary, e.data, lv.name as lineage_name,
           greatest(coalesce(lt.min_level, 1), coalesce(e.min_level, 1)) as unlock
    from public.character_lineages cl
    join public.lineage_traits lt on lt.version_id = cl.version_id or lt.version_id = cl.subversion_id
    join public.lineage_trait_effects e on e.trait_id = lt.id and e.effect_type = 'limited_use'
                                        and e.option_id is null and e.choice_id is null
    left join public.lineage_versions lv on lv.id = lt.version_id
    where cl.character_id = p_character
      and (e.data ->> 'uses' = 'pb' or e.data ->> 'uses' ~ '^[1-9][0-9]?$')
      and e.data ->> 'recharge' in ('short_rest', 'long_rest', 'short_or_long_rest', 'dawn')
    order by lt.id
  loop
    k := trim(both '-' from 'lin-' || regexp_replace(lower(t.trait_id), '[^a-z0-9]+', '-', 'g'));
    continue when k = any (keep);
    keep := keep || k;
    insert into public.character_resources (character_id, resource_key, name, source_type, source_id, max_formula, recharge,
                                            unlock_level, active, notes, created_by)
    values (p_character, k, left(t.name, 80), 'lineage', t.trait_id,
            case when t.data ->> 'uses' = 'pb' then '{"terms": [{"of": "proficiency_bonus"}]}'::jsonb
                 else jsonb_build_object('fixed', (t.data ->> 'uses')::int) end,
            t.data ->> 'recharge', case when t.unlock > 1 then t.unlock end, true,
            -- "<lineage> · <what it does>" (the Play card shows the lineage as the source and the rest as the action detail)
            left(coalesce(t.lineage_name, 'Lineage') || coalesce(' · ' || nullif(t.summary, ''), ' · ' || (t.data ->> 'notes'), ''), 500), auth.uid())
    on conflict (character_id, resource_key) do update
      set active = true, name = excluded.name, max_formula = excluded.max_formula, recharge = excluded.recharge,
          unlock_level = excluded.unlock_level, notes = excluded.notes, source_type = 'lineage', source_id = excluded.source_id;
  end loop;
  update public.character_resources set active = false
  where character_id = p_character and source_type = 'lineage' and resource_key like 'lin-%' and active
    and not (resource_key = any (keep));
end $$;
revoke all on function public._sync_lineage_resources(uuid) from public, anon, authenticated;

create or replace function public._lineage_resources_trigger()
returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
declare cid uuid := coalesce(new.character_id, old.character_id);
begin
  if exists (select 1 from public.characters where id = cid) then perform public._sync_lineage_resources(cid); end if;
  return null;
end $$;
revoke all on function public._lineage_resources_trigger() from public, anon, authenticated;
drop trigger if exists character_lineages_resources on public.character_lineages;
create trigger character_lineages_resources after insert or update or delete on public.character_lineages
  for each row execute function public._lineage_resources_trigger();

-- ------------------------------------------------------------------------------------------- 5. existing characters (idempotent)
do $$
declare c uuid; n_lin int := 0; n_feat int := 0;
begin
  for c in select distinct character_id from public.character_lineages loop
    perform public._sync_lineage_resources(c); n_lin := n_lin + 1;
  end loop;
  -- characters with a feat whose grants carry spells: the sync creates only what complete choices ask for, never duplicates
  -- (unique source / spell), and leaves every other spell source alone
  for c in select distinct g.character_id from (
      select cf.character_id, cf.feat_version_id as v from public.character_feats cf
      union all
      select cb.character_id, bg.feat_id from public.character_backgrounds cb join public.background_feat_grants bg on bg.version_id = cb.version_id) g
    where exists (select 1 from public.feat_spell_grants s where s.version_id = g.v)
      and exists (select 1 from public.characters ch where ch.id = g.character_id)
  loop
    perform public._sync_character_feats(c); n_feat := n_feat + 1;
  end loop;
  raise notice 'gameplay polish: lineage resources synced for % characters, feat spells re-synced for % characters', n_lin, n_feat;
end $$;

notify pgrst, 'reload schema';
