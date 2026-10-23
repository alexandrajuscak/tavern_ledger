-- ============================================================================================================
-- Tavern Ledger: in-place upgrade PRE-CHECK PACKAGE (read-only)
-- Target: the existing production project. Run in Dashboard -> SQL Editor.
-- Every block is ONE read-only SELECT. Select a block and run it ("Run selected"); the editor shows one result
-- per run. Nothing here writes, locks or changes settings.
-- ============================================================================================================

-- ------------------------------------------------------------------------------------------------------------
-- CHECK 0 - Environment (information)
-- Purpose : PostgreSQL version, pgcrypto location, whether a migration history exists yet.
-- Expected: PostgreSQL 15.x or 17.x; pgcrypto installed (normally in schema "extensions");
--           migration_history = false (legacy schema.sql was run by hand).
-- GO      : pgcrypto installed. migration_history false, or true with 0 rows.
-- NO-GO   : pgcrypto missing; or a migration history with rows (the CLI would think migrations ran).
-- ------------------------------------------------------------------------------------------------------------
select version() as postgres,
       (select e.extversion || ' in ' || n.nspname from pg_extension e join pg_namespace n on n.oid = e.extnamespace where e.extname = 'pgcrypto') as pgcrypto,
       to_regclass('supabase_migrations.schema_migrations') is not null as migration_history,
       (select count(*) from pg_class where relname = 'schema_migrations' and relnamespace = (select oid from pg_namespace where nspname = 'supabase_migrations')) as history_tables;

-- ------------------------------------------------------------------------------------------------------------
-- CHECK 1a - Schema fingerprint (one hash)
-- Purpose : proves the live public schema equals supabase/schema.sql = migration 20261015000000_base_schema.sql
--           (columns, constraints, RLS policies incl. the 3 portrait storage policies, app functions;
--           extension-owned functions are excluded). Verified identical on PostgreSQL 15 and Supabase PostgreSQL 17.
-- Expected: 16691ac5da028e0d60c85d7326d2d4d3
-- GO      : exactly that hash.
-- NO-GO   : any other hash -> do NOT upgrade yet; run CHECK 1b and send its output for a line-by-line diff
--           (small drift can be converged by re-running the idempotent baseline; extra policies must be reviewed).
-- ------------------------------------------------------------------------------------------------------------
select md5(string_agg(k || ' ' || v, E'\n' order by k, v)) as fingerprint from (
  select 'column' k, format('%s.%s %s null=%s default=%s', table_name, column_name, data_type, is_nullable, coalesce(column_default, '-')) v
    from information_schema.columns where table_schema = 'public'
  union all select 'constraint', format('%s %s %s', conrelid::regclass, conname, pg_get_constraintdef(oid))
    from pg_constraint where connamespace = 'public'::regnamespace
  union all select 'policy', format('%s.%s %s %s using=%s check=%s', schemaname, tablename, policyname, cmd, coalesce(qual, '-'), coalesce(with_check, '-'))
    from pg_policies where schemaname = 'public' or (schemaname = 'storage' and policyname like 'portraits%')
  union all select 'function', format('%s(%s) %s', proname, pg_get_function_identity_arguments(oid), md5(prosrc))
    from pg_proc p where pronamespace = 'public'::regnamespace and not exists (select 1 from pg_depend d where d.objid = p.oid and d.deptype = 'e')
) z;

-- ------------------------------------------------------------------------------------------------------------
-- CHECK 1b - Schema fingerprint (detail; run only if 1a differs, then export / copy all rows)
-- Purpose : the full list behind 1a plus triggers, RLS flags, buckets and Realtime tables, for a diff.
-- Expected: 248 rows (column 129, constraint 59, function 11, policy 23, rls 11, trigger 6, realtime 8, bucket 1);
--           realtime/bucket rows may differ legitimately (they are not part of the hash).
-- GO      : (only used for diagnosis)
-- NO-GO   : any extra or missing column / constraint / policy / function line versus the expected list.
-- ------------------------------------------------------------------------------------------------------------
select k, v from (
  select 'column' k, format('%s.%s %s null=%s default=%s', table_name, column_name, data_type, is_nullable, coalesce(column_default, '-')) v
    from information_schema.columns where table_schema = 'public'
  union all select 'constraint', format('%s %s %s', conrelid::regclass, conname, pg_get_constraintdef(oid)) from pg_constraint where connamespace = 'public'::regnamespace
  union all select 'policy', format('%s.%s %s %s using=%s check=%s', schemaname, tablename, policyname, cmd, coalesce(qual, '-'), coalesce(with_check, '-'))
    from pg_policies where schemaname = 'public' or (schemaname = 'storage' and policyname like 'portraits%')
  union all select 'trigger', format('%s %s %s', tgrelid::regclass, tgname, md5(pg_get_triggerdef(oid)))
    from pg_trigger where not tgisinternal and ((select relnamespace from pg_class where oid = tgrelid) = 'public'::regnamespace or tgname = 'on_auth_user_created')
  union all select 'function', format('%s(%s) %s', proname, pg_get_function_identity_arguments(oid), md5(prosrc))
    from pg_proc p where pronamespace = 'public'::regnamespace and not exists (select 1 from pg_depend d where d.objid = p.oid and d.deptype = 'e')
  union all select 'rls', format('%s rls=%s', relname, relrowsecurity) from pg_class where relnamespace = 'public'::regnamespace and relkind = 'r'
  union all select 'bucket', format('%s public=%s limit=%s types=%s', id, public, file_size_limit, allowed_mime_types) from storage.buckets
  union all select 'realtime', format('%s.%s', schemaname, tablename) from pg_publication_tables where pubname = 'supabase_realtime'
) z order by k, v;

