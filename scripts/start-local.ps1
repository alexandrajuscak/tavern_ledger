<#
.SYNOPSIS
  Starts Tavern Ledger LOCALLY: the local Supabase stack (Docker) and a static frontend server on http://127.0.0.1:5173/.

.DESCRIPTION
  Local only. Never links, pushes to or contacts a hosted Supabase project.
  Reuses a running stack and an already running frontend server. Keeps the local database: it never resets it
  and never re-creates demo data. On the very first run (no local database volume yet) Supabase applies all
  migrations and the reference seed from supabase/config.toml.

.PARAMETER ApplyMigrations
  Also apply NEW migration files to the existing local database (`supabase migration up --local`). Keeps data.

.EXAMPLE
  .\scripts\start-local.ps1
#>
[CmdletBinding()]
param([switch]$ApplyMigrations)

. (Join-Path $PSScriptRoot 'local\common.ps1')

Write-Host "Tavern Ledger - LOCAL development start" -ForegroundColor White
Write-Host "Repository: $RepoRoot"

Write-Step "Checks"
Assert-LocalOnly
Write-Ok "not linked to a hosted Supabase project"
if (-not $SupabaseCli) { Fail "Supabase CLI not found. Expected: $(Join-Path (Split-Path $RepoRoot -Parent) '.tools\supabase-2.118.0\supabase.exe')`n       (or set the SUPABASE_CLI environment variable to supabase.exe)." }
Write-Ok "Supabase CLI: $SupabaseCli"
$dockerVersion = Assert-Docker
Write-Ok "Docker engine $dockerVersion is running"
$python = Get-Python
if (-not $python) { Fail "Python was not found. Install Python 3 from python.org (it serves the frontend)." }
Write-Ok "Python: $python"
$ports = Get-LocalPorts
New-Item -ItemType Directory -Force -Path $RuntimeDir | Out-Null

# ---- Supabase --------------------------------------------------------------------------------------------------------
Write-Step "Local Supabase (project '$($ports.ProjectId)')"
if (Test-StackRunning) {
    Write-Ok "already running - reusing it"
} else {
    $firstRun = -not (Test-DbVolumeExists)
    if ($firstRun) { Write-Host "   First start: creating the local database, applying migrations and the reference seed (a few minutes)..." }
    else { Write-Host "   Starting containers; the existing local database is kept..." }
    # Not needed for Tavern Ledger: Edge Functions, image transforms, log collection (keeps Docker lighter).
    $code = Invoke-Supabase start -x 'edge-runtime,imgproxy,logflare,vector'
    if ($code -ne 0) {
        Fail "supabase start failed (exit $code).`n       Common causes: a port from supabase\config.toml is in use (API $($ports.Api), DB $($ports.Db), Studio $($ports.Studio)),`n       or leftover containers: run .\scripts\stop-local.ps1 and then this script again. See docs\LOCAL_DEVELOPMENT.md."
    }
}

$sbEnv = $null
for ($i = 0; $i -lt 30 -and -not $sbEnv; $i++) { $sbEnv = Get-SupabaseEnv; if (-not $sbEnv) { Start-Sleep -Seconds 2 } }
if (-not $sbEnv) { Fail "Local Supabase did not report its status. Run .\scripts\status-local.ps1 for details." }
$api = $sbEnv['API_URL']; $anon = $sbEnv['ANON_KEY']
if ((Get-JwtRole $anon) -ne 'anon') { Fail "The local key reported by Supabase is not an 'anon' key. Refusing to give it to the browser." }

$ready = $false
for ($i = 0; $i -lt 60 -and -not $ready; $i++) {
    $ready = (Test-Http "$api/auth/v1/health" @{ apikey = $anon }) -eq 200 -and (Test-Http "$api/rest/v1/" @{ apikey = $anon }) -eq 200
    if (-not $ready) { Start-Sleep -Seconds 2 }
}
if (-not $ready) { Fail "The local API at $api did not become ready. Check Docker Desktop, then run .\scripts\status-local.ps1." }
Write-Ok "local API ready: $api (Auth + PostgREST)"

