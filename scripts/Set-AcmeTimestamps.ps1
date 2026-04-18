#Requires -Version 7.0
<#
.SYNOPSIS
    Applies btime/mtime/atime to every file from file-manifest.jsonl (Phase 2e).

.DESCRIPTION
    Creating a file in Phase 2d set all three timestamps to "now". This
    script overwrites them from the manifest. Order: btime → mtime → atime
    (the spec: setting mtime bumps NTFS ctime but we don't track ctime, and
    atime must be last since it's the only one that can be "recent" when
    btime/mtime are old).

    Parallel via ForEach-Object -Parallel, batched exactly like
    Build-AcmeFiles.ps1. Pure managed calls — no P/Invoke needed.

.PARAMETER ConfigPath
    Path to config/main-config(.dev).json.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ConfigPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$RepoRoot    = Split-Path -Parent $PSScriptRoot
$ManifestDir = Join-Path $RepoRoot 'manifests'
$LogDir      = Join-Path $ManifestDir 'logs'
$FileManifest= Join-Path $ManifestDir 'file-manifest.jsonl'
if (-not (Test-Path $FileManifest)) { throw "file-manifest.jsonl missing at $FileManifest" }
if (-not (Test-Path $LogDir)) { New-Item -Path $LogDir -ItemType Directory | Out-Null }

$RunStamp = '{0:yyyyMMdd-HHmmss}' -f (Get-Date)
$LogPath = Join-Path $LogDir ("timestamps-$RunStamp.log")

function Write-Log {
    param([string]$Message, [ValidateSet('INFO','WARN','ERROR','OK')][string]$Level = 'INFO')
    $stamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    Add-Content -Path $LogPath -Value "[$stamp] [$Level] $Message"
    $color = switch ($Level) { 'ERROR' {'Red'} 'WARN' {'Yellow'} 'OK' {'Green'} default {'Gray'} }
    Write-Host "[$stamp] [$Level] $Message" -ForegroundColor $color
}

function Import-JsonFile {
    param([string]$Path)
    return Get-Content -Path $Path -Raw | ConvertFrom-Json
}

Write-Log "Set-AcmeTimestamps starting"
$cfg = Import-JsonFile $ConfigPath
$throttle  = [int]$cfg.scale.parallelThreads
$batchSize = [int]$cfg.scale.batchSize
Write-Log "parallelThreads=$throttle  batchSize=$batchSize"

$lines = [System.IO.File]::ReadAllLines($FileManifest)
$total = $lines.Length
Write-Log "Records: $total"
if ($total -eq 0) { return }

$batches = [System.Collections.Generic.List[object]]::new()
for ($i = 0; $i -lt $total; $i += $batchSize) {
    $end = [Math]::Min($i + $batchSize - 1, $total - 1)
    $batches.Add([pscustomobject]@{ Id = $batches.Count + 1; Lines = $lines[$i..$end] })
}
Write-Log "Batches: $($batches.Count)"

$sw = [System.Diagnostics.Stopwatch]::StartNew()
$results = $batches | ForEach-Object -ThrottleLimit $throttle -Parallel {
    $batch = $_
    $applied = 0; $failed = 0
    $swBatch = [System.Diagnostics.Stopwatch]::StartNew()
    $failMsgs = [System.Collections.Generic.List[string]]::new()
    foreach ($line in $batch.Lines) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $path = $null
        try {
            $rec = $line | ConvertFrom-Json
            $path = $rec.path
            $b = ([datetime]$rec.btime).ToUniversalTime()
            $m = ([datetime]$rec.mtime).ToUniversalTime()
            $a = ([datetime]$rec.atime).ToUniversalTime()
            [System.IO.File]::SetCreationTimeUtc($path, $b)
            [System.IO.File]::SetLastWriteTimeUtc($path, $m)
            [System.IO.File]::SetLastAccessTimeUtc($path, $a)
            $applied++
        } catch {
            $failed++
            $failMsgs.Add("$path :: $($_.Exception.Message)")
        }
    }
    $swBatch.Stop()
    [pscustomobject]@{ Id=$batch.Id; Applied=$applied; Failed=$failed; ElapsedMs=$swBatch.ElapsedMilliseconds; Failures=$failMsgs }
}
$sw.Stop()

$applied = ($results | Measure-Object Applied -Sum).Sum
$failed  = ($results | Measure-Object Failed -Sum).Sum
$rate = if ($sw.Elapsed.TotalSeconds -gt 0) { $applied / $sw.Elapsed.TotalSeconds } else { 0 }
Write-Log ("applied={0} failed={1} elapsed={2:N1}s ({3:N0} files/sec)" -f $applied, $failed, $sw.Elapsed.TotalSeconds, $rate) 'OK'
if ($failed -gt 0) {
    foreach ($r in $results) { foreach ($m in $r.Failures) { Write-Log $m 'ERROR' } }
}
$summary = [ordered]@{
    records = $total; applied = $applied; failed = $failed
    elapsedSeconds = [Math]::Round($sw.Elapsed.TotalSeconds, 2)
    filesPerSecond = [Math]::Round($rate, 1)
    logPath = $LogPath
}
$summary | ConvertTo-Json -Depth 3 | Set-Content -Path (Join-Path $LogDir 'timestamps-summary.json') -Encoding utf8
$summary | Format-List
if ($failed / [Math]::Max(1,$total) -gt 0.001) { exit 1 }
