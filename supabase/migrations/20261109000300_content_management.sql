-- DM / admin content management (docs/CONTENT_MANAGEMENT.md). ADDITIVE: four new functions; no existing function, table, policy
-- or row is changed.
--
-- The DM content lifecycle (20261019000400: draft -> validate -> publish -> new version -> archive -> restore, duplicate, delete of
-- a never-published draft by its author) gains:
--  * _dm_content_dependencies(content): every reference to every published version of a piece of content, counted per kind,
--    split into CURRENT use (blocks deletion and in-place change), HISTORY (completed encounter snapshots, audit history, earlier
--    assignments: delete is refused, archive recommended) and the content's own catalog rows. It covers the foreign keys that
--    would CASCADE silently into player data (character_feat_choices, character_seen_forms, character_form_favorites,
--    character_background_choices) and the text references that have no foreign key at all (a lineage or ASI feat pick
--    'feat:<id>', a background granting a custom feat, other DM content naming the id, combat snapshots, pending requests).
--  * get_dm_content_usage(content): the usage report (counts only, never names) with the classification
--    safe_to_delete | archive_recommended | delete_blocked (+ new_version_required when published content is in use) and the
--    actions the caller may take. Same authorization as every content function (_dm_can_manage): an unrelated DM, a player and
--    anonymous get "Content not found" (no existence leak).
--  * delete_unused_dm_content(content, confirm_name): permanent delete of custom content of ANY type that nothing uses and nothing
--    remembers (drafts and published versions). Campaign content: a DM of that campaign or an admin; private library: its author or
--    an admin. The content row and its catalog rows are locked, the dependencies are re-checked INSIDE the transaction (the UI
--    preview is never trusted), the catalog rows are deleted explicitly per type (no broad cascade beyond the definition's own
--    child rows), and one audit event is written (campaign_audit_events, visibility dm). Any failure leaves everything unchanged;
--    a repeated or concurrent delete gets "Content not found" (one final result, one audit event).
--  * duplicate_official_as_homebrew(type, ref, campaign): a NEW draft (new custom id at publish, source "Campaign custom") built
--    from an official catalog row (spell, item, feat, creature, background, lineage). The official row is only read.
-- Official catalog content (owner_id null, no content_version_id) is never edited or deleted by any of these.
--  * dm_assign_content (replaced, one change): it now takes a share lock on the dm_content row FIRST, like every other content
--    function (publish, archive, save, delete: dm_content -> version -> catalog). Found by content_deletion_concurrency_test.sh:
--    an assignment racing a delete deadlocked (version + catalog key-share locks, then the dm_content row via the event insert).
-- Rollback: supabase/rollback/rollback_content_management.sql (drops the four functions, restores dm_assign_content md5 5baa0d52).

create or replace function public._dm_content_dependencies(p_content uuid)
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
declare c public.dm_content; refs text[]; vids uuid[]; base text; d jsonb := '{}'; cur int := 0; hist int := 0; n int;
  item jsonb; r text;
