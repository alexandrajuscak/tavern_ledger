-- R-D4 secrecy follow-up (review v35 F1, F2, F3). Additive; rollback supabase/rollback/rollback_secrecy_followup.sql (the exact
-- previous function bodies; no data is changed by this migration or by its rollback).
--  1. F1: an inventory copy the reader sees only under its disguise (_inventory_item_masked, 20261114000700) was still labelled
--     with its TRUE name and catalog id where a function lists inventory rows: _character_effects (copy-level modifiers such as
--     an infusion or "Weapon +1": derived effects / inactive_effects, the AC / attack / damage / speed breakdowns),
--     get_character_infusions (candidates, active infusions; also the candidate order) and _wild_shape_sheet (worn armor AC label,
--     equipment while transformed, dropped items). They now carry the disguise and no item id for such a reader. The numbers do
--     not change; the DM (and an internal call) sees exactly what he saw before.
--  2. F2: examine_inventory_item and resolve_identify_attempt take the per-item lock pg_advisory_xact_lock(4242, hashtext(item
--     id)) before any row lock (a success rewrites the sibling copies; a transfer of a sibling copy takes the same lock first).
--  3. F3: a masked weapon / armor / shield proficiency object drops proficiency_id and matched_by as well (item_id already).
set lock_timeout = '5s';

-- --------------------------------------------------------------------------------------------------- 1a. F1 _character_effects
CREATE OR REPLACE FUNCTION public._character_effects(p_character uuid)
 RETURNS TABLE(source_type text, source_id uuid, item_id text, source_name text, modifier_id text, seq integer, effect_type text, value numeric, target text, activation text, stacking text, stack_group text, scope text, active boolean, inactive_reason text, applied boolean)
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
  with owned as (
    -- 20261114000800 (review v35 F1): a copy the reader sees only disguised is labelled with its disguise and no item id
    select ii.id, case when mk.masked then null else ii.item_id end as item_id,
           ii.is_attuned and public._item_active_in_form(p_character, ii.id) as is_attuned,
           case when mk.masked then coalesce(nullif(ii.custom_name, ''), nullif(ii.name, ''), 'Unidentified item') else coalesce(ii.custom_name, it.name) end as name, it.kind_id, it.requires_attunement, e.slot_id
    from public.inventories inv
    join public.inventory_items ii on ii.inventory_id = inv.id
    join public.items it on it.id = ii.item_id                       -- RLS: modifiers of invisible items do not exist
    left join public.character_equipment e on e.inventory_item_id = ii.id and e.character_id = p_character
      and public._item_active_in_form(p_character, ii.id)              -- merged or dropped in Wild Shape: no effect
    cross join lateral (select public._inventory_item_masked(ii.id) as masked) mk
    where inv.character_id = p_character
      and exists (select 1 from public.inventory_item_modifiers im where im.inventory_item_id = ii.id)
  ),
  raw as (
    -- 20261114000500: item effects of every owned item (also unidentified ones, under their disguise) and permanent effects
    select x.source_type, x.source_id, x.item_id, x.source_name, null::text as modifier_id, x.seq,
           x.effect_type, x.value, x.target, x.activation, x.stacking, x.stack_group, x.priority,
           case when x.effect_type in ('attack_bonus', 'damage_bonus') and x.kind_id = 'weapon' then 'self' else 'global' end as scope,
           x.inactive_reason
    from public._character_item_effect_rows(p_character) x
    union all
    select 'modifier', o.id, o.item_id, o.name || ' (' || md.name || ')', md.id, me.seq,
           me.effect_type, me.value, null,
           case when coalesce(md.requires_attunement_override, o.requires_attunement) then 'equipped_and_attuned' else 'equipped' end,
           'additive', null, 0,
           case when me.effect_type in ('attack_bonus', 'damage_bonus') then 'self' else 'global' end,
           case when o.slot_id is null then 'not_equipped'
                when coalesce(md.requires_attunement_override, o.requires_attunement) and not o.is_attuned then 'not_attuned' end
    from owned o
    join public.inventory_item_modifiers im on im.inventory_item_id = o.id
    join public.item_modifiers md on md.id = im.modifier_id
    join public.item_modifier_effects me on me.modifier_id = md.id
    union all
    -- class feature effects (20261015001800); only active features, the effect's own conditions decide inactive_reason
    select 'class_feature', ce.character_class_id, null, ce.class_name || ': ' || ce.feature_name,
           ce.unlock_id || ':' || ce.seq || ':' || coalesce(ce.pick, 0), ce.seq,
           ce.effect_type, ce.value, case when ce.effect_type = 'resistance' then coalesce(ce.target, ce.value_text) else ce.target end,
           'owned', 'additive', null, 0, 'global',
           case when ce.active then null else coalesce(ce.inactive_reason, 'inactive') end
    from public._character_feature_effects(p_character) ce
    where ce.feature_active and ce.automation <> 'informational'
      and ce.effect_type in ('ability_bonus', 'ac_bonus', 'save_bonus', 'speed_bonus', 'resistance', 'skill_advantage',
                             'skill_disadvantage', 'carrying_capacity_bonus')
  ),
  ranked as (
    select r.*, r.inactive_reason is null as active,
           row_number() over (
             partition by r.inactive_reason is null, r.effect_type, coalesce(r.target, ''), r.scope,
                          case when r.scope = 'self' then r.source_id::text else '' end,
                          case r.stacking when 'additive' then r.source_type || r.source_id || coalesce(r.modifier_id, '') || r.seq
                                          when 'non_stacking_group' then 'group:' || r.stack_group
                                          else r.stacking end
             order by r.value desc nulls last, r.priority desc, r.source_id) as rn
    from raw r
  )
  select source_type, source_id, item_id, source_name, modifier_id, seq, effect_type, value, target, activation, stacking, stack_group,
         scope, active, inactive_reason, active and rn = 1 as applied
  from ranked;
