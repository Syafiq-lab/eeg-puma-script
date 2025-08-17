param([string]$ConfigPath = "$PSScriptRoot\upload-many.config.json")
try {
  $raw = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8
  $cfg = $raw | ConvertFrom-Json
  $base = [string]$cfg.watchDir
  if ([string]::IsNullOrWhiteSpace($base)) { $base = $PSScriptRoot }
  $log = [string]$cfg.logFile
  if ([string]::IsNullOrWhiteSpace($log)) { $log = "watch-upload.log" }
  if (-not [System.IO.Path]::IsPathRooted($log)) {
    $log = Join-Path -Path $base -ChildPath ([System.IO.Path]::GetFileName($log))
  }
} catch {
  $log = Join-Path -Path $PSScriptRoot -ChildPath "watch-upload-bootstrap.log"
}
[Console]::WriteLine([System.IO.Path]::GetFullPath($log))