-- ------------------------------------------------------------------------------------------------------------
-- CHECK 1c - Name conflicts with the 40 upgrade migrations
-- Purpose : the upgrade creates 141 new tables (plain CREATE TABLE, fails if the name exists). The live public
--           schema must contain only the 11 legacy tables and no views.
-- Expected: 0 rows.
-- GO      : 0 rows.
-- NO-GO   : any row (an unexpected table / view / sequence-less object in public: review before upgrading).
-- ------------------------------------------------------------------------------------------------------------
select c.relname, c.relkind from pg_class c
where c.relnamespace = 'public'::regnamespace and c.relkind in ('r', 'v', 'm', 'p', 'f')
  and c.relname not in ('profiles', 'characters', 'inventory_items', 'notes', 'spell_slots', 'feature_trackers', 'features',
                        'attacks', 'spells', 'campaigns', 'campaign_members')
order by 1;

-- ------------------------------------------------------------------------------------------------------------
-- CHECK 2 - Negative current HP
-- Purpose : migration 20261023000100 adds CHECK (hp_current >= 0) and VALIDATES it; one bad row fails the upgrade.
-- Expected: bad_rows = 0
-- GO      : 0
-- NO-GO   : > 0 -> fix those characters' current HP in the app (set to 0 or more) first, then re-run this check.
-- ------------------------------------------------------------------------------------------------------------
select count(*) as bad_rows, coalesce(string_agg(id::text, ', '), '-') as character_ids
from public.characters where hp_current < 0;

-- ------------------------------------------------------------------------------------------------------------
-- CHECK 3 - Negative coins
-- Purpose : the same migration adds CHECK (cp, sp, ep, gp, pp >= 0) and validates it.
-- Expected: bad_rows = 0
-- GO      : 0
-- NO-GO   : > 0 -> correct the coins of those characters in the app first.
-- ------------------------------------------------------------------------------------------------------------
select count(*) as bad_rows, coalesce(string_agg(id::text, ', '), '-') as character_ids
from public.characters where cp < 0 or sp < 0 or ep < 0 or gp < 0 or pp < 0;

-- ------------------------------------------------------------------------------------------------------------
-- CHECK 4 - Legacy "quest" notes
-- Purpose : the baseline turns kind 'quest' into 'session' and DELETES quest notes of characters that already
--           have a session note (their text would be lost if the baseline has to be re-run).
-- Expected: quest_notes = 0 (the live schema already has the 'session' kind)
-- GO      : quest_notes = 0, or quest_notes_at_risk = 0
-- NO-GO   : quest_notes_at_risk > 0 -> copy that text into the session note first (no automatic merge).
-- ------------------------------------------------------------------------------------------------------------
select count(*) as quest_notes,
       count(*) filter (where content <> '' and exists (select 1 from public.notes s where s.character_id = n.character_id and s.kind = 'session')) as quest_notes_at_risk
from public.notes n where kind = 'quest';

-- ------------------------------------------------------------------------------------------------------------
-- CHECK 5 - Invalid / legacy roles
-- Purpose : profiles.role must be 'player' or 'admin' (the old global 'dm' role became 'admin'); campaign roles
--           must be 'dm' or 'player'. Also confirms at least one admin exists.
-- Expected: bad_profile_roles = 0, bad_campaign_roles = 0, admins >= 1
-- GO      : 0, 0, >= 1
-- NO-GO   : any bad role; or admins = 0 (nobody could manage campaigns after the upgrade).
-- ------------------------------------------------------------------------------------------------------------
select (select count(*) from public.profiles where role not in ('player', 'admin')) as bad_profile_roles,
       (select count(*) from public.campaign_members where role not in ('dm', 'player')) as bad_campaign_roles,
       (select count(*) from public.profiles where role = 'admin') as admins,
       (select count(*) from public.profiles where role = 'player') as players;

