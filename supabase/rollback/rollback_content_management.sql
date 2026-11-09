-- Rollback of 20261109000300_content_management.sql: drops the four new functions and restores the exact previous
-- dm_assign_content (md5 of pg_get_functiondef 5baa0d52). No data is changed.
begin;
drop function if exists public.duplicate_official_as_homebrew(text, text, uuid);
drop function if exists public.delete_unused_dm_content(uuid, text);
drop function if exists public.get_dm_content_usage(uuid);
drop function if exists public._dm_content_dependencies(uuid);
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
commit;
