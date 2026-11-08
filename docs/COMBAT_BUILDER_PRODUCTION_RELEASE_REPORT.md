# Combat Builder production release report (2026-11-08)

In-place production update of the existing Supabase project (`pfgz…wlsc`, PostgreSQL 17.11, Free plan) and the GitHub
Pages site. Plan: [COMBAT_BUILDER_PRODUCTION_PLAN.md](COMBAT_BUILDER_PRODUCTION_PLAN.md). Local evidence:
[COMBAT_BUILDER_FOLLOWUP.md](COMBAT_BUILDER_FOLLOWUP.md), [COMBAT_BUILDER_TESTING.md](COMBAT_BUILDER_TESTING.md).
No secret, connection string, player name, e-mail or hidden value appears in this report.

## Executive result

**Production release deployed successfully and monitoring.**

The Combat Builder is live for campaign DMs (`COMBAT_BUILDER = 'dm'`, `?v=19`). The six additive migrations and the
dedicated SRD monster seed are applied. Every existing user, character, campaign, item, coin and hidden value is intact
(counts and hashes identical before and after). The status stays "deployed and monitoring" until one real multiplayer combat
session has completed (see Monitoring).

## Timeline (UTC)

| Time | Step |
|---|---|
| 10:2x–10:36 | read-only inventory, baseline, logs / Advisor evidence |
| 10:36 | pre-deployment backup `2026-11-08T103650Z-pre-combat`, rehearsals on a restored copy |
| 19:3x | final re-verification (production byte-identical to the backup), dry run |
| 19:33:49–19:33:52 | `supabase db push`: the six migrations |
| 19:35:43–19:35:50 | SRD monster seed (once) |
| 19:4x | signed-in shadow smoke on production (flag `'dm'` only in a local copy of commit 1) |
| ~19:45 | commit 1 `aa0c2d1` pushed, Pages built, flag-off verification |
| ~19:50 | commit 2 `e9ff238` (flag `'dm'`, `?v=19`) pushed, Pages built |
| 19:53 | live smokes on the default route |
| 19:58:36 | post-deployment backup `2026-11-08T195836Z-post-combat`, rehearsal |

## Pre-deployment state

| Item | Value |
|---|---|
| Frontend | `adc42fe` (`?v=17`), `COMBAT_BUILDER` absent → off |
| Migrations | 46 (latest `20261031000200`) |
| Auth users / identities | 9 / 10 (Google 6, e-mail 4) |
| Profiles, campaigns, memberships, characters | 9, 2, 8, 7 |
| Custom items / custom creatures / DM content | 17 / 0 / 1 (7 versions) |
| Inventory rows / equipped / attuned | 131 / 16 / 2 |
| Active Wild Shape forms, hidden conditions, secret items | 0, 0, 0 |
| Audit events | 98 |
| Combat tables | 0 (none existed) |
| Hashes (recorded privately) | coins `5d7b610d…`, HP `05b8b736…`, base scores `31942043…`, governance `4335f26e…` |
| Database size | 31 MB (public 11 MB) |
| Schema | identical to the 46-migration chain (function bodies, tables, columns, indexes, policies, triggers, constraints, publication) apart from `service_role` ACL details and Supabase's `rls_auto_enable()` |

