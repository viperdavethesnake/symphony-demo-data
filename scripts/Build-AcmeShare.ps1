#Requires -Version 7.0
<#
.SYNOPSIS
    One-shot streaming generator for the Acme demo share.

.DESCRIPTION
    Replaces the old Plan/Folders/Files/Timestamps/Owners pipeline (see
    docs/06-streaming-rewrite.md and D-029).

    Phase A (serial):
      * Load configs, ad-manifest.
      * Expand folder templates into a flat folder list.
      * Allocate target file counts per folder (largest-remainder).
      * Emit manifests/folder-manifest.json — still needed by Set-AcmeACLs.ps1.
      * Create every folder on disk (no file writes yet).
      * Precompute SharedCtx: ext metadata, owner pools, age-bucket ranges,
        per-affinity ext weights — all plain data passed into runspaces.

    Phase B (parallel via ForEach-Object -Parallel):
      * Folders are sorted by targetFileCount desc and round-robin assigned to
        N = parallelThreads chunks. Each runspace owns its chunk end-to-end.
      * Per-folder RNG: System.Random(hash(relPath) XOR masterSeed) — identical
        folder = identical files across runs.
      * Per file: sample ext/size/timestamps/owner/filename, create sparse file
        via P/Invoke, write header+marker, SetLength, set btime/mtime/atime,
        set owner SID via P/Invoke.
      * Version drift inlined: each created file has a chance to spawn 2..N
        siblings with staircased mtime.

    Dup pass (single-threaded after Phase B):
      * Stream disk with Get-ChildItem -Recurse -File, probabilistically
        sample source files, copy each to 2..5 random destination folders with
        rename variants. Owner sampled from destination folder's pool.

.PARAMETER ConfigPath
    Path to main-config(.dev).json.

.PARAMETER SkipFolderCreation
    Skip the Phase A mkdir pass (useful when re-running into an existing tree).

.PARAMETER MaxFiles
    Override scale.totalFiles for a quick smoke test without editing config.
    0 (default) = use config value.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ConfigPath,
    [switch]$SkipFolderCreation,
    [int]$MaxFiles = 0
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# ---------------------------------------------------------------------------
# Paths + logging
# ---------------------------------------------------------------------------
$RepoRoot    = Split-Path -Parent $PSScriptRoot
$ConfigDir   = Split-Path -Parent (Resolve-Path $ConfigPath)
$ManifestDir = Join-Path $RepoRoot 'manifests'
$LogDir      = Join-Path $ManifestDir 'logs'
if (-not (Test-Path $ManifestDir)) { New-Item -Path $ManifestDir -ItemType Directory | Out-Null }
if (-not (Test-Path $LogDir))      { New-Item -Path $LogDir      -ItemType Directory | Out-Null }

$RunStamp           = '{0:yyyyMMdd-HHmmss}' -f (Get-Date)
$LogPath            = Join-Path $LogDir ("share-$RunStamp.log")
$ChunkLogDir        = Join-Path $LogDir ("share-chunks-$RunStamp")
$FailuresPath       = Join-Path $LogDir 'failures.jsonl'
$SummaryPath        = Join-Path $LogDir 'share-summary.json'
$FolderManifestPath = Join-Path $ManifestDir 'folder-manifest.json'
New-Item -Path $ChunkLogDir -ItemType Directory -Force | Out-Null

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

function Convert-HexToBytes {
    param([string]$Hex)
    if ([string]::IsNullOrEmpty($Hex)) { return ,([byte[]]@()) }
    $n = [int]($Hex.Length / 2)
    $bytes = New-Object 'byte[]' $n
    for ($i = 0; $i -lt $n; $i++) {
        $bytes[$i] = [Convert]::ToByte($Hex.Substring($i*2, 2), 16)
    }
    return ,$bytes
}

# ---------------------------------------------------------------------------
# Load configs
# ---------------------------------------------------------------------------
Write-Log "Build-AcmeShare starting"
Write-Log "ConfigPath: $ConfigPath"

$cfg             = Import-JsonFile $ConfigPath
$filetypes       = Import-JsonFile (Join-Path $ConfigDir 'filetypes.json')
$folderTemplates = Import-JsonFile (Join-Path $ConfigDir 'folder-templates.json')
$tokenPool       = Import-JsonFile (Join-Path $ConfigDir 'token-pool.json')
$adManifest      = Import-JsonFile (Join-Path $ManifestDir 'ad-manifest.json')

$resolvedRoot = Resolve-RootPath $cfg.scale.rootPath
$totalFiles   = if ($MaxFiles -gt 0) { $MaxFiles } else { [int]$cfg.scale.totalFiles }
$masterSeed   = [int]$cfg.meta.seed
$throttle     = [int]$cfg.scale.parallelThreads

Write-Log "rootPath=$resolvedRoot  totalFiles=$totalFiles  threads=$throttle  seed=$masterSeed"

# ---------------------------------------------------------------------------
# Phase-A RNGs (no per-file sampling — that's per-folder inside Phase B)
# ---------------------------------------------------------------------------
function Get-PhaseSeed {
    param([string]$PhaseName)
    $hash = 0
    foreach ($ch in [char[]]$PhaseName) { $hash = ($hash * 31 + [int]$ch) -band 0x7FFFFFFF }
    return ($masterSeed -bxor $hash) -band 0x7FFFFFFF
}
$rngTree   = [System.Random]::new((Get-PhaseSeed 'tree'))
$rngAlloc  = [System.Random]::new((Get-PhaseSeed 'alloc'))
$rngDup    = [System.Random]::new((Get-PhaseSeed 'dup'))
$rngOwners = [System.Random]::new((Get-PhaseSeed 'owners'))

# ---------------------------------------------------------------------------
# Phase-A helpers: sampling primitives (used only single-threaded)
# ---------------------------------------------------------------------------
function Get-LogNormalSample {
    param(
        [Parameter(Mandatory)][System.Random]$Rng,
        [Parameter(Mandatory)][double]$P50,
        [Parameter(Mandatory)][double]$P95,
        [double]$Min = 0,
        [double]$Max = [double]::MaxValue
    )
    if ($P50 -le 0 -or $P95 -le $P50) { return [Math]::Max($Min, [Math]::Min($Max, $P50)) }
    $mu    = [Math]::Log($P50)
    $sigma = ([Math]::Log($P95) - $mu) / 1.6448536269514722
    $u1    = [Math]::Max($Rng.NextDouble(), 1e-12)
    $u2    = $Rng.NextDouble()
    $z     = [Math]::Sqrt(-2.0 * [Math]::Log($u1)) * [Math]::Cos(2.0 * [Math]::PI * $u2)
    $val   = [Math]::Exp($mu + $sigma * $z)
    if ($val -lt $Min) { return $Min }
    if ($val -gt $Max) { return $Max }
    return $val
}

function Get-WeightedIndex {
    param(
        [Parameter(Mandatory)][System.Random]$Rng,
        [Parameter(Mandatory)][double[]]$Weights
    )
    if ($Weights.Length -eq 0) { return -1 }
    $sum = 0.0; foreach ($w in $Weights) { $sum += $w }
    if ($sum -le 0) { return 0 }
    $r = $Rng.NextDouble() * $sum
    $acc = 0.0
    for ($i = 0; $i -lt $Weights.Length; $i++) {
        $acc += $Weights[$i]
        if ($r -le $acc) { return $i }
    }
    return $Weights.Length - 1
}

function Get-RandomPick {
    param([Parameter(Mandatory)][System.Random]$Rng, [Parameter(Mandatory)][object[]]$Items)
    if ($Items.Length -eq 0) { return $null }
    return $Items[$Rng.Next(0, $Items.Length)]
}

function Get-RandomSample {
    param(
        [Parameter(Mandatory)][System.Random]$Rng,
        [Parameter(Mandatory)][object[]]$Items,
        [Parameter(Mandatory)][int]$N
    )
    $n = [Math]::Min($N, $Items.Length)
    if ($n -le 0) { return ,@() }
    $copy = @($Items)
    for ($i = 0; $i -lt $n; $i++) {
        $j = $Rng.Next($i, $copy.Length)
        $tmp = $copy[$i]; $copy[$i] = $copy[$j]; $copy[$j] = $tmp
    }
    return ,($copy[0..($n-1)])
}

