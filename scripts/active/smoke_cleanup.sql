-- Removes every synthetic object of the active features / content management production smoke
-- (supabase/tests/browser/production_active_features_smoke.py), the Combat Builder smoke and of
-- scripts/fluent/smoke_users.sql (all runs): smoke-fl-*@example.test accounts only. Never touches any other row.
-- Order (foreign keys): characters (inventories, transformations, revisions, cache rows, notes cascade), the smoke users' own
-- items (items.owner_id is RESTRICT; homebrew events and provenance cascade), their DM content and creatures (RESTRICT), the
-- smoke campaigns (encounters, participants, effects, events, change log, audit events cascade), then the accounts (profiles,
-- identities, sessions, favorites cascade). Prints what was removed and what is left (every "left" count must be 0).
begin;
create temp table _smoke_users on commit drop as select id from auth.users where email like 'smoke-fl-%@example.test';
create temp table _smoke_camps on commit drop as
  select id from public.campaigns where created_by in (select id from _smoke_users) and name like 'Smoke FL %';
with d as (delete from public.characters where owner_id in (select id from _smoke_users) returning 1) select 'characters removed', count(*) from d;
with d as (delete from public.items where owner_id in (select id from _smoke_users) or campaign_id in (select id from _smoke_camps) returning 1)
select 'items removed', count(*) from d;
with d as (delete from public.dm_content where author_id in (select id from _smoke_users) or campaign_id in (select id from _smoke_camps) returning 1)
select 'dm content removed', count(*) from d;
with d as (delete from public.creatures where owner_id in (select id from _smoke_users) or campaign_id in (select id from _smoke_camps) returning 1)
select 'creatures removed', count(*) from d;
with d as (delete from public.combat_encounters where campaign_id in (select id from _smoke_camps) returning 1) select 'encounters removed', count(*) from d;
-- campaign custom catalog rows of the smoke DM (feats, backgrounds, lineages, creatures cascade with the campaign; spells with the owner)
with d as (delete from public.catalog_spells where owner_id in (select id from _smoke_users) returning 1) select 'custom spells removed', count(*) from d;
with d as (delete from public.campaigns where id in (select id from _smoke_camps) returning 1) select 'campaigns removed', count(*) from d;
with d as (delete from auth.users where id in (select id from _smoke_users) returning 1) select 'accounts removed', count(*) from d;
select 'left', (select count(*) from auth.users where email like 'smoke-fl-%@example.test')
  + (select count(*) from public.profiles where id in (select id from _smoke_users))
  + (select count(*) from public.characters where name like 'Smoke FL %')
  + (select count(*) from public.campaigns where name like 'Smoke FL %')
  + (select count(*) from public.items where name like 'Smoke root %' or name like 'Smoke tonic %')
  + (select count(*) from public.combat_encounters where name like 'Smoke fight %')
  + (select count(*) from public.combat_monster_favorites where user_id in (select id from _smoke_users))
  + (select count(*) from public.feat_versions where name like '% (homebrew)' and campaign_id is not null and owner_id in (select id from _smoke_users))
  + (select count(*) from public.spell_versions where name like 'Smoke Ember %')
  + (select count(*) from public.dm_content where name like 'Smoke Ember %' or (name like '% (homebrew)' and author_id in (select id from _smoke_users)));
commit;
