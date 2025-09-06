# PowerShell: slow-grow.ps1
param(
  [string]$Path = "C:\Media\incoming\4865.mp4",
  [int]$TotalMB = 100,   # total size to write
  [int]$ChunkKB = 1024,  # size of each write
  [int]$DelayMs = 300    # delay between writes
)

$ErrorActionPreference = 'Stop'

# Prepare a chunk buffer (zeros; fast and fine for testing)
$buffer = New-Object byte[] ($ChunkKB * 1024)

# Open exclusively so the file stays locked while writing
$fs = [System.IO.FileStream]::new(
  $Path,
  [System.IO.FileMode]::Create,
  [System.IO.FileAccess]::Write,
  [System.IO.FileShare]::None
)

try {
  $totalBytes = [int64]$TotalMB * 1024 * 1024
  $written = [int64]0

  Write-Host "Writing $TotalMB MB to $Path in $ChunkKB KB chunks (delay $DelayMs ms)..."
  while ($written -lt $totalBytes) {
    $toWrite = [int]([Math]::Min($buffer.Length, $totalBytes - $written))
    $fs.Write($buffer, 0, $toWrite)
    $written += $toWrite

    # Optional progress
    $pct = [int](($written * 100) / $totalBytes)
    Write-Progress -Activity "Generating file" -Status "$pct% ($([math]::Round($written/1MB,1)) MB of $TotalMB MB)" -PercentComplete $pct

    Start-Sleep -Milliseconds $DelayMs
  }
  Write-Progress -Activity "Generating file" -Completed
  Write-Host "Done. Final size: $([math]::Round($written/1MB,1)) MB"
}
finally {
  $fs.Close()
}
