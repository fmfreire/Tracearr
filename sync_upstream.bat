@echo off
setlocal
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\sync-upstream.ps1 %*
pause
