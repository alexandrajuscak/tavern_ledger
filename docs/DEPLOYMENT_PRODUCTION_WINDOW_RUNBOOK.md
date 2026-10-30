# Production maintenance window runbook: in-place upgrade to V6.2

Rehearsed end to end on a clone of production (docs/DEPLOYMENT_INPLACE_UPGRADE_RUNBOOK.md, §1–2). Target: the existing
Supabase project `pfgz…wlsc`, the GitHub repository `alexandrajuscak/tavern_ledger`, and the Pages site
`https://alexandrajuscak.github.io/tavern_ledger/`.

## Tags

- **MANUAL**: Alexandra does it. ⛔ marks a checkpoint: Claude waits for "done" plus the requested output.
- **AUTOMATED**: Claude runs it on this computer. It never needs the database password and never writes to production.
- Where: **SUPABASE DASHBOARD**, **SUPABASE SQL EDITOR**, **POWERSHELL** (Alexandra's own window; the password is
  typed only there), **GITHUB**.

## Rules for the whole window

- The database password and the connection string exist only in Alexandra's PowerShell window (`$env:PROD_DB_URL`).
  Never paste them into the chat, a file or a commit.
- **Every command runs from the repository root:**
  `<repository folder>` (the folder that contains `index.html` and `supabase\`)
- Stop at the first failed pass criterion and use that phase's rollback point. Do not improvise.
- Rollback **R-A** (used from Phase 4 on) is two SQL files run with psql, in this order:
  `supabase/rollback/rollback_v62_hardening.sql`, then `supabase/rollback/rollback_inventory.sql` (exact command in
  Phase 4).

---

## Phase 0: Preparation (day before; nothing touches production)

**Things Alexandra must do manually**
- [ ] MANUAL: choose the window date and time, and tell the players:
  - the date and time, about 60 minutes;
  - "don't use the app during the window";
  - "afterwards, re-equip your weapons and gear once, and complete Lineage / Class / Background on Build".
- [ ] MANUAL / SUPABASE DASHBOARD: know the **database password**. If it is unknown: Project Settings → Database → *Reset
  database password*. This is safe; the app does not use it.
- [ ] MANUAL / SUPABASE DASHBOARD: Connect → *Session pooler*. Note the **host** (e.g. `aws-0-<region>.pooler.supabase.com`)
  and the **user** (`postgres.pfgz…wlsc`). Neither is secret, but keep them handy.
- [ ] MANUAL: move the old backup folder (`…\DnD\DB_backup_legacy\`) out of OneDrive, e.g. to
  `%USERPROFILE%\tavern-ledger-production-exports\legacy-backup-1\`.
- [ ] MANUAL: decide the commit author e-mail. The 10 existing public commits use your company address. Keep it, or set a
  GitHub no-reply address for this repository.
- [ ] MANUAL: approve the release commit (file list and message, which Claude shows in Phase 0).

**Things Claude can perform**
- [ ] AUTOMATED: `docker pull postgres:17` (the psql client used in the window; not yet on this computer).
- [ ] AUTOMATED: set `js/config.js` back to the **existing** project's public values (the URL and publishable key of
  commit `849d7f1`; `PRODUCTION_HOSTS` stays).
- [ ] AUTOMATED: run the complete browser suite (`PORT=5191 bash supabase/tests/run_browser_local.sh`); expect 0 failed.
- [ ] AUTOMATED: run the secret scan of the commit set.
- [ ] AUTOMATED: build the release commit locally (`git add` of the reviewed set, `git commit`) **after your approval**. It
  is **not pushed** until Phase 8.
- [ ] AUTOMATED: check that GitHub Pages still serves `849d7f1` (read-only).

⛔ **CHECKPOINT 0:** tell Claude: the window time, "password known", "pooler host noted", "commit approved".

---

## Phase 1: Production freeze (5 min) · rollback point: nothing changed

**Things Alexandra must do manually**
1. MANUAL: post "maintenance starts now, please don't use Tavern Ledger" to the players.
2. **SUPABASE SQL EDITOR**: open a new query, paste `scripts/deploy/precheck_package.sql`, select the **SUMMARY** block
   and run it. Then select **CHECK 7** and run it.

**Expected / pass criteria**
- SUMMARY: 12 rows, all `GO`.
- CHECK 7: `characters` = **7**, `inventory_rows` = **76**, `equipped_rows` = **37**, `last_character_change` older than
  your announcement.

**Fail:** any `NO-GO`, or different counts. Stop and send the output (Claude adapts the expected values only if the
change is legitimate, e.g. a player added an item yesterday).

⛔ **CHECKPOINT 1:** send Claude the SUMMARY rows and the CHECK 7 row.

**Things Claude can perform:** compare the numbers with the rehearsal; adapt the later expected values if needed.

---

## Phase 2: Fresh backup (10 min) · rollback point: nothing changed

**Things Alexandra must do manually: POWERSHELL** (a new window; leave it open until Phase 10)

```powershell
cd "<repository folder>"          # e.g. the folder you open in VS Code
$SB  = "..\.tools\supabase-2.118.0\supabase.exe"
$WIN = Get-Date -Format "yyyy-MM-dd"
$B   = "$env:USERPROFILE\tavern-ledger-production-exports\$WIN-window\pre-upgrade"
New-Item -ItemType Directory -Force $B | Out-Null
$pw  = Read-Host "Production DB password" -AsSecureString
$enc = [uri]::EscapeDataString([Net.NetworkCredential]::new('', $pw).Password)
$env:PROD_DB_URL = "postgresql://postgres.<project-ref>:$enc@<POOLER-HOST>:5432/postgres"
& $SB db dump --db-url $env:PROD_DB_URL -f "$B\roles.sql" --role-only
& $SB db dump --db-url $env:PROD_DB_URL -f "$B\schema.sql"
& $SB db dump --db-url $env:PROD_DB_URL -f "$B\data.sql" --data-only
Get-FileHash "$B\*.sql" -Algorithm SHA256 | Format-Table Hash, Path -Auto
```

Replace `<POOLER-HOST>` with the host from Phase 0.

**Expected:** three `Dumped schema …` / `Dumped data …` messages and three hashes. Sizes are similar to the first backup:
roles ~0.4 KB, schema ~33 KB, data ~150 KB.

**Fail:** an error, an empty file, or `password authentication failed`. Re-enter the password (run the `$pw`, `$enc`
and `$env:PROD_DB_URL` lines again), then repeat.

⛔ **CHECKPOINT 2:** tell Claude "backup done" plus the folder path. Do not paste the hashes if you prefer; Claude can
read them.

**Things Claude can perform**
- AUTOMATED: verify the three files without printing personal data. Pass: schema has the 11 tables; data has 8 users,
  9 identities, 7 characters, 2 campaigns, 76 items, 1 bucket; same as the rehearsal.
- AUTOMATED: write `SHA256SUMS.txt` next to them.

---

## Phase 3: Migration baseline repair (1 min) · rollback point: harmless history row

**Things Alexandra must do manually: POWERSHELL** (same window)

```powershell
& $SB migration repair --db-url $env:PROD_DB_URL --status applied 20261015000000
```

**Expected:** `Repaired migration history: [20261015000000] => applied`.

**Pass:** that line. **Fail:** any error. Stop. The database is unchanged, except possibly a new, empty
`supabase_migrations` schema. Undo is optional: `& $SB migration repair --db-url $env:PROD_DB_URL --status reverted 20261015000000`.

⛔ **CHECKPOINT 3:** send Claude the output line.

**Things Claude can perform:** confirm the output matches the rehearsal.

---

## Phase 4: Migration execution (2 min) · rollback point: R-A

**Things Alexandra must do manually: POWERSHELL**

```powershell
& $SB db push --db-url $env:PROD_DB_URL --dry-run
```

**Expected (dry run):** `Would push these migrations:` followed by **exactly 40** lines, first
`20261015000100_item_lookups.sql`, last `20261023000100_v62_hardening.sql`. The line `Skipping migration README.md…` is
normal.

⛔ **CHECKPOINT 4a:** send Claude the dry-run list (or "40 lines, first … last …"). **Do not run the next command
before Claude confirms.**

```powershell
& $SB db push --db-url $env:PROD_DB_URL
```

Answer `Y` if asked. **Expected:** 40 × `Applying migration …`, then `Finished supabase db push.` (rehearsal: 4 seconds).

**Pass:** no `ERROR`. **Fail:** any `ERROR`. Stop and send the full output. Each migration is its own transaction, so a
failed one leaves no half state. Rollback **R-A**:

```powershell
$env:DBURL = $env:PROD_DB_URL
docker run --rm -e DBURL -v "${PWD}\supabase\rollback:/rb:ro" postgres:17 sh -c 'psql $DBURL -v ON_ERROR_STOP=1 -f /rb/rollback_v62_hardening.sql && psql $DBURL -v ON_ERROR_STOP=1 -f /rb/rollback_inventory.sql'
```

(R-A only after Claude has looked at the error.)

⛔ **CHECKPOINT 4b:** send Claude the last ~5 lines of the push output.

**Things Claude can perform:** check that the 40 names and the order match the rehearsal; decide pass or fail with you.

---

## Phase 5: Catalog import (2 min) · rollback point: R-A

Exactly once. Never repeat on production after DM content exists.

**Things Alexandra must do manually: POWERSHELL**

```powershell
$env:DBURL = $env:PROD_DB_URL
foreach ($s in 'reference_data','item_effects','spells','classes','class_features','creatures','lineages','feats','backgrounds') {
  docker run --rm -e DBURL -e SEED=$s -v "${PWD}\supabase\seed:/seed:ro" postgres:17 sh -c 'psql $DBURL -v ON_ERROR_STOP=1 -q -f /seed/$SEED.sql > /dev/null'
  if ($LASTEXITCODE) { Write-Host "SEED FAILED: $s" -ForegroundColor Red; break } else { Write-Host "ok $s" }
}
docker run --rm -e DBURL -v "${PWD}\scripts\deploy:/d:ro" postgres:17 sh -c 'psql $DBURL -At -f /d/catalog_counts.sql'
```

**Expected:** `ok …` × 9, then 10 rows `name|count|expected` with count = expected:
items 1146 · spell_versions 574 · class_versions 13 · subclass_versions 118 · class_feature_versions 246 ·
creatures 334 · lineage_versions 133 · feat_versions 408 · background_versions 30 · source_books 58.

**Fail:** `SEED FAILED` or a different count. Stop and send the output; rollback **R-A** (Phase 4 command).

⛔ **CHECKPOINT 5:** send Claude the 9 `ok` lines and the 10 counts.

**Things Claude can perform:** compare the counts.

---

## Phase 6: Legacy inventory conversion (1 min) · rollback point: R-A

**Things Alexandra must do manually: SUPABASE SQL EDITOR** (or POWERSHELL with the same psql pattern)

Run, as two separate runs:

```sql
select public.migrate_legacy_inventory();
```
```sql
select public.migrate_legacy_inventory();
```

**Expected first result:** `{"linked_by_name": 44, "equipped_migrated": 4, "equipped_manual": 33, …}`.
**Expected second result:** `"linked_by_name": 0, "equipped_migrated": 0, "equipped_manual": 0`.

**Fail:** an error, or a second run that is not zero. Stop; rollback **R-A**.

⛔ **CHECKPOINT 6:** send Claude both JSON results.

**Things Claude can perform:** compare with the rehearsal (44 / 4 / 33). A small deviation is fine if items changed
since the backup.

---

## Phase 7: Validation (5 min) · rollback point: R-A (the old frontend still works)

**Things Alexandra must do manually: POWERSHELL**

```powershell
docker run --rm -e DBURL -v "${PWD}:/repo:ro" postgres:17 sh -c 'psql $DBURL -At -f /repo/scripts/deploy/postupgrade_validation.sql; psql $DBURL -At -f /repo/supabase/tests/catalog_integrity_report.sql'
```

**Expected:** 14 rows `check|actual|expected`, with actual = expected in every row:

| check | expected |
|---|---|
| V1 users / profiles / Google | 8 / 8 / 6 |
| V2 characters / campaigns / members | 7 / 2 / 8 |
| V3 inventory rows / without inventory_id | 76 / 0 |
| V4 character inventories | 7 |
| V5 governance | relaxed:2 |
| V6 characters set up | 7 |
| V9 tables / no RLS / unpinned | 152 / 0 / 0 |
| V10 policies / hash | 170 / 91bd4664f2167ec4ba8e3357538b7efc |
| V11 Realtime / storage policies | 31 / 3 |
| V12 bucket | portraits public=t 2097152 {image/jpeg,image/png,image/webp} |
| legacy rows | 36/21/73/9/35 |
| V6.2 constraints / admins / ensure_rls | 2 / 2 / 1 |

Then 14 integrity rows, all `0`.

⛔ **CHECKPOINT 7:** send Claude the full output.

**Things Claude can perform**
- AUTOMATED: compare every row.
- AUTOMATED: run the **anonymous probe** with the public key from read-only requests: characters / profiles / campaigns
  `[]`; inventory, audit and hidden data 401.
- Decide GO for the frontend.

**Fail:** any difference. Stop; rollback **R-A**. The legacy site is unaffected.

---

## Phase 8: Frontend release (5 min) · rollback point: revert commit + R-A

**Things Claude can perform**
- AUTOMATED: show the release commit (`git show --stat HEAD`) and run a last secret scan of the commit.

**Things Alexandra must do manually: POWERSHELL** (the push needs your github.com login)

⛔ **CHECKPOINT 8a:** Claude asks "push now?". Answer **yes** only after Checkpoint 7 is GO.

```powershell
git push origin main
```

If Windows asks for a GitHub sign-in, use **alexandrajuscak** on github.com (not the enterprise host).

**GITHUB:** nothing to click. Pages redeploys automatically from `main` (legacy branch build), in about 1–2 minutes.

⛔ **CHECKPOINT 8b:** tell Claude "pushed".

**Things Claude can perform**
- AUTOMATED: watch the Pages build (`gh api repos/alexandrajuscak/tavern_ledger/pages/builds/latest`, read-only) until
  `built`.
- AUTOMATED: verify the site:
  - `js/inventory-api.js` and `vendor/supabase-js/supabase-2.117.2.umd.js` answer 200;
  - `js/config.js` shows `pfgz…wlsc` and **no** secret.

**Rollback:** `git revert --no-edit HEAD` and `git push origin main` (you push), then **R-A**.

---

## Phase 9: Production smoke test (10 min) · rollback point: revert commit + R-A

**Things Alexandra must do manually: browser**
1. Open `https://alexandrajuscak.github.io/tavern_ledger/` in a **private window** (no old cache).
2. Sign in with **e-mail** (your admin account):
   - home lists the characters;
   - open two characters, with all 6 tabs;
   - Inventory shows the items;
   - DM Space opens and shows both campaigns.
3. Ask one player (or use a second account) to sign in with **Google**: their character opens.
4. Realtime: with the same character open in two browsers, change HP in one; the other updates within a few seconds.
5. Sign out: the sign-in screen appears.

**Pass:** all five. **Fail:** any sign-in failure, an error screen, or missing characters. Rollback: Phase 8 revert +
**R-A**.

⛔ **CHECKPOINT 9:** tell Claude the result of each of the five items.

**Things Claude can perform:** read-only checks of the public site (assets, no external CDN); help diagnose from
screenshots or console text.

---

## Phase 10: Post-upgrade backup and close (10 min)

**Things Alexandra must do manually: POWERSHELL** (same window)

```powershell
$B2 = "$env:USERPROFILE\tavern-ledger-production-exports\$WIN-window\post-upgrade"
New-Item -ItemType Directory -Force $B2 | Out-Null
& $SB db dump --db-url $env:PROD_DB_URL -f "$B2\roles.sql" --role-only
& $SB db dump --db-url $env:PROD_DB_URL -f "$B2\schema.sql"
& $SB db dump --db-url $env:PROD_DB_URL -f "$B2\data.sql" --data-only
Remove-Item Env:PROD_DB_URL, Env:DBURL; Remove-Variable pw, enc
```

Then:
- tell the players: "Tavern Ledger is back. Please re-equip your weapons and gear once and complete Lineage / Class /
  Background / Spells on Build."
- **SUPABASE DASHBOARD** (optional): Authentication → Sign In / Providers → turn off "Allow new users to sign up" if
  every player has an account.

⛔ **CHECKPOINT 10:** tell Claude "post-backup done" plus the folder path.

**Things Claude can perform**
- AUTOMATED: verify the post-upgrade backup. Pass: schema with 152 tables; data with 8 users and 7 characters.
- AUTOMATED: write the SHA-256 list.
- AUTOMATED: fill in docs/DEPLOYMENT_PRODUCTION_SMOKE_RESULTS.md and docs/DEPLOYMENT_FINAL_HANDOVER.md.

---

## PRODUCTION MIGRATION CHECKLIST

| Phase | | | |
|---|---|---|---|
| 0 Preparation | [ ] step completed | [ ] validation passed (browser suite 0 failed, commit approved) | [ ] rollback available (nothing changed) |
| 1 Freeze | [ ] step completed | [ ] validation passed (SUMMARY 12/12, counts 7 / 76 / 37) | [ ] rollback available (nothing changed) |
| 2 Fresh backup | [ ] step completed | [ ] validation passed (3 files verified, hashes written) | [ ] rollback available (nothing changed) |
| 3 Baseline repair | [ ] step completed | [ ] validation passed ("Repaired … applied") | [ ] rollback available (`repair --status reverted`) |
| 4 Migrations | [ ] step completed | [ ] validation passed (dry-run 40, push without error) | [ ] rollback available (R-A) |
| 5 Catalog import | [ ] step completed | [ ] validation passed (9 ok, counts exact) | [ ] rollback available (R-A) |
| 6 Inventory conversion | [ ] step completed | [ ] validation passed (44/4/33, second run 0) | [ ] rollback available (R-A) |
| 7 Validation | [ ] step completed | [ ] validation passed (14/14, integrity 0, anon probe) | [ ] rollback available (R-A) |
| 8 Frontend release | [ ] step completed | [ ] validation passed (Pages built, assets 200, config correct) | [ ] rollback available (revert + R-A) |
| 9 Smoke test | [ ] step completed | [ ] validation passed (e-mail, Google, characters, Realtime, sign-out) | [ ] rollback available (revert + R-A) |
| 10 Post-backup | [ ] step completed | [ ] validation passed (3 files verified) | [ ] rollback available (restore per DEPLOYMENT_INPLACE_UPGRADE_RUNBOOK.md §5) |
