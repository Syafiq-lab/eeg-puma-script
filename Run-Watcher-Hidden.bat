@echo off
setlocal
set "PSH=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
set "PS1=%~dp0uploader_watch.ps1"
for /f "usebackq delims=" %%L in (`"%PSH%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0Resolve-LogPath.ps1"`) do set "LOGFILE=%%L"
if "%LOGFILE%"=="" set "LOGFILE=%~dp0watch-upload-bootstrap.log"
echo [%DATE% %TIME%] launcher: starting (detached) uploader_watch.ps1 -Mode watch >> "%LOGFILE%" 2>&1
"%PSH%" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Command "Start-Process -WindowStyle Hidden -FilePath '%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe' -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File','%PS1%','-Mode','watch'"
echo [%DATE% %TIME%] launcher: started (detached) >> "%LOGFILE%" 2>&1
exit /b 0
