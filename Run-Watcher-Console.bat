@echo off
setlocal enabledelayedexpansion

REM CONFIG
set "LOG_DIR=C:\Media\incoming\logs"
if not exist "%LOG_DIR%" mkdir "%LOG_DIR%"
for /f "tokens=1-3 delims=/ " %%a in ("%date%") do set YMD=%%c-%%a-%%b
set "LOG_FILE=%LOG_DIR%\watcher-%YMD%.log"

echo [%date% %time%] launcher: starting watcher >> "%LOG_FILE%"

:loop
echo [%date% %time%] launcher: starting watcher_script.ps1 >> "%LOG_FILE%"
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0watcher_script.ps1" 1>>"%LOG_FILE%" 2>&1
echo [%date% %time%] exitcode=%ERRORLEVEL% >> "%LOG_FILE%"
timeout /t 5 /nobreak >nul
goto :loop