-- ------------------------------------------------------------------------------------------------------------
-- CHECK 6 - Users (record the numbers; they must be identical after the upgrade)
-- Purpose : baseline for "no account lost"; Google vs e-mail identities; accounts without a profile.
-- Expected: auth_users = profiles; users_without_profile = 0
-- GO      : users_without_profile = 0
-- NO-GO   : users_without_profile > 0 (the trigger missed someone: they cannot own characters; review first).
-- ------------------------------------------------------------------------------------------------------------
select (select count(*) from auth.users) as auth_users,
       (select count(*) from auth.users where email_confirmed_at is not null) as confirmed,
       (select count(*) from auth.users where last_sign_in_at > now() - interval '30 days') as active_30d,
       (select count(distinct user_id) from auth.identities where provider = 'google') as google_users,
       (select count(distinct user_id) from auth.identities where provider = 'email') as email_users,
       (select count(*) from public.profiles) as profiles,
       (select count(*) from auth.users u where not exists (select 1 from public.profiles p where p.id = u.id)) as users_without_profile;

-- ------------------------------------------------------------------------------------------------------------
-- CHECK 7 - Characters (record; must be identical after the upgrade)
-- Purpose : baseline counts, per owner (e-mail domain only), and the rows the upgrade converts.
-- Expected: characters = your export count; characters_without_campaign as you know it
-- GO      : characters = number of exported files
-- NO-GO   : characters differs from the export count (export again before upgrading).
-- ------------------------------------------------------------------------------------------------------------
select (select count(*) from public.characters) as characters,
       (select count(*) from public.characters where campaign_id is null) as characters_without_campaign,
       (select count(distinct owner_id) from public.characters) as owners,
       (select count(*) from public.inventory_items) as inventory_rows,
       (select count(*) from public.inventory_items where equipped) as equipped_rows,
       (select count(*) from public.inventory_items where quantity = 0) as zero_quantity_rows,
       (select count(*) from public.spells) as legacy_spells,
       (select count(*) from public.attacks) as attacks,
       (select count(*) from public.features) as features,
       (select count(*) from public.feature_trackers) as trackers,
       (select count(*) from public.notes where content <> '') as non_empty_notes,
       (select max(updated_at) from public.characters) as last_character_change;

-- ------------------------------------------------------------------------------------------------------------
-- CHECK 8 - Campaigns (record)
-- Purpose : every campaign becomes a "relaxed" governance table; each needs a DM.
-- Expected: campaigns_without_dm = 0
-- GO      : campaigns_without_dm = 0
-- NO-GO   : campaigns_without_dm > 0 is NOT a blocker for the database, but nobody can approve or manage that
--           table in DM Space: add a DM (admin "Manage" page) before or right after the upgrade.
-- ------------------------------------------------------------------------------------------------------------
select (select count(*) from public.campaigns) as campaigns,
       (select count(*) from public.campaign_members) as memberships,
       (select count(*) from public.campaign_members where role = 'dm') as dm_memberships,
       (select count(*) from public.campaigns c where not exists (select 1 from public.campaign_members m where m.campaign_id = c.id and m.role = 'dm')) as campaigns_without_dm;

-- ------------------------------------------------------------------------------------------------------------
-- CHECK 9 - Portraits (record)
-- Purpose : where character portraits live; uploaded files must be preserved, URLs keep working.
-- Expected: portraits_in_storage + portraits_external + portraits_other = characters_with_portrait
-- GO      : always (information), but note portraits_other
-- NO-GO   : portraits_other > 0 only means unusual values (e.g. data: URLs, relative paths): review, not blocking.
-- ------------------------------------------------------------------------------------------------------------
select count(*) filter (where portrait_url <> '') as characters_with_portrait,
       count(*) filter (where portrait_url like '%/storage/v1/object/public/portraits/%') as portraits_in_storage,
       count(*) filter (where portrait_url ~ '^https?://' and portrait_url not like '%/storage/v1/object/%') as portraits_external,
       count(*) filter (where portrait_url <> '' and portrait_url !~ '^https?://') as portraits_other
from public.characters;

-- ------------------------------------------------------------------------------------------------------------
-- CHECK 10a - Storage buckets
-- Purpose : the upgrade re-asserts bucket "portraits" (public, 2 MB, jpeg/png/webp); other buckets are untouched.
-- Expected: exactly one row: portraits | true | 2097152 | {image/jpeg,image/png,image/webp}
-- GO      : that row (other buckets are fine, they are listed for information)
-- NO-GO   : portraits missing (the upgrade creates it - not blocking), or different limits you rely on
--           (they will be RESET to 2 MB / jpeg-png-webp: decide before upgrading).
-- ------------------------------------------------------------------------------------------------------------
select b.id, b.public, b.file_size_limit, b.allowed_mime_types,
       (select count(*) from storage.objects o where o.bucket_id = b.id) as objects
