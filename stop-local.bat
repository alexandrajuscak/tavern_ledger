@echo off
rem Stop LOCAL Tavern Ledger (frontend server + this project's local Supabase). Local data is kept.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\stop-local.ps1" %*
if errorlevel 1 echo. & echo Stop FAILED - read the message above.
pause
