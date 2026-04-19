#Requires -Version 7.0
<#
.SYNOPSIS
    Verifies the generated dataset on disk. Produces manifests/logs/verification.json.

.DESCRIPTION
    Post-streaming-rewrite (see docs/06-streaming-rewrite.md), there is no
    file-manifest.jsonl to diff against — file existence, magic bytes,
    timestamps, and owners are validated directly from disk.

    Checks:
        1. Folder existence        — every relPath in folder-manifest exists on disk.
        2-4. Disk sample           — reservoir-sampled ~500 files (from Directory.EnumerateFiles);
                                     for each: valid magic bytes, btime ≤ mtime ≤ atime, non-null owner SID.
        5. ACL sanity              — sampled folders; count ACEs, note Everyone / AuthenticatedUsers SIDs.
        6. Distributions           — total files per extension (exact, from the single streaming pass)
                                     and per age bucket (from the 500-file sample), vs config targets.

.PARAMETER ConfigPath
    Path to config/main-config(.dev).json.
.PARAMETER SampleSize
    Number of disk files to sample for per-file checks + age histogram. Default 500.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ConfigPath,
    [int]$SampleSize = 500
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$RepoRoot       = Split-Path -Parent $PSScriptRoot
$ManifestDir    = Join-Path $RepoRoot 'manifests'
$LogDir         = Join-Path $ManifestDir 'logs'
$FolderManifest = Join-Path $ManifestDir 'folder-manifest.json'
if (-not (Test-Path $FolderManifest)) { throw "missing manifest: $FolderManifest" }
if (-not (Test-Path $LogDir)) { New-Item -Path $LogDir -ItemType Directory | Out-Null }

$RunStamp  = '{0:yyyyMMdd-HHmmss}' -f (Get-Date)
$LogPath   = Join-Path $LogDir ("verify-$RunStamp.log")
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

function Convert-HexToBytes {
    param([string]$Hex)
    if ([string]::IsNullOrEmpty($Hex)) { return ,([byte[]]@()) }
    $n = [int]($Hex.Length / 2)
    $b = New-Object 'byte[]' $n
    for ($i = 0; $i -lt $n; $i++) { $b[$i] = [Convert]::ToByte($Hex.Substring($i*2,2), 16) }
    return ,$b
}

Write-Log "Test-AcmeData starting — sampleSize=$SampleSize"
$cfg            = Import-JsonFile $ConfigPath
$folderManifest = Import-JsonFile $FolderManifest
$folders        = $folderManifest.folders
$rootPath       = $folderManifest.meta.rootPath
Write-Log "folder records=$($folders.Count)  rootPath=$rootPath"

# Extension → header + category map
$filetypes = Import-JsonFile (Join-Path (Split-Path -Parent (Resolve-Path $ConfigPath)) 'filetypes.json')
$extHeader = @{}
$extCategory = @{}
foreach ($cat in $filetypes.PSObject.Properties) {
    if ($cat.Name.StartsWith('$')) { continue }
    foreach ($e in $cat.Value.PSObject.Properties) {
        if ($e.Name.StartsWith('$')) { continue }
        $extHeader[$e.Name]   = [string]$e.Value.header
        $extCategory[$e.Name] = $cat.Name
    }
}

# Terminated SIDs (for distribution check)
$termSids = @{}
if (Test-Path (Join-Path $ManifestDir 'ad-manifest.json')) {
    $ad = Import-JsonFile (Join-Path $ManifestDir 'ad-manifest.json')
    foreach ($u in ($ad.users | Where-Object status -eq 'terminated')) { $termSids[$u.sid] = $true }
}

# Time anchor for age bucketing
if ($folderManifest.meta.PSObject.Properties['timeAnchorUtc']) {
    $nowUtc = ([datetime]$folderManifest.meta.timeAnchorUtc).ToUniversalTime()
} else {
    $nowUtc = (Get-Date).ToUniversalTime()
}

function Get-AgeBucket {
    param([datetime]$MtimeUtc)
    $days = ($nowUtc - $MtimeUtc).TotalDays
    if ($days -lt 30)   { return 'last30days' }
    if ($days -lt 365)  { return 'days30to365' }
    if ($days -lt 730)  { return 'years1to2' }
    if ($days -lt 1825) { return 'years2to5' }
    if ($days -lt 3650) { return 'years5to10' }
    return 'years10to15'
}

# ---------------------------------------------------------------------------
# (1) Folder existence
# ---------------------------------------------------------------------------
Write-Log "Check 1: folder existence"
$folderMissing = 0
$folderExpected = 0
foreach ($f in $folders) {
    if ($f.relPath -eq '') { continue }
    $folderExpected++
    if (-not (Test-Path -LiteralPath $f.path -PathType Container)) { $folderMissing++ }
}
Write-Log ("folders missing on disk: {0} / {1}" -f $folderMissing, $folderExpected)