from storage.buckets b order by b.id;

-- ------------------------------------------------------------------------------------------------------------
-- CHECK 10b - Portrait files
-- Purpose : files in "portraits" are kept; their first folder must be a character id (the RLS policies rely on it).
-- Expected: orphan_files = 0, bad_path_files = 0
-- GO      : both 0
-- NO-GO   : bad_path_files > 0 -> those files become unreachable for everyone except service tools (review);
--           orphan_files > 0 -> files of deleted characters (harmless, can be cleaned later).
-- ------------------------------------------------------------------------------------------------------------
select count(*) as portrait_files,
       coalesce(sum((o.metadata ->> 'size')::bigint), 0) as total_bytes,
       count(*) filter (where (storage.foldername(o.name))[1] !~ '^[0-9a-f-]{36}$') as bad_path_files,
       count(*) filter (where (storage.foldername(o.name))[1] ~ '^[0-9a-f-]{36}$'
                          and not exists (select 1 from public.characters c where c.id::text = (storage.foldername(o.name))[1])) as orphan_files
from storage.objects o where o.bucket_id = 'portraits';

-- ------------------------------------------------------------------------------------------------------------
-- CHECK 10c - Storage policies
-- Purpose : the upgrade replaces portraits_select / portraits_insert / portraits_delete. Any OTHER policy on
--           storage.objects stays and is combined with them (permissive OR).
-- Expected: exactly portraits_delete, portraits_insert, portraits_select
-- GO      : only those three
-- NO-GO   : any other policy -> review it before upgrading (it could widen access to files).
-- ------------------------------------------------------------------------------------------------------------
select policyname, cmd, roles::text, qual from pg_policies where schemaname = 'storage' and tablename = 'objects' order by 1;

-- ------------------------------------------------------------------------------------------------------------
-- SUMMARY - one row per blocking check (run last; everything above in one table)
-- GO when every "status" is GO.
-- ------------------------------------------------------------------------------------------------------------
select 'pgcrypto installed' as check_name, case when exists (select 1 from pg_extension where extname = 'pgcrypto') then 'GO' else 'NO-GO' end as status
union all select 'no migration history rows yet', case when to_regclass('supabase_migrations.schema_migrations') is null then 'GO'
       else 'REVIEW (history table exists)' end
union all select 'no conflicting objects in public', case when not exists (select 1 from pg_class c where c.relnamespace = 'public'::regnamespace
       and c.relkind in ('r', 'v', 'm', 'p', 'f') and c.relname not in ('profiles', 'characters', 'inventory_items', 'notes', 'spell_slots',
       'feature_trackers', 'features', 'attacks', 'spells', 'campaigns', 'campaign_members')) then 'GO' else 'NO-GO' end
union all select 'no negative current HP', case when not exists (select 1 from public.characters where hp_current < 0) then 'GO' else 'NO-GO' end
union all select 'no negative coins', case when not exists (select 1 from public.characters where cp < 0 or sp < 0 or ep < 0 or gp < 0 or pp < 0) then 'GO' else 'NO-GO' end
union all select 'no quest notes at risk', case when not exists (select 1 from public.notes n where kind = 'quest' and content <> ''
       and exists (select 1 from public.notes s where s.character_id = n.character_id and s.kind = 'session')) then 'GO' else 'NO-GO' end
union all select 'valid profile roles', case when not exists (select 1 from public.profiles where role not in ('player', 'admin')) then 'GO' else 'NO-GO' end
union all select 'valid campaign roles', case when not exists (select 1 from public.campaign_members where role not in ('dm', 'player')) then 'GO' else 'NO-GO' end
union all select 'at least one admin', case when exists (select 1 from public.profiles where role = 'admin') then 'GO' else 'NO-GO' end
union all select 'every user has a profile', case when not exists (select 1 from auth.users u where not exists (select 1 from public.profiles p where p.id = u.id)) then 'GO' else 'NO-GO' end
union all select 'only portrait storage policies', case when not exists (select 1 from pg_policies where schemaname = 'storage' and tablename = 'objects'
       and policyname not in ('portraits_select', 'portraits_insert', 'portraits_delete')) then 'GO' else 'NO-GO' end
union all select 'portrait files in character folders', case when not exists (select 1 from storage.objects o where o.bucket_id = 'portraits'
       and (storage.foldername(o.name))[1] !~ '^[0-9a-f-]{36}$') then 'GO' else 'NO-GO' end;
