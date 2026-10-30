-- Tavern Ledger architecture review 2026-10-30: READ-ONLY live-database evidence (docs/LIVE_DATABASE_ARCHITECTURE_EVIDENCE.md).
-- SELECT only; aggregates only (no e-mail, no name, no note, no user id). Returns ONE JSON value.
-- Companion of scripts/incident/readonly_evidence.sql (connections, catalog counts, top statements).
select jsonb_pretty(jsonb_build_object(
  'taken_at', now(),
  'version', current_setting('server_version'),
  'settings', (select jsonb_object_agg(name, setting || coalesce(unit, '')) from pg_settings where name in
     ('max_connections', 'shared_buffers', 'work_mem', 'effective_cache_size', 'maintenance_work_mem', 'max_worker_processes',
      'max_parallel_workers', 'track_functions', 'track_io_timing', 'random_page_cost', 'jit', 'default_transaction_isolation')),
  'database_bytes', pg_database_size(current_database()),
  'schema_bytes', (select jsonb_object_agg(nspname, b) from (
      select n.nspname, sum(pg_total_relation_size(c.oid)) as b from pg_class c join pg_namespace n on n.oid = c.relnamespace
      where c.relkind in ('r', 'm', 'p') group by 1 order by 2 desc limit 12) x),
  'largest_tables', (select jsonb_agg(x order by x.total_bytes desc) from (
      select n.nspname || '.' || c.relname as t, pg_total_relation_size(c.oid) as total_bytes, pg_relation_size(c.oid) as heap_bytes,
             pg_indexes_size(c.oid) as index_bytes, c.reltuples::bigint as est_rows
      from pg_class c join pg_namespace n on n.oid = c.relnamespace
      where c.relkind = 'r' and n.nspname not in ('pg_catalog', 'information_schema')
      order by pg_total_relation_size(c.oid) desc limit 25) x),
  'public_tables', (select count(*) from pg_tables where schemaname = 'public'),
  'public_functions', (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public'),
  'public_views', (select count(*) from pg_views where schemaname = 'public'),
  'public_policies', (select count(*) from pg_policies where schemaname = 'public'),
  'security_definer_functions', (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.prosecdef),
  'counts', jsonb_build_object(
    'auth_users', (select count(*) from auth.users),
    'auth_users_confirmed', (select count(*) from auth.users where email_confirmed_at is not null),
    'auth_users_signed_in_30d', (select count(*) from auth.users where last_sign_in_at > now() - interval '30 days'),
    'auth_identities_by_provider', (select jsonb_object_agg(provider, n) from (select provider, count(*) n from auth.identities group by 1) x),
    'auth_sessions', (select count(*) from auth.sessions),
    'auth_mfa_factors', (select count(*) from auth.mfa_factors),
    'characters', (select count(*) from public.characters),
    'characters_in_campaign', (select count(*) from public.characters where campaign_id is not null),
    'campaigns', (select count(*) from public.campaigns),
    'campaign_members', (select count(*) from public.campaign_members),
    'character_classes', (select count(*) from public.character_classes),
    'max_classes_per_char', (select max(n) from (select count(*) n from public.character_classes group by character_id) x),
    'inventory_items_rows', (select count(*) from public.inventory_items),
    'items_total', (select count(*) from public.items), 'items_custom', (select count(*) from public.items where owner_id is not null),
    'character_spells', (select count(*) from public.character_spells),
    'change_requests', (select count(*) from public.change_requests),
    'storage_objects', (select count(*) from storage.objects),
    'storage_bytes', (select coalesce(sum((metadata ->> 'size')::bigint), 0) from storage.objects)),
  'audit_like_tables', (select jsonb_object_agg(relname, n_live_tup) from pg_stat_user_tables
      where schemaname = 'public' and (relname like '%audit%' or relname like '%history%' or relname like '%log%' or relname like '%event%')),
  'cache_hit_pct', (select round(100.0 * sum(heap_blks_hit) / nullif(sum(heap_blks_hit) + sum(heap_blks_read), 0), 2) from pg_statio_user_tables),
  'index_hit_pct', (select round(100.0 * sum(idx_blks_hit) / nullif(sum(idx_blks_hit) + sum(idx_blks_read), 0), 2) from pg_statio_user_indexes),
  'db_stats', (select jsonb_build_object('xact_commit', xact_commit, 'xact_rollback', xact_rollback, 'temp_files', temp_files,
      'temp_bytes', temp_bytes, 'deadlocks', deadlocks, 'conflicts', conflicts, 'stats_reset', stats_reset)
      from pg_stat_database where datname = current_database()),
  'seq_scan_heavy_tables', (select jsonb_agg(x order by x.seq_tup_read desc) from (
      select relname as t, seq_scan, seq_tup_read, idx_scan, n_live_tup, n_dead_tup
      from pg_stat_user_tables where schemaname = 'public' order by seq_tup_read desc limit 15) x),
  'dead_tuple_tables', (select jsonb_agg(x order by x.n_dead_tup desc) from (
      select relname as t, n_live_tup, n_dead_tup, round(100.0 * n_dead_tup / nullif(n_live_tup + n_dead_tup, 0), 1) as dead_pct,
             last_autovacuum is not null as autovacuumed, last_autoanalyze is not null as autoanalyzed
      from pg_stat_user_tables where schemaname = 'public' and n_dead_tup > 0 order by n_dead_tup desc limit 10) x),
  'unused_public_indexes', (select count(*) from pg_stat_user_indexes s join pg_index i on i.indexrelid = s.indexrelid
      where s.schemaname = 'public' and s.idx_scan = 0 and not i.indisprimary and not i.indisunique),
  'public_index_bytes', (select sum(pg_relation_size(indexrelid)) from pg_stat_user_indexes where schemaname = 'public'),
  'function_stats_available', (select count(*) from pg_stat_user_functions),
  'pgss_reset', (select stats_reset from extensions.pg_stat_statements_info),
  'pgss_rpc', (select jsonb_agg(x order by x.total_ms desc) from (
      select substring(s.query from 'public\.([a-z_0-9]+)\(') as fn, sum(s.calls) as calls, round(sum(s.total_exec_time)) as total_ms,
             round(sum(s.total_exec_time) / nullif(sum(s.calls), 0)) as mean_ms, round(max(s.max_exec_time)) as max_ms,
             round(max(s.stddev_exec_time)) as stddev_ms, round(min(s.min_exec_time)) as min_ms
      from extensions.pg_stat_statements s join pg_roles r on r.oid = s.userid
      where r.rolname = 'authenticated' and s.query ~ 'public\.[a-z_0-9]+\('
      group by 1 order by 3 desc limit 40) x),
  'pgss_by_role', (select jsonb_object_agg(rolname, jsonb_build_object('calls', c, 'total_s', t)) from (
      select r.rolname, sum(s.calls) c, round(sum(s.total_exec_time) / 1000) t
      from extensions.pg_stat_statements s join pg_roles r on r.oid = s.userid group by 1) x),
  'pgss_over_5s_count', (select count(*) from extensions.pg_stat_statements where max_exec_time > 5000),
  'realtime_publication_tables', (select jsonb_agg(schemaname || '.' || tablename) from pg_publication_tables where pubname = 'supabase_realtime'),
  'realtime_subscriptions_now', (select count(*) from realtime.subscription),
  'realtime_clients_now', (select count(distinct subscription_id) from realtime.subscription),
  'connections_now', (select jsonb_object_agg(k, n) from (select coalesce(usename::text, '(bg)') || ':' || coalesce(state, '-') k, count(*) n
      from pg_stat_activity group by 1) x),
  'extensions', (select jsonb_agg(extname || ' ' || extversion order by extname) from pg_extension),
  'migrations', (select count(*) from supabase_migrations.schema_migrations),
  'last_migration', (select max(version) from supabase_migrations.schema_migrations)
)) as evidence;
