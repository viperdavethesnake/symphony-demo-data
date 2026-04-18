#Requires -Version 7.0
<#
.SYNOPSIS
    Master orchestrator — runs every generation phase end-to-end.

.DESCRIPTION
    Runs the full pipeline in order:
        ad      Build-AcmeAD.ps1       (only if ad-manifest.json missing)
        plan    Plan-AcmeData.ps1
        2c      Build-AcmeFolders.ps1
        2d      Build-AcmeFiles.ps1
        2e      Set-AcmeTimestamps.ps1
        2f      Set-AcmeOwners.ps1
        2g      Set-AcmeACLs.ps1
        2h      Remove-AcmeOrphans.ps1 (only with -RunOrphans)
        verify  Test-AcmeData.ps1

    Each phase is timed; a consolidated run-summary.json is written at
    the end. Stops on the first phase failure (ErrorActionPreference=Stop).

.PARAMETER ConfigPath
    Path to config/main-config(.dev).json.
.PARAMETER SkipPhase
    Array of phase ids to skip (e.g. -SkipPhase 'ad','plan','2c','2d').
.PARAMETER RunOrphans
    Opt-in switch to run Remove-AcmeOrphans.ps1. Off by default since it
    mutates live AD.
.PARAMETER DryRun
    Run only the planning phases (ad + plan) — no disk writes beyond
    manifests/.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ConfigPath,
    [string[]]$SkipPhase = @(),
    [switch]$RunOrphans,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$RepoRoot    = Split-Path -Parent $PSScriptRoot
$ScriptsDir  = $PSScriptRoot
$ManifestDir = Join-Path $RepoRoot 'manifests'
$LogDir      = Join-Path $ManifestDir 'logs'
if (-not (Test-Path $LogDir)) { New-Item -Path $LogDir -ItemType Directory -Force | Out-Null }

$RunStamp = '{0:yyyyMMdd-HHmmss}' -f (Get-Date)
$LogPath     = Join-Path $LogDir "run-$RunStamp.log"
$SummaryPath = Join-Path $LogDir 'run-summary.json'

function Write-Log {
    param([string]$Message, [ValidateSet('INFO','WARN','ERROR','OK')][string]$Level = 'INFO')
    $stamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    Add-Content -Path $LogPath -Value "[$stamp] [$Level] $Message"
    $color = switch ($Level) { 'ERROR' {'Red'} 'WARN' {'Yellow'} 'OK' {'Green'} default {'Gray'} }
    Write-Host "[$stamp] [$Level] $Message" -ForegroundColor $color
}

$phases = @(
    @{ id='ad';     script='Build-AcmeAD.ps1';       skipIf={ Test-Path (Join-Path $ManifestDir 'ad-manifest.json') } }
    @{ id='plan';   script='Plan-AcmeData.ps1' }
    @{ id='2c';     script='Build-AcmeFolders.ps1' }
    @{ id='2d';     script='Build-AcmeFiles.ps1' }
    @{ id='2e';     script='Set-AcmeTimestamps.ps1' }
    @{ id='2f';     script='Set-AcmeOwners.ps1' }
    @{ id='2g';     script='Set-AcmeACLs.ps1' }
    @{ id='2h';     script='Remove-AcmeOrphans.ps1'; optIn=$true }
    @{ id='verify'; script='Test-AcmeData.ps1' }
)

if ($DryRun) {
    Write-Log "DryRun: limiting to ad + plan phases"
    $phases = $phases | Where-Object { $_.id -in @('ad','plan') }
}

Write-Log "Build-AcmeData starting — config=$ConfigPath  skip=$($SkipPhase -join ',')  runOrphans=$RunOrphans  dryRun=$DryRun"
$overall = [System.Diagnostics.Stopwatch]::StartNew()
$results = [System.Collections.Generic.List[object]]::new()

foreach ($phase in $phases) {
    if ($SkipPhase -contains $phase.id) {
        Write-Log "[$($phase.id)] SKIP (requested)"
        $results.Add([pscustomobject]@{ id=$phase.id; script=$phase.script; status='skipped'; elapsedSec=0 })
        continue
    }
    if ($phase.ContainsKey('skipIf') -and (& $phase.skipIf)) {
        Write-Log "[$($phase.id)] SKIP (already satisfied)"
        $results.Add([pscustomobject]@{ id=$phase.id; script=$phase.script; status='skipped-satisfied'; elapsedSec=0 })
        continue
    }
    if ($phase.ContainsKey('optIn') -and $phase.optIn -and -not $RunOrphans) {
        Write-Log "[$($phase.id)] SKIP (opt-in; pass -RunOrphans to include)"
        $results.Add([pscustomobject]@{ id=$phase.id; script=$phase.script; status='skipped-optin'; elapsedSec=0 })
        continue
    }

    $scriptPath = Join-Path $ScriptsDir $phase.script
    if (-not (Test-Path $scriptPath)) {
        Write-Log "[$($phase.id)] MISSING script $scriptPath" 'ERROR'
        throw "Phase script not found: $scriptPath"
    }

    Write-Log "[$($phase.id)] START $($phase.script)"
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        # Extra args for specific phases
        $extra = @{}
        if ($phase.id -eq '2h' -and $RunOrphans) { $extra['Force'] = $true }

        & pwsh -NoProfile -File $scriptPath -ConfigPath $ConfigPath @extra
        if ($LASTEXITCODE -ne 0 -and $null -ne $LASTEXITCODE) {
            throw "phase $($phase.id) exited $LASTEXITCODE"
        }
        $sw.Stop()
        Write-Log ("[$($phase.id)] DONE in {0:N1}s" -f $sw.Elapsed.TotalSeconds) 'OK'
        $results.Add([pscustomobject]@{ id=$phase.id; script=$phase.script; status='ok'; elapsedSec=[Math]::Round($sw.Elapsed.TotalSeconds, 2) })
    } catch {
        $sw.Stop()
        Write-Log "[$($phase.id)] FAILED: $($_.Exception.Message)" 'ERROR'
        $results.Add([pscustomobject]@{ id=$phase.id; script=$phase.script; status='failed'; elapsedSec=[Math]::Round($sw.Elapsed.TotalSeconds, 2); error=$_.Exception.Message })
        break
    }
}
$overall.Stop()

$anyFailed = @($results | Where-Object { $_.status -eq 'failed' }).Count -gt 0
$summary = [ordered]@{
    runStamp       = $RunStamp
    configPath     = (Resolve-Path $ConfigPath).Path
    dryRun         = [bool]$DryRun
    skipPhase      = $SkipPhase
    runOrphans     = [bool]$RunOrphans
    totalElapsedSec= [Math]::Round($overall.Elapsed.TotalSeconds, 2)
    phases         = @($results)
    success        = -not $anyFailed
    logPath        = $LogPath
}
$summary | ConvertTo-Json -Depth 5 | Set-Content -Path $SummaryPath -Encoding utf8

Write-Log "------------------------------"
Write-Log ("Total: {0:N1}s  success={1}" -f $overall.Elapsed.TotalSeconds, (-not $anyFailed)) $(if ($anyFailed) { 'ERROR' } else { 'OK' })
$results | Format-Table id, script, status, elapsedSec
Write-Log "Run summary: $SummaryPath"

if ($anyFailed) { exit 1 }
