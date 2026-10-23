# Shared helpers for the LOCAL development scripts (start-local, stop-local, reset-local, status-local, seed-local-demo).
# Dot-sourced, never run directly. Everything here targets the local Supabase stack in Docker on this computer only:
# the Supabase CLI wrapper below refuses every command that could reach a hosted project.
# Works in Windows PowerShell 5.1 and PowerShell 7+.

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:RepoRoot   = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$script:ConfigToml = Join-Path $RepoRoot 'supabase\config.toml'
$script:RuntimeDir = Join-Path $RepoRoot '.local'                 # git-ignored: PID file, logs
$script:FrontendPidFile = Join-Path $RuntimeDir 'frontend.json'
$script:FrontendLog     = Join-Path $RuntimeDir 'frontend.log'
$script:LocalConfigJs   = Join-Path $RepoRoot 'js\config.local.js' # git-ignored: local URL + local anon key
$script:FrontendPort = 5173                                         # same port as supabase/tests/run_browser_local.sh
$script:FrontendHost = '127.0.0.1'
$script:FrontendUrl  = "http://$($FrontendHost):$FrontendPort/"
$script:ExpectedItemCount = 1146

# Supabase CLI: $env:SUPABASE_CLI, else the copy downloaded next to the repository (..\.tools\supabase-<version>\supabase.exe).
function Get-SupabaseCli {
    if ($env:SUPABASE_CLI) { $candidates = @($env:SUPABASE_CLI) }
    else {
        $tools = Join-Path (Split-Path $RepoRoot -Parent) '.tools'
        $candidates = @(Join-Path $tools 'supabase-2.118.0\supabase.exe')
        if (Test-Path -LiteralPath $tools) {
            $candidates += Get-ChildItem -LiteralPath $tools -Directory -Filter 'supabase-*' -ErrorAction SilentlyContinue |
                Sort-Object Name -Descending | ForEach-Object { Join-Path $_.FullName 'supabase.exe' }
        }
    }
    foreach ($c in $candidates) { if (Test-Path -LiteralPath $c -PathType Leaf) { return (Resolve-Path -LiteralPath $c).Path } }
    return $null
}

function Write-Step([string]$Text) { Write-Host "`n== $Text" -ForegroundColor Cyan }
function Write-Ok([string]$Text)   { Write-Host "   OK    $Text" -ForegroundColor Green }
function Write-Warn2([string]$Text){ Write-Host "   WARN  $Text" -ForegroundColor Yellow }
function Fail([string]$Text) {
    Write-Host "`nERROR: $Text" -ForegroundColor Red
    exit 1
}

# ---- config.toml (read-only, simple "key = value" lookups inside a [section]) -----------------------------------
function Get-TomlValue([string]$Section, [string]$Key) {
    $inSection = $false
    foreach ($line in Get-Content -LiteralPath $ConfigToml) {
        $t = $line.Trim()
        if ($t -match '^\[(.+)\]$') { $inSection = ($Matches[1] -eq $Section); continue }
        if ($inSection -and $t -match "^$([regex]::Escape($Key))\s*=\s*(.+)$") { return $Matches[1].Trim().Trim('"') }
    }
    return $null
}

function Get-LocalPorts {
    [pscustomobject]@{
        ProjectId = Get-ProjectId
        Api       = [int](Get-TomlValue 'api' 'port')
        Db        = [int](Get-TomlValue 'db' 'port')
        Studio    = [int](Get-TomlValue 'studio' 'port')
        Mail      = [int](Get-TomlValue 'local_smtp' 'port')
    }
}
# project_id sits above the first [section].
function Get-ProjectId {
    foreach ($line in Get-Content -LiteralPath $ConfigToml) {
        $t = $line.Trim()
        if ($t -match '^\[') { break }
        if ($t -match '^project_id\s*=\s*"(.+)"') { return $Matches[1] }
    }
    return $null
}

# ---- safety ------------------------------------------------------------------------------------------------------
function Assert-LocalOnly {
    if (-not (Test-Path -LiteralPath $ConfigToml)) { Fail "supabase\config.toml not found in $RepoRoot." }
    $ref = Join-Path $RepoRoot 'supabase\.temp\project-ref'
    if ((Test-Path -LiteralPath $ref) -and ((Get-Item -LiteralPath $ref).Length -gt 0)) {
        Fail "This checkout is LINKED to a hosted Supabase project (supabase\.temp\project-ref exists).`n       The local scripts refuse to run while linked. Remove that file to unlink (it only affects this folder)."
    }
}

