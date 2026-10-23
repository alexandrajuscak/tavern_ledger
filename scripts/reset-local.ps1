<#
.SYNOPSIS
  DELETES all LOCAL Tavern Ledger database data and rebuilds it from the migrations and the reference seed.

.DESCRIPTION
  Local only: runs `supabase db reset --local` against the Supabase stack in Docker on this computer.
  The hosted Supabase project is NOT affected (no --linked, no db push, no remote connection).
  Deletes local accounts, characters, inventories and homebrew. Asks for confirmation unless -Force is given.

.PARAMETER Force
  Skip the confirmation prompt.

.EXAMPLE
  .\scripts\reset-local.ps1
#>
[CmdletBinding()]
param([switch]$Force)

. (Join-Path $PSScriptRoot 'local\common.ps1')

Write-Host "Tavern Ledger - LOCAL database reset" -ForegroundColor White
Write-Host ""
Write-Host "WARNING: this deletes ALL LOCAL Tavern Ledger database data on this computer:" -ForegroundColor Yellow
Write-Host "         local accounts, characters, inventories, homebrew items and demo data." -ForegroundColor Yellow
Write-Host "         The hosted Supabase project (production) is NOT affected." -ForegroundColor Yellow
Write-Host ""

Assert-LocalOnly
Write-Ok "not linked to a hosted Supabase project"
if (-not $SupabaseCli) { Fail "Supabase CLI not found (expected under ..\.tools\supabase-*\supabase.exe)." }
Assert-Docker | Out-Null

if (-not $Force) {
    $answer = Read-Host "Type RESET to delete the local database, anything else to cancel"
    if ($answer -cne 'RESET') { Write-Host "Cancelled. Nothing was changed."; exit 0 }
}

Write-Step "Local Supabase"
if (-not (Test-StackRunning)) {
    Write-Host "   not running - starting it first"
    $code = Invoke-Supabase start -x 'edge-runtime,imgproxy,logflare,vector'
    if ($code -ne 0) { Fail "supabase start failed (exit $code)." }
}
$sbEnv = Get-SupabaseEnv   # fails if the API URL is not local
if (-not $sbEnv) { Fail "Local Supabase is not reporting its status." }
Write-Ok "target is local: $($sbEnv['API_URL']), container $(Get-DbContainer)"

Write-Step "supabase db reset --local (migrations + seed from supabase\config.toml)"
$code = Invoke-Supabase db reset --local
if ($code -ne 0) { Fail "db reset failed (exit $code). Read the migration / seed error above." }

Write-Step "Verification"
$files = Get-MigrationFileCount
$applied = Invoke-LocalSql 'select count(*) from supabase_migrations.schema_migrations'
$fail = $false
if ([int]$applied -eq $files) { Write-Ok "migrations: $applied of $files applied" } else { Write-Warn2 "migrations: $applied applied, $files expected"; $fail = $true }
if (@(Test-Catalog).Count) { $fail = $true }   # items, lineages, spells, classes vs data/reports/*_seed_summary.json
if ($fail) { Fail "The local database was reset but does not match the expected state." }

Write-Host ""
Write-Host "Local database reset complete. Migrations and the reference seeds were applied." -ForegroundColor Green
Write-Host "Local accounts were deleted: sign out in the browser (or create the account again)."
Write-Host "Optional demo data: .\scripts\seed-local-demo.ps1"