Private baseline (outside Git and OneDrive): `%USERPROFILE%\tavern-ledger-production-exports\2026-11-08-combat-release\baseline\`
(per-table count/md5 for all 153 tables, per-character golden read hashes, semantic counts, schema digest, replaced function
definitions incl. `_dm_try` md5 `f9313e82`, statement statistics, lints, dry-run and push output).

## Local validation

| Suite | Result |
|---|---|
| Local migration history | 10 migrations had been applied through psql. A from-zero build of all 52 files on a throwaway Supabase image produced the live local schema object for object (4421 objects; only an ACL ordering and a restore-only anon grant differed). Then `migration repair --status applied` for exactly those 10 ids (explicit local `--db-url`); dry run "up to date" |
| UX19 / UX21 isolation | the tests now own a synthetic Moon Druid in Brown Bear form (no dependency on the demo Showcase Druid); 5 sequential runs 30/0 each; fingerprint drift 0 |
| Complete browser suite (sequential) | **1281 passed, 0 failed, 39 suites, exit 0** (after the last `js/sheet.js` change) |
| Complete plain PostgreSQL (`run_local.sh`, from zero, all seeds, idempotency, rollbacks in reverse, re-apply) | **3441 passed, 0 failed, exit 0** (second run; the first was stopped by the agent's low-memory reaper at 476/0 and is not counted) |
| Combat Builder SQL on plain PostgreSQL | 179/0 |
| Combat concurrency / item-deletion concurrency (plain PostgreSQL) | 11/0 (no deadlock) / 6/0 |
| Lock-order concurrency | plain PostgreSQL 15: 12 functional checks passed, no deadlock, but its timing budget (< 1 s, calibrated for the Supabase stack) failed three times at ~2.8 s on the memory-constrained machine. In its intended environment (local Supabase, PG 17): **13/0**, slowest contended slot spend 826 ms, avg 305 ms |
| Earlier in this release cycle (unchanged code) | combat UI 89/0, combat API 35/0, Initiative 32/0, Wild Shape overflow 39/0, items/herbs/icons 48/0, feat removal 60/0 + concurrency 9/0, progressive reads 1284/0, fluent 1707/0 |
| After the `?v=19` + flag change | deployment environment 13/0, combat UI 89/0, combat smoke rehearsal 59/0 |
| Production combat smoke, local rehearsal | 59/0, cleanup left 0 |

No interrupted suite is reported as passed.

## Supabase review

**Access:** no Supabase CLI / Management API access token exists on this machine, so the hosted Log Explorer (Postgres, API,
Realtime, Auth logs) and the dashboard Advisors **were not reviewed directly**. Evidence used instead (read-only SQL):
`pg_stat_statements` (since 2026-10-30 21:41), `pg_stat_database`, `pg_stat_activity`, and Splinter-equivalent lint queries
(the SQL behind the Security / Performance Advisors). Statement timeouts (57014) are not visible in `pg_stat_statements`
(cancelled statements are not recorded) – the Log Explorer review is an open user action (below).

**Findings before the release**

| Finding | Classification |
|---|---|
| `get_character_reads` mean 651 ms, max 7.93 s (2302 calls); `get_character_shell` max 5.4 s; `get_dm_party` max 6.0 s; `expend_standard_spell_slot` max 5.9 s | pre-existing, not changed by this release; near the 8 s `authenticated` timeout on cold reads → future optimization, watch in the Log Explorer |
| deadlocks 2 (since 2026-10-30, explained and fixed 2026-10-31) | historical, resolved; unchanged after the release |
| no idle-in-transaction sessions, cache hit 100 % | healthy |
| RLS disabled / policy without RLS / security-definer views / anon table writes / extensions in public / duplicate indexes | none |
| `item_provenance` RLS without policy | intentional (definer-only access) |
| 21 anon-executable SECURITY DEFINER functions | intentional / pre-existing: RLS helpers needed by the anonymous catalog read, trigger functions, Supabase's `rls_auto_enable` |
| 5 functions without a fixed `search_path` (`try_uuid`, `_character_read_set`, `set_updated_at`, `_ability_mod`, `_infusion_modifier`) | moderate, pre-existing, unrelated → future fix |
| 12 policies calling `auth.uid()` per row; 1 table with two permissive policies | moderate performance, negligible at 7 characters → future |
| 176 unindexed foreign keys | almost all on small catalog tables → no action |

**Release-attributable lint changes (rehearsal and production identical):** +53 authenticated-executable SECURITY DEFINER
functions (the combat RPCs; each checks the campaign DM role itself), +1 per-row `auth.uid()` policy
(`combat_monster_favorites`, per-user rows), +8 unindexed combat foreign keys (participant / creator references used only on
delete). **No new anon-executable function, no table writable by anon or directly by authenticated.**

**Implemented optimizations:** none. The release is suitable for the Free-plan workload (one DM, 4–8 players, ≤ 30
combatants) as measured below; the 8 combat foreign keys and the favorites policy are deferred (expected gain below 1 ms at the
current scale; revisit when `combat_events` exceeds ~50k rows). No capacity setting was changed (statement timeout,
connections, Realtime pool, compute untouched).

## Migrations

| # | Migration | Kind | Applied |
|---|---|---|---|
| 1 | `20261106000100_combat_builder_schema.sql` | additive schema: 11 tables (RLS on all), indexes, policies, `combat_changes` in the Realtime publication, 30 combat conditions | 19:33:49–52 |
| 2 | `20261106000200_combat_builder_functions.sql` | new functions (combat RPCs, player-safe view, helpers); one anchor-checked line in `_dm_try` | same |
| 3 | `20261107000100_feat_removal.sql` | function replacement (`remove_character_feat`, `set_character_feat_choices`), new preview function, 2 revision triggers | same |
| 4 | `20261107000200_combat_initiative_wild_shape.sql` | function replacement (`damage_active_transformation`, `apply_character_hp`, `_combat_hp_one`, `combat_set_initiative`, `combat_roll_initiative`), `_ws_lock` | same |
| 5 | `20261107000300_items_herbs_icons_deletion.sql` | additive columns `items.icon_key / details` (+ check), kind `herbs_plants` + 11 categories (on conflict do nothing), `_write_homebrew`, `v_item_catalog`, `_character_read` (catalog columns), deletion preview / delete functions | same |
| 6 | `20261107000400_class_option_activation.sql` | targeted catalog patch: `activation` / `play` keys on 208 named class options (by feature version + option id) | same |

`supabase db push` took 3 s; the dry run (twice) listed exactly these six, seeds `[]`, roles `[]`. History now 52.

**Affected existing rows (exact):** `class_feature_choice_options` 208 of 240 gained keys (everything else in the rows
byte-identical), `item_kinds` +1, `item_categories` +11, `items` two new columns (all NULL / `{}`; the rest of every row
byte-identical, 1163 rows). Nothing else.

**Rollback (exact reverse order, tested on a restored production copy):** frontend first, then
`rollback_class_option_activation.sql`, `rollback_items_herbs_icons_deletion.sql`, `rollback_combat_initiative_wild_shape.sql`,
`rollback_feat_removal.sql`, `rollback_combat_builder_functions.sql`, `rollback_combat_builder_schema.sql`, then
`supabase migration repair --status reverted` for the six ids. On the copy the rollback returned every table and every
function body / policy / trigger / index exactly to production's pre-release state (only `v_item_catalog`'s `service_role`
grant becomes the default); re-apply reproduced the applied state. The schema rollback deletes all encounters: once real
encounters exist, prefer a forward fix.

## Seed

| Item | Value |
|---|---|
| File | `supabase/seed/combat_monsters.sql` (git-ignored private catalog; generated by `scripts/data-migration/combat_monsters_srd521.py`, also ignored) |
| SHA-256 | `546335ac03caf4f7432857ea1a9f7e01253c7735baed0d192a21594dcc067f2e` |
| Content | upserts into `combat_monsters` (73, SRD 5.2.1, ids `srd52-*`) and `creature_legendary_actions` (32, SRD 5.1, each guarded by `where exists` on its creature); one transaction; no delete |
| Licence | CC-BY-4.0 attribution in the seed header, every row, and the UI |
| Applied | once, 19:35:43–50Z, `psql -v ON_ERROR_STOP=1` (not `--include-seed`; no other seed ran) |
| Result | 73 / 32 / 30 conditions exactly; none of the 153 pre-existing tables changed (Wild Shape forms, companions, custom content untouched) |
| Idempotency | rehearsal on the restored production copy: second run identical checksums, 0 unrelated changes |

## Deployment

| Stage | Detail |
|---|---|
| Commit 1 | `aa0c2d1` feat: add DM Combat Builder and gameplay follow-up systems (144 files, flag `'off'`, `?v=18`) |
| Order | commit created locally → `db push` → seed → verification → shadow smoke → `git push` (the new frontend needs the new RPCs / columns) |
| Shadow smoke | commit 1 exported to a temporary folder, only the flag set to `'dm'`, served on a local origin with the app's `?env=staging` route pointing at the production URL + publishable key; synthetic accounts only → **59/0** |
| Pages (flag off) | built `aa0c2d1`; 17 sampled files byte-identical; one asset version `?v=18`; `config.staging.js` / `config.local.js` 404; no secret key; smokes: fluent (site default) 28/0, `?fluent=0` legacy fallback 25/0, gameplay polish 26/1 → PP-18 (Hungry Jaws Restore repaint not seen within 15 s right after the migration's cold-cache bump; the restore itself was saved) then **27/0 on two controlled reruns**, combat with link hidden 57/0 |
| Commit 2 | `e9ff238` feat: enable Combat Builder for campaign DMs (`COMBAT_BUILDER = 'dm'`, `?v=19` in 55 files) |
| Pages (flag dm) | built `e9ff238`; byte-identical; one asset version `?v=19` |
| Live smokes (default route) | combat **59/0**, fluent 28/0, polish 27/0 |
| Previous frontend for rollback | `adc42fe` (before the release) or `aa0c2d1` (release with the flag off) |

## Data preservation

Before / after (after all smokes and cleanup), production:

| Check | Result |
|---|---|
| Auth users, identities, profiles | 9 / 10 / 9 → 9 / 10 / 9 (synthetic smoke accounts created and removed; residue 0) |
| Campaigns, memberships, characters | 2, 8, 7 → identical |
| Custom items / creatures / DM content | identical (17 / 0 / 1); no custom content deleted |
| Inventory, equipped, attuned | 131 / 16 / 2 → identical |
| Coin, HP, base-score, governance hashes | identical (no coin conversion) |
| Spell grants, resources, Wild Shape states, hidden data, audit | identical |
| Golden reads (7 characters × 14 reads + runtime + conditions + inventory bundle, direct and via the view) | identical except `get_character_class_features` of 3 characters: only `options[].data.activation / play` keys added (intended, migration 6); every derived value (abilities, HP, AC, Initiative, speed, saves, skills, passives, spell attack / DC, resources, inventory) unchanged; the smokes changed nothing on real characters (final == post-migration) |
| Table fingerprints (153 existing tables) | only the intended tables (`class_feature_choice_options`, `item_kinds`, `item_categories`, `items`) and `character_revisions` 369 → 0: the change feed's designed 3-day retention prune (rows older than 3 days, 200 per pass) ran during the smoke writes; all 369 rows were older than 3 days (newest 99 h). It is a transient Realtime change log, not player data |
| Combat tables | only the 73 / 32 / 30 catalog rows; 0 encounters, participants, events, changes, statblocks, favorites |

## Combat Builder (production, synthetic campaign)

| Area | Result |
|---|---|
| Encounter | DM creates a draft, Add party (2 characters), monster search, SRD Ogre (hidden, disguise label) and a group of 2 Wolves |
| Initiative | player final totals stored exactly (17 stays 17, 9 stays 9); manual monster total 17; one roll for the wolf group gives both one total; Start asks for the tie review (17 = 17), starts after acceptance in round 1 |
| Live tracker (UI) | Combat Home lists the encounter, the tracker opens with all combatants, Next turn moves the current combatant |
| HP / linked sheet | 2 damage in the Combat Builder → the character 12 → 10 exactly once; the player's open sheet follows through Realtime without a sheet reload; heal 2 restores exactly 12; the sheet's own HP change (apply_character_hp) works and is seen by the Combat Builder |
| Wild Shape | 35 damage on a 34 HP Brown Bear form ends the form and exactly 1 reaches normal HP (30 → 29); deployed function definition identical to the tested one |
| Effects | condition and DM-only effect added, the condition removed |
| Player-safe view | active encounter and Prone visible; hidden Ogre, its disguise, DM notes and the DM-only effect absent; visible monsters show HP only as a state word |
| Permissions | player: no Combat link, `#/combat` goes home, DM read model / monster HP / table reads refused; unrelated user and anonymous denied on every combat RPC and `apply_character_hp`; anonymous reads no encounter rows |
| Lifecycle | pause, resume, finish, summary, archive |
| Homebrew creatures | covered by the local suites (UI 89/0, SQL 179/0); not created on production |

