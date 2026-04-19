#Requires -Version 7.0
<#
.SYNOPSIS
    Phase 2g — applies clean ACL templates plus the six mess patterns from
    docs/03-acl-design.md to every folder, and a small % of files.

.DESCRIPTION
    Two-pass design:
        (1) Single-threaded PLAN pass — decides every folder's final ACE list
            (clean template + deterministic mess-pattern overrides) and
            emits an in-memory plan.
        (2) Parallel APPLY pass — each runspace builds a DirectorySecurity
            from its batch of plan entries and calls SetAccessControl.

    Mess patterns are seeded-deterministic per folder: same manifest →
    same ACL plan every run. File-level ACLs apply to ~acl.oversharePercent/10
    of total files (roughly matching the ~0.5% target in the spec).

    Running before Remove-AcmeOrphans.ps1 is correct: we intentionally
    embed terminated-user SIDs now so they become orphaned ACEs after
    the orphan pass.

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
$FolderManifest = Join-Path $ManifestDir 'folder-manifest.json'
$FileManifest   = Join-Path $ManifestDir 'file-manifest.jsonl'
$AdManifest     = Join-Path $ManifestDir 'ad-manifest.json'
foreach ($p in @($FolderManifest, $AdManifest)) {
    if (-not (Test-Path $p)) { throw "missing: $p" }
}
if (-not (Test-Path $LogDir)) { New-Item -Path $LogDir -ItemType Directory | Out-Null }

$RunStamp = '{0:yyyyMMdd-HHmmss}' -f (Get-Date)
$LogPath  = Join-Path $LogDir ("acls-$RunStamp.log")

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

Write-Log "Set-AcmeACLs starting"
$cfg            = Import-JsonFile $ConfigPath
$folderManifest = Import-JsonFile $FolderManifest
$folders        = $folderManifest.folders
$adManifest     = Import-JsonFile $AdManifest

$throttle   = [int]$cfg.scale.parallelThreads
$seed       = [int]$cfg.meta.seed
Write-Log "folders=$($folders.Count) seed=$seed throttle=$throttle"

# ---------------------------------------------------------------------------
# SID lookups
# ---------------------------------------------------------------------------
# Active/terminated/service users from AD manifest
$usersBySam = @{}
foreach ($u in $adManifest.users) { $usersBySam[$u.samAccountName] = $u }
$activeUsers     = @($adManifest.users | Where-Object status -eq 'active')
$terminatedUsers = @($adManifest.users | Where-Object status -eq 'terminated')
$serviceUsers    = @($adManifest.users | Where-Object status -eq 'service')

# Group SIDs
$groupSid = @{}
foreach ($g in $adManifest.groups) { $groupSid[$g.name] = $g.sid }

# Derive domain SID from any user SID (strip the last RID).
$sampleSid = $adManifest.users[0].sid
$domainSid = ($sampleSid -replace '-\d+$','')
Write-Log "Domain SID: $domainSid"

$wellKnown = @{
    Everyone            = 'S-1-1-0'
    AuthenticatedUsers  = 'S-1-5-11'
    SYSTEM              = 'S-1-5-18'
    CreatorOwner        = 'S-1-3-0'
    DomainUsers         = "$domainSid-513"
    DomainAdmins        = "$domainSid-512"
}

function Get-GroupSid {
    param([string]$Name, [switch]$Silent)
    if ($groupSid.ContainsKey($Name)) { return $groupSid[$Name] }
    if (-not $Silent) { Write-Log "group not found: $Name" 'WARN' }
    return $null
}

# ---------------------------------------------------------------------------
# Seeded RNG
# ---------------------------------------------------------------------------
function Get-PhaseSeed {
    param([string]$Phase)
    $h = 0
    foreach ($ch in [char[]]$Phase) { $h = ($h * 31 + [int]$ch) -band 0x7FFFFFFF }
    return ($seed -bxor $h) -band 0x7FFFFFFF
}

$rngAcl   = [System.Random]::new((Get-PhaseSeed 'acl-base'))
$rngMess  = [System.Random]::new((Get-PhaseSeed 'acl-mess'))
$rngOwn   = [System.Random]::new((Get-PhaseSeed 'acl-own'))
$rngFile  = [System.Random]::new((Get-PhaseSeed 'acl-file'))