# The only Supabase CLI commands these scripts may run. Anything else (link, db push, --linked, --db-url, login, ...) is refused.
function Assert-AllowedCli([string[]]$CliArgs) {
    $joined = ($CliArgs -join ' ')
    foreach ($bad in @('--linked', '--db-url', 'link', 'push', 'login', 'deploy', 'repair', 'pull', 'dump', 'secrets', 'projects', 'branches')) {
        if ($CliArgs -contains $bad) { throw "Refusing Supabase CLI command '$joined': '$bad' is not allowed in local scripts." }
    }
    $ok = ($CliArgs[0] -in @('start', 'stop', 'status')) -or
          ($CliArgs[0] -eq 'db' -and $CliArgs[1] -eq 'reset' -and $CliArgs -contains '--local') -or
          ($CliArgs[0] -eq 'migration' -and $CliArgs[1] -in @('up', 'list') -and $CliArgs -contains '--local')
    if (-not $ok) { throw "Refusing Supabase CLI command '$joined': not on the local allow-list." }
    if ($CliArgs[0] -eq 'stop' -and ($CliArgs -contains '--no-backup' -or $CliArgs -contains '--all')) {
        throw "Refusing 'supabase $joined': it would delete local data or stop other projects."
    }
}

# Runs the CLI in the repository root and streams its output. Returns the exit code.
function Invoke-Supabase {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$CliArgs)
    Assert-AllowedCli $CliArgs
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    Push-Location -LiteralPath $RepoRoot
    try {
        & $script:SupabaseCli @CliArgs 2>&1 | ForEach-Object {
            $s = "$_"
            # `supabase start` ends with a status block that includes the local secret / service_role keys: never echo it.
            if ($s -match '(?i)service_role|secret|_KEY|jwt|eyJ|access key') { Write-Host "   (local status with keys hidden - URLs are listed below)" }
            elseif ($s -notmatch 'new version of Supabase CLI|recommend updating regularly') { Write-Host "   $s" }
        }
        return $LASTEXITCODE
    } finally { Pop-Location; $ErrorActionPreference = $prev }
}

# `supabase status -o env` as a hashtable. Secret values stay in memory and are never printed.
function Get-SupabaseEnv {
    Assert-AllowedCli @('status')
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    Push-Location -LiteralPath $RepoRoot
    try { $lines = & $script:SupabaseCli status -o env 2>$null; $code = $LASTEXITCODE }
    finally { Pop-Location; $ErrorActionPreference = $prev }
    if ($code -ne 0) { return $null }
    $h = @{}
    foreach ($l in $lines) { if ("$l" -match '^([A-Z_]+)="?(.*?)"?$') { $h[$Matches[1]] = $Matches[2] } }
    if (-not $h.ContainsKey('API_URL')) { return $null }
    if ($h['API_URL'] -notmatch '^http://(127\.0\.0\.1|localhost):\d+$') { Fail "Supabase reports a non-local API URL ($($h['API_URL'])). Refusing to continue." }
    return $h
}

function Get-JwtRole([string]$Jwt) {
    try {
        $p = $Jwt.Split('.')[1].Replace('-', '+').Replace('_', '/')
        while ($p.Length % 4) { $p += '=' }
        return ([System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($p)) | ConvertFrom-Json).role
    } catch { return $null }
}

# ---- Docker --------------------------------------------------------------------------------------------------------
function Assert-Docker {
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        Fail "Docker is not installed (the 'docker' command was not found).`n       Install Docker Desktop for Windows, start it, then run this script again."
    }
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    $v = & docker info --format '{{.ServerVersion}}' 2>$null; $code = $LASTEXITCODE
    $ErrorActionPreference = $prev
    if ($code -ne 0 -or -not $v) {
        $desktop = Get-Process -Name 'Docker Desktop' -ErrorAction SilentlyContinue
        if ($desktop) { Fail "Docker Desktop is starting but its engine is not ready yet.`n       Wait until Docker Desktop shows 'Engine running', then run this script again." }
        Fail "Docker Desktop is not running.`n       Start Docker Desktop from the Start menu, wait until it shows 'Engine running', then run this script again."
    }
    return "$v"
}

function Get-DbContainer { "supabase_db_$(Get-ProjectId)" }