$function$
;

-- ---------------------------------------------------------------------------------------------- 1b. F1 get_character_infusions
CREATE OR REPLACE FUNCTION public.get_character_infusions(p_character uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare inv uuid;
begin
  if auth.uid() is null or not public.can_access_character(p_character) then
    raise exception 'Character not found' using errcode = '42501';
  end if;
  select id into inv from public.inventories where character_id = p_character and kind = 'character';
  return jsonb_build_object('character_id', p_character,
    'choices', coalesce((select jsonb_agg(jsonb_build_object('character_class_id', c.character_class_id, 'choice_id', c.choice_id,
                 'unlock_id', c.unlock_id, 'class_level', c.class_level, 'max_items', c.max_items,
                 'active_count', (select count(*) from public.character_infusions ci where ci.character_id = p_character and ci.choice_id = c.choice_id),
                 'known', (select coalesce(jsonb_agg(jsonb_build_object('id', o.option_id, 'label', o.label, 'summary', o.summary,
                                 'infusion', o.data -> 'infusion', 'modifier', public._infusion_modifier(o.data -> 'infusion', c.class_level),
                                 'replicable', (select coalesce(jsonb_agg(x), '[]') from jsonb_array_elements(o.data -> 'infusion' -> 'replicate') e,
                                                  jsonb_array_elements_text(e -> 1) x where (e ->> 0)::int <= c.class_level),
                                 'candidates', case when o.data -> 'infusion' -> 'item' ? 'none' then '[]'::jsonb else
                                   (select coalesce(jsonb_agg(jsonb_build_object('inventory_item_id', ii.id, 'name', case when mk.masked then coalesce(nullif(ii.custom_name, ''), nullif(ii.name, ''), 'Unidentified item') else coalesce(ii.custom_name, it.name) end,
                                              'refusal', public._infusion_item_refusal(o.data -> 'infusion', ii)) order by case when mk.masked then coalesce(nullif(ii.custom_name, ''), nullif(ii.name, ''), 'Unidentified item') else it.name end), '[]')
                                    from public.inventory_items ii join public.items it on it.id = ii.item_id
                                    cross join lateral (select public._inventory_item_masked(ii.id) as masked) mk   -- 20261114000800 (review v35)
                                    where ii.inventory_id = inv) end)
                               order by o.label), '[]')
                           from public.class_feature_choice_options o where o.choice_id = c.choice_id and o.option_id = any (c.known))))
               from public._character_infusion_choices(p_character) c), '[]'),
    'active', coalesce((select jsonb_agg(jsonb_build_object('id', ci.id, 'infusion_id', ci.infusion_id, 'label', o.label,
                 'inventory_item_id', ci.inventory_item_id, 'item_name', case when mk.masked then coalesce(nullif(ii.custom_name, ''), nullif(ii.name, ''), 'Unidentified item') else coalesce(ii.custom_name, it.name) end, 'modifier_id', ci.modifier_id,
                 'expected_modifier', public._infusion_modifier(o.data -> 'infusion', c.class_level),
                 'outdated', ci.modifier_id is distinct from public._infusion_modifier(o.data -> 'infusion', c.class_level),
                 'known', ci.infusion_id = any (c.known), 'created_item', ci.created_item, 'companion_id', ci.companion_id,
                 'attunement', coalesce((o.data -> 'infusion' ->> 'attunement')::boolean, false), 'attuned', coalesce(ii.is_attuned, false))
               order by ci.applied_at)
               from public.character_infusions ci
               join public.class_feature_choice_options o on o.choice_id = ci.choice_id and o.option_id = ci.infusion_id
               left join public._character_infusion_choices(p_character) c on c.choice_id = ci.choice_id and c.character_class_id = ci.character_class_id
               left join public.inventory_items ii on ii.id = ci.inventory_item_id
               left join public.items it on it.id = ii.item_id
               left join lateral (select public._inventory_item_masked(ii.id) as masked) mk on true   -- 20261114000800 (review v35)
               where ci.character_id = p_character), '[]'));
end;
$function$
;

-- ---------------------------------------------------------------------------------------------------- 1c. F1 _wild_shape_sheet
CREATE OR REPLACE FUNCTION public._wild_shape_sheet(p_character uuid, d jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare t public.character_transformations; c public.creatures; ch public.characters; pb int; k text; ab text; mods jsonb := '{}';
  saves jsonb := '{}'; skills jsonb := '{}'; lvl int; char_total int; cand jsonb; best jsonb; pub int; m int; druid int;
  ac_opts jsonb := '[]'; e record; eq jsonb := '[]'; dur jsonb; spell jsonb; sz jsonb; retained jsonb := '[]'; acts jsonb;
  sens jsonb; conc jsonb; half int;
begin
  select * into t from public.character_transformations where character_id = p_character;
  if not found then return null; end if;
  select * into c from public.creatures where id = t.creature_id;
  select * into ch from public.characters where id = p_character;
  pb := coalesce((d -> 'proficiency_bonus' ->> 'value')::int, 2);
  select max(cc.level) into druid from public.character_classes cc where cc.character_id = p_character and cc.class_id = 'druid';

  -- abilities: STR, DEX, CON from the form; INT, WIS, CHA retained (the derived core already substituted the physical ones)
  for k in select unnest(array['str', 'dex', 'con', 'int', 'wis', 'cha']) loop
    m := floor(((case when k in ('str', 'dex', 'con') then (c.abilities ->> k)::int else (d -> 'abilities' -> k ->> 'score')::int end) - 10) / 2.0);
    mods := mods || jsonb_build_object(k, m);
  end loop;

  -- saving throws: your proficiency (your PB) or the form's; the form's printed bonus when it is higher
  for k in select unnest(array['str', 'dex', 'con', 'int', 'wis', 'cha']) loop
    m := (mods ->> k)::int;
    cand := '[]';
    if coalesce((ch.save_proficiencies ->> k)::boolean, false) or coalesce((d -> 'saving_throws' -> k ->> 'class_proficient')::boolean, false) then
      cand := cand || jsonb_build_object('kind', 'character', 'value', m + pb, 'label', format('your proficiency: %s + PB %s', m, pb));
    end if;
    if c.saving_throws ? k then
      pub := (c.saving_throws ->> k)::int;
      cand := cand || jsonb_build_object('kind', 'form_gained', 'value', m + pb, 'label', format('%s proficiency (gained): %s + PB %s', c.name, m, pb))
                   || jsonb_build_object('kind', 'form_printed', 'value', pub, 'label', format('%s stat block: %s', c.name, pub));
    end if;
    select x into best from jsonb_array_elements(cand) x order by (x ->> 'value')::int desc limit 1;
    saves := saves || jsonb_build_object(k, jsonb_build_object('ability', k, 'score', case when k in ('str', 'dex', 'con') then (c.abilities ->> k)::int
                                                                                     else (d -> 'abilities' -> k ->> 'score')::int end,
      'modifier', m, 'character_proficient', exists (select 1 from jsonb_array_elements(cand) x where x ->> 'kind' = 'character'),
      'creature_proficient', c.saving_throws ? k, 'creature_printed', c.saving_throws -> k, 'proficiency_bonus', pb,
      'other_bonus', coalesce((d -> 'saving_throws' -> k ->> 'class_bonus')::int, 0) + coalesce((d -> 'saving_throws' -> k ->> 'item_bonus')::int, 0),
      'total', coalesce((best ->> 'value')::int, m) + coalesce((d -> 'saving_throws' -> k ->> 'class_bonus')::int, 0)
               + coalesce((d -> 'saving_throws' -> k ->> 'item_bonus')::int, 0),
      'chosen', coalesce(best ->> 'kind', 'ability'), 'candidates', cand));
    best := null;
  end loop;

  -- skills: your proficiency / expertise (your PB) or the form's; its printed bonus when higher; half proficiency only without one
  for e in select s.id, s.ability from public.skills s loop
    m := (mods ->> e.ability)::int;
    lvl := greatest(public._skill_level(ch.skill_proficiencies -> e.id),
                    case when coalesce((d -> 'skills' -> e.id ->> 'class_expertise')::boolean, false) then 2
                         when coalesce((d -> 'skills' -> e.id ->> 'class_proficient')::boolean, false)
                           or coalesce((d -> 'skills' -> e.id ->> 'lineage_proficient')::boolean, false)
                           or coalesce((d -> 'skills' -> e.id ->> 'background_proficient')::boolean, false) then 1 else 0 end);
    cand := '[]';
    if lvl > 0 then
      cand := cand || jsonb_build_object('kind', 'character', 'value', m + lvl * pb,
        'label', format('your %s: %s + %s', case when lvl = 2 then 'expertise' else 'proficiency' end, m, lvl * pb));
    end if;
    if c.skills ? e.id then
      pub := (c.skills ->> e.id)::int;
      cand := cand || jsonb_build_object('kind', 'form_gained', 'value', m + pb, 'label', format('%s proficiency (gained): %s + PB %s', c.name, m, pb))
                   || jsonb_build_object('kind', 'form_printed', 'value', pub, 'label', format('%s stat block: %s', c.name, pub));
    end if;
    half := case when lvl = 0 and not c.skills ? e.id then coalesce((d -> 'skills' -> e.id -> 'half_proficiency' ->> 'value')::int, 0) else 0 end;
    select x into best from jsonb_array_elements(cand) x order by (x ->> 'value')::int desc limit 1;
    skills := skills || jsonb_build_object(e.id, jsonb_build_object('ability', e.ability, 'modifier', m, 'character_level', lvl,
      'creature_proficient', c.skills ? e.id, 'creature_printed', c.skills -> e.id, 'half_proficiency', half,
      'total', coalesce((best ->> 'value')::int, m + half), 'chosen', coalesce(best ->> 'kind', 'ability'), 'candidates', cand,
      'advantage_traits', (select coalesce(jsonb_agg(tr ->> 'name'), '[]') from jsonb_array_elements(c.traits) tr
                           where e.id = 'perception' and tr ->> 'name' like 'Keen%'
                              or e.id = 'stealth' and tr ->> 'name' = 'Underwater Camouflage')));
    best := null;
  end loop;

  -- armor class: the form's natural AC; Unarmored-Defense-style class formulas with the form's modifiers; worn armor / shield
  -- only when the player set them to "worn by the form" (DM confirmation)
  ac_opts := jsonb_build_array(jsonb_build_object('kind', 'form', 'value', c.armor_class,
    'label', format('%s %s', c.name, coalesce(c.armor_type, 'natural armor')), 'parts', jsonb_build_array(jsonb_build_object('label', c.name, 'value', c.armor_class))));
  for e in select x.feature_name, x.value, x.data, x.conditions from public._character_class_effects(p_character) x
           where x.active and x.effect_type = 'ac_formula' loop
    ac_opts := ac_opts || jsonb_build_object('kind', 'class_formula', 'value', e.value::int
        + (select coalesce(sum((mods ->> a)::int), 0) from jsonb_array_elements_text(e.data -> 'abilities') a),
      'label', format('%s: %s + %s', e.feature_name, e.value::int,
                      (select string_agg(upper(a), ' + ') from jsonb_array_elements_text(e.data -> 'abilities') a)),
      'note', 'retained class feature (your form must be able to use it)');
  end loop;
  -- 20261114000800 (review v35): a copy the reader sees only disguised is named by its disguise (worn armor, equipment, dropped)
  for e in select ii.id, ii.item_id, case when public._inventory_item_masked(ii.id) then coalesce(nullif(ii.custom_name, ''), nullif(ii.name, ''), 'Unidentified item') else coalesce(ii.custom_name, it.name) end as name, ce.slot_id, st.base_ac, st.ac_bonus, st.dex_modifier_mode, st.dex_cap, st.is_shield
           from public.character_equipment ce join public.inventory_items ii on ii.id = ce.inventory_item_id
           join public.items it on it.id = ii.item_id
           left join public.armor_stats st on st.item_id in (it.id, it.base_item_id)
           where ce.character_id = p_character and ce.slot_id in ('armor', 'shield') and public._item_active_in_form(p_character, ii.id) loop
    if e.slot_id = 'armor' and e.base_ac is not null then
      ac_opts := ac_opts || jsonb_build_object('kind', 'worn_armor', 'value', e.base_ac + case e.dex_modifier_mode when 'full' then (mods ->> 'dex')::int
                                                                                          when 'capped' then least((mods ->> 'dex')::int, coalesce(e.dex_cap, 2)) else 0 end,
        'label', format('%s worn by the form (DM confirmed)', e.name), 'note', 'equipment does not resize to fit the form');
    end if;
  end loop;
  select x into best from jsonb_array_elements(ac_opts) x order by (x ->> 'value')::int desc limit 1;
  if exists (select 1 from public.character_equipment ce where ce.character_id = p_character and ce.slot_id = 'shield'
             and public._item_active_in_form(p_character, ce.inventory_item_id)) then
    best := best || jsonb_build_object('value', (best ->> 'value')::int + 2, 'shield', 2);
  end if;

  -- actions with the per-form ability state (recharge rolls, once per rest abilities)
  select coalesce(jsonb_agg(a || jsonb_build_object('available', coalesce((t.action_state -> (a ->> 'name') ->> 'available')::boolean, true))), '[]')
  into acts from jsonb_array_elements(c.actions || c.reactions) a;

  -- senses: only the form's (your darkvision does not carry over unless the form has it)
  sens := (select coalesce(jsonb_object_agg(key, value), '{}') from jsonb_each(c.senses) where key <> 'passive_perception')
          || jsonb_build_object('passive_perception', 10 + (skills -> 'perception' ->> 'total')::int);

  -- equipment while transformed
  select coalesce(jsonb_agg(jsonb_build_object('inventory_item_id', ii.id, 'name', case when public._inventory_item_masked(ii.id) then coalesce(nullif(ii.custom_name, ''), nullif(ii.name, ''), 'Unidentified item') else coalesce(ii.custom_name, it.name) end, 'slot', ce.slot_id,
           'mode', coalesce(t.equipment -> 'items' ->> ii.id::text, t.equipment ->> 'mode'),
           'effects_active', public._item_active_in_form(p_character, ii.id)) order by ce.slot_id), '[]')
  into eq
  from public.character_equipment ce join public.inventory_items ii on ii.id = ce.inventory_item_id join public.items it on it.id = ii.item_id
  where ce.character_id = p_character;
  eq := eq || coalesce((select jsonb_agg(jsonb_build_object('inventory_item_id', x.key, 'mode', 'drop', 'dropped', true,
                                 'name', (select case when public._inventory_item_masked(ii.id) then coalesce(nullif(ii.custom_name, ''), nullif(ii.name, ''), 'Unidentified item') else coalesce(ii.custom_name, it.name) end from public.inventory_items ii join public.items it on it.id = ii.item_id
                                          where ii.id = x.key::uuid)))
                        from jsonb_each_text(coalesce(t.equipment -> 'dropped', '{}')) x), '[]');

  -- retained features: what the form keeps, applies automatically, or needs your DM to confirm
  select coalesce(jsonb_agg(distinct jsonb_build_object('feature', x.feature_name, 'class', x.class_name,
           'status', case when x.effect_type in ('proficiency', 'expertise', 'skill_half_proficiency', 'save_bonus_ability', 'save_dc', 'spell',
                                                  'spellcasting_source', 'resistance', 'immunity', 'condition_immunity', 'save_advantage', 'check_advantage')
                          then 'retained' when x.effect_type = 'ac_formula' then 'retained_if_capable'
                          when x.effect_type = 'sense' then 'not_retained'
                          when x.effect_type in ('attack', 'extra_attack', 'attack_bonus', 'damage_bonus', 'attack_rider', 'critical_range', 'speed_bonus',
                                                 'ac_bonus') then 'needs_dm' else 'informational' end,
           'applied', x.effect_type in ('proficiency', 'expertise', 'skill_half_proficiency', 'save_bonus_ability', 'resistance', 'immunity',
                                        'condition_immunity', 'ac_formula'))), '[]')
  into retained
  from public._character_class_effects(p_character) x
  where x.active and x.feature_active and x.effect_type not in ('transform_form', 'informational', 'resource_modifier');

  -- spellcasting while transformed (2014 Druid): no spells before Beast Spells (18); Archdruid (20) ignores V, S and costless M
  spell := case when coalesce(druid, 0) >= 20 then jsonb_build_object('can_cast', true, 'feature', 'Archdruid',
                  'rule', 'Beast Spells: verbal and somatic components in this form. Archdruid: ignore verbal and somatic components and material components without a cost or that are not consumed, for druid spells.')
                when coalesce(druid, 0) >= 18 then jsonb_build_object('can_cast', true, 'feature', 'Beast Spells',
                  'rule', 'You can perform the verbal and somatic components of a druid spell in this form, but not provide material components.')
                else jsonb_build_object('can_cast', false, 'feature', null,
                  'rule', 'You cannot cast spells in Wild Shape. Concentration on a spell you already cast continues.') end;
  conc := jsonb_build_object('active', exists (select 1 from jsonb_array_elements(coalesce(ch.conditions, '[]')) x
                                               where coalesce(x ->> 'name', x #>> '{}') ilike 'concentrat%'),
                             'note', (select coalesce(x ->> 'note', x ->> 'detail') from jsonb_array_elements(coalesce(ch.conditions, '[]')) x
                                      where coalesce(x ->> 'name', x #>> '{}') ilike 'concentrat%' limit 1),
                             'reminder', 'Taking damage: CON save DC 10 or half the damage (whichever is higher) or the spell ends.');
  sz := jsonb_build_object('size', c.size, 'space_ft', case c.size when 'Tiny' then 2.5 when 'Small' then 5 when 'Medium' then 5 when 'Large' then 10
                                                                  when 'Huge' then 15 else 20 end,
    'notes', case when c.size in ('Large', 'Huge', 'Gargantuan') then 'Large or bigger: squeeze through spaces one size smaller; carrying capacity scales with size. A mount only if your DM agrees.'
                  when c.size = 'Tiny' then 'Tiny: fits in a 2.5 ft. space; carrying capacity is halved.' else null end);
  dur := jsonb_build_object('started_at', t.started_at, 'max_minutes', t.max_duration_minutes, 'expires_at', t.expires_at,
    'expired', t.expires_at is not null and t.expires_at <= now(),
    'remaining_minutes', case when t.expires_at is not null then greatest(0, floor(extract(epoch from (t.expires_at - now())) / 60))::int end);

  return jsonb_build_object(
    'creature', jsonb_build_object('id', c.id, 'name', c.name, 'cr', c.challenge_rating, 'cr_text', public._cr_text(c.challenge_rating),
      'type', c.creature_type, 'size', c.size, 'hit_dice', c.hit_dice, 'source', c.source_label, 'source_url', c.source_url, 'license', c.license,
      'elemental', t.elemental, 'mechanics_status', c.mechanics_status, 'languages', c.languages),
    'hp', jsonb_build_object('current', t.hp_current, 'max', t.hp_max, 'temp', t.hp_temp, 'normal_current', ch.hp_current, 'normal_max', ch.hp_max,
      'normal_temp', ch.hp_temp, 'state', case when t.hp_current * 4 <= t.hp_max then 'critical' when t.hp_current * 2 <= t.hp_max then 'wounded' else 'healthy' end),
    'duration', dur, 'cost', t.cost, 'resource_key', t.resource_key, 'started_at', t.started_at,
    'abilities', (select jsonb_object_agg(k2, jsonb_build_object('score', case when k2 in ('str', 'dex', 'con') then (c.abilities ->> k2)::int
                                                                              else (d -> 'abilities' -> k2 ->> 'score')::int end,
                     'modifier', (mods ->> k2)::int,
                     'source', case when k2 in ('str', 'dex', 'con') then 'form' else 'retained' end,
                     'source_name', case when k2 in ('str', 'dex', 'con') then c.name else ch.name end))
                  from unnest(array['str', 'dex', 'con', 'int', 'wis', 'cha']) k2),
    'saving_throws', saves, 'skills', skills,
    'armor_class', jsonb_build_object('value', (best ->> 'value')::int, 'selected', best, 'options', ac_opts),
    'speed', c.speed, 'senses', sens, 'size', sz,
    'resistances', to_jsonb(c.damage_resistances), 'immunities', to_jsonb(c.damage_immunities), 'vulnerabilities', to_jsonb(c.damage_vulnerabilities),
    'condition_immunities', to_jsonb(c.condition_immunities),
    'actions', acts,
    'traits', c.traits, 'retained_features', retained, 'equipment', eq, 'spellcasting', spell, 'concentration', conc,
    'primal_strike', exists (select 1 from public.character_classes cc where cc.character_id = p_character and cc.class_id = 'druid'
                             and cc.subclass_version_id = 'druid-moon-phb' and cc.level >= 6),
    'notes', t.notes);
end;
$function$
;

-- ----------------------------------------------------------------------------------------------- 2a. F2 examine_inventory_item
CREATE OR REPLACE FUNCTION public.examine_inventory_item(p_inventory_item uuid, p_check text, p_roll integer, p_request uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare r public.inventory_items; inv public.inventories; ch public.characters; s public.item_secrets; k public.inventory_item_knowledge;
  it public.items; last public.item_identify_attempts; a public.item_identify_attempts; chk text := lower(btrim(coalesce(p_check, '')));
begin
  if auth.uid() is null then raise exception 'Not authenticated' using errcode = '42501'; end if;
  if p_request is not null then
    select * into a from public.item_identify_attempts where request_id = p_request;
    if a.id is not null then
      if a.created_by is distinct from auth.uid() then raise exception 'Item not found' using errcode = '42501'; end if;
      return public._identify_attempt_player(a) || jsonb_build_object('replayed', true);
    end if;
  end if;
  -- 20261114000800 (review v35 F2): the per-item lock before any row lock, as transfer_inventory_item / set_item_knowledge take
  -- it: a success rewrites the sibling copies of the item (_identify_apply -> _identify_sync_rows) while a sibling may be moving
  perform pg_advisory_xact_lock(4242, hashtext(ii.item_id)) from public.inventory_items ii where ii.id = p_inventory_item and ii.item_id is not null;
  select * into r from public.inventory_items where id = p_inventory_item for update;
  -- a concurrent duplicate waited for the row lock: once it holds the lock the first call has committed, so the replay (not the
  -- "nothing more to find out" / "not answered yet" checks below) answers it
  if p_request is not null then
    select * into a from public.item_identify_attempts where request_id = p_request;
    if a.id is not null then
      if a.created_by is distinct from auth.uid() then raise exception 'Item not found' using errcode = '42501'; end if;
      return public._identify_attempt_player(a) || jsonb_build_object('replayed', true);
    end if;
  end if;
  if r.id is null then raise exception 'Item not found' using errcode = 'P0002'; end if;
  select * into inv from public.inventories where id = r.inventory_id;
  select * into ch from public.characters where id = inv.character_id;
  if ch.id is null or not (ch.owner_id = auth.uid() or public.is_admin()) then
    raise exception 'Only the character''s player can examine this item' using errcode = '42501';
  end if;
  select * into k from public.inventory_item_knowledge where inventory_item_id = r.id;
  if r.item_id is null or k.inventory_item_id is null or k.state = 'identified' then
    raise exception 'There is nothing more to find out about this item' using errcode = '22023';
  end if;
  select * into s from public.item_secrets where item_id = r.item_id;
  if s.identify_dc is null then raise exception 'Your DM has not set up a check for this item' using errcode = '22023'; end if;
  if p_roll is null or p_roll < -10 or p_roll > 60 then raise exception 'Enter the total of your roll (-10 to 60)' using errcode = '22023'; end if;
  if chk = '' or length(chk) > 60 then raise exception 'Choose the check you rolled' using errcode = '22023'; end if;
  if cardinality(s.identify_checks) > 0 and not chk = any (s.identify_checks) then
    raise exception 'This check does not help with this item' using errcode = '22023';
  end if;
  perform 1 from public.characters where id = ch.id for update;   -- one attempt at a time per character
  select * into last from public.item_identify_attempts where character_id = ch.id and item_id = r.item_id order by created_at desc, id limit 1;
  if last.status = 'pending' then raise exception 'Your DM has not answered your last attempt yet' using errcode = '55000'; end if;
  if not public._identify_retry_ok(s.identify_retry, last) then raise exception 'You cannot try again yet' using errcode = '55000'; end if;

  insert into public.item_identify_attempts (character_id, inventory_item_id, item_id, check_key, roll_total, request_id)
  values (ch.id, r.id, r.item_id, chk, p_roll, p_request) on conflict (request_id) do nothing returning * into a;
  if a.id is null then   -- the same request id on another row, committed meanwhile: replay it as well (never a 23505)
    select * into a from public.item_identify_attempts where request_id = p_request;
    if a.created_by is distinct from auth.uid() then raise exception 'Item not found' using errcode = '42501'; end if;
    return public._identify_attempt_player(a) || jsonb_build_object('replayed', true);
  end if;
  insert into public.character_item_knowledge (character_id, item_id, state, revealed, updated_by)
  values (ch.id, r.item_id, k.state, k.revealed, auth.uid()) on conflict (character_id, item_id) do nothing;
  if s.identify_auto then
    if p_roll >= s.identify_dc then
      perform public._identify_apply(ch.id, r.item_id, s.identify_reveal);
      update public.item_identify_attempts set status = 'succeeded', auto = true, revealed = s.identify_reveal, resolved_at = now()
      where id = a.id returning * into a;
    else
      update public.item_identify_attempts set status = 'failed', auto = true, resolved_at = now() where id = a.id returning * into a;
    end if;
  end if;
  select * into it from public.items where id = r.item_id;
  perform public._audit(ch.campaign_id, ch.id, 'item_examined',
    'Examined ' || coalesce(nullif(r.custom_name, ''), r.name) || ' (' || public._identify_check_label(chk) || ' ' || p_roll || ')'
      || case a.status when 'succeeded' then ': learned something' when 'failed' then ': nothing new' else ': waiting for the DM' end,
    null, null, null, null, 'party');
  perform public._audit(ch.campaign_id, ch.id, 'item_examined',
    'Examine attempt on ' || it.name || ' (DC ' || s.identify_dc || '): ' || public._identify_check_label(chk) || ' ' || p_roll || ', ' || a.status,
    null, jsonb_build_object('item_id', it.id, 'attempt_id', a.id), null, null, 'dm');
  perform public._identify_touch(ch.id);
  return public._identify_attempt_player(a);
end $function$
;

-- --------------------------------------------------------------------------------------------- 2b. F2 resolve_identify_attempt
CREATE OR REPLACE FUNCTION public.resolve_identify_attempt(p_attempt uuid, p_success boolean DEFAULT NULL::boolean, p_dm_roll integer DEFAULT NULL::integer, p_note text DEFAULT NULL::text, p_allow_retry boolean DEFAULT false, p_reveal text[] DEFAULT NULL::text[])
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare a public.item_identify_attempts; camp uuid; s public.item_secrets; ok boolean; rev text[];
begin
  -- 20261114000800 (review v35 F2): the per-item lock first (see examine_inventory_item); the item id is read without a lock
  perform pg_advisory_xact_lock(4242, hashtext(x.item_id)) from public.item_identify_attempts x where x.id = p_attempt and x.item_id is not null;
  select * into a from public.item_identify_attempts where id = p_attempt for update;
  if a.id is null then raise exception 'Attempt not found' using errcode = 'P0002'; end if;
  select campaign_id into camp from public.characters where id = a.character_id;
  if auth.uid() is null or not (public.is_admin() or (camp is not null and public.is_campaign_dm(camp))) then
    raise exception 'Only the DM of the character''s campaign can answer an examine attempt' using errcode = '42501';
  end if;
  if a.status = 'failed' and coalesce(p_allow_retry, false) and p_success is distinct from true then
    update public.item_identify_attempts set retry_allowed = true, dm_note = coalesce(nullif(left(p_note, 500), ''), dm_note) where id = a.id returning * into a;
    perform public._identify_touch(a.character_id);
    return public._identify_attempt_dm(a);
  end if;
  if a.status <> 'pending' then raise exception 'This attempt was already answered' using errcode = '55000'; end if;
  if p_dm_roll is not null and (p_dm_roll < -10 or p_dm_roll > 60) then raise exception 'Roll out of range' using errcode = '22023'; end if;
  select * into s from public.item_secrets where item_id = a.item_id;
  ok := coalesce(p_success, coalesce(p_dm_roll, a.roll_total) >= coalesce(s.identify_dc, 1000));
  if ok then
    rev := coalesce(p_reveal, s.identify_reveal, '{all}');
    perform public._identify_apply(a.character_id, a.item_id, rev);
  end if;
  update public.item_identify_attempts set status = case when ok then 'succeeded' else 'failed' end, revealed = case when ok then rev else '{}' end,
         retry_allowed = not ok and coalesce(p_allow_retry, false), dm_roll_total = p_dm_roll, dm_note = nullif(left(p_note, 500), ''),
         resolved_at = now(), resolved_by = auth.uid()
   where id = a.id returning * into a;
  perform public._audit(camp, a.character_id, 'item_examined',
    'The DM answered an examine attempt: ' || case when ok then 'success' else 'no success' end, null, null, null, null, 'party');
  perform public._identify_touch(a.character_id);
  return public._identify_attempt_dm(a);
end $function$
;

-- --------------------------------------------------------------------- 3. F3 _derived_stats_core (body of 20261114000700 + F3)
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
      'ability_modifier', ab_mod, 'proficient', (prof ->> 'proficient')::boolean, 'proficiency', case when w.masked then prof - '{item_id,proficiency_id,matched_by}'::text[] else prof end,
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
      'proficiency', case when armor.masked then armor_prof - '{item_id,proficiency_id,matched_by}'::text[] else armor_prof end) end,
    'shield', case when shield.inventory_item_id is null then null else jsonb_build_object(
      'inventory_item_id', shield.inventory_item_id, 'item_id', case when shield.masked or not shield.visible then null else shield.item_id end, 'name', shield.name,
      'ac_bonus', shield.ac_bonus, 'proficiency', case when shield.masked then shield_prof - '{item_id,proficiency_id,matched_by}'::text[] else shield_prof end) end,
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


-- cached reads computed before this change may hold a true name: every cache entry is recomputed
update tl_cache.global_rev set rev = rev + 1 where id = 1;
reset lock_timeout;
notify pgrst, 'reload schema';
