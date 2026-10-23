<#
.SYNOPSIS
  Stops LOCAL Tavern Ledger: the frontend server started by start-local and this project's local Supabase containers.

.DESCRIPTION
  Keeps the local database (Docker volumes are NOT deleted, nothing is reset). Does not touch other Docker containers
  or other Supabase projects. Safe to run when everything is already stopped.

.EXAMPLE
  .\scripts\stop-local.ps1
#>
[CmdletBinding()]
param()

. (Join-Path $PSScriptRoot 'local\common.ps1')

Write-Host "Tavern Ledger - LOCAL development stop" -ForegroundColor White
Assert-LocalOnly
$stopped = @()

Write-Step "Frontend server"
$fp = Get-FrontendProcess
if ($fp) {
    Stop-Process -Id $fp.Id -Force
    $stopped += "frontend server (PID $($fp.Id), port $FrontendPort)"
    Write-Ok "stopped PID $($fp.Id)"
} else {
    Write-Host "   not running (started by start-local)"
    $owner = Get-PortOwner $FrontendPort
    if ($owner) { Write-Warn2 "port $FrontendPort is used by $owner, which start-local did not start - left alone" }
}
if (Test-Path -LiteralPath $FrontendPidFile) { Remove-Item -LiteralPath $FrontendPidFile -Force; Write-Host "   removed PID file" }

Write-Step "Local Supabase (project '$(Get-ProjectId)')"
$dockerUp = $true
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { $dockerUp = $false }
else {
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    & docker info --format '{{.ServerVersion}}' 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) { $dockerUp = $false }
    $ErrorActionPreference = $prev
}
if (-not $dockerUp) {
    Write-Host "   Docker Desktop is not running, so the local Supabase containers are not running either."
} elseif (-not $SupabaseCli) {
    Fail "Supabase CLI not found; cannot stop the local stack. Expected under ..\.tools\supabase-*\supabase.exe"
} elseif (-not (Test-StackRunning)) {
    Write-Host "   not running"
} else {
    # plain `supabase stop`: this project only, data volumes kept (never --no-backup, never --all)
    $code = Invoke-Supabase stop
    if ($code -ne 0) { Fail "supabase stop failed (exit $code). Nothing was deleted. Check Docker Desktop." }
    $stopped += "local Supabase containers of project '$(Get-ProjectId)'"
    Write-Ok "stopped"
}

Write-Host ""
if ($stopped.Count) { Write-Host "Stopped:" -ForegroundColor Green; $stopped | ForEach-Object { Write-Host "   - $_" } }
else { Write-Host "Nothing was running." -ForegroundColor Green }
Write-Host "Local data was preserved (database volume kept). Start again with: .\scripts\start-local.ps1"