## Follow-up features (production)

| Feature | Result |
|---|---|
| Feat removal | direct removal with preview on a synthetic character; a repeat is refused with the friendly "no longer on the character" answer (hint `feat_absent`); an unrelated user learns nothing (no campaign name) |
| Ability display, active class features, Artificer infusions | database: 208 options carry `activation`; UI covered by the local browser suite (1281/0); real characters' golden derived values unchanged |
| Items | a Herbs & Plants item with an icon override is created; an unused item: preview, wrong name refused, exact name deletes it; a used campaign potion cannot be deleted (archive instead) |
| Potions / herbs categories | kind `herbs_plants` + 11 categories present; existing items unchanged |

## Performance (production)

Client round trips include ~100–150 ms network latency; database durations from `pg_stat_statements` (three smoke runs).

| Operation | Shadow smoke (round trip) | Live smoke (round trip) | Database max / mean |
|---|---|---|---|
| Combat Home list | 139 ms | 201 ms | 177 / 64 ms |
| Encounter open (11 KB) | 134 ms | 453 ms | 1233 / 341 ms |
| UI: Combat Home / encounter open / Next turn | 227 / 232 / 653 ms | 439 / 849 / 1213 ms | – |
| Next turn (RPC) | 177 ms | 241 ms | 556 / 163 ms |
| HP damage (linked character) | 451 ms | 2047 ms (first call, cold) | 1885 / 641 ms |
| Wild Shape damage | 358 ms | 1337 ms | (in `combat_apply_hp`) |
| Start | 138 ms | 2398 ms (first call, cold) | 1993 / 448 ms |
| Monster search (3.6 KB) / library page (8.3 KB) | 123 / 128 ms | 308 / 281 ms | 212 / 83 ms |
| Player-safe view | 159 ms | 175 ms | 74 / 49 ms |
| Realtime: DM HP change → player's open sheet | 1.1 s | 3.1 s | – |

