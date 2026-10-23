# Deployment: Auth user plan (2026-10-23)

> **Superseded (2026-10-23):** production is upgraded **in place** (existing project, accounts and Google sign-in kept). Follow [DEPLOYMENT_INPLACE_UPGRADE_RUNBOOK.md](DEPLOYMENT_INPLACE_UPGRADE_RUNBOOK.md). This document describes the earlier new-project plan and is kept for reference (its seed, Auth and frontend details still apply).

## Known about the current project

- Providers: **email/password** and **Google**. Public sign-up **enabled**, email confirmation **required**.
- The number of accounts, which are real players and which account is the DM / admin: **unknown** until the inventory
  query runs (docs/DEPLOYMENT_EXISTING_DATA_INVENTORY.md).
- Password-reset flow: the app has no reset screen of its own. Supabase's reset e-mail returns to the Site URL, and SMTP is
  unknown (REQUIRES DASHBOARD CHECK).

## Options

| | A: keep the existing Auth users (rebuild only the app schema) | B: new project, users sign up / are invited again | C: staging first, then deliberate production users |
|---|---|---|---|
| Fits strategy | Rebuild B | Rebuild **A** | Rebuild **A** (with B for production) |
| Password hashes | stay where they are | never copied: people set a password or use Google again | as B |
| Ownership after import | the importer owns the character; reassigning to the right player needs the DM/admin owner field in the import dialog | the same | the same |

**Never:** copy password hashes, insert into `auth.users` with SQL, or reuse `local-dev-password` / demo accounts.

## Recommendation: **C (staging first) + B (production)**

1. **Staging:** two synthetic accounts, e.g. `staging-dm@…` and `staging-player@…`, created through the Dashboard
   ("Add user" → "Create new user", with a strong generated password) or by invitation. They are deleted after the
   sign-off.
2. **Production:**
   - The **DM account** is created first, through sign-up or invitation, with a strong unique password or Google sign-in,
     and MFA if the account is also the Supabase project owner (Dashboard MFA is separate from app MFA).
   - The **admin role** is set once in the SQL editor: `update public.profiles set role = 'admin' where email = '<dm e-mail>';`
     (the base migration allows this from the SQL editor only).
   - **Players** are invited (Dashboard → Authentication → Users → Invite) or sign up with Google. **Public sign-up is turned
     off** after the table's accounts exist (Dashboard → Authentication → Sign In / Providers → "Allow new users to sign up").
     That keeps the hosted catalog away from strangers, which matters for the licensing gate.
   - Each player signs in once; the DM adds them to the campaign.
3. **Google sign-in** in the new project needs the Google OAuth client ID and secret entered in the Dashboard. The user
   does that; the values never pass through this repository. The authorised redirect URI is
   `https://<new-ref>.supabase.co/auth/v1/callback`.

## Questions for the user

1. Which accounts exist today, and which belong to real people who must keep playing?
2. Is Google sign-in still wanted?
3. Is a custom SMTP sender configured, or should invitations and resets use the default mailer (low rate limits)?
