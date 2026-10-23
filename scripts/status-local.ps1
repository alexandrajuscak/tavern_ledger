<#
.SYNOPSIS
  Shows the state of LOCAL Tavern Ledger development (Docker, local Supabase, frontend server, database). Read-only.
.EXAMPLE
  .\scripts\status-local.ps1
#>
[CmdletBinding()]
param()

. (Join-Path $PSScriptRoot 'local\common.ps1')
$ports = Get-LocalPorts
function Line([string]$Name, [bool]$Ok, [string]$Detail) {
    $mark = if ($Ok) { 'yes' } else { 'no ' }
    Write-Host ("   {0,-28} {1}  {2}" -f $Name, $mark, $Detail) -ForegroundColor $(if ($Ok) { 'Green' } else { 'Yellow' })
}

Write-Host "Tavern Ledger - LOCAL status  ($RepoRoot)" -ForegroundColor White
$ref = Join-Path $RepoRoot 'supabase\.temp\project-ref'
Line 'not linked to hosted project' (-not ((Test-Path -LiteralPath $ref) -and (Get-Item -LiteralPath $ref).Length -gt 0)) ''
Line 'Supabase CLI found' ([bool]$SupabaseCli) "$SupabaseCli"

$docker = $false
if (Get-Command docker -ErrorAction SilentlyContinue) {
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    $v = & docker info --format '{{.ServerVersion}}' 2>$null
    $docker = ($LASTEXITCODE -eq 0 -and $v); $ErrorActionPreference = $prev
}
Line 'Docker running' $docker $(if ($docker) { "engine $v" } else { 'start Docker Desktop' })

$stack = $docker -and (Test-StackRunning)
Line 'local Supabase running' $stack "container $(Get-DbContainer)"
$api = "http://127.0.0.1:$($ports.Api)"
$apiOk = $false
if ($stack -and $SupabaseCli) {
    $sbEnv = Get-SupabaseEnv
    if ($sbEnv) { $api = $sbEnv['API_URL']; $apiOk = (Test-Http "$api/auth/v1/health" @{ apikey = $sbEnv['ANON_KEY'] }) -eq 200 }
}
Line 'local API responds' $apiOk $api
$studioUrl = "http://127.0.0.1:$($ports.Studio)"
Line 'Studio responds' ((Test-Http $studioUrl) -in 200, 307, 308) $studioUrl
$mailUrl = "http://127.0.0.1:$($ports.Mail)"
Line 'local e-mail (Mailpit)' ((Test-Http $mailUrl) -eq 200) $mailUrl

$fp = Get-FrontendProcess
Line 'frontend server running' ([bool]$fp) $(if ($fp) { "PID $($fp.Id), $FrontendUrl" } else { $FrontendUrl })
if (-not $fp -and (Test-Path -LiteralPath $FrontendPidFile)) { Line 'stale PID file' $false "$FrontendPidFile (start-local / stop-local remove it)" }
if (-not $fp) { $o = Get-PortOwner $FrontendPort; if ($o) { Line "port $FrontendPort free" $false "used by $o" } }
Line 'js\config.local.js present' (Test-Path -LiteralPath $LocalConfigJs) 'written by start-local'

if ($stack) {
    $files = Get-MigrationFileCount
    $applied = Invoke-LocalSql 'select count(*) from supabase_migrations.schema_migrations'
    $users = Invoke-LocalSql 'select count(*) from auth.users'
    $chars = Invoke-LocalSql 'select count(*) from public.characters'
    Line 'migrations applied' ([int]$applied -eq $files) "$applied of $files"
    $exp = Get-ExpectedCatalog; $act = Get-CatalogCounts
    if ($act) {
        Line 'item catalog' ($act.items -eq $exp.items) "$($act.items) official items (expected $($exp.items))"
        Line 'lineages' ($act.lineages -eq $exp.lineages -and $act.lineage_versions -eq $exp.lineage_versions) "$($act.lineages) lineages / $($act.lineage_versions) versions (expected $($exp.lineages) / $($exp.lineage_versions))"
        Line 'spell catalog' ($act.spell_versions -eq $exp.spell_versions -and $act.class_spell_lists -eq $exp.class_spell_lists) "$($act.spells) spells / $($act.spell_versions) versions, $($act.class_spell_lists) class lists (expected $($exp.spell_versions) / $($exp.class_spell_lists))"
        Line 'class progression' ($act.class_levels -eq $exp.class_levels -and $act.slot_progression_rows -eq $exp.slot_progression_rows) "$($act.class_versions) class versions, $($act.class_levels) level rows, $($act.slot_progression_rows) slot rows (expected $($exp.class_levels) / $($exp.slot_progression_rows))"
    }
    $demo = Get-DemoFixtureCount
    Line 'demo characters' ($demo -eq 9) "$demo of 9 (add with .\scripts\seed-local-demo.ps1)"
    Write-Host "   local accounts: $users, characters: $chars"
} elseif ($docker) {
    Line 'local database volume exists' (Test-DbVolumeExists) 'kept between stop and start'
}