function Test-StackRunning {
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    $s = & docker ps --filter "name=^$(Get-DbContainer)$" --format '{{.Status}}' 2>$null
    $ErrorActionPreference = $prev
    return [bool]("$s" -match '^Up')
}

function Test-DbVolumeExists {
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    $v = & docker volume ls --filter "name=^$(Get-DbContainer)$" --format '{{.Name}}' 2>$null
    $ErrorActionPreference = $prev
    return [bool]$v
}

# Read-only query inside the local database container (docker exec, no network port, no credentials needed).
function Invoke-LocalSql([string]$Sql) {
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    $out = & docker exec (Get-DbContainer) psql -U postgres -At -q -c $Sql 2>$null
    $ErrorActionPreference = $prev
    if ($LASTEXITCODE -ne 0) { return $null }
    return ("$out").Trim()
}

# ---- reference catalog: expected counts come from the generated reports (data/reports/*_seed_summary.json) ------------
function Get-SeedFiles {
    $line = (Get-Content -LiteralPath $ConfigToml | Where-Object { $_ -match '^\s*sql_paths\s*=' } | Select-Object -First 1)
    if (-not $line) { return @() }
    return @([regex]::Matches($line, '"\./([^"]+)"') | ForEach-Object { Join-Path (Join-Path $RepoRoot 'supabase') $_.Groups[1].Value })
}

function Get-ExpectedCatalog {
    $rep = Join-Path $RepoRoot 'data\reports'
    $read = { param($f) $p = Join-Path $rep $f; if (Test-Path -LiteralPath $p) { Get-Content -LiteralPath $p -Raw | ConvertFrom-Json } else { $null } }
    $lin = & $read 'lineage_seed_summary.json'; $sp = & $read 'spell_seed_summary.json'; $cl = & $read 'class_seed_summary.json'
    $e = [ordered]@{ items = $ExpectedItemCount }
    if ($lin) { $e.lineages = [int]$lin.lineages; $e.lineage_versions = [int]$lin.versions }
    if ($sp)  { $e.spells = [int]$sp.canonical_spells; $e.spell_versions = [int]$sp.spell_versions; $e.class_spell_lists = @($sp.class_lists.PSObject.Properties).Count }
    if ($cl)  { $e.class_versions = [int]$cl.class_versions; $e.class_levels = [int]$cl.class_version_levels; $e.slot_progression_rows = [int]$cl.progression_levels }
    return $e
}

# One cheap query for every catalog count. Missing tables (an older schema) count as -1.
function Get-CatalogCounts {
    $sql = "select concat_ws(',', " +
      "(select count(*) from public.items where data_source_id is distinct from 'homebrew'), " +
      "case when to_regclass('public.lineages') is null then -1 else (select count(*) from public.lineages) end, " +
      "case when to_regclass('public.lineage_versions') is null then -1 else (select count(*) from public.lineage_versions) end, " +
      "case when to_regclass('public.catalog_spells') is null then -1 else (select count(*) from public.catalog_spells where owner_id is null) end, " +
      "case when to_regclass('public.spell_versions') is null then -1 else (select count(*) from public.spell_versions v join public.catalog_spells c on c.id = v.spell_id where c.owner_id is null) end, " +
      "case when to_regclass('public.class_spell_lists') is null then -1 else (select count(*) from public.class_spell_lists) end, " +
      "case when to_regclass('public.class_version_levels') is null then -1 else (select count(distinct class_version_id) from public.class_version_levels) end, " +
      "case when to_regclass('public.class_version_levels') is null then -1 else (select count(*) from public.class_version_levels) end, " +
      "case when to_regclass('public.spell_slot_progression_levels') is null then -1 else (select count(*) from public.spell_slot_progression_levels) end)"
    $v = Invoke-LocalSql $sql
    if (-not $v) { return $null }
    $n = $v.Split(',')
    return [ordered]@{ items = [int]$n[0]; lineages = [int]$n[1]; lineage_versions = [int]$n[2]; spells = [int]$n[3]; spell_versions = [int]$n[4]
                       class_spell_lists = [int]$n[5]; class_versions = [int]$n[6]; class_levels = [int]$n[7]; slot_progression_rows = [int]$n[8] }
}