begin
  select * into c from public.dm_content where id = p_content;
  if c.id is null then return null; end if;
  select coalesce(array_agg(v.catalog_ref) filter (where v.catalog_ref is not null), '{}'), coalesce(array_agg(v.id), '{}')
    into refs, vids from public.dm_content_versions v where v.content_id = p_content;
  base := public._dm_short(p_content);
  -- current use, per type
  case c.content_type
  when 'spell' then
    d := d || jsonb_build_object(
      'character_spells', (select count(*) from public.character_spells where spell_version_id = any (refs)),
      'character_resources', (select count(*) from public.character_resources where spell_version_id = any (refs)),
      'feat_spell_grants', (select count(*) from public.feat_spell_grants where spell_version_id = any (refs)),
      'class_feature_effects', (select count(*) from public.class_feature_effects where spell_version_id = any (refs)));
  when 'item' then
    foreach r in array refs loop
      item := public._item_dependencies(r, p_content);
      d := d || jsonb_build_object(
        'inventory_instances', coalesce((d ->> 'inventory_instances')::int, 0) + coalesce((item ->> 'character_inventories')::int, 0) + coalesce((item ->> 'other_inventories')::int, 0),
        'inventory_history', coalesce((d ->> 'inventory_history')::int, 0) + coalesce((item ->> 'inventory_history')::int, 0),
        'owned_assets', coalesce((d ->> 'owned_assets')::int, 0) + coalesce((item ->> 'owned_assets')::int, 0),
        'background_equipment', coalesce((d ->> 'background_equipment')::int, 0) + coalesce((item ->> 'background_equipment')::int, 0),
        'proficiencies', coalesce((d ->> 'proficiencies')::int, 0) + coalesce((item ->> 'proficiencies')::int, 0),
        'items_based_on_it', coalesce((d ->> 'items_based_on_it')::int, 0) + coalesce((item ->> 'items_based_on_it')::int, 0));
    end loop;
    d := d || jsonb_build_object(
      'equipped_instances', (select count(*) from public.character_equipment e join public.inventory_items ii on ii.id = e.inventory_item_id where ii.item_id = any (refs)),
      'attuned_instances', (select count(*) from public.inventory_items ii where ii.item_id = any (refs) and coalesce(ii.is_attuned, false)));
  when 'feat' then
    d := d || jsonb_build_object(
      'feat_assignments', (select count(*) from public.character_feats where feat_version_id = any (refs)),
      'feat_choices', (select count(*) from public.character_feat_choices x join public.feat_choices fc on fc.id = x.choice_id where fc.version_id = any (refs)),
      'lineage_feat_picks', (select count(*) from public.character_lineage_choices where value = any (array(select 'feat:' || x from unnest(refs) x))),
      'class_feat_picks', (select count(*) from public.character_feature_choice_values where value = any (array(select 'feat:' || x from unnest(refs) x))),
      'backgrounds_granting', (select count(*) from public.background_feat_grants where feat_id = any (refs)));
  when 'creature', 'companion' then
    d := d || jsonb_build_object(
      'seen_forms', (select count(*) from public.character_seen_forms where creature_id = any (refs)),
      'form_favorites', (select count(*) from public.character_form_favorites where creature_id = any (refs)),
      'companions', (select count(*) from public.character_companions where creature_id = any (refs) or template_version_id = any (vids)),
      'transformations', (select count(*) from public.character_transformations where creature_id = any (refs)),
      'active_encounter_snapshots', (select count(*) from public.combat_statblocks s join public.combat_encounters e on e.id = s.encounter_id
                                     where s.source_id = any (refs) and e.status <> 'completed'));
  when 'background' then
    d := d || jsonb_build_object(
      'background_assignments', (select count(*) from public.character_backgrounds where version_id = any (refs)),
      'background_equipment', (select count(*) from public.character_background_equipment where version_id = any (refs)),
      'background_choices', (select count(*) from public.character_background_choices x join public.background_choices bc on bc.id = x.choice_id where bc.version_id = any (refs)));
  when 'lineage' then
    d := d || jsonb_build_object(
      'lineage_assignments', (select count(*) from public.character_lineages where version_id = any (refs) or subversion_id = any (refs)),
      'lineage_choices', (select count(*) from public.character_lineage_choices x join public.lineage_choices lc on lc.id = x.choice_id where lc.version_id = any (refs)));
  when 'condition' then
    d := d || jsonb_build_object('condition_assignments', (select count(*) from public.character_conditions where content_version_id = any (vids)));
  else null;
  end case;
  d := d || jsonb_build_object(
    'pending_requests', (select count(*) from public.change_requests cr where cr.status in ('draft', 'submitted', 'returned_for_changes')
                         and exists (select 1 from unnest(refs) x where cr.ops::text like '%' || x || '%')),
    'other_content', (select count(*) from public.dm_content_versions ov where ov.content_id <> p_content
                      and exists (select 1 from unnest(refs) x where ov.definition::text like '%"' || x || '"%')));
  select coalesce(sum(value::int), 0) into cur from jsonb_each_text(d) where key not in ('inventory_history', 'items_based_on_it');
  cur := cur + coalesce((d ->> 'items_based_on_it')::int, 0);
  -- history: kept for the record, so the content is archived instead of deleted
  d := d || jsonb_build_object(
    'completed_encounter_snapshots', case when c.content_type in ('creature', 'companion') then
        (select count(*) from public.combat_statblocks s join public.combat_encounters e on e.id = s.encounter_id where s.source_id = any (refs) and e.status = 'completed') else 0 end,
    'audit_references', (select count(*) from public.campaign_audit_events a where a.campaign_id is not distinct from c.campaign_id
                         and a.character_id is not null   -- a character's history (the content's own publish / archive events do not count)
                         and exists (select 1 from unnest(refs) x where coalesce(a.before::text, '') || coalesce(a.after::text, '') like '%' || x || '%')),
    'earlier_assignments', (select count(*) from public.dm_content_events ev where ev.content_id = p_content and ev.event = 'assigned'));
  hist := (d ->> 'completed_encounter_snapshots')::int + (d ->> 'audit_references')::int + (d ->> 'earlier_assignments')::int
          + coalesce((d ->> 'inventory_history')::int, 0);
  n := (select count(distinct x.cid) from (
      select character_id as cid from public.character_spells where spell_version_id = any (refs)
      union all select ii.character_id from public.inventory_items ii where ii.item_id = any (refs)
      union all select character_id from public.character_feats where feat_version_id = any (refs)
      union all select character_id from public.character_lineage_choices where value = any (array(select 'feat:' || x from unnest(refs) x))
      union all select ch.character_id from public.character_feature_choice_values fv join public.character_feature_choices ch on ch.id = fv.character_choice_id
                where fv.value = any (array(select 'feat:' || x from unnest(refs) x))
      union all select character_id from public.character_seen_forms where creature_id = any (refs)
      union all select character_id from public.character_companions where creature_id = any (refs) or template_version_id = any (vids)
      union all select character_id from public.character_transformations where creature_id = any (refs)
      union all select character_id from public.character_backgrounds where version_id = any (refs)
      union all select character_id from public.character_lineages where version_id = any (refs) or subversion_id = any (refs)
      union all select character_id from public.character_conditions where content_version_id = any (vids)) x where x.cid is not null);
  return jsonb_build_object('counts', d, 'characters', n, 'current', cur, 'history', hist, 'published_versions', cardinality(refs),
                            'catalog_refs', to_jsonb(refs), 'base', base);
