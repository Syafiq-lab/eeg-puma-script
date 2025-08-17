@echo off
setlocal
set "PSH=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
"%PSH%" -NoProfile -ExecutionPolicy Bypass -Command "$raw = Get-Content -LiteralPath '%~dp0upload-many.config.json' -Raw -Encoding UTF8; $cfg = $raw | ConvertFrom-Json; $log = if ([IO.Path]::IsPathRooted($cfg.logFile)) { $cfg.logFile } else { Join-Path -Path $cfg.watchDir -ChildPath ([IO.Path]::GetFileName($cfg.logFile)) }; Write-Host 'watchDir=' $cfg.watchDir; Write-Host 'successDir=' (Join-Path -Path $cfg.watchDir -ChildPath ([IO.Path]::GetFileName($cfg.successDir))); Write-Host 'failedDir=' (Join-Path -Path $cfg.watchDir -ChildPath ([IO.Path]::GetFileName($cfg.failedDir))); Write-Host 'logFile=' $log"
exit /b 0
