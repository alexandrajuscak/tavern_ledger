<#
Tavern Ledger nightly production backup (docs/PRODUCTION_OPERATIONS.md, "Nightly backup"). Supabase Free has no backups.

What it writes (one timestamped folder, never inside the repository or OneDrive):
  roles.sql, schema.sql, data.sql   supabase db dump (the format verified by the 2026-10-23 / 2026-10-29 restore rehearsals)
  migration_history.txt, counts.txt read-only queries (no personal data)
  SHA256SUMS.txt                    one line per file
  STATUS.txt                        OK or FAILED with the step; a failure also writes ..\LAST_FAILURE.txt and exits 1
Retention: the newest -KeepDaily folders plus the first backup of each of the last -KeepMonthly months.
Restore rehearsal (monthly, -Rehearse): restores the newest backup into a throw-away local PostgreSQL container and compares
the row counts with counts.txt (docs/PRODUCTION_OPERATIONS.md).

The database URL is read from -UrlFile (default %USERPROFILE%\.tavern-ledger\backup-db-url.txt; ACL: your user only) into this
process only. It is never printed, logged or passed on a command line visible to other users (environment variable only).
Use a read-only database role for this file if you create one; the dump needs only SELECT.

Schedule (Task Scheduler, daily 04:00, "Run whether user is logged on or not" not required):
  powershell -NoProfile -ExecutionPolicy Bypass -File "<repo>\scripts\backup\nightly_backup.ps1"