# ---------------------------------------------------------------------------
# (2-4 + 6a) Single streaming pass over disk:
#   - reservoir-sample SampleSize paths
#   - count total files + per-extension totals (exact)
# ---------------------------------------------------------------------------
Write-Log "Checks 2-4 + distribution: streaming disk enumeration"
$swScan = [System.Diagnostics.Stopwatch]::StartNew()
$seed = [int]$cfg.meta.seed
$rng  = [System.Random]::new($seed -bxor 0x7e57)

$reservoir = New-Object 'string[]' $SampleSize
$scanned = 0
$extCounts = @{}

$enumOpts = New-Object System.IO.EnumerationOptions
$enumOpts.RecurseSubdirectories = $true
$enumOpts.IgnoreInaccessible    = $true

foreach ($path in [System.IO.Directory]::EnumerateFiles($rootPath, '*', $enumOpts)) {
    $ext = [System.IO.Path]::GetExtension($path)
    if ($ext.StartsWith('.')) { $ext = $ext.Substring(1).ToLowerInvariant() }
    if (-not $extCounts.ContainsKey($ext)) { $extCounts[$ext] = 0 }
    $extCounts[$ext]++

    if ($scanned -lt $SampleSize) {
        $reservoir[$scanned] = $path
    } else {
        $j = $rng.Next(0, $scanned + 1)
        if ($j -lt $SampleSize) { $reservoir[$j] = $path }
    }
    $scanned++
}
$swScan.Stop()
$totalOnDisk = $scanned
$sampleCount = [Math]::Min($SampleSize, $totalOnDisk)
Write-Log ("scanned {0:N0} files in {1:N1}s" -f $totalOnDisk, $swScan.Elapsed.TotalSeconds)

# ---------------------------------------------------------------------------
# (2-4) Per-sample validation
# ---------------------------------------------------------------------------
$missing = 0
$headerMismatch = 0; $headersChecked = 0
$timestampInconsistent = 0
$ownerNull = 0
$termOwnerSample = 0
$ageCountsSample = @{ last30days=0; days30to365=0; years1to2=0; years2to5=0; years5to10=0; years10to15=0 }

for ($i = 0; $i -lt $sampleCount; $i++) {
    $p = $reservoir[$i]
    if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { $missing++; continue }
    try {
        $fi = [System.IO.FileInfo]::new($p)

        # Magic bytes (if the ext has a defined header)
        $ext = $fi.Extension.TrimStart('.').ToLowerInvariant()
        $headerHex = if ($extHeader.ContainsKey($ext)) { $extHeader[$ext] } else { '' }
        $headerLen = [int]($headerHex.Length / 2)
        if ($headerLen -gt 0) {
            $headersChecked++
            $expected = Convert-HexToBytes $headerHex
            $read = New-Object 'byte[]' $headerLen
            $fs = [System.IO.File]::OpenRead($p)
            try {
                $got = $fs.Read($read, 0, $headerLen)
            } finally { $fs.Dispose() }
            $bad = $false
            if ($got -lt $headerLen) { $bad = $true }
            else {
                for ($b = 0; $b -lt $headerLen; $b++) {
                    if ($read[$b] -ne $expected[$b]) { $bad = $true; break }
                }
            }
            if ($bad) { $headerMismatch++ }
        }

        # Timestamp consistency: btime ≤ mtime ≤ atime (±1s tolerance)
        $bt = $fi.CreationTimeUtc
        $mt = $fi.LastWriteTimeUtc
        $at = $fi.LastAccessTimeUtc
        if ( ($bt - $mt).TotalSeconds -gt 1 -or ($mt - $at).TotalSeconds -gt 1 ) {
            $timestampInconsistent++
        }

        # Age bucket from mtime (for distribution sample)
        $bucket = Get-AgeBucket -MtimeUtc $mt
        $ageCountsSample[$bucket]++

        # Owner — must be non-null
        try {
            $sec = [System.IO.FileSystemAclExtensions]::GetAccessControl($fi)
            $ownerStr = ($sec.GetOwner([System.Security.Principal.SecurityIdentifier])).Value
            if (-not $ownerStr) { $ownerNull++ }
            elseif ($termSids.ContainsKey($ownerStr)) { $termOwnerSample++ }
        } catch {
            $ownerNull++
        }
    } catch {
        $missing++
    }
}
Write-Log ("sample ({0}): missing={1} magicBad={2}/{3} tsBad={4} ownerNull={5} termOwner={6}" -f `
    $sampleCount, $missing, $headerMismatch, $headersChecked, $timestampInconsistent, $ownerNull, $termOwnerSample)

# ---------------------------------------------------------------------------
# (5) ACL sanity — sampled folders from the manifest
# ---------------------------------------------------------------------------
Write-Log "Check 5: folder ACL sanity"
$foldersOnly = @($folders | Where-Object { $_.relPath -ne '' })
$aclSample = [Math]::Min(200, $foldersOnly.Count)
$aclRng = [System.Random]::new($seed -bxor 0xacc1)
$seen = @{}; $aclIdxs = @()
while ($aclIdxs.Count -lt $aclSample) {
    $i = $aclRng.Next(0, $foldersOnly.Count)
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
            if ($r.IdentityReference.Value -eq 'S-1-1-0')  { $withEveryone++ }
            if ($r.IdentityReference.Value -eq 'S-1-5-11') { $withAuthUsers++ }
        }
    } catch { $noAcl++ }
}
Write-Log ("acl sample ({0}): noAcl={1} avgAces={2:N1} withEveryone={3} withAuthUsers={4}" -f `
    $aclSample, $noAcl, ($totalAces / [Math]::Max(1, ($aclSample - $noAcl))), $withEveryone, $withAuthUsers)

