@echo off
rem Brother DCP-T720DW scan diagnosis (read-only, changes nothing)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0brother-scan-fix.ps1" -Pause