#>
param(
  [string]$UrlFile = (Join-Path $env:USERPROFILE '.tavern-ledger\backup-db-url.txt'),
  [string]$Root = (Join-Path $env:USERPROFILE 'tavern-ledger-production-exports\nightly'),
  [string]$Cli = (Join-Path $PSScriptRoot '..\..\..\.tools\supabase-2.118.0\supabase.exe'),
  [string]$Label = '',
  [int]$KeepDaily = 14,
  [int]$KeepMonthly = 6,
  [string]$RehearsalImage = 'public.ecr.aws/supabase/postgres:17.6.1.171',
  [switch]$Rehearse
)
$ErrorActionPreference = 'Stop'
if ($Root -match 'OneDrive') { throw "Backups must not be written to OneDrive: $Root" }
New-Item -ItemType Directory -Force -Path $Root | Out-Null
$stamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHHmmssZ') + $(if ($Label) { "-$Label" } else { '' })
$dir = Join-Path $Root $stamp
New-Item -ItemType Directory -Force -Path $dir | Out-Null
$step = 'start'
$rehearsal = ''
function Fail($msg) {
  "FAILED at step '$step': $msg" | Set-Content (Join-Path $dir 'STATUS.txt')
  "$(Get-Date -Format o) FAILED $stamp at step '$step'" | Set-Content (Join-Path $Root 'LAST_FAILURE.txt')
  Write-Error "Backup FAILED at step '$step' (see $dir\STATUS.txt)"
  exit 1
}
try {
  $step = 'read url'
  if (-not (Test-Path $UrlFile)) { throw "URL file not found: $UrlFile" }
  $env:TL_BACKUP_DB_URL = (Get-Content -Raw $UrlFile).Trim()
  if ($env:TL_BACKUP_DB_URL -notmatch '^postgres(ql)?://') { throw 'URL file does not contain a postgres URL' }

  foreach ($part in @(@('roles.sql', '--role-only'), @('schema.sql', $null), @('data.sql', '--data-only'))) {
    $step = "dump $($part[0])"
    $dumpArgs = @('db', 'dump', '--db-url', $env:TL_BACKUP_DB_URL, '-f', (Join-Path $dir $part[0]))
    if ($part[1]) { $dumpArgs += $part[1] }
    & $Cli @dumpArgs 2>&1 | ForEach-Object { $_ -replace 'postgres(ql)?://[^\s"]+', '<db-url>' } | Out-File (Join-Path $dir 'dump.log') -Append
    if ($LASTEXITCODE -ne 0) { throw "supabase db dump exited with $LASTEXITCODE" }
    if ((Get-Item (Join-Path $dir $part[0])).Length -lt 100) { throw "$($part[0]) is empty" }
  }

  $step = 'counts'
  $q = @"
set default_transaction_read_only = on;
begin read only;
select 'migrations|' || count(*) || '|' || max(version) from supabase_migrations.schema_migrations;
select 'auth_users|' || count(*) from auth.users;
select 'characters|' || count(*) from public.characters;
select 'campaigns|' || count(*) from public.campaigns;
select 'campaign_members|' || count(*) from public.campaign_members;
select 'inventory_items|' || count(*) from public.inventory_items;
select 'character_spells|' || count(*) from public.character_spells;
select 'items_custom|' || count(*) from public.items where owner_id is not null;
select 'items|' || count(*) from public.items;
select 'spell_versions|' || count(*) from public.spell_versions;
select 'feat_versions|' || count(*) from public.feat_versions;
select 'background_versions|' || count(*) from public.background_versions;
select 'change_requests|' || count(*) from public.change_requests;
rollback;
"@
  $out = $q | docker run --rm -i -e TL_BACKUP_DB_URL postgres:17 sh -c 'psql "$TL_BACKUP_DB_URL" -X -q -A -t -v ON_ERROR_STOP=1' 2>&1
  if ($LASTEXITCODE -ne 0) { throw 'count query failed' }
  $out | Where-Object { $_ -match '\|' -and $_ -notmatch '^migrations' } | Set-Content (Join-Path $dir 'counts.txt')
  $out | Where-Object { $_ -match '^migrations' } | Set-Content (Join-Path $dir 'migration_history.txt')

  $step = 'checksums'
  Get-ChildItem $dir -File | Where-Object { $_.Name -notin @('SHA256SUMS.txt', 'STATUS.txt') } |
    ForEach-Object { "$((Get-FileHash $_.FullName -Algorithm SHA256).Hash.ToLower())  $($_.Name)" } | Set-Content (Join-Path $dir 'SHA256SUMS.txt')

  $step = 'retention'
  $all = Get-ChildItem $Root -Directory | Where-Object { Test-Path (Join-Path $_.FullName 'STATUS.txt') } | Sort-Object Name -Descending
  $keep = @($all | Select-Object -First $KeepDaily | ForEach-Object Name)
  $keep += $all | Group-Object { $_.Name.Substring(0, 7) } | Sort-Object Name -Descending | Select-Object -First $KeepMonthly |
    ForEach-Object { ($_.Group | Sort-Object Name | Select-Object -First 1).Name }
  $all | Where-Object { $_.Name -notin $keep -and $_.Name -notmatch '-pre-|-post-' } | Remove-Item -Recurse -Force

  if ($Rehearse) {
    $step = 'restore rehearsal'
    $name = "tl-restore-rehearsal-$([guid]::NewGuid().ToString('N').Substring(0,8))"
    # the Supabase Postgres image (auth/storage schemas, extensions, API roles); a plain postgres image cannot load schema.sql
    docker run -d --name $name -e POSTGRES_PASSWORD=rehearsal $RehearsalImage | Out-Null
    try {
      for ($i = 0; $i -lt 60; $i++) { docker exec $name pg_isready -U postgres -h 127.0.0.1 -q 2>$null | Out-Null; if ($LASTEXITCODE -eq 0) { break }; Start-Sleep 1 }
      Start-Sleep 5
      foreach ($f in 'roles.sql', 'schema.sql', 'data.sql') { docker cp (Join-Path $dir $f) "${name}:/tmp/$f" | Out-Null }
      # Supabase's documented restore order: roles, schema, then the data with triggers off (session_replication_role)
      docker exec -e PGPASSWORD=rehearsal $name psql -h 127.0.0.1 -U supabase_admin -d postgres -q -f /tmp/roles.sql -f /tmp/schema.sql `
        -c 'set session_replication_role = replica' -f /tmp/data.sql 2>&1 | Out-File (Join-Path $dir 'rehearsal.log')
      $chars = docker exec -e PGPASSWORD=rehearsal $name psql -h 127.0.0.1 -U supabase_admin -d postgres -At -c 'select count(*) from public.characters'
      $expect = ((Get-Content (Join-Path $dir 'counts.txt')) | Where-Object { $_ -like 'characters|*' }).Split('|')[1]
      $rehearsal = "rehearsal: characters restored=$("$chars".Trim()) expected=$("$expect".Trim())"
      if ("$chars".Trim() -ne "$expect".Trim()) { throw "restore rehearsal: $chars characters restored, $expect expected" }
    } finally { docker rm -f $name | Out-Null }
  }
  @("OK $stamp $((Get-ChildItem $dir -File | Measure-Object Length -Sum).Sum) bytes", $rehearsal) | Where-Object { $_ } | Set-Content (Join-Path $dir 'STATUS.txt')
  Write-Output "Backup OK: $dir"
} catch {
  Fail $_.Exception.Message
} finally {
  Remove-Item Env:\TL_BACKUP_DB_URL -ErrorAction SilentlyContinue
}