# ---------------------------------------------------------------------------
# (6) Distributions vs config
# ---------------------------------------------------------------------------
Write-Log "Check 6: distributions vs config"

# Category totals (exact, from the streaming pass)
$catTotals = @{}
foreach ($cat in $cfg.fileTypeMix.PSObject.Properties) {
    if ($cat.Name.StartsWith('$')) { continue }
    $catTotals[$cat.Name] = 0
}
$unclassified = 0
foreach ($ext in $extCounts.Keys) {
    if ($extCategory.ContainsKey($ext)) {
        $c = $extCategory[$ext]
        if ($catTotals.ContainsKey($c)) { $catTotals[$c] += $extCounts[$ext] } else { $unclassified += $extCounts[$ext] }
    } else {
        $unclassified += $extCounts[$ext]
    }
}
$catPct = [ordered]@{}
foreach ($name in ($cfg.fileTypeMix.PSObject.Properties | Where-Object { -not $_.Name.StartsWith('$') } | ForEach-Object { $_.Name })) {
    $target = [double]$cfg.fileTypeMix.$name
    $actual = if ($totalOnDisk -gt 0) { [Math]::Round(100.0 * $catTotals[$name] / $totalOnDisk, 2) } else { 0 }
    $catPct[$name] = [ordered]@{ target = $target; actual = $actual; count = $catTotals[$name] }
}

# Age histogram (statistical, from the sample)
$ageBuckets = @('last30days','days30to365','years1to2','years2to5','years5to10','years10to15')
$agePct = [ordered]@{}
foreach ($b in $ageBuckets) {
    $agePct[$b] = [ordered]@{
        target = [double]$cfg.ageDistribution.$b
        actual = if ($sampleCount -gt 0) { [Math]::Round(100.0 * $ageCountsSample[$b] / $sampleCount, 2) } else { 0 }
    }
}

# Estimated terminated-owner count (from sample, projected)
$termOwnerEst = if ($sampleCount -gt 0) { [int][Math]::Round(($termOwnerSample / $sampleCount) * $totalOnDisk) } else { 0 }

# ---------------------------------------------------------------------------
# Emit report
# ---------------------------------------------------------------------------
$pass = ($folderMissing -eq 0 -and $missing -eq 0 -and $headerMismatch -eq 0 `
    -and $timestampInconsistent -eq 0 -and $ownerNull -eq 0 -and $noAcl -eq 0)

$report = [ordered]@{
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
    rootPath       = $rootPath
    folderRecords  = $folders.Count
    filesOnDisk    = $totalOnDisk
    scanElapsedSec = [Math]::Round($swScan.Elapsed.TotalSeconds, 2)
    checks = [ordered]@{
        folderExistence = [ordered]@{ missing = $folderMissing; totalChecked = $folderExpected }
        fileSample      = [ordered]@{
            size                   = $sampleCount
            missing                = $missing
            magicMismatch          = $headerMismatch
            magicHeadersChecked    = $headersChecked
            timestampInconsistent  = $timestampInconsistent
            ownerNull              = $ownerNull
        }
        aclSample       = [ordered]@{
            size          = $aclSample
            withoutAcl    = $noAcl
            avgAces       = [Math]::Round($totalAces / [Math]::Max(1, ($aclSample - $noAcl)), 2)
            withEveryone  = $withEveryone
            withAuthUsers = $withAuthUsers
        }
        distribution    = [ordered]@{
            fileTypePct               = $catPct
            unclassifiedFiles         = $unclassified
            ageBucketsPctSample       = $agePct
            terminatedOwnerEstimate   = $termOwnerEst
            terminatedOwnerInSample   = $termOwnerSample
        }
    }
    pass    = $pass
    logPath = $LogPath
}
$report | ConvertTo-Json -Depth 6 | Set-Content -Path $VerifyOut -Encoding utf8
Write-Log ("Verification {0}. Report: {1}" -f $(if ($pass) { 'PASS' } else { 'FAIL' }), $VerifyOut) $(if ($pass) { 'OK' } else { 'ERROR' })
$report | Format-List
if (-not $pass) { exit 2 }
