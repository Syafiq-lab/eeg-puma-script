param(
  [string]$ConfigPath = "$PSScriptRoot\upload-many.config.json"
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Single unified log for the watcher
$UnifiedLogPath = Join-Path $PSScriptRoot 'Automate-upload.log'

function Ensure-Dir { param([string]$Dir) if (-not (Test-Path -LiteralPath $Dir -PathType Container)) { New-Item -ItemType Directory -Path $Dir -Force | Out-Null } }

# Load user config (no runtime/derived config; both watcher and manual use the same file)
function Load-Config {
  param([string]$Path)
  if (-not (Test-Path -LiteralPath $Path)) { throw "Config not found: $Path" }
  try { $cfg = (Get-Content -LiteralPath $Path -Raw -Encoding UTF8) | ConvertFrom-Json }
  catch { throw "Failed to parse JSON at $Path :: $($_.Exception.Message)" }

  if (-not $cfg.watchDir) { throw "Config must have 'watchDir'" }
  if ($null -eq $cfg.recursive)       { $cfg | Add-Member recursive        $false }
  if ($null -eq $cfg.initialScan)     { $cfg | Add-Member initialScan      $true }
  if (-not $cfg.batchSeconds)         { $cfg | Add-Member batchSeconds     1 }
  if ($null -eq $cfg.pollFallback)    { $cfg | Add-Member pollFallback     $true }
  if (-not $cfg.includeExt)           { $cfg | Add-Member includeExt       @(".mp4",".mov",".m4v",".webm",".avi",".mkv") }
  if (-not $cfg.filenamePattern)      { $cfg | Add-Member filenamePattern  ".*" }
  if (-not $cfg.filenamePatternFlags) { $cfg | Add-Member filenamePatternFlags "i" }
  return $cfg
}

# Minimal logger to the unified path
function Write-Log { param([string]$Message, [string]$Level = "INFO")
  try {
    $line = "{0} [{1}] {2}" -f (Get-Date -Format s), $Level, $Message
    $fs = [System.IO.File]::Open($UnifiedLogPath, 'Append', 'Write', 'ReadWrite')
    try {
      $bytes = [System.Text.Encoding]::UTF8.GetBytes($line + [Environment]::NewLine)
      $fs.Write($bytes, 0, $bytes.Length)
    } finally { $fs.Close() }
  } catch {}
}
function Write-Debug { param([string]$Message) if ($env:WATCHER_DEBUG -eq '1') { Write-Log $Message 'DEBUG' } }

# Validate config
try {
  $cfg = Load-Config -Path $ConfigPath
} catch {
  Ensure-Dir -Dir $PSScriptRoot
  Write-Log ("CONFIG-ERROR :: {0}" -f $_.Exception.Message) "ERROR"
  exit 2
}

Ensure-Dir -Dir $PSScriptRoot

Write-Log ("watcher: start (PID={0})" -f $PID)
Write-Log ("config: base={0}, recursive={1}, batch={2}s, pollFallback={3}, log={4}" -f $cfg.watchDir,$cfg.recursive,$cfg.batchSeconds,$cfg.pollFallback,$UnifiedLogPath)

# Helper filters
function Test-AllowedExt { param([string]$Path, [object]$Cfg)
  $ext = [System.IO.Path]::GetExtension($Path); if ([string]::IsNullOrWhiteSpace($ext)) { return $false }
  $ext = $ext.ToLowerInvariant()
  foreach ($e in $Cfg.includeExt) { if ($ext -eq ([string]$e).ToLowerInvariant()) { return $true } }
  return $false
}
function Test-NameMatches { param([string]$Path, [object]$Cfg)
  $name = [System.IO.Path]::GetFileName($Path)
  $options = [System.Text.RegularExpressions.RegexOptions]::None
  if ($Cfg.filenamePatternFlags -and $Cfg.filenamePatternFlags.ToString().ToLower().Contains('i')) { $options = $options -bor [System.Text.RegularExpressions.RegexOptions]::IgnoreCase }
  return [System.Text.RegularExpressions.Regex]::IsMatch($name, [string]$Cfg.filenamePattern, $options)
}
function Test-FileReady { param([string]$Path, [int]$TimeoutSec = 600, [int]$PollMs = 300)
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
    try { $fs = [System.IO.File]::Open($Path, 'Open', 'Read', 'None'); $fs.Close(); return $true } catch { Start-Sleep -Milliseconds $PollMs }
  }
  return $false
}

# Pending queue
$script:pending = [System.Collections.Concurrent.ConcurrentDictionary[string,byte]]::new()

# FileSystemWatcher
$base = [string]$cfg.watchDir
$fsw = New-Object System.IO.FileSystemWatcher
$fsw.Path = $base
$fsw.Filter = "*.*"
$fsw.IncludeSubdirectories = [bool]$cfg.recursive
$fsw.NotifyFilter = [IO.NotifyFilters]'FileName, LastWrite, CreationTime, Size'
$fsw.InternalBufferSize = 65536
$fsw.EnableRaisingEvents = $true