function Get-WeightedIndex {
    param([System.Random]$Rng, [double[]]$Weights)
    $sum = 0.0; foreach ($w in $Weights) { $sum += $w }
    if ($sum -le 0) { return 0 }
    $r = $Rng.NextDouble() * $sum
    $acc = 0.0
    for ($i = 0; $i -lt $Weights.Length; $i++) {
        $acc += $Weights[$i]; if ($r -le $acc) { return $i }
    }
    return $Weights.Length - 1
}

function Get-RandomPick {
    param([System.Random]$Rng, [object[]]$Items)
    if ($Items.Length -eq 0) { return $null }
    return $Items[$Rng.Next(0, $Items.Length)]
}

function Get-RandomSample {
    param([System.Random]$Rng, [object[]]$Items, [int]$N)
    $n = [Math]::Min($N, $Items.Length)
    $copy = @($Items)
    for ($i = 0; $i -lt $n; $i++) {
        $j = $Rng.Next($i, $copy.Length)
        $t = $copy[$i]; $copy[$i] = $copy[$j]; $copy[$j] = $t
    }
    return ,($copy[0..($n-1)])
}

# ---------------------------------------------------------------------------
# ACE spec factory — emits pscustomobject ACE specs we later translate to
# FileSystemAccessRule during the apply pass.
# ---------------------------------------------------------------------------
function New-Ace {
    param(
        [Parameter(Mandatory)][string]$Sid,
        [Parameter(Mandatory)][string]$Rights,       # FullControl/Modify/ReadAndExecute/Read/Write
        [ValidateSet('Allow','Deny')][string]$Type = 'Allow',
        [ValidateSet('None','This','ContainerOnly','All','CreatorOwner')][string]$Inherit = 'All'
    )
    return [pscustomobject]@{ Sid = $Sid; Rights = $Rights; Type = $Type; Inherit = $Inherit }
}

# ---------------------------------------------------------------------------
# Folder categorization
# ---------------------------------------------------------------------------
function Get-FolderCategory {
    param([object]$F)
    if ($F.relPath -eq '') { return 'root' }
    $parts = $F.relPath -split '/'
    $top = $parts[0]
    if ($top -eq 'Shared') {
        if ($parts.Length -lt 2) { return 'shared-root' }
        switch ($parts[1]) {
            'Public'   { return 'shared-public' }
            'Scratch'  { return 'shared-scratch' }
            'Archive'  { return 'shared-archive' }
            'Projects' { return 'shared-projects' }
        }
        return 'shared-other'
    }
    if ($top -eq 'Departments') {
        if ($parts.Length -lt 2) { return 'dept-container' }  # the top-level "Departments" folder itself
        if ($parts.Length -eq 2) { return 'dept-root' }
        if ($F.isSensitive)      { return 'dept-sensitive' }
        if ($F.isArchive)        { return 'dept-archive' }
        return 'dept-sub'
    }
    return 'other'
}

