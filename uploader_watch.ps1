param(
  [ValidateSet('once')] [string]$Mode = 'once',
  [string]$ConfigPath = "$PSScriptRoot\upload-many.config.json"
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$ConfirmPreference = 'None'  # suppress any implicit confirmation prompts

# One log in runner folder for manual/once runs
$LogPath = Join-Path $PSScriptRoot 'manual-upload.log'

function Ensure-Dir {
  param([string]$Dir)
  if (-not (Test-Path -LiteralPath $Dir -PathType Container)) {
    New-Item -ItemType Directory -Path $Dir -Force | Out-Null
  }
}
Ensure-Dir -Dir $PSScriptRoot

function Write-Log {
  param([string]$Message, [string]$Level = 'INFO')
  try {
    $line = '{0} [{1}] {2}' -f (Get-Date -Format s), $Level, $Message
    $fs = [System.IO.File]::Open($LogPath, 'Append', 'Write', 'ReadWrite')
    try {
      $bytes = [System.Text.Encoding]::UTF8.GetBytes($line + [Environment]::NewLine)
      $fs.Write($bytes, 0, $bytes.Length)
    } finally { $fs.Close() }
  } catch {}
}

function Load-Config {
  param([string]$Path)
  if (-not (Test-Path -LiteralPath $Path)) { throw "Config file not found: $Path" }
  try { $cfg = (Get-Content -LiteralPath $Path -Raw -Encoding UTF8) | ConvertFrom-Json }
  catch { throw "Failed to parse JSON at $Path :: $($_.Exception.Message)" }
  if (-not $cfg.serverBase -or -not $cfg.endpoint) { throw "Config must provide serverBase and endpoint" }
  if (-not $cfg.watchDir) { throw "Config must provide watchDir" }
  if (-not $cfg.includeExt)           { $cfg | Add-Member includeExt           @(".mp4",".mov",".m4v",".webm",".avi",".mkv") }
  if (-not $cfg.filenamePattern)      { $cfg | Add-Member filenamePattern      ".*" }
  if (-not $cfg.filenamePatternFlags) { $cfg | Add-Member filenamePatternFlags "i" }
  if ($null -eq $cfg.recursive)       { $cfg | Add-Member recursive            $false }
  if (-not $cfg.successDir)           { $cfg | Add-Member successDir           "processed" }
  if (-not $cfg.failedDir)            { $cfg | Add-Member failedDir            "failed" }
  return $cfg
}

function Is-Rooted { param([string]$Path) return [System.IO.Path]::IsPathRooted([string]$Path) }

# HTTP helpers
function Try-LoadHttpClient {
  try { Add-Type -AssemblyName System.Net.Http -ErrorAction Stop } catch {
    try { [void][System.Reflection.Assembly]::Load("System.Net.Http") } catch {}
  }
  return ([Type]::GetType("System.Net.Http.HttpClient, System.Net.Http") -ne $null) -and
         ([Type]::GetType("System.Net.Http.HttpClientHandler, System.Net.Http") -ne $null)
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
function Join-BaseUri {
  param([string]$Base, [string]$Endpoint)
  if ([string]::IsNullOrWhiteSpace($Base)) { throw "serverBase missing" }
  if ([string]::IsNullOrWhiteSpace($Endpoint)) { throw "endpoint missing" }
  $b = $Base.TrimEnd('/')
  $e = if ($Endpoint.StartsWith('/')) { $Endpoint } else { '/' + $Endpoint }
  return $b + $e
}
function Send-MultipartHttpClient {
  param([object]$Cfg, [string[]]$Files)
  $uri = Join-BaseUri -Base ([string]$Cfg.serverBase) -Endpoint ([string]$Cfg.endpoint)
  $client = $null; $content = $null
  try {
    $client  = New-HttpClient -Cfg $Cfg
    if ($client -eq $null) { return $null } # signal fallback
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
function Parse-UploadResponse {
  param([string]$Body, [string[]]$Files)
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
function Send-Multipart {
  param([object]$Cfg, [string[]]$Files)
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

# Selection + moves
function Test-AllowedExt { param([string]$Path, [object]$Cfg)
  $ext = [System.IO.Path]::GetExtension($Path)
  if ([string]::IsNullOrWhiteSpace($ext)) { return $false }
  $ext = $ext.ToLowerInvariant()
  foreach ($e in $Cfg.includeExt) { if ($ext -eq ([string]$e).ToLowerInvariant()) { return $true } }
  return $false
}
function Test-NameMatches { param([string]$Path, [object]$Cfg)
  $name = [System.IO.Path]::GetFileName($Path)
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
function Get-CandidateFiles {
  param([string]$Base, [object]$Cfg)
  $items = if ($Cfg.recursive) { Get-ChildItem -LiteralPath $Base -File -Recurse } else { Get-ChildItem -LiteralPath $Base -File }
  $items | Where-Object { (Test-AllowedExt -Path $_.FullName -Cfg $Cfg) -and (Test-NameMatches -Path $_.FullName -Cfg $Cfg) } |
    ForEach-Object { $_.FullName }
}
function Move-Result {
  param([string[]]$AllFiles, [string[]]$Uploaded, [string[]]$Failed, [string]$SuccessDir, [string]$FailedDir)
  $uploadedSet = @{}; foreach ($n in $Uploaded) { $uploadedSet[[string]$n] = $true }
  $failedSet = @{}; foreach ($n in $Failed) { $failedSet[[string]$n] = $true }
  foreach ($p in $AllFiles) {
    $leaf = [System.IO.Path]::GetFileName($p)
    if     ($uploadedSet.ContainsKey($leaf)) { $dest = Join-Path -Path $SuccessDir -ChildPath $leaf }
    elseif ($failedSet.ContainsKey($leaf))   { $dest = Join-Path -Path $FailedDir  -ChildPath $leaf }
    else                                     { $dest = Join-Path -Path $FailedDir  -ChildPath $leaf }
    try {
      Move-Item -LiteralPath $p -Destination $dest -Force -Confirm:$false
      Write-Log ("moved :: {0} -> {1}" -f $p,$dest)
    } catch {
      Write-Log ("move-failed :: {0} => {1} :: {2}" -f $p,$dest,$_.Exception.Message) "ERROR"
    }
  }
}

# Main (once)
try {
  $cfg = Load-Config -Path $ConfigPath
} catch {
  Write-Log ("CONFIG-ERROR :: {0}" -f $_.Exception.Message) 'ERROR'
  exit 2
}

$base = [string]$cfg.watchDir
$successLeaf = Split-Path -Path ([string]$cfg.successDir) -Leaf; if ([string]::IsNullOrWhiteSpace($successLeaf)) { $successLeaf = 'processed' }
$failedLeaf  = Split-Path -Path ([string]$cfg.failedDir)  -Leaf; if ([string]::IsNullOrWhiteSpace($failedLeaf))  { $failedLeaf  = 'failed' }
$SuccessDir = if (Is-Rooted $cfg.successDir) { [string]$cfg.successDir } else { Join-Path -Path $base -ChildPath $successLeaf }
$FailedDir  = if (Is-Rooted $cfg.failedDir)  { [string]$cfg.failedDir  } else { Join-Path -Path $base -ChildPath $failedLeaf  }

Ensure-Dir -Dir $base
Ensure-Dir -Dir $SuccessDir
Ensure-Dir -Dir $FailedDir

Write-Log ("manual-upload: start (PID={0}; base={1})" -f $PID, $base)

$paths = @(Get-CandidateFiles -Base $base -Cfg $cfg)
if (-not $paths -or $paths.Count -eq 0) {
  Write-Log "No files to upload (check ext/pattern)"
  exit 0
}
Write-Log ("candidates={0}" -f $paths.Count)

$ready = @()
foreach ($p in $paths) {
  if (Test-FileReady -Path $p -TimeoutSec 600 -PollMs 300) { $ready += $p }
}
if (-not $ready -or $ready.Count -eq 0) {
  Write-Log "No files ready to upload"
  exit 0
}

Write-Log ("ready={0} -> uploading..." -f $ready.Count)

$res = Send-Multipart -Cfg $cfg -Files $ready
if (-not $res.ok) {
  Write-Log "upload-error (HTTP or server) -> moving all to failed" "ERROR"
  Move-Result -AllFiles $ready -Uploaded @() -Failed ($ready | ForEach-Object { Split-Path $_ -Leaf }) -SuccessDir $SuccessDir -FailedDir $FailedDir
  exit 1
}

# Safely compute counts even if properties are null/missing
$uploaded = @()
$failed   = @()
try {
  if ($res -and $res.PSObject.Properties['uploaded'] -and $res.uploaded) { $uploaded = @($res.uploaded) }
  if ($res -and $res.PSObject.Properties['failed']   -and $res.failed)   { $failed   = @($res.failed)   }
} catch {}

Move-Result -AllFiles $ready -Uploaded $uploaded -Failed $failed -SuccessDir $SuccessDir -FailedDir $FailedDir
Write-Log ("manual-upload: done (uploaded={0}; failed={1})" -f $uploaded.Count, $failed.Count)
exit 0
