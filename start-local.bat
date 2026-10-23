@echo off
rem Start Tavern Ledger LOCALLY (local Supabase in Docker + frontend on http://127.0.0.1:5173/).
rem Execution policy is bypassed for this one PowerShell process only; no machine setting is changed.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\start-local.ps1" %*
if errorlevel 1 (
  echo.
  echo Start FAILED - read the message above.
  pause
  exit /b 1
)
start "" "http://127.0.0.1:5173/"
echo.
echo You can close this window; Tavern Ledger keeps running until you run stop-local.bat.
pause
