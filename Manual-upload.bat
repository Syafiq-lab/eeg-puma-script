@echo off
setlocal

set "PSH=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
set "SCRIPT=%~dp0uploader_watch.ps1"
set "CFG=%~dp0upload-many.config.json"

REM Unblock scripts to avoid the Windows "Open File - Security Warning" prompt
"%PSH%" -NoLogo -NoProfile -ExecutionPolicy Bypass -Command ^
  "Get-ChildItem -LiteralPath '%~dp0' -Filter *.ps1 | ForEach-Object { try { Unblock-File -LiteralPath $_.FullName -ErrorAction Stop } catch {} }"

REM Run once, no confirmations, no admin prompt; logging is handled inside the script (manual-upload.log)
"%PSH%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" -Mode once -ConfigPath "%CFG%"
set EXITCODE=%ERRORLEVEL%
exit /b %EXITCODE%