# ---------------------------------------------------------------------------
# Clean-template builder
# ---------------------------------------------------------------------------
function New-CleanTemplate {
    param([object]$F, [string]$Category)

    $aces = [System.Collections.Generic.List[object]]::new()
    $aces.Add((New-Ace -Sid $wellKnown.SYSTEM       -Rights FullControl -Inherit All))
    $aces.Add((New-Ace -Sid $wellKnown.DomainAdmins -Rights FullControl -Inherit All))
    $aces.Add((New-Ace -Sid $wellKnown.CreatorOwner -Rights FullControl -Inherit CreatorOwner))

    $protected = $false    # inheritance blocked?

    switch ($Category) {
        'dept-root' {
            $dept = ($F.relPath -split '/')[1]
            # Probe fancier group names silently — most depts only have GRP_$dept.
            $rwSid  = Get-GroupSid "GRP_${dept}BuildsRW"  -Silent
            if (-not $rwSid) { $rwSid = Get-GroupSid "GRP_${dept}ReadWrite" -Silent }
            if (-not $rwSid) { $rwSid = Get-GroupSid "GRP_$dept" }
            $deptSid = Get-GroupSid "GRP_$dept"
            if ($rwSid)  { $aces.Add((New-Ace -Sid $rwSid  -Rights Modify)) }
            if ($deptSid -and $deptSid -ne $rwSid) {
                $aces.Add((New-Ace -Sid $deptSid -Rights ReadAndExecute))
            }
        }
        'dept-sensitive' {
            $protected = $true
            $dept = ($F.relPath -split '/')[1]
            $specific = switch -Wildcard ($F.relPath) {
                '*/Payroll*'            { 'GRP_HRPayroll' }
                '*/Employees*'          { 'GRP_HREmployeeRecords' }
                '*/Contracts*'          { 'GRP_LegalContractsRW' }
                '*/Audit*'              { 'GRP_AuditReadOnly' }
                '*/Confidential*'       { 'GRP_ExecutiveConfidential' }
                '*/Board*'              { 'GRP_BoardAccess' }
                default                 { "GRP_$dept" }
            }
            $sid = Get-GroupSid $specific
            if ($sid) { $aces.Add((New-Ace -Sid $sid -Rights FullControl)) }
        }
        'dept-archive' {
            $dept = ($F.relPath -split '/')[1]
            $deptSid = Get-GroupSid "GRP_$dept"
            $itSid   = Get-GroupSid 'GRP_ITAdmins'
            if ($deptSid) { $aces.Add((New-Ace -Sid $deptSid -Rights Read)) }
            if ($itSid)   { $aces.Add((New-Ace -Sid $itSid   -Rights Modify)) }
        }
        'dept-sub' {
            # Inherit silently from dept-root — no explicit ACE needed beyond SYSTEM/DomainAdmins.
        }
        'shared-public' {
            $aces.Add((New-Ace -Sid (Get-GroupSid 'GRP_AllStaff') -Rights Modify))
        }
        'shared-scratch' {
            $aces.Add((New-Ace -Sid (Get-GroupSid 'GRP_AllStaff') -Rights Modify))
            $aces.Add((New-Ace -Sid $wellKnown.Everyone -Rights Read))
        }
        'shared-archive' {
            $aces.Add((New-Ace -Sid (Get-GroupSid 'GRP_AllStaff') -Rights Read))
            $itSid = Get-GroupSid 'GRP_ITAdmins'
            if ($itSid) { $aces.Add((New-Ace -Sid $itSid -Rights Modify)) }
        }
        'shared-projects' {
            $parts = $F.relPath -split '/'
            if ($parts.Length -ge 3) {
                $projName = $parts[2]
                $pSid = Get-GroupSid "GRP_Project$projName" -Silent  # may or may not exist
                if ($pSid) {
                    $aces.Add((New-Ace -Sid $pSid -Rights Modify))
                } else {
                    $all = Get-GroupSid 'GRP_AllStaff'
                    if ($all) { $aces.Add((New-Ace -Sid $all -Rights Read)) }
                }
            }
        }
        default {
            # Fallback: AllStaff:Read
            $all = Get-GroupSid 'GRP_AllStaff'
            if ($all) { $aces.Add((New-Ace -Sid $all -Rights Read)) }
        }
    }

    return [pscustomobject]@{
        Category  = $Category
        Protected = $protected
        Aces      = $aces
        Owner     = $null     # unchanged by default
    }
}

# ---------------------------------------------------------------------------
# Pre-plan every folder
# ---------------------------------------------------------------------------
Write-Log "Planning clean ACLs"
$plans = [System.Collections.Generic.List[object]]::new()
$nonRoot = [System.Collections.Generic.List[object]]::new()
foreach ($f in $folders) {
    if ($f.relPath -eq '') { continue }
    $cat = Get-FolderCategory $f
    $tmpl = New-CleanTemplate -F $f -Category $cat
    $plans.Add([pscustomobject]@{
        Path       = $f.path
        RelPath    = $f.relPath
        Category   = $cat
        Folder     = $f
        Aces       = $tmpl.Aces
        Protected  = $tmpl.Protected
        Owner      = $tmpl.Owner
        MessFlags  = [System.Collections.Generic.List[string]]::new()
    })
    $nonRoot.Add($f)
}
Write-Log "Planned $($plans.Count) folder ACLs"

# Build path → plan index for quick lookup
$planByPath = @{}
for ($i = 0; $i -lt $plans.Count; $i++) { $planByPath[$plans[$i].RelPath] = $i }

