-- Rollback of 20261112000200_character_conditions_unified.sql: drops the new triggers and functions, restores the exact previous
-- bodies of the five replaced functions (captured with pg_get_functiondef from the local database at 20261112000100; md5 of
-- pg_get_functiondef: _character_read bba461e3, get_character_conditions 344ca55b, remove_character_condition 0b7d764d,
-- apply_character_condition c5a9bf79, combat_finish 4db16266 (with the carriage returns the CLI applied; compare without them
-- after a checkout that changed line endings)), drops the new columns, puts character_conditions back into supabase_realtime and character_condition_secrets back on the
-- global tl_cache bump.
-- Grants are unchanged by CREATE OR REPLACE.
-- DATA:
--  * characters.conditions is never changed here. It holds the visible conditions as the mirror last wrote them (copied
--    sheet entries verbatim, newer entries by name, Exhaustion as "Exhaustion N"), which is what the previous sheet shows.
--  * Deleted: only VISIBLE rows with source 'legacy_sheet' (the migration's own copies of characters.conditions entries; every
--    one of them is still in characters.conditions). A copied row the DM hid since is kept as an ordinary hidden condition.
--  * Rows applied since the migration (DM, player, combat) are kept with their name, visibility, note and timer; the new
--    columns are dropped with their values (kind, SRD key, Exhaustion level, tag type, damage type, duration text, source).
--    Such a visible row then shows in DM Space next to its name in characters.conditions (as DM conditions did before).
-- Deploy the previous frontend first or together (the new sheet calls apply_character_effect / update_character_effect and
-- reads get_character_conditions through get_character_reads; without them it falls back to characters.conditions).
begin;
drop trigger if exists character_conditions_mirror on public.character_conditions;
drop trigger if exists character_conditions_revision_ins on public.character_conditions;
drop trigger if exists character_conditions_revision_upd on public.character_conditions;
drop trigger if exists character_conditions_revision_del on public.character_conditions;
drop trigger if exists characters_legacy_conditions on public.characters;
drop trigger if exists characters_legacy_conditions_insert on public.characters;
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
end $function$
;
CREATE OR REPLACE FUNCTION public.get_character_conditions(p_character uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare camp uuid; dm boolean;
begin
  if auth.uid() is null or not public.can_access_character(p_character) then raise exception 'Character not found' using errcode = '42501'; end if;
  select campaign_id into camp from public.characters where id = p_character;
  dm := public.is_admin() or (camp is not null and public.is_campaign_dm(camp));
  return (select coalesce(jsonb_agg(jsonb_build_object('id', k.id, 'name', k.name, 'note', k.note, 'expires_at', case when dm or not k.hidden then k.expires_at end,
             'applied_at', k.applied_at, 'revealed_at', k.revealed_at, 'custom', k.content_version_id is not null,
             'summary', (select summary from public.dm_content_versions where id = k.content_version_id),
             'player_text', (select player_text from public.dm_content_versions where id = k.content_version_id),
             'effects', (select definition -> 'effects' from public.dm_content_versions where id = k.content_version_id),
             'hidden', case when dm then k.hidden end,
             'dm_note', case when dm then (select dm_note from public.character_condition_secrets where condition_id = k.id) end)
           order by k.applied_at), '[]')
          from public.character_conditions k where k.character_id = p_character and (dm or not k.hidden));
end;
$function$
;
CREATE OR REPLACE FUNCTION public.remove_character_condition(p_condition uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare k public.character_conditions; camp uuid;
begin
  select * into k from public.character_conditions where id = p_condition for update;
  if k.id is null or not public.can_access_character(k.character_id) then raise exception 'Condition not found' using errcode = 'P0002'; end if;
  if k.hidden then camp := public._dm_hidden_gate(k.character_id); else perform public._gov_gate(k.character_id, 'runtime.conditions'); end if;
  if not k.hidden and k.applied_by is distinct from auth.uid() and k.content_version_id is not null then
    perform public._gov_gate(k.character_id, 'runtime.conditions');
  end if;
  delete from public.character_conditions where id = p_condition;
  select campaign_id into camp from public.characters where id = k.character_id;
  if camp is not null then
    perform public._audit(camp, k.character_id, 'condition_removed', 'Condition removed: ' || k.name, null, null, null, null, case when k.hidden then 'dm' else 'party' end);
  end if;
  return public.get_character_conditions(k.character_id);
end;
$function$
;
CREATE OR REPLACE FUNCTION public.apply_character_condition(p_character uuid, p_version uuid, p_name text, p_hidden boolean, p_expires timestamp with time zone, p_note text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare camp uuid; nm text := btrim(coalesce(p_name, '')); v public.dm_content_versions; c public.dm_content; cid uuid;
begin
  if auth.uid() is null or not public.can_access_character(p_character) then raise exception 'Character not found' using errcode = '42501'; end if;
  select campaign_id into camp from public.characters where id = p_character;
  if coalesce(p_hidden, false) then
    perform public._dm_hidden_gate(p_character);
  else
    perform public._gov_gate(p_character, 'runtime.conditions');
  end if;
  if p_version is not null then
    select * into v from public.dm_content_versions where id = p_version;
    select * into c from public.dm_content where id = v.content_id;
    if c.content_type <> 'condition' or v.status <> 'published' or c.campaign_id is distinct from camp then
      raise exception 'Unknown or unpublished condition' using errcode = '22023';
    end if;
    nm := coalesce(nullif(nm, ''), v.name);
  end if;
  if nm = '' then raise exception 'Name the condition' using errcode = '22023'; end if;
  perform 1 from public.characters where id = p_character for update;
  insert into public.character_conditions (character_id, content_version_id, name, hidden, note, expires_at)
  values (p_character, p_version, left(nm, 80), coalesce(p_hidden, false), nullif(left(p_note, 500), ''), p_expires)
  returning id into cid;
  if camp is not null then
    perform public._audit(camp, p_character, case when coalesce(p_hidden, false) then 'hidden_effect_added' else 'condition_added' end,
                          case when coalesce(p_hidden, false) then 'Hidden condition: ' else 'Condition: ' end || nm, null, null, null, null,
                          case when coalesce(p_hidden, false) then 'dm' else 'party' end);
  end if;
  return public.get_character_conditions(p_character);
end;
$function$
;
CREATE OR REPLACE FUNCTION public.combat_finish(p_encounter uuid, p_notes text DEFAULT NULL::text, p_decisions jsonb DEFAULT '{}'::jsonb, p_confirm boolean DEFAULT false, p_request uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare e public.combat_encounters := public._combat_auth(p_encounter, 'update'); r jsonb; lasting jsonb; l jsonb; d text; kept jsonb := '[]'; carried jsonb := '[]';
  summ jsonb; secs int; ev bigint;
begin
  r := public._combat_replay(e.id, p_request); if r is not null then return r; end if;
  if e.status not in ('active', 'paused') then raise exception 'Only a running or paused combat can be finished' using errcode = '22023'; end if;
  lasting := public._combat_lasting_effects(e.id);
  if jsonb_array_length(lasting) > 0 and not coalesce(p_confirm, false)
     and exists (select 1 from jsonb_array_elements(lasting) y where not coalesce(p_decisions, '{}') ? (y ->> 'id')) then
    return jsonb_build_object('needs_review', true, 'effects', lasting);
  end if;
  for l in select y from jsonb_array_elements(lasting) y loop
    d := coalesce(p_decisions ->> (l ->> 'id'), 'keep');
    if d = 'carry' and (l ->> 'can_carry')::boolean then
      perform public.apply_character_condition((l ->> 'character_id')::uuid, null, l ->> 'name', l ->> 'visibility' = 'dm', null,
        'From the encounter "' || e.name || '"');
      update public.combat_effects set active = false, ended_at = now(), ended_reason = 'carried_to_sheet', rev = rev + 1 where id = (l ->> 'id')::uuid;
      carried := carried || l;
    elsif d = 'end' then
      update public.combat_effects set active = false, ended_at = now(), ended_reason = 'encounter_finished', rev = rev + 1 where id = (l ->> 'id')::uuid;
    else kept := kept || l; end if;
  end loop;
  -- every other effect is a combat effect: it ends with the fight
  update public.combat_effects set active = false, ended_at = now(), ended_reason = 'encounter_finished', rev = rev + 1
  where encounter_id = e.id and active and not (id = any (public._combat_ids(kept, 'id')));
  secs := e.active_seconds + case when e.status = 'active' and e.resumed_at is not null then extract(epoch from now() - e.resumed_at)::int else 0 end;
  summ := jsonb_build_object('duration_seconds', secs, 'rounds', e.round, 'ruleset', e.ruleset,
    'participants', (select coalesce(jsonb_agg(jsonb_build_object('id', p.id, 'name', p.display_name || coalesce(' ' || p.instance_label, ''), 'kind', p.kind,
        'hp', case when p.kind = 'monster' then p.hp_current else (select c.hp_current from public.characters c where c.id = p.linked_character_id) end,
        'max', case when p.kind = 'monster' then p.hp_max else (select (public._feat_hp_bonus(c.id) ->> 'max')::int from public.characters c where c.id = p.linked_character_id) end,
        'defeated', p.defeated, 'removed', p.removed_at is not null, 'hidden', p.hidden,
        'down', p.kind = 'character' and coalesce((select c.hp_current from public.characters c where c.id = p.linked_character_id), 1) <= 0)
        order by p.initiative_order nulls last), '[]') from public.combat_participants p where p.encounter_id = e.id),
    'effects_applied', (select count(*) from public.combat_effects where encounter_id = e.id),
    'conditions', (select coalesce(jsonb_agg(distinct display_name), '[]') from public.combat_effects where encounter_id = e.id and effect_type = 'condition'),
    'kept_effects', kept, 'carried_effects', carried,
    'damage_total', (select coalesce(sum((details ->> 'amount')::int), 0) from public.combat_events where encounter_id = e.id and kind = 'damage' and undone_by is null),
    'healing_total', (select coalesce(sum((details ->> 'amount')::int), 0) from public.combat_events where encounter_id = e.id and kind = 'heal' and undone_by is null),
    'major_events', (select coalesce(jsonb_agg(jsonb_build_object('kind', z.kind, 'round', z.round, 'participant', (select display_name || coalesce(' ' || instance_label, '')
                       from public.combat_participants where id = z.participant_id), 'amount', z.details -> 'amount') order by z.id), '[]')
                     from (select * from public.combat_events where encounter_id = e.id and undone_by is null
                           and kind in ('participant_defeat', 'concentration_failed', 'participant_revealed', 'participants_added', 'damage')
                           and (kind <> 'damage' or coalesce((details ->> 'amount')::int, 0) >= 10)
                           and (kind <> 'participants_added' or coalesce(round, 0) > 0)   -- joins during the fight, not the preparation
                           order by id desc limit 20) z));
  update public.combat_encounters set status = 'completed', completed_at = now(), active_seconds = secs, summary = summ,
    finish_notes = coalesce(left(p_notes, 8000), finish_notes), turn_rev = turn_rev + 1, rev = rev + 1, updated_at = now() where id = e.id;
  ev := public._combat_event(e.id, 'combat_finished', null, null, null, jsonb_build_object('kept', kept, 'carried', carried), p_request, false);
  perform public._combat_changed(e.id, 'encounter', 'finished', null, true);
  r := jsonb_build_object('encounter', public._combat_encounter_json((select x from public.combat_encounters x where x.id = e.id)), 'summary', summ);
  perform public._combat_set_result(ev, r);
  return r;
end $function$
;
-- character_condition_secrets: back to the global counter bump of 20261030000200
drop trigger if exists tl_cache_rev on public.character_condition_secrets;
create trigger tl_cache_rev after insert or update or delete on public.character_condition_secrets
  for each row execute function tl_cache.bump('global');
drop function if exists tl_cache.skip();
drop function if exists public.apply_character_effect(uuid, jsonb);
drop function if exists public.update_character_effect(uuid, jsonb);
drop function if exists public._combat_carry_spec(uuid, text);
drop function if exists public._conditions_mirror();
drop function if exists public._conditions_from_sheet();
drop function if exists public._conditions_from_new_sheet();
drop function if exists public._condition_insert(uuid, jsonb, text, int);
drop function if exists public._conditions_visible(uuid);
drop function if exists public._condition_label(public.character_conditions);
drop function if exists public._condition_parse(text);
drop function if exists public._condition_text(jsonb);
-- the migration's own visible copies of sheet entries (still in characters.conditions)
delete from public.character_conditions where source = 'legacy_sheet' and not hidden;
drop index if exists public.character_conditions_one_exhaustion;
alter table public.character_conditions
  drop constraint if exists character_conditions_kind_check,
  drop constraint if exists character_conditions_key_check,
  drop constraint if exists character_conditions_level_check,
  drop constraint if exists character_conditions_tag_check,
  drop constraint if exists character_conditions_duration_check,
  drop constraint if exists character_conditions_source_check,
  drop column if exists kind,
  drop column if exists condition_key,
  drop column if exists level,
  drop column if exists tag_type,
  drop column if exists damage_type_id,
  drop column if exists duration_text,
  drop column if exists source,
  drop column if exists legacy_value,
  drop column if exists legacy_pos;
do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime')
     and not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'character_conditions') then
    alter publication supabase_realtime add table public.character_conditions;
  end if;
end $$;
notify pgrst, 'reload schema';
commit;
