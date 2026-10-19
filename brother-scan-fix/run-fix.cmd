@echo off
rem Brother DCP-T720DW scan diagnosis + automatic repair (asks for admin approval)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0brother-scan-fix.ps1" -Fix -Pause
