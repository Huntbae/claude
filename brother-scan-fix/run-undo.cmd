@echo off
rem Remove the firewall rules added by brother-scan-fix (asks for admin approval)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0brother-scan-fix.ps1" -Undo -Pause