Largest response 13.5 KB (summary). No request approached the 8 s statement timeout; deadlocks 2 → 2; no idle-in-transaction
session; one Realtime channel per sheet (unchanged design), one `combat_changes` publication entry.

## Backups

| Backup | Location (outside Git and OneDrive) | SHA-256 (first 16) | Rehearsal |
|---|---|---|---|
| Pre | `%USERPROFILE%\tavern-ledger-production-exports\2026-11-08-combat-release\2026-11-08T103650Z-pre-combat` | roles `168a95a9c745af5e`, schema `8a96ab95ecd70379`, data `a1a9d5175ea19862` | script rehearsal 7/7 characters; full restore with Auth / Storage DDL: **all 153 table fingerprints identical to production**, 9 auth users, 10 identities; then migration / seed / golden / rollback / re-apply rehearsal on that copy |
| Post | `…\2026-11-08T195836Z-post-combat` | roles `168a95a9c745af5e`, schema `9283fbb2282bb35d`, data `74c72e91949de801` | script rehearsal 7/7; full restore: **all 164 table fingerprints identical to production**, 9 / 10 |

**Restore caveat found (documented, not a release defect):** `pg_dump` records grants relative to PostgreSQL's built-in
defaults, so a logical restore into a Supabase image gives every object the image's default grants (anon / authenticated /
service_role) in addition – i.e. **broader ACLs than production** (for example anon EXECUTE on SECURITY DEFINER functions).
A real restore must reset the ACLs afterwards from the schema digest (the rehearsals did this with a generated script; the
digest with every ACL is in the baseline folder). The pre backup was not overwritten.

