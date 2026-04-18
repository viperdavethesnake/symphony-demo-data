#Requires -Version 7.0
<#
.SYNOPSIS
    Creates sparse files on disk from file-manifest.jsonl (Phase 2d).

.DESCRIPTION
    The hot path. For each record in manifests/file-manifest.jsonl:
      1. [System.IO.File]::Create(path)
      2. DeviceIoControl(FSCTL_SET_SPARSE) on the SafeFileHandle  (P/Invoke)
      3. Write magic-byte header at offset 0 (if defined)
      4. Write marker at markerOffset (if defined — iso, tar, wav, avi)
      5. SetLength(targetSize) — extends the file logically; the sparse flag
         makes the extension consume zero physical blocks.
      6. Close.

    Parallel via ForEach-Object -Parallel. Each parallel iteration processes
    a batch of config.scale.batchSize manifest records; total concurrency is
    config.scale.parallelThreads.

    Timestamps, owners, ACLs are applied by separate later phases — this
    script only creates files and writes headers.

.PARAMETER ConfigPath
    Path to config/main-config(.dev).json.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ConfigPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
$RepoRoot    = Split-Path -Parent $PSScriptRoot
$ConfigDir   = Split-Path -Parent (Resolve-Path $ConfigPath)
$ManifestDir = Join-Path $RepoRoot 'manifests'
$LogDir      = Join-Path $ManifestDir 'logs'
$FileManifest= Join-Path $ManifestDir 'file-manifest.jsonl'

if (-not (Test-Path $ManifestDir)) { throw "manifests/ dir missing; run Plan-AcmeData.ps1 first" }
if (-not (Test-Path $FileManifest)) { throw "file-manifest.jsonl missing at $FileManifest" }
if (-not (Test-Path $LogDir)) { New-Item -Path $LogDir -ItemType Directory | Out-Null }

$RunStamp = '{0:yyyyMMdd-HHmmss}' -f (Get-Date)
$LogPath  = Join-Path $LogDir ("files-$RunStamp.log")
$FailuresPath = Join-Path $LogDir "failures.jsonl"
$BatchLogDir  = Join-Path $LogDir ("files-batches-$RunStamp")
New-Item -Path $BatchLogDir -ItemType Directory -Force | Out-Null

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
function Write-Log {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO','WARN','ERROR','OK')][string]$Level = 'INFO'
    )
    $stamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    $line  = "[$stamp] [$Level] $Message"
    Add-Content -Path $LogPath -Value $line
    $color = switch ($Level) { 'ERROR' {'Red'} 'WARN' {'Yellow'} 'OK' {'Green'} default {'Gray'} }
    Write-Host $line -ForegroundColor $color
}

function Import-JsonFile {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path $Path)) { throw "File not found: $Path" }
    return Get-Content -Path $Path -Raw | ConvertFrom-Json
}

Write-Log "Build-AcmeFiles starting"
Write-Log "ConfigPath: $ConfigPath"

$cfg       = Import-JsonFile $ConfigPath
$filetypes = Import-JsonFile (Join-Path $ConfigDir 'filetypes.json')

$throttle  = [int]$cfg.scale.parallelThreads
$batchSize = [int]$cfg.scale.batchSize
Write-Log "parallelThreads=$throttle  batchSize=$batchSize"

# ---------------------------------------------------------------------------
# Flatten filetypes into a plain hashtable keyed by ext (for parallel block)
# ---------------------------------------------------------------------------
function Convert-HexToBytes {
    param([string]$Hex)
    if ([string]::IsNullOrEmpty($Hex)) { return [byte[]]@() }
    $n = [int]($Hex.Length / 2)
    $bytes = New-Object 'byte[]' $n
    for ($i = 0; $i -lt $n; $i++) {
        $bytes[$i] = [Convert]::ToByte($Hex.Substring($i*2, 2), 16)
    }
    return ,$bytes
}

$ExtMeta = @{}
foreach ($catProp in $filetypes.PSObject.Properties) {
    if ($catProp.Name.StartsWith('$')) { continue }
    foreach ($extProp in $catProp.Value.PSObject.Properties) {
        if ($extProp.Name.StartsWith('$')) { continue }
        $ext = $extProp.Name
        $e   = $extProp.Value
        $headerHex  = if ($e.PSObject.Properties['header']) { [string]$e.header } else { '' }
        $markerHex  = if ($e.PSObject.Properties['marker']) { [string]$e.marker } else { '' }
        $markerOff  = if ($e.PSObject.Properties['markerOffset']) { [int64]$e.markerOffset } else { [int64]0 }
        $ExtMeta[$ext] = @{
            HeaderBytes = (Convert-HexToBytes $headerHex)
            MarkerBytes = (Convert-HexToBytes $markerHex)
            MarkerOffset= $markerOff
        }
    }
}
Write-Log "ExtMeta built for $($ExtMeta.Keys.Count) extensions"