# ---------------------------------------------------------------------------
# Phase A.1 — folder template expansion (same logic as old Plan-AcmeData.ps1)
# ---------------------------------------------------------------------------
$MonthNames      = @('01-Jan','02-Feb','03-Mar','04-Apr','05-May','06-Jun',
                     '07-Jul','08-Aug','09-Sep','10-Oct','11-Nov','12-Dec')
$QuarterNames    = @('Q1','Q2','Q3','Q4')
$RevisionFolders = @('rev1','rev2','rev3','final','archive')
$VersionFolders  = @('v1.0','v1.1','v1.2','v2.0','v2.1')

function Expand-TemplateToken {
    param(
        [Parameter(Mandatory)][string]$Token,
        [Parameter(Mandatory)][int]$YearRangeStart,
        [Parameter(Mandatory)][int]$YearRangeEnd,
        [Parameter(Mandatory)][System.Random]$Rng
    )
    if ($Token -match '^yearRangeStart:(\d+),yearRangeEnd:(\d+)$') {
        $s = [int]$Matches[1]; $e = [int]$Matches[2]
        return @($s..$e | ForEach-Object { "FY$_" })
    }
    if ($Token -eq 'yearRange') { return @($YearRangeStart..$YearRangeEnd | ForEach-Object { "FY$_" }) }
    if ($Token -eq 'q')         { return $QuarterNames }
    if ($Token -eq 'month')     { return $MonthNames }
    if ($Token -eq 'rev')       { return $RevisionFolders }
    if ($Token -eq 'version')   { return $VersionFolders }
    if ($Token -match '^codewordList:(\d+)$') {
        $n = [int]$Matches[1]
        return (Get-RandomSample -Rng $Rng -Items $tokenPool.codewords -N $n)
    }
    if ($Token -match '^vendorList:(\d+)$') {
        $n = [int]$Matches[1]
        $vendors = $tokenPool.vendors | ForEach-Object { ($_ -replace '[^A-Za-z0-9]+','_') -replace '^_+|_+$','' }
        return (Get-RandomSample -Rng $Rng -Items $vendors -N $n)
    }
    if ($Token -match '^userList:(\d+)$') {
        $n = [int]$Matches[1]
        $activeSams = $adManifest.users | Where-Object { $_.status -eq 'active' } | ForEach-Object { $_.samAccountName }
        return (Get-RandomSample -Rng $Rng -Items @($activeSams) -N $n)
    }
    if ($Token -eq 'departmentList') { return @($cfg.folders.departmentShares) }
    if ($Token -match '^a-z:distributed$') { return @(65..90 | ForEach-Object { [char]$_ }) }
    if ($Token -match ',') { return @($Token -split ',' | ForEach-Object { $_.Trim() }) }
    return @($Token)
}

