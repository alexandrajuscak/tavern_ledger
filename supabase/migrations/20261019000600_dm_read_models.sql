-- =============================================================================
-- DM Space read models (docs/DM_SPACE.md): the campaigns a user directs, the campaign overview (urgent work first) and the
-- compact party overview. DM-only; every function checks the campaign role itself.
-- Rollback: supabase/rollback/rollback_dm_read_models.sql.
-- =============================================================================

-- campaigns the user directs (admins: all), with the counts the selector shows
create function public.get_my_dm_campaigns()
returns jsonb
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
begin
  if auth.uid() is null then raise exception 'Not signed in' using errcode = '42501'; end if;
  return (select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'name', c.name,
             'preset', coalesce((select preset from public.campaign_governance where campaign_id = c.id), 'relaxed'),
             'configured', exists (select 1 from public.campaign_governance where campaign_id = c.id),
             'characters', (select count(*) from public.characters ch where ch.campaign_id = c.id),
             'pending', (select count(*) from public.change_requests r where r.campaign_id = c.id and r.status in ('submitted', 'apply_failed')))
           order by c.name), '[]')
          from public.campaigns c
          where public.is_admin() or exists (select 1 from public.campaign_members m where m.campaign_id = c.id and m.user_id = auth.uid() and m.role = 'dm'));
end;
$$;

-- one character row of the party overview (runtime first, permanent build second)
create function public._dm_party_row(p_character uuid)
returns jsonb
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
declare c public.characters; d jsonb; hp jsonb; f jsonb; g public.character_governance; feats jsonb;
begin
  select * into c from public.characters where id = p_character;
  begin
    d := public._derived_stats_full(p_character);
  exception when others then d := '{}';
  end;
  hp := public._feat_hp_bonus(p_character);
  begin
    f := public.get_character_class_features(p_character);
  exception when others then f := '{}';
  end;
  select * into g from public.character_governance where character_id = p_character;
  select coalesce(sum(case when not x.complete and x.open then 1 else 0 end), 0) into feats
  from public._character_feat_choice_values(p_character) x join public._character_feat_grants(p_character) gr on gr.grant_key = x.grant_key and gr.active;
  return jsonb_build_object(
    'id', c.id, 'name', c.name, 'portrait_url', c.portrait_url, 'owner_id', c.owner_id,
    'owner_name', (select coalesce(display_name, email) from public.profiles where id = c.owner_id),
    'classes', (select coalesce(jsonb_agg(jsonb_build_object('class', k.name, 'level', cc.level,
                  'subclass', (select name from public.subclass_versions where id = cc.subclass_version_id)) order by cc.is_primary desc, k.name), '[]')
                from public.character_classes cc join public.classes k on k.id = cc.class_id where cc.character_id = c.id),
    'level', coalesce((select sum(level) from public.character_classes where character_id = c.id), c.level),
    'lineage', d -> 'lineage' ->> 'name', 'background', d -> 'background' ->> 'name',
    'hp', jsonb_build_object('current', c.hp_current, 'max', (hp ->> 'max')::int, 'temp', c.hp_temp),
    'ac', (d -> 'armor_class' ->> 'value')::int,
    'death_saves', jsonb_build_object('successes', c.death_successes, 'failures', c.death_failures),
    'conditions', coalesce(c.conditions, '[]'),
    'campaign_conditions', (select coalesce(jsonb_agg(jsonb_build_object('id', k.id, 'name', k.name, 'hidden', k.hidden, 'expires_at', k.expires_at)
                              order by k.applied_at), '[]') from public.character_conditions k where k.character_id = c.id),
    'active_states', coalesce(d -> 'active_states', '[]'),
    'transformation', (select jsonb_build_object('creature', cr.name, 'hp_current', t.hp_current, 'hp_max', t.hp_max)
                       from public.character_transformations t join public.creatures cr on cr.id = t.creature_id where t.character_id = c.id),
    'companions', (select coalesce(jsonb_agg(jsonb_build_object('name', cc.name, 'hp_current', cc.hp_current, 'hp_max', cc.hp_max, 'active', cc.active)
                     order by cc.created_at), '[]') from public.character_companions cc where cc.character_id = c.id),
    -- resources with uses spent (cheap: stored state only; the sheet shows exact remaining uses)
    'depleted_resources', (select coalesce(jsonb_agg(r.name || ' (' || r.expended || ' used)' order by r.name), '[]') from public.character_resources r
                           where r.character_id = c.id and r.active and r.expended > 0),
    'pending_requests', (select count(*) from public.change_requests r where r.character_id = c.id and r.status in ('submitted', 'apply_failed')),
    'incomplete_choices', coalesce(jsonb_array_length(f -> 'incomplete_choices'), 0) + coalesce(feats::int, 0),
    'lock_mode', coalesce(g.lock_mode, 'unlocked'), 'setup_complete', coalesce(g.setup_complete, false),
    'hidden_notes', (select count(*) from public.dm_character_notes n where n.character_id = c.id and n.revealed_at is null),
    'updated_at', c.updated_at);