# Names of catalog parts that differ from the generated reports (empty = complete).
function Test-Catalog([switch]$Quiet) {
    $exp = Get-ExpectedCatalog; $act = Get-CatalogCounts
    if (-not $act) { if (-not $Quiet) { Write-Warn2 'reference catalog: could not be read' }; return @('all') }
    $bad = @()
    foreach ($k in $exp.Keys) {
        if ($act[$k] -ne $exp[$k]) { $bad += $k; if (-not $Quiet) { Write-Warn2 ("reference catalog: {0} = {1} (expected {2})" -f $k, $act[$k], $exp[$k]) } }
    }
    if (-not $bad -and -not $Quiet) {
        Write-Ok ("reference catalog: {0} items, {1} lineages / {2} versions, {3} spells / {4} versions, {5} class versions / {6} level rows, {7} slot rows" -f `
            $act.items, $act.lineages, $act.lineage_versions, $act.spells, $act.spell_versions, $act.class_versions, $act.class_levels, $act.slot_progression_rows)
    }
    return $bad
}

# Loads the reference seeds of supabase/config.toml in their configured order into the LOCAL database. Every seed is
# idempotent (upserts by stable ids), so local accounts and characters are kept.
function Invoke-ReferenceSeeds {
    foreach ($f in Get-SeedFiles) {
        Write-Host "   loading $(Split-Path $f -Leaf)..."
        $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        Get-Content -LiteralPath $f -Raw | & docker exec -i -e 'PGOPTIONS=-c client_min_messages=warning' (Get-DbContainer) psql -U postgres -v ON_ERROR_STOP=1 -q 2>&1 | Out-Null
        $code = $LASTEXITCODE; $ErrorActionPreference = $prev
        if ($code -ne 0) { Fail "Loading $(Split-Path $f -Leaf) failed. A clean rebuild: .\scripts\reset-local.ps1 (deletes local data)." }
    }
}

# Demo characters present (by name, owned by the demo player; see scripts/local/seed_local_demo.py)
function Get-DemoFixtureCount {
    $names = "'Local Hero','Local Sidekick','Local Spellcaster','Local Wizard','Local Artificer','Local Paladin','Local Warlock','Local Multiclass','Local Feature Tester'"
    $n = Invoke-LocalSql "select count(*) from public.characters c join auth.users u on u.id = c.owner_id where u.email = 'local-player@example.test' and c.name in ($names)"
    if ($n) { return [int]$n } else { return 0 }
}

function Get-MigrationFileCount { @(Get-ChildItem -LiteralPath (Join-Path $RepoRoot 'supabase\migrations') -Filter '*.sql').Count }

function Test-Http([string]$Url, [hashtable]$Headers = @{}) {
    try {
        $r = Invoke-WebRequest -Uri $Url -Headers $Headers -UseBasicParsing -TimeoutSec 5 -Method Get
        return [int]$r.StatusCode
    } catch {
        # StrictMode: connection errors (nothing listening) have no Response property at all
        $resp = $_.Exception.PSObject.Properties['Response']
        if ($resp -and $resp.Value) { return [int]$resp.Value.StatusCode }
        return 0
    }
}

# ---- frontend static server ---------------------------------------------------------------------------------------
function Get-FrontendProcess {
    if (-not (Test-Path -LiteralPath $FrontendPidFile)) { return $null }
    try { $info = Get-Content -LiteralPath $FrontendPidFile -Raw | ConvertFrom-Json } catch { return $null }
    $p = Get-Process -Id $info.pid -ErrorAction SilentlyContinue
    # guard against PID reuse: same start time and a python process
    if ($p -and $p.ProcessName -match '^py(thon)?' -and (Get-StartTicks $p) -eq "$($info.startTicks)") { return $p }
    return $null
}

# Start time as a plain string (ConvertFrom-Json in PowerShell 7 would turn an ISO date into a DateTime).
function Get-StartTicks($Process) { "$($Process.StartTime.ToUniversalTime().Ticks)" }

function Get-PortOwner([int]$Port) {
    $c = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $c) { return $null }
    $p = Get-Process -Id $c.OwningProcess -ErrorAction SilentlyContinue
    if ($p) { return "$($p.ProcessName) (PID $($p.Id))" } else { return "PID $($c.OwningProcess)" }
}

function Get-Python {
    foreach ($name in @('python', 'py')) {
        $cmd = Get-Command $name -ErrorAction SilentlyContinue
        if ($cmd -and $cmd.Source -notmatch 'WindowsApps') { return $cmd.Source }
    }
    return $null
}

$script:SupabaseCli = Get-SupabaseCli
