-- V6.2 adversarial hardening (docs/V62_ADVERSARIAL_HARDENING_AUDIT.md). Rollback: supabase/rollback/rollback_v62_hardening.sql
-- ADV-BLOCKER-001  an unidentified item's true name was readable by the player in the audit log (table and get_campaign_audit)
-- ADV-SERIOUS-002  a feat with an unknown effect type could be published
-- ADV-SERIOUS-003  custom lineages without a summary could not be published (NOT NULL failure shown as a raw database text)
-- ADV-MODERATE-004 validation messages exposed constraint, relation and column names
-- ADV-MODERATE-005 negative current HP and negative coins could be written directly through the API
begin;

create or replace function public._audit_item_hidden(p_type text, p_character uuid, p_after jsonb)
returns boolean language sql stable security definer set search_path = public, pg_temp as $$
  -- an item event of this character whose catalog item is still unidentified in its inventory (or flagged unidentified)
  select p_type = 'item_assigned' and p_character is not null and (
    coalesce((p_after ->> 'unidentified')::boolean, false) and p_after ? 'catalog_ref'
    or exists (select 1 from public.inventory_items ii join public.inventories i on i.id = ii.inventory_id
                 join public.inventory_item_knowledge k on k.inventory_item_id = ii.id
               where i.character_id = p_character and ii.item_id = p_after ->> 'catalog_ref' and k.state <> 'identified'));
$$;
revoke all on function public._audit_item_hidden(text, uuid, jsonb) from public;
grant execute on function public._audit_item_hidden(text, uuid, jsonb) to authenticated;

drop policy if exists "campaign_audit_events_read" on public.campaign_audit_events;
create policy "campaign_audit_events_read" on public.campaign_audit_events for select to authenticated using ((is_admin() OR is_campaign_dm(campaign_id) OR ((visibility <> 'dm'::text) AND (character_id IS NOT NULL) AND (NOT public._audit_item_hidden(event_type, character_id, after)) AND (EXISTS ( SELECT 1
   FROM characters c
  WHERE ((c.id = campaign_audit_events.character_id) AND (c.owner_id = auth.uid())))))));

CREATE OR REPLACE FUNCTION public.get_campaign_audit(p_campaign uuid, p_character uuid DEFAULT NULL::uuid, p_types text[] DEFAULT NULL::text[], p_limit integer DEFAULT 200, p_before timestamp with time zone DEFAULT NULL::timestamp with time zone)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare dm boolean;
begin
  if auth.uid() is null or not (public.is_admin() or public.is_campaign_member(p_campaign)) then
    raise exception 'Campaign not found' using errcode = '42501';
  end if;
  dm := public.is_admin() or public.is_campaign_dm(p_campaign);
  return (select coalesce(jsonb_agg(j order by created_at desc), '[]') from (
    select jsonb_build_object('id', e.id, 'event_type', e.event_type, 'summary', e.summary, 'before', e.before, 'after', e.after,
             'reason', e.reason, 'request_id', e.request_id, 'visibility', case when dm then e.visibility end, 'created_at', e.created_at,
             'character_id', e.character_id, 'character_name', ch.name,
             'actor_name', (select coalesce(display_name, email) from public.profiles where id = e.actor_id)) as j, e.created_at
    from public.campaign_audit_events e left join public.characters ch on ch.id = e.character_id
    where e.campaign_id = p_campaign
      and (dm or (e.visibility <> 'dm' and ch.owner_id = auth.uid() and not public._audit_item_hidden(e.event_type, e.character_id, e.after)))
      and (p_character is null or e.character_id = p_character)
      and (p_types is null or e.event_type = any (p_types))
      and (p_before is null or e.created_at < p_before)
    order by e.created_at desc limit greatest(1, least(coalesce(p_limit, 200), 1000))) x);
end;
$function$;

