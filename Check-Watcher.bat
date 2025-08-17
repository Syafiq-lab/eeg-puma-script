@echo off
setlocal
set "PIDFILE=%~dp0watcher.pid"
if exist "%PIDFILE%" (
  for /f "usebackq delims=" %%P in ("%PIDFILE%") do set "PID=%%P"
  if not "%PID%"=="" (
    echo watcher pid: %PID%
    tasklist /FI "PID eq %PID%"
  ) else (
    echo watcher.pid is empty
  )
) else (
  echo watcher.pid not found, falling back to process scan...
  powershell -NoProfile -ExecutionPolicy Bypass -Command "$procs = Get-CimInstance Win32_Process | Where-Object { $_.Name -like 'powershell*' -and $_.CommandLine -match 'uploader_watch\.ps1' -and $_.CommandLine -match 'Mode watch' }; if ($procs) { $procs | Select-Object ProcessId, Name, CommandLine, CreationDate | Format-Table -AutoSize } else { 'no watcher found' }"
)
exit /b 0