**Nightly backup:** `scripts/backup/nightly_backup.ps1` ran twice in this release (pre and post, both with `-Rehearse`, OK).
Scheduling is a user action because the database password must be rotated first (below).

## Security

| Check | Result |
|---|---|
| Secret scan of the commit set and the staged diffs | clean (no JWT, secret key, connection string, password, user path, e-mail); `config.js` keeps only the public URL and publishable key |
| Access-file value in Git history, tracked files, export folder, session logs | 0 occurrences |
| Real production names in the commit set | 0 of 18 checked |
| RLS | on for all 11 new tables; no policy weakened (policies identical to the chain except the new ones) |
| Grants | 94 new / replaced functions: anon EXECUTE none, all with a fixed `search_path`; only the two RLS-policy helpers are callable by authenticated; no direct table writes for authenticated |
| DM authorization / player denial / unrelated user / anonymous | verified on production (CS-14…CS-36) |
| Hidden data / cache isolation | player-safe view hides hidden monsters, disguises, DM notes, DM-only effects; read cache keyed per viewer (unchanged) |
| Access file | **not yet deleted**: the agent's tool refuses deletions at the root of `C:\` ("protected path"); the user deletes it (below). The production database password must be rotated |

## Open items

1. **Delete `C:\supabaseaccess.txt`** (the agent could not: protected path) and **rotate the production database password**.
2. **Review the Supabase Log Explorer** (Postgres, API, Realtime, Auth) for 2026-11-08 19:33Z onward and the dashboard
   Security / Performance Advisors – not reachable from this machine (no access token).
