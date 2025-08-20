param(
  [ValidateSet('once')] [string]$Mode = 'once',
  [string]$ConfigPath = "$PSScriptRoot\upload-many.config.json"
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$ConfirmPreference = 'None'

$LogPath = Join-Path $PSScriptRoot 'manual-upload.log'

function Ensure-Dir { param([string]$Dir)
  if (-not (Test-Path -LiteralPath $Dir -PathType Container)) {
    New-Item -ItemType Directory -Path $Dir -Force | Out-Null
  }
}
Ensure-Dir -Dir $PSScriptRoot

function Write-Log { param([string]$Message,[string]$Level='INFO')
  try {
    $line = '{0} [{1}] {2}' -f (Get-Date -Format s), $Level, $Message
    $fs = [System.IO.File]::Open($LogPath,'Append','Write','ReadWrite')
    try {
      $bytes = [System.Text.Encoding]::UTF8.GetBytes($line + [Environment]::NewLine)
      $fs.Write($bytes,0,$bytes.Length)
    } finally { $fs.Close() }
  } catch {}
}

function Load-Config { param([string]$Path)
  if (-not (Test-Path -LiteralPath $Path)) { throw "Config file not found: $Path" }
  try { $cfg = (Get-Content -LiteralPath $Path -Raw -Encoding UTF8) | ConvertFrom-Json }
  catch { throw "Failed to parse JSON at $Path :: $($_.Exception.Message)" }
  if (-not $cfg.serverBase)    { throw "Config must provide serverBase" }
  if (-not $cfg.authorizePath) { throw "Config must provide authorizePath (e.g., /api/blob/authorize)" }
  if (-not $cfg.watchDir)      { throw "Config must provide watchDir" }
  if (-not $cfg.includeExt)           { $cfg | Add-Member includeExt           @(".mp4",".mov",".m4v",".webm",".avi",".mkv",".jpg",".jpeg",".png") }
  if (-not $cfg.filenamePattern)      { $cfg | Add-Member filenamePattern      "^(?<id>[A-Z0-9]{3}-[A-Z0-9]{3})" }
  if (-not $cfg.filenamePatternFlags) { $cfg | Add-Member filenamePatternFlags "i" }
  if ($null -eq $cfg.recursive)       { $cfg | Add-Member recursive            $false }
  if (-not $cfg.successDir)           { $cfg | Add-Member successDir           "processed" }
  if (-not $cfg.failedDir)            { $cfg | Add-Member failedDir            "failed" }
  if (-not $cfg.storePrefix)          { $cfg | Add-Member storePrefix          "uploads" }
  return $cfg
}

function Is-Rooted { param([string]$Path) return [System.IO.Path]::IsPathRooted([string]$Path) }

function Guess-ContentType { param([string]$Path)
  $ext = [System.IO.Path]::GetExtension($Path)
  if ($null -eq $ext) { $ext = "" }
  $ext = $ext.ToLowerInvariant()
  switch ($ext) {
    ".mp4"  { "video/mp4" }
    ".mov"  { "video/quicktime" }
    ".m4v"  { "video/x-m4v" }
    ".webm" { "video/webm" }
    ".mkv"  { "video/x-matroska" }
    ".avi"  { "video/x-msvideo" }
    ".jpg"  { "image/jpeg" }
    ".jpeg" { "image/jpeg" }
    ".png"  { "image/png" }
    ".gif"  { "image/gif" }
    ".webp" { "image/webp" }
    ".mp3"  { "audio/mpeg" }
    ".wav"  { "audio/wav" }
    default { "application/octet-stream" }
  }
}

function Join-BaseUri { param([string]$Base,[string]$Endpoint)
  if ([string]::IsNullOrWhiteSpace($Base))     { throw "serverBase missing" }
  if ([string]::IsNullOrWhiteSpace($Endpoint)) { throw "authorizePath missing" }
  $b = $Base.TrimEnd('/')
  $e = if ($Endpoint.StartsWith('/')) { $Endpoint } else { '/' + $Endpoint }
  return $b + $e
}

# Step A: ask API for a short-lived client token (JSON only)
function Get-BlobClientToken {
  param(
    [object]$Cfg,
    [string]$Pathname,
    [string]$ContentType,
    [string]$UserId,
    [string]$OriginalName
  )
  $authorizeUrl = Join-BaseUri -Base ([string]$Cfg.serverBase) -Endpoint ([string]$Cfg.authorizePath)
  $payload = @{
    type = "blob.generate-client-token"
    payload = @{
      pathname = $Pathname
      contentType = $ContentType
      multipart = $true
      clientPayload = ( @{ userId = $UserId; originalName = $OriginalName } | ConvertTo-Json -Compress )
    }
  } | ConvertTo-Json -Compress

  $headers = @{ "Content-Type" = "application/json" }
  if ($Cfg.authToken -and $Cfg.authToken.ToString().Trim().Length -gt 0) {
    $headers["Authorization"] = "Bearer " + [string]$Cfg.authToken
  }

  Write-Log ("Requesting client token: {0}" -f $authorizeUrl)
  try {
    $resp = Invoke-RestMethod -Uri $authorizeUrl -Method POST -Headers $headers -Body $payload
  } catch {
    throw "Token request failed: $($_.Exception.Message)"
  }

  if (-not $resp -or ($resp.type -ne 'blob.generate-client-token') -or (-not $resp.clientToken)) {
    $dump = if ($resp) { ($resp | ConvertTo-Json -Compress) } else { "<null>" }
    throw ("Unexpected token response: {0}" -f $dump)
  }
  return [string]$resp.clientToken
}

# Step B: stream file directly to https://blob.vercel-storage.com/<pathname>
function Put-To-VercelBlob {
  param(
    [string]$Pathname,
    [string]$ContentType,
    [string]$FilePath,
    [string]$ClientToken,
    [object]$Cfg,
    [string]$UserId,
    [string]$OriginalName
  )
  $url = "https://blob.vercel-storage.com/" + [System.Uri]::EscapeUriString($Pathname)
  Write-Log ("Uploading to Blob: {0}" -f $url)

  $req = [System.Net.HttpWebRequest]::Create($url)
  $req.Method = "PUT"
  $req.Headers["Authorization"] = "Bearer $ClientToken"
  $req.Headers["x-content-type"] = $ContentType

  $stream = $req.GetRequestStream()
  $fs = [System.IO.File]::OpenRead($FilePath)
  try {
    $buf = New-Object byte[] 65536
    while (($read = $fs.Read($buf,0,$buf.Length)) -gt 0) { $stream.Write($buf,0,$read) }
  } finally { $fs.Close(); $stream.Close() }

  try {
    $resp = $req.GetResponse()
    $s = $resp.GetResponseStream()
    $sr = New-Object System.IO.StreamReader($s)
    $body = $sr.ReadToEnd()
    $sr.Close(); $s.Close(); $resp.Close()

    $urlOut = $null
    if (-not [string]::IsNullOrWhiteSpace($body)) {
      try {
        $json = $body | ConvertFrom-Json
        if ($json -and $json.PSObject.Properties.Match('url').Count -gt 0) {
          $urlOut = [string]$json.url
        }
      } catch { }
    }

    # NEW: Notify API about completion
    if ($urlOut) {
      try {
        Notify-UploadCompletion -Cfg $Cfg -BlobUrl $urlOut -UserId $UserId -OriginalName $OriginalName -ContentType $ContentType
      } catch {
        Write-Log ("Failed to notify upload completion: {0}" -f $_.Exception.Message) "ERROR"
      }
    }

    return @{ ok = $true; url = $urlOut }
  } catch [System.Net.WebException] {
    $resp = $_.Exception.Response
    if ($resp -ne $null) {
      $s = $resp.GetResponseStream(); $sr = New-Object System.IO.StreamReader($s); $body = $sr.ReadToEnd(); $sr.Close(); $s.Close(); $resp.Close()
      Write-Log ("Blob PUT error: {0}" -f $body) "ERROR"
      return @{ ok = $false; error = $body }
    } else {
      Write-Log ("Blob PUT exception: {0}" -f $_.Exception.Message) "ERROR"
      return @{ ok = $false; error = $_.Exception.Message }
    }
  }
}

# NEW: Function to notify API about upload completion
function Notify-UploadCompletion {
  param(
    [object]$Cfg,
    [string]$BlobUrl,
    [string]$UserId,
    [string]$OriginalName,
    [string]$ContentType
  )
  
  $notifyUrl = Join-BaseUri -Base ([string]$Cfg.serverBase) -Endpoint ([string]$Cfg.authorizePath)
  $payload = @{
    type = "upload.completed"
    payload = @{
      blob = @{
        url = $BlobUrl
        contentType = $ContentType
      }
      tokenPayload = ( @{ userId = $UserId; originalName = $OriginalName } | ConvertTo-Json -Compress )
    }
  } | ConvertTo-Json -Compress

  $headers = @{ "Content-Type" = "application/json" }
  if ($Cfg.authToken -and $Cfg.authToken.ToString().Trim().Length -gt 0) {
    $headers["Authorization"] = "Bearer " + [string]$Cfg.authToken
  }

  Write-Log ("Notifying upload completion: {0}" -f $notifyUrl)
  try {
    $resp = Invoke-RestMethod -Uri $notifyUrl -Method POST -Headers $headers -Body $payload
    Write-Log ("Upload completion notification sent successfully")
  } catch {
    throw "Upload completion notification failed: $($_.Exception.Message)"
  }
}

function Test-AllowedExt { param([string]$Path,[object]$Cfg)
  $ext = [System.IO.Path]::GetExtension($Path)
  if ($null -eq $ext) { return $false }
  $ext = $ext.ToLowerInvariant()
  foreach ($e in $Cfg.includeExt) { if ($ext -eq ([string]$e).ToLowerInvariant()) { return $true } }
  return $false
}
function Test-NameMatches { param([string]$Path,[object]$Cfg)
  $name = [System.IO.Path]::GetFileName($Path)
  $options = [System.Text.RegularExpressions.RegexOptions]::None
  if ($Cfg.filenamePatternFlags -and $Cfg.filenamePatternFlags.ToString().ToLower().Contains('i')) {
    $options = $options -bor [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
  }
  return [System.Text.RegularExpressions.Regex]::IsMatch($name,[string]$Cfg.filenamePattern,$options)
}
function Test-FileReady { param([string]$Path,[int]$TimeoutSec=600,[int]$PollMs=300)
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
    try { $fs = [System.IO.FileStream]::new($Path,[System.IO.FileMode]::Open,[System.IO.FileAccess]::Read,[System.IO.FileShare]::None); $fs.Close(); return $true }
    catch { Start-Sleep -Milliseconds $PollMs }
  }
  return $false
}
function Get-CandidateFiles { param([string]$Base,[object]$Cfg)
  $items = if ($Cfg.recursive) { Get-ChildItem -LiteralPath $Base -File -Recurse } else { Get-ChildItem -LiteralPath $Base -File }
  $items | Where-Object { (Test-AllowedExt -Path $_.FullName -Cfg $Cfg) -and (Test-NameMatches -Path $_.FullName -Cfg $Cfg) } |
    ForEach-Object { $_.FullName }
}
function Move-Result { param([string[]]$AllFiles,[string[]]$Uploaded,[string[]]$Failed,[string]$SuccessDir,[string]$FailedDir)
  $uploadedSet = @{}; foreach ($n in $Uploaded) { $uploadedSet[[string]$n] = $true }
  $failedSet   = @{}; foreach ($n in $Failed)   { $failedSet[[string]$n]   = $true }
  foreach ($p in $AllFiles) {
    $leaf = [System.IO.Path]::GetFileName($p)
    if     ($uploadedSet.ContainsKey($leaf)) { $dest = Join-Path -Path $SuccessDir -ChildPath $leaf }
    elseif ($failedSet.ContainsKey($leaf))   { $dest = Join-Path -Path $FailedDir  -ChildPath $leaf }
    else                                     { $dest = Join-Path -Path $FailedDir  -ChildPath $leaf }
    try { Move-Item -LiteralPath $p -Destination $dest -Force -Confirm:$false; Write-Log ("moved :: {0} -> {1}" -f $p,$dest) }
    catch { Write-Log ("move-failed :: {0} => {1} :: {2}" -f $p,$dest,$_.Exception.Message) "ERROR" }
  }
}

# ----------------- Main -----------------
try { $cfg = Load-Config -Path $ConfigPath } catch { Write-Log ("CONFIG-ERROR :: {0}" -f $_.Exception.Message) 'ERROR'; exit 2 }

$base = [string]$cfg.watchDir
$successLeaf = Split-Path -Path ([string]$cfg.successDir) -Leaf; if ([string]::IsNullOrWhiteSpace($successLeaf)) { $successLeaf = 'processed' }
$failedLeaf  = Split-Path -Path ([string]$cfg.failedDir)  -Leaf; if ([string]::IsNullOrWhiteSpace($failedLeaf))  { $failedLeaf  = 'failed' }
$SuccessDir = if (Is-Rooted $cfg.successDir) { [string]$cfg.successDir } else { Join-Path -Path $base -ChildPath $successLeaf }
$FailedDir  = if (Is-Rooted $cfg.failedDir)  { [string]$cfg.failedDir  } else { Join-Path -Path $base -ChildPath $failedLeaf  }

Ensure-Dir -Dir $base
Ensure-Dir -Dir $SuccessDir
Ensure-Dir -Dir $FailedDir

Write-Log ("manual-upload: start (PID={0}; base={1})" -f $PID,$base)

$paths = @(Get-CandidateFiles -Base $base -Cfg $cfg)
if (-not $paths -or $paths.Count -eq 0) { Write-Log "No files to upload (check ext/pattern)"; exit 0 }
Write-Log ("candidates={0}" -f $paths.Count)

$ready = @(); foreach ($p in $paths) { if (Test-FileReady -Path $p -TimeoutSec 600 -PollMs 300) { $ready += $p } }
if (-not $ready -or $ready.Count -eq 0) { Write-Log "No files ready to upload"; exit 0 }
Write-Log ("ready={0} -> uploading..." -f $ready.Count)

$uploaded = @(); $failed = @()

# Update the main upload loop to pass additional parameters
foreach ($p in $ready) {
  $name = [System.IO.Path]::GetFileName($p)

  # Extract ID with your regex
  $opts = [System.Text.RegularExpressions.RegexOptions]::None
  if ($cfg.filenamePatternFlags -and $cfg.filenamePatternFlags.ToString().ToLower().Contains('i')) {
    $opts = $opts -bor [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
  }
  $m = [System.Text.RegularExpressions.Regex]::Match($name,[string]$cfg.filenamePattern,$opts)
  if (-not $m.Success) {
    Write-Log ("skip (pattern mismatch): {0}" -f $name) "ERROR"
    $failed += $name
    continue
  }

  $userId = if ($m.Groups['id'] -and $m.Groups['id'].Success) { $m.Groups['id'].Value.ToUpperInvariant() }
            else { $m.Value.ToUpperInvariant() }

  $contentType = Guess-ContentType -Path $p
  $pathname = $name

  try {
    $token = Get-BlobClientToken -Cfg $cfg -Pathname $pathname -ContentType $contentType -UserId $userId -OriginalName $name
    $r = Put-To-VercelBlob -Pathname $pathname -ContentType $contentType -FilePath $p -ClientToken $token -Cfg $cfg -UserId $userId -OriginalName $name

    $urlShown = "<url pending>"
    if ($r -and $r.ContainsKey('url') -and -not [string]::IsNullOrWhiteSpace($r['url'])) { $urlShown = [string]$r['url'] }

    if ($r.ok) { $uploaded += $name; Write-Log ("uploaded: {0} -> {1}" -f $name, $urlShown) }
    else { $failed += $name; Write-Log ("failed: {0} :: {1}" -f $name,$r.error) "ERROR" }
  } catch {
    $failed += $name
    Write-Log ("exception uploading {0} :: {1}" -f $name, $_.Exception.Message) "ERROR"
  }
}

Move-Result -AllFiles $ready -Uploaded $uploaded -Failed $failed -SuccessDir $SuccessDir -FailedDir $FailedDir
Write-Log ("manual-upload: done (uploaded={0}; failed={1})" -f $uploaded.Count,$failed.Count)
