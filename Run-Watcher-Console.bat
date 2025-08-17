@echo off
setlocal
set "PSH=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
set "PS1=%~dp0uploader_watch.ps1"
"%PSH%" -NoProfile -ExecutionPolicy Bypass -File "%PS1%" -Mode watch
exit /b %ERRORLEVEL%
