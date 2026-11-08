-- Rollback of 20261106000200_combat_builder_functions.sql (run BEFORE rollback_combat_builder_schema.sql).
-- Drops exactly the functions that migration created (an explicit list: older functions such as combat_wild_shape_heal
-- are never touched) and restores public._dm_try exactly as it was before (definition captured from the database on
-- 2026-11-06; carriage returns a Windows checkout may add are removed before it runs, so the body is byte-identical).
-- The sheet's Damage / Heal buttons need apply_character_hp: deploy the previous frontend first
-- (docs/COMBAT_BUILDER_PRODUCTION_PLAN.md "Rollback").
begin;
do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname = any (array['_combat_apply_order', '_combat_auth', '_combat_boundary', '_combat_campaign_ruleset', '_combat_can_act', '_combat_changed', '_combat_char_state', '_combat_creature_errors', '_combat_d20', '_combat_difficulty', '_combat_ejson', '_combat_encounter_json', '_combat_entries', '_combat_event', '_combat_hp_one', '_combat_hp_state', '_combat_ids', '_combat_init_mode', '_combat_label', '_combat_lasting_effects', '_combat_participant_auth', '_combat_pjson', '_combat_place', '_combat_reminders_due', '_combat_replay', '_combat_roll', '_combat_set_result', '_combat_snapshot', '_combat_sorted', '_combat_source', '_combat_ties', '_combat_touch', '_combat_turn_end', '_combat_turn_result', '_combat_turn_start', 'apply_character_hp', 'combat_ack_reminder', 'combat_add_characters', 'combat_add_custom', 'combat_add_effect', 'combat_add_monsters', 'combat_apply_hp', 'combat_apply_hp_bulk', 'combat_archive_encounter', 'combat_clear_initiative', 'combat_create_encounter', 'combat_delete_draft', 'combat_delete_reminder', 'combat_duplicate_encounter', 'combat_end_effect', 'combat_finish', 'combat_get_changes', 'combat_get_encounter', 'combat_get_history', 'combat_get_participant', 'combat_get_statblock', 'combat_get_summary', 'combat_goto_turn', 'combat_list_encounters', 'combat_monster_detail', 'combat_monster_library', 'combat_next_turn', 'combat_pause', 'combat_previous_turn', 'combat_recent_monsters', 'combat_reorder', 'combat_resolve_concentration', 'combat_resume', 'combat_roll_initiative', 'combat_save_reminder', 'combat_set_initiative', 'combat_set_participant_state', 'combat_set_reaction', 'combat_sort_initiative', 'combat_spend_legendary', 'combat_start', 'combat_toggle_favorite', 'combat_undo', 'combat_update_effect', 'combat_update_encounter', 'combat_update_participant', 'get_combat_player_view'])
  loop
    execute format('drop function %s', f.sig);
  end loop;
end $$;

do $outer$
begin
  execute replace($rb$CREATE OR REPLACE FUNCTION public._dm_try(p_version uuid)
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
$function$$rb$, chr(13), '');
end $outer$;
commit;
