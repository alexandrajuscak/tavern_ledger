# Deployment: migration and clean-rebuild strategy (2026-10-23)

> **Superseded (2026-10-23):** production is upgraded **in place** (existing project, accounts and Google sign-in kept). Follow [DEPLOYMENT_INPLACE_UPGRADE_RUNBOOK.md](DEPLOYMENT_INPLACE_UPGRADE_RUNBOOK.md). This document describes the earlier new-project plan and is kept for reference (its seed, Auth and frontend details still apply).

## Facts that decide it

1. Production runs the **legacy 11-table schema** (`supabase/schema.sql`). V6.2 is **41 migrations** on a different
   model (catalogs, class engine, governance, …). `20261015000000_base_schema` *can* upgrade the legacy tables. But that
   path was never tested against real legacy data, and the user does not need it: characters are exported and
   re-imported.
2. The live frontend (`849d7f1`) only works with the legacy schema, and the V6.2 frontend only works with the V6.2
   schema. **The database and the frontend must switch together.**
3. The current project has email + Google sign-in and public sign-up. The number of real accounts is unknown, probably
   small (one table).
4. Character exports from the legacy app are the migration vehicle. Their format is understood by the V6.2 importer
   (`parseCharacterJson`, schema version 1); a local pilot with the user's own legacy files is part of the rehearsal.

## Strategies

| | A: new hosted project | B: rebuild the existing project's schema | C: in-place migration |
|---|---|---|---|
| Old data during and after | **untouched**: the old project stays as it is (the strongest recovery package) | deleted / replaced after backup | upgraded in place |
| Destructive production step | **none** (the old project is only retired later, by the user's choice) | drop and recreate `public` objects | none, but irreversible schema changes |
| Auth users | re-register / invite (email + Google need configuring again) | kept | kept |
| Project URL / key | new, changed in `js/config.js` | same | same |
| Frontend rollback | revert the release commit: the old site points at the old, intact project | needs a DB restore too | needs a DB restore too |
| Clean of legacy leftovers (`dm` roles, old triggers, free-text rows) | yes | mostly | no |
| Risk | lowest | high (schema ownership, Auth triggers, storage policies) | medium-high (untested upgrade path) |
| Cost | possibly a second paid project while both exist (Free plan: max. 2 active projects) | none | none |

## Recommendation: **Strategy A**

A new project removes every destructive step from production. The old project remains, untouched, as a live and
restorable copy. Rollback is a single frontend revert. The only cost is that accounts are created again. For a private
table with a few people, that is cheaper than the risk of Strategy B. Strategy B would be preferable only if many
accounts had to keep their identities; that is not the case as far as known (to be confirmed by the inventory count).

### Sequence under Strategy A

1. Phase C: export every character from the **old** app; logical backup of the old project (read-only).
2. Phase D: **staging** project (new, separate). Apply the 41 migrations and the 9 catalog seeds, then run the rehearsal.
3. Phase E: show the plan and wait for the approval phrase.
4. Phase F: **production** project (new, empty). Apply the migrations, the seeds and the Auth configuration. Commit and push
   the frontend with the new `js/config.js`.
5. Phase G: the DM account and campaign; pilot import; the remaining characters.
6. The old project: keep it (paused, or as it is) until the user signs off. Deleting it is a separate, later decision and
   is not part of this task.

### Free-plan note

Two active projects at most. Old production + staging is fine. For the new production project, pause or delete
**staging** after its sign-off, or upgrade. The old production project is never the one deleted for this.

## Not chosen

- **B** is kept as a fallback only if the user decides that account continuity matters more than isolation. It then needs
  its own plan (which schemas, triggers, storage policies and grants are dropped; tested on a restored copy first).
- **C** is not needed to preserve characters, and its upgrade path is untested against real data.
