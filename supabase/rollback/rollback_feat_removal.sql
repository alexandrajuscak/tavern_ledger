-- Rollback of 20261107000100_feat_removal.sql: drops preview_character_feat_removal and restores remove_character_feat and
-- set_character_feat_choices exactly and drops the two feat revision triggers it added
-- as it was before (definition captured from the local database on 2026-11-07; same signature and grants). No data changes.
-- Deploy the previous frontend first if the new Feats dialog is live: it calls preview_character_feat_removal and falls back to
-- a plain confirmation when the function is missing, so the order is not critical.
begin;
drop function if exists public.preview_character_feat_removal(uuid);
drop trigger if exists character_feats_revision on public.character_feats;
drop trigger if exists character_feat_choices_revision on public.character_feat_choices;
CREATE OR REPLACE FUNCTION public.remove_character_feat(p_character_feat uuid, p_reason text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare cf public.character_feats; camp uuid; nm text;
begin
  select * into cf from public.character_feats where id = p_character_feat;
  if cf.id is null then raise exception 'Feat not found' using errcode = 'P0002'; end if;
  perform public._gov_gate(cf.character_id, 'choice.feat');
  if auth.uid() is null or not public.can_access_character(cf.character_id) then raise exception 'Feat not found' using errcode = '42501'; end if;
  perform 1 from public.characters where id = cf.character_id for update;
  select campaign_id into camp from public.characters where id = cf.character_id;
  select name into nm from public.feat_versions where id = cf.feat_version_id;
  delete from public.character_feat_choices where character_id = cf.character_id and grant_key = 'cf:' || cf.id;
  delete from public.character_feats where id = cf.id;
  perform public._sync_character_feats(cf.character_id);
  if camp is not null then
    perform public._audit(camp, cf.character_id, 'feat_removed', 'Feat removed: ' || nm, jsonb_build_object('feat_version_id', cf.feat_version_id),
                          null, p_reason, nullif(current_setting('tavern.gov_apply', true), '')::uuid, 'party');
  end if;
  return public.get_character_feats(cf.character_id);
end;
$function$

;
CREATE OR REPLACE FUNCTION public.set_character_feat_choices(p_character uuid, p_grant_key text, p_choices jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare g record;
begin
  select * into g from public._character_feat_grants(p_character) x where x.grant_key = p_grant_key;
  if g.grant_key is null then raise exception 'This feat is not granted to this character' using errcode = '22023'; end if;
  perform public._gov_gate(p_character, case g.source_type when 'background' then 'build.background' when 'lineage' then 'build.lineage' else 'choice.feat' end);
  if auth.uid() is null or not public.can_access_character(p_character) then raise exception 'Character not found' using errcode = '42501'; end if;
  perform 1 from public.characters where id = p_character for update;
  perform set_config('tavern.feat_sync', 'off', true);
  perform public._store_feat_choices(p_character, p_grant_key, g.feat_version_id, p_choices, false);
  perform set_config('tavern.feat_sync', '', true);
  perform public._sync_character_feats(p_character);
  return public.get_character_feats(p_character);
end;
$function$
;
revoke all on function public.remove_character_feat(uuid, text), public.set_character_feat_choices(uuid, text, jsonb) from public, anon;
grant execute on function public.remove_character_feat(uuid, text), public.set_character_feat_choices(uuid, text, jsonb) to authenticated;
commit;
