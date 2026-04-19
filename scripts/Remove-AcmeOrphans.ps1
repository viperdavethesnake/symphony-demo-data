#Requires -Version 7.0
#Requires -Modules ActiveDirectory
<#
.SYNOPSIS
    Phase 2h — deletes terminated users from AD so their SIDs become
    unresolvable on disk (owners + ACEs written in earlier phases).

.DESCRIPTION
    Reads manifests/ad-manifest.json, filters users with status='terminated',
    and deletes each with Remove-ADUser. Archives the manifest after success
    with a timestamp suffix so the run is auditable and so subsequent
    Build-AcmeAD Remove runs still have the pre-orphan manifest.

    Safe to re-run — users already absent are skipped silently. Never
    touches active, disabled, or service accounts. Never touches demo.admin
    or any built-in AD object.

    This script must run on the DC (or a box with RSAT+AD module).
.PARAMETER ConfigPath
    Path to config/main-config(.dev).json.
.PARAMETER Force
    Skip the interactive confirmation prompt.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact='High')]
param(
    [Parameter(Mandatory)][string]$ConfigPath,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$RepoRoot    = Split-Path -Parent $PSScriptRoot
$ManifestDir = Join-Path $RepoRoot 'manifests'
$LogDir      = Join-Path $ManifestDir 'logs'
$AdManifest  = Join-Path $ManifestDir 'ad-manifest.json'
if (-not (Test-Path $AdManifest)) { throw "ad-manifest.json missing at $AdManifest" }
if (-not (Test-Path $LogDir)) { New-Item -Path $LogDir -ItemType Directory | Out-Null }

$LogPath = Join-Path $LogDir ("orphans-{0:yyyyMMdd-HHmmss}.log" -f (Get-Date))

function Write-Log {
    param([string]$Message, [ValidateSet('INFO','WARN','ERROR','OK')][string]$Level = 'INFO')
    $stamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    Add-Content -Path $LogPath -Value "[$stamp] [$Level] $Message"
    $color = switch ($Level) { 'ERROR' {'Red'} 'WARN' {'Yellow'} 'OK' {'Green'} default {'Gray'} }
    Write-Host "[$stamp] [$Level] $Message" -ForegroundColor $color
}

Write-Log "Remove-AcmeOrphans starting"
$manifest = Get-Content -Path $AdManifest -Raw | ConvertFrom-Json
$terminated = @($manifest.users | Where-Object { $_.status -eq 'terminated' })
Write-Log "Terminated users in manifest: $($terminated.Count)"
if ($terminated.Count -eq 0) { Write-Log 'Nothing to do' 'OK'; return }

if (-not $Force) {
    $confirm = Read-Host "Delete $($terminated.Count) terminated users from AD (y/N)?"
    if ($confirm -notmatch '^(y|Y|yes|YES)$') { Write-Log 'Cancelled' 'WARN'; return }
}

$deleted = 0; $alreadyGone = 0; $failed = 0
$sw = [System.Diagnostics.Stopwatch]::StartNew()
foreach ($u in $terminated) {
    try {
        $existing = Get-ADUser -Identity $u.samAccountName -ErrorAction SilentlyContinue
        if (-not $existing) {
            $alreadyGone++
            Write-Log "skip (already gone): $($u.samAccountName)" 'INFO'
            continue
        }
        if ($WhatIfPreference) {
            Write-Log "what-if: Remove-ADUser -Identity $($u.samAccountName)" 'INFO'
            continue
        }
        Remove-ADUser -Identity $u.samAccountName -Confirm:$false -ErrorAction Stop
        $deleted++
        Write-Log "deleted: $($u.samAccountName) (sid $($u.sid))" 'OK'
    } catch {
        $failed++
        Write-Log "failed: $($u.samAccountName) :: $($_.Exception.Message)" 'ERROR'
    }
}
$sw.Stop()
Write-Log ("Done. deleted={0} alreadyGone={1} failed={2} elapsed={3:N1}s" -f `
    $deleted, $alreadyGone, $failed, $sw.Elapsed.TotalSeconds) 'OK'

# Archive the manifest as an orphan-pass snapshot so the SID list is preserved.
$archivePath = "$AdManifest.orphan-pass-{0:yyyyMMdd-HHmmss}" -f (Get-Date)
Copy-Item -LiteralPath $AdManifest -Destination $archivePath -Force
Write-Log "Snapshotted manifest to $archivePath"

$summary = [ordered]@{
    terminatedInManifest = $terminated.Count
    deleted              = $deleted
    alreadyGone          = $alreadyGone
    failed               = $failed
    elapsedSeconds       = [Math]::Round($sw.Elapsed.TotalSeconds, 2)
    manifestSnapshot     = $archivePath
    logPath              = $LogPath
}
$summary | ConvertTo-Json -Depth 3 | Set-Content -Path (Join-Path $LogDir 'orphans-summary.json') -Encoding utf8
$summary | Format-List
if ($failed -gt 0) { exit 1 }
