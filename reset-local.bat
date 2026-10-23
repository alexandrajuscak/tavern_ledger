@echo off
rem DELETE all LOCAL Tavern Ledger database data and rebuild it (migrations + reference seed). Asks for confirmation.
rem The hosted Supabase project is not affected.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\reset-local.ps1" %*
if errorlevel 1 echo. & echo Reset FAILED - read the message above.
pause