end $$;
revoke all on function public._dm_content_dependencies(uuid) from public, anon, authenticated;

create or replace function public.get_dm_content_usage(p_content uuid)
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
declare c public.dm_content; d jsonb; cls text; published boolean; author boolean; may_delete boolean;
begin
  if auth.uid() is null or not public._dm_can_manage(p_content) then raise exception 'Content not found' using errcode = '42501'; end if;
  select * into c from public.dm_content where id = p_content;
  d := public._dm_content_dependencies(p_content);
  published := c.published_version_id is not null or (d ->> 'published_versions')::int > 0;
  cls := case when (d ->> 'current')::int > 0 then 'delete_blocked'
              when (d ->> 'history')::int > 0 then 'archive_recommended'
              else 'safe_to_delete' end;
  author := c.author_id = auth.uid();
  may_delete := public.is_admin() or (c.campaign_id is not null and public.is_campaign_dm(c.campaign_id)) or (c.campaign_id is null and author);
  return jsonb_build_object(
    'content_id', c.id, 'name', c.name, 'content_type', c.content_type, 'status', c.status, 'source', 'campaign_custom',
    'scope', c.scope, 'archived', c.archived_at is not null,
    'version_no', (select version_no from public.dm_content_versions where id = coalesce(c.published_version_id, c.current_version_id)),
    'characters', d -> 'characters', 'counts', d -> 'counts', 'current_uses', d -> 'current', 'history_references', d -> 'history',
    'published_versions', d -> 'published_versions',
    'classification', cls,
    'edit', case when not published then 'edit_draft' when (d ->> 'current')::int > 0 then 'new_version_required' else 'new_version' end,
    'can_delete', may_delete and cls = 'safe_to_delete',
    'can_archive', published and c.archived_at is null,
    'advice', case cls
      when 'safe_to_delete' then 'Nothing uses this content and nothing refers to it. Deleting it cannot be undone.'
      when 'archive_recommended' then 'Nothing uses it now, but it is part of the campaign history (an encounter, an earlier assignment or the audit log). Archive it: it can no longer be picked, and the history stays readable.'
      else 'It is in use. Archive it (no new picks; everything that has it keeps working) or remove it from the characters first.' end);
