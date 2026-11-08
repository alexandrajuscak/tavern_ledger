-- Feat removal: authoritative, source-aware and idempotent (docs/FEAT_REMOVAL.md).
-- Rollback: supabase/rollback/rollback_feat_removal.sql.
--
-- What changes (no table, no column, no stored row is touched by this migration; set_character_feat_choices is reordered and two
-- revision triggers are added, below):
--   remove_character_feat(uuid, text)      same signature, same result shape. Now
--     * answers an unknown, already removed OR inaccessible feat row with the same friendly 'feat_absent' error (before: an
--       unrelated signed-in user who held a row id got the campaign's governance message, which named the campaign);
--     * checks access BEFORE the governance gate;
--     * locks the character, then re-reads the feat row FOR UPDATE: of two concurrent removals one removes, the other gets
--       'feat_absent' (before: both passed, the second deleted nothing but still wrote a second 'feat_removed' audit event);
--     * removes only rows of character_feats (direct, DM grant, campaign reward, approved request, import). Feats granted by
--       a background, a lineage or a class Ability Score Improvement are not rows of that table: they are changed at their
--       source (the Feats card links there), never deleted here.
--   preview_character_feat_removal(uuid)   NEW, read-only. The feat, its source, the campaign decision for this user and the
--     exact consequences: the removal is executed inside the governance simulator (_cr_simulate) and rolled back, so the diff
--     (maximum HP, Initiative, ability scores, spells, resources, proficiencies, open choices …) comes from the same rules as
--     the real removal. Spells are listed per source: the feat's entry leaves, the same spell from another source stays.
-- Dependent mechanics are unchanged and stay atomic in one transaction: the feat's choice rows (grant key 'cf:<id>') are
-- deleted, then _sync_character_feats reconciles the feat's spell grants and current HP (current HP above the new maximum is
-- lowered to it; it is never raised), and the feat's own resource rows ('cf:<id>', which the sync would only deactivate and which
-- could never become active again) are deleted. Ability bonuses, proficiencies, speed, AC and attacks of a feat are derived
-- from the remaining rows on every read and need no clean-up. The character revision (read cache) is bumped by the existing
-- triggers on character_feats / character_feat_choices; combat snapshots of monsters are not involved.

create or replace function public.remove_character_feat(p_character_feat uuid, p_reason text default null)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare cf public.character_feats; ch uuid; camp uuid; nm text;
begin
  if auth.uid() is null then raise exception 'Sign in to change feats.' using errcode = '42501'; end if;
  select character_id into ch from public.character_feats where id = p_character_feat;
  -- absent, already removed or not yours: one answer, so nothing about another character (or its campaign) is revealed
  if ch is null or not public.can_access_character(ch) then
    raise exception 'This feat is no longer on the character. The sheet shows the current feats.'
      using errcode = 'P0002', hint = 'feat_absent';
  end if;
  perform public._gov_gate(ch, 'choice.feat');
  perform 1 from public.characters where id = ch for update;                 -- lock order: character, then its feat rows
  select * into cf from public.character_feats where id = p_character_feat for update;
  if cf.id is null then                                                        -- another session removed it meanwhile
    raise exception 'This feat is no longer on the character. The sheet shows the current feats.'
      using errcode = 'P0002', hint = 'feat_absent';
  end if;
  select campaign_id into camp from public.characters where id = cf.character_id;
  select name into nm from public.feat_versions where id = cf.feat_version_id;
  delete from public.character_feat_choices where character_id = cf.character_id and grant_key = 'cf:' || cf.id;
  delete from public.character_feats where id = cf.id;
  perform public._sync_character_feats(cf.character_id);
  -- the sync only deactivates the feat's resources (free casts …); keyed to a row that no longer exists they could never be
  -- active again, so they go with the feat (no foreign key refers to character_resources)
  delete from public.character_resources where character_id = cf.character_id and source_type = 'feat' and source_id = 'cf:' || cf.id;
  if camp is not null then
    perform public._audit(camp, cf.character_id, 'feat_removed', 'Feat removed: ' || nm, jsonb_build_object('feat_version_id', cf.feat_version_id),
                          null, p_reason, nullif(current_setting('tavern.gov_apply', true), '')::uuid, 'party');
  end if;
  return public.get_character_feats(cf.character_id);
end;
$$;

