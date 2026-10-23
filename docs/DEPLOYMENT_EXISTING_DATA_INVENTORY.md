# Deployment: existing production data inventory (Phase B, 2026-10-23)

**Status: BLOCKED on access.** The anonymous key reads nothing (HTTP 401 on every table), which is correct. The counts
below need the read-only query in the Dashboard SQL editor, or a read-only database session
(docs/DEPLOYMENT_CURRENT_SUPABASE.md).

## What exists in the legacy schema

Production runs the legacy `supabase/schema.sql` (HEAD `849d7f1`). That schema has **no** catalog tables:
- class, race, background and subclass are free text on `characters`;
- inventory is free-text items;
- spells are free-text rows.

Most of the V6 domains (lineages, backgrounds, feats, spell sources, class choices, resources, companions, infusions,
transformations, Wild Shape, custom content, hidden DM data, approvals, audit) **do not exist** in production, so there
is nothing to inventory for them.

| Legacy table | Domain | Classification for the rebuild |
|---|---|---|
| `auth.users` | identities | **Auth identity: explicit decision** (docs/DEPLOYMENT_AUTH_USER_PLAN.md) |
| `profiles` | display name, role (`player` / `admin` / legacy `dm`) | recreate (automatic on sign-up; the admin role is set once) |
| `characters` | sheet: identity, scores, HP, AC, coins, proficiencies, conditions, pending choices | **export through the app** (the legacy *Download JSON* on the Bio tab) |
| `attacks`, `features`, `feature_trackers`, `spells`, `spell_slots`, `notes` | per-character rows | inside each character export |
| `inventory_items` | free-text items | inside each character export; becomes custom / legacy items on import |
| `campaigns`, `campaign_members` | tables and membership | **recreate manually** (names, members, DM): a handful of rows |
| `storage.objects` | portraits (if any were uploaded) | preserve in the backup; re-upload by hand if wanted |
| Hidden DM data | does not exist in the legacy schema | nothing to preserve (docs/DEPLOYMENT_DM_SECRET_DATA_PLAN.md) |
| Runtime state (current HP, slots used, conditions) | inside characters | **not worth migrating**: the reimport policy restores to full (docs/DEPLOYMENT_CHARACTER_REIMPORT_PLAN.md) |

## Read-only count query (paste into Dashboard → SQL editor; it changes nothing)

```sql
begin transaction read only;
select 'auth.users' as t, count(*) from auth.users
union all select 'auth.users confirmed', count(*) from auth.users where email_confirmed_at is not null
union all select 'auth.identities google', count(*) from auth.identities where provider = 'google'
union all select 'profiles', count(*) from public.profiles
union all select 'profiles admin', count(*) from public.profiles where role = 'admin'
union all select 'characters', count(*) from public.characters
union all select 'campaigns', count(*) from public.campaigns
union all select 'campaign_members', count(*) from public.campaign_members
union all select 'inventory_items', count(*) from public.inventory_items
union all select 'attacks', count(*) from public.attacks
union all select 'features', count(*) from public.features
union all select 'feature_trackers', count(*) from public.feature_trackers
union all select 'spells', count(*) from public.spells
union all select 'spell_slots', count(*) from public.spell_slots
union all select 'notes (non-empty)', count(*) from public.notes where content <> ''
union all select 'storage.objects', count(*) from storage.objects
union all select 'supabase_migrations', (select count(*) from information_schema.tables where table_schema = 'supabase_migrations')
union all select 'public tables', count(*) from information_schema.tables where table_schema = 'public';
-- characters per owner (no names of other people; e-mail domains only)
select split_part(u.email, '@', 2) as owner_domain, count(c.*) as characters
from auth.users u left join public.characters c on c.owner_id = u.id group by 1 order by 2 desc;
rollback;
```

Fill in after the query has run:

| Item | Count | Status |
|---|---|---|
| Auth users | – | REQUIRES USER INPUT |
| Characters | – | REQUIRES USER INPUT |
| Campaigns / members | – | REQUIRES USER INPUT |
| Storage objects | – | REQUIRES USER INPUT |