end $$;
revoke all on function public.get_dm_content_usage(uuid) from public, anon;
grant execute on function public.get_dm_content_usage(uuid) to authenticated;

create or replace function public.delete_unused_dm_content(p_content uuid, p_confirm_name text)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare c public.dm_content; d jsonb; refs text[]; base text; vno int;
begin
  if auth.uid() is null or not public._dm_can_manage(p_content) then raise exception 'Content not found' using errcode = '42501'; end if;
  -- lock order: the content row, then its catalog rows (a concurrent assignment holds / waits for a key-share lock on them)
  select * into c from public.dm_content where id = p_content for update;
  if c.id is null then raise exception 'Content not found' using errcode = '42501'; end if;    -- deleted meanwhile (repeat / race)
  if not (public.is_admin() or (c.campaign_id is not null and public.is_campaign_dm(c.campaign_id)) or (c.campaign_id is null and c.author_id = auth.uid())) then
    raise exception 'Only a DM of this campaign or an admin can delete it' using errcode = '42501';
  end if;
  if coalesce(btrim(p_confirm_name), '') <> c.name then raise exception 'Type the exact name to confirm' using errcode = '22023'; end if;
  select coalesce(array_agg(catalog_ref) filter (where catalog_ref is not null), '{}') into refs from public.dm_content_versions where content_id = p_content;
  base := public._dm_short(p_content);
  case c.content_type
    when 'spell' then perform 1 from public.spell_versions where id = any (refs) for update;
    when 'item' then perform 1 from public.items where id = any (refs) for update;
    when 'feat' then perform 1 from public.feat_versions where id = any (refs) for update;
    when 'creature', 'companion' then perform 1 from public.creatures where id = any (refs) for update;
    when 'background' then perform 1 from public.background_versions where id = any (refs) for update;
    when 'lineage' then perform 1 from public.lineage_versions where id = any (refs) for update;
    else null;
  end case;
  -- the authoritative re-check, after the locks
  d := public._dm_content_dependencies(p_content);
  if (d ->> 'current')::int > 0 then
    raise exception 'This content is in use. Archive it instead; nothing was deleted.' using errcode = 'TLUSE', hint = 'archive';
  end if;
  if (d ->> 'history')::int > 0 then
    raise exception 'This content is part of the campaign history. Archive it instead; nothing was deleted.' using errcode = 'TLUSE', hint = 'archive';
  end if;
  select version_no into vno from public.dm_content_versions where id = coalesce(c.published_version_id, c.current_version_id);
  begin
    update public.dm_content set current_version_id = null, published_version_id = null where id = p_content;
    case c.content_type
      when 'spell' then
        delete from public.class_spell_list_entries where spell_version_id = any (refs);
        delete from public.spell_versions where id = any (refs);
        delete from public.catalog_spells s where s.id = base and not exists (select 1 from public.spell_versions v where v.spell_id = s.id);
      when 'item' then
        delete from public.items where id = any (refs);
      when 'feat' then
        delete from public.feat_versions where id = any (refs);
        delete from public.feats f where f.id = base and not exists (select 1 from public.feat_versions v where v.feat_id = f.id);
      when 'creature', 'companion' then
        delete from public.creatures where id = any (refs);
      when 'background' then
        delete from public.background_versions where id = any (refs);
        delete from public.backgrounds b where b.id = base and not exists (select 1 from public.background_versions v where v.background_id = b.id);
      when 'lineage' then
        delete from public.lineage_versions where id = any (refs);
        delete from public.lineages l where l.id = base and not exists (select 1 from public.lineage_versions v where v.lineage_id = l.id);
      else null;
    end case;
    delete from public.dm_content where id = p_content;
    insert into public.campaign_audit_events (campaign_id, actor_id, event_type, summary, before, visibility)
    values (c.campaign_id, auth.uid(), 'content_deleted', left(format('Deleted unused %s "%s"', replace(c.content_type, '_', ' '), c.name), 300),
            jsonb_build_object('content_id', c.id, 'content_type', c.content_type, 'name', c.name, 'version_no', vno, 'catalog_refs', to_jsonb(refs)), 'dm');
  exception when foreign_key_violation or restrict_violation then
    raise exception 'This content is in use. Archive it instead; nothing was deleted.' using errcode = 'TLUSE', hint = 'archive';
  end;
  return jsonb_build_object('deleted', p_content, 'name', c.name, 'content_type', c.content_type, 'catalog_refs', to_jsonb(refs));