# ---------------------------------------------------------------------------
# Mess pattern overlays
# ---------------------------------------------------------------------------
$aclCfg = $cfg.acl
$messCounters = [ordered]@{ oversharing=0; orphaned=0; brokenInheritance=0; directUser=0; ownerMismatch=0; conflicting=0; fileAce=0 }

# --- 1. Oversharing (5%) ---
$overshareN = [int]([Math]::Ceiling($plans.Count * ([double]$aclCfg.oversharePercent / 100.0)))
$sensitiveIdx = @()
$nonSensitiveIdx = @()
for ($i = 0; $i -lt $plans.Count; $i++) {
    if ($plans[$i].Folder.isSensitive -or $plans[$i].Category -in @('dept-sensitive','dept-archive')) {
        $sensitiveIdx += $i
    } else {
        $nonSensitiveIdx += $i
    }
}
# Prefer sensitive folders but fall back to non-sensitive if not enough.
$pool = @($sensitiveIdx + $nonSensitiveIdx)
$picked = Get-RandomSample -Rng $rngMess -Items $pool -N $overshareN
foreach ($i in $picked) {
    $variant = Get-WeightedIndex -Rng $rngMess -Weights @(40.0, 25.0, 15.0, 20.0)
    $ace = switch ($variant) {
        0 { New-Ace -Sid $wellKnown.Everyone           -Rights Read       -Inherit All }
        1 { New-Ace -Sid $wellKnown.AuthenticatedUsers -Rights Modify     -Inherit All }
        2 { New-Ace -Sid $wellKnown.DomainUsers        -Rights FullControl -Inherit All }
        default {
            $all = Get-GroupSid 'GRP_AllStaff'
            if ($all) { New-Ace -Sid $all -Rights Read -Inherit All }
        }
    }
    if ($ace) { $plans[$i].Aces.Add($ace); [void]$plans[$i].MessFlags.Add('overshare'); $messCounters.oversharing++ }
}

# --- 2. Orphaned SID ACEs (3%) ---
$orphanN = [int]([Math]::Ceiling($plans.Count * ([double]$aclCfg.orphanedSidPercent / 100.0)))
if ($terminatedUsers.Count -gt 0) {
    $orphanIdxs = Get-RandomSample -Rng $rngMess -Items @(0..($plans.Count - 1)) -N $orphanN
    foreach ($i in $orphanIdxs) {
        $term = Get-RandomPick -Rng $rngMess -Items $terminatedUsers
        $plans[$i].Aces.Add((New-Ace -Sid $term.sid -Rights Modify -Inherit All))
        [void]$plans[$i].MessFlags.Add('orphanAce')
        $messCounters.orphaned++
    }
}

# --- 3. Broken inheritance (4%) — prefer 3+ level folders ---
$brokenN = [int]([Math]::Ceiling($plans.Count * ([double]$aclCfg.brokenInheritancePercent / 100.0)))
$deepIdx = @()
for ($i = 0; $i -lt $plans.Count; $i++) {
    $depth = ($plans[$i].RelPath -split '/').Length
    if ($depth -ge 3 -and $plans[$i].Category -notin @('dept-sensitive')) { $deepIdx += $i }
}
$brokenPicked = Get-RandomSample -Rng $rngMess -Items $deepIdx -N ([Math]::Min($brokenN, $deepIdx.Length))
foreach ($i in $brokenPicked) {
    $plans[$i].Protected = $true
    $subVariant = Get-WeightedIndex -Rng $rngMess -Weights @(40.0, 35.0, 25.0)  # stricter / looser / unrelated
    switch ($subVariant) {
        0 {
            # Stricter: keep a single manager-ish group
            $plans[$i].Aces.Clear()
            $plans[$i].Aces.Add((New-Ace -Sid $wellKnown.SYSTEM -Rights FullControl))
            $plans[$i].Aces.Add((New-Ace -Sid $wellKnown.DomainAdmins -Rights FullControl))
            $mgrSid = Get-GroupSid 'GRP_Managers'
            if ($mgrSid) { $plans[$i].Aces.Add((New-Ace -Sid $mgrSid -Rights FullControl)) }
        }
        1 {
            # Looser: add Everyone:Read on top
            $plans[$i].Aces.Add((New-Ace -Sid $wellKnown.Everyone -Rights Read -Inherit All))
        }
        default {
            # Unrelated: ACL belongs to a different department
            $otherDept = Get-RandomPick -Rng $rngMess -Items @($cfg.folders.departmentShares)
            $otherSid = Get-GroupSid "GRP_$otherDept"
            if ($otherSid) {
                $plans[$i].Aces.Clear()
                $plans[$i].Aces.Add((New-Ace -Sid $wellKnown.SYSTEM -Rights FullControl))
                $plans[$i].Aces.Add((New-Ace -Sid $wellKnown.DomainAdmins -Rights FullControl))
                $plans[$i].Aces.Add((New-Ace -Sid $otherSid -Rights Modify))
            }
        }
    }
    [void]$plans[$i].MessFlags.Add('brokenInherit')
    $messCounters.brokenInheritance++
}

