@echo off
setlocal

REM Single log is written by watcher_script.ps1 to "Automate-upload.log" in the runner folder.
REM Do not create extra BAT logs to keep only one log file.

:loop
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0watcher_script.ps1"
timeout /t 5 /nobreak >nul
goto :loop