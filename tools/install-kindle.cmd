@echo off
REM Builds and installs goodreadskosync.koplugin onto a connected Kindle (prefers E:).
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install-kindle.ps1" %*
echo.
pause