CREATE OR REPLACE FUNCTION public.dm_assign_content(p_content uuid, p_characters uuid[], p_mode text, p_options jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare c public.dm_content; v public.dm_content_versions; ch uuid; out jsonb := '[]'; err text; src uuid; inv uuid; camp uuid; o jsonb := coalesce(p_options, '{}');
begin
  if not public._dm_can_manage(p_content) then raise exception 'Content not found' using errcode = '42501'; end if;
  select * into c from public.dm_content where id = p_content;
  if c.campaign_id is null then raise exception 'Private library content is assigned after copying it to a campaign' using errcode = '22023'; end if;
  if not public.is_campaign_dm(c.campaign_id) and not public.is_admin() then raise exception 'Only a DM of the campaign assigns its content' using errcode = '42501'; end if;
  select * into v from public.dm_content_versions where id = c.published_version_id for share;
  if v.id is null or c.status = 'archived' or v.status <> 'published' then
    raise exception 'Only published, not archived content can be assigned' using errcode = 'TLPUB';
  end if;
  foreach ch in array coalesce(p_characters, '{}') loop
    err := null;
    begin
      select campaign_id into camp from public.characters where id = ch;
      if camp is distinct from c.campaign_id then raise exception 'The character is not in this campaign'; end if;
      case c.content_type
        when 'spell' then
          src := nullif(o ->> 'source_id', '')::uuid;
          if src is null then
            select id into src from public.character_spellcasting_sources where character_id = ch and source_type = 'other' and label = 'Campaign gifts';
            if src is null and p_mode in ('innate', 'known') then
              insert into public.character_spellcasting_sources (character_id, source_type, label, casting_ability, preparation_mode, uses_spell_slots, notes, created_by)
              values (ch, 'other', 'Campaign gifts', coalesce(o ->> 'casting_ability', 'cha'), 'innate', true, 'Spells granted by the DM.', auth.uid())
              returning id into src;
            end if;
          end if;
          if src is null then raise exception 'Choose the spellcasting source for this spell'; end if;
          perform public.set_character_spell(ch, src, v.catalog_ref, true, p_mode = 'always_prepared', p_mode = 'always_prepared',
                                             o ->> 'casting_ability', null, 'Granted by the DM');
        when 'item' then
          if p_mode = 'stash' then
            select id into inv from public.inventories where campaign_id = c.campaign_id and kind = 'party_stash' order by created_at limit 1;
            if inv is null then raise exception 'This campaign has no party stash'; end if;
          else
            select id into inv from public.inventories where character_id = ch and kind = 'character' order by created_at limit 1;
          end if;
          perform public._dm_add_item(inv, v.catalog_ref, coalesce((o ->> 'quantity')::int, 1), o ->> 'custom_name',
                                      coalesce((o ->> 'identified')::boolean, true), v.id);
        when 'feat' then
          perform public.assign_character_feat(ch, v.catalog_ref, coalesce(o -> 'choices', '{}'),
                                               case when p_mode = 'campaign_reward' then 'campaign_reward' else 'dm_grant' end, o ->> 'note');
        when 'creature' then
          if p_mode = 'companion' then
            perform public.add_character_companion(ch, v.catalog_ref, o ->> 'name', 'dm_grant', (o ->> 'hp_max')::int);
          else
            perform public.set_seen_forms(ch, array[v.catalog_ref], true, 'dm_grant', coalesce(o ->> 'note', 'Granted by the DM'));
          end if;
        when 'companion' then
          perform public.add_character_companion(ch, v.catalog_ref, coalesce(o ->> 'name', v.name), 'dm_grant',
                                                 coalesce((o ->> 'hp_max')::int, (v.definition -> 'creature' ->> 'hit_points')::int));
          update public.character_companions set template_version_id = v.id
          where id = (select id from public.character_companions where character_id = ch and creature_id = v.catalog_ref order by created_at desc limit 1);
        when 'background' then
          perform public.set_character_background(ch, v.catalog_ref, o -> 'ability', coalesce(o -> 'choices', '{}'), '[]', '{}');
        when 'lineage' then
          perform public.set_character_lineage(ch, v.catalog_ref, null, coalesce(o -> 'choices', '{}'), false, false);
        when 'condition' then
          perform public.apply_character_condition(ch, v.id, null, p_mode = 'hidden', (o ->> 'expires_at')::timestamptz, o ->> 'note');
      end case;
      perform public._dm_event(p_content, v.id, 'assigned', jsonb_build_object('character_id', ch, 'mode', p_mode));
      if c.content_type = 'item' and coalesce((o ->> 'identified')::boolean, true) = false then
        -- V6.2: an unidentified item never names its true identity to the party: the player sees the disguise, the DM the truth
        perform public._audit(c.campaign_id, ch, 'item_assigned',
                              'Assigned item: ' || coalesce(nullif(v.definition -> 'hidden' ->> 'unidentified_name', ''), 'an unidentified item'),
                              null, jsonb_build_object('mode', p_mode, 'unidentified', true), null, null, 'party');
        perform public._audit(c.campaign_id, ch, 'item_assigned', 'Assigned item (unidentified): ' || v.name, null,
                              jsonb_build_object('catalog_ref', v.catalog_ref, 'mode', p_mode, 'unidentified', true), null, null, 'dm');
      else
        perform public._audit(c.campaign_id, ch, case c.content_type when 'item' then 'item_assigned' when 'spell' then 'spell_learned'
                                                   when 'feat' then 'feat_added' else 'content_assigned' end,
                              'Assigned ' || c.content_type || ': ' || v.name, null, jsonb_build_object('catalog_ref', v.catalog_ref, 'mode', p_mode),
                              null, null, case when c.content_type = 'condition' and p_mode = 'hidden' then 'dm' else 'party' end);
      end if;
    exception when others then
      err := sqlerrm;
    end;
    out := out || jsonb_build_array(jsonb_build_object('character_id', ch, 'ok', err is null, 'error', err));
  end loop;
  return jsonb_build_object('content_id', p_content, 'version_id', v.id, 'results', out);
end;
$function$;

CREATE OR REPLACE FUNCTION public._dm_materialize(p_version uuid)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v public.dm_content_versions; c public.dm_content; d jsonb; base text; ref text; e jsonb; n int; x text; owner uuid;
  camp uuid; pkg text; ch jsonb; chid text; s jsonb; r jsonb;
begin
  select * into v from public.dm_content_versions where id = p_version;
  select * into c from public.dm_content where id = v.content_id;
  d := v.definition; base := public._dm_short(c.id); ref := base || '-v' || v.version_no; owner := c.author_id; camp := c.campaign_id;
  if camp is null then raise exception 'Copy the content to a campaign before publishing it' using errcode = '22023'; end if;
  case c.content_type
  when 'spell' then
    insert into public.catalog_spells (id, name, owner_id, campaign_id) values (base, v.name, owner, camp)
    on conflict (id) do update set name = excluded.name;
    insert into public.spell_versions (id, spell_id, name, level, school_id, casting_time_raw, casting_time_unit, casting_time_amount,
      reaction_trigger, range_raw, range_type, range_distance, range_unit, area_shape, area_size, duration_raw, duration_type,
      duration_amount, duration_unit, requires_concentration, is_ritual, components_raw, has_verbal_component, has_somatic_component,
      has_material_component, material_text, material_cost_gp, material_consumed, components_parse_status, mechanism, attack_type,
      save_ability, has_higher_levels, automation, source_label, source_url, status, rule_status, parse_notes, content_version_id)
    values (ref, base, v.name, (d ->> 'level')::int, d ->> 'school',
      coalesce(d -> 'casting_time' ->> 'raw', coalesce(d -> 'casting_time' ->> 'amount', '1') || ' ' || replace(coalesce(d -> 'casting_time' ->> 'unit', 'action'), '_', ' ')),
      coalesce(d -> 'casting_time' ->> 'unit', 'action'), coalesce((d -> 'casting_time' ->> 'amount')::int, 1), d ->> 'reaction_trigger',
      coalesce(d -> 'range' ->> 'raw', case d -> 'range' ->> 'type' when 'distance' then (d -> 'range' ->> 'distance') || ' ' || coalesce(d -> 'range' ->> 'unit', 'feet')
                                         else initcap(coalesce(d -> 'range' ->> 'type', 'self')) end),
      coalesce(d -> 'range' ->> 'type', 'self'), (d -> 'range' ->> 'distance')::int, d -> 'range' ->> 'unit',
      d -> 'area' ->> 'shape', (d -> 'area' ->> 'size')::int,
      coalesce(d -> 'duration' ->> 'raw', case d -> 'duration' ->> 'type' when 'timed' then (d -> 'duration' ->> 'amount') || ' ' || (d -> 'duration' ->> 'unit') || 's'
                                             else initcap(replace(coalesce(d -> 'duration' ->> 'type', 'instantaneous'), '_', ' ')) end),
      coalesce(d -> 'duration' ->> 'type', 'instantaneous'), (d -> 'duration' ->> 'amount')::int, d -> 'duration' ->> 'unit',
      coalesce((d ->> 'concentration')::boolean, false), coalesce((d ->> 'ritual')::boolean, false),
      concat_ws(', ', case when coalesce((d -> 'components' ->> 'v')::boolean, false) then 'V' end,
                      case when coalesce((d -> 'components' ->> 's')::boolean, false) then 'S' end,
                      case when coalesce((d -> 'components' ->> 'm')::boolean, false) then 'M' || coalesce(' (' || (d -> 'components' ->> 'material') || ')', '') end),
      coalesce((d -> 'components' ->> 'v')::boolean, false), coalesce((d -> 'components' ->> 's')::boolean, false),
      coalesce((d -> 'components' ->> 'm')::boolean, false), d -> 'components' ->> 'material', (d -> 'components' ->> 'cost_gp')::numeric,
      coalesce((d -> 'components' ->> 'consumed')::boolean, false), 'parsed',
      case when d ->> 'attack_type' is not null then 'attack' when d ->> 'save_ability' is not null then 'save' else 'automatic' end,
      d ->> 'attack_type', d ->> 'save_ability', nullif(d ->> 'higher_levels', '') is not null,
      case when jsonb_array_length(coalesce(d -> 'effects', '[]')) > 0 then 'partially_automated' else 'informational' end,
      'Campaign custom', null, 'current', 'homebrew', nullif(d ->> 'higher_levels', ''), v.id);
    n := 0;
    for e in select x2 from jsonb_array_elements(coalesce(d -> 'effects', '[]')) x2 loop
      n := n + 1;
      insert into public.spell_effects (version_id, seq, category, mechanism, timing, dice, flat_modifier, adds_spell_mod, damage_mode,
        half_on_save, scaling_type, scaling_dice, scaling_base, automation, notes)
      values (ref, n, coalesce(e ->> 'category', 'damage'),
        case when d ->> 'attack_type' is not null then 'attack' when d ->> 'save_ability' is not null then 'save' else 'automatic' end,
        coalesce(e ->> 'timing', case when d ->> 'attack_type' is not null then 'on_hit' when d ->> 'save_ability' is not null then 'on_failed_save' else 'on_cast' end),
        e ->> 'dice', coalesce((e ->> 'flat')::int, 0), coalesce((e ->> 'adds_spell_mod')::boolean, false), 'single',
        coalesce((e ->> 'half_on_save')::boolean, false), coalesce(e -> 'scaling' ->> 'type', 'none'), e -> 'scaling' ->> 'dice',
        (e -> 'scaling' ->> 'base')::int, 'automated', e ->> 'notes');
      for x in select jsonb_array_elements_text(coalesce(e -> 'damage_types', '[]')) loop
        insert into public.spell_effect_damage_types (version_id, seq, damage_type_id) values (ref, n, x);
      end loop;
    end loop;
    for x in select jsonb_array_elements_text(coalesce(d -> 'class_lists', '[]')) loop
      insert into public.class_spell_list_entries (list_id, spell_version_id, spell_level, is_optional, provenance, notes)
      values (x, ref, (d ->> 'level')::int, false, 'campaign_custom', 'Added by the DM of ' || (select name from public.campaigns where id = camp));
    end loop;
  when 'item' then
    perform public._write_homebrew(ref, coalesce(d -> 'item', '{}') || jsonb_build_object('campaign_id', camp, 'name', v.name,
                                   'description', coalesce(nullif(v.player_text, ''), d -> 'item' ->> 'description')),
                                   coalesce(d -> 'stats', '{}'), true);
    update public.items set content_version_id = v.id, source_label = 'Campaign custom', owner_id = owner where id = ref;
  when 'feat' then
    insert into public.feats (id, name, owner_id, campaign_id) values (base, v.name, owner, camp) on conflict (id) do update set name = excluded.name;
    insert into public.feat_versions (id, feat_id, name, category, ruleset, status, summary, automation, implementation_note, source_label,
      min_level, repeatable, max_count, distinct_choice_key, prerequisite_text, tags, owner_id, campaign_id, content_version_id)
    values (ref, base, v.name, coalesce(d ->> 'category', 'general'), coalesce(v.ruleset, '2024'), 'homebrew', left(v.summary, 400),
      case when jsonb_array_length(coalesce(d -> 'effects', '[]')) + jsonb_array_length(coalesce(d -> 'choices', '[]')) = 0 then 'informational'
           when exists (select 1 from jsonb_array_elements(coalesce(d -> 'effects', '[]')) e2 where e2 ->> 'type' = 'informational') then 'partially_automated'
           else 'automated' end,
      'Campaign custom feat', 'Campaign custom', (d ->> 'min_level')::int, coalesce(d ->> 'repeatable', 'once'), (d ->> 'max_count')::int,
      d ->> 'distinct_choice', d ->> 'prerequisite_text', array(select jsonb_array_elements_text(coalesce(d -> 'tags', '[]'))), owner, camp, v.id);
    n := 0;
    for e in select x2 from jsonb_array_elements(coalesce(d -> 'prerequisites', '[]')) x2 loop
      n := n + 1;
      insert into public.feat_prerequisites (version_id, seq, grp, kind, target, value, label)
      values (ref, n, coalesce((e ->> 'group')::int, n), e ->> 'kind', e ->> 'target', e ->> 'value', coalesce(e ->> 'label', e ->> 'kind'));
    end loop;
    n := 0;
    for ch in select x2 from jsonb_array_elements(coalesce(d -> 'choices', '[]')) x2 loop
      n := n + 1; chid := ref || ':' || (ch ->> 'key');
      insert into public.feat_choices (id, version_id, key, kind, label, min_picks, max_picks, config, seq)
      values (chid, ref, ch ->> 'key', ch ->> 'kind', coalesce(ch ->> 'label', ch ->> 'key'), coalesce((ch ->> 'min')::int, 1),
              coalesce((ch ->> 'max')::int, 1), coalesce(ch -> 'config', '{}'), n);
      insert into public.feat_choice_options (choice_id, option_id, label, data, seq)
      select chid, o ->> 'id', coalesce(o ->> 'label', o ->> 'id'), coalesce(o -> 'data', '{}'), ord::int
      from jsonb_array_elements(coalesce(ch -> 'options', '[]')) with ordinality o2(o, ord);
    end loop;
    n := 0;
    for e in select x2 from jsonb_array_elements(coalesce(d -> 'effects', '[]')) x2 loop
      n := n + 1;
      insert into public.feat_effects (version_id, seq, effect_type, target, value, value_text, choice_key, activation, automation, conditions, data, label)
      values (ref, n, e ->> 'type', e ->> 'target', (e ->> 'value')::numeric, e ->> 'value_text', e ->> 'choice', coalesce(e ->> 'activation', 'passive'),
              case when e ->> 'type' = 'informational' then 'informational' else coalesce(e ->> 'automation', 'automated') end,
              coalesce(e -> 'conditions', '{}'), coalesce(e -> 'data', '{}'), e ->> 'label');
    end loop;
    n := 0;
    for s in select x2 from jsonb_array_elements(coalesce(d -> 'spells', '[]')) x2 loop
      n := n + 1;
      insert into public.feat_spell_grants (version_id, seq, spell_version_id, choice_key, mode, ability, ability_choice_key, uses, uses_slots, label)
      values (ref, n, s ->> 'spell', s ->> 'choice', coalesce(s ->> 'mode', 'known'), s ->> 'ability', s ->> 'ability_choice',
              coalesce(s ->> 'uses', 'at_will'), coalesce((s ->> 'uses_slots')::boolean, false), coalesce(s ->> 'label', v.name));
    end loop;
    for r in select x2 from jsonb_array_elements(coalesce(d -> 'resources', '[]')) x2 loop
      insert into public.feat_resource_grants (version_id, key, name, max_formula, recharge)
      values (ref, r ->> 'key', r ->> 'name', coalesce(r -> 'max', '{"fixed": 1}'), coalesce(r ->> 'recharge', 'long_rest'));
    end loop;
  when 'creature', 'companion' then
    s := case when c.content_type = 'companion' then coalesce(d -> 'creature', '{}') else d end;
    insert into public.creatures (id, name, size, creature_type, subtype, alignment, armor_class, armor_type, hit_points, hit_dice, speed,
      abilities, saving_throws, skills, senses, languages, challenge_rating, xp, proficiency_bonus, damage_vulnerabilities,
      damage_resistances, damage_immunities, condition_immunities, traits, actions, reactions, content_scope, source_label, license,
      mechanics_status, mechanics_notes, owner_id, campaign_id, wild_shape_eligible, companion_eligible, content_version_id)
    values (ref, v.name, coalesce(s ->> 'size', 'Medium'), coalesce(s ->> 'creature_type', 'beast'), s ->> 'subtype', s ->> 'alignment',
      (s ->> 'armor_class')::int, s ->> 'armor_type', (s ->> 'hit_points')::int, s ->> 'hit_dice', coalesce(s -> 'speed', '{"walk": 30}'),
      s -> 'abilities', coalesce(s -> 'saving_throws', '{}'), coalesce(s -> 'skills', '{}'), coalesce(s -> 'senses', '{}'), s ->> 'languages',
      coalesce((s ->> 'challenge_rating')::numeric, 0), (s ->> 'xp')::int,
      coalesce((s ->> 'proficiency_bonus')::int, greatest(2, (coalesce((s ->> 'challenge_rating')::numeric, 0)::int - 1) / 4 + 2)),
      array(select jsonb_array_elements_text(coalesce(s -> 'damage_vulnerabilities', '[]'))), array(select jsonb_array_elements_text(coalesce(s -> 'damage_resistances', '[]'))),
      array(select jsonb_array_elements_text(coalesce(s -> 'damage_immunities', '[]'))), array(select jsonb_array_elements_text(coalesce(s -> 'condition_immunities', '[]'))),
      coalesce(s -> 'traits', '[]'), coalesce(s -> 'actions', '[]'), coalesce(s -> 'reactions', '[]'),
      'campaign', 'Campaign custom', 'Campaign content', 'complete', nullif(v.summary, ''), owner, camp,
      c.content_type = 'creature' and coalesce((d ->> 'wild_shape_eligible')::boolean, true),
      c.content_type = 'companion' or coalesce((d ->> 'companion_eligible')::boolean, false), v.id);
  when 'background' then
    insert into public.backgrounds (id, name, sort_order, owner_id, campaign_id) values (base, v.name, 900, owner, camp)
    on conflict (id) do update set name = excluded.name;
    insert into public.background_versions (id, background_id, name, ruleset, rules_label, status, source_label, source_url,
      dm_permission, enabled_by_default, duplicate_rule, sort_order, owner_id, campaign_id, content_version_id)
    values (ref, base, v.name, coalesce(v.ruleset, '2024'), case when coalesce(v.ruleset, '2024') = '2024' then '2024 (Campaign custom)' else 'Legacy (Campaign custom)' end,
      'homebrew', 'Campaign custom', null, false, true,
      coalesce(d ->> 'duplicate_rule', (select x.duplicate_rule from public.background_versions x where x.ruleset = coalesce(v.ruleset, '2024') and x.status = 'official'
                                         order by x.id limit 1), 'A duplicate proficiency is kept.'), 900, owner, camp, v.id);
    for x in select jsonb_array_elements_text(coalesce(d -> 'abilities', '[]')) loop
      insert into public.background_ability_options (version_id, ability) values (ref, x);
    end loop;
    if d ? 'feat' then
      insert into public.background_feat_grants (version_id, feat_id, parameter) values (ref, d ->> 'feat', d ->> 'feat_parameter');
    end if;
    n := 0;
    for x in select jsonb_array_elements_text(coalesce(d -> 'skills', '[]')) loop
      n := n + 1; insert into public.background_proficiency_grants (version_id, kind, target_id, seq) values (ref, 'skill', x, n);
    end loop;
    for x in select jsonb_array_elements_text(coalesce(d -> 'tools', '[]')) loop
      n := n + 1; insert into public.background_proficiency_grants (version_id, kind, target_id, seq) values (ref, 'tool', x, n);
    end loop;
    for x in select jsonb_array_elements_text(coalesce(d -> 'languages', '[]')) loop
      n := n + 1; insert into public.background_proficiency_grants (version_id, kind, target_id, seq) values (ref, 'language', x, n);
    end loop;
    if d ? 'feature' then
      insert into public.background_features (version_id, key, name, summary, automation)
      values (ref, 'feature', d -> 'feature' ->> 'name', coalesce(d -> 'feature' ->> 'summary', ''), 'informational');
    end if;
    if jsonb_array_length(coalesce(d -> 'equipment', '[]')) > 0 or d ? 'gold' then
      pkg := ref || ':A';
      insert into public.background_equipment_packages (id, version_id, key, label, coins, sort_order)
      values (pkg, ref, 'A', 'Equipment', coalesce(d -> 'equipment_coins', '{}'), 1);
      n := 0;
      for e in select x2 from jsonb_array_elements(coalesce(d -> 'equipment', '[]')) x2 loop
        n := n + 1;
        insert into public.background_equipment_entries (package_id, seq, item_id, quantity, label)
        values (pkg, n, e ->> 'item_id', coalesce((e ->> 'quantity')::int, 1), coalesce(e ->> 'label', e ->> 'item_id'));
      end loop;
      if d ? 'gold' then
        insert into public.background_equipment_packages (id, version_id, key, label, coins, sort_order)
        values (ref || ':B', ref, 'B', (d ->> 'gold') || ' GP', jsonb_build_object('gp', (d ->> 'gold')::int), 2);
      end if;
    end if;
  when 'lineage' then
    insert into public.lineages (id, category_id, name, summary, sort_order, owner_id, campaign_id)
    values (base, 'exotic', v.name, coalesce(v.summary, ''), 900, owner, camp) on conflict (id) do update set name = excluded.name;
    insert into public.lineage_versions (id, lineage_id, kind, name, source_label, source_url, status, creature_type, summary, sort_order,
                                         owner_id, campaign_id, content_version_id)
    values (ref, base, 'base', v.name, 'Campaign custom', null, 'current', coalesce(d ->> 'creature_type', 'humanoid'), coalesce(v.summary, ''), 900,
            owner, camp, v.id);
    n := 0;
    for e in select x2 from jsonb_array_elements(coalesce(d -> 'traits', '[]')) x2 loop
      n := n + 1; x := ref || '-t' || n;
      insert into public.lineage_traits (id, version_id, name, summary, automation, min_level, sort_order)
      values (x, ref, e ->> 'name', coalesce(e ->> 'summary', ''), case when jsonb_array_length(coalesce(e -> 'effects', '[]')) > 0 then 'automatic' else 'informational' end,
              coalesce((e ->> 'min_level')::int, 1), n);
      insert into public.lineage_trait_effects (trait_id, seq, effect_type, target, value, value_text, min_level, data)
      select x, ord::int, f ->> 'type',
             case when f ->> 'type' in ('resistance', 'immunity', 'condition_immunity', 'language') then null else f ->> 'target' end,
             (f ->> 'value')::numeric,
             case when f ->> 'type' in ('resistance', 'immunity', 'condition_immunity', 'language') then coalesce(f ->> 'value_text', f ->> 'target') else f ->> 'value_text' end,
             coalesce((f ->> 'min_level')::int, 1), coalesce(f -> 'data', '{}')
      from jsonb_array_elements(coalesce(e -> 'effects', '[]')) with ordinality f2(f, ord);
    end loop;
    if d ? 'ability_patterns' then
      insert into public.lineage_choices (id, version_id, kind, label, pick_count, required, config, sort_order)
      values (ref || ':asi', ref, 'ability_scores', 'Ability Score Increases', coalesce((d ->> 'ability_picks')::int, 2), true,
              jsonb_build_object('patterns', d -> 'ability_patterns'), 1);
    end if;
    if coalesce((d ->> 'feat_choice')::boolean, false) then
      insert into public.lineage_choices (id, version_id, kind, label, pick_count, required, config, sort_order)
      values (ref || ':feat', ref, 'feat', 'Feat', 1, false, '{"hint": "A feat from the feat catalog."}', 2);
    end if;
  when 'condition' then
    ref := v.id::text;                 -- conditions are assigned by version id (20261019000500)
  end case;
  update public.dm_content_versions set catalog_ref = ref where id = p_version;
  return ref;
end;
$function$;

CREATE OR REPLACE FUNCTION public._dm_try(p_version uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare ref text; prev jsonb; err text; t text; v public.dm_content_versions; errors jsonb := '[]'; warnings jsonb := '[]'; d jsonb;
begin
  select * into v from public.dm_content_versions where id = p_version;
  select content_type into t from public.dm_content where id = v.content_id;
  d := v.definition;
  -- structural checks with friendly messages (the catalog constraints catch the rest)
  if t = 'spell' then
    if (d ->> 'level') is null then errors := errors || '["Choose the spell level (0 for a cantrip)."]'; end if;
    if (d ->> 'school') is null then errors := errors || '["Choose the school of magic."]'; end if;
    if jsonb_array_length(coalesce(d -> 'class_lists', '[]')) = 0 then warnings := warnings || '["No class spell list: the spell can only be assigned directly."]'; end if;
  elsif t in ('creature', 'companion') then
    if coalesce((case when t = 'companion' then d -> 'creature' else d end) ->> 'armor_class', '') = '' then errors := errors || '["Armor Class is required."]'; end if;
    if coalesce((case when t = 'companion' then d -> 'creature' else d end) ->> 'hit_points', '') = '' then errors := errors || '["Hit points are required."]'; end if;
    if (case when t = 'companion' then d -> 'creature' else d end) -> 'abilities' is null then errors := errors || '["All six ability scores are required."]'; end if;
    if t = 'creature' and coalesce((d ->> 'wild_shape_eligible')::boolean, true) and jsonb_array_length(coalesce(d -> 'actions', '[]')) = 0 then
      warnings := warnings || '["A Wild Shape form without actions has no attacks in the form sheet."]';
    end if;
  elsif t = 'background' then
    if coalesce(v.ruleset, '2024') = '2024' and jsonb_array_length(coalesce(d -> 'abilities', '[]')) <> 3 then errors := errors || '["A 2024 background lists exactly three abilities."]'; end if;
    if coalesce(v.ruleset, '2024') = '2024' and not d ? 'feat' then errors := errors || '["A 2024 background grants an Origin feat."]'; end if;
    if coalesce(v.ruleset, '2024') = '2014' and (d ? 'abilities' or d ? 'feat') then errors := errors || '["Legacy (2014) backgrounds have no ability increases or Origin feat; use a 2024 background."]'; end if;
  elsif t = 'feat' then
    if exists (select 1 from jsonb_array_elements(coalesce(d -> 'choices', '[]')) c2 where coalesce(c2 ->> 'key', '') = '') then errors := errors || '["Every choice needs a key."]'; end if;
    -- V6.2: only effect types the derived-stat engine understands (the editor's list and the official catalog)
    if exists (select 1 from jsonb_array_elements(coalesce(d -> 'effects', '[]')) e2 where coalesce(e2 ->> 'type', '') not in
               ('speed_bonus', 'ac_bonus', 'initiative_bonus', 'hp_per_level', 'hp_flat', 'ability_bonus', 'save_bonus', 'attack_bonus', 'damage_bonus',
                'resistance', 'proficiency', 'expertise', 'sense', 'informational', 'attack')) then
      errors := errors || jsonb_build_array('Unknown effect type: ' || (select string_agg(distinct coalesce(e3 ->> 'type', '(empty)'), ', ')
        from jsonb_array_elements(coalesce(d -> 'effects', '[]')) e3 where coalesce(e3 ->> 'type', '') not in
        ('speed_bonus', 'ac_bonus', 'initiative_bonus', 'hp_per_level', 'hp_flat', 'ability_bonus', 'save_bonus', 'attack_bonus', 'damage_bonus',
         'resistance', 'proficiency', 'expertise', 'sense', 'informational', 'attack')) || '. Choose an effect from the list.');
    end if;
  elsif t = 'condition' then
    if coalesce(d ->> 'category', '') = '' then warnings := warnings || '["No category: shown under Other."]'; end if;
  end if;
  if jsonb_array_length(errors) > 0 then
    return jsonb_build_object('ok', false, 'errors', errors, 'warnings', warnings);
  end if;
  begin
    -- a version that was never published has no catalog row yet: materialize it under a temporary number
    ref := public._dm_materialize(p_version);
    prev := public._dm_catalog_json(t, ref);
    raise exception 'dm preview rollback' using errcode = 'TLPRV';
  exception
    when sqlstate 'TLPRV' then null;
    when others then err := sqlerrm;
  end;
  if err is not null then
    -- V6.2: database wording (constraint, relation and column names) becomes a message the DM can act on
    err := case
      when err ~* 'violates foreign key constraint' then 'Something this content refers to does not exist (for example an unknown damage type, spell, item or feat).'
      when err ~* 'null value in column "([a-z_]+)"' then 'A required value is missing: ' || replace(substring(err from 'null value in column "([a-z_]+)"'), '_', ' ') || '.'
      when err ~* 'violates check constraint' then 'A value is outside its allowed range (check numbers such as level, hit points, Armor Class or challenge rating).'
      when err ~* 'violates unique constraint|duplicate key' then 'Something with this name or key already exists.'
      when err ~* 'invalid input syntax|out of range for type' then 'A number or value has the wrong format.'
      else err end;
    return jsonb_build_object('ok', false, 'errors', jsonb_build_array(err), 'warnings', warnings);
  end if;
  return jsonb_build_object('ok', true, 'errors', '[]'::jsonb, 'warnings', warnings, 'preview', prev, 'catalog_ref_preview', ref);
end;
$function$;

alter table public.characters drop constraint if exists characters_hp_current_check;
alter table public.characters add constraint characters_hp_current_check check (hp_current >= 0) not valid;
alter table public.characters validate constraint characters_hp_current_check;
alter table public.characters drop constraint if exists characters_coins_check;
alter table public.characters add constraint characters_coins_check check (cp >= 0 and sp >= 0 and ep >= 0 and gp >= 0 and pp >= 0) not valid;
alter table public.characters validate constraint characters_coins_check;

commit;
