-- =============================================================================
-- Rollback of 20261019000200_change_requests.sql ONLY. Drops change requests (pending proposals are lost, applied
-- changes stay on the characters), their events and private notes, the op registry, update_character_build, the
-- campaign audit read model and the build-change audit triggers. Governance (20261019000100) stays.
-- =============================================================================
begin;

drop trigger if exists character_classes_audit on public.character_classes;
drop trigger if exists character_spells_audit on public.character_spells;
drop trigger if exists character_lineages_audit on public.character_lineages;
drop trigger if exists character_backgrounds_audit on public.character_backgrounds;
drop trigger if exists character_companions_audit on public.character_companions;
drop trigger if exists character_seen_forms_audit on public.character_seen_forms;

do $$
begin
  if exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'change_requests') then
    alter publication supabase_realtime drop table public.change_requests;
  end if;
end $$;

-- tables first: their RLS policies use _cr_can_review
alter table public.campaign_audit_events drop constraint if exists campaign_audit_events_request_fkey;
drop table if exists public.change_request_private_notes, public.change_request_events, public.change_requests, public.change_request_ops;

drop function if exists public.create_change_request(uuid, jsonb, text, text, text, boolean, uuid, uuid), public.add_change_request_op(uuid, jsonb, text),
  public.update_change_request(uuid, jsonb, text, text, text, int), public.submit_change_request(uuid, int),
  public.cancel_change_request(uuid, text), public.preview_change_request(uuid), public.refresh_change_request(uuid),
  public.review_change_request(uuid, text, text, int, jsonb, text), public.retry_change_request(uuid),
  public.get_character_change_requests(uuid, boolean), public.get_campaign_change_requests(uuid, text[], uuid, text, int),
  public.update_character_build(uuid, jsonb), public.get_campaign_audit(uuid, uuid, text[], int, timestamptz),
  public._audit_build_change(), public._cr_apply(uuid), public._cr_mark_stale(uuid), public._cr_event(uuid, text, text, jsonb), public._cr_can_review(uuid),
  public._cr_json(uuid, boolean), public._cr_simulate(uuid, jsonb), public._cr_diff(jsonb, jsonb), public._cr_baseline(uuid),
  public._cr_snapshot(uuid), public._cr_exec_op(uuid, jsonb), public._cr_resolve(uuid, text, text), public._cr_normalize_ops(uuid, jsonb),
  public._cr_normalize_op(uuid, jsonb);


do $$
begin
  if to_regclass('supabase_migrations.schema_migrations') is not null then
    delete from supabase_migrations.schema_migrations where version = '20261019000200';
  end if;
end $$;

commit;
