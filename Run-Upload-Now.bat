@echo off
setlocal
set "PSH=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
set "PS1=%~dp0uploader_watch.ps1"
for /f "usebackq delims=" %%L in (`"%PSH%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0Resolve-LogPath.ps1"`) do set "LOGFILE=%%L"
if "%LOGFILE%"=="" set "LOGFILE=%~dp0watch-upload-bootstrap.log"
echo [%DATE% %TIME%] launcher: starting uploader_watch.ps1 -Mode once >> "%LOGFILE%" 2>&1
"%PSH%" -NoProfile -ExecutionPolicy Bypass -File "%PS1%" -Mode once >> "%LOGFILE%" 2>&1
set EXITCODE=%ERRORLEVEL%
echo [%DATE% %TIME%] exitcode=%EXITCODE% >> "%LOGFILE%" 2>&1
exit /b %EXITCODE%
