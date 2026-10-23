<#
.SYNOPSIS
  Adds synthetic demo accounts, a campaign and nine demo characters to the LOCAL database. Safe to run again; keeps data.

.DESCRIPTION
  Local only (needs a running local stack: .\scripts\start-local.ps1). Never run automatically by start-local.
  Accounts (local only): local-player@example.test and local-dm@example.test, password local-dev-password.
  Demo characters have stable ids: missing ones are created, existing ones are left exactly as they are (your changes stay),
  characters you made yourself are never touched. Characters: docs/LOCAL_TEST_CHARACTERS.md.

.PARAMETER Repair
  Re-apply the demo setup to the existing demo characters (adds missing items / spells / classes, re-equips, resets the
  demo slot and tracker state). Still never touches characters the seeder did not create.

.EXAMPLE
  .\scripts\seed-local-demo.ps1
.EXAMPLE
  .\scripts\seed-local-demo.ps1 -Repair
#>
[CmdletBinding()]
param([switch]$Repair)

. (Join-Path $PSScriptRoot 'local\common.ps1')

Write-Host "Tavern Ledger - LOCAL demo data" -ForegroundColor White
Assert-LocalOnly
if (-not $SupabaseCli) { Fail "Supabase CLI not found (expected under ..\.tools\supabase-*\supabase.exe)." }
Assert-Docker | Out-Null
if (-not (Test-StackRunning)) { Fail "Local Supabase is not running. Run .\scripts\start-local.ps1 first." }
$sbEnv = Get-SupabaseEnv
if (-not $sbEnv) { Fail "Local Supabase is not reporting its status." }
$python = Get-Python
if (-not $python) { Fail "Python was not found." }

# The synthetic class feature test class (Local Feature Tester); test content only, idempotent, never part of the seeds
$fixture = Join-Path $RepoRoot 'supabase\tests\fixtures\class_feature_engine_fixture.sql'
$prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
Get-Content -LiteralPath $fixture -Raw | & docker exec -i -e 'PGOPTIONS=-c client_min_messages=warning' (Get-DbContainer) psql -U postgres -v ON_ERROR_STOP=1 -q 2>&1 | Out-Null
$fxCode = $LASTEXITCODE; $ErrorActionPreference = $prev
if ($fxCode -ne 0) { Fail "Loading the synthetic class feature fixture failed (run .\scripts\start-local.ps1 -ApplyMigrations first)." }
Write-Ok "synthetic class feature test class loaded (test content, not official)"

# The local keys exist only in this process's environment for the child process; they are never printed or saved.
$env:API_URL = $sbEnv['API_URL']; $env:ANON_KEY = $sbEnv['ANON_KEY']; $env:SERVICE_ROLE_KEY = $sbEnv['SERVICE_ROLE_KEY']
try {
    $pyArgs = @((Join-Path $RepoRoot 'scripts\local\seed_local_demo.py'))
    if ($Repair) { $pyArgs += '--repair' }
    & $python @pyArgs
    $code = $LASTEXITCODE
} finally {
    Remove-Item Env:API_URL, Env:ANON_KEY, Env:SERVICE_ROLE_KEY -ErrorAction SilentlyContinue
}
if ($code -ne 0) { Fail "Demo data could not be created (see above)." }
Write-Host "Open $FrontendUrl and sign in as local-player@example.test." -ForegroundColor Green