$createdHandler = [System.IO.FileSystemEventHandler]{ param($s,$e)
  try {
    $p = $e.FullPath
    if ((Test-AllowedExt -Path $p -Cfg $cfg) -and (Test-NameMatches -Path $p -Cfg $cfg)) { [byte]$b=0; $null=$script:pending.TryAdd($p,$b); Write-Debug ("event-created :: {0}" -f $p) }
  } catch { Write-Log ("event-created-error :: {0}" -f $_.Exception.Message) "ERROR" }
}
$changedHandler = [System.IO.FileSystemEventHandler]{ param($s,$e)
  try {
    $p = $e.FullPath
    if ((Test-AllowedExt -Path $p -Cfg $cfg) -and (Test-NameMatches -Path $p -Cfg $cfg)) { $null=$script:pending.AddOrUpdate($p,0,{param($k,$v)0}); Write-Debug ("event-changed :: {0}" -f $p) }
  } catch { Write-Log ("event-changed-error :: {0}" -f $_.Exception.Message) "ERROR" }
}
$renamedHandler = [System.IO.RenamedEventHandler]{ param($s,$e)
  try {
    $p = $e.FullPath
    if ((Test-AllowedExt -Path $p -Cfg $cfg) -and (Test-NameMatches -Path $p -Cfg $cfg)) { $null=$script:pending.AddOrUpdate($p,0,{param($k,$v)0}); Write-Debug ("event-renamed :: {0} -> {1}" -f $e.OldFullPath,$p) }
  } catch { Write-Log ("event-renamed-error :: {0}" -f $_.Exception.Message) "ERROR" }
}
$errorHandler = [System.IO.ErrorEventHandler]{ param($s,$e) try { Write-Log ("watcher-error :: {0}" -f $e.GetException().Message) "ERROR" } catch {} }

$fsw.add_Created($createdHandler)
$fsw.add_Changed($changedHandler)
$fsw.add_Renamed($renamedHandler)
$fsw.add_Error($errorHandler)

# Optional poll fallback
function Enqueue-Scan {
  try {
    $items = if ($cfg.recursive) { Get-ChildItem -LiteralPath $base -File -Recurse } else { Get-ChildItem -LiteralPath $base -File }
    foreach ($it in $items) {
      $p = $it.FullName
      if ((Test-AllowedExt -Path $p -Cfg $cfg) -and (Test-NameMatches -Path $p -Cfg $cfg)) {
        if (Test-FileReady -Path $p -TimeoutSec 1 -PollMs 200) { [byte]$b=0; $null=$script:pending.TryAdd($p,$b) }
      }
    }
  } catch { Write-Log ("poll-error :: {0}" -f $_.Exception.Message) "ERROR" }
}

# Batch timer -> call original uploader in -Mode once with the same config file
$batchTimer = New-Object System.Timers.Timer
$batchTimer.Interval = [double]([Math]::Max(1,[int]$cfg.batchSeconds) * 1000)
$batchTimer.AutoReset = $true
$batchHandler = [System.Timers.ElapsedEventHandler]{ param($s,$e)
  try {
    $keys = @($script:pending.Keys)
    if ($keys.Count -gt 0) {
      $ready = @()
      foreach ($k in $keys) {
        [byte]$out=0
        if ($script:pending.TryRemove($k,[ref]$out)) {
          if (Test-FileReady -Path $k -TimeoutSec 600 -PollMs 300) { $ready += $k }
        }
      }
      if ($ready.Count -gt 0) {
        Write-Log ("trigger-once :: {0} file(s)" -f $ready.Count)
        $args = @('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $PSScriptRoot 'uploader_watch.ps1'),'-Mode','once','-ConfigPath',$ConfigPath)
        $p = Start-Process -FilePath 'powershell.exe' -ArgumentList $args -NoNewWindow -PassThru
        $null = $p.WaitForExit()
        $code = 0; try { $code = $p.ExitCode } catch { $code = -1 }
        if ($code -ne 0) { Write-Log ("once-exitcode={0}" -f $code) "WARN" }
      }
    }
  } catch { Write-Log ("batch-error :: {0}" -f $_.Exception.Message) "ERROR" }
}
$batchTimer.add_Elapsed($batchHandler)
$batchTimer.Start()

# Initial scan (quiet unless failed)
if ($cfg.initialScan) {
  Write-Log "initial-scan: trigger"
  try {
    $args = @('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $PSScriptRoot 'uploader_watch.ps1'),'-Mode','once','-ConfigPath',$ConfigPath)
    $p = Start-Process -FilePath 'powershell.exe' -ArgumentList $args -NoNewWindow -PassThru
    $null = $p.WaitForExit()
    $code = 0; try { $code = $p.ExitCode } catch { $code = -1 }
    if ($code -ne 0) { Write-Log ("once-exitcode={0}" -f $code) "WARN" }
  } catch { Write-Log ("initial-scan-error :: {0}" -f $_.Exception.Message) "ERROR" }
}

# Keep alive
try {
  Write-Log ("watching: {0} (recursive={1}, batch={2}s, pollFallback={3})" -f $base, $cfg.recursive, $cfg.batchSeconds, $cfg.pollFallback)
  while ($true) { Start-Sleep -Seconds 1; [System.GC]::KeepAlive($fsw) }
} finally {
  try { $batchTimer.Stop(); $batchTimer.remove_Elapsed($batchHandler); $batchTimer.Dispose() } catch {}
  try { $fsw.remove_Created($createdHandler); $fsw.remove_Changed($changedHandler); $fsw.remove_Renamed($renamedHandler); $fsw.remove_Error($errorHandler); $fsw.EnableRaisingEvents=$false; $fsw.Dispose() } catch {}
  Write-Log "watcher: stopped"
}
