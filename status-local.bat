@echo off
rem Show the state of LOCAL Tavern Ledger development. Read-only.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\status-local.ps1" %*
pause