# ---- database state (read-only checks) ------------------------------------------------------------------------------
$applied = Invoke-LocalSql 'select count(*) from supabase_migrations.schema_migrations'
$files = Get-MigrationFileCount
if ($ApplyMigrations -and [int]$applied -lt $files) {
    Write-Host "   Applying $($files - [int]$applied) new migration(s) to the local database (data is kept)..."
    $code = Invoke-Supabase migration up --local
    if ($code -ne 0) { Fail "Applying new migrations failed. Fix the migration, or use .\scripts\reset-local.ps1 for a clean local database." }
    $applied = Invoke-LocalSql 'select count(*) from supabase_migrations.schema_migrations'
}
$users = Invoke-LocalSql 'select count(*) from auth.users'
$chars = Invoke-LocalSql 'select count(*) from public.characters'
if ([int]$applied -eq $files) { Write-Ok "migrations: $applied of $files applied" }
else { Write-Warn2 "migrations: $applied applied, $files files in supabase\migrations. Run: .\scripts\start-local.ps1 -ApplyMigrations" }
# reference catalog (items, lineages, spells, classes) against data/reports/*_seed_summary.json. New migrations add tables
# that only the seeds fill, so -ApplyMigrations reloads the idempotent seeds when something is missing (data is kept).
if (@(Test-Catalog -Quiet).Count -and $ApplyMigrations -and [int]$applied -eq $files) {
    Write-Host "   Loading the reference seeds (idempotent; local accounts and characters are kept)..."
    Invoke-ReferenceSeeds
}
if (@(Test-Catalog).Count) { Write-Warn2 "reference catalog incomplete. Run: .\scripts\start-local.ps1 -ApplyMigrations   (or a clean rebuild: .\scripts\reset-local.ps1)" }
Write-Ok "local accounts: $users, characters: $chars, demo characters: $(Get-DemoFixtureCount) of 9"

# ---- frontend config for local origins (local URL + local anon key only) --------------------------------------------
$js = @"
// GENERATED by scripts/start-local.ps1 - LOCAL development only. Git-ignored, never deployed.
// Used only when the app runs on localhost / 127.0.0.1 (see js/supabase.js). Standard local Supabase anon key.
export const LOCAL_SUPABASE_URL = '$api';
export const LOCAL_SUPABASE_ANON_KEY = '$anon';
"@
$existing = if (Test-Path -LiteralPath $LocalConfigJs) { Get-Content -LiteralPath $LocalConfigJs -Raw } else { '' }
if ($existing.Trim() -ne $js.Trim()) { [IO.File]::WriteAllText($LocalConfigJs, $js + "`n") }
Write-Ok "js\config.local.js points the local app at $api"

# ---- frontend static server -----------------------------------------------------------------------------------------
Write-Step "Frontend server"
$fp = Get-FrontendProcess
if ($fp) {
    Write-Ok "already running (PID $($fp.Id)) - reusing it"
} else {
    if (Test-Path -LiteralPath $FrontendPidFile) { Remove-Item -LiteralPath $FrontendPidFile -Force; Write-Host "   removed a stale PID file" }
    $owner = Get-PortOwner $FrontendPort
    if ($owner) { Fail "Port $FrontendPort is already used by $owner.`n       Close that program (or an old test server), then run this script again." }
    $serve = Join-Path $RepoRoot 'scripts\local\serve_frontend.py'
    # Start-Process joins arguments with spaces, so paths are quoted explicitly (OneDrive paths contain spaces).
    # No -Redirect*: that would make the server inherit this console's handles. The server writes its own log file.
    $p = Start-Process -FilePath $python -ArgumentList @("`"$serve`"", "`"$RepoRoot`"", "$FrontendPort", "`"$FrontendLog`"") `
        -WorkingDirectory $RepoRoot -WindowStyle Hidden -PassThru
    $up = $false
    for ($i = 0; $i -lt 20 -and -not $up; $i++) { Start-Sleep -Milliseconds 500; $up = (Test-Http $FrontendUrl) -eq 200; if ($p.HasExited) { break } }
    if (-not $up) { Fail "The frontend server did not start. See $FrontendLog" }
    $proc = Get-Process -Id $p.Id
    @{ pid = $p.Id; startTicks = (Get-StartTicks $proc); started = $proc.StartTime.ToString('s'); port = $FrontendPort; url = $FrontendUrl } |
        ConvertTo-Json | Set-Content -LiteralPath $FrontendPidFile -Encoding UTF8
    Write-Ok "started (PID $($p.Id)), listening on $($FrontendHost):$FrontendPort only"
}

# ---- summary --------------------------------------------------------------------------------------------------------
$studio = if ($sbEnv['STUDIO_URL']) { $sbEnv['STUDIO_URL'] } else { "http://127.0.0.1:$($ports.Studio)" }
$mail = if ($sbEnv['MAILPIT_URL']) { $sbEnv['MAILPIT_URL'] } elseif ($sbEnv['INBUCKET_URL']) { $sbEnv['INBUCKET_URL'] } else { "http://127.0.0.1:$($ports.Mail)" }
Write-Host ""
Write-Host "Tavern Ledger is running LOCALLY" -ForegroundColor Green
Write-Host "   Tavern Ledger     $FrontendUrl"
Write-Host "   Supabase Studio   $studio"
Write-Host "   Local API         $api"
Write-Host "   Local e-mail      $mail   (sign-in links and confirmation e-mails land here)"
Write-Host ""
Write-Host "Next:"
Write-Host "   1. Open $FrontendUrl"
Write-Host "   2. Sign in or create a local account (e.g. local-player@example.test). No real e-mail is sent."
Write-Host "      Ready-made demo accounts and items: .\scripts\seed-local-demo.ps1"
Write-Host "   3. When finished: .\scripts\stop-local.ps1   (local data is kept)"
