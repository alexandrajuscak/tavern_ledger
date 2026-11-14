-- R-D3 hardening (review v34 M4, m1, m2, m3, n1). Additive; rollback supabase/rollback/rollback_hardening.sql (the exact previous
-- function bodies; no data is changed by this migration or by its rollback).
--  1. M4: _derived_stats_core returned the TRUE name and item id of an equipped copy the reader sees only disguised (an
--     unidentified copy of an item whose catalog row the player can read, e.g. because he holds another identified copy).
--     Equipped weapons, armor, shield, their warnings / AC / speed parts and the proficiency match now carry the copy's disguise
--     and no item id for such a reader (as v_inventory_detail and _character_item_effect_rows already do); a disguised tool is
--     not listed under tools. The numbers do not change (the copy still works). The DM sees what he saw before.
--  2. m1: get_character_resources leaves out an INACTIVE item counter of a copy the reader sees only disguised.
--  3. m2: save_character_resource refuses a player's change to an item / feat / lineage counter (or a new one with such a source
--     or a reserved key); delete_character_resource refuses to delete such a counter for everybody (the sync would recreate it
--     unspent, past the rest limit). The DM may still adjust them.
--  4. m3: transfer_inventory_item and set_item_knowledge take one per-item lock (pg_advisory_xact_lock(4242, hashtext(item id)))
--     before any row lock: moving one copy while the DM identifies a sibling copy deadlocked (40P01) or failed with
--     lock_not_available on tl_cache.global_rev (supabase/tests/item_knowledge_transfer_concurrency_test.sh). The two-key space
--     4242 is new (4241 = grant sync flush; one-key locks are a different space).
--  5. n1: a weapon's Special block reports whether its linked item effect applies now (effect.active).
set lock_timeout = '5s';

-- ---------------------------------------------------------------------------------------------------- 1. masking helper (M4)
-- true when the reader sees this inventory row only under its disguise: the copy is not (fully) identified and the reader is
-- not the campaign DM / an admin (an internal call without a JWT knows everything). The predicate of v_inventory_detail and
-- _character_item_effect_rows. Invoker rights: the knowledge row is read under its RLS (owner and DM of the inventory).
create or replace function public._inventory_item_masked(p_row uuid)
returns boolean language sql stable set search_path = public, pg_temp as $$
  select coalesce((select kk.state <> 'identified' and auth.uid() is not null and not public._inventory_knows_all(ii.inventory_id)
                   from public.inventory_items ii join public.inventory_item_knowledge kk on kk.inventory_item_id = ii.id
                   where ii.id = p_row), false);
$$;
revoke all on function public._inventory_item_masked(uuid) from public, anon;
grant execute on function public._inventory_item_masked(uuid) to authenticated, service_role;