# ---------------------------------------------------------------------------
# P/Invoke for FSCTL_SET_SPARSE. Loaded once into the current AppDomain so
# all ForEach-Object -Parallel runspaces can reference the type.
# ---------------------------------------------------------------------------
if (-not ('Acme.NativeFsctl' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
namespace Acme {
    public static class NativeFsctl {
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool DeviceIoControl(
            IntPtr hDevice, uint dwIoControlCode,
            IntPtr lpInBuffer, uint nInBufferSize,
            IntPtr lpOutBuffer, uint nOutBufferSize,
            out uint lpBytesReturned, IntPtr lpOverlapped);
        // FSCTL_SET_SPARSE = 0x900C4
        public static void SetSparse(SafeFileHandle handle) {
            uint bytesReturned = 0;
            bool ok = DeviceIoControl(handle.DangerousGetHandle(), 0x900C4,
                IntPtr.Zero, 0, IntPtr.Zero, 0, out bytesReturned, IntPtr.Zero);
            if (!ok) {
                throw new System.ComponentModel.Win32Exception(
                    Marshal.GetLastWin32Error(),
                    "FSCTL_SET_SPARSE failed");
            }
        }
    }
}
'@
}
Write-Log "FSCTL_SET_SPARSE P/Invoke loaded"

# ---------------------------------------------------------------------------
# Read manifest into batches
# ---------------------------------------------------------------------------
Write-Log "Reading file-manifest.jsonl"
$lines = [System.IO.File]::ReadAllLines($FileManifest)
$totalFiles = $lines.Length
Write-Log "Total records: $totalFiles"

if ($totalFiles -eq 0) {
    Write-Log "Manifest empty — nothing to do" 'WARN'
    return
}

$batches = [System.Collections.Generic.List[object]]::new()
for ($i = 0; $i -lt $totalFiles; $i += $batchSize) {
    $end = [Math]::Min($i + $batchSize - 1, $totalFiles - 1)
    $batches.Add([pscustomobject]@{
        Id    = $batches.Count + 1
        Lines = $lines[$i..$end]
    })
}
Write-Log "Batches: $($batches.Count)  (approx $batchSize lines each)"

# Truncate failures file for this run
if (Test-Path $FailuresPath) { Remove-Item -LiteralPath $FailuresPath -Force }

# ---------------------------------------------------------------------------
# Parallel worker
# ---------------------------------------------------------------------------
$sw = [System.Diagnostics.Stopwatch]::StartNew()

$batches | ForEach-Object -ThrottleLimit $throttle -Parallel {
    $batch       = $_
    $extMeta     = $using:ExtMeta
    $batchLogDir = $using:BatchLogDir

    $batchLog = Join-Path $batchLogDir ("batch-{0:D5}.log" -f $batch.Id)
    $batchFails = Join-Path $batchLogDir ("batch-{0:D5}-failures.jsonl" -f $batch.Id)

    $created = 0
    $failed  = 0
    $bytesLogical = [int64]0
    $swBatch = [System.Diagnostics.Stopwatch]::StartNew()

    $logSw = [System.IO.StreamWriter]::new($batchLog, $false, [System.Text.UTF8Encoding]::new($false))
    $failSw = $null
    try {
        foreach ($line in $batch.Lines) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            try {
                $rec = $line | ConvertFrom-Json
                $path = $rec.path
                $ext  = $rec.ext
                $size = [int64]$rec.size

                $meta = $extMeta[$ext]
                if (-not $meta) { throw "No ext meta for '$ext'" }
                $header = [byte[]]$meta.HeaderBytes
                $marker = [byte[]]$meta.MarkerBytes
                $markerOffset = [int64]$meta.MarkerOffset

                # Ensure target size can contain the header and marker.
                $minSize = [int64]$header.Length
                if ($marker.Length -gt 0) {
                    $endOfMarker = $markerOffset + [int64]$marker.Length
                    if ($endOfMarker -gt $minSize) { $minSize = $endOfMarker }
                }
                if ($size -lt $minSize) { $size = $minSize }

                # Create (overwriting any existing).
                $fs = [System.IO.File]::Create($path)
                try {
                    # Sparse BEFORE any writes so SetLength'd tail is sparse.
                    [Acme.NativeFsctl]::SetSparse($fs.SafeFileHandle)

                    if ($header.Length -gt 0) {
                        $fs.Position = 0
                        $fs.Write($header, 0, $header.Length)
                    }
                    if ($marker.Length -gt 0) {
                        $fs.Position = $markerOffset
                        $fs.Write($marker, 0, $marker.Length)
                    }
                    if ($size -gt $fs.Length) { $fs.SetLength($size) }
                } finally {
                    $fs.Dispose()
                }

                $created++
                $bytesLogical += $size
            } catch {
                $failed++
                if ($null -eq $failSw) {
                    $failSw = [System.IO.StreamWriter]::new($batchFails, $false, [System.Text.UTF8Encoding]::new($false))
                }
                $failRec = [ordered]@{
                    phase   = 'files'
                    path    = if ($rec) { $rec.path } else { '<unparsed>' }
                    message = $_.Exception.Message
                    line    = $line
                }
                $failSw.WriteLine(($failRec | ConvertTo-Json -Compress -Depth 4))
            }
        }
        $swBatch.Stop()
        $logSw.WriteLine(("batch={0} created={1} failed={2} bytesLogical={3} elapsedMs={4}" -f `
            $batch.Id, $created, $failed, $bytesLogical, $swBatch.ElapsedMilliseconds))
    } finally {
        $logSw.Dispose()
        if ($failSw) { $failSw.Dispose() }
    }

    [pscustomobject]@{
        Id             = $batch.Id
        Created        = $created
        Failed         = $failed
        BytesLogical   = $bytesLogical
        ElapsedMs      = $swBatch.ElapsedMilliseconds
        Records        = $batch.Lines.Length
    }
} | Tee-Object -Variable batchResults | Out-Null

$sw.Stop()

# ---------------------------------------------------------------------------
# Aggregate results, merge failure shards
# ---------------------------------------------------------------------------
$totalCreated = ($batchResults | Measure-Object Created -Sum).Sum
$totalFailed  = ($batchResults | Measure-Object Failed  -Sum).Sum
$totalBytes   = ($batchResults | Measure-Object BytesLogical -Sum).Sum

# Merge per-batch failure shards.
$failShards = Get-ChildItem -Path $BatchLogDir -Filter 'batch-*-failures.jsonl' -ErrorAction SilentlyContinue
if ($failShards) {
    $failOut = [System.IO.StreamWriter]::new($FailuresPath, $false, [System.Text.UTF8Encoding]::new($false))
    try {
        foreach ($shard in $failShards) {
            foreach ($l in [System.IO.File]::ReadAllLines($shard.FullName)) {
                if (-not [string]::IsNullOrWhiteSpace($l)) { $failOut.WriteLine($l) }
            }
        }
    } finally { $failOut.Dispose() }
    Write-Log "Merged $($failShards.Count) failure shard(s) into $FailuresPath"
}

$filesPerSec = if ($sw.Elapsed.TotalSeconds -gt 0) { $totalCreated / $sw.Elapsed.TotalSeconds } else { 0 }
$gbPerSec    = if ($sw.Elapsed.TotalSeconds -gt 0) { ($totalBytes / 1GB) / $sw.Elapsed.TotalSeconds } else { 0 }
Write-Log ("Done. created={0} failed={1} logical={2:N2} GB elapsed={3:N1}s  ({4:N0} files/sec, {5:N2} GB/sec logical)" -f `
    $totalCreated, $totalFailed, ($totalBytes / 1GB), $sw.Elapsed.TotalSeconds, $filesPerSec, $gbPerSec) 'OK'

$summary = [ordered]@{
    records         = $totalFiles
    created         = $totalCreated
    failed          = $totalFailed
    bytesLogical    = $totalBytes
    gbLogical       = [Math]::Round($totalBytes / 1GB, 3)
    elapsedSeconds  = [Math]::Round($sw.Elapsed.TotalSeconds, 2)
    filesPerSecond  = [Math]::Round($filesPerSec, 1)
    batches         = $batches.Count
    parallelThreads = $throttle
    batchSize       = $batchSize
    failuresPath    = if (Test-Path $FailuresPath) { $FailuresPath } else { $null }
    logPath         = $LogPath
    batchLogDir     = $BatchLogDir
}
$summary | ConvertTo-Json -Depth 4 | Set-Content -Path (Join-Path $LogDir 'files-summary.json') -Encoding utf8
$summary | Format-List

if ($totalFailed -gt 0) {
    $failPct = ($totalFailed / $totalFiles)
    if ($failPct -gt 0.001) {
        Write-Log ("Failure rate {0:P2} exceeds 0.1% threshold" -f $failPct) 'ERROR'
        exit 1
    } else {
        Write-Log ("Failure rate {0:P2} within 0.1% tolerance — continuing" -f $failPct) 'WARN'
    }
}