3. Pre-existing slow cold reads: `get_character_reads` max 7.9 s, `get_character_shell` 5.4 s, `get_dm_party` 6.0 s,
   `expend_standard_spell_slot` 5.9 s (all before this release) – a future optimization; watch for 57014 in the logs.
4. Deferred lints: 8 unindexed combat foreign keys, `combat_monster_favorites` per-row `auth.uid()`, 5 functions without a
   fixed `search_path`.
5. A restore needs the ACL reset described under Backups.
6. The lock-order timing budget is calibrated for the Supabase stack (plain PostgreSQL 15 on this machine: ~2.8 s).
7. `.git/worktrees/release-9b810aa` (OneDrive lock) still cannot be pruned (harmless warning on every commit).

## Monitoring

| When | What |
|---|---|
| Immediate (done) | smokes 59/0 · 28/0 · 27/0; deadlocks 2; no idle-in-transaction; combat database max < 2 s |
| One hour | Log Explorer: API 4xx/5xx, Postgres 57014 / 40P01, Realtime pool warnings; `pg_stat_statements` for `combat_%` |
| First real session | one DM, several players: linked HP, Initiative, turn flow, conditions, Realtime; then the logs |
| 24 hours | Advisors, errors, the nightly backup result, data integrity counts |
| 7 days | Advisors, errors, performance, backup rehearsal, actual usage, defects |

The release stays **deployed and monitoring** until one real multiplayer combat session completes without a deadlock, a
timeout cluster, duplicated HP, stale Initiative, a hidden-data leak or a Realtime failure.

## Nightly backup (user action)

After rotating the password, create `%USERPROFILE%\.tavern-ledger\backup-db-url.txt` (one line, the session-pooler URL with
the new password; not in OneDrive, not in Git) and restrict it to your user:

```powershell
New-Item -ItemType Directory -Force "$env:USERPROFILE\.tavern-ledger" | Out-Null
notepad "$env:USERPROFILE\.tavern-ledger\backup-db-url.txt"
icacls "$env:USERPROFILE\.tavern-ledger\backup-db-url.txt" /inheritance:r /grant:r "$($env:USERNAME):(R,W)"
$script = "$env:USERPROFILE\OneDrive - SOFTIP, a.s\Dokumenty\DnD\tavern_ledger\scripts\backup\nightly_backup.ps1"
$daily   = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$script`""
$monthly = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$script`" -Rehearse"
Register-ScheduledTask -TaskName 'Tavern Ledger nightly backup' -Action $daily -Trigger (New-ScheduledTaskTrigger -Daily -At 04:00)
Register-ScheduledTask -TaskName 'Tavern Ledger restore rehearsal' -Action $monthly `
  -Trigger (New-ScheduledTaskTrigger -Weekly -WeeksInterval 4 -DaysOfWeek Sunday -At 05:00)
```

Validated without registering (2026-11-08): both action objects keep the quoted path (it contains spaces and a comma)
intact, e.g. `powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\Users\…\tavern_ledger\scripts\backup\nightly_backup.ps1" -Rehearse`;
the rehearsal runs every 4 weeks (the scheduled-task cmdlets have no monthly trigger). Check after a run:
`Get-Content "$env:USERPROFILE\tavern-ledger-production-exports\nightly\*\STATUS.txt"`.

The script keeps 14 daily and 6 monthly backups, writes `STATUS.txt` / `LAST_FAILURE.txt`, and needs Docker running.
A dedicated read-only backup role was not created: a complete dump (roles, Auth, public) needs privileges beyond SELECT on
public, and creating a role is a security-relevant change outside this release; the `postgres` URL with the rotated password
is used instead.

## Safety confirmation

- In-place update of the existing project; no reset, truncate, schema recreation or Auth change.
- No catalog re-import, no historical importer, no demo seed; only the dedicated SRD monster seed ran.
- No player-data loss, no custom-content loss, no coin conversion, no Auth user loss (counts and hashes identical).
- No hidden-data leak in the player-safe view or the tables (verified on production).
- No secret committed; no capacity change (statement timeout, connections, Realtime pool, compute untouched).
- No unexpected migration: the dry run and the push listed exactly the six release migrations; no migration repair on production.

Combat Builder production release is deployed and monitoring.

The next action for the user is:

1. rotate the production database password;
2. configure the nightly backup with the new password;
3. run one real multiplayer combat session;
4. review Supabase logs after the session.