function Expand-StructureEntry {
    param(
        [Parameter(Mandatory)][string]$Entry,
        [Parameter(Mandatory)][int]$YearRangeStart,
        [Parameter(Mandatory)][int]$YearRangeEnd,
        [Parameter(Mandatory)][System.Random]$Rng
    )
    $segments = $Entry -split '/'
    $current = @('')
    foreach ($seg in $segments) {
        $next = @()
        if ($seg -match '^\{([^}]+)\}$') {
            $values = Expand-TemplateToken -Token $Matches[1] `
                                           -YearRangeStart $YearRangeStart `
                                           -YearRangeEnd $YearRangeEnd `
                                           -Rng $Rng
            foreach ($prev in $current) {
                foreach ($v in $values) {
                    $next += if ($prev -eq '') { "$v" } else { "$prev/$v" }
                }
            }
        } else {
            if ($seg -eq '') { $next = $current; continue }
            foreach ($prev in $current) {
                $next += if ($prev -eq '') { $seg } else { "$prev/$seg" }
            }
        }
        $current = $next
    }
    return ,$current
}

function New-FolderEntry {
    param(
        [string]$RelativePath,
        [string]$Department,
        [string[]]$ThemeTags,
        [string]$AgeBias,
        [string]$OwnerBias,
        [bool]$IsArchive = $false,
        [bool]$IsSensitive = $false
    )
    return [ordered]@{
        path            = (Join-Path $resolvedRoot $RelativePath.Replace('/', '\'))
        relPath         = $RelativePath
        department      = $Department
        themeTags       = $ThemeTags
        ageBias         = $AgeBias
        ownerBias       = $OwnerBias
        isArchive       = $IsArchive
        isSensitive     = $IsSensitive
        targetFileCount = 0
    }
}

Write-Log "Phase A.1 — expanding folder templates"
$yrStart = [int]$folderTemplates.defaults.yearRangeStart
$yrEnd   = [int]$folderTemplates.defaults.yearRangeEnd

$allFolders = [System.Collections.Generic.List[object]]::new()
$allFolders.Add((New-FolderEntry -RelativePath '' -Department '_root' -ThemeTags @() -AgeBias 'mixed' -OwnerBias 'all-staff'))

foreach ($deptName in $cfg.folders.departmentShares) {
    $tmpl = $folderTemplates.departments.$deptName
    if ($null -eq $tmpl) { Write-Log "No template for department $deptName — skipping" 'WARN'; continue }
    $root = "Departments/$deptName"
    $sensitiveFolders = @()
    if ($tmpl.PSObject.Properties['sensitiveFolders']) { $sensitiveFolders = @($tmpl.sensitiveFolders) }
    $allFolders.Add((New-FolderEntry -RelativePath $root -Department $deptName `
                                     -ThemeTags @() -AgeBias $tmpl.ageBias -OwnerBias $tmpl.ownerBias))
    foreach ($entry in $tmpl.structure) {
        $topLevel       = ($entry -split '/')[0]
        $isArchiveTree  = $topLevel -match '^Archive'
        $isSensitive    = $sensitiveFolders -contains $topLevel
        $ageBias        = if ($isArchiveTree) {
            if ($tmpl.PSObject.Properties['archiveFolderAgeBias']) { $tmpl.archiveFolderAgeBias } else { 'very-old' }
        } else { $tmpl.ageBias }
        $themeTags = @($topLevel)
        if ($isSensitive)   { $themeTags += 'sensitive' }
        if ($isArchiveTree) { $themeTags += 'archive' }

        $expanded = Expand-StructureEntry -Entry $entry -YearRangeStart $yrStart -YearRangeEnd $yrEnd -Rng $rngTree
        foreach ($relSub in $expanded) {
            $full = "$root/$relSub"
            $allFolders.Add((New-FolderEntry -RelativePath $full -Department $deptName `
                                             -ThemeTags $themeTags -AgeBias $ageBias `
                                             -OwnerBias $tmpl.ownerBias `
                                             -IsArchive:$isArchiveTree -IsSensitive:$isSensitive))
        }
    }
}

foreach ($sharedName in $cfg.folders.commonShares) {
    $tmpl = $folderTemplates.shared.$sharedName
    if ($null -eq $tmpl) { Write-Log "No template for Shared/$sharedName — skipping" 'WARN'; continue }
    $root = "Shared/$sharedName"
    $allFolders.Add((New-FolderEntry -RelativePath $root -Department 'Shared' `
                                     -ThemeTags @($sharedName) -AgeBias $tmpl.ageBias -OwnerBias $tmpl.ownerBias))
    foreach ($entry in $tmpl.structure) {
        $topLevel      = ($entry -split '/')[0]
        $isArchiveTree = ($sharedName -eq 'Archive') -or ($topLevel -match '^Archive')
        $ageBias       = if ($isArchiveTree) { 'very-old' } else { $tmpl.ageBias }
        $themeTags = @($sharedName, $topLevel)
        if ($isArchiveTree) { $themeTags += 'archive' }
        $expanded = Expand-StructureEntry -Entry $entry -YearRangeStart $yrStart -YearRangeEnd $yrEnd -Rng $rngTree
        foreach ($relSub in $expanded) {
            $full = "$root/$relSub"
            $allFolders.Add((New-FolderEntry -RelativePath $full -Department 'Shared' `
                                             -ThemeTags $themeTags -AgeBias $ageBias `
                                             -OwnerBias $tmpl.ownerBias -IsArchive:$isArchiveTree))
        }
    }
}

# Intermediate ancestors — every leaf's parent chain must exist as a folder record.
$existing = @{}
foreach ($f in $allFolders) { $existing[$f.relPath] = $true }
$intermediates = [System.Collections.Generic.List[object]]::new()
foreach ($f in $allFolders) {
    if ($f.relPath -eq '') { continue }
    $parts = $f.relPath -split '/'
    $accum = ''
    for ($i = 0; $i -lt $parts.Length - 1; $i++) {
        $accum = if ($accum -eq '') { $parts[$i] } else { "$accum/$($parts[$i])" }
        if (-not $existing.ContainsKey($accum)) {
            $existing[$accum] = $true
            $intermediates.Add((New-FolderEntry -RelativePath $accum -Department $f.department `
                                                -ThemeTags $f.themeTags -AgeBias $f.ageBias `
                                                -OwnerBias $f.ownerBias `
                                                -IsArchive:$f.isArchive -IsSensitive:$f.isSensitive))
        }
    }
}
foreach ($f in $intermediates) { $allFolders.Add($f) }

# Deep-folder rabbit holes
$deepPct = [double]$cfg.folders.deepFolderPercent
$deepMax = [int]$cfg.folders.deepFolderMaxDepth
if ($deepPct -gt 0) {
    $leafCandidates = @($allFolders | Where-Object { -not $_.isArchive -and $_.relPath -ne '' })
    $deepCount = [int]([Math]::Ceiling($leafCandidates.Length * ($deepPct / 100.0)))
    $chosen = Get-RandomSample -Rng $rngTree -Items $leafCandidates -N $deepCount
    foreach ($f in $chosen) {
        $currentDepth = ($f.relPath -split '/').Length
        $extra = $rngTree.Next(2, [Math]::Max(2, ($deepMax - $currentDepth) + 1))
        $subPath = $f.relPath
        for ($d = 0; $d -lt $extra; $d++) {
            $tag = (Get-RandomPick -Rng $rngTree -Items @($tokenPool.codewords))
            $subPath = "$subPath/$tag"
            if (-not $existing.ContainsKey($subPath)) {
                $existing[$subPath] = $true
                $allFolders.Add((New-FolderEntry -RelativePath $subPath -Department $f.department `
                                                 -ThemeTags ($f.themeTags + 'deep') -AgeBias $f.ageBias `
                                                 -OwnerBias $f.ownerBias))
            }
        }
    }
    Write-Log "Added deep-folder rabbit holes from $($chosen.Count) leaves"
}
Write-Log ("Folder tree: {0} entries" -f $allFolders.Count) 'OK'

# ---------------------------------------------------------------------------
# Phase A.2 — file-count allocation (largest-remainder)
# ---------------------------------------------------------------------------
Write-Log "Phase A.2 — allocating file counts"
$defaults      = $folderTemplates.defaults
$p50           = [double]$defaults.filesPerFolderP50
$p95           = [double]$defaults.filesPerFolderP95
$maxPerFolder  = [double]$defaults.filesPerFolderMax

$weights = New-Object 'double[]' $allFolders.Count
for ($i = 0; $i -lt $allFolders.Count; $i++) {
    $f = $allFolders[$i]
    if ($f.relPath -eq '') { $weights[$i] = 0; continue }
    $w = Get-LogNormalSample -Rng $rngAlloc -P50 $p50 -P95 $p95 -Min 1 -Max $maxPerFolder
    if ($f.isArchive)                 { $w *= 1.3 }
    if ($f.themeTags -contains 'deep'){ $w *= 0.25 }
    $weights[$i] = $w
}

$sumW = 0.0; foreach ($w in $weights) { $sumW += $w }
$counts = New-Object 'int[]' $allFolders.Count
$residuals = New-Object 'double[]' $allFolders.Count
$assigned = 0
for ($i = 0; $i -lt $weights.Length; $i++) {
    $share = ($weights[$i] / $sumW) * $totalFiles
    $c = [int][Math]::Floor($share)
    $counts[$i] = $c; $residuals[$i] = $share - $c; $assigned += $c
}
$remaining = $totalFiles - $assigned
if ($remaining -gt 0) {
    $idxOrdered = @(0..($residuals.Length - 1) | Sort-Object { -$residuals[$_] })
    for ($k = 0; $k -lt $remaining; $k++) { $counts[$idxOrdered[$k % $idxOrdered.Length]]++ }
}
for ($i = 0; $i -lt $allFolders.Count; $i++) { $allFolders[$i].targetFileCount = $counts[$i] }
$nonEmpty = ($counts | Where-Object { $_ -gt 0 }).Count
Write-Log "Allocation: $totalFiles files across $nonEmpty non-empty folders (of $($allFolders.Count) total)" 'OK'

# ---------------------------------------------------------------------------
# Phase A.3 — time anchor + owner pools + extension catalog precompute
# ---------------------------------------------------------------------------
if ($adManifest.meta.PSObject.Properties['generatedAtUtc']) {
    $nowUtc = ([datetime]$adManifest.meta.generatedAtUtc).ToUniversalTime()
    Write-Log "Time anchor: ad-manifest.generatedAtUtc = $($nowUtc.ToString('o'))"
} else {
    $nowUtc = (Get-Date).ToUniversalTime()
    Write-Log "Time anchor: wall-clock (ad-manifest missing generatedAtUtc)" 'WARN'
}

$AgeBuckets = @('last30days','days30to365','years1to2','years2to5','years5to10','years10to15')
$AgeBucketRanges = @{
    last30days    = @($nowUtc.AddDays(-30),  $nowUtc)
    days30to365   = @($nowUtc.AddDays(-365), $nowUtc.AddDays(-30))
    years1to2     = @($nowUtc.AddYears(-2),  $nowUtc.AddYears(-1))
    years2to5     = @($nowUtc.AddYears(-5),  $nowUtc.AddYears(-2))
    years5to10    = @($nowUtc.AddYears(-10), $nowUtc.AddYears(-5))
    years10to15   = @($nowUtc.AddYears(-15), $nowUtc.AddYears(-10))
}

$AgeWeightCache = @{}
foreach ($bias in @('mixed','recent-leaning','old-leaning','very-old','old')) {
    $base = @{}
    foreach ($b in $AgeBuckets) { $base[$b] = [double]$cfg.ageDistribution.$b }
    switch ($bias) {
        'recent-leaning' { $base['last30days']*=2.0; $base['days30to365']*=2.0; $base['years1to2']*=2.0; $base['years10to15']*=0.3 }
        'old-leaning'    { $base['years5to10']*=2.0; $base['years10to15']*=2.0; $base['last30days']*=0.5; $base['days30to365']*=0.5 }
        'very-old'       { $base['years10to15']*=4.0; $base['years5to10']*=2.5; $base['last30days']*=0.1; $base['days30to365']*=0.1 }
        'old'            { $base['years5to10']*=2.5; $base['years10to15']*=3.0; $base['last30days']*=0.3; $base['days30to365']*=0.3 }
        default          { }
    }
    $arr = New-Object 'double[]' $AgeBuckets.Length
    $sum = 0.0
    for ($i = 0; $i -lt $AgeBuckets.Length; $i++) { $arr[$i] = $base[$AgeBuckets[$i]]; $sum += $arr[$i] }
    $AgeWeightCache[$bias] = @{ Weights = $arr; SumW = $sum }
}

# Owner pools: precompute one ordered (Sids[], Weights[], SumW) per bias-or-"bias::dept" key.
$usersAll = @($adManifest.users)
$usersByStatus = @{
    active     = @($usersAll | Where-Object { $_.status -eq 'active' })
    disabled   = @($usersAll | Where-Object { $_.status -eq 'disabled' })
    terminated = @($usersAll | Where-Object { $_.status -eq 'terminated' })
    service    = @($usersAll | Where-Object { $_.status -eq 'service' })
}
$usersByDept = @{}
foreach ($u in ($usersByStatus.active | Sort-Object samAccountName)) {
    if (-not $usersByDept.ContainsKey($u.department)) { $usersByDept[$u.department] = [System.Collections.Generic.List[object]]::new() }
    $usersByDept[$u.department].Add($u)
}
$hoarderPct = [int]$cfg.spaceSkew.hoarderUserPercent
$activeSorted = @($usersByStatus.active | Sort-Object {
    $h = 0
    foreach ($ch in [char[]]"$($_.sid)-hoarder") { $h = ($h * 31 + [int]$ch) -band 0x7FFFFFFF }
    $h
})
$hoarderCount = [int]([Math]::Ceiling($activeSorted.Count * ($hoarderPct / 100.0)))
$hoarders = @($activeSorted[0..([Math]::Max(0, $hoarderCount - 1))])
Write-Log "Active users: $($usersByStatus.active.Count)  hoarders: $($hoarders.Count)  service: $($usersByStatus.service.Count)  terminated: $($usersByStatus.terminated.Count)"

function Build-OwnerPool {
    param([string]$Bias, [string]$Department = '')
    $sids    = [System.Collections.Generic.List[string]]::new()
    $weights = [System.Collections.Generic.List[double]]::new()
    $addSet = {
        param([object[]]$Set, [double]$W)
        foreach ($u in $Set) { $sids.Add($u.sid); $weights.Add($W) }
    }
    switch ($Bias) {
        'department' {
            $deptUsers = if ($Department -and $usersByDept.ContainsKey($Department)) { @($usersByDept[$Department]) } else { @($usersByStatus.active) }
            & $addSet $deptUsers 8.0
            & $addSet $usersByStatus.service 1.5
            & $addSet $hoarders 2.0
            & $addSet $usersByStatus.terminated 0.4
        }
        'executives-only' {
            $execs = if ($usersByDept.ContainsKey('Executive')) { @($usersByDept['Executive']) } else { @() }
            & $addSet $execs 9.0
            & $addSet $usersByStatus.service 1.0
        }
        'it-admins-and-service-accounts' {
            $it = if ($usersByDept.ContainsKey('IT')) { @($usersByDept['IT']) } else { @() }
            & $addSet $it 5.0
            & $addSet $usersByStatus.service 5.0
        }
        'all-staff'                 { & $addSet $usersByStatus.active 1.0 }
        'mixed'                     { & $addSet $usersByStatus.active 7.0; & $addSet $usersByStatus.disabled 1.5; & $addSet $usersByStatus.terminated 1.0; & $addSet $usersByStatus.service 0.5 }
        'mixed-including-terminated'{ & $addSet $usersByStatus.active 4.0; & $addSet $usersByStatus.disabled 2.0; & $addSet $usersByStatus.terminated 4.0 }
        'cross-department' {
            $deptNames = @($usersByDept.Keys)
            $picked = Get-RandomSample -Rng $rngOwners -Items $deptNames -N ([Math]::Min(3, $deptNames.Length))
            foreach ($d in $picked) { & $addSet @($usersByDept[$d]) 5.0 }
            & $addSet $usersByStatus.service 0.5
        }
        default { & $addSet $usersByStatus.active 1.0 }
    }
    $sumW = 0.0; foreach ($w in $weights) { $sumW += $w }
    return @{ Sids = [string[]]@($sids); Weights = [double[]]@($weights); SumW = $sumW }
}

$OwnerPoolCache = @{}
foreach ($deptName in $cfg.folders.departmentShares) {
    $OwnerPoolCache["department::$deptName"] = Build-OwnerPool -Bias 'department' -Department $deptName
}
foreach ($bias in @('executives-only','it-admins-and-service-accounts','all-staff','mixed','mixed-including-terminated','cross-department')) {
    $OwnerPoolCache["$bias::"] = Build-OwnerPool -Bias $bias
}
$OwnerPoolCache['_fallback::'] = Build-OwnerPool -Bias 'mixed'
Write-Log "Owner pools: $($OwnerPoolCache.Keys.Count) precomputed"

# Extension catalog + per-affinity-key per-category weight tables
$ExtMeta     = @{}
$CategoryList = @($cfg.fileTypeMix.PSObject.Properties | Where-Object { -not $_.Name.StartsWith('$') } | ForEach-Object { $_.Name })
$CategoryBaseWeights = New-Object 'double[]' $CategoryList.Length
$CategoryBaseSum = 0.0
for ($i = 0; $i -lt $CategoryList.Length; $i++) {
    $CategoryBaseWeights[$i] = [double]$cfg.fileTypeMix.$($CategoryList[$i])
    $CategoryBaseSum += $CategoryBaseWeights[$i]
}
$CategoryExts = @{}
foreach ($catName in $CategoryList) {
    $catNode = $filetypes.$catName
    if ($null -eq $catNode) { continue }
    $list = [System.Collections.Generic.List[string]]::new()
    foreach ($extProp in $catNode.PSObject.Properties) {
        if ($extProp.Name.StartsWith('$')) { continue }
        $ext = $extProp.Name
        $e   = $extProp.Value
        $headerHex = if ($e.PSObject.Properties['header']) { [string]$e.header } else { '' }
        $markerHex = if ($e.PSObject.Properties['marker']) { [string]$e.marker } else { '' }
        $markerOff = if ($e.PSObject.Properties['markerOffset']) { [int64]$e.markerOffset } else { [int64]0 }
        $sd = $e.sizeDistribution
        $ExtMeta[$ext] = @{
            HeaderBytes      = (Convert-HexToBytes $headerHex)
            MarkerBytes      = (Convert-HexToBytes $markerHex)
            MarkerOffset     = $markerOff
            P50              = [double]$sd.p50Bytes
            P95              = [double]$sd.p95Bytes
            MinSize          = [int64]$sd.minBytes
            MaxSize          = [int64]$sd.maxBytes
            FilenamePatterns = @($e.filenamePatterns)
            Category         = $catName
        }
        $list.Add($ext)
    }
    $CategoryExts[$catName] = $list
}
Write-Log "Extension catalog: $($ExtMeta.Keys.Count) extensions, $($CategoryList.Length) categories"

# Per-affinity-key × per-category ext weight tables.
# Key format: "dept:<name>" | "shared:<bucket>" | "_default"
function Get-AffinityMap {
    param([string]$Key)
    if ($Key -like 'dept:*') {
        $dept = $Key.Substring(5)
        $tmpl = $folderTemplates.departments.$dept
        if ($tmpl -and $tmpl.PSObject.Properties['affinityMultipliers']) { return $tmpl.affinityMultipliers }
    } elseif ($Key -like 'shared:*') {
        $bucket = $Key.Substring(7)
        $tmpl = $folderTemplates.shared.$bucket
        if ($tmpl -and $tmpl.PSObject.Properties['affinityMultipliers']) { return $tmpl.affinityMultipliers }
    }
    return $null
}

$AffinityKeys = New-Object 'System.Collections.Generic.HashSet[string]'
[void]$AffinityKeys.Add('_default')
foreach ($d in $cfg.folders.departmentShares) { [void]$AffinityKeys.Add("dept:$d") }
foreach ($s in $cfg.folders.commonShares)     { [void]$AffinityKeys.Add("shared:$s") }

$ExtByAffinity = @{}
foreach ($key in $AffinityKeys) {
    $aff = Get-AffinityMap -Key $key
    $byCat = @{}
    foreach ($cat in $CategoryList) {
        $names = @($CategoryExts[$cat])
        $ws    = New-Object 'double[]' $names.Count
        $sum   = 0.0
        for ($i = 0; $i -lt $names.Count; $i++) {
            $mult = 1.0
            if ($aff -and $aff.PSObject.Properties[$names[$i]]) { $mult = [double]$aff.$($names[$i]) }
            $ws[$i] = $mult; $sum += $mult
        }
        $byCat[$cat] = @{ Names = [string[]]@($names); Weights = $ws; SumW = $sum }
    }
    $ExtByAffinity[$key] = $byCat
}
Write-Log "Affinity tables: $($ExtByAffinity.Keys.Count) keys × $($CategoryList.Length) categories"

function Resolve-AffinityKey {
    param([object]$Folder)
    if ($Folder.department -eq 'Shared') {
        $parts = $Folder.relPath -split '/'
        if ($parts.Length -ge 2) {
            $bucket = $parts[1]
            if ($AffinityKeys.Contains("shared:$bucket")) { return "shared:$bucket" }
        }
        return '_default'
    }
    if ($Folder.department -and $AffinityKeys.Contains("dept:$($Folder.department)")) {
        return "dept:$($Folder.department)"
    }
    return '_default'
}

# Stamp resolved affinity key + owner pool key onto each folder. Folders are
# OrderedDictionaries — use indexer (Add-Member would attach a PSObject prop
# that wouldn't serialize via ConvertTo-Json).
foreach ($f in $allFolders) {
    $f['affinityKey'] = (Resolve-AffinityKey -Folder $f)
    $ownerKey = if ($f.ownerBias -eq 'department') { "department::$($f.department)" } else { "$($f.ownerBias)::" }
    if (-not $OwnerPoolCache.ContainsKey($ownerKey)) { $ownerKey = '_fallback::' }
    $f['ownerKey'] = $ownerKey
}

# ---------------------------------------------------------------------------
# Phase A.4 — emit folder-manifest.json (Set-AcmeACLs reads this)
# ---------------------------------------------------------------------------
Write-Log "Phase A.4 — writing folder-manifest.json"
$folderOut = [ordered]@{
    meta = [ordered]@{
        generatedAtUtc    = (Get-Date).ToUniversalTime().ToString('o')
        timeAnchorUtc     = $nowUtc.ToString('o')
        configPath        = (Resolve-Path $ConfigPath).Path
        seed              = $masterSeed
        rootPath          = $resolvedRoot
        folderCount       = $allFolders.Count
        totalFilesPlanned = $totalFiles
    }
    folders = @($allFolders)
}
$folderOut | ConvertTo-Json -Depth 10 | Set-Content -Path $FolderManifestPath -Encoding utf8
Write-Log "folder-manifest.json: $($allFolders.Count) folders" 'OK'

# ---------------------------------------------------------------------------
# Phase A.5 — create folders on disk (serial, safe, no races)
# ---------------------------------------------------------------------------
if (-not (Test-Path $resolvedRoot)) {
    Write-Log "Creating root: $resolvedRoot"
    New-Item -Path $resolvedRoot -ItemType Directory -Force | Out-Null
}

if ($SkipFolderCreation) {
    Write-Log "Phase A.5 — SKIP (SkipFolderCreation)"
} else {
    Write-Log "Phase A.5 — creating folders on disk"
    $swFolders = [System.Diagnostics.Stopwatch]::StartNew()
    $created = 0; $existed = 0; $failed = 0
    $total = $allFolders.Count
    $reportEvery = [Math]::Max(1, [int]($total / 20))
    $i = 0
    foreach ($f in $allFolders) {
        $i++
        if ($f.relPath -eq '') { continue }
        try {
            if (Test-Path -LiteralPath $f.path -PathType Container) { $existed++ }
            else { New-Item -Path $f.path -ItemType Directory -Force -ErrorAction Stop | Out-Null; $created++ }
        } catch {
            $failed++
            Write-Log ("Folder create failed: {0} :: {1}" -f $f.path, $_.Exception.Message) 'ERROR'
        }
        if (($i % $reportEvery) -eq 0) {
            Write-Progress -Activity 'Creating folders' -Status "$i / $total" -PercentComplete (($i / $total) * 100)
        }
    }
    Write-Progress -Activity 'Creating folders' -Completed
    $swFolders.Stop()
    Write-Log ("Folders: created={0} existed={1} failed={2} in {3:N1}s" -f $created, $existed, $failed, $swFolders.Elapsed.TotalSeconds) 'OK'
    if ($failed -gt 0) { throw "Folder creation had $failed failures — aborting before file writes" }
}

# ---------------------------------------------------------------------------
# Phase A.6 — load P/Invoke types (once, inherited by runspaces)
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
        public static void SetSparse(SafeFileHandle handle) {
            uint bytesReturned = 0;
            bool ok = DeviceIoControl(handle.DangerousGetHandle(), 0x900C4,
                IntPtr.Zero, 0, IntPtr.Zero, 0, out bytesReturned, IntPtr.Zero);
            if (!ok) {
                throw new System.ComponentModel.Win32Exception(
                    Marshal.GetLastWin32Error(), "FSCTL_SET_SPARSE failed");
            }
        }
    }
}
'@
}
if (-not ('Acme.NativeOwner' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace Acme {
    public static class NativeOwner {
        private const uint SE_FILE_OBJECT = 1;
        private const uint OWNER_SECURITY_INFORMATION = 0x00000001;
        [DllImport("advapi32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
        private static extern uint SetNamedSecurityInfo(
            string pObjectName, uint objectType, uint securityInfo,
            IntPtr psidOwner, IntPtr psidGroup, IntPtr pDacl, IntPtr pSacl);
        [DllImport("advapi32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
        private static extern bool ConvertStringSidToSid(string stringSid, out IntPtr psid);
        [DllImport("kernel32.dll")]
        private static extern IntPtr LocalFree(IntPtr hMem);
        public static void SetOwner(string path, string sid) {
            IntPtr psid;
            if (!ConvertStringSidToSid(sid, out psid))
                throw new System.ComponentModel.Win32Exception(
                    Marshal.GetLastWin32Error(), "ConvertStringSidToSid failed for " + sid);
            try {
                uint rc = SetNamedSecurityInfo(path, SE_FILE_OBJECT, OWNER_SECURITY_INFORMATION,
                    psid, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
                if (rc != 0)
                    throw new System.ComponentModel.Win32Exception((int)rc,
                        "SetNamedSecurityInfo failed rc=" + rc + " for " + path);
            } finally {
                LocalFree(psid);
            }
        }
    }
}
'@
}
if (-not ('Acme.PrivilegeHelper' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace Acme {
    public static class PrivilegeHelper {
        [DllImport("advapi32.dll", SetLastError=true)]
        private static extern bool OpenProcessToken(IntPtr h, uint desired, out IntPtr token);
        [DllImport("advapi32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
        private static extern bool LookupPrivilegeValue(string system, string name, out LUID luid);
        [DllImport("advapi32.dll", SetLastError=true)]
        private static extern bool AdjustTokenPrivileges(IntPtr token, bool disableAll,
            ref TOKEN_PRIVILEGES newState, uint bufLen, IntPtr prevState, IntPtr returnLen);
        [DllImport("kernel32.dll")] private static extern IntPtr GetCurrentProcess();
        [StructLayout(LayoutKind.Sequential)] public struct LUID { public uint Low; public int High; }
        [StructLayout(LayoutKind.Sequential)] public struct TOKEN_PRIVILEGES {
            public uint PrivilegeCount; public LUID Luid; public uint Attributes;
        }
        public static void Enable(string privilege) {
            IntPtr token;
            if (!OpenProcessToken(GetCurrentProcess(), 0x28, out token))
                throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
            LUID luid;
            if (!LookupPrivilegeValue(null, privilege, out luid))
                throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
            TOKEN_PRIVILEGES tp;
            tp.PrivilegeCount = 1; tp.Luid = luid; tp.Attributes = 0x00000002;
            if (!AdjustTokenPrivileges(token, false, ref tp, 0, IntPtr.Zero, IntPtr.Zero))
                throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
        }
    }
}
'@
}
try { [Acme.PrivilegeHelper]::Enable('SeRestorePrivilege') } catch { Write-Log "SeRestorePrivilege enable failed (parent): $($_.Exception.Message)" 'WARN' }
try { [Acme.PrivilegeHelper]::Enable('SeTakeOwnershipPrivilege') } catch { }
Write-Log "P/Invoke types loaded in parent"

# ---------------------------------------------------------------------------
# Phase A.7 — chunk folders for parallel workers (round-robin by work size)
# ---------------------------------------------------------------------------
$nonEmptyFolders = @($allFolders | Where-Object { $_.targetFileCount -gt 0 })
$sortedFolders   = @($nonEmptyFolders | Sort-Object -Property targetFileCount -Descending)
$chunks = @()
for ($i = 0; $i -lt $throttle; $i++) { $chunks += ,([System.Collections.Generic.List[object]]::new()) }
for ($i = 0; $i -lt $sortedFolders.Length; $i++) { $chunks[$i % $throttle].Add($sortedFolders[$i]) }

$chunkObjs = @()
for ($i = 0; $i -lt $throttle; $i++) {
    $sum = 0
    foreach ($cf in $chunks[$i]) { $sum += [int]$cf.targetFileCount }
    $chunkObjs += [pscustomobject]@{
        Id      = $i + 1
        Folders = @($chunks[$i])
        Target  = $sum
    }
}
$targetMin = ($chunkObjs | Measure-Object Target -Minimum).Minimum
$targetMax = ($chunkObjs | Measure-Object Target -Maximum).Maximum
Write-Log "Chunks: $($chunkObjs.Count) (target files per chunk: min=$([int]$targetMin) max=$([int]$targetMax))"

# ---------------------------------------------------------------------------
# Build SharedCtx to ship into runspaces
# ---------------------------------------------------------------------------
$SharedCtx = @{
    ExtMeta             = $ExtMeta
    CategoryList        = $CategoryList
    CategoryBaseWeights = $CategoryBaseWeights
    CategoryBaseSum     = $CategoryBaseSum
    ExtByAffinity       = $ExtByAffinity
    AgeBuckets          = $AgeBuckets
    AgeBucketRanges     = $AgeBucketRanges
    AgeWeightCache      = $AgeWeightCache
    OwnerPoolCache      = $OwnerPoolCache
    TokenCodewords      = @($tokenPool.codewords)
    TokenRevisions      = @($tokenPool.revisions)
    TokenMonthsShort    = @($tokenPool.monthsShort)
    QuarterNames        = $QuarterNames
    AtimeBumpPct        = [double]$cfg.timeConsistency.atimeRecentlyTouchedPercent
    DriftTrigger        = [double]$cfg.duplicates.versionDriftPercent / 100.0
    DriftMin            = [int]$cfg.duplicates.versionDriftClusterSizeMin
    DriftMax            = [int]$cfg.duplicates.versionDriftClusterSizeMax
    NowUtc              = $nowUtc
    MasterSeed          = $masterSeed
    ChunkLogDir         = $ChunkLogDir
}

# ---------------------------------------------------------------------------
# Phase B — parallel file creation
# ---------------------------------------------------------------------------
Write-Log "Phase B — parallel file creation (throttle=$throttle)"
$swPhaseB = [System.Diagnostics.Stopwatch]::StartNew()

$results = $chunkObjs | ForEach-Object -ThrottleLimit $throttle -Parallel {
    $chunk = $_
    $ctx   = $using:SharedCtx
    $ErrorActionPreference = 'Stop'

    # P/Invoke safety net: types already loaded in parent AppDomain, but guard
    # in case a runspace lands on a fresh process.
    if (-not ('Acme.NativeFsctl' -as [type]) -or -not ('Acme.NativeOwner' -as [type])) {
        throw "P/Invoke types missing in runspace — parent load failed"
    }
    try { [Acme.PrivilegeHelper]::Enable('SeRestorePrivilege') } catch { }
    try { [Acme.PrivilegeHelper]::Enable('SeTakeOwnershipPrivilege') } catch { }

    $chunkLog   = Join-Path $ctx.ChunkLogDir ("chunk-{0:D5}.log" -f $chunk.Id)
    $chunkFails = Join-Path $ctx.ChunkLogDir ("chunk-{0:D5}-failures.jsonl" -f $chunk.Id)
    $logSw  = [System.IO.StreamWriter]::new($chunkLog, $false, [System.Text.UTF8Encoding]::new($false))
    $failSw = $null

    $filesCreated = 0
    $bytesLogical = [int64]0
    $failed       = 0
    $swChunk = [System.Diagnostics.Stopwatch]::StartNew()

    # -----------------------------------------------------------------------
    # Local sampling helpers (inline — no cross-runspace function calls)
    # -----------------------------------------------------------------------
    $sampleWeighted = {
        param([System.Random]$rng, [double[]]$weights, [double]$sum)
        if ($sum -le 0) { return 0 }
        $r = $rng.NextDouble() * $sum
        $acc = 0.0
        for ($i = 0; $i -lt $weights.Length; $i++) {
            $acc += $weights[$i]
            if ($r -le $acc) { return $i }
        }
        return $weights.Length - 1
    }

    $sampleLogNormal = {
        param([System.Random]$rng, [double]$p50, [double]$p95, [double]$min, [double]$max)
        if ($p50 -le 0 -or $p95 -le $p50) { return [Math]::Max($min, [Math]::Min($max, $p50)) }
        $mu = [Math]::Log($p50)
        $sigma = ([Math]::Log($p95) - $mu) / 1.6448536269514722
        $u1 = [Math]::Max($rng.NextDouble(), 1e-12)
        $u2 = $rng.NextDouble()
        $z  = [Math]::Sqrt(-2.0 * [Math]::Log($u1)) * [Math]::Cos(2.0 * [Math]::PI * $u2)
        $val = [Math]::Exp($mu + $sigma * $z)
        if ($val -lt $min) { return $min }
        if ($val -gt $max) { return $max }
        return $val
    }

    $monthsShort = $ctx.TokenMonthsShort
    $quarters    = $ctx.QuarterNames
    $codewords   = $ctx.TokenCodewords
    $revisions   = $ctx.TokenRevisions

    $renderFilename = {
        param([string]$pattern, [System.Random]$rng, [datetime]$btime)
        $out = $pattern
        $out = [regex]::Replace($out, '\{([^}]+)\}', {
            param($m)
            $tok = $m.Groups[1].Value
            if ($tok -match '^n(\d+)$') {
                $digits = [int]$Matches[1]
                $max = [int][Math]::Pow(10, [Math]::Min($digits, 9))
                return ('{0:D' + $digits + '}') -f ($rng.Next(0, $max))
            }
            switch ($tok) {
                'date'     { $d = $btime.AddDays($rng.Next(-30, 30));
                             if ($rng.NextDouble() -lt 0.5) { return $d.ToString('yyyyMMdd') } else { return $d.ToString('yyyy-MM-dd') } }
                'year'     { return $btime.Year.ToString() }
                'q'        { return $quarters[$rng.Next(0, $quarters.Length)] }
                'month'    { if ($rng.NextDouble() -lt 0.5) { return ('{0:D2}' -f $btime.Month) } else { return $monthsShort[$btime.Month - 1] } }
                'codeword' { return $codewords[$rng.Next(0, $codewords.Length)] }
                'rev'      { return $revisions[$rng.Next(0, $revisions.Length)] }
                default    { return $m.Value }
            }
        })
        return $out
    }

    try {
        foreach ($folder in $chunk.Folders) {
            # Per-folder seeded RNG
            $h = 0
            foreach ($ch in [char[]]$folder.relPath) { $h = ($h * 31 + [int]$ch) -band 0x7FFFFFFF }
            $seed = ($h -bxor $ctx.MasterSeed) -band 0x7FFFFFFF
            $rng  = [System.Random]::new($seed)

            $affinity = $ctx.ExtByAffinity[$folder.affinityKey]
            if (-not $affinity) { $affinity = $ctx.ExtByAffinity['_default'] }

            $ageBiasKey = if ($ctx.AgeWeightCache.ContainsKey($folder.ageBias)) { $folder.ageBias } else { 'mixed' }
            $ageEntry   = $ctx.AgeWeightCache[$ageBiasKey]

            $pool = $ctx.OwnerPoolCache[$folder.ownerKey]
            if (-not $pool) { $pool = $ctx.OwnerPoolCache['_fallback::'] }

            $target = [int]$folder.targetFileCount
            for ($k = 0; $k -lt $target; $k++) {
                try {
                    # --- category + extension ---
                    $catIdx = & $sampleWeighted $rng $ctx.CategoryBaseWeights $ctx.CategoryBaseSum
                    $cat    = $ctx.CategoryList[$catIdx]
                    $ec     = $affinity[$cat]
                    if (-not $ec -or $ec.Names.Length -eq 0) {
                        $ec = $ctx.ExtByAffinity['_default'][$cat]
                    }
                    $extIdx = & $sampleWeighted $rng $ec.Weights $ec.SumW
                    $ext    = $ec.Names[$extIdx]
                    $extMeta = $ctx.ExtMeta[$ext]

                    # --- size ---
                    $size = [int64](& $sampleLogNormal $rng $extMeta.P50 $extMeta.P95 ([double]$extMeta.MinSize) ([double]$extMeta.MaxSize))

                    # --- age bucket + timestamps ---
                    $bucketIdx = & $sampleWeighted $rng $ageEntry.Weights $ageEntry.SumW
                    $bucket    = $ctx.AgeBuckets[$bucketIdx]
                    $range     = $ctx.AgeBucketRanges[$bucket]
                    $bucketStart = $range[0]; $bucketEnd = $range[1]
                    $spanSec = ($bucketEnd - $bucketStart).TotalSeconds
                    $btime = $bucketStart.AddSeconds($rng.NextDouble() * $spanSec)
                    $mtimeMaxSec = ($ctx.NowUtc - $btime).TotalSeconds
                    if ($mtimeMaxSec -le 0) { $mtime = $btime }
                    else {
                        if ($rng.NextDouble() -lt 0.7) { $delta = $rng.NextDouble() * [Math]::Min(86400.0, $mtimeMaxSec) }
                        else { $delta = $rng.NextDouble() * $mtimeMaxSec }
                        $mtime = $btime.AddSeconds($delta)
                    }
                    if ($rng.NextDouble() -lt ($ctx.AtimeBumpPct / 100.0)) {
                        $recentStart = $ctx.NowUtc.AddDays(-30)
                        $atime = $recentStart.AddSeconds($rng.NextDouble() * ($ctx.NowUtc - $recentStart).TotalSeconds)
                        if ($atime -lt $mtime) { $atime = $mtime }
                    } else { $atime = $mtime }

                    # --- owner ---
                    $oIdx = & $sampleWeighted $rng $pool.Weights $pool.SumW
                    $ownerSid = $pool.Sids[$oIdx]

                    # --- filename ---
                    $patterns = $extMeta.FilenamePatterns
                    if ($patterns.Length -eq 0) {
                        $fname = ("file_{0}_{1}.{2}" -f $k, $rng.Next(10000, 99999), $ext)
                    } else {
                        $pat = $patterns[$rng.Next(0, $patterns.Length)]
                        $fname = & $renderFilename $pat $rng $btime
                    }

                    # Dedupe within folder: append (k) if collision
                    $path = Join-Path $folder.path $fname
                    if (Test-Path -LiteralPath $path) {
                        $base = [System.IO.Path]::GetFileNameWithoutExtension($fname)
                        $x    = [System.IO.Path]::GetExtension($fname)
                        $path = Join-Path $folder.path ("$base-$k$x")
                    }

                    # --- create file ---
                    $header       = $extMeta.HeaderBytes
                    $marker       = $extMeta.MarkerBytes
                    $markerOffset = $extMeta.MarkerOffset
                    $minSize      = [int64]$header.Length
                    if ($marker.Length -gt 0) {
                        $eom = $markerOffset + [int64]$marker.Length
                        if ($eom -gt $minSize) { $minSize = $eom }
                    }
                    if ($size -lt $minSize) { $size = $minSize }

                    $fs = [System.IO.File]::Create($path)
                    try {
                        [Acme.NativeFsctl]::SetSparse($fs.SafeFileHandle)
                        if ($header.Length -gt 0) { $fs.Position = 0; $fs.Write($header, 0, $header.Length) }
                        if ($marker.Length -gt 0) { $fs.Position = $markerOffset; $fs.Write($marker, 0, $marker.Length) }
                        if ($size -gt $fs.Length) { $fs.SetLength($size) }
                    } finally { $fs.Dispose() }

                    [System.IO.File]::SetCreationTimeUtc($path,  $btime)
                    [System.IO.File]::SetLastWriteTimeUtc($path, $mtime)
                    [System.IO.File]::SetLastAccessTimeUtc($path, $atime)
                    [Acme.NativeOwner]::SetOwner($path, $ownerSid)
                    $filesCreated++
                    $bytesLogical += $size

                    # --- version drift (inline) ---
                    if ($rng.NextDouble() -lt $ctx.DriftTrigger) {
                        $clusterSize = $rng.Next($ctx.DriftMin, $ctx.DriftMax + 1)
                        $suffixes = @('_v2','_v3','_FINAL','_FINAL_v2','_Approved','_Draft_v2','_USE_THIS')
                        $baseName = [System.IO.Path]::GetFileNameWithoutExtension($path)
                        $extOnly  = [System.IO.Path]::GetExtension($path)
                        $baseDir  = [System.IO.Path]::GetDirectoryName($path)
                        $stepHours = 0
                        $used = @{}
                        $want = [Math]::Min($clusterSize, $suffixes.Length)
                        $placed = 0
                        while ($placed -lt $want) {
                            $sfx = $suffixes[$rng.Next(0, $suffixes.Length)]
                            if ($used.ContainsKey($sfx)) { continue }
                            $used[$sfx] = $true
                            $stepHours += $rng.Next(24, 720)
                            $mtV = $mtime.AddHours($stepHours)
                            if ($mtV -gt $ctx.NowUtc) { $mtV = $ctx.NowUtc }
                            $sizeV = [int64]($size * (1.0 + (($rng.NextDouble() * 0.6) - 0.3)))
                            if ($sizeV -lt $minSize) { $sizeV = $minSize }
                            $dPath = Join-Path $baseDir ("$baseName$sfx$extOnly")
                            if (Test-Path -LiteralPath $dPath) { $placed++; continue }
                            try {
                                $fs2 = [System.IO.File]::Create($dPath)
                                try {
                                    [Acme.NativeFsctl]::SetSparse($fs2.SafeFileHandle)
                                    if ($header.Length -gt 0) { $fs2.Position = 0; $fs2.Write($header, 0, $header.Length) }
                                    if ($marker.Length -gt 0) { $fs2.Position = $markerOffset; $fs2.Write($marker, 0, $marker.Length) }
                                    if ($sizeV -gt $fs2.Length) { $fs2.SetLength($sizeV) }
                                } finally { $fs2.Dispose() }
                                [System.IO.File]::SetCreationTimeUtc($dPath,  $btime)
                                [System.IO.File]::SetLastWriteTimeUtc($dPath, $mtV)
                                [System.IO.File]::SetLastAccessTimeUtc($dPath, $mtV)
                                [Acme.NativeOwner]::SetOwner($dPath, $ownerSid)
                                $filesCreated++
                                $bytesLogical += $sizeV
                            } catch {
                                $failed++
                                if ($null -eq $failSw) { $failSw = [System.IO.StreamWriter]::new($chunkFails, $false, [System.Text.UTF8Encoding]::new($false)) }
                                $failSw.WriteLine((@{ phase='drift'; path=$dPath; message=$_.Exception.Message } | ConvertTo-Json -Compress))
                            }
                            $placed++
                        }
                    }
                } catch {
                    $failed++
                    if ($null -eq $failSw) { $failSw = [System.IO.StreamWriter]::new($chunkFails, $false, [System.Text.UTF8Encoding]::new($false)) }
                    $failSw.WriteLine((@{ phase='file'; folder=$folder.relPath; message=$_.Exception.Message } | ConvertTo-Json -Compress))
                }
            }
            $logSw.WriteLine(("folder={0} target={1}" -f $folder.relPath, $target))
        }
    } finally {
        $swChunk.Stop()
        $logSw.WriteLine(("chunk={0} filesCreated={1} bytesLogical={2} failed={3} elapsedMs={4}" -f `
            $chunk.Id, $filesCreated, $bytesLogical, $failed, $swChunk.ElapsedMilliseconds))
        $logSw.Dispose()
        if ($failSw) { $failSw.Dispose() }
    }

    [pscustomobject]@{
        ChunkId      = $chunk.Id
        FilesCreated = $filesCreated
        BytesLogical = $bytesLogical
        Failed       = $failed
        ElapsedMs    = $swChunk.ElapsedMilliseconds
    }
}
$swPhaseB.Stop()

$totalCreated = ($results | Measure-Object FilesCreated -Sum).Sum
$totalBytes   = ($results | Measure-Object BytesLogical -Sum).Sum
$totalFailed  = ($results | Measure-Object Failed -Sum).Sum
$rate = if ($swPhaseB.Elapsed.TotalSeconds -gt 0) { $totalCreated / $swPhaseB.Elapsed.TotalSeconds } else { 0 }
Write-Log ("Phase B done: created={0:N0} failed={1} bytesLogical={2:N0} elapsed={3:N1}s ({4:N0} files/sec)" -f `
    $totalCreated, $totalFailed, $totalBytes, $swPhaseB.Elapsed.TotalSeconds, $rate) 'OK'

# Merge per-chunk failure shards
$failShards = Get-ChildItem -Path $ChunkLogDir -Filter 'chunk-*-failures.jsonl' -ErrorAction SilentlyContinue
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

# ---------------------------------------------------------------------------
# Global dup pass (single-threaded)
# ---------------------------------------------------------------------------
$dupPct = [double]$cfg.duplicates.exactDuplicatePercent
$dupAdded = 0; $dupFailed = 0; $dupBytes = [int64]0
if ($dupPct -gt 0 -and $totalCreated -gt 100) {
    Write-Log "Dup pass — target ~$dupPct% of $totalCreated"
    $swDup = [System.Diagnostics.Stopwatch]::StartNew()
    $avgCopies = 3.5
    $sourceTarget = [int]([Math]::Ceiling(($totalCreated * $dupPct / 100.0) / $avgCopies))
    $acceptProb = [Math]::Min(1.0, ($sourceTarget * 1.8) / $totalCreated)
    $srcPaths = [System.Collections.Generic.List[string]]::new()
    $scanned = 0
    foreach ($fi in Get-ChildItem -Path $resolvedRoot -Recurse -File -ErrorAction SilentlyContinue) {
        $scanned++
        if ($srcPaths.Count -ge $sourceTarget) { break }
        if ($rngDup.NextDouble() -lt $acceptProb) { $srcPaths.Add($fi.FullName) }
    }
    Write-Log "Dup pass: scanned=$scanned selected=$($srcPaths.Count) target=$sourceTarget"

    $destFolderArr = @($allFolders | Where-Object { $_.relPath -ne '' })
    foreach ($srcPath in $srcPaths) {
        try {
            $srcItem = Get-Item -LiteralPath $srcPath -ErrorAction Stop
            $extOnly = $srcItem.Extension.TrimStart('.').ToLower()
            $meta    = $ExtMeta[$extOnly]
            if (-not $meta) { continue }
            $copies  = $rngDup.Next(2, 6)
            $baseName= [System.IO.Path]::GetFileNameWithoutExtension($srcPath)
            for ($c = 0; $c -lt $copies; $c++) {
                $destFolder = $destFolderArr[$rngDup.Next(0, $destFolderArr.Length)]
                $renameStyle = $rngDup.Next(0, 3)
                $newName = switch ($renameStyle) {
                    0 { "$baseName.$extOnly" }
                    1 { "$baseName - Copy.$extOnly" }
                    default { "{0} ({1}).{2}" -f $baseName, ($c + 2), $extOnly }
                }
                $dPath = Join-Path $destFolder.path $newName
                if (Test-Path -LiteralPath $dPath) {
                    $dPath = Join-Path $destFolder.path ("{0} ({1} alt).{2}" -f $baseName, ($c + 10 + $rngDup.Next(0, 9999)), $extOnly)
                }
                try {
                    $fs3 = [System.IO.File]::Create($dPath)
                    try {
                        [Acme.NativeFsctl]::SetSparse($fs3.SafeFileHandle)
                        $header = $meta.HeaderBytes
                        $marker = $meta.MarkerBytes
                        $mo     = $meta.MarkerOffset
                        if ($header.Length -gt 0) { $fs3.Position = 0; $fs3.Write($header, 0, $header.Length) }
                        if ($marker.Length -gt 0) { $fs3.Position = $mo; $fs3.Write($marker, 0, $marker.Length) }
                        if ($srcItem.Length -gt $fs3.Length) { $fs3.SetLength($srcItem.Length) }
                    } finally { $fs3.Dispose() }
                    $offset = $rngDup.Next(-3600, 3600)
                    $bt = $srcItem.CreationTimeUtc
                    $mt = $srcItem.LastWriteTimeUtc.AddSeconds($offset)
                    if ($mt -lt $bt) { $mt = $bt }
                    [System.IO.File]::SetCreationTimeUtc($dPath, $bt)
                    [System.IO.File]::SetLastWriteTimeUtc($dPath, $mt)
                    [System.IO.File]::SetLastAccessTimeUtc($dPath, $mt)
                    $pool = $OwnerPoolCache[$destFolder.ownerKey]
                    if (-not $pool) { $pool = $OwnerPoolCache['_fallback::'] }
                    $oIdx = Get-WeightedIndex -Rng $rngDup -Weights $pool.Weights
                    if ($oIdx -ge 0 -and $oIdx -lt $pool.Sids.Length) {
                        [Acme.NativeOwner]::SetOwner($dPath, $pool.Sids[$oIdx])
                    }
                    $dupAdded++
                    $dupBytes += $srcItem.Length
                } catch {
                    $dupFailed++
                }
            }
        } catch {
            $dupFailed++
        }
    }
    $swDup.Stop()
    Write-Log ("Dup pass: added={0} failed={1} elapsed={2:N1}s" -f $dupAdded, $dupFailed, $swDup.Elapsed.TotalSeconds) 'OK'
}

# ---------------------------------------------------------------------------
# Summary + failure threshold enforcement
# ---------------------------------------------------------------------------
$grandTotal   = $totalCreated + $dupAdded
$grandFailed  = $totalFailed + $dupFailed
$grandBytes   = $totalBytes + $dupBytes
$failPct      = if ($grandTotal -gt 0) { $grandFailed / $grandTotal } else { 0 }

$summary = [ordered]@{
    runStamp          = $RunStamp
    configPath        = (Resolve-Path $ConfigPath).Path
    rootPath          = $resolvedRoot
    totalFilesPlanned = $totalFiles
    phaseB = [ordered]@{
        filesCreated   = $totalCreated
        bytesLogical   = $totalBytes
        failed         = $totalFailed
        elapsedSeconds = [Math]::Round($swPhaseB.Elapsed.TotalSeconds, 2)
        filesPerSecond = [Math]::Round($rate, 1)
        chunks         = $throttle
    }
    dup = [ordered]@{
        added   = $dupAdded
        failed  = $dupFailed
        bytes   = $dupBytes
    }
    grandTotals = [ordered]@{
        filesCreated = $grandTotal
        bytesLogical = $grandBytes
        failed       = $grandFailed
        failPct      = [Math]::Round(($failPct * 100.0), 4)
    }
    folderManifest = $FolderManifestPath
    logPath        = $LogPath
    chunkLogDir    = $ChunkLogDir
    failuresPath   = $FailuresPath
}
$summary | ConvertTo-Json -Depth 6 | Set-Content -Path $SummaryPath -Encoding utf8
Write-Log "Summary written to $SummaryPath" 'OK'
$summary.grandTotals | Format-List

if ($failPct -gt 0.001) {
    Write-Log ("Failure rate {0:P3} exceeds 0.1% threshold — exit 1" -f $failPct) 'ERROR'
    exit 1
}
Write-Log ("Done. {0:N0} files, {1:N2} GB logical." -f $grandTotal, ($grandBytes / 1GB)) 'OK'