end $$;
revoke all on function public.delete_unused_dm_content(uuid, text) from public, anon;
grant execute on function public.delete_unused_dm_content(uuid, text) to authenticated;

-- Official catalog row -> DM content definition (the inverse of _dm_materialize for the fields the editor knows). What a custom
-- definition cannot express is left out (a lineage trait effect that depends on a player choice, spell text the catalog does not
-- store); the DM reviews the draft and the authoritative validation runs before publishing.
create or replace function public.duplicate_official_as_homebrew(p_type text, p_ref text, p_campaign uuid)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare def jsonb; nm text; summ text; txt text; rs text; it record; sv public.spell_versions; fv public.feat_versions; cr public.creatures;
  bv public.background_versions; lv public.lineage_versions; fields jsonb;
begin
  if auth.uid() is null then raise exception 'Not signed in' using errcode = '42501'; end if;
  if p_campaign is not null and not (public.is_campaign_dm(p_campaign) or public.is_admin()) then
    raise exception 'Not found' using errcode = '42501';
  end if;
  case p_type
  when 'spell' then
    select * into sv from public.spell_versions where id = p_ref and content_version_id is null;
    if sv.id is null or exists (select 1 from public.catalog_spells s where s.id = sv.spell_id and s.owner_id is not null) then
      raise exception 'Official spell not found' using errcode = 'P0002'; end if;
    nm := sv.name; rs := null;
    def := jsonb_strip_nulls(jsonb_build_object('level', sv.level, 'school', sv.school_id,
      'casting_time', jsonb_build_object('amount', sv.casting_time_amount, 'unit', sv.casting_time_unit), 'reaction_trigger', sv.reaction_trigger,
      'range', jsonb_build_object('type', sv.range_type, 'distance', sv.range_distance, 'unit', sv.range_unit),
      'area', case when sv.area_shape is not null then jsonb_build_object('shape', sv.area_shape, 'size', sv.area_size) end,
      'duration', jsonb_build_object('type', sv.duration_type, 'amount', sv.duration_amount, 'unit', sv.duration_unit),
      'concentration', sv.requires_concentration, 'ritual', sv.is_ritual,
      'components', jsonb_build_object('v', sv.has_verbal_component, 's', sv.has_somatic_component, 'm', sv.has_material_component,
                                       'material', sv.material_text, 'cost_gp', sv.material_cost_gp, 'consumed', sv.material_consumed),
      'attack_type', sv.attack_type, 'save_ability', sv.save_ability, 'higher_levels', sv.parse_notes,
      'class_lists', (select coalesce(jsonb_agg(distinct e.list_id), '[]') from public.class_spell_list_entries e where e.spell_version_id = sv.id),
      'effects', (select coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object('category', e.category, 'timing', e.timing, 'dice', e.dice,
                     'flat', nullif(e.flat_modifier, 0), 'adds_spell_mod', e.adds_spell_mod, 'half_on_save', e.half_on_save,
                     'scaling', case when e.scaling_type <> 'none' then jsonb_build_object('type', e.scaling_type, 'dice', e.scaling_dice, 'base', e.scaling_base) end,
                     'damage_types', (select jsonb_agg(t.damage_type_id) from public.spell_effect_damage_types t where t.version_id = e.version_id and t.seq = e.seq),
                     'notes', e.notes)) order by e.seq), '[]') from public.spell_effects e where e.version_id = sv.id)));
    txt := '';   -- the catalog keeps no spell text (licensing): the DM writes the player text
  when 'item' then
    select * into it from public.v_item_catalog where id = p_ref and owner_id is null;
    if it.id is null then raise exception 'Official item not found' using errcode = 'P0002'; end if;
    nm := it.name; txt := coalesce(it.description, '');
    def := jsonb_build_object('item', jsonb_strip_nulls(jsonb_build_object('kind_id', it.kind_id, 'category_id', it.category_id, 'description', it.description,
             'weight_lb', it.weight_lb, 'cost_value', it.cost_value, 'cost_unit', it.cost_unit, 'rarity_id', it.rarity_id, 'is_magic', it.is_magic,
             'requires_attunement', it.requires_attunement, 'is_consumable', it.is_consumable, 'stackable', it.stackable, 'icon_key', it.icon_key,
             'details', nullif(it.details, '{}'::jsonb))),
      'stats', jsonb_strip_nulls(jsonb_build_object(
        'weapon', case when it.kind_id = 'weapon' then jsonb_strip_nulls(jsonb_build_object('weapon_group', it.weapon_group, 'damage_dice', it.damage_dice,
                    'damage_type_id', it.damage_type_id, 'range_normal', it.range_normal, 'range_max', it.range_max)) end,
        'armor', case when it.kind_id = 'armor' then jsonb_strip_nulls(jsonb_build_object('base_ac', it.base_ac, 'ac_bonus', it.ac_bonus,
                    'dex_modifier_mode', it.dex_modifier_mode, 'dex_cap', it.dex_cap, 'strength_requirement', it.strength_requirement,
                    'stealth_disadvantage', it.stealth_disadvantage)) end,
        'ammunition', case when it.kind_id = 'ammunition' then jsonb_strip_nulls(jsonb_build_object('ammo_type_id', it.ammo_type_id, 'pack_size', it.pack_size)) end)));
  when 'feat' then
    select * into fv from public.feat_versions where id = p_ref and content_version_id is null and owner_id is null;
    if fv.id is null then raise exception 'Official feat not found' using errcode = 'P0002'; end if;
    nm := fv.name; rs := fv.ruleset; summ := fv.summary;
    def := jsonb_strip_nulls(jsonb_build_object('category', fv.category, 'min_level', fv.min_level, 'repeatable', fv.repeatable, 'max_count', fv.max_count,
      'distinct_choice', fv.distinct_choice_key, 'prerequisite_text', fv.prerequisite_text, 'tags', to_jsonb(fv.tags),
      'prerequisites', (select coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object('group', p.grp, 'kind', p.kind, 'target', p.target, 'value', p.value, 'label', p.label)) order by p.seq), '[]')
                        from public.feat_prerequisites p where p.version_id = fv.id),
      'choices', (select coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object('key', ch.key, 'kind', ch.kind, 'label', ch.label, 'min', ch.min_picks, 'max', ch.max_picks,
                     'config', ch.config, 'options', (select jsonb_agg(jsonb_build_object('id', o.option_id, 'label', o.label, 'data', o.data) order by o.seq)
                                                      from public.feat_choice_options o where o.choice_id = ch.id))) order by ch.seq), '[]')
                  from public.feat_choices ch where ch.version_id = fv.id),
      'effects', (select coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object('type', e.effect_type, 'target', e.target, 'value', e.value, 'value_text', e.value_text,
                     'choice', e.choice_key, 'activation', e.activation, 'automation', e.automation, 'conditions', nullif(e.conditions, '{}'::jsonb),
                     'data', nullif(e.data, '{}'::jsonb), 'label', e.label)) order by e.seq), '[]') from public.feat_effects e where e.version_id = fv.id),
      'spells', (select coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object('spell', g.spell_version_id, 'choice', g.choice_key, 'mode', g.mode, 'ability', g.ability,
                     'ability_choice', g.ability_choice_key, 'uses', g.uses, 'uses_slots', g.uses_slots, 'label', g.label)) order by g.seq), '[]')
                 from public.feat_spell_grants g where g.version_id = fv.id),
      'resources', (select coalesce(jsonb_agg(jsonb_build_object('key', r.key, 'name', r.name, 'max', r.max_formula, 'recharge', r.recharge)), '[]')
                    from public.feat_resource_grants r where r.version_id = fv.id)));
  when 'creature' then
    select * into cr from public.creatures where id = p_ref and owner_id is null and content_version_id is null;
    if cr.id is null then raise exception 'Official creature not found' using errcode = 'P0002'; end if;
    nm := cr.name;
    def := jsonb_strip_nulls(jsonb_build_object('size', cr.size, 'creature_type', cr.creature_type, 'subtype', cr.subtype, 'alignment', cr.alignment,
      'armor_class', cr.armor_class, 'armor_type', cr.armor_type, 'hit_points', cr.hit_points, 'hit_dice', cr.hit_dice, 'speed', cr.speed,
      'abilities', cr.abilities, 'saving_throws', cr.saving_throws, 'skills', cr.skills, 'senses', cr.senses, 'languages', cr.languages,
      'challenge_rating', cr.challenge_rating, 'xp', cr.xp, 'proficiency_bonus', cr.proficiency_bonus,
      'damage_vulnerabilities', to_jsonb(cr.damage_vulnerabilities), 'damage_resistances', to_jsonb(cr.damage_resistances),
      'damage_immunities', to_jsonb(cr.damage_immunities), 'condition_immunities', to_jsonb(cr.condition_immunities),
      'traits', cr.traits, 'actions', cr.actions, 'reactions', cr.reactions,
      'wild_shape_eligible', cr.wild_shape_eligible, 'companion_eligible', cr.companion_eligible));
  when 'background' then
    select * into bv from public.background_versions where id = p_ref and content_version_id is null and owner_id is null;
    if bv.id is null then raise exception 'Official background not found' using errcode = 'P0002'; end if;
    nm := bv.name; rs := bv.ruleset;
    def := jsonb_strip_nulls(jsonb_build_object('duplicate_rule', bv.duplicate_rule,
      'abilities', (select jsonb_agg(a.ability) from public.background_ability_options a where a.version_id = bv.id),
      'feat', (select g.feat_id from public.background_feat_grants g where g.version_id = bv.id limit 1),
      'feat_parameter', (select g.parameter from public.background_feat_grants g where g.version_id = bv.id limit 1),
      'skills', (select jsonb_agg(g.target_id order by g.seq) from public.background_proficiency_grants g where g.version_id = bv.id and g.kind = 'skill' and g.target_id is not null),
      'tools', (select jsonb_agg(g.target_id order by g.seq) from public.background_proficiency_grants g where g.version_id = bv.id and g.kind = 'tool' and g.target_id is not null),
      'languages', (select jsonb_agg(g.target_id order by g.seq) from public.background_proficiency_grants g where g.version_id = bv.id and g.kind = 'language' and g.target_id is not null),
      'feature', (select jsonb_build_object('name', f.name, 'summary', f.summary) from public.background_features f where f.version_id = bv.id order by f.key limit 1),
      'equipment', (select jsonb_agg(jsonb_build_object('item_id', e.item_id, 'quantity', e.quantity, 'label', e.label) order by e.seq)
                    from public.background_equipment_packages p join public.background_equipment_entries e on e.package_id = p.id
                    where p.version_id = bv.id and p.key = 'A' and e.item_id is not null),
      'gold', (select (p.coins ->> 'gp')::int from public.background_equipment_packages p where p.version_id = bv.id and p.key = 'B')));
  when 'lineage' then
    select * into lv from public.lineage_versions where id = p_ref and content_version_id is null and owner_id is null;
    if lv.id is null then raise exception 'Official lineage not found' using errcode = 'P0002'; end if;
    nm := lv.name; summ := lv.summary;
    def := jsonb_strip_nulls(jsonb_build_object('creature_type', lv.creature_type,
      'traits', (select coalesce(jsonb_agg(jsonb_build_object('name', t.name, 'summary', t.summary, 'min_level', t.min_level,
                   'effects', (select coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object('type', e.effect_type, 'target', e.target, 'value', e.value,
                                 'value_text', e.value_text, 'min_level', e.min_level, 'data', nullif(e.data, '{}'::jsonb))) order by e.seq), '[]')
                               from public.lineage_trait_effects e where e.trait_id = t.id and e.choice_id is null)) order by t.sort_order), '[]')
                 from public.lineage_traits t where t.version_id = lv.id),
      'ability_patterns', (select ch.config -> 'patterns' from public.lineage_choices ch where ch.version_id = lv.id and ch.kind = 'ability_scores' limit 1),
      'ability_picks', (select ch.pick_count from public.lineage_choices ch where ch.version_id = lv.id and ch.kind = 'ability_scores' limit 1),
      'feat_choice', exists (select 1 from public.lineage_choices ch where ch.version_id = lv.id and ch.kind = 'feat')));
  else
    raise exception 'This content type cannot be duplicated as homebrew' using errcode = '22023';
  end case;
  fields := jsonb_strip_nulls(jsonb_build_object('name', left(nm || ' (homebrew)', 80), 'summary', left(coalesce(summ, ''), 400),
    'player_text', left(coalesce(txt, ''), 4000), 'ruleset', rs, 'definition', def,
    'dm_notes', left('Duplicated from the official ' || p_type || ' "' || nm || '" (' || p_ref || '). Review it, then validate and publish.', 4000)));
  return public.create_dm_content(p_type, p_campaign, fields, null);
end $$;
revoke all on function public.duplicate_official_as_homebrew(text, text, uuid) from public, anon;
grant execute on function public.duplicate_official_as_homebrew(text, text, uuid) to authenticated;

CREATE OR REPLACE FUNCTION public.dm_assign_content(p_content uuid, p_characters uuid[], p_mode text, p_options jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare c public.dm_content; v public.dm_content_versions; ch uuid; out jsonb := '[]'; err text; src uuid; inv uuid; camp uuid; o jsonb := coalesce(p_options, '{}');
begin
  if not public._dm_can_manage(p_content) then raise exception 'Content not found' using errcode = '42501'; end if;
  -- lock order of every content function: the dm_content row first (20261109000300: a concurrent permanent delete holds it
  -- FOR UPDATE; without this share lock the assignment took the version and catalog locks first and the two deadlocked)
  select * into c from public.dm_content where id = p_content for share;
  if c.id is null then raise exception 'Content not found' using errcode = '42501'; end if;
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
