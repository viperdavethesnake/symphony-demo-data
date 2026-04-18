#Requires -Version 7.0
<#
.SYNOPSIS
    Verifies the generated dataset matches the manifests. Produces
    manifests/logs/verification.json — the "ground truth" report the
    Symphony demo owner can wave at the product during setup.

.DESCRIPTION
    Runs four checks:
        1. Folder existence — every relPath in folder-manifest exists on disk
        2. File existence / size / magic bytes — sampled subset of file-manifest
        3. Timestamp match (btime/mtime/atime) — sampled subset, ±1 second tolerance
        4. Owner SID match — sampled subset
        5. ACL sanity — every folder has at least one ACE; summary of
           well-known-SID counts
        6. Distribution checks — age-bucket, ext-mix, dup-group counts vs
           config targets

    Sample size is from -SampleSize (default 500) or the whole manifest if
    smaller. The verification is statistical at scale, exact on dev.

.PARAMETER ConfigPath
    Path to config/main-config(.dev).json.
.PARAMETER SampleSize
    Number of file records to sample for per-file checks. Default 500.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ConfigPath,
    [int]$SampleSize = 500
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$RepoRoot    = Split-Path -Parent $PSScriptRoot
$ManifestDir = Join-Path $RepoRoot 'manifests'
$LogDir      = Join-Path $ManifestDir 'logs'
$FolderManifest = Join-Path $ManifestDir 'folder-manifest.json'
$FileManifest   = Join-Path $ManifestDir 'file-manifest.jsonl'
foreach ($p in @($FolderManifest, $FileManifest)) {
    if (-not (Test-Path $p)) { throw "missing manifest: $p" }
}
if (-not (Test-Path $LogDir)) { New-Item -Path $LogDir -ItemType Directory | Out-Null }

$RunStamp = '{0:yyyyMMdd-HHmmss}' -f (Get-Date)
$LogPath = Join-Path $LogDir ("verify-$RunStamp.log")
$VerifyOut = Join-Path $LogDir 'verification.json'

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

Write-Log "Test-AcmeData starting — sampleSize=$SampleSize"
$cfg = Import-JsonFile $ConfigPath
$folderManifest = Import-JsonFile $FolderManifest
$folders = $folderManifest.folders
$fileLines = [System.IO.File]::ReadAllLines($FileManifest)
$totalRecords = $fileLines.Length
Write-Log "folder records=$($folders.Count)  file records=$totalRecords"

# Filetypes for magic-byte verification
$filetypes = Import-JsonFile (Join-Path (Split-Path -Parent (Resolve-Path $ConfigPath)) 'filetypes.json')
$extHeader = @{}
foreach ($cat in $filetypes.PSObject.Properties) {
    if ($cat.Name.StartsWith('$')) { continue }
    foreach ($e in $cat.Value.PSObject.Properties) {
        if ($e.Name.StartsWith('$')) { continue }
        $extHeader[$e.Name] = [string]$e.Value.header
    }
}

function Convert-HexToBytes {
    param([string]$Hex)
    if ([string]::IsNullOrEmpty($Hex)) { return [byte[]]@() }
    $n = [int]($Hex.Length / 2)
    $b = New-Object 'byte[]' $n
    for ($i = 0; $i -lt $n; $i++) { $b[$i] = [Convert]::ToByte($Hex.Substring($i*2,2), 16) }
    return ,$b
}

# ---------------------------------------------------------------------------
# (1) Folder existence
# ---------------------------------------------------------------------------
Write-Log "Check 1: folder existence"
$folderMissing = 0
foreach ($f in $folders) {
    if ($f.relPath -eq '') { continue }
    if (-not (Test-Path -LiteralPath $f.path -PathType Container)) { $folderMissing++ }
}
Write-Log ("folders missing on disk: {0} / {1}" -f $folderMissing, ($folders.Count - 1))

# ---------------------------------------------------------------------------
# (2-4) Sample per-file checks
# ---------------------------------------------------------------------------
Write-Log "Checks 2-4: sampling files"
$seed = [int]$cfg.meta.seed
$rng = [System.Random]::new($seed -bxor 0x7e57)
$n = [Math]::Min($SampleSize, $totalRecords)
$sampleIdx = @()
$seen = @{}
while ($sampleIdx.Count -lt $n) {
    $i = $rng.Next(0, $totalRecords)
    if (-not $seen.ContainsKey($i)) { $seen[$i] = $true; $sampleIdx += $i }
}