# --- 4. Direct-user ACEs (6%) ---
$directN = [int]([Math]::Ceiling($plans.Count * ([double]$aclCfg.directUserAcePercent / 100.0)))
$directIdxs = Get-RandomSample -Rng $rngMess -Items @(0..($plans.Count - 1)) -N $directN
foreach ($i in $directIdxs) {
    $variant = Get-WeightedIndex -Rng $rngMess -Weights @(60.0, 25.0, 15.0)   # single / sprawl / wrong-dept
    switch ($variant) {
        0 {
            $u = Get-RandomPick -Rng $rngMess -Items $activeUsers
            $rights = if ($rngMess.NextDouble() -lt 0.3) { 'FullControl' } else { 'Modify' }
            $plans[$i].Aces.Add((New-Ace -Sid $u.sid -Rights $rights))
        }
        1 {
            $picks = Get-RandomSample -Rng $rngMess -Items $activeUsers -N 4
            foreach ($u in $picks) { $plans[$i].Aces.Add((New-Ace -Sid $u.sid -Rights Modify)) }
        }
        default {
            $folderDept = ($plans[$i].RelPath -split '/')[1]
            $wrong = @($activeUsers | Where-Object { $_.department -ne $folderDept })
            if ($wrong.Count -gt 0) {
                $u = Get-RandomPick -Rng $rngMess -Items $wrong
                $plans[$i].Aces.Add((New-Ace -Sid $u.sid -Rights Modify))
            }
        }
    }
    [void]$plans[$i].MessFlags.Add('directUser')
    $messCounters.directUser++
}

# --- 5. Owner mismatches (10%) ---
$ownerN = [int]([Math]::Ceiling($plans.Count * ([double]$aclCfg.ownerMismatchPercent / 100.0)))
$ownerIdxs = Get-RandomSample -Rng $rngOwn -Items @(0..($plans.Count - 1)) -N $ownerN
foreach ($i in $ownerIdxs) {
    $variant = Get-WeightedIndex -Rng $rngOwn -Weights @(40.0, 20.0, 25.0, 15.0)
    $ownerSid = switch ($variant) {
        0 { (Get-RandomPick -Rng $rngOwn -Items $activeUsers).sid }              # random user
        1 { (Get-RandomPick -Rng $rngOwn -Items $activeUsers).sid }              # 'ex-admin' — approximated with random active user
        2 {
            if ($serviceUsers.Count -gt 0) { (Get-RandomPick -Rng $rngOwn -Items $serviceUsers).sid } else { $null }
        }
        default {
            if ($terminatedUsers.Count -gt 0) { (Get-RandomPick -Rng $rngOwn -Items $terminatedUsers).sid } else { $null }
        }
    }
    if ($ownerSid) {
        $plans[$i].Owner = $ownerSid
        [void]$plans[$i].MessFlags.Add("ownerMismatch/$variant")
        $messCounters.ownerMismatch++
    }
}