end;
$$;

-- p_characters: the rows to compute (the DM Space loads a large party in parallel batches; one row costs ~0.2 s)
create function public.get_dm_party(p_campaign uuid, p_characters uuid[] default null)
returns jsonb
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
begin
  if auth.uid() is null or not (public.is_admin() or public.is_campaign_dm(p_campaign)) then
    raise exception 'Only a DM of this campaign can open its party overview' using errcode = '42501';
  end if;
  return jsonb_build_object('campaign_id', p_campaign,
    'characters', (select coalesce(jsonb_agg(public._dm_party_row(ch.id) order by lower(ch.name)), '[]') from public.characters ch
                   where ch.campaign_id = p_campaign and (p_characters is null or ch.id = any (p_characters))));
end;
$$;

-- urgent work first: pending approvals, failed applications, dying / low characters, open choices, locks, content activity
create function public.get_dm_overview(p_campaign uuid)
returns jsonb
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
begin
  if auth.uid() is null or not (public.is_admin() or public.is_campaign_dm(p_campaign)) then
    raise exception 'Only a DM of this campaign can open its overview' using errcode = '42501';
  end if;
  -- the party part (warnings, forms, conditions, locks) comes from get_dm_party, loaded by the UI in batches
  return jsonb_build_object(
    'campaign', (select jsonb_build_object('id', c.id, 'name', c.name, 'description', c.description) from public.campaigns c where c.id = p_campaign),
    'governance', public._campaign_governance_json(p_campaign) - 'actions',
    'pending', public.get_campaign_change_requests(p_campaign, array['submitted', 'apply_failed'], null, null, 20),
    'counts', jsonb_build_object(
      'characters', (select count(*) from public.characters where campaign_id = p_campaign),
      'pending', (select count(*) from public.change_requests where campaign_id = p_campaign and status = 'submitted'),
      'failed', (select count(*) from public.change_requests where campaign_id = p_campaign and status = 'apply_failed'),
      'returned', (select count(*) from public.change_requests where campaign_id = p_campaign and status = 'returned_for_changes'),
      'content_drafts', (select count(*) from public.dm_content where campaign_id = p_campaign and status in ('draft', 'validation_failed', 'ready_for_review', 'revised')),
      'content_published', (select count(*) from public.dm_content where campaign_id = p_campaign and status = 'published')),
    'character_ids', (select coalesce(jsonb_agg(id order by lower(name)), '[]') from public.characters where campaign_id = p_campaign),
    'recent_content', (select coalesce(jsonb_agg(jsonb_build_object('content_id', e.content_id, 'name', d.name, 'content_type', d.content_type,
                         'event', e.event, 'at', e.created_at) order by e.created_at desc), '[]')
                       from (select * from public.dm_content_events where content_id in (select id from public.dm_content where campaign_id = p_campaign)
                             order by created_at desc limit 8) e join public.dm_content d on d.id = e.content_id),
    'recent_activity', public.get_campaign_audit(p_campaign, null, null, 12, null));
end;
$$;

revoke all on function public._dm_party_row(uuid) from public, anon, authenticated;
revoke all on function public.get_my_dm_campaigns(), public.get_dm_party(uuid, uuid[]), public.get_dm_overview(uuid) from public, anon;
grant execute on function public.get_my_dm_campaigns(), public.get_dm_party(uuid, uuid[]), public.get_dm_overview(uuid) to authenticated;
