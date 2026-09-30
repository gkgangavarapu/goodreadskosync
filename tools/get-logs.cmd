@echo off
REM Double-click this (or run it from cmd) to collect Goodreads plugin logs
REM from a connected Kindle. Output is also saved to Downloads\goodreadskosync-debug.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0get-logs.ps1"
echo.
pause
