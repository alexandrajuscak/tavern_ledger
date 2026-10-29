-- Tavern Ledger production incident 2026-10-23 (57014 / IncreaseSubscriptionConnectionPool): READ-ONLY evidence.
-- docs/PRODUCTION_INCIDENT_REALTIME_TIMEOUTS.md
--
-- * SELECT only. It changes nothing: no reset of pg_stat_statements, no setting, no terminate, no write.
-- * Returns ONE row with ONE JSON value, because the Dashboard SQL Editor shows only the last result set.
--   Copy the whole value back. It contains aggregates only: no e-mail, no user id, no character name, no note.
-- * Query texts come from pg_stat_statements (normalized: literal values are replaced by $1, $2 ...).
-- * Run it in the Dashboard SQL Editor (role postgres), or: psql "$env:PROD_DB_URL" -X -A -t -f scripts/incident/readonly_evidence.sql
select jsonb_pretty(jsonb_build_object(
  'taken_at', now(),
  'server', jsonb_build_object(
    'version', current_setting('server_version'),
    'max_connections', current_setting('max_connections')::int,
    'statement_timeout_session', current_setting('statement_timeout'),
    'shared_buffers', current_setting('shared_buffers'),
    'work_mem', current_setting('work_mem'),
    'role_statement_timeouts', (select jsonb_object_agg(r.rolname, coalesce(
        (select split_part(c, '=', 2) from unnest(r.rolconfig) c where c like 'statement_timeout=%'), '(default)'))
      from pg_roles r where r.rolname in ('anon', 'authenticated', 'authenticator', 'postgres', 'service_role',
        'supabase_realtime_admin', 'supabase_admin'))),
  -- connections right now
  'connections_total', (select count(*) from pg_stat_activity),
  'connections_by_app_role_state', (select coalesce(jsonb_agg(x order by x.n desc), '[]') from (
      select coalesce(nullif(application_name, ''), '(none)') as app, coalesce(usename::text, '(bg)') as role,
             coalesce(state, '(none)') as state, count(*) as n
      from pg_stat_activity group by 1, 2, 3) x),
  'active_statements', (select coalesce(jsonb_agg(x order by x.running_s desc), '[]') from (
      select coalesce(nullif(application_name, ''), '(none)') as app, usename as role, state,
             round(extract(epoch from now() - query_start)::numeric, 2) as running_s, wait_event_type, wait_event,
             left(regexp_replace(query, '\s+', ' ', 'g'), 160) as query_head
      from pg_stat_activity
      where datname = current_database() and state <> 'idle' and pid <> pg_backend_pid()) x),
  'idle_in_transaction', (select count(*) from pg_stat_activity where state like 'idle in transaction%'),
  'blocked', (select count(*) from pg_stat_activity where cardinality(pg_blocking_pids(pid)) > 0),
  -- Realtime: one row per postgres_changes binding of every connected client
  'realtime_subscriptions_total', (select count(*) from realtime.subscription),
  'realtime_subscriptions_by_table', (select coalesce(jsonb_object_agg(t, n), '{}') from (
      select entity::regclass::text as t, count(*) as n from realtime.subscription group by 1) x),
  'realtime_subscriptions_distinct_clients', (select count(distinct subscription_id) from realtime.subscription),
  'realtime_subscriptions_unfiltered', (select count(*) from realtime.subscription where filters = '{}'),
  'replication_slots', (select coalesce(jsonb_agg(jsonb_build_object('slot', slot_name, 'plugin', plugin, 'active', active,
      'lag_bytes', pg_wal_lsn_diff(pg_current_wal_lsn(), confirmed_flush_lsn))), '[]') from pg_replication_slots),
  -- statement statistics since the last reset (Supabase keeps pg_stat_statements in the extensions schema)
  'pgss_reset', (select stats_reset from extensions.pg_stat_statements_info),
  'pgss_top_by_max', (select coalesce(jsonb_agg(x order by x.max_ms desc), '[]') from (
      select r.rolname as role, s.calls, round(s.max_exec_time) as max_ms, round(s.mean_exec_time) as mean_ms,
             round(s.total_exec_time) as total_ms, s.rows, left(regexp_replace(s.query, '\s+', ' ', 'g'), 220) as query_head
      from extensions.pg_stat_statements s join pg_roles r on r.oid = s.userid
      order by s.max_exec_time desc limit 30) x),
  'pgss_top_by_total', (select coalesce(jsonb_agg(x order by x.total_ms desc), '[]') from (
      select r.rolname as role, s.calls, round(s.max_exec_time) as max_ms, round(s.mean_exec_time) as mean_ms,
             round(s.total_exec_time) as total_ms, s.rows, left(regexp_replace(s.query, '\s+', ' ', 'g'), 220) as query_head
      from extensions.pg_stat_statements s join pg_roles r on r.oid = s.userid
      order by s.total_exec_time desc limit 30) x),
  'pgss_over_5s', (select coalesce(jsonb_agg(x order by x.max_ms desc), '[]') from (
      select r.rolname as role, s.calls, round(s.max_exec_time) as max_ms, round(s.mean_exec_time) as mean_ms,
             left(regexp_replace(s.query, '\s+', ' ', 'g'), 220) as query_head
      from extensions.pg_stat_statements s join pg_roles r on r.oid = s.userid
      where s.max_exec_time > 5000) x),
  -- database-level counters
  'db_stats', (select jsonb_build_object('xact_commit', xact_commit, 'xact_rollback', xact_rollback, 'blks_hit', blks_hit,
      'blks_read', blks_read, 'cache_hit_pct', round(100.0 * blks_hit / nullif(blks_hit + blks_read, 0), 2),
      'temp_files', temp_files, 'deadlocks', deadlocks, 'stats_reset', stats_reset)
      from pg_stat_database where datname = current_database()),
  'checkpoints', (select to_jsonb(c) from pg_stat_checkpointer c),
  -- catalog integrity (expected values: docs/DEPLOYMENT_PRODUCTION_SEEDS.md); never re-import the catalog
  'catalog', jsonb_build_object(
    'items', (select count(*) from public.items), 'items_official', (select count(*) from public.items where owner_id is null),
    'spell_versions', (select count(*) from public.spell_versions), 'class_versions', (select count(*) from public.class_versions),
    'subclass_versions', (select count(*) from public.subclass_versions),
    'class_feature_versions', (select count(*) from public.class_feature_versions),
    'creatures', (select count(*) from public.creatures), 'lineage_versions', (select count(*) from public.lineage_versions),
    'feat_versions', (select count(*) from public.feat_versions), 'feat_versions_official', (select count(*) from public.feat_versions where owner_id is null),
    'source_books', (select count(*) from public.source_books),
    'backgrounds', (select count(*) from public.backgrounds),
    'background_versions', (select count(*) from public.background_versions),
    'background_versions_2024', (select count(*) from public.background_versions where ruleset = '2024'),
    'background_versions_2014', (select count(*) from public.background_versions where ruleset = '2014'),
    'background_versions_default_on', (select count(*) from public.background_versions where enabled_by_default),
    'background_proficiency_grants', (select count(*) from public.background_proficiency_grants),
    'background_choices', (select count(*) from public.background_choices),
    'background_choice_options', (select count(*) from public.background_choice_options),
    'background_features', (select count(*) from public.background_features),
    'background_feat_grants', (select count(*) from public.background_feat_grants),
    'background_equipment_packages', (select count(*) from public.background_equipment_packages),
    'character_backgrounds', (select count(*) from public.character_backgrounds)),
  'game_data', jsonb_build_object('users', (select count(*) from auth.users), 'characters', (select count(*) from public.characters),
    'campaigns', (select count(*) from public.campaigns), 'inventory_items', (select count(*) from public.inventory_items)),
  'migrations', (select count(*) from supabase_migrations.schema_migrations),
  'last_migration', (select max(version) from supabase_migrations.schema_migrations),
  -- payload of the Background picker RPC (size only; runs as postgres, i.e. without RLS cost)
  'background_catalog_bytes', (select octet_length(public.get_background_catalog()::text))
)) as evidence;
