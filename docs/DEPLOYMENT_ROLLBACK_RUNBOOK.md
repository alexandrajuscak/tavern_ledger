# Deployment: rollback runbook

Use the runbook; do not improvise destructive steps under pressure. Under Strategy A the old project is **never modified**,
so every rollback below is non-destructive.

## Triggers (stop, then roll back if not fixable in minutes)

- a migration fails;
- RLS fails;
- hidden data leaks;
- Auth fails;
- the wrong project is targeted;
- demo seeds appear;
- catalog counts are materially wrong (see docs/DEPLOYMENT_PRODUCTION_SEEDS.md);
- the frontend points to staging or localhost;
- a pilot import corrupts a character;
- existing users cannot sign in;
- the recovery backup is invalid;
- unexpected production data is present.

## R1: frontend rollback (seconds to a few minutes)

The previous production frontend is commit `849d7f1`, which points at the old, untouched project.

```bash
git revert --no-edit <release-commit>      # creates a new commit restoring the 849d7f1 tree; no history rewrite
git push origin main                       # Pages redeploys (watch: gh run list --workflow pages-build-deployment)
```

Check:
- `curl -s https://alexandrajuscak.github.io/tavern_ledger/js/config.js` shows the old project URL;
- signing in to the old app works.

Players can keep using the legacy app right away. Their old characters are still there.

## R2: the new production database is wrong

The new project holds only catalog data plus whatever was imported in Phase G, and every character has a file
(exported before and after import).

1. R1 (switch the frontend back).
2. Either fix forward on the new project (a new migration, tested locally and on staging first), or recreate it: delete
   and re-create the **new** project only, then reapply the migrations and seeds per the production runbook.
3. Never touch the old project during this.

## R3: the old project (only if it was damaged, which Strategy A never does)

Restore into a **new** project from `old-prod-full.dump` (recovery package):

```
pg_restore --no-owner --dbname "<new project session-pooler connection>" old-prod-full.dump
```

Then point the legacy frontend (`849d7f1`) at it with a one-line `js/config.js` change. Auth users are not in `public`.
Restoring `auth` needs Supabase support / a platform backup; the character files remain the fallback.

## R4: the character data of one person

Re-import their file from `original\` (pre-deploy) or from the post-import exports, then delete the broken copy.