-- ------------------------------------------------------------------- 2. derived stats core (body of 20261114000500 + M4)
CREATE OR REPLACE FUNCTION public._derived_stats_core(p_character uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  c public.characters;
  pb int;
  effects jsonb;
  abilities jsonb := '{}'; scores jsonb := '{}'; mods jsonb := '{}';
  k text; base_score int; override_score int; bonus int; score int;
  armor record; shield record; w record;
  dex_mod int; dex_part int; formula text; ac_parts jsonb := '[]'; ac_calc int; alternatives jsonb := '[]';
  armor_prof jsonb; shield_prof jsonb; nonprof_armor boolean := false; nonprof_shield boolean := false;
  stealth_sources jsonb := '[]'; str_unmet boolean := false; speed_parts jsonb; speed_val int;
  warnings jsonb := '[]'; weapons jsonb := '[]'; saves jsonb := '{}'; skills jsonb := '{}';
  ab text; ab_mod int; prof jsonb; atk_magic int; dmg_magic int; atk_total int; dmg_bonus int; atk_parts jsonb; dmg_parts jsonb;
  grp text; legacy_eq int; hidden jsonb;
  -- lineage layer (20261015001500)
  lsel public.character_lineages; leff jsonb := '[]'; lin_included boolean := false; lin_bonus int; after_lineage int;
  bg_alloc jsonb := '{}'; bg_bonus int; lin_after int;
  form_ab jsonb; form_name text;
  nat jsonb; nat_val int; armor_val int; worn boolean; use_nat boolean; armor_cat text; heavy_ignore jsonb;
  walk_eff jsonb; movement jsonb; mv text; best jsonb; any_mode jsonb; lin_skills jsonb; nat_weapons jsonb := '[]';
  -- item effects (20261114000500): permanent increases (used consumables), capped per row (default max 20)
  perm jsonb := '[]'; pk jsonb; pscore int; pbefore int; papplied jsonb;
begin
  select * into c from public.characters where id = p_character;                 -- RLS: owner, campaign DM, admin
  if not found then raise exception 'Character not found' using errcode = '42501'; end if;

  pb := (greatest(c.level, 1) - 1) / 4 + 2;
  select coalesce(jsonb_agg(to_jsonb(e) order by e.effect_type, e.source_name, e.seq), '[]'::jsonb) into effects
  from public._character_effects(p_character) e;
  perm := public._character_permanent_effect_rows(p_character);       -- 20261114000500
  select * into lsel from public.character_lineages where character_id = p_character;
  if found then
    lin_included := lsel.ability_bonuses_included;
    select coalesce(jsonb_agg(to_jsonb(e)), '[]') into leff from public._lineage_effects(p_character) e;
  end if;

  select f.abilities, f.name into form_ab, form_name from public._active_form(p_character) f;   -- Wild Shape (20261017001300)
  bg_alloc := public._character_background_abilities(p_character);         -- 2024 background increases (20261017001200)
  -- abilities: base score, highest active override (never lowers the score), plus additive bonuses (max 30)
  foreach k in array array['str', 'dex', 'con', 'int', 'wis', 'cha'] loop
    base_score := (to_jsonb(c) ->> (case k when 'str' then 'strength' when 'dex' then 'dexterity' when 'con' then 'constitution'
                                          when 'int' then 'intelligence' when 'wis' then 'wisdom' else 'charisma' end))::int;
    select max((e ->> 'value')::int) into override_score from jsonb_array_elements(effects) e
    where (e ->> 'applied')::boolean and e ->> 'effect_type' = 'ability_override' and e ->> 'target' = k;
    bonus := public._effect_total(effects, 'ability_bonus', k);
    lin_bonus := coalesce((select sum((e ->> 'value')::int) from jsonb_array_elements(leff) e
                           where (e ->> 'active')::boolean and e ->> 'effect_type' = 'ability_bonus' and e ->> 'target' = k), 0);
    lin_after := case when lin_included then base_score else greatest(base_score, least(20, base_score + lin_bonus)) end;
    bg_bonus := coalesce((bg_alloc ->> k)::int, 0);
    after_lineage := greatest(lin_after, least(20, lin_after + bg_bonus));      -- background after the lineage, both up to 20
    -- 20261114000500: permanent increases from used items, in the order they were applied; each up to its maximum (default 20),
    -- never lowering a score that is already higher; a negative one lowers the score (minimum 1). Reverted rows are not read.
    pscore := after_lineage; papplied := '[]';
    for pk in select x from jsonb_array_elements(perm) x
              where x ->> 'kind' = 'effect' and x ->> 'effect_type' = 'ability_bonus' and x ->> 'target' = k
              order by x ->> 'applied_at', x ->> 'id' loop
      pbefore := pscore;
      if (pk ->> 'value')::int >= 0 then
        pscore := greatest(pscore, least(coalesce((pk ->> 'max_score')::int, 20), pscore + (pk ->> 'value')::int));
      else
        pscore := greatest(1, pscore + (pk ->> 'value')::int);
      end if;
      papplied := papplied || jsonb_build_array(pk || jsonb_build_object('applied', pscore - pbefore));
    end loop;
    score := least(30, greatest(pscore, coalesce(override_score, 0)) + bonus);
    if form_ab is not null and k in ('str', 'dex', 'con') then score := (form_ab ->> k)::int; end if;   -- the form's physical scores
    scores := scores || jsonb_build_object(k, score);
    mods := mods || jsonb_build_object(k, public._ability_mod(score));
    abilities := abilities || jsonb_build_object(k, jsonb_build_object('base', base_score, 'score', score,
      'modifier', public._ability_mod(score), 'override', override_score, 'bonus', bonus,
      'lineage_bonus', lin_bonus, 'lineage_applied', lin_after - base_score, 'lineage_included', lin_included,
      'background_bonus', bg_bonus, 'background_applied', after_lineage - lin_after,
      'permanent_bonus', coalesce((select sum((x ->> 'value')::int) from jsonb_array_elements(papplied) x), 0),
      'permanent_applied', pscore - after_lineage, 'permanent_sources', papplied,
      'inactive_effects', (select coalesce(jsonb_agg(e), '[]'::jsonb) from jsonb_array_elements(effects) e
                           where e ->> 'effect_type' in ('ability_override', 'ability_bonus') and e ->> 'target' = k
                             and not (e ->> 'active')::boolean),
      'form_score', case when form_ab is not null and k in ('str', 'dex', 'con') then (form_ab ->> k)::int end,
      'form_name', case when form_ab is not null and k in ('str', 'dex', 'con') then form_name end,
      'lineage_sources', (select coalesce(jsonb_agg(jsonb_build_object('trait_id', e ->> 'trait_id', 'source_name', e ->> 'trait_name',
                                                                        'value', (e ->> 'value')::int)), '[]')
                          from jsonb_array_elements(leff) e
                          where (e ->> 'active')::boolean and e ->> 'effect_type' = 'ability_bonus' and e ->> 'target' = k),
      'sources', (select coalesce(jsonb_agg(e), '[]'::jsonb) from jsonb_array_elements(effects) e
                  where (e ->> 'applied')::boolean and e ->> 'effect_type' in ('ability_override', 'ability_bonus') and e ->> 'target' = k)));
  end loop;
  dex_mod := (mods ->> 'dex')::int;

  -- equipped armor and shield (stats of the item itself, or of its base item)
  select e.inventory_item_id, ii.item_id, case when mk.masked then coalesce(nullif(ii.custom_name, ''), nullif(ii.name, ''), 'Unidentified item') else coalesce(ii.custom_name, it.name) end as name,
         it.id is not null as visible, it.category_id, mk.masked, it.base_item_id, st.base_ac, st.ac_bonus, st.dex_modifier_mode, st.dex_cap, st.strength_requirement, st.stealth_disadvantage, st.is_shield
  into armor
  from public.character_equipment e
  join public.inventory_items ii on ii.id = e.inventory_item_id
  left join public.items it on it.id = ii.item_id
  left join lateral (select s.* from public.armor_stats s where s.item_id in (it.id, it.base_item_id)
                     order by s.item_id = it.id desc limit 1) st on true
  cross join lateral (select public._inventory_item_masked(ii.id) as masked) mk
  where e.character_id = p_character and e.slot_id = 'armor';

  select e.inventory_item_id, ii.item_id, case when mk.masked then coalesce(nullif(ii.custom_name, ''), nullif(ii.name, ''), 'Unidentified item') else coalesce(ii.custom_name, it.name) end as name,
         it.id is not null as visible, it.category_id, mk.masked, it.base_item_id, st.ac_bonus, st.is_shield
  into shield
  from public.character_equipment e
  join public.inventory_items ii on ii.id = e.inventory_item_id
  left join public.items it on it.id = ii.item_id
  left join lateral (select s.* from public.armor_stats s where s.item_id in (it.id, it.base_item_id)
                     order by s.item_id = it.id desc limit 1) st on true
  cross join lateral (select public._inventory_item_masked(ii.id) as masked) mk
  where e.character_id = p_character and e.slot_id = 'shield';

  -- ---- Armor Class: exactly one base formula, then additive bonuses --------------------------------------------
  -- candidates: unarmored (10 + DEX), worn armor, lineage natural armor ('best_of' competes with armor; 'replaces_armor'
  -- means worn armor gives no benefit). The best applicable one is used; the others are listed as alternatives.
  worn := armor.inventory_item_id is not null and armor.base_ac is not null and not armor.is_shield;
  if worn then
    armor_val := armor.base_ac + case armor.dex_modifier_mode when 'full' then dex_mod when 'capped' then least(dex_mod, armor.dex_cap) else 0 end;
  end if;
  select e into nat from jsonb_array_elements(leff) e
  where (e ->> 'active')::boolean and e ->> 'effect_type' = 'natural_armor'
  order by (e ->> 'value')::int + case when e -> 'data' ->> 'dex' = 'full' then dex_mod else 0 end desc limit 1;
  nat_val := (nat ->> 'value')::int + case when nat -> 'data' ->> 'dex' = 'full' then dex_mod else 0 end;
  use_nat := nat is not null and ((not worn and nat_val >= 10 + dex_mod)
                                  or (worn and nat -> 'data' ->> 'mode' = 'replaces_armor')
                                  or (worn and nat -> 'data' ->> 'mode' = 'best_of' and nat_val > armor_val));
  if use_nat then
    formula := 'natural_armor';
    ac_parts := ac_parts || jsonb_build_object('source_type', 'lineage', 'source_id', nat ->> 'trait_id', 'source_name', nat ->> 'trait_name',
                  'effect', 'base_ac', 'value', (nat ->> 'value')::int);
    ac_parts := ac_parts || jsonb_build_object('source_type', 'ability', 'source_id', 'dex', 'source_name', 'Dexterity',
                  'effect', 'ability_modifier', 'value', case when nat -> 'data' ->> 'dex' = 'full' then dex_mod else 0 end,
                  'modifier', dex_mod, 'mode', case when nat -> 'data' ->> 'dex' = 'full' then 'full' else 'none' end, 'cap', null,
                  'applied', nat -> 'data' ->> 'dex' = 'full');
    alternatives := alternatives || jsonb_build_object('formula', 'unarmored', 'value', 10 + dex_mod, 'used', false, 'reason', 'natural_armor_better');
    if worn then
      alternatives := alternatives || jsonb_build_object('formula', 'armor', 'value', armor_val, 'used', false,
        'reason', case when nat -> 'data' ->> 'mode' = 'replaces_armor' then 'natural_armor_replaces_armor' else 'natural_armor_better' end);
      if nat -> 'data' ->> 'mode' = 'replaces_armor' then
        warnings := warnings || jsonb_build_object('code', 'lineage_armor_no_benefit', 'severity', 'warning', 'source_type', 'armor',
                      'source_id', armor.inventory_item_id, 'item_id', case when armor.masked or not armor.visible then null else armor.item_id end, 'source_name', armor.name,
                      'trait_name', nat ->> 'trait_name');
      end if;
    end if;
  elsif worn then
    formula := case armor.dex_modifier_mode when 'full' then 'light_armor' when 'capped' then 'medium_armor' else 'heavy_armor' end;
    dex_part := case armor.dex_modifier_mode when 'full' then dex_mod when 'capped' then least(dex_mod, armor.dex_cap) else 0 end;
    ac_parts := ac_parts || jsonb_build_object('source_type', 'armor', 'source_id', armor.inventory_item_id, 'item_id', case when armor.masked or not armor.visible then null else armor.item_id end,
                  'source_name', armor.name, 'effect', 'base_ac', 'value', armor.base_ac);
    ac_parts := ac_parts || jsonb_build_object('source_type', 'ability', 'source_id', 'dex', 'source_name', 'Dexterity',
                  'effect', 'ability_modifier', 'value', dex_part, 'modifier', dex_mod, 'mode', armor.dex_modifier_mode,
                  'cap', armor.dex_cap, 'applied', armor.dex_modifier_mode <> 'none');
    alternatives := alternatives || jsonb_build_object('formula', 'unarmored', 'value', 10 + dex_mod, 'used', false,
                                                       'reason', 'armor_worn');
    if nat is not null then
      alternatives := alternatives || jsonb_build_object('formula', 'natural_armor', 'value', nat_val, 'used', false, 'reason', 'armor_better',
                                                         'source_name', nat ->> 'trait_name');
    end if;
  else
    formula := 'unarmored';
    ac_parts := ac_parts || jsonb_build_object('source_type', 'rule', 'source_id', 'unarmored', 'source_name', 'Unarmored',
                  'effect', 'base_ac', 'value', 10);
    ac_parts := ac_parts || jsonb_build_object('source_type', 'ability', 'source_id', 'dex', 'source_name', 'Dexterity',
                  'effect', 'ability_modifier', 'value', dex_mod, 'modifier', dex_mod, 'mode', 'full', 'cap', null, 'applied', true);
    if nat is not null then
      alternatives := alternatives || jsonb_build_object('formula', 'natural_armor', 'value', nat_val, 'used', false,
                                                         'reason', 'unarmored_better', 'source_name', nat ->> 'trait_name');
    end if;
  end if;
  if armor.inventory_item_id is not null and not worn then
    warnings := warnings || jsonb_build_object('code', case when armor.visible then 'armor_stats_unknown' else 'hidden_item' end,
                  'severity', 'warning', 'source_type', 'armor', 'source_id', armor.inventory_item_id, 'item_id', case when armor.masked or not armor.visible then null else armor.item_id end,
                  'source_name', armor.name);
  end if;
  if shield.inventory_item_id is not null then
    if shield.is_shield then
      ac_parts := ac_parts || jsonb_build_object('source_type', 'shield', 'source_id', shield.inventory_item_id, 'item_id', case when shield.masked or not shield.visible then null else shield.item_id end,
                    'source_name', shield.name, 'effect', 'ac_bonus', 'value', shield.ac_bonus);
    else
      warnings := warnings || jsonb_build_object('code', case when shield.visible then 'armor_stats_unknown' else 'hidden_item' end,
                    'severity', 'warning', 'source_type', 'shield', 'source_id', shield.inventory_item_id, 'item_id', case when shield.masked or not shield.visible then null else shield.item_id end,
                    'source_name', shield.name);
    end if;
  end if;
  ac_parts := ac_parts || coalesce((
    select jsonb_agg(jsonb_build_object('source_type', e ->> 'source_type', 'source_id', e ->> 'source_id', 'item_id', e ->> 'item_id',
             'modifier_id', e ->> 'modifier_id', 'source_name', e ->> 'source_name', 'effect', 'ac_bonus', 'value', (e ->> 'value')::int)
             order by e ->> 'source_name')
    from jsonb_array_elements(effects) e
    where (e ->> 'applied')::boolean and e ->> 'effect_type' = 'ac_bonus' and e ->> 'scope' = 'global'), '[]'::jsonb);
  select sum((p ->> 'value')::int) into ac_calc from jsonb_array_elements(ac_parts) p;

  -- ---- proficiency consequences of armor and shield ---------------------------------------------------------------
  armor_cat := coalesce(armor.category_id, (select category_id from public.items where id = armor.base_item_id));
  select e into heavy_ignore from jsonb_array_elements(leff) e
  where (e ->> 'active')::boolean and e ->> 'effect_type' = 'ignore_heavy_armor_speed_penalty' and armor_cat = 'heavy-armor' limit 1;
  if armor.inventory_item_id is not null and armor.visible then
    select id into grp from public.proficiency_groups
    where armor_category_id = coalesce(armor.category_id, (select category_id from public.items where id = armor.base_item_id));
    armor_prof := public._proficiency_match(p_character, armor.item_id, armor.base_item_id, grp);
    nonprof_armor := not (armor_prof ->> 'proficient')::boolean;
    if nonprof_armor then
      warnings := warnings || jsonb_build_object('code', 'nonproficient_armor', 'severity', 'warning', 'source_type', 'armor',
                    'source_id', armor.inventory_item_id, 'item_id', case when armor.masked or not armor.visible then null else armor.item_id end, 'source_name', armor.name,
                    'missing_group_id', armor_prof ->> 'missing_group_id', 'missing_group_name', armor_prof ->> 'missing_group_name');
    end if;
    if armor.stealth_disadvantage then
      stealth_sources := stealth_sources || jsonb_build_object('source_type', 'armor', 'source_id', armor.inventory_item_id,
                           'item_id', case when armor.masked or not armor.visible then null else armor.item_id end, 'source_name', armor.name);
      warnings := warnings || jsonb_build_object('code', 'stealth_disadvantage', 'severity', 'info', 'source_type', 'armor',
                    'source_id', armor.inventory_item_id, 'item_id', case when armor.masked or not armor.visible then null else armor.item_id end, 'source_name', armor.name);
    end if;
    if armor.strength_requirement is not null and (scores ->> 'str')::int < armor.strength_requirement then
      str_unmet := true;
      warnings := warnings || jsonb_build_object('code', 'strength_requirement_unmet', 'severity', 'warning', 'source_type', 'armor',
                    'source_id', armor.inventory_item_id, 'item_id', case when armor.masked or not armor.visible then null else armor.item_id end, 'source_name', armor.name,
                    'required', armor.strength_requirement, 'current', (scores ->> 'str')::int,
                    'speed_penalty', case when heavy_ignore is null then 10 else 0 end, 'speed_penalty_ignored_by', heavy_ignore ->> 'trait_name');
    end if;
  end if;
  if shield.inventory_item_id is not null and shield.visible then
    select id into grp from public.proficiency_groups where armor_category_id = 'shield';
    shield_prof := public._proficiency_match(p_character, shield.item_id, shield.base_item_id, grp);
    nonprof_shield := not (shield_prof ->> 'proficient')::boolean;
    if nonprof_shield then
      warnings := warnings || jsonb_build_object('code', 'nonproficient_shield', 'severity', 'warning', 'source_type', 'shield',
                    'source_id', shield.inventory_item_id, 'item_id', case when shield.masked or not shield.visible then null else shield.item_id end, 'source_name', shield.name,
                    'missing_group_id', shield_prof ->> 'missing_group_id', 'missing_group_name', shield_prof ->> 'missing_group_name');
    end if;
  end if;
  if nonprof_armor or nonprof_shield then
    warnings := warnings || jsonb_build_object('code', 'spellcasting_restricted', 'severity', 'warning', 'source_type', 'rule',
                  'source_id', case when nonprof_armor then armor.inventory_item_id else shield.inventory_item_id end,
                  'source_name', case when nonprof_armor then armor.name else shield.name end);
  end if;
  stealth_sources := stealth_sources || coalesce((select jsonb_agg(jsonb_build_object('source_type', e ->> 'source_type',
                       'source_id', e ->> 'source_id', 'item_id', e ->> 'item_id', 'source_name', e ->> 'source_name'))
                     from jsonb_array_elements(effects) e
                     where (e ->> 'applied')::boolean and e ->> 'effect_type' = 'skill_disadvantage' and e ->> 'target' = 'stealth'), '[]');

  -- ---- speed: stored base speed + permanent bonuses - equipment penalties (stored speed is never changed) ---------
  select e into walk_eff from jsonb_array_elements(leff) e
  where (e ->> 'active')::boolean and e ->> 'effect_type' = 'speed' and e ->> 'target' = 'walk' and e ->> 'value' is not null
  order by (e ->> 'value')::int desc limit 1;
  if walk_eff is not null then
    speed_parts := jsonb_build_array(jsonb_build_object('source_type', 'lineage', 'source_id', walk_eff ->> 'trait_id',
                     'source_name', walk_eff ->> 'trait_name', 'effect', 'base', 'value', (walk_eff ->> 'value')::int));
  else
    speed_parts := jsonb_build_array(jsonb_build_object('source_type', 'base', 'source_id', 'speed', 'source_name', 'Base speed',
                                                        'effect', 'base', 'value', c.speed));
  end if;
  if str_unmet and heavy_ignore is not null then
    speed_parts := speed_parts || jsonb_build_object('source_type', 'armor', 'source_id', armor.inventory_item_id, 'item_id', case when armor.masked or not armor.visible then null else armor.item_id end,
                     'source_name', armor.name, 'effect', 'strength_requirement', 'value', 0, 'ignored_by', heavy_ignore ->> 'trait_name',
                     'required', armor.strength_requirement, 'current', (scores ->> 'str')::int);
  elsif str_unmet then
    speed_parts := speed_parts || jsonb_build_object('source_type', 'armor', 'source_id', armor.inventory_item_id, 'item_id', case when armor.masked or not armor.visible then null else armor.item_id end,
                     'source_name', armor.name, 'effect', 'strength_requirement', 'value', -10,
                     'required', armor.strength_requirement, 'current', (scores ->> 'str')::int);
  end if;
  speed_parts := speed_parts || coalesce((select jsonb_agg(jsonb_build_object('source_type', e ->> 'source_type', 'source_id', e ->> 'source_id',
                     'item_id', e ->> 'item_id', 'source_name', e ->> 'source_name', 'effect', e ->> 'effect_type',
                     'value', case when e ->> 'effect_type' = 'speed_penalty' then -abs((e ->> 'value')::int) else (e ->> 'value')::int end))
                   from jsonb_array_elements(effects) e
                   where (e ->> 'applied')::boolean and e ->> 'effect_type' in ('speed_bonus', 'speed_penalty')), '[]');
  select greatest(0, sum((p ->> 'value')::int)) into speed_val from jsonb_array_elements(speed_parts) p;
  movement := jsonb_build_object('walk', jsonb_build_object('value', speed_val, 'active', true));
  foreach mv in array array['climb', 'swim', 'fly', 'burrow'] loop
    best := null; any_mode := null;
    select e || jsonb_build_object('resolved', case when e ->> 'value_text' = 'walk' then speed_val else (e ->> 'value')::int end,
                                   'blocked', coalesce(e -> 'conditions' -> 'not_armor' ? armor_cat, false) and worn)
    into any_mode
    from jsonb_array_elements(leff) e
    where (e ->> 'active')::boolean and e ->> 'effect_type' = 'speed' and e ->> 'target' = mv
    order by coalesce(e -> 'conditions' -> 'not_armor' ? armor_cat, false) and worn,
             case when e ->> 'value_text' = 'walk' then speed_val else (e ->> 'value')::int end desc
    limit 1;
    if any_mode is not null then
      movement := movement || jsonb_build_object(mv, jsonb_build_object(
        'value', (any_mode ->> 'resolved')::int, 'active', not (any_mode ->> 'blocked')::boolean,
        'inactive_reason', case when (any_mode ->> 'blocked')::boolean then 'armor' end,
        'equal_to_walk', any_mode ->> 'value_text' = 'walk', 'conditions', any_mode -> 'conditions',
        'source_name', any_mode ->> 'trait_name', 'trait_id', any_mode ->> 'trait_id'));
    end if;
  end loop;

  -- ---- saving throws and skills: only what equipment adds (proficiency is still calculated on the sheet) ---------
  foreach k in array array['str', 'dex', 'con', 'int', 'wis', 'cha'] loop
    saves := saves || jsonb_build_object(k, jsonb_build_object(
      'item_bonus', public._effect_total(effects, 'save_bonus', null) + public._effect_total(effects, 'save_bonus', k),
      'item_sources', (select coalesce(jsonb_agg(jsonb_build_object('source_type', e ->> 'source_type', 'source_name', e ->> 'source_name',
                                                                    'value', (e ->> 'value')::int, 'all_saves', e ->> 'target' is null)), '[]'::jsonb)
                       from jsonb_array_elements(effects) e where (e ->> 'applied')::boolean and e ->> 'effect_type' = 'save_bonus'
                         and e ->> 'scope' = 'global' and (e ->> 'target' is null or e ->> 'target' = k)),
      'inactive_effects', (select coalesce(jsonb_agg(e), '[]'::jsonb) from jsonb_array_elements(effects) e
                           where e ->> 'effect_type' = 'save_bonus' and (e ->> 'target' is null or e ->> 'target' = k)
                             and not (e ->> 'active')::boolean),
      'disadvantage', (nonprof_armor or nonprof_shield) and k in ('str', 'dex')));
  end loop;
  select coalesce(jsonb_object_agg(t.skill, t.v), '{}'::jsonb) into skills from (
    select s.skill, jsonb_build_object(
      'advantage', exists (select 1 from jsonb_array_elements(effects) e where (e ->> 'applied')::boolean
                           and e ->> 'effect_type' = 'skill_advantage' and e ->> 'target' = s.skill),
      'disadvantage', (s.skill = 'stealth' and jsonb_array_length(stealth_sources) > 0)
                      or exists (select 1 from jsonb_array_elements(effects) e where (e ->> 'applied')::boolean
                                 and e ->> 'effect_type' = 'skill_disadvantage' and e ->> 'target' = s.skill),
      'sources', case when s.skill = 'stealth' then stealth_sources else '[]'::jsonb end,
      'item_bonus', public._effect_total(effects, 'skill_bonus', s.skill),
      'item_sources', (select coalesce(jsonb_agg(jsonb_build_object('source_type', e ->> 'source_type', 'source_name', e ->> 'source_name',
                                                                    'value', (e ->> 'value')::int)), '[]'::jsonb)
                       from jsonb_array_elements(effects) e where (e ->> 'applied')::boolean and e ->> 'effect_type' = 'skill_bonus'
                         and e ->> 'target' = s.skill),
      'inactive_effects', (select coalesce(jsonb_agg(e), '[]'::jsonb) from jsonb_array_elements(effects) e
                           where e ->> 'effect_type' = 'skill_bonus' and e ->> 'target' = s.skill and not (e ->> 'active')::boolean)) as v
    from (select distinct e ->> 'target' as skill from jsonb_array_elements(effects) e
          where e ->> 'effect_type' in ('skill_advantage', 'skill_disadvantage', 'skill_bonus') and ((e ->> 'applied')::boolean
                or (e ->> 'effect_type' = 'skill_bonus' and not (e ->> 'active')::boolean))
          union select 'stealth') s) t;

  select coalesce(jsonb_object_agg(s.k, s.src), '{}') into lin_skills from (
    select e ->> 'value_text' as k, jsonb_agg(jsonb_build_object('source_type', 'lineage', 'trait_id', e ->> 'trait_id',
                                                                   'source_name', e ->> 'trait_name')) as src
    from jsonb_array_elements(leff) e
    where (e ->> 'active')::boolean and e ->> 'effect_type' = 'proficiency' and e ->> 'target' = 'skill'
    group by 1) s;
  for k in select jsonb_object_keys(lin_skills) loop
    skills := skills || jsonb_build_object(k, coalesce(skills -> k, '{"advantage": false, "disadvantage": false, "sources": []}'::jsonb)
                                               || jsonb_build_object('lineage_proficient', true, 'proficiency_sources', lin_skills -> k));
  end loop;

  -- ---- natural weapons from the lineage (unarmed strikes: Strength, always proficient) ---------------------------
  select coalesce(jsonb_agg(jsonb_build_object(
           'trait_id', e ->> 'trait_id', 'source_name', e ->> 'trait_name', 'name', e ->> 'value_text',
           'damage_dice', e -> 'data' ->> 'damage_dice', 'damage_type', e -> 'data' ->> 'damage_type', 'ability', 'str',
           'ability_modifier', (mods ->> 'str')::int, 'proficient', true, 'proficiency_bonus', pb,
           'attack_bonus', (mods ->> 'str')::int + pb,
           'damage', (e -> 'data' ->> 'damage_dice') || case when (mods ->> 'str')::int > 0 then ' + ' || (mods ->> 'str')
                                                             when (mods ->> 'str')::int < 0 then ' - ' || abs((mods ->> 'str')::int) else '' end,
           'attack_disadvantage', nonprof_armor or nonprof_shield) order by e ->> 'trait_id', e ->> 'seq'), '[]')
  into nat_weapons
  from jsonb_array_elements(leff) e where (e ->> 'active')::boolean and e ->> 'effect_type' = 'natural_weapon';

  -- ---- equipped weapons -----------------------------------------------------------------------------------------
  for w in
    select e.slot_id, e.inventory_item_id, ii.item_id, case when mk.masked then coalesce(nullif(ii.custom_name, ''), nullif(ii.name, ''), 'Unidentified item') else coalesce(ii.custom_name, it.name) end as name,
           mk.masked, it.base_item_id,
           ws.weapon_group, ws.damage_dice, ws.damage_type_id, ws.versatile_damage, ws.is_ranged, ws.range_normal, ws.range_max,
           exists (select 1 from public.weapon_property_links l where l.item_id = ws.item_id and l.property_id = 'finesse') as finesse,
           (select coalesce(array_agg(l.property_id order by l.property_id), '{}') from public.weapon_property_links l where l.item_id = ws.item_id) as properties
    from public.character_equipment e
    join public.inventory_items ii on ii.id = e.inventory_item_id
    join public.items it on it.id = ii.item_id
    join lateral (select s.* from public.weapon_stats s where s.item_id in (it.id, it.base_item_id)
                  order by s.item_id = it.id desc limit 1) ws on true
    cross join lateral (select public._inventory_item_masked(ii.id) as masked) mk
    where e.character_id = p_character and e.slot_id in ('main_hand', 'off_hand')
    order by e.slot_id
  loop
    if w.finesse then ab := case when (mods ->> 'dex')::int > (mods ->> 'str')::int then 'dex' else 'str' end;
    elsif w.is_ranged then ab := 'dex';
    else ab := 'str';
    end if;
    ab_mod := (mods ->> ab)::int;
    select id into grp from public.proficiency_groups where weapon_group = w.weapon_group;
    prof := public._proficiency_match(p_character, w.item_id, w.base_item_id, grp);
    atk_magic := public._effect_total(effects, 'attack_bonus', null, w.inventory_item_id) + public._effect_total(effects, 'attack_bonus', null);
    dmg_magic := public._effect_total(effects, 'damage_bonus', null, w.inventory_item_id) + public._effect_total(effects, 'damage_bonus', null);
    atk_total := ab_mod + case when (prof ->> 'proficient')::boolean then pb else 0 end + atk_magic;
    dmg_bonus := ab_mod + dmg_magic;
    atk_parts := jsonb_build_array(
      jsonb_build_object('source_type', 'ability', 'source_id', ab, 'effect', 'ability_modifier', 'value', ab_mod),
      jsonb_build_object('source_type', 'proficiency', 'source_id', 'proficiency_bonus', 'effect', 'proficiency_bonus',
                         'value', case when (prof ->> 'proficient')::boolean then pb else 0 end,
                         'applied', (prof ->> 'proficient')::boolean, 'proficiency_bonus', pb));
    atk_parts := atk_parts || coalesce((select jsonb_agg(jsonb_build_object('source_type', e ->> 'source_type', 'source_id', e ->> 'source_id',
                     'modifier_id', e ->> 'modifier_id', 'source_name', e ->> 'source_name', 'effect', 'attack_bonus', 'value', (e ->> 'value')::int))
                   from jsonb_array_elements(effects) e where (e ->> 'applied')::boolean and e ->> 'effect_type' = 'attack_bonus'
                     and (e ->> 'scope' = 'global' or (e ->> 'source_id')::uuid = w.inventory_item_id)), '[]');
    dmg_parts := jsonb_build_array(jsonb_build_object('source_type', 'ability', 'source_id', ab, 'effect', 'ability_modifier', 'value', ab_mod))
      || coalesce((select jsonb_agg(jsonb_build_object('source_type', e ->> 'source_type', 'source_id', e ->> 'source_id',
                     'modifier_id', e ->> 'modifier_id', 'source_name', e ->> 'source_name', 'effect', 'damage_bonus', 'value', (e ->> 'value')::int))
                   from jsonb_array_elements(effects) e where (e ->> 'applied')::boolean and e ->> 'effect_type' = 'damage_bonus'
                     and (e ->> 'scope' = 'global' or (e ->> 'source_id')::uuid = w.inventory_item_id)), '[]');
    weapons := weapons || jsonb_build_object(
      'inventory_item_id', w.inventory_item_id, 'item_id', case when w.masked then null else w.item_id end, 'name', w.name, 'slot_id', w.slot_id,
      'weapon_group', w.weapon_group, 'properties', to_jsonb(w.properties), 'is_ranged', w.is_ranged,
      'range_normal', w.range_normal, 'range_max', w.range_max,
      'ability', ab, 'ability_rule', case when w.finesse then 'finesse_best' when w.is_ranged then 'ranged_dex' else 'melee_str' end,
      'ability_modifier', ab_mod, 'proficient', (prof ->> 'proficient')::boolean, 'proficiency', case when w.masked then prof - 'item_id' else prof end,
      'proficiency_bonus', pb, 'proficiency_bonus_applied', (prof ->> 'proficient')::boolean,
      'magic_attack_bonus', atk_magic, 'attack_bonus', atk_total, 'attack_breakdown', atk_parts,
      'damage_dice', w.damage_dice, 'versatile_damage', w.versatile_damage, 'damage_type', w.damage_type_id,
      'magic_damage_bonus', dmg_magic, 'damage_bonus', dmg_bonus, 'damage_breakdown', dmg_parts,
      'damage', case when w.damage_dice is null then null
                     when w.damage_dice ~ '^[0-9]+$' then greatest(0, w.damage_dice::int + dmg_bonus)::text
                     when dmg_bonus = 0 then w.damage_dice
                     else w.damage_dice || case when dmg_bonus > 0 then ' + ' else ' - ' end || abs(dmg_bonus) end,
      'attack_disadvantage', nonprof_armor or nonprof_shield);
    if not (prof ->> 'proficient')::boolean then
      warnings := warnings || jsonb_build_object('code', 'nonproficient_weapon', 'severity', 'info', 'source_type', 'weapon',
                    'source_id', w.inventory_item_id, 'item_id', case when w.masked then null else w.item_id end, 'source_name', w.name,
                    'missing_group_id', prof ->> 'missing_group_id', 'missing_group_name', prof ->> 'missing_group_name');
    end if;
  end loop;

  -- ---- odds and ends --------------------------------------------------------------------------------------------
  select count(*) into legacy_eq from public.inventory_items ii join public.inventories inv on inv.id = ii.inventory_id
  where inv.character_id = p_character and ii.item_id is null and ii.equipped;
  if legacy_eq > 0 then
    warnings := warnings || jsonb_build_object('code', 'legacy_equipped_ignored', 'severity', 'info', 'source_type', 'legacy',
                  'source_id', null, 'count', legacy_eq);
  end if;
  select coalesce(jsonb_agg(jsonb_build_object('code', 'hidden_item', 'severity', 'warning', 'source_type', 'equipment',
           'source_id', e.inventory_item_id, 'slot_id', e.slot_id)), '[]') into hidden
  from public.character_equipment e join public.inventory_items ii on ii.id = e.inventory_item_id
  left join public.items it on it.id = ii.item_id
  where e.character_id = p_character and it.id is null and e.slot_id not in ('armor', 'shield');
  warnings := warnings || hidden;

  return public._background_layer(p_character, jsonb_build_object(
    'character_id', c.id,
    'ruleset', 'dnd5e-2014',
    'proficiency_bonus', jsonb_build_object('value', pb, 'source', 'level', 'level', c.level),
    'abilities', abilities,
    'armor_class', jsonb_build_object(
      'value', coalesce(c.ac_override, ac_calc), 'calculated', ac_calc, 'override', c.ac_override,
      'source', case when c.ac_override is not null then 'override' else 'calculated' end,
      'legacy_stored', c.ac, 'base_formula', formula, 'breakdown', ac_parts, 'alternatives', alternatives,
      'inactive_effects', (select coalesce(jsonb_agg(e), '[]'::jsonb) from jsonb_array_elements(effects) e
                           where e ->> 'effect_type' = 'ac_bonus' and not (e ->> 'active')::boolean)),
    'speed', jsonb_build_object('base', c.speed, 'value', speed_val, 'breakdown', speed_parts,
                                'base_source', case when walk_eff is not null then 'lineage' else 'character' end,
                                'movement', movement,
                                'inactive_effects', (select coalesce(jsonb_agg(e), '[]'::jsonb) from jsonb_array_elements(effects) e
                                                     where e ->> 'effect_type' in ('speed_bonus', 'speed_penalty') and not (e ->> 'active')::boolean)),
    'armor', case when armor.inventory_item_id is null then null else jsonb_build_object(
      'inventory_item_id', armor.inventory_item_id, 'item_id', case when armor.masked or not armor.visible then null else armor.item_id end, 'name', armor.name,
      'base_ac', armor.base_ac, 'dex_modifier_mode', armor.dex_modifier_mode, 'dex_cap', armor.dex_cap,
      'strength_requirement', armor.strength_requirement, 'stealth_disadvantage', armor.stealth_disadvantage,
      'proficiency', case when armor.masked then armor_prof - 'item_id' else armor_prof end) end,
    'shield', case when shield.inventory_item_id is null then null else jsonb_build_object(
      'inventory_item_id', shield.inventory_item_id, 'item_id', case when shield.masked or not shield.visible then null else shield.item_id end, 'name', shield.name,
      'ac_bonus', shield.ac_bonus, 'proficiency', case when shield.masked then shield_prof - 'item_id' else shield_prof end) end,
    'armor_consequences', jsonb_build_object(
      'nonproficient_armor', nonprof_armor, 'nonproficient_shield', nonprof_shield,
      'ability_check_disadvantage', case when nonprof_armor or nonprof_shield then '["str","dex"]'::jsonb else '[]'::jsonb end,
      'saving_throw_disadvantage', case when nonprof_armor or nonprof_shield then '["str","dex"]'::jsonb else '[]'::jsonb end,
      'attack_disadvantage', case when nonprof_armor or nonprof_shield then '["str","dex"]'::jsonb else '[]'::jsonb end,
      'spellcasting_restricted', nonprof_armor or nonprof_shield,
      'stealth_disadvantage', jsonb_array_length(stealth_sources) > 0, 'stealth_sources', stealth_sources,
      'strength_requirement_unmet', str_unmet,
      'strength_requirement', armor.strength_requirement, 'strength_current', (scores ->> 'str')::int,
      'speed_penalty', case when str_unmet and heavy_ignore is null then 10 else 0 end,
      'speed_penalty_ignored_by', case when str_unmet then heavy_ignore ->> 'trait_name' end),
    'saving_throws', saves,
    'skills', skills,
    'equipped_weapon_attacks', weapons,
    'tools', (select coalesce(jsonb_agg(jsonb_build_object('inventory_item_id', ii.id, 'item_id', ii.item_id,
                'name', coalesce(ii.custom_name, it.name), 'category_id', it.category_id,
                'proficient', (public._proficiency_match(p_character, ii.item_id, it.base_item_id, null) ->> 'proficient')::boolean)
                order by it.name), '[]'::jsonb)
              from public.inventory_items ii join public.inventories inv on inv.id = ii.inventory_id
              join public.items it on it.id = ii.item_id
              where inv.character_id = p_character and it.kind_id = 'tool' and not public._inventory_item_masked(ii.id)),
    'proficiencies', (select coalesce(jsonb_agg(jsonb_build_object('id', p.id, 'proficiency_type', p.proficiency_type,
                        'group_id', p.group_id, 'item_id', p.item_id, 'name', coalesce(g.name, it.name, p.item_id),
                        'source_type', p.source_type, 'notes', p.notes) order by p.proficiency_type, coalesce(g.sort_order, 1000), coalesce(g.name, it.name)), '[]'::jsonb)
                      from public.character_proficiencies p
                      left join public.proficiency_groups g on g.id = p.group_id
                      left join public.items it on it.id = p.item_id
                      where p.character_id = p_character)
                     || (select coalesce(jsonb_agg(jsonb_build_object('id', null, 'proficiency_type',
                              case e ->> 'target' when 'group' then g.proficiency_type when 'armor' then
                                   case when it.category_id = 'shield' then 'shield' else 'armor' end else e ->> 'target' end,
                              'group_id', case when e ->> 'target' = 'group' then e ->> 'value_text' end,
                              'item_id', case when e ->> 'target' <> 'group' then e ->> 'value_text' end,
                              'name', coalesce(g.name, it.name, e ->> 'value_text'), 'source_type', 'lineage',
                              'notes', e ->> 'trait_name', 'trait_id', e ->> 'trait_id')
                              order by e ->> 'target', coalesce(g.name, it.name)), '[]')
                         from jsonb_array_elements(leff) e
                         left join public.proficiency_groups g on e ->> 'target' = 'group' and g.id = e ->> 'value_text'
                         left join public.items it on e ->> 'target' in ('weapon', 'armor', 'tool') and it.id = e ->> 'value_text'
                         where (e ->> 'active')::boolean and e ->> 'effect_type' = 'proficiency' and e ->> 'target' <> 'skill'),
    'other_effects', (select coalesce(jsonb_agg(e), '[]'::jsonb) from jsonb_array_elements(effects) e
                      where e ->> 'effect_type' in ('resistance', 'carrying_capacity_bonus') or e ->> 'effect_type' is null),
    'effects', effects,
    'warnings', warnings,
    -- lineage layer
    'lineage', case when lsel.character_id is null then null else jsonb_build_object(
        'lineage_id', lsel.lineage_id, 'version_id', lsel.version_id, 'subversion_id', lsel.subversion_id,
        'name', (select name from public.lineages where id = lsel.lineage_id),
        'version_name', (select name from public.lineage_versions where id = lsel.version_id),
        'subversion_name', (select name from public.lineage_versions where id = lsel.subversion_id),
        'ability_bonuses_included', lsel.ability_bonuses_included) end,
    'size', (select jsonb_build_object('value', e ->> 'value_text', 'source_name', e ->> 'trait_name', 'trait_id', e ->> 'trait_id')
             from jsonb_array_elements(leff) e where (e ->> 'active')::boolean and e ->> 'effect_type' = 'size'
             order by (e ->> 'min_level')::int desc limit 1),
    'creature_type', (select coalesce(s.creature_type, v.creature_type) from public.lineage_versions v
                      left join public.lineage_versions s on s.id = lsel.subversion_id where v.id = lsel.version_id),
    'senses', (select coalesce(jsonb_object_agg(t.target, jsonb_build_object('value', t.v, 'source_name', t.src)), '{}') from (
                 select distinct on (e ->> 'target') e ->> 'target' as target, (e ->> 'value')::int as v, e ->> 'trait_name' as src
                 from jsonb_array_elements(leff) e where (e ->> 'active')::boolean and e ->> 'effect_type' = 'sense'
                 order by e ->> 'target', (e ->> 'value')::int desc) t),
    'languages', (select coalesce(jsonb_agg(jsonb_build_object('id', t.id, 'name', coalesce(lg.name, t.id), 'sources', t.src)
                                            order by coalesce(lg.sort_order, 999), t.id), '[]') from (
                    select e ->> 'value_text' as id, jsonb_agg(distinct e ->> 'trait_name') as src
                    from jsonb_array_elements(leff) e where (e ->> 'active')::boolean and e ->> 'effect_type' = 'language'
                    group by 1) t left join public.languages lg on lg.id = t.id),
    'resistances', (select coalesce(jsonb_agg(jsonb_build_object('damage_type', t.dt, 'sources', t.src) order by t.dt), '[]') from (
                      select x.dt, jsonb_agg(distinct x.src) as src from (
                        select e ->> 'value_text' as dt, e ->> 'trait_name' as src from jsonb_array_elements(leff) e
                        where (e ->> 'active')::boolean and e ->> 'effect_type' = 'resistance'
                        union all
                        select e ->> 'target', e ->> 'source_name' from jsonb_array_elements(effects) e
                        where (e ->> 'applied')::boolean and e ->> 'effect_type' = 'resistance') x group by 1) t),
    'immunities', (select coalesce(jsonb_agg(distinct e ->> 'value_text'), '[]') from jsonb_array_elements(leff) e
                   where (e ->> 'active')::boolean and e ->> 'effect_type' = 'immunity'),
    'condition_immunities', (select coalesce(jsonb_agg(distinct e ->> 'value_text'), '[]') from jsonb_array_elements(leff) e
                             where (e ->> 'active')::boolean and e ->> 'effect_type' = 'condition_immunity'),
    'advantages', (select coalesce(jsonb_agg(jsonb_build_object('kind', e ->> 'effect_type', 'target', e ->> 'target',
                     'scope', e ->> 'value_text', 'source_name', e ->> 'trait_name', 'trait_id', e ->> 'trait_id')
                     order by e ->> 'effect_type', e ->> 'trait_id', (e ->> 'seq')::int), '[]')
                   from jsonb_array_elements(leff) e
                   where (e ->> 'active')::boolean and e ->> 'effect_type' in ('save_advantage', 'check_advantage')),
    'natural_weapons', nat_weapons,
    'lineage_spells', (select coalesce(jsonb_agg(jsonb_build_object(
                         'name', e ->> 'value_text', 'slug', e -> 'data' ->> 'slug', 'trait_id', e ->> 'trait_id',
                         'source_name', e ->> 'trait_name', 'min_level', (e ->> 'min_level')::int, 'unlocked', (e ->> 'active')::boolean,
                         'uses', e -> 'data' ->> 'uses', 'recharge', e -> 'data' ->> 'recharge', 'cast_level', e -> 'data' -> 'cast_level',
                         'ability', e -> 'data' ->> 'ability', 'ability_needed', e -> 'data' ? 'ability_choice' and not e -> 'data' ? 'ability',
                         'save_dc', case when e -> 'data' ? 'ability' then 8 + pb + (mods ->> (e -> 'data' ->> 'ability'))::int end,
                         'attack_bonus', case when e -> 'data' ? 'ability' then pb + (mods ->> (e -> 'data' ->> 'ability'))::int end,
                         'notes', e -> 'data' ->> 'notes')
                         order by (e ->> 'min_level')::int, e ->> 'trait_id', (e ->> 'seq')::int), '[]')
                       from jsonb_array_elements(leff) e where e ->> 'effect_type' = 'spell'),
    'lineage_actions', (select coalesce(jsonb_agg(jsonb_build_object(
                          'name', e ->> 'value_text', 'trait_id', e ->> 'trait_id', 'source_name', e ->> 'trait_name',
                          'min_level', (e ->> 'min_level')::int, 'unlocked', (e ->> 'active')::boolean,
                          'uses', case e -> 'data' ->> 'uses' when 'pb' then to_jsonb(pb) when null then null
                                      else to_jsonb(e -> 'data' ->> 'uses') end,
                          'recharge', e -> 'data' ->> 'recharge',
                          'save_dc', case when e -> 'data' ? 'dc_ability' then 8 + pb + (mods ->> (e -> 'data' ->> 'dc_ability'))::int end,
                          'save_ability', e -> 'data' ->> 'save_ability',
                          'dice', (select d2 ->> 1 from jsonb_array_elements(e -> 'data' -> 'dice_by_level') d2
                                   where (d2 ->> 0)::int <= c.level order by (d2 ->> 0)::int desc limit 1),
                          'damage_type', e -> 'data' ->> 'damage_type', 'notes', e -> 'data' ->> 'notes')
                          order by (e ->> 'min_level')::int, e ->> 'trait_id', (e ->> 'seq')::int), '[]')
                        from jsonb_array_elements(leff) e where e ->> 'effect_type' = 'limited_use'),
    'initiative', jsonb_build_object('bonus', coalesce((select sum(case when e ->> 'value_text' = 'pb' then pb else (e ->> 'value')::int end)
                                                       from jsonb_array_elements(leff) e
                                                       where (e ->> 'active')::boolean and e ->> 'effect_type' = 'initiative_bonus'), 0)
                                              + public._effect_total(effects, 'initiative_bonus', null),
                                     'sources', (select coalesce(jsonb_agg(e ->> 'trait_name'), '[]') from jsonb_array_elements(leff) e
                                                 where (e ->> 'active')::boolean and e ->> 'effect_type' = 'initiative_bonus')
                                                || (select coalesce(jsonb_agg(e ->> 'source_name'), '[]') from jsonb_array_elements(effects) e
                                                    where (e ->> 'applied')::boolean and e ->> 'effect_type' = 'initiative_bonus' and e ->> 'scope' = 'global'),
                                     'item_sources', (select coalesce(jsonb_agg(jsonb_build_object('source_type', e ->> 'source_type',
                                                        'source_name', e ->> 'source_name', 'value', (e ->> 'value')::int)), '[]')
                                                      from jsonb_array_elements(effects) e
                                                      where (e ->> 'applied')::boolean and e ->> 'effect_type' = 'initiative_bonus' and e ->> 'scope' = 'global'),
                                     'inactive_effects', (select coalesce(jsonb_agg(e), '[]'::jsonb) from jsonb_array_elements(effects) e
                                                          where e ->> 'effect_type' = 'initiative_bonus' and not (e ->> 'active')::boolean)),
    'permanent_effects', perm,
    'hit_points', jsonb_build_object('lineage_bonus', coalesce((select sum((e ->> 'value')::int) * c.level from jsonb_array_elements(leff) e
                                                               where (e ->> 'active')::boolean and e ->> 'effect_type' = 'hp_per_level'), 0),
                                     'sources', (select coalesce(jsonb_agg(e ->> 'trait_name'), '[]') from jsonb_array_elements(leff) e
                                                 where (e ->> 'active')::boolean and e ->> 'effect_type' = 'hp_per_level')),
    'carrying_capacity', jsonb_build_object('size_steps', coalesce((select max((e ->> 'value')::int) from jsonb_array_elements(leff) e
                                                                    where (e ->> 'active')::boolean and e ->> 'effect_type' = 'carrying_capacity'), 0))));
end;
$function$
;

-- ------------------------------------------------------------------------- 3. resources read (body of 20261015001800 + m1)
CREATE OR REPLACE FUNCTION public.get_character_resources(p_character uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare mods jsonb; manual jsonb;
begin
  perform 1 from public.characters where id = p_character;                    -- RLS: owner, campaign DM, admin
  if not found then raise exception 'Character not found' using errcode = '42501'; end if;
  mods := public._character_mods(p_character);
  select coalesce(jsonb_agg(r || jsonb_build_object('key', 'r:' || (r ->> 'id'), 'kind', 'manual', 'automation', 'manual',
           'feature_name', null, 'class_name', null, 'max_known', true, 'temporary_bonus', 0, 'max_adjustment', 0,
           'active', (r ->> 'active')::boolean and (r ->> 'unlocked')::boolean,
           'max', (r ->> 'max')::int)), '[]')
  into manual from jsonb_array_elements(public._character_resource_rows(p_character, mods)) r
  -- 20261114000700 (review v34 m1): an inactive counter of a copy the reader sees only disguised is not listed
  where not (r ->> 'source_type' = 'item' and not (r ->> 'active')::boolean and r ->> 'source_id' ~ '^ii:[0-9a-f-]{36}$'
             and public._inventory_item_masked(substr(r ->> 'source_id', 4)::uuid));
  return jsonb_build_object('character_id', p_character,
    'resources', public._character_feature_resources(p_character, mods) || manual,
    'recharge_labels', jsonb_build_object('short_rest', 'Recovers on a short rest', 'long_rest', 'Recovers on a long rest',
      'short_or_long_rest', 'Recovers on a short or long rest', 'dawn', 'Recovers at dawn (not automatic)',
      'manual', 'Recovers only when restored by hand', 'none', 'Does not recover'));
end;
$function$
;

-- ------------------------------------------------------------------ 4. manual resource writes (bodies of 20261019000100 + m2)
CREATE OR REPLACE FUNCTION public.save_character_resource(p_character uuid, p_resource jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare k text; r public.character_resources; v_id uuid;
  allowed constant text[] := array['id', 'resource_key', 'name', 'source_type', 'source_id', 'character_class_id', 'max_formula', 'minimum',
    'die', 'recharge', 'unlock_level', 'spell_version_id', 'cast_level', 'active', 'notes'];
begin
  perform public._gov_gate(p_character, 'build.manual_stats');   -- campaign governance (20261019000100)
  if auth.uid() is null or not public.can_access_character(p_character) then
    raise exception 'Character not found' using errcode = '42501';
  end if;
  if jsonb_typeof(p_resource) <> 'object' then raise exception 'The resource must be an object' using errcode = '22023'; end if;
  for k in select jsonb_object_keys(p_resource) loop
    if not k = any (allowed) then raise exception 'Field "%" cannot be set on a resource', k using errcode = '22023'; end if;
  end loop;
  if p_resource ? 'max_formula' then
    perform public._resource_max(p_resource -> 'max_formula', '{"total_level": 1, "class_level": 1, "proficiency_bonus": 2, "mods": {}}');
  end if;
  if p_resource ->> 'character_class_id' is not null and not exists (
       select 1 from public.character_classes where id = (p_resource ->> 'character_class_id')::uuid and character_id = p_character) then
    raise exception 'Character class not found' using errcode = '22023';
  end if;
  v_id := nullif(p_resource ->> 'id', '')::uuid;
  -- 20261114000700 (review v34 m2): counters of items, feats and lineages are kept by their sync (a deleted or edited one
  -- would come back unspent): a player cannot change them or create one; the campaign DM (or an admin) may adjust them
  if not public._character_knows_all(p_character) and (
       coalesce(p_resource ->> 'source_type', '') in ('item', 'feat', 'lineage')
       or coalesce(p_resource ->> 'resource_key', '') ~ '^(item[pw]?|ft|lin)-'
       or exists (select 1 from public.character_resources x where x.id = v_id and x.character_id = p_character
                  and x.source_type in ('item', 'feat', 'lineage'))) then
    raise exception 'This counter comes from an item, a feat or a lineage; only the DM can change it' using errcode = '42501';
  end if;
  if v_id is not null and not exists (select 1 from public.character_resources where id = v_id and character_id = p_character) then
    raise exception 'Resource not found' using errcode = '42501';
  end if;
  begin
    if v_id is null then
      insert into public.character_resources (character_id, resource_key, name, created_by)
      values (p_character, p_resource ->> 'resource_key', btrim(p_resource ->> 'name'), auth.uid()) returning id into v_id;
    end if;
    update public.character_resources set
      resource_key = coalesce(p_resource ->> 'resource_key', resource_key), name = coalesce(btrim(p_resource ->> 'name'), name),
      source_type = coalesce(p_resource ->> 'source_type', source_type), source_id = coalesce(p_resource ->> 'source_id', source_id),
      character_class_id = coalesce((p_resource ->> 'character_class_id')::uuid, character_class_id),
      max_formula = coalesce(p_resource -> 'max_formula', max_formula), minimum = coalesce((p_resource ->> 'minimum')::int, minimum),
      die = coalesce(p_resource ->> 'die', die), recharge = coalesce(p_resource ->> 'recharge', recharge),
      unlock_level = coalesce((p_resource ->> 'unlock_level')::int, unlock_level),
      spell_version_id = coalesce(p_resource ->> 'spell_version_id', spell_version_id),
      cast_level = coalesce((p_resource ->> 'cast_level')::int, cast_level),
      active = coalesce((p_resource ->> 'active')::boolean, active), notes = coalesce(nullif(btrim(p_resource ->> 'notes'), ''), notes)
    where id = v_id returning * into r;
  exception
    when check_violation or not_null_violation or invalid_text_representation or foreign_key_violation or unique_violation then
      raise exception 'Invalid resource: %', sqlerrm using errcode = '22023';
  end;
  return to_jsonb(r) - 'created_by';
end;
$function$
;

CREATE OR REPLACE FUNCTION public.delete_character_resource(p_resource uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare cid uuid;
begin
  perform public._gov_gate_resource_row(p_resource, 'build.manual_stats');   -- campaign governance (20261019000100)
  select character_id into cid from public.character_resources where id = p_resource;
  if auth.uid() is null or cid is null or not public.can_access_character(cid) then
    raise exception 'Resource not found' using errcode = '42501';
  end if;
  -- 20261114000700 (review v34 m2): a synced counter (item, feat, lineage) is never deleted by hand, not even by the DM: it
  -- would come back unspent on the next sync (past the rest limit); its sync deactivates it instead
  if exists (select 1 from public.character_resources where id = p_resource and source_type in ('item', 'feat', 'lineage')) then
    raise exception 'This counter comes from an item, a feat or a lineage and cannot be deleted' using errcode = '42501';
  end if;
  delete from public.character_resources where id = p_resource;
  return jsonb_build_object('deleted', true, 'id', p_resource);
end;
$function$
;

-- ------------------------------------------------------ 5. per-item lock first (bodies of 20261112000300 / 20261114000300 + m3)
CREATE OR REPLACE FUNCTION public.transfer_inventory_item(p_item uuid, p_to_inventory uuid, p_quantity integer DEFAULT NULL::integer)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare r public.inventory_items; q int; moving uuid; from_inv uuid; res uuid;
  k public.inventory_item_knowledge; to_char uuid; ck public.character_item_knowledge; it public.items; d record; nm text; ds text;
begin
  perform public._gov_gate_item(p_item, 'inventory.transfer'); perform public._gov_gate_inventory(p_to_inventory, 'inventory.transfer');   -- campaign governance (20261019000100)
  perform public._rpc_begin();
  -- 20261114000700 (review v34 m3): copies of one item are moved and identified one at a time (the per-item lock before any
  -- row lock, also taken first by set_item_knowledge); the knowledge triggers bump every holder of the item
  perform pg_advisory_xact_lock(4242, hashtext(ii.item_id)) from public.inventory_items ii where ii.id = p_item and ii.item_id is not null;
  r := public._lock_item(p_item);
  from_inv := r.inventory_id;
  if from_inv = p_to_inventory then raise exception 'Source and target inventory are the same'; end if;
  if not public.can_write_inventory(from_inv) then raise exception 'Not allowed to take items from this inventory' using errcode = '42501'; end if;
  if not public.can_deposit_inventory(p_to_inventory) then raise exception 'Not allowed to add items to the target inventory' using errcode = '42501'; end if;
  if exists (select 1 from public.character_equipment where inventory_item_id = p_item) then
    raise exception 'Unequip the item before transferring it';
  end if;
  if exists (select 1 from public.inventory_items where container_item_id = p_item) then
    raise exception 'The container is not empty';
  end if;
  q := coalesce(p_quantity, r.quantity);
  if q < 1 or q > r.quantity then raise exception 'Invalid quantity % (have %)', q, r.quantity; end if;
  if q < r.quantity then moving := public._split_off(p_item, q); else moving := p_item; end if;

  -- 20261112000300: knowledge of the receiving character
  select * into k from public.inventory_item_knowledge where inventory_item_id = moving;
  select character_id into to_char from public.inventories where id = p_to_inventory;
  if k.inventory_item_id is not null and to_char is not null and r.item_id is not null then
    select * into ck from public.character_item_knowledge where character_id = to_char and item_id = r.item_id;
    if ck.character_id is null then
      insert into public.character_item_knowledge (character_id, item_id, state, revealed, updated_by)
      values (to_char, r.item_id, 'unidentified', '{}', auth.uid()) returning * into ck;
    end if;
    select * into it from public.items where id = r.item_id;
    select * into d from public._item_decoy(r.item_id);
    if ck.state = 'identified' then nm := it.name; ds := coalesce(it.description, '');
    else
      nm := case when 'name' = any (ck.revealed) then it.name else d.name end;
      ds := case when 'description' = any (ck.revealed) then coalesce(it.description, '') else d.description end;
    end if;
    update public.inventory_item_knowledge set state = ck.state, revealed = ck.revealed, updated_by = auth.uid(), updated_at = now()
    where inventory_item_id = moving;
    update public.inventory_items
    set inventory_id = p_to_inventory, container_item_id = null, is_attuned = false, sort_order = 0, name = nm, description = ds,
        custom_name = case when ck.state = 'identified' then custom_name end
    where id = moving;
  else
    update public.inventory_items
    set inventory_id = p_to_inventory, container_item_id = null, is_attuned = false, sort_order = 0
    where id = moving;
  end if;
  perform public.log_inventory_event(from_inv, null, 'transfer', -q, r.item_id, jsonb_build_object('to', p_to_inventory));
  perform public.log_inventory_event(p_to_inventory, moving, 'transfer', q, r.item_id, jsonb_build_object('from', from_inv));
  res := public._try_auto_merge(moving);
  perform public._rpc_end(); return res;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.set_item_knowledge(p_inventory_item uuid, p_state text, p_revealed text[] DEFAULT NULL::text[], p_magic_known boolean DEFAULT NULL::boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare r public.inventory_items; it public.items; inv public.inventories; k public.inventory_item_knowledge; camp uuid; s public.item_secrets; old_state text;
  ck0 public.character_item_knowledge; ck1 public.character_item_knowledge;   -- 20261114000300
begin
  -- 20261114000700 (review v34 m3): the per-item lock first (also taken first by transfer_inventory_item): a sibling copy moved
  -- meanwhile no longer holds its row against _identify_sync_rows while this call holds the character's cache counter
  perform pg_advisory_xact_lock(4242, hashtext(ii.item_id)) from public.inventory_items ii where ii.id = p_inventory_item and ii.item_id is not null;
  -- 20261114000300: the character row before the inventory row and its counter (the order of the existing RPCs)
  perform 1 from public.characters c join public.inventories i on i.character_id = c.id join public.inventory_items ii on ii.inventory_id = i.id
   where ii.id = p_inventory_item for key share of c;
  select * into r from public.inventory_items where id = p_inventory_item for update;
  if r.id is null then raise exception 'Item not found' using errcode = 'P0002'; end if;
  select * into inv from public.inventories where id = r.inventory_id;
  select * into it from public.items where id = r.item_id;
  camp := coalesce(inv.campaign_id, (select campaign_id from public.characters where id = inv.character_id), it.campaign_id);
  if auth.uid() is null or not (public.is_admin() or (camp is not null and public.is_campaign_dm(camp))) then
    raise exception 'Only the DM can identify items or reveal their properties' using errcode = '42501';
  end if;
  if p_state not in ('unidentified', 'partially_identified', 'identified') then raise exception 'Unknown knowledge state' using errcode = '22023'; end if;
  select * into k from public.inventory_item_knowledge where inventory_item_id = r.id;
  old_state := coalesce(k.state, 'identified');
  select * into s from public.item_secrets where item_id = r.item_id;
  insert into public.inventory_item_knowledge (inventory_item_id, state, magic_known, revealed, true_name, updated_by)
  values (r.id, p_state, coalesce(p_magic_known, false), coalesce(p_revealed, '{}'), coalesce(k.true_name, it.name), auth.uid())
  on conflict (inventory_item_id) do update set state = excluded.state, magic_known = coalesce(p_magic_known, inventory_item_knowledge.magic_known),
    revealed = coalesce(p_revealed, inventory_item_knowledge.revealed), updated_by = excluded.updated_by, updated_at = now();
  if p_state = 'identified' then
    update public.inventory_items set name = coalesce(k.true_name, it.name), description = coalesce(it.description, '') where id = r.id;
  else
    update public.items set secret = true where id = r.item_id and not secret;   -- 20261112000300: no global cache bump when already secret
    update public.inventory_items set name = coalesce(s.unidentified_name, 'Unidentified item'), description = coalesce(s.unidentified_description, '')
    where id = r.id and old_state = 'identified';
  end if;
  -- 20261112000300: knowledge is per character
  if inv.character_id is not null and r.item_id is not null then
    perform public._ik_drop_pending(inv.character_id, r.item_id);   -- 20261114000300
    select * into ck0 from public.character_item_knowledge where character_id = inv.character_id and item_id = r.item_id;   -- 20261114000300
    insert into public.character_item_knowledge (character_id, item_id, state, revealed, updated_by)
    values (inv.character_id, r.item_id, p_state, (select revealed from public.inventory_item_knowledge where inventory_item_id = r.id), auth.uid())
    on conflict (character_id, item_id) do update set state = excluded.state, revealed = excluded.revealed, updated_by = excluded.updated_by, updated_at = now();
    perform public._identify_sync_rows(inv.character_id, r.item_id);
    perform public._identify_touch(inv.character_id);
    -- 20261114000300: share an addition with the party (guarded per target); a removal holds the character back
    select * into ck1 from public.character_item_knowledge where character_id = inv.character_id and item_id = r.item_id;
    if public._ik_contains(ck1.state, ck1.revealed, ck0.state, ck0.revealed) then
      if (ck0.state, ck0.revealed) is distinct from (ck1.state, ck1.revealed) then
        -- the hold rule: only the transition into 'identified' lifts a hold; a held character is no source (_party_share_from
        -- returns 0). A non-held character also gets the party level of the item (its queued shares were dropped above: m1)
        if ck1.state = 'identified' and ck0.state is distinct from 'identified' then
          update public.character_item_knowledge set held_by_dm = false where character_id = inv.character_id and item_id = r.item_id and held_by_dm;
        end if;
        if not exists (select 1 from public.character_item_knowledge where character_id = inv.character_id and item_id = r.item_id and held_by_dm) then
          perform public._party_share_pull(inv.character_id, true, r.item_id);
        end if;
        perform public._party_share_from(inv.character_id, r.item_id);
      end if;
    else
      update public.character_item_knowledge set held_by_dm = true where character_id = inv.character_id and item_id = r.item_id and not held_by_dm;
      if found then   -- n8: the hold is derivable after a rollback -> reapply
        perform public._audit(camp, inv.character_id, 'item_revealed', 'Knowledge of ' || it.name || ': held back (per-copy editor)',
          null, jsonb_build_object('item_id', it.id, 'mode', 'set', 'state', ck1.state, 'revealed', to_jsonb(ck1.revealed)), null, null, 'dm');
      end if;
    end if;
  end if;
  if camp is not null then
    perform public._audit(camp, inv.character_id, 'item_revealed',
                          'Item knowledge: ' || replace(old_state, '_', ' ') || ' → ' || replace(p_state, '_', ' '),
                          null, jsonb_build_object('revealed', to_jsonb(coalesce(p_revealed, '{}'))), null, null, 'party');
  end if;
  return public.get_character_item_knowledge(inv.character_id);
end;
$function$
;

-- ----------------------------------------------------------------- 6. weapon blocks helper (body of 20261114000600 + n1)
CREATE OR REPLACE FUNCTION public._character_weapon_blocks(p_character uuid, p_rows uuid[])
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  with v as (select public.can_access_character(p_character) or public._internal_caller() as ok, public._internal_caller() as internal),
  fx as (select x.source_id, x.seq, x.inactive_reason from public._character_item_effect_rows(p_character) x
         where x.source_type = 'item_effect' and x.source_id = any (p_rows)),
  r as (
    select ii.id, ii.item_id,
           exists (select 1 from public.character_equipment e where e.inventory_item_id = ii.id and e.character_id = p_character
                   and e.slot_id in ('main_hand', 'off_hand'))
             and public._item_active_in_form(p_character, ii.id) and (not it.requires_attunement or ii.is_attuned) as available
    from v, public.inventories inv
    join public.inventory_items ii on ii.inventory_id = inv.id
    join public.items it on it.id = ii.item_id
    left join public.inventory_item_knowledge kk on kk.inventory_item_id = ii.id
    where v.ok and p_rows is not null and inv.character_id = p_character and ii.id = any (p_rows)
      and exists (select 1 from public.item_weapon_blocks b where b.item_id = ii.item_id)
      and (kk.state is null or kk.state = 'identified' or v.internal or public._inventory_knows_all(inv.id))
  )
  select coalesce(jsonb_object_agg(r.id::text, jsonb_build_object(
    'actions', (select coalesce(jsonb_agg(jsonb_build_object('seq', b.seq, 'name', b.name, 'description', b.description,
                  'cost', b.action_cost, 'roll', b.roll, 'save_ability', b.save_ability, 'dc', b.dc, 'dc_ability', b.dc_ability,
                  'damage', b.damage_dice, 'damage_type', b.damage_type_id, 'uses', b.uses, 'recharge', b.recharge,
                  'available', r.available,
                  'resource_key', (select 'r:' || cr.id from public.character_resources cr where cr.character_id = p_character
                                   and cr.resource_key = 'itemw-' || replace(r.id::text, '-', '') || '-' || b.seq and cr.active))
                  order by b.seq), '[]'::jsonb)
                from public.item_weapon_blocks b where b.item_id = r.item_id and b.block_type = 'action'),
    'special', (select coalesce(jsonb_agg(jsonb_build_object('seq', b.seq, 'name', b.name, 'text', b.description,
                  'effect', case when ie.item_id is not null then jsonb_build_object('type', ie.effect_type, 'value', ie.value,
                                 'target', ie.target, 'activation', ie.activation,
                                 'active', exists (select 1 from fx where fx.source_id = r.id and fx.seq = ie.seq and fx.inactive_reason is null)) end)
                  order by b.seq), '[]'::jsonb)
                from public.item_weapon_blocks b
                left join public.item_effects ie on ie.item_id = b.item_id and ie.seq = b.effect_seq
                where b.item_id = r.item_id and b.block_type = 'special'),
    'conditions', (select coalesce(jsonb_agg(jsonb_build_object('seq', b.seq, 'name', b.name, 'condition_key', b.condition_key,
                     'text', b.description, 'applies_on', b.applies_on, 'save_ability', b.save_ability, 'dc', b.dc,
                     'dc_ability', b.dc_ability, 'duration', b.duration) order by b.seq), '[]'::jsonb)
                   from public.item_weapon_blocks b where b.item_id = r.item_id and b.block_type = 'condition'))), '{}'::jsonb)
  from r;
$function$
;

-- cached reads computed before this change may hold a true weapon / armor name: every cache entry is recomputed
update tl_cache.global_rev set rev = rev + 1 where id = 1;
reset lock_timeout;
notify pgrst, 'reload schema';