# --- 6. Conflicting allow/deny (1%) ---
$conflictN = [int]([Math]::Ceiling($plans.Count * ([double]$aclCfg.conflictingAcePercent / 100.0)))
$conflictIdxs = Get-RandomSample -Rng $rngMess -Items @(0..($plans.Count - 1)) -N $conflictN
foreach ($i in $conflictIdxs) {
    $dept = ($plans[$i].RelPath -split '/')
    $deptName = if ($dept.Length -ge 2) { $dept[1] } else { 'Operations' }
    # Silent probe: for Shared/* folders $deptName is "Projects"/"Scratch"/etc which
    # are valid share buckets but not AD groups. Fall back to GRP_AllStaff quietly.
    $sid = Get-GroupSid "GRP_$deptName" -Silent
    if (-not $sid) { $sid = Get-GroupSid 'GRP_AllStaff' }
    if ($sid) {
        $plans[$i].Aces.Add((New-Ace -Sid $sid -Rights Write -Type Deny -Inherit All))
        [void]$plans[$i].MessFlags.Add('conflicting')
        $messCounters.conflicting++
    }
}

Write-Log ("Mess plan: " + ($messCounters.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ' ')

# ---------------------------------------------------------------------------
# File-level ACE plan (~0.5% of files) — disk-driven now that file-manifest.jsonl
# is gone (see docs/06-streaming-rewrite.md / D-029).
# Reservoir-samples paths from Directory.EnumerateFiles, then assigns a random
# active user + Modify ACE to each.
# ---------------------------------------------------------------------------
$filePlans = [System.Collections.Generic.List[object]]::new()
$rootPath = $folderManifest.meta.rootPath
if (Test-Path $rootPath) {
    # Upper-bound the sample size: base files + drift (~10%) + dup (~8%), so ~1.2x totalFilesPlanned.
    $estTotal = [int]([Math]::Ceiling([double]$folderManifest.meta.totalFilesPlanned * 1.2))
    $fileAceN = [int]([Math]::Ceiling($estTotal * 0.005))
    if ($fileAceN -gt 0) {
        Write-Log "File-level ACE target ~$fileAceN (reservoir sample over disk)"
        $reservoir = New-Object 'string[]' $fileAceN
        $seen = 0
        $enumOpts = New-Object System.IO.EnumerationOptions
        $enumOpts.RecurseSubdirectories = $true
        $enumOpts.IgnoreInaccessible    = $true
        foreach ($p in [System.IO.Directory]::EnumerateFiles($rootPath, '*', $enumOpts)) {
            if ($seen -lt $fileAceN) {
                $reservoir[$seen] = $p
            } else {
                $j = $rngFile.Next(0, $seen + 1)
                if ($j -lt $fileAceN) { $reservoir[$j] = $p }
            }
            $seen++
        }
        $actualN = [Math]::Min($seen, $fileAceN)
        for ($i = 0; $i -lt $actualN; $i++) {
            $u = Get-RandomPick -Rng $rngFile -Items $activeUsers
            $filePlans.Add([pscustomobject]@{
                Path   = $reservoir[$i]
                Sid    = $u.sid
                Rights = 'Modify'
            })
            $messCounters.fileAce++
        }
        Write-Log "Planned $($filePlans.Count) file-level ACEs (scanned $seen files)"
    }
}

# ---------------------------------------------------------------------------
# Apply — parallel
# ---------------------------------------------------------------------------
Write-Log "Applying folder ACLs (parallel, throttle=$throttle)"
$sw = [System.Diagnostics.Stopwatch]::StartNew()

# Chunk plans into batches for parallel work
$batchSize = [Math]::Max(200, [int]([Math]::Ceiling($plans.Count / ($throttle * 4))))
$batches = [System.Collections.Generic.List[object]]::new()
for ($i = 0; $i -lt $plans.Count; $i += $batchSize) {
    $end = [Math]::Min($i + $batchSize - 1, $plans.Count - 1)
    $batches.Add([pscustomobject]@{ Id = $batches.Count + 1; Plans = $plans[$i..$end] })
}
Write-Log "Apply batches: $($batches.Count) of ~$batchSize plans each"

$results = $batches | ForEach-Object -ThrottleLimit $throttle -Parallel {
    $batch = $_
    $applied = 0; $failed = 0
    $fails = [System.Collections.Generic.List[string]]::new()
    foreach ($plan in $batch.Plans) {
        try {
            $sec = New-Object System.Security.AccessControl.DirectorySecurity
            if ($plan.Protected) { $sec.SetAccessRuleProtection($true, $false) }

            foreach ($a in $plan.Aces) {
                $rightsEnum = [System.Security.AccessControl.FileSystemRights]$a.Rights
                $typeEnum   = [System.Security.AccessControl.AccessControlType]$a.Type
                $inherit = switch ($a.Inherit) {
                    'None'          { [System.Security.AccessControl.InheritanceFlags]::None }
                    'This'          { [System.Security.AccessControl.InheritanceFlags]::None }
                    'ContainerOnly' { [System.Security.AccessControl.InheritanceFlags]::ContainerInherit }
                    'All'           { [System.Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [System.Security.AccessControl.InheritanceFlags]::ObjectInherit }
                    'CreatorOwner'  { [System.Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [System.Security.AccessControl.InheritanceFlags]::ObjectInherit }
                    default         { [System.Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [System.Security.AccessControl.InheritanceFlags]::ObjectInherit }
                }
                $prop = if ($a.Inherit -eq 'CreatorOwner') {
                    [System.Security.AccessControl.PropagationFlags]::InheritOnly
                } else {
                    [System.Security.AccessControl.PropagationFlags]::None
                }
                $sidObj = [System.Security.Principal.SecurityIdentifier]::new($a.Sid)
                $rule = New-Object System.Security.AccessControl.FileSystemAccessRule `
                    -ArgumentList $sidObj, $rightsEnum, $inherit, $prop, $typeEnum
                $sec.AddAccessRule($rule)
            }
            if ($plan.Owner) {
                $sec.SetOwner([System.Security.Principal.SecurityIdentifier]::new($plan.Owner))
            }
            $di = [System.IO.DirectoryInfo]::new($plan.Path)
            [System.IO.FileSystemAclExtensions]::SetAccessControl($di, $sec)
            $applied++
        } catch {
            $failed++
            $fails.Add("$($plan.Path) :: $($_.Exception.Message)")
        }
    }
    [pscustomobject]@{ Id=$batch.Id; Applied=$applied; Failed=$failed; Failures=$fails }
}

$applied = ($results | Measure-Object Applied -Sum).Sum
$failed  = ($results | Measure-Object Failed  -Sum).Sum
Write-Log ("Folder apply: applied={0} failed={1}" -f $applied, $failed) 'OK'
if ($failed -gt 0) {
    foreach ($r in $results) { foreach ($m in ($r.Failures | Select-Object -First 5)) { Write-Log $m 'ERROR' } }
}

# --- Apply file-level ACEs ---
if ($filePlans.Count -gt 0) {
    Write-Log "Applying $($filePlans.Count) file-level ACEs"
    $fileFailed = 0; $fileApplied = 0
    foreach ($fp in $filePlans) {
        try {
            $fi = [System.IO.FileInfo]::new($fp.Path)
            $fs = [System.IO.FileSystemAclExtensions]::GetAccessControl($fi)
            $sidObj = [System.Security.Principal.SecurityIdentifier]::new($fp.Sid)
            $rule = New-Object System.Security.AccessControl.FileSystemAccessRule `
                -ArgumentList $sidObj, ([System.Security.AccessControl.FileSystemRights]$fp.Rights), ([System.Security.AccessControl.AccessControlType]::Allow)
            $fs.AddAccessRule($rule)
            [System.IO.FileSystemAclExtensions]::SetAccessControl($fi, $fs)
            $fileApplied++
        } catch {
            $fileFailed++
        }
    }
    Write-Log "File-level ACEs: applied=$fileApplied failed=$fileFailed" 'OK'
}

$sw.Stop()

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
$summary = [ordered]@{
    folderPlans       = $plans.Count
    folderApplied     = $applied
    folderFailed      = $failed
    filePlans         = $filePlans.Count
    messCounters      = $messCounters
    elapsedSeconds    = [Math]::Round($sw.Elapsed.TotalSeconds, 2)
    logPath           = $LogPath
}
$summary | ConvertTo-Json -Depth 4 | Set-Content -Path (Join-Path $LogDir 'acl-summary.json') -Encoding utf8
Write-Log ("Done in {0:N1}s. See acl-summary.json for breakdown." -f $sw.Elapsed.TotalSeconds) 'OK'
$summary | Format-List

if ($failed / [Math]::Max(1, $plans.Count) -gt 0.001) { exit 1 }
