#Requires -Version 7.0
<#
.SYNOPSIS
    Single-threaded planner for the symphony-demo-data file generator.

.DESCRIPTION
    Phases 2a + 2b of the pipeline: build the folder tree from
    folder-templates.json, allocate file counts per folder, then sample
    every file's attributes (extension, size, timestamps, owner SID,
    filename, dup/drift group) into manifests.

    Inputs:
        config/main-config(.dev).json
        config/filetypes.json
        config/folder-templates.json
        config/token-pool.json
        manifests/ad-manifest.json

    Outputs:
        manifests/folder-manifest.json      folder list with per-folder metadata
        manifests/file-manifest.jsonl       one JSON record per planned file

    Deterministic given config.meta.seed. No disk writes outside manifests/.

.PARAMETER ConfigPath
    Path to the main config JSON (dev or prod).
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

if (-not (Test-Path $ManifestDir)) { New-Item -Path $ManifestDir -ItemType Directory | Out-Null }
if (-not (Test-Path $LogDir))      { New-Item -Path $LogDir      -ItemType Directory | Out-Null }

$LogPath          = Join-Path $LogDir ("plan-{0:yyyyMMdd-HHmmss}.log" -f (Get-Date))
$FolderManifest   = Join-Path $ManifestDir 'folder-manifest.json'
$FileManifestJsonl= Join-Path $ManifestDir 'file-manifest.jsonl'

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

# ---------------------------------------------------------------------------
# Config loading
# ---------------------------------------------------------------------------
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

Write-Log "Plan-AcmeData starting"
Write-Log "ConfigPath: $ConfigPath"

$cfg           = Import-JsonFile $ConfigPath
$filetypes     = Import-JsonFile (Join-Path $ConfigDir 'filetypes.json')
$folderTemplates = Import-JsonFile (Join-Path $ConfigDir 'folder-templates.json')
$tokenPool     = Import-JsonFile (Join-Path $ConfigDir 'token-pool.json')
$adManifest    = Import-JsonFile (Join-Path $ManifestDir 'ad-manifest.json')

$resolvedRoot = Resolve-RootPath $cfg.scale.rootPath
$totalFiles   = [int]$cfg.scale.totalFiles
$masterSeed   = [int]$cfg.meta.seed

Write-Log "Resolved rootPath: $resolvedRoot"
Write-Log "Total files target: $totalFiles"
Write-Log "Master seed: $masterSeed"

# ---------------------------------------------------------------------------
# Seeded RNG
# ---------------------------------------------------------------------------
# Single System.Random per phase for determinism. Seed derivation:
# phase seed = masterSeed XOR stable-hash(phaseName).
function Get-PhaseSeed {
    param([string]$PhaseName)
    $hash = 0
    foreach ($ch in [char[]]$PhaseName) { $hash = ($hash * 31 + [int]$ch) -band 0x7FFFFFFF }
    return ($masterSeed -bxor $hash) -band 0x7FFFFFFF
}

$rngTree   = [System.Random]::new((Get-PhaseSeed 'tree'))
$rngAlloc  = [System.Random]::new((Get-PhaseSeed 'alloc'))
$rngFiles  = [System.Random]::new((Get-PhaseSeed 'files'))
$rngDup    = [System.Random]::new((Get-PhaseSeed 'dup'))
$rngDrift  = [System.Random]::new((Get-PhaseSeed 'drift'))
$rngOwners = [System.Random]::new((Get-PhaseSeed 'owners'))

function Get-LogNormalSample {
    param(
        [Parameter(Mandatory)][System.Random]$Rng,
        [Parameter(Mandatory)][double]$P50,
        [Parameter(Mandatory)][double]$P95,
        [double]$Min = 0,
        [double]$Max = [double]::MaxValue
    )
    if ($P50 -le 0 -or $P95 -le $P50) { return [Math]::Max($Min, [Math]::Min($Max, $P50)) }
    $mu = [Math]::Log($P50)
    $sigma = ([Math]::Log($P95) - $mu) / 1.6448536269514722   # z(0.95)
    # Box-Muller
    $u1 = [Math]::Max($Rng.NextDouble(), 1e-12)
    $u2 = $Rng.NextDouble()
    $z  = [Math]::Sqrt(-2.0 * [Math]::Log($u1)) * [Math]::Cos(2.0 * [Math]::PI * $u2)
    $val = [Math]::Exp($mu + $sigma * $z)
    if ($val -lt $Min) { return $Min }
    if ($val -gt $Max) { return $Max }
    return $val
}

function Get-WeightedIndex {
    param(
        [Parameter(Mandatory)][System.Random]$Rng,
        [Parameter(Mandatory)][double[]]$Weights
    )
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
    param(
        [Parameter(Mandatory)][System.Random]$Rng,
        [Parameter(Mandatory)][object[]]$Items
    )
    return $Items[$Rng.Next(0, $Items.Length)]
}

function Get-RandomSample {
    # Fisher-Yates partial — N items without replacement
    param(
        [Parameter(Mandatory)][System.Random]$Rng,
        [Parameter(Mandatory)][object[]]$Items,
        [Parameter(Mandatory)][int]$N
    )
    $n = [Math]::Min($N, $Items.Length)
    $copy = @($Items)
    for ($i = 0; $i -lt $n; $i++) {
        $j = $Rng.Next($i, $copy.Length)
        $tmp = $copy[$i]; $copy[$i] = $copy[$j]; $copy[$j] = $tmp
    }
    return ,($copy[0..($n-1)])
}

