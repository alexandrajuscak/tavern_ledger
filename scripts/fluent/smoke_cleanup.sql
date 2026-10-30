-- Removes every synthetic smoke object of smoke_users.sql (all runs): characters (child rows cascade), campaigns, accounts
-- (profiles, identities, sessions cascade). Prints what was removed and what is left (must be 0).
begin;
with u as (select id from auth.users where email like 'smoke-fl-%@example.test'),
     d as (delete from public.characters where owner_id in (select id from u) returning 1)
select 'characters removed', count(*) from d;
with u as (select id from auth.users where email like 'smoke-fl-%@example.test'),
     d as (delete from public.campaigns where created_by in (select id from u) and name like 'Smoke FL %' returning 1)
select 'campaigns removed', count(*) from d;
with d as (delete from auth.users where email like 'smoke-fl-%@example.test' returning 1)
select 'accounts removed', count(*) from d;
select 'left', (select count(*) from auth.users where email like 'smoke-fl-%@example.test')
  + (select count(*) from public.characters where name like 'Smoke FL %') + (select count(*) from public.campaigns where name like 'Smoke FL %');
commit;