$fileMissing = 0; $sizeMismatch = 0; $headerMismatch = 0
$tsMismatch = 0; $ownerMismatch = 0
$checkedHeaders = 0

foreach ($idx in $sampleIdx) {
    $rec = $fileLines[$idx] | ConvertFrom-Json
    if (-not (Test-Path -LiteralPath $rec.path -PathType Leaf)) { $fileMissing++; continue }
    $fi = [System.IO.FileInfo]::new($rec.path)

    # Size (accept the min-clamp applied at write time)
    $headerHex = if ($extHeader.ContainsKey($rec.ext)) { $extHeader[$rec.ext] } else { '' }
    $headerLen = [int]($headerHex.Length / 2)
    $expectedSize = [int64]$rec.size
    if ($expectedSize -lt $headerLen) { $expectedSize = $headerLen }
    if ($fi.Length -ne $expectedSize) { $sizeMismatch++ }

    # Timestamps ±1 second
    $tsOk = $true
    $rb = ([datetime]$rec.btime).ToUniversalTime()
    $rm = ([datetime]$rec.mtime).ToUniversalTime()
    $ra = ([datetime]$rec.atime).ToUniversalTime()
    if ([Math]::Abs(($fi.CreationTimeUtc   - $rb).TotalSeconds) -gt 1) { $tsOk = $false }
    if ([Math]::Abs(($fi.LastWriteTimeUtc  - $rm).TotalSeconds) -gt 1) { $tsOk = $false }
    if ([Math]::Abs(($fi.LastAccessTimeUtc - $ra).TotalSeconds) -gt 1) { $tsOk = $false }
    if (-not $tsOk) { $tsMismatch++ }

    # Magic bytes
    if ($headerLen -gt 0) {
        $checkedHeaders++
        $expected = Convert-HexToBytes $headerHex
        $read = New-Object 'byte[]' $headerLen
        $fs = [System.IO.File]::OpenRead($rec.path)
        try { [void]$fs.Read($read, 0, $headerLen) } finally { $fs.Dispose() }
        for ($b = 0; $b -lt $headerLen; $b++) {
            if ($read[$b] -ne $expected[$b]) { $headerMismatch++; break }
        }
    }

    # Owner (pure managed via GetAccessControl extension)
    try {
        $sec = [System.IO.FileSystemAclExtensions]::GetAccessControl($fi)
        $ownerStr = ($sec.GetOwner([System.Security.Principal.SecurityIdentifier])).Value
        if ($ownerStr -ne $rec.ownerSid) { $ownerMismatch++ }
    } catch { $ownerMismatch++ }
}

Write-Log ("sample ({0}): missing={1} sizeDiff={2} headerDiff={3}/{4} tsDiff={5} ownerDiff={6}" -f `
    $n, $fileMissing, $sizeMismatch, $headerMismatch, $checkedHeaders, $tsMismatch, $ownerMismatch)

# ---------------------------------------------------------------------------
# (5) ACL sanity — sample folders, count ACEs, note well-known SIDs
# ---------------------------------------------------------------------------
Write-Log "Check 5: folder ACL sanity"
$aclSample = [Math]::Min(200, $folders.Count - 1)
$fRng = [System.Random]::new($seed -bxor 0xacc1)
$foldersOnly = @($folders | Where-Object { $_.relPath -ne '' })
$aclIdxs = @()
$seen = @{}
while ($aclIdxs.Count -lt $aclSample) {
    $i = $fRng.Next(0, $foldersOnly.Count)
    if (-not $seen.ContainsKey($i)) { $seen[$i] = $true; $aclIdxs += $i }
}
$noAcl = 0; $totalAces = 0; $withEveryone = 0; $withAuthUsers = 0
foreach ($i in $aclIdxs) {
    $f = $foldersOnly[$i]
    try {
        $di = [System.IO.DirectoryInfo]::new($f.path)
        $sec = [System.IO.FileSystemAclExtensions]::GetAccessControl($di)
        $rules = $sec.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier])
        if ($rules.Count -eq 0) { $noAcl++; continue }
        $totalAces += $rules.Count
        foreach ($r in $rules) {
            if ($r.IdentityReference.Value -eq 'S-1-1-0') { $withEveryone++ }
            if ($r.IdentityReference.Value -eq 'S-1-5-11') { $withAuthUsers++ }
        }
    } catch {
        $noAcl++
    }
}
Write-Log ("acl sample ({0}): noAcl={1} avgAces={2:N1} withEveryone={3} withAuthUsers={4}" -f `
    $aclSample, $noAcl, ($totalAces / [Math]::Max(1, ($aclSample - $noAcl))), $withEveryone, $withAuthUsers)

