#Requires -Version 7.0
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Fully disables Microsoft Defender on the lab VM.

.DESCRIPTION
    Isolated lab-VM only. Runs three layers so the change survives
    reboots and Defender signature updates:

        1. Set-MpPreference — flips every runtime-scanning knob off and
           neutralizes cloud reporting / sample submission / PUA / etc.
        2. Group-policy registry keys under
           HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender — supported
           on Server SKUs only (blocked on client Windows 10/11). These
           prevent the service from re-enabling scanning on restart.
        3. Exclusion paths on S:\ and the repo root as belt-and-suspenders.

    Does NOT uninstall the Windows-Defender feature (that requires a
    reboot; preferences + policy are sufficient for throughput). If you
    need the feature removed, run:
        Uninstall-WindowsFeature -Name Windows-Defender -Restart

    The Server-SKU policy keys (DisableAntiSpyware / DisableAntiVirus)
    cause the WinDefend service to stand itself down shortly after they
    are written — AMRunningMode transitions to "Not running" and
    Get-MpPreference starts returning 0x800106ba (service unreachable).
    That's the success state. WinDefend is PPL-protected so Stop-Service
    won't work directly; we don't try.

    Requires Tamper Protection to be OFF. If it's on, preference writes
    silently revert. Script checks and warns.

.NOTES
    Recorded as D-047 in docs/decisions.md. Lab VM scope only —
    do not point this at a machine you actually want protected.

.EXAMPLE
    pwsh -File .\scripts\Disable-AcmeDefender.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

# --- Preconditions ---
$status = Get-MpComputerStatus
if ($status.IsTamperProtected) {
    throw "Tamper Protection is ON — preference writes will silently revert. Disable via Windows Security UI (Virus & threat protection settings → Tamper Protection Off) and re-run."
}
Write-Host "Defender present. Tamper Protection: Off. Proceeding."

# --- Layer 1: Set-MpPreference knobs ---
Write-Host "Layer 1: flipping Set-MpPreference flags..."
$prefs = @{
    DisableRealtimeMonitoring                   = $true
    DisableBehaviorMonitoring                   = $true
    DisableBlockAtFirstSeen                     = $true
    DisableIOAVProtection                       = $true
    DisableScriptScanning                       = $true
    DisableArchiveScanning                      = $true
    DisableIntrusionPreventionSystem            = $true
    DisableScanningMappedNetworkDrivesForFullScan = $true
    DisableScanningNetworkFiles                 = $true
    DisableEmailScanning                        = $true
    DisableRemovableDriveScanning               = $true
    DisableRestorePoint                         = $true
    DisableCatchupFullScan                      = $true
    DisableCatchupQuickScan                     = $true
    SubmitSamplesConsent                        = 2  # NeverSend
    MAPSReporting                               = 0  # Disabled (no cloud)
    CloudBlockLevel                             = 0
    PUAProtection                               = 0
}
Set-MpPreference @prefs

# --- Layer 2: Group-policy registry keys (Server SKU) ---
Write-Host "Layer 2: writing policy registry keys..."
$defPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender'
$rtpPath = Join-Path $defPath 'Real-Time Protection'
$spyPath = Join-Path $defPath 'Spynet'
foreach ($p in @($defPath, $rtpPath, $spyPath)) {
    if (-not (Test-Path $p)) { New-Item -Path $p -Force | Out-Null }
}
Set-ItemProperty -Path $defPath -Name DisableAntiSpyware         -Value 1 -Type DWord
Set-ItemProperty -Path $defPath -Name DisableAntiVirus           -Value 1 -Type DWord
Set-ItemProperty -Path $defPath -Name DisableRoutinelyTakingAction -Value 1 -Type DWord
Set-ItemProperty -Path $rtpPath -Name DisableRealtimeMonitoring  -Value 1 -Type DWord
Set-ItemProperty -Path $rtpPath -Name DisableBehaviorMonitoring  -Value 1 -Type DWord
Set-ItemProperty -Path $rtpPath -Name DisableOnAccessProtection  -Value 1 -Type DWord
Set-ItemProperty -Path $rtpPath -Name DisableScanOnRealtimeEnable -Value 1 -Type DWord
Set-ItemProperty -Path $rtpPath -Name DisableIOAVProtection      -Value 1 -Type DWord
Set-ItemProperty -Path $spyPath -Name SpynetReporting            -Value 0 -Type DWord
Set-ItemProperty -Path $spyPath -Name SubmitSamplesConsent       -Value 2 -Type DWord

# --- Layer 3: exclusion paths (defence in depth) ---
Write-Host "Layer 3: adding exclusion paths..."
$exclusions = @('S:\', 'C:\Projects')
foreach ($path in $exclusions) {
    Add-MpPreference -ExclusionPath $path
}

# --- Verify ---
# The service takes a moment to read the new policy keys and stand itself
# down. Poll for up to ~15 seconds before giving up.
Write-Host ""
Write-Host "Waiting for service to react to policy keys..."
$deadline = (Get-Date).AddSeconds(15)
$final = $null
do {
    Start-Sleep -Seconds 2
    $final = Get-MpComputerStatus
    if (-not $final.AntivirusEnabled) { break }
} while ((Get-Date) -lt $deadline)

Write-Host ""
Write-Host "=== Final status ==="
$final | Select-Object `
    AMServiceEnabled,
    AntivirusEnabled,
    RealTimeProtectionEnabled,
    IoavProtectionEnabled,
    BehaviorMonitorEnabled,
    OnAccessProtectionEnabled,
    IsTamperProtected,
    AMRunningMode | Format-List

# Get-MpPreference will fail with 0x800106ba once the service is down —
# that's the success signal. Don't treat as fatal.
Write-Host "=== Exclusions ==="
try {
    (Get-MpPreference).ExclusionPath
} catch {
    Write-Host "(Get-MpPreference unreachable — service is down, exclusions moot)"
}

Write-Host ""
if (-not $final.AntivirusEnabled -and $final.AMRunningMode -eq 'Not running') {
    Write-Host "Defender is fully disabled (service not running)." -ForegroundColor Green
} elseif (-not ($final.RealTimeProtectionEnabled -or $final.IoavProtectionEnabled -or $final.BehaviorMonitorEnabled -or $final.OnAccessProtectionEnabled)) {
    Write-Host "Defender scanning is OFF (service still up but inert)." -ForegroundColor Green
} else {
    Write-Warning "Some scanning flags are still TRUE. Reboot and re-check — Get-MpComputerStatus should report AntivirusEnabled=False, AMRunningMode='Not running'."
}
