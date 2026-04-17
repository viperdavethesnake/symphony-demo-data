#Requires -Version 7.0
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    One-shot initializer for the data disk that hosts S:\Share.

.DESCRIPTION
    Finds the raw unformatted disk (or the disk matching -DiskNumber),
    initializes GPT, creates a single partition spanning the disk,
    assigns drive letter S:, formats NTFS with 4 KB clusters and large
    file records, disables 8.3 names, disables last-access updates,
    disables indexing, and creates S:\Share with the sparse flag set.

    Format parameters locked in (authoritative — see docs/04-vm-provisioning.md
    Phase 3 and decision D-044):
        DriveLetter         S
        FileSystem          NTFS
        PartitionStyle      GPT
        AllocationUnitSize  4096 bytes (4 KB)
        UseLargeFRS         enabled
        VolumeLabel         AcmeShare
        ShortNames (8.3)    disabled
        LastAccessUpdates   disabled
        Indexing            disabled
        Compression         disabled (conflicts with sparse)
        Sparse flag         set on S:\Share

    Idempotent-ish: if S: is already present and formatted, script
    reports state, ensures S:\Share exists with sparse flag, and exits
    0 without destroying anything. Use -Force to wipe and reformat.

.PARAMETER DiskNumber
    Explicit target disk number. If omitted, picks the first RAW disk
    that is at least 100 GB.

.PARAMETER Force
    Wipe and reformat even if the target disk is already partitioned.
    Irreversible — all data on the disk is lost.

.EXAMPLE
    pwsh -File .\scripts\Initialize-AcmeDisk.ps1
    Auto-detects the new RAW disk and provisions it.

.EXAMPLE
    pwsh -File .\scripts\Initialize-AcmeDisk.ps1 -DiskNumber 1
    Targets disk 1 explicitly (use when multiple RAW disks exist).

.EXAMPLE
    pwsh -File .\scripts\Initialize-AcmeDisk.ps1 -DiskNumber 1 -Force
    Destructive: wipes disk 1 and reformats from scratch.
#>
[CmdletBinding()]
param(
    [int]$DiskNumber,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

# Virtio / hypervisor attach gotcha: freshly-attached disks often come up
# offline and/or read-only. Bring anything in that state online so the rest
# of the script can see and modify them.
$offline = Get-Disk | Where-Object IsOffline
foreach ($d in $offline) {
    Write-Host "Disk $($d.Number) is offline — bringing online."
    Set-Disk -Number $d.Number -IsOffline $false
}
$readonly = Get-Disk | Where-Object IsReadOnly
foreach ($d in $readonly) {
    Write-Host "Disk $($d.Number) is read-only — clearing read-only flag."
    Set-Disk -Number $d.Number -IsReadOnly $false
}

# Find the target disk
if (-not $PSBoundParameters.ContainsKey('DiskNumber')) {
    $candidate = Get-Disk | Where-Object { $_.PartitionStyle -eq 'RAW' -and $_.Size -ge 100GB } | Select-Object -First 1
    if (-not $candidate) { throw "No RAW disk >= 100 GB found. Pass -DiskNumber explicitly." }
    $DiskNumber = $candidate.Number
}
Write-Host "Target disk: $DiskNumber"

$disk = Get-Disk -Number $DiskNumber
Write-Host ("Size: {0:N0} GB  Style: {1}  HealthStatus: {2}" -f ($disk.Size/1GB), $disk.PartitionStyle, $disk.HealthStatus)

# Short-circuit if S: already exists
$existing = Get-Volume -DriveLetter S -ErrorAction SilentlyContinue
if ($existing -and -not $Force) {
    Write-Host "S: already exists (FS=$($existing.FileSystem) Size=$([math]::Round($existing.Size/1GB,1))GB). Use -Force to wipe."
    if (-not (Test-Path 'S:\Share')) { New-Item -Path 'S:\Share' -ItemType Directory | Out-Null }
    fsutil sparse setflag 'S:\Share' | Out-Null
    exit 0
}

if ($Force -and $disk.PartitionStyle -ne 'RAW') {
    Write-Warning "Force specified — wiping disk $DiskNumber"
    Clear-Disk -Number $DiskNumber -RemoveData -RemoveOEM -Confirm:$false
}

# Initialize GPT
Initialize-Disk -Number $DiskNumber -PartitionStyle GPT

# Single partition, max size, drive letter S
$part = New-Partition -DiskNumber $DiskNumber -UseMaximumSize -DriveLetter S

# Format NTFS with the right flags
Format-Volume -DriveLetter S `
    -FileSystem NTFS `
    -AllocationUnitSize 4096 `
    -UseLargeFRS `
    -NewFileSystemLabel 'AcmeShare' `
    -Force `
    -Confirm:$false | Out-Null

# Volume-level tweaks
# Disable 8.3 name creation globally, and explicitly on S:
fsutil behavior set disable8dot3 2 | Out-Null
fsutil 8dot3name set S: 1 | Out-Null

# Disable last-access updates globally (affects all volumes — acceptable for a lab VM)
fsutil behavior set disablelastaccess 1 | Out-Null

# Disable Windows Search indexing on the volume.
# Get-WmiObject / $_.Put() was removed in PowerShell 7; use CIM instead.
Get-CimInstance -ClassName Win32_Volume -Filter "DriveLetter='S:'" |
    Set-CimInstance -Property @{ IndexingEnabled = $false }

# Create the share root and mark sparse
New-Item -Path 'S:\Share' -ItemType Directory -Force | Out-Null
fsutil sparse setflag 'S:\Share' | Out-Null

# Report
$summary = [ordered]@{
    DiskNumber       = $DiskNumber
    SizeGB           = [math]::Round($disk.Size/1GB, 1)
    Partition        = (Get-Partition -DiskNumber $DiskNumber | Where-Object DriveLetter -eq 'S').PartitionNumber
    FileSystem       = (Get-Volume -DriveLetter S).FileSystem
    AllocationUnit   = '4096'
    LargeFRS         = $true
    ShortNames       = 'Disabled'
    LastAccessUpdate = 'Disabled'
    Indexing         = 'Disabled'
    SharePath        = 'S:\Share'
    SparseFlag       = 'Set'
}
$summary | Format-List
Write-Host "Disk ready for file generation."
