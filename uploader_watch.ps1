param(
  [ValidateSet('watch','once')] [string]$Mode = 'watch',
  [string]$ConfigPath = "$PSScriptRoot\upload-many.config.json",
  [switch]$PrintLogPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# ---- Bootstrap log (always available, even if config fails) ----
$BootstrapLog = Join-Path -Path $PSScriptRoot -ChildPath "watch-upload-bootstrap.log"
function Write-Boot { param([string]$m) try {
  $line = "{0} [BOOT] {1}" -f (Get-Date -Format s), $m
  Add-Content -LiteralPath $BootstrapLog -Value $line -Encoding UTF8
} catch {} }

Write-Boot "uploader_watch.ps1 starting (Mode=$Mode; PID=$PID; PSVersion=$($PSVersionTable.PSVersion.ToString()))"

function Ensure-Dir { param([string]$Dir) if (-not (Test-Path -LiteralPath $Dir -PathType Container)) { New-Item -ItemType Directory -Path $Dir -Force | Out-Null } }
function Is-Rooted   { param([string]$Path) return [System.IO.Path]::IsPathRooted([string]$Path) }

function Load-Config {
  param([string]$Path)
  if (-not (Test-Path -LiteralPath $Path)) { throw "Config file not found: $Path" }
  try { $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8; $cfg = $raw | ConvertFrom-Json }
  catch { throw "Failed to parse JSON config at $Path. Error: $($_.Exception.Message)" }
  if (-not $cfg.serverBase -or -not $cfg.endpoint) { throw "Config must have serverBase and endpoint" }
  if (-not $cfg.includeExt)           { $cfg | Add-Member includeExt           @(".mp4",".mov",".m4v",".webm",".avi",".mkv") }
  if (-not $cfg.filenamePattern)      { $cfg | Add-Member filenamePattern      "^(?<id>[A-Z0-9]{3}-[A-Z0-9]{3})(?:[ _()\\-].+)?\\.(mp4|mov|m4v|webm|avi|mkv)$" }
  if (-not $cfg.filenamePatternFlags) { $cfg | Add-Member filenamePatternFlags "i" }
  if ($null -eq $cfg.recursive)       { $cfg | Add-Member recursive            $false }
  if ($null -eq $cfg.initialScan)     { $cfg | Add-Member initialScan          $true }
  if (-not $cfg.batchSeconds)         { $cfg | Add-Member batchSeconds         5 }
  if (-not $cfg.heartbeatSeconds)     { $cfg | Add-Member heartbeatSeconds     10 }
  if ($null -eq $cfg.pollFallback)    { $cfg | Add-Member pollFallback         $true }
  if (-not $cfg.successDir)           { $cfg | Add-Member successDir           "processed" }
  if (-not $cfg.failedDir)            { $cfg | Add-Member failedDir            "failed" }
  if (-not $cfg.logFile)              { $cfg | Add-Member logFile              "watch-upload.log" }
  return $cfg
}

# Try load config; on failure, write to bootstrap and exit with a message to the bootstrap log
try {
  $cfg = Load-Config -Path $ConfigPath
} catch {
  Write-Boot ("CONFIG-ERROR :: {0}" -f $_.Exception.Message)
  if ($PrintLogPath) { [Console]::WriteLine( (Join-Path -Path $PSScriptRoot -ChildPath "watch-upload.log") ); exit 0 }
  exit 2
}

# Compute dirs and log path
$base = [string]$cfg.watchDir
if ([string]::IsNullOrWhiteSpace($base)) { Write-Boot "CONFIG-ERROR :: watchDir must be set"; exit 3 }
$successLeaf = Split-Path -Path ([string]$cfg.successDir) -Leaf; if ([string]::IsNullOrWhiteSpace($successLeaf)) { $successLeaf = "processed" }
$failedLeaf  = Split-Path -Path ([string]$cfg.failedDir)  -Leaf; if ([string]::IsNullOrWhiteSpace($failedLeaf))  { $failedLeaf  = "failed" }
$SuccessDir = Join-Path -Path $base -ChildPath $successLeaf
$FailedDir  = Join-Path -Path $base -ChildPath $failedLeaf

$LogPath = [string]$cfg.logFile
if (-not (Is-Rooted $LogPath)) { $LogPath = Join-Path -Path $base -ChildPath ([System.IO.Path]::GetFileName([string]$cfg.logFile)) }
Ensure-Dir -Dir ([System.IO.Path]::GetDirectoryName($LogPath))

# Promote bootstrap lines into main log
try {
  if (Test-Path -LiteralPath $BootstrapLog) {
    $boot = Get-Content -LiteralPath $BootstrapLog -Raw -Encoding UTF8
    if ($boot) { Add-Content -LiteralPath $LogPath -Value $boot -Encoding UTF8 }
  }
} catch {}

function Write-Log { param([string]$Message, [string]$Level = "INFO")
  $line = "{0} [{1}] {2}" -f (Get-Date -Format s), $Level, $Message
  for ($i=0; $i -lt 3; $i++) {
    try {
      $fs = [System.IO.File]::Open($LogPath, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
      try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($line + [Environment]::NewLine)
        $fs.Write($bytes, 0, $bytes.Length)
        break
      } finally { $fs.Close() }
    } catch {
      Start-Sleep -Milliseconds (50 * ($i+1))
    }
  }
}

# Avoid reacting to our own log
$LogLeaf = [System.IO.Path]::GetFileName($LogPath)

# PID file
$PidPath = Join-Path -Path $PSScriptRoot -ChildPath "watcher.pid"
try { Set-Content -LiteralPath $PidPath -Value $PID -Encoding ASCII -NoNewline } catch {}

# Banner
Write-Log ("impl=delegates; version=watchfix-v10 (PID={0})" -f $PID)
Ensure-Dir -Dir $base
Ensure-Dir -Dir $SuccessDir
Ensure-Dir -Dir $FailedDir

Write-Log ("start: mode={0}, base={1}, success={2}, failed={3}, recursive={4}, batch={5}s, heartbeat={6}s, pollFallback={7}" -f $Mode,$base,$SuccessDir,$FailedDir,$cfg.recursive,$cfg.batchSeconds,$cfg.heartbeatSeconds,$cfg.pollFallback)

function Test-AllowedExt { param([string]$Path, [object]$Cfg)
  $ext = [System.IO.Path]::GetExtension($Path)
  if ([string]::IsNullOrWhiteSpace($ext)) { return $false }
  $ext = $ext.ToLowerInvariant()
  foreach ($e in $Cfg.includeExt) { if ($ext -eq ([string]$e).ToLowerInvariant()) { return $true } }
  return $false
}
function Test-NameMatches { param([string]$Path, [object]$Cfg)
  $name = [System.IO.Path]::GetFileName($Path)
  if ($name -eq $LogLeaf) { return $false } # ignore our log file
  $options = [System.Text.RegularExpressions.RegexOptions]::None
  if ($Cfg.filenamePatternFlags -and $Cfg.filenamePatternFlags.ToString().ToLower().Contains('i')) {
    $options = $options -bor [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
  }
  return [System.Text.RegularExpressions.Regex]::IsMatch($name, [string]$Cfg.filenamePattern, $options)
}

function Test-FileReady { param([string]$Path, [int]$TimeoutSec = 600, [int]$PollMs = 300)
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
    try { $fs = [System.IO.FileStream]::new($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::None); $fs.Close(); return $true }
    catch { Start-Sleep -Milliseconds $PollMs }
  }
  return $false
}

function Try-LoadHttpClient {
  try { Add-Type -AssemblyName System.Net.Http -ErrorAction Stop } catch {
    try { [void][System.Reflection.Assembly]::Load("System.Net.Http") } catch {}
  }
  return ([Type]::GetType("System.Net.Http.HttpClient, System.Net.Http") -ne $null) -and ([Type]::GetType("System.Net.Http.HttpClientHandler, System.Net.Http") -ne $null)
}
function New-HttpClient {
  param([object]$Cfg)
  if (-not (Try-LoadHttpClient)) { return $null }
  $handler = New-Object System.Net.Http.HttpClientHandler
  $client  = New-Object System.Net.Http.HttpClient($handler)
  if ($Cfg.authToken -and $Cfg.authToken.ToString().Trim().Length -gt 0) {
    $client.DefaultRequestHeaders.Authorization = New-Object System.Net.Http.Headers.AuthenticationHeaderValue("Bearer", [string]$Cfg.authToken)
  }
  return $client
}
function Join-BaseUri { param([string]$Base, [string]$Endpoint)
  if ([string]::IsNullOrWhiteSpace($Base)) { throw "serverBase missing" }
  if ([string]::IsNullOrWhiteSpace($Endpoint)) { throw "endpoint missing" }
  $b = $Base.TrimEnd('/'); $e = if ($Endpoint.StartsWith('/')) { $Endpoint } else { "/" + $Endpoint }; return $b + $e
}
function Send-MultipartHttpClient {
  param([object]$Cfg, [string[]]$Files)
  $uri = Join-BaseUri -Base ([string]$Cfg.serverBase) -Endpoint ([string]$Cfg.endpoint)
  $client = $null; $content = $null
  try {
    $client  = New-HttpClient -Cfg $Cfg
    if ($client -eq $null) { return $null } # signal "use fallback"
    $content = New-Object System.Net.Http.MultipartFormDataContent
    foreach ($f in $Files) {
      $bytes = [System.IO.File]::ReadAllBytes($f)
      $fileContent = New-Object System.Net.Http.ByteArrayContent($bytes)
      $fileContent.Headers.ContentType = New-Object System.Net.Http.Headers.MediaTypeHeaderValue("application/octet-stream")
      $content.Add($fileContent, "file", ([System.IO.Path]::GetFileName($f)))
    }
    $response = $client.PostAsync($uri, $content).GetAwaiter().GetResult()
    $body = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
    return @{ IsSuccess = [bool]$response.IsSuccessStatusCode; Body = $body }
  } finally { if ($content) { $content.Dispose() }; if ($client) { $client.Dispose() } }
}
function Send-MultipartHttpWebRequest {
  param([object]$Cfg, [string[]]$Files)
  $uri = Join-BaseUri -Base ([string]$Cfg.serverBase) -Endpoint ([string]$Cfg.endpoint)
  $boundary = "---------------------------" + ([Guid]::NewGuid().ToString("N"))
  $nl = "`r`n"
  $req = [System.Net.HttpWebRequest]::Create($uri)
  $req.Method = "POST"
  $req.SendChunked = $true
  $req.AllowWriteStreamBuffering = $true
  $req.ContentType = "multipart/form-data; boundary=$boundary"
  $stream = $req.GetRequestStream()
  try {
    foreach ($f in $Files) {
      $name = [System.IO.Path]::GetFileName($f)
      $hdr = "--$boundary$nl" +
             "Content-Disposition: form-data; name=`"file`"; filename=`"$name`"$nl" +
             "Content-Type: application/octet-stream$nl$nl"
      $hdrBytes = [System.Text.Encoding]::ASCII.GetBytes($hdr)
      $stream.Write($hdrBytes, 0, $hdrBytes.Length)
      $fs = [System.IO.File]::OpenRead($f)
      try {
        $buf = New-Object byte[] 65536
        while (($read = $fs.Read($buf,0,$buf.Length)) -gt 0) { $stream.Write($buf,0,$read) }
      } finally { $fs.Close() }
      $trailBytes = [System.Text.Encoding]::ASCII.GetBytes($nl)
      $stream.Write($trailBytes,0,$trailBytes.Length)
    }
    $endBytes = [System.Text.Encoding]::ASCII.GetBytes("--$boundary--$nl")
    $stream.Write($endBytes,0,$endBytes.Length)
  } finally { $stream.Close() }
  try {
    $resp = $req.GetResponse()
    $s = $resp.GetResponseStream()
    $sr = New-Object System.IO.StreamReader($s)
    $body = $sr.ReadToEnd()
    $sr.Close(); $s.Close(); $resp.Close()
    return @{ IsSuccess = $true; Body = $body }
  } catch [System.Net.WebException] {
    $resp = $_.Exception.Response
    if ($resp -ne $null) {
      $s = $resp.GetResponseStream(); $sr = New-Object System.IO.StreamReader($s); $body = $sr.ReadToEnd(); $sr.Close(); $s.Close(); $resp.Close()
      return @{ IsSuccess = $false; Body = $body }
    } else {
      return @{ IsSuccess = $false; Body = $_.Exception.Message }
    }
  }
}
function Parse-UploadResponse { param([string]$Body, [string[]]$Files)
  try {
    $parsed = $Body | ConvertFrom-Json
    if ($parsed -is [System.Collections.IEnumerable]) {
      $uploaded = @(); foreach ($n in $parsed) { $uploaded += [string]$n }
      return @{ ok = $true; uploaded = $uploaded; failed = @() }
    } else {
      $uploaded = @(); if ($parsed.uploaded) { foreach ($n in $parsed.uploaded) { $uploaded += [string]$n } }
      $failed   = @(); if ($parsed.failed)   { foreach ($n in $parsed.failed)   { $failed   += [string]$n } }
      if (($uploaded.Count -eq 0) -and ($failed.Count -eq 0)) { $uploaded = ($Files | ForEach-Object { Split-Path $_ -Leaf }) }
      return @{ ok = $true; uploaded = $uploaded; failed = $failed }
    }
  } catch {
    return @{ ok = $true; uploaded = ($Files | ForEach-Object { Split-Path $_ -Leaf }); failed = @() }
  }
}
function Send-Multipart { param([object]$Cfg, [string[]]$Files)
  if (-not $Files -or $Files.Count -eq 0) { return @{ ok = $true; uploaded = @(); failed = @() } }
  $r = Send-MultipartHttpClient -Cfg $Cfg -Files $Files
  if ($null -ne $r) {
    if (-not $r.IsSuccess) { return @{ ok = $false; uploaded = @(); failed = ($Files | ForEach-Object { Split-Path $_ -Leaf }) } }
    return (Parse-UploadResponse -Body $r.Body -Files $Files)
  }
  $r = Send-MultipartHttpWebRequest -Cfg $Cfg -Files $Files
  if (-not $r.IsSuccess) { return @{ ok = $false; uploaded = @(); failed = ($Files | ForEach-Object { Split-Path $_ -Leaf }) } }
  return (Parse-UploadResponse -Body $r.Body -Files $Files)
}

function Get-CandidateFiles {
  $items = if ($cfg.recursive) { Get-ChildItem -LiteralPath $base -File -Recurse } else { Get-ChildItem -LiteralPath $base -File }
  $items | Where-Object { (Test-AllowedExt -Path $_.FullName -Cfg $cfg) -and (Test-NameMatches -Path $_.FullName -Cfg $cfg) } |
    ForEach-Object { $_.FullName }
}
function Move-Result {
  param([string[]]$AllFiles, [string[]]$Uploaded, [string[]]$Failed)
  $uploadedSet = @{}; foreach ($n in $Uploaded) { $uploadedSet[[string]$n] = $true }
  $failedSet = @{}; foreach ($n in $Failed) { $failedSet[[string]$n] = $true }
  foreach ($p in $AllFiles) {
    $leaf = [System.IO.Path]::GetFileName($p)
    if     ($uploadedSet.ContainsKey($leaf)) { $dest = Join-Path -Path $SuccessDir -ChildPath $leaf }
    elseif ($failedSet.ContainsKey($leaf))   { $dest = Join-Path -Path $FailedDir  -ChildPath $leaf }
    else                                     { $dest = Join-Path -Path $FailedDir  -ChildPath $leaf }
    try { Move-Item -LiteralPath $p -Destination $dest -Force; Write-Log ("moved :: {0} -> {1}" -f $p,$dest) }
    catch { Write-Log ("move-failed :: {0} => {1} :: {2}" -f $p,$dest,$_.Exception.Message) "ERROR" }
  }
}

function Enqueue-Scan {
  try {
    $paths = @(Get-CandidateFiles)
    if (-not $paths -or $paths.Count -eq 0) { return }
    $added = 0
    foreach ($p in $paths) {
      if (Test-FileReady -Path $p -TimeoutSec 1 -PollMs 200) {
        if (-not $script:pending.ContainsKey($p)) { [byte]$b = 0; if ($script:pending.TryAdd($p,$b)) { $added++ } }
      }
    }
    if ($added -gt 0) { Write-Log ("poll-added :: {0} file(s)" -f $added) }
  } catch { Write-Log ("poll-error :: {0}" -f $_.Exception.Message) "ERROR" }
}

function Run-Once {
  $paths = @(Get-CandidateFiles)
  if (-not $paths -or $paths.Count -eq 0) { Write-Log "No files to upload (check ext/pattern)"; return }
  $ready = @(); foreach ($p in $paths) { if (Test-FileReady -Path $p -TimeoutSec 600 -PollMs 300) { $ready += $p } else { Write-Log ("skip-not-ready :: {0}" -f $p) "WARN" } }
  if (-not $ready -or $ready.Count -eq 0) { Write-Log "No files ready to upload"; return }
  $res = Send-Multipart -Cfg $cfg -Files $ready
  if (-not $res.ok) { Write-Log "upload-error (HTTP or server) -> moving all to failed" "ERROR"; Move-Result -AllFiles $ready -Uploaded @() -Failed ($ready | ForEach-Object { Split-Path $_ -Leaf }); return }
  Move-Result -AllFiles $ready -Uploaded $res.uploaded -Failed $res.failed
}

function Run-Watch {
  if ($cfg.initialScan) {
    Write-Log "initial-scan: running once on existing files"
    try { Run-Once } catch { Write-Log ("initial-scan-error :: {0}" -f $_.Exception.Message) "ERROR" }
  }

  $fsw = New-Object System.IO.FileSystemWatcher
  $fsw.Path = $base
  $fsw.Filter = "*.*"
  $fsw.IncludeSubdirectories = [bool]$cfg.recursive
  $fsw.NotifyFilter = [IO.NotifyFilters]'FileName, LastWrite, Size'
  $fsw.InternalBufferSize = 65536
  $fsw.EnableRaisingEvents = $true

  $script:pending = [System.Collections.Concurrent.ConcurrentDictionary[string,byte]]::new()

  $createdHandler = [System.IO.FileSystemEventHandler]{
    param($sender,$eventArgs)
    try {
      $p = $eventArgs.FullPath
      Write-Log ("event-created :: {0}" -f $p)
      if ((Test-AllowedExt -Path $p -Cfg $cfg) -and (Test-NameMatches -Path $p -Cfg $cfg)) {
        [byte]$b = 0; $null = $script:pending.TryAdd($p,$b)
      }
    } catch { Write-Log ("event-created-error :: {0}" -f $_.Exception.Message) "ERROR" }
  }
  $changedHandler = [System.IO.FileSystemEventHandler]{
    param($sender,$eventArgs)
    try {
      $p = $eventArgs.FullPath
      Write-Log ("event-changed :: {0}" -f $p)
      if ((Test-AllowedExt -Path $p -Cfg $cfg) -and (Test-NameMatches -Path $p -Cfg $cfg)) {
        $null = $script:pending.AddOrUpdate($p,0, { param($k,$v) 0 })
      }
    } catch { Write-Log ("event-changed-error :: {0}" -f $_.Exception.Message) "ERROR" }
  }
  $deletedHandler = [System.IO.FileSystemEventHandler]{
    param($sender,$eventArgs)
    try {
      Write-Log ("event-deleted :: {0}" -f $eventArgs.FullPath)
    } catch { Write-Log ("event-deleted-error :: {0}" -f $_.Exception.Message) "ERROR" }
  }
  $renamedHandler = [System.IO.RenamedEventHandler]{
    param($sender,$eventArgs)
    try {
      Write-Log ("event-renamed :: {0} -> {1}" -f $eventArgs.OldFullPath, $eventArgs.FullPath)
      $p = $eventArgs.FullPath
      if ((Test-AllowedExt -Path $p -Cfg $cfg) -and (Test-NameMatches -Path $p -Cfg $cfg)) {
        $null = $script:pending.AddOrUpdate($p,0, { param($k,$v) 0 })
      }
    } catch { Write-Log ("event-renamed-error :: {0}" -f $_.Exception.Message) "ERROR" }
  }
  $errorHandler = [System.IO.ErrorEventHandler]{
    param($sender,$eventArgs)
    try {
      $ex = $eventArgs.GetException()
      Write-Log ("watcher-error :: {0}" -f $ex.Message) "ERROR"
    } catch {}
  }

  $fsw.add_Created($createdHandler)
  $fsw.add_Changed($changedHandler)
  $fsw.add_Deleted($deletedHandler)
  $fsw.add_Renamed($renamedHandler)
  $fsw.add_Error($errorHandler)

  $timer = New-Object System.Timers.Timer
  $timer.Interval = [double]($cfg.batchSeconds * 1000)
  $timer.AutoReset = $true

  $heartbeat = 0
  $elapsedHandler = [System.Timers.ElapsedEventHandler]{
    param($sender,$args)
    try {
      $keys = @($script:pending.Keys)
      if ($keys -and $keys.Count -gt 0) {
        $list = @()
        foreach ($k in $keys) {
          [byte]$out = 0
          if ($script:pending.TryRemove($k, [ref]$out)) {
            if (Test-FileReady -Path $k -TimeoutSec 600 -PollMs 300) { $list += $k }
          }
        }
        if ($list -and $list.Count -gt 0) {
          Write-Log ("batch :: {0} file(s) ready" -f $list.Count)
          $res = Send-Multipart -Cfg $cfg -Files $list
          if (-not $res.ok) {
            Write-Log "upload-error (HTTP or server) -> moving all to failed" "ERROR"
            Move-Result -AllFiles $list -Uploaded @() -Failed ($list | ForEach-Object { Split-Path $_ -Leaf })
          } else {
            Move-Result -AllFiles $list -Uploaded $res.uploaded -Failed $res.failed
          }
        }
      }
    } catch { Write-Log ("watch-batch-error :: {0}" -f $_.Exception.Message) "ERROR" }
  }
  $timer.add_Elapsed($elapsedHandler)
  $timer.Start()

  # Heartbeat + optional poll-fallback
  $hbTimer = New-Object System.Timers.Timer
  $hbTimer.Interval = [double]([Math]::Max(5,[int]$cfg.heartbeatSeconds) * 1000)
  $hbTimer.AutoReset = $true
  $hbHandler = [System.Timers.ElapsedEventHandler]{ param($s,$e) try {
      $script:heartbeat = $script:heartbeat + 1
      Write-Log ("heartbeat {0}" -f $script:heartbeat)
      if ($cfg.pollFallback) { Enqueue-Scan }
    } catch {} }
  $hbTimer.add_Elapsed($hbHandler)
  $hbTimer.Start()

  try {
    Write-Log ("watching: {0} (recursive={1}, batch={2}s, hb={3}s, pollFallback={4})" -f $base, $cfg.recursive, $cfg.batchSeconds, $cfg.heartbeatSeconds, $cfg.pollFallback)
    while ($true) { Start-Sleep -Seconds 1; [System.GC]::KeepAlive($fsw) }
  } finally {
    try { $timer.Stop(); $timer.remove_Elapsed($elapsedHandler) } catch {}
    try { $hbTimer.Stop(); $hbTimer.remove_Elapsed($hbHandler) } catch {}
    try { $fsw.remove_Created($createdHandler); $fsw.remove_Changed($changedHandler); $fsw.remove_Deleted($deletedHandler); $fsw.remove_Renamed($renamedHandler); $fsw.remove_Error($errorHandler) } catch {}
    try { $timer.Dispose(); $hbTimer.Dispose(); $fsw.Dispose() } catch {}
  }
}

try { if ($Mode -eq 'once') { Run-Once } else { Run-Watch } }
catch {
  Write-Log ("fatal :: {0} :: {1}" -f $_.Exception.GetType().FullName, $_.Exception.Message) "ERROR"
  $st = $_.ScriptStackTrace
  if ($st) { Write-Log ("stack :: {0}" -f $st) "ERROR" }
}