# ---------------------------------------------------------------------------
# Template token expansion
# ---------------------------------------------------------------------------
# Letter frequency weights for a-z:distributed (approximate English surname
# initial frequency; doesn't matter if exact — just non-uniform).
$LetterWeights = @{
    'A'=2;'B'=5;'C'=6;'D'=4;'E'=2;'F'=3;'G'=4;'H'=5;'I'=1;'J'=3;
    'K'=3;'L'=4;'M'=7;'N'=2;'O'=1;'P'=4;'Q'=1;'R'=5;'S'=8;'T'=5;
    'U'=1;'V'=2;'W'=4;'X'=1;'Y'=1;'Z'=1
}

$MonthNames = @('01-Jan','02-Feb','03-Mar','04-Apr','05-May','06-Jun',
                '07-Jul','08-Aug','09-Sep','10-Oct','11-Nov','12-Dec')
$QuarterNames = @('Q1','Q2','Q3','Q4')
$RevisionFolders = @('rev1','rev2','rev3','final','archive')
$VersionFolders = @('v1.0','v1.1','v1.2','v2.0','v2.1')

function Expand-TemplateToken {
    param(
        [Parameter(Mandatory)][string]$Token,
        [Parameter(Mandatory)][int]$YearRangeStart,
        [Parameter(Mandatory)][int]$YearRangeEnd,
        [Parameter(Mandatory)][System.Random]$Rng
    )
    # Returns string[] of folder-name values to expand into.
    if ($Token -match '^yearRangeStart:(\d+),yearRangeEnd:(\d+)$') {
        $s = [int]$Matches[1]; $e = [int]$Matches[2]
        return @($s..$e | ForEach-Object { "FY$_" })
    }
    if ($Token -eq 'yearRange') {
        return @($YearRangeStart..$YearRangeEnd | ForEach-Object { "FY$_" })
    }
    if ($Token -eq 'q') { return $QuarterNames }
    if ($Token -eq 'month') { return $MonthNames }
    if ($Token -eq 'rev') { return $RevisionFolders }
    if ($Token -eq 'version') { return $VersionFolders }
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
    if ($Token -eq 'departmentList') {
        return @($cfg.folders.departmentShares)
    }
    if ($Token -match '^a-z:distributed$') {
        return @(65..90 | ForEach-Object { [char]$_ })  # A..Z — weighting applied at file alloc time
    }
    # Brace alternation e.g. "src,docs,builds,tests,vendor"
    if ($Token -match ',') {
        return @($Token -split ',' | ForEach-Object { $_.Trim() })
    }
    # Unknown — treat as literal
    Write-Log "Unknown template token '$Token' — using literal" 'WARN'
    return @($Token)
}

function Expand-StructureEntry {
    # Takes one structure entry like "AP/{yearRange}/{month}" and returns all
    # expanded relative paths as string[].
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
        # A segment might be a single token "{...}" or a literal, or a mix.
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
            # Literal segment (possibly empty for leading slashes — skip).
            if ($seg -eq '') { $next = $current; continue }
            foreach ($prev in $current) {
                $next += if ($prev -eq '') { $seg } else { "$prev/$seg" }
            }
        }
        $current = $next
    }
    return ,$current
}

# ---------------------------------------------------------------------------
# Build folder tree
# ---------------------------------------------------------------------------
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
        path         = (Join-Path $resolvedRoot $RelativePath.Replace('/', '\'))
        relPath      = $RelativePath
        department   = $Department
        themeTags    = $ThemeTags
        ageBias      = $AgeBias
        ownerBias    = $OwnerBias
        isArchive    = $IsArchive
        isSensitive  = $IsSensitive
        targetFileCount = 0  # filled in allocation pass
    }
}