# ---------------------------------------------------------------------------
# (6) Distribution checks vs config targets
# ---------------------------------------------------------------------------
Write-Log "Check 6: distribution vs config"
# These read the manifest, not the disk — verifying the plan was faithful.
$ageBuckets = @('last30days','days30to365','years1to2','years2to5','years5to10','years10to15')
$ageCounts = @{}; foreach ($b in $ageBuckets) { $ageCounts[$b] = 0 }
$extCounts = @{}
$dupGroups = @{}
$driftGroups = @{}
$termSids = @{}
if (Test-Path (Join-Path $ManifestDir 'ad-manifest.json')) {
    $ad = Import-JsonFile (Join-Path $ManifestDir 'ad-manifest.json')
    foreach ($u in ($ad.users | Where-Object status -eq 'terminated')) { $termSids[$u.sid] = $true }
}
$termOwners = 0
foreach ($line in $fileLines) {
    $r = $line | ConvertFrom-Json
    if ($ageCounts.ContainsKey($r.ageBucket)) { $ageCounts[$r.ageBucket]++ }
    if (-not $extCounts.ContainsKey($r.ext)) { $extCounts[$r.ext] = 0 }
    $extCounts[$r.ext]++
    if ($r.dupGroup) {
        if ($r.dupGroup.StartsWith('d')) {
            if (-not $dupGroups.ContainsKey($r.dupGroup)) { $dupGroups[$r.dupGroup] = 0 }
            $dupGroups[$r.dupGroup]++
        } elseif ($r.dupGroup.StartsWith('v')) {
            if (-not $driftGroups.ContainsKey($r.dupGroup)) { $driftGroups[$r.dupGroup] = 0 }
            $driftGroups[$r.dupGroup]++
        }
    }
    if ($r.ownerSid -and $termSids.ContainsKey($r.ownerSid)) { $termOwners++ }
}
$agePct = [ordered]@{}
foreach ($b in $ageBuckets) {
    $agePct[$b] = @{
        target = [double]$cfg.ageDistribution.$b
        actual = [Math]::Round(100.0 * $ageCounts[$b] / [Math]::Max(1, $totalRecords), 2)
    }
}

# ---------------------------------------------------------------------------
# Emit report
# ---------------------------------------------------------------------------
$pass = ($folderMissing -eq 0 -and $fileMissing -eq 0 -and $sizeMismatch -eq 0 -and $headerMismatch -eq 0 -and $tsMismatch -eq 0 -and $ownerMismatch -eq 0 -and $noAcl -eq 0)

$report = [ordered]@{
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
    rootPath       = $folderManifest.meta.rootPath
    folderRecords  = $folders.Count
    fileRecords    = $totalRecords
    checks = [ordered]@{
        folderExistence = [ordered]@{ missing = $folderMissing; totalChecked = $folders.Count - 1 }
        fileSample      = [ordered]@{
            size          = $n
            missing       = $fileMissing
            sizeMismatch  = $sizeMismatch
            headerMismatch= $headerMismatch
            headersChecked= $checkedHeaders
            timestampMismatch = $tsMismatch
            ownerMismatch = $ownerMismatch
        }
        aclSample       = [ordered]@{
            size          = $aclSample
            withoutAcl    = $noAcl
            avgAces       = [Math]::Round($totalAces / [Math]::Max(1, ($aclSample - $noAcl)), 2)
            withEveryone  = $withEveryone
            withAuthUsers = $withAuthUsers
        }
        distribution    = [ordered]@{
            ageBucketsPct      = $agePct
            duplicateGroups    = $dupGroups.Count
            duplicateRecords   = ($dupGroups.Values | Measure-Object -Sum).Sum
            driftGroups        = $driftGroups.Count
            driftRecords       = ($driftGroups.Values | Measure-Object -Sum).Sum
            terminatedOwners   = $termOwners
        }
    }
    pass = $pass
    logPath = $LogPath
}
$report | ConvertTo-Json -Depth 6 | Set-Content -Path $VerifyOut -Encoding utf8
Write-Log ("Verification {0}. Report: {1}" -f $(if ($pass) { 'PASS' } else { 'FAIL' }), $VerifyOut) $(if ($pass) { 'OK' } else { 'ERROR' })
$report | Format-List
if (-not $pass) { exit 2 }
