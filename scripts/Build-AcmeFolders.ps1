#Requires -Version 7.0
<#
.SYNOPSIS
    Creates the folder tree on disk from folder-manifest.json.

.DESCRIPTION
    Phase 2c. Reads manifests/folder-manifest.json (produced by
    Plan-AcmeData.ps1) and creates every folder under the manifest's
    rootPath. Serial — serial avoids mkdir races on nested paths and
    finishes in well under a minute even at 100k folders.

    Idempotent: existing folders are skipped silently (New-Item -Force).
    Does not remove extra folders that exist on disk but not in the
    manifest — wipe rootPath manually if you want a clean slate.

.PARAMETER ConfigPath
    Path to the main config JSON. Used for a sanity check that the
    manifest's rootPath matches the config's rootPath; differences are
    logged as a warning (e.g. planner was dev, you ran folders against
    prod config).
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
$ManifestDir = Join-Path $RepoRoot 'manifests'
$LogDir      = Join-Path $ManifestDir 'logs'
$FolderManifestPath = Join-Path $ManifestDir 'folder-manifest.json'

if (-not (Test-Path $ManifestDir)) { throw "manifests/ dir missing; run Plan-AcmeData.ps1 first" }
if (-not (Test-Path $LogDir))      { New-Item -Path $LogDir -ItemType Directory | Out-Null }

$LogPath = Join-Path $LogDir ("folders-{0:yyyyMMdd-HHmmss}.log" -f (Get-Date))

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

function Resolve-RootPath {
    param([Parameter(Mandatory)][string]$RawPath)
    if ([System.IO.Path]::IsPathRooted($RawPath)) { return $RawPath }
    return (Join-Path $RepoRoot $RawPath)
}

Write-Log "Build-AcmeFolders starting"
Write-Log "ConfigPath: $ConfigPath"

if (-not (Test-Path $FolderManifestPath)) {
    throw "folder-manifest.json not found at $FolderManifestPath — run Plan-AcmeData.ps1 first"
}

$cfg = Import-JsonFile $ConfigPath
$manifest = Import-JsonFile $FolderManifestPath

$configRoot   = Resolve-RootPath $cfg.scale.rootPath
$manifestRoot = $manifest.meta.rootPath

if ($configRoot -ne $manifestRoot) {
    Write-Log "rootPath mismatch — config='$configRoot' manifest='$manifestRoot'. Using manifest value." 'WARN'
}
$root = $manifestRoot

Write-Log "Root: $root"
Write-Log "Folders in manifest: $($manifest.folders.Count)"

# ---------------------------------------------------------------------------
# Create root
# ---------------------------------------------------------------------------
if (-not (Test-Path $root)) {
    Write-Log "Creating root: $root"
    New-Item -Path $root -ItemType Directory -Force | Out-Null
}

# ---------------------------------------------------------------------------
# Create folders
# ---------------------------------------------------------------------------
$created   = 0
$existed   = 0
$failed    = 0
$total     = $manifest.folders.Count
$reportEvery = [Math]::Max(1, [int]($total / 50))
$sw = [System.Diagnostics.Stopwatch]::StartNew()

$i = 0
foreach ($f in $manifest.folders) {
    $i++
    if ($f.relPath -eq '') { continue }  # skip the _root sentinel

    $path = $f.path
    try {
        if (Test-Path -LiteralPath $path -PathType Container) {
            $existed++
        } else {
            New-Item -Path $path -ItemType Directory -Force -ErrorAction Stop | Out-Null
            $created++
        }
    } catch {
        $failed++
        Write-Log ("Failed to create '{0}': {1}" -f $path, $_.Exception.Message) 'ERROR'
    }

    if (($i % $reportEvery) -eq 0) {
        Write-Progress -Activity 'Creating folders' -Status "$i / $total" -PercentComplete (($i / $total) * 100)
    }
}
Write-Progress -Activity 'Creating folders' -Completed
$sw.Stop()

Write-Log ("Done. created={0} existed={1} failed={2} in {3:N1}s ({4:N0} folders/sec)" -f `
    $created, $existed, $failed, $sw.Elapsed.TotalSeconds, ($total / [Math]::Max(0.001, $sw.Elapsed.TotalSeconds))) 'OK'

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
$summary = [ordered]@{
    rootPath        = $root
    plannedFolders  = $total
    created         = $created
    existed         = $existed
    failed          = $failed
    elapsedSeconds  = [Math]::Round($sw.Elapsed.TotalSeconds, 2)
    logPath         = $LogPath
}
$summary | ConvertTo-Json -Depth 3 | Set-Content -Path (Join-Path $LogDir 'folders-summary.json') -Encoding utf8
$summary | Format-List

if ($failed -gt 0) {
    Write-Log "$failed folder(s) failed. Review log at $LogPath" 'ERROR'
    exit 1
}
