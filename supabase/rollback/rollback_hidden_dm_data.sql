-- =============================================================================
-- Rollback of 20261019000500_hidden_dm_data.sql ONLY. Drops secret notes, character conditions, item knowledge and item
-- secrets (unidentified instances keep their disguised name; rename them by hand if needed), restores the item read
-- policy and the plain item / condition helpers of 20261019000400. Run rollback_dm_read_models.sql first.
-- =============================================================================
begin;

do $$
begin
  if to_regprocedure('public.get_dm_party(uuid,uuid[])') is not null then raise exception 'run rollback_dm_read_models.sql first'; end if;
end $$;

drop trigger if exists dm_content_versions_item_secrets on public.dm_content_versions;
do $$
begin
  if exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'character_conditions') then
    alter publication supabase_realtime drop table public.character_conditions;
  end if;
end $$;

drop function if exists public.save_dm_note(uuid, text, text, uuid, text), public.delete_dm_note(uuid), public.reveal_dm_note(uuid),
  public.remove_character_condition(uuid), public.reveal_character_condition(uuid), public.set_condition_dm_note(uuid, text),
  public.get_character_conditions(uuid), public.set_item_knowledge(uuid, text, text[], boolean), public.set_item_secrets(text, jsonb),
  public.get_character_item_knowledge(uuid), public.get_dm_character_hidden(uuid), public.get_character_revealed_notes(uuid),
  public.export_campaign_dm_backup(uuid), public._dm_hidden_gate(uuid), public._dm_item_secrets_sync();

drop policy "items_read" on public.items;
create policy "items_read" on public.items for select to anon, authenticated using (public.can_view_owned(owner_id, campaign_id));
create or replace function public.can_view_item(p_item text)
returns boolean
language sql stable security definer
set search_path = public, pg_temp
as $$ select exists (select 1 from public.items i where i.id = p_item and public.can_view_owned(i.owner_id, i.campaign_id)); $$;
drop function if exists public._item_visible(text, uuid, uuid, boolean);

drop table if exists public.inventory_item_knowledge, public.item_secrets, public.character_condition_secrets, public.character_conditions,
  public.dm_character_notes;
alter table public.items drop column secret;

-- the plain helpers of 20261019000400
create or replace function public._dm_add_item(p_inventory uuid, p_item text, p_quantity int, p_custom_name text, p_identified boolean, p_version uuid)
returns uuid
language plpgsql security definer
set search_path = public, pg_temp
as $$ begin return public.add_inventory_item(p_inventory, p_item, greatest(coalesce(p_quantity, 1), 1), p_custom_name); end; $$;
create or replace function public.apply_character_condition(p_character uuid, p_version uuid, p_name text, p_hidden boolean, p_expires timestamptz, p_note text)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$ begin raise exception 'Character conditions need migration 20261019000500' using errcode = '0A000'; end; $$;

do $$
begin
  if to_regclass('supabase_migrations.schema_migrations') is not null then
    delete from supabase_migrations.schema_migrations where version = '20261019000500';
  end if;
end $$;

commit;
