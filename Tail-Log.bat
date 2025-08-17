@echo off
setlocal
for /f "usebackq delims=" %%L in (`"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0Resolve-LogPath.ps1"`) do set "LOGFILE=%%L"
if exist "%LOGFILE%" (
  start "" notepad "%LOGFILE%"
) else (
  echo Log file not found: %LOGFILE%
  if exist "%~dp0watch-upload-bootstrap.log" start "" notepad "%~dp0watch-upload-bootstrap.log"
)
exit /b 0
