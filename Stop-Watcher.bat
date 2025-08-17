@echo off
setlocal
set "PIDFILE=%~dp0watcher.pid"
if exist "%PIDFILE%" (
  for /f "usebackq delims=" %%P in ("%PIDFILE%") do set "PID=%%P"
  if not "%PID%"=="" (
    echo stopping watcher pid %PID% ...
    taskkill /PID %PID% /F >nul 2>&1
    del /q "%PIDFILE%" >nul 2>&1
    echo stopped.
    exit /b 0
  )
)
echo pid not found; scanning...
powershell -NoProfile -ExecutionPolicy Bypass -Command "$procs = Get-CimInstance Win32_Process | Where-Object { $_.Name -like 'powershell*' -and $_.CommandLine -match 'uploader_watch\.ps1' -and $_.CommandLine -match 'Mode watch' }; if ($procs) { $procs | ForEach-Object {{ try {{ Stop-Process -Id $_.ProcessId -Force -ErrorAction Stop }} catch {{}} }}; 'stopped ' + $procs.Count } else { 'no watcher found' }"
exit /b 0