function Build-DepartmentFolders {
    param(
        [string]$DeptName,
        [object]$DeptTemplate,
        [int]$DefaultYearStart,
        [int]$DefaultYearEnd
    )
    $folders = [System.Collections.Generic.List[object]]::new()
    $root = "Departments/$DeptName"
    $sensitiveFolders = @()
    if ($DeptTemplate.PSObject.Properties['sensitiveFolders']) {
        $sensitiveFolders = @($DeptTemplate.sensitiveFolders)
    }
    # Always include the department root itself
    $folders.Add((New-FolderEntry -RelativePath $root `
                                  -Department $DeptName `
                                  -ThemeTags @() `
                                  -AgeBias $DeptTemplate.ageBias `
                                  -OwnerBias $DeptTemplate.ownerBias))
    foreach ($entry in $DeptTemplate.structure) {
        $topLevel = ($entry -split '/')[0]
        $isArchiveSubtree = $topLevel -match '^Archive'
        $isSensitive = $sensitiveFolders -contains $topLevel
        $ageBias = if ($isArchiveSubtree) {
            if ($DeptTemplate.PSObject.Properties['archiveFolderAgeBias']) { $DeptTemplate.archiveFolderAgeBias } else { 'very-old' }
        } else { $DeptTemplate.ageBias }
        $themeTags = @($topLevel)
        if ($isSensitive) { $themeTags += 'sensitive' }
        if ($isArchiveSubtree) { $themeTags += 'archive' }

        $expanded = Expand-StructureEntry -Entry $entry `
                                          -YearRangeStart $DefaultYearStart `
                                          -YearRangeEnd $DefaultYearEnd `
                                          -Rng $rngTree
        foreach ($relSub in $expanded) {
            $full = "$root/$relSub"
            $folders.Add((New-FolderEntry -RelativePath $full `
                                          -Department $DeptName `
                                          -ThemeTags $themeTags `
                                          -AgeBias $ageBias `
                                          -OwnerBias $DeptTemplate.ownerBias `
                                          -IsArchive:$isArchiveSubtree `
                                          -IsSensitive:$isSensitive))
            # Add intermediate folders (so every ancestor gets created + can hold files)
            $accum = $root
            foreach ($seg in ($relSub -split '/')) {
                if ($seg -eq '') { continue }
                $accum = "$accum/$seg"
                if (-not ($folders | Where-Object { $_.relPath -eq $accum })) {
                    # Only add if not already present — cheap linear scan OK at this scale.
                    # This path is the outer leaf; intermediates added below in dedup pass.
                }
            }
        }
    }
    return $folders
}

function Build-SharedFolders {
    param(
        [string]$Name,
        [object]$Template,
        [int]$DefaultYearStart,
        [int]$DefaultYearEnd
    )
    $folders = [System.Collections.Generic.List[object]]::new()
    $root = "Shared/$Name"
    $folders.Add((New-FolderEntry -RelativePath $root `
                                  -Department 'Shared' `
                                  -ThemeTags @($Name) `
                                  -AgeBias $Template.ageBias `
                                  -OwnerBias $Template.ownerBias))
    foreach ($entry in $Template.structure) {
        $topLevel = ($entry -split '/')[0]
        $isArchiveSubtree = ($Name -eq 'Archive') -or ($topLevel -match '^Archive')
        $ageBias = if ($isArchiveSubtree) { 'very-old' } else { $Template.ageBias }
        $themeTags = @($Name, $topLevel)
        if ($isArchiveSubtree) { $themeTags += 'archive' }
        $expanded = Expand-StructureEntry -Entry $entry `
                                          -YearRangeStart $DefaultYearStart `
                                          -YearRangeEnd $DefaultYearEnd `
                                          -Rng $rngTree
        foreach ($relSub in $expanded) {
            $full = "$root/$relSub"
            $folders.Add((New-FolderEntry -RelativePath $full `
                                          -Department 'Shared' `
                                          -ThemeTags $themeTags `
                                          -AgeBias $ageBias `
                                          -OwnerBias $Template.ownerBias `
                                          -IsArchive:$isArchiveSubtree))
        }
    }
    return $folders
}

Write-Log "Phase 2a — building folder tree"
$yrStart = [int]$folderTemplates.defaults.yearRangeStart
$yrEnd   = [int]$folderTemplates.defaults.yearRangeEnd

$allFolders = [System.Collections.Generic.List[object]]::new()
# Root
$allFolders.Add((New-FolderEntry -RelativePath '' `
                                 -Department '_root' `
                                 -ThemeTags @() `
                                 -AgeBias 'mixed' `
                                 -OwnerBias 'all-staff'))

# Departments — iterate in config.folders.departmentShares order so the
# folder manifest is stable regardless of PSObject property ordering.
foreach ($deptName in $cfg.folders.departmentShares) {
    $tmpl = $folderTemplates.departments.$deptName
    if ($null -eq $tmpl) {
        Write-Log "No folder template for department $deptName — skipping" 'WARN'
        continue
    }
    $list = Build-DepartmentFolders -DeptName $deptName -DeptTemplate $tmpl `
                                    -DefaultYearStart $yrStart -DefaultYearEnd $yrEnd
    foreach ($f in $list) { $allFolders.Add($f) }
}
# Shared
foreach ($sharedName in $cfg.folders.commonShares) {
    $tmpl = $folderTemplates.shared.$sharedName
    if ($null -eq $tmpl) {
        Write-Log "No folder template for shared/$sharedName — skipping" 'WARN'
        continue
    }
    $list = Build-SharedFolders -Name $sharedName -Template $tmpl `
                                -DefaultYearStart $yrStart -DefaultYearEnd $yrEnd
    foreach ($f in $list) { $allFolders.Add($f) }
}

# Add intermediate ancestors for every leaf, so every folder gets created on disk.
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
            $intermediates.Add((New-FolderEntry -RelativePath $accum `
                                               -Department $f.department `
                                               -ThemeTags $f.themeTags `
                                               -AgeBias $f.ageBias `
                                               -OwnerBias $f.ownerBias `
                                               -IsArchive:$f.isArchive `
                                               -IsSensitive:$f.isSensitive))
        }
    }
}
foreach ($f in $intermediates) { $allFolders.Add($f) }

# Deep-folder rabbit holes: deepFolderPercent % of leaf folders get extra depth.
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
                $allFolders.Add((New-FolderEntry -RelativePath $subPath `
                                                 -Department $f.department `
                                                 -ThemeTags ($f.themeTags + 'deep') `
                                                 -AgeBias $f.ageBias `
                                                 -OwnerBias $f.ownerBias))
            }
        }
    }
    Write-Log "Added deep-folder rabbit holes from $($chosen.Count) leaves"
}

Write-Log "Folder tree size: $($allFolders.Count)" 'OK'

# ---------------------------------------------------------------------------
# File-count allocation
# ---------------------------------------------------------------------------
Write-Log "Phase 2b(i) — allocating file counts across folders"

# Per-folder weight via log-normal. Archive/sensitive/deep folders get mild
# modifiers. Zero-weight _root so no files land in the share root itself.
$defaults = $folderTemplates.defaults
$p50 = [double]$defaults.filesPerFolderP50
$p95 = [double]$defaults.filesPerFolderP95
$maxPerFolder = [double]$defaults.filesPerFolderMax

$weights = New-Object 'double[]' $allFolders.Count
for ($i = 0; $i -lt $allFolders.Count; $i++) {
    $f = $allFolders[$i]
    if ($f.relPath -eq '') { $weights[$i] = 0; continue }
    $w = Get-LogNormalSample -Rng $rngAlloc -P50 $p50 -P95 $p95 -Min 1 -Max $maxPerFolder
    if ($f.isArchive) { $w *= 1.3 }   # archives accumulate
    if ($f.themeTags -contains 'deep') { $w *= 0.25 }  # rabbit holes are sparsely used
    $weights[$i] = $w
}

# Convert weights → integer counts summing to totalFiles (largest-remainder).
$sumW = 0.0; foreach ($w in $weights) { $sumW += $w }
$counts = New-Object 'int[]' $allFolders.Count
$residuals = New-Object 'double[]' $allFolders.Count
$assigned = 0
for ($i = 0; $i -lt $weights.Length; $i++) {
    $share = ($weights[$i] / $sumW) * $totalFiles
    $c = [int][Math]::Floor($share)
    $counts[$i] = $c
    $residuals[$i] = $share - $c
    $assigned += $c
}
$remaining = $totalFiles - $assigned
if ($remaining -gt 0) {
    # Distribute the leftover to folders with largest residual.
    $idxOrdered = @(0..($residuals.Length - 1) | Sort-Object { -$residuals[$_] })
    for ($k = 0; $k -lt $remaining; $k++) { $counts[$idxOrdered[$k % $idxOrdered.Length]]++ }
}
for ($i = 0; $i -lt $allFolders.Count; $i++) { $allFolders[$i].targetFileCount = $counts[$i] }

$nonEmpty = ($counts | Where-Object { $_ -gt 0 }).Count
Write-Log "File allocation: $totalFiles files across $nonEmpty non-empty folders (of $($allFolders.Count) total)" 'OK'

# ---------------------------------------------------------------------------
# Owner pools
# ---------------------------------------------------------------------------
Write-Log "Building owner pools from ad-manifest"

$usersAll = @($adManifest.users)
$usersByStatus = @{
    active     = @($usersAll | Where-Object { $_.status -eq 'active' })
    disabled   = @($usersAll | Where-Object { $_.status -eq 'disabled' })
    terminated = @($usersAll | Where-Object { $_.status -eq 'terminated' })
    service    = @($usersAll | Where-Object { $_.status -eq 'service' })
}
$usersByDept = [ordered]@{}
foreach ($u in ($usersByStatus.active | Sort-Object samAccountName)) {
    $d = $u.department
    if (-not $usersByDept.Contains($d)) { $usersByDept[$d] = [System.Collections.Generic.List[object]]::new() }
    $usersByDept[$d].Add($u)
}

# Hoarders: deterministic top 10% of active users by hash order.
$hoarderPct = [int]$cfg.spaceSkew.hoarderUserPercent
$activeSorted = @($usersByStatus.active | Sort-Object {
    $h = 0; foreach ($ch in [char[]]"$($_.sid)-hoarder") { $h = ($h * 31 + [int]$ch) -band 0x7FFFFFFF }
    $h
})
$hoarderCount = [int]([Math]::Ceiling($activeSorted.Count * ($hoarderPct / 100.0)))
$hoarders = @($activeSorted[0..([Math]::Max(0, $hoarderCount - 1))])
Write-Log "Active users: $($usersByStatus.active.Count), hoarders: $($hoarders.Count), service: $($usersByStatus.service.Count), terminated: $($usersByStatus.terminated.Count)"

# Precompute owner-bias pools as (users[], weights[]) pairs.
function Get-OwnerPool {
    param(
        [Parameter(Mandatory)][string]$Bias,
        [string]$Department = $null
    )
    $users = [System.Collections.Generic.List[object]]::new()
    $weights = [System.Collections.Generic.List[double]]::new()
    function Add-Users { param([object[]]$Set, [double]$W)
        foreach ($u in $Set) { $users.Add($u); $weights.Add($W) }
    }
    switch ($Bias) {
        'department' {
            $deptUsers = if ($Department -and $usersByDept.Contains($Department)) { @($usersByDept[$Department]) } else { @($usersByStatus.active) }
            Add-Users $deptUsers 8.0
            Add-Users $usersByStatus.service 1.5
            Add-Users $hoarders 2.0
            Add-Users $usersByStatus.terminated 0.4
        }
        'executives-only' {
            $execs = if ($usersByDept.Contains('Executive')) { @($usersByDept['Executive']) } else { @() }
            Add-Users $execs 9.0
            Add-Users $usersByStatus.service 1.0
        }
        'it-admins-and-service-accounts' {
            $it = if ($usersByDept.Contains('IT')) { @($usersByDept['IT']) } else { @() }
            Add-Users $it 5.0
            Add-Users $usersByStatus.service 5.0
        }
        'all-staff' {
            Add-Users $usersByStatus.active 1.0
        }
        'mixed' {
            Add-Users $usersByStatus.active 7.0
            Add-Users $usersByStatus.disabled 1.5
            Add-Users $usersByStatus.terminated 1.0
            Add-Users $usersByStatus.service 0.5
        }
        'mixed-including-terminated' {
            Add-Users $usersByStatus.active 4.0
            Add-Users $usersByStatus.disabled 2.0
            Add-Users $usersByStatus.terminated 4.0
        }
        'cross-department' {
            $deptNames = @($usersByDept.Keys)
            $picked = Get-RandomSample -Rng $rngOwners -Items $deptNames -N 3
            foreach ($d in $picked) { Add-Users @($usersByDept[$d]) 5.0 }
            Add-Users $usersByStatus.service 0.5
        }
        default {
            Add-Users $usersByStatus.active 1.0
        }
    }
    return [pscustomobject]@{ Users = @($users); Weights = [double[]]@($weights) }
}

# ---------------------------------------------------------------------------
# Age-bucket helpers
# ---------------------------------------------------------------------------
# Today anchor — must be stable across re-runs for same-seed reproducibility.
# Prefer ad-manifest.meta.generatedAtUtc (fixed at AD build time); fall back
# to wall-clock only if that field is absent.
if ($adManifest.meta.PSObject.Properties['generatedAtUtc']) {
    $nowUtc = ([datetime]$adManifest.meta.generatedAtUtc).ToUniversalTime()
    Write-Log "Time anchor: ad-manifest.generatedAtUtc = $($nowUtc.ToString('o'))"
} else {
    $nowUtc = (Get-Date).ToUniversalTime()
    Write-Log "Time anchor: wall-clock (ad-manifest has no generatedAtUtc)" 'WARN'
}
function Get-BucketRange {
    param([string]$Bucket)
    switch ($Bucket) {
        'last30days'   { return @($nowUtc.AddDays(-30), $nowUtc) }
        'days30to365'  { return @($nowUtc.AddDays(-365), $nowUtc.AddDays(-30)) }
        'years1to2'    { return @($nowUtc.AddYears(-2), $nowUtc.AddYears(-1)) }
        'years2to5'    { return @($nowUtc.AddYears(-5), $nowUtc.AddYears(-2)) }
        'years5to10'   { return @($nowUtc.AddYears(-10), $nowUtc.AddYears(-5)) }
        'years10to15'  { return @($nowUtc.AddYears(-15), $nowUtc.AddYears(-10)) }
    }
    return @($nowUtc.AddYears(-1), $nowUtc)
}

$AgeBuckets = @('last30days','days30to365','years1to2','years2to5','years5to10','years10to15')

function Get-AgeWeights {
    param([string]$Bias)
    $base = @{}
    foreach ($b in $AgeBuckets) { $base[$b] = [double]$cfg.ageDistribution.$b }
    switch ($Bias) {
        'recent-leaning' {
            $base['last30days']  *= 2.0
            $base['days30to365'] *= 2.0
            $base['years1to2']   *= 2.0
            $base['years10to15'] *= 0.3
        }
        'old-leaning' {
            $base['years5to10']  *= 2.0
            $base['years10to15'] *= 2.0
            $base['last30days']  *= 0.5
            $base['days30to365'] *= 0.5
        }
        'very-old' {
            $base['years10to15'] *= 4.0
            $base['years5to10']  *= 2.5
            $base['last30days']  *= 0.1
            $base['days30to365'] *= 0.1
        }
        'old' {
            $base['years5to10']  *= 2.5
            $base['years10to15'] *= 3.0
            $base['last30days']  *= 0.3
            $base['days30to365'] *= 0.3
        }
        default { }  # mixed — use global
    }
    $arr = New-Object 'double[]' $AgeBuckets.Length
    for ($i = 0; $i -lt $AgeBuckets.Length; $i++) { $arr[$i] = $base[$AgeBuckets[$i]] }
    return ,$arr
}

# Precompute age-weight arrays per distinct bias label.
$AgeWeightCache = @{}
foreach ($b in @('mixed','recent-leaning','old-leaning','very-old','old')) {
    $AgeWeightCache[$b] = Get-AgeWeights $b
}

function Get-TimestampTriplet {
    param(
        [Parameter(Mandatory)][System.Random]$Rng,
        [Parameter(Mandatory)][datetime]$BucketStart,
        [Parameter(Mandatory)][datetime]$BucketEnd,
        [Parameter(Mandatory)][double]$AtimeRecentlyTouchedPct
    )
    $spanSec = ($BucketEnd - $BucketStart).TotalSeconds
    $btime = $BucketStart.AddSeconds($Rng.NextDouble() * $spanSec)
    # mtime ≥ btime. Usually same day; sometimes weeks/months later, bounded by now.
    $mtimeMaxSec = ($nowUtc - $btime).TotalSeconds
    if ($mtimeMaxSec -le 0) { $mtime = $btime }
    else {
        # 70% same-day-ish (< 24h), 30% longer (up to bucket span into future)
        if ($Rng.NextDouble() -lt 0.7) {
            $delta = $Rng.NextDouble() * [Math]::Min(86400.0, $mtimeMaxSec)
        } else {
            $delta = $Rng.NextDouble() * $mtimeMaxSec
        }
        $mtime = $btime.AddSeconds($delta)
    }
    # atime — usually == mtime; occasionally bumped recent.
    if ($Rng.NextDouble() -lt ($AtimeRecentlyTouchedPct / 100.0)) {
        $recentStart = $nowUtc.AddDays(-30)
        $atime = $recentStart.AddSeconds($Rng.NextDouble() * ($nowUtc - $recentStart).TotalSeconds)
        if ($atime -lt $mtime) { $atime = $mtime }
    } else {
        $atime = $mtime
    }
    return @($btime, $mtime, $atime)
}

# ---------------------------------------------------------------------------
# Extension sampling
# ---------------------------------------------------------------------------
# Flatten filetypes into a lookup + per-category ext list.
# ordered + explicit iteration of fileTypeMix to guarantee stable category
# order across runs (PSObject property enumeration is stable within a run but
# the category weight array must match the category list exactly).
$ExtensionCatalog = @{}
$CategoryExts = [ordered]@{}
$CategoryList = @($cfg.fileTypeMix.PSObject.Properties | Where-Object { -not $_.Name.StartsWith('$') } | ForEach-Object { $_.Name })
foreach ($catName in $CategoryList) {
    $catNode = $filetypes.$catName
    if ($null -eq $catNode) { continue }
    $CategoryExts[$catName] = [System.Collections.Generic.List[string]]::new()
    foreach ($extProp in $catNode.PSObject.Properties) {
        if ($extProp.Name.StartsWith('$')) { continue }
        $ExtensionCatalog[$extProp.Name] = $extProp.Value
        $CategoryExts[$catName].Add($extProp.Name)
    }
}
$CategoryBaseWeights = New-Object 'double[]' $CategoryList.Length
for ($i = 0; $i -lt $CategoryList.Length; $i++) {
    $c = $CategoryList[$i]
    $CategoryBaseWeights[$i] = [double]$cfg.fileTypeMix.$c
}

function Sample-Extension {
    param(
        [Parameter(Mandatory)][System.Random]$Rng,
        [object]$AffinityMultipliers
    )
    # Pick category weighted by fileTypeMix, then ext within category weighted
    # by affinityMultipliers (default 1.0).
    $catIdx = Get-WeightedIndex -Rng $Rng -Weights $CategoryBaseWeights
    $cat = $CategoryList[$catIdx]
    $exts = $CategoryExts[$cat]
    $w = New-Object 'double[]' $exts.Count
    for ($i = 0; $i -lt $exts.Count; $i++) {
        $e = $exts[$i]
        $mult = 1.0
        if ($AffinityMultipliers -and $AffinityMultipliers.PSObject.Properties[$e]) {
            $mult = [double]$AffinityMultipliers.$e
        }
        $w[$i] = $mult
    }
    $idx = Get-WeightedIndex -Rng $Rng -Weights $w
    return $exts[$idx]
}

# ---------------------------------------------------------------------------
# Filename rendering
# ---------------------------------------------------------------------------
function Render-Filename {
    param(
        [Parameter(Mandatory)][string]$Pattern,
        [Parameter(Mandatory)][System.Random]$Rng,
        [Parameter(Mandatory)][datetime]$Btime,
        [int]$GlobalIndex = 0
    )
    $out = $Pattern
    # Replace placeholders one at a time via regex so each gets an independent draw.
    $out = [regex]::Replace($out, '\{([^}]+)\}', {
        param($m)
        $tok = $m.Groups[1].Value
        switch -Regex ($tok) {
            '^n(\d+)$' {
                $digits = [int]$Matches[1]
                $max = [int][Math]::Pow(10, $digits)
                return ('{0:D' + $digits + '}') -f ($Rng.Next(0, $max))
            }
            '^date$' {
                # Random date near Btime. 50/50 format YYYYMMDD or YYYY-MM-DD.
                $d = $Btime.AddDays($Rng.Next(-30, 30))
                if ($Rng.NextDouble() -lt 0.5) { return $d.ToString('yyyyMMdd') } else { return $d.ToString('yyyy-MM-dd') }
            }
            '^year$' { return $Btime.Year.ToString() }
            '^q$'    { return (Get-RandomPick -Rng $Rng -Items $QuarterNames) }
            '^month$' {
                $numeric = $Rng.NextDouble() -lt 0.5
                if ($numeric) { return '{0:D2}' -f $Btime.Month }
                return $tokenPool.monthsShort[$Btime.Month - 1]
            }
            '^codeword$' { return (Get-RandomPick -Rng $Rng -Items @($tokenPool.codewords)) }
            '^rev$'      { return (Get-RandomPick -Rng $Rng -Items @($tokenPool.revisions)) }
        }
        return $m.Value  # leave unknown tokens as-is
    })
    return $out
}

# ---------------------------------------------------------------------------
# Main sampling loop → file-manifest.jsonl
# ---------------------------------------------------------------------------
Write-Log "Phase 2b(ii) — sampling per-file attributes and writing file-manifest.jsonl"

# Pre-build owner pools per (bias, department) pair we'll hit.
$ownerPoolCache = @{}
function Get-CachedOwnerPool {
    param([string]$Bias, [string]$Department)
    $key = "$Bias::$Department"
    if (-not $ownerPoolCache.ContainsKey($key)) {
        $ownerPoolCache[$key] = Get-OwnerPool -Bias $Bias -Department $Department
    }
    return $ownerPoolCache[$key]
}

function Sample-OwnerSid {
    param([object]$Folder)
    $pool = Get-CachedOwnerPool -Bias $Folder.ownerBias -Department $Folder.department
    if ($pool.Users.Count -eq 0) { return $null }
    $idx = Get-WeightedIndex -Rng $rngOwners -Weights $pool.Weights
    return $pool.Users[$idx].sid
}

$atimeBumpPct = [double]$cfg.timeConsistency.atimeRecentlyTouchedPercent

# In-memory file list so we can run dup/drift passes after sampling.
# For 10M this holds ~2-3 GB — acceptable on 96 GB RAM box. For dev trivial.
$fileRecords = [System.Collections.Generic.List[object]]::new($totalFiles)
$fileIdx = 0
$fileCountProgress = [Math]::Max(1, [int]($totalFiles / 20))

foreach ($folder in $allFolders) {
    if ($folder.targetFileCount -le 0) { continue }
    $ageWeights = if ($AgeWeightCache.ContainsKey($folder.ageBias)) { $AgeWeightCache[$folder.ageBias] } else { $AgeWeightCache['mixed'] }
    $affinityMultipliers = $null
    # Look up affinity: department template or shared template.
    if ($folder.department -in $cfg.folders.departmentShares) {
        $tmpl = $folderTemplates.departments.$($folder.department)
        if ($tmpl -and $tmpl.PSObject.Properties['affinityMultipliers']) { $affinityMultipliers = $tmpl.affinityMultipliers }
    } elseif ($folder.department -eq 'Shared') {
        # Determine which shared bucket
        $sharedBucket = ($folder.relPath -split '/')[1]
        $tmpl = $folderTemplates.shared.$sharedBucket
        if ($tmpl -and $tmpl.PSObject.Properties['affinityMultipliers']) { $affinityMultipliers = $tmpl.affinityMultipliers }
    }

    for ($k = 0; $k -lt $folder.targetFileCount; $k++) {
        $fileIdx++
        if (($fileIdx % $fileCountProgress) -eq 0) {
            Write-Progress -Activity 'Sampling files' -Status "$fileIdx / $totalFiles" -PercentComplete (($fileIdx / $totalFiles) * 100)
        }
        $ext = Sample-Extension -Rng $rngFiles -AffinityMultipliers $affinityMultipliers
        $extMeta = $ExtensionCatalog[$ext]

        # Size
        $sd = $extMeta.sizeDistribution
        $size = [long](Get-LogNormalSample -Rng $rngFiles -P50 ([double]$sd.p50Bytes) -P95 ([double]$sd.p95Bytes) -Min ([double]$sd.minBytes) -Max ([double]$sd.maxBytes))

        # Age bucket → timestamps
        $bucketIdx = Get-WeightedIndex -Rng $rngFiles -Weights $ageWeights
        $bucket = $AgeBuckets[$bucketIdx]
        $range = Get-BucketRange $bucket
        $ts = Get-TimestampTriplet -Rng $rngFiles -BucketStart $range[0] -BucketEnd $range[1] -AtimeRecentlyTouchedPct $atimeBumpPct

        # Filename
        $patterns = @($extMeta.filenamePatterns)
        $pat = Get-RandomPick -Rng $rngFiles -Items $patterns
        $fname = Render-Filename -Pattern $pat -Rng $rngFiles -Btime $ts[0] -GlobalIndex $fileIdx

        # Owner
        $ownerSid = Sample-OwnerSid -Folder $folder

        $rec = [ordered]@{
            path       = (Join-Path $folder.path $fname)
            ext        = $ext
            category   = $extMeta.category
            size       = $size
            btime      = $ts[0].ToString('o')
            mtime      = $ts[1].ToString('o')
            atime      = $ts[2].ToString('o')
            ownerSid   = $ownerSid
            folderRel  = $folder.relPath
            ageBucket  = $bucket
            dupGroup   = $null
        }
        $fileRecords.Add($rec)
    }
}
Write-Progress -Activity 'Sampling files' -Completed
Write-Log "Sampled $($fileRecords.Count) base file records" 'OK'

# ---------------------------------------------------------------------------
# Duplicate pass
# ---------------------------------------------------------------------------
$dupPct = [double]$cfg.duplicates.exactDuplicatePercent
if ($dupPct -gt 0 -and $fileRecords.Count -gt 10) {
    Write-Log "Planning exact duplicates (~$dupPct%)"
    # Target: dupPct of total files are "duplicate copies" (not counting the source).
    # Source count = ceil(totalFiles * dupPct / avgCopies) where avgCopies = 3.
    $sourceCount = [int]([Math]::Ceiling($fileRecords.Count * ($dupPct / 100.0) / 3.0))
    $sourceCount = [Math]::Min($sourceCount, [int]($fileRecords.Count / 2))
    $srcIdxPool = @(0..($fileRecords.Count - 1))
    $srcIdxs = Get-RandomSample -Rng $rngDup -Items $srcIdxPool -N $sourceCount

    # Folders that can receive a copy — any folder with some files already (or at least exists).
    $candidateFolders = @($allFolders | Where-Object { $_.relPath -ne '' })
    $dupAdded = 0
    $grp = 0
    foreach ($srcIdx in $srcIdxs) {
        $src = $fileRecords[$srcIdx]
        $grp++
        $dupGroupId = ('d{0:D5}' -f $grp)
        $src.dupGroup = $dupGroupId
        $copies = $rngDup.Next(2, 6)   # 2..5
        for ($c = 0; $c -lt $copies; $c++) {
            $destFolder = Get-RandomPick -Rng $rngDup -Items $candidateFolders
            # Copy-rename variations
            $renameStyle = $rngDup.Next(0, 3)
            $base = [System.IO.Path]::GetFileNameWithoutExtension($src.path)
            $extOnly = [System.IO.Path]::GetExtension($src.path)
            $newName = switch ($renameStyle) {
                0 { "$base$extOnly" }                                   # same name, different folder
                1 { "$base - Copy$extOnly" }
                default { "{0} ({1}){2}" -f $base, ($c + 2), $extOnly }
            }
            $mtimeOffset = $rngDup.Next(-3600, 3600)
            $mtimeDup = ([datetime]::Parse($src.mtime)).AddSeconds($mtimeOffset)
            $btimeDup = ([datetime]::Parse($src.btime))
            if ($mtimeDup -lt $btimeDup) { $mtimeDup = $btimeDup }
            $rec = [ordered]@{
                path       = (Join-Path $destFolder.path $newName)
                ext        = $src.ext
                category   = $src.category
                size       = $src.size
                btime      = $btimeDup.ToString('o')
                mtime      = $mtimeDup.ToString('o')
                atime      = $mtimeDup.ToString('o')
                ownerSid   = (Sample-OwnerSid -Folder $destFolder)
                folderRel  = $destFolder.relPath
                ageBucket  = $src.ageBucket
                dupGroup   = $dupGroupId
            }
            $fileRecords.Add($rec); $dupAdded++
        }
    }
    Write-Log "Added $dupAdded duplicate records across $sourceCount groups" 'OK'
}

# ---------------------------------------------------------------------------
# Version-drift pass
# ---------------------------------------------------------------------------
$driftPct = [double]$cfg.duplicates.versionDriftPercent
$driftMin = [int]$cfg.duplicates.versionDriftClusterSizeMin
$driftMax = [int]$cfg.duplicates.versionDriftClusterSizeMax
if ($driftPct -gt 0 -and $fileRecords.Count -gt 10) {
    Write-Log "Planning version drift (~$driftPct%)"
    $officeExts = @('docx','xlsx','pptx','pdf','doc','xls')
    $candidates = @()
    for ($i = 0; $i -lt $fileRecords.Count; $i++) {
        if ($null -eq $fileRecords[$i].dupGroup -and ($officeExts -contains $fileRecords[$i].ext)) { $candidates += $i }
    }
    if ($candidates.Length -gt 0) {
        $avgCluster = ($driftMin + $driftMax) / 2.0
        $clusterCount = [int]([Math]::Ceiling($fileRecords.Count * ($driftPct / 100.0) / $avgCluster))
        $clusterCount = [Math]::Min($clusterCount, $candidates.Length)
        $chosen = Get-RandomSample -Rng $rngDrift -Items $candidates -N $clusterCount
        $grp = 0; $driftAdded = 0
        foreach ($baseIdx in $chosen) {
            $base = $fileRecords[$baseIdx]
            $grp++
            $driftGroupId = ('v{0:D5}' -f $grp)
            $base.dupGroup = $driftGroupId
            $size = $driftMin + $rngDrift.Next(0, $driftMax - $driftMin + 1) - 1
            $baseName = [System.IO.Path]::GetFileNameWithoutExtension($base.path)
            $extOnly  = [System.IO.Path]::GetExtension($base.path)
            $baseDir  = [System.IO.Path]::GetDirectoryName($base.path)
            $baseMtime = [datetime]::Parse($base.mtime)
            $suffixes = @('_v2','_v3','_FINAL','_FINAL_v2','_FINAL_USE_THIS','_Approved')
            $picked = Get-RandomSample -Rng $rngDrift -Items $suffixes -N ([Math]::Min($size, $suffixes.Length))
            $stepHours = 0
            foreach ($sfx in $picked) {
                $stepHours += $rngDrift.Next(24, 24*30)
                $mtV = $baseMtime.AddHours($stepHours)
                if ($mtV -gt $nowUtc) { $mtV = $nowUtc }
                $sizeVar = [long]($base.size * (1.0 + (($rngDrift.NextDouble() * 0.6) - 0.3)))  # +/-30%
                if ($sizeVar -lt 1) { $sizeVar = 1 }
                $rec = [ordered]@{
                    path       = (Join-Path $baseDir ("$baseName$sfx$extOnly"))
                    ext        = $base.ext
                    category   = $base.category
                    size       = $sizeVar
                    btime      = $base.btime
                    mtime      = $mtV.ToString('o')
                    atime      = $mtV.ToString('o')
                    ownerSid   = $base.ownerSid
                    folderRel  = $base.folderRel
                    ageBucket  = $base.ageBucket
                    dupGroup   = $driftGroupId
                }
                $fileRecords.Add($rec); $driftAdded++
            }
        }
        Write-Log "Added $driftAdded version-drift records across $clusterCount clusters" 'OK'
    } else {
        Write-Log 'No office-ext candidates for version drift' 'WARN'
    }
}

# ---------------------------------------------------------------------------
# Write outputs
# ---------------------------------------------------------------------------
Write-Log "Writing folder-manifest.json"
$folderOut = [ordered]@{
    meta = [ordered]@{
        generatedAtUtc  = (Get-Date).ToUniversalTime().ToString('o')
        timeAnchorUtc   = $nowUtc.ToString('o')
        configPath      = (Resolve-Path $ConfigPath).Path
        seed            = $masterSeed
        rootPath        = $resolvedRoot
        folderCount     = $allFolders.Count
        totalFilesPlanned = $totalFiles
    }
    folders = @($allFolders)
}
$folderOut | ConvertTo-Json -Depth 10 | Set-Content -Path $FolderManifest -Encoding utf8
Write-Log "folder-manifest.json: $($allFolders.Count) folders" 'OK'

Write-Log "Writing file-manifest.jsonl"
$sw = [System.IO.StreamWriter]::new($FileManifestJsonl, $false, [System.Text.UTF8Encoding]::new($false))
try {
    $rowCount = 0
    foreach ($r in $fileRecords) {
        $sw.WriteLine(($r | ConvertTo-Json -Compress -Depth 6))
        $rowCount++
    }
} finally {
    $sw.Dispose()
}
Write-Log "file-manifest.jsonl: $rowCount records" 'OK'

# ---------------------------------------------------------------------------
# Run summary
# ---------------------------------------------------------------------------
$summary = [ordered]@{
    folderCount       = $allFolders.Count
    nonEmptyFolders   = $nonEmpty
    totalFilesPlanned = $totalFiles
    totalRecords      = $fileRecords.Count
    duplicateRecords  = ($fileRecords | Where-Object { $_.dupGroup -and $_.dupGroup.StartsWith('d') }).Count
    driftRecords      = ($fileRecords | Where-Object { $_.dupGroup -and $_.dupGroup.StartsWith('v') }).Count
    rootPath          = $resolvedRoot
    seed              = $masterSeed
    folderManifest    = $FolderManifest
    fileManifest      = $FileManifestJsonl
    logPath           = $LogPath
}
$summary | ConvertTo-Json -Depth 4 | Set-Content -Path (Join-Path $LogDir 'plan-summary.json') -Encoding utf8
Write-Log "Plan complete." 'OK'
$summary | Format-List