create or replace function public.preview_character_feat_removal(p_character_feat uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare cf public.character_feats; g record; dec jsonb; sim jsonb; nm text; d text;
begin
  if auth.uid() is null then raise exception 'Sign in to change feats.' using errcode = '42501'; end if;
  select * into cf from public.character_feats where id = p_character_feat;
  if cf.id is null or not public.can_access_character(cf.character_id) then
    raise exception 'This feat is no longer on the character. The sheet shows the current feats.'
      using errcode = 'P0002', hint = 'feat_absent';
  end if;
  select name into nm from public.feat_versions where id = cf.feat_version_id;
  select * into g from public._character_feat_grants(cf.character_id) x where x.character_feat_id = cf.id limit 1;
  dec := public._gov_decide(cf.character_id, 'choice.feat');
  d := dec ->> 'decision';
  -- the removal itself, executed and rolled back (governance approval is simulated as granted; locks and DM-only still refuse)
  sim := public._cr_simulate(cf.character_id, jsonb_build_array(jsonb_build_object('op', 'remove_character_feat',
           'args', jsonb_build_object('p_character_feat', cf.id))));
  return jsonb_build_object(
    'character_feat_id', cf.id, 'character_id', cf.character_id, 'feat_version_id', cf.feat_version_id, 'feat_name', nm,
    'source_type', cf.source_type, 'source_label', g.source_label, 'removable', true,
    -- allow / player_managed: removed now; approval_required: sent as a request; anything else: refused (message says why)
    'decision', case when d in ('allow', 'player_managed') then 'allow' when d = 'approval_required' then 'approval_required'
                     else 'refused' end,
    'ok', coalesce((sim ->> 'ok')::boolean, false),
    'message', case when (sim ->> 'ok')::boolean then null else sim ->> 'error' end,
    'diff', coalesce(sim -> 'diff', '[]'::jsonb));
end;
$$;

-- set_character_feat_choices(uuid, text, jsonb): same signature, result and rules; two orderings fixed (found by
-- feat_removal_concurrency_test.sh): access is checked before the governance gate (an unrelated caller learnt nothing more than
-- 'not found'), and the grant is looked up AFTER the character lock, so a choice change that waited for a concurrent removal
-- reports 'not granted' instead of storing choice rows for a feat that no longer exists.
create or replace function public.set_character_feat_choices(p_character uuid, p_grant_key text, p_choices jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare g record;
begin
  if auth.uid() is null or not public.can_access_character(p_character) then raise exception 'Character not found' using errcode = '42501'; end if;
  perform 1 from public.characters where id = p_character for update;          -- lock first: a concurrent removal finishes before
  select * into g from public._character_feat_grants(p_character) x where x.grant_key = p_grant_key;
  if g.grant_key is null then raise exception 'This feat is not granted to this character' using errcode = '22023'; end if;
  perform public._gov_gate(p_character, case g.source_type when 'background' then 'build.background' when 'lineage' then 'build.lineage' else 'choice.feat' end);
  perform set_config('tavern.feat_sync', 'off', true);
  perform public._store_feat_choices(p_character, p_grant_key, g.feat_version_id, p_choices, false);
  perform set_config('tavern.feat_sync', '', true);
  perform public._sync_character_feats(p_character);
  return public.get_character_feats(p_character);
end;
$$;

-- Realtime for feats: character_feats and character_feat_choices had no character_revisions trigger, so an open sheet (progressive
-- path: one Realtime table, character_revisions) and the Combat Builder never heard of a feat added, removed or re-chosen in
-- another session unless a side table (spells, resources) changed too. Same trigger function as the other character tables
-- (one revision row per character, table and transaction); the read cache counter (tl_cache_rev) was already present.
drop trigger if exists character_feats_revision on public.character_feats;
create trigger character_feats_revision after insert or delete or update on public.character_feats
  for each row execute function public._bump_character_revision();
drop trigger if exists character_feat_choices_revision on public.character_feat_choices;
create trigger character_feat_choices_revision after insert or delete or update on public.character_feat_choices
  for each row execute function public._bump_character_revision();

revoke all on function public.remove_character_feat(uuid, text), public.preview_character_feat_removal(uuid),
  public.set_character_feat_choices(uuid, text, jsonb) from public, anon;
grant execute on function public.remove_character_feat(uuid, text), public.preview_character_feat_removal(uuid),
  public.set_character_feat_choices(uuid, text, jsonb) to authenticated;
